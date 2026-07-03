import AVFoundation
import Combine
import CoreGraphics
import CoreImage
import Foundation

final class ObjectDetectionManager: ObservableObject {
    enum FindAndGoState: String {
        case waitingForTarget
        case scanning360
        case searching
        case reacquiring
        case bearingGuidance
        case acquired
        case approaching
        case arrived

        var displayText: String {
            switch self {
            case .waitingForTarget:
                return "Waiting"
            case .scanning360:
                return "Scanning"
            case .searching:
                return "Searching"
            case .reacquiring:
                return "Reacquiring"
            case .bearingGuidance:
                return "Bearing"
            case .acquired:
                return "Acquired"
            case .approaching:
                return "Approaching"
            case .arrived:
                return "Arrived"
            }
        }
    }

    private enum DepthSamplingStatus {
        case unavailable
        case missingBaseAddress
        case noValidSamples
        case insufficientValidSamples
        case outOfReliableRange
        case valid

        var displayText: String {
            switch self {
            case .unavailable:
                return "depth unavailable"
            case .missingBaseAddress:
                return "depth buffer unavailable"
            case .noValidSamples:
                return "no valid samples"
            case .insufficientValidSamples:
                return "low valid sample ratio"
            case .outOfReliableRange:
                return "out of reliable range"
            case .valid:
                return "valid"
            }
        }
    }

    private struct DepthSamplingResult {
        let distanceMeters: Float?
        let attemptedSampleCount: Int
        let validSampleCount: Int
        let status: DepthSamplingStatus
    }

    private struct FindAndGoScanObservation {
        let label: String
        let confidence: Float
        let distanceMeters: Float?
        let bearingRadians: Double
        let frameNumber: Int
        let observedAt: Date
        let score: CGFloat
    }

    private struct StopHysteresisState {
        var closeFrameCount = 0
        var clearFrameCount = 0
        var isStopped = false
    }

    @Published private(set) var modelStatusText = "Model not loaded"
    @Published private(set) var modelDetailsText = "No YOLO model requested yet"
    @Published private(set) var loadedModelNameText = "None"
    @Published private(set) var isModelLoaded = false
    @Published private(set) var inferenceStatusText = "Inference idle"
    @Published private(set) var detectionCountText = "0"
    @Published private(set) var lastInferenceFrameText = "No inference frames yet"
    @Published private(set) var detectionOverlays: [DetectionOverlayItem] = []
    @Published private(set) var latestLiveCommand: VestMessage?
    @Published private(set) var liveCommandStatusText = "No live command"
    @Published private(set) var liveCommandJSONText = "No live command JSON"
    @Published private(set) var liveUrgencyText = "No urgency"
    @Published private(set) var activeMode: AppCoordinator.Mode = .awareness
    @Published private(set) var requestedTargetLabel = ""
    @Published private(set) var findAndGoStatusText = "Enter an object to search for"
    @Published private(set) var findAndGoState: FindAndGoState = .waitingForTarget
    @Published private(set) var bearingStatusText = "No bearing lock"
    @Published private(set) var scanMemoryStatusText = "No scan target memory"
    @Published private(set) var depthFusionStatusText = "No depth fusion yet"
    @Published private(set) var depthFusionDetailsText = "No depth samples yet"
    @Published private(set) var inferencePerformanceText = "No inference timing yet"

    let targetSelector = TargetSelector()
    let directionEstimator = DirectionEstimator()
    let decisionSmoother = DecisionSmoother()
    let motionManager: MotionManager

    private let inferenceQueue = DispatchQueue(label: "visionvest.ultralytics.inference", qos: .userInitiated)
    private var detector: UltralyticsObjectDetector?
    private var isRunningInference = false
    private var commandSequence = 0
    private var hasLockedFindAndGoTarget = false
    private var hasSentFindAndGoScanCompleteMessage = false
    private var consecutiveMissingFindAndGoFrames = 0
    private var rememberedTargetBearingRadians: Double?
    private var bestFindAndGoScanObservation: FindAndGoScanObservation?
    private var awarenessStopHysteresisState = StopHysteresisState()
    private var findAndGoStopHysteresisState = StopHysteresisState()
    private var gpsStopHysteresisState = StopHysteresisState()
    private var recentInferenceTimes: [TimeInterval] = []
    private let maxInferenceTimingHistoryCount = 12

    init(motionManager: MotionManager = MotionManager()) {
        self.motionManager = motionManager
    }

    func setMode(_ mode: AppCoordinator.Mode) {
        activeMode = mode
        if mode == .findAndGo {
            motionManager.startUpdates()
            motionManager.resetScanProgress()
        } else {
            motionManager.stopUpdates()
            resetFindAndGoState()
        }
        updateFindAndGoStatus()
        updateLiveCommand()
    }

    func setRequestedTargetLabel(_ label: String) {
        let normalizedLabel = AppCoordinator.normalizeTargetLabel(label)
        let didChangeTarget = normalizedLabel != requestedTargetLabel

        requestedTargetLabel = normalizedLabel

        if didChangeTarget {
            resetFindAndGoState()
            motionManager.resetScanProgress()
            rememberedTargetBearingRadians = nil
            bearingStatusText = "No bearing lock"
        }

        let filteredDetections = filteredDetections(from: detectionOverlays)
        targetSelector.updateSelection(from: filteredDetections, mode: activeMode)
        directionEstimator.updateDirection(for: targetSelector.selectedTarget)
        decisionSmoother.update(
            selectedTarget: targetSelector.selectedTarget,
            estimatedDirection: directionEstimator.currentDirection
        )
        updateFindAndGoStatus()
        updateLiveCommand()
    }

    func loadModel() {
        modelStatusText = "Loading model"
        modelDetailsText = "Checking app bundle for configured YOLO model names"
        loadedModelNameText = "Searching"
        isModelLoaded = false
        inferenceStatusText = "Inference unavailable"
        detector = nil

        for candidate in AppConfig.ObjectDetection.candidateModelNames {
            if let modelURL = bundledModelURL(named: candidate) {
                loadModel(at: modelURL, modelName: candidate)
                return
            }
        }

        modelStatusText = "Model load failed"
        modelDetailsText = "No bundled YOLO model found in the app bundle"
        loadedModelNameText = "Missing"
    }

    func processFrame(_ snapshot: FrameProcessingSnapshot) {
        guard let detector else {
            DispatchQueue.main.async {
                self.inferenceStatusText = "Inference unavailable"
                self.lastInferenceFrameText = "Model not loaded"
                self.detectionCountText = "0"
                self.detectionOverlays = []
            }
            return
        }

        guard !isRunningInference else {
            DispatchQueue.main.async {
                self.inferenceStatusText = "Skipping frame while inference is busy"
            }
            return
        }

        isRunningInference = true

        inferenceQueue.async {
            defer {
                self.isRunningInference = false
            }

            do {
                let result = try detector.predict(
                    pixelBuffer: snapshot.pixelBuffer,
                    orientation: snapshot.orientation
                )

                let overlayDepthPairs = result.detections
                    .filter {
                        $0.confidence >= AppConfig.ObjectDetection.minimumObservationConfidence
                            && !AppConfig.ObjectDetection.ignoredLabels.contains($0.label.lowercased())
                    }
                    .map {
                        let depthResult = self.estimateDistance(
                            for: $0.normalizedBoundingBox,
                            depthData: snapshot.depthData
                        )

                        let overlay = DetectionOverlayItem(
                            label: $0.label,
                            confidence: $0.confidence,
                            boundingBox: $0.normalizedBoundingBox,
                            distanceMeters: depthResult.distanceMeters
                        )

                        return (overlay, depthResult)
                    }
                let overlays = overlayDepthPairs.map { $0.0 }
                let depthResults = overlayDepthPairs.map { $0.1 }

                let filteredOverlays = self.filteredDetections(from: overlays)

                DispatchQueue.main.async {
                    self.applyDetections(
                        filteredOverlays,
                        depthResults: depthResults,
                        frameNumber: snapshot.frameNumber,
                        inferenceTime: result.inferenceTime
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.inferenceStatusText = "Inference failed"
                    self.lastInferenceFrameText = "Frame \(snapshot.frameNumber)"
                    self.modelDetailsText = error.localizedDescription
                    self.detectionCountText = "0"
                    self.detectionOverlays = []
                    self.depthFusionStatusText = "Depth fusion unavailable"
                    self.depthFusionDetailsText = "Inference failed before depth sampling"
                    self.targetSelector.updateSelection(from: [], mode: self.activeMode)
                    self.directionEstimator.updateDirection(for: nil)
                    self.decisionSmoother.update(selectedTarget: nil, estimatedDirection: .none)
                    self.updateFindAndGoStatus()
                    self.updateLiveCommand()
                }
            }
        }
    }

    private func loadModel(at url: URL, modelName: String) {
        UltralyticsObjectDetector.create(
            modelURL: url,
            confidenceThreshold: AppConfig.ObjectDetection.minimumObservationConfidence,
            iouThreshold: AppConfig.ObjectDetection.iouThreshold,
            maxDetections: AppConfig.ObjectDetection.maxDetections
        ) { result in
            switch result {
            case .success(let detector):
                self.detector = detector
                self.isModelLoaded = true
                self.modelStatusText = "Model loaded"
                self.modelDetailsText = "Ultralytics YOLO detector initialized successfully"
                self.loadedModelNameText = modelName
                self.inferenceStatusText = "Ready for live inference"
                self.resetDetections()

            case .failure(let error):
                self.detector = nil
                self.isModelLoaded = false
                self.modelStatusText = "Model load failed"
                self.modelDetailsText = error.localizedDescription
                self.loadedModelNameText = modelName
                self.inferenceStatusText = "Inference unavailable"
                self.resetDetections()
            }
        }
    }

    private func applyDetections(
        _ overlays: [DetectionOverlayItem],
        depthResults: [DepthSamplingResult],
        frameNumber: Int,
        inferenceTime: TimeInterval
    ) {
        inferenceStatusText = "Ultralytics inference active"
        lastInferenceFrameText = "Frame \(frameNumber)"
        detectionCountText = "\(overlays.count)"
        detectionOverlays = overlays
        updateInferencePerformance(with: inferenceTime)
        updateDepthFusionStatus(from: depthResults)
        targetSelector.updateSelection(from: overlays, mode: activeMode)
        updateRememberedTargetBearing(
            using: targetSelector.selectedTarget,
            frameNumber: frameNumber
        )
        directionEstimator.updateDirection(for: targetSelector.selectedTarget)
        decisionSmoother.update(
            selectedTarget: targetSelector.selectedTarget,
            estimatedDirection: directionEstimator.currentDirection
        )
        updateFindAndGoStatus()
        updateLiveCommand()

        if let selectedTarget = targetSelector.selectedTarget {
            modelDetailsText = String(
                format: "Selected target: %@ %.2f%@ in %.0f ms",
                selectedTarget.label,
                selectedTarget.confidence,
                selectedTarget.distanceMeters.map { " at \(Int($0 * 1000))mm" } ?? "",
                inferenceTime * 1000
            )
        } else {
            modelDetailsText = String(
                format: "No detections on the latest frame (%.0f ms)",
                inferenceTime * 1000
            )
        }
    }

    private func resetDetections() {
        detectionOverlays = []
        detectionCountText = "0"
        depthFusionStatusText = "No depth fusion yet"
        depthFusionDetailsText = "No detections sampled"
        inferencePerformanceText = "No inference timing yet"
        recentInferenceTimes.removeAll()
        targetSelector.updateSelection(from: [], mode: activeMode)
        directionEstimator.updateDirection(for: nil)
        decisionSmoother.update(selectedTarget: nil, estimatedDirection: .none)
        if activeMode == .findAndGo {
            consecutiveMissingFindAndGoFrames = 0
        }
        updateFindAndGoStatus()
        latestLiveCommand = nil
        liveCommandStatusText = "No live command"
        liveCommandJSONText = "No live command JSON"
        liveUrgencyText = "No urgency"
    }

    private func bundledModelURL(named modelName: String) -> URL? {
        let bundle = Bundle.main

        let directMatch = bundle.url(forResource: modelName, withExtension: "mlmodelc")
            ?? bundle.url(forResource: modelName, withExtension: "mlpackage")
            ?? bundle.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: "Models")
            ?? bundle.url(forResource: modelName, withExtension: "mlpackage", subdirectory: "Models")

        if let directMatch {
            return directMatch
        }

        let candidateURLs = (bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: "Models") ?? [])
            + (bundle.urls(forResourcesWithExtension: "mlpackage", subdirectory: "Models") ?? [])

        return candidateURLs.first { url in
            url.deletingPathExtension().lastPathComponent == modelName
        }
    }

    private func estimateDistance(for normalizedBoundingBox: CGRect, depthData: AVDepthData?) -> DepthSamplingResult {
        guard let depthData else {
            return DepthSamplingResult(
                distanceMeters: nil,
                attemptedSampleCount: 0,
                validSampleCount: 0,
                status: .unavailable
            )
        }

        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepth.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return DepthSamplingResult(
                distanceMeters: nil,
                attemptedSampleCount: 0,
                validSampleCount: 0,
                status: .missingBaseAddress
            )
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let pointer = baseAddress.assumingMemoryBound(to: Float32.self)

        let inset = AppConfig.ObjectDetection.depthSampleInsetFactor
        let sampledRect = normalizedBoundingBox.insetBy(
            dx: normalizedBoundingBox.width * inset,
            dy: normalizedBoundingBox.height * inset
        )

        let xRange = pixelRange(
            start: sampledRect.minX,
            end: sampledRect.maxX,
            limit: width
        )
        let yRange = pixelRange(
            start: 1 - sampledRect.maxY,
            end: 1 - sampledRect.minY,
            limit: height
        )

        var depthSamples: [Float] = []
        let attemptedSampleCount = max(1, xRange.count * yRange.count)
        depthSamples.reserveCapacity(attemptedSampleCount)

        for y in yRange {
            for x in xRange {
                let depth = pointer[(y * rowStride) + x]
                if depth.isFinite, depth > 0 {
                    depthSamples.append(depth)
                }
            }
        }

        guard !depthSamples.isEmpty else {
            return DepthSamplingResult(
                distanceMeters: nil,
                attemptedSampleCount: attemptedSampleCount,
                validSampleCount: 0,
                status: .noValidSamples
            )
        }

        let validSampleRatio = Float(depthSamples.count) / Float(attemptedSampleCount)
        guard validSampleRatio >= AppConfig.ObjectDetection.minimumValidDepthSampleRatio else {
            return DepthSamplingResult(
                distanceMeters: nil,
                attemptedSampleCount: attemptedSampleCount,
                validSampleCount: depthSamples.count,
                status: .insufficientValidSamples
            )
        }

        depthSamples.sort()
        let medianDistance = depthSamples[depthSamples.count / 2]
        guard medianDistance <= AppConfig.ObjectDetection.maximumReliableDepthDistance else {
            return DepthSamplingResult(
                distanceMeters: nil,
                attemptedSampleCount: attemptedSampleCount,
                validSampleCount: depthSamples.count,
                status: .outOfReliableRange
            )
        }

        return DepthSamplingResult(
            distanceMeters: medianDistance,
            attemptedSampleCount: attemptedSampleCount,
            validSampleCount: depthSamples.count,
            status: .valid
        )
    }

    private func updateDepthFusionStatus(from depthResults: [DepthSamplingResult]) {
        guard !depthResults.isEmpty else {
            depthFusionStatusText = "No detections to depth sample"
            depthFusionDetailsText = "Depth active, waiting for YOLO detections"
            return
        }

        let validDetectionCount = depthResults.filter { $0.distanceMeters != nil }.count
        let attemptedSampleCount = depthResults.reduce(0) { $0 + $1.attemptedSampleCount }
        let validSampleCount = depthResults.reduce(0) { $0 + $1.validSampleCount }
        let failureSummaries = depthResults
            .filter { $0.status != .valid }
            .map(\.status.displayText)

        depthFusionStatusText = "LiDAR fused \(validDetectionCount)/\(depthResults.count) detections"

        if failureSummaries.isEmpty {
            depthFusionDetailsText = "Valid depth samples \(validSampleCount)/\(attemptedSampleCount)"
        } else {
            depthFusionDetailsText = "Valid depth samples \(validSampleCount)/\(attemptedSampleCount); \(failureSummaries.joined(separator: ", "))"
        }
    }

    private func updateInferencePerformance(with inferenceTime: TimeInterval) {
        recentInferenceTimes.append(inferenceTime)

        if recentInferenceTimes.count > maxInferenceTimingHistoryCount {
            recentInferenceTimes.removeFirst()
        }

        let averageInferenceTime = recentInferenceTimes.reduce(0, +) / Double(recentInferenceTimes.count)
        let latestMilliseconds = inferenceTime * 1000
        let averageMilliseconds = averageInferenceTime * 1000
        let detectorFPS = averageInferenceTime > 0 ? 1 / averageInferenceTime : 0

        inferencePerformanceText = String(
            format: "latest %.0f ms, avg %.0f ms, %.1f detector FPS",
            latestMilliseconds,
            averageMilliseconds,
            detectorFPS
        )
    }

    private func pixelRange(start: CGFloat, end: CGFloat, limit: Int) -> ClosedRange<Int> {
        let lowerBound = min(max(Int(start * CGFloat(limit)), 0), max(limit - 1, 0))
        let upperBound = min(max(Int(end * CGFloat(limit)), lowerBound), max(limit - 1, 0))
        return lowerBound...upperBound
    }

    private func updateLiveCommand() {
        if activeMode == .findAndGo {
            updateFindAndGoLiveCommand()
            return
        }

        guard
            let selectedTarget = targetSelector.selectedTarget,
            selectedTarget.confidence >= AppConfig.Decision.minimumConfidenceThreshold,
            decisionSmoother.smoothedDirection != .none
        else {
            liveCommandStatusText = activeMode == .findAndGo && !requestedTargetLabel.isEmpty
                ? "Find & Go searching for \(requestedTargetLabel)"
                : "No stable navigation command"
            latestLiveCommand = nil
            liveCommandJSONText = "No live command JSON"
            liveUrgencyText = "No urgency"
            resetStopHysteresisIfNeeded()
            return
        }

        commandSequence += 1

        let command: VestMessage

        switch activeMode {
        case .awareness:
            let urgency = stabilizedAwarenessUrgency(for: selectedTarget.distanceMeters)
            command = makeAwarenessMessage(
                direction: decisionSmoother.smoothedDirection,
                urgency: urgency,
                confidence: selectedTarget.confidence,
                distanceMeters: selectedTarget.distanceMeters,
                seq: commandSequence
            )
            liveUrgencyText = urgency == .stop ? "Stop" : urgency.rawValue.capitalized
            liveCommandStatusText = urgency == .stop
                ? "Awareness stop moving"
                : "Awareness \(command.direction) \(urgency.rawValue)"

        case .findAndGo:
            let findAndGoUrgency = stabilizedFindAndGoUrgency(for: selectedTarget.distanceMeters)
            command = makeObjectNavigationMessage(
                direction: decisionSmoother.smoothedDirection,
                urgency: findAndGoUrgency,
                confidence: selectedTarget.confidence,
                distanceMeters: selectedTarget.distanceMeters,
                seq: commandSequence
            )
            liveUrgencyText = findAndGoUrgency == .stop ? "Stop" : findAndGoUrgency.rawValue.capitalized
            liveCommandStatusText = findAndGoUrgency == .stop
                ? "Find & Go reached \(selectedTarget.label)"
                : "Find & Go \(command.direction) toward \(selectedTarget.label)"

        case .gpsNavigation:
            let urgency = stabilizedGPSUrgency(for: selectedTarget.distanceMeters)
            command = makeObjectNavigationMessage(
                direction: decisionSmoother.smoothedDirection,
                urgency: urgency,
                confidence: selectedTarget.confidence,
                distanceMeters: selectedTarget.distanceMeters,
                seq: commandSequence
            )
            liveUrgencyText = urgency == .stop ? "Stop" : urgency.rawValue.capitalized
            liveCommandStatusText = urgency == .stop
                ? "GPS safety stop"
                : "GPS local safety \(command.direction) \(urgency.rawValue)"
        }

        liveCommandJSONText = makePrettyJSONString(from: command)
        latestLiveCommand = command
    }

    private func updateFindAndGoLiveCommand() {
        if shouldSendFindAndGoScanCompleteMessage {
            hasSentFindAndGoScanCompleteMessage = true
            commandSequence += 1
            let command = makeFindAndGoScanCompleteMessage(seq: commandSequence)
            latestLiveCommand = command
            liveCommandJSONText = makePrettyJSONString(from: command)
            liveUrgencyText = "Scan Complete"
            liveCommandStatusText = "Find & Go 360 scan complete"
            return
        }

        switch findAndGoState {
        case .waitingForTarget:
            liveCommandStatusText = "Find & Go waiting for target"
            latestLiveCommand = nil
            liveCommandJSONText = "No live command JSON"
            liveUrgencyText = "No urgency"
            findAndGoStopHysteresisState = StopHysteresisState()

        case .scanning360:
            liveCommandStatusText = bestFindAndGoScanObservation == nil
                ? "Complete 360 scan for \(requestedTargetLabel)"
                : "Finish scan; \(requestedTargetLabel) bearing locked"
            latestLiveCommand = nil
            liveCommandJSONText = "No live command JSON"
            liveUrgencyText = "Scanning"

        case .searching, .reacquiring, .bearingGuidance:
            let searchDirection = currentSearchDirection
            commandSequence += 1
            let command = makeFindAndGoSearchMessage(
                direction: searchDirection,
                seq: commandSequence
            )
            switch findAndGoState {
            case .searching:
                liveCommandStatusText = bestFindAndGoScanObservation == nil
                    ? "Find & Go target not found; search \(command.direction)"
                    : "Find & Go search \(command.direction) for \(requestedTargetLabel)"
            case .reacquiring:
                liveCommandStatusText = "Find & Go reacquire \(command.direction) for \(requestedTargetLabel)"
            case .bearingGuidance:
                liveCommandStatusText = "Find & Go turn \(command.direction) to \(requestedTargetLabel)"
            case .waitingForTarget, .scanning360, .acquired, .approaching, .arrived:
                liveCommandStatusText = "Find & Go search update"
            }
            latestLiveCommand = command
            liveCommandJSONText = makePrettyJSONString(from: command)
            liveUrgencyText = "Search"

        case .acquired, .approaching, .arrived:
            guard
                let selectedTarget = targetSelector.selectedTarget,
                selectedTarget.confidence >= AppConfig.Decision.minimumConfidenceThreshold
            else {
                liveCommandStatusText = "Find & Go stabilizing target"
                latestLiveCommand = nil
                liveCommandJSONText = "No live command JSON"
                liveUrgencyText = "No urgency"
                findAndGoStopHysteresisState = StopHysteresisState()
                return
            }

            guard decisionSmoother.smoothedDirection != .none else {
                commandSequence += 1
                let command = makeNeutralModeEntryMessage(mode: "object_nav", seq: commandSequence)
                latestLiveCommand = command
                liveCommandJSONText = makePrettyJSONString(from: command)
                liveUrgencyText = "Object Nav"
                liveCommandStatusText = "Find & Go object navigation ready"
                return
            }

            let smoothedDirection = decisionSmoother.smoothedDirection
            let urgency = findAndGoUrgency(
                for: smoothedDirection,
                distanceMeters: selectedTarget.distanceMeters
            )
            commandSequence += 1
            let command = makeObjectNavigationMessage(
                direction: smoothedDirection,
                urgency: urgency,
                confidence: selectedTarget.confidence,
                distanceMeters: selectedTarget.distanceMeters,
                seq: commandSequence
            )
            liveUrgencyText = urgency == .stop ? "Stop" : urgency.rawValue.capitalized

            switch findAndGoState {
            case .acquired:
                liveCommandStatusText = "Find & Go target acquired \(command.direction)"
            case .approaching:
                liveCommandStatusText = urgency == .stop
                    ? "Find & Go reached \(selectedTarget.label)"
                    : "Find & Go \(command.direction) toward \(selectedTarget.label)"
            case .arrived:
                liveCommandStatusText = "Find & Go reached \(selectedTarget.label)"
            case .waitingForTarget, .scanning360, .searching, .reacquiring, .bearingGuidance:
                liveCommandStatusText = "Find & Go target update"
            }

            latestLiveCommand = command
            liveCommandJSONText = makePrettyJSONString(from: command)
        }
    }

    private var shouldSendFindAndGoScanCompleteMessage: Bool {
        activeMode == .findAndGo
            && !requestedTargetLabel.isEmpty
            && motionManager.hasCompletedFullScan
            && !hasSentFindAndGoScanCompleteMessage
            && findAndGoState != .waitingForTarget
    }

    private func filteredDetections(from overlays: [DetectionOverlayItem]) -> [DetectionOverlayItem] {
        guard activeMode == .findAndGo else {
            return overlays
        }

        guard !requestedTargetLabel.isEmpty else {
            return []
        }

        let labelMatchedDetections = overlays.filter { detection in
            AppCoordinator.normalizeTargetLabel(detection.label) == requestedTargetLabel
        }

        guard motionManager.hasCompletedFullScan,
              let rememberedTargetBearingRadians else {
            return labelMatchedDetections
        }

        return labelMatchedDetections.filter { detection in
            guard let detectionBearing = bearingRadians(for: detection) else {
                return false
            }

            let angularDifferenceDegrees = abs(normalizedAngle(detectionBearing - rememberedTargetBearingRadians)) * 180 / .pi
            return angularDifferenceDegrees <= AppConfig.Decision.findAndGoLockedBearingToleranceDegrees
        }
    }

    private func updateFindAndGoStatus() {
        guard activeMode == .findAndGo else {
            findAndGoStatusText = "Inactive"
            return
        }

        guard !requestedTargetLabel.isEmpty else {
            findAndGoState = .waitingForTarget
            findAndGoStatusText = "Enter an object to search for"
            return
        }

        if !motionManager.hasCompletedFullScan {
            findAndGoState = .scanning360
            if let bestFindAndGoScanObservation {
                let distanceText = bestFindAndGoScanObservation.distanceMeters
                    .map { " at \(Int($0 * 1000)) mm" } ?? ""
                findAndGoStatusText = "Locked \(bestFindAndGoScanObservation.label)\(distanceText), finish 360 scan (\(motionManager.accumulatedRotationDegreesText))"
            } else {
                findAndGoStatusText = "Scan 360 for \(requestedTargetLabel) (\(motionManager.accumulatedRotationDegreesText))"
            }
            return
        }

        guard let selectedTarget = targetSelector.selectedTarget else {
            consecutiveMissingFindAndGoFrames += 1
            if let bearingDirection = bearingGuidanceDirection {
                findAndGoState = .bearingGuidance
                findAndGoStatusText = bearingDirection == .front
                    ? "Bearing aligned, reacquire \(requestedTargetLabel)"
                    : "Turn \(bearingDirection.displayText.lowercased()) to \(requestedTargetLabel)"
            } else if hasLockedFindAndGoTarget,
               consecutiveMissingFindAndGoFrames <= AppConfig.Decision.findAndGoReacquisitionFrameWindow {
                findAndGoState = .reacquiring
                findAndGoStatusText = "Lost \(requestedTargetLabel), reacquiring"
            } else {
                findAndGoState = .searching
                findAndGoStatusText = hasLockedFindAndGoTarget
                    ? "Searching \(currentSearchDirection.displayText.lowercased()) for \(requestedTargetLabel)"
                    : "360 scan complete; \(requestedTargetLabel) not found"
            }
            return
        }

        hasLockedFindAndGoTarget = true
        consecutiveMissingFindAndGoFrames = 0

        if let distanceMeters = selectedTarget.distanceMeters,
           distanceMeters <= AppConfig.Decision.findAndGoArrivalDistanceMeters {
            findAndGoState = .arrived
        } else if decisionSmoother.smoothedDirection == .none {
            findAndGoState = .acquired
        } else {
            findAndGoState = .approaching
        }

        if let distanceMeters = selectedTarget.distanceMeters {
            findAndGoStatusText = "\(findAndGoState.displayText) \(selectedTarget.label) at \(Int(distanceMeters * 1000)) mm"
        } else {
            findAndGoStatusText = "\(findAndGoState.displayText) \(selectedTarget.label)"
        }
    }

    private var currentSearchDirection: DirectionEstimator.Direction {
        if findAndGoState != .scanning360,
           let bearingGuidanceDirection {
            return bearingGuidanceDirection
        }

        let searchPhase = (consecutiveMissingFindAndGoFrames / AppConfig.Decision.findAndGoSearchDirectionSwapFrames) % 2
        return searchPhase == 0 ? .left : .right
    }

    private func bearingRadians(for target: DetectionOverlayItem) -> Double? {
        guard let currentYawRadians = motionManager.currentYawRadians else {
            return nil
        }

        let horizontalOffsetFromCenter = Double(target.boundingBox.midX - 0.5)
        let halfFieldOfViewRadians = (AppConfig.Camera.approximateHorizontalFieldOfViewDegrees * .pi / 180) / 2
        let visualOffsetRadians = horizontalOffsetFromCenter * 2 * halfFieldOfViewRadians
        return normalizedAngle(currentYawRadians + visualOffsetRadians)
    }

    private func resetFindAndGoState() {
        hasLockedFindAndGoTarget = false
        hasSentFindAndGoScanCompleteMessage = false
        consecutiveMissingFindAndGoFrames = 0
        findAndGoState = requestedTargetLabel.isEmpty ? .waitingForTarget : .scanning360
        rememberedTargetBearingRadians = nil
        bestFindAndGoScanObservation = nil
        awarenessStopHysteresisState = StopHysteresisState()
        findAndGoStopHysteresisState = StopHysteresisState()
        gpsStopHysteresisState = StopHysteresisState()
        bearingStatusText = "No bearing lock"
        scanMemoryStatusText = "No scan target memory"
    }

    private func updateRememberedTargetBearing(
        using selectedTarget: DetectionOverlayItem?,
        frameNumber: Int
    ) {
        guard
            activeMode == .findAndGo,
            let selectedTarget
        else {
            return
        }

        guard let bearingRadians = bearingRadians(for: selectedTarget) else {
            return
        }

        let observation = FindAndGoScanObservation(
            label: selectedTarget.label,
            confidence: selectedTarget.confidence,
            distanceMeters: selectedTarget.distanceMeters,
            bearingRadians: bearingRadians,
            frameNumber: frameNumber,
            observedAt: Date(),
            score: findAndGoScanScore(for: selectedTarget)
        )

        guard shouldReplaceFindAndGoScanObservation(with: observation) else {
            return
        }

        bestFindAndGoScanObservation = observation
        rememberedTargetBearingRadians = observation.bearingRadians
        hasLockedFindAndGoTarget = true
        updateScanMemoryStatus()
    }

    private func shouldReplaceFindAndGoScanObservation(with observation: FindAndGoScanObservation) -> Bool {
        guard let bestFindAndGoScanObservation else {
            return true
        }

        if !motionManager.hasCompletedFullScan {
            return observation.score >= bestFindAndGoScanObservation.score
        }

        return observation.observedAt.timeIntervalSince(bestFindAndGoScanObservation.observedAt) >= 0.75
            || observation.score >= bestFindAndGoScanObservation.score
    }

    private func findAndGoScanScore(for target: DetectionOverlayItem) -> CGFloat {
        let confidenceScore = CGFloat(target.confidence)
        let distanceScore = normalizedDistanceScore(for: target.distanceMeters)
        let horizontalCenterScore = max(0, 1 - abs(target.boundingBox.midX - 0.5) * 2)
        let areaScore = min(1, target.boundingBox.width * target.boundingBox.height / 0.2)

        return confidenceScore * 0.45
            + distanceScore * 0.25
            + horizontalCenterScore * 0.20
            + areaScore * 0.10
    }

    private func normalizedDistanceScore(for distanceMeters: Float?) -> CGFloat {
        guard let distanceMeters else {
            return 0.5
        }

        let clampedDistance = min(max(distanceMeters, 0), AppConfig.ObjectDetection.preferredMaximumTargetDistance)
        return CGFloat(1 - (clampedDistance / AppConfig.ObjectDetection.preferredMaximumTargetDistance))
    }

    private func updateScanMemoryStatus() {
        guard let bestFindAndGoScanObservation else {
            bearingStatusText = "No bearing lock"
            scanMemoryStatusText = "No scan target memory"
            return
        }

        let bearingDegrees = bestFindAndGoScanObservation.bearingRadians * 180 / .pi
        let distanceText = bestFindAndGoScanObservation.distanceMeters
            .map { " at \(Int($0 * 1000)) mm" } ?? ""

        bearingStatusText = String(
            format: "Locked %@ %.0f%%%@ bearing %.0f°",
            bestFindAndGoScanObservation.label,
            bestFindAndGoScanObservation.confidence * 100,
            distanceText,
            bearingDegrees
        )
        scanMemoryStatusText = String(
            format: "Best %@ %.0f%%%@ on frame %d",
            bestFindAndGoScanObservation.label,
            bestFindAndGoScanObservation.confidence * 100,
            distanceText,
            bestFindAndGoScanObservation.frameNumber
        )
    }

    private var bearingGuidanceDirection: DirectionEstimator.Direction? {
        guard
            activeMode == .findAndGo,
            hasLockedFindAndGoTarget,
            let rememberedTargetBearingRadians,
            let currentYawRadians = motionManager.currentYawRadians
        else {
            return nil
        }

        let deltaRadians = normalizedAngle(rememberedTargetBearingRadians - currentYawRadians)
        let deltaDegrees = deltaRadians * 180 / .pi

        return DirectionEstimator.direction(forBearingDeltaDegrees: deltaDegrees)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var normalizedAngle = angle

        while normalizedAngle <= -.pi {
            normalizedAngle += 2 * .pi
        }

        while normalizedAngle > .pi {
            normalizedAngle -= 2 * .pi
        }

        return normalizedAngle
    }

    private func resetStopHysteresisIfNeeded() {
        switch activeMode {
        case .awareness:
            awarenessStopHysteresisState = StopHysteresisState()
        case .findAndGo:
            findAndGoStopHysteresisState = StopHysteresisState()
        case .gpsNavigation:
            gpsStopHysteresisState = StopHysteresisState()
        }
    }

    private func stabilizedAwarenessUrgency(for distanceMeters: Float?) -> NavigationUrgency {
        stabilizedUrgency(
            for: distanceMeters,
            stopDistanceMeters: AppConfig.Decision.stopDistanceMeters,
            state: &awarenessStopHysteresisState
        )
    }

    private func stabilizedFindAndGoUrgency(for distanceMeters: Float?) -> NavigationUrgency {
        stabilizedUrgency(
            for: distanceMeters,
            stopDistanceMeters: AppConfig.Decision.findAndGoArrivalDistanceMeters,
            state: &findAndGoStopHysteresisState
        )
    }

    private func findAndGoUrgency(
        for direction: DirectionEstimator.Direction,
        distanceMeters: Float?
    ) -> NavigationUrgency {
        let urgency = stabilizedFindAndGoUrgency(for: distanceMeters)

        guard direction.vestDirectionValue == "front",
              let distanceMeters else {
            return urgency
        }

        return distanceMeters > AppConfig.Decision.findAndGoArrivalDistanceMeters
            ? urgency
            : .stop
    }

    private func stabilizedGPSUrgency(for distanceMeters: Float?) -> NavigationUrgency {
        stabilizedUrgency(
            for: distanceMeters,
            stopDistanceMeters: AppConfig.Decision.stopDistanceMeters,
            state: &gpsStopHysteresisState
        )
    }

    private func stabilizedUrgency(
        for distanceMeters: Float?,
        stopDistanceMeters: Float,
        state: inout StopHysteresisState
    ) -> NavigationUrgency {
        let rawUrgency = urgency(
            for: distanceMeters,
            stopDistanceMeters: stopDistanceMeters
        )

        guard let distanceMeters else {
            state.closeFrameCount = 0
            updateStopClearState(distanceMeters: nil, stopDistanceMeters: stopDistanceMeters, state: &state)
            return state.isStopped ? .stop : rawUrgency
        }

        if distanceMeters <= stopDistanceMeters {
            state.closeFrameCount += 1
            state.clearFrameCount = 0

            if state.closeFrameCount >= AppConfig.Decision.stopRequiredConsecutiveFrames {
                state.isStopped = true
            }
        } else {
            state.closeFrameCount = 0
            updateStopClearState(
                distanceMeters: distanceMeters,
                stopDistanceMeters: stopDistanceMeters,
                state: &state
            )
        }

        if state.isStopped {
            return .stop
        }

        // Before Stop is latched, close readings should still feel urgent without speaking prematurely.
        if distanceMeters <= stopDistanceMeters {
            return .high
        }

        return rawUrgency
    }

    private func updateStopClearState(
        distanceMeters: Float?,
        stopDistanceMeters: Float,
        state: inout StopHysteresisState
    ) {
        guard state.isStopped else {
            state.clearFrameCount = 0
            return
        }

        let clearDistance = stopDistanceMeters + AppConfig.Decision.stopClearDistanceBufferMeters

        if let distanceMeters, distanceMeters < clearDistance {
            state.clearFrameCount = 0
            return
        }

        state.clearFrameCount += 1

        if state.clearFrameCount >= AppConfig.Decision.stopClearRequiredConsecutiveFrames {
            state.isStopped = false
            state.clearFrameCount = 0
        }
    }

    private func urgency(
        for distanceMeters: Float?,
        stopDistanceMeters: Float
    ) -> NavigationUrgency {
        guard let distanceMeters else {
            return .medium
        }

        if distanceMeters <= stopDistanceMeters {
            return .stop
        }

        if distanceMeters <= AppConfig.Decision.highUrgencyDistanceMeters {
            return .high
        }

        if distanceMeters <= AppConfig.Decision.mediumUrgencyDistanceMeters {
            return .medium
        }

        return .low
    }
}
