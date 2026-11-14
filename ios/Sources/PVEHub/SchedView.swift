import SwiftUI

// Horaires d'allumage / d'extinction, exécutés par le serveur PVE Hub à l'heure du téléphone
let SCHED_DAYS: [(String, String)] = [("all", "tous les jours"), ("week", "du lundi au vendredi"), ("weekend", "le week-end")]
let SCHED_ACT = ["start": "Allumer", "shutdown": "Éteindre"]
func schedDays(_ k: String) -> String { SCHED_DAYS.first { $0.0 == k }?.1 ?? k }

/// Écran « Horaires » : tous les horaires
struct SchedView: View {
    @EnvironmentObject var hub: Hub
    @State private var editing: SchedEdit?

    var body: some View {
        List {
            Section {
                if let all = hub.sched {
                    ForEach(all.sorted { $0.time.str < $1.time.str }) { x in
                        HStack(spacing: 12) {
                            IconBox(symbol: x.action.str == "start" ? "play.fill" : "power", color: x.action.str == "start" ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                (Text("\(SCHED_ACT[x.action.str] ?? "") à \(x.time.str) ") + Text(schedDays(x.days.str)).font(.footnote).foregroundColor(.secondary))
                                Text(x.targets.arr.map { hub.tName($0) }.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Actif", isOn: Binding(get: { x.enabled.bool }, set: { _ in Task { await hub.saveSched(["op": "toggle", "id": x.id]) } }))
                                .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await menu(x) } }
                    }
                } else { LoadingRow() }
                Button { editing = SchedEdit(item: nil, preset: []) } label: { LinkRow(symbol: "plus", color: .accentColor, title: "Nouvel horaire") }
            } footer: {
                Text("Touche un horaire pour le modifier. Exécutés par le serveur PVE Hub à ton heure, même app fermée ; chaque action est notée dans le Journal. « Éteindre » fait un arrêt propre.")
            }
        }
        .navigationTitle("Horaires")
        .task { await hub.loadSched() }
        .refreshable { await hub.loadSched() }
        .sheet(item: $editing) { SchedEditor(edit: $0) }
    }

    private func menu(_ x: J) async {
        let i = await Dialog.actions("\(SCHED_ACT[x.action.str] ?? "") à \(x.time.str)", schedDays(x.days.str), [("Modifier", false), ("Supprimer l'horaire", true)])
        if i == 0 { editing = SchedEdit(item: x, preset: []) }
        if i == 1 { await hub.saveSched(["op": "delete", "id": x.id]) }
    }
}

struct SchedEdit: Identifiable {
    let id = UUID()
    let item: J?
    let preset: [J]   // machines déjà cochées (depuis une fiche machine)
}

/// Éditeur : action, heure, jours et machines (plusieurs à la fois)
struct SchedEditor: View {
    @EnvironmentObject var hub: Hub
    @Environment(\.dismiss) private var dismiss
    let edit: SchedEdit
    @State private var action = "shutdown"
    @State private var time = hmDate("23:00")
    @State private var days = "all"
    @State private var sel: Set<String> = []
    @State private var busy = false

    private var guests: [J] { hub.guests.filter { !$0.template.bool }.sorted { $0.vmid.int < $1.vmid.int } }
    private func key(_ g: J) -> String { "\(g.type.str)/\(g.vmid.str)" }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $action) { Text("Allumer").tag("start"); Text("Éteindre").tag("shutdown") }
                    .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section {
                    DatePicker("Heure", selection: $time, displayedComponents: .hourAndMinute)
                    Picker("Jours", selection: $days) { ForEach(SCHED_DAYS, id: \.0) { Text($0.1.capitalizedFirst).tag($0.0) } }
                }
                Section {
                    ForEach(guests) { g in
                        Toggle(isOn: Binding(get: { sel.contains(key(g)) }, set: { if $0 { sel.insert(key(g)) } else { sel.remove(key(g)) } })) {
                            HStack(spacing: 12) {
                                IconBox(symbol: guestSymbol(g.type.str), color: guestColor(g.type.str))
                                VStack(alignment: .leading) {
                                    Text(guestTitle(g)).lineLimit(1)
                                    Text("\(kind(g.type.str)) \(g.vmid.str)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("Machines (\(sel.count))") } footer: {
                    Text("Les machines sont traitées dans l'ordre de la liste. Pour décaler une machine (dix minutes après les autres, par exemple), crée un second horaire.")
                }
            }
            .navigationTitle(edit.item == nil ? "Nouvel horaire" : "Horaire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { Task { await save() } }.bold().disabled(busy) }
            }
            .onAppear {
                if let it = edit.item {
                    action = it.action.str
                    time = hmDate(it.time.str)
                    days = it.days.str.isEmpty ? "all" : it.days.str
                }
                sel = Set((edit.item?.targets.arr ?? edit.preset).map { "\($0.type.str)/\($0.vmid.str)" })
            }
        }
    }

    private func save() async {
        let targets: [[String: Any]] = guests.filter { sel.contains(key($0)) }.map { ["node": $0.node.str, "type": $0.type.str, "vmid": $0.vmid.int] }
        guard !targets.isEmpty else { hub.toast("Choisis au moins une machine"); return }
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["op": edit.item == nil ? "add" : "update", "action": action, "time": hmString(time), "days": days,
                                   "targets": targets, "tz": TimeZone.current.identifier]
        if let it = edit.item { body["id"] = it.id }
        if await hub.saveSched(body) { dismiss() }
    }
}

/// Fiche d'une machine : ses horaires (seuls ou partagés avec d'autres machines)
struct GuestSchedSheet: View {
    @EnvironmentObject var hub: Hub
    @Environment(\.dismiss) private var dismiss
    let g: J
    @State private var editing: SchedEdit?

    private var mine: [J] {
        (hub.sched ?? []).filter { $0.targets.arr.contains { $0.vmid.str == g.vmid.str && $0.type.str == g.type.str } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(mine) { x in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(SCHED_ACT[x.action.str] ?? "") à \(x.time.str)")
                                let others = x.targets.arr.count - 1
                                Text(schedDays(x.days.str) + (others > 0 ? " · avec \(plural(others, "autre")) machine\(others > 1 ? "s" : "")" : ""))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await hub.saveSched(["op": "remove_target", "id": x.id, "type": g.type.str, "vmid": g.vmid.int]) }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Retirer cette machine de l'horaire")
                            Toggle("Actif", isOn: Binding(get: { x.enabled.bool }, set: { _ in Task { await hub.saveSched(["op": "toggle", "id": x.id]) } }))
                                .labelsHidden()
                        }
                    }
                    Button { editing = SchedEdit(item: nil, preset: [g]) } label: { LinkRow(symbol: "plus", color: .accentColor, title: "Ajouter un horaire") }
                    Button("Tous les horaires") { dismiss(); hub.open(.sched) }
                } header: { Text(guestTitle(g)) } footer: {
                    Text("À ton heure, même app fermée : c'est le serveur PVE Hub qui s'en charge. La corbeille retire cette machine de l'horaire ; un horaire partagé se modifie dans « Tous les horaires ».")
                }
            }
            .navigationTitle("Horaires")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .sheet(item: $editing) { SchedEditor(edit: $0) }
        }
    }
}
