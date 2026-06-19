import Foundation
import Combine
import CryptoKit

@MainActor
final class AppSettings: ObservableObject {
    @Published var host: String = "127.0.0.1"
    @Published var port: Int = 8080
    @Published var workers: Int = 2
    @Published var sqliteSoftHeapMB: Int = 8
    @Published var debug: Bool = false
    @Published var aiDebug: Bool = false
    @Published var sandboxUnrestricted: Bool = false
    @Published var sslSkipVerify: Bool = false
    @Published var nativeChromeMCPEnabled: Bool = false
    @Published var nativeChromeMCPPort: Int = 9223
    /// Kill the app-managed Chrome when the app quits (default true).
    @Published var terminateChromeOnQuit: Bool = true

    @Published var jwtSecret: String = ""
    @Published var activationKey: String = ""

    /// Ephemeral bearer token for the native Chrome MCP endpoint.
    /// Generated in memory at startup (never persisted) and passed to the Lua
    /// service via env, so only the app and its service process can call it.
    private(set) var nativeChromeMCPToken: String = ""

    private(set) var documentRoot: String = ""

    private static let configFileName = ".luanmac.json"

    private struct Snapshot: Codable {
        var host: String
        var port: Int
        var workers: Int
        var sqliteSoftHeapMB: Int?
        var debug: Bool
        var aiDebug: Bool
        var sandboxUnrestricted: Bool
        var sslSkipVerify: Bool?
        var nativeChromeMCPEnabled: Bool?
        var nativeChromeMCPPort: Int?
        var terminateChromeOnQuit: Bool?
        var jwtSecret: String
        var activationKey: String
        // Legacy (kept optional so old configs still decode)
        var wsToken: String?
        var purgeToken: String?
    }

    func load(documentRoot: String) {
        self.documentRoot = documentRoot
        let path = (documentRoot as NSString).appendingPathComponent(Self.configFileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            host = "127.0.0.1"; port = 8080; workers = 2
            sqliteSoftHeapMB = 8
            debug = false; aiDebug = false; sandboxUnrestricted = false; sslSkipVerify = false
            nativeChromeMCPEnabled = false; nativeChromeMCPPort = 9223
            terminateChromeOnQuit = true
            jwtSecret = ""; activationKey = ""
            return
        }
        host = snap.host
        port = snap.port
        workers = snap.workers
        sqliteSoftHeapMB = snap.sqliteSoftHeapMB ?? 8
        debug = snap.debug
        aiDebug = snap.aiDebug
        sandboxUnrestricted = snap.sandboxUnrestricted
        sslSkipVerify = snap.sslSkipVerify ?? false
        nativeChromeMCPEnabled = snap.nativeChromeMCPEnabled ?? false
        nativeChromeMCPPort = snap.nativeChromeMCPPort ?? 9223
        terminateChromeOnQuit = snap.terminateChromeOnQuit ?? true
        jwtSecret = snap.jwtSecret
        activationKey = snap.activationKey
    }

    func save() {
        guard !documentRoot.isEmpty else { return }
        let snap = Snapshot(host: host, port: port, workers: workers,
                            sqliteSoftHeapMB: sqliteSoftHeapMB,
                            debug: debug, aiDebug: aiDebug,
                            sandboxUnrestricted: sandboxUnrestricted,
                            sslSkipVerify: sslSkipVerify,
                            nativeChromeMCPEnabled: nativeChromeMCPEnabled,
                            nativeChromeMCPPort: nativeChromeMCPPort,
                            terminateChromeOnQuit: terminateChromeOnQuit,
                            jwtSecret: jwtSecret,
                            activationKey: activationKey)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(atPath: documentRoot, withIntermediateDirectories: true)
        let path = (documentRoot as NSString).appendingPathComponent(Self.configFileName)
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// 启动前补齐空字段, 然后保存.
    func ensureSecretsAndSave() {
        if jwtSecret.isEmpty { jwtSecret = Self.randomHex(bytes: 32) }
        if activationKey.isEmpty { activationKey = Self.randomHex(bytes: 16) }
        save()
    }

    /// Generate the ephemeral native MCP token once per app session.
    func ensureNativeChromeMCPToken() {
        if nativeChromeMCPToken.isEmpty {
            nativeChromeMCPToken = Self.randomHex(bytes: 32)
        }
    }

    func regenerateJWT()        { jwtSecret = Self.randomHex(bytes: 32); save() }
    func regenerateActivation() { activationKey = Self.randomHex(bytes: 16); save() }

    /// 转成传给 LuaBridge 的 env 字典.
    func envDict(uiLanguage: String = "system") -> [String: String] {
        var env = [
            "SERVICE_HOST": host,
            "SERVICE_PORT": String(port),
            "SERVICE_WORKERS": String(workers),
            "SQLITE_SOFT_HEAP_MB": String(sqliteSoftHeapMB),
            "SANDBOX_UNRESTRICTED": sandboxUnrestricted ? "1" : "0",
            "SSL_SKIP_VERIFY": sslSkipVerify ? "1" : "0",
            "DEBUG": debug ? "true" : "false",
            "AI_DEBUG": aiDebug ? "1" : "0",
            "LUAN_UI_LANGUAGE": uiLanguage,
            // 与 Dockerfile 默认一致, 开启 C 实现的 httpd/http (支持 websocket).
            "HTTP_USING_CORE": "true",
            "HTTPD_USING_CORE": "true",
            "JWT_SECRET": jwtSecret,
            "ACTIVATION_KEY": activationKey,
        ]
        if nativeChromeMCPEnabled {
            ensureNativeChromeMCPToken()
            env["NATIVE_CHROME_MCP_ENABLED"] = "1"
            env["NATIVE_CHROME_MCP_PORT"] = String(nativeChromeMCPPort)
            env["NATIVE_CHROME_MCP_TOKEN"] = nativeChromeMCPToken
        } else {
            env["NATIVE_CHROME_MCP_ENABLED"] = "0"
        }
        return env
    }

    private static func randomHex(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }
}
