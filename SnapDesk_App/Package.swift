// swift-tools-version:5.9
import PackageDescription
let kit: (String) -> Target = { n in .target(name: n, dependencies: ["SnapCore"]) }
let package = Package(
    name: "SnapDesk",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SnapCore"),
        kit("CaptureKit"), kit("EditorKit"), kit("ToolsKit"), kit("RecorderKit"),
        .executableTarget(name: "SnapDesk",
            dependencies: ["SnapCore", "CaptureKit", "EditorKit", "ToolsKit", "RecorderKit"]),
    ]
)
