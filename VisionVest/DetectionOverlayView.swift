import CoreGraphics
import SwiftUI

struct DetectionOverlayItem: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
    let distanceMeters: Float?
}

struct DetectionOverlayView: View {
    let overlays: [DetectionOverlayItem]
    let selectedTargetID: UUID?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(overlays) { overlay in
                    let rect = previewRect(
                        from: overlay.boundingBox,
                        in: geometry.size
                    )

                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            overlay.id == selectedTargetID ? Color.yellow : Color.green,
                            lineWidth: overlay.id == selectedTargetID ? 3 : 2
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    overlayLabel(
                        text: overlayText(for: overlay),
                        x: rect.midX,
                        y: max(14, rect.minY + 12)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func previewRect(from normalizedRect: CGRect, in size: CGSize) -> CGRect {
        let rectWidth = normalizedRect.width * size.width
        let rectHeight = normalizedRect.height * size.height
        let x = normalizedRect.minX * size.width
        let y = (1 - normalizedRect.maxY) * size.height

        return CGRect(x: x, y: y, width: rectWidth, height: rectHeight)
    }

    private func overlayLabel(text: String, x: CGFloat, y: CGFloat) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.72))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(x: x, y: y)
    }

    private func overlayText(for overlay: DetectionOverlayItem) -> String {
        if let distanceMeters = overlay.distanceMeters {
            return "\(overlay.label) \(Int(overlay.confidence * 100))% \(Int(distanceMeters * 1000))mm"
        }

        return "\(overlay.label) \(Int(overlay.confidence * 100))% no depth"
    }
}
