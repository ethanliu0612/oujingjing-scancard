import AppKit

enum PermissionGuide {
    private static var pollTimer: Timer?

    /// 授权后自动重启（macOS 必须重启进程权限才生效）。
    /// 只轮询，不再弹第二个对话框，避免和系统授权框打架。
    static func watchAndRestartWhenGranted() {
        guard pollTimer == nil else { return }
        Log.write("watching for screen recording grant")
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            if CGPreflightScreenCaptureAccess() {
                stopPolling()
                Log.write("permission detected, auto restarting")
                restartApp()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        // 两分钟后放弃轮询，避免长驻
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if pollTimer === timer { stopPolling() }
        }
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "扫描卡需要「屏幕录制」权限"
        alert.informativeText = """
        框选翻译要读取屏幕画面。

        1. 点下面的「打开系统设置」
        2. 在 隐私与安全性 › 屏幕与系统音频录制 里打开「扫描卡」
        3. 回来即可 —— 检测到授权后会自动重启生效

        授权完成后，按 ⌥⌘S 就能框选了。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        // 在弹窗期间轮询权限；一旦用户在系统设置里勾上，自动重启
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            if CGPreflightScreenCaptureAccess() {
                stopPolling()
                Log.write("permission detected, auto restarting")
                restartApp()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        let response = alert.runModal()
        stopPolling()
        if response == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    private static func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// macOS 要求授权后重启进程才生效，这里帮忙自动重启。
    static func restartApp() {
        Log.write("restarting app for permission")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.abortModal()
            NSApp.terminate(nil)
        }
        // 万一模态拦住退出，兜底硬退
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            exit(0)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
