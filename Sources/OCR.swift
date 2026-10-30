import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

struct OCRLine {
    var text: String
    /// Vision 归一化坐标，原点左下角。
    var box: CGRect
    var confidence: Float
}

struct OCRResult {
    var text: String
    var lines: [OCRLine]
    var confidence: Float
}

enum OCRError: LocalizedError {
    case noText
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noText: return "没识别到文字，试试框得更紧一点或放大页面"
        case .failed(let m): return m
        }
    }
}

enum OCR {
    private static let ligatures: [(String, String)] = [
        ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"),
        ("\u{FB04}", "ffl"), ("\u{FB05}", "st"), ("\u{FB06}", "st"),
        ("\u{00AD}", ""),
    ]

    static func recognize(image: CGImage, languages: [String] = ["en-US"]) async throws -> OCRResult {
        var best = try await run(image: image, languages: languages)

        // 低置信度时做一次增强（灰度 + 提对比度）再识别，取更好的结果。
        if best.confidence < 0.72 || best.text.count < 24 {
            if let enhanced = enhance(image) {
                if let second = try? await run(image: enhanced, languages: languages) {
                    let score1 = score(best)
                    let score2 = score(second)
                    if score2 > score1 * 1.02 { best = second }
                }
            }
        }

        guard !best.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRError.noText
        }
        return best
    }

    private static func score(_ r: OCRResult) -> Double {
        Double(r.text.count) * (0.35 + Double(r.confidence))
    }

    private static func run(image: CGImage, languages: [String]) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = languages
                request.minimumTextHeight = 0.004
                if #available(macOS 13.0, *) {
                    request.revision = VNRecognizeTextRequestRevision3
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(throwing: OCRError.failed(error.localizedDescription))
                    return
                }

                let observations = (request.results ?? []).compactMap { obs -> OCRLine? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return OCRLine(text: candidate.string,
                                   box: obs.boundingBox,
                                   confidence: candidate.confidence)
                }

                let cleaned = observations.filter { line in
                    let t = line.text.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { return false }
                    // 页码 / 行号：纯数字且贴在页边
                    if t.count <= 4, t.allSatisfy({ $0.isNumber }),
                       line.box.minX < 0.08 || line.box.minX > 0.88 {
                        return false
                    }
                    if line.confidence < 0.18 { return false }
                    return true
                }

                let text = paragraphize(cleaned)
                let conf: Float
                if cleaned.isEmpty {
                    conf = 0
                } else {
                    let total = cleaned.reduce(Float(0)) { $0 + $1.confidence * Float(max($1.text.count, 1)) }
                    let weight = cleaned.reduce(Float(0)) { $0 + Float(max($1.text.count, 1)) }
                    conf = total / max(weight, 1)
                }
                cont.resume(returning: OCRResult(text: text, lines: cleaned, confidence: conf))
            }
        }
    }

    private static func enhance(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let controls = CIFilter.colorControls()
        controls.inputImage = ci
        controls.saturation = 0
        controls.contrast = 1.35
        controls.brightness = 0.03
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = controls.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    // MARK: - 版面重建

    private static func paragraphize(_ lines: [OCRLine]) -> String {
        guard !lines.isEmpty else { return "" }

        let columns = splitColumns(lines)
        var paragraphs: [String] = []
        for column in columns {
            let ordered = column.sorted { a, b in
                if abs(a.box.maxY - b.box.maxY) > 0.005 { return a.box.maxY > b.box.maxY }
                return a.box.minX < b.box.minX
            }
            // 用本文区域自己的行距做基准，段落间距通常明显大于它
            var gaps: [CGFloat] = []
            for i in 1..<max(ordered.count, 1) {
                gaps.append(ordered[i - 1].box.minY - ordered[i].box.maxY)
            }
            gaps = gaps.filter { $0 > -0.02 }
            gaps.sort()
            let medianGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]

            let columnWidth = max((ordered.map { $0.box.maxX }.max() ?? 0)
                                  - (ordered.map { $0.box.minX }.min() ?? 0), 0.01)

            var current: [OCRLine] = []
            for line in ordered {
                guard let prev = current.last else {
                    current = [line]
                    continue
                }
                let gap = prev.box.minY - line.box.maxY
                let lineHeight = max(prev.box.height, line.box.height, 0.0001)
                let indented = line.box.minX > prev.box.minX + lineHeight * 1.4
                let threshold = medianGap + max(0.4 * lineHeight, medianGap * 1.2)
                // 标题/小标题：短行、且不以句读结尾，后接正文
                let trimmed = prev.text.trimmingCharacters(in: .whitespaces)
                let endsSentence = trimmed.last.map { ".,;:!?，。；：".contains($0) } ?? false
                let shortLine = (prev.box.width) < columnWidth * 0.62
                let looksLikeHeading = shortLine && !endsSentence && line.box.width > prev.box.width * 1.5
                if gap < threshold && !indented && !looksLikeHeading {
                    current.append(line)
                } else {
                    paragraphs.append(join(current))
                    current = [line]
                }
            }
            if !current.isEmpty { paragraphs.append(join(current)) }
        }

        var out: [String] = []
        for p in paragraphs {
            let t = cleanup(p)
            if !t.isEmpty { out.append(t) }
        }
        return out.joined(separator: "\n\n")
    }

    /// 双栏论文：如果能明显分成左右两栏，就按栏顺序输出，避免左右行交错。
    private static func splitColumns(_ lines: [OCRLine]) -> [[OCRLine]] {
        guard lines.count >= 8 else { return [lines] }
        let sortedByX = lines.sorted { $0.box.minX < $1.box.minX }
        let width = max(sortedByX.last!.box.maxX - sortedByX.first!.box.minX, 0.01)
        var bestGap: CGFloat = 0
        var splitIndex = -1
        for i in 1..<sortedByX.count {
            let gap = sortedByX[i].box.minX - sortedByX[i - 1].box.maxX
            let leftCount = i
            let rightCount = sortedByX.count - i
            if gap > bestGap, leftCount >= 3, rightCount >= 3, gap > width * 0.06 {
                bestGap = gap
                splitIndex = i
            }
        }
        guard splitIndex > 0, bestGap > 0.04 else { return [lines] }

        let left = Array(sortedByX[..<splitIndex])
        let right = Array(sortedByX[splitIndex...])

        // 两栏应当在纵向上有重叠，否则可能只是缩进错位。
        let leftRange = left.map { $0.box.minY }.min()!...left.map { $0.box.maxY }.max()!
        let rightRange = right.map { $0.box.minY }.min()!...right.map { $0.box.maxY }.max()!
        let overlap = min(leftRange.upperBound, rightRange.upperBound) - max(leftRange.lowerBound, rightRange.lowerBound)
        let minSpan = min(leftRange.upperBound - leftRange.lowerBound, rightRange.upperBound - rightRange.lowerBound)
        guard overlap > minSpan * 0.5 else { return [lines] }
        return [left, right]
    }

    private static func join(_ lines: [OCRLine]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            var text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if index == 0 {
                result = text
                continue
            }
            let endsWithHyphen = result.hasSuffix("-") || result.hasSuffix("\u{2010}") || result.hasSuffix("\u{2011}")
            let nextStartsLower = text.first.map { $0.isLowercase } ?? false
            if endsWithHyphen, nextStartsLower, text.count > 1 {
                result.removeLast()
                result += text
            } else {
                result += " " + text
            }
        }
        return result
    }

    private static func cleanup(_ text: String) -> String {
        var t = text
        for (from, to) in ligatures { t = t.replacingOccurrences(of: from, with: to) }
        t = t.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        // 句号后缺少空格
        t = t.replacingOccurrences(of: "([a-z])\\.([A-Z][a-z])", with: "$1. $2", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
