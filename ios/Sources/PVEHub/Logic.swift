import Foundation

// Logique sans interface (testée sous Linux par Checks/main.swift)

// MARK: - JSON dynamique
// L'API de PVE Hub renvoie tel quel ce que donne Proxmox (nombres parfois en texte, champs absents) :
// un accès souple évite des dizaines de modèles Codable fragiles.
@dynamicMemberLookup
struct J: Identifiable {
    let v: Any?
    init(_ v: Any?) { self.v = v is NSNull ? nil : v }

    subscript(dynamicMember k: String) -> J { self[k] }
    subscript(_ k: String) -> J { J((v as? [String: Any])?[k]) }

    var str: String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
    var num: Double { (v as? NSNumber)?.doubleValue ?? Double(str) ?? 0 }
    var opt: Double? { v == nil ? nil : ((v as? NSNumber)?.doubleValue ?? Double(str)) }
    var int: Int { Int(num) }
    var bool: Bool {
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return !s.isEmpty && s != "0" }
        return v != nil
    }
    var arr: [J] { (v as? [Any])?.map { J($0) } ?? [] }
    var strs: [String] { arr.map(\.str) }
    var dict: [String: Any] { v as? [String: Any] ?? [:] }
    var isNil: Bool { v == nil }
    var id: String {
        for k in ["id", "volid", "upid", "vmid", "name", "dev", "i"] {
            let s = self[k].str
            if !s.isEmpty { return s }
        }
        return self["ts"].str + self["title"].str
    }
}

// MARK: - Formats
func fb(_ n: Double) -> String {
    var n = n
    let u = ["o", "Ko", "Mo", "Go", "To"]
    var i = 0
    while n >= 1024 && i < 4 { n /= 1024; i += 1 }
    return String(format: i < 2 ? "%.0f" : "%.1f", n).replacingOccurrences(of: ".", with: ",") + " " + u[i]
}
func pct(_ a: Double, _ b: Double) -> Double { b > 0 ? min(100, a / b * 100) : 0 }
func up(_ s: Double) -> String {
    let s = Int(s), d = s / 86400, h = s % 86400 / 3600
    return d > 0 ? "\(d) j \(h) h" : "\(h) h \(s % 3600 / 60) min"
}
func kind(_ t: String) -> String { t == "qemu" ? "VM" : "CT" }
func p0(_ v: Double) -> String { String(format: "%.0f", v) }
let STATUS = ["running": "En marche", "stopped": "Arrêtée", "paused": "En pause", "online": "En ligne", "offline": "Hors ligne"]

private func fmt(_ template: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "fr_FR")
    f.setLocalizedDateFormatFromTemplate(template)
    return f
}
private let fWhen = fmt("dMMMHHmm"), fDay = fmt("EEEEdMMMM"), fHM = fmt("HHmm"), fFull = fmt("EEEEdMMMMHHmm")
func date(_ ts: Double) -> Date { Date(timeIntervalSince1970: ts) }
func when(_ ts: Double) -> String { fWhen.string(from: date(ts)) }
func hm(_ ts: Double) -> String { fHM.string(from: date(ts)) }
func fullWhen(_ ts: Double) -> String { fFull.string(from: date(ts)) }
func ago(_ ts: Double) -> String {
    let s = Date().timeIntervalSince1970 - ts
    return s < 3600 ? "il y a \(max(1, Int((s / 60).rounded()))) min" : s < 86400 ? "il y a \(Int((s / 3600).rounded())) h" : "il y a \(Int((s / 86400).rounded())) j"
}
func dayLabel(_ ts: Double) -> String {
    let cal = Calendar.current, d = date(ts)
    if cal.isDateInToday(d) { return "Aujourd'hui" }
    if cal.isDateInYesterday(d) { return "Hier" }
    return fDay.string(from: d).capitalizedFirst
}
/// « 23:00 » ↔ Date du jour, pour les DatePicker d'heure
func hmDate(_ s: String) -> Date {
    let p = s.split(separator: ":").compactMap { Int($0) }
    return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
}
func hmString(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}
func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n > 1 ? "s" : "")" }
func withScheme(_ u: String) -> String { u.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil ? u : "http://" + u }

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Valeur JSON facultative : null plutôt qu'un Optional que JSONSerialization refuserait
func orNull(_ v: Any?) -> Any { v ?? NSNull() }

// MARK: - Plannings
// Planification cron → français ; nil si trop exotique (on affiche alors l'expression brute)
let DAYS = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
let DAYN = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
func cronFr(_ s: String) -> String? {
    let sp = ["@reboot": "Au démarrage", "@hourly": "Toutes les heures", "@daily": "Tous les jours à 00:00", "@midnight": "Tous les jours à 00:00",
              "@weekly": "Le dimanche à 00:00", "@monthly": "Le 1er du mois à 00:00", "@yearly": "Le 1er janvier à 00:00", "@annually": "Le 1er janvier à 00:00"]
    if let x = sp[s.lowercased()] { return x }
    let p = s.split(separator: " ").map(String.init)
    guard p.count == 5 else { return nil }
    let (mi, h, dom, mon, dow) = (p[0], p[1], p[2], p[3], p[4])
    let num = { (x: String) in !x.isEmpty && x.allSatisfy(\.isNumber) }
    let every = { (x: String) -> String? in x.hasPrefix("*/") && num(String(x.dropFirst(2))) ? String(x.dropFirst(2)) : nil }
    let pad = { (x: String) in x.count < 2 ? "0" + x : x }
    if mon != "*" { return nil }
    if mi == "*" && h == "*" && dom == "*" && dow == "*" { return "Chaque minute" }
    if let m = every(mi), h == "*", dom == "*", dow == "*" { return "Toutes les \(m) minutes" }
    if num(mi) && h == "*" && dom == "*" && dow == "*" { return "Toutes les heures à :\(pad(mi))" }
    if num(mi), let m = every(h), dom == "*", dow == "*" { return "Toutes les \(m) heures à :\(pad(mi))" }
    guard num(mi), num(h) else { return nil }
    let t = "\(pad(h)):\(pad(mi))"
    if dom == "*" && dow == "*" { return "Tous les jours à \(t)" }
    let day = { (x: String) -> String? in num(x) ? (Int(x).flatMap { $0 < DAYS.count ? DAYS[$0] : nil }) : DAYN[x.lowercased()].map { DAYS[$0] } }
    if dom == "*" {
        let r = dow.split(separator: "-").map(String.init)
        if r.count == 2, let a = day(r[0]), let b = day(r[1]) { return "Du \(a) au \(b) à \(t)" }
        let ds = dow.split(separator: ",").map { day(String($0)) }
        guard ds.allSatisfy({ $0 != nil }) else { return nil }
        let names = ds.compactMap { $0 }
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " et " + names.last! : names.joined()
        return "Le \(list) à \(t)"
    }
    if num(dom) && dow == "*" { return "Le \(dom == "1" ? "1er" : dom) de chaque mois à \(t)" }
    return nil
}

private let DOW_PVE = ["mon": "lundi", "tue": "mardi", "wed": "mercredi", "thu": "jeudi", "fri": "vendredi", "sat": "samedi", "sun": "dimanche"]
/// Format calendrier de Proxmox : « 01:00 », « sun 02:00 », « mon..fri 21:00 »…
func scheduleFr(_ s0: String) -> String {
    let s = s0.trimmed
    // « 1:30 » → « 01:30 » ; nil si ce n'est pas une heure (comme \d{1,2}:\d{2} dans la version web)
    let time = { (t: Substring) -> String? in
        let hm = t.split(separator: ":", omittingEmptySubsequences: false)
        guard hm.count == 2, (1...2).contains(hm[0].count), hm[1].count == 2, (hm[0] + hm[1]).allSatisfy(\.isASCII), (hm[0] + hm[1]).allSatisfy(\.isNumber) else { return nil }
        return (hm[0].count < 2 ? "0" : "") + hm[0] + ":" + hm[1]
    }
    let parts = s.split(separator: " ")
    if parts.count == 1, let t = time(parts[0]) { return "Tous les jours à \(t)" }
    if parts.count == 2, let t = time(parts[1]) {
        let r = parts[0].components(separatedBy: "..")
        if r.count == 2, let a = DOW_PVE[r[0]], let b = DOW_PVE[r[1]] { return "Du \(a) au \(b) à \(t)" }
        let ds = parts[0].split(separator: ",").map { DOW_PVE[String($0)] }
        if ds.allSatisfy({ $0 != nil }) {
            let n = ds.compactMap { $0 }
            return "Le \(n.count > 1 ? n.dropLast().joined(separator: ", ") + " et " + n.last! : n.joined()) à \(t)"
        }
    }
    return s.isEmpty ? "Planification inconnue" : s
}
func bkWho(_ j: J) -> String {
    j.all.bool ? "Toutes les machines" + (j.exclude.str.isEmpty ? "" : " sauf " + j.exclude.str.replacingOccurrences(of: ",", with: ", "))
               : "Machines " + j.vmid.str.replacingOccurrences(of: ",", with: ", ")
}

/// Planification Proxmox → (heure, jours), ou nil si elle ne rentre pas dans les préréglages
func bkParse(_ sc: String) -> (String, String)? {
    let p = sc.trimmed.split(separator: " ").map(String.init)
    guard (1...2).contains(p.count) else { return nil }
    let hm = p.last!.split(separator: ":")
    guard hm.count == 2, let h = Int(hm[0]), hm[1].count == 2, Int(hm[1]) != nil else { return nil }
    let days = p.count == 1 ? "all" : ["mon..fri": "week", "sat,sun": "weekend", "sun": "sun"][p[0]]
    guard let days else { return nil }
    return (String(format: "%02d:%@", h, String(hm[1])), days)
}

func uaName(_ u: String) -> String {
    for (k, n) in [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("Mac OS", "Mac"), ("Windows", "Windows"), ("Linux", "Linux")] where u.contains(k) { return n }
    return "Appareil inconnu"
}

// MARK: - Hermes
let ACTION_RE = try! NSRegularExpression(pattern: "```pvehub\\n?([\\s\\S]*?)```")
private let LXC_RE = try! NSRegularExpression(pattern: #"printf\s+'approve %s ([^'\\]+?)\\n'\s+"\$\(date \+%s\)"\s*>\s*/root/\.lxc-approve"#)
func matches(_ re: NSRegularExpression, _ s: String) -> [String] {
    re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]).trimmed } }
}
func lxcGrants(_ content: String) -> [String] {
    var seen = Set<String>()
    return matches(LXC_RE, content).filter { seen.insert($0).inserted }
}

/// Découpe une réponse de Hermes : (langue, contenu), langue nil pour le texte ; un bloc pas encore fermé va jusqu'à la fin
func splitMessage(_ text: String) -> [(String?, String)] {
    var out: [(String?, String)] = []
    var rest = Substring(text)
    while let open = rest.range(of: "```") {
        out.append((nil, String(rest[..<open.lowerBound])))
        let after = rest[open.upperBound...]
        // comme la version web : la langue est collée aux ```, puis un saut de ligne facultatif
        let langEnd = after.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } ?? after.endIndex
        let lang = String(after[..<langEnd])
        var bodyStart = langEnd
        if bodyStart < after.endIndex, after[bodyStart] == "\n" { bodyStart = after.index(after: bodyStart) }
        if let close = after[bodyStart...].range(of: "```") {
            out.append((lang.lowercased(), String(after[bodyStart..<close.lowerBound])))
            rest = after[close.upperBound...]
        } else {  // bloc pas encore fermé (réponse en cours)
            out.append((lang.lowercased(), String(after[bodyStart...])))
            rest = ""
        }
    }
    out.append((nil, String(rest)))
    return out.filter { $0.0 != nil || !$0.1.trimmed.isEmpty }
}
