import AppKit
import SwiftUI
import NaturalLanguage

/// ⌘C twice (⌘ held or not): the copied text comes back translated (French ↔ English).
/// Three times: with its typos fixed. The result goes on the clipboard (so it's in
/// history too) and replaces the selection, which is still selected after the copy;
/// ⌘Z in that app undoes it. Watching keys in other apps needs Accessibility access,
/// the same permission auto-paste uses.
final class CopyTricks {
    enum Trick { case translate, fixTypos }

    private var monitor: Any?
    private var trustPoll: Timer?
    private var taps = 0
    private var lastTap = Date.distantPast
    /// Clipboard change count seen at the first ⌘C of a run of taps: the later ones must
    /// move it, or nothing was selected (and the old clipboard must not be translated).
    private var copyCountAtFirstTap = 0
    private var decide: DispatchWorkItem?
    private var running: Task<Void, Never>?
    private let overlay = TrickOverlay()
    private let inline = InlineDiff()

    func start() {
        // A key monitor added before access is granted never fires: wait for it.
        guard Paster.isTrusted else {
            trustPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
                guard Paster.isTrusted else { return }
                timer.invalidate()
                self?.start()
            }
            return
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
    }

    /// Counts ⌘C presses less than 0.6s apart (⌘ held between them or not), and acts
    /// 0.35s after the last one: two translate, three fix typos. Any other key resets.
    private func handle(_ event: NSEvent) {
        guard event.type == .keyDown else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), mods.isDisjoint(with: [.control, .option, .shift]),
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            taps = 0
            decide?.cancel()
            return
        }
        guard !event.isARepeat else { return }
        taps = Date().timeIntervalSince(lastTap) < 0.6 ? taps + 1 : 1
        lastTap = Date()
        if taps == 1 { copyCountAtFirstTap = NSPasteboard.general.changeCount }
        decide?.cancel()
        guard taps >= 2 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = self.taps
            self.taps = 0
            let settings = AppSettings.shared
            if count >= 3, settings.fixTyposOnTripleCopy { self.perform(.fixTypos) }
            else if count == 2, settings.translateOnDoubleCopy { self.perform(.translate) }
        }
        decide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private final class Place { var field: AXUIElement?; var placed = false }

    private func perform(_ trick: Trick) {
        let started = Date()
        let app = NSWorkspace.shared.frontmostApplication
        plog("copy tricks: \(trick) in \(app?.localizedName ?? "?")")
        // Feedback at once. Where the selection is comes from the app over Accessibility,
        // which a web-based app can take seconds to answer the first time: ask off the main
        // thread, and if it hasn't answered in 0.15s the bubble opens by the pointer.
        let place = Place()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let field = SelectionLocator.focusedElement()
            let rect = SelectionLocator.selectionRect(in: field)
            DispatchQueue.main.async { [self] in
                place.field = field
                guard !place.placed else { return }
                place.placed = true
                overlay.show(.working(trick, nil), at: rect)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            guard !place.placed else { return }
            place.placed = true
            overlay.show(.working(trick, nil), at: nil)
        }

        waitForCopy(since: copyCountAtFirstTap, until: Date().addingTimeInterval(0.8)) { [self] copied in
            guard copied, let text = NSPasteboard.general.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                plog("copy tricks: nothing was copied")
                overlay.show(.failed("Select some text first"), at: nil)
                return
            }
            guard text.count <= 12_000 else {
                overlay.show(.failed("That's too long to \(trick == .translate ? "translate" : "fix") at once"), at: nil)
                return
            }
            guard let key = AppSettings.shared.openRouterKey else {
                overlay.show(.failed("Add your OpenRouter key in Settings › API Keys"), at: nil)
                return
            }
            let target = trick == .translate ? Self.translationTarget(for: text) : nil
            overlay.show(.working(trick, target), at: nil)
            running?.cancel()
            running = Task { @MainActor in
                do {
                    let asked = Date()
                    let result = try await OpenRouterRewrite.run(
                        instructions: Self.instructions(for: trick, target: target),
                        text: text, apiKey: key, model: AppSettings.shared.textModel)
                    guard !Task.isCancelled else { return }
                    let output = Self.keepingEdges(of: text, around: result)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(output, forType: .string)
                    // Replace the selection only where it was: same app, same text field.
                    let now = await Task.detached { SelectionLocator.focusedElement() }.value
                    let samePlace = NSWorkspace.shared.frontmostApplication == app
                        && (place.field == nil || SelectionLocator.same(place.field, now))
                    if samePlace, output != text { Paster.pasteIntoFrontApp() }
                    plog(String(format: "copy tricks: %d chars, model %.2fs, total %.2fs, replaced: %@",
                                text.count, Date().timeIntervalSince(asked), Date().timeIntervalSince(started),
                                samePlace ? "yes" : "no"))
                    let done = TrickStatus.done(trick, target, before: text, after: output, replaced: samePlace)
                    // A typo fix is drawn on the text itself where the app says where its words
                    // are; elsewhere (many web apps), the bubble shows the diff.
                    if trick == .fixTypos, samePlace, output != text, let field = place.field ?? now {
                        inline.show(before: text, after: output, in: field) { [self] onText in
                            plog("copy tricks: diff \(onText ? "drawn on the text" : "in the bubble")")
                            if onText { overlay.dismiss() } else { overlay.show(done, at: nil) }
                        }
                    } else {
                        overlay.show(done, at: nil)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    plog("copy tricks: failed: \(error.localizedDescription)")
                    overlay.show(.failed(error.localizedDescription), at: nil)
                }
            }
        }
    }

    /// Calls back once the app's copy has landed on the clipboard (`true`), or at the
    /// deadline if it never changed (`false`: nothing was selected).
    private func waitForCopy(since count: Int, until deadline: Date, then: @escaping (Bool) -> Void) {
        if NSPasteboard.general.changeCount != count {
            // Landed; a beat more for apps that write their flavors one by one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { then(true) }
        } else if Date() >= deadline {
            then(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                waitForCopy(since: count, until: deadline, then: then)
            }
        }
    }

    // MARK: Language

    enum Language: String { case english = "English", french = "French" }

    /// French text goes to English; anything else goes to French. Detected on the Mac,
    /// so the model is told the direction instead of guessing it.
    static func translationTarget(for text: String) -> Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.french, .english]
        recognizer.processString(text)
        return recognizer.dominantLanguage == .french ? .english : .french
    }

    static func instructions(for trick: Trick, target: Language?) -> String {
        switch trick {
        case .translate:
            let to = (target ?? .english).rawValue
            return """
            Translate the user's text into \(to). Keep the meaning, tone and register. \
            Keep the formatting, line breaks, lists, punctuation style, names, code, URLs, numbers \
            and emoji exactly as they are. Leave anything already in \(to) as it is. Reply with \
            the translation only: no quotes, notes or explanations.
            """
        case .fixTypos:
            return """
            Fix the typos in the user's text: spelling, grammar, agreement, accents and punctuation \
            mistakes. Keep its language (French stays French, English stays English, a mix stays a \
            mix), its wording, tone, formatting, line breaks, names, code and URLs. Don't rephrase, \
            add, remove or reorder anything else. If nothing needs fixing, return it unchanged. \
            Reply with the text only: no quotes, notes or explanations.
            """
        }
    }

    /// The model trims; the selection may have started or ended with a space or a line
    /// break, and replacing it must keep them.
    static func keepingEdges(of original: String, around result: String) -> String {
        let lead = original.prefix { $0.isWhitespace }
        let trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        let core = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return lead + core + trail
    }

    #if DEBUG
    /// `CopyPasta --check-copy-tricks`: the logic that runs without a network call.
    static func selfCheck() {
        assert(translationTarget(for: "Bonjour, je voudrais réserver une table pour ce soir.") == .english)
        assert(translationTarget(for: "Hi, I'd like to book a table for tonight.") == .french)
        assert(keepingEdges(of: "  hello world\n", around: "bonjour le monde") == "  bonjour le monde\n")
        assert(keepingEdges(of: "hello", around: "\nbonjour\n") == "bonjour")
        // Word diff: an inserted word must not turn every later word into a change.
        assert(WordDiff.parts("a b c", "a x b c") == [.same("a"), .added("x"), .same("b"), .same("c")])
        assert(WordDiff.parts("une tabel pour", "une table pour") == [.same("une"), .removed("tabel"), .added("table"), .same("pour")])
        assert(WordDiff.parts("same text", "same text").allSatisfy { if case .same = $0 { return true }; return false })
        print("copy tricks check passed")
    }
    #endif
}

// MARK: - OpenRouter

/// One rewrite request, with thinking off where the model allows it: a typo fix
/// doesn't need it, and it would add seconds.
enum OpenRouterRewrite {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(instructions: String, text: String, apiKey: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CopyPasta", forHTTPHeaderField: "X-Title")
        var payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": text]],
        ]
        if model.hasPrefix("google/gemma") {
            payload["reasoning"] = ["enabled": false, "exclude": true]
        }
        if !model.hasSuffix(":nitro") {
            payload["provider"] = ["sort": "throughput"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Couldn't reach OpenRouter")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
            throw Failure(message: detail.map { "OpenRouter: \($0)" } ?? "OpenRouter request failed")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "OpenRouter sent back nothing")
        }
        return content
    }
}
