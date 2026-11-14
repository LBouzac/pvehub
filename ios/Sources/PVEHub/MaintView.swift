import SwiftUI

// MARK: - Maintenance : sauvegardes, disques, mises à jour
struct MaintView: View {
    @EnvironmentObject var hub: Hub
    @State private var editing: BkEdit?

    var body: some View {
        List {
            backupJobs
            lastBackups
            disks
            updates
        }
        .navigationTitle("Maintenance")
        .toolbar {
            Button("Actualiser") {
                hub.mB = nil; hub.mD = nil; hub.mU = J(["scanning": true, "cts": [Any]()])
                Task { await hub.loadMaint(refresh: true) }
            }
        }
        .refreshable { await hub.loadMaint(refresh: true) }
        .task {  // pendant la recherche des mises à jour : on repasse toutes les 3 s
            await hub.loadMaint()
            while !Task.isCancelled {
                let busy = hub.mJobs.values.contains { ["start", "snapshot", "upgrade"].contains($0.status.str) }
                guard hub.mU?.scanning.bool == true || busy else { break }
                try? await Task.sleep(for: .seconds(3))
                await hub.loadMaint()
            }
        }
        .sheet(item: $editing) { BackupJobEditor(edit: $0) }
    }

    @ViewBuilder
    private var backupJobs: some View {
        Section("Sauvegardes planifiées") {
            if let B = hub.mB {
                if !B.error.isNil { Text(B.error.str).foregroundStyle(.secondary) }
                else {
                    if B.jobs.arr.isEmpty { LinkRow(symbol: "arrow.down.doc.fill", color: .red, title: "Aucune sauvegarde planifiée") }
                    ForEach(B.jobs.arr) { j in
                        Button { Task { await jobMenu(j) } } label: {
                            HStack(spacing: 12) {
                                IconBox(symbol: "arrow.down.doc.fill", color: j.enabled.bool ? .green : .gray)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(scheduleFr(j.schedule.str)); if !j.enabled.bool { Pill(text: "en pause") } }
                                    Text("\(bkWho(j)) → \(j.storage.str.isEmpty ? "?" : j.storage.str)" + (j.keep.int > 0 ? " · garde \(j.keep.int)" : "") + (j.comment.str.isEmpty ? "" : " · " + j.comment.str))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    Button {
                        if (hub.mB?.storages.arr ?? []).isEmpty { hub.toast("Aucun stockage de sauvegarde trouvé") } else { editing = BkEdit(job: nil) }
                    } label: { LinkRow(symbol: "plus", color: .accentColor, title: "Nouvelle sauvegarde planifiée") }
                    ForEach(B.failed.arr.indices, id: \.self) { i in
                        let f = B.failed.arr[i]
                        HStack(spacing: 12) {
                            IconBox(symbol: "xmark", color: .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Échec \(when(f.starttime.num))").foregroundStyle(.red)
                                Text((f.vmid.str.isEmpty ? "" : "Machine \(f.vmid.str) · ") + f.status.str).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else { LoadingRow() }
        }
    }

    private var lastBackups: some View {
        Section {
            if let B = hub.mB {
                if B.error.isNil {
                    if B.guests.arr.isEmpty { Text("Aucune machine").foregroundStyle(.secondary) }
                    ForEach(B.guests.arr) { g in
                        let st = hub.bkState(g)
                        Button {
                            if hub.guest(g.id) != nil { hub.serverPath.append(Route.guest(g.id)) }
                        } label: {
                            HStack(spacing: 10) {
                                Circle().fill(st == "ok" ? Color.green : st == "old" ? .orange : .red).frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    (Text(guestTitle(g) + " ") + Text("\(kind(g.type.str)) \(g.vmid.str)").font(.footnote).foregroundColor(.secondary)).lineLimit(1)
                                    Text(g.last.isNil ? "Jamais sauvegardée" : "\(ago(g.last.ctime.num)) · \(fb(g.last.size.num)) · \(g.last.storage.str)")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !g.planned.bool { Pill(text: "non planifiée") }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } else { LoadingRow() }
        } header: { Text("Dernière sauvegarde") } footer: {
            Text("Vert : moins de 7 jours. Orange : plus ancienne. Rouge : aucune. Touche une machine pour la sauvegarder maintenant.")
        }
    }

    private var disks: some View {
        Section {
            if let D = hub.mD {
                let list = D.disks.arr
                if !D.error.isNil && list.isEmpty { Text(D.error.str).foregroundStyle(.secondary) }
                else if list.isEmpty { Text("Aucun disque trouvé").foregroundStyle(.secondary) }
                ForEach(list.indices, id: \.self) { i in
                    let d = list[i], s = hub.diskState(d)
                    HStack(spacing: 12) {
                        IconBox(symbol: "internaldrive.fill", color: s.bad ? .red : d.health.str == "UNKNOWN" ? .gray : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.model.str + (list.contains { $0.node.str != d.node.str } ? " · \(d.node.str)" : "")).lineLimit(1)
                            Text(diskSub(d, hot: s.hot)).font(.subheadline).foregroundStyle(s.hot ? Color.red : Color.secondary)
                        }
                        Spacer()
                        Pill(text: s.failed ? "En panne" : s.bad ? "À surveiller" : d.health.str == "UNKNOWN" ? "Inconnu" : "OK",
                             color: s.bad ? .red : Color(.tertiarySystemFill), fg: s.bad ? .white : .secondary)
                    }
                }
            } else { LoadingRow() }
        } header: { Text("Disques") } footer: {
            Text("État SMART lu par Proxmox. L'usure concerne les SSD (100 % = fin de vie annoncée). Alerte si un disque est en panne, usé à 90 % ou trop chaud.")
        }
    }
    private func diskSub(_ d: J, hot: Bool) -> String {
        [d.dev.str, fb(d.size.num), d.type.str == "unknown" ? "" : d.type.str.uppercased(),
         d.wearout.opt.map { "usure \(Int($0.rounded())) %" } ?? "", d.temp.opt.map { "\(Int($0)) °C" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var updates: some View {
        Section {
            if let U = hub.mU {
                if !U.error.isNil && U.cts.isNil { Text(U.error.str).foregroundStyle(.secondary) }
                else {
                    if U.scanning.bool { Text("Recherche des mises à jour… (jusqu'à 2 min)").foregroundStyle(.secondary) }
                    if !U.host.isNil {
                        let n = U.host.packages.arr.count
                        Button { Task { await hostMenu(U.host.packages.strs) } } label: {
                            LinkRow(symbol: "server.rack", color: .gray, title: "Hôte \(hub.ov?.nodes.arr.first?.node.str ?? "")",
                                    subtitle: n > 0 ? "\(plural(n, "paquet")) · à faire dans le Shell de Proxmox" : "À jour ✓")
                        }
                        .foregroundStyle(.primary)
                    }
                    ForEach(U.cts.arr.indices, id: \.self) { i in ctRow(U.cts.arr[i]) }
                    if !U.scanning.bool && U.cts.arr.isEmpty && U.host.isNil { Text("Aucune machine allumée").foregroundStyle(.secondary) }
                    let todo = hub.ctsToUpdate.filter { !["start", "snapshot", "upgrade", "done"].contains(hub.mJobs[$0.vmid.str]?.status.str ?? "") }
                    if todo.count > 1 {
                        Button { Task { await updateAll() } } label: {
                            LinkRow(symbol: "arrow.triangle.2.circlepath", color: .accentColor, title: "Tout mettre à jour (\(todo.count) machines)")
                        }
                    }
                }
            } else { LoadingRow() }
        } header: { Text("Mises à jour") } footer: {
            Text((hub.mU?.checked_at.opt.map { "Vérifié \(ago($0)). " } ?? "") + "Un snapshot est pris avant chaque mise à jour pour pouvoir revenir en arrière. Pour une VM, l'agent QEMU doit être installé et actif (qemu-guest-agent).")
        }
    }

    private func ctRow(_ c: J) -> some View {
        let j = hub.mJobs[c.vmid.str], n = c.packages.arr.count, st = j?.status.str ?? ""
        let sub: String = st == "snapshot" ? "⏳ Snapshot…" : st == "upgrade" || st == "start" ? "⏳ Mise à jour en cours…"
            : st == "done" ? "✓ Mis à jour" + ((j?.snapshot.str ?? "").isEmpty ? "" : " · snapshot " + j!.snapshot.str)
            : st == "error" ? "✕ " + (j?.error.str ?? "")
            : c.pm.str.isEmpty && c.type.str == "qemu" ? "Agent QEMU absent, ou système non pris en charge"
            : c.pm.str.isEmpty || c.pm.str == "none" ? "Gestionnaire de paquets inconnu"
            : n > 0 ? "\(plural(n, "paquet")) à mettre à jour · \(c.pm.str)" : "À jour ✓"
        return Button { Task { await ctMenu(c) } } label: {
            HStack(spacing: 12) {
                IconBox(symbol: guestSymbol(c.type.str.isEmpty ? "lxc" : c.type.str), color: n > 0 && j == nil ? .orange : .teal)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(guestTitle(c) + " ") + Text("\(kind(c.type.str.isEmpty ? "lxc" : c.type.str)) \(c.vmid.str)").font(.footnote).foregroundColor(.secondary)).lineLimit(1)
                    Text(sub).font(.subheadline).foregroundStyle(st == "error" ? Color.red : Color.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func jobMenu(_ j: J) async {
        let i = await Dialog.actions(scheduleFr(j.schedule.str), bkWho(j), [("Modifier", false), (j.enabled.bool ? "Mettre en pause" : "Réactiver", false), ("Supprimer", true)])
        if i == 0 { editing = BkEdit(job: j) }
        if i == 1 { await saveBackupJob(["op": "toggle", "id": j.id, "enabled": !j.enabled.bool]) }
        if i == 2, await Dialog.confirm("Supprimer cette sauvegarde planifiée ?", "Les sauvegardes déjà faites sont gardées.", "Supprimer", danger: true) {
            await saveBackupJob(["op": "delete", "id": j.id])
        }
    }

    private func hostMenu(_ pkgs: [String]) async {
        if await Dialog.actions("Hôte Proxmox", "La mise à jour de l'hôte se fait dans le Shell de Proxmox, pour pouvoir répondre à ses questions :\napt update && apt dist-upgrade",
                                [("Voir les paquets (\(pkgs.count))", false)]) == 0 {
            showText("Hôte", pkgs.isEmpty ? "Aucun paquet" : pkgs.joined(separator: "\n"))
        }
    }

    private func ctMenu(_ c: J) async {
        let vmid = c.vmid.str
        if ["start", "snapshot", "upgrade"].contains(hub.mJobs[vmid]?.status.str ?? "") { hub.toast("Mise à jour déjà en cours"); return }
        let n = c.packages.arr.count
        let btns = [("Mettre à jour (snapshot avant)", false), ("Mettre à jour sans snapshot", true), ("Voir les paquets (\(n))", false)]
        let i = await Dialog.actions(guestTitle(c), n > 0 ? "\(plural(n, "paquet")) à mettre à jour" : "Déjà à jour", n > 0 ? btns : [btns[2]])
        if n > 0 && i == 0 { await upgrade(vmid, snapshot: true) }
        if n > 0 && i == 1 { await upgrade(vmid, snapshot: false) }
        if (n > 0 && i == 2) || (n == 0 && i == 0) { showText(guestTitle(c), c.packages.strs.joined(separator: "\n")) }
    }

    private func updateAll() async {
        let todo = hub.ctsToUpdate.filter { hub.mJobs[$0.vmid.str] == nil }
        guard await Dialog.confirm("Mettre à jour \(todo.count) machines ?", "Un snapshot de chacune est pris avant, l'une après l'autre.", "Tout mettre à jour") else { return }
        for x in todo { await upgrade(x.vmid.str, snapshot: true) }
        await hub.loadMaint()
    }

    private func upgrade(_ vmid: String, snapshot: Bool) async {
        guard let g = hub.guest(vmid: vmid) else { return }
        let job: J
        do { job = try await API.shared.post("/api/maint/upgrade", ["node": g.node.str, "type": g.type.str, "vmid": g.vmid.int, "snapshot": snapshot]) }
        catch { hub.fail(error); return }
        hub.mJobs[vmid] = J(["status": "start"])
        while true {  // suivi jusqu'à la fin
            try? await Task.sleep(for: .seconds(3))
            guard let r = try? await API.shared.get("/api/maint/job", ["id": job.job.str]) else { continue }
            hub.mJobs[vmid] = r
            if ["done", "error"].contains(r.status.str) { break }
        }
        let r = hub.mJobs[vmid]!
        if r.status.str == "done" { hub.toast("✅ \(guestTitle(g)) mis à jour") }
        else if snapshot && r.error.str.contains("Snapshot impossible") {
            if await Dialog.confirm("Snapshot impossible", "Le stockage de \(guestTitle(g)) ne permet pas les snapshots. Mettre à jour quand même, sans retour en arrière possible ?",
                                    "Mettre à jour sans snapshot", danger: true) {
                await upgrade(vmid, snapshot: false)
            }
        } else { hub.toast("❌ " + (r.error.str.isEmpty ? "Échec" : r.error.str), seconds: 6) }
    }

    private func saveBackupJob(_ body: [String: Any]) async {
        do { hub.mB = try await API.shared.post("/api/maint/backupjob", body) } catch { hub.fail(error, seconds: 6) }
    }
}

/// Texte brut dans une feuille (liste de paquets, rapport…)
@MainActor
func showText(_ title: String, _ text: String) {
    Hub.shared.textSheet = TextSheet(title: title, text: text)
}
struct TextSheet: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
struct TextSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let sheet: TextSheet
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(sheet.text).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}

// MARK: - Sauvegardes planifiées (tâches vzdump de Proxmox)
private let BK_DAYS: [(String, String)] = [("all", "Tous les jours"), ("week", "Du lundi au vendredi"), ("weekend", "Le week-end"), ("sun", "Le dimanche")]
private let BK_MODE: [(String, String)] = [("snapshot", "Sans arrêt (snapshot)"), ("suspend", "Pause pendant la copie"), ("stop", "Arrêt pendant la copie")]

struct BkEdit: Identifiable {
    let id = UUID()
    let job: J?
}

struct BackupJobEditor: View {
    @EnvironmentObject var hub: Hub
    @Environment(\.dismiss) private var dismiss
    let edit: BkEdit
    @State private var time = hmDate("02:00")
    @State private var days = "all"
    @State private var storage = ""
    @State private var keep = 7
    @State private var mode = "snapshot"
    @State private var all = true
    @State private var sel: Set<Int> = []
    @State private var busy = false

    private var parsed: (String, String)? { edit.job.map { bkParse($0.schedule.str) } ?? ("02:00", "all") }
    private var guests: [J] { hub.guests.filter { !$0.template.bool }.sorted { $0.vmid.int < $1.vmid.int } }
    private var keeps: [Int] { [3, 7, 14, 30] + ((edit.job?.keep.int).map { $0 > 0 && ![3, 7, 14, 30].contains($0) ? [$0] : [] } ?? []) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if parsed != nil {
                        DatePicker("Heure", selection: $time, displayedComponents: .hourAndMinute)
                        Picker("Jours", selection: $days) { ForEach(BK_DAYS, id: \.0) { Text($0.1).tag($0.0) } }
                    } else if let j = edit.job {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scheduleFr(j.schedule.str))
                            Text("Planification faite dans Proxmox, gardée telle quelle").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Stockage", selection: $storage) { ForEach(hub.mB?.storages.strs ?? [], id: \.self) { Text($0).tag($0) } }
                    Picker("Garder", selection: $keep) { ForEach(keeps, id: \.self) { Text("\($0) dernières").tag($0) } }
                    Picker("Mode", selection: $mode) { ForEach(BK_MODE, id: \.0) { Text($0.1).tag($0.0) } }
                }
                Section {
                    Toggle(isOn: $all) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Toutes les machines")
                            if let ex = edit.job?.exclude.str, !ex.isEmpty {
                                Text("sauf \(ex.replacingOccurrences(of: ",", with: ", ")) (exclusion faite dans Proxmox)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    if all { Text("Exécutée par Proxmox, même PVE Hub éteint. « Toutes les machines » inclut celles créées plus tard. Au-delà du nombre gardé, les plus anciennes sauvegardes sont supprimées.") }
                }
                if !all {
                    Section("Machines") {
                        ForEach(guests) { g in
                            Toggle(isOn: Binding(get: { sel.contains(g.vmid.int) }, set: { if $0 { sel.insert(g.vmid.int) } else { sel.remove(g.vmid.int) } })) {
                                HStack(spacing: 12) {
                                    IconBox(symbol: guestSymbol(g.type.str), color: guestColor(g.type.str))
                                    VStack(alignment: .leading) {
                                        Text(guestTitle(g)).lineLimit(1)
                                        Text("\(kind(g.type.str)) \(g.vmid.str)").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(edit.job == nil ? "Nouvelle sauvegarde" : "Sauvegarde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { Task { await save() } }.bold().disabled(busy) }
            }
            .onAppear {
                if let p = parsed { time = hmDate(p.0); days = p.1 }
                let stores = hub.mB?.storages.strs ?? []
                storage = edit.job.map { $0.storage.str }.flatMap { stores.contains($0) ? $0 : nil } ?? stores.first ?? ""
                if let j = edit.job {
                    keep = j.keep.int > 0 ? j.keep.int : 7
                    mode = j.mode.str.isEmpty ? "snapshot" : j.mode.str
                    all = j.all.bool
                    sel = Set(j.vmid.str.split(separator: ",").compactMap { Int($0) })
                }
            }
        }
    }

    private func save() async {
        if !all && sel.isEmpty { hub.toast("Choisis au moins une machine"); return }
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["op": edit.job == nil ? "add" : "update", "storage": storage, "keep": keep, "mode": mode,
                                   "all": all, "vmids": Array(sel).sorted(), "enabled": edit.job?.enabled.bool ?? true]
        if let j = edit.job { body["id"] = j.id }
        if parsed != nil { body["time"] = hmString(time); body["days"] = days } else { body["raw"] = edit.job?.schedule.str ?? "" }
        do { hub.mB = try await API.shared.post("/api/maint/backupjob", body); dismiss() } catch { hub.fail(error, seconds: 6) }
    }
}

// MARK: - Journal : alertes, connexions, actions
private let J_FILTERS: [(String, String)] = [("", "Tout"), ("alert", "Alertes"), ("login", "Connexions"), ("actions", "Actions")]
private let J_KIND: [String: (String, Color)] = ["download": ("arrow.down.circle.fill", .blue), "alert": ("bell.fill", .red), "login": ("lock.shield.fill", .accentColor),
                                                 "security": ("lock.shield.fill", .orange), "store": ("bag.fill", .purple), "update": ("arrow.clockwise", .green), "report": ("bubble.left.fill", .indigo)]
struct JournalView: View {
    @EnvironmentObject var hub: Hub
    @State var filter: String
    @State private var events: [J]?
    @State private var err: String?

    private var list: [J] {
        (events ?? []).filter { e in filter.isEmpty || (filter == "actions" ? ["security", "store", "update", "report"].contains(e.kind.str) : e.kind.str == filter) }
    }
    private var days: [(String, [J])] {
        var out: [(String, [J])] = []
        for e in list {
            let d = dayLabel(e.ts.num)
            if out.last?.0 == d { out[out.count - 1].1.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    var body: some View {
        List {
            Picker("Filtre", selection: $filter) { ForEach(J_FILTERS, id: \.0) { Text($0.1).tag($0.0) } }
                .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if events == nil { Text(err ?? "Chargement…").foregroundStyle(.secondary) }
            else if list.isEmpty { Text("Rien pour l'instant.").foregroundStyle(.secondary) }
            ForEach(days, id: \.0) { day in
                Section(day.0) {
                    ForEach(day.1.indices, id: \.self) { i in row(day.1[i]) }
                }
            }
            Section { } footer: { Text("Les 300 derniers événements sont gardés sur le serveur.") }
        }
        .navigationTitle("Journal")
        .toolbar { Button("Actualiser") { Task { await load() } } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { events = try await API.shared.get("/api/events").events.arr; err = nil } catch { err = error.localizedDescription }
    }

    private func row(_ e: J) -> some View {
        let (sym, col) = e.kind.str == "login" && !e.ok.bool ? ("lock.shield.fill", Color.red) : J_KIND[e.kind.str] ?? ("bell.fill", .gray)
        let sub = [e.body.str, e.ua.str.isEmpty ? "" : uaName(e.ua.str)].filter { !$0.isEmpty }.joined(separator: " · ")
        let ask = hub.hermes && (e.kind.str == "alert" || e.title.str.contains("échec"))
        let link = e.url.str.hasPrefix("#") ? String(e.url.str.dropFirst()) : e.url.str
        return HStack(alignment: .top, spacing: 12) {
            IconBox(symbol: sym, color: col)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title.str)
                if !sub.isEmpty { Text(sub).font(.subheadline).foregroundStyle(.secondary) }
                if ask {
                    Button("Demander à Hermes") {
                        let at = fullWhen(e.ts.num)
                        let body = e.body.str.replacingOccurrences(of: #"[.\s]+$"#, with: "", options: .regularExpression)
                        hub.chat.ask("\(e.title.str) (\(at)). Regarde pourquoi et dis-moi quoi faire.",
                                     context: "Événement du journal de PVE Hub, \(at) : « \(e.title.str) »\(body.isEmpty ? "" : " — " + body).")
                    }
                    .font(.subheadline).buttonStyle(.bordered).padding(.top, 2)
                }
            }
            Spacer()
            Text(hm(e.ts.num)).font(.subheadline).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !link.isEmpty { hub.openLink(link) } }
    }
}
