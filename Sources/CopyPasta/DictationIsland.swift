import AppKit
import SwiftUI

// Dictation's overlay, picked from the design variants (Nov 2026): the Island, a black
// capsule that hangs from the top-center of the screen (from the notch, on a MacBook) and
// grows to fit what it has to say. It keeps every control SuperSamuel's window had: stop,
// add a screenshot as context, retry or trash a failed recording, and the full transcript
// (click the words to open it).

/// Everything the Island shows, as plain values (the dictation engine's state maps to it).
struct DictationIslandState: Equatable {
    enum Phase: Equatable { case ready, recording, transcribing, failed }

    var phase: Phase = .ready
    var elapsed: TimeInterval = 0
    /// Recent mic levels, 0…1, newest last.
    var levels: [CGFloat] = []
    /// Live transcript while recording; the result or a message otherwise.
    var transcript: String = ""
    /// One line under the transcript: a capture or screenshot status, a limit notice.
    var note: String?
    /// "Cleaning up transcript…" and friends.
    var processingMessage: String?
    var errorMessage: String?
    var showsRecoveryActions = false
    var screenshot: NSImage?
    var screenshotSource: String?
    var isCapturingScreenshot = false
    /// The app the words go into.
    var targetIcon: NSImage?

    static func == (a: Self, b: Self) -> Bool {
        a.phase == b.phase && a.elapsed == b.elapsed && a.levels == b.levels && a.transcript == b.transcript
            && a.note == b.note && a.processingMessage == b.processingMessage && a.errorMessage == b.errorMessage
            && a.showsRecoveryActions == b.showsRecoveryActions && (a.screenshot === b.screenshot)
            && a.screenshotSource == b.screenshotSource && a.isCapturingScreenshot == b.isCapturingScreenshot
            && a.targetIcon === b.targetIcon
    }
}

struct DictationIslandActions {
    var stop: () -> Void = {}
    var attachScreenshot: () -> Void = {}
    var clearScreenshot: () -> Void = {}
    var retry: () -> Void = {}
    var delete: () -> Void = {}
}

struct DictationIslandView: View {
    let state: DictationIslandState
    var actions = DictationIslandActions()
    /// Full transcript open (a click on the words toggles it).
    @Binding var expanded: Bool
    /// On a screen with a camera notch: its height. The Island grows out of the notch,
    /// flush with the top edge, its content below it. Nil on screens without one: the
    /// Island floats as a pill just below the menu bar instead (hanging over the menu
    /// bar there looked like a stray black block).
    var notchHeight: CGFloat? = nil

    private static let recRed = Color(red: 1, green: 0.27, blue: 0.23)
    private static let levelOrange = Color(red: 1, green: 0.62, blue: 0.04)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow.frame(height: 40)
            if showsTranscript { transcriptArea }
            if let note = state.note, state.phase != .failed {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .padding(.bottom, 10)
            }
            if state.phase == .failed { failure }
        }
        .padding(.horizontal, 16 + (notchHeight == nil ? 0 : IslandShape.ear))
        .padding(.top, notchHeight ?? 0)
        .frame(width: width + (notchHeight == nil ? 0 : 2 * IslandShape.ear), alignment: .leading)
        // With a notch: flush with the top of the screen, joined to it by two small curved
        // "ears", so it reads as the notch itself growing down (and is black like it).
        .background {
            if notchHeight == nil {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black)
            } else {
                IslandShape().fill(.black)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .foregroundStyle(.white)
        .animation(.spring(duration: 0.42, bounce: 0.18), value: state.phase)
        .animation(.spring(duration: 0.42, bounce: 0.18), value: showsTranscript)
        .animation(.spring(duration: 0.42, bounce: 0.18), value: expanded)
    }

    private var width: CGFloat {
        switch state.phase {
        case .recording: return 470
        case .transcribing: return 340
        case .failed: return 470
        case .ready: return 340
        }
    }

    private var showsTranscript: Bool {
        state.phase == .recording && !state.transcript.isEmpty
    }

    // MARK: Top row

    @ViewBuilder private var topRow: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .recording:
                RecordingDot()
                Text(Self.time(state.elapsed)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 8)
                Levels(levels: Array(state.levels.suffix(26)), color: Self.levelOrange)
                screenshotControl
                if let icon = state.targetIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22)
                }
                RoundButton(symbol: "stop.fill", help: "Finish (\(AppSettings.shared.shortcut(.dictation).glyphs))", tint: Self.recRed, action: actions.stop)
            case .transcribing:
                Spinner(size: 14)
                Text(state.processingMessage ?? "Transcribing…").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark", help: "Cancel", action: actions.stop)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                Text("Dictation needs attention").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark", help: "Dismiss", action: actions.stop)
            case .ready:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
                Text(state.note ?? "Transcript saved").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark", help: "Dismiss", action: actions.stop)
            }
        }
    }

    /// "Add the screen as context" while recording; once attached, its thumbnail (click
    /// it to remove it).
    @ViewBuilder private var screenshotControl: some View {
        if let shot = state.screenshot {
            Button(action: actions.clearScreenshot) {
                Image(nsImage: shot).resizable().scaledToFill().frame(width: 30, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .help("Context attached\(state.screenshotSource.map { " · \($0)" } ?? "") (click to remove)")
        } else if state.isCapturingScreenshot {
            Spinner(size: 13)
        } else {
            RoundButton(symbol: "camera.viewfinder", help: "Add the screen as context", action: actions.attachScreenshot)
        }
    }

    // MARK: Transcript

    private var transcriptArea: some View {
        Group {
            if expanded {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(state.transcript).id("end")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: state.transcript) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else {
                // The last lines, fading out at the top as older words move up. (Full height,
                // then clipped from the top: a height-limited Text would cut the newest words.)
                Text(state.transcript)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: 58, alignment: .bottomLeading)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.38)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
        .font(.system(size: 13.5))
        .lineSpacing(2)
        .foregroundStyle(.white.opacity(0.92))
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .help(expanded ? "Click to show the last lines" : "Click to show the whole transcript")
    }

    // MARK: Failure

    private var failure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.errorMessage ?? state.transcript)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
            if state.showsRecoveryActions {
                HStack(spacing: 8) {
                    PillButton(title: "Retry", prominent: true, action: actions.retry)
                    PillButton(title: "Trash", prominent: false, action: actions.delete)
                }
            }
        }
        .padding(.bottom, 14)
    }

    static func time(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Pieces

/// Flat top flush with the screen's edge, concave "ears" where it meets it, rounded bottom.
struct IslandShape: Shape {
    static let ear: CGFloat = 9
    var radius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let e = Self.ear, r = min(radius, (rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.minY + e), control: CGPoint(x: rect.maxX - e, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - e, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - e - r, y: rect.maxY), control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + e + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.maxY - r), control: CGPoint(x: rect.minX + e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + e, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.minX + e, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct RecordingDot: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(Color(red: 1, green: 0.27, blue: 0.23))
            .frame(width: 8, height: 8)
            .background(Circle().fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.25)).frame(width: 14, height: 14))
            .opacity(dim ? 0.4 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true } }
    }
}

private struct Levels: View {
    let levels: [CGFloat]
    let color: Color
    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(color.opacity(0.45 + 0.55 * min(1, Double(i) / Double(max(1, levels.count)) + 0.3)))
                    .frame(width: 2.5, height: max(2.5, sqrt(levels[i]) * 18))
            }
        }
        .frame(height: 18)
    }
}

private struct RoundButton: View {
    let symbol: String
    let help: String
    var tint: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct PillButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 26)
                .background(Capsule().fill(prominent ? Color.accentColor : .white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
