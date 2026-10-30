import AppKit

final class CardPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRetranslate: (() -> Void)?
    var onToggleOriginal: (() -> Void)?
    var onDictionary: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
        case 31: // o
            if !event.modifierFlags.contains(.command) { onToggleOriginal?() }
        case 49: // space
            onToggleOriginal?()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            onCopy?()
            return true
        case "r":
            onRetranslate?()
            return true
        case "e":
            onDictionary?()
            return true
        case "w":
            onCancel?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

@MainActor
final class CardController {
    static let shared = CardController()

    private var panel: CardPanel?
    private var card: CardView?
    private var previousApp: NSRunningApplication?
    private var anchor: CGRect = .zero
    private var lastOriginal: String?
    private var lastTranslation: String?
    private var pipelineToken = 0
    private var currentTask: Task<Void, Never>?

    private init() {}

    // MARK: - 公开入口

    func beginPipeline(image: CGImage, anchor: CGRect, shot: DisplayShot) {
        previousApp = NSWorkspace.shared.frontmostApplication
        self.anchor = anchor
        pipelineToken += 1
        let token = pipelineToken
        currentTask?.cancel()

        let width = min(max(anchor.width, 400), 560)
        show(width: width)
        card?.showLoading("正在识别文字…", original: nil)
        layoutAndShow()

        let languages = Pref.ocrLanguages
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        currentTask = Task { @MainActor in
            do {
                let ocr = try await OCR.recognize(image: image,
                                                  languages: languages.isEmpty ? ["en-US"] : languages)
                guard token == self.pipelineToken else { return }
                self.lastOriginal = ocr.text
                let preview = ocr.text.count > 240 ? String(ocr.text.prefix(240)) + "…" : ocr.text
                self.card?.showLoading("正在翻译…", original: preview)
                self.layoutAndShow()

                let output = try await Translators.translate(ocr.text)
                guard token == self.pipelineToken else { return }
                self.lastTranslation = output.text
                self.card?.showTranslation(output.text, engine: output.engine,
                                           elapsed: output.elapsed, original: ocr.text)
                self.layoutAndShow()
            } catch is CancellationError {
                // 用户关闭了卡片
            } catch {
                guard token == self.pipelineToken else { return }
                self.card?.showError(self.describe(error), hint: self.hint(for: error))
                self.layoutAndShow()
            }
        }
    }

    func retranslate() {
        guard let text = lastOriginal, !text.isEmpty else { return }
        pipelineToken += 1
        let token = pipelineToken
        currentTask?.cancel()
        card?.showLoading("正在重译…", original: text)
        layoutAndShow()
        currentTask = Task { @MainActor in
            do {
                let output = try await Translators.translate(text)
                guard token == self.pipelineToken else { return }
                self.lastTranslation = output.text
                self.card?.showTranslation(output.text, engine: output.engine,
                                           elapsed: output.elapsed, original: text)
                self.layoutAndShow()
            } catch {
                guard token == self.pipelineToken else { return }
                self.card?.showError(self.describe(error), hint: self.hint(for: error))
                self.layoutAndShow()
            }
        }
    }

    func showMessage(title: String, body: String, hint: String?) {
        previousApp = NSWorkspace.shared.frontmostApplication
        pipelineToken += 1
        currentTask?.cancel()
        anchor = anchorForCenter()
        show(width: 420)
        card?.showMessage(title: title, body: body, hint: hint)
        layoutAndShow()
    }

    func close() {
        currentTask?.cancel()
        currentTask = nil
        pipelineToken += 1
        panel?.orderOut(nil)
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    // MARK: - 内部

    private func show(width: CGFloat) {
        if panel == nil {
            let p = CardPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.animationBehavior = .none

            let v = CardView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
            v.onClose = { [weak self] in self?.close() }
            v.onCopy = { [weak self] in self?.card?.copyTranslation() }
            v.onEudic = { [weak self] in self?.openDictionary() }
            p.contentView = v

            p.onCancel = { [weak self] in self?.close() }
            p.onCopy = { [weak self] in self?.card?.copyTranslation() }
            p.onRetranslate = { [weak self] in self?.retranslate() }
            p.onToggleOriginal = { [weak self] in self?.card?.toggleOriginal(); self?.layoutAndShow() }
            p.onDictionary = { [weak self] in self?.openDictionary() }

            panel = p
            card = v
        } else {
            card?.cardWidth = width
        }
    }

    private func layoutAndShow() {
        guard let panel, let card else { return }
        card.frame.size.width = card.cardWidth
        card.relayout()
        let size = card.frame.size
        let screen = screenFor(anchor)
        let visible = screen.visibleFrame

        var x = anchor.minX
        if x + size.width > visible.maxX - 8 { x = visible.maxX - size.width - 8 }
        x = max(x, visible.minX + 8)

        var y = anchor.minY - size.height - 10
        if y < visible.minY + 8 {
            y = anchor.maxY + 10
        }
        if y + size.height > visible.maxY - 8 {
            y = visible.maxY - size.height - 8
        }
        y = max(y, visible.minY + 8)

        let target = NSRect(x: x, y: y, width: size.width, height: size.height)
        let firstShow = !panel.isVisible

        panel.setFrame(target, display: true)
        card.frame = NSRect(origin: .zero, size: size)
        card.relayout()

        if firstShow {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.makeKey()
        }
    }

    private func screenFor(_ rect: CGRect) -> NSScreen {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func anchorForCenter() -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let frame = screen.visibleFrame
        return CGRect(x: frame.midX - 200, y: frame.midY, width: 400, height: 1)
    }

    private func openDictionary() {
        guard let query = card?.dictionaryQuery(), !query.isEmpty else { return }
        let word = query.count > 80 ? String(query.prefix(80)) : query
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        let encoded = word.addingPercentEncoding(withAllowedCharacters: allowed) ?? word

        if let url = URL(string: "eudic://dict/\(encoded)") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                if error != nil {
                    Self.runEudicScript(word)
                }
            }
        } else {
            Self.runEudicScript(word)
        }
    }

    private static func runEudicScript(_ word: String) {
        let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application id \"com.eusoft.freeeudic\" to show dic with word \"\(escaped)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? TranslateError { return e.errorDescription ?? "翻译失败" }
        if let e = error as? OCRError { return e.errorDescription ?? "识别失败" }
        if let e = error as? CaptureError { return e.errorDescription ?? "截屏失败" }
        return error.localizedDescription
    }

    private func hint(for error: Error) -> String? {
        if let e = error as? TranslateError {
            switch e {
            case .noKey, .unauthorized:
                return "菜单栏图标 › 设置… 里填入 DeepSeek API Key 即可。"
            case .insufficientBalance:
                return "请到 platform.deepseek.com 充值后重试。"
            case .localUnavailable:
                return "打开 系统设置 › 通用 › 语言与地区 › 翻译语言，下载「中文（简体）」语言包。"
            default:
                return nil
            }
        }
        if error is OCRError {
            return "选中区域里如果没有清晰文字，就会识别失败。"
        }
        return nil
    }
}
