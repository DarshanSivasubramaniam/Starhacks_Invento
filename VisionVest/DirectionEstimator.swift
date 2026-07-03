import Combine
import CoreGraphics
import Foundation

final class DirectionEstimator: ObservableObject {
    enum Direction: String {
        case left
        case frontLeft = "front_left"
        case front
        case frontRight = "front_right"
        case right
        case backRight = "back_right"
        case back
        case backLeft = "back_left"
        case none

        var displayText: String {
            rawValue
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    @Published private(set) var currentDirection: Direction = .none
    @Published private(set) var directionStatusText = "No direction available"

    func updateDirection(for target: DetectionOverlayItem?) {
        guard let target else {
            currentDirection = .none
            directionStatusText = "No direction available"
            return
        }

        let horizontalMidpoint = target.boundingBox.midX

        let candidateDirection = direction(forHorizontalMidpoint: horizontalMidpoint)
        if shouldKeepCurrentDirection(forHorizontalMidpoint: horizontalMidpoint) {
            directionStatusText = "Direction \(currentDirection.displayText)"
            return
        }

        currentDirection = candidateDirection

        directionStatusText = "Direction \(currentDirection.displayText)"
    }

    private func direction(forHorizontalMidpoint horizontalMidpoint: CGFloat) -> Direction {
        if horizontalMidpoint < 0.2 {
            return .left
        } else if horizontalMidpoint < 0.4 {
            return .frontLeft
        } else if horizontalMidpoint <= 0.6 {
            return .front
        } else if horizontalMidpoint <= 0.8 {
            return .frontRight
        } else {
            return .right
        }
    }

    private func shouldKeepCurrentDirection(forHorizontalMidpoint horizontalMidpoint: CGFloat) -> Bool {
        guard currentDirection != .none else {
            return false
        }

        let margin = AppConfig.Decision.directionBoundaryHysteresis

        switch currentDirection {
        case .left:
            return horizontalMidpoint <= 0.2 + margin
        case .frontLeft:
            return horizontalMidpoint >= 0.2 - margin && horizontalMidpoint <= 0.4 + margin
        case .front:
            return horizontalMidpoint >= 0.4 - margin && horizontalMidpoint <= 0.6 + margin
        case .frontRight:
            return horizontalMidpoint >= 0.6 - margin && horizontalMidpoint <= 0.8 + margin
        case .right:
            return horizontalMidpoint >= 0.8 - margin
        case .back, .backLeft, .backRight, .none:
            return false
        }
    }

    static func direction(forBearingDeltaDegrees deltaDegrees: Double) -> Direction {
        switch deltaDegrees {
        case -22.5...22.5:
            return .front
        case 22.5...67.5:
            return .frontLeft
        case 67.5...112.5:
            return .left
        case 112.5...157.5:
            return .backLeft
        case -67.5 ... -22.5:
            return .frontRight
        case -112.5 ... -67.5:
            return .right
        case -157.5 ... -112.5:
            return .backRight
        default:
            return .back
        }
    }
}
