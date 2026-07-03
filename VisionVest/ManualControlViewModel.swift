import Foundation
import Combine
import SwiftUI
import UIKit

struct SendHistoryItem: Identifiable {
    let id = UUID()
    let commandText: String
    let sentTimeText: String
    let statusText: String
}

final class ManualControlViewModel: ObservableObject {
    @Published var lastCommandText = "No command sent yet"
    @Published var lastJSONText = "No JSON generated yet"
    @Published var sendStatusText = "Ready"
    @Published var lastSentTimeText = "Not sent yet"
    @Published var sendCountText = "0"
    @Published var sendHistory: [SendHistoryItem] = []
    @Published var lastDirectionText = "None"
    @Published var lastIntensityText = "-"
    @Published var lastPatternText = "-"
    @Published var lastPriorityText = "-"
    @Published var lastTTLText = "-"
    @Published var lastConfidenceText = "-"
    @Published var connectionModeText = "Mock / Local Only"
    @Published var copyStatusText = "Nothing copied yet"
    @Published var useMockMode = true
    @Published var piBaseURL = "http://192.168.4.1:5000"
    @Published var lastCommandColor: Color = .gray

    private let networkManager: NetworkManaging
    private let timeFormatter: DateFormatter
    private var sendCount = 0
    private let maxHistoryCount = 8

    init(networkManager: NetworkManaging = MockNetworkManager()) {
        self.networkManager = networkManager
        self.connectionModeText = networkManager.connectionModeText

        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        self.timeFormatter = formatter
    }

    func sendCommand(_ command: VestCommand) {
        let message = makeMessage(for: command)
        let result = makeSendResult(for: message)
        let sentTime = timeFormatter.string(from: Date())

        sendCount += 1

        lastCommandText = command.rawValue
        lastJSONText = result.jsonString
        sendStatusText = result.statusText
        lastSentTimeText = sentTime
        sendCountText = "\(sendCount)"
        connectionModeText = result.connectionModeText
        lastCommandColor = command.displayColor

        lastDirectionText = message.direction
        lastIntensityText = "\(message.intensity)"
        lastPatternText = message.pattern
        lastPriorityText = "\(message.priority)"
        lastTTLText = "\(message.ttlMs)"
        lastConfidenceText = String(format: "%.2f", message.confidence)

        let historyItem = SendHistoryItem(
            commandText: command.rawValue,
            sentTimeText: sentTime,
            statusText: result.statusText
        )

        sendHistory.insert(historyItem, at: 0)

        if sendHistory.count > maxHistoryCount {
            sendHistory = Array(sendHistory.prefix(maxHistoryCount))
        }

        print("Command pressed: \(command.rawValue)")
    }

    func copyLastJSON() {
        UIPasteboard.general.string = lastJSONText
        copyStatusText = "Last JSON copied"
    }

    func clearDisplayState() {
        lastCommandText = "No command sent yet"
        lastJSONText = "No JSON generated yet"
        sendStatusText = "Ready"
        lastSentTimeText = "Not sent yet"
        lastDirectionText = "None"
        lastIntensityText = "-"
        lastPatternText = "-"
        lastPriorityText = "-"
        lastTTLText = "-"
        lastConfidenceText = "-"
        lastCommandColor = .gray
        copyStatusText = "Nothing copied yet"
        sendCount = 0
        sendCountText = "0"
        sendHistory = []
        connectionModeText = networkManager.connectionModeText
    }

    func resetSendCounter() {
        sendCount = 0
        sendCountText = "0"
    }

    func updateConnectionModeText() {
        connectionModeText = useMockMode
            ? networkManager.connectionModeText
            : "HTTP mode selected (Pi send paused)"
    }

    private func makeSendResult(for message: VestMessage) -> SendResult {
        if useMockMode {
            return networkManager.send(message: message)
        }

        return SendResult(
            statusText: "HTTP send paused for camera-preview phase",
            jsonString: makePrettyJSONString(from: message),
            connectionModeText: "HTTP mode selected (Pi send paused)"
        )
    }
}
