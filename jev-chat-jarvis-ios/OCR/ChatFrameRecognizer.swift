import CoreGraphics
import Foundation

/// 单屏识别仅负责像素和版式，不等待跨屏对齐、长图编码或业务分析。
nonisolated final class ChatFrameRecognizer: Sendable {
    private let ocr = VisionOCRService()

    func recognize(jpeg: Data, frameID: UUID, capturedAt: Date, anchors: LayoutAnchors,
                   currentTitle: String?, overlayMarkers: [String]) async -> RecognizedChatFrame? {
        guard let bitmap = FrameBitmap(jpegData: jpeg) else { return nil }
        let started = Date()
        let rawLines = await ocr.recognize(bitmap.image)
        let (lines, keyboardTop, occluders) = Self.excludeJarvisUI(rawLines, markers: overlayMarkers, frameSize: bitmap.size)
        let parser = ChatLayoutParser()
        var parsed = parser.parse(lines: lines, bitmap: bitmap, frameID: frameID, capturedAt: capturedAt,
                                  anchors: anchors, jarvisKeyboardTop: keyboardTop, occluders: occluders)
        if let title = parsed.title, let currentTitle,
           !ChatLayoutParser.isTransientTitle(title),
           TextMatch.similarity(TextMatch.normalize(title), TextMatch.normalize(currentTitle)) < 0.6 {
            parsed = parser.parse(lines: lines, bitmap: bitmap, frameID: frameID, capturedAt: capturedAt,
                                  anchors: LayoutAnchors(), jarvisKeyboardTop: keyboardTop, occluders: occluders)
        }
        return RecognizedChatFrame(bitmap: bitmap, parsed: parsed,
                                   ocrMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    static func excludeJarvisUI(
        _ lines: [OCRLine], markers: [String], frameSize: CGSize
    ) -> (lines: [OCRLine], keyboardTop: CGFloat?, occluders: [CGRect]) {
        let keyboardHeader = lines
            .filter { $0.text.hasPrefix("Jarvis 键盘") || $0.text.hasPrefix("Jarvis键盘") }
            .filter { $0.rect.midY > 0.4 * frameSize.height }
            .min { $0.rect.minY < $1.rect.minY }
        let candidates = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return (text.hasPrefix("Jarvis ") || text.hasPrefix("Jarvis·"))
                && line != keyboardHeader
                && (keyboardHeader.map { line.rect.maxY < $0.rect.minY } ?? true)
        }
        var regions: [CGRect] = []
        for header in candidates where header.text.hasPrefix("Jarvis ·") || header.text.hasPrefix("Jarvis·") {
            let lineHeight = max(header.rect.height, 1)
            let rows = candidates.filter { line in
                line.rect.minY >= header.rect.maxY
                    && line.rect.minY - header.rect.maxY < lineHeight * 5
                    && abs(line.rect.minX - header.rect.minX) < lineHeight * 0.8
                    && line.rect.height >= lineHeight * 0.65
                    && line.rect.height <= lineHeight * 1.25
            }.sorted { $0.rect.minY < $1.rect.minY }
            guard rows.count >= 2 else { continue }
            let first = rows[0], second = rows[1]
            let firstLabels = ["Jarvis 意图", "Jarvis 判断", "Jarvis 识别到", "Jarvis 打开"]
            let secondLabels = ["Jarvis 建议", "Jarvis 分析完成后", "Jarvis 显示情绪"]
            guard firstLabels.contains(where: { first.text.hasPrefix($0) }),
                  secondLabels.contains(where: { second.text.hasPrefix($0) }) else { continue }
            let firstStep = first.rect.midY - header.rect.midY
            let secondStep = second.rect.midY - first.rect.midY
            guard firstStep >= lineHeight, firstStep <= lineHeight * 2.2,
                  abs(firstStep - secondStep) < lineHeight * 0.6 else { continue }
            let scale = (firstStep + secondStep) / 32
            let region = CGRect(x: header.rect.minX - 19 * scale, y: header.rect.midY - 16 * scale,
                                width: 414 * scale, height: 80 * scale)
            regions.append(region.intersection(CGRect(origin: .zero, size: frameSize)))
        }
        let kept = lines.filter { line in
            if let keyboardHeader, line.rect.minY >= keyboardHeader.rect.minY - 2 { return false }
            return !regions.contains { $0.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) }
        }
        return (kept, keyboardHeader?.rect.minY, regions)
    }
}
