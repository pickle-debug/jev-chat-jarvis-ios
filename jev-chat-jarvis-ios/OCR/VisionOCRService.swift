import CoreGraphics
import Foundation
import Vision

/// 本地 Vision OCR。所有识别在独立串行队列上执行，不阻塞主线程和引擎 actor。
nonisolated final class VisionOCRService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jarvis.ocr.vision", qos: .userInitiated)
    private let languages: [String]

    init() {
        // 按设备实际支持的语言选择，不假设 accurate 级别一定支持中文。
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        let preferred = ["zh-Hans", "en-US"].filter { supported.contains($0) }
        languages = preferred.isEmpty ? ["en-US"] : preferred
    }

    /// 返回帧像素坐标（左上原点）的文字行，按从上到下排序。失败返回空数组。
    func recognize(_ image: CGImage) async -> [OCRLine] {
        let languages = languages
        return await withCheckedContinuation { continuation in
            queue.async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = languages
                // 语言纠错会“修正”聊天原文里的口语、网络用语和错别字，关掉。
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.008
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                let width = CGFloat(image.width), height = CGFloat(image.height)
                let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let box = observation.boundingBox
                    let rect = CGRect(
                        x: box.minX * width,
                        y: (1 - box.maxY) * height,
                        width: box.width * width,
                        height: box.height * height
                    )
                    return OCRLine(text: text, rect: rect, confidence: candidate.confidence)
                }
                continuation.resume(returning: lines.sorted { $0.rect.minY < $1.rect.minY })
            }
        }
    }
}
