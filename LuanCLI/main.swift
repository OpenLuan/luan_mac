import Foundation
import Security

// MARK: - Argument Parsing

struct Config {
    var documentRoot: String = ""
    var host: String = "127.0.0.1"
    var port: Int = 8080
    var workers: Int = 2
    var sqliteSoftHeapMB: Int = 8
    var debug: Bool = false
    var aiDebug: Bool = false
    var sandboxUnrestricted: Bool = false
    var sslSkipVerify: Bool = false
    var jwtSecret: String = ""
    var activationKey: String = ""
    var wsToken: String = ""
    var purgeToken: String = ""
    var execCode: String = ""
    var execScript: String = ""
    var scriptArgs: [String] = []
}

func printUsage() {
    let usage = """
    luan — Lua runtime and luan service CLI

    Usage:
      luan [options]                          Start the HTTP service
      luan [options] -e <code> [-- args...]    Execute Lua code
      luan [options] --script <file> [args...] Execute a Lua script and exit

    Runtime execution uses the same embedded Lua, luafan, native modules, and
    merged runtime module tree as the service.

    Options:
      -d, --document-root <path>   Document root directory (default: current directory)
      -e, --eval <code>            Execute Lua code and exit
          --script <path>          Execute a Lua script and exit
          --host <addr>            Bind address (default: 127.0.0.1)
      -p, --port <port>            HTTP port (default: 8080)
          --workers <n>            Worker threads (default: 2)
          --sqlite-soft-heap-mb <n> SQLite soft heap limit in MB (default: 8)
          --debug                  Enable debug logging
          --ai-debug               Enable AI debug logging
          --sandbox-unrestricted   Allow sandbox escape for root users
          --ssl-skip-verify        Skip SSL certificate verification
          --jwt-secret <secret>    JWT secret
          --activation-key <key>   Activation key
          --ws-token <token>       WebSocket token
          --purge-token <token>    Purge token
      -h, --help                   Show this help
    """
    print(usage)
}

func parseArgs() -> Config? {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1

    while i < args.count {
        let arg = args[i]
        if arg == "--" {
            if i + 1 < args.count { config.scriptArgs = Array(args[(i + 1)..<args.count]) }
            break
        }
        switch arg {
        case "-h", "--help":
            printUsage()
            return nil
        case "-e", "--eval":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.execCode = args[i]
        case "--script":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.execScript = args[i]
        case "-d", "--document-root":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.documentRoot = args[i]
        case "-p", "--port":
            i += 1
            guard i < args.count, let p = Int(args[i]) else { fputs("error: \(arg) requires a numeric value\n", stderr); return nil }
            config.port = p
        case "--host":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.host = args[i]
        case "--workers":
            i += 1
            guard i < args.count, let w = Int(args[i]) else { fputs("error: \(arg) requires a numeric value\n", stderr); return nil }
            config.workers = w
        case "--sqlite-soft-heap-mb":
            i += 1
            guard i < args.count, let mb = Int(args[i]) else { fputs("error: \(arg) requires a numeric value\n", stderr); return nil }
            config.sqliteSoftHeapMB = mb
        case "--debug": config.debug = true
        case "--ai-debug": config.aiDebug = true
        case "--sandbox-unrestricted": config.sandboxUnrestricted = true
        case "--ssl-skip-verify": config.sslSkipVerify = true
        case "--jwt-secret":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.jwtSecret = args[i]
        case "--activation-key":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.activationKey = args[i]
        case "--ws-token":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.wsToken = args[i]
        case "--purge-token":
            i += 1
            guard i < args.count else { fputs("error: \(arg) requires a value\n", stderr); return nil }
            config.purgeToken = args[i]
        default:
            if arg.hasSuffix(".lua") && config.execScript.isEmpty {
                config.execScript = arg
            } else if arg.hasPrefix("-") {
                fputs("error: unknown option \(arg)\n", stderr)
                return nil
            } else if !config.execScript.isEmpty {
                config.scriptArgs.append(arg)
            } else if config.documentRoot.isEmpty {
                config.documentRoot = arg
            } else {
                fputs("error: unexpected argument \(arg)\n", stderr)
                return nil
            }
        }
        i += 1
    }

    if !config.execCode.isEmpty && !config.execScript.isEmpty {
        fputs("error: --eval and --script are mutually exclusive\n", stderr)
        return nil
    }

    if config.documentRoot.isEmpty {
        // Try current directory as default
        config.documentRoot = FileManager.default.currentDirectoryPath
        fputs("warning: no --document-root specified, using current directory: \(config.documentRoot)\n", stderr)
    }

    return config
}

// MARK: - Random hex string for auto-generated secrets

func randomHex(bytes: Int) -> String {
    var data = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(nil, bytes, &data)
    return data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - .luanmac.json config merge

func loadSavedConfig(documentRoot: String) -> [String: Any]? {
    let configPath = (documentRoot as NSString).appendingPathComponent(".luanmac.json")
    guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
    let obj = try? JSONSerialization.jsonObject(with: data)
    return obj as? [String: Any]
}

// MARK: - Main

guard var config = parseArgs() else {
    exit(EXIT_FAILURE)
}

// Expand tilde
if config.documentRoot.hasPrefix("~") {
    config.documentRoot = (config.documentRoot as NSString).expandingTildeInPath
}

// Ensure absolute path
if !config.documentRoot.hasPrefix("/") {
    config.documentRoot = FileManager.default.currentDirectoryPath + "/" + config.documentRoot
}

// Merge with .luanmac.json (CLI args override saved values)
let saved = loadSavedConfig(documentRoot: config.documentRoot)
let savedInt: (String) -> Int? = { key in (saved?[key] as? NSNumber)?.intValue }
let savedStr: (String) -> String? = { key in saved?[key] as? String }

// Auto-generate secrets if empty, persist to .luanmac.json
var dirty = false
if config.jwtSecret.isEmpty {
    config.jwtSecret = savedStr("jwtSecret") ?? randomHex(bytes: 32)
    if saved?["jwtSecret"] == nil { dirty = true }
}
if config.activationKey.isEmpty {
    config.activationKey = savedStr("activationKey") ?? randomHex(bytes: 32)
    if saved?["activationKey"] == nil { dirty = true }
}
if config.wsToken.isEmpty {
    config.wsToken = savedStr("wsToken") ?? randomHex(bytes: 32)
    if saved?["wsToken"] == nil { dirty = true }
}
if config.purgeToken.isEmpty {
    config.purgeToken = savedStr("purgeToken") ?? randomHex(bytes: 32)
    if saved?["purgeToken"] == nil { dirty = true }
}
if dirty {
    let cfgPath = (config.documentRoot as NSString).appendingPathComponent(".luanmac.json")
    var cfg: [String: Any] = saved ?? [:]
    cfg["jwtSecret"] = config.jwtSecret
    cfg["activationKey"] = config.activationKey
    cfg["wsToken"] = config.wsToken
    cfg["purgeToken"] = config.purgeToken
    cfg["port"] = config.port
    cfg["workers"] = config.workers
    if let data = try? JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted) {
        try? data.write(to: URL(fileURLWithPath: cfgPath))
    }
}

// Read port/workers from saved config only if not explicitly set via CLI
// (parseArgs uses defaults, so check if saved has values)
if let savedPort = savedInt("port"), CommandLine.arguments.firstIndex(where: { $0 == "-p" || $0 == "--port" }) == nil {
    config.port = savedPort
}
if let savedWorkers = savedInt("workers"), CommandLine.arguments.firstIndex(where: { $0 == "--workers" }) == nil {
    config.workers = savedWorkers
}

// Set environment variables
func setEnv(_ key: String, _ value: String) { setenv(key, value, 1) }
if !config.execCode.isEmpty { setEnv("LUAN_EXEC_CODE", config.execCode) }
if !config.execScript.isEmpty {
    setEnv("LUAN_EXEC_SCRIPT", config.execScript)
    setEnv("LUAN_ARGC", String(config.scriptArgs.count))
    for (index, value) in config.scriptArgs.enumerated() {
        setEnv("LUAN_ARG_\(index)", value)
    }
}
setEnv("SERVICE_HOST", config.host)
setEnv("SERVICE_PORT", String(config.port))
setEnv("SERVICE_WORKERS", String(config.workers))
setEnv("SQLITE_SOFT_HEAP_MB", String(config.sqliteSoftHeapMB))
setEnv("HTTP_USING_CORE", "true")
setEnv("HTTPD_USING_CORE", "true")
setEnv("JWT_SECRET", config.jwtSecret)
setEnv("ACTIVATION_KEY", config.activationKey)
setEnv("WS_TOKEN", config.wsToken)
setEnv("PURGE_TOKEN", config.purgeToken)
if config.debug { setEnv("DEBUG", "1") }
if config.aiDebug { setEnv("AI_DEBUG", "1") }
if config.sandboxUnrestricted { setEnv("SANDBOX_UNRESTRICTED", "1") }
if config.sslSkipVerify { setEnv("SSL_SKIP_VERIFY", "1") }

// Print startup info
print("luan runtime")
print("  document root: \(config.documentRoot)")
print("  listening on:  \(config.host):\(config.port)")
print("  workers:       \(config.workers)")
print("  JWT_SECRET:    \(config.jwtSecret)")
print("  ACTIVATION_KEY:\(config.activationKey)")
print("  WS_TOKEN:      \(config.wsToken)")
print("  PURGE_TOKEN:   \(config.purgeToken)")

// Find runtime directory (plain Lua tree; entry core.lua from build.sh).
let exeDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
let fm = FileManager.default
var runtimeDir = ""

func runtimeDirLooksValid(_ path: String) -> Bool {
    return fm.fileExists(atPath: path + "/core.lua")
}

// Primary: documentRoot/runtime (build.sh deploys here or symlinked).
let docRuntime = config.documentRoot + "/runtime"
let candidates = [
    // Inside .app bundle (binary at Contents/MacOS/luan)
    (exeDir as NSString).appendingPathComponent("../Resources/runtime"),
    // Alongside .app in Build/Products/Debug/ (Xcode dev layout)
    exeDir + "/LuanMac.app/Contents/Resources/runtime",
    // Development: xcodebuild output, runtime next to .app parent
    (exeDir as NSString).appendingPathComponent("../../../runtime"),
    // Fallback: next to binary
    exeDir + "/runtime",
]

var sourceDir = ""
for c in candidates {
    let resolved = (c as NSString).standardizingPath
    if runtimeDirLooksValid(resolved) {
        sourceDir = resolved
        break
    }
}

// A symlink may still resolve to a valid but stale runtime from another build.
// When a current build output is available, recreate the link unconditionally.
let docRuntimeIsSymlink = (try? fm.destinationOfSymbolicLink(atPath: docRuntime)) != nil
if docRuntimeIsSymlink && !sourceDir.isEmpty {
    try? fm.removeItem(atPath: docRuntime)
    try? fm.createSymbolicLink(atPath: docRuntime, withDestinationPath: sourceDir)
}

if runtimeDirLooksValid(docRuntime) {
    runtimeDir = docRuntime
} else if !sourceDir.isEmpty {
    // Create symlink so documentRoot/runtime always exists for next launch.
    try? fm.createDirectory(atPath: config.documentRoot, withIntermediateDirectories: true)
    if fm.fileExists(atPath: docRuntime) {
        try? fm.removeItem(atPath: docRuntime)
    }
    try? fm.createSymbolicLink(atPath: docRuntime, withDestinationPath: sourceDir)
    if runtimeDirLooksValid(docRuntime) {
        runtimeDir = docRuntime
    } else {
        runtimeDir = sourceDir
    }
}
if runtimeDir.isEmpty {
    fputs("error: cannot find runtime/ directory containing core.lua\n", stderr)
    fputs("  exe: \(exeDir)\n", stderr)
    fputs("  doc: \(config.documentRoot)\n", stderr)
    exit(EXIT_FAILURE)
}
print("  runtime dir:   \(runtimeDir)")

// Create and run LuaBridge
let bridge = LuaBridge()

// CLI: output logs to stderr instead of NSLog
LuanSetLogToStderr(true)
// Also wire outputHandler so load/runtime errors (LuaBridge emit) always show on CLI.
// Without this, !! lua 加载/运行时错误 only went to a nil handler and looked like a silent exit.
bridge.outputHandler = { chunk in
    fputs(chunk, stderr)
    fflush(stderr)
}

// Signal handling for graceful shutdown
signal(SIGINT) { _ in
    fputs("\nReceived SIGINT, shutting down...\n", stderr)
    bridge.stop()
}
signal(SIGTERM) { _ in
    fputs("\nReceived SIGTERM, shutting down...\n", stderr)
    bridge.stop()
}

if config.execCode.isEmpty && config.execScript.isEmpty {
    bridge.run(withDocumentRoot: config.documentRoot, env: [
        "SERVICE_HOST": config.host,
        "SERVICE_PORT": String(config.port),
        "SERVICE_WORKERS": String(config.workers),
        "SQLITE_SOFT_HEAP_MB": String(config.sqliteSoftHeapMB),
        "JWT_SECRET": config.jwtSecret,
        "ACTIVATION_KEY": config.activationKey,
        "WS_TOKEN": config.wsToken,
        "PURGE_TOKEN": config.purgeToken,
    ])
} else {
    bridge.runScript(withDocumentRoot: config.documentRoot, env: [
        "SERVICE_HOST": config.host,
        "SERVICE_PORT": String(config.port),
        "SERVICE_WORKERS": String(config.workers),
        "SQLITE_SOFT_HEAP_MB": String(config.sqliteSoftHeapMB),
        "JWT_SECRET": config.jwtSecret,
        "ACTIVATION_KEY": config.activationKey,
        "WS_TOKEN": config.wsToken,
        "PURGE_TOKEN": config.purgeToken,
        "LUAN_EXEC_CODE": config.execCode,
        "LUAN_EXEC_SCRIPT": config.execScript,
    ])
}

// Cleanup
print("luan runtime stopped.")
