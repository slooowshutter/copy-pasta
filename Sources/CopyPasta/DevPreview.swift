#if DEBUG
import AppKit
import SwiftUI

/// Dev only (debug builds): `CopyPasta --render-cards out.png` renders a gallery of sample
/// cards to a PNG and exits — no window, nothing on screen, no history read.
enum DevPreview {
    @MainActor
    static func renderCards(to path: String) {
        let samples = makeSamples()
        let rows = stride(from: 0, to: samples.count, by: 6).map { Array(samples[$0..<min($0 + 6, samples.count)]) }
        let gallery = VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28)
                TabLabel(icon: "clock.arrow.circlepath", text: "Clipboard", isCurrent: true)
                TabLabel(dot: Color(hex: "#FF8A3D"), text: "Prompts", isCurrent: false)
                TabLabel(dot: Color(hex: "#4D8DFF"), text: "Useful Links", isCurrent: false)
                TabLabel(dot: Color(hex: "#3DBF6B"), text: "Code", isCurrent: false)
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .frame(maxWidth: .infinity)
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 14) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        let sample = rows[r][i]
                        CardView(item: sample.item, selected: r == 0 && i == 0, boardColor: sample.board)
                    }
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.13)))
        .padding(20)
        .background(Color(white: 0.06))
        .environment(\.colorScheme, .dark)

        // In a hidden window, not ImageRenderer: that leaves scroll areas (long cards) blank.
        NSApplication.shared.setActivationPolicy(.prohibited)
        snapshot(gallery, size: NSHostingView(rootView: gallery).fittingSize, to: path)
    }

    /// The whole drawer, laid out at its real size in a window that's never shown
    /// (ScrollView and the material don't render through ImageRenderer).
    @MainActor
    static func renderPanel(to path: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, no focus
        let ctrl = PanelController(watcher: ClipboardWatcher())
        let state = DrawerState()
        // `--real`: your own latest history instead of the samples (the PNG then shows it).
        state.items = CommandLine.arguments.contains("--real")
            ? DB.shared.recent(limit: 40) : makeSamples().map(\.item)
        state.boards = [Board(id: 1, name: "Prompts", colorHex: "#FF8A3D"), Board(id: 2, name: "Useful Links", colorHex: "#4D8DFF")]
        state.selectedIndices = [0]
        let size = NSSize(width: CommandLine.arguments.contains("--wide") ? 3600 : 1512, height: 380)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(hex: "#F28C38"), Color(hex: "#C2410C")], startPoint: .top, endPoint: .bottom)
            DrawerView(state: state, ctrl: ctrl)
                .background(Color(white: 0.13).clipShape(panelShape)
                    .padding(EdgeInsets(top: 0, leading: panelInset, bottom: panelInset, trailing: panelInset)))
                .frame(height: 336 + panelInset)
        })
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// The Copy Tricks overlays (caret bubble, Island) in each state, on the wallpaper.
    @MainActor
    static func renderTricks(to path: String) {
        let french = "Tu peux m'envoyer le deck avant le point de 15h ? Je veux revoir la slide des prix avec Sam."
        let english = "Can you send me the deck before the 3pm sync? I want to go over the pricing slide with Sam."
        let fix = (before: "The bar: hover over the bar under the header and it cccc and displays a handle. Click anywhere on it to access it, or drag the handle left and right during audio playback.",
                   after: "The bar: hover over the bar under the header and it displays a handle. Click anywhere on it to access it, or drag the handle left and right during audio playback.")
        // Each state over the selection as it is then: French while it's translated, the result after.
        let states: [(TrickStatus, String)] = [
            (.working(.translate, .english), french),
            (.done(.translate, .english, before: french, after: english, replaced: true), english),
            (.done(.fixTypos, nil, before: fix.before, after: fix.after, replaced: true), fix.after),
            (.failed("Add your OpenRouter key in Settings › API Keys"), fix.before),
        ]
        let wallpaper = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")
        let view = ZStack {
            if let wallpaper { Image(nsImage: wallpaper).resizable().scaledToFill() }
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(states.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 10) {
                            CaretBubbleContent(status: states[i].0)
                            Text(states[i].1).font(.system(size: 13.5)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                                .padding(.leading, 8)
                        }
                    }
                }
            }
            .padding(40)
        }
        .frame(width: 1240, height: 760)
        .clipped()
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        // (main.swift is busy with the dictation port: ride on this flag rather than add one.)
        renderIsland(to: path.replacingOccurrences(of: ".png", with: "-island.png"))
        // The fix drawn on the text itself, in a light and a dark field.
        let before = "Hover over the bar under the header and it cccc and displays a handle, then drag it left an right."
        let fixed = "Hover over the bar under the header and it displays a handle, then drag it left and right."
        NSApplication.shared.setActivationPolicy(.prohibited)
        let inline = VStack(alignment: .leading, spacing: 24) {
            InlineDiff.preview(before: before, fixed: fixed, light: true)
            InlineDiff.preview(before: before, fixed: fixed, light: false)
        }
        .padding(30)
        .background(Color(white: 0.5))
        snapshot(inline, size: NSHostingView(rootView: inline).fittingSize, to: path.replacingOccurrences(of: ".png", with: "-inline.png"))
    }

    /// The dictation Island in each state, hanging from the top of a wallpaper strip.
    @MainActor
    static func renderIsland(to path: String) {
        let words = "Hey Sam, quick one before the three o'clock. Can you send me the deck? I want to go over the pricing slide together before we show it to the team."
        let levels: [CGFloat] = (0..<40).map { i in
            let t = Double(i) * 0.07
            return CGFloat(min(1, 0.08 + 0.85 * abs(sin(t * 9.1) * sin(t * 3.7 + 1.3)) * (0.55 + 0.45 * sin(t * 0.9 + 0.4))))
        }
        let messages = NSWorkspace.shared.icon(forFile: "/System/Applications/Messages.app")
        // A stock wallpaper, not the user's own: these renders can end up in the README.
        let wallpaper = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")
        var shot: NSImage?
        if let wallpaper { shot = wallpaper }
        let states: [(String, DictationIslandState)] = [
            ("Just started", .init(phase: .recording, elapsed: 1, levels: levels, targetIcon: messages)),
            ("Words coming in", .init(phase: .recording, elapsed: 7, levels: levels, transcript: words, targetIcon: messages)),
            ("Screen attached as context", .init(phase: .recording, elapsed: 9, levels: levels, transcript: words,
                                                 note: "Context attached · Safari", screenshot: shot, screenshotSource: "Safari", targetIcon: messages)),
            ("Finishing", .init(phase: .transcribing, processingMessage: "Cleaning up transcript…")),
            ("Failed", .init(phase: .failed, errorMessage: "OpenRouter didn't answer in time. Your recording is saved: retry, or trash it.", showsRecoveryActions: true)),
        ]
        let view = VStack(spacing: 22) {
            ForEach(states.indices, id: \.self) { i in
                ZStack(alignment: .top) {
                    if let wallpaper { Image(nsImage: wallpaper).resizable().scaledToFill().frame(height: 230).clipped() }
                    // Odd rows: a MacBook (camera notch); even rows: an external display.
                    Color.black.opacity(0.35).frame(height: i.isMultiple(of: 2) ? 32 : 25).frame(maxWidth: .infinity)
                    if i.isMultiple(of: 2) {
                        DictationIslandView(state: states[i].1, expanded: .constant(false), notchHeight: 32)
                        RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.02)).frame(width: 186, height: 32)
                            .overlay(Circle().fill(Color(white: 0.12)).frame(width: 7, height: 7))
                    } else {
                        DictationIslandView(state: states[i].1, expanded: .constant(false)).padding(.top, 33)
                    }
                    Text(states[i].0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(12)
                }
                .frame(width: 900, height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(24)
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// The Recordings tab (RecordingCards.swift, not in the drawer yet): the panel as it would
    /// look, plus `-states.png`, every card state up close. Sample recordings, nothing read.
    @MainActor
    static func renderRecordings(to path: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, no focus
        let min: TimeInterval = 60, hour = 3600.0
        let levels: [CGFloat] = (0..<34).map { i in
            let t = Double(i) * 0.07
            return CGFloat(Swift.min(1, 0.1 + 0.85 * abs(sin(t * 9.1) * sin(t * 3.7 + 1.3)) * (0.55 + 0.45 * sin(t * 0.9 + 0.4))))
        }
        let ago = { (s: TimeInterval) in Date().addingTimeInterval(-s) }
        let live = RecordingCard(createdAt: ago(12), status: .recording, duration: 12,
                                 text: "and then if the beta build is green on Thursday we can ship it to the first twenty people on Friday",
                                 audioBytes: 190_000, inputDevice: "MacBook Pro Microphone", levels: levels)
        let working = RecordingCard(createdAt: ago(20), status: .transcribing, duration: 23,
                                    text: "Okay so for the onboarding email, lead with the one-click import, then the screenshot of the panel, and push pricing to the second email.",
                                    message: "Cleaning up transcript…", audioBytes: 340_000)
        let sam = RecordingCard(createdAt: ago(4 * min), status: .transcribed, duration: 42,
                                text: "Hey Sam, quick one before the three o'clock. Can you send me the deck? I want to go over the pricing slide together before we show it to the team.",
                                audioBytes: 610_000)
        let prompt = RecordingCard(createdAt: ago(hour + 5 * min), status: .transcribed, duration: 65,
                                   text: "Refactor the settings window so each pane loads lazily. Keep the sidebar exactly as it is, don't touch the dictation pane, and add a test that opening General never reads the transcript history. Then run the whole suite, and if anything in the panel's tests breaks, fix it in the same pull request rather than skipping it.",
                                   audioBytes: 980_000, screenSource: "Xcode")
        let timeout = RecordingCard(createdAt: ago(12 * min), status: .failed, duration: 102,
                                    message: "OpenRouter didn't answer in time.", audioBytes: 1_640_000, screenSource: "Safari")
        let noKey = RecordingCard(createdAt: ago(26 * hour), status: .failed, duration: 38,
                                  message: "Couldn't transcribe: no OpenRouter key.", audioBytes: 410_000, keyMissing: true)
        let tooShort = RecordingCard(createdAt: ago(30 * hour), status: .notSent, duration: 1,
                                     message: "Too short to send. The audio was kept.", audioBytes: 18_000)
        let silent = RecordingCard(createdAt: ago(50 * hour), status: .failed, duration: 0,
                                   text: "remind me to call the bank about the",
                                   message: "The microphone only sent silence.", audioBytes: 0, inputDevice: "AirPods Pro")
        let strip = [working, sam, timeout, prompt, noKey, tooShort, silent]

        // 1. The real drawer, Recordings tab open, at a MacBook's width.
        let ctrl = PanelController(watcher: ClipboardWatcher())
        let state = DrawerState()
        state.boards = [Board(id: 1, name: "Prompts", colorHex: "#FF8A3D"), Board(id: 2, name: "Useful Links", colorHex: "#4D8DFF"),
                        Board(id: 3, name: "Code", colorHex: "#3DBF6B")]
        state.allRecordings = strip
        state.showingRecordings = true
        state.recordings = strip
        state.selectSingle(1)
        snapshot(ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(hex: "#F28C38"), Color(hex: "#C2410C")], startPoint: .top, endPoint: .bottom)
            DrawerView(state: state, ctrl: ctrl)
                .background(Color(white: 0.13).clipShape(panelShape)
                    .padding(EdgeInsets(top: 0, leading: panelInset, bottom: panelInset, trailing: panelInset)))
                .frame(height: 336 + panelInset)
        }, size: NSSize(width: 1512, height: 380), to: path)

        // 2. Every state, captioned. One card mid-playback, 25 s into 1:05.
        let playing = Playback()
        playing.time = 25
        playing.duration = 65
        let states: [(String, RecordingCard, Bool)] = [
            ("Recording, live", live, false),
            ("Transcribing", working, false),
            ("Done · hovered", sam, true),
            ("Done · playing (after Play)", prompt, false),
            ("Failed · audio kept → Retry", timeout, false),
            ("Failed · key missing → Add Key", noKey, false),
            ("Failed · no audio → Copy Draft", silent, false),
            ("Not sent · too short", tooShort, false),
        ]
        let gallery = VStack(alignment: .leading, spacing: 26) {
            ForEach(0..<2) { row in
                HStack(alignment: .top, spacing: 22) {
                    ForEach(0..<4) { col in
                        let s = states[row * 4 + col]
                        VStack(spacing: 10) {
                            RecordingCardView(card: s.1, selected: s.2,
                                              playback: s.1.id == prompt.id ? playing : nil)
                            Text(s.0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 1162, height: 640)
        .background(Color(white: 0.13))
        snapshot(gallery, size: NSSize(width: 1162, height: 640), to: path.replacingOccurrences(of: ".png", with: "-states.png"))
    }

    /// Lays the view out in a dark window that's never shown and writes it to a PNG
    /// (ImageRenderer skips SF Symbol effects and AppKit-backed views; this doesn't).
    @MainActor
    private static func snapshot(_ view: some View, size: NSSize, to path: String) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    private struct Sample { let item: ClipItem; var board: Color? = nil }

    private static var nextID: Int64 = 1

    private static func item(_ kind: ClipItem.Kind, text: String? = nil, rtf: Data? = nil, app: String?,
                             ago: TimeInterval, files: [String] = [], image: Data? = nil) -> ClipItem {
        nextID += 1
        var w = 0, h = 0
        if let image, let src = CGImageSourceCreateWithData(image as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        return ClipItem(id: nextID, createdAt: Date().addingTimeInterval(-ago), kind: kind, plainText: text,
                        rtf: rtf, html: nil, imagePath: nil, thumb: image.flatMap { makeThumbnail($0) },
                        filePaths: files, sourceBundleID: app, sourceAppName: nil, contentHash: "h\(nextID)",
                        charCount: text?.count ?? files.count, pixelW: w, pixelH: h)
    }

    private static func rtf(_ parts: [(String, NSFont, NSColor)]) -> Data? {
        let s = NSMutableAttributedString()
        for (text, font, color) in parts {
            s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        return s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])
    }

    private static func makeSamples() -> [Sample] {
        let helv = NSFont(name: "Helvetica", size: 12)!
        let helvBold = NSFont(name: "Helvetica-Bold", size: 18)!
        let notes = rtf([
            ("Lisbon trip\n", helvBold, .black),
            ("Flights land Thursday 9:40. Check-in at Casa do Bairro from 3pm.\n\nDinner Friday: Taberna da Rua das Flores — book for 8, they don't take cards.", helv, .black),
        ])
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let kw = NSColor(srgbRed: 0.61, green: 0.14, blue: 0.58, alpha: 1)
        let ty = NSColor(srgbRed: 0.04, green: 0.31, blue: 0.47, alpha: 1)
        let st = NSColor(srgbRed: 0.77, green: 0.10, blue: 0.09, alpha: 1)
        let code = rtf([
            ("struct ", mono, kw), ("ContentView", mono, ty), (": ", mono, .black), ("View", mono, ty), (" {\n    ", mono, .black),
            ("@State private var ", mono, kw), ("count = ", mono, .black), ("0", mono, kw), ("\n\n    ", mono, .black),
            ("var ", mono, kw), ("body: ", mono, .black), ("some ", mono, kw), ("View", mono, ty), (" {\n        ", mono, .black),
            ("Button", mono, ty), ("(", mono, .black), ("\"Tapped \\(count) times\"", mono, st), (") {\n            count += ", mono, .black),
            ("1", mono, kw), ("\n        }\n        .buttonStyle(.borderedProminent)\n    }\n}", mono, .black),
        ])
        let sonoma = try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic"))
        let smallIcon: Data? = {   // a small 220×140 crop, to check it's shown whole
            let image = NSImage(size: NSSize(width: 220, height: 140), flipped: false) { rect in
                NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 35)
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 60, dy: 40), xRadius: 12, yRadius: 12).fill()
                return true
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform.identity]) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: 220, height: 140)
            return rep.representation(using: .png, properties: [:])
        }()
        let repo = FileManager.default.currentDirectoryPath
        return [
            Sample(item: item(.text, text: "Lisbon trip\nFlights land Thursday 9:40…", rtf: notes, app: "com.apple.Notes", ago: 30)),
            Sample(item: item(.link, text: "https://developer.apple.com/documentation/swiftui/drag-and-drop", app: "com.google.Chrome", ago: 180)),
            Sample(item: item(.image, app: "com.apple.Photos", ago: 7200, image: sonoma)),
            Sample(item: item(.text, text: "Can you send me the deck before the 3pm sync? Want to go over the pricing slide with Sam first.", app: "com.tinyspeck.slackmacgap", ago: 900)),
            Sample(item: item(.text, text: "Running 5 min late!", app: "com.apple.MobileSMS", ago: 3600 * 5)),
            Sample(item: item(.text, text: String(repeating: "x", count: 212), rtf: code, app: "com.apple.dt.Xcode", ago: 86400)),
            Sample(item: item(.text, text: "    $ git log --oneline | head -3\n    2c29203 feat: auto-paste into the active app\n    d8169be feat: add Liquid Glass panel background\n    2c63aaf Readme change", app: "com.apple.Terminal", ago: 600)),
            Sample(item: item(.file, app: "com.apple.finder", ago: 86400 * 3, files: ["\(repo)/README.md", "\(repo)/Package.swift", "\(repo)/build.sh"])),
            Sample(item: item(.image, app: "com.apple.Preview", ago: 86400 * 9, image: smallIcon)),
            Sample(item: item(.text, text: "Hi Marc,\n\nThanks for the quick turnaround on the proposal. The team reviewed it this morning and we're aligned on scope and timeline. Two small things before we sign: could you split the onboarding fee into two milestones, and confirm the support hours are in our time zone? Once that's in, I'll get it over to legal the same day.\n\nBest,\nJordan", app: "com.apple.mail", ago: 86400 * 14)),
            Sample(item: item(.link, text: "https://www.notion.so/team/Q3-Roadmap-8f2a91c4", app: "com.apple.Safari", ago: 3600 * 26)),
            Sample(item: item(.text, text: "You are a senior editor. Rewrite the text below so it's half as long, keeps every fact, and reads like a person wrote it.", app: "com.conductor.app", ago: 3600 * 50), board: Color(hex: "#FF8A3D")),
        ]
    }
}
#endif
