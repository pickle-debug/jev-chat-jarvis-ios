import CoreGraphics
import Foundation

nonisolated struct LongScreenshotInput: Sendable {
    let epoch: UUID
    let sessionID: UUID
    let conversationID: UUID?
    let frameID: UUID
    let bitmap: FrameBitmap
    let parsed: ParsedChatFrame
    let placement: StitchPlacement
    let activeSegmentIDs: Set<UUID>
    let preferredSegmentID: UUID
}

nonisolated struct LongScreenshotMerge: Sendable {
    let conversationID: UUID?
    let sourceID: UUID
    let targetID: UUID
    let shift: CGFloat
}

nonisolated struct EngineOutput: Sendable {
    let update: EngineUpdate
    let longScreenshot: LongScreenshotInput?
}

nonisolated struct RecognizedChatFrame: Sendable {
    let bitmap: FrameBitmap
    let parsed: ParsedChatFrame
    let ocrMilliseconds: Int
}

/// 一行 OCR 文字。`rect` 是帧像素坐标，原点在左上角（已从 Vision 的左下归一化坐标换算）。
nonisolated struct OCRLine: Sendable, Equatable {
    let text: String
    let rect: CGRect
    let confidence: Float
}

/// 气泡的发言方判断。和 `Speaker` 分开，是因为 OCR 层还要带置信度。
nonisolated enum BubbleSide: String, Sendable {
    case me
    case other
    case unknown
}

/// 对话列表里的条目类型。时间分隔线也保留：它是跨帧对齐的锚点，也是给 Jev 的时间上下文。
nonisolated enum BubbleKind: String, Sendable {
    case message
    case time
    /// 不是识别出来的内容，而是“这里有一段没截到的聊天记录”的占位。
    case gap
}

/// 一帧里解析出的一个聊天气泡（一条或多条相邻 OCR 行），或一条时间分隔线。
nonisolated struct ChatBubble: Sendable {
    let kind: BubbleKind
    let text: String
    /// 文字外接框（帧像素）。气泡背景比它略大。
    let rect: CGRect
    let side: BubbleSide
    let sideConfidence: Double
    /// 贴着内容区上/下边缘，可能只露出一部分，文字不完整。
    let clippedTop: Bool
    let clippedBottom: Bool
    /// 群聊气泡上方的昵称，单聊为 nil。
    let senderName: String?
    /// 气泡下方的引用块（微信“引用回复”），例如 “Gidon：不对，今晚…”。
    let quote: String?
    /// 气泡背景色（文字框外侧取样），用于学习本会话两侧气泡的颜色。
    let color: RGB?

    var clipped: Bool { clippedTop || clippedBottom }
}

/// 一帧的版式解析结果。
nonisolated struct ParsedChatFrame: Sendable {
    let frameID: UUID
    let capturedAt: Date
    let pixelSize: CGSize
    /// 0...1，越高越像聊天页。
    let chatScore: Double
    let isChat: Bool
    let title: String?
    /// 标题是本帧识别到的（而不是沿用本会话学到的标题栏位置）。
    let titleAnchored: Bool
    /// 聊天内容区在帧中的纵向范围（排除标题栏、输入栏、键盘）。
    let contentTop: CGFloat
    let contentBottom: CGFloat
    /// 长截图标题栏的截取高度：紧贴标题下方，宁短勿长，避免带进聊天内容。
    let headerBottom: CGFloat
    /// 从上到下排序，包括时间分隔线。
    let bubbles: [ChatBubble]
    let keyboardVisible: Bool
    let inputBarVisible: Bool
    /// 本帧测到的正文字高，用来过滤图片里的小字，也用于学习本会话的稳定字高。
    let bodyLineHeight: CGFloat
    /// Jarvis 自己的界面（画中画）在帧里占掉的区域，压住的气泡按“显示不完整”处理。
    let occluders: [CGRect]
    /// 不是聊天页时的原因，只用于状态展示，不含聊天内容。
    let rejectReason: String?

    var messageBubbles: [ChatBubble] { bubbles.filter { $0.kind == .message } }

    /// 单张截图足够清楚即可分析；无标题时需要更强的版式或输入栏证据。
    var hasReliableSingleFrameEvidence: Bool {
        guard isChat else { return false }
        // 裁切表示内容可能不完整，不代表无法识别聊天身份；业务仍保留此质量标记。
        let complete = messageBubbles.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.sideConfidence >= 0.8 }
        guard !complete.isEmpty else { return false }
        if titleAnchored, !ChatLayoutParser.isTransientTitle(title), chatScore >= 0.64 { return true }
        if complete.count >= 2, chatScore >= 0.75 { return true }
        if complete.count >= 2, (keyboardVisible || inputBarVisible), chatScore >= 0.68 {
            return true
        }
        return false
    }

    /// 一条消息都没有，但确实是同一个聊天页（整屏都是图片时会出现）。
    /// 不能当成“不是聊天页”，否则会把会话切断。
    func continuingChat(reason: String) -> ParsedChatFrame {
        ParsedChatFrame(
            frameID: frameID, capturedAt: capturedAt, pixelSize: pixelSize, chatScore: chatScore, isChat: true,
            title: title, titleAnchored: titleAnchored, contentTop: contentTop, contentBottom: contentBottom,
            headerBottom: headerBottom, bubbles: bubbles, keyboardVisible: keyboardVisible, inputBarVisible: inputBarVisible,
            bodyLineHeight: bodyLineHeight, occluders: occluders, rejectReason: reason
        )
    }

    /// 帧里有没有被 Jarvis 界面压住的行（判断能否放宽跨帧对齐的冲突阈值）。
    var hasOcclusion: Bool { !occluders.isEmpty }
}

/// 按会话累积的版式知识：标题栏高度、两侧气泡边缘、两侧气泡颜色。
///
/// 只从几何上高置信（明显靠左/靠右）的气泡学习，再用来判断宽气泡（左右留白差不多）的发言方。
/// 学到的气泡颜色比“气泡 vs 页面背景”可靠得多：聊天背景可能是照片壁纸。
nonisolated struct LayoutAnchors: Sendable {
    private(set) var otherLeft: [CGFloat] = []
    private(set) var meRight: [CGFloat] = []
    private(set) var contentTops: [CGFloat] = []
    private(set) var meColors: [RGB] = []
    private(set) var otherColors: [RGB] = []
    private(set) var bodyHeights: [CGFloat] = []

    mutating func record(_ frame: ParsedChatFrame) {
        if frame.titleAnchored { Self.push(&contentTops, frame.contentTop) }
        // 正文行高：只统计确实分出了左右的消息，避免把图片里的小字当成正文。
        let strong = frame.bubbles.filter {
            $0.kind == .message && $0.sideConfidence >= 0.8 && !$0.clipped
        }
        if strong.count >= 2, frame.bodyLineHeight > 0 { Self.push(&bodyHeights, frame.bodyLineHeight) }
        for bubble in frame.bubbles where bubble.kind == .message && !bubble.clipped && bubble.sideConfidence >= 0.9 {
            switch bubble.side {
            case .other:
                Self.push(&otherLeft, bubble.rect.minX)
                if let color = bubble.color { Self.push(&otherColors, color) }
            case .me:
                Self.push(&meRight, bubble.rect.maxX)
                if let color = bubble.color { Self.push(&meColors, color) }
            case .unknown:
                break
            }
        }
    }

    var otherLeftMedian: CGFloat? { Self.median(otherLeft, minimum: 3) }
    var meRightMedian: CGFloat? { Self.median(meRight, minimum: 3) }
    var contentTopMedian: CGFloat? { Self.median(contentTops, minimum: 1) }
    /// 本会话学到的正文字高；学到之前由单帧的分位估算兜底。
    var bodyHeight: CGFloat? { Self.median(bodyHeights, minimum: 2) }
    var meColor: RGB? { Self.median(meColors) }
    var otherColor: RGB? { Self.median(otherColors) }

    private static func push<T>(_ list: inout [T], _ value: T) {
        list.append(value)
        if list.count > 30 { list.removeFirst(list.count - 30) }
    }

    private static func median(_ list: [CGFloat], minimum: Int) -> CGFloat? {
        guard list.count >= minimum else { return nil }
        let sorted = list.sorted()
        return sorted[sorted.count / 2]
    }

    private static func median(_ list: [RGB]) -> RGB? {
        guard list.count >= 2 else { return nil }
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return RGB(r: mid(list.map(\.r)), g: mid(list.map(\.g)), b: mid(list.map(\.b)))
    }
}

/// 文字比较工具。OCR 每帧会有细小差异（标点、空格、个别错字），
/// 所以跨帧对齐用规范化后的字符二元组 Dice 相似度，不用字符串全等。
nonisolated enum TextMatch {
    static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        })).lowercased()
    }

    /// 0...1。两个串都已规范化。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let ca = Array(a), cb = Array(b)
        guard !ca.isEmpty, !cb.isEmpty else { return 0 }
        let shorter = Double(min(ca.count, cb.count)), longer = Double(max(ca.count, cb.count))
        guard shorter / longer >= 0.5 else { return 0 }
        if ca.count < 2 || cb.count < 2 { return 0 }
        var bigrams: [String: Int] = [:]
        for i in 0..<(ca.count - 1) { bigrams[String(ca[i...i + 1]), default: 0] += 1 }
        var hits = 0
        for i in 0..<(cb.count - 1) {
            let key = String(cb[i...i + 1])
            if let n = bigrams[key], n > 0 { hits += 1; bigrams[key] = n - 1 }
        }
        return 2 * Double(hits) / Double(ca.count - 1 + cb.count - 1)
    }
}
