import AppKit
import PDFKit
import SwiftUI

/// PDFKit's view with Rime's markup tools. Pinch and smart zoom come from PDFKit's own scroll view.
final class RimePDFView: PDFView {
    weak var reader: ReaderModel?

    private var didFit = false
    private var drag: (annotation: PDFAnnotation, page: PDFPage, kind: ShapeKind, start: CGPoint)?
    private var notePopover: NSPopover?
    private var noteSession: NoteSession?

    var isEditingNote: Bool { notePopover?.isShown == true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        backgroundColor = .clear
        pageShadowsEnabled = true
        autoScales = false
        minScaleFactor = 0.1
        maxScaleFactor = 8
        interpolationQuality = .high
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Zoom

    /// The whole page on screen, but never wider than most of it, so landscape slides stay comfortable too.
    var fitScale: CGFloat {
        guard let page = currentPage ?? document?.page(at: 0) else { return 1 }
        var size = page.bounds(for: displayBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let height = bounds.height - pageBreakMargins.top - pageBreakMargins.bottom - 10
        let width = bounds.width * 0.86
        return min(max(min(height / size.height, width / size.width), minScaleFactor), maxScaleFactor)
    }

    override func layout() {
        super.layout()
        letFrostThrough()
        guard !didFit, document != nil, bounds.height > 100 else { return }
        didFit = true
        scaleFactor = fitScale
        scrollToTop()
        // PDFKit settles its layout a moment later; make sure we still start at the very top.
        onMain { [weak self] in self?.scrollToTop() }
    }

    /// PDFKit's scroll view paints an opaque backdrop even with a clear background colour; switch it off so the ice shows.
    private func letFrostThrough() {
        guard let scrollView = documentView?.enclosingScrollView else { return }
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        documentView?.layer?.backgroundColor = .clear
    }

    private func scrollToTop() {
        guard let documentView, let clip = documentView.enclosingScrollView?.contentView else { return }
        let top = documentView.isFlipped ? 0 : documentView.bounds.height - clip.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(top, 0)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func refit() {
        didFit = false
        needsLayout = true
    }

    /// Changes the zoom while keeping the spot under `anchor` (in window coordinates) where it is.
    func zoom(to scale: CGFloat, around anchor: NSPoint? = nil) {
        let scale = min(max(scale, minScaleFactor), maxScaleFactor)
        let anchorInView = anchor.map { convert($0, from: nil) } ?? NSPoint(x: bounds.midX, y: bounds.midY)
        guard let clip = documentView?.enclosingScrollView?.contentView,
              let page = page(for: anchorInView, nearest: true) else {
            scaleFactor = scale
            return
        }
        let pagePoint = convert(anchorInView, to: page)
        let before = clip.convert(anchorInView, from: self)
        let offset = NSPoint(x: before.x - clip.bounds.minX, y: before.y - clip.bounds.minY)
        scaleFactor = scale
        layoutDocumentView()
        let after = clip.convert(convert(pagePoint, from: page), from: self)
        let visible = NSRect(origin: NSPoint(x: after.x - offset.x, y: after.y - offset.y), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(visible).origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: Tools

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let reader, let page = page(for: location, nearest: false) else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(location, to: page)

        if let note = page.annotation(at: point), Markup.isNote(note) {
            editNote(note, on: page, isNew: false)
            return
        }

        switch reader.tool {
        case .note:
            let note = Markup.note(at: point, color: reader.color.color)
            page.addAnnotation(note)
            editNote(note, on: page, isNew: true)
        case .shape:
            let shape = Markup.shape(reader.shape, color: reader.color.color)
            Markup.reshape(shape, kind: reader.shape, from: point, to: point, square: false)
            page.addAnnotation(shape)
            drag = (shape, page, reader.shape, point)
        case .select, .highlight, .underline:
            super.mouseDown(with: event)
            // PDFKit may track the whole drag inside mouseDown; if the button is already up, the selection is final.
            if NSEvent.pressedMouseButtons & 1 == 0 { applyToolToSelection() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else {
            super.mouseDragged(with: event)
            return
        }
        let point = pagePoint(of: event, on: drag.page)
        Markup.reshape(drag.annotation, kind: drag.kind, from: drag.start, to: point, square: event.modifierFlags.contains(.shift))
        annotationsChanged(on: drag.page)
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else {
            super.mouseUp(with: event)
            applyToolToSelection()
            return
        }
        drag = nil
        let end = pagePoint(of: event, on: current.page)
        guard hypot(end.x - current.start.x, end.y - current.start.y) > 4 else {
            current.page.removeAnnotation(current.annotation)
            return
        }
        registerUndo("Add \(current.kind.title)") { $0.remove([(current.annotation, current.page)], actionName: "Add \(current.kind.title)") }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let tool = reader?.tool, tool == .shape || tool == .note { NSCursor.crosshair.set() }
    }

    /// With Highlight or Underline chosen, selected text gets marked as soon as the selection is made.
    func applyToolToSelection() {
        guard let reader, let selection = currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let type: PDFAnnotationSubtype
        switch reader.tool {
        case .highlight: type = .highlight
        case .underline: type = .underline
        default: return
        }
        let items = Markup.textMarkup(type, over: selection, color: reader.color.color)
        guard !items.isEmpty else { return }
        add(items, actionName: reader.tool == .highlight ? "Highlight" : "Underline")
        clearSelection()
    }

    private func pagePoint(of event: NSEvent, on page: PDFPage) -> CGPoint {
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        let box = page.bounds(for: .mediaBox)
        return CGPoint(x: min(max(point.x, box.minX), box.maxX), y: min(max(point.y, box.minY), box.maxY))
    }

    // MARK: Editing annotations, with undo

    func add(_ items: [(PDFAnnotation, PDFPage)], actionName: String) {
        for (annotation, page) in items { page.addAnnotation(annotation) }
        registerUndo(actionName) { $0.remove(items, actionName: actionName) }
    }

    func remove(_ items: [(PDFAnnotation, PDFPage)], actionName: String) {
        for (annotation, page) in items { page.removeAnnotation(annotation) }
        registerUndo(actionName) { $0.add(items, actionName: actionName) }
    }

    private func setColors(_ items: [(PDFAnnotation, PDFPage)], _ colors: [NSColor]) {
        let previous = items.map(\.0.color)
        for ((annotation, page), color) in zip(items, colors) {
            annotation.color = color
            annotationsChanged(on: page)
        }
        registerUndo("Change Color") { $0.setColors(items, previous) }
    }

    private func setNoteText(_ note: PDFAnnotation, on page: PDFPage, to text: String) {
        let previous = note.contents ?? ""
        note.contents = text
        annotationsChanged(on: page)
        registerUndo("Edit Note") { $0.setNoteText(note, on: page, to: previous) }
    }

    private func registerUndo(_ name: String, _ handler: @escaping (RimePDFView) -> Void) {
        undoManager?.registerUndo(withTarget: self, handler: handler)
        undoManager?.setActionName(name)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: false),
              let annotation = page.annotation(at: convert(location, to: page)),
              Markup.isMarkup(annotation) else { return super.menu(for: event) }

        let group = Markup.group(of: annotation, on: page, in: document)
        let menu = NSMenu()
        if Markup.isNote(annotation) {
            menu.addItem(ClosureMenuItem("Edit Note") { [weak self] in self?.editNote(annotation, on: page, isNew: false) })
            menu.addItem(.separator())
        }
        let colors = NSMenu()
        for color in MarkupColor.allCases {
            let item = ClosureMenuItem(color.title) { [weak self] in
                self?.setColors(group, Array(repeating: color.color, count: group.count))
            }
            item.image = color.swatch
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete") { [weak self] in self?.remove(group, actionName: "Delete") })
        return menu
    }

    // MARK: Notes

    func closeNote() {
        notePopover?.close()
    }

    private func editNote(_ note: PDFAnnotation, on page: PDFPage, isNew: Bool) {
        notePopover?.close()
        let session = NoteSession(note: note, page: page, isNew: isNew)
        session.onClose = { [weak self] session in
            guard let self else { return }
            let text = session.note.contents ?? ""
            if session.deleted {
                // Already handled by the Delete button.
            } else if session.isNew {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    session.page.removeAnnotation(session.note)
                } else {
                    self.registerUndo("Add Note") { $0.remove([(session.note, session.page)], actionName: "Add Note") }
                }
            } else if text != session.original {
                let edited = text
                session.note.contents = session.original
                self.setNoteText(session.note, on: session.page, to: edited)
            }
            self.notePopover = nil
            self.noteSession = nil
            self.window?.makeFirstResponder(self)
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = session
        popover.contentViewController = NSHostingController(rootView: NoteEditor(
            text: session.original,
            onChange: { note.contents = $0 },
            onDelete: { [weak self, weak popover] in
                session.deleted = true
                popover?.close()
                if session.isNew {
                    page.removeAnnotation(note)
                } else {
                    note.contents = session.original
                    self?.remove([(note, page)], actionName: "Delete Note")
                }
            }
        ))
        notePopover = popover
        noteSession = session
        popover.show(relativeTo: convert(note.bounds, from: page), of: self, preferredEdge: .maxX)
    }
}

/// Keeps track of one note being edited in its popover.
@MainActor
private final class NoteSession: NSObject, NSPopoverDelegate {
    let note: PDFAnnotation
    let page: PDFPage
    let isNew: Bool
    let original: String
    var deleted = false
    var onClose: (NoteSession) -> Void = { _ in }

    init(note: PDFAnnotation, page: PDFPage, isNew: Bool) {
        self.note = note
        self.page = page
        self.isNew = isNew
        self.original = note.contents ?? ""
    }

    func popoverDidClose(_ notification: Notification) {
        onClose(self)
    }
}
