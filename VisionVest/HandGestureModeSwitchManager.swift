import Foundation
import Combine
import UIKit
import Vision

final class HandGestureModeSwitchManager: ObservableObject {
    @Published private(set) var statusText = "Hand gesture mode switch idle"
    @Published private(set) var lastGestureText = "No hand gesture"

    var onModeDetected: ((AppCoordinator.Mode) -> Void)?
    var onFindAndGoTargetCaptureGesture: (() -> Void)?

    private let visionQueue = DispatchQueue(label: "visionvest.handGesture.vision", qos: .userInitiated)
    private var isProcessingFrame = false
    private var lastProcessedFrameNumber = 0
    private var lastAcceptedGesture: AppCoordinator.Mode?
    private var stableModeCandidate: AppCoordinator.Mode?
    private var stableFingerCountCandidate = 0
    private var stableFrameCount = 0
    private var lastSwitchDate = Date.distantPast
    private var lastTargetCaptureGestureDate = Date.distantPast
    private var isTargetCaptureGestureArmed = true
    private let targetCaptureHapticGenerator = UIImpactFeedbackGenerator(style: .heavy)

    private let minimumPointConfidence: VNConfidence = 0.35
    private let extendedFingerXOffset: CGFloat = 0.055
    private let maximumFingerVerticalDrift: CGFloat = 0.20
    private let maximumLeftHandCenterX: CGFloat = 0.45
    private let requiredStableFrameCount = 3
    private let frameStride = 2
    private let switchCooldownSeconds: TimeInterval = 2.0
    private let targetCaptureCooldownSeconds: TimeInterval = 1.2

    init() {
        targetCaptureHapticGenerator.prepare()
    }

    func processFrame(_ snapshot: FrameProcessingSnapshot) {
        guard snapshot.frameNumber == 1 || snapshot.frameNumber.isMultiple(of: frameStride) else {
            return
        }

        guard !isProcessingFrame else {
            return
        }

        isProcessingFrame = true
        lastProcessedFrameNumber = snapshot.frameNumber

        visionQueue.async { [weak self] in
            guard let self else { return }

            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1

            let handler = VNImageRequestHandler(
                cvPixelBuffer: snapshot.pixelBuffer,
                orientation: snapshot.orientation,
                options: [:]
            )

            do {
                try handler.perform([request])
                let fingerCount = self.pointingRightFingerCount(from: request.results?.first)

                DispatchQueue.main.async {
                    self.isProcessingFrame = false
                    self.handleDetectedFingerCount(fingerCount, frameNumber: snapshot.frameNumber)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessingFrame = false
                    self.statusText = "Hand gesture unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pointingRightFingerCount(from observation: VNHumanHandPoseObservation?) -> Int? {
        guard let observation else {
            return nil
        }

        guard let points = try? observation.recognizedPoints(.all) else {
            return nil
        }

        let visiblePoints = points.values.filter { $0.confidence >= minimumPointConfidence }
        guard !visiblePoints.isEmpty else {
            return nil
        }

        let handCenterX = visiblePoints.map(\.location.x).reduce(0, +) / CGFloat(visiblePoints.count)
        guard handCenterX <= maximumLeftHandCenterX else {
            return nil
        }

        let pointingRightFingerCount = [
            isFingerPointingRight(tip: .indexTip, lowerJoint: .indexPIP, points: points),
            isFingerPointingRight(tip: .middleTip, lowerJoint: .middlePIP, points: points),
            isFingerPointingRight(tip: .ringTip, lowerJoint: .ringPIP, points: points),
            isFingerPointingRight(tip: .littleTip, lowerJoint: .littlePIP, points: points)
        ].filter { $0 }.count

        return (1...4).contains(pointingRightFingerCount) ? pointingRightFingerCount : nil
    }

    private func isFingerPointingRight(
        tip: VNHumanHandPoseObservation.JointName,
        lowerJoint: VNHumanHandPoseObservation.JointName,
        points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
    ) -> Bool {
        guard let tipPoint = points[tip],
              let lowerPoint = points[lowerJoint],
              tipPoint.confidence >= minimumPointConfidence,
              lowerPoint.confidence >= minimumPointConfidence else {
            return false
        }

        let horizontalExtension = tipPoint.location.x - lowerPoint.location.x
        let verticalDrift = abs(tipPoint.location.y - lowerPoint.location.y)

        return horizontalExtension > extendedFingerXOffset
            && verticalDrift <= maximumFingerVerticalDrift
    }

    private func handleDetectedFingerCount(_ fingerCount: Int?, frameNumber: Int) {
        guard let fingerCount else {
            stableModeCandidate = nil
            stableFingerCountCandidate = 0
            stableFrameCount = 0
            isTargetCaptureGestureArmed = true
            lastGestureText = "No valid left-side hand gesture"
            statusText = "Waiting for left hand pointing right"
            return
        }

        if fingerCount != 4 {
            isTargetCaptureGestureArmed = true
        }

        if stableFingerCountCandidate == fingerCount {
            stableFrameCount += 1
        } else {
            stableFingerCountCandidate = fingerCount
            stableModeCandidate = mode(for: fingerCount)
            stableFrameCount = 1
        }

        let gestureName = mode(for: fingerCount)?.displayName ?? "Find & Go target capture"
        lastGestureText = "\(fingerCount)-finger gesture, frame \(frameNumber)"
        statusText = "Gesture \(stableFrameCount)/\(requiredStableFrameCount): \(gestureName)"

        guard stableFrameCount >= requiredStableFrameCount else {
            return
        }

        if fingerCount == 4 {
            handleTargetCaptureGesture()
            return
        }

        guard let mode = mode(for: fingerCount) else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastSwitchDate) >= switchCooldownSeconds else {
            return
        }

        guard lastAcceptedGesture != mode else {
            return
        }

        lastAcceptedGesture = mode
        lastSwitchDate = now
        statusText = "Switched mode by hand gesture: \(mode.displayName)"
        onModeDetected?(mode)
    }

    private func mode(for fingerCount: Int) -> AppCoordinator.Mode? {
        switch fingerCount {
        case 1:
            return .awareness
        case 2:
            return .findAndGo
        case 3:
            return .gpsNavigation
        default:
            return nil
        }
    }

    private func handleTargetCaptureGesture() {
        guard isTargetCaptureGestureArmed else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastTargetCaptureGestureDate) >= targetCaptureCooldownSeconds else {
            return
        }

        isTargetCaptureGestureArmed = false
        lastTargetCaptureGestureDate = now
        statusText = "Find & Go target capture gesture"
        playTargetCaptureHaptic()
        onFindAndGoTargetCaptureGesture?()
    }

    private func playTargetCaptureHaptic() {
        targetCaptureHapticGenerator.prepare()
        targetCaptureHapticGenerator.impactOccurred(intensity: 1.0)
    }
}
