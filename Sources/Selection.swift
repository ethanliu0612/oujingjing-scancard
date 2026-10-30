import AppKit
import CoreGraphics

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    var shot: DisplayShot?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var hasDragged = false
    private var hintAlpha: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    private var selectionRect: NSRect? {
        guard let startPoint, let currentPoint else { return nil }
        let rect = NSRect(x: min(startPoint.x, currentPoint.x),
                          y: min(startPoint.y, currentPoint.y),
                          width: abs(currentPoint.x - startPoint.x),
                          height: abs(currentPoint.y - startPoint.y))
        return rect.intersection(bounds)
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        hasDragged = false
        hintAlpha = 0
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentPoint = NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                               y: min(max(point.y, bounds.minY), bounds.maxY))
        hasDragged = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if !hasDragged { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, hasDragged, rect.width >= 12, rect.height >= 12 else {
            onCancel?()
            return
        }
        onFinish?(rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        _ = ctx
        let rect = selectionRect

        // 用奇偶填充把选区挖空，让下面真实的屏幕内容透出来
        let mask = NSBezierPath(rect: bounds)
        if let rect, rect.width > 0, rect.height > 0 {
            mask.append(NSBezierPath(rect: rect))
        }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.32).setFill()
        mask.fill()

        if let rect, rect.width > 0, rect.height > 0 {
            // 边框：外深内蓝，带一点“取景器”味道
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let outer = NSBezierPath(rect: rect.insetBy(dx: -1.5, dy: -1.5))
            outer.lineWidth = 3
            outer.stroke()

            Palette.accent.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5
            border.stroke()

            drawCornerHandles(rect)
            drawSizeBadge(rect)
            if hasDragged, let point = cursorPoint() { drawLoupe(at: point) }
        } else {
            drawHint()
            if let point = cursorPoint() { drawLoupe(at: point) }
        }
    }

    private func cursorPoint() -> NSPoint? {
        guard let window else { return nil }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    private func drawCornerHandles(_ rect: NSRect) {
        let size: CGFloat = 5
        NSColor.white.setFill()
        let points = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        for p in points {
            let r = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            NSBezierPath(ovalIn: r).fill()
        }
    }

    private func drawSizeBadge(_ rect: NSRect) {
        guard let shot else { return }
        let width = Int((rect.width * shot.scale).rounded())
        let height = Int((rect.height * shot.scale).rounded())
        let text = "\(width) × \(height)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 7
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 8)
        if origin.y + 20 > bounds.maxY { origin.y = rect.minY - 26 }
        let badge = NSRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: 20)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + 4), withAttributes: attrs)
    }

    private func drawHint() {
        let text = "拖拽框选要翻译的区域   ·   Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - (size.width + 40) / 2,
                         y: bounds.midY + 60,
                         width: size.width + 40,
                         height: 34)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 17, yRadius: 17).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 20, y: box.minY + 10), withAttributes: attrs)
    }

    private func drawLoupe(at point: NSPoint) {
        guard let shot, let image = shot.image.croppingForLoupe(at: point,
                                                                viewHeight: bounds.height,
                                                                scale: shot.scale) else { return }
        let side: CGFloat = 132
        let sourceSide = 46.0
        var origin = NSPoint(x: point.x + 22, y: point.y - side - 22)
        if origin.x + side > bounds.maxX { origin.x = point.x - side - 22 }
        if origin.y < bounds.minY + 8 { origin.y = point.y + 22 }
        let frame = NSRect(origin: origin, size: NSSize(width: side, height: side))

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        clip.addClip()
        NSColor.black.setFill()
        frame.fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .none
            ctx.saveGState()
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            ctx.restoreGState()
        }
        // 中心十字
        NSColor.white.withAlphaComponent(0.75).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: frame.midX, y: frame.midY - 6))
        cross.line(to: NSPoint(x: frame.midX, y: frame.midY + 6))
        cross.move(to: NSPoint(x: frame.midX - 6, y: frame.midY))
        cross.line(to: NSPoint(x: frame.midX + 6, y: frame.midY))
        cross.lineWidth = 1
        cross.stroke()
        NSGraphicsContext.restoreGraphicsState()

        Palette.accent.setStroke()
        let border = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        border.lineWidth = 1.5
        border.stroke()

        let label = String(format: "%.0f%%", sourceSide > 0 ? side / sourceSide * 100 : 300)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]
        (label as NSString).draw(at: NSPoint(x: frame.minX + 6, y: frame.maxY - 16), withAttributes: attrs)
    }
}

extension CGImage {
    func croppingForLoupe(at point: NSPoint, viewHeight: CGFloat, scale: CGFloat) -> CGImage? {
        let sourceSide: CGFloat = 46
        let pixelX = point.x * scale - (sourceSide * scale) / 2
        let pixelY = (viewHeight - point.y) * scale - (sourceSide * scale) / 2
        let rect = CGRect(x: pixelX, y: pixelY, width: sourceSide * scale, height: sourceSide * scale)
        let bounded = rect.intersection(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard !bounded.isNull, bounded.width >= 4, bounded.height >= 4 else { return nil }
        return cropping(to: bounded.integral)
    }
}

// MARK: - 控制器

@MainActor
final class SelectionController {
    static let shared = SelectionController()

    private var windows: [OverlayWindow] = []
    private var shots: [DisplayShot] = []
    private var isActive = false

    private init() {}

    func begin() {
        Log.write("selection begin, active=\(isActive) perm=\(CGPreflightScreenCaptureAccess())")
        guard !isActive else { return }

        // 某些系统版本 preflight 会滞后于实际授权，所以不直接返回，
        // 先申请一次并真正尝试抓屏，失败再给引导。
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        isActive = true
        Task { @MainActor in
            do {
                let captured = try await Capture.allDisplays()
                guard isActive else { return }
                shots = captured
                Log.write("captured \(captured.count) display(s): " + captured.map { "\($0.displayID)@\($0.frame)" }.joined(separator: ", "))
                presentOverlays()
            } catch {
                Log.write("capture failed: \(error) preflight=\(CGPreflightScreenCaptureAccess())")
                isActive = false
                if !CGPreflightScreenCaptureAccess() {
                    PermissionGuide.watchAndRestartWhenGranted()
                    return
                }
                CardController.shared.showMessage(
                    title: "无法截屏",
                    body: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    hint: "请在 系统设置 › 隐私与安全性 › 屏幕与系统音频录制 中允许「扫描卡」。")
            }
        }
    }

    private func presentOverlays() {
        NSApp.activate(ignoringOtherApps: true)
        windows.removeAll()
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false

            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            view.shot = shots.first(where: { $0.displayID == id }) ?? shots.first
            view.onFinish = { [weak self, weak view] rect in
                guard let self, let view else { return }
                self.finish(rect: rect, in: view)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.makeKey()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                window.animator().alphaValue = 1
            }
            windows.append(window)
        }

        keysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
    }

    private var keysMonitor: Any?

    func cancel() {
        guard isActive else { return }
        isActive = false
        removeMonitor()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func removeMonitor() {
        if let keysMonitor {
            NSEvent.removeMonitor(keysMonitor)
            self.keysMonitor = nil
        }
    }

    private func finish(rect: NSRect, in view: OverlayView) {
        guard isActive, let window = view.window else { return }
        let screenRect = window.convertToScreen(rect)
        cancel()

        let cgRect = Capture.toCGGlobal(screenRect)
        guard let shot = shots.first(where: { $0.frame.intersects(cgRect) }) ?? shots.first,
              let cropped = shot.crop(cgRect: cgRect) else {
            CardController.shared.showMessage(title: "选区无效", body: "没能截取这块区域，请重新框选。", hint: nil)
            return
        }
        CardController.shared.beginPipeline(image: cropped, anchor: screenRect, shot: shot)
    }
}
