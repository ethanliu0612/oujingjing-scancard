import AppKit
import Foundation
import Security

let AppDisplayName = "扫描卡"
let HotKeyText = "⌥⌘S"

enum Pref {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "baseURL": "https://api.deepseek.com",
            "model": "deepseek-chat",
            "style": "fluent",
            "glossary": "",
            "ocrLanguages": "en-US",
            "keepOriginal": true,
            "fontSize": 13.5,
            "didOnboard": false,
            "lastPick": 0.0,
        ])
    }

    static var baseURL: String {
        get { d.string(forKey: "baseURL") ?? "https://api.deepseek.com" }
        set { d.set(newValue, forKey: "baseURL") }
    }

    static var model: String {
        get { d.string(forKey: "model") ?? "deepseek-chat" }
        set { d.set(newValue, forKey: "model") }
    }

    static var style: String {
        get { d.string(forKey: "style") ?? "fluent" }
        set { d.set(newValue, forKey: "style") }
    }

    static var glossary: String {
        get { d.string(forKey: "glossary") ?? "" }
        set { d.set(newValue, forKey: "glossary") }
    }

    static var ocrLanguages: String {
        get { d.string(forKey: "ocrLanguages") ?? "en-US" }
        set { d.set(newValue, forKey: "ocrLanguages") }
    }

    static var didOnboard: Bool {
        get { d.bool(forKey: "didOnboard") }
        set { d.set(newValue, forKey: "didOnboard") }
    }

    static var fontSize: Double {
        get { d.double(forKey: "fontSize") > 0 ? d.double(forKey: "fontSize") : 13.5 }
        set { d.set(newValue, forKey: "fontSize") }
    }

    /// 术语表："atrial fibrillation = 心房颤动"
    static var glossaryPairs: [(String, String)] {
        glossary.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            for sep in ["=", "→", "——"] {
                if let r = line.range(of: sep) {
                    let k = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let v = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty, !v.isEmpty { return (k, v) }
                }
            }
            return nil
        }
    }
}

/// 钥匙串优先；某些环境（沙箱、未签名 CLI）拿不到钥匙串时，退化为 0600 权限的本地文件。
enum SecretStore {
    private static let account = "deepseek"

    private static var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ScanCard", isDirectory: true)
            .appendingPathComponent("credential")
    }

    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["SCANCARD_KEY"], !env.isEmpty {
            return env
        }
        if let key = Keychain.load(account: account), !key.isEmpty { return key }
        if let data = try? Data(contentsOf: fallbackURL),
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func save(_ value: String) {
        Keychain.save(value, account: account)
        if Keychain.load(account: account) != value {
            writeFile(value)
        }
    }

    static func delete() {
        Keychain.delete(account: account)
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    private static func writeFile(_ value: String) {
        let url = fallbackURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? value.data(using: .utf8)?.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Keychain {
    static let service = "com.leo.scancard"

    static func save(_ value: String, account: String = "deepseek") {
        delete(account: account)
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String = "deepseek") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func delete(account: String = "deepseek") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum Palette {
    static let accent = NSColor(srgbRed: 0.32, green: 0.64, blue: 1.0, alpha: 1)
    static let cardTop = NSColor(srgbRed: 0.098, green: 0.110, blue: 0.133, alpha: 0.96)
    static let cardBottom = NSColor(srgbRed: 0.063, green: 0.071, blue: 0.086, alpha: 0.96)
    static let textPrimary = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    static let textSecondary = NSColor(srgbRed: 0.63, green: 0.67, blue: 0.74, alpha: 1)
    static let textOriginal = NSColor(srgbRed: 0.70, green: 0.74, blue: 0.80, alpha: 1)
    static let separator = NSColor(white: 1.0, alpha: 0.08)
    static let chip = NSColor(white: 1.0, alpha: 0.07)
}

enum TypeSet {
    static func bodyFont(_ size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }

    static func body(_ text: String, size: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4.5
        p.paragraphSpacing = 7
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: bodyFont(size),
            .foregroundColor: Palette.textPrimary,
            .paragraphStyle: p,
        ])
    }

    static func original(_ text: String, size: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 6
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size - 1.5, weight: .regular),
            .foregroundColor: Palette.textOriginal,
            .paragraphStyle: p,
        ])
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: max(width, 10), height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height)
    }
}

extension NSView {
    func pinEdges(to other: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor),
            trailingAnchor.constraint(equalTo: other.trailingAnchor),
            topAnchor.constraint(equalTo: other.topAnchor),
            bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ])
    }
}

enum Log {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ScanCard.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
