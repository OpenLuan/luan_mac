import SwiftUI
import AppKit

@main
struct LuanMacApp: App {
    @AppStorage("uiLanguage") private var uiLanguage: String = "system"
    @StateObject private var nativeChromeMCP = NativeChromeMCP()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        enforceSingleInstance()
    }

    /// App lifecycle glue: tear down the native Chrome MCP (listener + the
    /// app-managed Chrome it spawned) when the app quits, so no orphan Chrome
    /// keeps running on 9222 after us.
    ///
    /// Note: the delegate cannot reach the MCP through
    /// `(NSApplication.shared.delegate as? LuanMacApp)` — LuanMacApp is a
    /// SwiftUI `App` struct and the runtime delegate is this AppDelegate
    /// object, so that cast always fails. Instead the root view hands the MCP
    /// to the delegate in `onAppear` (long before any user quit).
    final class AppDelegate: NSObject, NSApplicationDelegate {
        var nativeChromeMCP: NativeChromeMCP?

        func applicationWillTerminate(_ notification: Notification) {
            if let mcp = nativeChromeMCP {
                mcp.stop(killChrome: mcp.terminateChromeOnQuit)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(uiLanguage: $uiLanguage)
                .environmentObject(nativeChromeMCP)
                .environment(\.locale, selectedLocale)
                .id(uiLanguage)
                .frame(minWidth: 360, minHeight: 400)
                .onAppear {
                    // Hand the MCP to the lifecycle delegate so it can tear
                    // down the app-managed Chrome on quit.
                    appDelegate.nativeChromeMCP = nativeChromeMCP
                }
        }
        .windowResizability(.contentSize)
    }

    /// Debug runs (Xcode "Run" without stopping, snippets, manual launches)
    /// can leave multiple app instances alive. The native MCP binds a fixed
    /// loopback port, so extra instances would fail with "Address already in
    /// use". Activate the existing instance and quit instead of starting a
    /// second one.
    private func enforceSingleInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.luanmac.LuanMac"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows])
            print("[NativeChromeMCP] \(Date()) another instance already running (pid \(existing.processIdentifier)); activating it and quitting")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private var selectedLocale: Locale {
        if uiLanguage == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return .autoupdatingCurrent
        }
        UserDefaults.standard.set([uiLanguage], forKey: "AppleLanguages")
        return Locale(identifier: uiLanguage)
    }
}
