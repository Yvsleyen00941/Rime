import AppKit

/// Runs `body` on the main actor, after `delay` seconds if given.
func onMain(after delay: TimeInterval = 0, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        MainActor.assumeIsolated { body() }
    }
}

/// A menu item that runs a closure, for menus built on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
