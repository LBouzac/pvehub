import SwiftUI

func guestSymbol(_ type: String) -> String { type == "qemu" ? "desktopcomputer" : "shippingbox.fill" }
func guestColor(_ type: String) -> Color { type == "qemu" ? .indigo : .teal }
func guestTitle(_ g: J) -> String { g.name.str.isEmpty ? g.vmid.str : g.name.str }

// MARK: - Liste des machines
struct GuestsView: View {
    @EnvironmentObject var hub: Hub
    @State private var q = ""
    @State private var filter = "all"

    private var list: [J] {
        let s = q.trimmed.lowercased()
        return hub.guests
            .filter { (filter == "all" || $0.status.str == filter) && (s.isEmpty || $0.vmid.str.contains(s) || $0.name.str.lowercased().contains(s)) }
            .sorted { a, b in
                let ra = a.status.str == "running", rb = b.status.str == "running"
                return ra != rb ? ra : a.vmid.int < b.vmid.int
            }
    }

    var body: some View {
        NavigationStack(path: $hub.guestsPath) {
            List {
                Picker("Filtre", selection: $filter) {
                    Text("Toutes").tag("all"); Text("Actives").tag("running"); Text("Arrêtées").tag("stopped")
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                ForEach(list) { g in
                    NavigationLink(value: Route.guest(g.id)) { GuestRow(g: g) }
                }
            }
            .overlay { if list.isEmpty && hub.ov != nil { ContentUnavailableView("Aucune machine", systemImage: "shippingbox") } }
            .searchable(text: $q, prompt: "Rechercher")
            .navigationTitle("Machines")
            .hubToolbar()
            .navigationDestination(for: Route.self) { destination($0) }
            .refreshable { await hub.refresh() }
        }
    }
}

struct GuestRow: View {
    let g: J
    var body: some View {
        let on = g.status.str == "running"
        HStack(spacing: 12) {
            IconBox(symbol: guestSymbol(g.type.str), color: guestColor(g.type.str))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(g.name.str.isEmpty ? "sans nom" : g.name.str).lineLimit(1)
                    if g.template.bool { Pill(text: "modèle") }
                }
                Text("\(kind(g.type.str)) \(g.vmid.str) · " + (on ? "CPU \(p0(g.cpu.num * 100)) % · RAM \(fb(g.mem.num))" : STATUS[g.status.str] ?? g.status.str))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StatusDot(status: g.status.str)
        }
    }
}

// MARK: - Fiche d'une machine
struct GuestDetail: View {
    @EnvironmentObject var hub: Hub
    let id: String
    @AppStorage("tf") private var tf = "hour"
    @State private var rrd: [J] = []
    @State private var cfg: J?
    @State private var snaps: [J]?
    @State private var snapsErr: String?
    @State private var bk: J?
    @State private var bkErr: String?
    @State private var onboot: Bool?
    @State private var showRes = false
    @State private var showSched = false

    var body: some View {
        if let g = hub.guest(id) {
            content(g)
        } else {
            ContentUnavailableView("Machine introuvable", systemImage: "questionmark.square.dashed")
        }
    }

    private func base(_ g: J) -> [String: Any] { ["node": g.node.str, "type": g.type.str, "vmid": g.vmid.int] }
    private func q(_ g: J) -> [String: String] { ["node": g.node.str, "type": g.type.str, "vmid": g.vmid.str] }

    private func content(_ g: J) -> some View {
        let on = g.status.str == "running", cpu = g.cpu.num * 100
        return List {
            Section {
                HStack(spacing: 8) {
                    StatusDot(status: g.status.str)
                    Text("\(kind(g.type.str)) \(g.vmid.str) · \(STATUS[g.status.str] ?? g.status.str)" + (on ? " depuis \(up(g.uptime.num))" : ""))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                HStack(spacing: 10) {
                    PowerButton(title: "Démarrer", symbol: "play.fill", color: .green, enabled: !on) { act(g, "start") }
                    PowerButton(title: "Éteindre", symbol: "power", color: .orange, enabled: on) { act(g, "shutdown") }
                    PowerButton(title: "Redémarrer", symbol: "arrow.clockwise", color: .blue, enabled: on) { act(g, "reboot") }
                    PowerButton(title: "Forcer", symbol: "stop.fill", color: .red, enabled: on) { act(g, "stop") }
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if hub.hermes {
                Section {
                    Button { askHermes(g) } label: { LinkRow(symbol: "bubble.left.fill", color: .indigo, title: "Demander à Hermes") }
                }
            }
            Section("Ressources") {
                MeterRow(title: "Processeur", detail: "\(on ? p0(cpu) + " %" : "–") · \(plural(g.maxcpu.int, "cœur"))", value: on ? cpu : 0, symbol: "cpu", color: .orange)
                MeterRow(title: "Mémoire", detail: "\(on ? fb(g.mem.num) : "–") / \(fb(g.maxmem.num))", value: on ? pct(g.mem.num, g.maxmem.num) : 0, symbol: "memorychip", color: .blue)
                MeterRow(title: "Disque", detail: "\(g.disk.num > 0 ? fb(g.disk.num) : "–") / \(fb(g.maxdisk.num))", value: pct(g.disk.num, g.maxdisk.num), symbol: "internaldrive", color: .purple)
                HStack(spacing: 12) {
                    IconBox(symbol: "arrow.up.arrow.down", color: .green)
                    Text("Réseau")
                    Spacer()
                    Text("↓ \(fb(g.netin.num)) · ↑ \(fb(g.netout.num))").font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Modifier les ressources") { showRes = true }
            }
            Section("Activité") {
                TimeframePicker()
                UsageChart(rows: rrd, series: [cpuSeries, memSeries], maxY: 100)
                UsageChart(rows: rrd, series: netSeries, unit: { fb($0) + "/s" })
            }
            Section {
                Toggle(isOn: Binding(get: { onboot ?? (cfg?.config.onboot.int == 1) }, set: { v in Task { await setOnboot(g, v) } })) {
                    LinkRow(symbol: "power", color: .green, title: "Démarrer avec le serveur")
                }
                .disabled(cfg == nil)
                Button { showSched = true } label: {
                    LinkRow(symbol: "bell.fill", color: .indigo, title: "Horaires", subtitle: schedSummary(g))
                }
                .foregroundStyle(.primary)
                if hub.exec {
                    Button {
                        hub.runInExec(target: execTargetJSON(g))
                    } label: { LinkRow(symbol: "apple.terminal", color: .gray, title: "Lancer une commande") }
                    .foregroundStyle(.primary)
                }
            } header: { Text("Options") } footer: {
                Text("Après une coupure de courant ou un redémarrage du serveur, les machines cochées repartent toutes seules.")
            }
            Section("Snapshots") { snapsRows(g) }
            Section("Sauvegardes") { backupRows(g) }
        }
        .navigationTitle(g.name.str.isEmpty ? "sans nom" : g.name.str)
        .task(id: "\(id)\(tf)") {
            while !Task.isCancelled {
                if let r = try? await API.shared.get("/api/rrd", q(g).merging(["tf": tf]) { $1 }) { rrd = r.data.arr }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: hub.taskTick) { await loadExtras(g) }
        .refreshable { await hub.refresh(); await loadExtras(g) }
        .sheet(isPresented: $showRes) { ResourcesSheet(g: g, cfg: cfg) { cfg = $0 } }
        .sheet(isPresented: $showSched) { GuestSchedSheet(g: g) }
    }

    private func act(_ g: J, _ action: String) {
        Task { await hub.runAction(base(g).merging(["action": action]) { $1 }) }
    }

    private func loadExtras(_ g: J) async {
        async let c = try? API.shared.get("/api/guest", q(g))
        async let s: () = hub.loadSched()
        do { snaps = try await API.shared.get("/api/snapshots", q(g)).items.arr; snapsErr = nil } catch { snapsErr = error.localizedDescription }
        do { bk = try await API.shared.get("/api/backups", q(g)); bkErr = nil } catch { bkErr = error.localizedDescription }
        if let r = await c { cfg = r; onboot = nil }
        _ = await s
    }

    private func setOnboot(_ g: J, _ v: Bool) async {
        onboot = v
        do {
            try await API.shared.post("/api/guest/config", base(g).merging(["onboot": v]) { $1 })
            hub.toast(v ? "✅ Démarrera avec le serveur" : "Ne démarrera plus avec le serveur")
        } catch {
            onboot = !v
            hub.fail(error)
        }
    }

    private func schedSummary(_ g: J) -> String {
        guard let all = hub.sched else { return "Chargement…" }
        let l = all.filter { $0.targets.arr.contains { $0.vmid.str == g.vmid.str && $0.type.str == g.type.str } }
        if l.isEmpty { return "Allumer ou éteindre à heure fixe" }
        return l.map { "\($0.enabled.bool ? "" : "⏸ ")\(SCHED_ACT[$0.action.str] ?? "") à \($0.time.str)" }.joined(separator: " · ")
    }

    private func askHermes(_ g: J) {
        let on = g.status.str == "running"
        let label = "\(kind(g.type.str)) \(g.vmid.str) « \(g.name.str.isEmpty ? "sans nom" : g.name.str) »"
        let ctx = "État actuel vu par PVE Hub : \(label) sur le nœud \(g.node.str), \((STATUS[g.status.str] ?? g.status.str).lowercased())\(on ? " depuis " + up(g.uptime.num) : ""). "
            + "CPU \(on ? p0(g.cpu.num * 100) + " %" : "–") sur \(g.maxcpu.int) cœur(s), mémoire \(on ? fb(g.mem.num) : "–") / \(fb(g.maxmem.num)), disque \(g.disk.num > 0 ? fb(g.disk.num) : "–") / \(fb(g.maxdisk.num))."
        hub.chat.ask("Regarde la \(label) : est-ce que tout va bien ? Si quelque chose cloche, explique-moi pourquoi et propose une solution.", context: ctx)
    }

    @ViewBuilder
    private func snapsRows(_ g: J) -> some View {
        if let snapsErr { Text(snapsErr).foregroundStyle(.secondary) }
        else if let snaps {
            ForEach(snaps) { s in
                Button {
                    Task {
                        let i = await Dialog.actions(s.name.str, nil, [("Revenir à ce snapshot", false), ("Supprimer le snapshot", true)])
                        if i >= 0 { await hub.runAction(base(g).merging(["action": i == 0 ? "rollback" : "snapdelete", "name": s.name.str]) { $1 }) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name.str).lineLimit(1)
                        Text([s.snaptime.num > 0 ? when(s.snaptime.num) : "", s.description.str.trimmed].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }
            Button {
                Task {
                    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
                    guard let v = await Dialog.form("Nouveau snapshot", g.name.str, [.init(placeholder: "Nom", value: "pvehub-" + f.string(from: Date())),
                                                                                     .init(placeholder: "Description (facultatif)")]) else { return }
                    await hub.runAction(base(g).merging(["action": "snapshot", "name": v[0].trimmed, "description": v[1]]) { $1 }, skipConfirm: true)
                }
            } label: { LinkRow(symbol: "camera.fill", color: .blue, title: "Créer un snapshot") }
        } else { LoadingRow() }
    }

    @ViewBuilder
    private func backupRows(_ g: J) -> some View {
        if let bkErr { Text(bkErr).foregroundStyle(.secondary) }
        else if let bk {
            ForEach(bk.items.arr.prefix(15)) { b in
                Button {
                    Task {
                        if await Dialog.actions("Sauvegarde", when(b.ctime.num), [("Restaurer sur cette machine", true)]) == 0 {
                            await hub.runAction(base(g).merging(["action": "restore", "volid": b.volid.str]) { $1 })
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(when(b.ctime.num) + (b.protected.bool ? " 🔒" : ""))
                        Text([b.storage.str, fb(b.size.num), b.notes.str].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }
            let stores = bk.storages.strs
            if stores.isEmpty {
                Text("Aucun stockage de sauvegarde sur ce nœud").foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        var si = 0
                        if stores.count > 1 { si = await Dialog.actions("Stockage", nil, stores.map { ($0, false) }) }
                        guard si >= 0 else { return }
                        let modes = [("snapshot", "Sans arrêt (snapshot)"), ("suspend", "Pause pendant la copie"), ("stop", "Arrêt pendant la copie")]
                        let mi = await Dialog.actions("Mode", nil, modes.map { ($0.1, false) })
                        guard mi >= 0 else { return }
                        await hub.runAction(base(g).merging(["action": "backup", "storage": stores[si], "mode": modes[mi].0]) { $1 }, skipConfirm: true)
                    }
                } label: { LinkRow(symbol: "arrow.down.doc.fill", color: .green, title: "Sauvegarder maintenant") }
            }
        } else { LoadingRow() }
    }
}

func execTargetJSON(_ g: J) -> String {
    "{\"type\":\"\(g.type.str)\",\"node\":\"\(g.node.str)\",\"vmid\":\(g.vmid.int)}"
}

struct PowerButton: View {
    let title: String
    let symbol: String
    let color: Color
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(enabled ? color : Color.secondary)
                Text(title).font(.caption).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Ressources (cœurs, mémoire, disque)
struct ResourcesSheet: View {
    @EnvironmentObject var hub: Hub
    @Environment(\.dismiss) private var dismiss
    let g: J
    let cfg: J?
    let onSaved: (J) -> Void
    @State private var cores = 1
    @State private var memory = ""
    @State private var grow = 0
    @State private var busy = false

    private var c: J { cfg?.config ?? J(nil) }
    private var origCores: Int { c.cores.int > 0 ? c.cores.int : g.maxcpu.int }
    private var origMem: Double { ((c.memory.opt ?? g.maxmem.num / 1_048_576) / 1024 * 100).rounded() / 100 }
    private var diskSize: String {
        let d = ["rootfs", "scsi0", "virtio0", "sata0", "ide0"].map { c[$0].str }.first { !$0.isEmpty } ?? ""
        guard let r = d.range(of: #"size=[\d.]+[KMGT]?"#, options: .regularExpression) else { return "" }
        let v = d[r].dropFirst(5)
        return v.last?.isLetter == true ? "\(v.dropLast()) \(v.last!)o" : "\(v) Go"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Cœurs : \(cores)", value: $cores, in: 1...256)
                    HStack {
                        Text("Mémoire (Go)")
                        TextField("2", text: $memory).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } footer: { Text("\(kind(g.type.str)) \(g.vmid.str)") }
                Section {
                    Stepper("Agrandir le disque de \(grow) Go", value: $grow, in: 0...4096)
                } footer: {
                    Text((diskSize.isEmpty ? "" : "Disque actuel : \(diskSize). ") + "Proxmox ne sait pas réduire un disque.")
                }
            }
            .navigationTitle("Ressources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { Task { await save() } }.disabled(busy) }
            }
            .onAppear {
                cores = origCores
                memory = String(format: "%g", origMem).replacingOccurrences(of: ".", with: ",")
            }
        }
    }

    private func save() async {
        var body: [String: Any] = ["node": g.node.str, "type": g.type.str, "vmid": g.vmid.int]
        let newMem = Int(((Double(memory.replacingOccurrences(of: ",", with: ".")) ?? 0) * 1024).rounded())
        if cores != origCores { body["cores"] = cores }
        if newMem > 0 && newMem != Int((origMem * 1024).rounded()) { body["memory"] = newMem }
        if grow > 0 {
            guard await Dialog.confirm("Agrandir le disque de \(grow) Go ?", "C'est définitif : Proxmox ne sait pas réduire un disque.", "Agrandir") else { return }
            body["disk_grow"] = grow
        }
        if body.count == 3 { hub.toast("Rien n'a changé"); dismiss(); return }
        busy = true
        defer { busy = false }
        let t = hub.toast("⏳ Application…", seconds: 120)
        do {
            let r = try await API.shared.post("/api/guest/config", body)
            hub.dismissToast(t)
            hub.toast(r.restart_needed.bool ? "✅ Enregistré : appliqué au prochain redémarrage de la VM" : "✅ Ressources modifiées", seconds: 5)
            if let n = try? await API.shared.get("/api/guest", ["node": g.node.str, "type": g.type.str, "vmid": g.vmid.str]) { onSaved(n) }
            await hub.refresh()
            dismiss()
        } catch {
            hub.dismissToast(t)
            hub.fail(error, seconds: 6)
        }
    }
}
