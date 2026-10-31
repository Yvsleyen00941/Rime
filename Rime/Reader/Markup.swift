import AppKit
import PDFKit

enum Tool: Int {
    case select, highlight, underline, note, shape

    var usesColor: Bool { self != .select }
}

enum ShapeKind: Int, CaseIterable, Identifiable {
    case rectangle, oval, line, arrow

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        }
    }
}

enum MarkupColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, red

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.86, blue: 0.24, alpha: 1)
        case .green: NSColor(srgbRed: 0.47, green: 0.85, blue: 0.43, alpha: 1)
        case .blue: NSColor(srgbRed: 0.40, green: 0.69, blue: 1.00, alpha: 1)
        case .pink: NSColor(srgbRed: 1.00, green: 0.52, blue: 0.72, alpha: 1)
        case .purple: NSColor(srgbRed: 0.73, green: 0.55, blue: 0.98, alpha: 1)
        case .red: NSColor(srgbRed: 0.94, green: 0.27, blue: 0.23, alpha: 1)
        }
    }

    var swatch: NSImage {
        let color = color
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}

/// Builds the annotations Rime writes into the PDF, in the standard forms other PDF apps understand.
enum Markup {
    static let lineWidth: CGFloat = 2.5
    private static let groupKey = PDFAnnotationKey(rawValue: "/RimeGroup")

    static func kind(of annotation: PDFAnnotation) -> String {
        (annotation.type ?? "").replacingOccurrences(of: "/", with: "")
    }

    static func isNote(_ annotation: PDFAnnotation) -> Bool { kind(of: annotation) == "Text" }

    static func isMarkup(_ annotation: PDFAnnotation) -> Bool {
        ["Highlight", "Underline", "StrikeOut", "Text", "FreeText", "Square", "Circle", "Line", "Ink"].contains(kind(of: annotation))
    }

    /// One annotation per line of the selection, so highlights hug the text like a marker.
    static func textMarkup(_ type: PDFAnnotationSubtype, over selection: PDFSelection, color: NSColor) -> [(PDFAnnotation, PDFPage)] {
        var items: [(PDFAnnotation, PDFPage)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                annotation.color = color
                annotation.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: bounds.height)), NSValue(point: NSPoint(x: bounds.width, y: bounds.height)),
                    NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: bounds.width, y: 0)),
                ]
                items.append((annotation, page))
            }
        }
        // Lines marked together are deleted and recoloured together.
        if items.count > 1 {
            let id = UUID().uuidString
            for (annotation, _) in items {
                _ = annotation.setValue(id, forAnnotationKey: groupKey)
            }
        }
        return items
    }

    /// The annotation plus any lines that were marked together with it.
    static func group(of annotation: PDFAnnotation, on page: PDFPage, in document: PDFDocument?) -> [(PDFAnnotation, PDFPage)] {
        guard let id = annotation.value(forAnnotationKey: groupKey) as? String, let document, document.pageCount > 0 else {
            return [(annotation, page)]
        }
        let index = document.index(for: page)
        var items: [(PDFAnnotation, PDFPage)] = []
        for i in max(index - 2, 0)...min(index + 2, document.pageCount - 1) {
            guard let candidate = document.page(at: i) else { continue }
            for other in candidate.annotations where other.value(forAnnotationKey: groupKey) as? String == id {
                items.append((other, candidate))
            }
        }
        return items.isEmpty ? [(annotation, page)] : items
    }

    static func note(at point: CGPoint, color: NSColor) -> PDFAnnotation {
        let size: CGFloat = 22
        let note = PDFAnnotation(bounds: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size), forType: .text, withProperties: nil)
        note.iconType = .note
        note.color = color
        note.contents = ""
        return note
    }

    static func shape(_ kind: ShapeKind, color: NSColor) -> PDFAnnotation {
        let type: PDFAnnotationSubtype = switch kind {
        case .rectangle: .square
        case .oval: .circle
        case .line, .arrow: .line
        }
        let annotation = PDFAnnotation(bounds: .zero, forType: type, withProperties: nil)
        annotation.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        if kind == .arrow { annotation.endLineStyle = .openArrow }
        return annotation
    }

    /// Fits a shape between the drag's start and end. With `square`, rectangles and ovals keep equal sides.
    static func reshape(_ annotation: PDFAnnotation, kind: ShapeKind, from a: CGPoint, to b: CGPoint, square: Bool) {
        switch kind {
        case .rectangle, .oval:
            var rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            if square {
                let side = max(rect.width, rect.height)
                rect = CGRect(x: b.x < a.x ? a.x - side : a.x, y: b.y < a.y ? a.y - side : a.y, width: side, height: side)
            }
            annotation.bounds = rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .line, .arrow:
            let pad = lineWidth * 5
            let rect = CGRect(x: min(a.x, b.x) - pad, y: min(a.y, b.y) - pad, width: abs(b.x - a.x) + pad * 2, height: abs(b.y - a.y) + pad * 2)
            annotation.bounds = rect
            annotation.startPoint = CGPoint(x: a.x - rect.minX, y: a.y - rect.minY)
            annotation.endPoint = CGPoint(x: b.x - rect.minX, y: b.y - rect.minY)
        }
    }
}
