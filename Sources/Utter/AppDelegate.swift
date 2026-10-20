import AppKit
import SwiftUI
import Carbon
import ServiceManagement

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless panel that sits above the menu bar, on every Space, around the notch.
final class NotchPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// System-wide hotkey via Carbon (needs no Accessibility permission).
final class HotKey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4E505452), id: 1) // "NPTR"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var panel: NotchPanel!
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var pollCount = 0
    private var hotKey: HotKey?
    private var screenFrame: NSRect = .zero
    private let windowSize = NSSize(width: 1100, height: 660)

    private var hideFromCapture: Bool {
        get { UserDefaults.standard.object(forKey: "hideFromCapture") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "hideFromCapture")
            panel.sharingType = newValue ? .none : .readOnly
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMainMenu()

        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: windowSize))
        panel.contentView = FirstMouseHostingView(rootView: RootView(model: model))
        panel.sharingType = hideFromCapture ? .none : .readOnly
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        positionWindow()
        panel.orderFrontRegardless()

        model.onOpen = { [weak self] in self?.didOpen() }
        model.onClose = { [weak self] in self?.didClose() }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t

        setupStatusItem()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.model.toggleOpen()
        }

        // Debug: --test-pick shows the file picker, reports whether it stayed up, then cancels it.
        if CommandLine.arguments.contains("--test-pick") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.model.pickFiles() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                for w in NSApp.windows where w is NSOpenPanel {
                    FileHandle.standardError.write("open panel visible=\(w.isVisible) key=\(w.isKeyWindow) active=\(NSApp.isActive)\n".data(using: .utf8)!)
                    (w as? NSOpenPanel)?.cancel(nil)
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-format"), i + 1 < CommandLine.arguments.count {
            let host = NSHostingView(rootView: FormatBar(model: model, state: FormatState(color: "orange", box: "orange"),
                                                         actions: FormatActions(textColor: { _ in }, box: { _ in }, connect: { _ in },
                                                                                addFile: {}, clear: {}, clearAll: {}))
                .background(Color(white: 0.17)).preferredColorScheme(.dark))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = host
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
        }
        if CommandLine.arguments.contains("--hittest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let v = self.panel.contentView else { return }
                for y in stride(from: 80, through: self.model.panelHeight - 10, by: 40) {
                    let pt = NSPoint(x: v.bounds.midX - 150, y: v.bounds.maxY - y)
                    let hit = v.hitTest(pt).map { String(describing: type(of: $0)) } ?? "nil"
                    FileHandle.standardError.write("y=\(Int(y)) -> \(hit)\n".data(using: .utf8)!)
                }
            }
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.open() }
        }
        // Debug: --snapshot <path> writes an image of the window (no screen-recording permission needed).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let view = self.panel.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.saveNow() }

    // MARK: Placement

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    @objc private func screensChanged() { positionWindow() }

    private func positionWindow() {
        guard let screen = targetScreen() else { return }
        screenFrame = screen.frame
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.hasNotch = true
            model.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: inset)
        } else {
            model.hasNotch = false
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            model.notchSize = CGSize(width: 200, height: menuBar > 0 ? menuBar : 24)
        }
        model.panelWidth = min(680, screen.frame.width - 40)
        model.maxPanelHeight = min(windowSize.height - 40, screen.frame.height * 0.75)
        model.setPanelHeight(model.panelHeight)
        panel.setFrame(NSRect(x: screen.frame.midX - windowSize.width / 2,
                              y: screen.frame.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height), display: true)
    }

    /// Screen rect of a shape of `size` hanging from the top-center, grown by `pad`.
    private func topRect(_ size: CGSize, pad: CGFloat = 0) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2 - pad,
               y: screenFrame.maxY - size.height - pad,
               width: size.width + pad * 2,
               height: size.height + pad + 4) // +4: mouse can sit right on the top edge
    }

    /// Hover detection + click-through. Polling the mouse needs no permissions.
    private func poll() {
        let p = NSEvent.mouseLocation
        let buttonsDown = NSEvent.pressedMouseButtons != 0

        switch model.state {
        case .closed:
            let zone = model.hasNotch ? topRect(model.notchSize, pad: 4) : topRect(CGSize(width: 220, height: 6))
            if zone.contains(p) && !buttonsDown { model.setHover(true) }
        case .hover:
            if !topRect(model.shapeSize, pad: 12).contains(p) { model.setHover(false) }
        case .open:
            break
        }

        var interactive = model.state != .closed && topRect(model.shapeSize, pad: 2).contains(p)
        if !panel.ignoresMouseEvents && buttonsDown { interactive = true } // don't drop an in-progress drag
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }

        let inPanel = model.state == .open && topRect(model.shapeSize, pad: 2).contains(p)
        if model.mouseInPanel != inPanel { model.mouseInPanel = inPanel }

        // Popups are separate windows; keep them hidden from screen sharing too.
        pollCount += 1
        if pollCount % 8 == 0 {
            let wanted: NSWindow.SharingType = hideFromCapture ? .none : .readOnly
            for w in NSApp.windows where w.sharingType != wanted { w.sharingType = wanted }
        }
    }

    // MARK: Focus

    /// The panel takes the keyboard without activating the app, so whatever you
    /// were using stays in front and nothing jumps when you close it.
    private func didOpen() {
        panel.makeKey()
    }

    private func didClose() {
        panel.makeFirstResponder(nil)
        // Hand the keyboard back once the tuck-away animation has finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.model.state != .open, self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
            self.panel.orderFrontRegardless()
        }
    }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        let key = e.charactersIgnoringModifiers?.lowercased()
        if key == "q" { NSApp.terminate(nil); return true }
        guard model.state == .open else { return false }

        // The app isn't "active" while the panel is open, so route editing keys ourselves.
        func send(_ action: String) -> Bool { NSApp.sendAction(Selector(action), to: nil, from: self) }
        switch key {
        case "c": return send("copy:")
        case "v": return send("paste:")
        case "x": return send("cut:")
        case "a": return send("selectAll:")
        case "z": return send(flags.contains(.shift) ? "redo:" : "undo:")
        case "b", "e":
            model.commands.send(.toggleBox)
        case "\r": model.togglePlay()
        case "=", "+": model.bumpFont(2)
        case "-": model.bumpFont(-2)
        case "1": model.mode = .script1
        case "2": model.mode = .script2
        case "w": model.close()
        default: return false
        }
        return true
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Utter")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: model.state == .open ? "Hide Prompter" : "Show Prompter",
                                action: #selector(toggleFromMenu), keyEquivalent: "p")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let capture = NSMenuItem(title: "Hide from Screen Sharing", action: #selector(toggleCapture), keyEquivalent: "")
        capture.state = hideFromCapture ? .on : .off
        capture.target = self
        menu.addItem(capture)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleFromMenu() {
        DispatchQueue.main.async { self.model.toggleOpen() }
    }

    @objc private func toggleCapture() { hideFromCapture.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "Move Utter into your Applications folder and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
}
