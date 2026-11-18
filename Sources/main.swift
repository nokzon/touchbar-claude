import Cocoa
import QuartzCore

// MARK: - Private Touch Bar API (the same calls Pock / MTMR use to own the Touch Bar globally)

enum PrivateTouchBar {
    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    static func setControlStripPresence(_ id: NSTouchBarItem.Identifier, _ on: Bool) {
        guard let sym = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias F = @convention(c) (CFString, Bool) -> Void
        unsafeBitCast(sym, to: F.self)(id.rawValue as CFString, on)
    }

    static func showCloseBox(_ on: Bool) {
        guard let sym = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias F = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: F.self)(on)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        let sel = NSSelectorFromString("addSystemTrayItem:")
        guard let m = class_getClassMethod(NSTouchBarItem.self, sel) else { return }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(NSTouchBarItem.self, sel, item)
    }

    static func present(_ bar: NSTouchBar, trayId: NSTouchBarItem.Identifier) {
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        guard let m = class_getClassMethod(NSTouchBar.self, sel) else { return }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBar, NSString) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(NSTouchBar.self, sel, bar, trayId.rawValue as NSString)
    }

    static func minimize(_ bar: NSTouchBar) {
        let sel = NSSelectorFromString("minimizeSystemModalTouchBar:")
        guard let m = class_getClassMethod(NSTouchBar.self, sel) else { return }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(NSTouchBar.self, sel, bar)
    }
}

// MARK: - Status model (reads the files the Claude Code hook writes)

final class StatusModel {
    struct Session { var id: String; var state: String; var since: Double; var workStart: Double; var updated: Double; var tool: String }

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/claudebar/sessions")
    static let doneHold: Double = 60         // wave the flag this long, then go back to idle
    static let staleWorking: Double = 20 * 60

    private(set) var mood: Mood = .idle
    private(set) var animStart = CACurrentMediaTime()
    private(set) var sessions: [Session] = []
    private var lastPoll = 0.0
    private var preview: (mood: Mood, until: Double)?
    var onMoodChange: ((Mood) -> Void)?

    func tick() {
        let now = CACurrentMediaTime()
        guard now - lastPoll >= 0.4 else { return }
        lastPoll = now
        sessions = Self.readSessions()
        var m = computeMood()
        if let p = preview {
            if now < p.until { m = p.mood } else { preview = nil }
        }
        setMood(m)
    }

    func startPreview(_ m: Mood) {
        preview = (m, CACurrentMediaTime() + (m == .done ? 20 : 12))
        mood = m == .idle ? .working : .idle   // force a change so the animation restarts
        lastPoll = 0
        tick()
    }

    private func setMood(_ m: Mood) {
        guard m != mood else { return }
        mood = m
        animStart = CACurrentMediaTime()
        onMoodChange?(m)
    }

    private static func readSessions() -> [Session] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Session] = []
        for f in files where !f.hasPrefix(".") {
            let url = dir.appendingPathComponent(f)
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 4).map(String.init)
            guard parts.count >= 4, let since = Double(parts[1]), let ws = Double(parts[2]), let up = Double(parts[3]) else { continue }
            if now - up > 12 * 3600 { try? fm.removeItem(at: url); continue }   // abandoned session
            out.append(Session(id: f, state: parts[0], since: since, workStart: ws, updated: up, tool: parts.count > 4 ? parts[4] : ""))
        }
        return out
    }

    var working: [Session] {
        let now = Date().timeIntervalSince1970
        return sessions.filter { $0.state == "working" && now - $0.updated < Self.staleWorking }
    }
    var waiting: [Session] { sessions.filter { $0.state == "waiting" } }
    var done: [Session] {
        let now = Date().timeIntervalSince1970
        return sessions.filter { $0.state == "done" && now - $0.since < Self.doneHold }
    }

    private func computeMood() -> Mood {
        if !waiting.isEmpty { return .waiting }
        if !working.isEmpty { return .working }
        if !done.isEmpty { return .done }
        return .idle
    }

    // MARK: Details (shown when you tap the mascot)

    private let reader = TranscriptReader()
    private var detailCache: (at: Double, details: SessionDetails?, limits: Limits?)?

    /// The session the bar is currently about: the one driving the mood, else the most recent.
    var focusSession: Session? {
        let group: [Session]
        switch mood {
        case .waiting: group = waiting
        case .working: group = working
        case .done: group = done
        case .idle: group = sessions
        }
        return (group.isEmpty ? sessions : group).max { $0.updated < $1.updated }
    }

    func detailInfo() -> (SessionDetails?, Limits?) {
        let now = CACurrentMediaTime()
        if let c = detailCache, now - c.at < 1 { return (c.details, c.limits) }
        var d: SessionDetails?
        let sid = focusSession?.id
        if let sid {
            let meta = Self.dir.deletingLastPathComponent().appendingPathComponent("meta/\(sid)")
            if let lines = try? String(contentsOf: meta, encoding: .utf8).split(separator: "\n").map(String.init),
               let path = lines.first {
                d = reader.details(transcript: path, cwd: lines.count > 1 ? lines[1] : "")
            }
        }
        let l = Limits.read(sessionId: sid)
        detailCache = (now, d, l)
        return (d, l)
    }

    // MARK: Text for the bar

    func scene() -> Scene {
        let t = CACurrentMediaTime() - animStart
        let now = Date().timeIntervalSince1970
        let isPreview = preview != nil
        switch mood {
        case .idle:
            return Scene(mood: .idle, t: t, title: "Ready", subtitle: "Waiting for your prompt")
        case .waiting:
            let n = waiting.count
            return Scene(mood: .waiting, t: t, title: "Needs you",
                         subtitle: n > 1 ? "\(n) sessions are asking for permission" : "Claude is asking for permission")
        case .working:
            let dots = String(repeating: ".", count: Int(t * 2.5) % 4)
            let w = working.sorted { $0.updated > $1.updated }
            var sub: String
            if let s = w.first, !isPreview {
                sub = "\(Self.label(for: s.tool)) · \(Self.duration(now - s.workStart))"
                if w.count > 1 { sub += " · \(w.count) sessions" }
            } else {
                sub = "Editing files · \(Self.duration(t))"
            }
            // A new spinner verb every few seconds, starting somewhere different each prompt.
            let seed = Int(working.first?.workStart ?? 0) % SpinnerVerbs.all.count
            let verb = SpinnerVerbs.all[(seed + Int(t / 3.2) * 11) % SpinnerVerbs.all.count]  // 11 is coprime with the count, so every verb comes up
            return Scene(mood: .working, t: t, title: verb + dots, subtitle: sub)
        case .done:
            var sub = "All finished"
            if let s = done.max(by: { $0.since < $1.since }), !isPreview, s.workStart > 0, s.since > s.workStart {
                sub = "Finished in \(Self.duration(s.since - s.workStart))"
            }
            return Scene(mood: .done, t: t, title: "Done!", subtitle: sub)
        }
    }

    static func label(for tool: String) -> String {
        switch tool {
        case "": return "Thinking"
        case "Bash", "BashOutput", "KillShell": return "Running a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing files"
        case "Read": return "Reading files"
        case "Grep", "Glob", "LS": return "Searching the code"
        case "WebFetch", "WebSearch": return "Browsing the web"
        case "Task", "Agent": return "Running a subagent"
        case "TodoWrite": return "Planning"
        default: return tool.hasPrefix("mcp__") ? "Using a tool" : tool
        }
    }

    static func duration(_ s: Double) -> String {
        let s = Int(max(0, s))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

// MARK: - Spinner verbs (the playful words Claude Code shows while it works)

enum SpinnerVerbs {
    static let all = [
        "Thinking", "Pondering", "Cogitating", "Brewing", "Clauding", "Combobulating",
        "Noodling", "Percolating", "Ruminating", "Schlepping", "Simmering", "Finagling",
        "Moseying", "Mulling", "Musing", "Marinating", "Conjuring", "Crafting", "Forging",
        "Hatching", "Herding", "Honking", "Hustling", "Ideating", "Manifesting", "Mustering",
        "Puttering", "Reticulating", "Shucking", "Smooshing", "Stewing", "Synthesizing",
        "Transmuting", "Vibing", "Whirring", "Churning", "Crunching", "Deliberating",
        "Spelunking", "Tinkering", "Wrangling", "Doodling",
    ]
}

// MARK: - Views

final class MascotView: NSView {
    let model: StatusModel
    let compact: Bool
    var onTap: (() -> Void)?
    /// Full bar only: show model / context / usage instead of the status text.
    var detailsUntil: Double = 0
    var showingDetails: Bool { !compact && CACurrentMediaTime() < detailsUntil }
    func toggleDetails() { detailsUntil = showingDetails ? 0 : CACurrentMediaTime() + 15 }

    init(model: StatusModel, compact: Bool) {
        self.model = model
        self.compact = compact
        super.init(frame: NSRect(x: 0, y: 0, width: compact ? 46 : MascotView.fullWidth, height: 30))
        wantsLayer = true
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    static let fullWidth: CGFloat = 540
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: compact ? 46 : Self.fullWidth, height: 30) }

    @objc private func tapped() { onTap?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        if showingDetails {
            Renderer.draw(c, bounds: NSRect(x: 0, y: 0, width: 46, height: bounds.height), scene: model.scene(), compact: true)
            let (d, l) = model.detailInfo()
            DetailsRenderer.draw(c, bounds: bounds, details: d, limits: l)
        } else {
            Renderer.draw(c, bounds: bounds, scene: model.scene(), compact: compact)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
    let model = StatusModel()
    let trayId = NSTouchBarItem.Identifier("com.claudebar.tray")
    let mainId = NSTouchBarItem.Identifier("com.claudebar.main")
    var bar: NSTouchBar!
    var trayView: MascotView!
    var fullView: MascotView!
    var statusItem: NSStatusItem!
    var timer: Timer?
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    var autoShow: Bool {
        get { UserDefaults.standard.object(forKey: "autoShow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoShow") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        Renderer.workingTitleWidth = SpinnerVerbs.all
            .map { NSAttributedString(string: $0 + "...", attributes: [.font: titleFont]).size().width }
            .max() ?? 82
        fullView = MascotView(model: model, compact: false)
        fullView.widthAnchor.constraint(equalToConstant: MascotView.fullWidth).isActive = true
        trayView = MascotView(model: model, compact: true)
        trayView.widthAnchor.constraint(equalToConstant: 46).isActive = true
        trayView.onTap = { [weak self] in
            self?.showBar()
            self?.fullView.detailsUntil = CACurrentMediaTime() + 15
        }
        fullView.onTap = { [weak self] in self?.fullView.toggleDetails() }

        bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [mainId]

        let tray = NSCustomTouchBarItem(identifier: trayId)
        tray.view = trayView
        PrivateTouchBar.addSystemTrayItem(tray)
        PrivateTouchBar.setControlStripPresence(trayId, true)
        PrivateTouchBar.showCloseBox(true)

        setupMenuBar()

        model.onMoodChange = { [weak self] m in
            guard let self, self.autoShow, m != .idle else { return }
            self.showBar()
        }
        model.tick()
        showBar()

        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func frame() {
        model.tick()
        fullView.needsDisplay = true
        trayView.needsDisplay = true
    }

    @objc func showBar() { PrivateTouchBar.present(bar, trayId: trayId) }
    @objc func hideBar() { PrivateTouchBar.minimize(bar) }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard id == mainId else { return nil }
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = fullView
        return item
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show on Touch Bar", action: #selector(showBar), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Hide from Touch Bar", action: #selector(hideBar), keyEquivalent: "").target = self
        let auto = menu.addItem(withTitle: "Pop up when status changes", action: #selector(toggleAuto(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoShow ? .on : .off
        menu.addItem(.separator())
        let previewMenu = NSMenu()
        for (title, m) in [("Idle", Mood.idle), ("Building", .working), ("Needs you", .waiting), ("Done + flag", .done)] {
            let it = previewMenu.addItem(withTitle: title, action: #selector(preview(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
        }
        let p = menu.addItem(withTitle: "Preview animation", action: nil, keyEquivalent: "")
        menu.setSubmenu(previewMenu, for: p)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClaudeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let s = model.scene()
        statusLine.title = "\(s.title.trimmingCharacters(in: CharacterSet(charactersIn: "."))) — \(s.subtitle)"
    }

    @objc private func toggleAuto(_ sender: NSMenuItem) {
        autoShow.toggle()
        sender.state = autoShow ? .on : .off
    }

    @objc private func preview(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mood(rawValue: raw) else { return }
        showBar()
        model.startPreview(m)
    }

    private static func menuIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 26, height: 18), flipped: true) { r in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            Renderer.draw(c, bounds: r.insetBy(dx: 0, dy: 0), scene: Scene(mood: .idle, t: 0, title: "", subtitle: ""), compact: true)
            return true
        }
        return img
    }
}

// `ClaudeBar --version` style CLI flags are not needed; just run the app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
