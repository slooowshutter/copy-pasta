import AppKit
import ImageIO

/// macOS has no clipboard-changed event; everyone polls changeCount. ~4x/sec is
/// the standard rate (Maccy, Paste do the same) and costs nothing measurable.
final class ClipboardWatcher {
    var isPaused = false
    var onCapture: (() -> Void)?

    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    /// PNG encoding, hashing and thumbnailing a big screenshot can take a few hundred
    /// ms — off the main thread so the hotkey and panel stay responsive meanwhile.
    private let imageQueue = DispatchQueue(label: "com.marclamy.pastey.images", qos: .userInitiated)

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Pastey's own writes (picking an item in the panel) aren't new copies: mark the
    /// current change as seen so the next tick skips it.
    func skipCurrentChange() {
        lastChange = NSPasteboard.general.changeCount
    }

    private enum Content {
        case ready(Capture)
        case image(Data)  // raw PNG/TIFF, processed on imageQueue
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard !isPaused else { return }

        let types = Set(pb.types ?? [])
        // Privacy: password managers mark copies as concealed/transient. Never store those.
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) {
            return
        }

        guard let content = read(pb) else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let copiedAt = Date()
        let finish: (Capture) -> Void = { [weak self] capture in
            var capture = capture
            capture.sourceBundleID = app?.bundleIdentifier
            capture.sourceAppName = app?.localizedName
            self?.store(capture, at: copiedAt)
        }

        switch content {
        case .ready(let capture):
            finish(capture)
        case .image(let raw):
            imageQueue.async {
                guard let capture = Self.imageCapture(raw) else { return }
                DispatchQueue.main.async { finish(capture) }
            }
        }
    }

    private func store(_ capture: Capture, at date: Date) {
        DB.shared.upsert(capture, at: date)
        DB.shared.trim()
        DB.shared.pruneHistory(olderThan: AppSettings.shared.keepHistory.seconds)
        if AppSettings.shared.soundEffects { NSSound(named: "Pop")?.play() }
        onCapture?()
    }

    // Priority: file URLs > image > text. (A Finder copy also carries an icon image
    // and a name string; the file representation is the real content.) Exception:
    // document apps (Word, Excel, Keynote…) put a rendered picture of the selection
    // next to its rich text — there the text is the content, or pasting it back
    // would give a picture. A bare link next to an image is a browser "Copy Image".
    private func read(_ pb: NSPasteboard) -> Content? {
        if let files = fileCapture(pb) { return .ready(files) }
        let text = textCapture(pb)
        guard let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff) else {
            return text.map(Content.ready)
        }
        if let text, text.kind == .text, text.rtf != nil || text.html != nil {
            return .ready(text)
        }
        return .image(raw)
    }

    private func fileCapture(_ pb: NSPasteboard) -> Capture? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        let paths = urls.map(\.path)
        let joined = paths.joined(separator: "\n")
        return Capture(
            kind: .file,
            plainText: joined,
            filePaths: paths,
            contentHash: sha256(Data(joined.utf8)),
            charCount: paths.count
        )
    }

    private func textCapture(_ pb: NSPasteboard) -> Capture? {
        guard let s = pb.string(forType: .string),
              !s.trimmingCharacters(in: Self.blank).isEmpty else { return nil }
        let text = String(s.prefix(100_000)) // ponytail: cap giant copies; raise if it ever bites
        return Capture(
            kind: isLink(text) ? .link : .text,
            plainText: text,
            rtf: pb.data(forType: .rtf),
            html: pb.data(forType: .html),
            contentHash: sha256(Data(text.utf8)),
            charCount: text.count
        )
    }

    /// Whitespace, plus U+FFFC: the placeholder rich-text apps put in the plain text
    /// where an inline image sits (copying just an image from Word/Pages/Notes).
    private static let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))

    private func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let url = URL(string: t) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    /// Runs on imageQueue: pure data + file work, no DB or UI.
    private static func imageCapture(_ raw: Data) -> Capture? {
        guard let png = normalizedPNG(raw) else { return nil }
        let hash = sha256(png)
        let filename = String(hash.prefix(32)) + ".png"
        let url = DB.imagesDir.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? png.write(to: url)
        }
        let (w, h) = pixelSize(png)
        return Capture(
            kind: .image,
            imagePath: filename,
            thumb: makeThumbnail(png),
            contentHash: hash,
            pixelW: w,
            pixelH: h
        )
    }

    private static func normalizedPNG(_ data: Data) -> Data? {
        // Already PNG? Keep as-is. TIFF from the pasteboard is huge; convert.
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    private static func pixelSize(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}

/// Card thumbnails. 1000px so a 256pt card (512px on Retina) downscales sharply
/// instead of upscaling a too-small image (the old 400px thumbs looked blurry).
func makeThumbnail(_ data: Data, maxPx: Int = 1000) -> Data? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPx,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
}
