import Combine
import Foundation

final class DecisionSmoother: ObservableObject {
    @Published private(set) var smoothedDirection: DirectionEstimator.Direction = .none
    @Published private(set) var smoothingStatusText = "No stable direction"

    private var recentDirections: [DirectionEstimator.Direction] = []

    func update(
        selectedTarget: DetectionOverlayItem?,
        estimatedDirection: DirectionEstimator.Direction
    ) {
        guard let selectedTarget,
              selectedTarget.confidence >= AppConfig.Decision.minimumConfidenceThreshold,
              estimatedDirection != .none else {
            recentDirections.removeAll()
            smoothedDirection = .none
            smoothingStatusText = "Confidence below threshold"
            return
        }

        recentDirections.append(estimatedDirection)

        if recentDirections.count > AppConfig.Decision.historyLength {
            recentDirections.removeFirst()
        }

        let counts = Dictionary(grouping: recentDirections, by: { $0 }).mapValues(\.count)

        guard let bestDirection = counts.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue > rhs.key.rawValue
            }

            return lhs.value < rhs.value
        }) else {
            smoothedDirection = .none
            smoothingStatusText = "No stable direction"
            return
        }

        let nextDirection = stabilizedDirection(from: bestDirection.key, counts: counts)

        if counts[nextDirection, default: 0] >= AppConfig.Decision.minimumStableFrameCount {
            smoothedDirection = nextDirection
            smoothingStatusText = "Stable \(nextDirection.displayText)"
        } else {
            smoothingStatusText = "Waiting for stable direction"
        }
    }

    private func stabilizedDirection(
        from bestDirection: DirectionEstimator.Direction,
        counts: [DirectionEstimator.Direction: Int]
    ) -> DirectionEstimator.Direction {
        guard smoothedDirection != .none,
              smoothedDirection != bestDirection else {
            return bestDirection
        }

        let currentCount = counts[smoothedDirection, default: 0]
        let bestCount = counts[bestDirection, default: 0]
        let requiredSwitchCount = currentCount + AppConfig.Decision.directionSwitchVoteMargin

        return bestCount >= requiredSwitchCount ? bestDirection : smoothedDirection
    }
}
