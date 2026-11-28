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
    /// False when a tap would start a new session instead of jumping to one.
    private var canJump = false
    /// With no session the mascot roams without text; a tap shows the text for a few seconds.
    var roaming: Bool { mood == .idle && !canJump && clock >= promptUntil }
    /// While the mascot is being petted the idle animation is paused, so it stays under your finger.
    private var petStart: Double?
    private var petEnd = 0.0
    /// After this long with nothing happening the mascot dozes off. The idle animation pauses too,
    /// so it sleeps (and wakes up) where it stopped.
    static let napAfter: Double = 2 * 60
    private var napStart: Double?
    private var lastActivity = CACurrentMediaTime()
    private var clock: Double { petStart ?? napStart ?? CACurrentMediaTime() }
    var isPetted: Bool { petStart != nil }
    private var wasRoaming = false
    private var roamStart = 0.0
    private var promptStart = 0.0
    private var promptUntil = 0.0
    private var slideFrom: CGFloat = 0
    private var preview: (mood: Mood, warning: Warning?, until: Double)?
    private var warning: Warning?
    private var lastWarningCheck = 0.0
    /// Little moments: a stretch after an hour of Claude working, a yawn on the first idle look each morning.
    enum Moment { case stretch, yawn }
    private var moment: (kind: Moment, start: Double)?
    private var workedFor = 0.0
    private var lastFrame = CACurrentMediaTime()
    static let stretchEvery: Double = 60 * 60
    /// The "Stretch timer?" prompt: when it was shown, and when the countdown the user started ends.
    private(set) var stretchOffer: Double?
    private(set) var stretchEnds: Double?
    static let offerFor: Double = 20          // seconds before an ignored prompt goes away
    static let stretchCycle: Double = 30      // while a timer runs, the mascot stretches this often
    var onAlert: (() -> Void)?                // asks the app to show the bar
    var offeringStretch: Bool { stretchOffer != nil }
    var stretchRunning: Bool { stretchEnds != nil }
    var onMoodChange: ((Mood) -> Void)?

    func tick() {
        defer {
            if roaming && !wasRoaming { roamStart = CACurrentMediaTime() }   // always set off from home
            wasRoaming = roaming
        }
        let now = CACurrentMediaTime()
        if petStart != nil, now >= petEnd { endPet() }
        updateMoments(now)
        guard now - lastPoll >= 0.4 else { return }
        lastPoll = now
        sessions = Self.readSessions()
        let couldJump = canJump
        canJump = sessions.contains { Self.hostApp(of: $0.id) != nil }
        if canJump != couldJump { wake() }          // a session started or ended
        var m = computeMood()
        if let p = preview {
            if now < p.until { m = p.mood } else { preview = nil; wake() }
        }
        setMood(m)
        if let p = preview {
            warning = p.warning
            lastWarningCheck = 0          // go back to the real value as soon as the preview ends
        } else if now - lastWarningCheck >= 2 {
            lastWarningCheck = now
            warning = currentWarning()
        }
        if preview == nil { updateNap(now) }
    }

    private func updateMoments(_ now: Double) {
        let dt = now - lastFrame
        lastFrame = now
        guard dt < 5 else { return }                 // the Mac was asleep: don't count the gap
        if mood == .working { workedFor += dt }
        if let ends = stretchEnds, now >= ends {     // the user's countdown finished
            stretchEnds = nil
            moment = (.stretch, now)
            onAlert?()
        }
        if let m = moment {
            if now - m.start > (m.kind == .stretch ? stretchDuration : yawnDuration) { moment = nil }
            return
        }
        if let offer = stretchOffer {
            if mood != .idle {                       // Claude got busy: ask again at the next quiet moment
                stretchOffer = nil
                workedFor = Self.stretchEvery
            } else if now - offer > Self.offerFor {  // ignored: wait another hour
                stretchOffer = nil
            }
            return
        }
        guard mood == .idle, preview == nil, petStart == nil, napStart == nil else { return }
        if workedFor >= Self.stretchEvery {
            workedFor = 0
            stretchOffer = now
            onAlert?()
        } else if Self.yawnDue() {
            Self.markYawned()
            moment = (.yawn, now)
        }
    }

    private static func yawnDue() -> Bool {
        let cal = Calendar.current
        guard (6..<11).contains(cal.component(.hour, from: Date())) else { return false }
        let today = cal.startOfDay(for: Date()).timeIntervalSince1970
        return UserDefaults.standard.double(forKey: "yawnDay") != today
    }

    private static func markYawned() {
        UserDefaults.standard.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: "yawnDay")
    }

    /// The user's answer to the prompt. 0 minutes skips it.
    func chooseStretch(minutes: Int) {
        stretchOffer = nil
        if minutes > 0 { stretchEnds = CACurrentMediaTime() + Double(minutes) * 60 }
    }

    func cancelStretchTimer() { stretchEnds = nil }

    func previewStretchOffer() {
        startPreview(.idle)
        stretchOffer = CACurrentMediaTime()
    }

    /// m:ss, rounded up so the last second still shows.
    static func mmss(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func previewMoment(_ kind: Moment) {
        startPreview(.idle)
        moment = (kind, CACurrentMediaTime())
    }

    private func updateNap(_ now: Double) {
        // A warning shown next to an open session matters more than a nap.
        if canJump && warning != nil { wake(); return }
        if mood == .idle, petStart == nil, napStart == nil, now - lastActivity >= Self.napAfter {
            napStart = now
        }
    }

    /// Something happened: wake up if dozing, and start counting the quiet time again.
    func wake() {
        lastActivity = CACurrentMediaTime()
        guard let start = napStart else { return }
        shiftClocks(by: lastActivity - start)
        napStart = nil
    }

    func previewNap() {
        startPreview(.idle)
        napStart = CACurrentMediaTime()
    }

    private func currentWarning() -> Warning? {
        // Context belongs to one session, so only warn while that session is still running.
        let sid = focusSession.map(\.id).flatMap { Self.hostApp(of: $0) != nil ? $0 : nil }
        guard let l = Limits.read(sessionId: sid) else { return nil }
        return Warning.from(l, context: l.context)
    }

    func startPreview(_ m: Mood, warning: Warning? = nil) {
        preview = (m, warning, CACurrentMediaTime() + (m == .done ? 20 : 12))
        mood = m == .idle ? .working : .idle   // force a change so the animation restarts
        lastPoll = 0
        tick()
    }

    private func setMood(_ m: Mood) {
        guard m != mood else { return }
        endPet()
        wake()
        mood = m
        animStart = CACurrentMediaTime()
        onMoodChange?(m)
    }

    /// Called while a finger strokes the mascot. It stays happy for a moment after the last stroke.
    func pet() {
        guard mood == .idle else { return }          // not while it's busy
        wake()
        let now = CACurrentMediaTime()
        if petStart == nil { petStart = now }
        petEnd = now + 2
    }

    /// Moves the animation clocks forward by the pause, so it carries on from where it stopped.
    private func endPet() {
        guard let start = petStart else { return }
        shiftClocks(by: CACurrentMediaTime() - start)
        petStart = nil
        lastActivity = CACurrentMediaTime()
    }

    private func shiftClocks(by paused: Double) {
        animStart += paused
        roamStart += paused
        promptStart += paused
        promptUntil += paused
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
        let sid = (liveSession ?? focusSession)?.id
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

    // MARK: Jump to the session (tap)

    /// A tap on the full bar. While roaming, the first tap only shows "Tap to start Claude";
    /// a tap after that opens Claude.
    func tap() {
        wake()
        guard roaming else { openClaude(); return }
        promptStart = CACurrentMediaTime()
        promptUntil = promptStart + 6
        slideFrom = Renderer.roamX
        wasRoaming = false
    }

    /// Brings the app running a Claude session to the front (Terminal, iTerm, VS Code, Claude...).
    /// With no session running, starts a new one in Terminal.
    func openClaude() {
        wake()
        if let s = liveSession, let app = Self.hostApp(of: s.id) {
            app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            return
        }
        startSession()
    }

    /// The running session the bar acts on: the one it is about, else the newest.
    var liveSession: Session? {
        let focus = focusSession
        let others = sessions.filter { $0.id != focus?.id }.sorted { $0.updated > $1.updated }
        return ((focus.map { [$0] } ?? []) + others).first { Self.hostApp(of: $0.id) != nil }
    }

    /// Types `/model x` or `/effort x` into a session's Terminal tab. `report` gets a line for the bar.
    func send(_ choice: Choice, _ option: String, to sid: String, report: @escaping (String) -> Void) {
        sessions = Self.readSessions()          // the state must be current before typing anything
        guard let s = sessions.first(where: { $0.id == sid }), let app = Self.hostApp(of: sid),
              let pid = Self.claudePid(of: sid) else { return report("That session has ended") }
        // Only at the prompt: typing into a permission question could answer it.
        guard s.state == "idle" || s.state == "done" else { return report("Claude is busy · try when it's done") }
        guard app.bundleIdentifier == "com.apple.Terminal", let tty = TerminalTyper.tty(of: pid) else {
            return report("Switching only works in Terminal")
        }
        let line = "/\(choice.rawValue) \(option)"
        TerminalTyper.type(line, tty: tty) { error in report(error ?? "Sent \(line)") }
    }

    /// The Claude process of a session, or nil if it has exited. It is the first pid recorded
    /// by the hook; the rest are its ancestors (shell, terminal app).
    private static func claudePid(of sid: String) -> pid_t? {
        let lines = metaLines(sid)
        let first = (lines.count > 3 ? lines[3] : "").split(separator: " ").first.flatMap { pid_t($0) }
        return first.flatMap { kill($0, 0) == 0 ? $0 : nil }
    }

    private static func metaLines(_ sid: String) -> [String] {
        let meta = dir.deletingLastPathComponent().appendingPathComponent("meta/\(sid)")
        return (try? String(contentsOf: meta, encoding: .utf8))?.components(separatedBy: "\n") ?? []
    }

    /// The app hosting a session, or nil if that session's process has exited.
    private static func hostApp(of sid: String) -> NSRunningApplication? {
        guard let claude = claudePid(of: sid) else { return nil }
        let lines = metaLines(sid)
        if let app = guiApp(above: claude) { return app }
        guard lines.count > 2, !lines[2].isEmpty else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: lines[2]).first
    }

    private var lastStart = -Double.infinity

    /// Opens a new Terminal window in the home folder and runs `claude`. Uses a .command
    /// file, so macOS doesn't ask for Automation permission.
    private func startSession() {
        // A new session takes a moment to report in; don't open a second window meanwhile.
        let now = CACurrentMediaTime()
        guard now - lastStart >= 5 else { return }
        lastStart = now

        let script = Self.dir.deletingLastPathComponent().appendingPathComponent("new-session.command")
        // Login + interactive shell so `claude` is on PATH; the window stays usable after it exits.
        let body = "#!/bin/zsh -il\ncd ~\nclear\nclaude\(Choice.launchFlags)\nexec /bin/zsh -il\n"
        do {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            NSLog("Touchbar Claude: couldn't write %@: %@", script.path, error.localizedDescription)
            return
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("Touchbar Claude: couldn't open Terminal: %@", error.localizedDescription) }
        }
    }

    private static func guiApp(above pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<20 where p > 1 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            p = parentPid(p)
        }
        return nil
    }

    private static func parentPid(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // MARK: Text for the bar

    func scene() -> Scene {
        var s = moodScene()
        // Stays put (no strolling) while a prompt, a timer or the end-of-timer stretch is on screen.
        if s.mood == .idle && (stretchEnds != nil || stretchOffer != nil || moment?.kind == .stretch) { s.still = true }
        if let start = napStart {
            s.nap = CACurrentMediaTime() - start
            if !s.roaming { s.title = "Napping"; s.subtitle = "Tap to wake Claude" }
            return s
        }
        if let start = petStart {
            s.pet = CACurrentMediaTime() - start
            if !s.roaming { s.title = "Hehe!"; s.subtitle = "Claude loves the pats" }
            return s                   // too happy to be tired or stressed
        }
        if let m = moment {
            let elapsed = CACurrentMediaTime() - m.start
            switch m.kind {
            case .stretch:
                s.stretch = elapsed
                if !s.roaming { s.title = "Stretch break"; s.subtitle = "Rest your eyes and roll your shoulders" }
            case .yawn:
                s.yawn = elapsed
                if !s.roaming { s.title = "Good morning"; s.subtitle = "Yawn... let's get going" }
            }
            return s
        }
        if stretchOffer != nil {
            s.title = "Stretch timer?"; s.subtitle = ""; s.roaming = false
            return s
        }
        if let ends = stretchEnds {
            let left = Self.mmss(ends - CACurrentMediaTime())
            if s.mood == .working { s.subtitle += " · stretch in \(left)" }
            if s.mood == .idle {
                s.title = "Stretch timer"; s.subtitle = "\(left) left"; s.roaming = false
                let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.stretchCycle)
                if phase < stretchDuration { s.stretch = phase }     // a stretch every cycle
            }
        }
        guard let w = warning else { return s }
        s.health = w.health
        switch s.mood {
        case .idle where canJump || preview != nil:
            s.title = w.health == .tired ? "Tired" : "Stressed"
            s.subtitle = w.text
            s.roaming = false
        case .working:
            s.subtitle += " · " + w.short
        default:
            break                      // keep "Needs you", "Done!" and "Tap to start Claude"
        }
        return s
    }

    private func moodScene() -> Scene {
        let t = clock - animStart
        let now = Date().timeIntervalSince1970
        let isPreview = preview != nil
        switch mood {
        case .idle:
            if canJump { return Scene(mood: .idle, t: t, title: "Ready", subtitle: "Waiting for your prompt") }
            let prompting = clock < promptUntil
            return Scene(mood: .idle, t: clock - (prompting ? promptStart : roamStart), title: "Ready",
                         subtitle: "Tap to start Claude", roaming: !prompting,
                         slideFrom: prompting ? slideFrom : 0)
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
    // Only words of similar width (about 65-86 pt at the title font), so the subtitle column
    // stays tight: no gap left by one very long word, no tiny ones that look lost.
    static let all = [
        "Forging", "Herding", "Stewing", "Brewing", "Ideating", "Crafting", "Honking",
        "Hustling", "Whirring", "Thinking", "Clauding", "Doodling", "Noodling", "Hatching",
        "Finagling", "Churning", "Shucking", "Puttering", "Tinkering", "Moseying", "Conjuring",
        "Mustering", "Wrangling", "Pondering", "Crunching", "Cogitating", "Marinating", "Simmering",
    ]
}

// MARK: - Views

final class MascotView: NSView {
    let model: StatusModel
    let compact: Bool
    var onTap: ((CGFloat) -> Void)?     // x position of the tap
    var onLongPress: (() -> Void)?
    private var swallowTap = false
    /// The current finger drag: the furthest point in this direction, and how often it has turned.
    private var stroke = (edge: CGFloat(0), direction: CGFloat(0), turns: 0)
    /// Full bar only: show model / context / usage instead of the status text.
    var detailsUntil: Double = 0
    var showingDetails: Bool { !compact && CACurrentMediaTime() < detailsUntil }
    func toggleDetails() { picker = nil; notice = nil; detailsUntil = showingDetails ? 0 : CACurrentMediaTime() + 15 }
    private var picker: Picker?
    private var notice: (text: String, until: Double)?

    /// A tap in the details view: the model opens the picker, anywhere else goes to Claude.
    func detailsTap(_ x: CGFloat) {
        detailsUntil = CACurrentMediaTime() + 15
        notice = nil
        if var p = picker {
            let hit = p.buttons(in: bounds, details: model.detailInfo().0).first { x >= $0.rect.minX && x < $0.rect.maxX }
            switch hit?.action {
            case .page(let page): p.page = page; picker = p
            case .choose(let option):
                picker = nil
                if let sid = p.sessionId, let option {
                    model.send(p.page, option, to: sid) { [weak self] text in
                        self?.notice = (text, CACurrentMediaTime() + 4)
                    }
                } else {
                    p.page.next = option
                }
            case .close: picker = nil
            case nil: break
            }
            return
        }
        let live = model.liveSession
        let chipEnd: CGFloat = live == nil ? DetailsRenderer.nextChipEnd : DetailsRenderer.modelChipEnd
        if x >= 54 && x < chipEnd { picker = Picker(sessionId: live?.id) } else { model.openClaude() }
    }

    init(model: StatusModel, compact: Bool) {
        self.model = model
        self.compact = compact
        super.init(frame: NSRect(x: 0, y: 0, width: compact ? 46 : MascotView.fullWidth, height: 30))
        wantsLayer = true
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)
        let hold = NSPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.allowedTouchTypes = .direct
        hold.minimumPressDuration = 0.45
        addGestureRecognizer(hold)
        if !compact {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(stroked(_:)))
            pan.allowedTouchTypes = .direct
            addGestureRecognizer(pan)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static let fullWidth: CGFloat = 540
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: compact ? 46 : Self.fullWidth, height: 30) }

    @objc private func tapped(_ g: NSClickGestureRecognizer) {
        if swallowTap { swallowTap = false; return }   // the finger-up that ended a long press
        onTap?(g.location(in: self).x)
    }

    @objc private func held(_ g: NSPressGestureRecognizer) {
        guard g.state == .began, !model.isPetted else { return }
        swallowTap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.swallowTap = false }
        model.wake()
        onLongPress?()
    }

    /// Petting: drag a finger back and forth over the mascot.
    @objc private func stroked(_ g: NSPanGestureRecognizer) {
        let x = g.location(in: self).x
        switch g.state {
        case .began:
            stroke = (x, 0, 0)
            swallowTap = true              // a stroke is not a tap
        case .changed:
            let moved = x - stroke.edge
            if stroke.direction == 0 {
                if abs(moved) > 5 { stroke = (x, moved > 0 ? 1 : -1, 0) }
            } else if moved * stroke.direction > 0 {
                stroke.edge = x
            } else if abs(moved) > 5 {
                stroke = (x, -stroke.direction, stroke.turns + 1)
            }
            // Two turns (there, back and there again), close to the mascot.
            if stroke.turns >= 2, !showingDetails, abs(x - Renderer.mascotCentre) < 45 { model.pet() }
        case .ended, .cancelled, .failed:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.swallowTap = false }
        default:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        if showingDetails {
            Renderer.draw(c, bounds: NSRect(x: 0, y: 0, width: 46, height: bounds.height), scene: model.scene(), compact: true)
            let (d, l) = model.detailInfo()
            if let n = notice, CACurrentMediaTime() < n.until {
                DetailsRenderer.drawNotice(bounds: bounds, n.text)
            } else if let picker {
                picker.draw(c, bounds: bounds, details: d)
            } else if model.liveSession == nil {
                DetailsRenderer.drawNext(c, bounds: bounds)
            } else {
                DetailsRenderer.draw(c, bounds: bounds, details: d, limits: l)
            }
        } else {
            picker = nil
            Renderer.draw(c, bounds: bounds, scene: model.scene(), compact: compact)
            if !compact && model.offeringStretch { StretchPrompt.draw(c, bounds: bounds) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
    let model = StatusModel()
    let trayId = NSTouchBarItem.Identifier("com.touchbarclaude.tray")
    let mainId = NSTouchBarItem.Identifier("com.touchbarclaude.main")
    var bar: NSTouchBar!
    var trayView: MascotView!
    var fullView: MascotView!
    var statusItem: NSStatusItem!
    var timer: Timer?
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let stretchItem = NSMenuItem(title: "Cancel stretch timer", action: nil, keyEquivalent: "")

    /// Bring the bar back on every status change, Ready included. Closing it with ✕ (or Hide)
    /// still works: it stays closed until Claude's status next changes.
    var keepShowing: Bool {
        get { UserDefaults.standard.object(forKey: "keepShowing") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepShowing") }
    }
    let keepItem = NSMenuItem(title: "Keep on Touch Bar", action: nil, keyEquivalent: "")
    /// While any screenshot UI is on screen (⌘⇧3 thumbnail, ⌘⇧4 crosshair, ⌘⇧5 toolbar, ⌘⇧6),
    /// the bar steps aside so the Touch Bar shows the screenshot controls (Cancel, Options...).
    private var steppedAside = false
    private var lastScreenshotCheck = 0.0
    private static let screenshotApps: Set<String> = ["com.apple.screencaptureui", "com.apple.screencapture", "com.apple.Screenshot"]

    /// Checks window owners only (no window titles or contents, so no Screen Recording permission).
    private static func screenshotOnScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            let name = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            if name.contains("screencapture") || name == "screenshot" { return true }
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return screenshotApps.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
        }
    }

    private func checkScreenshot() {
        let now = CACurrentMediaTime()
        guard now - lastScreenshotCheck > 0.4 else { return }
        lastScreenshotCheck = now
        let on = Self.screenshotOnScreen()
        if on, !steppedAside {
            steppedAside = true
            PrivateTouchBar.minimize(bar)
        } else if !on, steppedAside {
            steppedAside = false
            if keepShowing { showBar() }
        }
    }

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
        // Tap: jump to the running Claude session, or start one. Long-press: model / context / usage details.
        trayView.onTap = { [weak self] _ in self?.showBar() }
        trayView.onLongPress = { [weak self] in
            self?.showBar()
            self?.fullView.detailsUntil = CACurrentMediaTime() + 15
        }
        fullView.onTap = { [weak self] x in
            guard let self else { return }
            if self.fullView.showingDetails {
                self.fullView.detailsTap(x)
            } else if self.model.offeringStretch, let minutes = StretchPrompt.minutes(at: x, in: self.fullView.bounds) {
                self.model.chooseStretch(minutes: minutes)
            } else {
                self.model.tap()
            }
        }
        fullView.onLongPress = { [weak self] in self?.fullView.toggleDetails() }

        bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [mainId]

        let tray = NSCustomTouchBarItem(identifier: trayId)
        tray.view = trayView
        PrivateTouchBar.addSystemTrayItem(tray)
        PrivateTouchBar.setControlStripPresence(trayId, true)
        PrivateTouchBar.showCloseBox(false)   // no ✕: hide the bar from the menu bar icon instead

        setupMenuBar()

        model.onMoodChange = { [weak self] m in
            guard let self, !self.steppedAside else { return }
            if self.keepShowing || (self.autoShow && m != .idle) { self.showBar() }
        }
        model.onAlert = { [weak self] in self?.showBar() }
        model.tick()
        showBar()

        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func frame() {
        model.tick()
        checkScreenshot()
        fullView.needsDisplay = true
        trayView.needsDisplay = true
    }

    @objc func showBar() { PrivateTouchBar.present(bar, trayId: trayId) }
    @objc func hideBar() { PrivateTouchBar.minimize(bar) }

    @objc private func toggleKeep(_ sender: NSMenuItem) {
        keepShowing.toggle()
        sender.state = keepShowing ? .on : .off
        if keepShowing { showBar() }
    }

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
        keepItem.action = #selector(toggleKeep(_:))
        keepItem.target = self
        keepItem.state = keepShowing ? .on : .off
        menu.addItem(keepItem)
        let auto = menu.addItem(withTitle: "Pop up when status changes", action: #selector(toggleAuto(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoShow ? .on : .off
        menu.addItem(.separator())
        stretchItem.action = #selector(cancelStretch)
        stretchItem.target = self
        menu.addItem(stretchItem)
        let previewMenu = NSMenu()
        for (title, m) in [("Idle", Mood.idle), ("Building", .working), ("Needs you", .waiting), ("Done + flag", .done)] {
            let it = previewMenu.addItem(withTitle: title, action: #selector(preview(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
        }
        for (title, w) in [("Tired (context full)", Warning(health: .tired, text: "Context 85% full · try /compact", short: "context 85%")),
                           ("Stressed (limit)", Warning(health: .stressed, text: "5h limit 91% used · resets in 1h 20m", short: "5h limit 91%"))] {
            let it = previewMenu.addItem(withTitle: title, action: #selector(previewWarning(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = w
        }
        previewMenu.addItem(withTitle: "Napping", action: #selector(previewNap), keyEquivalent: "").target = self
        for (title, kind) in [("Stretch break", StatusModel.Moment.stretch), ("Morning yawn", .yawn)] {
            let it = previewMenu.addItem(withTitle: title, action: #selector(previewMoment(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = kind == .stretch ? "stretch" : "yawn"
        }
        let offer = previewMenu.addItem(withTitle: "Stretch timer prompt", action: #selector(previewMoment(_:)), keyEquivalent: "")
        offer.target = self
        offer.representedObject = "offer"
        let p = menu.addItem(withTitle: "Preview animation", action: nil, keyEquivalent: "")
        menu.setSubmenu(previewMenu, for: p)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Touchbar Claude", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        stretchItem.isHidden = !model.stretchRunning
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

    @objc private func cancelStretch() { model.cancelStretchTimer() }

    @objc private func previewMoment(_ sender: NSMenuItem) {
        showBar()
        switch sender.representedObject as? String {
        case "offer": model.previewStretchOffer()
        case "yawn": model.previewMoment(.yawn)
        default: model.previewMoment(.stretch)
        }
    }

    @objc private func previewNap() {
        showBar()
        model.previewNap()
    }

    @objc private func previewWarning(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? Warning else { return }
        showBar()
        model.startPreview(.idle, warning: w)
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

// `TouchbarClaude --version` style CLI flags are not needed; just run the app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
