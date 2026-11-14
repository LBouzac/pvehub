import SwiftUI
import UIKit
import Security

// MARK: - Session (trousseau)
enum Keychain {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "pvehub-session"]
    static func get() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ v: String?) {
        SecItemDelete(base as CFDictionary)
        guard let v, !v.isEmpty else { return }
        var a = base
        a[kSecValueData as String] = Data(v.utf8)
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(a as CFDictionary, nil)
    }
}

// MARK: - API
struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class API {
    static let shared = API()
    @MainActor var onUnauthorized: () -> Void = {}

    var server: String {
        get { UserDefaults.standard.string(forKey: "server") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "server") }
    }
    var base: URL? { URL(string: server) }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false   // cookie de session géré à la main, rangé dans le trousseau
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 90 // une commande peut durer 60 s
        return URLSession(configuration: c)
    }()
    // le Journal et la liste des appareils lisent l'appareil dans le User-Agent (iPhone, iPad…)
    private let userAgent = "PVEHub-iOS (\(UIDevice.current.model); iOS \(UIDevice.current.systemVersion))"

    func makeRequest(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        guard let base, base.scheme?.hasPrefix("http") == true,
              var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw APIError(message: "Adresse du serveur invalide") }
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw APIError(message: "Adresse invalide") }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token = Keychain.get() { req.setValue("pvehub=\(token)", forHTTPHeaderField: "Cookie") }
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    func request(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> J {
        let req = try makeRequest(path, query: query, body: body)
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let j = J(try? JSONSerialization.jsonObject(with: data))
        if code == 401 {
            await MainActor.run { onUnauthorized() }
            throw APIError(message: "Non connecté")
        }
        guard (200..<300).contains(code) else {
            throw APIError(message: j.error.str.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: code) : j.error.str)
        }
        if let http, let url = http.url, let fields = http.allHeaderFields as? [String: String],
           let c = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first(where: { $0.name == "pvehub" }) {
            Keychain.set(c.value)  // connexion, ou première session après « Définir un mot de passe »
        }
        return j
    }

    func get(_ path: String, _ q: [String: String] = [:]) async throws -> J { try await request(path, query: q) }
    @discardableResult
    func post(_ path: String, _ body: [String: Any] = [:]) async throws -> J { try await request(path, body: body) }

    /// Flux SSE de Hermes : un événement JSON par ligne « data: ».
    func stream(_ path: String, _ q: [String: String]) async throws -> (URLSession.AsyncBytes, Int) {
        let (bytes, resp) = try await session.bytes(for: try makeRequest(path, query: q))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { await MainActor.run { onUnauthorized() } }
        return (bytes, code)
    }
}

// MARK: - Boîtes de dialogue (équivalents de actionSheet / confirmBox / alertForm de la version web)
@MainActor
enum Dialog {
    private static var top: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }

    private static func present(_ a: UIAlertController) -> Bool {
        guard let top else { return false }
        if let p = a.popoverPresentationController {  // iPad : feuille d'actions centrée
            p.sourceView = top.view
            p.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            p.permittedArrowDirections = []
        }
        top.present(a, animated: true)
        return true
    }

    /// Feuille d'actions : index du bouton choisi, ou -1.
    static func actions(_ title: String?, _ message: String? = nil, _ buttons: [(String, Bool)]) async -> Int {
        await withCheckedContinuation { c in
            let a = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
            for (i, b) in buttons.enumerated() {
                a.addAction(UIAlertAction(title: b.0, style: b.1 ? .destructive : .default) { _ in c.resume(returning: i) })
            }
            a.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in c.resume(returning: -1) })
            if !present(a) { c.resume(returning: -1) }
        }
    }

    static func confirm(_ title: String, _ message: String? = nil, _ label: String = "Confirmer", danger: Bool = false) async -> Bool {
        await actions(title, message, [(label, danger)]) == 0
    }

    struct Field {
        var placeholder: String
        var value: String = ""
        var secure = false
        var keyboard: UIKeyboardType = .default
    }

    /// Petit formulaire : les valeurs saisies, ou nil si annulé.
    static func form(_ title: String, _ message: String? = nil, _ fields: [Field], ok: String = "OK") async -> [String]? {
        await withCheckedContinuation { c in
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for f in fields {
                a.addTextField { t in
                    t.placeholder = f.placeholder
                    t.text = f.value
                    t.isSecureTextEntry = f.secure
                    t.keyboardType = f.keyboard
                    t.autocapitalizationType = .none
                    t.autocorrectionType = .no
                    t.clearButtonMode = .whileEditing
                }
            }
            a.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in c.resume(returning: nil) })
            a.addAction(UIAlertAction(title: ok, style: .default) { [weak a] _ in
                c.resume(returning: a?.textFields?.map { $0.text ?? "" } ?? [])
            })
            if !present(a) { c.resume(returning: nil) }
        }
    }
}

// MARK: - Toasts (fenêtre au-dessus de tout, feuilles comprises)
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor
enum ToastWindow {
    private static var window: UIWindow?
    static func install(_ hub: Hub) {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ToastStack().environmentObject(hub))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.windowLevel = .alert + 1
        w.isUserInteractionEnabled = false
        w.isHidden = false
        window = w
    }
}

struct ToastStack: View {
    @EnvironmentObject var hub: Hub
    var body: some View {
        VStack(spacing: 8) {
            ForEach(hub.toasts) { t in
                Text(t.text)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.3), value: hub.toasts)
    }
}

@MainActor
func copyText(_ t: String) {
    UIPasteboard.general.string = t
    Hub.shared.toast("📋 Copié")
}

// MARK: - Petits composants
struct IconBox: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 29
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct UsageBar: View {
    let value: Double
    var body: some View {
        ProgressView(value: min(max(value, 0), 100), total: 100)
            .tint(value > 90 ? .red : value > 75 ? .orange : .accentColor)
    }
}

struct StatusDot: View {
    let status: String
    var body: some View {
        Circle().fill(status == "running" || status == "online" ? Color.green : status == "paused" ? .orange : Color.secondary.opacity(0.5))
            .frame(width: 9, height: 9)
    }
}

/// Ligne « titre … valeur » avec une barre de progression dessous
struct MeterRow: View {
    let title: String
    let detail: String
    let value: Double
    var symbol: String? = nil
    var color: Color = .accentColor
    var body: some View {
        HStack(spacing: 12) {
            if let symbol { IconBox(symbol: symbol, color: color) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(detail).foregroundStyle(.secondary).font(.subheadline)
                }
                UsageBar(value: value)
            }
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = Color(.tertiarySystemFill)
    var fg: Color = .secondary
    var body: some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color, in: Capsule()).foregroundStyle(fg)
    }
}

struct LoadingRow: View {
    var text = "Chargement…"
    var body: some View { Text(text).foregroundStyle(.secondary) }
}
