import AppKit
import SnapCore

private func chk(_ n: String, _ ok: Bool, _ d: @autoclosure () -> String = "") { SelfTest.check("tools/" + n, ok, d()) }

/// Pure-logic checks for ToolsKit (colour formats, pixel sampling, ruler units, palette maths, tool lifecycle).
public func toolsKitSelfTest() {
    // --- colour formats
    let o = RGB(r: 255, g: 128, b: 0)
    let f = Dictionary(uniqueKeysWithValues: o.formats.map { ($0.name, $0.value) })
    chk("color/names", o.formats.map { $0.name } == ["HEX", "RGB", "HTML", "C++", "Delphi", "Swift"])
    chk("color/HEX", f["HEX"] == "FF8000"); chk("color/RGB", f["RGB"] == "255, 128, 0"); chk("color/HTML", f["HTML"] == "#ff8000")
    chk("color/C++ (BGR COLORREF)", f["C++"] == "0x0080FF", f["C++"] ?? "")
    chk("color/Delphi (BGR)", f["Delphi"] == "$000080FF", f["Delphi"] ?? "")
    chk("color/Swift", f["Swift"] == "NSColor(srgbRed: 1.000, green: 0.502, blue: 0.000, alpha: 1)", f["Swift"] ?? "")
    chk("color/black+white", RGB(r: 0, g: 0, b: 0).formats[0].value == "000000" && RGB(r: 255, g: 255, b: 255).formats[3].value == "0xFFFFFF")
    chk("color/html-accessor", o.html == "#ff8000")
    for c in [RGB(r: 0, g: 0, b: 0), RGB(r: 255, g: 255, b: 255), o, RGB(r: 1, g: 2, b: 3), RGB(r: 171, g: 205, b: 239)] {
        chk("color/hex-roundtrip \(c.html)", RGB(hex: c.formats[0].value) == c && RGB(hex: c.html) == c && RGB(hex: "0x" + c.formats[0].value) == c && RGB(hex: "$" + c.formats[0].value) == c)
        let ns = c.nsColor.usingColorSpace(.sRGB)!
        chk("color/nscolor \(c.html)", Int((ns.redComponent * 255).rounded()) == Int(c.r) && Int((ns.greenComponent * 255).rounded()) == Int(c.g) && Int((ns.blueComponent * 255).rounded()) == Int(c.b))
    }
    chk("color/hex-parses-padded", RGB(hex: "  #FF8000 ") == o)
    for bad in ["", "12345", "1234567", "GGGGGG", "#12", "0x12345", "FF 80 00"] { chk("color/hex-rejects '\(bad)'", RGB(hex: bad) == nil) }
    // --- pixel sampling (top-left origin)
    let cols: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [10, 20, 30], [40, 50, 60], [70, 80, 90]]
    var buf = [UInt8](); for c in cols { buf += c + [255] }
    let ctx = buf.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)! }
    let im = ctx.makeImage()!
    var ok = true
    for y in 0..<2 { for x in 0..<3 { let c = cols[y * 3 + x]; if RGB.pixel(im, x: x, y: y) != RGB(r: c[0], g: c[1], b: c[2]) { ok = false; print("  pixel(\(x),\(y)) = \(String(describing: RGB.pixel(im, x: x, y: y)))") } } }
    chk("color/pixel-sampling-all-positions", ok)

    // --- ruler unit conversion (no window => backing scale 2)
    let r = RulerView()
    chk("ruler/px", { r.unit = 0; return r.value(at: 50) == "100 px" && r.value(at: 0) == "0 px" && r.value(at: 25) == "50 px" }())
    r.unit = 1; r.dpi = 96
    chk("ruler/inches@96", r.value(at: 48) == "1.00 in" && r.value(at: 24) == "0.50 in", r.value(at: 48))
    r.dpi = 300; chk("ruler/inches@300", r.value(at: 150) == "1.00 in", r.value(at: 150))
    r.unit = 2; r.dpi = 96
    chk("ruler/cm@96", r.value(at: 96 / 2.54 / 2) == "1.00 cm", r.value(at: 96 / 2.54 / 2))
    chk("ruler/cm-vs-inches-ratio", abs(Double(r.value(at: 48).split(separator: " ")[0])! - 2.54) < 0.01, r.value(at: 48))
    r.unit = 0; r.dpi = 96
    chk("ruler/draw-all-units-no-crash", { for u in 0..<3 { for d in RulerView.dpis { r.unit = u; r.dpi = d; r.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
        _ = r.bitmapImageRepForCachingDisplay(in: r.bounds).map { r.cacheDisplay(in: r.bounds, to: $0) } } }; return true }())

    // --- palette: RGB <-> HSV maths (window kept invisible)
    DesignTools.show(.colorPalette)
    guard let p = DesignTools.registry[.colorPalette] as? PaletteTool else { chk("palette/opens-and-registers", false); return }
    p.win.alphaValue = 0; p.win.orderOut(nil)
    chk("palette/opens-and-registers", true)
    func ref(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0; if d > 0 { h = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d; h *= 60; if h < 0 { h += 360 } }
        return (h, mx == 0 ? 0 : d / mx * 100, mx / 255 * 100)
    }
    var bad = 0, tried = 0
    for r in stride(from: 0, through: 255, by: 51) { for g in stride(from: 0, through: 255, by: 51) { for b in stride(from: 0, through: 255, by: 51) {
        tried += 1
        p.setRGB(Double(r), Double(g), Double(b))
        let e = ref(Double(r), Double(g), Double(b))
        if abs(p.v[4] - e.1) > 0.01 || abs(p.v[5] - e.2) > 0.01 || (e.1 > 0 && abs(p.v[3] - e.0) > 0.01 && abs(abs(p.v[3] - e.0) - 360) > 0.01) { bad += 1 }
        let (h, s, v) = (p.v[3], p.v[4], p.v[5]); p.v[3] = h; p.v[4] = s; p.v[5] = v; p.setHSV()
        if abs(p.v[0] - Double(r)) > 1 || abs(p.v[1] - Double(g)) > 1 || abs(p.v[2] - Double(b)) > 1 { bad += 1 }
    } } }
    chk("palette/rgb-hsv-roundtrip(\(tried) colours)", bad == 0, "\(bad) mismatches")
    p.v[3] = 360; p.v[4] = 100; p.v[5] = 100; p.setHSV()
    chk("palette/hue-360-is-red", p.rgb == RGB(r: 255, g: 0, b: 0), "\(p.rgb)")
    p.v[3] = 0; p.v[4] = 0; p.v[5] = 100; p.setHSV(); chk("palette/white", p.rgb == RGB(r: 255, g: 255, b: 255))
    p.hex.stringValue = "#336699"; p.hexTyped(); chk("palette/hex-typed", p.rgb == RGB(r: 51, g: 102, b: 153))
    p.hex.stringValue = "zzz"; p.hexTyped(); chk("palette/bad-hex-reverts-field", p.hex.stringValue == "#336699")
    p.fields[0].stringValue = "999"; p.typed(p.fields[0]); chk("palette/typed-clamped-to-255", p.v[0] == 255)
    p.fields[3].stringValue = "-5"; p.typed(p.fields[3]); chk("palette/typed-hue-clamped-to-0", p.v[3] == 0)
    DesignTools.show(.colorPalette); chk("palette/show-again-toggles-closed", DesignTools.registry[.colorPalette] == nil)

    // --- ruler tool lifecycle / rotate geometry (window invisible)
    DesignTools.show(.pixelRuler)
    guard let rt = DesignTools.registry[.pixelRuler] as? RulerTool else { chk("ruler/opens-and-registers", false); return }
    rt.win.alphaValue = 0
    let f0 = rt.win.frame; rt.rotate()
    chk("ruler/rotate-swaps-size-keeps-top-left", rt.view.vertical && abs(rt.win.frame.width - f0.height) < 1 && abs(rt.win.frame.height - f0.width) < 1 && abs(rt.win.frame.maxY - f0.maxY) < 1)
    rt.rotate(); chk("ruler/rotate-back", !rt.view.vertical && abs(rt.win.frame.width - f0.width) < 1)
    rt.close(); rt.close(); chk("ruler/close-unregisters-and-double-close-safe", DesignTools.registry[.pixelRuler] == nil)
    DesignTools.show(.protractor); (DesignTools.registry[.protractor] as? ProtractorTool)?.win.alphaValue = 0
    chk("protractor/registers", DesignTools.registry[.protractor] != nil); DesignTools.show(.protractor); chk("protractor/toggle-closed", DesignTools.registry[.protractor] == nil)
    // menuItem helper: target must stay alive and respond
    var fired = false; let mi = menuItem("x") { fired = true }
    _ = (mi.target as AnyObject).perform(mi.action!)
    chk("menuItem/helper-fires-closure", fired && mi.representedObject != nil)
}
