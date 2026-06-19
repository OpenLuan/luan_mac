import Foundation
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

    private let bridge = LuaBridge()
    private var healthcheckTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?

    // Startup diagnostics captured from bridge.outputHandler on the bridge
    // thread. Consumed after bridge.run returns to surface .failed(msg) when
    // healthcheck never flipped the state to .running.
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

    private init() {
        bridge.outputHandler = { [weak self] chunk in
            LuanLogWrite(chunk)
            self?.captureStartupDiag(chunk)
        }
    }

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
        guard canStart else { return }
        state = .starting
        boundHost = ""
        boundPort = 0
        // Reset diagnostics from any previous failed run and open the
        // capture window. captureStartupDiag is a no-op outside this
        // window, so we don't scan every print/stderr chunk once the
        // service is stable.
        diagLock.lock(); startupDiag.removeAll(keepingCapacity: false); diagLock.unlock()
        openCaptureWindow(seconds: LuaRunner.defaultCaptureWindowSec)
        let dir = (documentRoot as NSString).expandingTildeInPath
        let host = env["SERVICE_HOST"] ?? ""
        let port = Int(env["SERVICE_PORT"] ?? "") ?? 0
        logPath = dir + "/luan.log"

        startHealthcheck(host: host, port: port)
        startMetricsSampling()

        Task.detached(priority: .userInitiated) { [bridge] in
            bridge.run(withDocumentRoot: dir, env: env)
            await MainActor.run {
                let me = LuaRunner.shared
                me.stopHealthcheck()
                me.stopMetricsSampling()
                // If bridge.run returned while we were still .starting, the
                // Lua entry never reached fan.loop (e.g. port bind failed,
                // syntax error). Surface captured diagnostics as .failed —
                // otherwise the UI silently flips back to idle.
                let diag = me.consumeStartupDiag()
                switch me.state {
                case .stopping:
                    me.state = .idle
                case .starting:
                    me.state = .failed(diag ?? String(localized: "native.status.startFailed"))
                case .running:
                    me.state = .idle
                default:
                    break
                }
            }
        }
    }

    func stop() {
        guard canStop else { return }
        state = .stopping
        stopHealthcheck()
        // Belt-and-suspenders: normally already closed when we hit
        // .running, but stop() from any state should also disable it.
        closeCaptureWindow()
        bridge.stop()
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

    // MARK: - Metrics sampling (CPU% / RSS / Lua VM 内存)

    private func startMetricsSampling() {
        stopMetricsSampling()
        // 先打一次 CPU 基线 — 不存到 history, 仅消耗第一次返回的 0.
        _ = LuaBridge.currentCPUPercent()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self = self else { return }
                await MainActor.run { self.tickMetrics() }
            }
        }
    }

    private func stopMetricsSampling() {
        metricsTask?.cancel()
        metricsTask = nil
        cpuNow = nil
        rssNowMB = nil
        luaNowMB = nil
    }

    private func tickMetrics() {
        guard isRunning else { return }
        let cpu = LuaBridge.currentCPUPercent()
        let rssMB = Double(LuaBridge.currentRSSBytes()) / (1024.0 * 1024.0)
        let luaKB = LuaBridge.currentLuaMemKB()
        let luaMB = Double(luaKB) / 1024.0
        cpuNow = cpu
        rssNowMB = rssMB
        luaNowMB = luaKB > 0 ? luaMB : nil
        refCount = Int(bridge.refCount())
    }
}
