import AppKit
import QuartzCore

// MARK: - 卡片按钮

final class CardButton: NSButton {
    private var tracking: NSTrackingArea?

    convenience init(symbol: String, title: String? = nil, action: Selector?, target: AnyObject?) {
        self.init()
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = Palette.textSecondary
        let attrs = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            let attachment = NSTextAttachment()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            attachment.image = image.withSymbolConfiguration(config)
            attrs.append(NSAttributedString(attachment: attachment))
        }
        if let title {
            if attrs.length > 0 { attrs.append(NSAttributedString(string: " ")) }
            attrs.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: Palette.textSecondary,
            ]))
        }
        attributedTitle = attrs
        imagePosition = .imageLeading
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - 卡片视图

final class CardView: NSView {
    private let headerLabel = NSTextField(labelWithString: "英 → 中")
    private let engineLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let bodyScroll = NSScrollView()
    private let bodyText = NSTextView()
    private let originalScroll = NSScrollView()
    private let originalText = NSTextView()
    private let originalTitle = NSTextField(labelWithString: "原文")
    private let separator = NSView()
    private var eudicButton: CardButton!
    private var copyButton: CardButton!
    private var closeButton: CardButton!

    private let scanBand = CAGradientLayer()

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onEudic: (() -> Void)?

    var cardWidth: CGFloat = 420
    private var translationText: String?
    private var originalString: String?
    private var isLoading = false
    private var errorText: String?
    private var hintText: String?
    private var showOriginal = true
    private var messageMode = false
    private var messageBody = ""

    private let pad: CGFloat = 18
    private let headerH: CGFloat = 24
    private let gap: CGFloat = 12
    private let footerH: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true


        headerLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = Palette.textSecondary
        headerLabel.isEditable = false
        headerLabel.isBordered = false
        headerLabel.drawsBackground = false
        addSubview(headerLabel)

        engineLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        engineLabel.textColor = Palette.accent
        engineLabel.alignment = .right
        addSubview(engineLabel)

        configureTextView(bodyText, in: bodyScroll)
        configureTextView(originalText, in: originalScroll)
        addSubview(bodyScroll)
        addSubview(originalScroll)
        addSubview(separator)
        addSubview(originalTitle)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = Palette.separator.cgColor

        originalTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        originalTitle.textColor = NSColor(white: 0.52, alpha: 1)
        addSubview(originalTitle)

        footerLabel.font = NSFont.systemFont(ofSize: 10.5)
        footerLabel.textColor = NSColor(white: 0.42, alpha: 1)
        addSubview(footerLabel)

        closeButton = CardButton(symbol: "xmark", title: nil, action: #selector(closeTapped), target: self)
        copyButton = CardButton(symbol: "doc.on.doc", title: "复制", action: #selector(copyTapped), target: self)
        eudicButton = CardButton(symbol: "character.book.closed", title: "词典", action: #selector(eudicTapped), target: self)
        addSubview(closeButton)
        addSubview(copyButton)
        addSubview(eudicButton)

        scanBand.colors = [NSColor.clear.cgColor,
                           Palette.accent.withAlphaComponent(0.28).cgColor,
                           NSColor.clear.cgColor]
        scanBand.startPoint = CGPoint(x: 0, y: 0.5)
        scanBand.endPoint = CGPoint(x: 1, y: 0.5)
        scanBand.isHidden = true
        layer?.addSublayer(scanBand)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        path.addClip()
        NSGradient(colors: [Palette.cardTop, Palette.cardBottom])?.draw(in: bounds, angle: -90)

        // 顶部一条极细高光
        NSColor(white: 1, alpha: 0.07).setStroke()
        let top = NSBezierPath()
        top.move(to: NSPoint(x: 14, y: bounds.maxY - 0.5))
        top.line(to: NSPoint(x: bounds.maxX - 14, y: bounds.maxY - 0.5))
        top.lineWidth = 1
        top.stroke()
    }

    private func configureTextView(_ textView: NSTextView, in scroll: NSScrollView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.selectedTextAttributes = [
            .backgroundColor: Palette.accent.withAlphaComponent(0.35),
            .foregroundColor: NSColor.white,
        ]

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        scroll.borderType = .noBorder
        scroll.appearance = NSAppearance(named: .darkAqua)
    }

    // MARK: - 状态

    func showLoading(_ status: String, original: String?) {
        translationText = nil
        errorText = nil
        hintText = nil
        messageMode = false
        isLoading = true
        originalString = original
        headerLabel.stringValue = "英 → 中"
        engineLabel.stringValue = ""
        footerLabel.stringValue = status
        startScanning()
        relayout()
    }

    func showTranslation(_ text: String, engine: String, elapsed: TimeInterval, original: String) {
        translationText = text
        originalString = original
        errorText = nil
        hintText = nil
        messageMode = false
        isLoading = false
        headerLabel.stringValue = "英 → 中"
        engineLabel.stringValue = "\(engine) · \(String(format: "%.1f", elapsed))s"
        stopScanning()
        relayout()
    }

    func showError(_ message: String, hint: String?) {
        translationText = nil
        isLoading = false
        messageMode = false
        errorText = message
        hintText = hint
        engineLabel.stringValue = "失败"
        stopScanning()
        relayout()
    }

    func showMessage(title: String, body: String, hint: String?) {
        translationText = nil
        isLoading = false
        errorText = nil
        messageMode = true
        messageBody = body
        hintText = hint
        headerLabel.stringValue = title
        engineLabel.stringValue = ""
        stopScanning()
        relayout()
    }

    func toggleOriginal() {
        showOriginal.toggle()
        relayout()
    }

    var hasTranslation: Bool { translationText != nil }

    func copyTranslation() {
        guard let text = translationText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        footerLabel.stringValue = "✓ 已复制"
        footerLabel.textColor = Palette.accent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.footerLabel.textColor = NSColor(white: 0.42, alpha: 1)
            self.updateFooter()
        }
    }

    func dictionaryQuery() -> String? {
        let range = bodyText.selectedRange()
        if range.length > 0, range.location != NSNotFound {
            return (bodyText.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return originalString?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 布局

    func relayout() {
        let width = cardWidth
        let contentW = width - pad * 2

        var bodyH: CGFloat = 0
        var bodyMeasure: CGFloat = 0
        var bodyAttrs: NSAttributedString?
        var origH: CGFloat = 0
        var origMeasure: CGFloat = 0
        var origAttrs: NSAttributedString?
        var showsOriginalBlock = false

        if isLoading {
            bodyH = 6
        } else if let errorText {
            let attrs = NSAttributedString(string: errorText, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor(srgbRed: 1.0, green: 0.58, blue: 0.52, alpha: 1),
                .paragraphStyle: lineStyle(3),
            ])
            bodyAttrs = attrs
            bodyMeasure = TypeSet.measure(attrs, width: contentW)
            bodyH = min(max(bodyMeasure, 18), 240)
            if let hintText, !hintText.isEmpty {
                let a = TypeSet.original(hintText, size: 11.5)
                origAttrs = a
                origMeasure = TypeSet.measure(a, width: contentW)
                origH = min(origMeasure, 120)
                showsOriginalBlock = true
            }
        } else if let translationText {
            let attrs = TypeSet.body(translationText, size: CGFloat(Pref.fontSize))
            bodyAttrs = attrs
            bodyMeasure = TypeSet.measure(attrs, width: contentW)
            bodyH = min(max(bodyMeasure, 18), 300)
            if showOriginal, let originalString, !originalString.isEmpty {
                let a = TypeSet.original(originalString, size: CGFloat(Pref.fontSize))
                origAttrs = a
                origMeasure = TypeSet.measure(a, width: contentW)
                origH = min(origMeasure, 130)
                showsOriginalBlock = true
            }
        } else if messageMode {
            let attrs = NSAttributedString(string: messageBody, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: Palette.textPrimary,
                .paragraphStyle: lineStyle(3.5),
            ])
            bodyAttrs = attrs
            bodyMeasure = TypeSet.measure(attrs, width: contentW)
            bodyH = min(max(bodyMeasure, 18), 320)
            if let hintText, !hintText.isEmpty {
                let a = TypeSet.original(hintText, size: 11.5)
                origAttrs = a
                origMeasure = TypeSet.measure(a, width: contentW)
                origH = min(origMeasure, 140)
                showsOriginalBlock = true
            }
        }

        let origBlock: CGFloat = showsOriginalBlock ? (14 + 13 + 6 + origH) : 0
        let totalH = pad + headerH + gap + bodyH + origBlock + 12 + footerH + pad
        let topY = totalH - pad

        headerLabel.sizeToFit()
        headerLabel.frame = NSRect(x: pad, y: topY - 19, width: 78, height: 17)

        closeButton.sizeToFit()
        closeButton.frame = NSRect(x: width - pad - 24, y: topY - headerH, width: 24, height: 24)
        copyButton.sizeToFit()
        let copyW = max(copyButton.intrinsicContentSize.width, 48)
        copyButton.frame = NSRect(x: closeButton.frame.minX - 8 - copyW, y: topY - headerH, width: copyW, height: 24)
        eudicButton.sizeToFit()
        let eudicW = max(eudicButton.intrinsicContentSize.width, 52)
        eudicButton.frame = NSRect(x: copyButton.frame.minX - 8 - eudicW, y: topY - headerH, width: eudicW, height: 24)

        let engineW = max(0, eudicButton.frame.minX - (pad + 84) - 8)
        engineLabel.frame = NSRect(x: pad + 84, y: topY - 17, width: engineW, height: 14)
        engineLabel.isHidden = engineLabel.stringValue.isEmpty

        let bodyTop = topY - headerH - gap
        if let bodyAttrs {
            bodyScroll.isHidden = false
            bodyScroll.frame = NSRect(x: pad, y: bodyTop - bodyH, width: contentW, height: bodyH)
            bodyText.textStorage?.setAttributedString(bodyAttrs)
            bodyText.textContainer?.containerSize = NSSize(width: contentW, height: .greatestFiniteMagnitude)
            bodyText.frame = NSRect(x: 0, y: 0, width: contentW, height: max(bodyMeasure, bodyH))
            bodyText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        } else {
            bodyScroll.isHidden = true
        }

        separator.isHidden = !showsOriginalBlock
        originalTitle.isHidden = !showsOriginalBlock
        originalScroll.isHidden = !showsOriginalBlock
        if showsOriginalBlock, let origAttrs {
            let sepY = bodyTop - bodyH - 14
            separator.frame = NSRect(x: pad, y: sepY, width: contentW, height: 1)
            originalTitle.frame = NSRect(x: pad, y: sepY - 16, width: contentW, height: 13)
            originalTitle.stringValue = messageMode ? "说明" : "原文 · 按 O 收起"
            originalScroll.frame = NSRect(x: pad, y: sepY - 16 - 6 - origH, width: contentW, height: origH)
            originalText.textStorage?.setAttributedString(origAttrs)
            originalText.textContainer?.containerSize = NSSize(width: contentW, height: .greatestFiniteMagnitude)
            originalText.frame = NSRect(x: 0, y: 0, width: contentW, height: max(origMeasure, origH))
        }

        footerLabel.frame = NSRect(x: pad, y: pad - 3, width: contentW, height: 14)
        updateFooter()

        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: width, height: totalH)
        scanBand.frame = CGRect(x: 0, y: -60, width: width, height: 60)
        needsDisplay = true
    }

    private func lineStyle(_ spacing: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = spacing
        return p
    }

    private func updateFooter() {
        footerLabel.textColor = NSColor(white: 0.42, alpha: 1)
        if isLoading { return }
        var parts: [String] = []
        if translationText != nil {
            parts = ["⌘C 复制", "O 原文", "⌘R 重译", "Esc 关闭"]
        } else {
            parts = ["Esc 关闭"]
        }
        footerLabel.stringValue = parts.joined(separator: "   ·   ")
    }

    // MARK: - 扫描动画

    private func startScanning() {
        scanBand.isHidden = false
        scanBand.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = -60
        animation.toValue = Double(max(frame.height, 140)) + 60
        animation.duration = 1.5
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scanBand.add(animation, forKey: "scan")
    }

    private func stopScanning() {
        scanBand.isHidden = true
        scanBand.removeAllAnimations()
    }

    // MARK: - 动作

    @objc private func copyTapped() { onCopy?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func eudicTapped() { onEudic?() }
}
