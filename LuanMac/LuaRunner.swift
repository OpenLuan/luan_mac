import Foundation
import Darwin
import Combine

/// 服务生命周期. stop 后会等 cleanup 完成再回到 idle, 所以可以反复 启动 / 停止.
enum ServiceState: Equatable {
    case idle           // 未启动 / 已干净停止, 可启动
    case starting       // 正在引导 lua / 编译
    case running        // core.lua 已经把 httpd 绑好, 服务对外可用
    case stopping       // 已请求 event_mgr_break, 等 fan.loop + cleanup 退
    case failed(String) // 启动过程出错
}

@MainActor
final class LuaRunner: ObservableObject {
    static let shared = LuaRunner()

    @Published private(set) var state: ServiceState = .idle
    @Published private(set) var boundHost: String = ""
    @Published private(set) var boundPort: Int = 0
    @Published private(set) var logPath: String = ""

    // 资源占用. nil = 暂未采到(刚启动)或服务已停 — UI 渲染为 "—".
    @Published private(set) var cpuNow: Double? = nil
    @Published private(set) var rssNowMB: Double? = nil
    @Published private(set) var luaNowMB: Double? = nil
    @Published private(set) var refCount: Int = 0

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var healthcheckTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?

    // Startup diagnostics captured from the luan child process. Consumed after
    // the process exits to surface .failed(msg) when healthcheck never succeeds.
    //
    // Perf note: outputHandler runs for EVERY print/stderr chunk (can be
    // very hot once fan.loop starts serving traffic). Capture is gated by
    // a monotonic deadline so scanning only happens during the startup
    // window (~10s from start(), or until healthcheck flips .running).
    // Outside the window captureStartupDiag returns after a lock+read+return,
    // ~10-20ns uncontended — no split/contains/array access.
    private let diagLock = NSLock()
    // startupDiag / captureDeadline are guarded solely by diagLock and are
    // read/written from the bridge thread (nonisolated) as well as MainActor,
    // so they are deliberately not actor-isolated. nonisolated(unsafe) tells
    // the compiler the synchronization is manual (the NSLock above).
    nonisolated(unsafe) private var startupDiag: [String] = []
    // Deadline (DispatchTime.uptimeNanoseconds domain) after which capture
    // is disabled; 0 = disabled. Read/written under diagLock only.
    nonisolated(unsafe) private var captureDeadline: UInt64 = 0
    // How long we scan for startup errors after start() before assuming
    // the service is stable and any later errors are runtime noise (not
    // start failures). Clamped to [1, 60] in openCaptureWindow.
    private static let defaultCaptureWindowSec: Double = 10.0

    var isRunning: Bool { if case .running = state { return true }; return false }
    var canStart: Bool { if case .idle = state { return true }; if case .failed = state { return true }; return false }
    var canStop: Bool { if case .running = state { return true }; return false }

    private init() {}

    // MARK: - Startup diagnostics capture
    //
    // bridge.outputHandler is invoked on the bridge thread for every print()
    // / stderr chunk. We record lines that look like Lua/host errors so we
    // can present them as .failed(msg) if the service never comes up.
    // Called on the bridge thread — must stay cheap. Fast path (post-startup)
    // is one lock+read+return; scanning only happens inside the window.
    nonisolated private func captureStartupDiag(_ chunk: String) {
        // Fast path: read deadline under lock, bail if window closed.
        diagLock.lock()
        let deadline = captureDeadline
        if deadline == 0 {
            diagLock.unlock()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline {
            // Window expired — close gate so subsequent chunks bail on the
            // first branch above without another clock read.
            captureDeadline = 0
            diagLock.unlock()
            return
        }
        diagLock.unlock()
        // Slow path: inside startup window — scan the chunk.
        // Only keep obvious error lines to avoid dumping the whole log.
        // Matches:
        //   "!! lua 运行时错误 ..."  (LuaBridge.m)
        //   "!! lua 加载失败 ..."    (LuaBridge.m)
        //   "!! ..."                  (any bridge diagnostic)
        //   "LuaError:..."            (fan.utils lua traceback wrapper)
        //   "...:N: attempt to ..."   (raw lua runtime error line)
        for rawLine in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let isDiag = line.hasPrefix("!! ")
                || line.hasPrefix("LuaError")
                || line.contains(": attempt to ")
                || line.contains("httpd.bind failed")
            if !isDiag { continue }
            diagLock.lock()
            // Cap to avoid unbounded growth if a runaway loop errors.
            if startupDiag.count < 20 {
                startupDiag.append(line)
            }
            diagLock.unlock()
        }
    }

    // Open the diag capture window for `seconds` from now.
    // Called on MainActor from start(); safe across threads (locked).
    private func openCaptureWindow(seconds: Double) {
        let clamped = max(1.0, min(60.0, seconds))
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(clamped * 1_000_000_000)
        diagLock.lock()
        captureDeadline = deadline
        diagLock.unlock()
    }

    // Close the diag capture window immediately. Called when we know the
    // service reached a stable state (healthcheck → .running, or stop()),
    // so subsequent chunks skip scanning entirely.
    nonisolated private func closeCaptureWindow() {
        diagLock.lock()
        captureDeadline = 0
        diagLock.unlock()
    }

    private func consumeStartupDiag() -> String? {
        diagLock.lock()
        let lines = startupDiag
        startupDiag.removeAll(keepingCapacity: false)
        diagLock.unlock()
        if lines.isEmpty { return nil }
        // Deduplicate consecutive dupes; keep at most 6 lines for the UI.
        var seen = Set<String>()
        var out: [String] = []
        for l in lines {
            if seen.insert(l).inserted {
                out.append(l)
                if out.count >= 6 { break }
            }
        }
        return out.joined(separator: "\n")
    }

    func start(documentRoot: String, env: [String: String]) {
        guard canStart, process == nil else { return }
        state = .starting
        boundHost = ""
        boundPort = 0
        refCount = 0
        cpuNow = nil
        rssNowMB = nil
        luaNowMB = nil
        diagLock.lock(); startupDiag.removeAll(keepingCapacity: false); diagLock.unlock()
        openCaptureWindow(seconds: LuaRunner.defaultCaptureWindowSec)

        let dir = (documentRoot as NSString).expandingTildeInPath
        let host = env["SERVICE_HOST"] ?? "127.0.0.1"
        let port = Int(env["SERVICE_PORT"] ?? "") ?? 0
        logPath = dir + "/luan.log"

        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("luan"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            state = .failed("luan CLI executable not found in the app bundle")
            closeCaptureWindow()
            return
        }

        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "--document-root", dir,
            "--host", host,
            "--port", String(port),
            "--workers", env["SERVICE_WORKERS"] ?? "0",
            "--sqlite-soft-heap-mb", env["SQLITE_SOFT_HEAP_MB"] ?? "0",
        ]
        var childEnv = ProcessInfo.processInfo.environment
        for (key, value) in env { childEnv[key] = value }
        child.environment = childEnv

        let output = Pipe()
        let errors = Pipe()
        outputPipe = output
        errorPipe = errors
        child.standardOutput = output
        child.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.consumeChildOutput(text) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.consumeChildOutput(text) }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in self?.childDidTerminate(terminated) }
        }
        do {
            try child.run()
            process = child
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            errorPipe = nil
            state = .failed("failed to start luan CLI: \(error.localizedDescription)")
            closeCaptureWindow()
            return
        }

        startHealthcheck(host: host, port: port)
        startMetricsSampling(host: host, port: port, token: env["STATUS_TOKEN"] ?? "")
    }

    func stop() {
        guard canStop, let child = process else { return }
        state = .stopping
        stopHealthcheck()
        closeCaptureWindow()
        child.terminate()
        stopTimeoutTask?.cancel()
        stopTimeoutTask = Task { @MainActor [weak self, weak child] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, let child, child.isRunning else { return }
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
            self.stopTimeoutTask = nil
        }
    }

    /// Synchronously terminate the child before the app process exits. Async
    /// cleanup tasks are not reliable once NSApplication is terminating.
    func terminateForAppExit() {
        guard let child = process, child.isRunning else { return }
        state = .stopping
        stopHealthcheck()
        stopMetricsSampling()
        closeCaptureWindow()
        child.terminate()
        usleep(250_000)
        if child.isRunning {
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }

    private func consumeChildOutput(_ chunk: String) {
        for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let text = String(line)
            appendChildLog(text + "\n")
            captureStartupDiag(text)
        }
    }

    private func appendChildLog(_ text: String) {
        guard !logPath.isEmpty else { return }
        let url = URL(fileURLWithPath: logPath)
        let data = Data(text.utf8)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func parseMetrics(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let value = object["cpu_percent"] as? NSNumber { cpuNow = value.doubleValue }
        if let value = object["rss_bytes"] as? NSNumber { rssNowMB = value.doubleValue / (1024.0 * 1024.0) }
        if let value = object["lua_memory_kb"] as? NSNumber, value.doubleValue > 0 { luaNowMB = value.doubleValue / 1024.0 }
    }

    private func childDidTerminate(_ child: Process) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        process = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        stopHealthcheck()
        stopMetricsSampling()
        let diag = consumeStartupDiag()
        switch state {
        case .stopping:
            state = .idle
        case .starting:
            state = .failed(diag ?? String(localized: "native.status.startFailed"))
        case .running:
            state = child.terminationStatus == 0 ? .idle : .failed(diag ?? "luan exited with status \(child.terminationStatus)")
        default:
            break
        }
    }

    // MARK: - Healthcheck (主动 ping 替代 stdout sniff)

    private func startHealthcheck(host: String, port: Int) {
        stopHealthcheck()
        guard port > 0 else { return }

        // host 是 bind 地址 (可能是 0.0.0.0 或空); ping 的时候用 127.0.0.1
        let pingHost = (host.isEmpty || host == "0.0.0.0" || host == "::") ? "127.0.0.1" : host
        guard let url = URL(string: "http://\(pingHost):\(port)/") else { return }

        healthcheckTask = Task { [weak self] in
            // 给 lua 一小段时间起来再开始 ping, 避免一上来就刷一堆 ECONNREFUSED
            try? await Task.sleep(nanoseconds: 200_000_000)
            let session = URLSession(configuration: .ephemeral)
            session.configuration.timeoutIntervalForRequest = 1.0
            session.configuration.timeoutIntervalForResource = 1.0
            defer { session.invalidateAndCancel() }

            while !Task.isCancelled {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                req.timeoutInterval = 1.0

                let alive: Bool
                do {
                    let (_, resp) = try await session.data(for: req)
                    // 只要有响应就算服务活了 — 任何 HTTP 状态码都说明 httpd 已 bind
                    alive = (resp as? HTTPURLResponse) != nil
                } catch {
                    alive = false
                }

                if alive {
                    await MainActor.run {
                        guard let me = self else { return }
                        if case .starting = me.state {
                            me.boundHost = pingHost
                            me.boundPort = port
                            me.state = .running
                            // Service came up — close diag capture so
                            // outputHandler stops scanning every chunk.
                            me.closeCaptureWindow()
                        }
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func stopHealthcheck() {
        healthcheckTask?.cancel()
        healthcheckTask = nil
    }

    // MARK: - Metrics sampling (authenticated Lua status API)

    private func startMetricsSampling(host: String, port: Int, token: String) {
        stopMetricsSampling()
        guard port > 0, !token.isEmpty else { return }
        let statusHost = (host.isEmpty || host == "0.0.0.0" || host == "::") ? "127.0.0.1" : host
        guard let url = URL(string: "http://\(statusHost):\(port)/_status") else { return }
        metricsTask = Task { [weak self] in
            let session = URLSession(configuration: .ephemeral)
            session.configuration.timeoutIntervalForRequest = 1.0
            session.configuration.timeoutIntervalForResource = 1.0
            defer { session.invalidateAndCancel() }
            while !Task.isCancelled {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 1.0
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let (data, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    await MainActor.run { [weak self] in self?.parseMetrics(data) }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopMetricsSampling() {
        metricsTask?.cancel()
        metricsTask = nil
        cpuNow = nil
        rssNowMB = nil
        luaNowMB = nil
        refCount = 0
    }
}
