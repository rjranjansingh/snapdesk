import AppKit
import Carbon.HIToolbox
import SnapCore
import CaptureKit
import EditorKit
import ToolsKit
import RecorderKit

/// Global hotkeys via Carbon (works without accessibility permission).
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var next: UInt32 = 1
    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeys.shared.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
    @discardableResult
    func register(_ key: Int, _ mods: Int, _ action: @escaping () -> Void) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x53444B31), id: next)
        handlers[next] = action; next += 1
        let st = RegisterEventHotKey(UInt32(key), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
        if st != noErr { NSLog("SnapDesk: hotkey keycode %d was not registered (OSStatus %d)", key, Int(st)); handlers[id.id] = nil }
        return st == noErr
    }
}

extension NSMenuItem { var isSectionHeaderLike: Bool { action == nil && submenu == nil && !isSeparatorItem && !title.isEmpty && !(image != nil) } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let prefs = Preferences.shared
    let rec = RecordingOptions()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapDesk")
        item.button?.title = " Snap"
        item.menu = buildMenu()
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        // ⌃⌥1..8 capture modes, ⌃⌥R record, ⌃⌥C colour picker (registered before the modal welcome alert so they work even while it is open)
        for (i, m) in CaptureMode.allCases.enumerated() {
            HotKeys.shared.register(Self.captureKeys[i], Self.hotkeyMods) { [weak self] in self?.capture(m) }
        }
        HotKeys.shared.register(kVK_ANSI_R, Self.hotkeyMods) { [weak self] in self?.toggleRecord() }
        HotKeys.shared.register(kVK_ANSI_C, Self.hotkeyMods) { DesignTools.show(.colorPicker) }
        let a = NSAlert(); a.messageText = "SnapDesk is running"
        a.informativeText = "Use the \"Snap\" menu at the top of the screen (menu bar, right side) or the Dock icon menu for captures and tools.\n\nHotkeys: ⌃⌥1 Full Screen, ⌃⌥6 Region, ⌃⌥R Record, ⌃⌥C Color Picker."
        a.addButton(withTitle: "OK"); a.runModal()
    }
    static let hotkeyMods = controlKey | optionKey
    static let captureKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]   // one per CaptureMode, in allCases order

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { buildMenu() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil); return true
    }
    // MARK: menus (shared by the status item, Dock menu and the app's main menu bar)
    private func mi(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.control, .option],
                    symbol: String? = nil, rep: Any? = nil, on: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self; i.representedObject = rep
        if !key.isEmpty { i.keyEquivalentModifierMask = mods }
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let on { i.state = on ? .on : .off }
        return i
    }
    private func header(_ t: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: t) }
        let i = NSMenuItem(title: t.uppercased(), action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        // Capture
        m.addItem(header("Capture"))
        let cap: [(CaptureMode, String, String)] = [
            (.fullScreen, "Full Screen", "rectangle.dashed"), (.activeWindow, "Active Window", "macwindow"),
            (.windowControl, "Window Control", "cursorarrow.rays"), (.scrollingWindow, "Scrolling Window", "arrow.up.and.down.text.horizontal"),
            (.fixedRegion, "Fixed Region", "rectangle.center.inset.filled"), (.region, "Region", "crop"),
            (.freehand, "Freehand", "lasso"), (.repeatLast, "Repeat Last Capture", "arrow.counterclockwise")]
        for (n, c) in cap.enumerated() { m.addItem(mi(c.1, #selector(captureItem(_:)), key: String(n + 1), symbol: c.2, rep: c.0)) }
        // Record
        m.addItem(.separator()); m.addItem(header("Record"))
        let recTitle = ScreenRecorder.shared.isRecording ? "Stop Recording" : "Record Screen…"
        m.addItem(mi(recTitle, #selector(recordItem), key: "r", symbol: ScreenRecorder.shared.isRecording ? "stop.circle" : "record.circle"))
        // Design tools
        m.addItem(.separator()); m.addItem(header("Design Tools"))
        let tl: [(DesignTool, String, String, String)] = [
            (.colorPicker, "Color Picker", "eyedropper", "c"), (.colorPalette, "Color Palette", "paintpalette", ""),
            (.pixelRuler, "Pixel Ruler", "ruler", ""), (.magnifier, "Magnifier", "plus.magnifyingglass", ""),
            (.crosshair, "Crosshair", "scope", ""), (.protractor, "Protractor", "angle", ""),
            (.whiteboard, "Whiteboard", "pencil.and.scribble", "")]
        for t in tl { m.addItem(mi(t.1, #selector(toolItem(_:)), key: t.3, symbol: t.2, rep: t.0)) }
        // Editor / files
        m.addItem(.separator())
        m.addItem(mi("Open Image in Editor…", #selector(openImage), key: "o", mods: .command, symbol: "photo.on.rectangle"))
        m.addItem(mi("Open Save Folder", #selector(openFolder), symbol: "folder"))
        // Settings
        m.addItem(.separator())
        let settings = NSMenu(); settings.autoenablesItems = false
        settings.addItem(header("After Capture"))
        settings.addItem(mi("Open in Editor", #selector(toggleOpt(_:)), rep: "editor", on: prefs.openEditorAfterCapture))
        settings.addItem(mi("Copy to Clipboard", #selector(toggleOpt(_:)), rep: "clip", on: prefs.copyToClipboard))
        settings.addItem(mi("Auto-save to Folder", #selector(toggleOpt(_:)), rep: "autosave", on: prefs.autoSave))
        settings.addItem(.separator()); settings.addItem(header("Capture Options"))
        settings.addItem(mi("Include Mouse Cursor", #selector(toggleOpt(_:)), rep: "cursor", on: prefs.includeCursor))
        let delay = NSMenu()
        for d in [0.0, 3, 5, 10] { delay.addItem(mi(d == 0 ? "No Delay" : "\(Int(d)) seconds", #selector(setDelay(_:)), rep: d, on: prefs.captureDelay == d)) }
        let di = NSMenuItem(title: "Capture Delay", action: nil, keyEquivalent: ""); di.submenu = delay; settings.addItem(di)
        settings.addItem(.separator()); settings.addItem(header("Output"))
        let fmt = NSMenu()
        for f in ImageFormat.allCases { fmt.addItem(mi(f.rawValue.uppercased(), #selector(setFormat(_:)), rep: f, on: prefs.format == f)) }
        let fi = NSMenuItem(title: "Image Format", action: nil, keyEquivalent: ""); fi.submenu = fmt; settings.addItem(fi)
        settings.addItem(mi("Save Folder…", #selector(chooseFolder)))
        let si = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""); si.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil); si.submenu = settings
        m.addItem(si)
        m.addItem(.separator())
        m.addItem(mi("Quit SnapDesk", #selector(quit), key: "q", mods: .command))
        return m
    }
    func refreshMenu() { item.menu = buildMenu(); installMainMenu() }

    /// Real menu bar for the app: SnapDesk + the same grouped menu items as submenus.
    func installMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let app = NSMenu(title: "SnapDesk"); appItem.submenu = app
        app.addItem(mi("About SnapDesk", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.items[0].target = NSApp
        app.addItem(.separator())
        app.addItem(mi("Quit SnapDesk", #selector(quit), key: "q", mods: .command))
        // Split the flat menu at separators; each group becomes a top-level menu.
        var groups: [[NSMenuItem]] = [[]]
        for it in buildMenu().items { if it.isSeparatorItem { groups.append([]) } else { groups[groups.count - 1].append(it) } }
        for g in groups where !g.isEmpty {
            if g.count == 1, g[0].title.hasPrefix("Quit") { continue }
            let name = g[0].isSectionHeaderLike ? g[0].title : (g[0].title == "Settings" ? "Settings" : "File")
            let sub = NSMenu(title: name); sub.autoenablesItems = false
            let top = NSMenuItem(); top.submenu = sub; bar.addItem(top)
            let body = g[0].title == "Settings" ? (g[0].submenu?.items ?? []) : g
            for x in body { x.menu?.removeItem(x); sub.addItem(x) }
        }
        NSApp.mainMenu = bar
    }

    func capture(_ mode: CaptureMode) {
        CaptureManager.shared.capture(mode) { [prefs] img in
            guard let img else { return }
            DispatchQueue.main.async {
                if prefs.copyToClipboard { ImageOutput.copyToClipboard(img) }
                if prefs.autoSave { ImageOutput.autoSave(img) }
                if prefs.openEditorAfterCapture { NSApp.activate(ignoringOtherApps: true); EditorWindowController.open(image: img) }
            }
        }
    }
    func toggleRecord() { ScreenRecorder.shared.toggle(RecordingOptions(target: .region, systemAudio: true, microphone: false, fps: 30, quality: 0.8, showCursor: prefs.includeCursor)) }

    @objc func captureItem(_ s: NSMenuItem) { capture(s.representedObject as! CaptureMode) }
    @objc func recordItem() { toggleRecord() }
    @objc func toolItem(_ s: NSMenuItem) { DesignTools.show(s.representedObject as! DesignTool) }
    @objc func openImage() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u) { EditorWindowController.open(image: img) }
    }
    @objc func toggleOpt(_ s: NSMenuItem) {
        switch s.representedObject as! String {
        case "cursor": prefs.includeCursor.toggle()
        case "autosave": prefs.autoSave.toggle()
        case "clip": prefs.copyToClipboard.toggle()
        default: prefs.openEditorAfterCapture.toggle()
        }
        refreshMenu()
    }
    @objc func setDelay(_ s: NSMenuItem) { prefs.captureDelay = s.representedObject as! Double; refreshMenu() }
    @objc func setFormat(_ s: NSMenuItem) { prefs.format = s.representedObject as! ImageFormat; refreshMenu() }
    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { prefs.saveFolder = u }
    }
    @objc func openFolder() { try? FileManager.default.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(prefs.saveFolder) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--snapshot-editor" {
    print(editorKitSnapshot(to: CommandLine.arguments[2])); exit(0)
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest" {
    exit(runSelfTest())
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
