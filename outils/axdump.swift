import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func dump(_ e: AXUIElement, _ depth: Int) {
    if depth > 14 { return }
    let pad = String(repeating: "  ", count: depth)
    var names: CFArray?
    AXUIElementCopyAttributeNames(e, &names)
    let role = attr(e, "AXRole") as? String ?? "?"
    var parts = [role]
    for k in ["AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXMinValue", "AXMaxValue", "AXValueDescription", "AXHelp", "AXEnabled", "AXMain", "AXMinimized"] {
        if let v = attr(e, k) {
            var s = "\(v)"
            if s.count > 160 { s = String(s.prefix(160)) + "…" }
            parts.append("\(k)=\(s)")
        }
    }
    var acts: CFArray?
    AXUIElementCopyActionNames(e, &acts)
    if let a = acts as? [String], !a.isEmpty { parts.append("actions=\(a)") }
    print(pad + parts.joined(separator: " | "))
    if let kids = attr(e, "AXChildren") as? [AXUIElement] {
        for k in kids { dump(k, depth + 1) }
    }
}
print("trusted:", AXIsProcessTrusted())
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { fatalError("no Finder") }
let app = AXUIElementCreateApplication(finder.processIdentifier)
var wins: AnyObject?
let err = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &wins)
print("AXWindows err:", err.rawValue)
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
for w in (wins as? [AXUIElement]) ?? [] {
    let sub = attr(w, "AXSubrole") as? String ?? ""
    let title = attr(w, "AXTitle") as? String ?? ""
    if filter == "brief" {
        print("WINDOW subrole=\(sub) title=\(title) id=\(attr(w, "AXIdentifier") ?? "nil" as AnyObject)")
        continue
    }
    print("=== WINDOW ===")
    dump(w, 0)
}
