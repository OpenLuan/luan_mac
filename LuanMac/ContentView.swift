import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject private var runner = LuaRunner.shared
    @StateObject private var settings = AppSettings()
    @EnvironmentObject private var nativeChromeMCP: NativeChromeMCP
    @AppStorage("documentRoot") private var documentRoot: String = "~/.luan_ws"
    @AppStorage("autoStart") private var autoStart: Bool = false
    @Binding var uiLanguage: String
    @State private var showSettings = false
    @State private var didAutoStart = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("native.action.settings"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()
            mainContent
            Spacer()

            quickActions
                .padding(.bottom, 20)
        }
        .frame(minWidth: 360, idealWidth: 380, minHeight: 400, idealHeight: 440)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if documentRoot.isEmpty { documentRoot = "~/.luan_ws" }
            settings.load(documentRoot: expandedRoot)
            applyNativeChromeMCP()
            nativeChromeMCP.terminateChromeOnQuit = settings.terminateChromeOnQuit
            if autoStart && !didAutoStart && runner.canStart {
                didAutoStart = true
                startService()
            }
        }
        .onChange(of: documentRoot) { _, _ in
            settings.load(documentRoot: expandedRoot)
            applyNativeChromeMCP()
            nativeChromeMCP.terminateChromeOnQuit = settings.terminateChromeOnQuit
        }
        .onChange(of: settings.nativeChromeMCPEnabled) { _, _ in
            applyNativeChromeMCP()
            settings.save()
        }
        .onChange(of: settings.nativeChromeMCPPort) { _, _ in
            applyNativeChromeMCP()
            settings.save()
        }
        .onChange(of: settings.terminateChromeOnQuit) { _, newValue in
            nativeChromeMCP.terminateChromeOnQuit = newValue
            settings.save()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: settings, documentRoot: $documentRoot,
                         autoStart: $autoStart, uiLanguage: $uiLanguage,
                         canEdit: runner.canStart, L: L)
        }
    }

    private var expandedRoot: String {
        (documentRoot as NSString).expandingTildeInPath
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 20) {
            statusIndicator

            if runner.isRunning {
                Button { openInBrowser() } label: {
                    let h = runner.boundHost.isEmpty ? settings.host : runner.boundHost
                    let p = runner.boundPort > 0 ? runner.boundPort : settings.port
                    Text(verbatim: "http://\(h):\(p)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("native.action.openBrowser"))
            }

            if runner.isRunning {
                metricsRow
            }

            actionButton
                .padding(.top, 8)

            if case .failed(let msg) = runner.state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Circle()
                    .fill(statusColor)
                    .frame(width: 24, height: 24)
                    .shadow(color: statusColor.opacity(0.5), radius: runner.isRunning ? 8 : 0)
            }

            Text(statusTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch runner.state {
        case .idle: return .secondary
        case .starting, .stopping: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }

    private var statusTitle: String {
        switch runner.state {
        case .idle: return L("native.status.idle")
        case .starting: return L("native.status.starting")
        case .running: return L("native.status.running")
        case .stopping: return L("native.status.stopping")
        case .failed: return L("native.status.failed")
        }
    }

    // MARK: - Metrics

    private var metricsRow: some View {
        HStack(spacing: 16) {
            metricPill("CPU", value: runner.cpuNow.map { String(format: "%.0f%%", $0) })
            metricPill("Mem", value: runner.rssNowMB.map { formatMB($0) })
            metricPill("Lua", value: runner.luaNowMB.map { formatMB($0) })
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func metricPill(_ label: String, value: String?) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .tertiary : .secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func formatMB(_ v: Double) -> String {
        if v >= 1024 { return String(format: "%.1fG", v / 1024) }
        if v >= 100  { return String(format: "%.0fM", v) }
        return String(format: "%.1fM", v)
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button {
            if isStopState {
                runner.stop()
            } else {
                startService()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isStopState ? "stop.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(isStopState ? L("native.action.stop") : L("native.action.start"))
                    .font(.system(size: 16, weight: .semibold))
                if isStopState && runner.refCount > 1 {
                    Text("(\(runner.refCount - 1))")
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
            }
            .frame(minWidth: 160, minHeight: 42, maxHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(isStopState ? .red : .green)
        .controlSize(.large)
        .disabled(runner.state == .stopping)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private var isStopState: Bool {
        runner.isRunning || runner.state == .starting
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 16) {
            Button { openInBrowser() } label: {
                Label(L("native.action.openBrowser"), systemImage: "safari")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!runner.isRunning)

            Button {
                let path = runner.logPath.isEmpty ? (expandedRoot + "/luan.log") : runner.logPath
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Label(L("native.action.viewLog"), systemImage: "doc.text")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(runner.logPath.isEmpty && documentRoot.isEmpty)
        }
    }

    // MARK: - Helpers

    private var baseURL: String {
        let h = runner.boundHost.isEmpty ? settings.host : runner.boundHost
        let p = runner.boundPort > 0 ? runner.boundPort : settings.port
        return "http://\(h):\(p)"
    }

    private func startService() {
        settings.ensureSecretsAndSave()
        runner.start(documentRoot: expandedRoot, env: settings.envDict(uiLanguage: uiLanguage))
    }

    /// Keep the native Chrome MCP listener in sync with settings. The
    /// ephemeral token is generated here (in-memory) and handed both to the
    /// listener and to the Lua service via env.
    private func applyNativeChromeMCP() {
        if settings.nativeChromeMCPEnabled {
            settings.ensureNativeChromeMCPToken()
            nativeChromeMCP.start(port: settings.nativeChromeMCPPort, token: settings.nativeChromeMCPToken)
        } else {
            nativeChromeMCP.stop()
        }
    }

    private func openInBrowser() {
        let base = baseURL
        Task {
            let hasUsers = await checkHasUsers(base: base)
            let urlStr: String
            if hasUsers {
                urlStr = "\(base)/_admin/"
            } else {
                let key = settings.activationKey
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                urlStr = "\(base)/_login.html?register=1&activation_key=\(key)&redirect=/_admin/"
            }
            // When the native Chrome MCP is running, open through Chrome CDP
            // (dedicated app-managed Chrome). Fall back to the system browser
            // if Chrome is unavailable.
            var opened = false
            if nativeChromeMCP.isRunning {
                opened = await nativeChromeMCP.open(urlString: urlStr)
            }
            if !opened {
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func checkHasUsers(base: String) async -> Bool {
        guard let url = URL(string: "\(base)/_api/auth/status") else { return true }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hasUsers = json["has_users"] as? Bool {
                return hasUsers
            }
        } catch {}
        return true
    }

    // MARK: - Localization

    private func L(_ key: String) -> String {
        guard uiLanguage != "system" else {
            return String(localized: String.LocalizationValue(key))
        }
        if let path = Bundle.main.path(forResource: uiLanguage, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return String(localized: String.LocalizationValue(key), bundle: bundle)
        }
        return String(localized: String.LocalizationValue(key))
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var runner = LuaRunner.shared
    @Binding var documentRoot: String
    @Binding var autoStart: Bool
    @Binding var uiLanguage: String
    let canEdit: Bool
    let L: (String) -> String
    @Environment(\.dismiss) private var dismiss
    @State private var revealSecrets = false
    @State private var copiedLabel: String?
    @State private var rootUsername: String = ""
    @State private var showResetPassword = false
    @State private var newPassword: String = ""
    @State private var resetStatus: String = ""
    @State private var isResetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("native.action.settings"))
                    .font(.headline)
                Spacer()
                Button(L("native.action.done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    generalSection
                    networkSection
                    chromeMCPSection
                    advancedSection
                    secretsSection
                }
                .padding(16)
            }
        }
        .frame(width: 440, height: 520)
    }

    // MARK: General

    private var generalSection: some View {
        settingsGroup(L("native.section.general")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("native.section.workspace"))
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("~/.luan_ws", text: $documentRoot)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEdit)
                }

                Toggle(L("native.settings.autoStart"), isOn: $autoStart)

                HStack(spacing: 8) {
                    Text(L("native.settings.uiLanguage"))
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $uiLanguage) {
                        Text(L("native.settings.uiLanguage.system")).tag("system")
                        Text("English").tag("en")
                        Text("简体中文").tag("zh-Hans")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    // MARK: Network

    private var networkSection: some View {
        settingsGroup(L("native.section.network")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Host")
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("0.0.0.0", text: $settings.host)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEdit)
                }
                HStack {
                    Text("Port")
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("8080", value: $settings.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(!canEdit)
                    Spacer()
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        settingsGroup(L("native.section.advanced")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Toggle("Debug", isOn: $settings.debug)
                    Toggle("AI Debug", isOn: $settings.aiDebug)
                    Toggle(L("native.http.sandboxUnrestricted"), isOn: $settings.sandboxUnrestricted)
                        .help(L("native.http.sandboxUnrestricted.help"))
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .disabled(!canEdit)

                HStack {
                    Text("Workers")
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(settings.workers) },
                        set: { settings.workers = Int($0) }
                    ), in: 0...8, step: 1)
                    Text(settings.workers == 0 ? L("native.common.disabled") : "\(settings.workers)")
                        .frame(width: 30, alignment: .trailing)
                        .monospacedDigit()
                }
                .disabled(!canEdit)
            }
        }
    }

    // MARK: Chrome MCP

    private var chromeMCPSection: some View {
        settingsGroup(L("native.section.chromeMCP")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("native.settings.chromeMCP.enabled"), isOn: $settings.nativeChromeMCPEnabled)
                    .toggleStyle(.switch)
                    .disabled(!canEdit)
                Toggle(L("native.settings.chromeMCP.terminateOnQuit"), isOn: $settings.terminateChromeOnQuit)
                    .toggleStyle(.switch)
                HStack {
                    Text(L("native.settings.chromeMCP.port"))
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("9223", value: $settings.nativeChromeMCPPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(!canEdit || !settings.nativeChromeMCPEnabled)
                    Spacer()
                }
                Text(L("native.settings.chromeMCP.help"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Secrets

    private var secretsSection: some View {
        settingsGroup(L("native.section.security")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Toggle(L("native.action.reveal"), isOn: $revealSecrets)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                secretRow("JWT Secret", text: $settings.jwtSecret)
                secretRow("Activation", text: $settings.activationKey)
                Text(L("native.secrets.autoGenerated"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider().padding(.vertical, 4)

                // Root account reset
                HStack(spacing: 6) {
                    Text("Root")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(rootUsername.isEmpty ? "—" : rootUsername)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button(isResetting ? "Resetting…" : "Reset Password") {
                        showResetPassword = true
                        newPassword = ""
                        resetStatus = ""
                    }
                    .font(.caption)
                    .disabled(isResetting)
                }

                if !resetStatus.isEmpty {
                    Text(resetStatus)
                        .font(.caption)
                        .foregroundStyle(resetStatus.hasPrefix("✓") ? .green : .red)
                }
            }
        }
        .onAppear { fetchRootUsername() }
        .alert("Reset Root Password", isPresented: $showResetPassword) {
            SecureField("New password (min 4 chars)", text: $newPassword)
            Button("Reset") { performResetPassword() }
                .disabled(newPassword.count < 4)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new password for root user \"\(rootUsername)\".\nService will restart during reset.")
        }
    }

    @ViewBuilder
    private func secretRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            Group {
                if revealSecrets {
                    TextField(L("native.secrets.emptyPlaceholder"), text: text)
                } else {
                    SecureField(L("native.secrets.emptyPlaceholder"), text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .disabled(!canEdit)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text.wrappedValue, forType: .string)
                copiedLabel = label
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedLabel == label { copiedLabel = nil }
                }
            } label: {
                Image(systemName: copiedLabel == label ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copiedLabel == label ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .disabled(text.wrappedValue.isEmpty)
        }
    }

    // MARK: Root password reset helpers

    private var expandedRoot: String {
        (documentRoot as NSString).expandingTildeInPath
    }

    private var serviceBaseURL: String {
        let h = runner.boundHost.isEmpty ? settings.host : runner.boundHost
        let p = runner.boundPort > 0 ? runner.boundPort : settings.port
        return "http://\(h):\(p)"
    }

    private func fetchRootUsername() {
        guard runner.isRunning else { return }
        let key = settings.activationKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(serviceBaseURL)/_api/auth/root-info?activation_key=\(key)") else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let username = json["username"] as? String {
                    await MainActor.run { rootUsername = username }
                }
            } catch {}
        }
    }

    private func performResetPassword() {
        guard newPassword.count >= 4 else { return }
        isResetting = true
        resetStatus = ""
        let password = newPassword

        Task { @MainActor in
            // 1. Stop current service if running
            if runner.canStop { runner.stop() }
            // Wait for service to stop
            while runner.state == .stopping {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            // 2. Start with ALLOW_RESET_ROOT=1
            var env = settings.envDict(uiLanguage: uiLanguage)
            env["ALLOW_RESET_ROOT"] = "1"
            settings.ensureSecretsAndSave()
            runner.start(documentRoot: expandedRoot, env: env)

            // Wait for service to become running
            for _ in 0..<50 {
                if runner.isRunning { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard runner.isRunning else {
                resetStatus = "✗ Service failed to start"
                isResetting = false
                return
            }

            // 3. Call PUT API
            let base = serviceBaseURL
            let key = settings.activationKey
            guard let url = URL(string: "\(base)/_api/auth/root-info") else {
                resetStatus = "✗ Invalid URL"; isResetting = false
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["activation_key": key, "new_password": password]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let result: String
            do {
                let (data, resp) = try await URLSession.shared.data(for: request)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let username = json["username"] as? String {
                        result = "✓ Password reset for \"\(username)\""
                    } else {
                        result = "✓ Password reset successfully"
                    }
                } else {
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let errMsg = json?["error"] as? String ?? "HTTP \(status)"
                    result = "✗ \(errMsg)"
                }
            } catch {
                result = "✗ \(error.localizedDescription)"
            }

            // 4. Stop service (exit reset mode)
            runner.stop()
            while runner.state == .stopping {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            // 5. Restart normally
            settings.ensureSecretsAndSave()
            runner.start(documentRoot: expandedRoot, env: settings.envDict(uiLanguage: uiLanguage))
            resetStatus = result
            isResetting = false

            // Wait for normal start, then refresh root username
            for _ in 0..<50 {
                if runner.isRunning { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            fetchRootUsername()
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
