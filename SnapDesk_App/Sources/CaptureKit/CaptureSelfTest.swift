import CoreGraphics
import SnapCore

private func chk(_ n: String, _ ok: Bool, _ d: @autoclosure () -> String = "") { SelfTest.check("capture/" + n, ok, d()) }

/// Scrolling-capture stitching with synthetic frames (screen capture itself cannot run headlessly).
public func captureKitSelfTest() {
    let w = 200, h = 400, pageH = 1400
    var seed: UInt32 = 99
    func rnd() -> UInt8 { seed = seed &* 1664525 &+ 1013904223; return UInt8(truncatingIfNeeded: seed >> 16) }
    func img(_ rows: [[UInt8]]) -> CGImage {
        var buf = [UInt8](); buf.reserveCapacity(rows.count * w * 4)
        for r in rows { for v in r { buf += [v, v, v, 255] } }
        let ctx = buf.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: rows.count, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)! }
        return ctx.makeImage()!
    }
    func frame(_ page: [[UInt8]], _ off: Int, header: Int = 0) -> CGImage {
        var rows = Array(page[off..<off + h]); for i in 0..<header { rows[i] = page[i] }; return img(rows)   // header rows stay fixed (sticky header)
    }
    // pages: noise (ideal), "text" (sparse lines on white), with a blank gap
    let noise = (0..<pageH).map { _ in (0..<w).map { _ in rnd() } }
    let text: [[UInt8]] = (0..<pageH).map { y in
        let line = y % 23 < 6 && (y / 23) % 5 != 3                     // text lines, every 5th line missing
        var hsh = UInt32(truncatingIfNeeded: (y / 23) &* 2654435761); hsh ^= hsh >> 15
        let len = 40 + Int(hsh % 150)                                    // irregular line lengths (a perfectly periodic page is ambiguous by nature)
        return (0..<w).map { x in line && x > 10 && x < 10 + len && (x / 3 + y / 23) % 2 == 0 ? 20 : 250 }
    }
    func readGray(_ im: CGImage) -> [UInt8] { Stitch.gray(im) }

    // shift(): known offsets
    for (nm, page) in [("noise", noise), ("text", text)] {
        for d in [5, 50, 133, 175] {
            let a = readGray(frame(page, 100)), b = readGray(frame(page, 100 + d))
            let got = Stitch.shift(a, b, w: w, h: h)
            chk("shift/\(nm)/offset-\(d)", got == d, "got \(String(describing: got))")
        }
    }
    let f0 = readGray(frame(noise, 0))
    chk("shift/identical-frames-are-0", Stitch.shift(f0, f0, w: w, h: h) == 0)
    chk("shift/unrelated-frames-are-nil", Stitch.shift(f0, readGray(frame(noise, 700)), w: w, h: h) == nil)
    chk("shift/size-mismatch-nil", Stitch.shift([1, 2, 3], [1, 2], w: 1, h: 1) == nil && Stitch.shift([], [], w: 0, h: 0) == nil)
    let hd = readGray(frame(noise, 0, header: 40)), hd2 = readGray(frame(noise, 133, header: 40))
    chk("shift/sticky-header-ignored", Stitch.shift(hd, hd2, w: w, h: h) == 133, "got \(String(describing: Stitch.shift(hd, hd2, w: w, h: h)))")
    chk("shift/just-over-max-offset-is-not-trusted", { let g = Stitch.shift(readGray(frame(noise, 100)), readGray(frame(noise, 100 + 260)), w: w, h: h); return g == nil || g! != 1 }())

    // full pipeline exactly as CaptureManager.scroll does it
    for (nm, page) in [("noise", noise), ("text", text)] {
        let step = 133, offs = [0, 133, 266, 399, 532, 665]
        var pieces = [frame(page, 0)], prev = readGray(pieces[0]), ok = true, why = ""
        for o in offs.dropFirst() {
            let im = frame(page, o), g = readGray(im)
            guard let d = Stitch.shift(prev, g, w: w, h: h), d > 0 else { ok = false; why = "shift nil/0 at \(o)"; break }
            if d != step { ok = false; why = "d=\(d) at \(o)" }
            if let p = Stitch.tail(im, d) { pieces.append(p) }
            prev = g
        }
        let out = Stitch.assemble(pieces)
        let want = h + step * (offs.count - 1)
        chk("assemble/\(nm)/height", out?.height == want && out?.width == w, "\(String(describing: out?.height)) want \(want) \(why)")
        if let out, out.height == want {
            let got = readGray(out); var bad = 0
            for y in 0..<want { for x in 0..<w where got[y * w + x] != page[y][x] { bad += 1 } }
            chk("assemble/\(nm)/pixel-exact-vs-page", bad == 0 && ok, "\(bad) px differ \(why)")
        } else { chk("assemble/\(nm)/pixel-exact-vs-page", false, why) }
    }
    chk("assemble/empty-is-nil", Stitch.assemble([]) == nil)
}
