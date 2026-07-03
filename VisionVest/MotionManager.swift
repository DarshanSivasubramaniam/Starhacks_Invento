import Combine
import CoreMotion
import Foundation

final class MotionManager: ObservableObject {
    @Published private(set) var statusText = "Motion idle"
    @Published private(set) var currentYawRadians: Double?
    @Published private(set) var currentYawDegreesText = "No yaw"
    @Published private(set) var isTracking = false
    @Published private(set) var accumulatedRotationRadians: Double = 0
    @Published private(set) var accumulatedRotationDegreesText = "0°"
    @Published private(set) var hasCompletedFullScan = false

    private let motionManager = CMMotionManager()
    private let updateQueue = OperationQueue()
    private var previousYawRadians: Double?
    private var signedRotationRadians: Double = 0

    init() {
        updateQueue.name = "visionvest.motion.updates"
        updateQueue.qualityOfService = .userInteractive
    }

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            statusText = "Device motion unavailable"
            currentYawRadians = nil
            currentYawDegreesText = "No yaw"
            isTracking = false
            return
        }

        guard !motionManager.isDeviceMotionActive else {
            isTracking = true
            statusText = "Tracking yaw"
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: updateQueue
        ) { [weak self] motion, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    self.statusText = "Motion error: \(error.localizedDescription)"
                    self.currentYawRadians = nil
                    self.currentYawDegreesText = "No yaw"
                    self.isTracking = false
                    return
                }

                guard let motion else {
                    self.statusText = "Waiting for motion"
                    self.isTracking = false
                    return
                }

                let yawRadians = Self.normalizedAngle(motion.attitude.yaw)
                if let previousYawRadians = self.previousYawRadians {
                    if !self.hasCompletedFullScan {
                        let yawDelta = Self.normalizedAngle(yawRadians - previousYawRadians)
                        if abs(yawDelta) >= Self.minimumYawDeltaRadians {
                            self.signedRotationRadians += yawDelta
                        }
                        self.accumulatedRotationRadians = abs(self.signedRotationRadians)
                        self.accumulatedRotationDegreesText = String(
                            format: "%.0f°",
                            self.accumulatedRotationRadians * 180 / .pi
                        )
                        if self.accumulatedRotationRadians * 180 / .pi
                            >= AppConfig.Decision.findAndGoRequiredScanDegrees {
                            self.hasCompletedFullScan = true
                        }
                    }
                }

                self.previousYawRadians = yawRadians
                self.currentYawRadians = yawRadians
                self.currentYawDegreesText = String(format: "%.0f°", yawRadians * 180 / .pi)
                self.statusText = "Tracking yaw"
                self.isTracking = true
            }
        }
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
        statusText = "Motion idle"
        isTracking = false
        previousYawRadians = nil
    }

    func resetScanProgress() {
        signedRotationRadians = 0
        accumulatedRotationRadians = 0
        accumulatedRotationDegreesText = "0°"
        hasCompletedFullScan = false
        previousYawRadians = currentYawRadians
    }

    private static let minimumYawDeltaRadians = 0.5 * .pi / 180

    private static func normalizedAngle(_ angle: Double) -> Double {
        var normalizedAngle = angle

        while normalizedAngle <= -.pi {
            normalizedAngle += 2 * .pi
        }

        while normalizedAngle > .pi {
            normalizedAngle -= 2 * .pi
        }

        return normalizedAngle
    }
}
