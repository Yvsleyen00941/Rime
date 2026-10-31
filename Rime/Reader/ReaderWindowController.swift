import AppKit
import PDFKit
import SwiftUI

/// One open PDF: a borderless window the size of the screen, with frost all around the pages.
/// It freezes in when Rime is in front and melts away when you switch to another app.
final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    static var all: [ReaderWindowController] {
        NSDocumentController.shared.documents.flatMap(\.windowControllers).compactMap { $0 as? ReaderWindowController }
    }

    let reader: ReaderModel
    let pdfView: RimePDFView
    private let stage: StageView
    private(set) var isFrozen = false
    private var surfaceKey: FrostRenderer.Key?
    private var transition = 0
    private var controlsShown = true
    private var concealWork: DispatchWorkItem?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var bars = Preferences.bars

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var isDark: Bool {
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    init(document: ReaderDocument) {
        let reader = ReaderModel()
        let pdfView = RimePDFView(frame: .zero)
        pdfView.document = document.pdf
        pdfView.reader = reader
        let controls = NSHostingView(rootView: ControlCapsule(reader: reader))
        controls.sizingOptions = [.intrinsicContentSize]
        self.reader = reader
        self.pdfView = pdfView
        stage = StageView(pdfView: pdfView, controls: controls)
        super.init(window: IceWindow(screen: NSScreen.main ?? NSScreen.screens[0]))
        shouldCloseDocument = true
        window?.contentView = stage
        window?.delegate = self
        reader.perform = { [weak self] in self?.perform($0) }
        observePDFView()
        installEventMonitor()
        syncReader()
        layoutForBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func documentDidReload(_ pdf: PDFDocument) {
        pdfView.document = pdf
        pdfView.refit()
        syncReader()
    }

    // MARK: Freeze and melt

    override func showWindow(_ sender: Any?) {
        present(animated: true)
    }

    /// Brings the window in. Animated, frost grows over the desktop from the screen edges and then the pages fade in.
    func present(animated: Bool) {
        guard let window else { return }
        // Already frozen (or freezing): just come forward, without cancelling the fade-in in progress.
        if isFrozen, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        transition += 1
        let generation = transition
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let takingOver = Self.all.contains { $0 !== self && $0.isFrozen }

        FrostRenderer.shared.surface(for: screen, dark: isDark) { [weak self] surface in
            guard let self, generation == self.transition else { return }
            window.setFrame(screen.frame, display: false)
            self.surfaceKey = surface.key
            self.stage.frost.show(surface, crossfade: false)
            self.isFrozen = true
            AppDelegate.updatePresentation()
            self.layoutForBars()

            if takingOver || !animated {
                // Another document was already frozen here: swap in place, no thaw in between.
                self.stage.frost.setFrozen(true, duration: 0)
                self.stage.content.alphaValue = 1
                window.alphaValue = 1
                window.makeKeyAndOrderFront(nil)
            } else if self.reduceMotion {
                self.stage.frost.setFrozen(true, duration: 0)
                self.stage.content.alphaValue = 1
                window.alphaValue = 0
                window.makeKeyAndOrderFront(nil)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    window.animator().alphaValue = 1
                }
            } else {
                self.stage.frost.setFrozen(false, duration: 0)
                self.stage.content.alphaValue = 0
                window.alphaValue = 1
                window.makeKeyAndOrderFront(nil)
                self.stage.frost.setFrozen(true, duration: 0.95)
                onMain(after: 0.35) { [weak self] in
                    guard let self, generation == self.transition else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.55
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.stage.content.animator().alphaValue = 1
                    }
                }
            }
            window.makeFirstResponder(self.pdfView)
            self.revealControls()
            self.closeOtherDocuments()
        }
    }

    /// The reverse: the pages fade, the frost recedes to the edges, and the window steps aside.
    func melt(completion: (() -> Void)? = nil) {
        transition += 1
        let generation = transition
        guard let window, window.isVisible, isFrozen else {
            completion?()
            return
        }
        isFrozen = false
        AppDelegate.updatePresentation()
        pdfView.closeNote()
        concealControls(hideCursor: false)

        let finish = { [weak self] in
            if let self, generation == self.transition {
                window.orderOut(nil)
                window.alphaValue = 1
                self.stage.content.alphaValue = 1
            }
            completion?()
        }
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                self.stage.content.animator().alphaValue = 0
            }
            stage.frost.setFrozen(false, duration: 0.6) { finish() }
        }
    }

    func appDidBecomeActive() {
        if isFrozen, window?.isVisible == true {
            refreshFrost()
        } else {
            present(animated: true)
        }
    }

    /// Closing saves first (Rime autosaves like Preview), then melts the ice away.
    func closeWithMelt() {
        guard let document = document as? NSDocument else {
            close()
            return
        }
        document.canClose(withDelegate: self, shouldClose: #selector(closeDecision(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func closeDecision(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose else { return }
        melt { document.close() }
    }

    /// One document at a time: once this one holds the screen, the others save and close.
    private func closeOtherDocuments() {
        for other in Self.all where other !== self {
            (other.document as? ReaderDocument)?.closeAfterSaving()
        }
    }

    // MARK: Surroundings

    /// Pages always avoid the notch, and the menu bar and Dock too when those stay visible.
    func layoutForBars() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        var insets = NSEdgeInsets(top: screen.safeAreaInsets.top, left: 0, bottom: 0, right: 0)
        if Preferences.bars == .show {
            let frame = screen.frame, visible = screen.visibleFrame
            insets.top = max(insets.top, frame.maxY - visible.maxY)
            insets.bottom = visible.minY - frame.minY
            insets.left = visible.minX - frame.minX
            insets.right = frame.maxX - visible.maxX
        }
        stage.insets = insets
    }

    func preferencesChanged() {
        guard Preferences.bars != bars else { return }
        bars = Preferences.bars
        AppDelegate.updatePresentation()
        layoutForBars()
        // The bars take a moment to come back before their final size is known.
        onMain(after: 0.5) { [weak self] in self?.layoutForBars() }
    }

    func screenChanged() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
        layoutForBars()
        refreshFrost()
    }

    /// Re-renders the frost after the wallpaper, appearance or screen changed.
    func refreshFrost() {
        guard isFrozen, let screen = window?.screen else { return }
        guard FrostRenderer.key(for: screen, dark: isDark) != surfaceKey else { return }
        FrostRenderer.shared.surface(for: screen, dark: isDark) { [weak self] surface in
            guard let self, self.isFrozen else { return }
            self.surfaceKey = surface.key
            self.stage.frost.show(surface, crossfade: true)
        }
    }

    // MARK: Controls

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return event }
                switch event.type {
                case .mouseMoved, .leftMouseDragged:
                    self.revealControls()
                case .scrollWheel:
                    if !self.reader.hoveringControls { self.concealControls(hideCursor: true) }
                case .keyDown where event.keyCode == 53 && self.reader.tool != .select:
                    // Escape puts the pen down.
                    self.perform(.tool(.select))
                    return nil
                default:
                    break
                }
                return event
            }
        }
    }

    private func revealControls() {
        if !controlsShown {
            controlsShown = true
            stage.controls.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.stage.controls.animator().alphaValue = 1
            }
        }
        scheduleConceal()
    }

    private func scheduleConceal() {
        concealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.reader.hoveringControls || self.pdfView.isEditingNote {
                    self.scheduleConceal()
                } else {
                    self.concealControls(hideCursor: true)
                }
            }
        }
        concealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func concealControls(hideCursor: Bool) {
        concealWork?.cancel()
        guard controlsShown else { return }
        controlsShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            self.stage.controls.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.controlsShown else { return }
                self.stage.controls.isHidden = true
            }
        })
        if hideCursor, window?.isKeyWindow == true, reader.tool == .select {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func perform(_ command: ReaderModel.Command) {
        switch command {
        case .zoomIn: pdfView.zoom(to: pdfView.scaleFactor * 1.25)
        case .zoomOut: pdfView.zoom(to: pdfView.scaleFactor / 1.25)
        case .zoomToFit: pdfView.zoom(to: pdfView.fitScale)
        case .export: (document as? ReaderDocument)?.exportDocument(nil)
        case .tool(let tool): choose(tool)
        case .shape(let kind):
            reader.shape = kind
            choose(.shape)
        case .color(let color):
            reader.colors[reader.tool] = color
        }
    }

    private func choose(_ tool: Tool) {
        reader.tool = tool
        pdfView.applyToolToSelection()
        window?.makeFirstResponder(pdfView)
    }

    // MARK: Menu actions

    @objc func zoomInStep(_ sender: Any?) { perform(.zoomIn) }
    @objc func zoomOutStep(_ sender: Any?) { perform(.zoomOut) }
    @objc func zoomToFit(_ sender: Any?) { perform(.zoomToFit) }
    @objc func zoomActualSize(_ sender: Any?) { pdfView.zoom(to: 1) }

    @objc func chooseTool(_ sender: NSMenuItem) {
        if let tool = Tool(rawValue: sender.tag) { perform(.tool(tool)) }
    }

    @objc func chooseShape(_ sender: NSMenuItem) {
        if let kind = ShapeKind(rawValue: sender.tag) { perform(.shape(kind)) }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(chooseTool(_:)):
            item.state = reader.tool.rawValue == item.tag ? .on : .off
        case #selector(chooseShape(_:)):
            item.state = reader.tool == .shape && reader.shape.rawValue == item.tag ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        isFrozen = false
        transition += 1
        concealWork?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        onMain { AppDelegate.updatePresentation() }
    }

    private func observePDFView() {
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewDocumentChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncReader() }
            })
        }
    }

    private func syncReader() {
        guard let document = pdfView.document else { return }
        reader.pageCount = document.pageCount
        if let page = pdfView.currentPage { reader.pageIndex = document.index(for: page) }
        reader.scale = pdfView.scaleFactor
    }
}
