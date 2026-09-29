import PencilKit
import SwiftUI

struct PencilCanvas: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var drawing: PKDrawing

    private var inkColor: UIColor {
        let value: CGFloat = colorScheme == .dark ? 1 : 0
        return UIColor(red: value, green: value, blue: value, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        // Ink colors are explicit; prevent PencilKit from inverting them again in dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: inkColor, width: 5)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawing = displayDrawing
        canvas.delegate = context.coordinator
        canvas.accessibilityIdentifier = "dictation.canvas"
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        canvas.overrideUserInterfaceStyle = .light
        if let tool = canvas.tool as? PKInkingTool, tool.color != inkColor {
            canvas.tool = PKInkingTool(.pen, color: inkColor, width: 5)
        }
        let displayed = displayDrawing
        if canvas.drawing != displayed {
            context.coordinator.isUpdatingDrawing = true
            canvas.drawing = displayed
            context.coordinator.isUpdatingDrawing = false
        }
    }

    private var displayDrawing: PKDrawing {
        guard drawing.strokes.contains(where: { $0.ink.color != inkColor }) else {
            return drawing
        }
        return PKDrawing(strokes: drawing.strokes.map { original in
            var stroke = original
            stroke.ink.color = inkColor
            return stroke
        })
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvas
        var isUpdatingDrawing = false
        init(parent: PencilCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isUpdatingDrawing else { return }
            parent.drawing = canvasView.drawing
        }
    }
}
