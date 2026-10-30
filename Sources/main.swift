import AppKit
import Foundation
import Translation

// MARK: - 命令行自测入口（不影响正常启动）

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

private func loadCGImage(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("无法读取图片：\(path)")
    }
    return cg
}

private func runOCR(path: String) {
    Task.detached {
        do {
            let image = loadCGImage(path)
            let result = try await OCR.recognize(image: image, languages: ["en-US"])
            print("=== OCR 结果（置信度 \(String(format: "%.2f", result.confidence))，\(result.lines.count) 行）===")
            print(result.text)
            exit(0)
        } catch {
            fail("OCR 失败：\(error)")
        }
    }
    CFRunLoopRun()
}

private func runTranslate(text: String) {
    Task.detached {
        do {
            let output = try await Translators.translate(text)
            print("=== \(output.engine) · \(String(format: "%.1f", output.elapsed))s ===")
            print(output.text)
            exit(0)
        } catch {
            fail("翻译失败：\(error)")
        }
    }
    CFRunLoopRun()
}

private func runTest() {
    Task.detached {
        let result = await Translators.test()
        print(result)
        exit(result.hasPrefix("✅") ? 0 : 1)
    }
    CFRunLoopRun()
}

private func saveKey(_ key: String) {
    SecretStore.save(key)
    print("已保存到钥匙串（\(key.prefix(6))…）")
    exit(0)
}

private func runCapture(rectString: String) {
    let parts = rectString.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { fail("格式：--capture x,y,w,h") }
    Task.detached {
        do {
            let shots = try await Capture.allDisplays()
            let cgRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            guard let shot = shots.first(where: { $0.frame.intersects(cgRect) }),
                  let cropped = shot.crop(cgRect: cgRect) else { fail("裁切失败") }
            let url = URL(fileURLWithPath: "/tmp/scancard-capture.png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cropped, nil)
                CGImageDestinationFinalize(dest)
                print("已保存 \(url.path) (\(cropped.width)×\(cropped.height))")
            }
            let result = try await OCR.recognize(image: cropped, languages: ["en-US"])
            print("=== 置信度 \(String(format: "%.2f", result.confidence)) ===")
            print(result.text)
            exit(0)
        } catch {
            fail("截图失败：\(error)")
        }
    }
    CFRunLoopRun()
}

let arguments = CommandLine.arguments

// CLI 自测时也让 AppKit 就绪，便于测试本地翻译
if arguments.count > 1 {
    _ = NSApplication.shared
}

if let index = arguments.firstIndex(of: "--ocr"), index + 1 < arguments.count {
    runOCR(path: arguments[index + 1])
}
if let index = arguments.firstIndex(of: "--translate"), index + 1 < arguments.count {
    runTranslate(text: arguments[index + 1])
}
private func runLocalSelfTest(outputPath: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        Task {
            var message: String
            do {
                let text = try await AppleTranslateBridge.shared.translate(
                    "The measured transmittance decreases with increasing film thickness.")
                message = "OK: \(text)"
            } catch {
                message = "ERROR: \(error)"
            }
            try? message.write(toFile: outputPath, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
    app.run()
}

private func renderCard(_ path: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let sampleEN = "We present a systematic analysis of the attenuation observed in the multilayer samples prepared by chemical vapor deposition. Contrary to earlier reports, the loss cannot be attributed to scattering alone; it arises from the interplay between interfacial absorption and boundary effects that previous models have systematically underestimated."
    let sampleZH = "我们对化学气相沉积制备的多层样品中观察到的衰减进行了系统分析。与早先的报道相反，这种损耗不能仅归因于散射；它源于界面吸收与边界效应之间的相互作用，而以往模型系统性地低估了这一作用。"

    let card = CardView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
    card.cardWidth = 460
    card.showTranslation(sampleZH, engine: "DeepSeek", elapsed: 1.4, original: sampleEN)
    card.relayout()
    card.layoutSubtreeIfNeeded()

    let size = card.frame.size
    let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 60, height: size.height + 60))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(srgbRed: 0.83, green: 0.85, blue: 0.88, alpha: 1).cgColor
    card.setFrameOrigin(NSPoint(x: 30, y: 30))
    container.addSubview(card)
    container.layoutSubtreeIfNeeded()

    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { exit(1) }
    container.cacheDisplay(in: container.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("rendered \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        exit(0)
    }
    exit(1)
}

if let index = arguments.firstIndex(of: "--render-card"), index + 1 < arguments.count {
    renderCard(arguments[index + 1])
}
if let index = arguments.firstIndex(of: "--selftest-local"), index + 1 < arguments.count {
    runLocalSelfTest(outputPath: arguments[index + 1])
}
if arguments.contains("--test") {
    runTest()
}
if let index = arguments.firstIndex(of: "--save-key"), index + 1 < arguments.count {
    saveKey(arguments[index + 1])
}
private func runPipeline(path: String) {
    Task.detached {
        do {
            let image = loadCGImage(path)
            let ocr = try await OCR.recognize(image: image, languages: ["en-US"])
            print("=== OCR (\(String(format: "%.2f", ocr.confidence))) ===")
            print(ocr.text)
            let output = try await Translators.translate(ocr.text)
            print("=== \(output.engine) · \(String(format: "%.1f", output.elapsed))s ===")
            print(output.text)
            exit(0)
        } catch {
            fail("流水线失败：\(error)")
        }
    }
    CFRunLoopRun()
}

if let index = arguments.firstIndex(of: "--pipeline"), index + 1 < arguments.count {
    runPipeline(path: arguments[index + 1])
}
if let index = arguments.firstIndex(of: "--capture"), index + 1 < arguments.count {
    runCapture(rectString: arguments[index + 1])
}
if arguments.contains("--diag") {
    print("bundle: \(Bundle.main.bundlePath)")
    print("bundleID: \(Bundle.main.bundleIdentifier ?? "-")")
    print("screenRecording: \(CGPreflightScreenCaptureAccess())")
    print("hasAPIKey: \(Translators.hasKey())")
    print("runningInstances: \(NSRunningApplication.runningApplications(withBundleIdentifier: "com.leo.scancard").count)")
    print("logFile: \(Log.fileURL.path)")
    exit(0)
}
if arguments.contains("--version") {
    print("ScanCard 1.0.0")
    exit(0)
}

// MARK: - 正常启动

Pref.registerDefaults()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
