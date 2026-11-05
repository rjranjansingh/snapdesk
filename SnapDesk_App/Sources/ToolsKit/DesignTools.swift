import AppKit
import SnapCore

public enum DesignTools {
    nonisolated(unsafe) static var registry: [DesignTool: ToolBase] = [:]
    nonisolated(unsafe) static var monitor: Any?

    /// Opens the tool, or closes it if it is already open.
    public static func show(_ tool: DesignTool) {
        guard Thread.isMainThread else { DispatchQueue.main.async { show(tool) }; return }
        if let t = registry[tool] { t.close(); return }
        let t: ToolBase
        switch tool {
        case .colorPicker: t = PickerTool()
        case .colorPalette: t = PaletteTool()
        case .pixelRuler: t = RulerTool()
        case .magnifier: t = MagnifierTool()
        case .crosshair: t = CrosshairTool()
        case .protractor: t = ProtractorTool()
        case .whiteboard: t = WhiteboardTool()
        }
        registry[tool] = t
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.keyCode == 53 else { return e }
                let hit = registry.values.filter { $0.wantsEscape }
                hit.forEach { $0.escape() }
                return hit.isEmpty ? e : nil
            }
        }
    }
}
