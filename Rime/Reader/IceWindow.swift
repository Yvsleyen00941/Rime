import AppKit

/// A borderless window that exactly covers one screen, menu bar and Dock areas included.
final class IceWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        tabbingMode = .disallowed
        collectionBehavior = [.fullScreenNone, .managed]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Windows normally get pushed below the menu bar; this one has to cover it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func performClose(_ sender: Any?) {
        (windowController as? ReaderWindowController)?.closeWithMelt()
    }

    // There's no title bar to minimise; stepping out of the way is the closest match.
    override func performMiniaturize(_ sender: Any?) {
        NSApp.hide(sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performClose(_:)), #selector(performMiniaturize(_:)): true
        default: super.validateMenuItem(menuItem)
        }
    }
}
