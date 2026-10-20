import SwiftUI
import AppKit
import Combine

/// Draws colored boxes behind boxed text, and a paperclip in front of text connected to a file.
final class PromptLayoutManager: NSLayoutManager {
    private static var clipCache: [Int: NSImage] = [:]

    private static func clip(_ size: CGFloat) -> NSImage? {
        let key = Int(size)
        if let img = clipCache[key] { return img }
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.85, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        let img = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        clipCache[key] = img
        return img
    }

    /// How far a box reaches past its words; the text gets twice this as extra spacing on each side.
    static func boxPad(_ fontSize: CGFloat) -> CGFloat { (fontSize * 0.2).rounded() }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let none = NSRange(location: NSNotFound, length: 0)

        let ns = storage.string as NSString
        let fullText = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.promptBox, in: charRange) { value, clipped, _ in
            guard let color = Palette.color(value as? String) else { return }
            var run = NSRange()
            _ = storage.attribute(.promptBox, at: clipped.location, longestEffectiveRange: &run, in: fullText)
            let font = storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont
                ?? .systemFont(ofSize: 26, weight: .semibold)
            let pad = Self.boxPad(font.pointSize)
            let boxGlyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let lastChar = NSMaxRange(run) - 1

            // One box per line, hugging the glyphs: from ascender to descender (so lines
            // above/below never touch), trailing spaces trimmed.
            enumerateLineFragments(forGlyphRange: boxGlyphs) { lineRect, _, tc, lineGlyphs, _ in
                var sub = NSIntersectionRange(lineGlyphs, boxGlyphs)
                while sub.length > 0 {
                    let c = ns.character(at: self.characterIndexForGlyph(at: NSMaxRange(sub) - 1))
                    guard let u = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(u) else { break }
                    sub.length -= 1
                }
                guard sub.length > 0 else { return }
                let r = self.boundingRect(forGlyphRange: sub, in: tc)
                let endsRun = self.characterIndexForGlyph(at: NSMaxRange(sub) - 1) == lastChar
                let baseline = lineRect.minY + self.location(forGlyphAt: sub.location).y
                let left = r.minX - pad
                // The run's last character carries extra kerning (the gap after the box); stop before it.
                let right = (endsRun ? r.maxX - pad * 2 : r.maxX) + pad
                let box = NSRect(x: left + origin.x, y: baseline - font.ascender + origin.y,
                                 width: right - left, height: font.ascender - font.descender)
                // Apple-style continuous ("squircle") corners.
                let path = Path(roundedRect: box, cornerRadius: box.height * 0.24, style: .continuous).cgPath
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.addPath(path)
                    ctx.setFillColor(color.withAlphaComponent(0.88).cgColor)
                    ctx.fillPath()
                }
            }
        }

        storage.enumerateAttribute(.link, in: charRange) { value, range, _ in
            guard let id = AppModel.fileID(from: value) else { return }
            // Only at the real start of the connected run.
            if range.location > 0, AppModel.fileID(from: storage.attribute(.link, at: range.location - 1, effectiveRange: nil)) == id { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            var first = NSRect.zero
            enumerateEnclosingRects(forGlyphRange: NSRange(location: glyph, length: 1), withinSelectedGlyphRange: none, in: container) { r, stop in
                first = r
                stop.pointee = true
            }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let size = (font?.pointSize ?? 26) * 0.75
            let boxed = storage.attribute(.promptBox, at: range.location, effectiveRange: nil) != nil
            let x = max(2, first.minX + origin.x - size - 5 - (boxed ? Self.boxPad(font?.pointSize ?? 26) : 0))
            let rect = NSRect(x: x, y: first.midY + origin.y - size / 2, width: size, height: size)
            Self.clip(size)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

final class PromptTextView: NSTextView {
    var onType: (() -> Void)?
    var onMouseUp: (() -> Void)?
    var onEscape: (() -> Void)?

    /// Empty, clickable space kept below the last line so it can scroll up toward the camera.
    var overscroll: CGFloat = 0 {
        didSet { if oldValue != overscroll { setFrameSize(frame.size) } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let lm = layoutManager, let tc = textContainer {
            let used = lm.usedRect(for: tc).height + textContainerInset.height * 2
            size.height = max(size.height, used + overscroll, minSize.height)
        }
        super.setFrameSize(size)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event) // tracks until the mouse is released
        onMouseUp?()
    }

    override func keyDown(with event: NSEvent) { onType?(); super.keyDown(with: event) }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Dropped files go to the Files tab, not into the text as a path.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }
}

struct ScriptEditor: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.sync() }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.teardown() }

    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        let model: AppModel
        private var textView: PromptTextView!
        private var scrollView: NSScrollView!
        private var loadedID: UUID?
        private var loadedToken = -1
        private var loadedFontSize: CGFloat = 0
        private var isLoading = false
        private var timer: Timer?
        private var lastTick = CACurrentMediaTime()
        private var exactY: CGFloat = 0
        private var formatPopover: NSPopover?
        private var filePopover: NSPopover?
        private var bag = Set<AnyCancellable>()

        init(model: AppModel) { self.model = model }

        private var storage: NSTextStorage { textView.textStorage! }

        func makeScrollView() -> NSScrollView {
            let storage = NSTextStorage()
            let layout = PromptLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = true
            layout.addTextContainer(container)

            let tv = PromptTextView(frame: .zero, textContainer: container)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.autoresizingMask = [.width]
            tv.minSize = .zero
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            tv.drawsBackground = false
            tv.isRichText = true
            tv.importsGraphics = false
            tv.usesFontPanel = false
            tv.allowsUndo = true
            tv.isContinuousSpellCheckingEnabled = false
            tv.isGrammarCheckingEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticLinkDetectionEnabled = false
            tv.insertionPointColor = .white
            tv.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.25)]
            tv.linkTextAttributes = [.cursor: NSCursor.pointingHand] // colors come from restyleLinks()
            tv.textContainerInset = NSSize(width: 28, height: 16)
            tv.delegate = self
            tv.onType = { [weak self] in
                if self?.model.isPlaying == true { self?.model.isPlaying = false }
            }
            tv.onMouseUp = { [weak self] in self?.selectionFinished() }
            tv.onEscape = { [weak self] in self?.model.close() }

            let sv = NSScrollView()
            sv.drawsBackground = false
            sv.borderType = .noBorder
            sv.hasVerticalScroller = true
            sv.autohidesScrollers = true
            sv.scrollerStyle = .overlay
            sv.automaticallyAdjustsContentInsets = false
            sv.documentView = tv

            textView = tv
            scrollView = sv
            load()

            model.commands.sink { [weak self] cmd in
                switch cmd {
                case .toggleBox: self?.toggleOrangeBox()
                case .restart: self?.scroll(to: 0)
                }
            }.store(in: &bag)

            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let tv = self?.textView else { return }
                tv.window?.makeFirstResponder(tv)
            }
            return sv
        }

        func teardown() {
            timer?.invalidate()
            timer = nil
            bag.removeAll()
            formatPopover?.close()
            filePopover?.close()
        }

        func sync() {
            if loadedID != model.currentDoc?.id || loadedToken != model.reloadToken { load() }
            else if loadedFontSize != model.fontSize { applyFont() }
        }

        // MARK: Loading & saving

        private func fontAttributes() -> [NSAttributedString.Key: Any] {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = model.fontSize * 0.18
            para.paragraphSpacing = model.fontSize * 0.35
            return [.font: NSFont.systemFont(ofSize: model.fontSize, weight: .semibold), .paragraphStyle: para]
        }

        private func load() {
            guard let doc = model.currentDoc else { return }
            isLoading = true
            var base = fontAttributes()
            base[.foregroundColor] = NSColor.white
            let attr = NSMutableAttributedString(string: doc.text, attributes: base)
            let length = attr.length
            for s in doc.spans where s.location >= 0 && s.length > 0 && s.location + s.length <= length {
                let r = NSRange(location: s.location, length: s.length)
                if let name = s.color, let c = Palette.color(name) {
                    attr.addAttributes([.promptColor: name, .foregroundColor: c], range: r)
                }
                if let box = s.box { attr.addAttribute(.promptBox, value: box, range: r) }
                if let f = s.file, model.file(f) != nil { attr.addAttribute(.link, value: AppModel.fileLink(f), range: r) }
            }
            storage.setAttributedString(attr)
            restyleLinks()
            textView.typingAttributes = base
            textView.undoManager?.removeAllActions()
            let keepSelection = loadedID == doc.id
            if !keepSelection { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
            loadedID = doc.id
            loadedToken = model.reloadToken
            loadedFontSize = model.fontSize
            isLoading = false
            let saved = model.scrollPositions[doc.id] ?? 0
            DispatchQueue.main.async { [weak self] in self?.scroll(to: saved) }
        }

        private func applyFont() {
            let attrs = fontAttributes()
            storage.beginEditing()
            storage.addAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            restyleLinks()
            textView.typingAttributes.merge(attrs) { _, new in new }
            loadedFontSize = model.fontSize
        }

        /// Extra spacing around boxed text (so boxes get room) and before connected text (for the paperclip).
        private func restyleLinks() {
            let full = NSRange(location: 0, length: storage.length)
            let ns = storage.string as NSString
            func isBreak(_ i: Int) -> Bool { let c = ns.character(at: i); return c == 10 || c == 13 }
            var kern: [Int: CGFloat] = [:]
            let boxGap = PromptLayoutManager.boxPad(model.fontSize) * 2
            storage.enumerateAttribute(.promptBox, in: full) { value, range, _ in
                guard value != nil else { return }
                if range.location > 0, !isBreak(range.location - 1) { kern[range.location - 1, default: 0] += boxGap }
                let last = NSMaxRange(range) - 1
                if !isBreak(last) { kern[last, default: 0] += boxGap }
            }
            let linkGap = model.fontSize * 0.75 + 8
            storage.enumerateAttribute(.link, in: full) { value, range, _ in
                guard AppModel.fileID(from: value) != nil, range.location > 0 else { return }
                kern[range.location - 1, default: 0] += linkGap
            }
            storage.beginEditing()
            storage.removeAttribute(.kern, range: full)
            for (i, k) in kern { storage.addAttribute(.kern, value: k, range: NSRange(location: i, length: 1)) }
            // Text color: boxes are solid, so text inside them goes white unless it was given
            // a different color than the box. Connected text is blue when not boxed.
            storage.enumerateAttributes(in: full) { attrs, range, _ in
                let box = attrs[.promptBox] as? String
                let chosen = attrs[.promptColor] as? String
                let linked = AppModel.fileID(from: attrs[.link]) != nil
                let color: NSColor
                if box != nil {
                    color = (chosen != nil && chosen != box) ? Palette.color(chosen)! : Palette.textOn(box)
                } else if linked {
                    color = .systemBlue
                } else {
                    color = Palette.color(chosen) ?? .white
                }
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
        }

        private func extractSpans() -> [StyleSpan] {
            var spans: [StyleSpan] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                let color = attrs[.promptColor] as? String
                let box = attrs[.promptBox] as? String
                let file = AppModel.fileID(from: attrs[.link])
                guard color != nil || box != nil || file != nil else { return }
                if let last = spans.last, last.location + last.length == range.location,
                   last.color == color, last.box == box, last.file == file {
                    spans[spans.count - 1].length += range.length
                } else {
                    spans.append(StyleSpan(location: range.location, length: range.length, color: color, box: box, file: file))
                }
            }
            return spans
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let id = loadedID else { return }
            restyleLinks()
            let text = storage.string
            let spans = extractSpans()
            model.updateDoc(id) {
                $0.text = text
                $0.spans = spans
            }
        }

        // MARK: Formatting

        private func edit(_ range: NSRange, _ change: (NSTextStorage) -> Void) {
            guard range.length > 0, NSMaxRange(range) <= storage.length,
                  textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            change(storage)
            storage.endEditing()
            textView.didChangeText()
            textView.needsDisplay = true
        }

        func setTextColor(_ name: String?, _ range: NSRange) {
            edit(range) { s in
                if let name, let c = Palette.color(name) {
                    s.addAttributes([.promptColor: name, .foregroundColor: c], range: range)
                } else {
                    s.removeAttribute(.promptColor, range: range)
                    s.addAttribute(.foregroundColor, value: NSColor.white, range: range)
                }
            }
        }

        func setBox(_ name: String?, _ range: NSRange) {
            edit(range) { s in
                if let name { s.addAttribute(.promptBox, value: name, range: range) }
                else { s.removeAttribute(.promptBox, range: range) }
            }
        }

        func setFile(_ id: UUID?, _ range: NSRange) {
            edit(range) { s in
                if let id { s.addAttribute(.link, value: AppModel.fileLink(id), range: range) }
                else { s.removeAttribute(.link, range: range) }
            }
        }

        /// Clears color, box and file link from the selection, including the whole of any
        /// box/color/link the selection touches, so no fragments are left behind.
        func clearFormatting(_ selection: NSRange) {
            let full = NSRange(location: 0, length: storage.length)
            var range = selection
            for key in [NSAttributedString.Key.promptBox, .promptColor, .link] {
                for i in [selection.location, NSMaxRange(selection) - 1] where i >= 0 && i < storage.length {
                    var run = NSRange()
                    if storage.attribute(key, at: i, longestEffectiveRange: &run, in: full) != nil {
                        range = NSUnionRange(range, run)
                    }
                }
            }
            stripFormatting(range)
        }

        /// Clears every box, color and link in this script (undo with ⌘Z).
        func clearAllFormatting() {
            stripFormatting(NSRange(location: 0, length: storage.length))
        }

        private func stripFormatting(_ range: NSRange) {
            edit(range) { s in
                s.removeAttribute(.promptColor, range: range)
                s.removeAttribute(.promptBox, range: range)
                s.removeAttribute(.link, range: range)
            }
            textView.typingAttributes.removeValue(forKey: .promptColor)
            textView.typingAttributes.removeValue(forKey: .promptBox)
            textView.typingAttributes.removeValue(forKey: .link)
            textView.typingAttributes[.foregroundColor] = NSColor.white
        }

        /// ⌘B: orange box on/off for the selection.
        private func toggleOrangeBox() {
            let range = trimmed(textView.selectedRange())
            guard range.length > 0 else { return }
            var fully = true
            storage.enumerateAttribute(.promptBox, in: range) { v, _, stop in
                if v == nil { fully = false; stop.pointee = true }
            }
            setBox(fully ? nil : "orange", range)
        }

        private func trimmed(_ input: NSRange) -> NSRange {
            let ns = storage.string as NSString
            var range = input
            func isSpace(_ i: Int) -> Bool {
                Unicode.Scalar(ns.character(at: i)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            }
            while range.length > 0, isSpace(range.location) { range = NSRange(location: range.location + 1, length: range.length - 1) }
            while range.length > 0, isSpace(NSMaxRange(range) - 1) { range.length -= 1 }
            return range
        }

        // MARK: Popups

        /// Rect of the last line of `range`, in text view coordinates.
        private func anchorRect(for range: NSRange) -> NSRect {
            guard let lm = textView.layoutManager, let tc = textView.textContainer else { return .zero }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var last = NSRect.zero
            lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in last = r }
            let o = textView.textContainerOrigin
            return last.offsetBy(dx: o.x, dy: o.y)
        }

        private func selectionFinished() {
            let range = trimmed(textView.selectedRange())
            guard range.length > 0 else { return }
            showFormatPopover(for: range)
        }

        private func showFormatPopover(for range: NSRange) {
            formatPopover?.close()
            let at = range.location
            let initial = FormatState(
                color: storage.attribute(.promptColor, at: at, effectiveRange: nil) as? String,
                box: storage.attribute(.promptBox, at: at, effectiveRange: nil) as? String,
                file: AppModel.fileID(from: storage.attribute(.link, at: at, effectiveRange: nil)))
            let actions = FormatActions(
                textColor: { [weak self] in self?.setTextColor($0, range) },
                box: { [weak self] in self?.setBox($0, range) },
                connect: { [weak self] in self?.setFile($0, range) },
                addFile: { [weak self] in
                    self?.formatPopover?.close()
                    self?.model.pickFiles { added in
                        if let f = added.first { self?.setFile(f.id, range) }
                    }
                },
                clear: { [weak self] in self?.clearFormatting(range) },
                clearAll: { [weak self] in
                    self?.clearAllFormatting()
                    self?.formatPopover?.close()
                })
            let pop = makePopover(FormatBar(model: model, state: initial, actions: actions))
            pop.show(relativeTo: anchorRect(for: range), of: textView, preferredEdge: .maxY)
            matchSharing(pop)
            formatPopover = pop
            model.popoverOpen = true
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let id = AppModel.fileID(from: link) else { return false }
            guard let file = model.file(id) else { NSSound.beep(); return true }
            var effective = NSRange()
            _ = storage.attribute(.link, at: charIndex, effectiveRange: &effective)
            filePopover?.close()
            let pop = makePopover(FilePreviewCard(file: file))
            pop.show(relativeTo: anchorRect(for: effective), of: textView, preferredEdge: .maxY)
            matchSharing(pop)
            filePopover = pop
            model.popoverOpen = true
            return true
        }

        private func makePopover<V: View>(_ view: V) -> NSPopover {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            let pop = NSPopover()
            pop.contentViewController = host
            pop.behavior = .transient
            pop.animates = true
            pop.appearance = NSAppearance(named: .darkAqua)
            pop.delegate = self
            return pop
        }

        private func matchSharing(_ pop: NSPopover) {
            pop.contentViewController?.view.window?.sharingType = textView.window?.sharingType ?? .none
        }

        func popoverDidClose(_ notification: Notification) {
            let pop = notification.object as? NSPopover
            if pop === formatPopover { formatPopover = nil }
            if pop === filePopover { filePopover = nil }
            model.popoverOpen = formatPopover != nil || filePopover != nil
        }

        // MARK: Scrolling

        private var maxScrollY: CGFloat {
            max(0, textView.frame.height - scrollView.contentView.bounds.height)
        }

        private func scroll(to y: CGFloat) {
            guard let sv = scrollView else { return }
            exactY = min(max(0, y), maxScrollY)
            sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: exactY))
            sv.reflectScrolledClipView(sv.contentView)
            if let id = loadedID { model.scrollPositions[id] = exactY }
        }

        private func tick() {
            guard let sv = scrollView else { return }
            let now = CACurrentMediaTime()
            let dt = min(now - lastTick, 0.1)
            lastTick = now

            // The editor fills the whole visible area (so every spot is clickable) plus room
            // below the last line so the end can scroll up toward the camera.
            let visible = sv.contentView.bounds.height
            if abs(textView.minSize.height - visible) > 0.5 { textView.minSize = NSSize(width: 0, height: visible) }
            let wantOverscroll = (visible * 0.55).rounded()
            if abs(textView.overscroll - wantOverscroll) > 1 { textView.overscroll = wantOverscroll }

            let clipY = sv.contentView.bounds.origin.y
            if abs(clipY - exactY) > 1 { exactY = clipY } // scrolled by hand
            if let id = loadedID { model.scrollPositions[id] = clipY }

            // Hovering the panel or looking at a popup holds the text still.
            guard model.isPlaying, model.state == .open, model.currentDocIndex != nil,
                  !model.mouseInPanel, !model.popoverOpen else { return }
            let step = model.speed.pointsPerSecond * (model.fontSize / 26) * CGFloat(dt)
            if exactY + step >= maxScrollY {
                scroll(to: maxScrollY)
                model.isPlaying = false
            } else {
                scroll(to: exactY + step)
            }
        }
    }
}
