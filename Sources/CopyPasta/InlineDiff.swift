import AppKit
import SwiftUI

/// A typo fix drawn on the text itself, the way Grammarly marks text in other apps: the new
/// words get a green highlight where they now are, and the words taken out float just above
/// that spot, struck through in red. The text isn't touched again: macOS lets an app read
/// where each word is on screen (Accessibility), not draw into another app's text, so this is
/// a see-through window lined up over the field. Shown for 3 s, longer while the pointer is
/// over the field; any key, click or scroll takes it away (the text may have moved).
/// Where an app won't say where its words are (many web apps), the caller shows the bubble.
final class InlineDiff {
    /// One change, in the fixed text: where the new words are (`length` 0 for a pure
    /// deletion: where the old words were) and what was taken out.
    struct Change: Equatable {
        let added: NSRange
        let removed: String
    }

    fileprivate struct Mark: Identifiable {
        let id = UUID()
        var added: [CGRect] = []   // window coordinates, top-left origin
        var removed: String?
        var removedAt: CGPoint = .zero   // the label's bottom-left
        var lineHeight: CGFloat = 16
    }

    fileprivate final class Model: ObservableObject {
        @Published var marks: [Mark] = []
        @Published var visible = false
    }

    private let model = Model()
    private var window: NSPanel?
    private var fieldFrame: NSRect = .zero
    private var shownAt = Date.distantPast
    private var lastHover = Date.distantPast
    private var tick: Timer?
    private var dismissMonitor: Any?

    // MARK: Changes (no Accessibility: testable)

    /// The fixed text's changes, from the word diff. Ranges are UTF-16, as Accessibility counts.
    static func changes(before: String, after: String) -> [Change] {
        let tokens = after.components(separatedBy: " ")
        var starts: [Int] = [], offset = 0
        for token in tokens { starts.append(offset); offset += token.utf16.count + 1 }
        let end = after.utf16.count

        var out: [Change] = [], removed: [String] = [], added: [Int] = [], next = 0
        func flush() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            let range: NSRange
            if let first = added.first, let last = added.last {
                range = NSRange(location: starts[first], length: starts[last] + tokens[last].utf16.count - starts[first])
            } else {
                range = NSRange(location: next < tokens.count ? starts[next] : end, length: 0)
            }
            out.append(Change(added: range, removed: removed.joined(separator: " ")))
            removed = []; added = []
        }
        for part in WordDiff.parts(before, after) {
            switch part {
            case .same: flush(); next += 1
            case .removed(let word): removed.append(word)
            case .added: added.append(next); next += 1
            }
        }
        flush()
        return out
    }

    // MARK: Showing

    /// Lines the fix up over `field` once the app has pasted it in, and shows it. `done`
    /// gets false when the app won't say where the words are (or they aren't the fix):
    /// show the bubble instead.
    func show(before: String, after: String, in field: AXUIElement, done: @escaping (Bool) -> Void) {
        let changes = Self.changes(before: before, after: after)
        guard !changes.isEmpty else { return done(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            // The app pastes after our ⌘V lands: ask until the fixed text is in the field.
            var found: (marks: [Mark], field: NSRect, screen: NSScreen)?
            for _ in 0..<10 where found == nil {
                Thread.sleep(forTimeInterval: 0.06)
                found = Self.locate(changes, of: after, in: field)
            }
            DispatchQueue.main.async { [self] in
                guard let found else { return done(false) }
                present(found.marks, field: found.field, on: found.screen)
                done(true)
            }
        }
    }

    func dismiss() {
        tick?.invalidate(); tick = nil
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
        guard model.visible else { return }
        withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
            model.visible = false
        } completion: { [weak self] in
            guard let self, !self.model.visible else { return }
            self.window?.orderOut(nil)
        }
    }

    private func present(_ marks: [Mark], field: NSRect, on screen: NSScreen) {
        dismiss()
        let panel = window ?? Self.panel(model: model)
        window = panel
        panel.setFrame(screen.frame, display: false)
        fieldFrame = field
        model.marks = marks
        model.visible = false
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.22)) { model.visible = true }
        shownAt = Date()
        lastHover = .distantPast
        // Typing, clicking or scrolling moves the text out from under the marks.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            self?.dismiss()
        }
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.check() }
    }

    /// 3 s at least; while the pointer is over the field, for as long as it stays (and a
    /// beat after it leaves); never more than 20 s.
    private func check() {
        let now = Date()
        if fieldFrame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation) { lastHover = now }
        let age = now.timeIntervalSince(shownAt)
        if age > 20 || (age > 3 && now.timeIntervalSince(lastHover) > 1.2) { dismiss() }
    }

    private static func panel(model: Model) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: Marks(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    // MARK: Where the words are (Accessibility, off the main thread)

    /// The marks for `changes`, if the field now holds `fixed` right before its caret
    /// (just pasted) and says where its words are.
    private static func locate(_ changes: [Change], of fixed: String, in field: AXUIElement) -> (marks: [Mark], field: NSRect, screen: NSScreen)? {
        guard let caret = AX.range(field, kAXSelectedTextRangeAttribute), caret.length == 0 else { return nil }
        let length = fixed.utf16.count
        let start = caret.location - length
        guard start >= 0,
              let inField = AX.string(field, NSRange(location: start, length: length)),
              normalized(inField) == normalized(fixed) else { return nil }

        var screenRects: [[NSRect]] = [], anchors: [NSRect?] = []
        for change in changes {
            // A word broken over two lines has one box per line: ask line by line.
            let pieces = lines(of: change.added, in: fixed)
            let rects = pieces.compactMap { AX.bounds(field, NSRange(location: start + $0.location, length: $0.length)) }
            if !pieces.isEmpty, rects.count != pieces.count { return nil }
            screenRects.append(rects)
            // A pure deletion: the old words float over the character before the gap.
            let at = change.added.location
            anchors.append(rects.first ?? (at > 0 ? AX.bounds(field, NSRange(location: start + at - 1, length: 1)) : nil)
                ?? AX.bounds(field, NSRange(location: start + at, length: 1)))
        }
        guard let fieldFrame = AX.frame(field) ?? screenRects.flatMap({ $0 }).first,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(fieldFrame) }) ?? NSScreen.main else { return nil }

        let top = screen.frame.maxY, left = screen.frame.minX
        func local(_ r: NSRect) -> CGRect { CGRect(x: r.minX - left, y: top - r.maxY, width: r.width, height: r.height) }
        var marks: [Mark] = []
        for (i, change) in changes.enumerated() {
            var mark = Mark()
            mark.added = screenRects[i].map(local)
            if !change.removed.isEmpty, let anchor = anchors[i] {
                let box = local(anchor)
                mark.removed = change.removed
                // Over the start of the new words; after the character before a deletion.
                mark.removedAt = CGPoint(x: change.added.length == 0 && change.added.location > 0 ? box.maxX : box.minX, y: box.minY)
                mark.lineHeight = box.height
            }
            if !mark.added.isEmpty || mark.removed != nil { marks.append(mark) }
        }
        return marks.isEmpty ? nil : (marks, fieldFrame, screen)
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// `range` of `text`, cut at line breaks (empty pieces dropped).
    static func lines(of range: NSRange, in text: String) -> [NSRange] {
        guard range.length > 0 else { return [] }
        let ns = text as NSString
        var out: [NSRange] = [], start = range.location
        for i in range.location..<NSMaxRange(range) where ns.character(at: i) == 10 || ns.character(at: i) == 13 {
            if i > start { out.append(NSRange(location: start, length: i - start)) }
            start = i + 1
        }
        if NSMaxRange(range) > start { out.append(NSRange(location: start, length: NSMaxRange(range) - start)) }
        return out
    }

    // MARK: Drawing

    private struct Marks: View {
        @ObservedObject var model: Model
        private let green = Color(red: 0.19, green: 0.82, blue: 0.35)
        private let red = Color(red: 1, green: 0.42, blue: 0.4)

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(model.marks) { mark in
                    ForEach(Array(mark.added.enumerated()), id: \.offset) { _, rect in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(green.opacity(0.2))
                            .overlay(alignment: .bottom) {
                                Capsule().fill(green).frame(height: 2)
                                    .scaleEffect(x: model.visible ? 1 : 0, anchor: .leading)   // drawn in, left to right
                            }
                            .frame(width: rect.width + 4, height: rect.height + 2)
                            .offset(x: rect.minX - 2, y: rect.minY - 1)
                    }
                    if let removed = mark.removed {
                        let size = min(max(mark.lineHeight * 0.62, 10), 14)
                        Text(removed)
                            .font(.system(size: size, weight: .medium))
                            .strikethrough(color: red)
                            .foregroundStyle(red)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color(white: 0.11).opacity(0.92)))
                            .overlay(Capsule().strokeBorder(red.opacity(0.35), lineWidth: 0.5))
                            .fixedSize()
                            // Sits on the line's top edge: a zero-height frame its bottom hangs from.
                            // (An alignment guide here moved every other mark down with it.)
                            .frame(height: 0, alignment: .bottomLeading)
                            .offset(x: mark.removedAt.x - 3, y: mark.removedAt.y - 1 + (model.visible ? 0 : 3))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(model.visible ? 1 : 0)
        }
    }
}

/// The few Accessibility questions InlineDiff asks, with the answers in AppKit's terms.
private enum AX {
    static func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? NSRange(location: range.location, length: range.length) : nil
    }

    static func string(_ element: AXUIElement, _ range: NSRange) -> String? {
        var value: CFTypeRef?
        guard let parameter = axRange(range),
              AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success else { return nil }
        return value as? String
    }

    /// On screen, AppKit coordinates. Nil for an empty or implausible box.
    static func bounds(_ element: AXUIElement, _ range: NSRange) -> NSRect? {
        var value: CFTypeRef?
        guard let parameter = axRange(range),
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let rect = cgRect(value), rect.width > 0, rect.height > 0, rect.height < 200 else { return nil }
        return flipped(rect)
    }

    static func frame(_ element: AXUIElement) -> NSRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0 else { return nil }
        return flipped(CGRect(origin: origin, size: extent))
    }

    private static func axRange(_ range: NSRange) -> AXValue? {
        var cf = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cf)
    }

    private static func cgRect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// Accessibility uses top-left screen coordinates; AppKit, bottom-left.
    private static func flipped(_ rect: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

#if DEBUG
extension InlineDiff {
    /// For `--render-tricks`: a one-line text field holding `fixed`, with the marks a fix from
    /// `before` gets, word boxes measured with the field's font (no Accessibility offscreen).
    static func preview(before: String, fixed: String, light: Bool) -> some View {
        let font = NSFont.systemFont(ofSize: 14)
        let inset = CGPoint(x: 14, y: 30)   // the text's top-left in the preview
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let ns = fixed as NSString
        var marks: [Mark] = []
        for change in changes(before: before, after: fixed) {
            var mark = Mark()
            let x = inset.x + width(ns.substring(to: change.added.location))
            if change.added.length > 0 {
                mark.added = [CGRect(x: x, y: inset.y, width: width(ns.substring(with: change.added)), height: lineHeight)]
            }
            if !change.removed.isEmpty {
                mark.removed = change.removed
                mark.removedAt = CGPoint(x: change.added.length == 0 ? x - width(" ") : x, y: inset.y)
                mark.lineHeight = lineHeight
            }
            marks.append(mark)
        }
        let model = Model()
        model.marks = marks
        model.visible = true
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(light ? Color.white : Color(white: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(light ? Color.black.opacity(0.12) : .white.opacity(0.12)))
            Text(fixed).font(Font(font)).foregroundStyle(light ? Color.black : .white)
                .fixedSize().offset(x: inset.x, y: inset.y)
            Marks(model: model)
        }
        .frame(width: inset.x * 2 + width(fixed), height: 70)
    }
}
#endif
