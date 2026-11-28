import Cocoa

// Choosing the model and effort from the details view.
// A running session gets the matching slash command typed into its Terminal tab.
// With no session running, the choice is saved and used by the next one started from the bar.

enum Choice: String {
    case model, effort

    var options: [String] {
        switch self {
        case .model: return ["fable", "opus", "sonnet", "haiku"]
        case .effort: return ["low", "medium", "high", "xhigh", "max"]
        }
    }

    private var key: String { self == .model ? "nextModel" : "nextEffort" }

    /// What the next session started from the bar will use; nil means Claude Code's own default.
    var next: String? {
        get { UserDefaults.standard.string(forKey: key).flatMap { options.contains($0) ? $0 : nil } }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var launchFlags: String {
        [Choice.model, .effort].compactMap { c in c.next.map { " --\(c.rawValue) \($0)" } }.joined()
    }

    static func title(_ option: String) -> String {
        option == "xhigh" ? "XHigh" : option.prefix(1).uppercased() + option.dropFirst()
    }
}

struct Picker {
    enum Action { case page(Choice), choose(String?), close }
    struct Button { var rect: CGRect; var title: String; var selected: Bool; var action: Action }

    var sessionId: String?          // nil: choosing for the next session
    var page = Choice.model

    func buttons(in bounds: CGRect, details d: SessionDetails?) -> [Button] {
        var out: [Button] = []
        var x = bounds.minX + 54
        func add(_ title: String, _ width: CGFloat, _ selected: Bool, _ action: Action) {
            out.append(Button(rect: CGRect(x: x, y: bounds.minY, width: width, height: bounds.height),
                              title: title, selected: selected, action: action))
            x += width
        }
        add("Model", 54, page == .model, .page(.model))
        add("Effort", 54, page == .effort, .page(.effort))
        x += 10
        // "Default" only makes sense before a session starts.
        let options: [String?] = (sessionId == nil ? [nil] : []) + page.options.map { $0 }
        let width = (bounds.maxX - x - 30) / CGFloat(options.count)
        for o in options {
            let selected: Bool
            if sessionId == nil { selected = page.next == o }
            else if page == .model { selected = o.map { d?.model.contains($0) ?? false } ?? false }
            else { selected = d?.effort == o }
            add(o.map(Choice.title) ?? "Default", width, selected, .choose(o))
        }
        add("✕", 30, false, .close)
        return out
    }

    func draw(_ c: CGContext, bounds: CGRect, details: SessionDetails?) {
        let clay = CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        for b in buttons(in: bounds, details: details) {
            var isTab = false
            if case .page = b.action { isTab = true }
            let r = b.rect.insetBy(dx: 1.5, dy: 1)
            // Tabs are outlined by a lighter fill; the current option is orange.
            c.setFillColor(b.selected ? (isTab ? CGColor(gray: 1, alpha: 0.35) : clay) : CGColor(gray: 1, alpha: isTab ? 0.08 : 0.17))
            c.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
            c.fillPath()
            let a = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.white])
            let size = a.size()
            a.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }
    }
}

enum TerminalTyper {
    /// Types a line into the Terminal tab on `tty`, and brings that tab forward so the result
    /// (or any confirmation Claude Code asks for) is visible. macOS asks for permission once.
    static func type(_ line: String, tty: String, done: @escaping (_ error: String?) -> Void) {
        let script = """
        on run argv
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is (item 1 of argv) then
                            do script (item 2 of argv) in t
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
        end run
        """
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, tty, line]
        p.standardOutput = out
        p.standardError = err
        p.terminationHandler = { p in
            let said = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let failed = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var error: String?
            if p.terminationStatus != 0 {
                NSLog("Touchbar Claude: osascript failed: %@", failed)
                error = failed.contains("-1743") ? "Allow it in Privacy settings → Automation" : "Couldn't type into Terminal"
            } else if !said.hasPrefix("ok") {
                error = "Couldn't find that Terminal tab"
            }
            DispatchQueue.main.async { done(error) }
        }
        do { try p.run() } catch { done("Couldn't type into Terminal") }
    }

    /// The terminal device a process is attached to, e.g. "/dev/ttys003".
    static func tty(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_tdev != -1,
              let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}

/// The "Stretch timer?" buttons drawn on the right of the bar while the mascot asks.
enum StretchPrompt {
    static let options: [(title: String, minutes: Int)] = [("5m", 5), ("10m", 10), ("15m", 15), ("Skip", 0)]

    static func rects(in bounds: CGRect) -> [CGRect] {
        let w: CGFloat = 44, gap: CGFloat = 4
        var x = bounds.maxX - 6 - (CGFloat(options.count) * w + CGFloat(options.count - 1) * gap)
        var out: [CGRect] = []
        for _ in options {
            out.append(CGRect(x: x, y: bounds.minY + 3, width: w, height: bounds.height - 6))
            x += w + gap
        }
        return out
    }

    static func draw(_ c: CGContext, bounds: CGRect) {
        for (r, o) in zip(rects(in: bounds), options) {
            c.setFillColor(o.minutes == 0 ? CGColor(gray: 1, alpha: 0.12)
                           : CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
            c.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
            c.fillPath()
            let a = NSAttributedString(string: o.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.white])
            let s = a.size()
            a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }

    /// The minutes of the button under x (0 = Skip), or nil if x is not on a button.
    static func minutes(at x: CGFloat, in bounds: CGRect) -> Int? {
        for (r, o) in zip(rects(in: bounds), options) where x >= r.minX && x < r.maxX { return o.minutes }
        return nil
    }
}
