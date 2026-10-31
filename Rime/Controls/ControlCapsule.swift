import SwiftUI

/// The floating glass controls. They appear when the pointer moves and fade away while you read.
struct ControlCapsule: View {
    let reader: ReaderModel

    var body: some View {
        HStack(spacing: 2) {
            Text("\(reader.pageIndex + 1) / \(max(reader.pageCount, 1))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            separator
            CapsuleButton(symbol: "minus.magnifyingglass", help: "Zoom Out") { reader.perform(.zoomOut) }
            Button { reader.perform(.zoomToFit) } label: {
                Text("\(Int((reader.scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom to Fit")
            CapsuleButton(symbol: "plus.magnifyingglass", help: "Zoom In") { reader.perform(.zoomIn) }

            separator
            toolButton(.select, "character.cursor.ibeam", "Select Text")
            toolButton(.highlight, "highlighter", "Highlight")
            toolButton(.underline, "underline", "Underline")
            toolButton(.note, "note.text", "Note")
            toolButton(.shape, reader.shape.symbol, "Shapes")
            if reader.tool == .shape {
                ForEach(ShapeKind.allCases) { kind in
                    CapsuleButton(symbol: kind.symbol, help: kind.title, isOn: reader.shape == kind, compact: true) {
                        reader.perform(.shape(kind))
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            if reader.tool.usesColor {
                separator
                ForEach(MarkupColor.allCases) { color in swatch(color) }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            separator
            CapsuleButton(symbol: "square.and.arrow.up", help: "Export…") { reader.perform(.export) }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .padding(10)
        .onHover { reader.hoveringControls = $0 }
        .animation(.snappy(duration: 0.3), value: reader.tool)
    }

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 6)
    }

    private func toolButton(_ tool: Tool, _ symbol: String, _ help: String) -> some View {
        CapsuleButton(symbol: symbol, help: help, isOn: reader.tool == tool) { reader.perform(.tool(tool)) }
    }

    private func swatch(_ color: MarkupColor) -> some View {
        let selected = reader.color == color
        return Button { reader.perform(.color(color)) } label: {
            Circle()
                .fill(Color(nsColor: color.color))
                .frame(width: 14, height: 14)
                .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                .padding(3)
                .overlay { Circle().strokeBorder(Color.primary.opacity(selected ? 0.55 : 0), lineWidth: 1.5) }
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color.title)
    }
}

/// An icon button that sits inside the glass capsule: no glass of its own, a soft fill when hovered or on.
private struct CapsuleButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 12 : 14, weight: .medium))
                .frame(width: compact ? 26 : 32, height: 28)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background {
                    Capsule().fill(isOn ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.primary.opacity(hovering ? 0.08 : 0)))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
