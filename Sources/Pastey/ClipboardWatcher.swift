import AppKit
import ImageIO

/// macOS has no clipboard-changed event; everyone polls changeCount. ~4x/sec is
/// the standard rate (Maccy, Paste do the same) and costs nothing measurable.
final class ClipboardWatcher {
    var isPaused = false
    var onCapture: (() -> Void)?

    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
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

        guard var capture = buildCapture(pb) else { return }
        let app = NSWorkspace.shared.frontmostApplication
        capture.sourceBundleID = app?.bundleIdentifier
        capture.sourceAppName = app?.localizedName
        DB.shared.upsert(capture)
        DB.shared.trim()
        DB.shared.pruneHistory(olderThan: AppSettings.shared.keepHistory.seconds)
        if AppSettings.shared.soundEffects { NSSound(named: "Pop")?.play() }
        onCapture?()
    }

    // Priority: file URLs > image > text. (A Finder copy also carries an icon
    // image and a name string; the file representation is the real content.)
    private func buildCapture(_ pb: NSPasteboard) -> Capture? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
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

        if let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
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
                thumb: makeThumb(png),
                contentHash: hash,
                pixelW: w,
                pixelH: h
            )
        }

        if let s = pb.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        return nil
    }

    private func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let url = URL(string: t) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private func normalizedPNG(_ data: Data) -> Data? {
        // Already PNG? Keep as-is. TIFF from the pasteboard is huge; convert.
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    private func pixelSize(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private func makeThumb(_ data: Data) -> Data? {
        makeThumbnail(data)
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
