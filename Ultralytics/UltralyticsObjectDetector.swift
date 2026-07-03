import CoreML
import CoreVideo
import Foundation
import QuartzCore
import Vision

struct UltralyticsDetection {
    let index: Int
    let label: String
    let confidence: Float
    let normalizedBoundingBox: CGRect
}

struct UltralyticsDetectionResult {
    let detections: [UltralyticsDetection]
    let inferenceTime: TimeInterval
}

enum UltralyticsObjectDetectorError: Error {
    case modelFileNotFound
    case invalidModelMetadata
}

final class UltralyticsObjectDetector {
    private let visionModel: VNCoreMLModel
    private let visionRequest: VNCoreMLRequest
    private let labels: [String]
    private let requiresNMS: Bool
    private let modelInputSize: CGSize
    private let maxDetections: Int
    private let confidenceThreshold: Float
    private let iouThreshold: Float

    private init(
        visionModel: VNCoreMLModel,
        visionRequest: VNCoreMLRequest,
        labels: [String],
        requiresNMS: Bool,
        modelInputSize: CGSize,
        maxDetections: Int,
        confidenceThreshold: Float,
        iouThreshold: Float
    ) {
        self.visionModel = visionModel
        self.visionRequest = visionRequest
        self.labels = labels
        self.requiresNMS = requiresNMS
        self.modelInputSize = modelInputSize
        self.maxDetections = maxDetections
        self.confidenceThreshold = confidenceThreshold
        self.iouThreshold = iouThreshold
    }

    static func create(
        modelURL: URL,
        confidenceThreshold: Float,
        iouThreshold: Float,
        maxDetections: Int,
        completion: @escaping @Sendable (Result<UltralyticsObjectDetector, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .all

                let modelExtension = modelURL.pathExtension.lowercased()
                let mlModel: MLModel

                if modelExtension == "mlmodelc" {
                    mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
                } else {
                    let compiledURL = try MLModel.compileModel(at: modelURL)
                    mlModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
                }

                guard
                    let userDefined = mlModel.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
                else {
                    throw UltralyticsObjectDetectorError.invalidModelMetadata
                }

                let labels = extractLabels(from: userDefined)
                let requiresNMS = (userDefined["nms"]?.lowercased() != "false")
                let inputSize = modelInputSize(for: mlModel)

                let visionModel = try VNCoreMLModel(for: mlModel)
                let effectiveIoU = requiresNMS ? Double(iouThreshold) : 1.0
                visionModel.featureProvider = ThresholdProvider(
                    iouThreshold: effectiveIoU,
                    confidenceThreshold: Double(confidenceThreshold)
                )

                let request = VNCoreMLRequest(model: visionModel)
                request.imageCropAndScaleOption = .scaleFill

                let detector = UltralyticsObjectDetector(
                    visionModel: visionModel,
                    visionRequest: request,
                    labels: labels,
                    requiresNMS: requiresNMS,
                    modelInputSize: inputSize,
                    maxDetections: maxDetections,
                    confidenceThreshold: confidenceThreshold,
                    iouThreshold: iouThreshold
                )

                DispatchQueue.main.async {
                    completion(.success(detector))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func predict(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> UltralyticsDetectionResult {
        let requestHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        let start = CACurrentMediaTime()

        try requestHandler.perform([visionRequest])

        let detections = decodeDetections(
            from: visionRequest.results ?? [],
            imageSize: CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        )

        return UltralyticsDetectionResult(
            detections: detections,
            inferenceTime: CACurrentMediaTime() - start
        )
    }

    private func decodeDetections(from results: [Any], imageSize: CGSize) -> [UltralyticsDetection] {
        if let recognizedDetections = results as? [VNRecognizedObjectObservation] {
            return Array(recognizedDetections.prefix(maxDetections)).compactMap { observation in
                guard let topLabel = observation.labels.first else {
                    return nil
                }

                return UltralyticsDetection(
                    index: labels.firstIndex(of: topLabel.identifier) ?? 0,
                    label: topLabel.identifier,
                    confidence: topLabel.confidence,
                    normalizedBoundingBox: observation.boundingBox
                )
            }
        }

        if let rawResults = results as? [VNCoreMLFeatureValueObservation],
           let prediction = rawResults.first?.featureValue.multiArrayValue {
            return decodeRawDetections(prediction)
        }

        return []
    }

    private func decodeRawDetections(_ prediction: MLMultiArray) -> [UltralyticsDetection] {
        let shape = prediction.shape.map(\.intValue)
        let strides = prediction.strides.map(\.intValue)
        let pointer = prediction.dataPointer.assumingMemoryBound(to: Float.self)

        guard shape.count == 3 else {
            return []
        }

        let isEndToEnd = shape[2] < shape[1]
        if isEndToEnd {
            return processEndToEndResults(pointer: pointer, shape: shape, strides: strides)
        }

        return processTraditionalResults(pointer: pointer, shape: shape, strides: strides)
    }

    private func processEndToEndResults(
        pointer: UnsafeMutablePointer<Float>,
        shape: [Int],
        strides: [Int]
    ) -> [UltralyticsDetection] {
        let numDetections = shape[1]
        let numFields = shape[2]
        let detectionStride = strides[1]
        let fieldStride = strides[2]
        var detections: [UltralyticsDetection] = []

        for index in 0..<numDetections {
            let base = index * detectionStride
            let confidence = pointer[base + 4 * fieldStride]

            guard confidence >= confidenceThreshold else {
                continue
            }

            let x1 = CGFloat(pointer[base])
            let y1 = CGFloat(pointer[base + fieldStride])
            let x2 = CGFloat(pointer[base + 2 * fieldStride])
            let y2 = CGFloat(pointer[base + 3 * fieldStride])
            let classIndex = numFields > 5 ? Int(pointer[base + 5 * fieldStride]) : 0

            let normalizedRect = normalizedRectFromModelCoordinates(
                x: x1,
                y: y1,
                width: x2 - x1,
                height: y2 - y1
            )

            detections.append(
                UltralyticsDetection(
                    index: classIndex,
                    label: label(for: classIndex),
                    confidence: confidence,
                    normalizedBoundingBox: normalizedRect
                )
            )

            if detections.count >= maxDetections {
                break
            }
        }

        return detections
    }

    private func processTraditionalResults(
        pointer: UnsafeMutablePointer<Float>,
        shape: [Int],
        strides: [Int]
    ) -> [UltralyticsDetection] {
        let numFeatures = shape[1]
        let numAnchors = shape[2]
        let numClasses = numFeatures - 4
        let featureStride = strides[1]
        let anchorStride = strides[2]

        var candidateBoxes: [CGRect] = []
        var candidateScores: [Float] = []
        var candidateClasses: [Int] = []

        for anchorIndex in 0..<numAnchors {
            var bestScore: Float = 0
            var bestClass = 0

            for classIndex in 0..<numClasses {
                let score = pointer[(4 + classIndex) * featureStride + anchorIndex * anchorStride]
                if score > bestScore {
                    bestScore = score
                    bestClass = classIndex
                }
            }

            guard bestScore >= confidenceThreshold else {
                continue
            }

            let x = CGFloat(pointer[anchorIndex * anchorStride])
            let y = CGFloat(pointer[featureStride + anchorIndex * anchorStride])
            let width = CGFloat(pointer[2 * featureStride + anchorIndex * anchorStride])
            let height = CGFloat(pointer[3 * featureStride + anchorIndex * anchorStride])

            candidateBoxes.append(
                CGRect(
                    x: x - width / 2,
                    y: y - height / 2,
                    width: width,
                    height: height
                )
            )
            candidateScores.append(bestScore)
            candidateClasses.append(bestClass)
        }

        let selectedIndices = nonMaxSuppression(
            boxes: candidateBoxes,
            scores: candidateScores,
            threshold: iouThreshold
        )

        return selectedIndices.prefix(maxDetections).map { selectedIndex in
            let rect = candidateBoxes[selectedIndex]
            return UltralyticsDetection(
                index: candidateClasses[selectedIndex],
                label: label(for: candidateClasses[selectedIndex]),
                confidence: candidateScores[selectedIndex],
                normalizedBoundingBox: normalizedRectFromModelCoordinates(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: rect.height
                )
            )
        }
    }

    private func normalizedRectFromModelCoordinates(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let normalizedX = x / modelInputSize.width
        let normalizedY = y / modelInputSize.height
        let normalizedWidth = width / modelInputSize.width
        let normalizedHeight = height / modelInputSize.height

        return CGRect(
            x: normalizedX,
            y: 1 - normalizedY - normalizedHeight,
            width: normalizedWidth,
            height: normalizedHeight
        )
    }

    private func label(for index: Int) -> String {
        guard labels.indices.contains(index) else {
            return "\(index)"
        }

        return labels[index]
    }

    private static func extractLabels(from metadata: [String: String]) -> [String] {
        if let classes = metadata["classes"] {
            return classes.components(separatedBy: ",")
        }

        if let names = metadata["names"] {
            let cleanedInput = names
                .replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
                .replacingOccurrences(of: " ", with: "")

            let parsedLabels = cleanedInput
                .components(separatedBy: ",")
                .compactMap { pair -> String? in
                    let components = pair.components(separatedBy: ":")
                    guard components.count >= 2 else {
                        return nil
                    }

                    return components[1].replacingOccurrences(of: "'", with: "")
                }

            if !parsedLabels.isEmpty {
                return parsedLabels
            }
        }

        return []
    }

    private static func modelInputSize(for model: MLModel) -> CGSize {
        guard let inputDescription = model.modelDescription.inputDescriptionsByName.first?.value else {
            return CGSize(width: 640, height: 640)
        }

        if let multiArrayConstraint = inputDescription.multiArrayConstraint {
            let shape = multiArrayConstraint.shape.map(\.intValue)
            if shape.count >= 2 {
                return CGSize(width: shape[shape.count - 1], height: shape[shape.count - 2])
            }
        }

        if let imageConstraint = inputDescription.imageConstraint {
            return CGSize(width: imageConstraint.pixelsWide, height: imageConstraint.pixelsHigh)
        }

        return CGSize(width: 640, height: 640)
    }
}

private final class ThresholdProvider: MLFeatureProvider {
    nonisolated(unsafe) private let values: [String: MLFeatureValue]

    init(iouThreshold: Double, confidenceThreshold: Double) {
        values = [
            "iouThreshold": MLFeatureValue(double: iouThreshold),
            "confidenceThreshold": MLFeatureValue(double: confidenceThreshold)
        ]
    }

    nonisolated var featureNames: Set<String> {
        Set(values.keys)
    }

    nonisolated func featureValue(for featureName: String) -> MLFeatureValue? {
        values[featureName]
    }
}

private func nonMaxSuppression(boxes: [CGRect], scores: [Float], threshold: Float) -> [Int] {
    let sortedIndices = scores.enumerated()
        .sorted { $0.element > $1.element }
        .map(\.offset)

    var selectedIndices: [Int] = []
    var activeIndices = Array(repeating: true, count: boxes.count)

    for sortedPosition in 0..<sortedIndices.count {
        let index = sortedIndices[sortedPosition]
        guard activeIndices[index] else {
            continue
        }

        selectedIndices.append(index)

        for comparisonPosition in (sortedPosition + 1)..<sortedIndices.count {
            let comparisonIndex = sortedIndices[comparisonPosition]
            guard activeIndices[comparisonIndex] else {
                continue
            }

            let intersection = boxes[index].intersection(boxes[comparisonIndex])
            let union = boxes[index].area + boxes[comparisonIndex].area - intersection.area

            if union > 0, intersection.area / union > CGFloat(threshold) {
                activeIndices[comparisonIndex] = false
            }
        }
    }

    return selectedIndices
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }
}
