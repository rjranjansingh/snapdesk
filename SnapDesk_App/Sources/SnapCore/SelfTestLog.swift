import Foundation

/// Tiny check reporter shared by every kit's `--selftest` hook.
public enum SelfTest {
    nonisolated(unsafe) public static var total = 0
    nonisolated(unsafe) public static var failed: [String] = []
    public static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("PASS \(name)") } else { failed.append(name); print("FAIL \(name)\(detail().isEmpty ? "" : ": " + detail())") }
    }
}
