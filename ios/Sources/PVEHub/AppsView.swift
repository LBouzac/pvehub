import SwiftUI

// MARK: - Logos
private let APP_COLORS: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .green, .teal]
func appColor(_ s: String) -> Color {
    var h: UInt32 = 7
    for c in s { h = h &* 31 &+ UInt32(c.utf16.first ?? 0) }
    return APP_COLORS[Int(h % UInt32(APP_COLORS.count))]
}
func csIcon(_ slug: String) -> String { "https://cdn.jsdelivr.net/gh/selfhst/icons/webp/\(slug).webp" }  // logos du catalogue communautaire
func logoSrc(_ s: String) -> String {
    switch s {
    case "pvehub", "pvehub-light": return API.shared.server + "/icon.png"
    case "pvehub-dark": return API.shared.server + "/icon-dark.png"
    default: return s.hasPrefix("https:") ? s : csIcon(s)
    }
}

/// Initiale sur fond coloré, recouverte par le premier logo qui se charge
struct AppLogo: View {
    let name: String
    let sources: [String]
    var size: CGFloat = 60
    @State private var idx = 0

    private var urls: [URL] {
        var seen = Set<String>()
        return sources.filter { !$0.isEmpty && seen.insert($0).inserted }.compactMap(URL.init(string:))
    }

    var body: some View {
        ZStack {
            appColor(name)
            Text(name.trimmed.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            if idx < urls.count {
                AsyncImage(url: urls[idx]) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit().padding(size * 0.12)
                            .frame(width: size, height: size)
                            .background(Color(.secondarySystemGroupedBackground))
                    case .failure:
                        Color.clear.onAppear { idx += 1 }
                    default:
                        Color.clear
                    }
                }
                .id(idx)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

func appLogo(_ a: J, size: CGFloat = 60) -> AppLogo {
    var fav = ""
    if let u = URL(string: a.url.str), let scheme = u.scheme, let host = u.host {
        fav = "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")/favicon.ico"
    }
    return AppLogo(name: a.name.str, sources: [a.icon.str.isEmpty ? "" : logoSrc(a.icon.str),
                                               a.icon2.str.isEmpty || a.icon2.str == a.icon.str ? "" : csIcon(a.icon2.str), fav], size: size)
}

// MARK: - Mes apps
struct AppsView: View {
    @EnvironmentObject var hub: Hub
    @Environment(\.openURL) private var openURL
    @State private var edit = false
    @State private var follow: String?

    private var mine: [J] { (hub.apps ?? []).filter { $0.added.bool } }
    private var sugg: [J] { (hub.apps ?? []).filter { !$0.added.bool && !$0.custom.bool } }

    var body: some View {
        NavigationStack(path: $hub.appsPath) {
            List {
                if let _ = hub.apps {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 16) {
                            ForEach(mine) { a in tile(a) }
                            Button { Task { await add() } } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "plus").font(.title.weight(.semibold)).foregroundStyle(.tint)
                                        .frame(width: 60, height: 60)
                                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    Text("Ajouter").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                    } footer: {
                        if mine.isEmpty { Text("Touche + et colle l'adresse d'une app, ou choisis-la dans les suggestions.") }
                        else if edit { Text("Touche une app pour la renommer, changer son adresse ou son logo, ou la retirer de l'écran.") }
                    }
                    suggestions
                } else {
                    Text(hub.appsErr ?? "Chargement…").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !edit {
                        NavigationLink(value: Route.store) { Image(systemName: "bag") }.accessibilityLabel("Store")
                    }
                    Button(edit ? "OK" : "Modifier") { edit.toggle() }.bold(edit)
                    Button { hub.showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Réglages")
                }
            }
            .navigationDestination(for: Route.self) { destination($0) }
            .refreshable { await hub.loadApps() }
            .task { if hub.appsAt.timeIntervalSinceNow < -30 { await hub.loadApps() } }
            .sheet(item: Binding(get: { follow.map(JobRef.init) }, set: { follow = $0?.id })) { JobSheet(jobId: $0.id) }
        }
    }

    private func tile(_ a: J) -> some View {
        Button { Task { await tap(a) } } label: {
            VStack(spacing: 6) {
                appLogo(a)
                    .overlay(alignment: .topTrailing) {
                        if !a.up.isNil {
                            Circle().fill(a.up.bool ? Color.green : Color.red).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2)).offset(x: 3, y: -3)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if edit { Image(systemName: "minus.circle.fill").foregroundStyle(.white, .gray).offset(x: -6, y: -6) }
                    }
                Text(a.name.str).font(.caption).lineLimit(1).foregroundStyle(.primary)
            }
            .opacity(a.off.bool ? 0.4 : 1)
        }
        .buttonStyle(.plain)
    }

    private var suggestions: some View {
        let searching = !hub.appsFull && hub.appsErr == nil
        return Section {
            ForEach(sugg) { a in
                HStack(spacing: 12) {
                    appLogo(a, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name.str).lineLimit(1)
                        Text(suggSub(a)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Ajouter") { Task { await hub.saveApp(["op": "edit", "id": a.id, "added": true]) } }
                        .bold().buttonStyle(.borderless)
                }
            }
            if sugg.isEmpty {
                Text(searching ? "Recherche sur tes machines…" : hub.appsScan ? "Rien de plus trouvé sur tes machines." : "Active la section Commandes pour détecter les apps de tes machines.")
                    .foregroundStyle(.secondary)
            }
            if hub.appsScan && !searching {
                Button("Rechercher à nouveau") { Task { hub.appsFull = false; await hub.loadApps(rescan: true) } }
            }
        } header: { Text("Suggestions") } footer: { Text("Programmes et conteneurs Docker trouvés sur tes machines allumées.") }
    }

    private func suggSub(_ a: J) -> String {
        let m = hub.guest(a.guest.str).map { "\(guestTitle($0)) · \(kind($0.type.str)) \($0.vmid.str)" } ?? ""
        let tail = a.off.bool ? "arrêtée" : a.url.str.isEmpty ? "sans page web" : a.url.str.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        return [m, tail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func tap(_ a: J) async {
        if !edit {
            if !a.url.str.isEmpty && !a.off.bool, let u = URL(string: a.url.str) { openURL(u) }
            else if hub.guest(a.guest.str) != nil { hub.appsPath.append(Route.guest(a.guest.str)) }
            return
        }
        var acts: [(String, Bool, () async -> Void)] = [
            ("Renommer", false, {
                if let v = await Dialog.form("Renommer", "Laisse vide pour revenir au nom d'origine.", [.init(placeholder: "Nom", value: a.name.str)]) {
                    await hub.saveApp(["op": "edit", "id": a.id, "name": v[0].trimmed])
                }
            }),
            ("Changer l'adresse", false, {
                if let v = await Dialog.form("Adresse", nil, [.init(placeholder: "http://…", value: a.url.str, keyboard: .URL)]) {
                    await hub.saveApp(["op": "edit", "id": a.id, "url": withScheme(v[0].trimmed)])
                }
            }),
            ("Changer le logo", false, { await changeLogo(a) }),
            a.custom.bool ? ("Supprimer", true, { await hub.saveApp(["op": "delete", "id": a.id]) })
                          : ("Retirer de l'écran", false, { await hub.saveApp(["op": "edit", "id": a.id, "added": false]) }),
        ]
        if !a.store.isNil { acts.append(("Désinstaller l'app…", true, { await uninstall(a) })) }
        let i = await Dialog.actions(a.name.str, a.url.str.isEmpty ? "Sans interface web" : a.url.str, acts.map { ($0.0, $0.1) })
        if i >= 0 { await acts[i].2() }
    }

    private func changeLogo(_ a: J) async {
        if a.icon.str.hasPrefix("pvehub") {  // PVE Hub : son logo clair ou sombre
            let j = await Dialog.actions("Logo de PVE Hub", nil, [("Clair", false), ("Sombre", false), ("Autre logo…", false)])
            if j == 0 || j == 1 { await hub.saveApp(["op": "edit", "id": a.id, "icon": j == 1 ? "pvehub-dark" : "pvehub"]); return }
            if j != 2 { return }
        }
        if let v = await Dialog.form("Logo", "Le nom d'un logo de selfh.st/icons (ex. vaultwarden), ou l'adresse https d'une image. Laisse vide pour revenir au logo détecté.",
                                     [.init(placeholder: "jellyfin", value: a.icon.str)]) {
            await hub.saveApp(["op": "edit", "id": a.id, "icon": v[0].trimmed])
        }
    }

    private func uninstall(_ a: J) async {
        let i = await Dialog.actions("Désinstaller \(a.name.str) ?", "Le conteneur \(a.store.str) et ses disques seront supprimés.",
                                     [("Sauvegarder puis supprimer", true), ("Supprimer sans sauvegarde", true)])
        guard i >= 0 else { return }
        do {
            let r = try await API.shared.post("/api/store/uninstall", ["vmid": a.store.int, "backup": i == 0])
            hub.addJob(["id": r.job.str, "kind": "uninstall", "name": a.name.str, "status": "running", "log": [Any]()])
            follow = r.job.str
        } catch { hub.fail(error, seconds: 6) }
    }

    private func add() async {
        guard let v = await Dialog.form("Ajouter une app", "Son adresse, par exemple 192.168.1.20:8096. Le nom est facultatif.",
                                        [.init(placeholder: "http://192.168.1.20:8096", keyboard: .URL), .init(placeholder: "Nom (facultatif)")]),
              !v[0].trimmed.isEmpty else { return }
        let url = withScheme(v[0].trimmed), name = v[1].trimmed
        guard let u = URL(string: url), let host = u.host else { hub.toast("Adresse invalide"); return }
        // une app déjà détectée à cette adresse : on la garde (logo, état, machine)
        let origin = { (s: String) -> String? in URL(string: s).flatMap { x in x.host.map { "\(x.scheme ?? "")://\($0):\(x.port ?? 0)" } } }
        if let hit = (hub.apps ?? []).first(where: { !$0.custom.bool && !$0.url.str.isEmpty && origin($0.url.str) == origin(url) }) {
            var body: [String: Any] = ["op": "edit", "id": hit.id, "added": true]
            if !name.isEmpty { body["name"] = name }
            if url != hit.url.str { body["url"] = url }
            await hub.saveApp(body)
        } else {
            await hub.saveApp(["op": "add", "name": name.isEmpty ? host : name, "url": url])
        }
    }
}

struct JobRef: Identifiable { let id: String }

// MARK: - Store : applications à installer (communauté + modèles officiels TurnKey)
struct StoreView: View {
    @EnvironmentObject var hub: Hub
    @State private var src = "community"
    @State private var tag = ""
    @State private var q = ""
    @State private var items: [String: J] = [:]
    @State private var err: String?
    @State private var removed: [J] = []
    @State private var item: J?
    @State private var follow: String?

    private var cat: J? { items[src] }
    private var list: [J]? {
        guard let cat else { return nil }
        let s = q.trimmed.lowercased()
        return cat.items.arr.filter { i in
            (tag.isEmpty || i.tags.strs.contains(tag)) &&
            (s.isEmpty || i.name.str.lowercased().contains(s) || i.id.contains(s) || i.tags.strs.contains { $0.contains(s) } || i.desc.str.lowercased().contains(s))
        }
    }
    private var tags: [String] {
        var count: [String: Int] = [:]
        for t in (cat?.items.arr ?? []).flatMap({ $0.tags.strs }) where t != "officiel" { count[t, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }.prefix(14).map(\.key)
    }
    private var running: [J] { hub.storeJobs.values.map { J($0) }.filter { $0.status.str == "running" } }

    var body: some View {
        List {
            Picker("Source", selection: $src) { Text("Communauté").tag("community"); Text("Officiel").tag("turnkey") }
                .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        TagChip(text: "Toutes", on: tag.isEmpty) { tag = "" }
                        ForEach(tags, id: \.self) { t in TagChip(text: t, on: tag == t) { tag = t } }
                    }
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if !running.isEmpty {
                Section {
                    ForEach(running) { j in
                        Button { follow = j.id } label: {
                            LinkRow(symbol: "arrow.down.circle.fill", color: .accentColor, title: "\(jobWord(j.kind.str).0) de \(j.name.str)…", subtitle: "Touche pour suivre")
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            if !removed.isEmpty {
                Section("Désinstallées") {
                    ForEach(removed) { r in
                        Button { Task { await restore(r) } } label: {
                            HStack(spacing: 12) {
                                IconBox(symbol: "arrow.down.doc.fill", color: .gray)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name.str).lineLimit(1)
                                    Text("Sauvegarde du \(when(r.ctime.opt ?? r.at.num)) · CT \(r.vmid.str)").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Pill(text: "Réinstaller")
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            Section {
                catalogRows
            } footer: { Text(footer) }
        }
        .navigationTitle("Store")
        .searchable(text: $q, prompt: "Rechercher une app")
        .toolbar {
            if src == "community" {
                Button("Actualiser") { items[src] = nil; Task { await load(refresh: true) } }
            }
        }
        .task(id: src) {
            tag = ""
            if items[src] == nil { await load() }
            while !Task.isCancelled, items[src]?.building.bool == true {  // catalogue en préparation
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
        .task { await loadRemoved() }
        .sheet(item: Binding(get: { item.map { StoreItemRef(item: $0, src: src) } }, set: { item = $0?.item })) { ref in
            StoreItemSheet(item: ref.item, src: ref.src, exec: items["community"]?.exec.bool ?? false) { job in follow = job }
        }
        .sheet(item: Binding(get: { follow.map(JobRef.init) }, set: { follow = $0?.id }), onDismiss: { Task { await loadRemoved() } }) { JobSheet(jobId: $0.id) }
    }

    @ViewBuilder
    private var catalogRows: some View {
        if let err { Text(err).foregroundStyle(.secondary) }
        else if let cat, let list {
            if !cat.error.isNil && cat.items.arr.isEmpty { Text(cat.error.str).foregroundStyle(.secondary) }
            else if cat.building.bool && cat.items.arr.isEmpty { Text("Préparation du catalogue (première fois, quelques secondes)…").foregroundStyle(.secondary) }
            else if list.isEmpty { Text("Aucune app ne correspond").foregroundStyle(.secondary) }
            else {
                ForEach(list.prefix(120)) { i in
                    Button { item = i } label: {
                        HStack(spacing: 12) {
                            AppLogo(name: i.name.str, sources: src == "community" ? [csIcon(i.id)] : [], size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.name.str).lineLimit(1)
                                Text(src == "turnkey" ? (i.desc.str.isEmpty ? i.os.str : i.desc.str) : [i.tags.strs.joined(separator: ", "), resources(i)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        } else { LoadingRow() }
    }

    private var footer: String {
        var s = ""
        if let list, !(cat?.building.bool == true && cat?.items.arr.isEmpty == true) {
            s = list.count > 120 ? "\(list.count) apps : affine la recherche pour voir les autres. " : "\(plural(list.count, "app")). "
        }
        return s + (src == "community" ? "Scripts de la communauté Proxmox VE Helper-Scripts (non officiels), installés avec leurs réglages par défaut."
                                       : "Modèles officiels de Proxmox (appliances TurnKey Linux), installés par l'API de Proxmox.")
    }

    private func load(refresh: Bool = false) async {
        let s = src
        do {
            var q = ["source": s]
            if refresh { q["refresh"] = "1" }
            items[s] = try await API.shared.get("/api/store", q)
            err = nil
        } catch { err = error.localizedDescription }
    }
    private func loadRemoved() async { removed = (try? await API.shared.get("/api/store/removed"))?.items.arr ?? [] }

    private func restore(_ r: J) async {
        let i = await Dialog.actions("Réinstaller \(r.name.str) ?", "Le conteneur est recréé à partir de sa sauvegarde du \(when(r.ctime.opt ?? r.at.num)), tel qu'il était à la désinstallation, puis démarré.",
                                     [("Réinstaller", false), ("Retirer de la liste", true)])
        if i == 1 {
            do { try await API.shared.post("/api/store/restore", ["id": r.id, "forget": true]) } catch { hub.fail(error) }
            await loadRemoved()
        }
        guard i == 0 else { return }
        do {
            let j = try await API.shared.post("/api/store/restore", ["id": r.id])
            hub.addJob(["id": j.job.str, "kind": "restore", "name": r.name.str, "status": "running", "log": [Any]()])
            follow = j.job.str
        } catch { hub.fail(error, seconds: 6) }
    }
}

struct StoreItemRef: Identifiable {
    let item: J
    let src: String
    var id: String { item.id }
}

struct TagChip: View {
    let text: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

func resources(_ i: J) -> String {
    [i.cpu.int > 0 ? plural(i.cpu.int, "cœur") : "",
     i.ram.int > 0 ? (i.ram.int >= 1024 ? "\(String(format: "%g", i.ram.num / 1024)) Go" : "\(i.ram.int) Mo") : "",
     i.disk.int > 0 ? "\(i.disk.int) Go disque" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
}
func jobWord(_ kind: String) -> (String, String) {
    kind == "uninstall" ? ("Désinstallation", "Désinstallé") : kind == "restore" ? ("Réinstallation", "Réinstallé") : ("Installation", "Installé")
}

struct StoreItemSheet: View {
    @EnvironmentObject var hub: Hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let item: J
    let src: String
    let exec: Bool
    let onJob: (String) -> Void
    @State private var opts: [J]?
    @State private var node = ""
    @State private var storage = ""
    @State private var tstorage = ""
    @State private var bridge = ""
    @State private var busy = false

    private var community: Bool { src == "community" }
    private var o: J? { opts?.first { $0.node.str == node } ?? opts?.first }
    private var canInstall: Bool { (!community || exec) && !(o?.rootdir.arr.isEmpty ?? true) && !(o?.vztmpl.arr.isEmpty ?? true) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AppLogo(name: item.name.str, sources: community ? [csIcon(item.id)] : [], size: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name.str).font(.title2.bold()).lineLimit(1)
                            Text(community ? "Script communautaire" : "Modèle officiel · TurnKey").font(.subheadline).foregroundStyle(.secondary)
                            if let u = URL(string: item.site.str), !item.site.str.isEmpty { Button("Site") { openURL(u) }.font(.subheadline) }
                        }
                    }
                    if !item.desc.str.isEmpty { Text(item.desc.str) }
                }
                Section {
                    LabeledContent(community ? "Ressources par défaut" : "Ressources", value: community ? (resources(item).isEmpty ? "—" : resources(item)) : "2 cœurs · 1 Go · 8 Go disque")
                    LabeledContent("Système", value: item.os.str.isEmpty ? "—" : item.os.str)
                    if community { LabeledContent("Catégories", value: item.tags.strs.isEmpty ? "—" : item.tags.strs.joined(separator: ", ")) }
                }
                Section {
                    if let opts {
                        if opts.count > 1 { picker("Nœud", opts.map { $0.node.str }, $node) }
                        picker("Disque du conteneur", o?.rootdir.strs ?? [], $storage)
                        picker("Modèles", o?.vztmpl.strs ?? [], $tstorage)
                        picker("Réseau", o?.bridges.strs ?? [], $bridge)
                    } else { LoadingRow() }
                } header: { Text("Installation") } footer: {
                    Text(community ? "Ce script de la communauté s'exécute en root sur ton serveur et crée un nouveau conteneur avec ses réglages par défaut (environ 2 à 10 minutes)."
                                   : "Proxmox télécharge le modèle puis crée et démarre un nouveau conteneur. Un mot de passe root sera généré.")
                }
                Section {
                    Button { Task { await install() } } label: { HStack { Spacer(); Text("Installer").bold(); Spacer() } }
                        .disabled(!canInstall || busy)
                } footer: {
                    if community && !exec { Text("Active la section Commandes pour installer depuis l'app.") }
                }
                if community {
                    Section {
                        Button("Copier la commande (pour la console)") {
                            copyText("bash -c \"$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/\(item.id).sh)\"")
                        }
                    } footer: { Text("Pour choisir toi-même les réglages : colle cette commande dans le Shell de Proxmox et prends « Advanced ».") }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
            .task { await loadOpts() }
            .onChange(of: node) { _, _ in pickDefaults() }
        }
    }

    private func picker(_ label: String, _ values: [String], _ sel: Binding<String>) -> some View {
        Group {
            if values.isEmpty {
                LabeledContent(label) { Text("aucun").foregroundStyle(.red) }
            } else {
                Picker(label, selection: sel) { ForEach(values, id: \.self) { Text($0).tag($0) } }
            }
        }
    }

    private func loadOpts() async {
        if let cached = hub.storeOpts { opts = cached } else {
            do { hub.storeOpts = try await API.shared.get("/api/store/options").nodes.arr; opts = hub.storeOpts }
            catch { hub.fail(error); dismiss(); return }
        }
        node = opts?.first?.node.str ?? ""
        pickDefaults()
    }
    private func pickDefaults() {
        guard let o else { return }
        let r = o.rootdir.strs, t = o.vztmpl.strs, b = o.bridges.strs
        storage = r.first { $0.range(of: "lvm|zfs", options: [.regularExpression, .caseInsensitive]) != nil } ?? r.first ?? ""
        tstorage = t.contains("local") ? "local" : t.first ?? ""
        bridge = b.contains("vmbr0") ? "vmbr0" : b.first ?? ""
    }

    private func install() async {
        if community, !(await Dialog.confirm("Installer \(item.name.str) ?", "Le script communautaire va s'exécuter en root sur ton serveur.", "Installer")) { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await API.shared.post("/api/store/install", ["source": src, "id": item.id, "node": o?.node.str ?? node,
                                                                    "storage": storage, "tstorage": tstorage, "bridge": bridge])
            hub.addJob(["id": r.job.str, "name": item.name.str, "source": src, "status": "running", "log": [Any]()])
            dismiss()
            onJob(r.job.str)
        } catch { hub.fail(error, seconds: 6) }
    }
}

/// Suivi d'une installation, désinstallation ou réinstallation
struct JobSheet: View {
    @EnvironmentObject var hub: Hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let jobId: String

    private var job: J { J(hub.storeJobs[jobId] ?? [:]) }

    var body: some View {
        let done = job.status.str != "running", un = job.kind.str == "uninstall", w = jobWord(job.kind.str)
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(!done ? "⏳ \(w.0) en cours…" : job.status.str == "done" ? "✅ \(w.1)" : "❌ Échec")
                        if !job.error.str.isEmpty { Text(job.error.str).font(.subheadline).foregroundStyle(.red) }
                        if !job.vmid.str.isEmpty { Text("Conteneur \(job.vmid.str)").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    if !job.url.str.isEmpty && !un, let u = URL(string: job.url.str) {
                        Button("Ouvrir \(job.url.str)") { openURL(u) }
                    }
                    if !job.password.str.isEmpty {
                        LabeledContent("Mot de passe root") { Text(job.password.str).font(.body.monospaced()).textSelection(.enabled) }
                        Button("Copier le mot de passe") { copyText(job.password.str) }
                    }
                } footer: {
                    if !job.password.str.isEmpty && done {
                        Text("Dernière étape : dans Proxmox, ouvre la Console du conteneur \(job.vmid.str) et connecte-toi en root avec ce mot de passe. L'assistant TurnKey te demande alors les mots de passe de l'application et termine sa configuration. Note ce mot de passe : il ne sera plus affiché.")
                    } else if done && job.status.str == "done" {
                        Text(un ? "Avec une sauvegarde, l'app reste réinstallable depuis le Store (section « Désinstallées »)." : "L'app apparaîtra dans l'onglet Apps (Modifier → toucher l'app pour la désinstaller).")
                    }
                }
                Section("Journal") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(job.log.strs.suffix(40).joined(separator: "\n").isEmpty ? "…" : job.log.strs.suffix(40).joined(separator: "\n"))
                                .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(height: 260)
                        .onChange(of: job.log.strs.count) { _, _ in proxy.scrollTo("end") }
                    }
                }
            }
            .navigationTitle(job.name.str)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(done ? "OK" : "Masquer") { dismiss() } } }
            .task { await poll() }
        }
    }

    private func poll() async {
        while !Task.isCancelled, job.status.str == "running" {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            var j = hub.storeJobs[jobId] ?? [:]
            do {
                for (k, v) in try await API.shared.get("/api/store/job", ["id": jobId]).dict { j[k] = v }
            } catch {
                j["status"] = "error"
                j["error"] = error.localizedDescription
            }
            hub.storeJobs[jobId] = j
            let r = J(j)
            if r.status.str != "running" {
                hub.saveJobs()
                if r.status.str == "done" { hub.toast("✅ \(r.name.str) \(jobWord(r.kind.str).1.lowercased())") }
                await hub.loadApps()
            }
        }
    }
}
