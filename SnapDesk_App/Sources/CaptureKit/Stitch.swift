import CoreGraphics

/// Frame-overlap stitching for scrolling capture.
enum Stitch {
    static func gray(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height)
        buf.withUnsafeMutableBytes {
            let c = CGContext(data: $0.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            c?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return buf
    }

    /// Pixels the content moved up between frames a -> b. 0 = unchanged, nil = no confident match.
    /// ponytail: matches one band from the middle of b (ignores fixed headers); fixed footers get duplicated, repeated content can mis-match.
    static func shift(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int) -> Int? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var total = 0, n = 0
        for i in stride(from: 0, to: a.count, by: 7) { total += abs(Int(a[i]) - Int(b[i])); n += 1 }
        if total < n / 2 { return 0 }
        let band = max(16, h / 8), s = h / 2 - band / 2, maxD = h - s - band
        guard maxD >= 1 else { return nil }
        var best = Int.max, bestD = 0
        for d in 1...maxD {
            var e = 0
            rows: for i in stride(from: 0, to: band, by: 2) {
                let ra = (s + d + i) * w, rb = (s + i) * w
                for x in stride(from: 0, to: w, by: 4) { e += abs(Int(a[ra + x]) - Int(b[rb + x])) }
                if e > best { break rows }
            }
            if e < best { best = e; bestD = d }
        }
        let samples = ((band + 1) / 2) * ((w + 3) / 4)
        guard best / max(samples, 1) <= 4 else { return nil }
        // The coarse search samples every 2nd row / 4th column, so on sparse content (text on white) an off-by-one-pixel
        // shift scores almost as well as the true one. Re-score the neighbours at full resolution and take the best.
        func full(_ d: Int) -> Int {
            var e = 0
            for i in 0..<band { let ra = (s + d + i) * w, rb = (s + i) * w; for x in 0..<w { e += abs(Int(a[ra + x]) - Int(b[rb + x])) } }
            return e
        }
        var refined = bestD, refinedErr = full(bestD)
        for d in max(1, bestD - 2)...min(maxD, bestD + 2) where d != bestD { let e = full(d); if e < refinedErr { refinedErr = e; refined = d } }
        return refined
    }

    /// Bottom `d` rows of a frame: the newly revealed content after scrolling `d` pixels.
    static func tail(_ img: CGImage, _ d: Int) -> CGImage? {
        img.cropping(to: CGRect(x: 0, y: img.height - d, width: img.width, height: d))
    }

    static func assemble(_ pieces: [CGImage]) -> CGImage? {
        guard let w = pieces.first?.width else { return nil }
        let total = pieces.reduce(0) { $0 + $1.height }
        guard let c = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for p in pieces { y -= p.height; c.draw(p, in: CGRect(x: 0, y: y, width: w, height: p.height)) }
        return c.makeImage()
    }
}
