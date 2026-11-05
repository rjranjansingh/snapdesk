import AppKit

enum Tool: String, CaseIterable {
    case select, text, arrow, line, rect, ellipse, rounded, callout, number, cursor, symbol
    case pencil, brush, marker, airbrush, calligraphy, highlighter
    case marquee, blur, mosaic, freehand, crop, fill, eraser, retouch

    var sym: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .rounded: return "app"
        case .callout: return "bubble.left"
        case .number: return "1.circle.fill"
        case .cursor: return "cursorarrow.click"
        case .symbol: return "star"
        case .pencil: return "pencil"
        case .brush: return "paintbrush"
        case .marker: return "paintbrush.pointed"
        case .airbrush: return "sparkles"
        case .calligraphy: return "signature"
        case .highlighter: return "highlighter"
        case .marquee: return "rectangle.dashed"
        case .blur: return "aqi.medium"
        case .mosaic: return "square.grid.3x3.fill"
        case .freehand: return "lasso"
        case .crop: return "crop"
        case .fill: return "drop.fill"
        case .eraser: return "eraser"
        case .retouch: return "wand.and.stars"
        }
    }
    var label: String {
        switch self {
        case .marquee: return "Select Area"
        case .rect: return "Rectangle"
        case .blur: return "Blur Region"
        case .mosaic: return "Mosaic Region"
        case .callout: return "Speech Bubble"
        case .number: return "Numbered Stamp"
        case .cursor: return "Cursor Stamp"
        case .symbol: return "Symbol Icon"
        case .freehand: return "Freehand Selection"
        case .fill: return "Fill Bucket"
        case .retouch: return "Retouch (Blur Brush)"
        case .rounded: return "Rounded Rectangle"
        default: return rawValue.capitalized
        }
    }
    var isStroke: Bool { [.pencil, .brush, .marker, .airbrush, .calligraphy, .highlighter, .eraser, .retouch].contains(self) }
}

/// Vector annotation (value type so undo snapshots are cheap).
struct Obj {
    var id = UUID()
    var kind: Tool
    var rect = CGRect.zero
    var points: [CGPoint] = []
    var color: NSColor = .systemRed
    var fill: NSColor?
    var width: CGFloat = 3
    var text = ""
    var fontSize: CGFloat = 18
    var number = 1          // stamp number, or mosaic block size
    var symbol = "star.fill"

    var rawBounds: CGRect {
        guard let f = points.first else { return rect }
        var x0 = f.x, x1 = f.x, y0 = f.y, y1 = f.y
        for p in points { x0 = min(x0, p.x); x1 = max(x1, p.x); y0 = min(y0, p.y); y1 = max(y1, p.y) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    var bounds: CGRect {
        var r = rawBounds
        if !points.isEmpty { r = r.insetBy(dx: -width * 2, dy: -width * 2) }
        if kind == .callout { r.size.height += 24 }
        return r
    }
    mutating func move(_ dx: CGFloat, _ dy: CGFloat) {
        rect.origin.x += dx; rect.origin.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
    mutating func resize(to n: CGRect) {
        guard !points.isEmpty else { rect = n; return }
        let o = rawBounds
        points = points.map {
            CGPoint(x: n.minX + (o.width == 0 ? 0 : ($0.x - o.minX) / o.width * n.width),
                    y: n.minY + (o.height == 0 ? 0 : ($0.y - o.minY) / o.height * n.height))
        }
    }
}

final class Options {
    var color = NSColor.systemRed
    var fill = NSColor.systemYellow
    var useFill = false
    var width: CGFloat = 3
    var fontSize: CGFloat = 18
    var symbol = "star.fill"
    var block = 10
}

/// Document = base raster + vector objects, with snapshot-based undo.
final class Document {
    struct State { var image: NSImage; var objects: [Obj] }
    var state: State { didSet { onChange?() } }
    let undo = UndoManager()
    var onChange: (() -> Void)?
    init(image: NSImage) { state = State(image: Raster.normalized(image), objects: []) }

    func commit(_ name: String, _ f: (inout State) -> Void) {
        let old = state
        f(&state)
        register(old, name)
    }
    func register(_ old: State, _ name: String) {
        undo.registerUndo(withTarget: self) { d in
            let cur = d.state
            d.state = old
            d.register(cur, name)
        }
        undo.setActionName(name)
    }
    /// Effects applied to the base image only (objects stay crisp).
    func filterBase(_ name: String, _ f: (NSImage) -> NSImage) { commit(name) { $0.image = f($0.image) } }
    /// Same, but limited to `region` (image pixels, top-left origin) when given; the rest of the image is untouched.
    func filterBase(_ name: String, region: CGRect?, _ f: (NSImage) -> NSImage) {
        guard let region else { return filterBase(name, f) }
        commit(name) { $0.image = Raster.applyInRegion($0.image, region, f) }
    }
    /// Geometry ops: objects are flattened into the image first.
    func flattenOp(_ name: String, _ f: (NSImage) -> NSImage) {
        commit(name) { s in s.image = f(Painter.flatten(s)); s.objects = [] }
    }
}
