import Foundation

struct TranslationOutput {
    var text: String
    var engine: String
    var elapsed: TimeInterval
}

enum TranslateError: LocalizedError {
    case noKey
    case unauthorized
    case insufficientBalance
    case rateLimited
    case server(Int, String)
    case network(String)
    case localUnavailable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "还没配置 DeepSeek API Key"
        case .unauthorized:
            return "API Key 无效或已过期，请在设置里重新填写"
        case .insufficientBalance:
            return "DeepSeek 账户余额不足"
        case .rateLimited:
            return "请求太频繁，请稍等几秒再试"
        case .server(let code, let body):
            return "服务端错误 \(code)：\(body.prefix(120))"
        case .network(let message):
            return "网络错误：\(message)"
        case .localUnavailable(let message):
            return "本地翻译不可用：\(message)"
        case .empty:
            return "翻译结果为空，请重试"
        }
    }
}

enum Translators {
    static func hasKey() -> Bool {
        let key = SecretStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    static func translate(_ text: String) async throws -> TranslationOutput {
        let started = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslateError.empty }

        if hasKey() {
            do {
                let result = try await DeepSeekTranslator.translate(trimmed)
                return TranslationOutput(text: result, engine: "DeepSeek",
                                         elapsed: Date().timeIntervalSince(started))
            } catch let error as TranslateError {
                // 密钥类错误直接抛给用户，网络类错误尝试本地兜底
                if case .unauthorized = error { throw error }
                if case .insufficientBalance = error { throw error }
                if let local = try? await localTranslate(trimmed) {
                    return TranslationOutput(text: local, engine: "本地翻译（已兜底）",
                                             elapsed: Date().timeIntervalSince(started))
                }
                throw error
            }
        }

        do {
            let local = try await localTranslate(trimmed)
            return TranslationOutput(text: local, engine: "本地翻译",
                                     elapsed: Date().timeIntervalSince(started))
        } catch let error as TranslateError {
            throw error
        } catch {
            throw TranslateError.localUnavailable(error.localizedDescription)
        }
    }

    private static func localTranslate(_ text: String) async throws -> String {
        guard #available(macOS 15.0, *) else {
            throw TranslateError.localUnavailable("需要 macOS 15 或更新系统")
        }
        return try await AppleTranslateBridge.shared.translate(text)
    }

    /// 设置面板里的连通性测试
    static func test() async -> String {
        guard hasKey() else { return "❌ 未填写 API Key" }
        do {
            let out = try await DeepSeekTranslator.translate("The results demonstrate a statistically significant improvement.")
            return "✅ 连接成功（\(Pref.model)）：\(out.prefix(40))…"
        } catch let e as TranslateError {
            return "❌ \(e.errorDescription ?? "未知错误")"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }
}

// MARK: - DeepSeek

enum DeepSeekTranslator {
    static func translate(_ text: String) async throws -> String {
        guard let rawKey = SecretStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKey.isEmpty else { throw TranslateError.noKey }

        let chunks = chunk(text, limit: 2200)
        if chunks.count == 1 {
            return try await request(chunk: chunks[0], key: rawKey)
        }

        // 多段并发（每批 3 个），保持顺序
        var results = [String?](repeating: nil, count: chunks.count)
        var start = 0
        while start < chunks.count {
            let end = min(start + 3, chunks.count)
            let batch = Array(start..<end)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for index in batch {
                    let piece = chunks[index]
                    group.addTask {
                        (index, try await request(chunk: piece, key: rawKey))
                    }
                }
                for try await (index, value) in group {
                    results[index] = value
                }
            }
            start = end
        }
        return results.compactMap { $0 }.joined(separator: "\n\n")
    }

    private static func request(chunk: String, key: String) async throws -> String {
        let base = Pref.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            throw TranslateError.network("API 地址无效")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": Pref.model,
            "stream": false,
            "temperature": 1.0,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": "<source>\n\(chunk)\n</source>"],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let error as URLError where error.code == .timedOut {
            throw TranslateError.network("请求超时")
        } catch {
            throw TranslateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.network("无效响应")
        }
        if http.statusCode == 401 { throw TranslateError.unauthorized }
        if http.statusCode == 402 { throw TranslateError.insufficientBalance }
        if http.statusCode == 429 { throw TranslateError.rateLimited }
        guard http.statusCode == 200 else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw TranslateError.server(http.statusCode, snippet)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslateError.server(200, "无法解析返回内容")
        }
        return stripWrapping(content)
    }

    private static func stripWrapping(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "^```[a-zA-Z]*\\n?", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\n?```$", with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func systemPrompt() -> String {
        var prompt = """
        你是资深的学术文献翻译专家，专门把英文学术文献翻译成简体中文。

        硬性要求：
        1. 准确传达原意，术语必须专业；同一术语在全文保持统一译法。
        2. 保留原文的段落结构、列表编号、公式、变量名、数字、引用标记（如 [12]、(Smith et al., 2021)）。
        3. 只输出中文译文：不要解释、不要总结、不要译者注、不要「以下是翻译」之类的前后缀。
        4. 遇到图表标题、页眉页脚、参考文献条目也照常翻译，不要跳过。
        5. 如果原文本身是中文或已经是中英混排，就原样保留并只翻译英文部分。
        """

        if Pref.style == "literal" {
            prompt += "\n\n风格：贴近原文语序与结构，逐句对应，尽量少意译。"
        } else {
            prompt += "\n\n风格：学术书面语，通顺、准确、简洁；过长的英文长句可以按中文习惯拆分或重组，读起来要像中文期刊论文。"
        }

        let pairs = Pref.glossaryPairs
        if !pairs.isEmpty {
            let table = pairs.map { "- \($0.0) → \($0.1)" }.joined(separator: "\n")
            prompt += "\n\n术语表（必须严格遵守，出现即使用该译法）：\n" + table
        }
        return prompt
    }

    /// 按段落切成不超过 limit 字符的块，保证段落完整。
    static func chunk(_ text: String, limit: Int) -> [String] {
        if text.count <= limit { return [text] }
        var chunks: [String] = []
        var current = ""
        let paragraphs = text.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            var piece = paragraph
            if piece.count > limit {
                // 单段过长：按句子切
                let sentences = piece.components(separatedBy: ". ")
                piece = ""
                for sentence in sentences {
                    if (piece + sentence).count > limit, !piece.isEmpty {
                        chunks.append(piece)
                        piece = ""
                    }
                    piece += (piece.isEmpty ? "" : ". ") + sentence
                }
            }
            if (current + "\n\n" + piece).count > limit, !current.isEmpty {
                chunks.append(current)
                current = piece
            } else {
                current += (current.isEmpty ? "" : "\n\n") + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }
}
