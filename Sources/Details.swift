import Cocoa

/// What we know about one Claude Code session, read from its transcript (.jsonl).
struct SessionDetails {
    var model = ""            // e.g. "claude-opus-5-5"
    var effort = ""           // e.g. "medium"
    var contextTokens = 0     // tokens in the context window on the latest request
    var outputTokens = 0      // total tokens Claude has written this session
    var prompts = 0           // messages you sent
    var startedAt: Date?
    var project = ""
    var branch = ""

    var modelName: String { Self.prettyModel(model) }

    /// Context window size: 1M models are marked "[1m]"; otherwise assume 200k unless usage proves bigger.
    var contextLimit: Int {
        if model.contains("[1m]") || contextTokens > 200_000 { return 1_000_000 }
        return 200_000
    }

    static func prettyModel(_ id: String) -> String {
        guard !id.isEmpty else { return "—" }
        var s = id.replacingOccurrences(of: "[1m]", with: "")
        if s.hasPrefix("claude-") { s.removeFirst(7) }
        let parts = s.split(separator: "-").map(String.init)
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}

/// Reads transcripts incrementally (only the bytes appended since the last read).
final class TranscriptReader {
    private struct Cache { var offset: UInt64; var details: SessionDetails; var tail: Data }
    private var cache: [String: Cache] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func details(transcript path: String, cwd: String) -> SessionDetails? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var c = cache[path] ?? Cache(offset: 0, details: SessionDetails(), tail: Data())
        let size = (try? fh.seekToEnd()) ?? 0
        if size < c.offset { c = Cache(offset: 0, details: SessionDetails(), tail: Data()) } // file was rewritten
        if size > c.offset {
            try? fh.seek(toOffset: c.offset)
            let chunk = c.tail + (fh.readDataToEndOfFile())
            c.offset = size
            var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            c.tail = Data(lines.removeLast())   // keep any half-written last line for next time
            for line in lines where !line.isEmpty { apply(Data(line), to: &c.details) }
        }
        if !cwd.isEmpty { c.details.project = (cwd as NSString).lastPathComponent }
        cache[path] = c
        return c.details
    }

    private func apply(_ line: Data, to d: inout SessionDetails) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if d.startedAt == nil, let ts = obj["timestamp"] as? String { d.startedAt = iso.date(from: ts) }
        if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { d.branch = b }
        if (obj["isSidechain"] as? Bool) == true { return }   // subagent traffic: not the main context
        if type == "user", let msg = obj["message"] as? [String: Any] {
            // Count real prompts, not tool results (those are also "user" messages).
            if msg["content"] is String { d.prompts += 1 }
            else if let arr = msg["content"] as? [[String: Any]], arr.contains(where: { $0["type"] as? String == "text" }) { d.prompts += 1 }
        }
        guard type == "assistant", let msg = obj["message"] as? [String: Any] else { return }
        if let m = msg["model"] as? String, m.hasPrefix("claude") { d.model = m }
        if let e = obj["effort"] as? String { d.effort = e }
        if let u = msg["usage"] as? [String: Any] {
            let n = { (k: String) in (u[k] as? Int) ?? 0 }
            let ctx = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
            if ctx > 0 { d.contextTokens = ctx }
            d.outputTokens += n("output_tokens")
        }
    }
}

func compactTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k" }
    return "\(n)"
}

/// Account-wide plan usage + per-session cost, captured by the Touchbar Claude status line.
struct Limits {
    var fiveHour: Double?, fiveReset: Double?
    var week: Double?, weekReset: Double?
    var cost: Double?
    var context: Double?          // how full this session's context window is, 0...100

    static func read(sessionId: String?) -> Limits? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/claudebar/status")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let jsons = files.filter { $0.pathExtension == "json" }
        func load(_ u: URL) -> [String: Any]? {
            guard let d = try? Data(contentsOf: u) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var l = Limits()
        // Plan limits are per account, so the newest file wins.
        if let newest = jsons.max(by: { mtime($0) < mtime($1) }), let o = load(newest),
           let rl = o["rate_limits"] as? [String: Any] {
            let five = rl["five_hour"] as? [String: Any], week = rl["seven_day"] as? [String: Any]
            l.fiveHour = (five?["used_percentage"] as? NSNumber)?.doubleValue
            l.fiveReset = (five?["resets_at"] as? NSNumber)?.doubleValue
            l.week = (week?["used_percentage"] as? NSNumber)?.doubleValue
            l.weekReset = (week?["resets_at"] as? NSNumber)?.doubleValue
        }
        if let sid = sessionId, let o = load(dir.appendingPathComponent("\(sid).json")) {
            let cost = o["cost"] as? [String: Any], window = o["context_window"] as? [String: Any]
            l.cost = (cost?["total_cost_usd"] as? NSNumber)?.doubleValue
            l.context = (window?["used_percentage"] as? NSNumber)?.doubleValue
        }
        return l
    }
}

/// Why the mascot looks tired (context nearly full) or stressed (a plan limit nearly used up).
struct Warning {
    static let threshold = 80.0   // percent

    var health: Health
    var text: String              // shown when idle
    var short: String             // added to the subtitle while working

    /// A plan limit comes first: it stops everything, a full context only needs /compact.
    /// `context` is nil when there's no running session to warn about.
    static func from(_ l: Limits, context: Double?) -> Warning? {
        let now = Date().timeIntervalSince1970
        let plan = [("5h limit", l.fiveHour, l.fiveReset), ("weekly limit", l.week, l.weekReset)]
        let hit = plan.compactMap { name, used, reset -> (String, Double, Double?)? in
            // A limit whose reset time has passed is old data.
            guard let used, used >= threshold, (reset ?? .infinity) > now else { return nil }
            return (name, used, reset)
        }.max { $0.1 < $1.1 }
        if let (name, used, reset) = hit {
            let short = "\(name) \(Int(used.rounded()))%"
            var text = short.prefix(1).uppercased() + short.dropFirst() + " used"
            if let reset { text += " · resets in " + DetailsRenderer.resetIn(reset) }
            return Warning(health: .stressed, text: text, short: short)
        }
        if let context, context >= threshold {
            let short = "context \(Int(context.rounded()))%"
            return Warning(health: .tired, text: "Context \(Int(context.rounded()))% full · try /compact", short: short)
        }
        return nil
    }
}

enum DetailsRenderer {
    private static let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)

    static func draw(_ c: CGContext, bounds: CGRect, details d: SessionDetails?, limits l: Limits?) {
        var x = bounds.minX + 54
        guard let d else {
            text("No Claude Code session yet", NSFont.systemFont(ofSize: 12), .init(white: 1, alpha: 0.6),
                 at: NSPoint(x: x, y: bounds.midY - 8))
            return
        }
        func chip(_ label: String, width: CGFloat, value: (CGFloat) -> Void) {
            text(label, labelFont, NSColor(white: 1, alpha: 0.45), at: NSPoint(x: x, y: bounds.minY + 1))
            value(x)
            c.setFillColor(CGColor(gray: 1, alpha: 0.15))
            c.fill(CGRect(x: x + width - 8, y: bounds.minY + 5, width: 1, height: bounds.height - 10))
            x += width
        }
        let vy = bounds.minY + 13

        chip(d.effort.isEmpty ? "MODEL" : "MODEL · \(d.effort.uppercased())", width: 108) { x in
            text(d.modelName, valueFont, .white, at: NSPoint(x: x, y: vy))
        }

        chip("CONTEXT", width: 116) { x in
            let pct = Double(d.contextTokens) / Double(d.contextLimit)
            gauge(c, x: x, y: vy + 5, pct: pct)
            text("\(compactTokens(d.contextTokens))/\(compactTokens(d.contextLimit))", valueFont, .white,
                 at: NSPoint(x: x + 38, y: vy))
        }

        if let l, let five = l.fiveHour {
            chip("PLAN USAGE (5H · WEEK)", width: 172) { x in
                gauge(c, x: x, y: vy + 5, pct: five / 100)
                var s = "\(Int(five.rounded()))%"
                if let r = l.fiveReset { s += " ↻" + resetIn(r) }
                if let w = l.week { s += " · \(Int(w.rounded()))%" }
                text(s, valueFont, .white, at: NSPoint(x: x + 38, y: vy))
            }
        } else {
            chip("WRITTEN", width: 92) { x in
                var s = compactTokens(d.outputTokens) + " tok"
                if let cost = l?.cost { s = String(format: "$%.2f", cost) }
                text(s, valueFont, .white, at: NSPoint(x: x, y: vy))
            }
        }

        chip("SESSION", width: bounds.maxX - x) { x in
            var parts: [String] = []
            if !d.project.isEmpty { parts.append(d.project + (d.branch.isEmpty ? "" : " (\(d.branch))")) }
            if let s = d.startedAt {
                let m = Int(Date().timeIntervalSince(s) / 60)
                parts.append(m >= 60 ? "\(m / 60)h\(m % 60)m" : "\(m)m")
            }
            text(parts.joined(separator: " · "), valueFont, .white, at: NSPoint(x: x, y: vy), maxWidth: bounds.maxX - x - 4)
        }
    }

    static func resetIn(_ epoch: Double) -> String {
        let s = max(0, epoch - Date().timeIntervalSince1970)
        return s >= 3600 ? "\(Int(s / 3600))h\(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m" : "\(Int(s / 60))m"
    }

    static func gauge(_ c: CGContext, x: CGFloat, y: CGFloat, pct: Double, width w: CGFloat = 32) {
        let h: CGFloat = 6
        c.setFillColor(CGColor(gray: 1, alpha: 0.18))
        c.fill(CGRect(x: x, y: y, width: w, height: h))
        let p = min(1, max(0, pct))
        let color: CGColor = p < 0.6 ? CGColor(srgbRed: 0.55, green: 0.82, blue: 0.49, alpha: 1)
            : p < 0.85 ? CGColor(srgbRed: 0.95, green: 0.76, blue: 0.31, alpha: 1)
            : CGColor(srgbRed: 0.91, green: 0.40, blue: 0.36, alpha: 1)
        c.setFillColor(color)
        c.fill(CGRect(x: x, y: y, width: max(1, w * CGFloat(p)), height: h))
    }

    private static func text(_ s: String, _ f: NSFont, _ col: NSColor, at p: NSPoint, maxWidth: CGFloat = .greatestFiniteMagnitude) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: col, .paragraphStyle: para])
        if maxWidth < .greatestFiniteMagnitude {
            a.draw(with: NSRect(x: p.x, y: p.y, width: maxWidth, height: f.pointSize + 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            a.draw(at: p)
        }
    }
}
