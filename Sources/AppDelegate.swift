import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var permissionItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()

        HotKeyCenter.shared.onTrigger = {
            Log.write("hotkey fired -> begin selection")
            SelectionController.shared.begin()
        }
        let status = HotKeyCenter.shared.register()
        Log.write("launch: bundle=\(Bundle.main.bundlePath) pid=\(ProcessInfo.processInfo.processIdentifier) "
                  + "screenPerm=\(CGPreflightScreenCaptureAccess()) key=\(Translators.hasKey()) hotkeyStatus=\(status)")
        if status != noErr {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let alert = NSAlert()
                alert.messageText = "快捷键 ⌥⌘S 注册失败（\(status)）"
                alert.informativeText = "可能被其他应用占用。可以从菜单栏图标里点「框选翻译」，或重启电脑后再试。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }

        if !Pref.didOnboard {
            Pref.didOnboard = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showWelcome()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "扫描卡")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "扫描卡 · \(HotKeyText) 框选翻译"
        }

        let menu = NSMenu()
        menu.addItem(menuItem(title: "框选翻译", action: #selector(startCapture), key: "s", modifiers: [.command, .option]))
        menu.addItem(menuItem(title: "重新翻译上一次", action: #selector(retranslate), key: "r", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "设置…", action: #selector(openSettings), key: ",", modifiers: [.command]))
        let permItem = menuItem(title: "屏幕录制权限…", action: #selector(openPermission))
        permissionItem = permItem
        menu.addItem(permItem)
        menu.addItem(menuItem(title: "使用说明", action: #selector(showHelp)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "退出扫描卡", action: #selector(quit), key: "q", modifiers: [.command]))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let ok = CGPreflightScreenCaptureAccess()
        permissionItem?.title = ok ? "屏幕录制权限：已开启 ✓" : "屏幕录制权限：未开启 ⚠️"
        statusItem.button?.toolTip = ok
            ? "扫描卡 · \(HotKeyText) 框选翻译"
            : "扫描卡 · 还没给屏幕录制权限，点这里处理"
    }

    @objc private func startCapture() {
        SelectionController.shared.begin()
    }

    @objc private func retranslate() {
        CardController.shared.retranslate()
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func openPermission() {
        PermissionGuide.show()
    }

    @objc private func showHelp() {
        CardController.shared.showMessage(
            title: "使用说明",
            body: """
            1. 在任意应用里按 ⌥⌘S
            2. 拖拽框选一块英文区域，松手即开始识别
            3. 翻译结果会以小卡片出现在选区旁边

            卡片快捷键：⌘C 复制、O 切换原文、⌘R 重译、Esc 关闭。
            选中译文里的某个词再点「词典」，会送到欧路词典查词。

            准确度小贴士：框选时尽量避开页边、页码和多栏混排；在设置里补充术语表，专业名词会更稳。
            """,
            hint: "菜单栏的取景器图标里可以随时回到设置。"
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showWelcome() {
        let hasKey = Translators.hasKey()
        var body = """
        按 ⌥⌘S，在任意应用（PDF、网页、Word）上拖一个框，松手就会自动识别英文并翻译成中文，结果卡片就贴在选区旁边。

        第一次使用需要允许「屏幕录制」权限：系统设置 › 隐私与安全性 › 屏幕与系统音频录制。
        """
        if !hasKey {
            body += "\n\n还差一步：在菜单栏图标 ›「设置…」里填入 DeepSeek API Key。"
        }
        CardController.shared.showMessage(title: "扫描卡已就绪", body: body,
                                          hint: "快捷键 \(HotKeyText) · 卡片里 ⌘C 直接复制译文")
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}
