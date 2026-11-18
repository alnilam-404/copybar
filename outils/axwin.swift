import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first!
let app = AXUIElementCreateApplication(finder.processIdentifier)
let wins = attr(app, "AXWindows") as? [AXUIElement] ?? []
let p = wins.first { attr($0, "AXIdentifier") as? String == "Progress" }
if CommandLine.arguments.contains("minimize"), let p { AXUIElementSetAttributeValue(p, "AXMinimized" as CFString, kCFBooleanTrue) ; usleep(900_000) }
print("premier plan=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") | Progress: \(p == nil ? "absente" : "minimisée=\(attr(p!, "AXMinimized") as? Bool ?? false) principale=\(attr(p!, "AXMain") as? Bool ?? false) rang=\(wins.firstIndex(where: { CFEqual($0, p!) }) ?? -1)")")
