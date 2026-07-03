import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class VoiceTargetInputManager: ObservableObject {
    @Published private(set) var transcriptText = ""
    @Published private(set) var resolvedTargetText = ""
    @Published private(set) var statusText = "Tap the microphone to speak a target object"
    @Published private(set) var authorizationStatusText = "Speech idle"
    @Published private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isAwaitingModeSelection = false
    private var shouldKeepListening = false
    private var isRestartingRecognition = false
    private var lastHandledModeTranscript = ""
    private var lastHandledTargetTranscript = ""
    private var lastModeSwitchPromptDate: Date?
    private var modeSwitchCooldownUntil: Date?
    private var modeSelectionTimeoutTask: Task<Void, Never>?
    private var hasSpokenModeSwitchAcknowledgement = false
    private var onResolvedTargetHandler: ((String) -> Void)?
    private var onResolvedModeHandler: ((AppCoordinator.Mode) -> Void)?

    func toggleListening(
        onResolvedTarget: @escaping (String) -> Void,
        onResolvedMode: @escaping (AppCoordinator.Mode) -> Void
    ) {
        if isListening {
            stopContinuousListening()
        } else {
            startContinuousListening(
                onResolvedTarget: onResolvedTarget,
                onResolvedMode: onResolvedMode
            )
        }
    }

    func startContinuousListening(
        onResolvedTarget: @escaping (String) -> Void,
        onResolvedMode: @escaping (AppCoordinator.Mode) -> Void
    ) {
        onResolvedTargetHandler = onResolvedTarget
        onResolvedModeHandler = onResolvedMode
        shouldKeepListening = true

        guard !isListening else {
            statusText = "Always listening for voice commands"
            return
        }

        isAwaitingModeSelection = false
        lastHandledModeTranscript = ""
        lastHandledTargetTranscript = ""
        lastModeSwitchPromptDate = nil
        modeSwitchCooldownUntil = nil
        modeSelectionTimeoutTask?.cancel()
        modeSelectionTimeoutTask = nil
        hasSpokenModeSwitchAcknowledgement = false
        startListening(
            onResolvedTarget: onResolvedTarget,
            onResolvedMode: onResolvedMode
        )
    }

    func stopContinuousListening() {
        shouldKeepListening = false
        cancelModeSelection()
        stopListening()
    }

    func stopListening() {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false
        authorizationStatusText = "Speech idle"

        if resolvedTargetText.isEmpty {
            statusText = transcriptText.isEmpty
                ? "Voice listening paused"
                : "No supported object found in speech"
        } else {
            statusText = "Using voice target \(resolvedTargetText)"
        }
    }

    private func startListening(
        onResolvedTarget: @escaping (String) -> Void,
        onResolvedMode: @escaping (AppCoordinator.Mode) -> Void
    ) {
        guard let speechRecognizer else {
            statusText = "Speech recognizer unavailable"
            authorizationStatusText = "Speech unavailable"
            return
        }

        Task {
            let hasSpeechPermission = await requestSpeechAuthorization()
            let hasMicrophonePermission = await requestMicrophoneAuthorization()

            guard hasSpeechPermission else {
                authorizationStatusText = "Speech denied"
                statusText = "Enable speech recognition in Settings"
                return
            }

            guard hasMicrophonePermission else {
                authorizationStatusText = "Mic denied"
                statusText = "Enable microphone access in Settings"
                return
            }

            do {
                try configureAudioSession()
                try beginRecognition(
                    speechRecognizer: speechRecognizer,
                    onResolvedTarget: onResolvedTarget,
                    onResolvedMode: onResolvedMode
                )
            } catch {
                stopListening()
                authorizationStatusText = "Speech failed"
                statusText = error.localizedDescription
            }
        }
    }

    private func beginRecognition(
        speechRecognizer: SFSpeechRecognizer,
        onResolvedTarget: @escaping (String) -> Void,
        onResolvedMode: @escaping (AppCoordinator.Mode) -> Void
    ) throws {
        stopListening()

        transcriptText = ""
        resolvedTargetText = ""
        statusText = "Listening for target object or mode switch"
        authorizationStatusText = "Listening"

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else {
                    return
                }

                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.transcriptText = transcript
                    let normalizedTranscript = Self.normalizedSpeechText(transcript)

                    if self.isAwaitingModeSelection {
                        if let mode = Self.resolvedMode(from: normalizedTranscript) {
                            self.completeModeSelection(
                                mode,
                                transcript: normalizedTranscript,
                                onResolvedMode: onResolvedMode
                            )
                        } else {
                            self.statusText = "Waiting for awareness, find and go, or GPS"
                        }
                    } else if Self.isModeSwitchCommand(normalizedTranscript),
                              self.shouldHandleModeSwitchPrompt(for: normalizedTranscript) {
                        self.beginModeSelection(from: normalizedTranscript)
                    } else if !self.isAwaitingModeSelection,
                              let resolvedTarget = AppConfig.ObjectDetection.resolvedTargetLabel(from: transcript),
                              self.lastHandledTargetTranscript != normalizedTranscript {
                        self.lastHandledTargetTranscript = normalizedTranscript
                        self.resolvedTargetText = resolvedTarget
                        self.statusText = "Recognized \(resolvedTarget)"
                        onResolvedTarget(resolvedTarget)
                    } else {
                        self.statusText = self.isAwaitingModeSelection
                            ? "Listening for awareness, find and go, or GPS"
                            : "Listening for a supported object or mode switch"
                    }

                    if result.isFinal {
                        self.restartRecognitionIfNeeded()
                    }
                }

                if error != nil {
                    self.restartRecognitionIfNeeded()
                }
            }
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func configureSpokenAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)
    }

    private func speak(_ text: String) {
        do {
            try configureSpokenAudioSession()
        } catch {
            statusText = "Speech confirmation failed: \(error.localizedDescription)"
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    private func beginModeSelection(from normalizedTranscript: String) {
        isAwaitingModeSelection = true
        lastHandledModeTranscript = normalizedTranscript
        lastModeSwitchPromptDate = Date()
        hasSpokenModeSwitchAcknowledgement = true
        statusText = "Switch mode: waiting for mode name"
        speak("Ok")
        scheduleModeSelectionTimeout()
    }

    private func completeModeSelection(
        _ mode: AppCoordinator.Mode,
        transcript normalizedTranscript: String,
        onResolvedMode: @escaping (AppCoordinator.Mode) -> Void
    ) {
        modeSelectionTimeoutTask?.cancel()
        modeSelectionTimeoutTask = nil
        isAwaitingModeSelection = false
        lastHandledModeTranscript = normalizedTranscript
        lastModeSwitchPromptDate = nil
        hasSpokenModeSwitchAcknowledgement = false
        modeSwitchCooldownUntil = Date().addingTimeInterval(AppConfig.Voice.modeSwitchCooldownSeconds)
        statusText = "Switched to \(mode.displayName)"
        onResolvedMode(mode)
    }

    private func cancelModeSelection() {
        modeSelectionTimeoutTask?.cancel()
        modeSelectionTimeoutTask = nil
        isAwaitingModeSelection = false
        lastModeSwitchPromptDate = nil
        hasSpokenModeSwitchAcknowledgement = false
    }

    private func scheduleModeSelectionTimeout() {
        modeSelectionTimeoutTask?.cancel()
        modeSelectionTimeoutTask = Task { @MainActor [weak self] in
            let delayNanoseconds = UInt64(AppConfig.Voice.modeSelectionTimeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            guard let self, self.isAwaitingModeSelection else {
                return
            }

            self.cancelModeSelection()
            self.modeSwitchCooldownUntil = Date().addingTimeInterval(AppConfig.Voice.modeSwitchCooldownSeconds)
            self.statusText = "Always listening for voice commands"
        }
    }

    private func shouldHandleModeSwitchPrompt(for normalizedTranscript: String) -> Bool {
        if let modeSwitchCooldownUntil, Date() < modeSwitchCooldownUntil {
            return false
        }

        guard lastHandledModeTranscript != normalizedTranscript else {
            return false
        }

        guard let lastModeSwitchPromptDate else {
            return true
        }

        return Date().timeIntervalSince(lastModeSwitchPromptDate) > 8
    }

    private func restartRecognitionIfNeeded() {
        guard shouldKeepListening,
              !isRestartingRecognition,
              let speechRecognizer,
              let onResolvedTargetHandler,
              let onResolvedModeHandler else {
            stopListening()
            return
        }

        isRestartingRecognition = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            do {
                try self.configureAudioSession()
                try self.beginRecognition(
                    speechRecognizer: speechRecognizer,
                    onResolvedTarget: onResolvedTargetHandler,
                    onResolvedMode: onResolvedModeHandler
                )
                self.isRestartingRecognition = false
                self.statusText = self.isAwaitingModeSelection
                    ? "Listening for awareness, find and go, or GPS"
                    : "Always listening for voice commands"
            } catch {
                self.isRestartingRecognition = false
                self.statusText = "Speech restart failed: \(error.localizedDescription)"
            }
        }
    }

    private static func isModeSwitchCommand(_ normalizedTranscript: String) -> Bool {
        normalizedTranscript.contains("switch mode")
            || normalizedTranscript.contains("change mode")
            || normalizedTranscript.contains("mode switch")
    }

    private static func resolvedMode(from normalizedTranscript: String) -> AppCoordinator.Mode? {
        if normalizedTranscript.contains("awareness") || normalizedTranscript.contains("aware") {
            return .awareness
        }

        if normalizedTranscript.contains("find and go")
            || normalizedTranscript.contains("find go")
            || normalizedTranscript.contains("find mode")
            || normalizedTranscript.contains("object mode") {
            return .findAndGo
        }

        if normalizedTranscript.contains("gps")
            || normalizedTranscript.contains("navigation")
            || normalizedTranscript.contains("navigate") {
            return .gpsNavigation
        }

        return nil
    }

    private static func normalizedSpeechText(_ text: String) -> String {
        let lowercasedText = text.lowercased()
        let scalarView = lowercasedText.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(scalar) : " "
        }

        return String(scalarView)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func requestSpeechAuthorization() async -> Bool {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()

        if currentStatus == .authorized {
            return true
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
