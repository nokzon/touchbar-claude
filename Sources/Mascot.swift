import Cocoa
import QuartzCore

// The mascot is built only from rectangles (same idea as the Codrops article), in a
// 1-unit grid where the body spans x 6...100 and the feet touch the ground at y = 84.
// Everything is drawn procedurally every frame from the current mood + elapsed time.

enum Mood: String { case idle, working, waiting, done }

struct ArmPose { var dx: CGFloat = 0; var dy: CGFloat = 0; var rot: CGFloat = 0 }
enum EyeStyle { case normal, focused, happy }

struct Pose {
    var gx: CGFloat = 0, gy: CGFloat = 0
    var bodyDX: CGFloat = 0, bodyDY: CGFloat = 0, bodyRot: CGFloat = 0, bodySY: CGFloat = 1
    var eyeDX: CGFloat = 0, eyeDY: CGFloat = 0, blink: CGFloat = 1, eyes: EyeStyle = .normal
    var lArm = ArmPose(), rArm = ArmPose()
    var legRot: [CGFloat] = [0, 0, 0, 0]
    var legSY: [CGFloat] = [1, 1, 1, 1]
    var legLift: [CGFloat] = [0, 0, 0, 0]
    var rArmHidden = false
    var rArmReach: CGFloat = 0    // extra arm length out to the right (the arm stays rooted in the body)
    var legUpperDX: CGFloat = 0
    var legHipPivot = false       // walking: legs swing from the hip (and get clipped by the ground)   // two-part legs: feet stay planted, the upper part sways with the body
}

struct Scene {
    var mood: Mood
    var t: Double          // seconds since this mood started
    var title: String
    var subtitle: String
    var roaming = false    // no session: just the mascot, wandering the whole bar
    var slideFrom: CGFloat = 0   // where it was roaming when tapped; it dashes home from there
}

// MARK: - Geometry & palette

private enum G {
    // Same proportions as the reference (Codrops article): one ~11-unit "pixel" grid.
    // Outer legs line up with the body's edges; arms are leg-width blocks on each side.
    static let body = CGRect(x: 11, y: 0, width: 85, height: 60)
    // Hands are 22x22 squares centred on the body edge: at rest half is tucked inside the
    // body (11 wide showing); when an arm moves, the whole square swings out.
    static let lArm = CGRect(x: 0, y: 22, width: 22, height: 22)
    static let rArm = CGRect(x: 85, y: 22, width: 22, height: 22)
    static let lPivot = CGPoint(x: 11, y: 33)
    static let rPivot = CGPoint(x: 96, y: 33)
    static let eyeX: [CGFloat] = [20, 76]
    static let eyeY: CGFloat = 12, eyeSize: CGFloat = 11
    static let legX: [CGFloat] = [11, 32, 64, 85]
    static let legW: CGFloat = 11, hip: CGFloat = 60, ground: CGFloat = 86
    static let bodyPivot = CGPoint(x: 53.5, y: 60)
    // vertical units visible in the bar: -21 ... 89
    static let viewTop: CGFloat = -21, viewUnits: CGFloat = 110
}

private func rgb(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

private enum C {
    static let clay = rgb(0xD97757)
    static let eye = rgb(0x2A1B16)
    static let wood = rgb(0x8A5A3B)
    static let steel = rgb(0xA7AFB8)
    static let steelDark = rgb(0x7D858F)
    static let brick = rgb(0xC9B8A6)
    static let brickNew = rgb(0xF0DCC4)
    static let pole = rgb(0xD9D4CB)
    static let gold = rgb(0xF2C14E)
    static let ink = rgb(0x1E1E1E)
    static let flagDark = rgb(0x4A4A4A)   // visible on the black Touch Bar
    static let paper = rgb(0xF4F1EA)
    static let confetti: [CGColor] = [0xD97757, 0xF2C14E, 0x6FB7E8, 0x8BD17C, 0xE86FA8, 0xF4F1EA].map(rgb)
}

// MARK: - Easing / helpers (GSAP-style)

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
private func power2Out(_ x: Double) -> Double { 1 - (1 - x) * (1 - x) }
private func power2InOut(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
private func power3In(_ x: Double) -> Double { x * x * x }
private func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }
private func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }
private func fmod(_ a: Double, _ b: Double) -> Double { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }

/// Tiny deterministic RNG so particles look random but stay stable frame to frame.
private struct LCG {
    var s: UInt64
    init(_ seed: Int) { s = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 1013904223) | 1 }
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double((s >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}

// MARK: - Poses per mood

private func breathe(_ p: inout Pose, _ t: Double) {
    let b = sin(t * 2 * .pi / 2.8)
    p.bodySY = 1 + 0.02 * CGFloat(b)
    p.lArm.dy -= 0.7 * CGFloat(b)
    p.rArm.dy -= 0.7 * CGFloat(b)
}

private func blink(_ p: inout Pose, _ t: Double) {
    let bt = fmod(t, 3.7)
    if bt > 3.56 || (Int(t / 3.7) % 3 == 2 && bt > 3.30 && bt < 3.42) { p.blink = 0.15 }
}

/// Lean left (k < 0) or right (k > 0): eyes, body and legs move in one beat.
private func lean(_ p: inout Pose, _ k: Double) {
    let a = CGFloat(abs(k)), s: CGFloat = k < 0 ? -1 : 1
    p.eyeDX += 3 * s * a
    p.bodyRot += 3 * s * a
    p.bodyDX += 3 * s * a
    p.bodyDY -= 5 * a
    let rot: [CGFloat] = k < 0 ? [-7, -8, -8, -9] : [9, 8, 8, 7]
    let sy: [CGFloat] = k < 0 ? [0.35, 0.3, 0.2, 0.15] : [0.15, 0.2, 0.3, 0.35]
    for i in 0..<4 { p.legRot[i] += rot[i] * a; p.legSY[i] += sy[i] * a }
}

// Idle, based on the "Walking Claude" clip: look around (lean left, lean right), look down,
// a small hop, then a crouched scuttle to the right where the lowered body pushes the legs
// into the ground clip so only stubs show. Then the same on the other side, walking back.
private let walkDistance: CGFloat = 70
private let lookDuration = 3.4     // lean L, lean R, settle, look down, hop
private let walkDuration = 1.5
private let restDuration = 0.6      // short pause before looking around (walk starts at 4 s)
private let restAfterWalk = 1.8    // breathe and blink after arriving

private func power3InOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
private func sineOut(_ x: Double) -> Double { sin(x * .pi / 2) }
private func power1InOut(_ x: Double) -> Double { power2InOut(x) * 0.5 + x * 0.5 }

/// `stops` walks to the right, each followed by a look around, then the same number back.
private func idlePose(_ t: Double, distance: CGFloat = walkDistance, walkTime: Double = walkDuration,
                      stops: Int = 1) -> Pose {
    var p = Pose()
    let half = restDuration + lookDuration + walkTime + restAfterWalk
    let lt = fmod(t, half * Double(stops * 2))
    let step = min(Int(lt / half), stops * 2 - 1)
    let goingBack = step >= stops
    let u = lt - Double(step) * half              // time within this half
    let dir: CGFloat = goingBack ? -1 : 1         // walking direction for this half
    let startX = CGFloat(goingBack ? stops * 2 - step : step) * distance
    p.gx = startX

    if u < restDuration {
        // Quiet moment: breathe and blink.
        breathe(&p, u)
        blink(&p, t)
        return p
    }
    let v = u - restDuration
    if v < lookDuration {
        // Lean left, hold; lean right, hold; settle with eyes down; hop.
        var k = 0.0
        if v < 1.0 { k = -power2Out(seg(v, 0, 0.35)) }
        else if v < 2.0 { k = lerp(-1, 1, power2InOut(seg(v, 1.0, 1.35))) }
        else { k = 1 - power2Out(seg(v, 2.0, 2.3)) }
        lean(&p, k)
        if v < 2.3 { blink(&p, t) }
        if v >= 2.3 { p.eyeDY = CGFloat(4 * power2Out(seg(v, 2.3, 2.45))) }  // look down
        if v >= 2.55 && v < 2.65 {                                           // crouch, gathering
            let c = power3In(seg(v, 2.55, 2.65))
            p.bodyDY = CGFloat(8 * c); p.lArm.dy = CGFloat(4 * c); p.rArm.dy = CGFloat(4 * c)
        } else if v >= 2.65 && v < 3.15 {                                    // the hop
            let h = v < 2.9 ? sineOut(seg(v, 2.65, 2.9)) : 1 - power3In(seg(v, 2.9, 3.15))
            p.gy = CGFloat(-14 * h)
            p.gx += dir * CGFloat(6 * seg(v, 2.65, 3.15))
        } else if v >= 3.15 {                                                // land low into the walk
            let c = power2Out(seg(v, 3.15, 3.4))
            p.gx += dir * 6
            p.bodyDY = CGFloat(9 * c); p.lArm.dy = CGFloat(-2 * c); p.rArm.dy = CGFloat(-2 * c)
            p.legHipPivot = true
            p.eyeDY = CGFloat(4 * (1 - c))
            p.eyeDX = 4 * dir * CGFloat(c)
        }
        return p
    }
    // Crouched scuttle: the body stays low, legs swing from the hip in alternating pairs.
    let w = v - lookDuration
    if w < walkTime {
        let prog = power1InOut(seg(w, 0, walkTime - 0.2))
        p.gx += dir * (6 + (distance - 6) * CGFloat(prog))
        p.legHipPivot = true
        let phase = w / 0.26 * 2 * .pi
        let standUp = seg(w, walkTime - 0.2, walkTime)
        let low = 9 * (1 - power2Out(standUp))
        p.bodyDY = CGFloat(low + 1.5 * abs(sin(phase)) * (1 - standUp))
        p.eyeDX = 4 * dir
        for i in 0..<4 {
            let s = sin(phase + (i % 2 == 0 ? 0 : .pi)) * (1 - standUp)
            // Alternate pairs: one pair lifts clear of the ground while the other is planted.
            // (The legs reach below the ground while crouched, so lift from the crouch depth.)
            let up: CGFloat = s > 0.15 ? 7 : 0
            p.legLift[i] = CGFloat(low) + up
        }
        p.lArm.dy = CGFloat(-2 * (1 - standUp)); p.rArm.dy = p.lArm.dy
    } else {
        p.gx = startX + dir * distance
        breathe(&p, w - walkTime)
        blink(&p, t)
    }
    return p
}

private let hammerPeriod = 0.72
private let hammerImpact = 0.58

private func hammerAngle(_ u: Double) -> Double {
    if u < 0.34 { return lerp(95, -35, power2Out(u / 0.34)) }               // wind up
    if u < 0.48 { return -35 - 5 * sin(.pi * (u - 0.34) / 0.14) }           // anticipation
    if u < hammerImpact { return lerp(-35, 95, power3In((u - 0.48) / 0.10)) } // strike
    return 95 - 10 * sin(.pi * (u - hammerImpact) / (hammerPeriod - hammerImpact)) // rebound
}

private func workingPose(_ t: Double) -> Pose {
    var p = Pose()
    let u = fmod(t, hammerPeriod)
    let ang = hammerAngle(u)
    p.rArm.rot = CGFloat(ang)
    p.bodyRot = CGFloat((ang - 30) / 65 * 2.5)
    p.bodyDX = CGFloat((ang - 30) / 65 * 1.5)
    if u >= hammerImpact {
        let k = 1 - (u - hammerImpact) / (hammerPeriod - hammerImpact)
        p.bodySY = 1 - 0.05 * CGFloat(k)
        p.lArm.dy = 2 * CGFloat(k)
    }
    p.eyes = .normal                 // eyes fully open while working
    p.eyeDX = 3
    p.rArmReach = 11                 // hammer arm is longer: reaches a full square out of the body
    for i in 0..<4 { p.legRot[i] = p.bodyRot * 0.8 }
    return p
}

private func waitingPose(_ t: Double) -> Pose {
    var p = Pose()
    breathe(&p, t)
    blink(&p, t)
    p.eyeDY = -2
    // Shrug: both hands fully out (whole 22x22 squares, touching the body). They pop up with
    // the shoulders, hang there a beat, then drop with a little overshoot bounce and rest.
    let u = fmod(t, 1.6)
    var lift = 0.0                                   // + = up
    if u < 0.14 { lift = power2Out(u / 0.14) }                                    // quick pop up
    else if u < 0.55 { lift = 1 }                                                 // hold the shrug
    else if u < 0.68 { lift = lerp(1, -0.45, power3In(seg(u, 0.55, 0.68))) }      // drop
    else if u < 0.84 { lift = lerp(-0.45, 0.15, power2Out(seg(u, 0.68, 0.84))) }  // bounce back up
    else if u < 0.96 { lift = lerp(0.15, 0, power2InOut(seg(u, 0.84, 0.96))) }    // settle
    p.lArm.dx = -11
    p.rArm.dx = 11
    let handsLower: CGFloat = 9                      // whole shrug sits lower on the body
    p.lArm.dy += handsLower - CGFloat(8 * lift)
    p.rArm.dy += handsLower - CGFloat(8 * lift)
    p.bodyDY -= CGFloat(3 * max(0, lift))            // shoulders come up with the hands
    p.eyeDY -= CGFloat(1 * max(0, lift))
    return p
}

private let celebrateDuration = 3.0   // three full stomp cycles (24 frames x 125 ms)
private let stompFrame = 0.125

private func stompPose(_ f: Int) -> Pose {
    var p = Pose()
    p.eyes = .happy
    let m: CGFloat = f >= 4 ? -1 : 1     // frames 4...7 mirror 0...3
    switch f % 4 {
    case 0:
        p.bodyRot = -6 * m; p.bodyDX = -3 * m
        if m > 0 { p.lArm.rot = 70; p.rArm.rot = 10; p.legLift = [0, 0, 6, 6] }
        else { p.rArm.rot = -70; p.lArm.rot = -10; p.legLift = [6, 6, 0, 0] }
    case 1:
        p.gy = -11; p.bodySY = 1.04; p.lArm.rot = 78; p.rArm.rot = -78
    case 2:
        p.gy = -4; p.lArm.rot = 50; p.rArm.rot = -50
    default:
        p.bodySY = 0.92; p.lArm.rot = 20; p.rArm.rot = -20
    }
    return p
}

// Flag waver, matched to the reference clip: the pole always stays vertical and the flag is
// a sequence of drawn poses (edge-on, streaming right, streaming left, up-left), one per
// 80 ms. The hand pulls against the flag, the body sways opposite to it (feet planted), and
// the low left hand drops when the body shifts left. The first three poses (the flag rising)
// play once, then the loop repeats.
private let flagFrame = 0.08
private enum FlagShape { case limp, half, edge, right, left, leftHigh }
private struct FlagKey { let shape: FlagShape; let sway: CGFloat; let hand: CGFloat; let lhand: CGFloat }
private let flagRise: [FlagKey] = [
    FlagKey(shape: .limp, sway: 0, hand: 0, lhand: 0),
    FlagKey(shape: .half, sway: 0, hand: 0, lhand: 0),
    FlagKey(shape: .edge, sway: -2, hand: -1, lhand: 0),
]
private let flagLoop: [FlagKey] = [
    FlagKey(shape: .right, sway: -5, hand: -3, lhand: 4),
    FlagKey(shape: .right, sway: -5, hand: -4, lhand: 4),
    FlagKey(shape: .edge, sway: 0, hand: 0, lhand: 0),
    FlagKey(shape: .edge, sway: 0, hand: 0, lhand: 0),
    FlagKey(shape: .left, sway: 4, hand: 3, lhand: 0),
    FlagKey(shape: .left, sway: 4, hand: 4, lhand: 0),
    FlagKey(shape: .leftHigh, sway: 4, hand: 5, lhand: 0),
    FlagKey(shape: .leftHigh, sway: 0, hand: 5, lhand: 0),
    FlagKey(shape: .edge, sway: 0, hand: 0, lhand: 0),
]

private func flagKey(_ tf: Double) -> FlagKey {
    let step = Int(tf / flagFrame)
    return step < flagRise.count ? flagRise[step] : flagLoop[(step - flagRise.count) % flagLoop.count]
}

private func flagPose(_ tf: Double) -> Pose {
    var p = Pose()
    let k = flagKey(tf)
    p.eyes = .happy
    p.rArmHidden = true
    p.bodyDX = k.sway
    p.legUpperDX = k.sway
    p.lArm.dx = -11                            // left hand fully out: the whole 22x22 square
    p.lArm.dy = 10 + k.lhand
    return p
}

/// Flag cells for a pose as (column, row): column 0 is the pole, negative is left;
/// row 0 is level with the top of the pole and rows grow downwards. Outlines traced from
/// the reference clip (cells are ~0.4 of a leg wide, the flag ~11 cells across).
private func flagCells(_ shape: FlagShape) -> [(Int, Int)] {
    var cells: [(Int, Int)] = []
    func column(_ c: Int, _ top: Int, _ bottom: Int, ragged: Bool = false) {
        guard bottom >= top else { return }
        for r in top...bottom where !(ragged && (r - top) % 2 == 1) { cells.append((c, r)) }
    }
    switch shape {
    case .limp:                                    // hanging down the pole
        column(1, 0, 4)
        column(2, 1, 5, ragged: true)
    case .half:                                    // lifting out to the right, still drooping
        for c in 1...5 { column(c, c / 2, c / 2 + 3, ragged: c == 5) }
    case .edge:                                    // turning through: a stub left, bulk right
        column(-1, 0, 3)
        for c in 1...4 { column(c, c / 3, 5 - c / 2, ragged: c == 4) }
    case .right:                                   // streaming right, sloping down to the tip
        for c in 1...7 { let top = max(0, (c - 2) / 2); column(c, top, top + 3, ragged: c == 7) }
    case .left:                                    // streaming left, the far end curling down
        for c in 1...6 {
            let top = c <= 4 ? 0 : c - 4
            let bottom = c <= 3 ? 3 : c
            column(-c, top, bottom, ragged: c == 6)
        }
    case .leftHigh:                                // whipped up-left, far end flicked up a row
        for c in 1...7 {
            let top = c >= 4 ? -1 : 0
            let bottom = c <= 3 ? 4 : 3
            column(-c, top, bottom, ragged: c == 7)
        }
    }
    return cells
}

/// How far up the view reaches: zooms out for the flag so the pole fits in the 30 pt bar.
private func viewTop(_ sc: Scene) -> CGFloat {
    guard sc.mood == .done else { return G.viewTop }
    let celebrateTop: CGFloat = -80     // room for the reaching hand and the confetti
    if sc.t <= celebrateDuration { return celebrateTop }
    return CGFloat(lerp(Double(celebrateTop), -38, power2InOut(seg(sc.t - celebrateDuration, 0, 0.35))))
}

// MARK: - Renderer

enum Renderer {
    /// How far from home the roaming mascot was last drawn (mascot units).
    private(set) static var roamX: CGFloat = 0

    /// Draws the scene into `bounds` of a flipped view.
    static func draw(_ c: CGContext, bounds: CGRect, scene: Scene, compact: Bool) {
        let s0 = bounds.height / G.viewUnits
        let top = viewTop(scene)
        let s = bounds.height / (G.ground + 3 - top)
        let keepCentre = G.body.midX * (s0 - s)     // zooming keeps the mascot centred where it was
        let x0: CGFloat = (compact ? bounds.minX + 2 + 10 * s0 : bounds.minX + 8 + 22 * s0) + keepCentre

        // Room to the right of home, leaving space for the mascot itself.
        let roamSpan = max(0, (bounds.maxX - x0) / s - 125)

        if !compact && !scene.roaming && !(scene.slideFrom > 0 && scene.t < slideTime) {
            drawText(scene, x: bounds.minX + 8 + 22 * s0 + 206 * s0 + 10, maxX: bounds.maxX - 6, bounds: bounds)
        }

        c.saveGState()
        c.clip(to: bounds)
        c.translateBy(x: x0, y: bounds.minY - top * s)
        c.scaleBy(x: s, y: s)
        drawStage(c, scene, compact: compact, roamSpan: roamSpan)
        c.restoreGState()
    }

    private static let slideTime = 0.4

    private static func drawStage(_ c: CGContext, _ sc: Scene, compact: Bool, roamSpan: CGFloat) {
        let t = sc.t
        switch sc.mood {
        case .idle:
            var p: Pose
            if sc.roaming && !compact {
                let stops = 6
                let distance = roamSpan / CGFloat(stops)
                // Same walking speed as the short stroll next to the text.
                let walkTime = max(walkDuration, Double(distance / walkDistance) * walkDuration)
                p = idlePose(t, distance: distance, walkTime: walkTime, stops: stops)
                roamX = p.gx
            } else {
                p = idlePose(t)
                if sc.slideFrom > 0 { p.gx += sc.slideFrom * CGFloat(1 - power2Out(seg(t, 0, slideTime))) }
            }
            if compact { p.gx = 0 }
            drawMascot(c, p)

        case .waiting:
            let p = waitingPose(t)
            drawMascot(c, p)
            drawBubble(c, t)

        case .working:
            if !compact { drawWall(c, t) }
            drawMascot(c, workingPose(t), prop: drawHammer)
            drawSparks(c, t)

        case .done:
            drawConfetti(c, t)      // behind the mascot
            if t < celebrateDuration {
                drawStompSprite(c, Int(t / stompFrame) % 8)
            } else {
                let tf = t - celebrateDuration
                drawMascot(c, flagPose(tf), bodyProp: { c in drawFlag(c, tf) })
            }
        }
    }

    // MARK: Mascot

    private static func applyArm(_ c: CGContext, _ a: ArmPose, pivot: CGPoint) {
        c.translateBy(x: a.dx, y: a.dy)
        c.translateBy(x: pivot.x, y: pivot.y)
        c.rotate(by: rad(a.rot))
        c.translateBy(x: -pivot.x, y: -pivot.y)
    }

    private static func applyBody(_ c: CGContext, _ p: Pose) {
        c.translateBy(x: p.bodyDX, y: p.bodyDY)
        c.translateBy(x: G.bodyPivot.x, y: G.bodyPivot.y)
        c.rotate(by: rad(p.bodyRot))
        c.scaleBy(x: 1, y: p.bodySY)
        c.translateBy(x: -G.bodyPivot.x, y: -G.bodyPivot.y)
    }

    static func drawMascot(_ c: CGContext, _ p: Pose, prop: ((CGContext) -> Void)? = nil,
                           bodyProp: ((CGContext) -> Void)? = nil) {
        c.saveGState()
        c.translateBy(x: p.gx, y: p.gy)

        // Legs pivot at the feet and are clipped at the ground so stretching never pokes through.
        c.saveGState()
        c.clip(to: CGRect(x: -60, y: -80, width: 300, height: 80 + G.ground))
        c.setFillColor(C.clay)
        for i in 0..<4 {
            c.saveGState()
            if p.legHipPivot {
                c.translateBy(x: G.legX[i] + G.legW / 2, y: G.hip + p.bodyDY)
                c.rotate(by: rad(p.legRot[i]))
                let len = G.ground - G.hip - p.legLift[i]
                c.fill(CGRect(x: -G.legW / 2, y: -6, width: G.legW, height: len + 6))
                c.restoreGState()
                continue
            }
            c.translateBy(x: G.legX[i] + G.legW / 2, y: G.ground)
            c.rotate(by: rad(p.legRot[i]))
            c.scaleBy(x: 1, y: p.legSY[i])
            let full = G.ground - G.hip + 6
            if p.legUpperDX != 0 {
                let foot: CGFloat = 9
                c.fill(CGRect(x: -G.legW / 2, y: -foot, width: G.legW, height: foot))
                c.fill(CGRect(x: -G.legW / 2 + p.legUpperDX, y: -full, width: G.legW, height: full - foot + 0.5))
            } else {
                c.fill(CGRect(x: -G.legW / 2, y: -full, width: G.legW, height: full - p.legLift[i]))
            }
            c.restoreGState()
        }
        c.restoreGState()

        c.saveGState()
        applyBody(c, p)
        c.setFillColor(C.clay)
        var arms = [(p.lArm, G.lArm, G.lPivot)]
        if !p.rArmHidden {
            var r = G.rArm; r.size.width += p.rArmReach
            arms.append((p.rArm, r, G.rPivot))
        }
        for (arm, rect, pivot) in arms {
            c.saveGState(); applyArm(c, arm, pivot: pivot); c.fill(rect); c.restoreGState()
        }
        c.fill(G.body)
        drawEyes(c, p)
        bodyProp?(c)
        if let prop {
            c.saveGState(); applyArm(c, p.rArm, pivot: G.rPivot); prop(c); c.restoreGState()
        }
        c.restoreGState()
        c.restoreGState()
    }

    private static func drawEyes(_ c: CGContext, _ p: Pose) {
        c.setFillColor(C.eye)
        c.setStrokeColor(C.eye)
        for ex in G.eyeX {
            let x = ex + p.eyeDX, y = G.eyeY + p.eyeDY
            switch p.eyes {
            case .normal:
                let h = G.eyeSize * p.blink
                c.fill(CGRect(x: x, y: y + (G.eyeSize - h) / 2, width: G.eyeSize, height: h))
            case .focused:
                c.fill(CGRect(x: x, y: y + 3, width: G.eyeSize, height: 6))
            case .happy:
                // Pixel ^ made of 6-unit blocks: a bar with a block under each end.
                // Nudged slightly towards the middle of the face.
                // Centred 22 units either side of the middle of the face.
                let cx = (ex < G.body.midX ? G.body.midX - 24 : G.body.midX + 24) + p.eyeDX
                let topGap: CGFloat = 8.5
                let hy = G.body.minY + topGap + p.eyeDY
                c.fill(CGRect(x: cx - 6, y: hy, width: 12, height: 6))
                c.fill(CGRect(x: cx - 12, y: hy + 6, width: 6, height: 6))
                c.fill(CGRect(x: cx + 6, y: hy + 6, width: 6, height: 6))
            }
        }
    }

    // MARK: Props (drawn in right-arm space; hand is around x 98...116, y 26...42)

    private static func drawHammer(_ c: CGContext) {
        // Drawn for the long (reaching) arm: the hand end is at x 107...118.
        c.setFillColor(C.wood)
        c.fill(CGRect(x: 110, y: 4, width: 5, height: 30))
        c.setFillColor(C.steel)
        c.fill(CGRect(x: 101, y: -4, width: 23, height: 11))
        c.setFillColor(C.steelDark)
        c.fill(CGRect(x: 119, y: -4, width: 5, height: 11))
        // The whole arm is drawn again on top, from inside the body to the hand, so it stays
        // joined to the body however far it swings (no gap at the shoulder).
        c.setFillColor(C.clay)
        c.fill(CGRect(x: G.rArm.minX, y: G.rArm.minY, width: G.rArm.width + 11, height: G.rArm.height))
    }

    /// Drawn in body space: raised hand on the body's top-right corner, a vertical pole, and
    /// the flag as 5-unit checker cells (white and grey, since the Touch Bar is black).
    private static func drawFlag(_ c: CGContext, _ tf: Double) {
        let k = flagKey(tf)
        let g: CGFloat = 6.5                     // big flag cells, fewer of them
        // Hand sticks out of the body's right side at arm height, gripping the pole.
        let handTop: CGFloat = G.rArm.minY
        let hx = G.rArm.minX + k.hand
        c.setFillColor(C.clay)
        c.fill(CGRect(x: hx, y: handTop, width: G.rArm.width, height: G.rArm.height))

        // When the flag whips up-left, the top of the pole kicks one cell out to the right of
        // the part in the hand, leaving a step in the pole (as in the reference).
        let poleX = hx + 15
        let topShift: CGFloat = k.shape == .leftHigh ? g : 0
        let poleTopY: CGFloat = handTop - 7 * g
        for (col, row) in flagCells(k.shape) {
            c.setFillColor((row + col) % 2 == 0 ? C.paper : C.flagDark)
            c.fill(CGRect(x: poleX + topShift + CGFloat(col) * g, y: poleTopY + CGFloat(row) * g,
                          width: g, height: g))
        }
        c.setFillColor(rgb(0xFFFFFF))   // white pole
        var y = poleTopY
        while y < handTop {
            let lower = y >= handTop - 3 * g
            c.fill(CGRect(x: lower ? poleX : poleX + topShift, y: y, width: g, height: g + 0.3))
            y += g
        }
    }

    // MARK: World effects

    private static func drawWall(_ c: CGContext, _ t: Double) {
        // A brick lands every second hammer strike; the wall resets after 16 bricks.
        let strikes = t < hammerImpact ? 0 : Int((t - hammerImpact) / hammerPeriod) + 1
        let n = (strikes / 2) % 17
        for i in 0..<n {
            let row = i / 4, col = i % 4
            var y = G.ground - CGFloat(row + 1) * 8 + 1
            let x = 135 + CGFloat(col) * 13 + (row % 2 == 1 ? 6 : 0)
            var color = C.brick
            if i == n - 1 {
                let landed = hammerImpact + Double(2 * n - 1) * hammerPeriod
                let k = clamp01((t - landed) / 0.16)
                y -= CGFloat(14 * (1 - k) * (1 - k))
                if t - landed < 0.5 { color = C.brickNew }
            }
            c.setFillColor(color)
            c.fill(CGRect(x: x, y: y, width: 12, height: 7))
        }
    }

    private static func drawSparks(_ c: CGContext, _ t: Double) {
        guard t >= hammerImpact else { return }
        let k = Int((t - hammerImpact) / hammerPeriod)
        let age = t - (hammerImpact + Double(k) * hammerPeriod)
        guard age < 0.26 else { return }
        var rng = LCG(k)
        for i in 0..<6 {
            let ang = -Double.pi * (0.15 + 0.7 * rng.next())
            let v = 90 + 80 * rng.next()
            let x = 133 + cos(ang) * v * age
            let y = 52 + sin(ang) * v * age + 260 * age * age
            c.setFillColor(i % 2 == 0 ? C.gold : C.paper)
            let sz: CGFloat = age < 0.15 ? 4 : 3
            c.fill(CGRect(x: (x / 2).rounded() * 2, y: (y / 2).rounded() * 2, width: sz, height: sz))
        }
    }

    // MARK: Celebration (sprite frames measured from the reference clip)

    /// One stomp frame. Drawn on the reference's pixel grid: P = one leg width, x in pixels
    /// from the body's left edge, y in pixels up from the ground. Frames: 0 squat, 1-3 reach
    /// up-right (the tilt is drawn as half-pixel steps, not a rotation), 4 squat, 5-7 mirrored.
    private static func drawStompSprite(_ c: CGContext, _ frame: Int) {
        let P: CGFloat = G.legW
        let mirrored = frame >= 5
        let f = frame >= 4 ? frame - 4 : frame
        func px(_ x: CGFloat) -> CGFloat { mirrored ? 8 - x : x }
        // Pieces are collected and filled as one shape, so touching columns have no seams.
        var rects: [CGRect] = []
        func cell(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            let a = px(x0), b = px(x1)
            rects.append(CGRect(x: G.body.minX + min(a, b) * P, y: G.ground - y1 * P,
                                width: abs(b - a) * P, height: (y1 - y0) * P))
        }
        var eyes: [(CGFloat, CGFloat)] = []
        if f == 0 {
            // Squat: low body, both hands straight out as full squares, stubby legs.
            for lx in [0, 2, 5, 7] as [CGFloat] { cell(lx, 0, lx + 1, 1.5) }
            cell(0, 1, 8, 6.75)
            cell(-2, 1.75, 0, 3.75)
            cell(8, 1.75, 10, 3.75)
            eyes = [(0.9, 3.75), (5.9, 3.75)]
        } else {
            let reachHigh = f == 2
            let lift: CGFloat = f == 3 ? 0.3 : (f == 2 ? 0.3 : 0)   // stomp: far legs leave the ground
            let drop: CGFloat = reachHigh ? -0.25 : 0
            // Legs: near pair planted, far pair (under the raised hand) a little shorter.
            cell(0, 0, 1, 2.6); cell(2, 0, 3, 2.6)
            cell(5, lift, 6, 3.1); cell(7, lift, 8, 3.1)
            // Body columns step up towards the raised hand.
            cell(0, 2.33 + drop, 2, 8.5 + drop)
            cell(2, 2.33 + drop, 4, 9.0 + drop)
            cell(4, 2.8 + drop, 8, 9.5 + drop)
            // Raised hand: a tall block on the top corner; angled further out when reaching high.
            if reachHigh {
                cell(7.5, 8.2, 8, 9.6)
                cell(7.9, 8.25, 9.5, 10.45)
                cell(8, 7.9, 9.0, 8.3)
                cell(8, 7.6, 8.5, 7.95)
            } else {
                cell(7.75, 7.5, 9.75, 10.4)
            }
            // Other hand sticks straight out (lower on the high reach).
            if reachHigh { cell(-2, 2.9, 0, 4.9) } else { cell(-2, 4.25, 0, 6.3) }
            eyes = [(0.9, 6.45 + drop), (6.0, 7.5 + drop)]
        }
        c.setFillColor(C.clay)
        c.beginPath(); c.addRects(rects); c.fillPath()
        rects.removeAll()
        for (ex, ey) in eyes { cell(ex, ey, ex + 1, ey + 1) }
        c.setFillColor(C.eye)
        c.beginPath(); c.addRects(rects); c.fillPath()
    }

    /// Confetti burst sprite, transcribed from the reference's 8 frames. Each frame is a fixed
    /// scatter of 12 px squares (pairs make the bars and diagonals) in a 235 px cell: a tight
    /// cluster that spreads, drifts down and thins out to one dot. The whole cell moves through
    /// the air with the article's particleYOffsets. 0 = orange, 1 = pink, 2 = blue.
    private static let burstY: [CGFloat] = [-65, -72, -76, -70, -58, -42, -22, 0]
    private static let burstFrames: [[(CGFloat, CGFloat, Int)]] = [
        [(43, 39, 0), (55, 39, 0), (103, 44, 1), (91, 56, 1), (18, 72, 2), (18, 84, 2),
         (56, 72, 1), (56, 84, 1), (103, 86, 0), (91, 98, 0), (30, 109, 2), (42, 121, 2),
         (113, 119, 2), (101, 131, 2)],
        [(67, 20, 0), (79, 20, 0), (135, 20, 1), (147, 20, 1), (67, 46, 1), (79, 58, 1),
         (19, 51, 2), (31, 63, 2), (114, 85, 0), (126, 85, 0), (54, 109, 2), (66, 109, 2),
         (149, 121, 2), (161, 133, 2)],
        [(81, 21, 0), (69, 33, 0), (149, 32, 1), (161, 44, 1), (69, 65, 1), (81, 65, 1),
         (12, 78, 2), (24, 78, 2), (116, 86, 0), (128, 98, 0), (55, 109, 2), (43, 121, 2),
         (163, 127, 2), (163, 139, 2)],
        [(73, 26, 0), (73, 38, 0), (204, 34, 1), (204, 46, 1), (67, 66, 1), (55, 78, 1),
         (17, 92, 2), (140, 92, 0), (152, 92, 0), (37, 119, 2), (37, 131, 2),
         (198, 136, 2), (186, 148, 2)],
        [(70, 56, 0), (82, 68, 0), (204, 88, 1), (70, 109, 1), (17, 120, 2), (157, 127, 0),
         (32, 154, 2), (198, 172, 2), (186, 184, 2)],
        [(59, 99, 0), (189, 127, 1), (17, 193, 2), (177, 222, 2)],
        [(17, 149, 0), (147, 176, 1)],
        [(17, 203, 1)],
    ]
    private static let confettiColors: [CGColor] = [rgb(0xD97757), rgb(0xC46686), rgb(0x6A9BCC)]

    private static func drawConfetti(_ c: CGContext, _ t: Double) {
        // Burst 1 fires one frame in, when the right hand is up; burst 2 (mirrored, from the
        // left) fires six frames in, at the opposite stomp. Each repeats every 8 frames.
        let cycle = 8 * stompFrame
        let k: CGFloat = 0.42                      // reference px -> mascot units (square ~ half a leg)
        let cellW = 235 * k
        let sq = 12 * k
        for (delay, mirrored) in [(stompFrame, false), (6 * stompFrame, true)] {
            guard t >= delay else { continue }
            let n = floor((t - delay) / cycle)
            let start = delay + n * cycle
            guard start < celebrateDuration else { continue }
            let frame = Int((t - start) / stompFrame)
            guard frame < 8 else { continue }
            let cellX = mirrored ? G.body.midX + 15 - cellW : G.body.midX - 15
            let cellY: CGFloat = -40 + burstY[frame] * 0.6
            for (x, y, col) in burstFrames[frame] {
                let lx = mirrored ? cellW - x * k - sq : x * k      // scale(-1, 1) for burst 2
                c.setFillColor(confettiColors[col])
                c.fill(CGRect(x: cellX + lx, y: cellY + y * k, width: sq, height: sq))
            }
        }
    }

    /// Pixel "?" in the mascot's orange, synced to the shrug: it pops up and tips over as the
    /// hands go up, wobbles while the shrug is held, and lands with a little bounce.
    private static let questionGlyph = [
        ".###.",
        "#...#",
        "....#",
        "..##.",
        "..#..",
        ".....",
        "..#..",
    ]
    private static func drawBubble(_ c: CGContext, _ t: Double) {
        let u = fmod(t, 1.6)
        var hop = 0.0, tilt = 0.0
        if u < 0.16 { hop = sin(u / 0.16 * .pi / 2) }                                  // pop up
        else if u < 0.55 { hop = 1; tilt = 12 * sin((u - 0.16) / 0.39 * 2 * .pi) }    // wobble
        else if u < 0.7 { hop = 1 - power3In(seg(u, 0.55, 0.7)) * 1.25 }               // drop
        else if u < 0.86 { hop = lerp(-0.25, 0, power2Out(seg(u, 0.7, 0.86))) }       // bounce
        let px: CGFloat = 4
        let w = px * 5, h = px * 7
        let origin = CGPoint(x: 114, y: -12 - CGFloat(hop) * 5)
        c.saveGState()
        c.translateBy(x: origin.x + w / 2, y: origin.y + h)          // tip from the bottom dot
        c.rotate(by: rad(CGFloat(tilt)))
        c.translateBy(x: -w / 2, y: -h)
        c.setFillColor(C.clay)
        var rects: [CGRect] = []
        for (r, row) in questionGlyph.enumerated() {
            for (col, ch) in row.enumerated() where ch == "#" {
                rects.append(CGRect(x: CGFloat(col) * px, y: CGFloat(r) * px, width: px, height: px))
            }
        }
        c.beginPath(); c.addRects(rects); c.fillPath()
        c.restoreGState()
    }

    // MARK: Text

    static var workingTitleWidth: CGFloat = 82

    private static func drawText(_ sc: Scene, x: CGFloat, maxX: CGFloat, bounds: CGRect) {
        let title = NSAttributedString(string: sc.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let sub = NSAttributedString(string: sc.subtitle, attributes: [
            .paragraphStyle: para,
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ])
        let th = title.size().height
        let y = bounds.midY - th / 2
        title.draw(at: NSPoint(x: x, y: y))
        // While working, the subtitle sits after a fixed column (wide enough for the longest
        // spinner verb plus "..."), so it doesn't jump as the words and dots change.
        let titleCol = sc.mood == .working ? workingTitleWidth : title.size().width
        let subX = x + titleCol + 10
        sub.draw(with: NSRect(x: subX, y: y + (th - sub.size().height) / 2 + 0.5, width: max(0, maxX - subX), height: sub.size().height),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
