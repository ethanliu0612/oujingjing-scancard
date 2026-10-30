import AppKit
import Combine
import SwiftUI
import Translation

/// 用系统自带的 Translation 框架做离线兜底。
/// 该框架只有 SwiftUI 的 `.translationTask` 入口，所以这里挂一个 2×2 的隐形窗口来承载会话。
@available(macOS 15.0, *)
final class AppleTranslateBridge {
    static let shared = AppleTranslateBridge()

    final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
    }

    private let model = Model()
    private var window: NSWindow?
    private var pendingText: String?
    private var pending: CheckedContinuation<String, Error>?
    private var timeoutWork: DispatchWorkItem?

    private init() {}

    func translate(_ text: String) async throws -> String {
        let availability = LanguageAvailability()
        let status = await availability.status(from: Locale.Language(identifier: "en"),
                                               to: Locale.Language(identifier: "zh-Hans"))
        switch status {
        case .installed:
            break
        case .supported:
            throw TranslateError.localUnavailable("系统翻译的中文语言包尚未下载")
        default:
            throw TranslateError.localUnavailable("当前系统不支持英译中")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.begin(text, continuation)
            }
        }
    }

    private func begin(_ text: String, _ continuation: CheckedContinuation<String, Error>) {
        guard NSApp != nil else {
            continuation.resume(throwing: TranslateError.localUnavailable("需要图形界面环境"))
            return
        }
        guard pending == nil else {
            continuation.resume(throwing: TranslateError.localUnavailable("上一段还在翻译中"))
            return
        }

        ensureWindow()

        pending = continuation
        pendingText = text

        // 每次换一个新 configuration，确保 SwiftUI 重新触发 translationTask
        model.configuration = nil
        let configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        )
        DispatchQueue.main.async {
            self.model.configuration = configuration
        }

        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending != nil else { return }
            self.finish(.failure(TranslateError.localUnavailable("系统翻译超时（语言包可能未下载）")))
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func ensureWindow() {
        if window != nil { return }

        let size = NSSize(width: 2, height: 2)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.alphaValue = 0.02
        win.level = .normal
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false

        let bridge = BridgeView(model: model) { [weak self] session in
            await self?.handle(session)
        }
        let host = NSHostingView(rootView: bridge)
        host.frame = NSRect(origin: .zero, size: size)
        win.contentView = host

        if let screen = NSScreen.main {
            win.setFrameOrigin(NSPoint(x: screen.frame.minX + 4, y: screen.frame.minY + 4))
        }
        win.orderFrontRegardless()
        window = win
    }

    private func handle(_ session: TranslationSession) async {
        guard let text = pendingText, pending != nil else { return }
        pendingText = nil
        do {
            let response = try await session.translate(text)
            finish(.success(response.targetText))
        } catch {
            finish(.failure(TranslateError.localUnavailable(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let continuation = self.pending else { return }
            self.pending = nil
            self.pendingText = nil
            continuation.resume(with: result)
        }
    }
}

@available(macOS 15.0, *)
private struct BridgeView: View {
    @ObservedObject var model: AppleTranslateBridge.Model
    let onSession: (TranslationSession) async -> Void

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .translationTask(model.configuration) { session in
                await onSession(session)
            }
    }
}
