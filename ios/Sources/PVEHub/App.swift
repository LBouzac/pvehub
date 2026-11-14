import SwiftUI
import UserNotifications

/// Notifications natives : jeton APNs envoyé au serveur, bannière même app ouverte, toucher = ouvrir l'écran lié
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data) {
        let token = t.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await Hub.shared.sendPushToken(token) }
    }
    func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError e: Error) {
        print("APNs :", e.localizedDescription)  // build xtool sans droit push, ou pas de réseau
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        // même lien que la version web : « /#maint », « /#g=lxc/101 »…
        let url = r.notification.request.content.userInfo["url"] as? String ?? ""
        await MainActor.run { Hub.shared.openLink(String(url.drop { $0 == "/" || $0 == "#" })) }
    }
}

@main
struct PVEHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var hub = Hub.shared
    @AppStorage("mode") private var mode = "auto"
    @AppStorage("accent") private var accent = "blue"

    var body: some Scene {
        WindowGroup {
            Root()
                .environmentObject(hub)
                .environmentObject(hub.chat)
                .tint(accentTint(accent))
                .preferredColorScheme(mode == "light" ? .light : mode == "dark" ? .dark : nil)
        }
    }
}

let ACCENTS: [(String, String)] = [("blue", "Bleu"), ("indigo", "Indigo"), ("purple", "Violet"), ("pink", "Rose"), ("red", "Rouge"),
                                   ("orange", "Orange"), ("green", "Vert"), ("teal", "Turquoise"), ("mono", "Noir et blanc")]
func accentTint(_ k: String) -> Color {
    switch k {
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "orange": return .orange
    case "green": return .green
    case "teal": return .teal
    case "mono": return .primary
    default: return .blue
    }
}

struct Root: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var chat: ChatModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if hub.starting && hub.ov == nil {
                ProgressView()
            } else if hub.loggedIn {
                MainTabs()
            } else {
                LoginView()
            }
        }
        .onAppear { ToastWindow.install(hub) }
        .task { await hub.start() }
        // rafraîchissement toutes les 5 s, en pause quand l'app est en arrière-plan
        .task(id: phase == .active && hub.loggedIn) {
            guard phase == .active, hub.loggedIn else { return }
            while !Task.isCancelled {
                await hub.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: phase == .active && hub.loggedIn) {  // maintenance toutes les 5 min, version toutes les heures
            guard phase == .active, hub.loggedIn else { return }
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { break }
                await hub.loadMaint()
                n += 1
                if n % 12 == 0 { await hub.checkVersion() }
            }
        }
        .onChange(of: phase) { _, p in
            // en arrière-plan, le serveur continue la réponse de Hermes et notifie ; on s'y raccroche au retour
            if p == .background { chat.stopFollowing() } else if p == .active { chat.resumeRuns() }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var hub: Hub
    var body: some View {
        TabView(selection: $hub.tab) {
            ServerView().tabItem { Label("Serveur", systemImage: "server.rack") }.tag(Tab.server)
            GuestsView().tabItem { Label("Machines", systemImage: "shippingbox") }.tag(Tab.guests)
            AppsView().tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }.tag(Tab.apps)
            ExecView().tabItem { Label("Commandes", systemImage: "apple.terminal") }.tag(Tab.exec)
            if hub.hermes {
                ChatView().tabItem { Label("Hermes", systemImage: "bubble.left.fill") }.tag(Tab.chat)
            }
        }
        .sheet(isPresented: $hub.showSettings) { SettingsView() }
        .sheet(item: $hub.textSheet) { TextSheetView(sheet: $0) }
    }
}

/// Boutons communs à droite de la barre : « en direct » et réglages
struct HubToolbar: ViewModifier {
    @EnvironmentObject var hub: Hub
    var live = true
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if live {
                    HStack(spacing: 5) {
                        Circle().fill(hub.online ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(hub.online ? "en direct" : "hors ligne").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button { hub.showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) {
                            if hub.ver?.available.bool == true { Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: 3, y: -3) }
                        }
                }
                .accessibilityLabel("Réglages")
            }
        }
    }
}
extension View {
    func hubToolbar(live: Bool = true) -> some View { modifier(HubToolbar(live: live)) }
}

struct LoginView: View {
    @EnvironmentObject var hub: Hub
    @State private var server = API.shared.server
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "server.rack").font(.system(size: 44)).foregroundStyle(.tint)
                        Text("PVE Hub").font(.largeTitle.bold())
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("http://192.168.1.20:8080", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.URL)
                    SecureField("Mot de passe", text: $password).textContentType(.password)
                } header: {
                    Text("Ton serveur PVE Hub")
                } footer: {
                    Text(error.isEmpty ? "L'adresse affichée à la fin de l'installation, ou ton adresse Tailscale en https." : error)
                        .foregroundStyle(error.isEmpty ? Color.secondary : Color.red)
                }
                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Se connecter").bold() }; Spacer() }
                    }
                    .disabled(busy || server.trimmed.isEmpty)
                }
            }
        }
    }

    private func login() async {
        busy = true
        defer { busy = false }
        error = ""
        var s = withScheme(server.trimmed)
        while s.hasSuffix("/") { s.removeLast() }
        API.shared.server = s
        server = s
        do {
            try await API.shared.post("/api/login", ["password": password])
            password = ""
            hub.ov = try await API.shared.get("/api/overview")
            hub.online = true
            hub.loggedIn = true
            await hub.afterLogin()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
