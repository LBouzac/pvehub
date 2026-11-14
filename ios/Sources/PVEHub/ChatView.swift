import SwiftUI

// MARK: - Modèle des conversations Hermes (gardées sur le serveur : les mêmes sur tous les appareils)
struct Approval {
    var command = ""
    var description = ""
    var choices: [String] = []
    var requestId = ""
    var answer: String?
}

struct Msg: Identifiable {
    let id = UUID()
    var role: String
    var content: String
    var sent: String?          // texte réellement envoyé (avec les notes de contexte)
    var tools: [String] = []
    var approvals: [Approval] = []
    var typing = false
    var runId: String?
    var done: [String: String] = [:]

    init(role: String, content: String, sent: String? = nil, typing: Bool = false) {
        self.role = role; self.content = content; self.sent = sent; self.typing = typing
    }
    init(_ j: J) {
        role = j.role.str
        content = j.content.str
        sent = j.sent.isNil ? nil : j.sent.str
        tools = j.tools.strs
        approvals = j.approvals.arr.map { a in
            Approval(command: a.command.str, description: a.description.str, choices: a.choices.strs, requestId: a.request_id.str, answer: a.answer.isNil ? nil : a.answer.str)
        }
        typing = j.typing.bool
        runId = j.runId.isNil ? nil : j.runId.str
        done = j.done.dict.mapValues { J($0).str }
    }
    /// « en cours » n'est enregistré que pour une réponse suivie par le serveur : elle pourra reprendre
    var json: [String: Any] {
        var d: [String: Any] = ["role": role, "content": content]
        if let sent { d["sent"] = sent }
        if !tools.isEmpty { d["tools"] = tools }
        if !approvals.isEmpty {
            d["approvals"] = approvals.map { a -> [String: Any] in
                var x: [String: Any] = ["command": a.command, "description": a.description, "choices": a.choices, "request_id": a.requestId]
                if let ans = a.answer { x["answer"] = ans }
                return x
            }
        }
        if let runId { d["runId"] = runId; if typing { d["typing"] = true } }
        if !done.isEmpty { d["done"] = done }
        return d
    }
}

struct Conv {
    var id: String?
    var title = ""
    var report: String?
    var messages: [Msg] = []
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var conv = Conv()
    @Published var chats: [J] = []
    @Published var busy = false
    @Published var prompt = ""
    private var pending: [String] = []
    private var following: [String: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?

    private var hub: Hub { Hub.shared }

    // MARK: liste et ouverture
    func loadChats() async {
        if let r = try? await API.shared.get("/api/chats") { chats = r.chats.arr }
    }
    func initChats() async {
        await loadChats()
        if let id = UserDefaults.standard.string(forKey: "chatId"), chats.contains(where: { $0.id == id }) { await openConv(id, quiet: true) }
    }
    func setConv(_ c: Conv) {
        stopFollowing()  // la réponse en cours continue côté serveur ; on s'y raccroche en revenant
        conv = c
        pending = []
        busy = false
        UserDefaults.standard.set(c.id, forKey: "chatId")
    }
    func openConv(_ id: String, quiet: Bool = false) async {
        do {
            let c = try await API.shared.get("/api/chats/get", ["id": id])
            setConv(Conv(id: c.id, title: c.title.str, report: c.report.isNil ? nil : c.report.str, messages: c.messages.arr.map { Msg($0) }))
            if !quiet { hub.tab = .chat; hub.chatPath = NavigationPath() }
            resumeRuns()
            await autoLxc()
        } catch { if !quiet { hub.fail(error) } }
    }
    func newConv() { setConv(Conv()) }
    func deleteConv(_ id: String) async {
        do { try await API.shared.post("/api/chats/delete", ["id": id]) } catch { hub.fail(error); return }
        chats.removeAll { $0.id == id }
        if conv.id == id { newConv() }
    }

    /// Nouvelle conversation avec la question prête (modifiable) ; le contexte part avec, sans encombrer le chat
    func ask(_ question: String, context: String?) {
        setConv(Conv(title: String(question.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(60))))
        if let context { addNote(context) }
        prompt = question
        hub.tab = .chat
        hub.chatPath = NavigationPath()
    }

    func addNote(_ text: String) {
        pending.append("[PVE Hub] " + text)
        conv.messages.append(Msg(role: "note", content: text))
    }

    func save() {
        guard !conv.messages.isEmpty else { return }
        if conv.id == nil {
            conv.id = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            UserDefaults.standard.set(conv.id, forKey: "chatId")
        }
        if conv.title.isEmpty, let u = conv.messages.first(where: { $0.role == "user" }) {
            conv.title = String(u.content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(60))
        }
        // liste à jour sans attendre le serveur
        let entry: [String: Any] = ["id": conv.id!, "title": conv.title, "updated": Date().timeIntervalSince1970, "count": conv.messages.count, "report": conv.report ?? ""]
        chats.removeAll { $0.id == conv.id }
        chats.insert(J(entry), at: 0)
        let body: [String: Any] = ["id": conv.id!, "title": conv.title, "report": orNull(conv.report), "messages": conv.messages.map(\.json)]
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            do { try await API.shared.post("/api/chats/save", body) } catch { Hub.shared.toast("❌ Conversation non enregistrée : " + error.localizedDescription) }
        }
    }

    // MARK: envoi et suivi des réponses
    func send(_ text0: String? = nil) async {
        let text = (text0 ?? prompt).trimmed
        guard !text.isEmpty, !busy else { return }
        if text0 == nil { prompt = "" }
        let content = (pending.isEmpty ? "" : pending.joined(separator: "\n") + "\n\n") + text
        pending = []
        conv.messages.append(Msg(role: "user", content: text, sent: content))
        save()  // la question est gardée même si l'app se ferme
        let history: [[String: Any]] = conv.messages.filter { ($0.role == "user" || $0.role == "assistant") && !($0.sent ?? $0.content).isEmpty }
            .map { ["role": $0.role, "content": $0.sent ?? $0.content] }
        conv.messages.append(Msg(role: "assistant", content: "", typing: true))
        let idx = conv.messages.count - 1
        busy = true
        do {
            let r = try await API.shared.post("/api/chat", ["messages": history, "conv": orNull(conv.id)])
            conv.messages[idx].runId = r.run_id.str
            save()  // le serveur suit la réponse : l'app peut se fermer
            follow(r.run_id.str)
        } catch {
            conv.messages[idx].content = "⚠️ " + error.localizedDescription
            conv.messages[idx].typing = false
            busy = false
            save()
        }
    }

    func stopFollowing() {
        for t in following.values { t.cancel() }
        following = [:]
    }
    /// Réponses encore en cours dans la conversation affichée (après réouverture de l'app ou d'une conversation)
    func resumeRuns() {
        for m in conv.messages where m.role == "assistant" && m.typing { if let r = m.runId { follow(r) } }
    }

    /// Abonnement à une réponse suivie par le serveur ; il rejoue tout depuis le début (reprise sans perte)
    func follow(_ runId: String) {
        guard following[runId] == nil, let i0 = conv.messages.firstIndex(where: { $0.runId == runId }) else { return }
        busy = true
        let answered = conv.messages[i0].approvals.map(\.answer)
        let convId = conv.id
        following[runId] = Task { [weak self] in
            guard let self else { return }
            var m = self.conv.messages[i0]
            m.content = ""; m.tools = []; m.approvals = []; m.typing = true
            var ended = false
            var lastPaint = Date.distantPast
            @MainActor func paint(_ force: Bool = false) {
                guard self.conv.id == convId, let i = self.conv.messages.firstIndex(where: { $0.runId == runId }) else { return }
                if force || Date().timeIntervalSince(lastPaint) > 0.08 { lastPaint = Date(); self.conv.messages[i] = m }
            }
            do {
                let (bytes, code) = try await API.shared.stream("/api/chat/stream", ["run": runId])
                if code == 404 {  // serveur redémarré : la réponse a peut-être été enregistrée avant
                    let saved = (try? await API.shared.get("/api/chats/get", ["id": convId ?? ""]))?.messages.arr.map { Msg($0) }.first { $0.runId == runId }
                    if let saved, !saved.typing { m = saved } else { m.content = "⚠️ Réponse interrompue (PVE Hub a redémarré). Repose ta question." }
                    ended = true
                } else if code != 200 {
                    throw APIError(message: code == 401 ? "Non connecté" : HTTPURLResponse.localizedString(forStatusCode: code))
                } else {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"), let d = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) else { continue }
                        let j = J(obj)
                        switch j.event.str {
                        case "message.delta": m.content += j.delta.str
                        case "tool.started": if !j.tool.str.isEmpty && !m.tools.contains(j.tool.str) { m.tools.append(j.tool.str) }
                        case "approval.request":
                            let ans = m.approvals.count < answered.count ? answered[m.approvals.count] : nil
                            m.approvals.append(Approval(command: j.command.str, description: j.description.str, choices: j.choices.strs, requestId: j.request_id.str, answer: ans))
                            paint(true)
                            if ans == nil { Hub.shared.toast("🛡️ Hermes demande une autorisation") }
                        case "approval.responded":
                            if let k = m.approvals.firstIndex(where: { $0.answer == nil }) { m.approvals[k].answer = j.choice.str }
                        case "run.completed": if !j.output.str.isEmpty { m.content = j.output.str }
                        case "run.failed", "run.interrupted": m.content += (m.content.isEmpty ? "" : "\n\n") + "⚠️ " + (j.error.str.isEmpty ? "Hermes a échoué" : j.error.str)
                        case "run.cancelled": m.content += (m.content.isEmpty ? "" : "\n\n") + "_(annulé)_"
                        case "pvehub.end": ended = true
                        default: break
                        }
                        paint()
                        if ended { break }
                    }
                }
            } catch {
                if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                    m.content += (m.content.isEmpty ? "" : "\n\n") + "⚠️ " + error.localizedDescription
                    ended = true
                }
            }
            if self.following[runId] != nil && !Task.isCancelled { self.following[runId] = nil }
            guard ended else { return }  // app passée en arrière-plan : le serveur continue, on se raccrochera au retour
            m.typing = false
            paint(true)
            guard self.conv.id == convId else { return }
            self.save()
            self.busy = false
            if let i = self.conv.messages.firstIndex(where: { $0.runId == runId }) {
                await self.autoRun(i)
                await self.autoLxc()
            }
        }
    }

    func answerApproval(msg: UUID, index: Int, choice: String) async {
        guard let i = conv.messages.firstIndex(where: { $0.id == msg }) else { return }
        let m = conv.messages[i]
        do {
            try await API.shared.post("/api/chat/approval", ["run_id": m.runId ?? "", "choice": choice, "request_id": m.approvals[index].requestId])
            if let k = conv.messages.firstIndex(where: { $0.id == msg }) { conv.messages[k].approvals[index].answer = choice }
            save()
        } catch { hub.fail(error) }
    }

    // MARK: actions proposées par Hermes (blocs ```pvehub)
    func runBlock(msg: UUID, code: String) async {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(code.utf8)) as? [String: Any] else { return }
        guard let res = await hub.runAction(obj) else { return }
        if let i = conv.messages.firstIndex(where: { $0.id == msg }) { conv.messages[i].done[code] = res }
        addNote("\(hub.describe(obj)) → \(res == "OK" ? "terminé" : res)")
        save()
    }
    /// Actions pré-autorisées (Autorisations) : exécutées dès que Hermes les propose
    private func autoRun(_ i: Int) async {
        let auto = UserDefaults.standard.dictionary(forKey: "auto") as? [String: Bool] ?? [:]
        let msgId = conv.messages[i].id
        for code in matches(ACTION_RE, conv.messages[i].content) {
            guard let a = try? JSONSerialization.jsonObject(with: Data(code.utf8)) as? [String: Any], let act = a["action"] as? String,
                  auto[act] == true, Hub.AUTO_OK.contains(where: { $0.0 == act }),
                  let k = conv.messages.firstIndex(where: { $0.id == msgId }), conv.messages[k].done[code] == nil else { continue }
            conv.messages[k].done[code] = "…"
            let res = await hub.runAction(a, skipConfirm: true) ?? "annulé"
            if let k2 = conv.messages.firstIndex(where: { $0.id == msgId }) { conv.messages[k2].done[code] = res }
            addNote("\(hub.describe(a)) → \(res == "OK" ? "fait automatiquement" : res)")
            save()
        }
    }

    // MARK: demandes « lxc-approve » : un bouton au lieu de copier-coller dans le Shell
    private struct Grant: Codable { let g: String; var conv: String?; let until: Date }
    private var grants: [Grant] {
        get { (UserDefaults.standard.data(forKey: "lxcGrants")).flatMap { try? JSONDecoder().decode([Grant].self, from: $0) }?.filter { $0.until > Date() } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "lxcGrants") }
    }
    private func allowed(_ g: String) -> Bool { grants.contains { $0.g == g && ($0.conv == nil || $0.conv == conv.id) } }

    func approveLxc(msg: UUID, grant g: String, auto: Bool = false, remember: String? = nil) async -> Bool {
        do { try await API.shared.post("/api/lxc/approve", ["grant": g]) } catch { hub.fail(error, seconds: 6); return false }
        if let i = conv.messages.firstIndex(where: { $0.id == msg }) { conv.messages[i].done["lxc:" + g] = auto ? "AUTO" : "OK" }
        addNote("Autorisation écrite sur l'hôte\(auto ? " (automatiquement)" : "") : \(g)")
        if let remember {  // « Pendant 1 h » / « Toute la conversation » : la même demande passe ensuite toute seule
            grants = grants.filter { $0.g != g } + [remember == "hour" ? Grant(g: g, until: Date().addingTimeInterval(3600))
                                                                      : Grant(g: g, conv: conv.id, until: Date().addingTimeInterval(86400))]
            hub.toast(remember == "hour" ? "Autorisé pendant 1 h" : "Autorisé pour cette conversation")
        }
        save()
        return true
    }
    func autoLxc() async {
        guard hub.exec, let m = conv.messages.last, !m.typing, m.role == "assistant", !m.content.isEmpty else { return }
        let todo = lxcGrants(m.content).filter { m.done["lxc:" + $0] == nil && allowed($0) }
        guard !todo.isEmpty else { return }
        for g in todo { guard await approveLxc(msg: m.id, grant: g, auto: true) else { return } }
        if !busy { await send("C'est autorisé, tu peux continuer.") }  // Hermes attend la suite
    }

    // MARK: rapport du matin
    func openReport(_ rep: J) {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let day = f.string(from: date(rep.ts.num))
        guard hub.hermes else { showText("Rapport du matin", rep.text.str); return }
        // chaque rapport a sa conversation : on peut répondre à Hermes juste en dessous
        if let known = chats.first(where: { $0.report.str == rep.id }) { Task { await openConv(known.id) }; return }
        if !busy {
            setConv(Conv(title: "Rapport du \(day)", report: rep.id, messages: [Msg(role: "assistant", content: "☀️ **Rapport du \(day)**\n\n\(rep.text.str)")]))
        }
        save()
        hub.tab = .chat
    }
    func openLatestReport() async {
        if let rep = (try? await API.shared.get("/api/reports"))?.reports.arr.first { openReport(rep) }
    }
    func reportNow() async {
        let r: J
        do { r = try await API.shared.post("/api/report/now") } catch { hub.fail(error); return }
        let t = hub.toast(hub.hermes ? "⏳ Hermes rédige le rapport…" : "⏳ Préparation du rapport…", seconds: 600)
        defer { hub.dismissToast(t) }
        for _ in 0..<100 {  // jusqu'à 5 min : Hermes peut prendre son temps
            try? await Task.sleep(for: .seconds(3))
            if let rep = (try? await API.shared.get("/api/reports"))?.reports.arr.first(where: { $0.ts.num >= r.started.num }) { openReport(rep); return }
        }
        hub.toast("Le rapport n'est pas arrivé : regarde le journal de PVE Hub.", seconds: 7)
    }
}

// MARK: - Écran Hermes
struct ChatView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var chat: ChatModel
    @State private var perms = false
    @FocusState private var focused: Bool

    private var hasReal: Bool { chat.conv.messages.contains { $0.role != "note" } }

    var body: some View {
        NavigationStack(path: $hub.chatPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !chat.conv.title.isEmpty && !chat.conv.messages.isEmpty {
                            Text(chat.conv.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if chat.conv.messages.isEmpty { empty }
                        ForEach(Array(chat.conv.messages.enumerated()), id: \.element.id) { i, m in
                            MessageView(m: m, last: i == chat.conv.messages.count - 1)
                        }
                        if hasReal {
                            Button("Nouvelle conversation") { chat.newConv() }
                                .font(.subheadline).buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 10)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.conv.messages.last?.content.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.conv.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.chats) { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Conversations")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { chat.newConv(); focused = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("Nouvelle conversation")
                    Button { perms = true } label: { Image(systemName: "checkmark.shield") }.accessibilityLabel("Autorisations")
                }
            }
            .navigationDestination(for: Route.self) { destination($0) }
            .sheet(isPresented: $perms) { PermsSheet() }
            .onChange(of: chat.prompt) { _, p in if !p.isEmpty && !focused { focused = true } }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("Demande à Hermes comment va ton serveur, ou ce qu'il ferait.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            ForEach(["Comment va mon serveur ?", "Quelle machine consomme le plus ?"], id: \.self) { ex in
                Button(ex) { Task { await chat.send(ex) } }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $chat.prompt, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button { Task { await chat.send() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .disabled(chat.busy || chat.prompt.trimmed.isEmpty)
            .accessibilityLabel("Envoyer")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Une bulle : texte (markdown simple), blocs de code, actions, choix, autorisations
struct MessageView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var chat: ChatModel
    let m: Msg
    let last: Bool

    var body: some View {
        switch m.role {
        case "note":
            Text(m.content).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
        case "user":
            Text(m.content)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
                .textSelection(.enabled)
        default:
            VStack(alignment: .leading, spacing: 8) {
                if !m.tools.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(m.tools, id: \.self) { Label($0, systemImage: "wrench.fill").font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Color(.tertiarySystemFill), in: Capsule()) } }
                    }
                }
                if m.content.isEmpty {
                    if m.typing { ProgressView().padding(.vertical, 4) } else { Text("(réponse vide)").foregroundStyle(.secondary) }
                } else {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in partView(p) }
                    ForEach(lxcGrants(m.content), id: \.self) { g in lxcCard(g) }
                }
                ForEach(m.approvals.indices, id: \.self) { i in approvalCard(i) }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.trailing, 24)
        }
    }

    private var parts: [(String?, String)] { splitMessage(m.content) }

    @ViewBuilder
    private func partView(_ p: (String?, String)) -> some View {
        let code = p.1.trimmed
        switch p.0 {
        case nil:
            Text(markdown(p.1)).textSelection(.enabled)
        case "choix"?:  // réponses proposées : des boutons, seulement sur le dernier message
            if last && !m.typing {
                let opts = code.split(separator: "\n").map { $0.replacingOccurrences(of: #"^(?:[-*]|\d+[.)])\s+"#, with: "", options: .regularExpression).trimmed }.filter { !$0.isEmpty }.prefix(6)
                FlowButtons(options: Array(opts)) { o in if !chat.busy { Task { await chat.send(o) } } }
            }
        case "pvehub"?:
            actionCard(code)
        default:
            codeBox(p.0 ?? "", code)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        var t = s.trimmingCharacters(in: .newlines)
        t = t.replacingOccurrences(of: #"(?m)^#{1,4} (.+)$"#, with: "**$1**", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^[-*] "#, with: "• ", options: .regularExpression)
        return (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
    }

    private func codeBox(_ lang: String, _ code: String) -> some View {
        let shell = ["bash", "sh", "shell", "console", "zsh", "terminal"].contains(lang)
        let text = shell ? code.replacingOccurrences(of: #"(?m)^\$ "#, with: "", options: .regularExpression) : code
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copier") { copyText(text) }.font(.caption)
                if shell && hub.exec { Button("Commandes") { hub.runInExec(command: text) }.font(.caption) }  // préremplie, rien n'est lancé sans toi
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView(.horizontal) {
                Text(text).font(.caption.monospaced()).textSelection(.enabled).padding(10)
            }
        }
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func actionCard(_ code: String) -> some View {
        if let a = try? JSONSerialization.jsonObject(with: Data(code.utf8)) as? [String: Any] {
            Card(symbol: "bolt.fill", title: hub.describe(a)) {
                if let done = m.done[code] {
                    Text(done == "OK" ? "✓ Fait" : "✕ " + done).font(.subheadline).foregroundStyle(done == "OK" ? Color.green : Color.red)
                } else if !m.typing {
                    Button("Exécuter") { Task { await chat.runBlock(msg: m.id, code: code) } }.buttonStyle(.borderedProminent)
                }
            }
        } else if m.typing {
            Text("Action en préparation…").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func lxcCard(_ g: String) -> some View {
        let words = g.split(separator: " ").map(String.init)
        let cmd = g.components(separatedBy: " -- ").dropFirst().first
        let done = m.done["lxc:" + g]
        return Card(symbol: "checkmark.shield.fill", title: "Autoriser \(words.first ?? "") dans la machine \(words.count > 1 ? words[1] : "")") {
            if let cmd { Text("Commande : ").font(.subheadline) + Text(cmd).font(.subheadline.monospaced()) }
            if let done {
                Text(done == "OK" ? "✓ Autorisé" : done == "AUTO" ? "✓ Autorisé automatiquement" : "✕ " + done)
                    .font(.subheadline).foregroundStyle(done == "OK" || done == "AUTO" ? Color.green : Color.red)
            } else if !m.typing {
                if hub.exec {
                    FlowButtons(options: ["Autoriser", "Pendant 1 h", "Toute la conversation"], primary: "Autoriser") { o in
                        Task { _ = await chat.approveLxc(msg: m.id, grant: g, remember: o == "Pendant 1 h" ? "hour" : o == "Toute la conversation" ? "conv" : nil) }
                    }
                } else {
                    Text("Active la section Commandes pour autoriser d'ici.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let CHOICE = ["once": "Autoriser", "session": "Pour la session", "always": "Toujours", "deny": "Refuser"]
    private func approvalCard(_ i: Int) -> some View {
        let ap = m.approvals[i]
        return Card(symbol: "checkmark.shield.fill", title: "Hermes demande l'autorisation") {
            if !ap.description.isEmpty { Text(ap.description).font(.subheadline) }
            if !ap.command.isEmpty { Text(ap.command).font(.caption.monospaced()).textSelection(.enabled) }
            if let ans = ap.answer {
                Text(ans == "deny" ? "✕ Refusé" : "✓ " + (Self.CHOICE[ans] ?? ans)).font(.subheadline).foregroundStyle(ans == "deny" ? Color.red : Color.green)
            } else if m.typing {
                let choices = ap.choices.isEmpty ? ["once", "deny"] : ap.choices
                FlowButtons(options: choices.map { Self.CHOICE[$0] ?? $0 }, primary: "Autoriser") { label in
                    let c = choices.first { (Self.CHOICE[$0] ?? $0) == label } ?? label
                    Task { await chat.answerApproval(msg: m.id, index: i, choice: c) }
                }
            } else {
                Text("Demande expirée").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct Card<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).symbolRenderingMode(.multicolor)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Boutons qui passent à la ligne
struct FlowButtons: View {
    let options: [String]
    var primary: String? = nil
    let action: (String) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
    }
    @ViewBuilder private var buttons: some View {
        ForEach(options, id: \.self) { o in
            if o == primary { Button(o) { action(o) }.buttonStyle(.borderedProminent) }
            else { Button(o) { action(o) }.buttonStyle(.bordered) }
        }
    }
}

// MARK: - Conversations
struct ChatsView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var chat: ChatModel
    @State private var q = ""

    private var days: [(String, [J])] {
        var out: [(String, [J])] = []
        for c in chat.chats where q.isEmpty || c.title.str.lowercased().contains(q.lowercased()) {
            let d = dayLabel(c.updated.num)
            if out.last?.0 == d { out[out.count - 1].1.append(c) } else { out.append((d, [c])) }
        }
        return out
    }

    var body: some View {
        List {
            Button { chat.newConv(); hub.chatPath = NavigationPath() } label: { LinkRow(symbol: "square.and.pencil", color: .accentColor, title: "Nouvelle conversation") }
            if days.isEmpty { Text(q.isEmpty ? "Aucune conversation pour l'instant." : "Aucun résultat.").foregroundStyle(.secondary) }
            ForEach(days, id: \.0) { day in
                Section(day.0) {
                    ForEach(day.1) { c in
                        Button { Task { await chat.openConv(c.id) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((c.report.str.isEmpty ? "" : "☀️ ") + (c.title.str.isEmpty ? "Conversation" : c.title.str)).lineLimit(1)
                                Text("\(plural(c.count.int, "message")) · \(hm(c.updated.num))\(c.id == chat.conv.id ? " · en cours" : "")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Supprimer", role: .destructive) {
                                Task {
                                    if await Dialog.confirm("Supprimer la conversation ?", c.title.str, "Supprimer", danger: true) { await chat.deleteConv(c.id) }
                                }
                            }
                        }
                    }
                }
            }
            Section { } footer: { Text("Les conversations sont gardées sur le serveur : tu les retrouves sur tous tes appareils. Les 100 plus récentes sont conservées.") }
        }
        .navigationTitle("Conversations")
        .searchable(text: $q, prompt: "Rechercher")
        .task { await chat.loadChats() }
        .refreshable { await chat.loadChats() }
    }
}

// MARK: - Autorisations de Hermes
struct PermsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var auto: [String: Bool] = UserDefaults.standard.dictionary(forKey: "auto") as? [String: Bool] ?? [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Hub.AUTO_OK, id: \.0) { k, l in
                        Toggle(l, isOn: Binding(get: { auto[k] ?? false }, set: { auto[k] = $0; UserDefaults.standard.set(auto, forKey: "auto") }))
                    }
                } header: { Text("Hermes peut, sans demander") } footer: {
                    Text("Quand Hermes propose une de ces actions, elle s'exécute tout de suite. Forcer l'arrêt, restaurer et supprimer demandent toujours ta confirmation.")
                }
                Section {
                    LinkRow(symbol: "checkmark.shield.fill", color: .orange, title: "Validation dans la conversation",
                            subtitle: "Quand Hermes veut lancer une commande sensible sur sa machine, une demande apparaît : Autoriser, Pour la session, Toujours ou Refuser.")
                } header: { Text("Ses propres commandes") } footer: {
                    Text("« Toujours » est retenu par Hermes lui-même ; pour l'annuler, modifie sa configuration.")
                }
            }
            .navigationTitle("Autorisations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}
