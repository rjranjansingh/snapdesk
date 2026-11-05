import AppKit
import SnapCore

// Headless self-test for EditorKit (run via `SnapDesk --selftest`). Drives the real window / canvas / ribbon with synthetic events.

private func chk(_ n: String, _ ok: Bool, _ d: @autoclosure () -> String = "") { SelfTest.check("editor/" + n, ok, d()) }
private func pump(_ s: Double) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)); Thread.sleep(forTimeInterval: 0.005) }
}

// MARK: pixel helpers
private struct Px {
    let w: Int, h: Int
    var d: [UInt8]
    func at(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * w + x) * 4; return Array(d[i..<i + 4]) }
}
private func px(_ img: NSImage) -> Px {
    let c = img.cg!, w = c.width, h = c.height
    var d = [UInt8](repeating: 0, count: w * h * 4)
    d.withUnsafeMutableBytes {
        let ctx = CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Px(w: w, h: h, d: d)
}
private func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }
private func inRect(_ x: Int, _ y: Int, _ r: CGRect) -> Bool { x >= Int(r.minX) && x < Int(r.maxX) && y >= Int(r.minY) && y < Int(r.maxY) }
/// (pixels changed where `region` is true, pixels total in region)
private func changed(_ a: Px, _ b: Px, tol: Int = 0, _ region: (Int, Int) -> Bool) -> (Int, Int) {
    guard a.w == b.w, a.h == b.h else { return (-1, -1) }
    var n = 0, t = 0
    for y in 0..<a.h { for x in 0..<a.w where region(x, y) { t += 1; if maxDiff(a.at(x, y), b.at(x, y)) > tol { n += 1 } } }
    return (n, t)
}
private func color(_ r: Double, _ g: Double, _ b: Double) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

private func detailImage(_ w: Int, _ h: Int) -> NSImage {
    var s: UInt32 = 12345
    func rnd() -> Double { s = s &* 1664525 &+ 1013904223; return Double(s >> 8 & 0xFFFF) / 65535 }
    return makeImage(CGSize(width: w, height: h)) {
        for y in stride(from: 0, to: h, by: 3) { for x in stride(from: 0, to: w, by: 3) {
            color(rnd(), rnd(), rnd()).setFill(); CGRect(x: x, y: y, width: 3, height: 3).fill() } }
    }
}
private func solid(_ w: Int, _ h: Int, _ c: NSColor = .white) -> NSImage {
    makeImage(CGSize(width: w, height: h)) { c.setFill(); CGRect(x: 0, y: 0, width: w, height: h).fill() }
}
/// red everywhere, white inside `r` (used to detect colour bleeding across the selection edge)
private func bleedImage(_ w: Int, _ h: Int, _ r: CGRect) -> NSImage {
    makeImage(CGSize(width: w, height: h)) {
        color(1, 0, 0).setFill(); CGRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor.white.setFill(); r.fill()
    }
}
private func halves(_ w: Int, _ h: Int) -> NSImage {
    makeImage(CGSize(width: w, height: h)) {
        color(1, 0, 0).setFill(); CGRect(x: 0, y: 0, width: w / 2, height: h).fill()
        color(0, 0, 1).setFill(); CGRect(x: w / 2, y: 0, width: w - w / 2, height: h).fill()
    }
}

private func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }

public func editorKitSelfTest() {
    let img0 = detailImage(300, 200)
    let c = EditorWindowController(image: img0)
    guard let win = c.window, let root = win.contentView else { chk("window", false, "no window"); return }
    // keep everything invisible: transparent window + transparent tip bubble
    win.alphaValue = 0; RibbonTip.shared.panel.alphaValue = 0
    c.showWindow(nil); win.orderFrontRegardless()
    let doc = c.doc, cv = c.canvas
    chk("window/created", true)

    doc.undo.groupsByEvent = false   // headless: no run-loop turns between synthetic events, so every operation is wrapped in step{} instead
    func nwin(_ x: CGFloat, _ y: CGFloat) -> NSPoint { cv.convert(NSPoint(x: x, y: y), to: nil) }
    func ipt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { nwin(cv.margin + x * cv.zoom, cv.margin + y * cv.zoom) }   // image px -> window coords
    func ev(_ t: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    /// One undo step per call, independent of run-loop turns.
    func step(_ f: () -> Void) { doc.undo.beginUndoGrouping(); f(); doc.undo.endUndoGrouping() }
    func drag(_ pts: [(CGFloat, CGFloat)], clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        step {
            cv.mouseDown(with: ev(.leftMouseDown, ipt(pts[0].0, pts[0].1), clicks: clicks, flags: flags))
            for p in pts.dropFirst() { cv.mouseDragged(with: ev(.leftMouseDragged, ipt(p.0, p.1), flags: flags)) }
            cv.mouseUp(with: ev(.leftMouseUp, ipt(pts.last!.0, pts.last!.1), clicks: clicks, flags: flags))
        }
    }
    func click(_ x: CGFloat, _ y: CGFloat, clicks: Int = 1) { drag([(x, y)], clicks: clicks) }
    func reset(_ image: NSImage, zoom: CGFloat = 1) {
        doc.state = Document.State(image: Raster.normalized(image), objects: [])
        while doc.undo.groupingLevel > 0 { doc.undo.endUndoGrouping() }
        doc.undo.removeAllActions(); cv.marquee = nil; cv.selected = nil; cv.tool = .select; cv.zoom = zoom
        c.opt.color = color(1, 0, 0); c.opt.fill = color(0, 0, 1); c.opt.useFill = false; c.opt.width = 3; c.opt.fontSize = 18; c.opt.block = 10
        win.layoutIfNeeded()
    }
    func press(_ t: String) { step { button(t)?.click() } }
    func cur() -> Px { px(doc.state.image) }
    func flat() -> Px { px(Painter.flatten(doc.state)) }
    func sameObjs(_ a: [Obj], _ b: [Obj]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.rect == $1.rect && $0.points == $1.points && $0.text == $1.text && $0.kind == $1.kind && $0.number == $1.number && $0.width == $1.width }
    }
    func button(_ title: String) -> RibbonButton? { allViews(root).compactMap { $0 as? RibbonButton }.first { $0.title == title } }
    var answers: [String: [String]?] = [:]
    askOverride = { t, _ in answers[t] ?? nil }
    defer { askOverride = nil }

    /// Runs `op`, then checks base+objects undo/redo restore exactly.
    func undoable(_ name: String, expectChange: Bool = true, _ op: () -> Void) {
        let b0 = doc.state; let p0 = px(b0.image)
        step(op)
        let a0 = doc.state; let p1 = px(a0.image)
        let did = p0.d != p1.d || p0.w != p1.w || p0.h != p1.h || !sameObjs(b0.objects, a0.objects)
        chk("\(name)/changes-state", did == expectChange, "changed=\(did)")
        guard did else { return }
        doc.undo.undo()
        let u = px(doc.state.image)
        chk("\(name)/undo-exact", u.d == p0.d && u.w == p0.w && sameObjs(doc.state.objects, b0.objects), "pix \(u.d == p0.d) size \(u.w)x\(u.h) vs \(p0.w)x\(p0.h) objs \(doc.state.objects.count) vs \(b0.objects.count)")
        doc.undo.redo()
        let r = px(doc.state.image)
        chk("\(name)/redo-exact", r.d == p1.d && r.w == p1.w && sameObjs(doc.state.objects, a0.objects))
    }

    // ============================================================ 1. ribbon: hover / tooltips / clipping
    let seg = allViews(root).compactMap { $0 as? NSSegmentedControl }.first!
    func selectTab(_ i: Int) { seg.selectedSegment = i; _ = seg.sendAction(seg.action, to: seg.target); win.layoutIfNeeded(); win.displayIfNeeded() }
    func visibleButtons() -> [RibbonButton] { allViews(root).compactMap { $0 as? RibbonButton }.filter { !$0.isHiddenOrHasHiddenAncestor } }
    let off = NSPoint(x: 0, y: 0)
    func canvasPoint() -> NSPoint { c.scroll.convert(NSPoint(x: c.scroll.bounds.midX, y: c.scroll.bounds.midY), to: nil) }
    _ = off

    var seenTitles = Set<String>()
    let tabs = ["Home", "Image", "View"]
    for width in [1180.0, 1320.0] {
        win.setFrame(NSRect(x: 100, y: 100, width: width, height: 820), display: true); win.layoutIfNeeded()
        for (ti, tn) in tabs.enumerated() {
            selectTab(ti)
            let bs = visibleButtons()
            guard let rs = bs.first?.enclosingScrollView, let host = rs.documentView else { chk("ribbon/\(tn)@\(Int(width))/buttons", false, "none"); continue }
            let need = host.frame.width, have = rs.contentView.bounds.width
            let fits = need <= have + 0.5
            let scrolls = rs.hasHorizontalScroller && need > have
            chk("ribbon/\(tn)@\(Int(width))/fits-or-scrolls", fits || scrolls, "need \(need) have \(have)")
            print("INFO ribbon \(tn)@\(Int(width)): content \(Int(need))pt in \(Int(have))pt -> \(fits ? "fits" : "scrolls")")
            if fits { chk("ribbon/\(tn)@\(Int(width))/no-scroll-offset", rs.contentView.bounds.origin.x == 0) }
            for b in bs {
                let r = b.convert(b.bounds, to: host)
                chk("ribbon/\(tn)@\(Int(width))/\(b.title)/inside-content", host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(r) vs \(host.bounds)")
                if width == 1320 { chk("ribbon/\(tn)/\(b.title)/label-not-truncated", b.titleFits, "label wider than button") }
            }
            // group captions fully visible
            let caps = Set(["File", "Edit", "Arrange", "Select", "Annotate", "Draw", "Retouch", "Style", "Options", "Canvas", "Transform", "Effects", "Adjust", "Decorate", "Zoom"])
            let labels = allViews(host).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor && caps.contains($0.stringValue) && $0.font?.pointSize == 10 && !(allAncestors($0).contains { $0 is RibbonButton }) }
            chk("ribbon/\(tn)@\(Int(width))/captions-found", !labels.isEmpty)
            for l in labels {
                let r = l.convert(l.bounds, to: host)
                chk("ribbon/\(tn)@\(Int(width))/caption '\(l.stringValue)' visible", host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) && l.intrinsicContentSize.width <= l.frame.width + 0.5, "\(r)")
            }
            // when scrolling is needed, last button must be reachable
            if !fits, let last = bs.last { last.scrollToVisible(last.bounds); chk("ribbon/\(tn)@\(Int(width))/last-button-reachable", last.visibleRect.width >= last.bounds.width - 0.5) }
            rs.contentView.scroll(to: .zero); rs.reflectScrolledClipView(rs.contentView)
        }
    }

    // hover every button on every tab at the minimum window width
    win.setFrame(NSRect(x: 100, y: 100, width: 1180, height: 820), display: true); win.layoutIfNeeded()
    var hoverCount = 0
    for (ti, tn) in tabs.enumerated() {
        selectTab(ti)
        let bs = visibleButtons()
        for (bi, b) in bs.enumerated() {
            seenTitles.insert(b.title)
            let n = "hover/\(tn)/\(b.title)"
            b.scrollToVisible(b.bounds); win.layoutIfNeeded()
            let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
            NSApp.sendEvent(ev(.mouseMoved, p, clicks: 0))
            chk("\(n)/highlights", b.isHovering)
            if hoverCount == 0 { chk("\(n)/tip-not-instant-but-delayed", !RibbonTip.shared.isVisible) }
            pump(0.25)
            chk("\(n)/tip-visible", RibbonTip.shared.isVisible)
            chk("\(n)/tip-title", RibbonTip.shared.shownTitle == b.title, "got '\(RibbonTip.shared.shownTitle)'")
            chk("\(n)/tip-text-nonempty", !RibbonTip.shared.shownText.isEmpty && RibbonTip.shared.shownText == b.help)
            chk("\(n)/status-shows-title", c.status.stringValue == b.title, "status '\(c.status.stringValue)'")
            chk("\(n)/has-icon", b.hasIcon)
            chk("\(n)/help-nonempty", !(EditorWindowController.help[b.title] ?? "").isEmpty)
            NSApp.sendEvent(ev(.mouseMoved, canvasPoint(), clicks: 0)); pump(0.05)
            chk("\(n)/unhighlights", !b.isHovering)
            chk("\(n)/tip-hidden-after-leave", !RibbonTip.shared.isVisible)
            chk("\(n)/status-reverts", c.status.stringValue != b.title && c.status.stringValue.contains("px"), "status '\(c.status.stringValue)'")
            hoverCount += 1
            // direct switch to the next button (no gap in between)
            if bi + 1 < bs.count {
                let nb = bs[bi + 1]
                b.scrollToVisible(b.bounds); win.layoutIfNeeded()
                NSApp.sendEvent(ev(.mouseMoved, b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil), clicks: 0)); pump(0.12)
                nb.scrollToVisible(nb.bounds); win.layoutIfNeeded()
                NSApp.sendEvent(ev(.mouseMoved, nb.convert(NSPoint(x: nb.bounds.midX, y: nb.bounds.midY), to: nil), clicks: 0)); pump(0.2)
                chk("\(n)/direct-switch-to-next", !b.isHovering && nb.isHovering && RibbonTip.shared.isVisible && RibbonTip.shared.shownTitle == nb.title && c.status.stringValue == nb.title)
                NSApp.sendEvent(ev(.mouseMoved, canvasPoint(), clicks: 0)); pump(0.05)
            }
        }
    }
    selectTab(0)
    let helpKeys = Set(EditorWindowController.help.keys)
    chk("help/no-missing", seenTitles.isSubset(of: helpKeys), "missing: \(seenTitles.subtracting(helpKeys).sorted())")
    chk("help/no-orphans", helpKeys.isSubset(of: seenTitles), "orphan help: \(helpKeys.subtracting(seenTitles).sorted())")
    chk("help/all-tools-have-buttons", Set(Tool.allCases.map { $0.label }).isSubset(of: seenTitles), "\(Set(Tool.allCases.map { $0.label }).subtracting(seenTitles))")
    chk("help/count", seenTitles.count >= 55, "\(seenTitles.count) titles")
    win.setFrame(NSRect(x: 100, y: 100, width: 1320, height: 820), display: true); win.layoutIfNeeded()
    RibbonTip.shared.hide()

    // tool buttons switch the tool and show the toggle state
    for t in Tool.allCases {
        guard let b = c.toolButtons[t] else { chk("toolbutton/\(t.label)", false, "missing"); continue }
        b.click()
        chk("toolbutton/\(t.label)/selects-tool", cv.tool == t && b.isOn && c.toolButtons.values.filter { $0.isOn }.count == 1)
    }
    cv.tool = .select

    // ============================================================ 2. selection-limited effects
    let M = CGRect(x: 60, y: 40, width: 120, height: 90)
    struct FX { let name: String; let button: String; let dialog: String?; let answer: [String] }
    let fxs = [FX(name: "blur", button: "Blur", dialog: "Blur", answer: ["4"]),
               FX(name: "sharpen", button: "Sharpen", dialog: "Sharpen", answer: ["1.5"]),
               FX(name: "mosaic", button: "Mosaic", dialog: "Mosaic", answer: ["8"]),
               FX(name: "grayscale", button: "Grayscale", dialog: nil, answer: []),
               FX(name: "invert", button: "Invert", dialog: nil, answer: []),
               FX(name: "brightness/contrast", button: "Brightness", dialog: "Brightness / Contrast", answer: ["0.3", "1.4"]),
               FX(name: "hue/sat", button: "Hue / Sat", dialog: "Hue / Saturation", answer: ["90", "1.5"]),
               FX(name: "color-balance", button: "Balance", dialog: "Color Balance", answer: ["-0.5", "0.3", "0.6"])]
    for fx in fxs {
        if let d = fx.dialog { answers[d] = fx.answer }
        guard let btn = button(fx.button) else { chk("fx/\(fx.name)/button", false); continue }
        // (a) with marquee
        reset(detailImage(300, 200)); cv.marquee = M
        let before = cur()
        undoable("fx/\(fx.name)/marquee") { btn.click() }
        step { btn.click() }
        let after = cur()
        chk("fx/\(fx.name)/outside-identical", changed(before, after) { !inRect($0, $1, M) }.0 == 0, "changed outside: \(changed(before, after) { !inRect($0, $1, M) }.0)")
        let (n, t) = changed(before, after) { inRect($0, $1, M) }
        chk("fx/\(fx.name)/inside-changed", n > t / 10, "\(n)/\(t)")
        chk("fx/\(fx.name)/size-kept", after.w == 300 && after.h == 200)
        // fractional marquee: nothing outside the enclosing integral rect may change
        reset(detailImage(300, 200)); let fr = CGRect(x: 60.4, y: 40.6, width: 120.3, height: 90.2); cv.marquee = fr
        let fb = cur(); step { btn.click() }; let fa = cur()
        chk("fx/\(fx.name)/fractional-marquee-outside-identical", changed(fb, fa) { !inRect($0, $1, fr.integral) }.0 == 0)
        // (b) no colour bleed from outside the marquee
        reset(bleedImage(300, 200, M)); cv.marquee = M
        let bb = cur(); step { btn.click() }; let ba = cur()
        let centre = ba.at(Int(M.midX), Int(M.midY))
        var bleed = 0
        for y in Int(M.minY)..<Int(M.maxY) { for x in Int(M.minX)..<Int(M.maxX) where x < Int(M.minX) + 3 || x >= Int(M.maxX) - 3 || y < Int(M.minY) + 3 || y >= Int(M.maxY) - 3 {
            if maxDiff(ba.at(x, y), centre) > 2 { bleed += 1 } } }
        chk("fx/\(fx.name)/no-edge-bleed", bleed == 0, "\(bleed) edge pixels differ from interior")
        chk("fx/\(fx.name)/bleed-outside-identical", changed(bb, ba) { !inRect($0, $1, M) }.0 == 0)
        // (c) no marquee: whole image
        reset(detailImage(300, 200))
        let nb = cur(); step { btn.click() }; let na = cur()
        let (no, nt) = changed(nb, na) { !inRect($0, $1, M) }
        chk("fx/\(fx.name)/no-marquee-whole-image", no > nt / 10, "\(no)/\(nt)")
        // (d) zoomed canvas does not matter for effects; ⌘A selects all
        reset(detailImage(300, 200), zoom: 0.5)
        let rb = root.performKeyEquivalent(with: key(0, "a", .command))
        chk("fx/\(fx.name)/cmdA-selects-all", rb && cv.marquee == CGRect(x: 0, y: 0, width: 300, height: 200))
        let ab = cur(); step { btn.click() }; let aa = cur()
        chk("fx/\(fx.name)/cmdA-changes-whole", changed(ab, aa) { _, _ in true }.0 > 300 * 200 / 10)
    }
    // weird dialog input must never crash or corrupt the image
    for (title, btnName, ans) in [("Blur", "Blur", ["-5"]), ("Blur", "Blur", ["abc"]), ("Blur", "Blur", ["100000"]), ("Mosaic", "Mosaic", ["0"]), ("Mosaic", "Mosaic", ["-3"]),
                                  ("Sharpen", "Sharpen", ["99"]), ("Brightness / Contrast", "Brightness", ["9", "-9"]), ("Hue / Saturation", "Hue / Sat", ["1e9", "-50"])] {
        answers[title] = ans; reset(detailImage(100, 80)); cv.marquee = CGRect(x: 10, y: 10, width: 40, height: 30)
        step { button(btnName)?.click() }
        chk("fx/weird-input/\(btnName)(\(ans.joined(separator: ",")))/survives", doc.state.image.size == CGSize(width: 100, height: 80))
    }
    answers["Blur"] = ["4"]; answers["Mosaic"] = ["8"]

    // marquee tool mechanics
    reset(detailImage(300, 200)); cv.tool = .marquee
    drag([(30, 20), (80, 60), (130, 100)])
    chk("marquee/drag-creates", cv.marquee == CGRect(x: 30, y: 20, width: 100, height: 80), "\(String(describing: cv.marquee))")
    chk("marquee/status-shows-selection", c.status.stringValue.contains("Selection 100 x 80"), c.status.stringValue)
    drag([(200, 150), (100, 100)])
    chk("marquee/reverse-drag-normalised", cv.marquee == CGRect(x: 100, y: 100, width: 100, height: 50))
    drag([(-40, -30), (50, 50)])
    chk("marquee/clamped-to-image", cv.marquee == CGRect(x: 0, y: 0, width: 50, height: 50), "\(String(describing: cv.marquee))")
    click(150, 100)
    chk("marquee/tiny-click-clears", cv.marquee == nil)
    cv.marquee = M; drag([(150, 100), (151, 101)])
    chk("marquee/tiny-drag-clears", cv.marquee == nil)
    cv.marquee = M; cv.keyDown(with: key(53, "\u{1b}"))
    chk("marquee/esc-clears", cv.marquee == nil)
    cv.marquee = M; _ = root.performKeyEquivalent(with: key(2, "d", .command))
    chk("marquee/cmdD-clears", cv.marquee == nil)
    reset(detailImage(300, 200), zoom: 0.5); cv.tool = .marquee
    drag([(30, 20), (130, 100)])
    chk("marquee/zoom-0.5-maps-to-image-pixels", cv.marquee.map { abs($0.minX - 30) < 1 && abs($0.minY - 20) < 1 && abs($0.width - 100) < 1 && abs($0.height - 80) < 1 } ?? false, "\(String(describing: cv.marquee))")
    reset(detailImage(300, 200)); cv.marquee = M
    undoable("marquee/rotate-clears-marquee-state", expectChange: true) { press("Rotate Right") }
    chk("marquee/cleared-after-geometry-op", cv.marquee == nil, "stale marquee \(String(describing: cv.marquee))")

    // Blur Region / Mosaic Region
    for (tool, nm) in [(Tool.blur, "blur-region"), (Tool.mosaic, "mosaic-region")] {
        let R = CGRect(x: 50, y: 35, width: 103, height: 77)
        reset(detailImage(300, 200)); cv.tool = tool
        let b0 = cur()
        undoable("region/\(nm)") { drag([(50, 35), (100, 80), (153, 112)]) }
        chk("region/\(nm)/object-added", doc.state.objects.count == 1 && doc.state.objects[0].kind == tool && doc.state.objects[0].rect == R, "\(doc.state.objects.map { $0.rect })")
        let f = flat()
        chk("region/\(nm)/base-untouched", cur().d == b0.d)
        chk("region/\(nm)/outside-identical", changed(b0, f) { !inRect($0, $1, R.integral) }.0 == 0, "\(changed(b0, f) { !inRect($0, $1, R.integral) }.0) outside px changed")
        let (n, t) = changed(b0, f) { inRect($0, $1, R) }
        chk("region/\(nm)/inside-changed", n > t / 5, "\(n)/\(t)")
        if tool == .mosaic {
            var nonUniform = 0
            for by in stride(from: 35, to: 35 + 70, by: 10) { for bx in stride(from: 50, to: 50 + 100, by: 10) {
                let ref = f.at(bx + 5, by + 5)
                for y in by..<by + 10 { for x in bx..<bx + 10 where maxDiff(f.at(x, y), ref) > 1 { nonUniform += 1 } } } }
            chk("region/mosaic/blocks-uniform", nonUniform == 0, "\(nonUniform) pixels not uniform within their 10x10 block")
        }
        // bleed test at the edge
        let rr = CGRect(x: 50, y: 35, width: 103, height: 77)
        reset(bleedImage(300, 200, rr)); cv.tool = tool; step { doc.commit("x") { var o = Obj(kind: tool); o.rect = rr; o.number = 10; $0.objects.append(o) } }
        let ff = flat(); let ce = ff.at(100, 70); var bl = 0
        for y in 35..<112 { for x in 50..<153 where maxDiff(ff.at(x, y), ce) > 2 { bl += 1 } }
        chk("region/\(nm)/no-edge-bleed", bl == 0, "\(bl) px differ")
        // zoomed drag + start outside the image
        reset(detailImage(300, 200), zoom: 0.5); cv.tool = tool
        drag([(-30, -30), (60, 50)])
        chk("region/\(nm)/drag-from-outside-image", doc.state.objects.count == 1)
        let fz = flat(); let b00 = px(doc.state.image)
        chk("region/\(nm)/outside-identical-zoomed", changed(b00, fz) { !inRect($0, $1, CGRect(x: 0, y: 0, width: 60, height: 50)) }.0 == 0)
        reset(detailImage(300, 200)); cv.tool = tool; click(100, 100)
        chk("region/\(nm)/tiny-click-adds-nothing", doc.state.objects.isEmpty)
    }
    // Retouch / Fill / Eraser operate on the base image
    // ============================================================ 3. every other tool / op
    let W = 300, H = 200
    func box(_ r: CGRect, pad: CGFloat) -> CGRect { r.insetBy(dx: -pad, dy: -pad) }

    // --- shapes
    for (tool, nm) in [(Tool.rect, "rect"), (.ellipse, "ellipse"), (.rounded, "rounded")] {
        for fill in [false, true] {
            reset(solid(W, H)); cv.tool = tool; c.opt.useFill = fill
            let R = CGRect(x: 50, y: 40, width: 100, height: 80)
            undoable("tool/\(nm)\(fill ? "+fill" : "")") { drag([(50, 40), (100, 90), (150, 120)]) }
            guard let o = doc.state.objects.first else { chk("tool/\(nm)/object", false); continue }
            chk("tool/\(nm)\(fill ? "+fill" : "")/geometry", o.kind == tool && o.rect == R && (o.fill != nil) == fill)
            let f = flat(), b = px(solid(W, H))
            chk("tool/\(nm)\(fill ? "+fill" : "")/confined", changed(b, f) { !inRect($0, $1, box(R, pad: 3)) }.0 == 0)
            let centre = f.at(100, 80)
            chk("tool/\(nm)\(fill ? "+fill" : "")/centre", fill ? maxDiff(centre, [0, 0, 255, 255]) < 3 : centre == [255, 255, 255, 255], "\(centre)")
            let corner = f.at(51, 41)
            if tool == .rect { chk("tool/rect/corner-painted", corner != [255, 255, 255, 255]) }
            else { chk("tool/\(nm)\(fill ? "+fill" : "")/corner-cut", corner == [255, 255, 255, 255], "\(corner)") }
            chk("tool/\(nm)/edge-stroke-red", maxDiff(f.at(Int(R.minX), 80), [255, 0, 0, 255]) < 40 || tool == .ellipse)
            // reverse drag normalises
            reset(solid(W, H)); cv.tool = tool; drag([(150, 120), (50, 40)])
            chk("tool/\(nm)/reverse-drag-normalised", doc.state.objects.first?.rect == R)
            reset(solid(W, H)); cv.tool = tool; drag([(50, 40), (51, 41)])
            chk("tool/\(nm)/tiny-drag-ignored", doc.state.objects.isEmpty)
        }
    }
    // --- line vs arrow
    reset(solid(W, H)); cv.tool = .line; undoable("tool/line") { drag([(30, 150), (120, 150), (200, 150)]) }
    let lineFlat = flat()
    chk("tool/line/points", doc.state.objects.first.map { $0.kind == .line && $0.points == [CGPoint(x: 30, y: 150), CGPoint(x: 200, y: 150)] } ?? false)
    chk("tool/line/painted", lineFlat.at(100, 150) != [255, 255, 255, 255] && lineFlat.at(191, 147) == [255, 255, 255, 255])
    reset(solid(W, H)); cv.tool = .arrow; undoable("tool/arrow") { drag([(30, 150), (200, 150)]) }
    let arrowFlat = flat()
    chk("tool/arrow/head-painted", arrowFlat.at(100, 150) != [255, 255, 255, 255] && arrowFlat.at(191, 147) != [255, 255, 255, 255])
    reset(solid(W, H)); cv.tool = .arrow; drag([(30, 150), (31, 150)])
    chk("tool/arrow/tiny-ignored", doc.state.objects.isEmpty)
    // --- text
    reset(solid(W, H)); cv.tool = .text
    answers["Text"] = ["Hello"]
    undoable("tool/text") { click(40, 40) }
    if let o = doc.state.objects.first {
        chk("tool/text/object", o.kind == .text && o.text == "Hello" && o.rect.origin == CGPoint(x: 40, y: 40) && o.rect.size == Painter.textSize(o))
        let f = flat(); let b = px(solid(W, H))
        chk("tool/text/painted-inside-rect", changed(b, f) { inRect($0, $1, o.rect) }.0 > 20 && changed(b, f) { !inRect($0, $1, o.rect.insetBy(dx: -2, dy: -2)) }.0 == 0)
    } else { chk("tool/text/object", false) }
    reset(solid(W, H)); cv.tool = .text; answers["Text"] = nil; click(40, 40)
    chk("tool/text/cancel-adds-nothing", doc.state.objects.isEmpty)
    reset(solid(W, H)); cv.tool = .text; answers["Text"] = [""]; click(40, 40)
    chk("tool/text/empty-adds-nothing", doc.state.objects.isEmpty)
    // text edit by double click
    reset(solid(W, H)); cv.tool = .text; answers["Text"] = ["Hello"]; click(40, 40)
    cv.tool = .select; answers["Text"] = ["Changed text longer"]
    if let o = doc.state.objects.first {
        undoable("tool/text-edit-double-click") { click(o.rect.midX, o.rect.midY, clicks: 2) }
        chk("tool/text-edit/updated", doc.state.objects.first?.text == "Changed text longer")
    }
    // --- callout
    reset(solid(W, H)); cv.tool = .callout; answers["Text"] = ["Hi"]
    undoable("tool/callout") { drag([(60, 40), (200, 100)]) }
    if let o = doc.state.objects.first {
        chk("tool/callout/object", o.kind == .callout && o.text == "Hi" && o.rect == CGRect(x: 60, y: 40, width: 140, height: 60) && o.bounds.height == 84)
        let f = flat(), b = px(solid(W, H))
        chk("tool/callout/tail-painted", changed(b, f) { inRect($0, $1, CGRect(x: 60, y: 101, width: 40, height: 20)) }.0 > 5)
    }
    reset(solid(W, H)); cv.tool = .callout; answers["Text"] = nil; drag([(60, 40), (200, 100)])
    chk("tool/callout/cancel-adds-nothing", doc.state.objects.isEmpty)
    // --- numbered stamp auto-increment
    reset(solid(W, H)); cv.tool = .number
    for (i, x) in [60.0, 120, 180].enumerated() { click(CGFloat(x), 100); chk("tool/number/auto-increment-\(i + 1)", doc.state.objects.last?.number == i + 1) }
    chk("tool/number/centre-colour", flat().at(60 - 12, 100) == [255, 0, 0, 255], "\(flat().at(48, 100))")
    doc.undo.undo(); chk("tool/number/undo-removes-last", doc.state.objects.count == 2, "count \(doc.state.objects.count) lvl \(doc.undo.groupingLevel)")
    doc.undo.redo()
    cv.tool = .select; click(120, 100); chk("tool/number/select-middle", cv.selected == doc.state.objects[1].id)
    step { cv.deleteSelected() }; cv.tool = .number; click(120, 100)
    chk("tool/number/continues-after-delete", doc.state.objects.last?.number == 4, "\(doc.state.objects.map { $0.number })")
    // --- cursor stamp / symbol
    reset(solid(W, H)); cv.tool = .cursor
    undoable("tool/cursor-stamp") { click(100, 100) }
    chk("tool/cursor-stamp/object+painted", doc.state.objects.first?.rect == CGRect(x: 100, y: 100, width: 24, height: 32) && changed(px(solid(W, H)), flat()) { inRect($0, $1, CGRect(x: 100, y: 100, width: 24, height: 32)) }.0 > 10)
    for sym in ["star.fill", "heart.fill"] {
        reset(solid(W, H)); cv.tool = .symbol; c.opt.symbol = sym
        undoable("tool/symbol-\(sym)") { click(150, 100) }
        chk("tool/symbol-\(sym)/object+painted", doc.state.objects.first.map { $0.symbol == sym && $0.rect == CGRect(x: 126, y: 76, width: 48, height: 48) } ?? false && changed(px(solid(W, H)), flat()) { inRect($0, $1, CGRect(x: 126, y: 76, width: 48, height: 48)) }.0 > 50)
    }
    // --- freehand-ish strokes
    for t in [Tool.pencil, .brush, .marker, .airbrush, .calligraphy, .highlighter] {
        reset(solid(W, H)); cv.tool = t
        let path: [(CGFloat, CGFloat)] = [(40, 160), (70, 168), (100, 170), (130, 166), (160, 160), (190, 168), (220, 170)]
        undoable("tool/\(t.label)") { drag(path) }
        guard let o = doc.state.objects.first else { chk("tool/\(t.label)/object", false); continue }
        chk("tool/\(t.label)/points", o.kind == t && o.points.count == path.count, "\(o.points.count)")
        let f = flat(), b = px(solid(W, H))
        let (n, _) = changed(b, f) { inRect($0, $1, CGRect(x: 40, y: 150, width: 190, height: 40)) }
        chk("tool/\(t.label)/painted-along-path", n > 15, "\(n) px")
        chk("tool/\(t.label)/nothing-far-away", changed(b, f) { $1 < 100 }.0 == 0)
        reset(solid(W, H)); cv.tool = t; click(100, 100)
        chk("tool/\(t.label)/single-click-dot-object", doc.state.objects.count == 1)
    }
    // --- eraser / retouch (modify base image)
    reset(detailImage(W, H)); cv.tool = .eraser
    var b0 = cur()
    undoable("tool/eraser") { drag([(20, 50), (60, 50), (100, 50)]) }
    var a0 = cur()
    chk("tool/eraser/erases-to-white", a0.at(60, 50) == [255, 255, 255, 255] && a0.at(60, 90) == b0.at(60, 90) && doc.state.objects.isEmpty)
    chk("tool/eraser/confined", changed(b0, a0) { !inRect($0, $1, CGRect(x: 10, y: 40, width: 100, height: 20)) }.0 == 0)
    reset(detailImage(W, H)); cv.tool = .retouch; b0 = cur()
    undoable("tool/retouch") { drag([(20, 50), (60, 50), (100, 50)]) }
    a0 = cur()
    chk("tool/retouch/softens-along-stroke", changed(b0, a0) { inRect($0, $1, CGRect(x: 20, y: 46, width: 80, height: 8)) }.0 > 100 && changed(b0, a0) { !inRect($0, $1, CGRect(x: 10, y: 40, width: 100, height: 20)) }.0 == 0)
    // --- fill bucket
    reset(halves(W, H)); cv.tool = .fill; c.opt.color = color(0.2, 0.4, 0.6)
    b0 = cur()
    undoable("tool/fill") { click(20, 20) }
    a0 = cur()
    chk("tool/fill/left-half-filled-exact-colour", a0.at(5, 5) == [51, 102, 153, 255] && a0.at(149, 199) == [51, 102, 153, 255], "\(a0.at(5, 5)) expected [51,102,153,255]")
    chk("tool/fill/right-half-untouched", changed(b0, a0) { x, _ in x >= W / 2 }.0 == 0)
    reset(halves(W, H)); cv.tool = .fill; c.opt.color = color(0.2, 0.4, 0.6); click(-0.6, 20)
    chk("tool/fill/click-outside-image-ignored", cur().d == px(halves(W, H)).d)
    // --- crop
    reset(detailImage(W, H)); cv.tool = .rect; drag([(10, 10), (60, 40)])   // an annotation that must be flattened into the crop
    let preFlat = flat()
    cv.tool = .crop
    undoable("tool/crop") { drag([(20, 20), (100, 60), (120, 90)]) }
    chk("tool/crop/size", doc.state.image.size == CGSize(width: 100, height: 70), "\(doc.state.image.size)")
    chk("tool/crop/objects-flattened", doc.state.objects.isEmpty)
    let cr = cur(); var cropOK = cr.w == 100 && cr.h == 70
    if cropOK { for y in 0..<70 { for x in 0..<100 where maxDiff(cr.at(x, y), preFlat.at(x + 20, y + 20)) > 0 { cropOK = false } } }
    chk("tool/crop/content-exact", cropOK)
    reset(detailImage(W, H)); cv.tool = .crop; drag([(20, 20), (21, 21)]); chk("tool/crop/tiny-ignored", doc.state.image.size == CGSize(width: W, height: H))
    // --- freehand crop
    reset(detailImage(W, H)); cv.tool = .freehand
    let tri: [(CGFloat, CGFloat)] = [(50, 30), (100, 50), (150, 80), (100, 130), (50, 130), (50, 60), (50, 30)]
    let orig = cur()
    undoable("tool/freehand-crop") { drag(tri) }
    let fc = cur()
    chk("tool/freehand-crop/bbox-size", fc.w == 100 && fc.h == 100, "\(fc.w)x\(fc.h)")
    if fc.w == 100 && fc.h == 100 {
        chk("tool/freehand-crop/inside-kept", maxDiff(fc.at(40, 70), orig.at(90, 100)) == 0)
        chk("tool/freehand-crop/outside-cut-transparent", fc.at(95, 2)[3] == 0, "\(fc.at(95, 2))")
        // exporting a cut-out as JPEG must not turn the cut area black
        if let jd = ImageOutput.data(doc.state.image, format: .jpeg), let rep = NSBitmapImageRep(data: jd), let col = rep.colorAt(x: 95, y: 2) {
            chk("tool/freehand-crop/jpeg-cutout-not-black", col.brightnessComponent > 0.9, "brightness \(col.brightnessComponent)")
        } else { chk("tool/freehand-crop/jpeg-decodes", false) }
    }
    // --- resize / canvas size
    reset(halves(W, H))
    answers["Resize Image (pixels)"] = ["150", "100"]
    undoable("op/resize") { press("Resize") }
    chk("op/resize/size+content", doc.state.image.size == CGSize(width: 150, height: 100) && cur().at(10, 50) == [255, 0, 0, 255] && cur().at(140, 50) == [0, 0, 255, 255])
    reset(halves(W, H))
    for bad in [["0", "10"], ["abc", "10"], ["-5", "10"], ["10", ""], ["100000", "100000"], ["1e9", "1e9"]] {
        answers["Resize Image (pixels)"] = bad; press("Resize")
        chk("op/resize/rejects-\(bad)", doc.state.image.size == CGSize(width: W, height: H), "\(doc.state.image.size)")
    }
    c.opt.fill = color(0, 1, 0)
    answers["Resize Canvas (pixels)"] = ["400", "300"]
    reset(halves(W, H)); c.opt.fill = color(0, 1, 0)
    undoable("op/canvas-size-grow") { press("Canvas Size") }
    chk("op/canvas-size-grow/content", doc.state.image.size == CGSize(width: 400, height: 300) && cur().at(10, 10) == [255, 0, 0, 255] && cur().at(390, 290) == [0, 255, 0, 255], "\(cur().at(390, 290))")
    answers["Resize Canvas (pixels)"] = ["100", "80"]; reset(halves(W, H))
    undoable("op/canvas-size-shrink") { press("Canvas Size") }
    chk("op/canvas-size-shrink/size", doc.state.image.size == CGSize(width: 100, height: 80))
    answers["Resize Canvas (pixels)"] = ["100000", "100000"]; reset(halves(W, H)); press("Canvas Size")
    chk("op/canvas-size/rejects-huge", doc.state.image.size == CGSize(width: W, height: H))
    // --- rotate / flip (exact pixel mapping)
    let src = detailImage(61, 37); reset(src); let s0 = cur()
    undoable("op/rotate-right") { press("Rotate Right") }
    var r = cur(); var ok = r.w == 37 && r.h == 61
    if ok { for y in 0..<37 { for x in 0..<61 where maxDiff(s0.at(x, y), r.at(37 - 1 - y, x)) > 1 { ok = false } } }
    chk("op/rotate-right/pixel-mapping", ok)
    reset(src)
    undoable("op/rotate-left") { press("Rotate Left") }
    r = cur(); ok = r.w == 37 && r.h == 61
    if ok { for y in 0..<37 { for x in 0..<61 where maxDiff(s0.at(x, y), r.at(y, 61 - 1 - x)) > 1 { ok = false } } }
    chk("op/rotate-left/pixel-mapping", ok)
    reset(src); press("Rotate Right"); press("Rotate Left")
    chk("op/rotate-right-then-left-is-identity", changed(s0, cur(), tol: 1) { _, _ in true }.0 == 0)
    reset(src)
    undoable("op/flip-horizontal") { press("Flip Horizontal") }
    r = cur(); ok = r.w == 61
    if ok { for y in 0..<37 { for x in 0..<61 where maxDiff(s0.at(x, y), r.at(61 - 1 - x, y)) > 1 { ok = false } } }
    chk("op/flip-horizontal/pixel-mapping", ok)
    reset(src)
    undoable("op/flip-vertical") { press("Flip Vertical") }
    r = cur(); ok = r.h == 37
    if ok { for y in 0..<37 { for x in 0..<61 where maxDiff(s0.at(x, y), r.at(x, 37 - 1 - y)) > 1 { ok = false } } }
    chk("op/flip-vertical/pixel-mapping", ok)
    // objects are flattened by geometry ops
    reset(solid(W, H)); cv.tool = .rect; drag([(10, 10), (60, 40)]); cv.tool = .select
    step { press("Rotate Right") }
    chk("op/rotate/flattens-objects", doc.state.objects.isEmpty && cur().d != px(solid(H, W)).d)
    // --- frame / shadow / watermark
    reset(detailImage(W, H)); c.opt.color = color(0, 0.5, 0); let s1 = cur()
    answers["Frame / Border (uses Line color)"] = ["10"]
    undoable("op/frame") { press("Frame") }
    r = cur()
    chk("op/frame/size+border+interior", r.w == W + 20 && r.h == H + 20 && maxDiff(r.at(0, 0), [0, 128, 0, 255]) <= 1 && r.at(10, 10) == s1.at(0, 0) && r.at(W + 9, H + 9) == s1.at(W - 1, H - 1), "\(r.w)x\(r.h) \(r.at(0, 0))")
    for bad in [["-10"], ["abc"], ["99999"]] {
        answers["Frame / Border (uses Line color)"] = bad; reset(detailImage(100, 80)); press("Frame")
        chk("op/frame/weird-\(bad)/survives", doc.state.image.size.width >= 1)
    }
    reset(detailImage(W, H)); answers["Drop Shadow"] = ["10"]
    undoable("op/shadow") { press("Shadow") }
    r = cur(); let pad = 26
    chk("op/shadow/size", r.w == W + 2 * pad && r.h == H + 2 * pad, "\(r.w)x\(r.h)")
    if r.w == W + 2 * pad {
        chk("op/shadow/interior-exact", r.at(pad - 3 + 50, pad - 3 + 50) == s1.at(50, 50))
        chk("op/shadow/corner-white", r.at(0, 0) == [255, 255, 255, 255])
        chk("op/shadow/darkens-right-of-image", r.at(pad - 3 + W + 2, pad - 3 + 100)[0] < 250, "\(r.at(pad - 3 + W + 2, pad - 3 + 100))")
    }
    for bad in [["-10"], ["abc"], ["99999"]] {
        answers["Drop Shadow"] = bad; reset(detailImage(100, 80)); press("Shadow")
        chk("op/shadow/weird-\(bad)/survives", doc.state.image.size.width >= 1)
    }
    reset(solid(W, H, color(0.2, 0.2, 0.2))); answers["Watermark"] = ["(c) SnapDesk"]
    let w0 = cur()
    undoable("op/watermark") { press("Watermark") }
    let w1 = cur()
    chk("op/watermark/bottom-right-only", changed(w0, w1) { $0 > W / 2 && $1 > H * 3 / 4 }.0 > 20 && changed(w0, w1) { !($0 > W / 2 && $1 > H * 3 / 4) }.0 == 0)
    answers["Watermark"] = [""]; reset(solid(W, H)); press("Watermark"); chk("op/watermark/empty-ignored", cur().d == px(solid(W, H)).d)
    // --- arrange order
    reset(solid(W, H)); cv.tool = .rect
    for i in 0..<4 { drag([(CGFloat(10 + i * 40), 20), (CGFloat(40 + i * 40), 60)]) }
    let ids = doc.state.objects.map { $0.id }
    func order() -> [Int] { doc.state.objects.map { ids.firstIndex(of: $0.id)! } }
    func select(_ i: Int) { cv.tool = .select; click(CGFloat(25 + i * 40), 40); cv.selected = ids[i] }
    select(1); undoable("arrange/bring-to-front") { press("Bring to Front") }; chk("arrange/front-order", order() == [0, 2, 3, 1], "\(order())")
    select(3); undoable("arrange/send-to-back") { press("Send to Back") }; chk("arrange/back-order", order() == [3, 0, 2, 1], "\(order())")
    select(0); step { press("Forward") }; chk("arrange/forward-order", order() == [3, 2, 0, 1], "\(order())")
    select(1); step { press("Backward") }; chk("arrange/backward-order", order() == [3, 2, 1, 0], "\(order())")
    select(3); step { press("Send to Back") }; select(3); step { press("Backward") }; chk("arrange/backward-at-bottom-noop", order() == [3, 2, 1, 0], "\(order())")
    select(0); step { press("Bring to Front") }; select(0); step { press("Forward") }; chk("arrange/forward-at-top-noop", order() == [3, 2, 1, 0], "\(order())")
    // --- select / move / resize / delete / nudge / restyle
    reset(solid(W, H)); cv.tool = .rect; drag([(50, 40), (150, 120)]); cv.tool = .select
    let oid = doc.state.objects[0].id
    doc.undo.removeAllActions(); doc.undo.groupsByEvent = true   // raw events, no explicit group: any registration would show up
    cv.mouseDown(with: ev(.leftMouseDown, ipt(100, 80))); cv.mouseUp(with: ev(.leftMouseUp, ipt(100, 80)))
    chk("select/click-selects", cv.selected == oid)
    chk("select/plain-click-adds-no-undo-step", !doc.undo.canUndo, "undo action: \(doc.undo.undoActionName)")
    doc.undo.groupsByEvent = false
    click(250, 180); chk("select/click-empty-deselects", cv.selected == nil)
    click(100, 80)
    let ob = doc.state.objects
    undoable("select/move") { drag([(100, 80), (120, 90), (130, 100)]) }
    chk("select/move/by-delta", doc.state.objects[0].rect == CGRect(x: 80, y: 60, width: 100, height: 80), "\(doc.state.objects[0].rect)")
    doc.undo.undo(); chk("select/move/undo-exact-position", doc.state.objects[0].rect == ob[0].rect); doc.undo.redo()
    cv.selected = oid
    undoable("select/resize-handle") { drag([(180, 140), (200, 150), (210, 160)]) }   // bottom-right handle of moved rect
    chk("select/resize/rect", doc.state.objects[0].rect == CGRect(x: 80, y: 60, width: 130, height: 100), "\(doc.state.objects[0].rect)")
    cv.selected = oid
    undoable("select/nudge-arrow") { cv.keyDown(with: key(124, "\u{F703}")) }
    chk("select/nudge/right-1px", doc.state.objects[0].rect.origin.x == 81)
    undoable("select/nudge-shift-arrow") { cv.keyDown(with: key(125, "\u{F701}", .shift)) }
    chk("select/nudge/down-10px", doc.state.objects[0].rect.origin.y == 70, "\(doc.state.objects[0].rect.origin.y)")
    // restyle
    c.opt.color = color(0, 1, 0); c.opt.width = 8; c.opt.useFill = true; c.opt.fill = color(1, 1, 0)
    undoable("select/restyle") { cv.restyle() }
    chk("select/restyle/applied", doc.state.objects[0].width == 8 && doc.state.objects[0].fill != nil && doc.state.objects[0].color == color(0, 1, 0))
    // delete via button, via key, undo
    undoable("select/delete-button") { press("Delete") }
    chk("select/delete/removed", doc.state.objects.isEmpty && cv.selected == nil)
    doc.undo.undo(); cv.selected = oid
    undoable("select/delete-key") { cv.keyDown(with: key(51, "\u{7F}")) }
    // line endpoints: select by hit, drag handle
    reset(solid(W, H)); cv.tool = .line; drag([(30, 150), (200, 150)]); cv.tool = .select
    click(100, 152); chk("select/line/hit-near-line", cv.selected != nil)
    click(100, 120); chk("select/line/miss-far-from-line", cv.selected == nil)
    click(100, 150)
    undoable("select/line-endpoint-drag") { drag([(200, 150), (210, 170)]) }
    chk("select/line/endpoint-moved", doc.state.objects[0].points[1] == CGPoint(x: 210, y: 170) && doc.state.objects[0].points[0] == CGPoint(x: 30, y: 150))
    // stroke object resize/move keeps shape
    reset(solid(W, H)); cv.tool = .pencil; drag([(40, 160), (100, 170), (160, 160)]); cv.tool = .select
    let so = doc.state.objects[0].points
    click(70, 165); chk("select/stroke/hit", cv.selected != nil)
    undoable("select/stroke-move") { drag([(70, 165), (80, 175)]) }
    chk("select/stroke/moved-all-points", zip(so, doc.state.objects[0].points).allSatisfy { $1 == CGPoint(x: $0.x + 10, y: $0.y + 10) })
    // switching tool drops the selection
    cv.tool = .rect; chk("select/tool-switch-clears-selection", cv.selected == nil)

    // --- flattened export through ImageOutput
    reset(solid(W, H)); cv.tool = .rect; c.opt.useFill = true; drag([(50, 40), (150, 120)]); cv.tool = .text; answers["Text"] = ["Export"]; click(160, 150)
    let fl = c.flat(); let fp = px(fl)
    chk("export/flat-size", fl.size == CGSize(width: W, height: H) && fp.at(100, 80) == [0, 0, 255, 255])
    for f in ImageFormat.allCases {
        guard let d = ImageOutput.data(fl, format: f, quality: 0.8), d.count > 100 else { chk("export/\(f.rawValue)/data", false); continue }
        let magic: [UInt8] = {
            switch f { case .png: return [0x89, 0x50, 0x4E, 0x47]; case .jpeg: return [0xFF, 0xD8]; case .bmp: return [0x42, 0x4D]
            case .gif: return [0x47, 0x49, 0x46]; case .tiff: return [d[0], d[0]]; case .pdf: return [0x25, 0x50, 0x44, 0x46] } }()
        if f == .tiff { chk("export/tiff/magic", (d[0] == 0x49 && d[1] == 0x49) || (d[0] == 0x4D && d[1] == 0x4D)) }
        else {         chk("export/\(f.rawValue)/magic", Array(d.prefix(magic.count)) == magic) }
        if f == .pdf {
            let rep = NSPDFImageRep(data: d)
            chk("export/pdf/decodes-right-size", rep != nil && abs(rep!.bounds.width - CGFloat(W)) < 1 && abs(rep!.bounds.height - CGFloat(H)) < 1 && rep!.pageCount == 1, "\(String(describing: rep?.bounds))")
            continue
        }
        guard let rep = NSBitmapImageRep(data: d) else { chk("export/\(f.rawValue)/decodes", false); continue }
        chk("export/\(f.rawValue)/decodes-right-size", rep.pixelsWide == W && rep.pixelsHigh == H, "\(rep.pixelsWide)x\(rep.pixelsHigh)")
        if let back = rep.cgImage {
            let dec = px(NSImage(cgImage: back, size: CGSize(width: W, height: H)))
            let tol = f == .jpeg ? 12 : f == .gif ? 70 : 0
            chk("export/\(f.rawValue)/pixels-match", maxDiff(dec.at(100, 80), [0, 0, 255, 255]) <= tol && maxDiff(dec.at(5, 5), [255, 255, 255, 255]) <= tol, "\(dec.at(100, 80)) \(dec.at(5, 5))")
        }
    }
    chk("export/ext-mapping", ImageFormat.allCases.map { ImageOutput.ext($0) } == ["png", "jpg", "bmp", "gif", "tiff", "pdf"])
    chk("export/sanity-check-hook", editorKitSanityCheck())

    // Copy button puts a decodable image on the pasteboard
    NSPasteboard.general.clearContents(); press("Copy")
    chk("export/copy-button-pasteboard", NSImage(pasteboard: NSPasteboard.general)?.size == CGSize(width: W, height: H))

    // ============================================================ window lifecycle
    win.close()
    pump(0.05)
    chk("window/close-hides-tip-and-removes-monitor", !RibbonTip.shared.isVisible)
}

private func allAncestors(_ v: NSView) -> [NSView] { var r: [NSView] = []; var x = v.superview; while let s = x { r.append(s); x = s.superview }; return r }
