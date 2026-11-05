import AppKit

/// Flat ribbon button: instant hover/press feedback via tracking areas (no system tooltip delay).
final class RibbonButton: NSView {
    private let small: Bool
    private let action: (NSView) -> Void
    var onHover: ((Bool) -> Void)?
    var toggles = false
    var help = ""
    private(set) var title = ""
    var isOn = false { didSet { refresh() } }
    private var hovering = false, pressed = false
    private let icon = NSImageView(), label = NSTextField(labelWithString: "")

    init(title: String, symbol: String, small: Bool, action: @escaping (NSView) -> Void) {
        self.small = small; self.action = action; self.title = title
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 6
        let cfg = NSImage.SymbolConfiguration(pointSize: small ? 14 : 20, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = .labelColor; icon.imageScaling = .scaleNone
        addSubview(icon)
        if !small {
            label.stringValue = title; label.font = .systemFont(ofSize: 10); label.alignment = .center
            label.lineBreakMode = .byTruncatingTail; label.textColor = .labelColor
            addSubview(label)
        }
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        if small { return NSSize(width: 28, height: 28) }
        let tw = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
        return NSSize(width: max(54, ceil(tw) + 6), height: 56)   // wide enough that the caption is never truncated
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        if small { icon.frame = bounds }
        else { icon.frame = NSRect(x: 0, y: 22, width: bounds.width, height: 30); label.frame = NSRect(x: 1, y: 4, width: bounds.width - 2, height: 14) }
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    private func refresh() {
        let c: NSColor = pressed ? NSColor.labelColor.withAlphaComponent(0.30)
            : isOn ? NSColor.controlAccentColor.withAlphaComponent(0.35)
            : hovering ? NSColor.labelColor.withAlphaComponent(0.20) : .clear
        layer?.backgroundColor = c.cgColor
        layer?.borderWidth = hovering ? 1 : 0
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
    }
    func setHover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on; if !on { pressed = false }
        refresh(); onHover?(on)
        if on { RibbonTip.shared.show(for: self, title: title, text: help) } else { RibbonTip.shared.hide() }
    }
    var isHovering: Bool { hovering }
    var hasIcon: Bool { icon.image != nil }
    var titleFits: Bool { small || label.intrinsicContentSize.width <= label.frame.width + 0.5 }
    /// Test hook: same as a user click.
    func click() { action(self) }
    override func mouseEntered(with e: NSEvent) { setHover(true) }
    override func mouseExited(with e: NSEvent) { setHover(false) }
    override func mouseDown(with e: NSEvent) { pressed = true; refresh(); RibbonTip.shared.hide() }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        pressed = false
        if inside { action(self) }
        refresh()
    }
}

/// Small floating description bubble shown ~instantly under a hovered ribbon button.
final class RibbonTip {
    static let shared = RibbonTip()
    let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.level = .popUpMenu; panel.isReleasedWhenClosed = false
        let fx = NSVisualEffectView(); fx.material = .toolTip; fx.state = .active; fx.wantsLayer = true
        fx.layer?.cornerRadius = 7; fx.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        textLabel.font = .systemFont(ofSize: 11); textLabel.textColor = .secondaryLabelColor
        textLabel.preferredMaxLayoutWidth = 230; textLabel.maximumNumberOfLines = 4
        let st = NSStackView(views: [titleLabel, textLabel]); st.orientation = .vertical; st.alignment = .leading; st.spacing = 2
        st.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 7, right: 9)
        st.translatesAutoresizingMaskIntoConstraints = false; fx.addSubview(st)
        NSLayoutConstraint.activate([st.leadingAnchor.constraint(equalTo: fx.leadingAnchor), st.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     st.topAnchor.constraint(equalTo: fx.topAnchor), st.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        panel.contentView = fx
    }

    var isVisible: Bool { panel.isVisible }
    var shownTitle: String { titleLabel.stringValue }
    var shownText: String { textLabel.stringValue }

    func show(for v: NSView, title: String, text: String, delay: TimeInterval = 0.08) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self, weak v] _ in
            guard let self, let v else { return }; self.present(v, title, text)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func present(_ v: NSView, _ title: String, _ text: String) {
        guard let win = v.window else { return }
        titleLabel.stringValue = title; textLabel.stringValue = text; textLabel.isHidden = text.isEmpty
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize
        let r = win.convertToScreen(v.convert(v.bounds, to: nil))
        var o = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 4)
        if let vis = (win.screen ?? NSScreen.main)?.visibleFrame {
            o.x = max(vis.minX + 4, min(o.x, vis.maxX - size.width - 4)); o.y = max(vis.minY + 4, o.y)
        }
        panel.setFrame(NSRect(origin: o, size: size), display: true)
        panel.orderFrontRegardless()
    }
    func hide() { timer?.invalidate(); timer = nil; panel.orderOut(nil) }
}
