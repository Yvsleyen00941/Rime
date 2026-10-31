#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug builds only. Opened with `-RimeShots <folder>`, Rime photographs its own window for the
/// README and the website, then quits. Only Rime's window is captured, so no permission is needed.
@MainActor
enum Shots {
    static func runIfAsked() {
        guard let path = UserDefaults.standard.string(forKey: "RimeShots") else { return }
        Task { await run(into: URL(fileURLWithPath: path, isDirectory: true)) }
    }

    private static func run(into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        guard let controller = await frozenReader(), let window = controller.window,
              let stage = window.contentView as? StageView else {
            quit()
            return
        }
        let reader = controller.reader
        reader.hoveringControls = true

        // The sharpest screen with the notch, whichever one Rime opened on.
        if let builtIn = NSScreen.screens.first(where: isBuiltIn), window.screen != builtIn {
            window.setFrame(builtIn.frame, display: true)
            controller.screenChanged()
            controller.pdfView.refit()
        }
        await pause(3)

        // Reading with the pen picked up: the capsule shows the highlighter's colours.
        reader.perform(.tool(.highlight))
        await pause(1)
        await capture(window, "light-controls", into: folder)

        // The controls fade, and only the page is left.
        reader.perform(.tool(.select))
        reader.hoveringControls = false
        await pause(3)
        await capture(window, "light-reading", into: folder)

        // Zoomed out: the pages float on the ice.
        controller.pdfView.zoom(to: controller.pdfView.fitScale * 0.62)
        await pause(1.5)
        await capture(window, "light-pages", into: folder)

        // Dark Mode.
        controller.pdfView.zoom(to: controller.pdfView.fitScale)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await pause(3)
        await capture(window, "dark-reading", into: folder)
        reader.hoveringControls = true
        wiggle(window)
        reader.perform(.tool(.shape))
        await pause(1)
        await capture(window, "dark-controls", into: folder)
        reader.perform(.tool(.select))

        // The freeze, slowed down, without the pages: frost growing in from the edges.
        NSApp.appearance = NSAppearance(named: .aqua)
        await pause(2.5)
        stage.content.alphaValue = 0
        stage.controls.isHidden = true
        stage.frost.setFrozen(false, duration: 0)
        await pause(0.5)
        stage.frost.setFrozen(true, duration: 6)
        for (i, delay) in [0.45, 0.3, 0.3].enumerated() {
            await pause(delay)
            await capture(window, "freezing-\(i + 1)", into: folder)
        }
        await pause(5)
        quit()
    }

    /// Quits from the run loop: terminating inside this task would block the melt it waits for.
    private static func quit() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private static func frozenReader() async -> ReaderWindowController? {
        for _ in 0..<100 {
            if let reader = ReaderWindowController.all.first(where: \.isFrozen) { return reader }
            await pause(0.2)
        }
        return nil
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }

    /// A mouse move inside the window, so the controls come back.
    private static func wiggle(_ window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: window.frame.width / 2, y: 200),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func capture(_ window: NSWindow, _ name: String, into folder: URL) async {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let scale = window.screen?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            NSLog("Shots: \(name) failed: \(error)")
        }
    }
}
#endif
