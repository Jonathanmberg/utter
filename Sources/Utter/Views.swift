import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

// MARK: - Notch shape

/// A shape that hangs from the top edge: outward-curving top corners (like the
/// hardware notch) and rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let tr = max(0, min(topRadius, r.width / 4, r.height))
        let br = max(0, min(bottomRadius, r.height - tr, r.width / 4))
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr, y: r.minY + tr), control: CGPoint(x: r.minX + tr, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tr, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr + br, y: r.maxY), control: CGPoint(x: r.minX + tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - tr, y: r.maxY - br), control: CGPoint(x: r.maxX - tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY + tr))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - tr, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let size = model.shapeSize
        let (tr, br) = model.radii
        ZStack(alignment: .top) {
            NotchShape(topRadius: tr, bottomRadius: br)
                .fill(Color.black)
                .shadow(color: .black.opacity(model.state == .open ? 0.45 : 0), radius: 14, y: 6)

            if model.state == .hover {
                VStack {
                    Spacer()
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.bottom, 1)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { model.open() }
                .transition(.opacity)
            }

            if model.state == .open {
                OpenPanel(model: model)
                    .frame(width: model.panelSize.width - tr * 2, height: model.panelSize.height)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.16)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))))
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

struct OpenPanel: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model).frame(height: model.topBarHeight)
            ScriptPane(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ResizeHandle(model: model)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.addFiles([url]) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.75)))
                    .overlay(Label("Drop to add to Files", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Top bar

struct BarButton: View {
    let symbol: String
    var help: String = ""
    var selected = false
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? Color(nsColor: .systemBlue) : tint.opacity(hovering ? 1 : 0.85))
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(selected ? 0.12 : hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct TopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            BarButton(symbol: "scroll", help: "Script 1 (⌘1)", selected: model.mode == .script1) { model.mode = .script1 }
            BarButton(symbol: "text.bubble", help: "Script 2 (⌘2)", selected: model.mode == .script2) { model.mode = .script2 }
            Spacer(minLength: model.hasNotch ? model.notchSize.width + 16 : 16)
            BarButton(symbol: model.isPlaying ? "pause.fill" : "play.fill",
                      help: "Play / pause (⌘↩)", tint: Color(nsColor: .systemBlue)) {
                model.togglePlay()
            }
            BarButton(symbol: "xmark", help: "Tuck back behind the camera (Esc)") { model.close() }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }
}

// MARK: - Script

struct ScriptPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            ScriptEditor(model: model)
                .mask(fadeMask.animation(.easeInOut(duration: 0.35), value: model.isPlaying))

            if (model.currentDoc?.text ?? "").isEmpty {
                Text("Paste or type here.\nSelect words to color them, box them or connect a file.")
                    .font(.system(size: model.fontSize * 0.75, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 33)
                    .padding(.top, 16)
                    .allowsHitTesting(false)
            }

            // Only visible while the pointer is over the panel.
            ScriptControls(model: model)
                .padding(.top, 14)
                .padding(.bottom, 2)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.9), .black],
                                           startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false))
                .opacity(model.mouseInPanel ? 1 : 0)
                .allowsHitTesting(model.mouseInPanel)
                .animation(.easeOut(duration: 0.2), value: model.mouseInPanel)
        }
    }

    /// While rolling, the top lines fade into black as they move up toward the camera.
    private var fadeMask: some View {
        let playing = model.isPlaying
        return LinearGradient(stops: [
            .init(color: .black.opacity(playing ? 0.1 : 0.7), location: 0),
            .init(color: .black, location: playing ? 0.3 : 0.06),
            .init(color: .black, location: 0.82),
            .init(color: .black.opacity(0.3), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

struct ScriptControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            SpeedPicker(model: model)
            HStack(spacing: 6) {
                SmallIconButton(symbol: "backward.end.fill", help: "Back to the top") { model.commands.send(.restart) }
                if model.isPlaying {
                    Text("Paused while you hover")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                SmallIconButton(symbol: "textformat.size.smaller", help: "Smaller text (⌘−)") { model.bumpFont(-2) }
                SmallIconButton(symbol: "textformat.size.larger", help: "Bigger text (⌘+)") { model.bumpFont(2) }
            }
        }
        .padding(.horizontal, 14)
    }
}

struct SpeedPicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Speed.allCases) { s in
                Text(s.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(model.speed == s ? .black : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(model.speed == s ? Color.white : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.speed = s } }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(white: 0.16)))
    }
}

struct SmallIconButton: View {
    let symbol: String
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Resize handle (length only)

struct ResizeHandle: View {
    @ObservedObject var model: AppModel
    @State private var startHeight: CGFloat?

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .frame(width: 40, height: 5)
            .frame(width: 140, height: 16)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startHeight == nil { startHeight = model.panelHeight }
                        model.setPanelHeight((startHeight ?? model.panelHeight) + v.translation.height)
                    }
                    .onEnded { _ in startHeight = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    let compact = AppModel.compactHeight
                    model.setPanelHeight(model.panelHeight > compact + 20 ? compact : compact * 1.9)
                }
            }
            .help("Drag down to make it longer · double-click to switch size")
    }
}

// MARK: - Shared controls

/// A small Apple-style capsule button: quiet at rest, brighter on hover.
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .white
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule(style: .continuous)
                    .fill(prominent ? tint.opacity(hovering ? 0.28 : 0.2) : Color.white.opacity(hovering ? 0.16 : 0.1)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Selection popup

struct FormatState {
    var color: String?
    var box: String?
    var file: UUID?
}

struct FormatActions {
    var textColor: (String?) -> Void
    var box: (String?) -> Void
    var connect: (UUID?) -> Void
    var addFile: () -> Void
    var clear: () -> Void
    var clearAll: () -> Void
}

struct FormatBar: View {
    @ObservedObject var model: AppModel
    @State var state: FormatState
    let actions: FormatActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Text Color") {
                Swatch(name: nil, style: .text, selected: state.color == nil) { state.color = nil; actions.textColor(nil) }
                ForEach(Palette.names, id: \.self) { name in
                    Swatch(name: name, style: .text, selected: state.color == name) {
                        state.color = name; actions.textColor(name)
                    }
                }
            }
            section("Box") {
                Swatch(name: nil, style: .box, selected: state.box == nil) { state.box = nil; actions.box(nil) }
                ForEach(Palette.names, id: \.self) { name in
                    Swatch(name: name, style: .box, selected: state.box == name) {
                        state.box = name; actions.box(name)
                    }
                }
            }

            Divider().opacity(0.6)

            HStack(spacing: 6) {
                Menu {
                    if model.files.isEmpty {
                        Text("No files yet")
                    }
                    ForEach(model.files) { f in
                        Button {
                            state.file = f.id; actions.connect(f.id)
                        } label: {
                            Label(f.name, systemImage: state.file == f.id ? "checkmark" : f.symbol)
                        }
                    }
                    Divider()
                    Button { actions.addFile() } label: { Label("Add a File…", systemImage: "plus") }
                    if state.file != nil {
                        Button { state.file = nil; actions.connect(nil) } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    }
                    if !model.files.isEmpty {
                        Divider()
                        Menu {
                            ForEach(model.files) { f in
                                Button(role: .destructive) {
                                    if state.file == f.id { state.file = nil }
                                    model.deleteFile(f.id)
                                } label: {
                                    let used = model.usage(of: f.id)
                                    Text(used.isEmpty ? f.name : "\(f.name) — connected in \(used.joined(separator: ", "))")
                                }
                            }
                        } label: {
                            Label("Remove a File from Utter", systemImage: "trash")
                        }
                    }
                } label: {
                    Label(state.file.flatMap { model.file($0)?.name } ?? "Connect File", systemImage: "paperclip")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .help("Show a file when you click these words while presenting")

                Spacer(minLength: 4)

                Button("Clear") {
                    state = FormatState()
                    actions.clear()
                }
                .buttonStyle(PillButtonStyle())
                .help("Remove color, box and file link from the selected words")

                Button("Clear All") { actions.clearAll() }
                    .buttonStyle(PillButtonStyle(tint: Color(nsColor: .systemRed), prominent: true))
                    .help("Remove every color, box and link in this script (⌘Z to undo)")
            }
        }
        .padding(14)
        .frame(width: 318)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 6) { content() }
        }
    }
}

struct Swatch: View {
    enum Style { case text, box }
    let name: String?
    let style: Style
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var color: Color? { Palette.color(name).map { Color(nsColor: $0) } }

    var body: some View {
        Button(action: action) {
            ZStack {
                switch style {
                case .text:
                    // A tinted "A", like the text color control in Apple's apps.
                    Circle().fill(Color.white.opacity(0.08))
                    Text("A")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(color ?? .white)
                case .box:
                    if let name, let color {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.88))
                        Text("A")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(Color(nsColor: Palette.textOn(name)))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    }
                }
            }
            .frame(width: 24, height: 24)
            .padding(2)
            .overlay(
                RoundedRectangle(cornerRadius: style == .box ? 8 : 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
            )
            .background(
                RoundedRectangle(cornerRadius: style == .box ? 8 : 14, style: .continuous)
                    .fill(Color.white.opacity(hovering && !selected ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name.map { $0.capitalized } ?? (style == .box ? "No box" : "Default (white)"))
        .accessibilityLabel(Text("\(style == .box ? "Box" : "Text") \(name ?? "none")"))
    }
}

// MARK: - File preview

extension StoredFile {
    var type: UTType? { UTType(filenameExtension: url.pathExtension) }

    var kindDescription: String {
        let kind = type?.localizedDescription ?? "Document"
        return kind.prefix(1).uppercased() + kind.dropFirst()
    }

    var sizeDescription: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var symbol: String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        return "doc.text"
    }

    /// A preview size that suits the content: images keep their shape, PDFs are portrait.
    var previewSize: CGSize {
        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url), image.size.width > 0 {
            let maxW: CGFloat = 600, maxH: CGFloat = 440
            let scale = min(maxW / image.size.width, maxH / image.size.height, 1.5)
            return CGSize(width: max(280, image.size.width * scale), height: max(180, image.size.height * scale))
        }
        if type?.conforms(to: .pdf) == true { return CGSize(width: 480, height: 540) }
        return CGSize(width: 560, height: 400)
    }
}

extension AppModel {
    /// Names of the scripts that link to this file.
    func usage(of id: UUID) -> [String] {
        docs.enumerated().compactMap { i, doc in
            doc.spans.contains { $0.file == id } ? "Script \(i + 1)" : nil
        }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct FilePreviewCard: View {
    let file: StoredFile

    var body: some View {
        let size = file.previewSize
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(file.kindDescription) · \(file.sizeDescription)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(PillButtonStyle())
                .help("Show in Finder")
                Button { NSWorkspace.shared.open(file.url) } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(PillButtonStyle())
                .help("Open in its app")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            QuickLookView(url: file.url)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding([.horizontal, .bottom], 8)
        }
        .frame(minWidth: 380)
    }
}
