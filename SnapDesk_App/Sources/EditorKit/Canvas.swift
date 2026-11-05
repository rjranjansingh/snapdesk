import AppKit

/// Test hook: when set, replaces the modal input dialog (nil result = Cancel).
nonisolated(unsafe) var askOverride: ((String, [(String, String)]) -> [String]?)?

func ask(_ title: String, _ fields: [(String, String)]) -> [String]? {
    if let o = askOverride { return o(title, fields) }
    let a = NSAlert(); a.messageText = title
    a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
    let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
    var tfs: [NSTextField] = []
    for (l, d) in fields {
        let tf = NSTextField(string: d); tf.widthAnchor.constraint(equalToConstant: 220).isActive = true
        tfs.append(tf)
        let row = NSStackView(views: [NSTextField(labelWithString: l), tf]); row.spacing = 8
        stack.addArrangedSubview(row)
    }
    stack.setFrameSize(stack.fittingSize)
    a.accessoryView = stack
    a.window.initialFirstResponder = tfs.first
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    return tfs.map { $0.stringValue }
}

final class CanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    let doc: Document
    let opt: Options
    var tool: Tool = .select { didSet { selected = nil; draft = nil; lasso = []; needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// Rectangular pixel selection; effects (blur, sharpen, ...) apply only inside it when present.
    var marquee: CGRect? { didSet { needsDisplay = true; onStatus?("") } }
    var selected: UUID? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1 { didSet { updateFrame(); onStatus?("") } }
    var onStatus: ((String) -> Void)?
    let margin: CGFloat = 20

    private enum Drag { case none, create(CGPoint), move, resize(Int) }
    private var drag = Drag.none
    private var startState: Document.State?
    private var last = CGPoint.zero
    private var dragged = false       // an object was actually moved/resized (a plain click must not add an undo step)
    private var lastSize = CGSize.zero
    private var draft: Obj? { didSet { needsDisplay = true } }
    private var lasso: [CGPoint] = []

    init(doc: Document, opt: Options) {
        self.doc = doc; self.opt = opt
        super.init(frame: .zero)
        doc.onChange = { [weak self] in self?.updateFrame() }
        updateFrame()
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateFrame() {
        let s = doc.state.image.size
        if s != lastSize { lastSize = s; marquee = nil }   // a pixel selection is meaningless once the canvas geometry changed
        setFrameSize(NSSize(width: s.width * zoom + 2 * margin, height: s.height * zoom + 2 * margin))
        needsDisplay = true
    }
    func fit(in v: NSSize) {
        let s = doc.state.image.size
        zoom = max(0.05, min(1, (v.width - 2 * margin) / s.width, (v.height - 2 * margin) / s.height))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .select ? .arrow : .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: drawing
    var selectedObj: Obj? { doc.state.objects.first { $0.id == selected } }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.32, alpha: 1).setFill(); dirty.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = doc.state, full = s.image.full
        ctx.saveGState()
        ctx.translateBy(x: margin, y: margin); ctx.scaleBy(x: zoom, y: zoom)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8)
        NSColor.white.setFill(); full.fill()
        ctx.restoreGState()
        NSGraphicsContext.current?.imageInterpolation = zoom < 1 ? .high : .none
        s.image.drawFlipped(in: full, op: .copy)
        ctx.saveGState(); ctx.clip(to: full)
        for o in s.objects { Painter.draw(o, base: s.image) }
        if let d = draft { Painter.draw(d, base: s.image) }
        if lasso.count > 1 {
            ctx.setLineDash(phase: 0, lengths: [5 / zoom, 4 / zoom]); ctx.setLineWidth(1.5 / zoom)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.addPath(Raster.strokePath(lasso)); ctx.strokePath()
        }
        ctx.restoreGState()
        if let m = (tool == .marquee ? draft?.rect : nil) ?? marquee {
            ctx.setLineWidth(1 / zoom)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineDash(phase: 0, lengths: [])
            ctx.stroke(m)
            ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineDash(phase: 0, lengths: [5 / zoom, 5 / zoom]); ctx.stroke(m)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if tool == .select, let o = selectedObj {
            ctx.setLineWidth(1 / zoom); ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom]); ctx.stroke(o.bounds); ctx.setLineDash(phase: 0, lengths: [])
            let hs = 8 / zoom
            for p in handles(o) {
                let r = CGRect(x: p.x - hs / 2, y: p.y - hs / 2, width: hs, height: hs)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r); ctx.stroke(r)
            }
        }
        ctx.restoreGState()
    }

    // MARK: geometry helpers
    func handles(_ o: Obj) -> [CGPoint] {
        if (o.kind == .line || o.kind == .arrow), o.points.count >= 2 { return Array(o.points.prefix(2)) }
        let r = o.rawBounds
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }
    func hit(_ o: Obj, _ p: CGPoint) -> Bool {
        let tol = 6 / zoom
        guard !o.points.isEmpty else { return o.bounds.insetBy(dx: -tol, dy: -tol).contains(p) }
        let pts = o.points
        for i in 0..<max(1, pts.count - 1) {
            let a = pts[i], b = pts[min(i + 1, pts.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
            let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
            if hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)) <= o.width * 1.5 + tol { return true }
        }
        return false
    }
    func ip(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: (p.x - margin) / zoom, y: (p.y - margin) / zoom)
    }
    func newObj(_ k: Tool) -> Obj {
        Obj(kind: k, color: opt.color, fill: opt.useFill ? opt.fill : nil, width: opt.width, fontSize: opt.fontSize, symbol: opt.symbol)
    }
    func add(_ o: Obj, _ name: String) { doc.commit(name) { $0.objects.append(o) } }
    func promptText(_ initial: String) -> String? {
        guard let r = ask("Text", [("Text", initial)]), !r[0].isEmpty else { return nil }
        return r[0]
    }

    // MARK: mouse
    override func mouseMoved(with e: NSEvent) {
        let p = ip(e); onStatus?("x:\(Int(p.x)) y:\(Int(p.y))")
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = ip(e); last = p; startState = nil; drag = .none; dragged = false
        switch tool {
        case .select:
            if let s = selectedObj, let i = handles(s).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 7 / zoom }) {
                startState = doc.state; drag = .resize(i)
            } else if let o = doc.state.objects.last(where: { hit($0, p) }) {
                selected = o.id
                if e.clickCount == 2 { edit(o) }
                startState = doc.state; drag = .move
            } else { selected = nil }
        case .fill:
            doc.filterBase("Fill") { Raster.flood($0, at: p, color: opt.color) }
        case .text:
            guard let t = promptText("") else { return }
            var o = newObj(.text); o.text = t; o.rect = CGRect(origin: p, size: Painter.textSize(o)); add(o, "Text")
        case .number:
            var o = newObj(.number)
            o.number = (doc.state.objects.filter { $0.kind == .number }.map { $0.number }.max() ?? 0) + 1
            o.rect = CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32); add(o, "Number")
        case .cursor:
            var o = newObj(.cursor); o.rect = CGRect(x: p.x, y: p.y, width: 24, height: 32); add(o, "Cursor Stamp")
        case .symbol:
            var o = newObj(.symbol); o.rect = CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48); add(o, "Symbol")
        case .freehand: lasso = [p]
        case .rect, .ellipse, .rounded, .callout, .mosaic, .blur, .marquee, .crop:
            drag = .create(p); draft = newObj(tool)
            draft?.rect = CGRect(origin: p, size: .zero)
            if tool == .mosaic || tool == .blur { draft?.number = opt.block }
        case .line, .arrow:
            drag = .create(p); draft = newObj(tool); draft?.points = [p, p]
        default: // stroke tools
            drag = .create(p); draft = newObj(tool); draft?.points = [p]
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = ip(e)
        onStatus?("x:\(Int(p.x)) y:\(Int(p.y))")
        if tool == .freehand { lasso.append(p); needsDisplay = true; return }
        switch drag {
        case .none: break
        case .create(let s):
            guard draft != nil else { return }
            if tool == .line || tool == .arrow { draft!.points = [s, p] }
            else if tool.isStroke { draft!.points.append(p) }
            else { draft!.rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)) }
        case .move:
            guard let i = doc.state.objects.firstIndex(where: { $0.id == selected }) else { return }
            doc.state.objects[i].move(p.x - last.x, p.y - last.y); last = p; dragged = true
        case .resize(let h):
            guard let i = doc.state.objects.firstIndex(where: { $0.id == selected }) else { return }
            var o = doc.state.objects[i]
            if (o.kind == .line || o.kind == .arrow), o.points.count >= 2 { o.points[h] = p }
            else {
                let r = o.rawBounds
                var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
                if [0, 6, 7].contains(h) { x0 = p.x }
                if [2, 3, 4].contains(h) { x1 = p.x }
                if [0, 1, 2].contains(h) { y0 = p.y }
                if [4, 5, 6].contains(h) { y1 = p.y }
                o.resize(to: CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)))
            }
            doc.state.objects[i] = o; dragged = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = .none; startState = nil }
        if tool == .freehand {
            let pts = lasso; lasso = []
            if pts.count > 2 {
                let r = CGRect(x: pts.map { $0.x }.min()!, y: pts.map { $0.y }.min()!, width: 0, height: 0)
                    .union(CGRect(x: pts.map { $0.x }.max()!, y: pts.map { $0.y }.max()!, width: 0, height: 0))
                doc.flattenOp("Freehand Crop") { Raster.crop($0, r, mask: pts) }
            }
            needsDisplay = true; return
        }
        switch drag {
        case .move, .resize:
            if dragged, let s = startState { doc.register(s, "Edit Object") }
        case .create:
            guard var o = draft else { return }
            draft = nil
            let tiny: Bool
            if o.kind == .line || o.kind == .arrow { tiny = hypot(o.points[1].x - o.points[0].x, o.points[1].y - o.points[0].y) < 3 }
            else if o.kind.isStroke { tiny = false }
            else { tiny = o.rect.width < 3 || o.rect.height < 3 }
            if o.kind == .marquee { marquee = tiny ? nil : o.rect.intersection(doc.state.image.full); return }
            if tiny { return }
            switch o.kind {
            case .crop: doc.flattenOp("Crop") { Raster.crop($0, o.rect) }
            case .eraser: doc.filterBase("Eraser") { Raster.erase($0, o.points, o.width * 3) }
            case .retouch: doc.filterBase("Retouch") { Raster.retouch($0, o.points, o.width * 3) }
            case .callout:
                guard let t = promptText("") else { return }
                o.text = t; add(o, "Callout")
            default: add(o, o.kind.label)
            }
        case .none: break
        }
    }

    func edit(_ o: Obj) {
        guard o.kind == .text || o.kind == .callout, let t = promptText(o.text) else { return }
        doc.commit("Edit Text") { s in
            guard let i = s.objects.firstIndex(where: { $0.id == o.id }) else { return }
            s.objects[i].text = t
            if o.kind == .text { s.objects[i].rect.size = Painter.textSize(s.objects[i]) }
        }
    }

    // MARK: object ops
    func deleteSelected() {
        guard let id = selected else { return }
        doc.commit("Delete") { $0.objects.removeAll { $0.id == id } }
        selected = nil
    }
    /// 0 front, 1 back, 2 forward, 3 backward
    func reorder(_ how: Int) {
        guard let id = selected else { return }
        doc.commit("Arrange") { s in
            guard let i = s.objects.firstIndex(where: { $0.id == id }) else { return }
            let o = s.objects.remove(at: i)
            let n = s.objects.count
            let j = [0: n, 1: 0, 2: min(n, i + 1), 3: max(0, i - 1)][how]!
            s.objects.insert(o, at: j)
        }
    }
    func restyle() {
        guard let id = selected else { return }
        doc.commit("Style") { s in
            guard let i = s.objects.firstIndex(where: { $0.id == id }) else { return }
            s.objects[i].color = opt.color; s.objects[i].width = opt.width; s.objects[i].fontSize = opt.fontSize
            s.objects[i].fill = opt.useFill ? opt.fill : nil
            if s.objects[i].kind == .text { s.objects[i].rect.size = Painter.textSize(s.objects[i]) }
        }
    }

    override func keyDown(with e: NSEvent) {
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch e.keyCode {
        case 51, 117: deleteSelected()
        case 53: selected = nil; marquee = nil
        case 123, 124, 125, 126:
            guard let id = selected else { return }
            let dx: CGFloat = e.keyCode == 123 ? -step : e.keyCode == 124 ? step : 0
            let dy: CGFloat = e.keyCode == 125 ? step : e.keyCode == 126 ? -step : 0
            doc.commit("Nudge") { s in
                if let i = s.objects.firstIndex(where: { $0.id == id }) { s.objects[i].move(dx, dy) }
            }
        default: super.keyDown(with: e)
        }
    }
}
