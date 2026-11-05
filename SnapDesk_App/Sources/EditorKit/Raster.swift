import AppKit
import CoreImage

extension NSImage {
    var cg: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

/// Renders into a top-left-origin (flipped) bitmap; pixel size == point size.
func makeImage(_ size: CGSize, _ draw: () -> Void) -> NSImage {
    let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return NSImage(cgImage: ctx.makeImage()!, size: CGSize(width: w, height: h))
}

extension NSImage {
    func drawFlipped(in r: CGRect, from: CGRect = .zero, op: NSCompositingOperation = .sourceOver) {
        draw(in: r, from: from, operation: op, fraction: 1, respectFlipped: true, hints: nil)
    }
    var full: CGRect { CGRect(origin: .zero, size: size) }
}

enum Raster {
    static let ci = CIContext()

    static func normalized(_ img: NSImage) -> NSImage {
        guard let c = img.cg else { return img }
        let s = CGSize(width: c.width, height: c.height)
        return makeImage(s) { img.drawFlipped(in: CGRect(origin: .zero, size: s), op: .copy) }
    }

    static func strokePath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let f = pts.first else { return p }
        p.move(to: f)
        if pts.count == 1 { p.addLine(to: CGPoint(x: f.x + 0.01, y: f.y)) }
        for q in pts.dropFirst() { p.addLine(to: q) }
        return p
    }

    // MARK: raster tools
    static func flood(_ img: NSImage, at p: CGPoint, color: NSColor, tol: Int = 24) -> NSImage {
        guard let cg = img.cg, let c = color.usingColorSpace(.sRGB) else { return img }
        let w = cg.width, h = cg.height
        guard p.x >= 0, p.y >= 0 else { return img }   // Int() truncates toward zero, so -0.5 would otherwise land on pixel 0
        let x0 = Int(p.x), y0 = Int(p.y)
        guard x0 >= 0, y0 >= 0, x0 < w, y0 < h,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return img }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let b = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let f: [UInt8] = [UInt8((c.redComponent * 255).rounded()), UInt8((c.greenComponent * 255).rounded()), UInt8((c.blueComponent * 255).rounded()), 255]
        let t = (0..<4).map { b[(y0 * w + x0) * 4 + $0] }
        if t == f { return img }
        func match(_ i: Int) -> Bool { (0..<4).allSatisfy { abs(Int(b[i * 4 + $0]) - Int(t[$0])) <= tol } }
        var seen = [Bool](repeating: false, count: w * h)
        var stack = [y0 * w + x0]
        while let i = stack.popLast() {
            if seen[i] || !match(i) { continue }
            seen[i] = true
            for k in 0..<4 { b[i * 4 + k] = f[k] }
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }
        guard let out = ctx.makeImage() else { return img }
        return NSImage(cgImage: out, size: CGSize(width: w, height: h))
    }

    static func erase(_ img: NSImage, _ pts: [CGPoint], _ w: CGFloat) -> NSImage {
        makeImage(img.size) {
            img.drawFlipped(in: img.full, op: .copy)
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(strokePath(pts)); ctx.strokePath()
        }
    }

    static func retouch(_ img: NSImage, _ pts: [CGPoint], _ w: CGFloat) -> NSImage {
        let blurred = filter(img) { $0.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0]) }
        return makeImage(img.size) {
            img.drawFlipped(in: img.full, op: .copy)
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.addPath(strokePath(pts).copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1))
            ctx.clip()
            blurred.drawFlipped(in: img.full)
        }
    }

    // MARK: geometry
    static func crop(_ img: NSImage, _ r: CGRect, mask: [CGPoint]? = nil) -> NSImage {
        let r = r.intersection(img.full).integral
        guard r.width >= 1, r.height >= 1 else { return img }
        return makeImage(r.size) {
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: -r.minX, y: -r.minY)
            if let m = mask, m.count > 2 { let p = CGMutablePath(); p.addLines(between: m); p.closeSubpath(); ctx.addPath(p); ctx.clip() }
            img.drawFlipped(in: img.full)
        }
    }
    static func resizeImage(_ img: NSImage, _ s: CGSize) -> NSImage {
        makeImage(s) {
            NSGraphicsContext.current?.imageInterpolation = .high
            img.drawFlipped(in: CGRect(origin: .zero, size: s), op: .copy)
        }
    }
    static func resizeCanvas(_ img: NSImage, _ s: CGSize, bg: NSColor = .white) -> NSImage {
        makeImage(s) { bg.setFill(); CGRect(origin: .zero, size: s).fill(); img.drawFlipped(in: img.full) }
    }
    static func rotate(_ img: NSImage, clockwise: Bool) -> NSImage {
        let w = img.size.width, h = img.size.height
        return makeImage(CGSize(width: h, height: w)) {
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: h / 2, y: w / 2); ctx.rotate(by: clockwise ? .pi / 2 : -.pi / 2); ctx.translateBy(x: -w / 2, y: -h / 2)
            img.drawFlipped(in: img.full)
        }
    }
    static func flip(_ img: NSImage, horizontal: Bool) -> NSImage {
        makeImage(img.size) {
            let ctx = NSGraphicsContext.current!.cgContext
            if horizontal { ctx.translateBy(x: img.size.width, y: 0); ctx.scaleBy(x: -1, y: 1) }
            else { ctx.translateBy(x: 0, y: img.size.height); ctx.scaleBy(x: 1, y: -1) }
            img.drawFlipped(in: img.full)
        }
    }
    static func frame(_ img: NSImage, width b: CGFloat, color: NSColor) -> NSImage {
        let s = CGSize(width: img.size.width + 2 * b, height: img.size.height + 2 * b)
        return makeImage(s) { color.setFill(); CGRect(origin: .zero, size: s).fill(); img.drawFlipped(in: CGRect(origin: CGPoint(x: b, y: b), size: img.size)) }
    }
    static func shadow(_ img: NSImage, blur: CGFloat) -> NSImage {
        let pad = blur * 2 + 6
        let s = CGSize(width: img.size.width + 2 * pad, height: img.size.height + 2 * pad)
        return makeImage(s) {
            NSColor.white.setFill(); CGRect(origin: .zero, size: s).fill()
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setShadow(offset: CGSize(width: 5, height: -5), blur: blur, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            img.drawFlipped(in: CGRect(origin: CGPoint(x: pad - 3, y: pad - 3), size: img.size))
        }
    }
    static func watermark(_ img: NSImage, text: String) -> NSImage {
        makeImage(img.size) {
            img.drawFlipped(in: img.full, op: .copy)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: max(14, img.size.height / 20)),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
            let s = (text as NSString).size(withAttributes: a)
            (text as NSString).draw(at: CGPoint(x: img.size.width - s.width - 12, y: img.size.height - s.height - 10), withAttributes: a)
        }
    }

    // MARK: Core Image
    static func filter(_ img: NSImage, _ f: (CIImage) -> CIImage?) -> NSImage {
        guard let cg = img.cg else { return img }
        let src = CIImage(cgImage: cg)
        guard let out = f(src.clampedToExtent())?.cropped(to: src.extent),
              let res = ci.createCGImage(out, from: src.extent) else { return img }
        return NSImage(cgImage: res, size: img.size)
    }

    /// Runs `f` on just the cropped region (so edges clamp, no bleed from outside) and pastes the result back.
    static func applyInRegion(_ img: NSImage, _ region: CGRect, _ f: (NSImage) -> NSImage) -> NSImage {
        let r = region.intersection(img.full).integral
        guard r.width >= 1, r.height >= 1 else { return img }
        let piece = f(crop(img, r))
        return makeImage(img.size) {
            img.drawFlipped(in: img.full, op: .copy)
            piece.drawFlipped(in: r, op: .copy)
        }
    }
}
