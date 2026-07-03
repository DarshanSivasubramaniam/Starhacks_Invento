import Combine
import CoreGraphics
import Foundation

final class TargetSelector: ObservableObject {
    @Published private(set) var selectedTarget: DetectionOverlayItem?
    @Published private(set) var selectionStatusText = "No target selected"

    func updateSelection(from detections: [DetectionOverlayItem], mode: AppCoordinator.Mode = .awareness) {
        let bestDetection: DetectionOverlayItem?

        switch mode {
        case .awareness:
            let viableDetections = detections.filter(isViableAwarenessSelection)
            let bestCandidate = viableDetections.max(by: compareAwarenessDetections)
            bestDetection = stabilizedAwarenessSelection(bestCandidate: bestCandidate, from: viableDetections)
        case .findAndGo, .gpsNavigation:
            let viableDetections = detections.filter(isViableSelection)
            bestDetection = viableDetections.max(by: compareNavigationDetections)
        }

        guard let bestDetection else {
            selectedTarget = nil
            selectionStatusText = detections.isEmpty
                ? "No target selected"
                : "No stable target selected"
            return
        }

        selectedTarget = bestDetection
        switch mode {
        case .awareness:
            selectionStatusText = "Aware of \(bestDetection.label) \(Int(bestDetection.confidence * 100))%"
        case .findAndGo, .gpsNavigation:
            selectionStatusText = "Selected \(bestDetection.label) \(Int(bestDetection.confidence * 100))%"
        }
    }

    private func compareNavigationDetections(_ lhs: DetectionOverlayItem, _ rhs: DetectionOverlayItem) -> Bool {
        selectionScore(lhs) < selectionScore(rhs)
    }

    private func compareAwarenessDetections(_ lhs: DetectionOverlayItem, _ rhs: DetectionOverlayItem) -> Bool {
        awarenessScore(lhs) < awarenessScore(rhs)
    }

    private func stabilizedAwarenessSelection(
        bestCandidate: DetectionOverlayItem?,
        from viableDetections: [DetectionOverlayItem]
    ) -> DetectionOverlayItem? {
        guard let bestCandidate else {
            return nil
        }

        guard let selectedTarget,
              let currentCandidate = bestCurrentAwarenessMatch(for: selectedTarget, in: viableDetections) else {
            return bestCandidate
        }

        if currentCandidate.id == bestCandidate.id {
            return bestCandidate
        }

        if isHuman(bestCandidate) && !isHuman(currentCandidate) {
            return bestCandidate
        }

        if isHuman(currentCandidate) && !isHuman(bestCandidate) {
            return currentCandidate
        }

        let currentScore = awarenessScore(currentCandidate)
        let bestScore = awarenessScore(bestCandidate)
        let switchMargin = AppConfig.ObjectDetection.awarenessSwitchScoreMargin

        return bestScore >= currentScore + switchMargin ? bestCandidate : currentCandidate
    }

    private func bestCurrentAwarenessMatch(
        for currentTarget: DetectionOverlayItem,
        in viableDetections: [DetectionOverlayItem]
    ) -> DetectionOverlayItem? {
        let candidates = viableDetections.filter {
            $0.label.caseInsensitiveCompare(currentTarget.label) == .orderedSame
        }

        return candidates
            .filter { isLikelySameAwarenessTarget($0, as: currentTarget) }
            .max {
                awarenessTargetMatchScore($0, against: currentTarget) < awarenessTargetMatchScore($1, against: currentTarget)
            }
    }

    private func isLikelySameAwarenessTarget(_ detection: DetectionOverlayItem, as currentTarget: DetectionOverlayItem) -> Bool {
        let centerDelta = normalizedCenterDelta(between: detection.boundingBox, and: currentTarget.boundingBox)
        let overlap = intersectionOverUnion(detection.boundingBox, currentTarget.boundingBox)

        return centerDelta <= AppConfig.ObjectDetection.awarenessCurrentTargetMatchMaxCenterDelta
            || overlap >= AppConfig.ObjectDetection.awarenessCurrentTargetMatchMinimumIoU
    }

    private func awarenessTargetMatchScore(_ detection: DetectionOverlayItem, against currentTarget: DetectionOverlayItem) -> CGFloat {
        let maxCenterDelta = AppConfig.ObjectDetection.awarenessCurrentTargetMatchMaxCenterDelta
        let centerDelta = normalizedCenterDelta(between: detection.boundingBox, and: currentTarget.boundingBox)
        let centerScore = max(0, 1 - centerDelta / maxCenterDelta)
        let overlapScore = intersectionOverUnion(detection.boundingBox, currentTarget.boundingBox)

        return centerScore * 0.45 + overlapScore * 0.55
    }

    private func boundingBoxArea(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private func normalizedCenterDelta(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let deltaX = lhs.midX - rhs.midX
        let deltaY = lhs.midY - rhs.midY

        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull && !intersection.isEmpty else {
            return 0
        }

        let intersectionArea = boundingBoxArea(intersection)
        let unionArea = boundingBoxArea(lhs) + boundingBoxArea(rhs) - intersectionArea

        guard unionArea > 0 else {
            return 0
        }

        return intersectionArea / unionArea
    }

    private func isViableSelection(_ detection: DetectionOverlayItem) -> Bool {
        let box = detection.boundingBox

        return box.width >= AppConfig.ObjectDetection.minimumSelectionDimension
            && box.height >= AppConfig.ObjectDetection.minimumSelectionDimension
            && boundingBoxArea(box) >= AppConfig.ObjectDetection.minimumSelectionArea
    }

    private func isViableAwarenessSelection(_ detection: DetectionOverlayItem) -> Bool {
        guard isViableSelection(detection) else {
            return false
        }

        if isHuman(detection) {
            return true
        }

        let area = boundingBoxArea(detection.boundingBox)
        let forwardPathScore = horizontalForwardPathScore(for: detection.boundingBox)
        let isPeripheralSmallObject = forwardPathScore < AppConfig.ObjectDetection.awarenessPeripheralCenterThreshold
            && area < AppConfig.ObjectDetection.awarenessPeripheralMinimumArea

        return !isPeripheralSmallObject
    }

    private func selectionScore(_ detection: DetectionOverlayItem) -> CGFloat {
        let areaScore = min(1, boundingBoxArea(detection.boundingBox) / 0.2)
        let centerDistance = abs(detection.boundingBox.midX - 0.5) + abs(detection.boundingBox.midY - 0.5)
        let centerednessScore = max(0, 1 - centerDistance)
        let confidenceScore = CGFloat(detection.confidence)
        let distanceScore = normalizedDistanceScore(for: detection.distanceMeters)

        return confidenceScore * 0.40
            + areaScore * 0.20
            + centerednessScore * 0.10
            + distanceScore * 0.30
    }

    private func awarenessScore(_ detection: DetectionOverlayItem) -> CGFloat {
        let confidenceScore = CGFloat(detection.confidence)
        let distanceScore = normalizedDistanceScore(for: detection.distanceMeters)
        let areaScore = min(1, boundingBoxArea(detection.boundingBox) / 0.2)
        let forwardPathScore = horizontalForwardPathScore(for: detection.boundingBox)
        let humanPriorityScore: CGFloat = isHuman(detection) ? 2.0 : 0

        return humanPriorityScore
            + forwardPathScore * 0.40
            + distanceScore * 0.25
            + areaScore * 0.20
            + confidenceScore * 0.15
    }

    private func horizontalForwardPathScore(for rect: CGRect) -> CGFloat {
        max(0, 1 - abs(rect.midX - 0.5) * 2)
    }

    private func isHuman(_ detection: DetectionOverlayItem) -> Bool {
        AppConfig.ObjectDetection.humanPriorityLabels.contains(detection.label.lowercased())
    }

    private func normalizedDistanceScore(for distanceMeters: Float?) -> CGFloat {
        guard let distanceMeters else {
            return 0.5
        }

        let clampedDistance = min(max(distanceMeters, 0), AppConfig.ObjectDetection.preferredMaximumTargetDistance)
        let normalizedDistance = 1 - (clampedDistance / AppConfig.ObjectDetection.preferredMaximumTargetDistance)
        return CGFloat(normalizedDistance)
    }
}
