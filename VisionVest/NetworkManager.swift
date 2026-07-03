import Foundation

struct SendResult {
    let statusText: String
    let jsonString: String
    let connectionModeText: String
}

protocol NetworkManaging {
    func send(message: VestMessage) -> SendResult
    var connectionModeText: String { get }
}

final class MockNetworkManager: NetworkManaging {
    let connectionModeText = "Mock / Local Only"

    func send(message: VestMessage) -> SendResult {
        let jsonString = makePrettyJSONString(from: message)
        let status = "Mock send complete (local only)"

        print(status)
        print("JSON sent:\n\(jsonString)")

        return SendResult(
            statusText: status,
            jsonString: jsonString,
            connectionModeText: connectionModeText
        )
    }
}
