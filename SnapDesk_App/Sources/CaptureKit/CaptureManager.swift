import AppKit
import ApplicationServices
import ScreenCaptureKit
import SnapCore

struct WinInfo { var id: CGWindowID; var pid: pid_t; var bounds: CGRect; var title: String }
enum LastTarget { case rect(CGRect), window(CGWindowID, CGRect) }   // CGRects: global, top-left origin
enum Pick { case image(CGImage, scale: CGFloat, LastTarget), window(WinInfo), cancel }

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID() }
    var cgFrame: CGRect { CGDisplayBounds(displayID) }
}
func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
func scaleFor(cgRect r: CGRect) -> CGFloat {
    NSScreen.screens.first { $0.cgFrame.contains(CGPoint(x: r.midX, y: r.midY)) }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
}
func nsImage(_ cg: CGImage, scale: CGFloat) -> NSImage {
    NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
}

public final class CaptureManager {
    public static let shared = CaptureManager()
    private var session: OverlaySession?
    private var lastTarget: LastTarget?
    private var busy = false
    private var countdownWindow: NSWindow?
    private init() {}

    public func capture(_ mode: CaptureMode, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !busy else { completion(nil); return }
            guard ensurePermission() else { completion(nil); return }
            busy = true
            let done: (NSImage?) -> Void = { [self] img in busy = false; completion(img) }
            countdown(Preferences.shared.captureDelay) { [self] in run(mode, done) }
        }
    }

    // MARK: permission
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "Screen Recording permission required"
        a.informativeText = "Enable this app under System Settings > Privacy & Security > Screen Recording, then relaunch it and capture again."
        a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
        return false
    }

    // MARK: delay + countdown
    private func countdown(_ seconds: Double, _ then: @escaping () -> Void) {
        guard seconds > 0 else { then(); return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = NSColor.black.withAlphaComponent(0.6); w.level = .screenSaver
        w.ignoresMouseEvents = true; w.hasShadow = false; w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let l = NSTextField(labelWithString: ""); l.font = .boldSystemFont(ofSize: 72); l.textColor = .white; l.alignment = .center
        l.frame = NSRect(x: 0, y: 18, width: 120, height: 90); w.contentView?.addSubview(l); w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 18
        w.setFrameOrigin(NSPoint(x: screen.frame.midX - 60, y: screen.frame.midY - 60))
        countdownWindow = w; w.orderFrontRegardless()
        func tick(_ left: Int) {
            if left <= 0 {
                w.orderOut(nil); countdownWindow = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: then)   // let the window leave the screen
                return
            }
            l.stringValue = "\(left)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(left - 1) }
        }
        tick(Int(seconds.rounded(.up)))
    }

    // MARK: dispatch
    private func run(_ mode: CaptureMode, _ done: @escaping (NSImage?) -> Void) {
        let prefs = Preferences.shared
        switch mode {
        case .fullScreen:
            let s = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
            grabRect(s.cgFrame, done)
        case .activeWindow:
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let wins = onScreenWindows()
            guard let w = wins.first(where: { $0.pid == front }) ?? wins.first else { return done(nil) }
            grabWindow(w, done)
        case .windowControl:
            overlay(.window(control: true)) { [self] in finish($0, done) }
        case .scrollingWindow:
            overlay(.window(control: false)) { [self] in
                if case .window(let w) = $0 { scroll(w, done) } else { done(nil) }
            }
        case .fixedRegion:
            overlay(.fixed(prefs.fixedRegionSize)) { [self] in finish($0, done) }
        case .region:
            overlay(.region) { [self] in finish($0, done) }
        case .freehand:
            overlay(.freehand) { [self] in finish($0, done) }
        case .repeatLast:
            switch lastTarget {
            case .rect(let r)?: grabRect(r, done)
            case .window(let id, let r)?:
                if let w = onScreenWindows().first(where: { $0.id == id }) { grabWindow(w, done) } else { grabRect(r, done) }
            case nil: run(.region, done)
            }
        }
    }

    private func finish(_ p: Pick, _ done: @escaping (NSImage?) -> Void) {
        switch p {
        case .image(let cg, let s, let t): lastTarget = t; done(nsImage(cg, scale: s))
        case .window(let w): grabWindow(w, done)
        case .cancel: done(nil)
        }
    }

    private func grabRect(_ r: CGRect, _ done: @escaping (NSImage?) -> Void) {
        lastTarget = .rect(r)
        let s = scaleFor(cgRect: r)
        grab(rect: r, windowID: nil) { done($0.map { nsImage($0, scale: s) }) }
    }
    private func grabWindow(_ w: WinInfo, _ done: @escaping (NSImage?) -> Void) {
        lastTarget = .window(w.id, w.bounds)
        let s = scaleFor(cgRect: w.bounds)
        grab(rect: w.bounds, windowID: w.id) { done($0.map { nsImage($0, scale: s) }) }
    }

    // MARK: overlay (freeze-frame of every screen, then pick)
    private func overlay(_ mode: OverlayMode, _ done: @escaping (Pick) -> Void) {
        let wins = onScreenWindows()
        var frozen: [(NSScreen, CGImage)] = []
        let g = DispatchGroup()
        for s in NSScreen.screens {
            g.enter()
            grab(rect: s.cgFrame, windowID: nil) { if let i = $0 { frozen.append((s, i)) }; g.leave() }
        }
        g.notify(queue: .main) { [self] in
            guard !frozen.isEmpty else { return done(.cancel) }
            session = OverlaySession(frozen: frozen, mode: mode, wins: wins) { [self] p in session = nil; done(p) }
            session?.show()
        }
    }

    // MARK: window list
    func onScreenWindows() -> [WinInfo] {
        let me = getpid()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0, (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: bd),
                  b.width >= 20, b.height >= 20, let id = d[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return WinInfo(id: id, pid: pid, bounds: b, title: (d[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (d[kCGWindowOwnerName as String] as? String) ?? "")
        }
    }

    // MARK: low-level grab. rect = global top-left coords. Completion on main, CGImage at native pixel scale.
    func grab(rect: CGRect, windowID: CGWindowID?, completion: @escaping (CGImage?) -> Void) {
        let cursor = Preferences.shared.includeCursor
        let scale = scaleFor(cgRect: rect)
        let fin: (CGImage?) -> Void = { img in DispatchQueue.main.async { completion(img) } }
        guard #available(macOS 14.0, *) else { return fin(legacyGrab(rect, windowID)) }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content else { return fin(nil) }
            let cfg = SCStreamConfiguration(); cfg.showsCursor = cursor
            let filter: SCContentFilter
            if let id = windowID {
                guard let w = content.windows.first(where: { $0.windowID == id }) else { return fin(nil) }
                filter = SCContentFilter(desktopIndependentWindow: w)
                cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
            } else {
                guard let d = content.displays.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) else { return fin(nil) }
                let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
                filter = SCContentFilter(display: d, excludingWindows: mine)
                cfg.sourceRect = rect.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
                cfg.width = Int(rect.width * scale); cfg.height = Int(rect.height * scale)
            }
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in fin(img) }
        }
    }
    // macOS 13 fallback (no cursor compositing). ponytail: CGWindowListCreateImage is obsoleted in the 15 SDK but still compiles for a 13 target.
    private func legacyGrab(_ r: CGRect, _ id: CGWindowID?) -> CGImage? {
        if let id { return CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) }
        return CGWindowListCreateImage(r, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    // MARK: scrolling capture
    private func scroll(_ w: WinInfo, _ done: @escaping (NSImage?) -> Void) {
        lastTarget = .window(w.id, w.bounds)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return done(nil) }   // posting scroll events needs Accessibility
        let scale = scaleFor(cgRect: w.bounds)
        let center = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
        CGWarpMouseCursorPosition(center)
        var pieces: [CGImage] = []
        var prev: [UInt8] = []
        func finishUp() {
            done(Stitch.assemble(pieces).map { nsImage($0, scale: scale) })
        }
        func step(_ n: Int) {
            let amount = Int32(w.bounds.height / 3)
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -amount, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                grab(rect: w.bounds, windowID: w.id) { img in
                    guard let img, img.width == pieces[0].width, img.height == pieces[0].height else { return finishUp() }
                    let g = Stitch.gray(img)
                    guard let d = Stitch.shift(prev, g, w: img.width, h: img.height), d > 0 else { return finishUp() }
                    if let p = Stitch.tail(img, d) { pieces.append(p) }
                    prev = g
                    n < 60 ? step(n + 1) : finishUp()
                }
            }
        }
        grab(rect: w.bounds, windowID: w.id) { img in
            guard let img else { return done(nil) }
            pieces = [img]; prev = Stitch.gray(img); step(0)
        }
    }
}
