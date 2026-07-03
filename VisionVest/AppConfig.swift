import SwiftUI

enum AppConfig {
    enum BLE {
        static let vestServiceUUID = "7B7E1000-7C6B-4B8F-9E2A-6B5F4F0A1000"
        static let commandCharacteristicUUID = "7B7E1001-7C6B-4B8F-9E2A-6B5F4F0A1000"
        static let minimumSendIntervalSeconds = 0.12
        static let sendTimerIntervalSeconds = 0.10
    }

    enum Voice {
        static let modeSelectionTimeoutSeconds = 6.0
        static let modeSwitchCooldownSeconds = 4.0
    }

    enum GPS {
        static let lawsonLatitude = 40.42742778138011
        static let lawsonLongitude = -86.91684335496801
        static let arrivalDistanceMeters = 15.0
        static let commandIntensity = 150
        static let commandPriority = 1
    }

    enum Layout {
        static let screenPadding: CGFloat = 20
        static let sectionSpacing: CGFloat = 16
        static let cardPadding: CGFloat = 16
        static let cardCornerRadius: CGFloat = 18
        static let cameraPlaceholderHeight: CGFloat = 260
        static let dashboardCameraHeight: CGFloat = 400
        static let debugPanelHeight: CGFloat = 180
        static let cameraControlSpacing: CGFloat = 10
    }

    enum Camera {
        static let sampleEveryNFrames = 3
        static let preferredLiDARWidth = 1280
        static let approximateHorizontalFieldOfViewDegrees: Double = 60
    }

    enum Decision {
        static let minimumConfidenceThreshold: Float = 0.35
        static let historyLength = 5
        static let minimumStableFrameCount = 2
        static let stopDistanceMeters: Float = 1.0
        static let stopRequiredConsecutiveFrames = 2
        static let stopClearDistanceBufferMeters: Float = 0.20
        static let stopClearRequiredConsecutiveFrames = 2
        static let findAndGoArrivalDistanceMeters: Float = 1.0
        static let findAndGoLockedBearingToleranceDegrees: Double = 25
        static let highUrgencyDistanceMeters: Float = 1.5
        static let mediumUrgencyDistanceMeters: Float = 2.5
        static let commandTTLMilliseconds = 300
        static let findAndGoReacquisitionFrameWindow = 12
        static let findAndGoSearchDirectionSwapFrames = 20
        static let findAndGoBearingAlignmentThresholdDegrees: Double = 12
        static let findAndGoRequiredScanDegrees: Double = 360
        static let directionBoundaryHysteresis: CGFloat = 0.04
        static let directionSwitchVoteMargin = 1
    }

    enum ObjectDetection {
        // Ordered by runtime preference. Use the smaller model first for lower navigation latency.
        static let candidateModelNames = [
            "YOLO11SmallDetector",
            "yolo11l",
            "best",
            "YOLOv8n",
            "YOLOv8s",
            "YOLOv5s",
            "ObjectDetector"
        ]
        static let minimumObservationConfidence: Float = 0.20
        static let iouThreshold: Float = 0.45
        static let maxDetections = 30
        static let minimumSelectionArea: CGFloat = 0.015
        static let minimumSelectionDimension: CGFloat = 0.08
        static let awarenessPeripheralMinimumArea: CGFloat = 0.04
        static let awarenessPeripheralCenterThreshold: CGFloat = 0.35
        static let awarenessSwitchScoreMargin: CGFloat = 0.35
        static let awarenessCurrentTargetMatchMaxCenterDelta: CGFloat = 0.18
        static let awarenessCurrentTargetMatchMinimumIoU: CGFloat = 0.20
        static let humanPriorityLabels: Set<String> = [
            "person"
        ]
        static let ignoredLabels: Set<String> = [
            "dining table"
        ]
        static let depthSampleInsetFactor: CGFloat = 0.2
        static let minimumValidDepthSampleRatio: Float = 0.05
        static let maximumReliableDepthDistance: Float = 5.0
        static let preferredMaximumTargetDistance: Float = 3.0
        static let supportedFindAndGoLabels: [String] = [
            "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
            "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
            "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
            "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
            "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
            "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
            "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
            "couch", "sofa", "potted plant", "bed", "toilet", "tv", "laptop", "mouse", "remote",
            "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book",
            "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
        ]
        static let voiceTargetAliases: [String: String] = [
            "people": "person",
            "man": "person",
            "woman": "person",
            "boy": "person",
            "girl": "person",
            "bike": "bicycle",
            "bikes": "bicycle",
            "motorbike": "motorcycle",
            "motorbikes": "motorcycle",
            "plane": "airplane",
            "planes": "airplane",
            "hydrant": "fire hydrant",
            "stoplight": "traffic light",
            "stoplights": "traffic light",
            "light": "traffic light",
            "lights": "traffic light",
            "bag": "handbag",
            "bags": "handbag",
            "purse": "handbag",
            "purses": "handbag",
            "phone": "cell phone",
            "phones": "cell phone",
            "cellphone": "cell phone",
            "tvs": "tv",
            "television": "tv",
            "televisions": "tv",
            "monitor": "tv",
            "monitors": "tv",
            "plant": "potted plant",
            "plants": "potted plant",
            "couches": "couch",
            "sofas": "sofa",
            "fridge": "refrigerator",
            "fridges": "refrigerator",
            "refrigerators": "refrigerator",
            "chairs": "chair",
            "bottles": "bottle",
            "cups": "cup",
            "books": "book",
            "dogs": "dog",
            "cats": "cat"
        ]

        static func resolvedTargetLabel(from transcript: String) -> String? {
            let normalizedTranscript = normalizedSpeechText(transcript)
            guard !normalizedTranscript.isEmpty else {
                return nil
            }

            let searchableTranscript = " \(normalizedTranscript) "
            let candidates = (supportedFindAndGoLabels + Array(voiceTargetAliases.keys))
                .sorted { $0.count > $1.count }

            for candidate in candidates {
                let normalizedCandidate = normalizedSpeechText(candidate)
                guard !normalizedCandidate.isEmpty else {
                    continue
                }

                if searchableTranscript.contains(" \(normalizedCandidate) ") {
                    return voiceTargetAliases[normalizedCandidate] ?? normalizedCandidate
                }
            }

            let fillerWords: Set<String> = [
                "take", "me", "to", "the", "nearest", "closest", "find", "a", "an", "please",
                "want", "i", "need", "show", "go", "toward", "towards", "there", "here", "look",
                "for", "at", "my", "that", "this", "is", "it", "can", "you", "bring", "guide"
            ]

            let remainingWords = normalizedTranscript
                .split(separator: " ")
                .map(String.init)
                .filter { !fillerWords.contains($0) }

            for word in remainingWords.reversed() {
                if let aliasMatch = voiceTargetAliases[word] {
                    return aliasMatch
                }

                if supportedFindAndGoLabels.contains(word) {
                    return word
                }

                if word.hasSuffix("s") {
                    let singularWord = String(word.dropLast())
                    if let aliasMatch = voiceTargetAliases[singularWord] {
                        return aliasMatch
                    }

                    if supportedFindAndGoLabels.contains(singularWord) {
                        return singularWord
                    }
                }
            }

            return nil
        }

        private static func normalizedSpeechText(_ text: String) -> String {
            let lowercasedText = text.lowercased()
            let scalarView = lowercasedText.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(scalar) : " "
            }

            return String(scalarView)
                .split(separator: " ")
                .joined(separator: " ")
        }
    }

    enum Colors {
        static let screenBackground = Color(.systemGroupedBackground)
        static let cardBackground = Color(.secondarySystemGroupedBackground)
        static let modeBadgeBackground = Color.blue.opacity(0.14)
        static let cameraPlaceholderBackground = Color.black.opacity(0.92)
        static let cameraPlaceholderTint = Color.green.opacity(0.85)
        static let debugPanelBackground = Color(.systemGray6)
        static let primaryButtonBackground = Color.blue
        static let secondaryButtonBackground = Color(.systemGray4)
    }

    enum Copy {
        static let appTitle = "VisionVest"
        static let homeTitle = "iPhone Compute Shell"
        static let homeSubtitle = "Live camera detection powered by an Ultralytics YOLO pipeline."
        static let cameraPlaceholderTitle = "Live Camera Preview"
        static let cameraPlaceholderBody = "Start the camera to run the bundled Ultralytics YOLO model on live frames."
        static let modelCardTitle = "Object Detection Model"
        static let modelRetryButtonTitle = "Retry Model Load"
        static let inferenceCardTitle = "Live Inference"
        static let smoothingCardTitle = "Decision Smoothing"
    }
}
