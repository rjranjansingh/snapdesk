import AppKit

/// Shared contract between all kits. Owned by the integrator; kit agents must not edit this file.
public enum CaptureMode: String, CaseIterable, Sendable {
    case fullScreen, activeWindow, windowControl, scrollingWindow, fixedRegion, region, freehand, repeatLast
}

public enum DesignTool: String, CaseIterable, Sendable {
    case colorPicker, colorPalette, pixelRuler, magnifier, crosshair, protractor, whiteboard
}

public enum ImageFormat: String, CaseIterable, Sendable { case png, jpeg, bmp, gif, tiff, pdf }

public final class Preferences: @unchecked Sendable {
    public static let shared = Preferences()
    private let d: UserDefaults
    public var saveFolder: URL {
        get { d.url(forKey: "saveFolder") ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SnapDesk") }
        set { d.set(newValue, forKey: "saveFolder") }
    }
    public var format: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "format") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "format") }
    }
    public var jpegQuality: Double { get { d.object(forKey: "jpegQuality") as? Double ?? 0.9 } set { d.set(newValue, forKey: "jpegQuality") } }
    public var includeCursor: Bool { get { d.bool(forKey: "includeCursor") } set { d.set(newValue, forKey: "includeCursor") } }
    public var captureDelay: Double { get { d.double(forKey: "captureDelay") } set { d.set(newValue, forKey: "captureDelay") } }
    public var autoSave: Bool { get { d.bool(forKey: "autoSave") } set { d.set(newValue, forKey: "autoSave") } }
    public var copyToClipboard: Bool { get { d.bool(forKey: "copyToClipboard") } set { d.set(newValue, forKey: "copyToClipboard") } }
    public var openEditorAfterCapture: Bool { get { d.object(forKey: "openEditor") as? Bool ?? true } set { d.set(newValue, forKey: "openEditor") } }
    public var fileNamePattern: String { get { d.string(forKey: "fileNamePattern") ?? "SnapDesk_yyyy-MM-dd_HH-mm-ss" } set { d.set(newValue, forKey: "fileNamePattern") } }
    public var fixedRegionSize: CGSize {
        get { CGSize(width: d.object(forKey: "frW") as? Double ?? 800, height: d.object(forKey: "frH") as? Double ?? 600) }
        set { d.set(newValue.width, forKey: "frW"); d.set(newValue.height, forKey: "frH") }
    }
    public init(defaults: UserDefaults = .standard) { d = defaults }
}

public enum ImageOutput {
    public static func data(_ image: NSImage, format: ImageFormat, quality: Double = 0.9) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case .bmp: return rep.representation(using: .bmp, properties: [:])
        case .gif: return rep.representation(using: .gif, properties: [:])
        case .tiff: return tiff
        case .pdf:
            let v = NSImageView(frame: NSRect(origin: .zero, size: image.size)); v.image = image
            return v.dataWithPDF(inside: v.bounds)
        }
    }
    public static func ext(_ f: ImageFormat) -> String { f == .jpeg ? "jpg" : f.rawValue }
    /// Saves to the preferences folder using the filename pattern; returns the file URL.
    @discardableResult
    public static func autoSave(_ image: NSImage, prefs: Preferences = .shared) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = prefs.fileNamePattern
        let base = df.string(from: Date()), e = ext(prefs.format)
        var url = prefs.saveFolder.appendingPathComponent(base).appendingPathExtension(e)
        var n = 1   // two captures in the same second must not overwrite each other
        while fm.fileExists(atPath: url.path) { n += 1; url = prefs.saveFolder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(e) }
        guard let d = data(image, format: prefs.format, quality: prefs.jpegQuality) else { return nil }
        return (try? d.write(to: url)) != nil ? url : nil
    }
    public static func copyToClipboard(_ image: NSImage) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
    }
}
