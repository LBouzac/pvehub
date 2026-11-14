import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var chat: ChatModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mode") private var mode = "auto"
    @AppStorage("accent") private var accent = "blue"
    @State private var push: J?
    @State private var allowed: UNAuthorizationStatus?
    @State private var remote: J?
    @State private var auth: J?
    @State private var checking = false

    private var s: J { push?.settings ?? J(nil) }

    var body: some View {
        NavigationStack {
            Form {
                appearance
                notifications
                assistant
                remoteSection
                update
                security
                Section("Compte") {
                    LabeledContent("Serveur", value: API.shared.server)
                    Button("Se déconnecter", role: .destructive) { Task { dismiss(); await hub.logout() } }
                }
            }
            .navigationTitle("Réglages")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .task {
                async let p = try? API.shared.get("/api/push")
                async let r = try? API.shared.get("/api/remote")
                async let a = try? API.shared.get("/api/auth")
                (push, remote, auth) = await (p ?? J(["available": false]), r, a)
                allowed = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            }
        }
    }

    // MARK: apparence
    private var appearance: some View {
        Section {
            Picker("Apparence", selection: $mode) { Text("Auto").tag("auto"); Text("Clair").tag("light"); Text("Sombre").tag("dark") }
                .pickerStyle(.segmented)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 9), spacing: 8) {
                ForEach(ACCENTS, id: \.0) { k, l in
                    Button { accent = k } label: {
                        Circle().fill(accentTint(k)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary, lineWidth: accent == k ? 2.5 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l)
                    .accessibilityAddTraits(accent == k ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        } header: { Text("Apparence") } footer: {
            Text("Auto suit le réglage de ton iPhone. Couleur : \(ACCENTS.first { $0.0 == accent }?.1 ?? "").")
        }
    }

    // MARK: notifications (alertes calculées par le serveur)
    @ViewBuilder
    private var notifications: some View {
        Section {
            if let p = push {
                if !p.available.bool {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mise à jour nécessaire")
                        Text("Le module de notifications n'est pas installé. Relance la mise à jour de PVE Hub.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    if !p.apns.bool {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reçues via la version web")
                            Text("Ce serveur n'a pas de clé de notifications iPhone (APNs). Pour recevoir les alertes, ouvre PVE Hub dans Safari (adresse Tailscale en https), ajoute-le à l'écran d'accueil et active les notifications depuis ses Réglages.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else if allowed == .denied {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications refusées")
                            Text("Autorise-les pour PVE Hub dans les Réglages de l'iPhone.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("Ouvrir les Réglages de l'iPhone") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    } else if allowed == .authorized {
                        Label("Activées sur cet iPhone", systemImage: "checkmark.circle.fill")
                    } else {
                        Button("Activer les notifications sur cet iPhone") {
                            Task {
                                await hub.enablePush()
                                allowed = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                            }
                        }
                    }
                    Button("Envoyer une notification de test") {
                        Task {
                            do { let r = try await API.shared.post("/api/push/test"); hub.toast("🔔 Envoyée à \(plural(r.sent.int, "appareil"))") }
                            catch { hub.fail(error, seconds: 6) }
                        }
                    }
                }
            } else { LoadingRow() }
        } header: { Text("Notifications") } footer: {
            if push?.available.bool == true {
                let n = push?.devices.int ?? 0
                Text((n > 0 ? "\(plural(n, "appareil")) abonné\(n > 1 ? "s" : ""). " : "Aucun appareil abonné pour l'instant. ") + "Les alertes sont vérifiées chaque minute par le serveur, même quand l'app est fermée.")
            }
        }
        if push?.available.bool == true {
            Section("Alertes") {
                alertToggle("stopped", "Machine arrêtée", "Sans qu'aucun arrêt n'ait été demandé")
                alertToggle("apps", "App hors ligne", "Une app de l'onglet Apps ne répond plus")
                alertToggle("disk", "Disque ou stockage plein")
                alertToggle("smart", "Santé des disques", "Panne SMART, usure ou température")
                if s.disk.bool {
                    Picker("Seuil", selection: Binding(get: { s.disk_threshold.int }, set: { v in Task { await setAlert("disk_threshold", v) } })) {
                        ForEach([80, 85, 90, 95], id: \.self) { Text("\($0) %").tag($0) }
                    }
                }
                alertToggle("backup", "Sauvegardes", "Échec, ou machine non sauvegardée depuis 7 jours")
                alertToggle("updates", "Résumé des mises à jour", "Une fois par semaine")
                alertToggle("dl", "Téléchargements", "Film ou série lancé, puis terminé (qBittorrent)")
                if s.dl.bool {
                    Button { Task { await qbConfig() } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("qBittorrent").foregroundStyle(.primary)
                            Text(s.qb_url.str.isEmpty ? "À configurer" : s.qb_url.str + (s.qb_user.str.isEmpty ? "" : " · " + s.qb_user.str))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                alertToggle("report", "Rapport du matin", hub.hermes ? "Hermes résume l'état du serveur chaque jour" : "Résumé de l'état du serveur chaque jour")
                if s.report.bool {
                    DatePicker("Heure du rapport", selection: Binding(get: { hmDate(s.report_time.str) }, set: { d in Task { await setAlert("report_time", hmString(d)) } }),
                               displayedComponents: .hourAndMinute)
                }
                Button("Recevoir le rapport maintenant") { dismiss(); Task { await chat.reportNow() } }
            }
        }
    }

    private func alertToggle(_ k: String, _ label: String, _ sub: String? = nil) -> some View {
        Toggle(isOn: Binding(get: { s[k].bool }, set: { v in Task { await setAlert(k, v) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let sub { Text(sub).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    /// Le fuseau du téléphone accompagne chaque réglage : le conteneur, lui, est à l'heure UTC
    private func setAlert(_ k: String, _ v: Any) async {
        do {
            let r = try await API.shared.post("/api/alerts", [k: v, "tz": TimeZone.current.identifier])
            var p = push?.dict ?? [:]
            p["settings"] = r.settings.v
            push = J(p)
            if k == "dl", (v as? Bool) == true, s.qb_url.str.isEmpty { await qbConfig() }
        } catch { hub.fail(error) }
    }

    /// qBittorrent : adresse de son interface web (Outils → Options → Interface web), identifiant et mot de passe
    private func qbConfig() async {
        guard let v = await Dialog.form("qBittorrent", "L'adresse de son interface web, et ses identifiants s'il en demande.",
                                        [.init(placeholder: "http://192.168.1.30:8080", value: s.qb_url.str, keyboard: .URL),
                                         .init(placeholder: "Identifiant (facultatif)", value: s.qb_user.str),
                                         .init(placeholder: s.qb_pass_set.bool ? "Mot de passe (inchangé)" : "Mot de passe", secure: true)]) else { return }
        let t = hub.toast("⏳ Connexion à qBittorrent…", seconds: 20)
        defer { hub.dismissToast(t) }
        do {
            let r = try await API.shared.post("/api/alerts", ["qb_url": withScheme(v[0].trimmed), "qb_user": v[1], "qb_pass": v[2]])
            var p = push?.dict ?? [:]
            p["settings"] = r.settings.v
            push = J(p)
            hub.toast("✅ qBittorrent connecté")
        } catch { hub.fail(error, seconds: 7) }
    }

    // MARK: assistant
    private var assistant: some View {
        let configured = hub.ov?.hermes_configured.bool ?? false
        return Section {
            Toggle(isOn: Binding(get: { hub.hermes }, set: { v in Task { await setHermes(v) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes")
                    Text(configured ? "Onglet, « Demander à Hermes », rapport rédigé" : "Non configuré").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .disabled(!configured)
        } header: { Text("Assistant") } footer: {
            Text(configured ? "Désactivé, Hermes disparaît de l'app sur tous tes appareils et le rapport du matin devient factuel. Tes conversations sont gardées."
                            : "Pour brancher Hermes, renseigne HERMES_URL et HERMES_KEY (section 3 du README).")
        }
    }
    private func setHermes(_ v: Bool) async {
        do {
            let r = try await API.shared.post("/api/settings", ["hermes": v])
            var o = hub.ov?.dict ?? [:]
            o["hermes"] = r.hermes.bool
            hub.ov = J(o)
            if !r.hermes.bool && hub.tab == .chat { hub.tab = .server }
        } catch { hub.fail(error) }
    }

    // MARK: accès à distance
    private var remoteSection: some View {
        let cmd = "bash <(curl -fsSL https://raw.githubusercontent.com/\(remote?.repo.str.isEmpty == false ? remote!.repo.str : "LBouzac/pvehub")/main/pvehub-install.sh) tailscale \(remote?.ctid.str.isEmpty == false ? remote!.ctid.str : "<ID>")"
        let running = remote?.installed.bool == true && remote?.state.str == "Running" && remote?.url.str.isEmpty == false
        return Section {
            if let r = remote {
                if running {
                    LabeledContent("Adresse", value: r.url.str.replacingOccurrences(of: "https://", with: ""))
                    Button("Copier l'adresse") { copyText(r.url.str) }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(r.installed.bool ? "Tailscale installé mais pas connecté (\(r.state.str.isEmpty ? "?" : r.state.str))" : "Non configuré")
                        Text(cmd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("Copier la commande") { copyText(cmd) }
                }
            } else { LoadingRow() }
        } header: { Text("Accès à distance") } footer: {
            Text(running ? "Depuis l'extérieur : l'app Tailscale doit être connectée sur ton téléphone, avec le même compte."
                         : "Pour ouvrir l'app hors de chez toi, en HTTPS, lance cette commande dans le Shell de Proxmox.")
        }
    }

    // MARK: mise à jour du serveur PVE Hub
    private var update: some View {
        Section {
            LabeledContent("Version") { Text(hub.ver?.local.str.isEmpty == false ? hub.ver!.local.str : "inconnue").font(.body.monospaced()) }
            if hub.ver?.available.bool == true {
                Button("Installer la nouvelle version") { Task { await hub.doUpdate() } }.disabled(hub.ver?.can_update.bool != true)
            } else {
                Button(checking ? "Vérification…" : !(hub.ver?.error.str ?? "").isEmpty ? hub.ver!.error.str : hub.ver != nil ? "À jour · Vérifier maintenant" : "Vérifier maintenant") {
                    Task { checking = true; await hub.checkVersion(force: true); checking = false }
                }
                .disabled(checking)
            }
        } header: { Text("Mise à jour") } footer: {
            Text(updateFooter)
        }
    }

    // découpé en étapes typées : en une seule expression, le compilateur d'Xcode abandonne (« unable to type-check »)
    private var updateFooter: String {
        var s = "Vérification automatique une fois par semaine."
        if let d = hub.ver?.checked_at.opt { s = "Dernière vérification : \(when(d)). " + s }
        if let v = hub.ver, v.can_update.bool != true { s += "\n" + v.why_not.str }
        return s
    }

    // MARK: sécurité
    @ViewBuilder
    private var security: some View {
        if let a = auth {
            if a.enabled.bool {
                Section {
                    ForEach(a.sessions.arr) { x in
                        Button { Task { await session(x) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(uaName(x.ua.str) + (x.current.bool ? " · cet appareil" : "")).foregroundStyle(.primary)
                                Text("\(x.who.str.isEmpty ? x.ip.str : x.who.str) · actif \(ago(x.seen.num))").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if a.sessions.arr.count > 1 {
                        Button("Déconnecter les autres appareils", role: .destructive) {
                            Task {
                                guard await Dialog.confirm("Déconnecter les autres appareils", "Tous les appareils devront se reconnecter, sauf celui-ci.", "Déconnecter", danger: true) else { return }
                                do { try await API.shared.post("/api/auth/revoke"); hub.toast("✅ Autres appareils déconnectés") } catch { hub.fail(error) }
                                auth = (try? await API.shared.get("/api/auth")) ?? auth
                            }
                        }
                    }
                } header: { Text("Appareils connectés") } footer: { Text("Touche un appareil pour le déconnecter.") }
            }
            Section {
                Button("Tentatives de connexion") { dismiss(); hub.open(.journal("login")) }
                Button(a.enabled.bool ? "Changer le mot de passe" : "Définir un mot de passe") { Task { await changePassword(a) } }
            } footer: { Text("Changer le mot de passe déconnecte aussi les autres appareils. Une notification arrive en cas de mot de passe incorrect.") }
        } else {
            Section("Sécurité") { LoadingRow() }
        }
    }

    private func session(_ x: J) async {
        guard await Dialog.confirm(uaName(x.ua.str), "\(x.who.str.isEmpty ? x.ip.str : x.who.str) · connecté le \(when(x.t.num))",
                                   x.current.bool ? "Me déconnecter" : "Déconnecter cet appareil", danger: true) else { return }
        do { try await API.shared.post("/api/auth/revoke", ["id": x.id]) } catch { hub.fail(error); return }
        if x.current.bool { dismiss(); Keychain.set(nil); hub.loggedIn = false; return }
        hub.toast("✅ Appareil déconnecté")
        auth = (try? await API.shared.get("/api/auth")) ?? auth
    }

    private func changePassword(_ a: J) async {
        var fields: [Dialog.Field] = []
        if a.enabled.bool { fields.append(.init(placeholder: "Mot de passe actuel", secure: true)) }
        fields += [.init(placeholder: "Nouveau mot de passe", secure: true), .init(placeholder: "Confirmer", secure: true)]
        guard let v = await Dialog.form("Changer le mot de passe", "Au moins 10 caractères. Les autres appareils seront déconnectés.", fields) else { return }
        let cur = a.enabled.bool ? v[0] : "", new = v[v.count - 2], again = v[v.count - 1]
        guard new == again else { hub.toast("❌ Les deux mots de passe ne correspondent pas"); return }
        do { try await API.shared.post("/api/auth/password", ["current": cur, "new": new]); hub.toast("✅ Mot de passe changé") }
        catch { hub.fail(error); return }
        auth = (try? await API.shared.get("/api/auth")) ?? auth
    }
}
