import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let delegate = AppDelegate()
    private var settingsWindow: NSWindow?
    private var appearanceObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Preferences.barsKey: BarsWhileReading.hide.rawValue])
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ReaderWindowController.all.forEach { $0.preferencesChanged() } }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ReaderWindowController.all.forEach { $0.screenChanged() } }
            },
        ]
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            onMain { ReaderWindowController.all.forEach { $0.refreshFrost() } }
        }
        #if DEBUG
        Shots.runIfAsked()
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // Launched with nothing to open (or the Dock icon clicked with nothing open): start with the Open panel, like Preview.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let readers = ReaderWindowController.all
        guard !readers.isEmpty else { return true }
        readers.forEach { $0.present(animated: true) }
        return false
    }

    // MARK: Freezing follows Rime being in front

    func applicationDidBecomeActive(_ notification: Notification) {
        ReaderWindowController.all.forEach { $0.appDidBecomeActive() }
        Self.updatePresentation()
    }

    func applicationDidResignActive(_ notification: Notification) {
        ReaderWindowController.all.forEach { $0.melt() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let frozen = ReaderWindowController.all.filter(\.isFrozen)
        guard !frozen.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        var remaining = frozen.count
        for reader in frozen {
            reader.melt {
                remaining -= 1
                if remaining == 0 { reply() }
            }
        }
        onMain(after: 1.2) { reply() }
        return .terminateLater
    }

    /// While reading, the menu bar and Dock tuck away, unless Settings says to keep them.
    static func updatePresentation() {
        let reading = NSApp.isActive && ReaderWindowController.all.contains(where: \.isFrozen)
        let options: NSApplication.PresentationOptions = reading && Preferences.bars == .hide ? [.autoHideDock, .autoHideMenuBar] : []
        if NSApp.presentationOptions != options { NSApp.presentationOptions = options }
    }

    // MARK: Settings

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(window.contentViewController?.view.fittingSize ?? .zero)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(sender)
    }
}
