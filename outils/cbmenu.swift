// Usage : menu <bundle id> [press:<chemin/de/titres séparés par ▸>]   — liste le menu (2 niveaux sous Historique) ou clique.
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }
let args = Array(CommandLine.arguments.dropFirst())
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[0]).first else { print("absent"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
if args.contains("alert") {
    for w in attr(ax, "AXWindows") as? [AXUIElement] ?? [] {
        func walk(_ e: AXUIElement, _ d: Int) {
            let role = attr(e, "AXRole") as? String ?? ""
            let text = (attr(e, "AXValue") as? String) ?? (attr(e, "AXTitle") as? String) ?? ""
            if !text.isEmpty { print(String(repeating: "  ", count: d), role, text.replacingOccurrences(of: "\n", with: " ⏎ ")) }
            if role == "AXButton", let p = args.first(where: { $0.hasPrefix("button:") })?.dropFirst(7), text == p { print("   → clic", AXUIElementPerformAction(e, "AXPress" as CFString).rawValue) }
            for k in kids(e) { walk(k, d + 1) }
        }
        walk(w, 0)
    }
    exit(0)
}
guard let bar = attr(ax, "AXExtrasMenuBar"), let item = kids(bar as! AXUIElement).first else { print("pas de barre"); exit(1) }
print("barre:", attr(item, "AXTitle") as? String ?? "")
AXUIElementPerformAction(item, "AXPress" as CFString); usleep(500_000)
func show(_ menu: AXUIElement, _ depth: Int) {
    for i in kids(menu) {
        let t = attr(i, "AXTitle") as? String ?? ""
        print(String(repeating: "    ", count: depth) + "[\((attr(i, "AXEnabled") as? Bool ?? false) ? "x" : " ")] " + (t.isEmpty ? "────" : t))
        if depth < 2, let sub = kids(i).first { show(sub, depth + 1) }
    }
}
let menu = kids(item).first!
if let path = args.first(where: { $0.hasPrefix("press:") })?.dropFirst(6).components(separatedBy: "▸") {
    var current = menu; var target: AXUIElement?
    for part in path {
        guard let hit = kids(current).first(where: { (attr($0, "AXTitle") as? String ?? "").contains(part) }) else { print("introuvable:", part); break }
        target = hit
        if let sub = kids(hit).first { current = sub }
    }
    if let target { print("→ clic « \(attr(target, "AXTitle") as? String ?? "") » err=\(AXUIElementPerformAction(target, "AXPress" as CFString).rawValue)") }
} else { show(menu, 0); AXUIElementPerformAction(menu, "AXCancel" as CFString) }
