import Foundation
import Network
import Combine

/// Native Chrome MCP server, implemented in Swift.
///
/// Serves an MCP endpoint (JSON-RPC 2.0 over HTTP POST) on 127.0.0.1 that is
/// backed by Chrome DevTools (CDP). It is owned by the app process — not by
/// the Lua service — so it stays alive for the lifetime of the app regardless
/// of Lua start/stop cycles.
///
/// The builtin `chrome-devtools` MCP entry forwards to this endpoint (see
/// agent_tools_mcp.lua) when `NATIVE_CHROME_MCP_ENABLED=1`, so agents share
/// the same app-managed Chrome session.
@MainActor
final class NativeChromeMCP: ObservableObject {
    static let defaultPort = 9223
    static let chromeDebugPort = 9222

    @Published private(set) var isRunning = false
    @Published private(set) var currentPort = 0
    @Published private(set) var lastError: String?

    /// Whether the app-managed Chrome should be killed when the app quits.
    /// Mirrors AppSettings.terminateChromeOnQuit (synced by the UI); the
    /// lifecycle delegate reads this in `applicationWillTerminate`. Defaults to
    /// true — keep the old behavior unless the user opts out.
    var terminateChromeOnQuit = true

    private var listener: NWListener?
    private var chromeProcess: Process?
    private var nextWSID = 0
    private let browserWS = BrowserWSPool()
    /// Bearer token required on every MCP request (ephemeral, per app session).
    private var token: String = ""

    private let debugEndpoint = URL(string: "http://127.0.0.1:\(NativeChromeMCP.chromeDebugPort)")!

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func log(_ msg: String) {
        print("[NativeChromeMCP] \(Self.logFormatter.string(from: Date())) \(msg)")
    }

    // MARK: - Lifecycle

    /// Start (or restart on a different port) the loopback MCP listener.
    /// Requests must carry `Authorization: Bearer <token>`.
    func start(port: Int, token: String) {
        let clamped = min(max(port, 1024), 65535)
        guard !token.isEmpty else {
            lastError = "MCP requires an auth token"
            log("start aborted: empty token")
            return
        }
        // Idempotent: a listener already exists for this port+token (even if
        // it has not reached .ready yet) — keep it. Without this, a second
        // start() cancels the pending listener and immediately re-binds the
        // same port, racing the asynchronous port release ("Address already
        // in use", errno 48).
        if listener != nil && currentPort == clamped && self.token == token { return }
        // Restarting the listener (for example after a port change) must not
        // tear down the long-lived app-managed Chrome session.
        stop(killChrome: false)
        self.token = token

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamped)) else {
            lastError = "invalid MCP port: \(clamped)"
            log("start aborted: invalid port \(clamped)")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback-only listener: requiredLocalEndpoint pins host+port (do NOT
        // also pass `on:` to NWListener — combining both yields EINVAL).
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

        guard let listener = try? NWListener(using: params) else {
            lastError = "failed to create MCP listener on port \(clamped)"
            log("start aborted: NWListener create failed on port \(clamped)")
            return
        }
        log("start: creating listener on port \(clamped)")
        currentPort = clamped
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in
                self?.log("newConnection accepted")
                self?.accept(conn)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.log("listener state: \(state)")
                switch state {
                case .ready:
                    self.isRunning = true
                    self.lastError = nil
                    self.log("listener ready on port \(clamped)")
                case .failed(let err):
                    self.isRunning = false
                    self.currentPort = 0
                    self.lastError = "MCP listener failed: \(err.localizedDescription)"
                    self.listener = nil
                    self.log("listener failed: \(err.localizedDescription) — port \(clamped) may be in use by another process")
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop(killChrome: Bool = true) {
        listener?.cancel()
        listener = nil
        isRunning = false
        currentPort = 0
        if killChrome {
            terminateChrome()
        }
        log("stopped")
    }

    /// Terminate the Chrome instance this manager spawned itself (app-managed,
    /// dedicated `--user-data-dir` profile). A Chrome already listening on the
    /// debug port before us (reused, `chromeProcess == nil`) is left alone —
    /// it belongs to the user / other tooling, not to us. Mirrors the Lua CDP
    /// client, whose `launch_chrome` child dies with the Lua service.
    private func terminateChrome() {
        guard let proc = chromeProcess else { return }
        chromeProcess = nil
        if proc.isRunning {
            log("terminating app-managed chrome pid \(proc.processIdentifier)")
            proc.terminate() // SIGTERM; Chrome exits on it
        }
    }

    /// Open `urlString` in Chrome: activate an existing same-origin tab, reuse
    /// a blank startup tab, or create a new one. Used by the SwiftUI "Open in
    /// Browser" action.
    @discardableResult
    func open(urlString: String) async -> Bool {
        log("open(origin: \(originOf(urlString)))")
        do {
            try await ensureChrome()
            let origin = originOf(urlString)
            let pages = try await fetchPages()
            if let existing = pages.first(where: { originOf($0["url"] as? String ?? "") == origin }),
               let id = existing["id"] as? String {
                _ = try await cdpPut("json/activate/\(id)")
                log("open: activated existing tab \(id)")
                return true
            }
            // A fresh Chrome creates a blank startup tab. Navigate that tab
            // instead of creating a second one; this also keeps sensitive URLs
            // (such as registration links) out of Chrome's process arguments.
            if let blank = pages.first(where: { Self.isBlankPage($0) }),
               let ws = blank["webSocketDebuggerUrl"] as? String {
                _ = try await wsCommand(wsURL: ws, method: "Page.navigate", params: ["url": urlString])
                log("open: navigated blank tab to target")
                return true
            }
            let created = try await cdpCreatePage(urlString)
            log("open: created new tab \(created.targetID)")
            return true
        } catch {
            lastError = String(describing: error)
            log("open FAILED: \(error)")
            return false
        }
    }

    /// A startup/new-tab page with no real content — safe to navigate instead
    /// of creating another tab.
    private static func isBlankPage(_ entry: [String: Any]) -> Bool {
        let u = (entry["url"] as? String) ?? ""
        return u.isEmpty
            || u == "about:blank"
            || u == "chrome://newtab/"
            || u.hasPrefix("chrome://newtab")
            || u == "chrome://new-tab-page/"
    }

    // MARK: - HTTP plumbing

    private func accept(_ conn: NWConnection) {
        var buffer = Data()
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        self.log("receive \(data.count) bytes, buffer=\(buffer.count)")
                    }
                    if let req = Self.parseHTTP(buffer) {
                        self.log("parsed request: \(req.method) content-length=\(req.headers["content-length"] ?? "?") body=\(req.body.count)")
                        self.process(conn, req)
                        return
                    }
                    self.log("parseHTTP nil, buffer=\(buffer.count) complete=\(isComplete) err=\(error != nil)")
                    if error != nil || isComplete {
                        conn.cancel()
                        return
                    }
                    pump()
                }
            }
        }
        pump()
    }

    private func process(_ conn: NWConnection, _ req: HTTPRequest) {
        let authPresent = req.headers["authorization"]?.hasPrefix("Bearer ") ?? false
        log("process: method=\(req.method) auth=\(authPresent ? "present" : "missing")")
        guard req.method == "POST" else {
            reply(conn, status: 405, body: nil)
            return
        }
        // Bearer auth: only the app (and the Lua service it started, which
        // receives the token via env) can call this endpoint.
        guard req.headers["authorization"] == "Bearer \(token)" else {
            reply(conn, status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            reply(conn, status: 400, body: Data(#"{"error":"invalid JSON body"}"#.utf8))
            return
        }
        Task {
            let (status, body) = await handleRequest(obj)
            reply(conn, status: status, body: body)
        }
    }

    private func reply(_ conn: NWConnection, status: Int, body: Data?) {
        let body = body ?? Data()
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        log("reply: status=\(status) bytes=\(out.count)")
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private struct HTTPRequest {
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private static func parseHTTP(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let headerStr = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = headerStr.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            if let idx = line.firstIndex(of: ":") {
                let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let bodyLen = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + bodyLen else { return nil }
        return HTTPRequest(
            method: String(parts[0]),
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + bodyLen))
        )
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }

    // MARK: - JSON-RPC dispatch

    private func handleRequest(_ request: [String: Any]) async -> (status: Int, body: Data?) {
        guard let method = request["method"] as? String else {
            return (400, jsonData(["jsonrpc": "2.0", "id": request["id"] ?? NSNull(),
                                   "error": ["code": -32600, "message": "Invalid Request"]]))
        }
        let id = request["id"] ?? NSNull()
        let params = (request["params"] as? [String: Any]) ?? [:]

        switch method {
        case "initialize":
            return (200, jsonData(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "serverInfo": ["name": "native-chrome-mcp", "version": "1.0.0"],
            ]]))
        case "notifications/initialized":
            return (204, nil)
        case "ping":
            return (200, jsonData(["jsonrpc": "2.0", "id": id, "result": [String: Any]()]))
        case "tools/list":
            return (200, jsonData(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.tools]]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return (200, jsonData(["jsonrpc": "2.0", "id": id,
                                       "error": ["code": -32602, "message": "name required"]]))
            }
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            let result = await callTool(name, args)
            return (200, jsonData(["jsonrpc": "2.0", "id": id, "result": result]))
        default:
            return (200, jsonData(["jsonrpc": "2.0", "id": id,
                                   "error": ["code": -32601, "message": "Method not found: \(method)"]]))
        }
    }

    private func jsonData(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    // MARK: - Tools
    //
    // Only the generic CDP passthrough tools are exposed. The full 50-tool
    // Lua client (mcp_client_chrome_devtools + native_chrome_backend) is the
    // single consumer and implements all convenience operations (version,
    // new_page, navigate, evaluate, ...) on top of these three primitives.
    // NativeChromeMCP's own job is long-lived Chrome management, not a
    // convenience API surface.

    private static let tools: [[String: Any]] = [
        ["name": "page_command",
         "description": "Send an arbitrary CDP command to a page target (Page.*, DOM.*, Runtime.*, Network.*, ...).",
         "inputSchema": ["type": "object",
                         "properties": [
                            "id": ["type": "string", "description": "targetId"],
                            "method": ["type": "string", "description": "CDP method, e.g. Page.captureScreenshot"],
                            "params": ["type": "object", "description": "CDP method params"],
                            "sessionId": ["type": "string", "description": "optional flat session id from Target.attachToTarget(flatten=true)"]],
                         "required": ["id", "method"]]],
        ["name": "browser_command",
         "description": "Send an arbitrary CDP command to the browser target (Target.*, Extensions.*, ...).",
         "inputSchema": ["type": "object",
                         "properties": [
                            "method": ["type": "string", "description": "CDP method, e.g. Target.createTarget"],
                            "params": ["type": "object", "description": "CDP method params"],
                            "sessionId": ["type": "string", "description": "optional flat session id from Target.attachToTarget(flatten=true)"]],
                         "required": ["method"]]],
        ["name": "http_command",
         "description": "Call a Chrome DevTools HTTP endpoint: GET /json/version, GET /json/list, PUT /json/new?url=..., PUT /json/activate/{id}, PUT /json/close/{id}.",
         "inputSchema": ["type": "object",
                         "properties": [
                            "method": ["type": "string", "description": "GET or PUT"],
                            "path": ["type": "string", "description": "endpoint path, e.g. /json/list"]],
                         "required": ["path"]]],
    ]

    private func callTool(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "page_command":
                try await ensureChrome()
                guard let id = arguments["id"] as? String,
                      let method = arguments["method"] as? String else {
                    return toolError("id (targetId) and method required")
                }
                guard let page = try await findPage(id), let ws = page["webSocketDebuggerUrl"] as? String else {
                    return toolError("page not found: \(id)")
                }
                let params = (arguments["params"] as? [String: Any]) ?? [:]
                let sessionId = arguments["sessionId"] as? String
                let r = try await wsCommand(wsURL: ws, method: method, params: params, sessionId: sessionId)
                return toolResult(r)
            case "browser_command":
                try await ensureChrome()
                guard let method = arguments["method"] as? String else {
                    return toolError("method required")
                }
                let ws = try await browserWSURL()
                let params = (arguments["params"] as? [String: Any]) ?? [:]
                let sessionId = arguments["sessionId"] as? String
                let r = try await browserWS.run(wsURL: ws, method: method, params: params, sessionId: sessionId)
                return toolResult(r)
            case "http_command":
                try await ensureChrome()
                guard let path = arguments["path"] as? String, !path.isEmpty else {
                    return toolError("path required")
                }
                let httpMethod = (arguments["method"] as? String) ?? "GET"
                let r = try await cdpHTTP(method: httpMethod, path: path)
                return toolResult(r)
            default:
                return toolError("unknown tool: \(name)")
            }
        } catch {
            return toolError(String(describing: error))
        }
    }

    private func toolResult(_ value: Any) -> [String: Any] {
        let text = (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                                encoding: .utf8)) ?? "{}"
        return ["content": [["type": "text", "text": text]]]
    }

    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - Chrome (CDP)

    private enum ChromeError: LocalizedError {
        case unreachable, noExecutable, invalidTarget, cdpFailed, wsFailed, timeout, cdpError(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: return "Chrome DevTools endpoint unreachable"
            case .noExecutable: return "Chrome executable not found"
            case .invalidTarget: return "invalid CDP target"
            case .cdpFailed: return "CDP request failed"
            case .wsFailed: return "CDP WebSocket failed"
            case .timeout: return "CDP command timed out"
            case .cdpError(let m): return m
            }
        }
    }

    /// Serial CDP command runner over a PERSISTENT browser-level WebSocket.
    /// A per-call connection would break flat `Target.attachToTarget` sessions:
    /// a session id only exists on the connection that created it. Keeping one
    /// long-lived browser connection lets `set_proxy` / `query_proxy` do
    /// attach -> evaluate with the same sessionId across tool calls. Commands
    /// are serialized by the actor; a command timeout keeps the connection
    /// (session ids must survive), a transport error drops it for reconnect.
    private actor BrowserWSPool {
        private var task: URLSessionWebSocketTask?
        private var wsURL = ""
        private var nextID = 0

        func run(wsURL: String, method: String, params: [String: Any],
                 sessionId: String?, timeout: Double = 20) async throws -> [String: Any] {
            let reusing = (task != nil && self.wsURL == wsURL)
            print("[NativeChromeMCP] BrowserWSPool.run method=\(method) sid=\(sessionId ?? "-") reusing=\(reusing)")
            if task == nil || self.wsURL != wsURL {
                task?.cancel(with: .goingAway, reason: nil)
                guard let url = URL(string: wsURL) else { throw NativeChromeMCP.ChromeError.invalidTarget }
                print("[NativeChromeMCP] BrowserWSPool new connection (old wsURL=\(self.wsURL))")
                let t = URLSession.shared.webSocketTask(with: url)
                t.resume()
                task = t
                self.wsURL = wsURL
            }
            guard let task else { throw NativeChromeMCP.ChromeError.wsFailed }

            nextID += 1
            let id = nextID
            var payload: [String: Any] = ["id": id, "method": method, "params": params]
            if let sessionId, !sessionId.isEmpty { payload["sessionId"] = sessionId }
            let data = try JSONSerialization.data(withJSONObject: payload)
            do {
                if let text = String(data: data, encoding: .utf8) {
                    try await task.send(.string(text))
                } else {
                    try await task.send(.data(data))
                }
            } catch {
                print("[NativeChromeMCP] BrowserWSPool send error, dropping connection: \(error)")
                task.cancel(with: .goingAway, reason: nil)
                self.task = nil
                throw NativeChromeMCP.ChromeError.wsFailed
            }

            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await NativeChromeMCP.withTimeout(seconds: timeout) {
                        try await task.receive()
                    }
                } catch is NativeChromeMCP.ChromeError {
                    // command timeout — keep the connection (sessions survive)
                    throw NativeChromeMCP.ChromeError.timeout
                } catch {
                    // transport error — drop the connection so the next call reconnects
                    print("[NativeChromeMCP] BrowserWSPool transport error, dropping connection: \(error)")
                    task.cancel(with: .goingAway, reason: nil)
                    self.task = nil
                    throw NativeChromeMCP.ChromeError.wsFailed
                }
                let d: Data
                switch message {
                case .string(let s): d = Data(s.utf8)
                case .data(let raw): d = raw
                @unknown default: continue
                }
                guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let rid = obj["id"] as? Int, rid == id
                else { continue }
                if let err = obj["error"] as? [String: Any] {
                    throw NativeChromeMCP.ChromeError.cdpError((err["message"] as? String) ?? "CDP error")
                }
                return (obj["result"] as? [String: Any]) ?? [:]
            }
        }
    }

    private var chromeExecutableURL: URL? {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private var chromeDataDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/luan-chrome-devtools/profile").path
    }

    /// Make sure Chrome is listening on the debug port; launch it if needed.
    private func ensureChrome() async throws {
        if (try? await cdpGet("json/version") as? [String: Any]) != nil { return }
        guard let exe = chromeExecutableURL else { throw ChromeError.noExecutable }
        try FileManager.default.createDirectory(atPath: chromeDataDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = [
            "--remote-debugging-port=\(NativeChromeMCP.chromeDebugPort)",
            "--user-data-dir=\(chromeDataDir)",
            "--hide-crash-restore-bubble",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                if self?.chromeProcess === p { self?.chromeProcess = nil }
            }
        }
        try proc.run()
        chromeProcess = proc
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if (try? await cdpGet("json/version") as? [String: Any]) != nil { return }
        }
        throw ChromeError.unreachable
    }

    private func fetchPages() async throws -> [[String: Any]] {
        let list = try await cdpGet("json/list")
        guard let arr = list as? [[String: Any]] else { return [] }
        return arr.filter { ($0["type"] as? String) == "page" }
    }

    private func findPage(_ id: String) async throws -> [String: Any]? {
        let pages = try await fetchPages()
        return pages.first { ($0["id"] as? String) == id }
    }

    private struct CreatedPage {
        let targetID: String
        let url: String
    }

    private func cdpCreatePage(_ url: String) async throws -> CreatedPage {
        var comps = URLComponents(url: debugEndpoint, resolvingAgainstBaseURL: false)!
        comps.path = "/json/new"
        comps.query = url
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "PUT"
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String
        else { throw ChromeError.cdpFailed }
        return CreatedPage(targetID: id, url: (obj["url"] as? String) ?? url)
    }

    private func cdpGet(_ path: String) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(from: debugEndpoint.appendingPathComponent(path))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw ChromeError.unreachable }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func cdpPut(_ path: String) async throws -> Any {
        var req = URLRequest(url: debugEndpoint.appendingPathComponent(path))
        req.httpMethod = "PUT"
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw ChromeError.cdpFailed }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Generic CDP HTTP endpoint call (GET/PUT). Returns the decoded JSON.
    private func cdpHTTP(method: String, path: String) async throws -> Any {
        // /json/new takes the URL as a query param on the raw path (may already
        // contain '?'), so build the request URL without percent-encoding the query.
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = NativeChromeMCP.chromeDebugPort
        if let qIdx = path.firstIndex(of: "?") {
            comps.path = String(path[..<qIdx])
            comps.query = String(path[path.index(after: qIdx)...])
        } else {
            comps.path = path
        }
        guard let url = comps.url else { throw ChromeError.invalidTarget }
        var req = URLRequest(url: url)
        req.httpMethod = method.uppercased()
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw ChromeError.cdpFailed }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Browser-level WebSocket URL from /json/version.
    private func browserWSURL() async throws -> String {
        let v = try await cdpGet("json/version")
        guard let obj = v as? [String: Any], let ws = obj["webSocketDebuggerUrl"] as? String, !ws.isEmpty else {
            throw ChromeError.invalidTarget
        }
        return ws
    }

    /// Send one CDP command over WebSocket and wait for its matching reply.
    /// CDP speaks JSON **text** frames (binary frames are ignored by Chrome),
    /// so both send and receive use text; binary frames are also accepted on
    /// receive for robustness.
    private func wsCommand(wsURL: String, method: String, params: [String: Any],
                           sessionId: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: wsURL) else { throw ChromeError.invalidTarget }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        nextWSID += 1
        let id = nextWSID
        var payload: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId, !sessionId.isEmpty {
            payload["sessionId"] = sessionId
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        if let text = String(data: data, encoding: .utf8) {
            try await task.send(.string(text))
        } else {
            try await task.send(.data(data))
        }

        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await Self.withTimeout(seconds: 20) { try await task.receive() } }
            catch { throw ChromeError.wsFailed }
            let d: Data
            switch message {
            case .string(let s): d = Data(s.utf8)
            case .data(let raw): d = raw
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let rid = obj["id"] as? Int, rid == id
            else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw ChromeError.cdpError((err["message"] as? String) ?? "CDP error")
            }
            return (obj["result"] as? [String: Any]) ?? [:]
        }
    }

    /// Race `body` against a deadline; throws `ChromeError.timeout` if the
    /// deadline fires first (WebSocket receive has no built-in timeout).
    private static func withTimeout<T: Sendable>(seconds: Double,
                                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ChromeError.timeout
            }
            guard let first = try await group.next() else { throw ChromeError.timeout }
            group.cancelAll()
            return first
        }
    }

    private func originOf(_ urlString: String) -> String {
        guard let u = URL(string: urlString), let scheme = u.scheme, let host = u.host else {
            return urlString
        }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port: String
        if let p = u.port, p != defaultPort {
            port = ":\(p)"
        } else {
            port = ""
        }
        return scheme + "://" + host + port
    }
}
