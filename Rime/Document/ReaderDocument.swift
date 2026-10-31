import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A PDF on disk. Markup is written back into the file, autosaved in place the way Preview does it.
@objc(ReaderDocument)
final class ReaderDocument: NSDocument {
    private(set) var pdf = PDFDocument()

    override class var autosavesInPlace: Bool { true }

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let pdf = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        guard !pdf.isLocked else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue, userInfo: [
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is protected with a password.",
                NSLocalizedRecoverySuggestionErrorKey: "Rime can’t open locked PDFs yet. Open it in Preview to unlock it.",
            ])
        }
        self.pdf = pdf
        (windowControllers.first as? ReaderWindowController)?.documentDidReload(pdf)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        guard pdf.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
    }

    // MARK: Closing

    func closeAfterSaving() {
        canClose(withDelegate: self, shouldClose: #selector(closeDecision(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func closeDecision(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if shouldClose { close() }
    }

    // MARK: Export

    @IBAction func exportDocument(_ sender: Any?) {
        let panel = NSSavePanel()
        let options = ExportOptions(panel: panel, baseName: (displayName as NSString).deletingPathExtension)
        panel.title = "Export"
        panel.accessoryView = options
        panel.canCreateDirectories = true
        let page = (windowControllers.first as? ReaderWindowController)?.pdfView.currentPage ?? pdf.page(at: 0)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    switch options.format {
                    case .pdf:
                        guard self.pdf.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
                    case .png, .jpeg:
                        guard let page else { return }
                        try Self.writeImage(of: page, to: url, as: options.format)
                    }
                } catch {
                    self.presentError(error)
                }
            }
        }
    }

    private static func writeImage(of page: PDFPage, to url: URL, as format: ExportOptions.Format) throws {
        let box = page.bounds(for: .cropBox)
        var size = CGSize(width: box.width * 3, height: box.height * 3)   // about 216 dpi
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let image = page.thumbnail(of: size, for: .cropBox)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = format == .png
                ? bitmap.representation(using: .png, properties: [:])
                : bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}

/// The format menu at the bottom of the Export panel.
private final class ExportOptions: NSView {
    enum Format: Int, CaseIterable {
        case pdf, png, jpeg

        var title: String {
            switch self {
            case .pdf: "PDF"
            case .png: "PNG image of this page"
            case .jpeg: "JPEG image of this page"
            }
        }

        var type: UTType {
            switch self {
            case .pdf: .pdf
            case .png: .png
            case .jpeg: .jpeg
            }
        }
    }

    private weak var panel: NSSavePanel?
    private let baseName: String
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    var format: Format { Format(rawValue: popup.indexOfSelectedItem) ?? .pdf }

    init(panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        popup.addItems(withTitles: Format.allCases.map(\.title))
        popup.target = self
        popup.action = #selector(formatChanged)
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        formatChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func formatChanged() {
        let type = format.type
        panel?.allowedContentTypes = [type]
        panel?.nameFieldStringValue = baseName + "." + (type.preferredFilenameExtension ?? "pdf")
    }
}
