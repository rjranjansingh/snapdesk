import AppKit
import AVFoundation
import ScreenCaptureKit
import SnapCore

public enum RecordingTarget { case fullScreen, window, region }

public struct RecordingOptions {
    public var target: RecordingTarget
    public var systemAudio: Bool
    public var microphone: Bool
    public var fps: Int
    public var quality: Double
    public var showCursor: Bool
    public init(target: RecordingTarget = .fullScreen, systemAudio: Bool = false, microphone: Bool = false,
                fps: Int = 30, quality: Double = 0.7, showCursor: Bool = true) {
        self.target = target; self.systemAudio = systemAudio; self.microphone = microphone
        self.fps = fps; self.quality = quality; self.showCursor = showCursor
    }
}

public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static let shared = ScreenRecorder()

    public private(set) var isRecording = false
    public var onStateChange: ((Bool) -> Void)?

    private let q = DispatchQueue(label: "recorderkit.samples")
    private var picking = false
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var vIn: AVAssetWriterInput?, sysIn: AVAssetWriterInput?, micIn: AVAssetWriterInput?
    private var sessionStarted = false
    private var startPTS = CMTime.invalid
    private var micSession: AVCaptureSession?
    private var outURL: URL?
    private var hud: HUD?
    private var overlays: [NSWindow] = []

    public func toggle(_ options: RecordingOptions) {
        if isRecording { stop(completion: nil) } else { start(options) }
    }

    // MARK: Start

    public func start(_ o: RecordingOptions) {
        guard !isRecording, !picking else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            alert("Screen recording permission needed",
                  "Enable this app in System Settings > Privacy & Security > Screen Recording, then try again.")
            return
        }
        switch o.target {
        case .fullScreen: begin(o, screen: NSScreen.main ?? NSScreen.screens[0], window: nil, rect: nil)
        case .region:
            picking = true
            Overlay.pickRegion { [weak self] screen, rect in
                self?.picking = false
                guard let screen, let rect else { return }
                self?.begin(o, screen: screen, window: nil, rect: rect)
            }
        case .window:
            picking = true
            Overlay.pickWindow { [weak self] id in
                self?.picking = false
                guard let id else { return }
                self?.begin(o, screen: NSScreen.main ?? NSScreen.screens[0], window: id, rect: nil)
            }
        }
    }

    private func begin(_ o: RecordingOptions, screen: NSScreen, window: CGWindowID?, rect: CGRect?) {
        Task { @MainActor in
            do {
                // Mic permission: degrade to no-mic rather than failing.
                var useMic = o.microphone
                if useMic, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    useMic = false
                    alert("Microphone access denied", "Recording continues without microphone. Enable it in System Settings > Privacy & Security > Microphone.")
                }
                let hud = HUD { [weak self] in self?.stop(completion: nil) }
                self.hud = hud
                hud.show()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let excluded = content.windows.filter { $0.windowID == CGWindowID(hud.windowNumber) }
                let scale = screen.backingScaleFactor
                let cfg = SCStreamConfiguration()
                let filter: SCContentFilter
                var size: CGSize
                if let window {
                    guard let w = content.windows.first(where: { $0.windowID == window }) else { throw RecErr.msg("Window not found") }
                    filter = SCContentFilter(desktopIndependentWindow: w)
                    size = CGSize(width: w.frame.width * scale, height: w.frame.height * scale)
                } else {
                    let did = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
                    guard let d = content.displays.first(where: { $0.displayID == did }) ?? content.displays.first else { throw RecErr.msg("No display") }
                    filter = SCContentFilter(display: d, excludingWindows: excluded)
                    size = CGSize(width: CGFloat(d.width) * scale, height: CGFloat(d.height) * scale)
                    if let r = rect { // Cocoa global -> display-local, top-left origin
                        let local = CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
                        cfg.sourceRect = local
                        size = CGSize(width: local.width * scale, height: local.height * scale)
                    }
                }
                let w = max(2, Int(size.width) & ~1), h = max(2, Int(size.height) & ~1)
                cfg.width = w; cfg.height = h
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, o.fps)))
                cfg.showsCursor = o.showCursor
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.queueDepth = 6
                cfg.capturesAudio = o.systemAudio
                cfg.sampleRate = 48000; cfg.channelCount = 2
                cfg.excludesCurrentProcessAudio = true

                try self.setupWriter(w: w, h: h, o: o, sys: o.systemAudio, mic: useMic)
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
                if o.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q) }
                if useMic { try self.startMic() }
                try await s.startCapture()
                self.stream = s
                self.isRecording = true
                self.onStateChange?(true)
            } catch {
                self.cleanup()
                self.alert("Could not start recording", "\(error.localizedDescription)")
            }
        }
    }

    private func setupWriter(w: Int, h: Int, o: RecordingOptions, sys: Bool, mic: Bool) throws {
        let fm = FileManager.default
        let dir = Preferences.shared.saveFolder
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "'Recording_'yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent(df.string(from: Date())).appendingPathExtension("mp4")
        let wr = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let q = min(1, max(0, o.quality))
        let bitrate = Int(Double(w * h * max(1, o.fps)) * (0.04 + 0.2 * q)) // ponytail: bits-per-pixel heuristic
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
        v.expectsMediaDataInRealTime = true
        wr.add(v)
        func audio(_ ch: Int) -> AVAssetWriterInput {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: ch, AVEncoderBitRateKey: 128_000])
            a.expectsMediaDataInRealTime = true
            wr.add(a); return a
        }
        sysIn = sys ? audio(2) : nil
        micIn = mic ? audio(1) : nil // second audio track
        vIn = v; writer = wr; outURL = url
        sessionStarted = false; startPTS = .invalid
        guard wr.startWriting() else { throw wr.error ?? RecErr.msg("Writer failed") }
    }

    private func startMic() throws {
        guard let dev = AVCaptureDevice.default(for: .audio) else { throw RecErr.msg("No microphone") }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: dev)
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: q)
        guard s.canAddInput(input), s.canAddOutput(out) else { throw RecErr.msg("Microphone unavailable") }
        s.addInput(input); s.addOutput(out)
        micSession = s
        s.startRunning()
    }

    // MARK: Samples (all on q)

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let wr = writer, wr.status == .writing, let v = vIn else { return }
            if !sessionStarted {
                startPTS = sb.presentationTimeStamp
                wr.startSession(atSourceTime: startPTS); sessionStarted = true
            }
            if v.isReadyForMoreMediaData { v.append(sb) }
        case .audio: appendAudio(sb, sysIn)
        default: break
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        appendAudio(sb, micIn)
    }

    private func appendAudio(_ sb: CMSampleBuffer, _ input: AVAssetWriterInput?) {
        guard sessionStarted, let input, input.isReadyForMoreMediaData, writer?.status == .writing,
              CMTimeCompare(sb.presentationTimeStamp, startPTS) >= 0 else { return }
        input.append(sb)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { if self.isRecording { self.stop(completion: nil) } }
    }

    // MARK: Stop

    public func stop(completion: ((URL?) -> Void)?) {
        guard isRecording else { completion?(nil); return }
        isRecording = false
        hud?.close(); hud = nil
        micSession?.stopRunning(); micSession = nil
        let s = stream; stream = nil
        Task { @MainActor in
            try? await s?.stopCapture()
            self.q.async {
                guard let wr = self.writer, let url = self.outURL else { DispatchQueue.main.async { completion?(nil) }; return }
                let ok = self.sessionStarted && wr.status == .writing
                self.vIn?.markAsFinished(); self.sysIn?.markAsFinished(); self.micIn?.markAsFinished()
                let done: () -> Void = {
                    DispatchQueue.main.async {
                        self.writer = nil; self.vIn = nil; self.sysIn = nil; self.micIn = nil
                        self.onStateChange?(false)
                        if ok && wr.status == .completed {
                            NSWorkspace.shared.activateFileViewerSelecting([url]); completion?(url)
                        } else { completion?(nil) }
                    }
                }
                if ok { wr.finishWriting(completionHandler: done) } else { wr.cancelWriting(); done() }
            }
        }
    }

    private func cleanup() {
        hud?.close(); hud = nil
        micSession?.stopRunning(); micSession = nil
        writer?.cancelWriting(); writer = nil
        if let u = outURL { try? FileManager.default.removeItem(at: u) }
    }

    private func alert(_ title: String, _ text: String) {
        DispatchQueue.main.async {
            let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
        }
    }
}

private enum RecErr: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

// MARK: HUD

private final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "● 00:00")
    private var timer: Timer?
    private let started = Date()
    private let onStop: () -> Void
    var windowNumber: Int { panel.windowNumber }

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isFloatingPanel = true
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.sharingType = .none // legacy exclusion; SCContentFilter also excludes it
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        label.textColor = .white; label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.frame = NSRect(x: 12, y: 9, width: 80, height: 18)
        let b = NSButton(title: "Stop", target: self, action: #selector(stop))
        b.frame = NSRect(x: 92, y: 5, width: 52, height: 26); b.bezelStyle = .rounded
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(b)
        if let f = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: f.maxX - 170, y: f.maxY - 56)) }
    }
    func show() {
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Int(Date().timeIntervalSince(self.started))
            self.label.stringValue = String(format: "● %02d:%02d", t / 60, t % 60)
        }
    }
    func close() { timer?.invalidate(); panel.orderOut(nil) }
    @objc private func stop() { onStop() }
}

// MARK: Overlays (region drag-select, window hover picker)

private final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

private final class PickView: NSView {
    let screen: NSScreen
    let windowMode: Bool
    let done: (NSScreen?, CGRect?, CGWindowID?) -> Void
    var dragStart: NSPoint?, current: NSRect = .zero   // view coords
    var hoverID: CGWindowID?

    init(screen: NSScreen, windowMode: Bool, done: @escaping (NSScreen?, CGRect?, CGWindowID?) -> Void) {
        self.screen = screen; self.windowMode = windowMode; self.done = done
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ r: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill()
        guard !current.isEmpty else { return }
        NSColor.clear.setFill(); current.fill(using: .copy)
        NSColor.systemBlue.setStroke()
        let p = NSBezierPath(rect: current); p.lineWidth = 2; p.stroke()
        if !windowMode {
            let s = "\(Int(current.width)) x \(Int(current.height))" as NSString
            s.draw(at: NSPoint(x: current.minX + 4, y: current.maxY + 4),
                   withAttributes: [.foregroundColor: NSColor.white, .backgroundColor: NSColor.black, .font: NSFont.systemFont(ofSize: 12)])
        }
    }

    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { done(nil, nil, nil) } }

    override func mouseMoved(with e: NSEvent) {
        guard windowMode else { return }
        let g = NSEvent.mouseLocation
        let cgY = (NSScreen.screens.first?.frame.height ?? 0) - g.y
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        hoverID = nil; current = .zero
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.contains(CGPoint(x: g.x, y: cgY)),
                  let n = w[kCGWindowNumber as String] as? UInt32 else { continue }
            hoverID = n
            // CG top-left global -> this view's coords
            current = NSRect(x: b.minX - screen.frame.minX,
                             y: (NSScreen.screens.first?.frame.height ?? 0) - b.maxY - screen.frame.minY,
                             width: b.width, height: b.height)
            break
        }
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        if windowMode { done(nil, nil, hoverID); return }
        dragStart = convert(e.locationInWindow, from: nil)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        current = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(s.x - p.x), height: abs(s.y - p.y))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard !windowMode else { return }
        guard current.width > 8, current.height > 8 else { done(nil, nil, nil); return }
        done(screen, current.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), nil)
    }
}

private enum Overlay {
    static var windows: [NSWindow] = []

    static func run(windowMode: Bool, _ finish: @escaping (NSScreen?, CGRect?, CGWindowID?) -> Void) {
        let closeAll = { windows.forEach { $0.orderOut(nil) }; windows = [] }
        for s in NSScreen.screens {
            let w = KeyWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: s)
            w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.acceptsMouseMovedEvents = true; w.isReleasedWhenClosed = false
            let v = PickView(screen: s, windowMode: windowMode) { scr, r, id in
                closeAll()
                DispatchQueue.main.async { finish(scr, r, id) }
            }
            w.contentView = v
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func pickRegion(_ cb: @escaping (NSScreen?, CGRect?) -> Void) {
        run(windowMode: false) { s, r, _ in cb(s, r) }
    }
    static func pickWindow(_ cb: @escaping (CGWindowID?) -> Void) {
        run(windowMode: true) { _, _, id in cb(id) }
    }
}
