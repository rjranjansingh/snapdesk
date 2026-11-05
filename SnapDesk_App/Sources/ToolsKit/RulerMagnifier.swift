import AppKit

// MARK: - Pixel ruler

final class RulerView: NSView {
    var vertical = false { didSet { needsDisplay = true } }
    var unit = 0 { didSet { needsDisplay = true } }          // 0 px, 1 in, 2 cm
    var dpi: CGFloat = 96 { didSet { needsDisplay = true } }
    var mouse: NSPoint? { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    var onRotate: (() -> Void)?
    static let units = ["px", "in", "cm"], dpis: [CGFloat] = [72, 96, 120, 144, 192, 300]
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { mouse = convert(e.locationInWindow, from: nil) }
    override func mouseExited(with e: NSEvent) { mouse = nil }
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { onRotate?() } }

    var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    /// points per one "major unit" (100 px, 1 in or 1 cm)
    var ptPerMajor: CGFloat {
        switch unit { case 0: return 100 / scale; case 1: return dpi / scale; default: return dpi / 2.54 / scale }
    }
    func value(at pt: CGFloat) -> String {
        let major = pt / ptPerMajor
        return unit == 0 ? "\(Int((major * 100).rounded())) px" : String(format: "%.2f %@", major, Self.units[unit])
    }

    override func draw(_ r: NSRect) {
        NSColor(calibratedRed: 1, green: 0.96, blue: 0.78, alpha: 1).setFill(); bounds.fill()
        NSColor.darkGray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let len = vertical ? bounds.height : bounds.width
        let step = ptPerMajor / 10
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black]
        let path = NSBezierPath(); path.lineWidth = 1
        var i = 0
        while CGFloat(i) * step <= len {
            let p = CGFloat(i) * step + 0.5, tl: CGFloat = i % 10 == 0 ? 18 : i % 5 == 0 ? 12 : 7
            if vertical { path.move(to: NSPoint(x: 0, y: p)); path.line(to: NSPoint(x: tl, y: p)) }
            else { path.move(to: NSPoint(x: p, y: 0)); path.line(to: NSPoint(x: p, y: tl)) }
            if i % 10 == 0 {
                let n = unit == 0 ? i * 10 : i / 10
                (String(n) as NSString).draw(at: vertical ? NSPoint(x: 20, y: p - 5) : NSPoint(x: p + 2, y: 18), withAttributes: attrs)
            }
            i += 1
        }
        NSColor.black.setStroke(); path.stroke()
        let info = "\(value(at: len)) @ \(Int(dpi)) dpi"
        (info as NSString).draw(at: vertical ? NSPoint(x: 30, y: bounds.midY - 6) : NSPoint(x: bounds.midX - 40, y: bounds.height - 18),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.darkGray])
        if let m = mouse {
            NSColor.red.setStroke(); let l = NSBezierPath()
            let pt = vertical ? m.y : m.x
            if vertical { l.move(to: NSPoint(x: 0, y: m.y)); l.line(to: NSPoint(x: bounds.width, y: m.y)) }
            else { l.move(to: NSPoint(x: m.x, y: 0)); l.line(to: NSPoint(x: m.x, y: bounds.height)) }
            l.stroke()
            drawLabel(value(at: pt), at: NSPoint(x: m.x - 16, y: m.y - 16), in: bounds)
        }
    }
    override func menu(for e: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(menuItem(vertical ? "Rotate to Horizontal" : "Rotate to Vertical") { [weak self] in self?.onRotate?() })
        m.addItem(.separator())
        for (i, u) in Self.units.enumerated() { m.addItem(menuItem("Units: \(u)", checked: unit == i) { [weak self] in self?.unit = i }) }
        m.addItem(.separator())
        for d in Self.dpis { m.addItem(menuItem("DPI: \(Int(d))", checked: dpi == d) { [weak self] in self?.dpi = d }) }
        m.addItem(.separator())
        m.addItem(menuItem("Close Ruler") { [weak self] in self?.onClose?() })
        return m
    }
}

final class RulerTool: ToolBase {
    let win: KeyWindow
    let view = RulerView()
    init() {
        win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 64), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init(.pixelRuler)
        win.isReleasedWhenClosed = false; win.isMovableByWindowBackground = true; win.level = .floating
        win.hasShadow = true; win.alphaValue = 0.95; win.minSize = NSSize(width: 60, height: 60)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view; win.delegate = self; win.acceptsMouseMovedEvents = true
        view.onClose = { [weak self] in self?.close() }
        view.onRotate = { [weak self] in self?.rotate() }
        win.center(); win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    override var wantsEscape: Bool { false }
    func rotate() {
        var f = win.frame; let nf = NSRect(x: f.minX, y: f.maxY - f.width, width: f.height, height: f.width); f = nf
        view.vertical.toggle(); win.setFrame(f, display: true)
    }
    override func teardown() { win.delegate = nil; win.orderOut(nil); win.close() }
}

// MARK: - Magnifier lens

final class MagnifierTool: ToolBase {
    let win: NSPanel
    let lens = LoupeView()
    var zoom: CGFloat = 4, follow = true, inflight = false, timer: Timer?
    static let zooms: [CGFloat] = [2, 3, 4, 6, 8, 12, 16]

    init() {
        win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 260), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(.magnifier)
        win.isReleasedWhenClosed = false; win.level = .screenSaver; win.hasShadow = true; win.minSize = NSSize(width: 80, height: 80)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        lens.centerBox = false; win.contentView = lens
        lens.onScroll = { [weak self] d in
            guard let self, d != 0, let i = Self.zooms.firstIndex(of: self.zoom) else { return }
            self.zoom = Self.zooms[min(max(i + (d > 0 ? 1 : -1), 0), Self.zooms.count - 1)]
        }
        lens.menuBuilder = { [weak self] in self?.buildMenu() }
        win.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func buildMenu() -> NSMenu {
        let m = NSMenu()
        for z in Self.zooms { m.addItem(menuItem("Zoom \(Int(z))x", checked: zoom == z) { [weak self] in self?.zoom = z }) }
        m.addItem(.separator())
        m.addItem(menuItem("Follow Cursor", checked: follow) { [weak self] in self?.follow.toggle() })
        m.addItem(menuItem("Close Magnifier") { [weak self] in self?.close() })
        return m
    }
    override func teardown() { timer?.invalidate(); win.orderOut(nil); win.close() }

    func tick() {
        let cm = NSEvent.mouseLocation, m = Grab.mouse()
        let sz = win.frame.size
        if follow && !win.frame.insetBy(dx: -8, dy: -8).contains(cm) {
            let scr = NSScreen.screens.first { $0.frame.contains(cm) } ?? NSScreen.screens[0]
            var o = NSPoint(x: cm.x + 28, y: cm.y - 28 - sz.height)
            if o.x + sz.width > scr.frame.maxX { o.x = cm.x - 28 - sz.width }
            if o.y < scr.frame.minY { o.y = cm.y + 28 }
            win.setFrameOrigin(o)
        }
        guard !inflight else { return }
        let w = sz.width / zoom, h = sz.height / zoom
        inflight = true
        Grab.image(CGRect(x: m.x - w / 2, y: m.y - h / 2, width: w, height: h)) { [weak self] img, _ in
            guard let self else { return }
            self.inflight = false
            self.lens.image = img
            self.lens.caption = img == nil ? ["Screen Recording permission needed"] : ["\(Int(self.zoom))x"]
        }
    }
}

