import AppKit
import SnapCore
import ScreenCaptureKit

// MARK: - Color model

struct RGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    var formats: [(name: String, value: String)] {
        let (r, g, b) = (Int(r), Int(g), Int(b))
        return [
            ("HEX", String(format: "%02X%02X%02X", r, g, b)),
            ("RGB", "\(r), \(g), \(b)"),
            ("HTML", String(format: "#%02x%02x%02x", r, g, b)),
            ("C++", String(format: "0x%02X%02X%02X", b, g, r)),
            ("Delphi", String(format: "$00%02X%02X%02X", b, g, r)),
            ("Swift", String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: 1)", Double(r) / 255, Double(g) / 255, Double(b) / 255)),
        ]
    }
    var html: String { formats[2].value }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#$ ")); if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8(v >> 16 & 255), g: UInt8(v >> 8 & 255), b: UInt8(v & 255))
    }
    static func pixel(_ img: CGImage, x: Int, y: Int) -> RGB? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return RGB(r: px[0], g: px[1], b: px[2])
    }
}

// MARK: - Screen grabbing (ScreenCaptureKit on 14+, legacy CGWindowListCreateImage via dlsym on 13)

enum Grab {
    nonisolated(unsafe) static var warned = false
    nonisolated(unsafe) static var cache: (Date, SCShareableContent)?

    /// Cocoa (bottom-left) point -> global CG (top-left) point.
    static func cg(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: NSScreen.screens[0].frame.height - p.y) }
    static func mouse() -> CGPoint { cg(NSEvent.mouseLocation) }
    static func scale(at p: CGPoint) -> CGFloat {
        NSScreen.screens.first { CGRect(x: $0.frame.minX, y: NSScreen.screens[0].frame.height - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height).contains(p) }?.backingScaleFactor ?? 2
    }
    static var permitted: Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !warned { warned = true; CGRequestScreenCaptureAccess() }
        return false
    }

    /// `rect` is in global top-left points. Completion (main thread) gets the image and the rect actually captured (clamped to its display).
    static func image(_ rect: CGRect, _ done: @escaping (CGImage?, CGRect) -> Void) {
        guard permitted else { done(nil, rect); return }
        var did = CGDirectDisplayID(); var n: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &did, &n)
        guard n > 0 else { done(nil, rect); return }
        let db = CGDisplayBounds(did)
        let src = rect.intersection(db)
        guard !src.isNull, src.width >= 1, src.height >= 1 else { done(nil, rect); return }
        let sc = CGFloat(CGDisplayPixelsWide(did)) / db.width
        if #available(macOS 14.0, *) {
            let ownWins = Set(NSApp.windows.filter { $0.isVisible }.map { CGWindowID($0.windowNumber) })
            Task {
                do {
                    var content: SCShareableContent
                    if let c = cache, Date().timeIntervalSince(c.0) < 2,
                       ownWins.isSubset(of: Set(c.1.windows.map { $0.windowID })) { content = c.1 }
                    else { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true); cache = (Date(), content) }
                    guard let d = content.displays.first(where: { $0.displayID == did }) else { done(nil, src); return }
                    let own = content.windows.filter { ownWins.contains($0.windowID) }
                    let cfg = SCStreamConfiguration()
                    cfg.sourceRect = CGRect(x: src.minX - db.minX, y: src.minY - db.minY, width: src.width, height: src.height)
                    cfg.width = max(1, Int((src.width * sc).rounded())); cfg.height = max(1, Int((src.height * sc).rounded()))
                    cfg.showsCursor = false
                    let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: own), configuration: cfg)
                    await MainActor.run { done(img, src) }
                } catch { await MainActor.run { done(nil, src) } }
            }
        } else {
            typealias F = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let s = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { done(nil, src); return }
            // ponytail: legacy path includes our own windows (macOS 13 only); fine since 14+ uses SCK exclusion
            done(unsafeBitCast(s, to: F.self)(src, 1, 0, 1 << 3)?.takeRetainedValue(), src)
        }
    }
}

// MARK: - Shared UI helpers

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Act: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func run() { f() }
}
func menuItem(_ title: String, checked: Bool = false, _ f: @escaping () -> Void) -> NSMenuItem {
    let a = Act(f)
    let i = NSMenuItem(title: title, action: #selector(Act.run), keyEquivalent: "")
    i.target = a; i.representedObject = a; i.state = checked ? .on : .off
    return i
}

func drawLabel(_ s: String, at p: NSPoint, in bounds: NSRect, color: NSColor = .white, bg: NSColor = NSColor.black.withAlphaComponent(0.75)) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
    let sz = (s as NSString).size(withAttributes: attrs)
    var r = NSRect(x: p.x + 16, y: p.y + 16, width: sz.width + 12, height: sz.height + 6)
    if r.maxX > bounds.maxX { r.origin.x = p.x - 16 - r.width }
    if r.maxY > bounds.maxY { r.origin.y = p.y - 16 - r.height }
    bg.setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
    (s as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: attrs)
}

// MARK: - Tool base + full-screen overlays

class ToolBase: NSObject, NSWindowDelegate {
    let kind: DesignTool
    private var closed = false
    var wantsEscape: Bool { true }
    init(_ k: DesignTool) { kind = k }
    func teardown() {}
    func escape() { close() }
    final func close() {
        guard !closed else { return }
        closed = true; teardown()
        if DesignTools.registry[kind] === self { DesignTools.registry[kind] = nil }
    }
    func windowWillClose(_ n: Notification) { close() }
}

class OverlayView: NSView {
    let cgFrame: CGRect
    init(screen: NSScreen) {
        let h = NSScreen.screens[0].frame.height
        cgFrame = CGRect(x: screen.frame.minX, y: h - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    func local(_ g: CGPoint) -> NSPoint { NSPoint(x: g.x - cgFrame.minX, y: g.y - cgFrame.minY) }
    func global(_ l: NSPoint) -> CGPoint { CGPoint(x: l.x + cgFrame.minX, y: l.y + cgFrame.minY) }
    override func draw(_ r: NSRect) {
        NSColor(white: 0, alpha: 0.01).setFill(); bounds.fill(using: .copy)   // near-invisible so the window still receives mouse events
        paint()
    }
    func paint() {}
}

class OverlayTool: ToolBase {
    var windows: [KeyWindow] = []
    var views: [OverlayView] = []
    var timer: Timer?
    func startOverlays(level: NSWindow.Level = .screenSaver, fps: Double = 60, _ make: (NSScreen) -> OverlayView) {
        for s in NSScreen.screens {
            let w = KeyWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(s.frame, display: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.level = level
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = make(s); w.contentView = v
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
            windows.append(w); views.append(v)
        }
        NSApp.activate(ignoringOtherApps: true)
        if fps > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }
    func stopOverlays() {
        timer?.invalidate(); timer = nil
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []; views = []
    }
    func tick() { views.forEach { $0.needsDisplay = true } }
    override func teardown() { stopOverlays() }
}

// MARK: - Loupe (magnified pixel image)

final class LoupeView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var caption: [String] = [] { didSet { needsDisplay = true } }
    var swatch: NSColor?
    var centerBox = true
    var capHeight: CGFloat = 0
    var onScroll: ((CGFloat) -> Void)?
    var menuBuilder: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuBuilder?() }
    override var isFlipped: Bool { true }
    override func scrollWheel(with e: NSEvent) { onScroll?(e.scrollingDeltaY) }
    override func draw(_ r: NSRect) {
        let box = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - capHeight)
        NSColor.black.setFill(); bounds.fill()
        if let img = image {
            NSImage(cgImage: img, size: .zero).draw(in: box, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                                                    hints: [.interpolation: NSImageInterpolation.none])
            if centerBox {
                let cw = box.width / CGFloat(img.width), ch = box.height / CGFloat(img.height)
                let c = NSRect(x: CGFloat(img.width / 2) * cw, y: CGFloat(img.height / 2) * ch, width: cw, height: ch)
                NSColor.black.setStroke(); NSBezierPath(rect: c.insetBy(dx: -1, dy: -1)).stroke()
                NSColor.white.setStroke(); NSBezierPath(rect: c).stroke()
            }
        }
        if capHeight > 0 {
            var y = box.maxY + 4
            if let s = swatch { s.setFill(); NSRect(x: 6, y: y + 2, width: 28, height: capHeight - 12).fill(); NSColor.white.setStroke(); NSBezierPath(rect: NSRect(x: 6, y: y + 2, width: 28, height: capHeight - 12)).stroke() }
            for line in caption {
                (line as NSString).draw(at: NSPoint(x: 42, y: y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white])
                y += 15
            }
        }
        if capHeight == 0, let c = caption.first { drawLabel(c, at: NSPoint(x: -10, y: -10), in: bounds) }
        NSColor.white.withAlphaComponent(0.8).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
