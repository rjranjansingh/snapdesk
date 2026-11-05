import AppKit

// MARK: - Crosshair

final class CrosshairView: OverlayView {
    weak var tool: CrosshairTool?
    override func mouseDown(with e: NSEvent) { tool?.locked = Grab.mouse() }
    override func rightMouseDown(with e: NSEvent) { tool?.locked = nil }
    override func paint() {
        let m = Grab.mouse(), p = local(m)
        let red = NSColor.red.withAlphaComponent(0.8)
        red.setStroke()
        let l = NSBezierPath(); l.lineWidth = 1
        l.move(to: NSPoint(x: 0, y: p.y + 0.5)); l.line(to: NSPoint(x: bounds.maxX, y: p.y + 0.5))
        l.move(to: NSPoint(x: p.x + 0.5, y: 0)); l.line(to: NSPoint(x: p.x + 0.5, y: bounds.maxY)); l.stroke()
        var text = "X: \(Int(m.x))  Y: \(Int(m.y))"
        if let lk = tool?.locked {
            let q = local(lk), b = NSColor.systemBlue
            b.setStroke()
            let k = NSBezierPath(); k.lineWidth = 1; k.setLineDash([4, 3], count: 2, phase: 0)
            k.move(to: NSPoint(x: 0, y: q.y + 0.5)); k.line(to: NSPoint(x: bounds.maxX, y: q.y + 0.5))
            k.move(to: NSPoint(x: q.x + 0.5, y: 0)); k.line(to: NSPoint(x: q.x + 0.5, y: bounds.maxY)); k.stroke()
            b.withAlphaComponent(0.15).setFill(); NSRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y)).fill()
            let dx = m.x - lk.x, dy = m.y - lk.y
            text += String(format: "\nΔX: %.0f  ΔY: %.0f  D: %.1f\nLocked: %.0f, %.0f", dx, dy, hypot(dx, dy), lk.x, lk.y)
        }
        for (i, line) in text.split(separator: "\n").enumerated() {
            drawLabel(String(line), at: NSPoint(x: p.x, y: p.y + CGFloat(i) * 24), in: bounds)
        }
    }
}
final class CrosshairTool: OverlayTool {
    var locked: CGPoint?
    init() {
        super.init(.crosshair)
        startOverlays { [unowned self] s in let v = CrosshairView(screen: s); v.tool = self; return v }
    }
}

// MARK: - Protractor

final class ProtractorView: NSView {
    var pts: [CGPoint] = [CGPoint(x: 0.85, y: 0.5), CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.6, y: 0.15)]   // A, B (vertex), C as fractions of bounds
    var drag: Int?, startMouse = NSPoint.zero, startOrigin = NSPoint.zero
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    func abs(_ i: Int) -> NSPoint { NSPoint(x: pts[i].x * bounds.width, y: pts[i].y * bounds.height) }
    var closeRect: NSRect { NSRect(x: bounds.maxX - 24, y: 4, width: 20, height: 20) }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if closeRect.contains(p) { onClose?(); return }
        drag = (0..<3).first { hypot(abs($0).x - p.x, abs($0).y - p.y) < 14 }
        startMouse = NSEvent.mouseLocation; startOrigin = window?.frame.origin ?? .zero
    }
    override func mouseDragged(with e: NSEvent) {
        if let d = drag {
            let p = convert(e.locationInWindow, from: nil)
            pts[d] = CGPoint(x: min(max(p.x / bounds.width, 0), 1), y: min(max(p.y / bounds.height, 0), 1)); needsDisplay = true
        } else {
            let m = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: startOrigin.x + m.x - startMouse.x, y: startOrigin.y + m.y - startMouse.y))
        }
    }
    override func mouseUp(with e: NSEvent) { drag = nil }
    override func draw(_ r: NSRect) {
        NSColor(white: 0, alpha: 0.12).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.6).setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
        let a = abs(0), b = abs(1), c = abs(2)
        let ray = NSBezierPath(); ray.lineWidth = 2
        ray.move(to: a); ray.line(to: b); ray.line(to: c)
        NSColor.systemRed.setStroke(); ray.stroke()
        let a1 = atan2(a.y - b.y, a.x - b.x), a2 = atan2(c.y - b.y, c.x - b.x)
        var d = a2 - a1; while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
        let rad: CGFloat = 40, arc = NSBezierPath(); arc.lineWidth = 2
        for i in 0...40 {
            let t = a1 + d * CGFloat(i) / 40, q = NSPoint(x: b.x + rad * cos(t), y: b.y + rad * sin(t))
            i == 0 ? arc.move(to: q) : arc.line(to: q)
        }
        NSColor.systemYellow.setStroke(); arc.stroke()
        let deg = Swift.abs(d) * 180 / .pi
        let mid = a1 + d / 2
        (String(format: "%.1f°", deg) as NSString).draw(at: NSPoint(x: b.x + (rad + 8) * cos(mid) - 18, y: b.y + (rad + 8) * sin(mid) - 8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.systemYellow, .backgroundColor: NSColor.black.withAlphaComponent(0.5)])
        for (i, n) in ["A", "B", "C"].enumerated() {
            let p = abs(i)
            NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)).fill()
            NSColor.systemRed.setStroke(); NSBezierPath(ovalIn: NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)).stroke()
            (n as NSString).draw(at: NSPoint(x: p.x + 10, y: p.y - 18), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.5)])
        }
        ("✕" as NSString).draw(at: NSPoint(x: closeRect.minX + 3, y: closeRect.minY), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white])
        ("Drag handles A, B, C; drag elsewhere to move; Esc closes" as NSString).draw(at: NSPoint(x: 10, y: bounds.maxY - 20), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
    }
}
final class ProtractorTool: ToolBase {
    let win: KeyWindow
    init() {
        win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init(.protractor)
        let v = ProtractorView(); v.onClose = { [weak self] in self?.close() }
        win.isReleasedWhenClosed = false; win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.level = .screenSaver; win.minSize = NSSize(width: 200, height: 160); win.contentView = v
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.center(); win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    override func teardown() { win.orderOut(nil); win.close() }
}

// MARK: - Whiteboard

struct Stroke { var pts: [NSPoint]; var color: NSColor; var width: CGFloat; var highlighter: Bool }

final class WhiteboardView: OverlayView {
    weak var tool: WhiteboardTool?
    var strokes: [Stroke] = []
    override func mouseDown(with e: NSEvent) {
        guard let t = tool else { return }
        let p = convert(e.locationInWindow, from: nil)
        if t.mode == 2 { erase(at: p) }
        else { strokes.append(Stroke(pts: [p], color: t.color, width: t.mode == 1 ? t.width * 3 : t.width, highlighter: t.mode == 1)); needsDisplay = true }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if tool?.mode == 2 { erase(at: p) } else if !strokes.isEmpty { strokes[strokes.count - 1].pts.append(p); needsDisplay = true }
    }
    func erase(at p: NSPoint) {
        let n = strokes.count
        strokes.removeAll { s in s.pts.contains { hypot($0.x - p.x, $0.y - p.y) < s.width / 2 + 8 } }
        if strokes.count != n { needsDisplay = true }
    }
    override func paint() {
        for s in strokes {
            let path = NSBezierPath(); path.lineWidth = s.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: s.pts[0]); s.pts.dropFirst().forEach { path.line(to: $0) }
            if s.pts.count == 1 { path.line(to: NSPoint(x: s.pts[0].x + 0.1, y: s.pts[0].y)) }
            (s.highlighter ? s.color.withAlphaComponent(0.35) : s.color).setStroke(); path.stroke()
        }
    }
}

final class WhiteboardTool: OverlayTool {
    var mode = 0                      // 0 pen, 1 highlighter, 2 eraser
    var color = NSColor.systemRed
    var width: CGFloat = 4
    let bar: NSPanel
    weak var modeSeg: NSSegmentedControl?
    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    init() {
        bar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 44), styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(.whiteboard)
        startOverlays(fps: 0) { [unowned self] s in let v = WhiteboardView(screen: s); v.tool = self; return v }
        let seg = NSSegmentedControl(labels: ["Pen", "Highlighter", "Eraser"], trackingMode: .selectOne, target: self, action: #selector(setMode(_:)))
        seg.selectedSegment = 0; modeSeg = seg
        var items: [NSView] = [seg]
        for (i, c) in Self.palette.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(setColor(_:))); b.tag = i; b.isBordered = false
            b.wantsLayer = true; b.layer?.backgroundColor = c.cgColor; b.layer?.cornerRadius = 9; b.layer?.borderWidth = 1; b.layer?.borderColor = NSColor.gray.cgColor
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true; b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            items.append(b)
        }
        let sl = NSSlider(value: 4, minValue: 1, maxValue: 30, target: self, action: #selector(setWidth(_:)))
        sl.widthAnchor.constraint(equalToConstant: 80).isActive = true; sl.toolTip = "Width"
        items += [sl, NSButton(title: "Clear", target: self, action: #selector(clear)), NSButton(title: "Done", target: self, action: #selector(done))]
        let st = NSStackView(views: items); st.spacing = 6; st.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.contentView = st; bar.title = "Whiteboard"; bar.level = .screenSaver + 1; bar.isReleasedWhenClosed = false
        bar.setContentSize(st.fittingSize)
        if let s = NSScreen.main { bar.setFrameTopLeftPoint(NSPoint(x: s.frame.midX - bar.frame.width / 2, y: s.frame.maxY - 40)) }
        bar.orderFrontRegardless()
    }
    @objc func setMode(_ s: NSSegmentedControl) { mode = s.selectedSegment }
    @objc func setColor(_ b: NSButton) { color = Self.palette[b.tag]; if mode == 2 { mode = 0; modeSeg?.selectedSegment = 0 } }   // picking a colour leaves eraser mode; keep the control in sync
    @objc func setWidth(_ s: NSSlider) { width = CGFloat(s.doubleValue) }
    @objc func clear() { (views as? [WhiteboardView])?.forEach { $0.strokes = []; $0.needsDisplay = true } }
    @objc func done() { close() }
    override func teardown() { stopOverlays(); bar.orderOut(nil); bar.close() }
}
