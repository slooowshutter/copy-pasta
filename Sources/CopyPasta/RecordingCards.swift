import SwiftUI
import AppKit

// The Recordings tab: one card per dictation. Not wired into the drawer yet; see it with
// `.build/debug/CopyPasta --render-recordings out.png` (debug builds, headless).

/// One dictation as the Recordings tab shows it. Built from a RecordingSession (unsent or
/// failed) or a Transcript History entry (done).
struct RecordingCard: Identifiable {
    enum Status { case recording, transcribing, transcribed, notSent, failed }

    var id = UUID()
    let createdAt: Date
    var status: Status
    var duration: TimeInterval
    /// The transcript; before it exists (recording, transcribing, failed), the live draft.
    var text: String?
    /// What went wrong (the session's lastError), or what it's doing now.
    var message: String?
    /// Size of the saved audio. 0: nothing usable was recorded.
    var audioBytes: Int64
    /// App whose screen was attached as context.
    var screenSource: String?
    var inputDevice: String?
    var keyMissing = false
    var levels: [CGFloat] = []
    /// In Transcript History (done), rather than in Recordings.
    var archived = false

    var words: Int { text?.split(whereSeparator: \.isWhitespace).count ?? 0 }
    var needsAttention: Bool { status == .failed || status == .notSent }

    /// The way out of a failed or unsent recording: its button, and what ⏎ does.
    var primary: (label: String, icon: String, action: RecordingAction)? {
        guard needsAttention else { return nil }
        if status == .notSent { return ("Send Anyway", "arrow.up", .send) }
        if keyMissing { return ("Add Key…", "key.fill", .addKey) }
        if audioBytes > 0 { return ("Retry", "arrow.clockwise", .retry) }
        if words > 0 { return ("Copy Draft", "doc.on.doc", .copyDraft) }
        return nil
    }
}

enum RecordingAction { case copy, duplicate, play, retry, send, addKey, copyDraft, reveal, trash }

/// The recording that's playing: where it's got to and how long it is, and a way to jump.
/// Its own object, so only the playing card redraws as the time moves.
final class Playback: ObservableObject {
    @Published var time: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    var seek: (TimeInterval) -> Void = { _ in }
}

struct RecordingCardView: View {
    let card: RecordingCard
    let selected: Bool
    /// Set while its audio plays.
    var playback: Playback? = nil
    var perform: (RecordingAction) -> Void = { _ in }
    @State private var hovering = false

    private static let width = CardView.width, height = CardView.height, headerHeight = CardView.headerHeight
    private static let radius: CGFloat = 13
    private static var bodyHeight: CGFloat { height - headerHeight }
    private static let ink = Color(nsColor: CardView.ink)
    private static let surface = CardView.surface

    var body: some View {
        VStack(spacing: 0) {
            header
            content.frame(width: Self.width, height: Self.bodyHeight).clipped()
        }
        .overlay(alignment: .top) {
            if let playback {   // on the seam between header and text
                PlaybackScrubber(playback: playback).offset(y: Self.headerHeight - PlaybackScrubber.hitHeight / 2)
            }
        }
        .background(Self.surface)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .opacity(selected ? 1 : 0))
        .onHover { hovering = $0 }
    }

    // MARK: Header: the status, colored, with its glyph cropped into the corner

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if card.status == .recording { PulsingDot() }
                Text(title).font(.system(size: 13.5, weight: .semibold))
            }
            Group {
                if let playback {
                    PlaybackClock(age: age, playback: playback)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(subtitle) }   // the live clock ticks
                }
            }
            .font(.system(size: 11)).monospacedDigit().opacity(0.8)
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 56)
        .frame(width: Self.width, height: Self.headerHeight, alignment: .leading)
        .background(tint)
        .overlay(alignment: .topTrailing) {
            if card.status == .recording {
                HeaderWaveform(levels: card.levels).padding(.trailing, 12)
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.22))
                    .offset(x: 10, y: -4)
            }
        }
        .overlay(alignment: .bottom) {
            if card.status == .transcribing { IndeterminateBar() }
        }
        .clipped()
    }

    private var title: String {
        switch card.status {
        case .recording: "Recording"
        case .transcribing: "Transcribing…"
        case .transcribed: "Transcript"
        case .notSent: "Not sent"
        case .failed: "Failed"
        }
    }

    private var subtitle: String {
        if card.status == .recording { return Self.clock(Date().timeIntervalSince(card.createdAt)) }
        return card.duration > 0 ? "\(age) · \(Self.clock(card.duration))" : age
    }

    private var age: String {
        Date().timeIntervalSince(card.createdAt) < 60
            ? "just now" : Self.relative.localizedString(for: card.createdAt, relativeTo: Date())
    }

    private var tint: Color {
        switch card.status {
        case .recording: Color(white: 0.24)
        case .transcribing, .transcribed: Color(hex: "#6E56CF")
        case .notSent: Color(hex: "#D98A1F")
        case .failed: Color(hex: "#DC3E42")
        }
    }

    private var glyph: String {
        switch card.status {
        case .recording: "mic.fill"
        case .transcribing, .transcribed: "waveform"
        case .notSent: "paperplane.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch card.status {
        case .recording: recordingContent
        case .transcribing: transcribingContent
        case .transcribed: transcriptContent
        case .notSent, .failed: problemContent
        }
    }

    private var transcriptContent: some View {
        ScrollingText(text: card.text ?? "", color: Self.ink)
            .overlay(alignment: .bottom) {
                // Selected or under the pointer: the actions take the footer's place.
                if selected || hovering || playback != nil {   // playing: Stop stays in reach
                    HStack(spacing: 6) {
                        CardButton(label: "Copy", icon: "doc.on.doc", prominent: true) { perform(.copy) }
                        if card.audioBytes > 0 { playButton(labeled: true) }
                    }
                    .padding(EdgeInsets(top: 30, leading: 10, bottom: 10, trailing: 10))
                    .background(fade)
                } else {
                    footer {
                        Text(card.screenSource.map { "\(card.words) words · \($0) context" } ?? "\(card.words) words")
                    }
                }
            }
    }

    private var transcribingContent: some View {
        ScrollingText(text: card.text ?? "", color: Self.ink.opacity(0.45), followsEnd: true)
            .overlay(alignment: .bottom) {
                footer {
                    HStack(spacing: 6) {
                        ArcSpinner()
                        Text(card.message ?? "Transcribing…")
                    }
                }
            }
    }

    /// The words as they're recognized, following the newest (scroll up to read back).
    @ViewBuilder
    private var recordingContent: some View {
        Group {
            if let text = card.text, !text.isEmpty {
                ScrollingText(text: text, color: Self.ink.opacity(0.85), followsEnd: true)
            } else {
                Text("Listening…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Self.ink.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottom) {
            footer { Text("\(HotkeyService.glyphs) to stop") }
        }
    }

    /// Failed or unsent: what went wrong, what was kept, what's missing, and the way out.
    private var problemContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.message ?? "Something went wrong.")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Self.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(checks.prefix(3), id: \.label) { CheckRow(check: $0) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let primary = card.primary {
                    CardButton(label: primary.label, icon: primary.icon, prominent: true) { perform(primary.action) }
                }
                if card.audioBytes > 0 { playButton(labeled: false) }
                CardButton(icon: "trash", help: "Move to Trash") { perform(.trash) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var checks: [Check] {
        var list: [Check] = []
        list.append(card.audioBytes > 0
            ? Check(state: .ok, label: "Audio saved", detail: "\(Self.clock(card.duration)) · \(Self.size(card.audioBytes))")
            : Check(state: .missing, label: "No audio", detail: card.inputDevice ?? "0 KB"))
        if card.keyMissing { list.append(Check(state: .missing, label: "OpenRouter key", detail: "missing")) }
        if card.words > 0 {
            list.append(Check(state: .partial, label: "Live draft", detail: "\(card.words) words"))
        } else {
            list.append(Check(state: card.status == .notSent ? .waiting : .missing, label: "Transcript",
                              detail: card.status == .notSent ? "not sent" : "not received"))
        }
        if let source = card.screenSource { list.append(Check(state: .ok, label: "Screen context", detail: source)) }
        return list
    }

    /// Play ↔ Stop (Space does the same on the selected card).
    private func playButton(labeled: Bool) -> some View {
        let playing = playback != nil
        return CardButton(label: labeled ? (playing ? "Stop" : "Play") : nil, icon: playing ? "stop.fill" : "play.fill",
                          help: playing ? "Stop" : "Play the recording") { perform(.play) }
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: Self.surface.opacity(0), location: 0),
                               .init(color: Self.surface, location: 0.55)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func footer(@ViewBuilder _ label: () -> some View) -> some View {
        label()
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .background(fade)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

/// The recording in progress, fed live by dictation while the panel is open: the
/// waveform moves, words come in as they're recognized, then "Cleaning up…".
struct LiveRecordingCard: View {
    let card: RecordingCard
    @ObservedObject var live: AppState
    let selected: Bool

    var body: some View {
        var card = card
        if card.status == .recording {
            card.levels = Array(live.waveformSamples.suffix(34))
            if !live.transcriptIsProgress { card.text = live.transcriptText }
        } else {
            if let message = live.processingStatusMessage { card.message = message }
            if !live.transcriptIsProgress { card.text = live.transcriptText }
        }
        return RecordingCardView(card: card, selected: selected)
    }
}

// MARK: - Pieces

private struct Check {
    enum State { case ok, missing, partial, waiting }
    let state: State
    let label: String
    let detail: String
}

private struct CheckRow: View {
    let check: Check

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(check.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(check.state == .ok ? 0.85 : 0.95))
            Spacer(minLength: 6)
            Text(check.detail)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(check.state == .missing ? color.opacity(0.95) : .white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var symbol: String {
        switch check.state {
        case .ok: "checkmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .waiting: "circle.dashed"
        }
    }

    private var color: Color {
        switch check.state {
        case .ok: Color(hex: "#46C46F")
        case .missing: Color(hex: "#FF6B6B")
        case .partial: Color(hex: "#F5B544")
        case .waiting: .white.opacity(0.4)
        }
    }
}

/// A card's button: a label (stretches) or just an icon (square).
private struct CardButton: View {
    var label: String? = nil
    let icon: String
    var prominent = false
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                if let label { Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .frame(maxWidth: label == nil ? nil : .infinity)
            .frame(width: label == nil ? 30 : nil, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? AnyShapeStyle(.white.opacity(0.92)) : AnyShapeStyle(.white.opacity(0.11))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label ?? "")
    }
}

/// A card's text, scrollable with the mouse or trackpad when it's longer than the card.
/// `followsEnd`: keeps the newest words in view as they come in (live, transcribing).
private struct ScrollingText: View {
    let text: String
    let color: Color
    var followsEnd = false

    var body: some View {
        OverflowScroll(following: followsEnd ? text : nil) {
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(2.5)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 36, trailing: 12))   // clear of the footer
        }
    }
}

/// A card's content, scrollable with the mouse or trackpad when it's taller than the
/// card. Content that fits gets no scroll area: one under every card could catch the
/// sideways swipes that scroll the strip of cards. `following`: as it changes, the end
/// stays in view (live words).
struct OverflowScroll<Content: View>: View {
    var following: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.frame(maxHeight: .infinity, alignment: .top)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        content
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                }
                .scrollIndicators(.never)
                .onAppear { if following != nil { proxy.scrollTo(Self.end, anchor: .bottom) } }
                .onChange(of: following) {
                    guard following != nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
    }

    private static var end: String { "end" }
}

/// The microphone's level, live, where the other cards have their glyph.
private struct HeaderWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.suffix(12).enumerated()), id: \.offset) { i, level in
                Capsule()
                    .fill(.white.opacity(0.3 + 0.5 * Double(i) / 11))
                    .frame(width: 3, height: max(4, sqrt(level) * 34))   // sqrt, like the Island: speech is quiet
            }
        }
        .frame(height: Self.height)
        .animation(.easeOut(duration: 0.1), value: levels)
    }

    private static let height: CGFloat = 50
}

private struct PulsingDot: View {
    var body: some View {
        TimelineView(.animation) { t in
            let phase = (sin(t.date.timeIntervalSinceReferenceDate * 3.4) + 1) / 2
            Circle().fill(Color(hex: "#FF453A")).frame(width: 8, height: 8).opacity(0.55 + 0.45 * phase)
        }
        .frame(width: 8, height: 8)
    }
}

private struct ArcSpinner: View {
    var body: some View {
        TimelineView(.animation) { t in
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 10, height: 10)
    }
}

/// Where playback has got, along the header's bottom edge. Point at it and it thickens
/// and shows a knob: click or drag anywhere on it to jump there.
private struct PlaybackScrubber: View {
    @ObservedObject var playback: Playback
    @State private var hovering = false
    @State private var dragging = false
    static let hitHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = playback.duration > 0 ? min(1, max(0, playback.time / playback.duration)) : 0
            let active = hovering || dragging
            let thickness: CGFloat = active ? 5 : 2.5
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.22)).frame(height: thickness)
                Rectangle().fill(.white.opacity(0.95)).frame(width: width * progress, height: thickness)
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: min(max(0, width * progress - 5.5), width - 11))
                    .opacity(active ? 1 : 0)
            }
            .frame(width: width, height: Self.hitHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    let time = min(1, max(0, drag.location.x / max(width, 1))) * playback.duration
                    playback.time = time
                    playback.seek(time)
                }
                .onEnded { _ in dragging = false })
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: Self.hitHeight)
    }
}

/// "4 minutes ago · 0:23 / 1:05" while it plays.
private struct PlaybackClock: View {
    let age: String
    @ObservedObject var playback: Playback

    var body: some View {
        Text("\(age) · \(RecordingCardView.clock(playback.time)) / \(RecordingCardView.clock(playback.duration))")
    }
}

/// A light segment sweeping along the header's bottom edge while it transcribes.
private struct IndeterminateBar: View {
    var body: some View {
        TimelineView(.animation) { t in
            GeometryReader { geo in
                let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: geo.size.width * 0.35, height: 2.5)
                    .offset(x: (geo.size.width * 1.35) * p - geo.size.width * 0.35)
            }
        }
        .frame(height: 2.5)
        .background(.white.opacity(0.18))
    }
}

// MARK: - Tab

/// The Recordings tab: the last tab, right before +.
struct RecordingsTab: View {
    let isCurrent: Bool

    var body: some View {
        TabLabel(icon: "waveform", text: "Recordings", isCurrent: isCurrent)
    }

    static let hint = "← → navigate   ⏎ paste or retry   ␣ play   ⌘C copy   ⌘R retry   ⌘⌫ trash   esc close"
}
