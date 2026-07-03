import Combine
import Foundation

final class AppCoordinator: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case awareness
        case findAndGo
        case gpsNavigation

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .awareness:
                return "Awareness"
            case .findAndGo:
                return "Find & Go"
            case .gpsNavigation:
                return "GPS"
            }
        }

        var summaryText: String {
            switch self {
            case .awareness:
                return "Passive nearby-object awareness with direction, urgency, and stop feedback."
            case .findAndGo:
                return "Find a specified object, lock onto it, and guide the user toward it."
            case .gpsNavigation:
                return "Outdoor route guidance with local perception and safety layered on top."
            }
        }
    }

    @Published private(set) var currentMode: Mode = .awareness
    @Published var requestedFindAndGoTarget = ""

    var normalizedRequestedFindAndGoTarget: String {
        Self.normalizeTargetLabel(requestedFindAndGoTarget)
    }

    var debugSummary: String {
        [
            "Milestone 1 mode architecture active.",
            "currentMode=\(currentMode.rawValue)",
            "findAndGo.target=\(normalizedRequestedFindAndGoTarget.isEmpty ? "none" : normalizedRequestedFindAndGoTarget)",
            "modeSummary=\(currentMode.summaryText)",
            "Camera, perception, and live command pipeline available locally.",
            "BLE and firmware integration pending."
        ].joined(separator: "\n")
    }

    func setMode(_ mode: Mode) {
        currentMode = mode
    }

    func setRequestedFindAndGoTarget(_ label: String) {
        requestedFindAndGoTarget = label
    }

    static func normalizeTargetLabel(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
