import AVFoundation
import Combine
import CoreGraphics
import Foundation

final class CameraManager: NSObject, ObservableObject {
    enum AuthorizationState {
        case notDetermined
        case authorized
        case denied
        case restricted
        case unknown

        var description: String {
            switch self {
            case .notDetermined:
                return "Not requested"
            case .authorized:
                return "Granted"
            case .denied:
                return "Denied"
            case .restricted:
                return "Restricted"
            case .unknown:
                return "Unknown"
            }
        }
    }

    @Published private(set) var authorizationState: AuthorizationState = .notDetermined
    @Published private(set) var cameraStatusText = "Camera not started"
    @Published private(set) var frameStatusText = "Frame pipeline idle"
    @Published private(set) var latestFrameText = "No frames received"
    @Published private(set) var sampledFrameCountText = "0"
    @Published private(set) var isSessionRunning = false
    @Published private(set) var previewAspectRatio: CGFloat = 3.0 / 4.0
    @Published private(set) var depthStatusText = "LiDAR depth unavailable"

    let session = AVCaptureSession()
    let frameProcessor: FrameProcessor

    private let sessionQueue = DispatchQueue(label: "visionvest.camera.session")
    private let outputQueue = DispatchQueue(label: "visionvest.camera.output")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var isConfigured = false
    private var frameCount = 0
    private var sampledFrameCount = 0

    init(frameProcessor: FrameProcessor = FrameProcessor()) {
        self.frameProcessor = frameProcessor
        super.init()
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        authorizationState = makeAuthorizationState(from: AVCaptureDevice.authorizationStatus(for: .video))

        switch authorizationState {
        case .authorized:
            cameraStatusText = isSessionRunning ? "Camera running" : "Ready to start"
        case .notDetermined:
            cameraStatusText = "Camera permission not requested"
        case .denied:
            cameraStatusText = "Enable camera access in Settings"
        case .restricted:
            cameraStatusText = "Camera access is restricted"
        case .unknown:
            cameraStatusText = "Camera state unavailable"
        }
    }

    func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
            configureAndStartSessionIfNeeded()

        case .notDetermined:
            cameraStatusText = "Requesting camera permission"

            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorizationState = granted ? .authorized : .denied
                    self.cameraStatusText = granted
                        ? "Permission granted"
                        : "Camera access denied"
                }

                if granted {
                    self.configureAndStartSessionIfNeeded()
                }
            }

        case .denied:
            authorizationState = .denied
            cameraStatusText = "Enable camera access in Settings"

        case .restricted:
            authorizationState = .restricted
            cameraStatusText = "Camera access is restricted"

        @unknown default:
            authorizationState = .unknown
            cameraStatusText = "Unable to determine camera state"
        }
    }

    func stopSession() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()

            DispatchQueue.main.async {
                self.isSessionRunning = false
                self.cameraStatusText = "Camera stopped"
                self.frameStatusText = "Frame pipeline idle"
                self.sampledFrameCountText = "\(self.sampledFrameCount)"
            }
        }
    }

    private func configureAndStartSessionIfNeeded() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
            }

            guard self.isConfigured else {
                DispatchQueue.main.async {
                    self.cameraStatusText = "Failed to configure camera"
                }
                return
            }

            guard !self.session.isRunning else {
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                    self.cameraStatusText = "Camera running"
                }
                return
            }

            self.session.startRunning()

            DispatchQueue.main.async {
                self.isSessionRunning = true
                self.cameraStatusText = "Camera running"
                self.frameStatusText = "Waiting for frames"
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        guard let camera = makeCaptureDevice() else {
            DispatchQueue.main.async {
                self.cameraStatusText = "Back LiDAR camera not available"
            }
            return
        }

        do {
            try configureFormats(for: camera)
            let input = try AVCaptureDeviceInput(device: camera)

            guard session.canAddInput(input) else {
                DispatchQueue.main.async {
                    self.cameraStatusText = "Could not add camera input"
                }
                return
            }

            session.addInput(input)

            let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            let portraitWidth = min(CGFloat(dimensions.width), CGFloat(dimensions.height))
            let portraitHeight = max(CGFloat(dimensions.width), CGFloat(dimensions.height))

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]

            guard session.canAddOutput(videoOutput) else {
                DispatchQueue.main.async {
                    self.cameraStatusText = "Could not add video output"
                }
                return
            }

            session.addOutput(videoOutput)

            depthOutput.isFilteringEnabled = true

            guard session.canAddOutput(depthOutput) else {
                DispatchQueue.main.async {
                    self.depthStatusText = "LiDAR depth output unavailable"
                }
                return
            }

            session.addOutput(depthOutput)

            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            synchronizer.setDelegate(self, queue: outputQueue)
            outputSynchronizer = synchronizer

            if let connection = videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }

            if let depthConnection = depthOutput.connection(with: .depthData),
               depthConnection.isVideoRotationAngleSupported(90) {
                depthConnection.videoRotationAngle = 90
            }

            DispatchQueue.main.async {
                self.previewAspectRatio = portraitWidth / portraitHeight
                self.frameStatusText = "Frame and LiDAR pipeline ready"
                self.latestFrameText = "No frames received"
                self.sampledFrameCountText = "0"
                self.depthStatusText = "LiDAR depth active"
            }

            isConfigured = true
        } catch {
            DispatchQueue.main.async {
                self.cameraStatusText = "Camera setup error: \(error.localizedDescription)"
            }
        }
    }

    private func makeAuthorizationState(from status: AVAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    private func makeCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
    }

    private func configureFormats(for device: AVCaptureDevice) throws {
        guard let videoFormat = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription)

            return dimensions.width == AppConfig.Camera.preferredLiDARWidth
                && mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && !format.supportedDepthDataFormats.isEmpty
        }) ?? device.formats.first(where: { !$0.supportedDepthDataFormats.isEmpty }) else {
            throw CameraConfigurationError.requiredFormatUnavailable
        }

        guard let depthFormat = videoFormat.supportedDepthDataFormats.first(where: { format in
            let mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return mediaSubType == kCVPixelFormatType_DepthFloat16
                || mediaSubType == kCVPixelFormatType_DepthFloat32
        }) else {
            throw CameraConfigurationError.requiredFormatUnavailable
        }

        try device.lockForConfiguration()
        device.activeFormat = videoFormat
        device.activeDepthDataFormat = depthFormat
        device.unlockForConfiguration()
    }
}

extension CameraManager: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard
            let synchronizedVideo = synchronizedDataCollection.synchronizedData(for: videoOutput)
                as? AVCaptureSynchronizedSampleBufferData,
            let synchronizedDepth = synchronizedDataCollection.synchronizedData(for: depthOutput)
                as? AVCaptureSynchronizedDepthData,
            !synchronizedVideo.sampleBufferWasDropped,
            !synchronizedDepth.depthDataWasDropped,
            let imageBuffer = CMSampleBufferGetImageBuffer(synchronizedVideo.sampleBuffer)
        else {
            return
        }

        frameCount += 1

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let dimensionsText = "\(width) x \(height) px"

        if frameCount == 1 || frameCount.isMultiple(of: 15) {
            DispatchQueue.main.async {
                self.frameStatusText = "Receiving live video + LiDAR frames"
                let depthDimensions = CVPixelBufferGetWidth(synchronizedDepth.depthData.depthDataMap)
                let depthHeight = CVPixelBufferGetHeight(synchronizedDepth.depthData.depthDataMap)
                self.latestFrameText = "\(dimensionsText), depth \(depthDimensions) x \(depthHeight)"
            }
        }

        guard shouldProcessCurrentFrame() else {
            return
        }

        sampledFrameCount += 1

        let snapshot = FrameProcessingSnapshot(
            frameNumber: frameCount,
            timestamp: Date(),
            dimensionsText: dimensionsText,
            pixelBuffer: imageBuffer,
            depthData: synchronizedDepth.depthData,
            // The output connection is already rotated into portrait, so Vision should
            // treat the sampled buffer as upright instead of applying another rotation.
            orientation: .up
        )

        frameProcessor.processFrame(snapshot)

        DispatchQueue.main.async {
            self.sampledFrameCountText = "\(self.sampledFrameCount)"
            self.frameStatusText = "Processing sampled LiDAR frames"
        }
    }

    private func shouldProcessCurrentFrame() -> Bool {
        frameCount == 1 || frameCount.isMultiple(of: AppConfig.Camera.sampleEveryNFrames)
    }
}

private enum CameraConfigurationError: LocalizedError {
    case requiredFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .requiredFormatUnavailable:
            return "Required LiDAR video or depth format is unavailable"
        }
    }
}
