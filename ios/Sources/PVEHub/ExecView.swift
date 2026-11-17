import SwiftUI

private let PRESETS = ["uptime", "df -h", "free -h", "top -bn1 | head -15", "ip -br a", "systemctl --failed", "apt list --upgradable 2>/dev/null", "docker ps"]
private let HOST = "{\"type\":\"host\"}"

struct ExecEntry: Codable, Identifiable {
    var id = UUID()
    let command: String
    let label: String
    let at: Date
    var code: Int = -1
    var output: String = ""
    var ms: Double?
}

struct ExecView: View {
    @EnvironmentObject var hub: Hub
    @State private var sec = "run"
    @State private var busy = false
    @State private var log: [ExecEntry] = (UserDefaults.standard.data(forKey: "exec")).flatMap { try? JSONDecoder().decode([ExecEntry].self, from: $0) } ?? []
    @State private var cronTarget = HOST
    @State private var cron: J?
    @State private var cronErr: String?
    @State private var editing: CronEdit?
    @FocusState private var focused: Bool

    /// Hôte puis machines allumées (comme la version web)
    private var targets: [(String, String)] {
        [(HOST, "Hôte \(hub.ov?.nodes.arr.first?.node.str ?? "")")] + hub.guests
            .filter { $0.status.str == "running" && !$0.template.bool }.sorted { $0.vmid.int < $1.vmid.int }
            .map { (execTargetJSON($0), "\(kind($0.type.str)) \($0.vmid.str) · \($0.name.str)") }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hub.exec {
                    List {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pas encore activé").font(.headline)
                            Text("Les commandes passent par une clé SSH vers l'hôte Proxmox. Relance l'installeur en mode mise à jour et réponds « o » à la question sur les commandes.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    List {
                        Picker("Section", selection: $sec) { Text("Exécuter").tag("run"); Text("Tâches planifiées").tag("cron") }
                            .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                        if sec == "run" { runSection } else { cronSection }
                    }
                }
            }
            .navigationTitle("Commandes")
            .hubToolbar(live: false)
            .onAppear { if hub.execTarget.isEmpty || !targets.contains(where: { $0.0 == hub.execTarget }) { hub.execTarget = HOST } }
            .onChange(of: hub.execCommand) { _, c in if !c.isEmpty { sec = "run"; focused = true } }
            .sheet(item: $editing) { CronEditor(edit: $0, target: cronTarget) { cron = $0 } }
        }
    }

    // MARK: exécuter
    @ViewBuilder
    private var runSection: some View {
        Section {
            Picker("Exécuter sur", selection: $hub.execTarget) { ForEach(targets, id: \.0) { Text($0.1).tag($0.0) } }
            TextField("ex. df -h", text: $hub.execCommand, axis: .vertical)
                .font(.body.monospaced()).lineLimit(3...8)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused)
            Button { Task { await run() } } label: {
                HStack { Spacer(); Text(busy ? "Exécution…" : "Exécuter").bold(); Spacer() }
            }
            .disabled(busy || hub.execCommand.trimmed.isEmpty)
        }
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PRESETS, id: \.self) { p in
                        Button(p) { hub.execCommand = p; Task { await run() } }
                            .font(.caption.monospaced()).buttonStyle(.bordered).disabled(busy)
                    }
                }
            }
        } header: { Text("Raccourcis") } footer: {
            Text("Sur l'hôte, en root. Dans une VM, l'agent QEMU doit être installé. 60 s maximum par commande.")
        }
        if !log.isEmpty {
            Section {
                ForEach(log) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("$ \(r.command)").font(.subheadline.monospaced()).lineLimit(1)
                            Spacer()
                            Text(r.code == 0 ? "OK" : "code \(r.code)").font(.caption.bold()).foregroundStyle(r.code == 0 ? Color.green : Color.red)
                        }
                        Text("\(r.label) · \(hm(r.at.timeIntervalSince1970))" + (r.ms.map { " · " + String(format: "%.1f", $0 / 1000).replacingOccurrences(of: ".", with: ",") + " s" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            Text(r.output.isEmpty ? "(aucune sortie)" : r.output).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                HStack { Text("Résultats"); Spacer(); Button("Effacer") { log = []; persist() }.font(.footnote) }
            }
        }
    }

    private func run() async {
        let command = hub.execCommand.trimmed
        guard !command.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        let label = targets.first { $0.0 == hub.execTarget }?.1 ?? "Hôte"
        var e = ExecEntry(command: command, label: label, at: Date())
        var body = J(try? JSONSerialization.jsonObject(with: Data(hub.execTarget.utf8))).dict
        body["command"] = command
        do {
            let r = try await API.shared.post("/api/exec", body)
            e.code = r.code.int
            e.output = r.output.str
            e.ms = r.ms.opt
        } catch {
            e.output = (error as? URLError) != nil
                ? "Connexion coupée avant la fin. Si la commande redémarre PVE Hub (mise à jour), c'est normal : rouvre l'app dans un moment."
                : error.localizedDescription
        }
        e.output = String(e.output.suffix(8000))
        log.insert(e, at: 0)
        log = Array(log.prefix(15))
        persist()
    }
    private func persist() { if let d = try? JSONEncoder().encode(log) { UserDefaults.standard.set(d, forKey: "exec") } }

    // MARK: tâches planifiées (crontab)
    @ViewBuilder
    private var cronSection: some View {
        Section {
            Picker("Machine", selection: $cronTarget) {
                ForEach(targets.filter { !$0.0.contains("\"qemu\"") }, id: \.0) { Text($0.1).tag($0.0) }  // crontab : hôte et conteneurs
            }
        }
        Section {
            if let cronErr { Text(cronErr).foregroundStyle(.secondary) }
            else if let c = cron {
                if !c.available.bool {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("cron n'est pas installé")
                        Text("Sur Alpine : apk add cronie. Sur Debian : apt install cron.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(c.entries.arr) { job in
                        Button { Task { await menu(job) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(cronFr(job.sched.str) ?? job.sched.str)
                                    if !job.enabled.bool { Pill(text: "désactivée") }
                                }
                                Text((cronFr(job.sched.str) != nil ? job.sched.str + " · " : "") + job.cmd.str)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .opacity(job.enabled.bool ? 1 : 0.45)
                        }
                        .foregroundStyle(.primary)
                    }
                    Button { editing = CronEdit(job: nil, hash: c.hash.str) } label: { LinkRow(symbol: "plus", color: .accentColor, title: "Ajouter une tâche") }
                }
            } else { LoadingRow() }
        } header: {
            HStack { Text("Tâches"); Spacer(); Button("Actualiser") { Task { await loadCron() } }.font(.footnote) }
        } footer: {
            Text("Crontab de root. Les tâches système (/etc/cron.d) et les sauvegardes planifiées de Proxmox ne sont pas listées ici.")
        }
        .task(id: cronTarget) { await loadCron() }
    }

    private func loadCron() async {
        cron = nil
        do {
            let t = J(try? JSONSerialization.jsonObject(with: Data(cronTarget.utf8)))
            cron = try await API.shared.get("/api/cron", t.dict.mapValues { J($0).str })
            cronErr = nil
        } catch { cronErr = error.localizedDescription }
    }

    private func menu(_ job: J) async {
        let i = await Dialog.actions(cronFr(job.sched.str) ?? job.sched.str, job.cmd.str,
                                     [("Lancer maintenant", false), ("Modifier", false), (job.enabled.bool ? "Désactiver" : "Activer", false), ("Supprimer", true)])
        switch i {
        case 0:  // exécution immédiate : on passe par Exécuter pour voir le résultat
            sec = "run"; hub.execTarget = cronTarget; hub.execCommand = job.cmd.str
            await run()
        case 1: editing = CronEdit(job: job, hash: cron?.hash.str)
        case 2: if let c = await cronSave(["op": "toggle", "i": job.i.int], target: cronTarget, hash: cron?.hash.str) { cron = c }
        case 3:
            if await Dialog.confirm("Supprimer cette tâche ?", job.cmd.str, "Supprimer", danger: true),
               let c = await cronSave(["op": "delete", "i": job.i.int], target: cronTarget, hash: cron?.hash.str) { cron = c }
        default: break
        }
    }
}

@MainActor
func cronSave(_ body: [String: Any], target: String, hash: String?) async -> J? {
    var b = J(try? JSONSerialization.jsonObject(with: Data(target.utf8))).dict
    b["hash"] = hash ?? ""
    for (k, v) in body { b[k] = v }
    do { return try await API.shared.post("/api/cron", b) }
    catch { Hub.shared.fail(error, seconds: 6); return nil }
}

struct CronEdit: Identifiable {
    let id = UUID()
    let job: J?
    let hash: String?  // empreinte de la crontab affichée : le serveur refuse si elle a changé entre-temps
}

private let CRON_PRESETS: [(String, String)] = [("5min", "Toutes les 5 minutes"), ("hour", "Toutes les heures"), ("day", "Tous les jours"), ("week", "Chaque semaine"),
                                                ("month", "Chaque mois"), ("reboot", "Au démarrage"), ("custom", "Personnalisé")]

struct CronEditor: View {
    @Environment(\.dismiss) private var dismiss
    let edit: CronEdit
    let target: String
    let onSaved: (J) -> Void
    @State private var preset = "day"
    @State private var time = hmDate("03:00")
    @State private var dow = 1
    @State private var dom = 1
    @State private var sched = ""
    @State private var cmd = ""
    @State private var hash: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Quand") {
                    Picker("Fréquence", selection: $preset) { ForEach(CRON_PRESETS, id: \.0) { Text($0.1).tag($0.0) } }
                    if ["day", "week", "month"].contains(preset) { DatePicker("Heure", selection: $time, displayedComponents: .hourAndMinute) }
                    if preset == "week" { Picker("Jour", selection: $dow) { ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { Text(DAYS[$0].capitalizedFirst).tag($0) } } }
                    if preset == "month" { Picker("Jour du mois", selection: $dom) { ForEach(1...28, id: \.self) { Text("\($0)").tag($0) } } }
                    HStack {
                        Text("Expression cron")
                        TextField("0 3 * * *", text: $sched)
                            .font(.body.monospaced()).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: sched) { _, v in if v != built() { preset = "custom" } }
                    }
                }
                Section {
                    TextField("/root/sauvegarde.sh", text: $cmd, axis: .vertical)
                        .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(preview)
                } footer: { Text("Une seule ligne. Exécutée par root\(target.contains("host") ? " sur l'hôte Proxmox" : " dans le conteneur").") }
            }
            .keyboardDismiss()
            .navigationTitle(edit.job == nil ? "Nouvelle tâche" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { Task { await save() } }.bold().disabled(busy) }
            }
            .onAppear(perform: setup)
            .onChange(of: preset) { _, _ in rebuild() }
            .onChange(of: time) { _, _ in rebuild() }
            .onChange(of: dow) { _, _ in rebuild() }
            .onChange(of: dom) { _, _ in rebuild() }
        }
    }

    private var preview: String {
        let v = sched.trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return v.isEmpty ? "Commande" : (cronFr(v) ?? "Expression personnalisée : \(v)")
    }

    /// préréglage → expression
    private func built() -> String? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hh = c.hour ?? 3, mm = c.minute ?? 0
        switch preset {
        case "5min": return "*/5 * * * *"
        case "hour": return "0 * * * *"
        case "day": return "\(mm) \(hh) * * *"
        case "week": return "\(mm) \(hh) * * \(dow)"
        case "month": return "\(mm) \(hh) \(dom) * *"
        case "reboot": return "@reboot"
        default: return nil
        }
    }
    private func rebuild() { if let x = built() { sched = x } }

    /// ouverture : on retrouve le préréglage qui correspond à la tâche existante
    private func setup() {
        guard let job = edit.job else { rebuild(); return }
        sched = job.sched.str
        cmd = job.cmd.str
        let p = job.sched.str.split(separator: " ").map(String.init)
        let n = { (x: String) in !x.isEmpty && x.allSatisfy(\.isNumber) }
        var pr = "custom"
        if job.sched.str == "*/5 * * * *" { pr = "5min" }
        else if job.sched.str == "0 * * * *" { pr = "hour" }
        else if job.sched.str == "@reboot" { pr = "reboot" }
        else if p.count == 5, n(p[0]), n(p[1]) {
            time = hmDate("\(p[1]):\(p[0])")
            if p[2] == "*" && p[4] == "*" { pr = "day" }
            else if p[2] == "*", let d = Int(p[4]), (0...6).contains(d) { pr = "week"; dow = d }
            else if let d = Int(p[2]), d <= 28, p[4] == "*" { pr = "month"; dom = d }
        }
        preset = pr
        DispatchQueue.main.async { sched = job.sched.str }  // les onChange ci-dessus ne doivent pas écraser l'expression d'origine
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["op": edit.job == nil ? "add" : "edit", "sched": sched.trimmed, "cmd": cmd.trimmed]
        if let job = edit.job { body["i"] = job.i.int }
        if let r = await cronSave(body, target: target, hash: edit.hash) { onSaved(r); dismiss() }
    }
}
