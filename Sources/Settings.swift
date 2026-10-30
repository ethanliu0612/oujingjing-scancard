import AppKit
import Translation

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private let keyField = NSSecureTextField()
    private let baseField = NSTextField()
    private let modelField = NSTextField()
    private let stylePopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private let glossaryView = NSTextView()
    private let testLabel = NSTextField(labelWithString: "")
    private let permissionLabel = NSTextField(labelWithString: "")
    private var loadedKey = ""
    private let localStatusLabel = NSTextField(labelWithString: "检测中…")

    private override init() { super.init() }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = "扫描卡 · 设置"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.appearance = NSAppearance(named: .darkAqua)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "翻译引擎")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        root.addArrangedSubview(title)

        keyField.placeholderString = "sk-…（保存在系统钥匙串）"
        keyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        keyField.delegate = self
        root.addArrangedSubview(row("API Key", keyField, width: 140))

        baseField.placeholderString = "https://api.deepseek.com"
        baseField.delegate = self
        root.addArrangedSubview(row("接口地址", baseField, width: 140))

        modelField.placeholderString = "deepseek-chat"
        modelField.delegate = self
        root.addArrangedSubview(row("模型", modelField, width: 140))

        stylePopup.addItems(withTitles: ["流畅学术（推荐）", "贴近原文直译"])
        stylePopup.target = self
        stylePopup.action = #selector(saveFields)
        stylePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        root.addArrangedSubview(row("翻译风格", stylePopup, width: 140))

        languagePopup.addItems(withTitles: ["英文（推荐，最准）", "英文 + 中文（混排文档）"])
        languagePopup.target = self
        languagePopup.action = #selector(saveFields)
        languagePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        root.addArrangedSubview(row("识别语言", languagePopup, width: 140))

        let testButton = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
        testButton.bezelStyle = .rounded
        testLabel.font = NSFont.systemFont(ofSize: 11.5)
        testLabel.textColor = .secondaryLabelColor
        testLabel.lineBreakMode = .byWordWrapping
        testLabel.maximumNumberOfLines = 2
        let testRow = NSStackView(views: [testButton, testLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 10
        root.addArrangedSubview(row("", testRow, width: 140))

        let glossaryTitle = NSTextField(labelWithString: "术语表（每行一条：英文 = 中文，可显著提升专业术语准确度）")
        glossaryTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        glossaryTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(glossaryTitle)

        glossaryView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        glossaryView.isRichText = false
        glossaryView.isAutomaticQuoteSubstitutionEnabled = false
        glossaryView.drawsBackground = true
        glossaryView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        glossaryView.textContainerInset = NSSize(width: 8, height: 6)
        let glossaryScroll = NSScrollView()
        glossaryScroll.documentView = glossaryView
        glossaryScroll.hasVerticalScroller = true
        glossaryScroll.borderType = .bezelBorder
        glossaryScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        glossaryScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(glossaryScroll)
        glossaryScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
        root.addArrangedSubview(spacer)

        let permTitle = NSTextField(labelWithString: "权限")
        permTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        permTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(permTitle)

        permissionLabel.font = NSFont.systemFont(ofSize: 12)
        permissionLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(permissionLabel)

        let permButton = NSButton(title: "打开屏幕录制设置", target: self, action: #selector(openPermission))
        permButton.bezelStyle = .rounded
        root.addArrangedSubview(permButton)

        let localTitle = NSTextField(labelWithString: "离线兜底")
        localTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        localTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(localTitle)

        localStatusLabel.font = NSFont.systemFont(ofSize: 12)
        localStatusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(localStatusLabel)

        let downloadButton = NSButton(title: "下载系统翻译语言包（打开「翻译」App）",
                                      target: self, action: #selector(openTranslateApp))
        downloadButton.bezelStyle = .rounded
        root.addArrangedSubview(downloadButton)

        let hint = NSTextField(labelWithString: "全局快捷键 ⌥⌘S：在任意应用中框选英文区域，松手即翻译。\n结果卡片：⌘C 复制 · O 切换原文 · ⌘R 重译 · Esc 关闭。")
        hint.font = NSFont.systemFont(ofSize: 11.5)
        hint.textColor = NSColor.secondaryLabelColor
        hint.maximumNumberOfLines = 3
        root.addArrangedSubview(hint)

        win.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: win.contentView!.topAnchor, constant: 22),
        ])

        win.layoutIfNeeded()
        let fit = root.fittingSize
        win.setContentSize(NSSize(width: 560, height: max(fit.height + 46, 520)))
        window = win
    }

    private func row(_ label: String, _ control: NSView, width: CGFloat) -> NSStackView {
        let name = NSTextField(labelWithString: label)
        name.font = NSFont.systemFont(ofSize: 12.5)
        name.textColor = .labelColor
        name.alignment = .right
        name.widthAnchor.constraint(equalToConstant: 82).isActive = true
        let stack = NSStackView(views: [name, control])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func loadValues() {
        loadedKey = SecretStore.load() ?? ""
        keyField.stringValue = loadedKey
        baseField.stringValue = Pref.baseURL
        modelField.stringValue = Pref.model
        stylePopup.selectItem(at: Pref.style == "literal" ? 1 : 0)
        languagePopup.selectItem(at: Pref.ocrLanguages.contains("zh") ? 1 : 0)
        glossaryView.string = Pref.glossary
        updatePermissionLabel()
        testLabel.stringValue = ""
        refreshLocalStatus()
    }

    private func refreshLocalStatus() {
        guard #available(macOS 15.0, *) else {
            localStatusLabel.stringValue = "需要 macOS 15 或更新系统"
            return
        }
        Task { @MainActor in
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: "en"),
                to: Locale.Language(identifier: "zh-Hans"))
            switch status {
            case .installed:
                localStatusLabel.stringValue = "✅ 语言包已安装，断网时可用"
                localStatusLabel.textColor = .systemGreen
            case .supported:
                localStatusLabel.stringValue = "⚠️ 语言包未下载，断网或没 key 时无法兜底"
                localStatusLabel.textColor = .systemOrange
            default:
                localStatusLabel.stringValue = "⚠️ 当前系统不支持英译中"
                localStatusLabel.textColor = .systemOrange
            }
        }
    }

    @objc private func openTranslateApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Translate.app"))
    }

    private func updatePermissionLabel() {
        let ok = CGPreflightScreenCaptureAccess()
        permissionLabel.stringValue = ok
            ? "✅ 屏幕录制权限已开启"
            : "⚠️ 尚未授权屏幕录制，框选会失败"
        permissionLabel.textColor = ok ? .systemGreen : .systemOrange
    }

    @objc private func saveFields() {
        let newKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newKey != loadedKey {
            if newKey.isEmpty {
                SecretStore.delete()
            } else {
                SecretStore.save(newKey)
            }
            loadedKey = newKey
        }
        if !baseField.stringValue.isEmpty { Pref.baseURL = baseField.stringValue }
        if !modelField.stringValue.isEmpty { Pref.model = modelField.stringValue }
        Pref.style = stylePopup.indexOfSelectedItem == 1 ? "literal" : "fluent"
        Pref.ocrLanguages = languagePopup.indexOfSelectedItem == 1 ? "en-US,zh-Hans" : "en-US"
        Pref.glossary = glossaryView.string
        updatePermissionLabel()
    }

    @objc private func testConnection() {
        saveFields()
        testLabel.textColor = .secondaryLabelColor
        testLabel.stringValue = "测试中…"
        Task { @MainActor in
            let result = await Translators.test()
            testLabel.stringValue = result
            testLabel.textColor = result.hasPrefix("✅") ? .systemGreen : .systemRed
        }
    }

    @objc private func openPermission() {
        PermissionGuide.openScreenRecordingSettings()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        saveFields()
    }

    func windowWillClose(_ notification: Notification) {
        saveFields()
    }
}
