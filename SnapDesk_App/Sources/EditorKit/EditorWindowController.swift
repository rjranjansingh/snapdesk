import AppKit
import SnapCore

final class Act: NSObject {
    let f: (NSView) -> Void
    init(_ f: @escaping (NSView) -> Void) { self.f = f }
    @objc func go(_ s: Any?) { f((s as? NSView) ?? NSView()) }
}

final class RootView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with e: NSEvent) -> Bool { (onKey?(e) ?? false) || super.performKeyEquivalent(with: e) }
}

public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var live: [EditorWindowController] = []

    /// Opens a new editor window for the image (keeps itself alive until closed).
    public static func open(image: NSImage) {
        let c = EditorWindowController(image: image)
        live.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    let doc: Document
    let opt = Options()
    let canvas: CanvasView
    let scroll = NSScrollView()
    let status = NSTextField(labelWithString: "")
    private var acts: [Act] = []
    var toolButtons: [Tool: RibbonButton] = [:]

    init(image: NSImage) {
        doc = Document(image: image)
        canvas = CanvasView(doc: doc, opt: opt)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "SnapDesk Editor"; w.minSize = NSSize(width: 1180, height: 520); w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.acceptsMouseMovedEvents = true
        build(w)
        installHover()
        w.center()
        DispatchQueue.main.async { [self] in
            canvas.fit(in: scroll.contentSize); canvas.window?.makeFirstResponder(canvas)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Hover is driven by a window-level mouse-moved monitor: instant, and independent of tracking-area quirks.
    private var monitor: Any?
    weak var hoverBtn: RibbonButton?
    private func installHover() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            self?.updateHover(e); return e
        }
    }
    func updateHover(_ e: NSEvent) {
        var target: RibbonButton?
        if e.window === window, let root = window?.contentView, let sup = root.superview {
            var v = root.hitTest(sup.convert(e.locationInWindow, from: nil))
            while let x = v { if let b = x as? RibbonButton { target = b; break }; v = x.superview }
        }
        if target !== hoverBtn { let old = hoverBtn; hoverBtn = target; old?.setHover(false); target?.setHover(true) }
    }

    public func windowWillClose(_ n: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        RibbonTip.shared.hide()
        Self.live.removeAll { $0 === self } }
    public func windowWillReturnUndoManager(_ w: NSWindow) -> UndoManager? { doc.undo }

    // MARK: UI building
    /// Effects run on the marquee selection if there is one, otherwise on the whole image.
    private func applyFX(_ name: String, _ f: @escaping (NSImage) -> NSImage) { doc.filterBase(name, region: canvas.marquee, f) }

    static let help: [String: String] = [
        "Open": "Open another image in a new editor window (⌘O).", "Save As": "Save the image as PNG, JPEG, BMP, GIF, TIFF or PDF (⌘S).",
        "Copy": "Copy the finished image to the clipboard (⌘C).", "Print": "Print the image (⌘P).", "Share": "Send via AirDrop, Mail, Messages and more.",
        "Undo": "Undo the last change (⌘Z).", "Redo": "Redo the change you undid (⇧⌘Z).", "Delete": "Delete the selected object (⌫).",
        "Bring to Front": "Move the selected object above all others.", "Send to Back": "Move the selected object behind all others.",
        "Forward": "Move the selected object up one layer.", "Backward": "Move the selected object down one layer.",
        "Select": "Pick, move and resize annotations you have drawn.", "Select Area": "Drag a rectangle. Blur, sharpen and other effects then apply only inside it (Esc clears).",
        "Freehand Selection": "Draw around an area to cut it out of the image.", "Crop": "Drag a rectangle to keep only that part of the image.",
        "Text": "Click and type to add a text label.", "Arrow": "Drag to draw an arrow.", "Line": "Drag to draw a straight line.",
        "Rectangle": "Drag to draw a rectangle (turn on Fill for a solid box).", "Ellipse": "Drag to draw an ellipse or circle.",
        "Rounded Rectangle": "Drag to draw a rectangle with rounded corners.", "Speech Bubble": "Drag to draw a callout bubble, then type its text.",
        "Numbered Stamp": "Click to drop a numbered circle; numbers go up automatically.", "Cursor Stamp": "Click to place a mouse-pointer graphic.",
        "Symbol Icon": "Click to place the symbol chosen under Options.", "Pencil": "Thin freehand line.", "Brush": "Smooth, thick freehand stroke.",
        "Marker": "Semi-transparent marker stroke.", "Airbrush": "Soft spray-paint stroke.", "Calligraphy": "Angled calligraphy pen stroke.",
        "Highlighter": "Wide translucent highlight over text.", "Blur Region": "Drag over any area to blur just that part (strength: Blur / Mosaic option).",
        "Mosaic Region": "Drag over any area to pixelate just that part (block size: Blur / Mosaic option).",
        "Fill Bucket": "Click to fill a connected area with the line color.", "Eraser": "Paint over the image to erase it to white.",
        "Retouch (Blur Brush)": "Paint to softly blur small details.",
        "Resize": "Change the image size in pixels.", "Canvas Size": "Make the canvas bigger or smaller without scaling the image.",
        "Rotate Left": "Rotate the image 90° counter-clockwise.", "Rotate Right": "Rotate the image 90° clockwise.",
        "Flip Horizontal": "Mirror the image left to right.", "Flip Vertical": "Mirror the image top to bottom.",
        "Blur": "Gaussian blur. Applies to the Select Area rectangle if there is one, else the whole image.",
        "Sharpen": "Sharpen details (selection or whole image).", "Mosaic": "Pixelate (selection or whole image).",
        "Grayscale": "Remove color (selection or whole image).", "Invert": "Invert the colors (selection or whole image).",
        "Brightness": "Adjust brightness and contrast (selection or whole image).", "Hue / Sat": "Shift hue and saturation (selection or whole image).",
        "Balance": "Tune the red, green and blue balance (selection or whole image).",
        "Frame": "Add a border around the image in the line color.", "Shadow": "Add a soft drop shadow around the image.",
        "Watermark": "Stamp text over the image.", "Zoom In": "Zoom in (⌘+).", "Zoom Out": "Zoom out (⌘−).",
        "Fit": "Fit the whole image in the window (⌘0).", "100%": "Show the image at actual size (⌘1)."]

    private func act(_ f: @escaping (NSView) -> Void) -> Act { let a = Act(f); acts.append(a); return a }

    /// Ribbon button with instant hover feedback (no system tooltip delay); hovered name shows in the status bar.
    private func button(_ title: String, _ sym: String, icon: Bool = false, _ f: @escaping (NSView) -> Void) -> RibbonButton {
        let b = RibbonButton(title: title, symbol: sym, small: icon, action: f)
        b.help = Self.help[title] ?? ""
        b.onHover = { [unowned self] on in
            if on { status.stringValue = title } else { canvas.onStatus?("") }
        }
        return b
    }

    /// A ribbon group: content on top, centered caption below, thin divider on the right.
    private func group(_ title: String, _ rows: [NSView]) -> NSView {
        let body = NSStackView(views: rows); body.orientation = .vertical; body.spacing = 2; body.alignment = .centerX
        body.heightAnchor.constraint(equalToConstant: 58).isActive = true   // same content height => captions line up
        let cap = NSTextField(labelWithString: title); cap.font = .systemFont(ofSize: 10, weight: .medium); cap.textColor = .tertiaryLabelColor
        cap.alignment = .center
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let v = NSStackView(views: [body, spacer, cap]); v.orientation = .vertical; v.spacing = 2; v.alignment = .centerX
        v.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        let sep = NSBox(); sep.boxType = .separator; sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let h = NSStackView(views: [v, sep]); h.spacing = 4; h.alignment = .top
        v.heightAnchor.constraint(equalToConstant: 78).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 76).isActive = true
        return h
    }
    private func row(_ v: [NSView]) -> NSStackView { let s = NSStackView(views: v); s.spacing = 1; s.alignment = .centerY; return s }

    private func setTool(_ t: Tool) {
        canvas.tool = t
        for (k, b) in toolButtons { b.isOn = k == t }
    }

    private func toolGroup(_ title: String, _ tools: [Tool], perRow: Int) -> NSView {
        var rows: [NSView] = []
        var i = 0
        while i < tools.count {
            let chunk = tools[i..<min(i + perRow, tools.count)]
            rows.append(row(chunk.map { t in
                let b = button(t.label, t.sym, icon: true) { [unowned self] _ in setTool(t) }
                b.toggles = true; toolButtons[t] = b; return b }))
            i += perRow
        }
        return group(title, rows)
    }

    private func build(_ w: NSWindow) {
        let root = RootView(); w.contentView = root
        root.onKey = { [weak self] e in self?.key(e) ?? false }

        // ---- Home tab
        let selectG = toolGroup("Select", [.marquee, .select, .freehand, .crop], perRow: 2)
        let annotate = toolGroup("Annotate", [.text, .arrow, .line, .rect, .ellipse, .rounded, .callout, .number, .cursor, .symbol], perRow: 5)
        let draw = toolGroup("Draw", [.pencil, .brush, .marker, .airbrush, .calligraphy, .highlighter], perRow: 3)
        let retouch = toolGroup("Retouch", [.blur, .mosaic, .fill, .eraser, .retouch], perRow: 3)
        toolButtons[.select]?.isOn = true

        let file = group("File", [row([
            button("Open", "folder") { [unowned self] _ in openFile() },
            button("Save As", "square.and.arrow.down") { [unowned self] _ in save() },
            button("Copy", "doc.on.doc") { [unowned self] _ in copyImage() },
            button("Print", "printer") { [unowned self] _ in printImage() },
            button("Share", "square.and.arrow.up") { [unowned self] v in share(v) }])])
        let edit = group("Edit", [row([
            button("Undo", "arrow.uturn.backward") { [unowned self] _ in doc.undo.undo() },
            button("Redo", "arrow.uturn.forward") { [unowned self] _ in doc.undo.redo() },
            button("Delete", "trash") { [unowned self] _ in canvas.deleteSelected() }])])
        let arrange = group("Arrange", [
            row([button("Bring to Front", "square.3.layers.3d.top.filled", icon: true) { [unowned self] _ in canvas.reorder(0) },
                 button("Send to Back", "square.3.layers.3d.bottom.filled", icon: true) { [unowned self] _ in canvas.reorder(1) }]),
            row([button("Forward", "arrow.up.square", icon: true) { [unowned self] _ in canvas.reorder(2) },
                 button("Backward", "arrow.down.square", icon: true) { [unowned self] _ in canvas.reorder(3) }])])

        func well(_ c: NSColor, _ tip: String, _ f: @escaping (NSColor) -> Void) -> NSColorWell {
            let cw = NSColorWell(style: .minimal); cw.color = c; cw.toolTip = tip
            let a = act { [unowned self] v in f((v as! NSColorWell).color); canvas.restyle() }
            cw.target = a; cw.action = #selector(Act.go(_:))
            cw.widthAnchor.constraint(equalToConstant: 44).isActive = true; cw.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return cw
        }
        func pop(_ items: [String], _ sel: String, _ f: @escaping (String) -> Void) -> NSPopUpButton {
            let p = NSPopUpButton(); p.controlSize = .small; p.addItems(withTitles: items); p.selectItem(withTitle: sel)
            let a = act { [unowned self] v in f((v as! NSPopUpButton).titleOfSelectedItem ?? ""); canvas.restyle() }
            p.target = a; p.action = #selector(Act.go(_:)); return p
        }
        let fillBox = NSButton(checkboxWithTitle: "", target: nil, action: nil); fillBox.controlSize = .small; fillBox.toolTip = "Fill shapes"
        let fa = act { [unowned self] v in opt.useFill = (v as! NSButton).state == .on; canvas.restyle() }
        fillBox.target = fa; fillBox.action = #selector(Act.go(_:))
        func lab(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; return l }
        let grid = NSGridView(views: [
            [lab("Line"), well(opt.color, "Line / text color") { [unowned self] in opt.color = $0 }, lab("Width"), pop(["1", "2", "3", "5", "8", "12", "20"], "3") { [unowned self] in opt.width = CGFloat(Double($0) ?? 3) }],
            [lab("Fill"), row([well(opt.fill, "Fill color") { [unowned self] in opt.fill = $0 }, fillBox]), lab("Font"), pop(["12", "14", "18", "24", "36", "48", "72"], "18") { [unowned self] in opt.fontSize = CGFloat(Double($0) ?? 18) }]])
        grid.rowSpacing = 6; grid.columnSpacing = 6
        for r in 0..<2 { grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .trailing; grid.cell(atColumnIndex: 2, rowIndex: r).xPlacement = .trailing }
        let style = group("Style", [grid])

        let syms = ["star.fill", "heart.fill", "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill",
                    "questionmark.circle.fill", "info.circle.fill", "flag.fill", "pin.fill", "bolt.fill", "lightbulb.fill", "hand.thumbsup.fill",
                    "arrow.right.circle.fill", "bell.fill", "bookmark.fill", "eye.fill", "lock.fill", "gearshape.fill"]
        let sp = NSPopUpButton(); sp.controlSize = .small; sp.widthAnchor.constraint(equalToConstant: 64).isActive = true
        for s in syms { sp.addItem(withTitle: ""); sp.lastItem?.representedObject = s; sp.lastItem?.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        let sa = act { [unowned self] v in opt.symbol = (v as! NSPopUpButton).selectedItem?.representedObject as? String ?? "star.fill"; setTool(.symbol) }
        sp.target = sa; sp.action = #selector(Act.go(_:))
        let mp = pop(["5", "8", "10", "16", "24", "32"], "10") { [unowned self] in opt.block = Int($0) ?? 10 }
        let optGrid = NSGridView(views: [[lab("Symbol"), sp], [lab("Blur / Mosaic"), mp]]); optGrid.rowSpacing = 6; optGrid.columnSpacing = 6
        let stamps = group("Options", [optGrid])
        let home = panel([file, edit, arrange, selectG, annotate, draw, retouch, style, stamps])

        // ---- Image tab
        func fx(_ t: String, _ s: String, _ f: @escaping () -> Void) -> RibbonButton { button(t, s) { _ in f() } }
        let geo = group("Canvas", [row([
            fx("Crop", "crop") { [unowned self] in setTool(.crop) },
            fx("Resize", "arrow.up.left.and.arrow.down.right") { [unowned self] in resizeImage() },
            fx("Canvas Size", "rectangle.expand.vertical") { [unowned self] in resizeCanvas() }])])
        let xform = group("Transform", [row([
            fx("Rotate Left", "rotate.left") { [unowned self] in doc.flattenOp("Rotate") { Raster.rotate($0, clockwise: false) } },
            fx("Rotate Right", "rotate.right") { [unowned self] in doc.flattenOp("Rotate") { Raster.rotate($0, clockwise: true) } },
            fx("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") { [unowned self] in doc.flattenOp("Flip") { Raster.flip($0, horizontal: true) } },
            fx("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") { [unowned self] in doc.flattenOp("Flip") { Raster.flip($0, horizontal: false) } }])])
        let filters = group("Effects", [row([
            fx("Blur", "aqi.medium") { [unowned self] in blur() },
            fx("Sharpen", "triangle") { [unowned self] in sharpen() },
            fx("Mosaic", "square.grid.3x3") { [unowned self] in mosaicAll() },
            fx("Grayscale", "circle.lefthalf.filled") { [unowned self] in applyFX("Grayscale") { Raster.filter($0) { $0.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.0]) } } },
            fx("Invert", "circle.righthalf.filled") { [unowned self] in applyFX("Invert") { Raster.filter($0) { $0.applyingFilter("CIColorInvert") } } }])])
        let adjust = group("Adjust", [row([
            fx("Brightness", "sun.max") { [unowned self] in brightness() },
            fx("Hue / Sat", "paintpalette") { [unowned self] in hueSat() },
            fx("Balance", "slider.horizontal.3") { [unowned self] in colorBalance() }])])
        let deco = group("Decorate", [row([
            fx("Frame", "square.dashed") { [unowned self] in frame() },
            fx("Shadow", "shadow") { [unowned self] in shadow() },
            fx("Watermark", "textformat.alt") { [unowned self] in watermark() }])])
        let image = panel([geo, xform, filters, adjust, deco])

        // ---- View tab
        let zoomG = group("Zoom", [row([
            fx("Zoom In", "plus.magnifyingglass") { [unowned self] in canvas.zoom = min(16, canvas.zoom * 1.25) },
            fx("Zoom Out", "minus.magnifyingglass") { [unowned self] in canvas.zoom = max(0.05, canvas.zoom / 1.25) },
            fx("Fit", "arrow.up.left.and.down.right.magnifyingglass") { [unowned self] in canvas.fit(in: scroll.contentSize) },
            fx("100%", "1.magnifyingglass") { [unowned self] in canvas.zoom = 1 }])])
        let view = panel([zoomG])

        // ---- tabs
        let seg = NSSegmentedControl(labels: ["Home", "Image", "View"], trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = 0; seg.segmentStyle = .texturedRounded
        let panels = [home, image, view]
        let sa2 = act { v in
            let i = (v as! NSSegmentedControl).selectedSegment
            for (k, p) in panels.enumerated() { p.isHidden = k != i }
        }
        seg.target = sa2; seg.action = #selector(Act.go(_:))
        image.isHidden = true; view.isHidden = true
        let panelHost = NSView(); panelHost.translatesAutoresizingMaskIntoConstraints = false
        for p in panels {
            p.translatesAutoresizingMaskIntoConstraints = false; panelHost.addSubview(p)
            NSLayoutConstraint.activate([p.leadingAnchor.constraint(equalTo: panelHost.leadingAnchor),
                                         p.topAnchor.constraint(equalTo: panelHost.topAnchor),
                                         p.bottomAnchor.constraint(equalTo: panelHost.bottomAnchor),
                                         panelHost.widthAnchor.constraint(greaterThanOrEqualTo: p.widthAnchor)])
        }
        // Ribbon lives in a horizontal scroll view so a narrow window scrolls instead of clipping.
        let ribbonScroll = NSScrollView(); ribbonScroll.translatesAutoresizingMaskIntoConstraints = false
        ribbonScroll.drawsBackground = false; ribbonScroll.hasHorizontalScroller = true; ribbonScroll.autohidesScrollers = true
        ribbonScroll.hasVerticalScroller = false; ribbonScroll.horizontalScrollElasticity = .allowed
        ribbonScroll.documentView = panelHost
        let clip = ribbonScroll.contentView
        NSLayoutConstraint.activate([panelHost.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                                     panelHost.topAnchor.constraint(equalTo: clip.topAnchor),
                                     panelHost.heightAnchor.constraint(equalTo: clip.heightAnchor),
                                     ribbonScroll.heightAnchor.constraint(equalToConstant: 84)])

        scroll.documentView = canvas; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(white: 0.32, alpha: 1)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        canvas.onStatus = { [unowned self] s in
            if hoverBtn != nil { return }  // keep the hovered tool name visible
            let sz = doc.state.image.size
            let sel = canvas.marquee.map { "   Selection \(Int($0.width)) x \(Int($0.height))" } ?? ""
            status.stringValue = "\(Int(sz.width)) x \(Int(sz.height)) px   \(Int(canvas.zoom * 100))%\(sel)   \(s)"
        }
        canvas.onStatus?("")

        let ribbonBG = NSVisualEffectView(); ribbonBG.material = .headerView; ribbonBG.blendingMode = .withinWindow
        seg.translatesAutoresizingMaskIntoConstraints = false
        ribbonBG.addSubview(seg); ribbonBG.addSubview(ribbonScroll)
        NSLayoutConstraint.activate([
            seg.leadingAnchor.constraint(equalTo: ribbonBG.leadingAnchor, constant: 10), seg.topAnchor.constraint(equalTo: ribbonBG.topAnchor, constant: 8),
            ribbonScroll.leadingAnchor.constraint(equalTo: ribbonBG.leadingAnchor, constant: 6),
            ribbonScroll.trailingAnchor.constraint(equalTo: ribbonBG.trailingAnchor),
            ribbonScroll.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 6),
            ribbonScroll.bottomAnchor.constraint(equalTo: ribbonBG.bottomAnchor, constant: -4)])
        let sep = NSBox(); sep.boxType = .separator
        let statusBar = NSStackView(views: [status]); statusBar.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        let col = NSStackView(views: [ribbonBG, sep, scroll, statusBar]); col.orientation = .vertical; col.spacing = 0; col.alignment = .leading
        col.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(col)
        for v in [ribbonBG, sep, scroll, statusBar] { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([col.leadingAnchor.constraint(equalTo: root.leadingAnchor), col.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     col.topAnchor.constraint(equalTo: root.topAnchor), col.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
    }

    /// Test hook: renders the editor, simulates hovering the first ribbon button, writes PNGs, returns a report.
    static func snapshot(to dir: String) -> String {
        let img = NSImage(size: NSSize(width: 900, height: 560), flipped: false) { r in
            NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: r, angle: 30); return true }
        let c = EditorWindowController(image: img)
        c.showWindow(nil); c.window?.orderFrontRegardless()
        c.window?.layoutIfNeeded(); c.window?.displayIfNeeded()
        func shot(_ name: String) {
            guard let v = c.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        shot("editor_home")
        var report = "window \(c.window?.frame.size ?? .zero)\n"
        if let b = c.toolButtons[.blur], let win = c.window {
            let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
            let ev = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            NSApp.sendEvent(ev)
            report += "hover on blur button: \(b.isHovering), status: \(c.status.stringValue)\n"
            win.displayIfNeeded(); shot("editor_hover")
        }
        report += "ribbon button frames visible: \(c.toolButtons.count) tools\n"
        return report
    }

    private func panel(_ groups: [NSView]) -> NSView {
        let s = NSStackView(views: groups); s.orientation = .horizontal; s.alignment = .top; s.spacing = 2; return s
    }

    // MARK: keyboard shortcuts
    private func key(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command), let k = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = e.modifierFlags.contains(.shift)
        switch k {
        case "z": shift ? doc.undo.redo() : doc.undo.undo()
        case "a": canvas.marquee = doc.state.image.full
        case "d": canvas.marquee = nil
        case "s": save()
        case "c": copyImage()
        case "p": printImage()
        case "o": openFile()
        case "=", "+": canvas.zoom = min(16, canvas.zoom * 1.25)
        case "-": canvas.zoom = max(0.05, canvas.zoom / 1.25)
        case "0": canvas.fit(in: scroll.contentSize)
        case "1": canvas.zoom = 1
        default: return false
        }
        return true
    }

    // MARK: file ops
    func flat() -> NSImage { Painter.flatten(doc.state) }

    private func openFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url, let i = NSImage(contentsOf: u) { Self.open(image: i) }
    }
    private func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = "Untitled"; p.canCreateDirectories = true
        let pop = NSPopUpButton(); pop.addItems(withTitles: ImageFormat.allCases.map { $0.rawValue.uppercased() })
        pop.selectItem(at: ImageFormat.allCases.firstIndex(of: Preferences.shared.format) ?? 0)
        p.accessoryView = pop
        guard p.runModal() == .OK, let u = p.url else { return }
        let f = ImageFormat.allCases[pop.indexOfSelectedItem]
        let url = u.deletingPathExtension().appendingPathExtension(ImageOutput.ext(f))
        if let d = ImageOutput.data(flat(), format: f, quality: Preferences.shared.jpegQuality) {
            do { try d.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
    }
    private func copyImage() { ImageOutput.copyToClipboard(flat()) }
    private func printImage() {
        let img = flat()
        let v = NSImageView(frame: NSRect(origin: .zero, size: img.size)); v.image = img
        NSPrintOperation(view: v).run()
    }
    private func share(_ v: NSView) {
        NSSharingServicePicker(items: [flat()]).show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
    }

    // MARK: image ops
    private func num(_ s: String, _ d: Double) -> Double { Double(s) ?? d }
    static let maxSide = 16384.0   // CGContext allocation limit guard
    private func clamped(_ s: String, _ d: Double, _ hi: Double) -> CGFloat { CGFloat(min(max(num(s, d), 0), hi)) }
    private func resizeImage() {
        let s = doc.state.image.size
        guard let r = ask("Resize Image (pixels)", [("Width", "\(Int(s.width))"), ("Height", "\(Int(s.height))")]),
              let w = Double(r[0]), let h = Double(r[1]), w >= 1, h >= 1, w <= Self.maxSide, h <= Self.maxSide else { return }
        doc.flattenOp("Resize Image") { Raster.resizeImage($0, CGSize(width: w, height: h)) }
    }
    private func resizeCanvas() {
        let s = doc.state.image.size
        guard let r = ask("Resize Canvas (pixels)", [("Width", "\(Int(s.width))"), ("Height", "\(Int(s.height))")]),
              let w = Double(r[0]), let h = Double(r[1]), w >= 1, h >= 1, w <= Self.maxSide, h <= Self.maxSide else { return }
        doc.flattenOp("Resize Canvas") { Raster.resizeCanvas($0, CGSize(width: w, height: h), bg: opt.fill) }
    }
    private func blur() {
        guard let r = ask("Blur", [("Radius", "5")]) else { return }
        let v = num(r[0], 5); applyFX("Blur") { Raster.filter($0) { $0.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v]) } }
    }
    private func sharpen() {
        guard let r = ask("Sharpen", [("Amount (0-2)", "0.8")]) else { return }
        let v = num(r[0], 0.8); applyFX("Sharpen") { Raster.filter($0) { $0.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": v]) } }
    }
    private func mosaicAll() {
        guard let r = ask("Mosaic", [("Block size", "10")]) else { return }
        let v = num(r[0], 10); applyFX("Mosaic") { Raster.filter($0) { $0.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: v]) } }
    }
    private func brightness() {
        guard let r = ask("Brightness / Contrast", [("Brightness (-1..1)", "0"), ("Contrast (0..4)", "1")]) else { return }
        let b = num(r[0], 0), c = num(r[1], 1)
        applyFX("Brightness/Contrast") { Raster.filter($0) { $0.applyingFilter("CIColorControls", parameters: ["inputBrightness": b, "inputContrast": c]) } }
    }
    private func hueSat() {
        guard let r = ask("Hue / Saturation", [("Hue (degrees)", "0"), ("Saturation (0..3)", "1")]) else { return }
        let h = num(r[0], 0) * .pi / 180, s = num(r[1], 1)
        applyFX("Hue/Saturation") { Raster.filter($0) {
            $0.applyingFilter("CIHueAdjust", parameters: ["inputAngle": h]).applyingFilter("CIColorControls", parameters: ["inputSaturation": s]) } }
    }
    private func colorBalance() {
        guard let r = ask("Color Balance", [("Red (-1..1)", "0"), ("Green (-1..1)", "0"), ("Blue (-1..1)", "0")]) else { return }
        let (a, b, c) = (1 + num(r[0], 0), 1 + num(r[1], 0), 1 + num(r[2], 0))
        applyFX("Color Balance") { Raster.filter($0) {
            $0.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: b, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: c, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]) } }
    }
    private func frame() {
        guard let r = ask("Frame / Border (uses Line color)", [("Width", "10")]) else { return }
        let w = clamped(r[0], 10, 2000); doc.flattenOp("Frame") { Raster.frame($0, width: w, color: opt.color) }
    }
    private func shadow() {
        guard let r = ask("Drop Shadow", [("Blur", "10")]) else { return }
        let b = clamped(r[0], 10, 200); doc.flattenOp("Drop Shadow") { Raster.shadow($0, blur: b) }
    }
    private func watermark() {
        guard let r = ask("Watermark", [("Text", "Watermark")]), !r[0].isEmpty else { return }
        doc.flattenOp("Watermark") { Raster.watermark($0, text: r[0]) }
    }
}

public func editorKitSnapshot(to dir: String) -> String { EditorWindowController.snapshot(to: dir) }

/// Cheap self-check (call from a debug build): renders objects, runs a filter, flood fill, and undo.
public func editorKitSanityCheck() -> Bool {
    let base = makeImage(CGSize(width: 40, height: 30)) { NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 40, height: 30).fill() }
    let d = Document(image: base)
    var o = Obj(kind: .rect); o.rect = CGRect(x: 5, y: 5, width: 20, height: 10); o.fill = .blue
    d.undo.groupsByEvent = false   // no run loop here: make each operation its own undo step explicitly
    func step(_ f: () -> Void) { d.undo.beginUndoGrouping(); f(); d.undo.endUndoGrouping() }
    step { d.commit("add") { $0.objects.append(o) } }
    let flat = Painter.flatten(d.state)
    step { d.flattenOp("rot") { Raster.rotate($0, clockwise: true) } }
    let rotated = d.state.image.size == CGSize(width: 30, height: 40)
    d.undo.undo()
    let f = Raster.flood(base, at: .zero, color: .red)
    return flat.size == base.size && rotated && d.state.objects.count == 1 && f.size == base.size
        && Raster.filter(base) { $0.applyingFilter("CIColorInvert") }.size == base.size
}
