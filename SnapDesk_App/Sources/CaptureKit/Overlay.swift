import AppKit
import ApplicationServices

enum OverlayMode { case region, fixed(CGSize), freehand, window(control: Bool) }

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One borderless, top-level window per screen, each showing a frozen snapshot of that screen.
final class OverlaySession {
    private var windows: [NSWindow] = []
    private var monitor: Any?
    private var finished = false
    private let frozen: [(NSScreen, CGImage)], mode: OverlayMode, wins: [WinInfo], done: (Pick) -> Void

    init(frozen: [(NSScreen, CGImage)], mode: OverlayMode, wins: [WinInfo], done: @escaping (Pick) -> Void) {
        self.frozen = frozen; self.mode = mode; self.wins = wins; self.done = done
    }

    func show() {
        for (s, img) in frozen {
            let w = OverlayWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(s.frame, display: false)
            w.level = .screenSaver; w.isOpaque = true; w.hasShadow = false; w.backgroundColor = .black
            w.acceptsMouseMovedEvents = true; w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = OverlayView(screen: s, image: img, mode: mode, wins: wins, session: self)
            w.contentView = v
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(v)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(.cancel); return nil }   // Esc
            return e
        }
    }

    func finish(_ p: Pick) {
        guard !finished else { return }
        finished = true
        if let m = monitor { NSEvent.removeMonitor(m) }
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        windows = []
        // let the window server drop the overlays before anything re-captures
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [done] in done(p) }
    }
}

final class OverlayView: NSView {
    let screen: NSScreen, image: CGImage, mode: OverlayMode, wins: [WinInfo]
    unowned let session: OverlaySession
    var mouse: CGPoint?, start: CGPoint?, cur: CGPoint?
    var path: [CGPoint] = []
    var hover: (rect: CGRect, cg: CGRect, win: WinInfo, control: Bool)?

    init(screen: NSScreen, image: CGImage, mode: OverlayMode, wins: [WinInfo], session: OverlaySession) {
        self.screen = screen; self.image = image; self.mode = mode; self.wins = wins; self.session = session
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: geometry
    var sx: CGFloat { CGFloat(image.width) / bounds.width }
    var sy: CGFloat { CGFloat(image.height) / bounds.height }
    func toCG(_ r: CGRect) -> CGRect {   // view rect -> global top-left rect
        let g = r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        return CGRect(x: g.minX, y: primaryHeight() - g.maxY, width: g.width, height: g.height)
    }
    func fromCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screen.frame.minX, y: primaryHeight() - r.maxY - screen.frame.minY, width: r.width, height: r.height)
    }
    func pxRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * sx, y: (bounds.height - r.maxY) * sy, width: r.width * sx, height: r.height * sy).integral
    }
    var selection: CGRect? {
        switch mode {
        case .region: if let a = start, let b = cur { return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
        case .fixed(let s): if let m = mouse {
            return CGRect(x: min(max(m.x - s.width / 2, 0), max(bounds.width - s.width, 0)), y: min(max(m.y - s.height / 2, 0), max(bounds.height - s.height, 0)),
                          width: min(s.width, bounds.width), height: min(s.height, bounds.height)) }
        case .window: return hover?.rect
        case .freehand: break
        }
        return nil
    }

    // MARK: input
    override func mouseMoved(with e: NSEvent) {
        mouse = convert(e.locationInWindow, from: nil)
        if case .window(let control) = mode, let m = mouse { updateHover(m, control: control) }
        needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        start = p; cur = p; path = [p]; needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p; cur = p
        if case .freehand = mode { path.append(p) }
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p; cur = p
        switch mode {
        case .region:
            if let r = selection, r.width >= 3, r.height >= 3 { commit(r) } else { start = nil; cur = nil }
        case .fixed:
            if let r = selection { commit(r) }
        case .window:
            if let h = hover { h.control ? commit(h.rect) : session.finish(.window(h.win)) }
        case .freehand:
            if path.count > 2 { commitPath() } else { path = [] }
        }
        needsDisplay = true
    }
    override func rightMouseDown(with e: NSEvent) { session.finish(.cancel) }

    func updateHover(_ p: CGPoint, control: Bool) {
        let g = toCG(CGRect(origin: p, size: .zero)).origin
        guard let w = wins.first(where: { $0.bounds.contains(g) }) else { hover = nil; return }
        if control, AXIsProcessTrusted(), let r = axFrame(pid: w.pid, at: g), r.width >= 8, r.height >= 8 {
            hover = (fromCG(r), r, w, true)
        } else {
            hover = (fromCG(w.bounds), w.bounds, w, false)
        }
    }
    private func axFrame(pid: pid_t, at g: CGPoint) -> CGRect? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(g.x), Float(g.y), &el) == .success, let el else { return nil }
        var pv: CFTypeRef?, sv: CFTypeRef?, pt = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    func commit(_ r: CGRect) {
        guard let c = image.cropping(to: pxRect(r)) else { return session.finish(.cancel) }
        session.finish(.image(c, scale: sx, .rect(toCG(r))))
    }

    func commitPath() {
        let xs = path.map(\.x), ys = path.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).intersection(bounds)
        let px = pxRect(box)
        guard px.width >= 2, px.height >= 2, let crop = image.cropping(to: px),
              let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return session.finish(.cancel) }
        let p = CGMutablePath()
        for (i, pt) in path.enumerated() {
            let q = CGPoint(x: pt.x * sx - px.minX, y: CGFloat(crop.height) - ((bounds.height - pt.y) * sy - px.minY))
            i == 0 ? p.move(to: q) : p.addLine(to: q)
        }
        p.closeSubpath()
        ctx.addPath(p); ctx.clip()
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let out = ctx.makeImage() else { return session.finish(.cancel) }
        session.finish(.image(out, scale: sx, .rect(toCG(box))))
    }

    // MARK: drawing
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: bounds)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.fill(bounds)
        if let r = selection {
            ctx.saveGState(); ctx.clip(to: r); ctx.draw(image, in: bounds); ctx.restoreGState()
            let isWin: Bool = { if case .window = mode { return true }; return false }()
            if isWin { ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor); ctx.fill(r) }
            ctx.setStrokeColor((isWin ? NSColor.systemBlue : NSColor.white).cgColor); ctx.setLineWidth(isWin ? 3 : 1); ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            label("\(Int(r.width * sx)) × \(Int(r.height * sx))" + (hover.map { isWin ? "  " + $0.win.title : "" } ?? ""), near: r)
        }
        if path.count > 1 {
            ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(2); ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.addLines(between: path); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
        }
        if case .window = mode {} else if let m = mouse { loupe(ctx, at: m) }
    }

    func label(_ s: String, near r: CGRect) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let t = NSAttributedString(string: s, attributes: a), sz = t.size()
        var o = CGPoint(x: r.minX, y: r.maxY + 4)
        if o.y + sz.height + 6 > bounds.height { o.y = r.minY - sz.height - 8 }
        if o.y < 0 { o.y = r.maxY - sz.height - 8 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: CGRect(x: o.x, y: o.y, width: sz.width + 10, height: sz.height + 4), xRadius: 4, yRadius: 4).fill()
        t.draw(at: CGPoint(x: o.x + 5, y: o.y + 2))
    }

    /// Magnifier loupe: 8x zoom of the pixels around the cursor.
    func loupe(_ ctx: CGContext, at m: CGPoint) {
        let d: CGFloat = 120, zoom: CGFloat = 8, n = Int(d / zoom)
        var o = CGPoint(x: m.x + 24, y: m.y - 24 - d)
        if o.x + d > bounds.width { o.x = m.x - 24 - d }
        if o.y < 0 { o.y = m.y + 24 }
        let box = CGRect(origin: o, size: CGSize(width: d, height: d))
        let src = CGRect(x: m.x * sx - CGFloat(n) / 2, y: (bounds.height - m.y) * sy - CGFloat(n) / 2, width: CGFloat(n), height: CGFloat(n)).integral
        guard let c = image.cropping(to: src) else { return }
        ctx.saveGState()
        ctx.addEllipse(in: box); ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(c, in: box)
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: box.minX, y: box.midY)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        ctx.move(to: CGPoint(x: box.midX, y: box.minY)); ctx.addLine(to: CGPoint(x: box.midX, y: box.maxY))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2); ctx.strokeEllipse(in: box)
        let g = toCG(CGRect(origin: m, size: .zero)).origin
        label("\(Int(g.x)), \(Int(g.y))", near: CGRect(x: box.minX, y: box.minY - 22, width: 0, height: 0))
    }
}
