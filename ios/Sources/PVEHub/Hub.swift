import SwiftUI
import UserNotifications

enum Tab: Hashable { case server, guests, apps, exec, chat }

/// Écrans poussés dans une pile de navigation
enum Route: Hashable {
    case guest(String), maint, journal(String), sched, store, chats
}

@ViewBuilder
func destination(_ r: Route) -> some View {
    switch r {
    case .guest(let id): GuestDetail(id: id)
    case .maint: MaintView()
    case .journal(let f): JournalView(filter: f)
    case .sched: SchedView()
    case .store: StoreView()
    case .chats: ChatsView()
    }
}

/// État partagé de l'app (l'équivalent de l'objet S de la version web)
@MainActor
final class Hub: ObservableObject {
    static let shared = Hub()

    @Published var loggedIn = false
    @Published var starting = true
    @Published var ov: J?
    @Published var online = true
    @Published var sched: [J]?
    @Published var ver: J?
    @Published var toasts: [Toast] = []
    @Published var tab: Tab = .server
    @Published var taskTick = 0                // une tâche Proxmox vient de finir : les fiches se rechargent
    @Published var showSettings = false
    @Published var textSheet: TextSheet?
    @Published var serverPath = NavigationPath()
    @Published var guestsPath = NavigationPath()
    @Published var appsPath = NavigationPath()
    @Published var chatPath = NavigationPath()
    // onglet Commandes : cible ({"type":"host"} ou machine) et commande préremplie
    @Published var execTarget = ""
    @Published var execCommand = ""
    // maintenance (résumé sur l'écran Serveur)
    @Published var mB: J?
    @Published var mU: J?
    @Published var mD: J?
    @Published var mJobs: [String: J] = [:]
    var mDAt = Date.distantPast
    // apps : dernier résultat gardé sur l'appareil, l'onglet s'affiche tout de suite puis se met à jour
    @Published var apps: [J]? = (UserDefaults.standard.data(forKey: "apps")).flatMap { try? JSONSerialization.jsonObject(with: $0) }.map { J($0).arr }
    @Published var appsFull = false
    @Published var appsScan = UserDefaults.standard.data(forKey: "apps") != nil
    @Published var appsErr: String?
    var appsAt = Date.distantPast
    private var appsAsk = UUID()
    // store
    @Published var storeJobs: [String: [String: Any]] = (UserDefaults.standard.data(forKey: "storeJobs"))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
    var storeOpts: [J]?

    let chat = ChatModel()

    var guests: [J] { ov?.guests.arr ?? [] }
    var hermes: Bool { ov?.hermes.bool ?? false }
    var exec: Bool { ov?.exec.bool ?? false }
    func guest(_ id: String) -> J? { guests.first { $0.id == id } }
    func guest(vmid: String) -> J? { guests.first { $0.vmid.str == vmid } }

    init() {
        API.shared.onUnauthorized = { [weak self] in self?.loggedIn = false }
    }

    // MARK: démarrage et rafraîchissement
    func start() async {
        starting = true
        defer { starting = false }
        guard !API.shared.server.isEmpty else { loggedIn = false; return }
        do {
            ov = try await API.shared.get("/api/overview")
            loggedIn = true
            await afterLogin()
        } catch {
            if (error as? APIError)?.message != "Non connecté" { online = false; loggedIn = Keychain.get() != nil }
        }
    }

    func afterLogin() async {
        Task { await refreshPush() }
        async let s: () = loadSched()
        async let v: () = checkVersion()
        async let m: () = loadMaint()
        async let c: () = chat.initChats()
        _ = await (s, v, m, c)
    }

    func refresh() async {
        do {
            ov = try await API.shared.get("/api/overview")
            online = true
            if !hermes && tab == .chat { tab = .server }
        } catch {
            if (error as? APIError)?.message != "Non connecté" { online = false }
        }
    }

    func logout() async {
        _ = try? await API.shared.post("/api/logout")
        Keychain.set(nil)
        UserDefaults.standard.removeObject(forKey: "apps")
        ov = nil
        loggedIn = false
    }

    // MARK: toasts
    @discardableResult
    func toast(_ text: String, seconds: Double = 3.5) -> UUID {
        let t = Toast(text: text)
        toasts.append(t)
        let id = t.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.dismissToast(id)
        }
        return id
    }
    func dismissToast(_ id: UUID) { toasts.removeAll { $0.id == id } }
    func fail(_ error: Error, seconds: Double = 5) { toast("❌ " + error.localizedDescription, seconds: seconds) }

    // MARK: actions sur les machines (boutons et Hermes)
    struct Act { let label: String; var danger = false; var warn: String? = nil; let path: String }
    static let ACT: [String: Act] = [
        "start": Act(label: "Démarrer", path: "/api/power"),
        "shutdown": Act(label: "Éteindre", path: "/api/power"),
        "reboot": Act(label: "Redémarrer", path: "/api/power"),
        "stop": Act(label: "Forcer l'arrêt de", danger: true, warn: "Équivaut à débrancher la prise : risque de perte de données.", path: "/api/power"),
        "snapshot": Act(label: "Snapshot de", path: "/api/snapshot"),
        "rollback": Act(label: "Revenir au snapshot", danger: true, warn: "L'état actuel de la machine sera perdu.", path: "/api/snapshot/rollback"),
        "snapdelete": Act(label: "Supprimer le snapshot", danger: true, path: "/api/snapshot/delete"),
        "backup": Act(label: "Sauvegarder", path: "/api/backup"),
        "restore": Act(label: "Restaurer la sauvegarde sur", danger: true, warn: "La machine sera écrasée. Elle doit être arrêtée.", path: "/api/restore"),
    ]
    /// Actions que l'on peut pré-autoriser pour Hermes (jamais les destructrices)
    static let AUTO_OK: [(String, String)] = [("start", "Démarrer une machine"), ("shutdown", "Éteindre une machine"),
                                              ("reboot", "Redémarrer une machine"), ("snapshot", "Créer un snapshot"), ("backup", "Lancer une sauvegarde")]

    func describe(_ a: [String: Any]) -> String {
        let action = a["action"] as? String ?? "?", vmid = J(a["vmid"]).str
        let g = guest(vmid: vmid)
        let type = a["type"] as? String ?? g?.type.str ?? ""
        let name = g.map { $0.name.str }.flatMap { $0.isEmpty ? nil : " « \($0) »" } ?? ""
        let extra = (a["name"] as? String).map { action == "snapshot" ? " « \($0) »" : " (\($0))" } ?? ""
        return "\(Hub.ACT[action]?.label ?? action) \(kind(type)) \(vmid)\(name)\(extra)"
    }

    /// Lance une action ; nil si annulée, sinon « OK » ou le message d'erreur.
    @discardableResult
    func runAction(_ a0: [String: Any], skipConfirm: Bool = false) async -> String? {
        let action = a0["action"] as? String ?? ""
        guard let d = Hub.ACT[action] else { toast("Action inconnue : \(action)"); return nil }
        var a = a0
        let g = guest(vmid: J(a["vmid"]).str)
        if a["node"] == nil { a["node"] = g?.node.str }
        if a["type"] == nil { a["type"] = g?.type.str }
        guard (a["node"] as? String)?.isEmpty == false, (a["type"] as? String)?.isEmpty == false else {
            toast("Machine introuvable : \(J(a["vmid"]).str)"); return nil
        }
        let text = describe(a)
        if !skipConfirm, !(await Dialog.confirm(text + " ?", d.warn, d.danger ? "Confirmer" : d.label, danger: d.danger)) { return nil }
        do {
            let r = try await API.shared.post(d.path, a)
            return await track(r, text)
        } catch {
            fail(error)
            return error.localizedDescription
        }
    }

    /// Suit une tâche Proxmox jusqu'à la fin ; renvoie « OK » ou le message d'erreur.
    func track(_ res: J, _ label: String) async -> String {
        let t = toast("⏳ \(label)…", seconds: 600)
        defer { dismissToast(t) }
        for i in 0..<900 {
            try? await Task.sleep(for: .seconds(i < 5 ? 1 : 2.5))
            do {
                let s = try await API.shared.get("/api/task", ["node": res.node.str, "upid": res.upid.str])
                if s.status.str == "stopped" {
                    let ok = s.exitstatus.str == "OK"
                    toast("\(ok ? "✅" : "❌") \(label)\(ok ? "" : " : " + s.exitstatus.str)", seconds: 5)
                    await refresh()
                    taskTick += 1
                    return s.exitstatus.str
                }
            } catch {
                fail(error)
                return error.localizedDescription
            }
        }
        return "toujours en cours"
    }

    // MARK: horaires
    func loadSched() async {
        if let r = try? await API.shared.get("/api/schedules") { sched = r.items.arr }
    }
    @discardableResult
    func saveSched(_ body: [String: Any]) async -> Bool {
        do { sched = try await API.shared.post("/api/schedules", body).items.arr; return true }
        catch { fail(error); return false }
    }
    func tName(_ t: J) -> String {
        guests.first { $0.vmid.str == t.vmid.str && $0.type.str == t.type.str }.map { $0.name.str } ?? "\(kind(t.type.str)) \(t.vmid.str)"
    }

    // MARK: maintenance
    func loadMaint(refresh: Bool = false) async {
        async let b = try? API.shared.get("/api/maint/backups")
        async let u = try? API.shared.get("/api/maint/updates", refresh ? ["refresh": "1"] : [:])
        // SMART : pas plus d'une fois toutes les 5 min
        let cur = mD, reuseDisks = mD != nil && !refresh && Date().timeIntervalSince(mDAt) < 300
        var rd = cur
        if !reuseDisks { rd = try? await API.shared.get("/api/disks") }
        let (rb, ru) = await (b, u)
        if !reuseDisks, rd != nil { mDAt = Date() }
        mB = rb ?? J(["error": "Sauvegardes indisponibles"])
        mU = ru ?? J(["error": "Mises à jour indisponibles"])
        mD = rd ?? J(["error": "Disques indisponibles", "disks": [Any]()])
        let running = (mU?.jobs.dict.values).map { $0.map { J($0) } } ?? []
        for j in running {  // mises à jour lancées depuis un autre appareil
            let k = j.vmid.str
            if mJobs[k] == nil || mJobs[k]!.at.num <= j.at.num { mJobs[k] = j }
        }
    }

    func diskState(_ d: J) -> (failed: Bool, hot: Bool, worn: Bool, bad: Bool) {
        let lim = mD?.limits[d.type.str].opt ?? mD?.limits.other.opt ?? 70
        let failed = !["PASSED", "OK", "UNKNOWN", ""].contains(d.health.str)
        let hot = d.temp.opt.map { $0 >= lim } ?? false
        let worn = d.wearout.opt.map { $0 >= 90 } ?? false
        return (failed, hot, worn, failed || hot || worn)
    }
    func bkState(_ g: J) -> String {
        g.last.isNil ? "none" : Date().timeIntervalSince1970 - g.last.ctime.num > 7 * 86400 ? "old" : "ok"
    }
    var ctsToUpdate: [J] { (mU?.cts.arr ?? []).filter { !$0.packages.arr.isEmpty } }

    var maintSummary: String {
        guard mB != nil || mU != nil else { return "Sauvegardes et mises à jour" }
        var parts: [String] = []
        let late = (mB?.guests.arr ?? []).filter { bkState($0) != "ok" }.count
        let upd = ctsToUpdate.count + ((mU?.host.packages.arr.isEmpty ?? true) ? 0 : 1)
        if let b = mB, b.error.isNil, b.jobs.arr.isEmpty { parts.append("aucune sauvegarde planifiée") }
        if late > 0 { parts.append("\(plural(late, "machine")) sans sauvegarde récente") }
        if !(mB?.failed.arr.isEmpty ?? true) { parts.append("sauvegarde en échec") }
        if upd > 0 { parts.append("\(plural(upd, "machine")) à mettre à jour") }
        let dbad = (mD?.disks.arr ?? []).filter { diskState($0).bad }.count
        if dbad > 0 { parts.append("\(plural(dbad, "disque")) à surveiller") }
        if mU?.scanning.bool == true && upd == 0 { parts.append("recherche des mises à jour…") }
        return parts.isEmpty ? "Tout est à jour ✓" : parts.joined(separator: " · ").capitalizedFirst
    }
    var maintAlert: Bool {
        let s = maintSummary
        return s != "Tout est à jour ✓" && (mB != nil || mU != nil) && !s.hasPrefix("Recherche") && s != "Sauvegardes et mises à jour"
    }

    // MARK: apps
    func loadApps(rescan: Bool = false) async {
        appsAt = Date()
        let ask = UUID()
        appsAsk = ask  // un rechargement plus récent l'emporte
        if !rescan && (apps ?? []).isEmpty, let r = try? await API.shared.get("/api/apps", ["mine": "1"]), appsAsk == ask, !appsFull {
            apps = r.apps.arr; appsScan = r.scan.bool; appsErr = nil  // d'abord tes apps (rapide), puis les suggestions
        }
        appsFull = false
        do {
            let r = try await API.shared.get("/api/apps", rescan ? ["rescan": "1"] : [:])
            guard appsAsk == ask else { return }
            apps = r.apps.arr; appsScan = r.scan.bool; appsErr = nil; appsFull = true
            if let v = r.apps.v, let d = try? JSONSerialization.data(withJSONObject: v) { UserDefaults.standard.set(d, forKey: "apps") }
        } catch { appsErr = error.localizedDescription }
    }

    /// Appliqué tout de suite à l'écran ; le serveur confirme ensuite
    func saveApp(_ body: [String: Any]) async {
        let op = body["op"] as? String, id = body["id"] as? String
        var list = (apps ?? []).map(\.dict)
        if op == "edit", let i = list.firstIndex(where: { J($0).id == id }) {
            for k in ["added", "name", "url", "icon", "hidden"] where body[k] != nil {
                let v = body[k]!
                if J(v).bool { list[i][k] = v } else if k == "added" { list[i][k] = false }
            }
        }
        if op == "delete" { list.removeAll { J($0).id == id } }
        if op == "add" { list.append(["id": "new:\(Date().timeIntervalSince1970)", "name": body["name"] ?? "", "url": body["url"] ?? "", "custom": true, "added": true]) }
        apps = list.map { J($0) }
        do { try await API.shared.post("/api/apps/save", body) } catch { fail(error) }
        await loadApps()
    }

    // MARK: store
    func addJob(_ j: [String: Any]) {
        guard let id = j["id"] as? String else { return }
        storeJobs[id] = j
        saveJobs()
    }
    func saveJobs() {
        let keep = storeJobs.sorted { J($0.value).id < J($1.value).id }.suffix(10)
        if let d = try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })) {
            UserDefaults.standard.set(d, forKey: "storeJobs")
        }
    }

    // MARK: version de PVE Hub
    func checkVersion(force: Bool = false) async {
        if let v = try? await API.shared.get("/api/version", force ? ["check": "1"] : [:]) { ver = v }
    }

    func doUpdate() async {
        guard await Dialog.confirm("Mettre à jour PVE Hub ?", "Le serveur télécharge la nouvelle version depuis GitHub puis redémarre (environ 1 minute).", "Mettre à jour") else { return }
        let t = toast("⏳ Mise à jour en cours…", seconds: 600)
        defer { dismissToast(t) }
        do {
            let r = try await API.shared.post("/api/update")
            let t2 = toast("🔄 Redémarrage du serveur…", seconds: 120)
            defer { dismissToast(t2) }
            for _ in 0..<45 {  // attend que la nouvelle version réponde
                try? await Task.sleep(for: .seconds(2))
                if let v = try? await API.shared.get("/api/version"), v.local.str == r.version.str {
                    ver = v
                    toast("✅ PVE Hub \(v.local.str) installé")
                    await refresh()
                    return
                }
            }
            toast("Le serveur ne répond pas encore : réessaie dans un moment.", seconds: 8)
        } catch { fail(error, seconds: 8) }
    }

    // MARK: notifications natives (APNs)
    @Published var pushToken: String?
    private var pushAsked = false

    /// Demande l'autorisation puis le jeton à Apple ; la réponse arrive dans AppDelegate → pushRegistered
    func enablePush() async {
        do {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                toast("Notifications refusées. Pour les autoriser : Réglages de l'iPhone → Notifications → PVE Hub.", seconds: 7)
                return
            }
            pushAsked = true
            UIApplication.shared.registerForRemoteNotifications()
        } catch { fail(error) }
    }
    /// À chaque connexion si déjà autorisé : le jeton peut changer (réinstallation, restauration)
    func refreshPush() async {
        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    func pushRegistered(_ token: String) async {
        do {
            try await API.shared.post("/api/push/subscribe", ["apns": token, "topic": Bundle.main.bundleIdentifier ?? "", "name": UIDevice.current.name])
            pushToken = token
            if pushAsked { toast("🔔 Notifications activées sur cet iPhone") }
        } catch { if pushAsked { fail(error) } }
        pushAsked = false
    }

    // MARK: navigation entre onglets
    func open(_ r: Route) {
        tab = .server
        serverPath = NavigationPath()
        serverPath.append(r)
    }
    /// Liens du Journal (même format que les notifications : maint, g=lxc/101, journal=login…)
    func openLink(_ h: String) {
        if h == "maint" { open(.maint) }
        else if h == "report" { Task { await chat.openLatestReport() } }
        else if h == "security" { showSettings = true }
        else if h == "apps" { tab = .apps }
        else if h == "sched" { open(.sched) }
        else if h.hasPrefix("chat=") { Task { await chat.openConv(String(h.dropFirst(5))) } }
        else if h == "journal" || h.hasPrefix("journal=") { open(.journal(h.split(separator: "=").dropFirst().first.map(String.init) ?? "")) }
        else if h.hasPrefix("g="), guest(String(h.dropFirst(2))) != nil { tab = .guests; guestsPath = NavigationPath(); guestsPath.append(Route.guest(String(h.dropFirst(2)))) }
    }
    func runInExec(target: String? = nil, command: String = "") {
        if let target { execTarget = target }
        execCommand = command
        tab = .exec
    }
}
