import AppKit

enum Painter {
    static func attrs(_ o: Obj, _ c: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: o.fontSize, weight: .medium), .foregroundColor: c ?? o.color]
    }
    static func textSize(_ o: Obj) -> CGSize {
        let s = (o.text as NSString).boundingRect(with: CGSize(width: 600, height: 10000),
                                                  options: [.usesLineFragmentOrigin], attributes: attrs(o)).size
        return CGSize(width: ceil(s.width) + 8, height: ceil(s.height) + 8)
    }

    static func flatten(_ s: Document.State) -> NSImage {
        makeImage(s.image.size) {
            s.image.drawFlipped(in: s.image.full, op: .copy)
            for o in s.objects { draw(o, base: s.image) }
        }
    }

    static func draw(_ o: Obj, base: NSImage) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(o.color.cgColor); ctx.setFillColor(o.color.cgColor)
        ctx.setLineWidth(o.width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let r = o.rect
        func stroke(width: CGFloat, alpha: CGFloat = 1, cap: CGLineCap = .round) {
            ctx.setStrokeColor(o.color.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(width); ctx.setLineCap(cap)
            ctx.addPath(Raster.strokePath(o.points)); ctx.strokePath()
        }
        switch o.kind {
        case .rect, .ellipse, .rounded:
            let rad = o.kind == .rounded ? min(16, r.width / 2, r.height / 2) : 0
            let path: CGPath = o.kind == .ellipse ? CGPath(ellipseIn: r, transform: nil)
                : CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
            if let f = o.fill { ctx.setFillColor(f.cgColor); ctx.addPath(path); ctx.fillPath() }
            if o.width > 0 { ctx.addPath(path); ctx.strokePath() }
        case .line, .arrow:
            guard o.points.count >= 2 else { return }
            let a = o.points[0], b = o.points[1]
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            if o.kind == .arrow {
                let ang = atan2(b.y - a.y, b.x - a.x), len = max(12, o.width * 4)
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - len * cos(ang - .pi / 7), y: b.y - len * sin(ang - .pi / 7)))
                ctx.addLine(to: CGPoint(x: b.x - len * cos(ang + .pi / 7), y: b.y - len * sin(ang + .pi / 7)))
                ctx.closePath(); ctx.fillPath()
            }
        case .callout:
            let fc = (o.fill ?? .white).cgColor
            let bub = CGPath(roundedRect: r, cornerWidth: min(12, r.width / 2, r.height / 2), cornerHeight: min(12, r.width / 2, r.height / 2), transform: nil)
            ctx.setFillColor(fc); ctx.addPath(bub); ctx.fillPath(); ctx.addPath(bub); ctx.strokePath()
            let a = CGPoint(x: r.minX + r.width * 0.2, y: r.maxY), b = CGPoint(x: a.x + 18, y: r.maxY)
            let tip = CGPoint(x: r.minX + r.width * 0.1, y: r.maxY + 22)
            ctx.move(to: a); ctx.addLine(to: tip); ctx.addLine(to: b); ctx.closePath(); ctx.fillPath()
            ctx.move(to: a); ctx.addLine(to: tip); ctx.addLine(to: b); ctx.strokePath()
            ctx.setStrokeColor(fc); ctx.setLineWidth(o.width + 1); ctx.setLineCap(.butt)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            (o.text as NSString).draw(with: r.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin], attributes: attrs(o, .darkGray))
        case .text:
            if let f = o.fill { ctx.setFillColor(f.cgColor); ctx.fill(r) }
            (o.text as NSString).draw(with: r.insetBy(dx: 4, dy: 4), options: [.usesLineFragmentOrigin], attributes: attrs(o))
        case .number:
            ctx.setFillColor((o.fill ?? o.color).cgColor); ctx.fillEllipse(in: r)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: r.height * 0.55), .foregroundColor: NSColor.white]
            let s = ("\(o.number)" as NSString).size(withAttributes: a)
            ("\(o.number)" as NSString).draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: a)
        case .cursor:
            NSCursor.arrow.image.drawFlipped(in: r)
        case .symbol:
            if let i = NSImage(systemSymbolName: o.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [o.color])) {
                let s = i.size, k = min(r.width / s.width, r.height / s.height)
                i.drawFlipped(in: CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k))
            }
        case .pencil: stroke(width: max(1, o.width / 3))
        case .brush: stroke(width: o.width)
        case .marker: stroke(width: o.width * 3, alpha: 0.4, cap: .square)
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(o.color.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(o.width * 4); ctx.setLineCap(.butt)
            ctx.addPath(Raster.strokePath(o.points)); ctx.strokePath()
        case .eraser: stroke(width: o.width * 3)
        case .retouch: stroke(width: o.width * 3, alpha: 0.25)
        case .airbrush:
            let rad = o.width * 2.5
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [o.color.withAlphaComponent(0.14).cgColor, o.color.withAlphaComponent(0).cgColor] as CFArray,
                               locations: [0, 1])!
            func dot(_ p: CGPoint) { ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: rad, options: []) }
            if let f = o.points.first { dot(f) }
            for (a, b) in zip(o.points, o.points.dropFirst()) {
                let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 2))
                for i in 1...n { let t = CGFloat(i) / CGFloat(n); dot(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
            }
        case .calligraphy:
            let v = CGPoint(x: o.width * 0.7, y: -o.width * 0.7)
            for (a, b) in zip(o.points, o.points.dropFirst()) {
                ctx.move(to: CGPoint(x: a.x + v.x, y: a.y + v.y)); ctx.addLine(to: CGPoint(x: b.x + v.x, y: b.y + v.y))
                ctx.addLine(to: CGPoint(x: b.x - v.x, y: b.y - v.y)); ctx.addLine(to: CGPoint(x: a.x - v.x, y: a.y - v.y))
                ctx.closePath(); ctx.fillPath()
            }
        case .blur:
            let rr = r.intersection(base.full)
            guard !rr.isNull, rr.width >= 1, rr.height >= 1 else { return }
            let src = CGRect(x: rr.minX, y: base.size.height - rr.maxY, width: rr.width, height: rr.height)
            let crop = makeImage(rr.size) { base.drawFlipped(in: CGRect(origin: .zero, size: rr.size), from: src, op: .copy) }
            let rad = Double(max(2, o.number))
            let blurred = Raster.filter(crop) { img in
                let e = img.extent
                return img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: rad]).cropped(to: e)
            }
            ctx.clip(to: rr)
            blurred.drawFlipped(in: rr)
        case .mosaic:
            let rr = r.intersection(base.full)
            guard !rr.isNull, rr.width >= 1, rr.height >= 1 else { return }
            let b = CGFloat(max(2, o.number))
            let sw = max(1, ceil(rr.width / b)), sh = max(1, ceil(rr.height / b))
            let src = CGRect(x: rr.minX, y: base.size.height - rr.maxY, width: rr.width, height: rr.height)
            // exact 1:1 crop first, so the down-sampling filter cannot read pixels from outside the region
            let crop = makeImage(rr.size) { base.drawFlipped(in: CGRect(origin: .zero, size: rr.size), from: src, op: .copy) }
            let small = makeImage(CGSize(width: sw, height: sh)) {
                crop.drawFlipped(in: CGRect(x: 0, y: 0, width: sw, height: sh), op: .copy)
            }
            ctx.clip(to: rr)
            NSGraphicsContext.current?.imageInterpolation = .none
            small.drawFlipped(in: CGRect(x: rr.minX, y: rr.minY, width: sw * b, height: sh * b))
        case .crop:
            ctx.setLineDash(phase: 0, lengths: [6, 4]); ctx.setLineWidth(1.5); ctx.setStrokeColor(NSColor.black.cgColor); ctx.stroke(r)
            ctx.setLineDash(phase: 5, lengths: [6, 4]); ctx.setStrokeColor(NSColor.white.cgColor); ctx.stroke(r)
        case .select, .freehand, .fill, .marquee: break
        }
    }
}
