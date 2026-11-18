// CopyBar — suit les copies du Finder depuis la barre de menus.
//
// Le Finder n'expose aucune API de progression : on lit sa fenêtre de progression par
// l'accessibilité (AX). Structure relevée sur macOS 27 :
//
//   AXWindow  AXIdentifier="Progress"  (action AXRaise)
//     AXScrollArea
//       AXImage                                   ┐
//       AXStaticText        "Copie de « x » dans « y »"   │ une ligne
//       AXProgressIndicator AXValue 0…1                   │ par copie
//       AXButton            "arrêter la progression"      │
//       AXStaticText        "8,93 Go sur 12,58 Go – Environ 5 secondes" ┘
//
// Les lignes n'ont pas d'identifiant stable et leur titre change en cours de copie
// (« Copie de 21 699 éléments » devient « Copie de 895 éléments ») : voir Tracker.
//
// La fenêtre ne donne que des noms, jamais de chemins. Pour l'historique, les chemins sont
// retrouvés à côté (voir OriginProbe) : le Finder donne à tout élément en cours de copie la
// date de création du 24 janvier 1984, et ses fenêtres exposent l'URL des éléments affichés.

import AppKit
import ApplicationServices
import Darwin
import ServiceManagement
import UserNotifications

// MARK: - Langue

/// Textes de l'interface : en français si c'est la langue du Mac, en anglais sinon.
/// (Le journal, lui, reste en français.)
let french = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
func L(_ fr: String, _ en: String) -> String { french ? fr : en }

// MARK: - Journal (~/Library/Logs/CopyBar.log)

func log(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    NSLog("%@", message)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CopyBar.log")
    guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

// MARK: - Lecture AX du Finder

struct Row {
    var title = ""
    var detail = ""
    var fraction: Double?
}

enum Reading {
    case untrusted                     // droit Accessibilité non accordé
    case noFinder                      // Finder absent (relance en cours)
    case failed                        // erreur AX passagère : on ignore ce tour
    case ok([Row], window: AXUIElement?, busy: [Busy])
}

enum FinderProbe {
    static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func read() -> Reading {
        guard AXIsProcessTrusted() else { return .untrusted }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return .noFinder
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return .failed }

        var rows: [Row] = []
        var progressWindow: AXUIElement?
        var others: [AXUIElement] = []
        for window in windows {
            guard attr(window, kAXIdentifierAttribute) as? String == "Progress" else { others.append(window); continue }
            if progressWindow == nil { progressWindow = window }
            var leaves: [(role: String, element: AXUIElement)] = []
            flatten(window, depth: 0, into: &leaves)
            rows += parse(leaves)
        }
        if rows.isEmpty { origins.reset() }
        let busy = rows.isEmpty ? [] : origins.scan(titles: rows.map(\.title), pid: finder.processIdentifier, windows: others)
        return .ok(rows, window: progressWindow, busy: busy)
    }

    private static let origins = OriginProbe()   // n'est utilisé que depuis la file de polling

    private static func flatten(_ element: AXUIElement, depth: Int, into out: inout [(role: String, element: AXUIElement)]) {
        guard depth < 8 else { return }
        for child in attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let role = attr(child, kAXRoleAttribute) as? String ?? ""
            switch role {
            case "AXImage", "AXStaticText", "AXProgressIndicator": out.append((role, child))
            case "AXButton": break
            default: flatten(child, depth: depth + 1, into: &out)
            }
        }
    }

    private static func parse(_ leaves: [(role: String, element: AXUIElement)]) -> [Row] {
        var rows: [Row] = []
        var current: Row?
        var texts = 0
        func close() {
            if let row = current, !row.title.isEmpty { rows.append(row) }
            current = nil
            texts = 0
        }
        for leaf in leaves {
            switch leaf.role {
            case "AXImage":
                close()
                current = Row()
            case "AXStaticText":
                if texts >= 2 { close() }
                if current == nil { current = Row() }
                let text = attr(leaf.element, kAXValueAttribute) as? String ?? ""
                if texts == 0 { current?.title = text } else { current?.detail = text }
                texts += 1
            case "AXProgressIndicator":
                if current == nil { current = Row() }
                current?.fraction = fraction(of: leaf.element)
            default: break
            }
        }
        close()
        return rows
    }

    /// nil quand l'indicateur est indéterminé (pas de valeur numérique).
    private static func fraction(of indicator: AXUIElement) -> Double? {
        guard let value = (attr(indicator, kAXValueAttribute) as? NSNumber)?.doubleValue else { return nil }
        let low = (attr(indicator, kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
        let high = (attr(indicator, kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 1
        guard high > low else { return nil }
        return min(max((value - low) / (high - low), 0), 1)
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }
}

// MARK: - Textes du Finder

enum Title {
    private static let quotes = try! NSRegularExpression(pattern: "«\\s*(.+?)\\s*»|“(.+?)”|„(.+?)“|\"(.+?)\"|「(.+?)」")
    private static let amount = try! NSRegularExpression(pattern: "\\d[\\d\\s.,]*\\s*\\p{L}+\\s*$")

    /// Noms entre guillemets d'un titre : [élément, destination] pour un élément seul,
    /// [destination] pour « Copie de 12 éléments dans « y » », [] si la langue cite autrement.
    static func quoted(_ title: String) -> [String] {
        let text = title as NSString
        return quotes.matches(in: title, range: NSRange(location: 0, length: text.length)).compactMap { match in
            (1..<match.numberOfRanges).map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(text.substring(with:))
        }
    }

    /// « 12,58 Go » dans « 8,93 Go sur 12,58 Go – Environ 5 secondes ».
    static func total(_ detail: String) -> String? {
        let head = detail.components(separatedBy: " – ")[0].components(separatedBy: " — ")[0]
        guard let match = amount.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else { return nil }
        return (head as NSString).substring(with: match.range).trimmingCharacters(in: .whitespaces)
    }

    /// Le Finder affiche le nom localisé, parfois sans extension : on compare les deux formes.
    static func matches(_ path: String, _ name: String) -> Bool {
        let wanted = name.precomposedStringWithCanonicalMapping
        return (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping == wanted
            || FileManager.default.displayName(atPath: path).precomposedStringWithCanonicalMapping == wanted
    }
}

// MARK: - Chemins des copies en cours

/// Élément en cours de copie repéré sur disque dans un dossier de destination.
struct Busy {
    let dir: String
    let name: String
    let baseline: Set<String>    // ce que le dossier contenait déjà au premier relevé
    let sources: [String]        // éléments de même nom dans les autres dossiers ouverts
}

/// Retrouve où vont les copies en cours. Deux indices, aucun n'est une API :
///  - le Finder garde ouvert le gros fichier qu'il écrit (visible par proc_pidinfo) ;
///  - tout élément en cours de copie porte la date de création du 24/01/1984, y compris le
///    dossier de premier niveau d'une copie de dossier. On cherche donc cette date dans les
///    dossiers candidats : ceux des fenêtres du Finder, le bureau, les volumes…
final class OriginProbe {
    private var baselines: [String: Set<String>] = [:]
    private var sources: [String: [String]] = [:]
    private var folders: [String] = []
    private var key = ""
    private var polls = 0

    func reset() {
        baselines = [:]; sources = [:]; folders = []; key = ""; polls = 0
    }

    func scan(titles: [String], pid: pid_t, windows: [AXUIElement]) -> [Busy] {
        let wanted = titles.map { Title.quoted($0).last }
        let newKey = "\(titles.count)|" + wanted.map { $0 ?? "?" }.sorted().joined(separator: "|")
        if newKey != key { key = newKey; polls = 0 }
        defer { polls += 1 }
        let open = Self.openPaths(pid)

        // Gros fichier tenu ouvert : on remonte jusqu'à l'élément de premier niveau.
        for file in open.files where Self.isBusy(file) {
            var top = file
            while Self.isBusy(Self.parent(top)) { top = Self.parent(top) }
            watch(Self.parent(top))
        }

        // Recherche parmi les dossiers candidats, tant qu'une copie n'a pas de destination.
        let unresolved = wanted.contains { name in
            name.map { n in !baselines.keys.contains { Title.matches($0, n) } } ?? (baselines.count < titles.count)
        }
        if unresolved, [0, 1, 2, 4, 8, 15, 30, 60].contains(polls) {
            folders = Self.candidates(windows: windows, openDirs: open.dirs)
            for name in Set(wanted) {
                var isDir: ObjCBool = false
                let dirs = name.map { n in
                    folders.filter { Title.matches($0, n) }
                        + folders.map { ($0 as NSString).appendingPathComponent(n) }
                            .filter { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
                } ?? Array(folders.prefix(15))
                for dir in dirs { watch(dir) }
            }
        }

        // Relevé des dossiers suivis : chaque seconde au début, puis toutes les 5 s.
        guard polls < 10 || polls % 5 == 0 else { return [] }
        var out: [Busy] = []
        for (dir, baseline) in baselines {
            for name in Self.list(dir).busy {
                let path = (dir as NSString).appendingPathComponent(name)
                if sources[path] == nil {
                    if folders.isEmpty { folders = Self.candidates(windows: windows, openDirs: open.dirs) }
                    sources[path] = folders.filter { $0 != dir }
                        .map { ($0 as NSString).appendingPathComponent(name) }
                        .filter { FileManager.default.fileExists(atPath: $0) }
                }
                out.append(Busy(dir: dir, name: name, baseline: baseline, sources: sources[path] ?? []))
            }
        }
        return out
    }

    private func watch(_ dir: String) {
        guard baselines[dir] == nil else { return }
        let content = Self.list(dir)
        if !content.busy.isEmpty { baselines[dir] = content.idle }
    }

    // MARK: Disque

    /// Date de création que le Finder donne aux éléments en cours de copie (24/01/1984 08:00 UTC).
    private static let magic: TimeInterval = 443_779_200

    static func isBusy(_ date: Date?) -> Bool {
        date.map { abs($0.timeIntervalSince1970 - magic) < 86_400 } ?? false
    }

    private static func isBusy(_ path: String) -> Bool {
        isBusy((try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date)
    }

    private static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func list(_ dir: String) -> (idle: Set<String>, busy: [String]) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.creationDateKey])) ?? []
        var idle = Set<String>(), busy: [String] = []
        for url in urls {
            if isBusy((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate) { busy.append(url.lastPathComponent) }
            else { idle.insert(url.lastPathComponent) }
        }
        return (idle, busy)
    }

    // MARK: Dossiers candidats

    private static func candidates(windows: [AXUIElement], openDirs: [String]) -> [String] {
        let fm = FileManager.default
        var all: [String] = []
        for window in windows {
            var budget = 500
            collect(window, depth: 0, budget: &budget, into: &all)
        }
        all += openDirs
        let home = fm.homeDirectoryForCurrentUser.path
        all += ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { (home as NSString).appendingPathComponent($0) } + [home]
        all += (fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []).map(\.path)
        var seen = Set<String>()
        return Array(all.filter { $0 != "/" && seen.insert($0).inserted }.prefix(80))
    }

    /// Dossiers affichés dans une fenêtre du Finder : parents des éléments visibles (attribut
    /// AXURL). Un élément par conteneur suffit, d'où le parcours volontairement partiel.
    private static func collect(_ element: AXUIElement, depth: Int, budget: inout Int, into out: inout [String]) {
        guard depth < 14 else { return }
        for child in (FinderProbe.attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(12) {
            guard budget > 0 else { return }
            budget -= 1
            if let url = FinderProbe.attr(child, "AXURL") as? NSURL, let path = url.filePathURL?.path {
                out.append(parent(path))
                break
            }
            collect(child, depth: depth + 1, budget: &budget, into: &out)
        }
    }

    // MARK: Fichiers ouverts par le Finder

    private static let ignored = ["/System/", "/usr/", "/Library/", "/private/var/", "/dev/", NSHomeDirectory() + "/Library/"]

    private static func openPaths(_ pid: pid_t) -> (files: [String], dirs: [String]) {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return ([], []) }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        var files: [String] = [], dirs: [String] = []
        for fd in fds.prefix(max(0, Int(used)) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard path.hasPrefix("/"), path != "/", !ignored.contains(where: path.hasPrefix) else { continue }
            switch info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT {
            case S_IFREG: files.append(path)
            case S_IFDIR: dirs.append(path)
            default: break
            }
        }
        return (files, dirs)
    }
}

// MARK: - Session verrouillée

/// Quand l'économiseur d'écran démarre ou que la session se verrouille, la fenêtre de
/// progression du Finder disparaît de l'arbre AX alors que la copie continue (constaté le
/// 16/11/2026 : fausse « copie interrompue » à la seconde du verrouillage). Pendant ces
/// périodes les relevés ne valent rien : on les ignore.
final class Session {
    private var screensaver = false
    private var locked = false

    init() {
        let center = DistributedNotificationCenter.default()
        for (name, change) in [
            ("com.apple.screensaver.didstart", { (s: Session) in s.screensaver = true }),
            ("com.apple.screensaver.didstop", { (s: Session) in s.screensaver = false }),
            ("com.apple.screenIsLocked", { (s: Session) in s.locked = true }),
            ("com.apple.screenIsUnlocked", { (s: Session) in s.locked = false; s.screensaver = false }),
        ] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                if let self { change(self) }
            }
        }
    }

    /// Raison pour laquelle on ne peut pas se fier à l'arbre AX, ou nil si tout va bien.
    var blindReason: String? {
        if screensaver { return "économiseur d’écran" }
        if locked { return "session verrouillée" }
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if info["CGSSessionScreenIsLocked"] as? Bool == true { return "session verrouillée" }
            if info["kCGSSessionOnConsoleKey"] as? Bool == false { return "session en arrière-plan" }
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return "écran en veille" }
        return nil
    }
}

// MARK: - Suivi des copies d'un tour de polling au suivant

struct Copy {
    let id: Int
    let firstTitle: String   // le titre évolue ; celui du début est le plus parlant
    let started: Date
    var row: Row
    var seen = Date()        // dernier tour où la ligne était présente
    var rate: Double?        // progression par seconde, mesurée entre les deux derniers tours

    /// La fenêtre AX ne dit pas pourquoi une ligne disparaît (fin, annulation, disque plein…).
    /// On extrapole donc la progression au moment de la disparition : loin de 100 %, la copie
    /// a été interrompue. Sans mesure de vitesse (copie vue une seule fois), on la suppose finie.
    func wasInterrupted(at vanished: Date) -> Bool {
        guard let fraction = row.fraction, let rate else { return false }
        let projected = fraction + max(rate, 0) * vanished.timeIntervalSince(seen) * 1.5
        return projected < 0.85
    }
}

struct Tracker {
    private(set) var copies: [Copy] = []
    private var nextID = 1

    /// Remet en suivi des copies déclarées disparues à tort (voir AppDelegate.pending).
    mutating func restore(_ restored: [Copy]) {
        copies += restored
    }

    /// Met à jour l'état avec les lignes lues et renvoie les copies qui ont disparu (= terminées).
    mutating func update(with rows: [Row]) -> [Copy] {
        var old = copies.map { Optional($0) }
        var matched = [Copy?](repeating: nil, count: rows.count)

        // 1. Même titre : c'est la même copie.
        for (i, row) in rows.enumerated() {
            if let j = old.firstIndex(where: { $0?.row.title == row.title }) {
                matched[i] = old[j]
                old[j] = nil
            }
        }
        // 2. Titre changé : on apparie dans l'ordre, à condition que la progression n'ait pas
        //    reculé (sinon c'est une nouvelle copie qui remplace une copie terminée).
        for (i, row) in rows.enumerated() where matched[i] == nil {
            let j = old.firstIndex { candidate in
                guard let candidate else { return false }
                guard let before = candidate.row.fraction, let now = row.fraction else { return true }
                return now >= before - 0.02
            }
            if let j {
                matched[i] = old[j]
                old[j] = nil
            }
        }

        copies = rows.enumerated().map { i, row in
            if var copy = matched[i] {
                let now = Date()
                if let before = copy.row.fraction, let after = row.fraction, now > copy.seen {
                    copy.rate = (after - before) / now.timeIntervalSince(copy.seen)
                }
                copy.row = row
                copy.seen = now
                return copy
            }
            defer { nextID += 1 }
            return Copy(id: nextID, firstTitle: row.title, started: Date(), row: row)
        }
        return old.compactMap { $0 }
    }
}

// MARK: - Historique

/// Ce qu'on a pu apprendre d'une copie en cours sur ses chemins (voir OriginProbe).
struct Origin {
    let dir: String
    let baseline: Set<String>
    var items: [String: [String]] = [:]   // nom vu en cours de copie → sources possibles
    var shared = false                    // une autre copie visait le même dossier en même temps
}

struct Entry: Codable {
    enum Outcome: String, Codable { case done, interrupted, unknown }
    struct Item: Codable {
        var name: String
        var source: String?
        var verified = false   // la source a été retrouvée identique (date de création, taille)
        var inode: UInt64      // pour vérifier, avant d'annuler, que c'est toujours le même élément
    }

    var id = UUID()
    var title: String
    var started: Date
    var ended: Date
    var outcome: Outcome
    var fraction: Double?
    var total: String?         // taille lue dans la fenêtre du Finder, faute de mieux
    var destination: String?
    var items: [Item] = []
    var moved = false          // les sources ont disparu : c'était un déplacement
    var bytes: Int64?
    var files: Int?
    var undone: Date?

    var source: String? {
        let dirs = Set(items.compactMap { $0.source.map { ($0 as NSString).deletingLastPathComponent } })
        return dirs.count == 1 ? dirs.first : nil
    }

    /// On ne met une copie à la corbeille que si l'original a été identifié avec certitude
    /// (ou si la copie, interrompue, est de toute façon incomplète) ; sa présence est
    /// revérifiée au moment d'agir. Un déplacement se défait en remettant l'élément à sa place.
    var canUndo: Bool {
        undone == nil && !items.isEmpty
            && items.allSatisfy { $0.source != nil && (moved || $0.verified || outcome == .interrupted) }
    }

    func path(of item: Item) -> String {
        ((destination ?? "") as NSString).appendingPathComponent(item.name)
    }

    private struct Info {
        let inode: UInt64, created: Date?, size: Int64, isDir: Bool

        init?(_ path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            created = attributes[.creationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            isDir = attributes[.type] as? FileAttributeType == .typeDirectory
        }

        /// Le Finder conserve la date de création : même date (et même taille pour un fichier)
        /// des deux côtés, c'est bien l'original et sa copie.
        func isCopy(of other: Info) -> Bool {
            guard let a = created, let b = other.created, abs(a.timeIntervalSince(b)) < 2, isDir == other.isDir else { return false }
            return isDir || size == other.size
        }
    }

    static func inode(_ path: String) -> UInt64? { Info(path)?.inode }

    /// Complète l'entrée avec ce qui se trouve réellement sur disque. Accès fichiers
    /// potentiellement lents (NAS) : à appeler hors du fil principal.
    mutating func resolve(_ origin: Origin) {
        let fm = FileManager.default
        destination = origin.dir
        let dirOf = { (path: String) in (path as NSString).deletingLastPathComponent }
        let addedDate = { (path: String) in (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate }

        // Éléments vus en cours de copie, avec leurs sources possibles encore présentes et identiques.
        var seen: [(name: String, inode: UInt64, candidates: [String], identical: [String], gone: [String])] = []
        var unfinished = false
        for name in origin.items.keys.sorted() {
            guard let copied = Info((origin.dir as NSString).appendingPathComponent(name)) else { continue }   // retiré par le Finder (annulation)
            let candidates = origin.items[name] ?? []
            if OriginProbe.isBusy(copied.created) {
                // Encore marqué « en cours » après la fin. Sans source connue, c'est le reste d'une
                // ancienne copie interrompue qui traînait dans le dossier (vu le 18/11/2026 sur
                // un NAS) : on l'ignore. Avec une source, c'est un élément de cette copie resté
                // incomplet : on ne le liste pas, et l'issue de la copie est douteuse.
                if !candidates.isEmpty { unfinished = true }
                continue
            }
            let present = candidates.filter { fm.fileExists(atPath: $0) }
            seen.append((name, copied.inode, candidates, present.filter { Info($0).map(copied.isCopy(of:)) ?? false }, candidates.filter { !present.contains($0) }))
        }
        // Plusieurs sources identiques possibles (copies de copies) : on retient le dossier qui
        // explique le plus d'éléments.
        var votes: [String: Int] = [:]
        for item in seen { for dir in Set(item.identical.map(dirOf)) { votes[dir, default: 0] += 1 } }
        var sourceDirs = Set<String>()
        for item in seen {
            if item.gone.count == 1 {
                // Une source présente au début a disparu à la fin : c'était un déplacement.
                moved = true
                items.append(Item(name: item.name, source: item.gone[0], inode: item.inode))
            } else if let best = item.identical.map({ votes[dirOf($0)] ?? 0 }).max(),
                      let source = item.identical.first(where: { votes[dirOf($0)] == best }) {   // à égalité : presse-papiers d'abord
                sourceDirs.insert(dirOf(source))
                items.append(Item(name: item.name, source: source, verified: true, inode: item.inode))
            } else {
                items.append(Item(name: item.name, source: item.candidates.count == 1 ? item.candidates[0] : nil, inode: item.inode))
            }
            log("CopyBar: %@ — %d source(s) possible(s), %d identique(s), %d disparue(s)", item.name, item.candidates.count, item.identical.count, item.gone.count)
        }
        // Le disque en dit plus que la fenêtre du Finder sur l'issue de la copie.
        if outcome != .unknown {
            if unfinished {
                if outcome == .done { outcome = .unknown }   // la ligne a disparu avant la fin d'un élément
            } else if seen.isEmpty {
                outcome = .interrupted                // le Finder a retiré ce qu'il avait commencé à écrire
            } else if moved || items.allSatisfy(\.verified) {
                outcome = .done
            }
        }
        // Éléments copiés trop vite pour avoir été vus en cours de route. On ne les ajoute que
        // s'ils sont identiques à un élément du dossier source ET arrivés pendant cette copie :
        // absents du premier relevé, ou ajoutés au dossier après son début (date d'ajout,
        // disponible sur les volumes locaux mais pas sur un NAS).
        let firstAdded = items.compactMap { addedDate(path(of: $0)) }.min()
        if !origin.shared, !moved, !sourceDirs.isEmpty {
            for name in ((try? fm.contentsOfDirectory(atPath: origin.dir)) ?? []).sorted() where !name.hasPrefix(".") && origin.items[name] == nil {
                let path = (origin.dir as NSString).appendingPathComponent(name)
                if origin.baseline.contains(name) {
                    guard let firstAdded, let added = addedDate(path), added >= firstAdded.addingTimeInterval(-5) else { continue }
                }
                guard let copied = Info(path) else { continue }
                let source = sourceDirs.map { ($0 as NSString).appendingPathComponent(name) }
                    .first { Info($0).map(copied.isCopy(of:)) ?? false }
                if let source { items.append(Item(name: name, source: source, verified: true, inode: copied.inode)) }
            }
        }
        guard !items.isEmpty else { return }
        // La fenêtre du Finder n'apparaît que 2 à 3 s après le début : quand le volume la
        // fournit, la date d'ajout au dossier donne le vrai départ.
        if let firstAdded, firstAdded < started, started.timeIntervalSince(firstAdded) < 120 { started = firstAdded }
    }

    /// Taille et nombre de fichiers réellement présents à destination (long sur un gros dossier).
    mutating func measure() {
        let fm = FileManager.default
        guard !items.isEmpty else { return }
        var bytes: Int64 = 0, files = 0
        for item in items {
            let url = URL(fileURLWithPath: path(of: item))
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            let all = [url] + ((fm.enumerator(at: url, includingPropertiesForKeys: Array(keys))?.allObjects as? [URL]) ?? [])
            for file in all {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                bytes += Int64(values.fileSize ?? 0)
                files += 1
            }
        }
        self.bytes = bytes
        self.files = files
    }
}

/// Historique des copies, le plus récent en tête, conservé dans Application Support.
final class History {
    private(set) var entries: [Entry] = []
    private(set) var version = 0          // change à chaque modification : sert à reconstruire le menu
    private static let limit = 50
    private let url: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "CopyBar")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([Entry].self, from: data) { entries = saved }
    }

    subscript(id: UUID) -> Entry? { entries.first { $0.id == id } }

    func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.limit))
        save()
    }

    func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        version += 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(entries).write(to: url, options: .atomic) }
        catch { log("CopyBar: historique non enregistré : %@", "\(error)") }
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let pollQueue = DispatchQueue(label: "copybar.poll", qos: .utility)
    private var timer: DispatchSourceTimer?

    private var tracker = Tracker()
    private var progressWindow: AXUIElement?
    private var trusted = true {
        didSet { if trusted != oldValue { log("CopyBar: accès Accessibilité %@", trusted ? "accordé" : "manquant") } }
    }
    private let session = Session()
    private var blind: String? {
        didSet {
            guard blind != oldValue else { return }
            if let blind { log("CopyBar: relevés suspendus (%@), %d copie(s) en suivi", blind, tracker.copies.count + pending.count) }
            else { log("CopyBar: relevés repris") }
        }
    }
    /// Copies dont la ligne vient de disparaître. On attend quelques secondes avant de
    /// notifier : si la session se verrouille dans l'intervalle, la disparition était un
    /// artefact et les copies retournent dans le suivi.
    private var pending: [(copy: Copy, vanished: Date)] = []
    private static let confirmationDelay: TimeInterval = 3
    private var notifications = UNAuthorizationStatus.notDetermined
    private var polls = 0
    private var copyItems: [(title: NSMenuItem, detail: NSMenuItem)] = []
    private let history = History()
    private var origins: [Int: Origin] = [:]           // chemins des copies en cours, par Copy.id
    private let fileQueue = DispatchQueue(label: "copybar.files", qos: .utility)
    private var builtSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.menu = menu
        menu.autoenablesItems = false
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshNotificationStatus() }
        }

        if !AXIsProcessTrusted() { promptForAccessibility() }
        enableLoginItemOnFirstLaunch()
        render()

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let reading = FinderProbe.read()
            DispatchQueue.main.async { self?.apply(reading) }
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: État

    private func apply(_ reading: Reading) {
        polls += 1
        if polls % 10 == 0 { refreshNotificationStatus() }   // l'utilisateur peut changer le réglage à tout moment
        let known = Set(tracker.copies.map(\.id))
        defer {
            for copy in tracker.copies where !known.contains(copy.id) { log("CopyBar: début — %@", copy.firstTitle) }
            render()
        }
        blind = session.blindReason
        if blind != nil {
            tracker.restore(pending.map(\.copy))    // disparues juste avant le verrouillage : fausse alerte
            pending = []
            return
        }
        defer {
            let now = Date()
            for item in pending where now.timeIntervalSince(item.vanished) >= Self.confirmationDelay { finish(item.copy, vanished: item.vanished) }
            pending.removeAll { now.timeIntervalSince($0.vanished) >= Self.confirmationDelay }
        }
        switch reading {
        case .failed:
            return                                  // surtout ne pas déclarer les copies terminées
        case .untrusted:
            trusted = false
            progressWindow = nil
            _ = tracker.update(with: [])
        case .noFinder:
            trusted = true
            progressWindow = nil
            _ = tracker.update(with: [])            // Finder tué : copies interrompues, pas de notification
        case .ok(let rows, let window, let busy):
            trusted = true
            progressWindow = window
            let now = Date()
            pending += tracker.update(with: rows).map { ($0, now) }
            attribute(busy)
        }
    }

    /// Rattache à leur copie les éléments repérés sur disque en cours de copie.
    private func attribute(_ busy: [Busy]) {
        let copies = tracker.copies
        for item in busy {
            let path = (item.dir as NSString).appendingPathComponent(item.name)
            let quoted = { (copy: Copy) in Title.quoted(copy.row.title) }
            let copy = copies.first { let q = quoted($0); return q.count == 2 && Title.matches(path, q[0]) && Title.matches(item.dir, q[1]) }
                ?? copies.first { origins[$0.id]?.dir == item.dir && quoted($0).count < 2 }
                ?? copies.first { origins[$0.id] == nil && quoted($0).count == 1 && Title.matches(item.dir, quoted($0)[0]) }
                ?? (copies.count == 1 && origins[copies[0].id] == nil && quoted(copies[0]).isEmpty ? copies[0] : nil)
            guard let copy else { continue }
            var origin = origins[copy.id] ?? Origin(dir: item.dir, baseline: item.baseline)
            guard origin.dir == item.dir else { continue }
            if origin.items[item.name] == nil {
                // Copier-coller et glisser-déposer laissent les URL d'origine dans un presse-papiers.
                let pasted = [NSPasteboard(name: .drag), NSPasteboard.general]
                    .flatMap { $0.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] }
                    .map(\.path)
                    .filter { ($0 as NSString).lastPathComponent == item.name && $0 != path }
                var seen = Set<String>()
                origin.items[item.name] = (pasted + item.sources).filter { seen.insert($0).inserted }
                log("CopyBar: %@ → %@ (%d source(s) possible(s))", item.name, item.dir, origin.items[item.name]?.count ?? 0)
            }
            origins[copy.id] = origin
        }
        for (id, origin) in origins where origins.contains(where: { $0.key != id && $0.value.dir == origin.dir }) {
            origins[id]?.shared = true
        }
        let alive = Set(copies.map(\.id) + pending.map(\.copy.id))
        origins = origins.filter { alive.contains($0.key) }
    }

    /// Fin d'une copie : vérifie ses chemins et son issue sur disque, l'inscrit dans
    /// l'historique et notifie. La taille, longue à mesurer, est ajoutée après coup.
    private func finish(_ copy: Copy, vanished: Date) {
        // Disparue pendant une période sans relevés (session verrouillée) : on sait seulement
        // qu'elle n'est plus en cours, ni quand ni comment elle s'est arrêtée.
        let unseen = vanished.timeIntervalSince(copy.seen) > 10
        let guess: Entry.Outcome = unseen ? .unknown : copy.wasInterrupted(at: vanished) ? .interrupted : .done
        var entry = Entry(title: copy.firstTitle, started: copy.started, ended: vanished, outcome: guess,
                          fraction: copy.row.fraction, total: Title.total(copy.row.detail))
        let origin = origins.removeValue(forKey: copy.id)
        fileQueue.async { [weak self] in
            if let origin { entry.resolve(origin) }
            let resolved = entry
            DispatchQueue.main.async {
                self?.history.add(resolved)
                self?.notify(resolved)
                self?.render()
            }
            entry.measure()
            let (bytes, files) = (entry.bytes, entry.files)
            DispatchQueue.main.async {
                self?.history.update(resolved.id) { $0.bytes = bytes; $0.files = files }
                self?.render()
            }
        }
    }

    // MARK: Affichage

    private static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "…" }
        let value = Int((fraction * 100).rounded(.down))
        return L("\(value) %", "\(value)%")
    }

    private func render() {
        let copies = tracker.copies
        guard let button = statusItem.button else { return }

        if !trusted {
            button.image = symbol("exclamationmark.triangle")
            button.title = ""
        } else if copies.isEmpty {
            button.image = symbol("doc.on.doc")
            button.title = ""
        } else {
            button.image = symbol("doc.on.doc.fill")
            let known = copies.compactMap(\.row.fraction)
            let mean = known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
            button.title = " " + Self.percent(mean) + (copies.count > 1 ? " (\(copies.count))" : "")
        }
        button.toolTip = copies.isEmpty ? L("CopyBar — aucune copie en cours", "CopyBar — no copy in progress") : copies.map(\.row.title).joined(separator: "\n")

        // On ne reconstruit le menu que si sa structure change, pour qu'il reste utilisable
        // (surbrillance conservée) pendant qu'il est ouvert et que les pourcentages défilent.
        let signature = "\(trusted)|\(notifications.rawValue)|\(copies.map { String($0.id) }.joined(separator: ","))|\(progressWindow != nil)|\(history.version)"
        if signature != builtSignature {
            builtSignature = signature
            rebuildMenu(copies)
        }
        for (items, copy) in zip(copyItems, copies) {
            items.title.title = "\(Self.percent(copy.row.fraction)) — \(copy.row.title)"
            items.detail.title = copy.row.detail.isEmpty ? L("Préparation…", "Preparing…") : copy.row.detail
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "CopyBar")
        image?.isTemplate = true
        return image
    }

    private func rebuildMenu(_ copies: [Copy]) {
        menu.removeAllItems()
        copyItems = []

        if !trusted {
            add(L("Autoriser l’accès Accessibilité…", "Grant Accessibility Access…"), #selector(promptForAccessibility))
            let hint = add(L("Nécessaire pour lire la progression du Finder", "Required to read Finder’s progress"), nil)
            hint.isEnabled = false
        } else if copies.isEmpty {
            add(L("Aucune copie en cours", "No copy in progress"), nil).isEnabled = false
        } else {
            add(copies.count == 1 ? L("1 copie en cours", "1 copy in progress") : L("\(copies.count) copies en cours", "\(copies.count) copies in progress"), nil).isEnabled = false
            for _ in copies {
                let title = add("", #selector(raiseProgressWindow))
                let detail = add("", nil)
                detail.isEnabled = false
                detail.indentationLevel = 1
                copyItems.append((title, detail))
            }
        }

        if notifications != .authorized && notifications != .provisional {
            menu.addItem(.separator())
            add(L("Activer les notifications…", "Enable Notifications…"), #selector(enableNotifications))
        }

        menu.addItem(.separator())
        add(L("Afficher la fenêtre de progression", "Show Progress Window"), #selector(raiseProgressWindow)).isEnabled = progressWindow != nil
        let past = add(L("Historique", "History"), nil)
        past.isEnabled = true
        past.submenu = historyMenu()
        menu.addItem(.separator())
        add(L("Lancer au login", "Launch at Login"), #selector(toggleLoginItem)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        add(L("À propos de CopyBar \(version)", "About CopyBar \(version)"), #selector(showAbout))
        add(L("Quitter CopyBar", "Quit CopyBar"), #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector?, key: String = "", to target: NSMenu? = nil, entry: Entry? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = entry?.id
        item.isEnabled = action != nil
        (target ?? menu).addItem(item)
        return item
    }

    // MARK: Historique

    private func historyMenu() -> NSMenu {
        let list = NSMenu()
        list.autoenablesItems = false
        if history.entries.isEmpty { add(L("Aucune copie enregistrée", "No copies recorded"), nil, to: list) }
        for entry in history.entries {
            let item = add(Self.when(entry.ended) + "  " + Self.summary(entry), nil, to: list)
            item.isEnabled = true
            item.image = symbol(entry.undone != nil ? "arrow.uturn.backward.circle" : entry.outcome == .done ? "checkmark.circle"
                                : entry.outcome == .interrupted ? "xmark.circle" : "questionmark.circle")
            item.submenu = detailMenu(entry)
        }
        list.addItem(.separator())
        add(L("Effacer l’historique", "Clear History"), #selector(clearHistory), to: list).isEnabled = !history.entries.isEmpty
        return list
    }

    private func detailMenu(_ entry: Entry) -> NSMenu {
        let detail = NSMenu()
        detail.autoenablesItems = false
        add(entry.title, nil, to: detail)
        if entry.items.count == 1 {
            add(L("Élément : ", "Item: ") + entry.items[0].name, nil, to: detail)
        } else if entry.items.count > 1 {
            add(L("\(entry.items.count) éléments identifiés :", "\(entry.items.count) items identified:"), nil, to: detail)
            for item in entry.items.prefix(8) { add(item.name, nil, to: detail).indentationLevel = 1 }
            if entry.items.count > 8 { add(L("… et \(entry.items.count - 8) autres", "… and \(entry.items.count - 8) more"), nil, to: detail).indentationLevel = 1 }
        }
        if let source = entry.source {
            add((entry.moved ? L("Déplacé de : ", "Moved from: ") : L("De : ", "From: ")) + Self.short(source), #selector(openSource(_:)), to: detail, entry: entry)
        } else {
            add(L("De : provenance non identifiée", "From: source not identified"), nil, to: detail)
        }
        if let destination = entry.destination {
            add(L("Vers : ", "To: ") + Self.short(destination), #selector(openDestination(_:)), to: detail, entry: entry)
        } else {
            add(L("Vers : destination non identifiée", "To: destination not identified"), nil, to: detail)
        }
        add(Self.stats(entry), nil, to: detail)
        add(Self.status(entry), nil, to: detail)
        detail.addItem(.separator())
        add(L("Afficher dans le Finder", "Show in Finder"), #selector(reveal(_:)), to: detail, entry: entry).isEnabled = !entry.items.isEmpty && entry.undone == nil
        if entry.undone == nil, !entry.canUndo {
            add(L("Marche arrière indisponible : provenance non vérifiée", "Undo unavailable: source not verified"), nil, to: detail)
        } else {
            add(L("Faire marche arrière…", "Undo…"), #selector(undo(_:)), to: detail, entry: entry)
                .isEnabled = entry.canUndo
        }
        add(L("Retirer de l’historique", "Remove from History"), #selector(forget(_:)), to: detail, entry: entry)
        return detail
    }

    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jm" : "dMjm")
        return formatter.string(from: date)
    }

    private static func short(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func summary(_ entry: Entry) -> String {
        guard let destination = entry.destination, !entry.items.isEmpty else { return entry.title }
        let what = entry.items.count == 1 ? entry.items[0].name : L("\(entry.items.count) éléments", "\(entry.items.count) items")
        return "\(what) → \(FileManager.default.displayName(atPath: destination))"
    }

    private static func duration(_ entry: Entry) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: max(1, entry.ended.timeIntervalSince(entry.started))) ?? ""
    }

    private static func stats(_ entry: Entry) -> String {
        var parts: [String] = []
        if let bytes = entry.bytes, let files = entry.files {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            parts.append(files == 1 ? L("1 fichier", "1 file") : L("\(files) fichiers", "\(files) files"))
            let seconds = entry.ended.timeIntervalSince(entry.started)
            if entry.outcome == .done, seconds >= 1 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(Double(bytes) / seconds), countStyle: .file) + "/s")
            }
        } else if let total = entry.total {
            parts.append(total)
        }
        parts.insert(duration(entry), at: min(parts.count, 2))
        return parts.joined(separator: " · ")
    }

    private static func status(_ entry: Entry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        if let undone = entry.undone { return L("Marche arrière faite le ", "Undone on ") + formatter.string(from: undone) }
        switch entry.outcome {
        case .done: return L("Terminée le ", "Finished on ") + formatter.string(from: entry.ended)
        case .interrupted: return L("Interrompue vers \(percent(entry.fraction)) le ", "Interrupted at about \(percent(entry.fraction)) on ") + formatter.string(from: entry.ended)
        case .unknown: return L("Fin non observée, issue non vérifiable", "End not observed, outcome unknown")
        }
    }

    private func entry(_ sender: NSMenuItem) -> Entry? {
        (sender.representedObject as? UUID).flatMap { history[$0] }
    }

    @objc private func openSource(_ sender: NSMenuItem) {
        if let source = entry(sender)?.source { NSWorkspace.shared.open(URL(fileURLWithPath: source)) }
    }

    @objc private func openDestination(_ sender: NSMenuItem) {
        if let destination = entry(sender)?.destination { NSWorkspace.shared.open(URL(fileURLWithPath: destination)) }
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let entry = entry(sender) else { return }
        let urls = entry.items.map { URL(fileURLWithPath: entry.path(of: $0)) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { openDestination(sender) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc private func forget(_ sender: NSMenuItem) {
        if let entry = entry(sender) { history.remove(entry.id) }
        render()
    }

    @objc private func clearHistory() {
        history.clear()
        render()
    }

    // MARK: Marche arrière

    private func ask(_ message: String, _ text: String, confirm: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = text
        if let confirm {
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: L("Annuler", "Cancel"))
        }
        return alert.runModal() == .alertFirstButtonReturn && confirm != nil
    }

    /// Copie : les éléments copiés partent à la corbeille, les originaux ne sont pas touchés.
    /// Déplacement : les éléments retournent à leur emplacement d'origine.
    @objc private func undo(_ sender: NSMenuItem) {
        guard let entry = entry(sender), entry.canUndo, let destination = entry.destination else { return }
        let names = entry.items.prefix(10).map { "• " + $0.name }.joined(separator: "\n")
            + (entry.items.count > 10 ? L("\n… et \(entry.items.count - 10) autres", "\n… and \(entry.items.count - 10) more") : "")
        let text: String
        if entry.moved {
            let origin = entry.source.map(Self.short) ?? L("leur dossier d’origine", "their original folder")
            text = entry.items.count == 1
                ? L("L’élément suivant sera remis dans « \(origin) » :\n\(names)", "The following item will be put back in “\(origin)”:\n\(names)")
                : L("Les \(entry.items.count) éléments suivants seront remis dans « \(origin) » :\n\(names)", "The following \(entry.items.count) items will be put back in “\(origin)”:\n\(names)")
        } else {
            let from = Self.short(destination)
            let what = entry.items.count == 1
                ? L("L’élément suivant sera mis à la corbeille depuis « \(from) » :", "The following item will be moved to the Trash from “\(from)”:")
                : L("Les \(entry.items.count) éléments suivants seront mis à la corbeille depuis « \(from) » :", "The following \(entry.items.count) items will be moved to the Trash from “\(from)”:")
            let originals = entry.source.map(Self.short).map { L("Les originaux dans « \($0) » ne sont pas touchés.", "The originals in “\($0)” are left untouched.") }
                ?? L("Les originaux ne sont pas touchés.", "The originals are left untouched.")
            text = "\(what)\n\(names)\n\n\(originals)"
        }
        guard ask(L("Faire marche arrière ?", "Undo this operation?"), text, confirm: entry.moved ? L("Remettre à sa place", "Put Back") : L("Mettre à la corbeille", "Move to Trash")) else { return }

        fileQueue.async { [weak self] in
            let fm = FileManager.default
            var done = 0, problems: [String] = [], untrashable: [Entry.Item] = []
            for item in entry.items {
                let path = entry.path(of: item)
                guard let inode = Entry.inode(path) else { problems.append(L("\(item.name) : introuvable", "\(item.name): not found")); continue }
                guard inode == item.inode else { problems.append(L("\(item.name) : a été remplacé depuis la copie, laissé en place", "\(item.name): replaced since the copy, left in place")); continue }
                guard let source = item.source else { continue }
                do {
                    if entry.moved {
                        guard !fm.fileExists(atPath: source) else { problems.append(L("\(item.name) : un élément du même nom existe déjà à l’origine", "\(item.name): an item with the same name already exists at the original location")); continue }
                        try fm.moveItem(atPath: path, toPath: source)
                    } else {
                        guard fm.fileExists(atPath: source) else { problems.append(L("\(item.name) : l’original est introuvable, copie laissée en place", "\(item.name): original not found, copy left in place")); continue }
                        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    }
                    done += 1
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFeatureUnsupportedError && !entry.moved {
                    untrashable.append(item)                      // volume sans corbeille (certains NAS)
                } catch {
                    problems.append("\(item.name) : \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if !untrashable.isEmpty, self.ask(L("Pas de corbeille sur ce volume", "This volume has no Trash"),
                        L("\(untrashable.count) élément(s) de « \(Self.short(destination)) » ne peuvent pas aller à la corbeille. Les supprimer définitivement ?\n",
                          "\(untrashable.count) item(s) in “\(Self.short(destination))” cannot be moved to the Trash. Delete them permanently?\n")
                        + untrashable.prefix(10).map { "• " + $0.name }.joined(separator: "\n"), confirm: L("Supprimer définitivement", "Delete Permanently")) {
                    for item in untrashable {
                        let path = entry.path(of: item)
                        do {
                            guard Entry.inode(path) == item.inode, let source = item.source, fm.fileExists(atPath: source) else { continue }
                            try fm.removeItem(atPath: path)
                            done += 1
                        } catch { problems.append("\(item.name) : \(error.localizedDescription)") }
                    }
                }
                log("CopyBar: marche arrière — %@ : %d élément(s) traité(s), %d problème(s)", entry.title, done, problems.count)
                if done > 0 { self.history.update(entry.id) { $0.undone = Date() } }
                self.render()
                if !problems.isEmpty {
                    _ = self.ask(done > 0 ? L("Marche arrière partielle", "Undo partially done") : L("Marche arrière impossible", "Undo failed"), problems.joined(separator: "\n"), confirm: nil)
                }
            }
        }
    }

    // MARK: Actions

    @objc private func raiseProgressWindow() {
        guard let window = progressWindow else { return }
        pollQueue.async { FinderProbe.raise(window) }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: L("Suit les copies du Finder depuis la barre de menus.", "Keeps an eye on Finder copies from the menu bar."),
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor]),
        ])
    }

    @objc private func promptForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            log("CopyBar: lancement au login impossible : %@", "\(error)")
        }
        builtSignature = ""
        render()
    }

    /// Activé d'office au premier lancement ; ensuite seul le menu décide.
    private func enableLoginItemOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
            log("CopyBar: lancement au login activé")
        } catch {
            log("CopyBar: lancement au login impossible : %@", "\(error)")
        }
    }

    // MARK: Notifications

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, settings.authorizationStatus != self.notifications else { return }
                self.notifications = settings.authorizationStatus
                let names: [UNAuthorizationStatus: String] = [.notDetermined: "non décidées", .denied: "refusées", .authorized: "autorisées", .provisional: "provisoires"]
                log("CopyBar: notifications %@", names[settings.authorizationStatus] ?? "?")
                self.render()
            }
        }
    }

    /// Redemande l'autorisation ; si macOS ne veut plus poser la question, ouvre les Réglages.
    @objc private func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refreshNotificationStatus()
                if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func notify(_ entry: Entry) {
        let content = UNMutableNotificationContent()
        let state: String
        switch entry.outcome {
        case .done:
            state = "terminé"
            content.title = entry.moved ? L("Déplacement terminé", "Move finished") : L("Copie terminée", "Copy finished")
            content.body = entry.title + "\n" + L("Durée : ", "Duration: ") + Self.duration(entry)
        case .interrupted:
            state = "interrompu"
            content.title = L("Copie interrompue", "Copy interrupted")
            content.body = entry.title + "\n" + L("Arrêtée vers \(Self.percent(entry.fraction)) après \(Self.duration(entry))", "Stopped at about \(Self.percent(entry.fraction)) after \(Self.duration(entry))")
        case .unknown:
            state = "fin non observée"
            content.title = L("Copie sortie des relevés", "Copy lost from view")
            content.body = entry.title + "\n" + L("Dernier relevé : \(Self.percent(entry.fraction)). Issue non vérifiable.", "Last reading: \(Self.percent(entry.fraction)). Outcome unknown.")
        }
        content.sound = .default
        log("CopyBar: %@ — %@ (%@, dernier relevé %@)", state, entry.title, Self.duration(entry), Self.percent(entry.fraction))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { log("CopyBar: notification refusée : %@", "\(error)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
