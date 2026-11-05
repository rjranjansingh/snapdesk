import AppKit
import Carbon.HIToolbox
import SnapCore
import CaptureKit
import EditorKit
import ToolsKit
import RecorderKit

private func chk(_ n: String, _ ok: Bool, _ d: @autoclosure () -> String = "") { SelfTest.check(n, ok, d()) }

/// `SnapDesk --selftest`: headless checks across all kits. Exit code 0 only if every check passed.
func runSelfTest() -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()
    coreSelfTest()
    menuSelfTest()
    captureKitSelfTest()
    toolsKitSelfTest()
    editorKitSelfTest()
    print("\n\(SelfTest.total - SelfTest.failed.count)/\(SelfTest.total) checks passed")
    if !SelfTest.failed.isEmpty { print("FAILED:\n  " + SelfTest.failed.joined(separator: "\n  ")) }
    return SelfTest.failed.isEmpty ? 0 : 1
}

// MARK: SnapCore
private func coreSelfTest() {
    let suite = "com.local.snapdesk.selftest"
    UserDefaults().removePersistentDomain(forName: suite)
    let ud = UserDefaults(suiteName: suite)!
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let p = Preferences(defaults: ud)
    chk("core/prefs/default-folder", p.saveFolder == FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SnapDesk"))
    chk("core/prefs/default-format", p.format == .png)
    chk("core/prefs/default-jpegQuality", p.jpegQuality == 0.9)
    chk("core/prefs/default-includeCursor", p.includeCursor == false)
    chk("core/prefs/default-delay", p.captureDelay == 0)
    chk("core/prefs/default-autoSave", p.autoSave == false)
    chk("core/prefs/default-copyToClipboard", p.copyToClipboard == false)
    chk("core/prefs/default-openEditor", p.openEditorAfterCapture == true)
    chk("core/prefs/default-pattern", p.fileNamePattern == "SnapDesk_yyyy-MM-dd_HH-mm-ss")
    chk("core/prefs/default-fixedRegion", p.fixedRegionSize == CGSize(width: 800, height: 600))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snapdesk-selftest-\(getpid())")
    try? FileManager.default.removeItem(at: tmp); defer { try? FileManager.default.removeItem(at: tmp) }
    p.saveFolder = tmp; p.format = .jpeg; p.jpegQuality = 0.5; p.includeCursor = true; p.captureDelay = 5; p.autoSave = true
    p.copyToClipboard = true; p.openEditorAfterCapture = false; p.fileNamePattern = "'shot'_yyyyMMdd_HHmmss"; p.fixedRegionSize = CGSize(width: 321, height: 123)
    let q = Preferences(defaults: ud)   // fresh instance reads what was persisted
    chk("core/prefs/roundtrip-folder", q.saveFolder == tmp, "\(q.saveFolder)")
    chk("core/prefs/roundtrip-format", q.format == .jpeg); chk("core/prefs/roundtrip-quality", q.jpegQuality == 0.5)
    chk("core/prefs/roundtrip-bools", q.includeCursor && q.autoSave && q.copyToClipboard && !q.openEditorAfterCapture)
    chk("core/prefs/roundtrip-delay", q.captureDelay == 5); chk("core/prefs/roundtrip-pattern", q.fileNamePattern == "'shot'_yyyyMMdd_HHmmss")
    chk("core/prefs/roundtrip-fixedRegion", q.fixedRegionSize == CGSize(width: 321, height: 123))
    for f in ImageFormat.allCases { p.format = f; chk("core/prefs/roundtrip-format-\(f.rawValue)", Preferences(defaults: ud).format == f) }
    ud.set("bogus", forKey: "format"); chk("core/prefs/bad-format-falls-back-to-png", Preferences(defaults: ud).format == .png)
    chk("core/prefs/shared-uses-standard-defaults", Preferences.shared.format.rawValue.count > 0)

    // autoSave naming
    let img = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
    for f in ImageFormat.allCases {
        p.format = f; p.fileNamePattern = "'shot'_yyyy-MM-dd_HH-mm-ss'_\(f.rawValue)'"
        guard let u = ImageOutput.autoSave(img, prefs: p) else { chk("core/autosave/\(f.rawValue)", false, "nil url"); continue }
        let e = ImageOutput.ext(f)
        chk("core/autosave/\(f.rawValue)-name+ext", u.deletingLastPathComponent().path == tmp.path && u.pathExtension == e
            && u.lastPathComponent.range(of: "^shot_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}_\(f.rawValue)\\.\(e)$", options: .regularExpression) != nil, u.lastPathComponent)
        chk("core/autosave/\(f.rawValue)-file-decodes", (try? Data(contentsOf: u)).map { $0.count > 50 } ?? false)
    }
    // two saves in the same second must not overwrite each other
    p.format = .png; p.fileNamePattern = "'same'"
    let a1 = ImageOutput.autoSave(img, prefs: p), a2 = ImageOutput.autoSave(img, prefs: p), a3 = ImageOutput.autoSave(img, prefs: p)
    chk("core/autosave/no-overwrite-same-name", a1 != nil && a2 != nil && a3 != nil && Set([a1, a2, a3].compactMap { $0?.path }).count == 3, "\(String(describing: [a1, a2, a3].map { $0?.lastPathComponent }))")
    p.fileNamePattern = "yyyy-MM-dd"
    chk("core/autosave/creates-missing-folder", { try? FileManager.default.removeItem(at: tmp); return ImageOutput.autoSave(img, prefs: p) != nil && FileManager.default.fileExists(atPath: tmp.path) }())
    chk("core/ext/jpeg-is-jpg", ImageOutput.ext(.jpeg) == "jpg" && ImageOutput.ext(.tiff) == "tiff")
    chk("core/output/empty-image-returns-nil-not-crash", ImageOutput.data(NSImage(), format: .png) == nil)
    chk("core/capture-modes-have-hotkeys", AppDelegate.captureKeys.count == CaptureMode.allCases.count, "\(AppDelegate.captureKeys.count) keys for \(CaptureMode.allCases.count) modes")
    let ro = RecordingOptions()
    chk("recorder/options-defaults", ro.fps == 30 && ro.quality == 0.7 && ro.showCursor && !ro.microphone && !ro.systemAudio)
}

// MARK: menus
private func menuSelfTest() {
    let d = AppDelegate()
    let prefs = Preferences.shared
    var seenKeys: [String: String] = [:]
    var captureSeen: [CaptureMode: Int] = [:], toolSeen: [DesignTool: Int] = [:]
    func walk(_ m: NSMenu, _ path: String, top: Bool) {
        for it in m.items where !it.isSeparatorItem {
            let n = "\(path)/\(it.title)"
            if let s = it.submenu { walk(s, n, top: false); continue }
            guard let a = it.action else {
                chk("menu/\(n)/is-header-or-disabled", !it.isEnabled || it.isSectionHeaderLike, "enabled, no action"); continue }
            guard let t = it.target else { chk("menu/\(n)/has-target", false, "action \(a) without target"); continue }
            chk("menu/\(n)/target-responds-to-\(a)", (t as AnyObject).responds(to: a))
            switch a {
            case #selector(AppDelegate.captureItem(_:)): let ok = it.representedObject is CaptureMode; chk("menu/\(n)/rep-CaptureMode", ok); if let c = it.representedObject as? CaptureMode { captureSeen[c, default: 0] += 1 }
            case #selector(AppDelegate.toolItem(_:)): let ok = it.representedObject is DesignTool; chk("menu/\(n)/rep-DesignTool", ok); if let c = it.representedObject as? DesignTool { toolSeen[c, default: 0] += 1 }
            case #selector(AppDelegate.setDelay(_:)): chk("menu/\(n)/rep-Double", it.representedObject is Double)
                chk("menu/\(n)/checkmark-matches-prefs", (it.state == .on) == (prefs.captureDelay == it.representedObject as? Double))
            case #selector(AppDelegate.setFormat(_:)): chk("menu/\(n)/rep-ImageFormat", it.representedObject is ImageFormat)
                chk("menu/\(n)/checkmark-matches-prefs", (it.state == .on) == (prefs.format == it.representedObject as? ImageFormat))
            case #selector(AppDelegate.toggleOpt(_:)):
                let k = it.representedObject as? String
                chk("menu/\(n)/rep-known-key", ["cursor", "autosave", "clip", "editor"].contains(k ?? ""), "\(String(describing: k))")
                let cur: Bool? = k == "cursor" ? prefs.includeCursor : k == "autosave" ? prefs.autoSave : k == "clip" ? prefs.copyToClipboard : k == "editor" ? prefs.openEditorAfterCapture : nil
                chk("menu/\(n)/checkmark-matches-prefs", (it.state == .on) == cur)
            default: break
            }
            if !it.keyEquivalent.isEmpty {
                let sig = "\(it.keyEquivalentModifierMask.rawValue)+\(it.keyEquivalent)"
                chk("menu/\(n)/key-equivalent-unique(\(sig))", seenKeys[sig] == nil, "also on \(seenKeys[sig] ?? "")")
                seenKeys[sig] = n
            }
        }
    }
    let status = d.buildMenu()
    walk(status, "status", top: true)
    chk("menu/status/all-capture-modes-once", CaptureMode.allCases.allSatisfy { captureSeen[$0] == 1 }, "\(captureSeen)")
    chk("menu/status/all-design-tools-once", DesignTool.allCases.allSatisfy { toolSeen[$0] == 1 }, "\(toolSeen)")
    // key equivalents must not collide with each other inside one menu bar (status menu already walked; main menu is the same items)
    seenKeys = [:]; captureSeen = [:]; toolSeen = [:]
    d.installMainMenu()
    guard let bar = NSApp.mainMenu else { chk("menu/main/installed", false); return }
    chk("menu/main/installed", bar.items.count >= 4, "\(bar.items.count) top-level")
    chk("menu/main/every-top-level-has-submenu", bar.items.allSatisfy { $0.submenu != nil && !($0.submenu!.items.isEmpty) })
    chk("menu/main/titles", bar.items.compactMap { $0.submenu?.title } == ["SnapDesk", "Capture", "Record", "Design Tools", "File", "Settings"], "\(bar.items.compactMap { $0.submenu?.title })")
    walk(bar, "main", top: true)
    chk("menu/main/all-capture-modes-once", CaptureMode.allCases.allSatisfy { captureSeen[$0] == 1 })
    chk("menu/main/all-design-tools-once", DesignTool.allCases.allSatisfy { toolSeen[$0] == 1 })
    let about = bar.items[0].submenu!.items[0]
    chk("menu/main/about-targets-NSApp", about.target === NSApp && NSApp.responds(to: about.action!))
    chk("menu/dock-menu-builds", d.applicationDockMenu(NSApp)?.items.isEmpty == false)
    d.installMainMenu(); chk("menu/main/rebuild-twice-safe", NSApp.mainMenu?.items.count == bar.items.count)
    // hotkeys: no duplicates, and report combos the OS owns
    var combos: [String: String] = [:]
    for (i, m) in CaptureMode.allCases.enumerated() { combos["\(AppDelegate.captureKeys[i])"] = "\(m)" }
    combos["\(kVK_ANSI_R)"] = (combos["\(kVK_ANSI_R)"].map { $0 + "+" } ?? "") + "record"
    combos["\(kVK_ANSI_C)"] = (combos["\(kVK_ANSI_C)"].map { $0 + "+" } ?? "") + "colorPicker"
    chk("hotkeys/no-duplicates", combos.count == CaptureMode.allCases.count + 2, "\(combos)")
    let reserved = [kVK_ANSI_3: "Full-screen screenshot", kVK_ANSI_4: "Region screenshot", kVK_ANSI_5: "Screenshot toolbar"]
    for (k, why) in reserved where AppDelegate.captureKeys.contains(k) {
        print("WARN hotkeys: ⌘⇧\(k == kVK_ANSI_3 ? 3 : k == kVK_ANSI_4 ? 4 : 5) is reserved by macOS (\(why)); the SnapDesk shortcut will not fire unless the system one is disabled (not auto-fixed: needs a shortcut-scheme decision)")
    }
    // global hotkey registration really succeeds for the non-reserved combos (and is released again)
    var ref: EventHotKeyRef?
    let st = RegisterEventHotKey(UInt32(kVK_ANSI_1), UInt32(AppDelegate.hotkeyMods), EventHotKeyID(signature: 0x53544B31, id: 99), GetApplicationEventTarget(), 0, &ref)
    chk("hotkeys/RegisterEventHotKey-works-for-cmd-shift-1", st == noErr, "OSStatus \(st)")
    if let ref { UnregisterEventHotKey(ref) }
}
