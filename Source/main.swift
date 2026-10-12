import AppKit

private let mint = NSColor(srgbRed: 0.33, green: 0.61, blue: 0.47, alpha: 1)
private let ink = NSColor(srgbRed: 0.16, green: 0.24, blue: 0.20, alpha: 1)
private let secondary = NSColor(srgbRed: 0.46, green: 0.51, blue: 0.47, alpha: 1)
private let cream = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.93, alpha: 1)
private let card = NSColor(srgbRed: 1, green: 1, blue: 0.99, alpha: 1)

struct HealthState: Codable {
    var waterMinutes = 45
    var moveMinutes = 50
    var waterEnabled = true
    var moveEnabled = true
    var soundEnabled = false
    var glasses = 0
    var stretches = 0
    var day = ""
    var nextWater: Date = Date().addingTimeInterval(45 * 60)
    var nextMove: Date = Date().addingTimeInterval(50 * 60)
    var pausedUntil: Date? = nil
    // Session timers intentionally aren't restored after the app exits.
}

enum Session { case idle, focus, rest }
enum Event: Equatable { case water, move, focusFinished, restFinished }

final class HealthModel {
    var state: HealthState
    var session: Session = .idle
    var sessionEnd: Date?
    let defaults: UserDefaults?
    init(defaults: UserDefaults? = .standard, now: Date = Date()) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: "MintHealthState"),
           let decoded = try? JSONDecoder().decode(HealthState.self, from: data) {
            state = decoded
        } else { state = HealthState() }
        state.waterMinutes = max(10, min(180, state.waterMinutes))
        state.moveMinutes = max(10, min(180, state.moveMinutes))
        rollover(now)
        resetReminders(now)
    }
    func dayKey(_ now: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }
    func rollover(_ now: Date) {
        let key = dayKey(now)
        if state.day != key { state.day = key; state.glasses = 0; state.stretches = 0; save() }
    }
    func save() {
        if let data = try? JSONEncoder().encode(state) { defaults?.set(data, forKey: "MintHealthState") }
    }
    func resetReminders(_ now: Date) {
        state.nextWater = now.addingTimeInterval(Double(state.waterMinutes * 60))
        state.nextMove = now.addingTimeInterval(Double(state.moveMinutes * 60))
        save()
    }
    func isPaused(_ now: Date) -> Bool { state.pausedUntil.map { $0 > now } ?? false }
    func drink(_ now: Date) { rollover(now); state.glasses += 1; state.nextWater = now.addingTimeInterval(Double(state.waterMinutes * 60)); save() }
    func stretch(_ now: Date) { rollover(now); state.stretches += 1; state.nextMove = now.addingTimeInterval(Double(state.moveMinutes * 60)); save() }
    func startFocus(_ minutes: Int, _ now: Date) { session = .focus; sessionEnd = now.addingTimeInterval(Double(minutes * 60)) }
    func startRest(_ now: Date) { session = .rest; sessionEnd = now.addingTimeInterval(5 * 60) }
    func stopSession(_ now: Date) { session = .idle; sessionEnd = nil; resetReminders(now) }
    func remaining(_ now: Date) -> Int { max(0, Int(ceil(sessionEnd?.timeIntervalSince(now) ?? 0))) }
    func tick(_ now: Date) -> [Event] {
        rollover(now)
        if let end = sessionEnd, now >= end {
            let event: Event = session == .focus ? .focusFinished : .restFinished
            session = .idle; sessionEnd = nil; resetReminders(now)
            return [event]
        }
        // Quiet sessions and pause suppress nudges; they do not change the timer.
        if session != .idle || isPaused(now) { return [] }
        if state.pausedUntil != nil { state.pausedUntil = nil; resetReminders(now); return [] }
        var result: [Event] = []
        if state.waterEnabled && now >= state.nextWater {
            result.append(.water); state.nextWater = now.addingTimeInterval(Double(state.waterMinutes * 60))
        }
        if state.moveEnabled && now >= state.nextMove {
            result.append(.move); state.nextMove = now.addingTimeInterval(Double(state.moveMinutes * 60))
        }
        if !result.isEmpty { save() }
        return result
    }
}

func fillRound(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func ellipse(_ rect: NSRect, _ color: NSColor) { color.setFill(); NSBezierPath(ovalIn: rect).fill() }
func text(_ string: String, _ rect: NSRect, size: CGFloat = 14, color: NSColor = ink, weight: NSFont.Weight = .regular, align: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle(); style.alignment = align; style.lineBreakMode = .byWordWrapping
    (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
}
func line(_ points: [NSPoint], _ color: NSColor, width: CGFloat = 2) {
    guard let first = points.first else { return }
    let p = NSBezierPath(); p.move(to: first); points.dropFirst().forEach { p.line(to: $0) }
    p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round; color.setStroke(); p.stroke()
}

// A damped spring gives each press a squash, overshoot and soft settling.
struct JellySpring {
    var compression = 0.0
    var velocity = 0.0
    var tilt = 0.0
    var tiltVelocity = 0.0
    var held = false
    var rub = 0.0
    mutating func press() { held = true }
    mutating func release() { held = false; velocity -= 1.05; rub = 0 }
    mutating func stroke(_ delta: Double) {
        rub = max(-1, min(1, delta / 12))
        tiltVelocity += max(-1.8, min(1.8, delta * 0.08))
        velocity += min(0.65, abs(delta) * 0.025)
    }
    mutating func step(_ elapsed: Double, reducedMotion: Bool = false) {
        let target = held ? 0.23 + abs(rub) * 0.045 : 0
        if reducedMotion { compression = target; velocity = 0; tilt = 0; tiltVelocity = 0; return }
        let duration = max(0, min(elapsed, 0.1))
        let count = max(1, Int(ceil(duration * 120)))
        let dt = duration / Double(count)
        for _ in 0..<count {
            velocity += ((target - compression) * 185 - velocity * 12) * dt
            compression += velocity * dt
            tiltVelocity += ((held ? rub * 0.09 : 0) - tilt) * 145 * dt - tiltVelocity * 11 * dt
            tilt += tiltVelocity * dt
            compression = max(-0.14, min(0.34, compression))
            tilt = max(-0.16, min(0.16, tilt))
        }
    }
}

struct PetHop {
    var height = 0.0
    var velocity = 0.0
    mutating func kick(excited: Bool = false) { velocity = excited ? 245 : 220 }
    mutating func step(_ elapsed: Double, reducedMotion: Bool = false) {
        if reducedMotion { height = 0; velocity = 0; return }
        let duration = max(0, min(elapsed, 0.1))
        let n = max(1, Int(ceil(duration * 120))); let dt = duration / Double(n)
        for _ in 0..<n {
            guard height > 0 || velocity != 0 else { continue }
            velocity -= 1400 * dt; height += velocity * dt
            if height < 0 { height = 0; velocity = abs(velocity) > 70 ? -velocity * 0.24 : 0 }
            if height > 26 { height = 26; velocity = min(0, velocity) }
        }
    }
}

enum PetAction: CaseIterable { case water, focus, rest, move
    var rect: NSRect {
        switch self {
        case .water: return NSRect(x: 3, y: 105, width: 45, height: 46)
        case .move: return NSRect(x: 3, y: 173, width: 45, height: 46)
        case .focus: return NSRect(x: 212, y: 105, width: 45, height: 46)
        case .rest: return NSRect(x: 212, y: 173, width: 45, height: 46)
        }
    }
    static func at(_ point: NSPoint, visible: Bool = true) -> PetAction? { visible ? allCases.first { $0.rect.contains(point) } : nil }
}

struct NoseTray {
    private(set) var expanded = false
    private var closesAt = Date.distantPast
    mutating func toggle(_ now: Date) {
        expanded.toggle(); closesAt = now.addingTimeInterval(8)
    }
    mutating func keepOpen(_ now: Date) { if expanded { closesAt = now.addingTimeInterval(8) } }
    mutating func close() { expanded = false }
    mutating func expire(_ now: Date) { if expanded && now >= closesAt { close() } }
}

enum TouchZone { case nose, head, cheek, belly, paw, tail, body
    static func at(_ p: NSPoint) -> TouchZone {
        if hypot(p.x - 81, p.y - 76) <= 12 { return .nose }
        if p.y < 58 { return .head }
        if (p.x < 57 || p.x > 106) && p.y >= 72 && p.y <= 92 { return .cheek }
        if p.x > 132 && p.y > 89 { return .tail }
        if p.y >= 124 { return .paw }
        if p.x > 47 && p.x < 114 && p.y >= 91 { return .belly }
        return .body
    }
}

// Inverse of the drawing transform: even a squashed or tilted nose stays clickable.
func catPoint(_ point: NSPoint, rect: NSRect, phase: Double, squash: Double, tilt: Double, hop: Double) -> NSPoint {
    let scale = rect.width / 160
    let x = (point.x - rect.minX) / scale - 80
    let y = (point.y - rect.minY) / scale - 145
    let rx = x * cos(tilt) + y * sin(tilt)
    let ry = -x * sin(tilt) + y * cos(tilt)
    return NSPoint(x: rx / (1 + squash * 0.8) + 80, y: ry / (1 - squash) + 145 - sin(phase) * 0.8 + hop)
}

func heart(_ center: NSPoint, size: CGFloat, alpha: CGFloat = 1) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: center.x, y: center.y + size * 0.42))
    p.curve(to: NSPoint(x: center.x - size * 0.5, y: center.y - size * 0.04), controlPoint1: NSPoint(x: center.x - size * 0.18, y: center.y + size * 0.27), controlPoint2: NSPoint(x: center.x - size * 0.5, y: center.y + size * 0.04))
    p.curve(to: center, controlPoint1: NSPoint(x: center.x - size * 0.5, y: center.y - size * 0.42), controlPoint2: NSPoint(x: center.x - size * 0.14, y: center.y - size * 0.45))
    p.curve(to: NSPoint(x: center.x + size * 0.5, y: center.y - size * 0.04), controlPoint1: NSPoint(x: center.x + size * 0.14, y: center.y - size * 0.45), controlPoint2: NSPoint(x: center.x + size * 0.5, y: center.y - size * 0.42))
    p.curve(to: NSPoint(x: center.x, y: center.y + size * 0.42), controlPoint1: NSPoint(x: center.x + size * 0.5, y: center.y + size * 0.04), controlPoint2: NSPoint(x: center.x + size * 0.18, y: center.y + size * 0.27))
    p.close(); NSColor(srgbRed: 0.94, green: 0.53, blue: 0.61, alpha: alpha).setFill(); p.fill()
}

// Original mochi-shaped vector cat. All deformation pivots around its feet.
func drawCat(in rect: NSRect, phase: Double = 0, resting: Bool = false, squash: Double = 0, tilt: Double = 0, happy: Bool = false, hop: Double = 0, blush: Double = 0, wave: Double = 0, wag: Double = 0, noseBop: Double = 0) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: rect.minX, yBy: rect.minY); t.scale(by: rect.width / 160); t.concat()
    let lift = CGFloat(sin(phase) * 0.8)
    let shadowWidth = CGFloat(102 + squash * 60)
    ellipse(NSRect(x: 80 - shadowWidth / 2, y: 140, width: shadowWidth, height: 10), ink.withAlphaComponent(0.07))
    let deform = NSAffineTransform()
    deform.translateX(by: 80, yBy: 145)
    deform.rotate(byDegrees: CGFloat(tilt * 180 / .pi))
    deform.scaleX(by: CGFloat(1 + squash * 0.8), yBy: CGFloat(1 - squash))
    deform.translateX(by: -80, yBy: -145 + lift - CGFloat(hop)); deform.concat()
    let pale = NSColor(srgbRed: 0.76, green: 0.91, blue: 0.81, alpha: 1)
    let soft = NSColor(srgbRed: 0.51, green: 0.77, blue: 0.64, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    let tailTurn = NSAffineTransform(); tailTurn.translateX(by: 125, yBy: 120); tailTurn.rotate(byDegrees: CGFloat(wag * 30)); tailTurn.translateX(by: -125, yBy: -120); tailTurn.concat()
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: 125, y: 120)); tail.curve(to: NSPoint(x: 141, y: 98), controlPoint1: NSPoint(x: 148, y: 130), controlPoint2: NSPoint(x: 153, y: 110)); tail.lineWidth = 12; tail.lineCapStyle = .round; soft.setStroke(); tail.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 23, y: 75))
    body.curve(to: NSPoint(x: 31, y: 23), controlPoint1: NSPoint(x: 22, y: 60), controlPoint2: NSPoint(x: 20, y: 22))
    body.curve(to: NSPoint(x: 58, y: 36), controlPoint1: NSPoint(x: 42, y: 15), controlPoint2: NSPoint(x: 53, y: 29))
    body.curve(to: NSPoint(x: 104, y: 36), controlPoint1: NSPoint(x: 72, y: 31), controlPoint2: NSPoint(x: 91, y: 31))
    body.curve(to: NSPoint(x: 131, y: 23), controlPoint1: NSPoint(x: 114, y: 26), controlPoint2: NSPoint(x: 122, y: 15))
    body.curve(to: NSPoint(x: 138, y: 79), controlPoint1: NSPoint(x: 145, y: 25), controlPoint2: NSPoint(x: 137, y: 59))
    body.curve(to: NSPoint(x: 128, y: 125), controlPoint1: NSPoint(x: 145, y: 98), controlPoint2: NSPoint(x: 141, y: 116))
    body.curve(to: NSPoint(x: 34, y: 125), controlPoint1: NSPoint(x: 119, y: 149), controlPoint2: NSPoint(x: 42, y: 149))
    body.curve(to: NSPoint(x: 23, y: 75), controlPoint1: NSPoint(x: 19, y: 116), controlPoint2: NSPoint(x: 16, y: 92))
    body.close()
    NSGradient(starting: pale, ending: soft)!.draw(in: body, angle: 90)
    // Rounded inner ears, cream belly and tiny marshmallow paws.
    ellipse(NSRect(x: 33, y: 29, width: 15, height: 22), NSColor(srgbRed: 0.99, green: 0.79, blue: 0.75, alpha: 0.75))
    ellipse(NSRect(x: 114, y: 29, width: 15, height: 22), NSColor(srgbRed: 0.99, green: 0.79, blue: 0.75, alpha: 0.75))
    ellipse(NSRect(x: 47, y: 89, width: 68, height: 46), cream.withAlphaComponent(0.85))
    ellipse(NSRect(x: 35, y: 128, width: 32, height: 17), pale)
    ellipse(NSRect(x: 95, y: 128, width: 32, height: 17), pale)
    ellipse(NSRect(x: 36, y: 94, width: 20, height: 29), pale.withAlphaComponent(0.9))
    NSGraphicsContext.saveGraphicsState()
    let pawTurn = NSAffineTransform(); pawTurn.translateX(by: 116, yBy: 100); pawTurn.rotate(byDegrees: CGFloat(wave * 60)); pawTurn.translateX(by: -116, yBy: -100); pawTurn.concat()
    ellipse(NSRect(x: 106, y: 94, width: 20, height: 29), pale.withAlphaComponent(0.9))
    NSGraphicsContext.restoreGraphicsState()
    ellipse(NSRect(x: 32 - blush * 2, y: 75 - blush, width: 24 + blush * 4, height: 13 + blush * 3), NSColor(srgbRed: 0.98, green: 0.60, blue: 0.66, alpha: 0.7 + blush * 0.3))
    ellipse(NSRect(x: 107 - blush * 2, y: 75 - blush, width: 24 + blush * 4, height: 13 + blush * 3), NSColor(srgbRed: 0.98, green: 0.60, blue: 0.66, alpha: 0.7 + blush * 0.3))
    let blink = resting || happy || sin(phase * 0.37) > 0.992
    let eyeInk = NSColor(srgbRed: 0.22, green: 0.30, blue: 0.26, alpha: 1)
    if blink {
        for x: CGFloat in [54, 99] {
            let eye = NSBezierPath(); eye.move(to: NSPoint(x: x, y: 69)); eye.curve(to: NSPoint(x: x + 12, y: 69), controlPoint1: NSPoint(x: x + 3, y: happy ? 60 : 74), controlPoint2: NSPoint(x: x + 9, y: happy ? 60 : 74)); eye.lineWidth = 2.8; eye.lineCapStyle = .round; eyeInk.setStroke(); eye.stroke()
        }
    } else {
        ellipse(NSRect(x: 54, y: 58, width: 12, height: 17), eyeInk)
        ellipse(NSRect(x: 98, y: 58, width: 12, height: 17), eyeInk)
        ellipse(NSRect(x: 56, y: 60, width: 4, height: 5), .white)
        ellipse(NSRect(x: 100, y: 60, width: 4, height: 5), .white)
        ellipse(NSRect(x: 61, y: 70, width: 2, height: 2), .white.withAlphaComponent(0.7))
        ellipse(NSRect(x: 105, y: 70, width: 2, height: 2), .white.withAlphaComponent(0.7))
    }
    ellipse(NSRect(x: 78 - noseBop, y: 74 - noseBop * 0.5, width: 6 + noseBop * 2, height: 4 + noseBop), eyeInk)
    line([NSPoint(x: 81, y: 78), NSPoint(x: 81, y: 81), NSPoint(x: 76, y: 84)], eyeInk, width: 1.7)
    line([NSPoint(x: 81, y: 81), NSPoint(x: 86, y: 84)], eyeInk, width: 1.7)
    if happy { ellipse(NSRect(x: 78, y: 84, width: 6, height: 4), NSColor(srgbRed: 0.96, green: 0.59, blue: 0.63, alpha: 1)) }
    // A little custard-yellow bow instead of a rigid collar.
    ellipse(NSRect(x: 67, y: 94, width: 14, height: 11), NSColor(srgbRed: 0.98, green: 0.84, blue: 0.52, alpha: 1))
    ellipse(NSRect(x: 81, y: 94, width: 14, height: 11), NSColor(srgbRed: 0.98, green: 0.84, blue: 0.52, alpha: 1))
    ellipse(NSRect(x: 77, y: 95, width: 8, height: 9), NSColor(srgbRed: 0.93, green: 0.74, blue: 0.40, alpha: 1))
    ellipse(NSRect(x: 38, y: 49, width: 15, height: 6), .white.withAlphaComponent(0.35))
    line([NSPoint(x: 80, y: 35), NSPoint(x: 80, y: 21)], soft, width: 2.2)
    ellipse(NSRect(x: 79, y: 12, width: 18, height: 9), pale)
    ellipse(NSRect(x: 66, y: 15, width: 15, height: 8), pale)
    NSGraphicsContext.restoreGraphicsState()
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

final class IconView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        fillRound(bounds.insetBy(dx: 20, dy: 20), 210, cream)
        drawCat(in: NSRect(x: 132, y: 132, width: 760, height: 760))
    }
}

struct LoveParticle {
    var position: NSPoint
    var age: Double = 0
    var drift: CGFloat
    var size: CGFloat
}

final class PetView: FlippedView {
    weak var owner: AppDelegate?
    var phase: Double = 0
    var message = "戳戳我嘛 陪你一起摸鱼 ♡"
    var subtitle = "点鼻子开小口袋 抓住就能拖"
    var jelly = JellySpring()
    var hop = PetHop()
    var happyUntil = Date.distantPast
    var tray = NoseTray()
    var reaction: TouchZone?
    var reactionStarted = Date.distantPast
    private var touchedZone: TouchZone = .body
    var reactionAge: Double { max(0, Date().timeIntervalSince(reactionStarted)) }
    var reactionStrength: Double { max(0, 1 - reactionAge / 1.8) }
    var renderTilt: Double {
        guard !reducedMotion else { return 0 }
        let frequency = reaction == .belly ? 15.0 : 7.0
        let amplitude = reaction == .belly ? 0.09 : (reaction == .head ? 0.035 : 0)
        return jelly.tilt + sin(reactionAge * frequency) * amplitude * reactionStrength
    }
    var renderSquash: Double {
        jelly.compression + ((!reducedMotion && reaction == .belly) ? sin(reactionAge * 15) * 0.035 * reactionStrength : 0)
    }
    var particles: [LoveParticle] = []
    var loveUntil = Date.distantPast
    private var down: NSPoint?
    private var origin = NSPoint.zero
    private var moved = false
    private var touchingCat = false
    private var lastStrokeX: CGFloat = 0
    private var lastHeart = Date.distantPast
    private var pressedAction: PetAction?
    private var wasRubbed = false
    private var downAt = Date.distantPast
    var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func animationStep(_ elapsed: Double) {
        if pressedAction == nil { tray.expire(Date()) }
        jelly.step(elapsed, reducedMotion: reducedMotion)
        hop.step(elapsed, reducedMotion: reducedMotion)
        if !reducedMotion { phase += elapsed * 1.4 }
        for index in particles.indices {
            particles[index].age += elapsed
            particles[index].position.y -= CGFloat(elapsed * 29)
            particles[index].position.x += particles[index].drift * CGFloat(elapsed)
        }
        particles.removeAll { $0.age >= 1.25 }
        needsDisplay = true
    }
    func spawnHeart() {
        guard !reducedMotion, Date().timeIntervalSince(lastHeart) > 0.15 else { return }
        lastHeart = Date()
        if particles.count >= 10 { particles.removeFirst() }
        particles.append(LoveParticle(position: NSPoint(x: CGFloat.random(in: 72...188), y: CGFloat.random(in: 106...135)), drift: CGFloat.random(in: -14...14), size: CGFloat.random(in: 9...15)))
    }
    override func draw(_ dirtyRect: NSRect) {
        fillRound(NSRect(x: 10, y: 8, width: 240, height: 60), 18, cream)
        let triangle = NSBezierPath(); triangle.move(to: NSPoint(x: 123, y: 67)); triangle.line(to: NSPoint(x: 132, y: 76)); triangle.line(to: NSPoint(x: 140, y: 67)); triangle.close(); cream.setFill(); triangle.fill()
        let pleased = jelly.held || Date() < loveUntil || Date() < happyUntil
        text((jelly.held || Date() < loveUntil) ? "呼噜呼噜 再揉一下嘛 ♡" : message, NSRect(x: 23, y: 23, width: 214, height: 35), size: 13, weight: .medium, align: .center)
        drawCat(in: NSRect(x: 54, y: 75, width: 152, height: 152), phase: phase, resting: owner?.model.session == .rest, squash: renderSquash, tilt: renderTilt, happy: pleased, hop: hop.height,
                blush: reaction == .cheek ? reactionStrength : 0,
                wave: !reducedMotion && reaction == .paw ? sin(reactionAge * 12) * reactionStrength : 0,
                wag: !reducedMotion && reaction == .tail ? sin(reactionAge * 15) * reactionStrength : 0,
                noseBop: reaction == .nose ? reactionStrength : 0)
        for particle in particles { heart(particle.position, size: particle.size, alpha: CGFloat(max(0, 1 - particle.age / 1.25))) }
        for action in (tray.expanded ? PetAction.allCases : []) {
            let r = action.rect
            fillRound(r, 16, pressedAction == action ? mint.withAlphaComponent(0.28) : cream.withAlphaComponent(0.97))
            let emoji: String; let caption: String
            switch action {
            case .water: emoji = "💧"; caption = "喝水"
            case .move: emoji = "🐾"; caption = "活动"
            case .focus: emoji = "⏳"; caption = (owner?.model.session ?? .idle) == .idle ? "专注" : "结束"
            case .rest: emoji = "🍃"; caption = "歇歇"
            }
            text(emoji, NSRect(x: r.minX + 3, y: r.minY + 3, width: 39, height: 23), size: 18, align: .center)
            text(caption, NSRect(x: r.minX + 2, y: r.minY + 29, width: 41, height: 15), size: 9, color: secondary, align: .center)
        }
        fillRound(NSRect(x: 21, y: 231, width: 218, height: 26), 13, cream.withAlphaComponent(0.96))
        text(touchingCat ? "松开 啵唧～" : (tray.expanded ? "点鼻子收口袋 或选一个小挂件" : subtitle), NSRect(x: 27, y: 236, width: 206, height: 20), size: 10, color: secondary, align: .center)
    }
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        down = NSEvent.mouseLocation; origin = window?.frame.origin ?? .zero; moved = false
        downAt = Date(); wasRubbed = false; pressedAction = PetAction.at(local, visible: tray.expanded)
        touchingCat = pressedAction == nil && NSRect(x: 50, y: 75, width: 160, height: 153).contains(local) && !event.modifierFlags.contains(.shift)
        lastStrokeX = NSEvent.mouseLocation.x
        if pressedAction != nil { tray.keepOpen(Date()) }
        if touchingCat {
            touchedZone = TouchZone.at(catPoint(local, rect: NSRect(x: 54, y: 75, width: 152, height: 152), phase: phase, squash: renderSquash, tilt: renderTilt, hop: hop.height))
            // Nose taps open the pocket, so the nose must not move away during a press.
            if touchedZone != .nose { jelly.press(); loveUntil = Date().addingTimeInterval(2); spawnHeart() }
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, pressedAction == nil else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - down.x; let dy = p.y - down.y
        // Small strokes cuddle the cat; a deliberate drag picks up the whole pet.
        // Once picked up, it stays in drag mode until mouseUp.
        if touchingCat && hypot(dx, dy) >= 14 {
            touchingCat = false
            if jelly.held { jelly.release() }
            tray.close()
            loveUntil = .distantPast
        }
        if touchingCat {
            if touchedZone == .nose && hypot(dx, dy) > 4 { touchedZone = .body; jelly.press() }
            jelly.stroke(Double(p.x - lastStrokeX)); lastStrokeX = p.x
            wasRubbed = wasRubbed || abs(p.x - down.x) > 4
            loveUntil = Date().addingTimeInterval(2); spawnHeart()
        } else {
            if hypot(dx, dy) > 4 {
                moved = true; window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
                jelly.stroke(Double(p.x - lastStrokeX) * 0.35); lastStrokeX = p.x
            }
        }
    }
    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let action = pressedAction {
            if PetAction.at(local, visible: tray.expanded) == action {
                loveUntil = .distantPast; happyUntil = Date().addingTimeInterval(1.5)
                switch action {
                case .water: owner?.drink(nil)
                case .move: owner?.stretch(nil)
                case .focus: owner?.focusToggle(nil)
                case .rest: owner?.rest(nil)
                }
                tray.close(); hop.kick(); spawnHeart()
            }
        } else if touchingCat {
            if jelly.held { jelly.release() }
            if !wasRubbed {
                respond(to: touchedZone, excited: event.clickCount >= 2)
            } else { loveUntil = Date().addingTimeInterval(1.5); spawnHeart() }
        } else if moved { owner?.clampPet(); owner?.savePosition() }
        else { owner?.showStats(nil) }
        touchingCat = false; pressedAction = nil; down = nil
        needsDisplay = true
    }
    func respond(to zone: TouchZone, excited: Bool = false) {
        loveUntil = .distantPast; happyUntil = Date().addingTimeInterval(1.8)
        reaction = zone; reactionStarted = Date()
        switch zone {
        case .nose:
            tray.toggle(Date())
            owner?.bubble(tray.expanded ? "啵 小口袋打开啦 ♡" : "收好啦 继续摸摸我嘛 ♡", seconds: 4)
        case .head: owner?.bubble("摸摸脑袋 我就乖乖啦 ♡", seconds: 3); spawnHeart()
        case .cheek: owner?.bubble("哎呀 脸脸被你戳红啦 ♡", seconds: 3); spawnHeart()
        case .belly: owner?.bubble("痒痒痒 肚肚要扭起来啦 ♡", seconds: 3); spawnHeart()
        case .paw: owner?.bubble("小爪爪跟你说嗨呀 🐾", seconds: 3); spawnHeart()
        case .tail: owner?.bubble("尾巴摇摇 今天也喜欢你 ♡", seconds: 3); spawnHeart()
        case .body:
            hop.kick(excited: excited)
            owner?.bubble(excited ? "嘿嘿 开心到蹦起来 ♡" : ["啵唧 被你戳到啦 ♡", "我是一颗弹弹的薄荷团子 ♡", "再戳一下嘛 我还会蹦 ♡"].randomElement()!, seconds: 3)
            spawnHeart()
        }
        if excited && zone != .nose { hop.kick(excited: true) }
        needsDisplay = true
    }
    override func rightMouseDown(with event: NSEvent) { if let menu = owner?.makeMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
    override func accessibilityLabel() -> String? { "薄荷健康桌宠，点鼻子展开或收起按钮，摸脑袋戳脸挠肚子点爪子都有反应，按住小猫直接拖动搬家" }
}

final class RuaPreviewView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        fillRound(bounds, 24, cream)
        text("薄荷 · 揉起来软乎乎", NSRect(x: 28, y: 23, width: 700, height: 34), size: 23, weight: .semibold)
        let labels = ["按下 · 软软压扁", "松手 · 啵唧回弹", "揉揉 · 呼噜呼噜"]
        for i in 0..<3 {
            let x = CGFloat(24 + i * 244)
            fillRound(NSRect(x: x, y: 78, width: 226, height: 238), 22, card)
            drawCat(in: NSRect(x: x + 17, y: 100, width: 192, height: 192), squash: [0.25, -0.10, 0.09][i], tilt: [0, -0.05, 0.10][i], happy: i != 1)
            if i == 2 { heart(NSPoint(x: x + 45, y: 128), size: 16); heart(NSPoint(x: x + 190, y: 102), size: 12) }
            text(labels[i], NSRect(x: x + 10, y: 286, width: 206, height: 24), size: 13, color: secondary, align: .center)
        }
        text("点鼻子打开小口袋 · 脑袋脸脸肚肚爪爪都有小反应", NSRect(x: 24, y: 336, width: 714, height: 26), size: 13, color: secondary, align: .center)
    }
}

final class FloatingPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = HealthModel()
    var pet: FloatingPanel!
    var petView: PetView!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var animation: Timer?
    var bubbleUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPet()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "薄荷健康桌宠")
        statusItem.button?.toolTip = "薄荷健康桌宠"
        statusItem.menu = makeMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        var lastFrame = ProcessInfo.processInfo.systemUptime
        animation = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = min(0.1, max(0, now - lastFrame)); lastFrame = now
            guard let self, self.pet.isVisible else { return }
            self.petView.animationStep(elapsed)
        }
        RunLoop.main.add(animation!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        bubble("你好呀 我是软乎乎的薄荷 ♡", seconds: 6)
    }
    func createPet() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: screen.maxX - 285, y: screen.minY + 40)
        if let value = UserDefaults.standard.string(forKey: "MintPetPosition") { origin = NSPointFromString(value) }
        pet = FloatingPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 260, height: 266)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pet.isOpaque = false; pet.backgroundColor = .clear; pet.hasShadow = false
        pet.level = .floating; pet.hidesOnDeactivate = false
        pet.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 260, height: 266)); petView.owner = self
        pet.contentView = petView; clampPet(); pet.orderFrontRegardless()
    }
    @objc func screenChanged() { clampPet(); savePosition() }
    func clampPet() {
        guard let pet else { return }
        let screens = NSScreen.screens
        let frame = pet.frame
        let selected = screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let visible = selected?.visibleFrame else { return }
        pet.setFrameOrigin(NSPoint(x: min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width)), y: min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))))
    }
    func savePosition() { UserDefaults.standard.set(NSStringFromPoint(pet.frame.origin), forKey: "MintPetPosition") }
    @objc func woke() { model.resetReminders(Date()); tick() }
    func bubble(_ message: String, seconds: Double = 15) {
        petView.message = message; bubbleUntil = Date().addingTimeInterval(seconds)
        petView.needsDisplay = true
        if model.state.soundEnabled { NSSound(named: "Pop")?.play() }
    }
    func tick() {
        let now = Date()
        let events = model.tick(now)
        if events.contains(.focusFinished) { bubble("写完一段啦 点小叶子歇歇 🍃", seconds: 60) }
        else if events.contains(.restFinished) { bubble("伸个懒腰 慢慢继续呀 ♡", seconds: 30) }
        else if events.contains(.water) && events.contains(.move) { bubble("咕嘟喝口水 再起来走走呀 💧", seconds: 45) }
        else if events.contains(.water) { bubble("喝口水嘛 我陪你咕嘟咕嘟 💧", seconds: 45) }
        else if events.contains(.move) { bubble("小屁股歇歇 起来走走呀 🐾", seconds: 45) }
        if now > bubbleUntil {
            if model.isPaused(now) { petView.message = "嘘 我会乖乖陪着你 ♡" }
            else { switch model.session {
            case .focus: petView.message = "认真写吧 我在旁边陪你 ♡"
            case .rest: petView.message = "一起歇歇 看看远处的风景 🍃"
            case .idle: petView.message = "戳戳我嘛 陪你一起摸鱼 ♡"
            } }
        }
        if model.session != .idle {
            let left = model.remaining(now)
            petView.subtitle = String(format: "%@ · %02d:%02d", model.session == .focus ? "专注" : "休息", left / 60, left % 60)
        } else { petView.subtitle = "点鼻子开小口袋 抓住就能拖" }
        petView.needsDisplay = true
    }
    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; return item }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("看看今天的小进步 ♡", #selector(showStats(_:))))
        menu.addItem(menuItem("喝过水了 +1", #selector(drink(_:))))
        menu.addItem(menuItem("起身活动了 +1", #selector(stretch(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("专注 25 分钟", #selector(start25(_:))))
        menu.addItem(menuItem("专注 50 分钟", #selector(start50(_:))))
        menu.addItem(menuItem("休息 5 分钟", #selector(rest(_:))))
        menu.addItem(menuItem("结束当前计时", #selector(stop(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("暂停提醒 1 小时", #selector(pause(_:))))
        menu.addItem(menuItem("恢复提醒", #selector(resume(_:))))
        menu.addItem(menuItem("显示 / 隐藏桌宠", #selector(togglePet(_:))))
        let preferences = NSMenuItem(title: "提醒设置", action: nil, keyEquivalent: "")
        let options = NSMenu()
        for (title, values, selector, current, toggle, enabled) in [
            ("喝水提醒", [30, 45, 60, 90], #selector(setWaterInterval(_:)), model.state.waterMinutes, #selector(toggleWater(_:)), model.state.waterEnabled),
            ("起身提醒", [20, 30, 45, 50, 60], #selector(setMoveInterval(_:)), model.state.moveMinutes, #selector(toggleMove(_:)), model.state.moveEnabled)
        ] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let submenu = NSMenu()
            let enabledItem = menuItem("开启提醒", toggle); enabledItem.state = enabled ? .on : .off; submenu.addItem(enabledItem)
            submenu.addItem(.separator())
            for minutes in values {
                let item = menuItem("每 \(minutes) 分钟", selector); item.tag = minutes; item.state = minutes == current ? .on : .off; submenu.addItem(item)
            }
            parent.submenu = submenu; options.addItem(parent)
        }
        let sound = menuItem("轻轻的提示音", #selector(toggleSound(_:))); sound.state = model.state.soundEnabled ? .on : .off; options.addItem(sound)
        preferences.submenu = options; menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = menuItem("退出薄荷", #selector(quit(_:))); quit.keyEquivalent = "q"; menu.addItem(quit)
        return menu
    }
    @objc func showStats(_ sender: Any?) {
        model.rollover(Date())
        bubble("今天喝水 \(model.state.glasses) 次  活动 \(model.state.stretches) 次 ♡", seconds: 8)
        pet.orderFrontRegardless()
    }
    @objc func drink(_ sender: Any?) { model.drink(Date()); bubble("咕嘟咕嘟 喝水记好啦 💧", seconds: 8); tick() }
    @objc func stretch(_ sender: Any?) { model.stretch(Date()); bubble("活动记好啦 小爪爪为你鼓掌 🐾", seconds: 8); tick() }
    @objc func start25(_ sender: Any?) { model.startFocus(25, Date()); bubble("陪你专注 25 分钟 嗷 ♡"); tick() }
    @objc func start50(_ sender: Any?) { model.startFocus(50, Date()); bubble("陪你专注 50 分钟 乖乖等你 ♡"); tick() }
    @objc func focusToggle(_ sender: Any?) { if model.session == .idle { start25(sender) } else { stop(sender) } }
    @objc func stop(_ sender: Any?) { model.stopSession(Date()); bubble("好啦 计时收起来 慢慢来 ♡"); tick() }
    @objc func rest(_ sender: Any?) { guard model.session != .rest else { return }; model.startRest(Date()); bubble("歇五分钟嘛 薄荷也打个盹 🍃"); tick() }
    @objc func pause(_ sender: Any?) { model.state.pausedUntil = Date().addingTimeInterval(3600); model.save(); bubble("提醒睡一小时 计时还在跑哦 ♡"); tick() }
    @objc func resume(_ sender: Any?) { model.state.pausedUntil = nil; model.resetReminders(Date()); bubble("我醒啦 继续照顾你 ♡"); tick() }
    @objc func pauseToggle(_ sender: Any?) { model.isPaused(Date()) ? resume(sender) : pause(sender) }
    @objc func togglePet(_ sender: Any?) { pet.isVisible ? pet.orderOut(nil) : pet.orderFrontRegardless() }
    @objc func quit(_ sender: Any?) { model.save(); savePosition(); NSApp.terminate(nil) }
    func refreshSettings() {
        model.resetReminders(Date()); statusItem?.menu = makeMenu(); tick()
        bubble("记住啦 按你的节奏陪你 ♡", seconds: 5)
    }
    @objc func setWaterInterval(_ sender: NSMenuItem) { model.state.waterMinutes = sender.tag; refreshSettings() }
    @objc func setMoveInterval(_ sender: NSMenuItem) { model.state.moveMinutes = sender.tag; refreshSettings() }
    @objc func toggleWater(_ sender: Any?) { model.state.waterEnabled.toggle(); refreshSettings() }
    @objc func toggleMove(_ sender: Any?) { model.state.moveEnabled.toggle(); refreshSettings() }
    @objc func toggleSound(_ sender: Any?) { model.state.soundEnabled.toggle(); refreshSettings() }

}

func selfTest() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let m = HealthModel(defaults: nil, now: now)
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }; print("PASS: \(name)")
    }
    check(m.tick(now).isEmpty, "no immediate reminder on launch")
    check(m.tick(now.addingTimeInterval(45 * 60)) == [.water], "water reminder at configured interval")
    check(m.tick(now.addingTimeInterval(50 * 60)) == [.move], "movement reminder at configured interval")
    m.drink(now); check(m.state.glasses == 1, "drink action logs once")
    m.stretch(now); check(m.state.stretches == 1, "movement action logs once")
    m.startFocus(25, now)
    m.state.nextWater = now
    check(m.tick(now.addingTimeInterval(60)).isEmpty, "focus suppresses nudges")
    check(m.tick(now.addingTimeInterval(25 * 60)) == [.focusFinished], "focus finishes exactly once")
    check(m.tick(now.addingTimeInterval(25 * 60 + 1)).isEmpty, "no reminder burst after focus")
    m.startRest(now); check(m.state.stretches == 1, "starting rest does not invent a movement record")
    check(m.tick(now.addingTimeInterval(5 * 60)) == [.restFinished], "rest finishes after five minutes")
    m.state.pausedUntil = now.addingTimeInterval(3600)
    m.state.nextWater = now; m.state.nextMove = now
    check(m.tick(now.addingTimeInterval(1800)).isEmpty, "pause suppresses reminders")
    check(m.tick(now.addingTimeInterval(3601)).isEmpty, "pause expiry resets deadlines without burst")
    m.startFocus(25, now)
    check(m.tick(now.addingTimeInterval(25 * 60)) == [.focusFinished], "pause does not stop focus timer")
    m.stopSession(now); check(m.sessionEnd == nil && m.session == .idle, "stop clears session")
    m.rollover(now.addingTimeInterval(86400)); check(m.state.glasses == 0 && m.state.stretches == 0, "day change resets daily counts")
    let suite = "MintHealthSelfTest-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    let persisted = HealthModel(defaults: d, now: now); persisted.drink(now); persisted.state.waterMinutes = 60; persisted.save()
    let loaded = HealthModel(defaults: d, now: now)
    check(loaded.state.glasses == 1 && loaded.state.waterMinutes == 60, "settings and daily counts survive relaunch")
    d.removePersistentDomain(forName: suite)
    var spring = JellySpring(); spring.press()
    for _ in 0..<60 { spring.step(1.0 / 60) }
    check(abs(spring.compression - 0.23) < 0.01, "holding settles to a soft squash")
    spring.release()
    var overshot = false
    for _ in 0..<120 { spring.step(1.0 / 60); if spring.compression < -0.01 { overshot = true } }
    check(overshot, "release visibly overshoots for a jelly bounce")
    check(abs(spring.compression) < 0.001 && abs(spring.velocity) < 0.01, "release settles without endless wobble")
    spring.press(); spring.stroke(2000)
    for _ in 0..<15 { spring.step(1.0 / 60) }
    check(abs(spring.tilt) <= 0.16 && spring.compression <= 0.34, "fast rubbing stays within drawing bounds")
    spring.release(); spring.step(500)
    check(spring.compression.isFinite && spring.tilt.isFinite, "long frame gaps cannot explode spring simulation")
    spring.press(); spring.step(0.1, reducedMotion: true)
    check(abs(spring.compression - 0.23) < 0.001 && spring.tilt == 0, "reduced motion keeps press feedback without oscillation")
    var hop = PetHop(); hop.kick()
    var peak = 0.0
    for _ in 0..<120 { hop.step(1.0 / 60); peak = max(peak, hop.height) }
    check(peak > 12 && peak <= 26, "click makes a visible bounded hop")
    check(hop.height == 0 && hop.velocity == 0, "hop lands and stops")
    hop.kick(); hop.step(0.1, reducedMotion: true)
    check(hop.height == 0 && hop.velocity == 0, "reduced motion suppresses click hopping")
    check(PetAction.allCases.allSatisfy { PetAction.at(NSPoint(x: $0.rect.midX, y: $0.rect.midY)) == $0 }, "each on-pet button dispatches its own action")
    check(PetAction.at(NSPoint(x: 130, y: 150)) == nil, "petting the belly cannot accidentally record health actions")
    var pocket = NoseTray()
    check(!pocket.expanded && PetAction.at(NSPoint(x: 25, y: 128), visible: pocket.expanded) == nil, "hidden buttons cannot receive health actions")
    pocket.toggle(now)
    check(pocket.expanded && PetAction.at(NSPoint(x: 25, y: 128), visible: pocket.expanded) == .water, "nose opens buttons and makes them clickable")
    pocket.toggle(now)
    check(!pocket.expanded, "second nose tap closes buttons")
    pocket.toggle(now); pocket.keepOpen(now.addingTimeInterval(7)); pocket.expire(now.addingTimeInterval(9))
    check(pocket.expanded, "interacting keeps the pocket from closing mid-click")
    pocket.expire(now.addingTimeInterval(15))
    check(!pocket.expanded, "idle pocket automatically closes")
    let bodyRect = NSRect(x: 54, y: 75, width: 152, height: 152)
    let mappedNose = catPoint(NSPoint(x: 54 + 81 * 0.95, y: 75 + 76 * 0.95), rect: bodyRect, phase: 0, squash: 0, tilt: 0, hop: 0)
    check(TouchZone.at(mappedNose) == .nose, "rendered nose maps to nose interaction")
    check(TouchZone.at(NSPoint(x: 81, y: 44)) == .head && TouchZone.at(NSPoint(x: 44, y: 80)) == .cheek && TouchZone.at(NSPoint(x: 81, y: 112)) == .belly && TouchZone.at(NSPoint(x: 51, y: 135)) == .paw && TouchZone.at(NSPoint(x: 143, y: 108)) == .tail, "pet body zones produce distinct reactions")
    print("All 34 health and pet interaction checks passed.")
}

func exportPNG(_ view: NSView, path: String) {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot create bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot export PNG") }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { fatalError("PNG write failed: \(error)") }
}

if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
    let path = CommandLine.arguments[index + 1]
    let pv = PetView(frame: NSRect(x: 0, y: 0, width: 260, height: 266)); pv.owner = delegate
    exportPNG(pv, path: path)
    exportPNG(pv, path: path.replacingOccurrences(of: ".png", with: "-pet.png"))
    pv.tray.toggle(Date())
    exportPNG(pv, path: path.replacingOccurrences(of: ".png", with: "-open.png"))
    let icon = IconView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    exportPNG(icon, path: path.replacingOccurrences(of: ".png", with: "-icon.png"))
    let rua = RuaPreviewView(frame: NSRect(x: 0, y: 0, width: 762, height: 380))
    exportPNG(rua, path: path.replacingOccurrences(of: ".png", with: "-rua.png"))
    print("Preview exported: \(path)")
    exit(0)
}
app.run()
