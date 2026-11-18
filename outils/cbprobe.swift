// Inspecte l'élément de barre de menus de CopyBar par AX. Args : [menu] [press:<préfixe de titre>]
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.alnilam-404.copybar").first else { print("CopyBar absent"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
guard let bar = attr(ax, "AXExtrasMenuBar"), let item = (attr(bar as! AXUIElement, "AXChildren") as? [AXUIElement])?.first else { print("pas d'élément de barre de menus"); exit(1) }
print("barre: titre=\"\(attr(item, "AXTitle") as? String ?? "")\" aide=\"\((attr(item, "AXHelp") as? String ?? "").replacingOccurrences(of: "\n", with: " ⏎ "))\"")
let args = CommandLine.arguments.dropFirst()
guard !args.isEmpty else { exit(0) }
AXUIElementPerformAction(item, "AXPress" as CFString)
usleep(600_000)
let menu = (attr(item, "AXChildren") as? [AXUIElement])?.first
let items = menu.flatMap { attr($0, "AXChildren") as? [AXUIElement] } ?? []
for i in items {
    let t = attr(i, "AXTitle") as? String ?? ""
    print("  menu: [\((attr(i, "AXEnabled") as? Bool ?? false) ? "x" : " ")] \(t.isEmpty ? "────" : t) \(attr(i, "AXMenuItemMarkChar") as? String ?? "")")
}
if let p = args.first(where: { $0.hasPrefix("press:") })?.dropFirst(6), let target = items.first(where: { (attr($0, "AXTitle") as? String ?? "").contains(p) }) {
    print("  → clic sur « \(attr(target, "AXTitle") as? String ?? "") » : err=\(AXUIElementPerformAction(target, "AXPress" as CFString).rawValue)")
} else {
    AXUIElementPerformAction(menu ?? item, "AXCancel" as CFString)
}
