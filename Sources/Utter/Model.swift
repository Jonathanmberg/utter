import SwiftUI
import Combine

extension NSAttributedString.Key {
    /// Palette name of the box drawn around the text.
    static let promptBox = NSAttributedString.Key("UtterBox")
    /// Palette name of the text color (the actual color lives in `.foregroundColor`).
    static let promptColor = NSAttributedString.Key("UtterColor")
}

enum Palette {
    static let names = ["orange", "yellow", "green", "blue", "purple", "pink", "red", "gray"]

    static func color(_ name: String?) -> NSColor? {
        switch name {
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "red": return .systemRed
        case "gray": return .systemGray
        default: return nil
        }
    }

    /// Readable text on a solid box. Prompter text is large and bold, so (per WCAG / Apple's
    /// accessibility guidance) white is used when it reaches 3:1 contrast, otherwise near-black.
    static func textOn(_ box: String?) -> NSColor {
        guard let c = color(box)?.usingColorSpace(.sRGB) else { return .white }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        let onBlack = lum * 0.88 // boxes are drawn at 88% over the black panel
        return 1.05 / (onBlack + 0.05) >= 3 ? .white : NSColor(white: 0.08, alpha: 1)
    }
}

/// A run of styled text: color, box and/or a connected file.
struct StyleSpan: Codable, Equatable {
    var location: Int
    var length: Int
    var color: String?
    var box: String?
    var file: UUID?
}

struct PromptDoc: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var spans: [StyleSpan] = []
}

struct StoredFile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var fileName: String
    var added = Date()
    var url: URL { AppModel.filesDir.appendingPathComponent(fileName) }
}

enum Mode: Int { case script1, script2 }

enum NotchState { case closed, hover, open }

enum Speed: String, CaseIterable, Identifiable {
    case slow, normal, fast
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Scroll speed in points/second at the default 26pt font size.
    var pointsPerSecond: CGFloat {
        switch self {
        case .slow: return 9
        case .normal: return 15
        case .fast: return 24
        }
    }
}

enum ScriptCommand { case toggleBox, restart }

private struct SavedData: Codable {
    var docs: [PromptDoc]
    var files: [StoredFile]
}

final class AppModel: ObservableObject {
    static let compactHeight: CGFloat = 230

    @Published var state: NotchState = .closed
    @Published var mode: Mode = .script1 { didSet { if mode != oldValue { isPlaying = false } } }
    @Published var isPlaying = false
    @Published var speed: Speed { didSet { defaults.set(speed.rawValue, forKey: "speed") } }
    @Published var fontSize: CGFloat { didSet { defaults.set(Double(fontSize), forKey: "fontSize") } }
    @Published var panelHeight: CGFloat { didSet { defaults.set(Double(panelHeight), forKey: "panelHeight") } }
    @Published var panelWidth: CGFloat = 680
    @Published var docs: [PromptDoc]
    @Published var files: [StoredFile]
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
    /// Pointer is over the open panel: text pauses and the speed controls show.
    @Published var mouseInPanel = false
    /// A format or file popup is showing: text pauses.
    @Published var popoverOpen = false
    /// Bumped when stored text changes outside the editor (e.g. a connected file was deleted).
    @Published var reloadToken = 0

    var maxPanelHeight: CGFloat = 600
    let commands = PassthroughSubject<ScriptCommand, Never>()
    var scrollPositions: [UUID: CGFloat] = [:]
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var bag = Set<AnyCancellable>()

    init() {
        Self.migrateFromOldName()
        speed = Speed(rawValue: defaults.string(forKey: "speed") ?? "") ?? .normal
        let fs = defaults.double(forKey: "fontSize")
        fontSize = fs > 0 ? CGFloat(fs) : 26
        let h = defaults.double(forKey: "panelHeight")
        panelHeight = h > 0 ? CGFloat(h) : Self.compactHeight

        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode(SavedData.self, from: data) {
            var d = saved.docs
            while d.count < 2 { d.append(PromptDoc()) }
            docs = d
            files = saved.files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        } else {
            docs = Self.sampleDocs()
            files = []
        }

        $docs.combineLatest($files)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &bag)
    }

    // MARK: Geometry

    var topBarHeight: CGFloat { max(notchSize.height, 32) }
    var panelSize: CGSize { CGSize(width: panelWidth, height: panelHeight) }

    var shapeSize: CGSize {
        switch state {
        case .closed:
            return hasNotch ? notchSize : CGSize(width: 220, height: 0)
        case .hover:
            return hasNotch
                ? CGSize(width: notchSize.width + 36, height: notchSize.height + 14)
                : CGSize(width: 220, height: 22)
        case .open:
            return panelSize
        }
    }

    /// (top flare radius, bottom corner radius)
    var radii: (CGFloat, CGFloat) {
        switch state {
        case .closed: return (6, 10)
        case .hover: return (8, 14)
        case .open: return (12, 26)
        }
    }

    /// Only the length changes; the panel never gets shorter than the compact size.
    func setPanelHeight(_ h: CGFloat) {
        panelHeight = min(max(h, Self.compactHeight), max(maxPanelHeight, Self.compactHeight))
    }

    // MARK: Open / close

    func setHover(_ on: Bool) {
        guard state != .open else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { state = on ? .hover : .closed }
    }

    func open() {
        guard state != .open else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { state = .open }
        onOpen?()
    }

    func close() {
        guard state == .open else { return }
        isPlaying = false
        mouseInPanel = false
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { state = .closed }
        onClose?()
    }

    func toggleOpen() { state == .open ? close() : open() }

    func togglePlay() {
        guard state == .open else { return }
        isPlaying.toggle()
    }

    func bumpFont(_ delta: CGFloat) { fontSize = min(max(fontSize + delta, 14), 56) }

    // MARK: Documents

    var currentDocIndex: Int? {
        switch mode {
        case .script1: return 0
        case .script2: return 1
        }
    }

    var currentDoc: PromptDoc? { currentDocIndex.map { docs[$0] } }

    func updateDoc(_ id: UUID, _ change: (inout PromptDoc) -> Void) {
        guard let i = docs.firstIndex(where: { $0.id == id }) else { return }
        change(&docs[i])
    }

    // MARK: Files

    static var supportDir: URL {
        // --test-data keeps debug runs away from the real library.
        if CommandLine.arguments.contains("--test-data") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("UtterTest", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utter", isDirectory: true)
    }
    static var filesDir: URL { supportDir.appendingPathComponent("Files", isDirectory: true) }
    static var storeURL: URL { supportDir.appendingPathComponent("data.json") }

    static func fileLink(_ id: UUID) -> URL { URL(string: "notchfile://\(id.uuidString)")! }

    static func fileID(from link: Any?) -> UUID? {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == "notchfile", let host = url.host else { return nil }
        return UUID(uuidString: host)
    }

    func file(_ id: UUID) -> StoredFile? { files.first { $0.id == id } }

    /// Copies the files into the app's own storage so they survive the originals moving.
    @discardableResult
    func addFiles(_ urls: [URL]) -> [StoredFile] {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.filesDir, withIntermediateDirectories: true)
        var added: [StoredFile] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let id = UUID()
            let fileName = "\(id.uuidString)-\(url.lastPathComponent)"
            do {
                try fm.copyItem(at: url, to: Self.filesDir.appendingPathComponent(fileName))
                added.append(StoredFile(id: id, name: url.lastPathComponent, fileName: fileName))
            } catch {
                NSSound.beep()
            }
        }
        files.insert(contentsOf: added, at: 0)
        return added
    }

    func deleteFile(_ id: UUID) {
        if let f = file(id) { try? FileManager.default.removeItem(at: f.url) }
        files.removeAll { $0.id == id }
        for i in docs.indices {
            docs[i].spans = docs[i].spans.compactMap { span in
                var s = span
                if s.file == id { s.file = nil }
                return (s.color == nil && s.box == nil && s.file == nil) ? nil : s
            }
        }
        reloadToken += 1
    }

    func pickFiles(then: (([StoredFile]) -> Void)? = nil) {
        // Let the menu/popup that triggered this finish closing first.
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = "Add"
            panel.message = "Choose images, PDFs or any files to show from Utter"
            // Utter usually isn't the active app while you use the notch panel, and panels
            // normally vanish when their app isn't active — which is why this used to disappear.
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                guard response == .OK, let self else { return }
                then?(self.addFiles(panel.urls))
            }
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    // MARK: Persistence

    /// The app used to be called NotchPrompter: carry its scripts, files and settings over once.
    private static func migrateFromOldName() {
        guard !CommandLine.arguments.contains("--test-data") else { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("NotchPrompter", isDirectory: true)
        if !fm.fileExists(atPath: supportDir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: supportDir)
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "migratedSettings") == nil {
            if let oldDefaults = UserDefaults(suiteName: "com.jonathanberg.notchprompter") {
                for key in ["speed", "fontSize", "panelHeight", "hideFromCapture"] {
                    if let v = oldDefaults.object(forKey: key) { defaults.set(v, forKey: key) }
                }
            }
            defaults.set(true, forKey: "migratedSettings")
        }
    }

    func saveNow() {
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(SavedData(docs: docs, files: files)) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    private static func sampleDocs() -> [PromptDoc] {
        let intro = """
        Welcome to Utter. This is your teleprompter, sitting right under your camera.

        Press play and the text starts rolling. Read it while you look straight at the person you're talking to.

        Hover over the panel and the text holds still. Move away and it keeps going. Choose Slow, Normal or Fast at the bottom.

        Everything here is editable. Click anywhere to type, or paste in your own script.

        Drag the handle at the bottom to see more lines. Click the X to tuck Utter back behind the camera.
        """
        let notes = """
        Notes and keywords

        Use this second page for short keywords instead of a full script.

        Select any words to open the style menu.
        Text Color changes the color of the words.
        Box puts a bright box around them.
        Connect File links an image or PDF. Click the words while presenting and the file pops up.

        Drop files anywhere on the panel to add them.
        Clear removes the style from your selection. Clear All resets the whole page.

        Shortcuts
        ⌘B  orange box
        ⌘↩  play or pause
        ⌘1 and ⌘2  switch page
        ⌥⌘P  open or close Utter from anywhere
        """
        func span(_ text: String, in s: String, color: String? = nil, box: String? = nil) -> StyleSpan {
            let r = (s as NSString).range(of: text)
            return StyleSpan(location: r.location, length: r.length, color: color, box: box)
        }
        return [
            PromptDoc(text: intro, spans: [
                span("right under your camera.", in: intro, box: "orange"),
                span("look straight at", in: intro, box: "green"),
                span("holds still", in: intro, box: "blue"),
            ]),
            PromptDoc(text: notes, spans: [
                span("Notes and keywords", in: notes, color: "orange"),
                span("Text Color", in: notes, color: "purple"),
                span("Box", in: notes, box: "yellow"),
                span("Connect File", in: notes, box: "blue"),
                span("Shortcuts", in: notes, color: "orange"),
                span("⌘B", in: notes, box: "orange"),
            ]),
        ]
    }
}
