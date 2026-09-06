import SwiftUI
import WebKit
import LocalAuthentication

// MARK: - App Configuration

enum AppConfig {
    /// Primary destination loaded into the WebView.
    static let dashboardURLString = "https://scssoftware.in/public/admin/dashboard"
    /// Navigation outside this domain (and its subdomains) is handed off to the system browser / app.
    static let allowedDomain = "scssoftware.in"
}

// MARK: - App Lock Manager

/// Mirrors the Android AppLockManager's behavior: lock is enabled by default,
/// re-locks whenever the app leaves the foreground, and unlocks via Face ID / Touch ID
/// (falling back to the device passcode automatically, the same way Android falls back to PIN).
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var isAuthenticating: Bool = false
    @Published var authError: String?

    private let lockEnabledKey = "com.scssoftware.app.lockEnabled"

    var isLockEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: lockEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: lockEnabledKey) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: lockEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: lockEnabledKey)
        }
    }

    /// Called when the scene goes to background — re-arms the lock screen.
    func lock() {
        guard isLockEnabled else { return }
        isUnlocked = false
        authError = nil
    }

    /// Called on launch and whenever the scene becomes active.
    func authenticate() {
        guard isLockEnabled else {
            isUnlocked = true
            return
        }
        guard !isUnlocked, !isAuthenticating else { return }

        isAuthenticating = true
        authError = nil

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var evalError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication // Face ID / Touch ID, falls back to device passcode

        guard context.canEvaluatePolicy(policy, error: &evalError) else {
            DispatchQueue.main.async {
                self.isAuthenticating = false
                self.authError = evalError?.localizedDescription
                    ?? "Biometric authentication is not available on this device."
            }
            return
        }

        let reason = "Authenticate to access your Admin Dashboard."
        context.evaluatePolicy(policy, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.isUnlocked = true
                } else {
                    self.isUnlocked = false
                    if let laError = error as? LAError, laError.code == .userCancel {
                        self.authError = nil
                    } else {
                        self.authError = error?.localizedDescription ?? "Authentication failed."
                    }
                }
            }
        }
    }
}

// MARK: - Alternate Icon Theme Manager

/// Legitimate iOS alternate-icon support: lets the user pick a cosmetic theme
/// for the app's own icon. This does NOT rename or re-badge the app as an
/// unrelated utility — every option is presented and labeled as this app.
final class IconThemeManager {
    static let shared = IconThemeManager()

    enum Theme: String, CaseIterable, Identifiable {
        case classic = "AppIcon"
        case midnight = "AppIcon-Midnight"
        case ocean = "AppIcon-Ocean"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .classic: return "Classic"
            case .midnight: return "Midnight"
            case .ocean: return "Ocean"
            }
        }

        /// nil tells UIKit to use the primary icon.
        var alternateIconName: String? {
            self == .classic ? nil : rawValue
        }
    }

    var currentTheme: Theme {
        let current = UIApplication.shared.alternateIconName
        return Theme.allCases.first { $0.alternateIconName == current } ?? .classic
    }

    func setTheme(_ theme: Theme, completion: ((Bool) -> Void)? = nil) {
        guard UIApplication.shared.supportsAlternateIcons else {
            completion?(false)
            return
        }
        guard UIApplication.shared.alternateIconName != theme.alternateIconName else {
            completion?(true)
            return
        }
        UIApplication.shared.setAlternateIconName(theme.alternateIconName) { error in
            if let error {
                print("Failed to set alternate icon: \(error.localizedDescription)")
            }
            completion?(error == nil)
        }
    }
}

// MARK: - WKWebView Wrapper

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Persistent cookies + localStorage/DOM storage across launches (equivalent to
        // Android's CookieManager.setAcceptCookie(true) + WebSettings.setDomStorageEnabled(true)).
        configuration.websiteDataStore = .default()

        // Appended to the default UA, mirroring `settings.getUserAgentString() + " SCSApp/1.0"`.
        configuration.applicationNameForUserAgent = "SCSApp/1.0"

        // Inline media playback, autoplay allowed (parity with default Android WebView media behavior).
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePreferences

        // NOTE on file uploads: WKWebView on iOS natively presents the system
        // photo/camera/file picker for <input type="file"> without any extra
        // delegate code, as long as NSCameraUsageDescription /
        // NSPhotoLibraryUsageDescription are present in Info.plist.

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: WebView

        init(_ parent: WebView) {
            self.parent = parent
        }

        // Equivalent to Android's shouldOverrideUrlLoading: tel/mailto and
        // WhatsApp links go to the system; only the allowed domain (and its
        // subdomains) loads inside the WebView, everything else is handed
        // off externally.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = requestURL.scheme?.lowercased() ?? ""
            let host = requestURL.host?.lowercased() ?? ""

            if scheme == "tel" || scheme == "mailto" {
                openExternally(requestURL)
                decisionHandler(.cancel)
                return
            }

            if host.contains("wa.me") || host.contains("whatsapp") {
                openExternally(requestURL)
                decisionHandler(.cancel)
                return
            }

            if scheme == "http" || scheme == "https" {
                let allowed = AppConfig.allowedDomain
                if host == allowed || host.hasSuffix(".\(allowed)") {
                    decisionHandler(.allow)
                } else {
                    openExternally(requestURL)
                    decisionHandler(.cancel)
                }
                return
            }

            openExternally(requestURL)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.loadFailed = false
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        private func handleFailure(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadFailed = true
            }
        }

        private func openExternally(_ url: URL) {
            guard UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var lockManager = AppLockManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var reloadToken = UUID()
    @State private var showingSettings = false

    private var dashboardURL: URL {
        URL(string: AppConfig.dashboardURLString)!
    }

    var body: some View {
        ZStack {
            WebView(url: dashboardURL, isLoading: $isLoading, loadFailed: $loadFailed)
                .id(reloadToken)
                .ignoresSafeArea()
                .opacity(lockManager.isUnlocked ? 1 : 0)

            if lockManager.isUnlocked {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .padding(10)
                                .background(.thinMaterial, in: Circle())
                        }
                        .padding()
                    }
                    Spacer()
                }
            }

            if isLoading && lockManager.isUnlocked {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
            }

            if loadFailed && lockManager.isUnlocked {
                offlineOverlay
            }

            if !lockManager.isUnlocked {
                lockOverlay
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            lockManager.authenticate()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                lockManager.authenticate()
            case .background:
                lockManager.lock()
            default:
                break
            }
        }
    }

    private var offlineOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("You're Offline")
                .font(.headline)
            Text("Check your internet connection and try again.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                loadFailed = false
                isLoading = true
                reloadToken = UUID()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }

    private var lockOverlay: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("SCS Admin")
                .font(.title2.bold())

            if lockManager.isAuthenticating {
                ProgressView("Authenticating…")
            } else {
                Button {
                    lockManager.authenticate()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }

            if let error = lockManager.authError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - Settings (App Lock toggle + Icon Theme picker)

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lockManager = AppLockManager.shared
    @State private var lockEnabled: Bool
    @State private var selectedTheme: IconThemeManager.Theme

    init() {
        _lockEnabled = State(initialValue: AppLockManager.shared.isLockEnabled)
        _selectedTheme = State(initialValue: IconThemeManager.shared.currentTheme)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Security") {
                    Toggle("Require Face ID / Touch ID", isOn: $lockEnabled)
                        .onChange(of: lockEnabled) { newValue in
                            lockManager.isLockEnabled = newValue
                        }
                }

                Section("App Icon") {
                    Picker("Theme", selection: $selectedTheme) {
                        ForEach(IconThemeManager.Theme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: selectedTheme) { newValue in
                        IconThemeManager.shared.setTheme(newValue)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}