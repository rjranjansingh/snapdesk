import AppKit

// MARK: - Color picker

final class PickView: OverlayView {
    weak var tool: PickerTool?
    override func mouseDown(with e: NSEvent) { tool?.pick() }
    override func rightMouseDown(with e: NSEvent) { tool?.stopPicking() }
}

final class PickerTool: OverlayTool {
    static let histKey = "ToolsKit.pickerHistory"
    let loupe = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 150 + 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let loupeView = LoupeView()
    var panel: NSPanel!
    var swatch = NSView(), valueFields: [NSTextField] = [], histRow = NSStackView(), fmtPopup = NSPopUpButton()
    var current: RGB?, inflight = false
    var history: [RGB] {
        get { (UserDefaults.standard.stringArray(forKey: Self.histKey) ?? []).compactMap { RGB(hex: $0) } }
        set { UserDefaults.standard.set(newValue.prefix(14).map { $0.formats[0].value }, forKey: Self.histKey) }
    }

    init() {
        super.init(.colorPicker)
        loupeView.capHeight = 54; loupeView.frame = NSRect(x: 0, y: 0, width: 150, height: 204)
        loupe.contentView = loupeView; loupe.level = .screenSaver + 1; loupe.ignoresMouseEvents = true
        loupe.isOpaque = false; loupe.hasShadow = true; loupe.collectionBehavior = [.canJoinAllSpaces, .stationary]
        buildPanel()
        startPicking()
    }

    func startPicking() {
        guard windows.isEmpty else { return }
        startOverlays { [unowned self] s in let v = PickView(screen: s); v.tool = self; return v }
        loupe.orderFrontRegardless()
    }
    func stopPicking() { stopOverlays(); loupe.orderOut(nil); panel.makeKeyAndOrderFront(nil) }
    override func escape() { if windows.isEmpty { close() } else { stopPicking() } }
    override func teardown() { stopOverlays(); loupe.orderOut(nil); panel.delegate = nil; panel.close() }

    override func tick() {
        let m = Grab.mouse(), cm = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { $0.frame.contains(cm) } ?? NSScreen.screens[0]
        var o = NSPoint(x: cm.x + 24, y: cm.y - 24 - loupe.frame.height)
        if o.x + loupe.frame.width > scr.frame.maxX { o.x = cm.x - 24 - loupe.frame.width }
        if o.y < scr.frame.minY { o.y = cm.y + 24 }
        loupe.setFrameOrigin(o)
        guard !inflight else { return }
        let sc = Grab.scale(at: m), n = 13
        let px = NSPoint(x: floor(m.x * sc) / sc, y: floor(m.y * sc) / sc)
        let rect = CGRect(x: px.x - CGFloat(n / 2) / sc, y: px.y - CGFloat(n / 2) / sc, width: CGFloat(n) / sc, height: CGFloat(n) / sc)
        inflight = true
        Grab.image(rect) { [weak self] img, src in
            guard let self else { return }
            self.inflight = false
            guard let img else {
                self.loupeView.image = nil; self.loupeView.swatch = nil
                self.loupeView.caption = ["Screen Recording", "permission needed"]; self.current = nil; return
            }
            let ix = Int(((px.x - src.minX) * sc).rounded()), iy = Int(((px.y - src.minY) * sc).rounded())
            if let c = RGB.pixel(img, x: min(max(ix, 0), img.width - 1), y: min(max(iy, 0), img.height - 1)) {
                self.current = c; self.loupeView.swatch = c.nsColor
                self.loupeView.caption = [c.html, "\(c.r), \(c.g), \(c.b)", "x \(Int(m.x))  y \(Int(m.y))"]
            }
            self.loupeView.image = img
        }
    }

    func pick() {
        guard let c = current else { return }
        var h = history.filter { $0 != c }; h.insert(c, at: 0); history = h
        show(c)
        let f = c.formats[fmtPopup.indexOfSelectedItem]
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.value, forType: .string)
        stopPicking()
    }

    // Result panel
    func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 330), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Color Picker"; panel.isReleasedWhenClosed = false; panel.delegate = self; panel.level = .floating
        swatch.wantsLayer = true; swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.heightAnchor.constraint(equalToConstant: 36).isActive = true
        swatch.layer?.borderWidth = 1; swatch.layer?.borderColor = NSColor.gray.cgColor
        let stack = NSStackView(views: [swatch]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        let names = RGB(r: 0, g: 0, b: 0).formats.map { $0.name }
        for (i, n) in names.enumerated() {
            let l = NSTextField(labelWithString: n); l.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let tf = NSTextField(string: ""); tf.isEditable = false; tf.isSelectable = true; tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tf.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
            let b = NSButton(title: "Copy", target: self, action: #selector(copyField(_:))); b.tag = i
            valueFields.append(tf)
            let row = NSStackView(views: [l, tf, b]); row.spacing = 6; stack.addArrangedSubview(row)
        }
        fmtPopup.addItems(withTitles: names); fmtPopup.selectItem(at: 2)
        let pick = NSButton(title: "Pick color", target: self, action: #selector(repick))
        let r = NSStackView(views: [NSTextField(labelWithString: "Auto-copy on pick:"), fmtPopup, pick]); r.spacing = 8
        stack.addArrangedSubview(r)
        stack.addArrangedSubview(NSTextField(labelWithString: "History (click to reload)"))
        histRow.spacing = 4; stack.addArrangedSubview(histRow)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = stack
        swatch.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        show(history.first)
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    func show(_ c: RGB?) {
        swatch.layer?.backgroundColor = (c?.nsColor ?? .clear).cgColor
        for (i, f) in valueFields.enumerated() { f.stringValue = c?.formats[i].value ?? "" }
        histRow.views.forEach { $0.removeFromSuperview() }
        for (i, h) in history.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(loadHist(_:))); b.tag = i
            b.isBordered = false; b.wantsLayer = true; b.layer?.backgroundColor = h.nsColor.cgColor; b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.gray.cgColor; b.toolTip = h.html
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true; b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            histRow.addArrangedSubview(b)
        }
    }
    @objc func copyField(_ s: NSButton) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(valueFields[s.tag].stringValue, forType: .string)
    }
    @objc func loadHist(_ s: NSButton) { show(history[s.tag]) }
    @objc func repick() { startPicking() }
}

// MARK: - Palette (RGB + HSV with saved swatches)

final class SwatchGrid: NSView {
    static let key = "ToolsKit.paletteSwatches"
    var onSelect: ((RGB) -> Void)?
    var items: [RGB] {
        get { (UserDefaults.standard.stringArray(forKey: Self.key) ?? []).compactMap { RGB(hex: $0) } }
        set { UserDefaults.standard.set(newValue.map { $0.formats[0].value }, forKey: Self.key); needsDisplay = true }
    }
    let cell: CGFloat = 26, perRow = 14
    override var isFlipped: Bool { true }
    func index(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        let i = Int(p.y / cell) * perRow + Int(p.x / cell)
        return p.x >= 0 && p.y >= 0 && Int(p.x / cell) < perRow && i < items.count ? i : nil
    }
    override func mouseDown(with e: NSEvent) { if let i = index(e) { onSelect?(items[i]) } }
    override func menu(for e: NSEvent) -> NSMenu? {
        guard let i = index(e) else { return nil }
        let m = NSMenu(); m.addItem(menuItem("Delete swatch") { [weak self] in self?.items.remove(at: i) }); return m
    }
    override func draw(_ r: NSRect) {
        for (i, c) in items.enumerated() {
            let rc = NSRect(x: CGFloat(i % perRow) * cell + 1, y: CGFloat(i / perRow) * cell + 1, width: cell - 3, height: cell - 3)
            c.nsColor.setFill(); rc.fill(); NSColor.gray.setStroke(); NSBezierPath(rect: rc).stroke()
        }
    }
}

final class PaletteTool: ToolBase {
    var win: NSWindow!
    var sliders: [NSSlider] = [], fields: [NSTextField] = [], hex = NSTextField(string: ""), swatch = NSView()
    let grid = SwatchGrid()
    var v: [Double] = [255, 128, 0, 30, 100, 100]   // r g b h s v

    init() {
        super.init(.colorPalette)
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Color Palette"; win.isReleasedWhenClosed = false; win.delegate = self; win.level = .floating
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        swatch.wantsLayer = true; swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.heightAnchor.constraint(equalToConstant: 50).isActive = true
        swatch.widthAnchor.constraint(equalToConstant: 396).isActive = true
        stack.addArrangedSubview(swatch)
        let maxes: [Double] = [255, 255, 255, 360, 100, 100]
        for (i, n) in ["R", "G", "B", "H", "S", "V"].enumerated() {
            let s = NSSlider(value: 0, minValue: 0, maxValue: maxes[i], target: self, action: #selector(slid(_:))); s.tag = i
            s.widthAnchor.constraint(equalToConstant: 280).isActive = true
            let f = NSTextField(string: ""); f.tag = i; f.target = self; f.action = #selector(typed(_:)); f.widthAnchor.constraint(equalToConstant: 50).isActive = true
            sliders.append(s); fields.append(f)
            let l = NSTextField(labelWithString: n); l.widthAnchor.constraint(equalToConstant: 16).isActive = true
            stack.addArrangedSubview(NSStackView(views: [l, s, f]))
        }
        hex.target = self; hex.action = #selector(hexTyped); hex.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let save = NSButton(title: "Save swatch", target: self, action: #selector(saveSwatch))
        let copy = NSButton(title: "Copy HTML", target: self, action: #selector(copyHex))
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "HTML"), hex, save, copy]))
        stack.addArrangedSubview(NSTextField(labelWithString: "Saved swatches (click to load, right-click to delete)"))
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: 14 * 26).isActive = true; grid.heightAnchor.constraint(equalToConstant: 26 * 6).isActive = true
        grid.onSelect = { [unowned self] c in setRGB(Double(c.r), Double(c.g), Double(c.b)) }
        stack.addArrangedSubview(grid)
        win.contentView = stack
        refresh(); win.center(); win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    override var wantsEscape: Bool { false }
    override func teardown() { win.delegate = nil; win.close() }

    var rgb: RGB { RGB(r: UInt8(v[0].rounded()), g: UInt8(v[1].rounded()), b: UInt8(v[2].rounded())) }
    func setRGB(_ r: Double, _ g: Double, _ b: Double) {
        v[0] = r; v[1] = g; v[2] = b
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        if d > 0 {
            var h = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d
            h *= 60; if h < 0 { h += 360 }; v[3] = h
        }
        v[4] = mx == 0 ? 0 : d / mx * 100; v[5] = mx / 255 * 100; refresh()
    }
    func setHSV() {
        let h = v[3] / 60, s = v[4] / 100, val = v[5] / 100, c = val * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = val - c
        let t: (Double, Double, Double) = switch Int(h) % 6 { case 0: (c, x, 0); case 1: (x, c, 0); case 2: (0, c, x); case 3: (0, x, c); case 4: (x, 0, c); default: (c, 0, x) }
        v[0] = (t.0 + m) * 255; v[1] = (t.1 + m) * 255; v[2] = (t.2 + m) * 255; refresh()
    }
    func refresh() {
        for i in 0..<6 { sliders[i].doubleValue = v[i]; fields[i].stringValue = String(Int(v[i].rounded())) }
        swatch.layer?.backgroundColor = rgb.nsColor.cgColor; hex.stringValue = rgb.html
    }
    @objc func slid(_ s: NSSlider) { v[s.tag] = s.doubleValue; s.tag < 3 ? setRGB(v[0], v[1], v[2]) : setHSV() }
    @objc func typed(_ f: NSTextField) {
        let mx: Double = f.tag == 3 ? 360 : f.tag < 3 ? 255 : 100
        v[f.tag] = min(max(Double(f.intValue), 0), mx); f.tag < 3 ? setRGB(v[0], v[1], v[2]) : setHSV()
    }
    @objc func hexTyped() { if let c = RGB(hex: hex.stringValue) { setRGB(Double(c.r), Double(c.g), Double(c.b)) } else { refresh() } }
    @objc func saveSwatch() { if !grid.items.contains(rgb) { grid.items.append(rgb) } }
    @objc func copyHex() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rgb.html, forType: .string) }
}
