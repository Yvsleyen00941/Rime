import AppKit
import Observation

/// What the floating controls show. The window controller carries out their commands.
@Observable
final class ReaderModel {
    enum Command {
        case zoomIn, zoomOut, zoomToFit, export
        case tool(Tool)
        case shape(ShapeKind)
        case color(MarkupColor)
    }

    var pageIndex = 0
    var pageCount = 0
    var scale: CGFloat = 1
    var tool: Tool = .select
    var shape: ShapeKind = .rectangle
    var colors: [Tool: MarkupColor] = [.highlight: .yellow, .underline: .red, .note: .yellow, .shape: .red]
    var hoveringControls = false

    @ObservationIgnored var perform: (Command) -> Void = { _ in }

    /// The colour the current tool draws with.
    var color: MarkupColor { colors[tool] ?? .yellow }
}
