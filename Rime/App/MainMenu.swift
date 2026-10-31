import AppKit
import PDFKit

/// The menu bar, built in code. Actions travel the responder chain to the PDF view, the reader window,
/// its document or the app delegate.
@MainActor
enum MainMenu {
    private static let recents = RecentDocumentsMenu()

    static func build() -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenu("Rime", appMenu()))
        bar.addItem(submenu("File", fileMenu()))
        bar.addItem(submenu("Edit", editMenu()))
        bar.addItem(submenu("View", viewMenu()))
        bar.addItem(submenu("Tools", toolsMenu()))
        bar.addItem(submenu("Go", goMenu()))
        let window = windowMenu()
        bar.addItem(submenu("Window", window))
        NSApp.windowsMenu = window
        return bar
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("About Rime", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu()
        menu.addItem(submenu("Services", services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide Rime", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Rime", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu()
        recent.delegate = recents
        menu.addItem(submenu("Open Recent", recent))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(.separator())
        menu.addItem(item("Export…", #selector(ReaderDocument.exportDocument(_:)), "e", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Actual Size", #selector(ReaderWindowController.zoomActualSize(_:)), "0"))
        menu.addItem(item("Zoom to Fit", #selector(ReaderWindowController.zoomToFit(_:)), "9"))
        menu.addItem(item("Zoom In", #selector(ReaderWindowController.zoomInStep(_:)), "+"))
        // ⌘= also zooms in, for keyboards where + needs Shift.
        let zoomIn = item("Zoom In", #selector(ReaderWindowController.zoomInStep(_:)), "=")
        zoomIn.isHidden = true
        zoomIn.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomIn)
        menu.addItem(item("Zoom Out", #selector(ReaderWindowController.zoomOutStep(_:)), "-"))
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu()
        let choose = #selector(ReaderWindowController.chooseTool(_:))
        menu.addItem(item("Select Text", choose, tag: Tool.select.rawValue))
        menu.addItem(item("Highlight", choose, "h", [.command, .control], tag: Tool.highlight.rawValue))
        menu.addItem(item("Underline", choose, "u", [.command, .control], tag: Tool.underline.rawValue))
        menu.addItem(item("Note", choose, "n", [.command, .control], tag: Tool.note.rawValue))
        menu.addItem(.separator())
        for kind in ShapeKind.allCases {
            menu.addItem(item(kind.title, #selector(ReaderWindowController.chooseShape(_:)), tag: kind.rawValue))
        }
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Previous Page", #selector(PDFView.goToPreviousPage(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]))
        menu.addItem(item("Next Page", #selector(PDFView.goToNextPage(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("First Page", #selector(PDFView.goToFirstPage(_:))))
        menu.addItem(item("Last Page", #selector(PDFView.goToLastPage(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}

/// Fills File ▸ Open Recent from the document controller's list.
@MainActor
private final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path), action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { onMain { NSApp.presentError(error) } }
        }
    }
}
