import AppKit
import SwiftUI

// Copy Tricks speak "at the caret" (picked from the design variants, Nov 2026): a bubble
// pinned to the selection, with a word diff for typo fixes. It never takes focus or clicks.

/// What a Copy Trick has to say.
enum TrickStatus: Equatable {
    case working(CopyTricks.Trick, CopyTricks.Language?)
    case done(CopyTricks.Trick, CopyTricks.Language?, before: String, after: String, replaced: Bool)
    case failed(String)

    var title: String {
        switch self {
        case .working(.translate, let to): return to.map { "Translating to \($0.rawValue)…" } ?? "Translating…"
        case .working(.fixTypos, _): return "Fixing typos…"
        case .done(.translate, let to, _, _, _): return "Translated to \(to?.rawValue ?? "English")"
        case .done(.fixTypos, _, let before, let after, _): return before == after ? "No typos found" : "Typos fixed"
        case .failed(let message): return message
        }
    }

    /// "⌘Z to undo" once the selection was replaced; "On the clipboard" when it couldn't be.
    var hint: String? {
        guard case .done(_, _, let before, let after, let replaced) = self, before != after else { return nil }
        return replaced ? "⌘Z to undo" : "On the clipboard"
    }

    /// Typo fixes show what changed.
    var diff: (before: String, after: String)? {
        guard case .done(.fixTypos, _, let before, let after, _) = self, before != after else { return nil }
        return (before, after)
    }

    var isWorking: Bool { if case .working = self { return true }; return false }
    var isFailure: Bool { if case .failed = self { return true }; return false }
}

// MARK: - Word diff

/// Word-level diff by longest common subsequence, so an added or dropped word doesn't
/// shift every word after it into a "change".
enum WordDiff {
    enum Part: Equatable { case same(String), removed(String), added(String) }

    static func parts(_ before: String, _ after: String) -> [Part] {
        let a = before.components(separatedBy: " "), b = after.components(separatedBy: " ")
        // ponytail: O(n·m) table; past ~250×250 words, fall back to "all of it changed".
        guard a.count * b.count <= 62_500 else { return [.removed(before), .added(after)] }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Part] = [], i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { out.append(.removed(a[i])); i += 1 }
            else { out.append(.added(b[j])); j += 1 }
        }
        out += a[i...].map(Part.removed) + b[j...].map(Part.added)
        return out
    }

    /// Short texts: the whole text, changes struck and highlighted inline. Long ones: just
    /// the changes, "old → new", so the bubble stays small.
    static func attributed(_ before: String, _ after: String, font: Font = .system(size: 12.5)) -> AttributedString {
        let parts = parts(before, after)
        let struck = Color(red: 1, green: 0.41, blue: 0.38)
        let added = Color(red: 0.19, green: 0.82, blue: 0.35)
        var out = AttributedString()
        func piece(_ text: String, _ kind: Part) -> AttributedString {
            var s = AttributedString(text)
            s.font = font
            switch kind {
            case .same: s.foregroundColor = Color(white: 0.7)
            case .removed: s.foregroundColor = struck; s.strikethroughStyle = .single
            case .added: s.foregroundColor = added; s.font = font.weight(.semibold)
            }
            return s
        }
        if before.count <= 220 {
            for (n, part) in parts.enumerated() {
                if n > 0 { out += AttributedString(" ") }
                switch part {
                case .same(let w): out += piece(w, part)
                case .removed(let w): out += piece(w, part)
                case .added(let w): out += piece(w, part)
                }
            }
            return out
        }
        var pairs: [(String, String)] = [], old: [String] = [], new: [String] = []
        func flush() { if !old.isEmpty || !new.isEmpty { pairs.append((old.joined(separator: " "), new.joined(separator: " "))) }; old = []; new = [] }
        for part in parts {
            switch part {
            case .same: flush()
            case .removed(let w): old.append(w)
            case .added(let w): new.append(w)
            }
        }
        flush()
        for (n, pair) in pairs.prefix(4).enumerated() {
            if n > 0 { out += AttributedString("   ") }
            if !pair.0.isEmpty { out += piece(pair.0, .removed("")) }
            if !pair.0.isEmpty, !pair.1.isEmpty { out += piece(" → ", .same("")) }
            if !pair.1.isEmpty { out += piece(pair.1, .added("")) }
        }
        if pairs.count > 4 { out += piece("   and \(pairs.count - 4) more", .same("")) }
        return out
    }
}

// MARK: - Where the selection is

enum SelectionLocator {
    /// Each Accessibility question waits at most this long (the default is 6 seconds,
    /// and a web-based app building its accessibility tree can take that long).
    private static let timeout: Float = 0.5

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// Apps that don't report a focused element count as unchanged (callers also check the app).
    static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return CFEqual(a, b)
    }

    /// The selected text's rectangle on screen (AppKit coordinates), or the text field's
    /// when the app won't say where the selection is. Nil when neither is known, or the
    /// "field" is a whole page: no caret to point at.
    static func selectionRect(in element: AXUIElement?) -> NSRect? {
        guard let element else { return nil }
        var range: CFTypeRef?, bounds: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let range,
           AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                      range, &bounds) == .success,
           let rect = cgRect(bounds), rect.height > 0, rect.height < 600 {
            return flipped(rect)
        }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let origin = cgPoint(position), let extent = cgSize(size), extent.height > 0, extent.height < 200
        else { return nil }
        return flipped(CGRect(origin: origin, size: extent))
    }

    private static func cgRect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }
    private static func cgPoint(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }
    private static func cgSize(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Accessibility uses top-left screen coordinates; AppKit, bottom-left.
    private static func flipped(_ rect: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Overlay host

/// Shows a Copy Trick's status at the selection, or in the Island when there's no
/// selection rectangle. One status at a time; it hides itself after reading time.
final class TrickOverlay {
    fileprivate final class Model: ObservableObject {
        @Published var status: TrickStatus = .failed("")
        @Published var visible = false
        @Published var below = false   // bubble under the selection (no room above)
    }

    private let model = Model()
    private var hideWork: DispatchWorkItem?
    private lazy var bubblePanel = Self.panel(size: Self.bubbleSize, view: CaretBubble(model: model))
    private var current: NSPanel?
    /// Where this trick's bubble went, so its later states stay put.
    private var pointerAnchor: NSRect?

    private static func pointerRect() -> NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x - 8, y: p.y - 2, width: 1, height: 16)
    }

    private static let bubbleSize = NSSize(width: 480, height: 230)
    /// Room around the bubble for its shadow, inside the panel.
    static let shadowPad: CGFloat = 24

    /// `anchor`: the selection's rectangle, captured when the trick started. Without one
    /// (the app won't say where its text is), the bubble points at the mouse pointer,
    /// which is usually where the text was just selected.
    func show(_ status: TrickStatus, at anchor: NSRect?) {
        let anchor = anchor ?? pointerAnchor ?? Self.pointerRect()
        if status.isWorking || current == nil { pointerAnchor = anchor }
        let panel = bubblePanel
        if current !== panel {
            current?.orderOut(nil)
            current = panel
            place(panel, anchor: anchor)
            panel.orderFrontRegardless()
        }
        model.status = status
        withAnimation(.spring(duration: 0.32, bounce: 0)) { model.visible = true }
        hideWork?.cancel()
        guard !status.isWorking else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        let reading = status.diff != nil ? 4.0 : status.isFailure ? 3.2 : 2.2
        DispatchQueue.main.asyncAfter(deadline: .now() + reading, execute: work)
    }

    /// Away now (the fix is being shown on the text instead).
    func dismiss() {
        hideWork?.cancel()
        hide()
    }

    private func hide() {
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16), completionCriteria: .logicallyComplete) {
            model.visible = false
        } completion: { [weak self] in
            guard let self, !self.model.visible else { return }
            self.current?.orderOut(nil)
            self.current = nil
            self.pointerAnchor = nil
        }
    }

    private func place(_ panel: NSPanel, anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        // Above the selection, tail pointing at its start; below it when there's no room.
        let size = Self.bubbleSize, pad = Self.shadowPad
        let x = min(max(anchor.minX - 4 - pad, frame.minX), frame.maxX - size.width)
        let roomAbove = frame.maxY - 30 - (anchor.maxY + 10)
        model.below = roomAbove < 140
        let y = model.below ? anchor.minY - 10 - size.height + pad : anchor.maxY + 10 - pad
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func panel<V: View>(size: NSSize, view: V) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    // MARK: Views

    /// The "at the caret" bubble: status line, hint, and the diff for typo fixes.
    struct CaretBubble: View {
        @ObservedObject fileprivate var model: Model

        var body: some View {
            CaretBubbleContent(status: model.status, below: model.below)
                .scaleEffect(model.visible ? 1 : 0.97, anchor: model.below ? .topLeading : .bottomLeading)
                .offset(y: model.visible ? 0 : (model.below ? -6 : 6))
                .opacity(model.visible ? 1 : 0)
                .padding(TrickOverlay.shadowPad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.below ? .topLeading : .bottomLeading)
        }
    }
}

struct CaretBubbleContent: View {
    let status: TrickStatus
    var below = false
    private let fill = Color(red: 0.141, green: 0.141, blue: 0.149).opacity(0.97)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusGlyph(status: status, size: 14)
                Text(status.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if let hint = status.hint {
                    Spacer(minLength: 12)
                    Text(hint).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                }
            }
            if let diff = status.diff {
                Text(WordDiff.attributed(diff.before, diff.after, font: .system(size: 12)))
                    .lineSpacing(2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(CappedWidth(maxWidth: 440))
        .background {
            // Bubble and pointer as one outline, so the hairline runs around both.
            BubbleShape(pointerDown: !below).fill(fill)
                .overlay(BubbleShape(pointerDown: !below).stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }
}

/// Its natural width up to `maxWidth`, and the height it needs at that width. (A plain
/// `.frame(maxWidth:).fixedSize()` measured the height for one unwrapped line, so a
/// diff that wrapped spilled out of the bubble at the top and bottom.)
private struct CappedWidth: ViewModifier {
    let maxWidth: CGFloat
    func body(content: Content) -> some View { CappedWidthLayout(maxWidth: maxWidth) { content } }
}

private struct CappedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, maxWidth)
        return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A rounded rectangle with a small pointer under (or over) its left end, aimed at the
/// start of the selection.
struct BubbleShape: Shape {
    var pointerDown = true
    private let radius: CGFloat = 13, pointerX: CGFloat = 16, pointerW: CGFloat = 14, pointerH: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        var pointer = Path()
        let edge = pointerDown ? rect.maxY : rect.minY
        let tip = pointerDown ? edge + pointerH : edge - pointerH
        pointer.move(to: CGPoint(x: rect.minX + pointerX, y: edge - (pointerDown ? 1 : -1)))
        pointer.addLine(to: CGPoint(x: rect.minX + pointerX + pointerW / 2, y: tip))
        pointer.addLine(to: CGPoint(x: rect.minX + pointerX + pointerW, y: edge - (pointerDown ? 1 : -1)))
        pointer.closeSubpath()
        return body.union(pointer)
    }
}

struct StatusGlyph: View {
    let status: TrickStatus
    var size: CGFloat = 15

    var body: some View {
        Group {
            switch status {
            case .working: Spinner(size: size - 1)
            case .done(_, _, let before, let after, _):
                Image(systemName: before == after ? "checkmark.circle" : "checkmark.circle.fill")
                    .font(.system(size: size, weight: .semibold)).foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: size, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }
}

/// A thin ring with a bright arc going round (a ProgressView doesn't render offscreen,
/// and this one matches the prototypes).
struct Spinner: View {
    var size: CGFloat = 14
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 2)
            Circle().trim(from: 0, to: 0.28).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}

struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.12)))
    }
}
