import CoreGraphics
import Foundation

/// 把一帧 OCR 行解析成聊天版式：标题、内容区、气泡、时间分隔线和发言方。
///
/// OCR 只知道“哪里有字”，不知道“谁说的”。分边用三类证据：
/// 1. 几何：对方气泡贴左（头像在左），我方气泡贴右；
/// 2. 颜色：本会话已学到的两侧气泡颜色（微信绿 / 白），其次是“彩色气泡 = 我方”；
/// 3. 会话锚点：宽气泡左右留白差不多时，比对已确认的左/右边缘中位数。
/// 都不可靠时标 `unknown`，不擅自归成对方（安卓 OCR 路线把整屏归为对方是已知缺陷）。
///
/// 样本（微信 iOS，照片壁纸）暴露的几个现实问题，这里都做了处理：
/// - 聊天背景是照片且不随消息滚动：不用“页面背景色”找输入栏，改为从底部找输入栏自身的纯色带；
/// - 引用回复块（“Gidon：不对，今晚…”）以“名字：”开头、紧贴在消息下方：挂到上一条消息的 `quote`；
/// - 图片/截图里的小字：比正文小很多的行丢弃；
/// - 通知横幅盖住标题栏：本帧找不到标题时沿用本会话学到的标题栏高度，不把横幅当成标题。
nonisolated struct ChatLayoutParser {

    func parse(
        lines rawLines: [OCRLine],
        bitmap: FrameBitmap,
        frameID: UUID,
        capturedAt: Date,
        anchors: LayoutAnchors
    ) -> ParsedChatFrame {
        let W = CGFloat(bitmap.width), H = CGFloat(bitmap.height)
        var headerBottom: CGFloat = 0.1 * H
        var titleAnchored = false

        func result(
            score: Double, title: String?, top: CGFloat, bottom: CGFloat,
            bubbles: [ChatBubble], keyboard: Bool, reason: String?
        ) -> ParsedChatFrame {
            ParsedChatFrame(
                frameID: frameID, capturedAt: capturedAt, pixelSize: bitmap.size,
                chatScore: max(0, min(1, score)), isChat: reason == nil,
                title: title, titleAnchored: titleAnchored, contentTop: top, contentBottom: bottom,
                headerBottom: min(top, headerBottom), bubbles: bubbles, keyboardVisible: keyboard,
                rejectReason: reason
            )
        }

        guard H > W * 1.3 else {
            return result(score: 0, title: nil, top: 0, bottom: H, bubbles: [], keyboard: false, reason: "横屏画面暂不支持")
        }
        let lines = Self.mergeFragments(rawLines)

        // 标题：导航栏里水平居中的那一行。状态栏时间更靠上且形如 9:41；通知横幅文字靠左，不会被当成标题。
        let titleLine = lines
            .filter { line in
                line.rect.minY > 0.035 * H && line.rect.maxY < 0.145 * H
                    && abs(line.rect.midX - W / 2) < 0.13 * W && line.rect.width < 0.8 * W
                    && !Self.isStatusBarText(line.text)
            }
            .max { $0.rect.height < $1.rect.height }
        let title = titleLine.map { Self.cleanTitle($0.text) }
        let contentTop: CGFloat
        if let titleLine {
            titleAnchored = true
            contentTop = titleLine.rect.maxY + 0.022 * H
            headerBottom = titleLine.rect.maxY + 0.012 * H
        } else {
            // 找不到标题，多半是通知横幅等浮层盖住了导航栏：内容区从浮层下沿开始，
            // 否则横幅残边会被当成聊天内容拼进长图。
            let learned = anchors.contentTopMedian ?? 0.115 * H
            let overlayBottom = lines
                .filter { $0.rect.minY < learned && $0.rect.maxY < learned + 0.06 * H && $0.rect.minY > 0.035 * H }
                .map(\.rect.maxY).max()
            contentTop = max(learned, overlayBottom.map { $0 + 0.025 * H } ?? learned)
        }

        let keyboardTop = Self.detectKeyboardTop(lines, W: W, H: H)

        // 页面背景色只作“气泡是否彩色”的弱参考；照片壁纸下它不代表输入栏或气泡外的颜色。
        let midRegion = CGRect(x: 0.03 * W, y: 0.25 * H, width: 0.94 * W, height: 0.4 * H)
        let pageColor = bitmap.dominantColor(in: midRegion, excluding: lines.map(\.rect))

        var contentBottom: CGFloat = 0.885 * H
        var bottomDetected = false
        if let bar = Self.detectInputBarTop(bitmap), bar > 0.8 * H {
            contentBottom = bar
            bottomDetected = true
        }
        if let keyboardTop {
            contentBottom = min(contentBottom, keyboardTop - (bottomDetected ? 0.06 : 0.12) * H)
        }
        guard contentBottom > contentTop + 0.2 * H else {
            return result(score: 0, title: title, top: contentTop, bottom: contentBottom, bubbles: [],
                          keyboard: keyboardTop != nil, reason: "可见内容区太小")
        }

        let zoneLines = lines.filter { $0.rect.midY > contentTop && $0.rect.midY < contentBottom }
        let edgeCount = zoneLines.filter { $0.rect.minX < 0.06 * W || $0.rect.maxX > 0.94 * W }.count
        let edgeRatio = zoneLines.isEmpty ? 1 : Double(edgeCount) / Double(zoneLines.count)
        // 正文行高：取偏上分位，避免图片小字、引用小字把基准拉低。
        let heights = zoneLines.map(\.rect.height).sorted()
        let bodyHeight = heights.isEmpty ? 0 : heights[min(heights.count - 1, heights.count * 7 / 10)]

        var contentLines: [OCRLine] = []
        var timeBubbles: [ChatBubble] = []
        for line in zoneLines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            // 图片、截图、表情里的小字不是聊天消息。
            if zoneLines.count >= 3 && line.rect.height < 0.62 * bodyHeight { continue }
            let centered = abs(line.rect.midX - W / 2) < 0.06 * W
                && abs(line.rect.minX - (W - line.rect.maxX)) < 0.1 * W
            if Self.isTimestamp(text) {
                if centered {
                    timeBubbles.append(ChatBubble(
                        kind: .time, text: text, rect: line.rect, side: .unknown, sideConfidence: 0,
                        clippedTop: false, clippedBottom: false, senderName: nil, quote: nil, color: nil
                    ))
                }
                continue
            }
            if Self.isChrome(text) || Self.isSystemNotice(text) { continue }
            let small = zoneLines.count >= 3 ? line.rect.height < 0.85 * bodyHeight : line.rect.width < 0.45 * W
            if centered && small && line.rect.width < 0.6 * W { continue }
            contentLines.append(line)
        }

        // 行 → 气泡：纵向间距小于行高的 0.75 且左边缘对齐，视为同一气泡的续行。
        var groups: [[OCRLine]] = []
        for line in contentLines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            if var group = groups.last, let last = group.last, let first = group.first {
                let gap = line.rect.minY - last.rect.maxY
                let lineHeight = max(min(last.rect.height, line.rect.height), 1)
                if gap < 0.75 * lineHeight && abs(line.rect.minX - first.rect.minX) < 0.035 * W {
                    group.append(line)
                    groups[groups.count - 1] = group
                    continue
                }
            }
            groups.append([line])
        }

        // 引用块：以“名字：”开头，字号不大于正文，紧贴在一条消息下方（比消息间距小）。
        // 挂到上方那条消息的 `quote`；上方消息已滚出屏幕时丢弃，不当成新消息。
        var quoteFor: [Int: String] = [:]
        var skip = Set<Int>()
        // 实测 1280 帧里引用字号与正文只差 1–2 像素，行高不可靠，靠“名字：”前缀 + 紧贴间距判断。
        for (i, group) in groups.enumerated() where Self.isQuoteLead(group[0].text) {
            var parent = i - 1
            while parent >= 0 && skip.contains(parent) { parent -= 1 }
            // 本屏最上面的“名字：”块：它引用的那条消息已滚出屏幕，丢弃（下一帧会连同上方消息一起看到）。
            if parent < 0 { skip.insert(i); continue }
            guard let above = groups[parent].last, group[0].rect.minY - above.rect.maxY < 2.3 * bodyHeight else { continue }
            skip.insert(i)
            let text = Self.join(group.map(\.text))
            quoteFor[parent] = quoteFor[parent].map { $0 + " " + text } ?? text
        }

        // 群聊昵称：单行、字号更小、紧贴在下一个气泡上方且左对齐。
        var senderNames: [Int: String] = [:]
        if groups.count >= 2 {
            for i in 0..<(groups.count - 1) where groups[i].count == 1 && !skip.contains(i) && !skip.contains(i + 1) {
                let label = groups[i][0], next = groups[i + 1][0]
                let gap = next.rect.minY - label.rect.maxY
                if label.rect.height < 0.85 * next.rect.height,
                   gap < 1.4 * next.rect.height,
                   abs(label.rect.minX - next.rect.minX) < 0.03 * W,
                   label.text.count <= 16,
                   label.rect.maxX < 0.7 * W {
                    senderNames[i + 1] = label.text
                    skip.insert(i)
                }
            }
        }

        var bubbles: [ChatBubble] = timeBubbles
        for (index, group) in groups.enumerated() where !skip.contains(index) {
            let rect = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
            let text = Self.cleanBubbleText(Self.join(group.map(\.text)))
            guard !text.isEmpty else { continue }
            let lineHeight = group.map(\.rect.height).min() ?? rect.height
            let color = Self.bubbleColor(rect: rect, lineHeight: lineHeight, bitmap: bitmap)
            let (side, confidence) = Self.classifySide(rect: rect, color: color, page: pageColor, anchors: anchors, W: W)
            bubbles.append(ChatBubble(
                kind: .message, text: text, rect: rect, side: side, sideConfidence: confidence,
                clippedTop: rect.minY < contentTop + 0.8 * lineHeight,
                clippedBottom: rect.maxY > contentBottom - 0.5 * lineHeight,
                senderName: senderNames[index], quote: quoteFor[index], color: color
            ))
        }
        bubbles.sort { $0.rect.minY < $1.rect.minY }

        // 聊天页打分。聊天气泡两侧有头像，几乎不贴屏幕边缘；会话列表、文章、朋友圈大量贴边。
        let messages = bubbles.filter { $0.kind == .message }
        let sided = messages.filter { $0.side != .unknown && $0.sideConfidence >= 0.75 }
        var score = min(Double(messages.count), 4) * 0.1
        score += edgeRatio <= 0.1 ? 0.25 : (edgeRatio <= 0.25 ? 0.1 : -0.3)
        score += sided.isEmpty ? 0 : 0.2
        score += sided.contains { $0.side == .me } && sided.contains { $0.side == .other } ? 0.15 : 0
        score += titleLine == nil ? 0 : 0.1
        score += bottomDetected ? 0.05 : 0
        score += timeBubbles.isEmpty ? 0 : 0.05

        let reason: String?
        if messages.isEmpty {
            reason = "没有识别到聊天气泡"
        } else if score < 0.6 {
            reason = edgeRatio > 0.25 ? "版式不像聊天页（文字贴边较多）" : "聊天页特征不足"
        } else {
            reason = nil
        }
        return result(score: score, title: title, top: contentTop, bottom: contentBottom,
                      bubbles: bubbles, keyboard: keyboardTop != nil, reason: reason)
    }

    // MARK: - 分边

    /// 气泡背景色：文字框外侧一点点，仍在气泡内边距里。
    private static func bubbleColor(rect: CGRect, lineHeight: CGFloat, bitmap: FrameBitmap) -> RGB? {
        let pad = max(4, 0.35 * lineHeight)
        return bitmap.medianColor(at: [
            CGPoint(x: rect.minX - pad, y: rect.midY),
            CGPoint(x: rect.maxX + pad, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.minY - pad * 0.8),
            CGPoint(x: rect.midX, y: rect.maxY + pad * 0.8),
            CGPoint(x: rect.minX - pad, y: rect.minY + 2),
            CGPoint(x: rect.maxX + pad, y: rect.maxY - 2)
        ])
    }

    private static func classifySide(
        rect: CGRect, color: RGB?, page: RGB?, anchors: LayoutAnchors, W: CGFloat
    ) -> (BubbleSide, Double) {
        let leftGap = rect.minX / W, rightGap = (W - rect.maxX) / W
        let bias = rightGap - leftGap   // >0：文字靠左 → 对方

        var colored = false
        var distinct = false
        if let color, let page {
            let distance = color.distance(to: page)
            colored = color.saturation > 0.15 && distance > 30
            distinct = distance > 12
        } else if let color {
            colored = color.saturation > 0.2
        }
        // 学到的两侧颜色投票。
        var colorVote: BubbleSide?
        if let color, let meColor = anchors.meColor, let otherColor = anchors.otherColor,
           meColor.distance(to: otherColor) > 40 {
            let dMe = color.distance(to: meColor), dOther = color.distance(to: otherColor)
            if dMe < 0.5 * dOther && dMe < 45 { colorVote = .me }
            if dOther < 0.5 * dMe && dOther < 45 { colorVote = .other }
        }

        if bias > 0.12 || bias < -0.12 {
            let side: BubbleSide = bias > 0 ? .other : .me
            if let colorVote { return (side, colorVote == side ? 0.97 : 0.7) }
            if side == .other { return (.other, colored ? 0.75 : 0.92) }
            return (.me, colored ? 0.96 : 0.9)
        }
        if let colorVote { return (colorVote, 0.85) }
        if colored { return (.me, 0.8) }

        let tolerance = 0.02 * W
        let nearOther = anchors.otherLeftMedian.map { abs(rect.minX - $0) < tolerance } ?? false
        let nearMe = anchors.meRightMedian.map { abs(rect.maxX - $0) < tolerance } ?? false
        if nearOther && !nearMe { return (.other, 0.75) }
        if nearMe && !nearOther { return (.me, 0.75) }
        // 中性色但和页面背景不同：多半是对方的白/灰气泡。证据弱，低于自动分析阈值。
        if distinct { return (.other, 0.55) }
        return (.unknown, 0)
    }

    // MARK: - 键盘和输入栏

    private static func detectKeyboardTop(_ lines: [OCRLine], W: CGFloat, H: CGFloat) -> CGFloat? {
        let keys = lines.filter { $0.rect.midY > 0.55 * H && isKeyLabel($0.text) }
        guard keys.count >= 3 else { return nil }
        var rows: [[OCRLine]] = []
        for key in keys.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = rows.last?.last, abs(last.rect.midY - key.rect.midY) < 0.02 * H {
                rows[rows.count - 1].append(key)
            } else {
                rows.append([key])
            }
        }
        let dense = rows.filter { row in row.count >= 3 || row.contains { isKeyRow($0.text) } }
        guard dense.count >= 2 else { return nil }
        return dense.flatMap { $0 }.map(\.rect.minY).min()
    }

    /// 输入栏顶部：沿屏幕两侧 2–7 像素的窄边，从底部附近取输入栏自身颜色，向上走到颜色变化处。
    /// 窄边避开了头像和输入栏按钮；输入栏是纯色带，而上方是页面背景或照片壁纸。
    static func detectInputBarTop(_ bitmap: FrameBitmap) -> CGFloat? {
        let w = bitmap.width
        func edge(_ y: Int) -> RGB? {
            bitmap.medianColor(at: [
                CGPoint(x: 3, y: y), CGPoint(x: 6, y: y),
                CGPoint(x: w - 4, y: y), CGPoint(x: w - 7, y: y)
            ])
        }
        guard let bar = edge(Int(Double(bitmap.height) * 0.955)) else { return nil }
        var mismatch = 0
        var y = Int(Double(bitmap.height) * 0.955)
        let stop = Int(Double(bitmap.height) * 0.6)
        while y > stop {
            if let sample = edge(y), sample.distance(to: bar) > 14 {
                mismatch += 1
                if mismatch >= 5 { return CGFloat(y + 5 * 2) }
            } else {
                mismatch = 0
            }
            y -= 2
        }
        return nil
    }

    // MARK: - 文本规则

    static func isKeyLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.count <= 2 { return true }
        if isKeyRow(text) { return true }
        let words: Set<String> = [
            "space", "空格", "换行", "发送", "return", "abc", "123", "拼音", "分词", "重输",
            "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz", "@#/", "确认", "完成", "go", "send", "选拼音"
        ]
        return words.contains(text.lowercased())
    }

    /// Vision 可能把一整排字母键识别成一行，例如 “QWERTYUIOP”。
    static func isKeyRow(_ raw: String) -> Bool {
        let letters = raw.uppercased().filter { !$0.isWhitespace }
        guard letters.count >= 3 else { return false }
        return ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"].contains { $0.contains(letters) }
    }

    static func isStatusBarText(_ text: String) -> Bool {
        if text.range(of: #"^\d{1,2}[:：]\d{2}$"#, options: .regularExpression) != nil { return true }
        if text.contains("%") { return true }
        return ["中国移动", "中国联通", "中国电信", "5G", "4G", "LTE"].contains { text.contains($0) }
    }

    static func isTimestamp(_ text: String) -> Bool {
        let patterns = [
            #"^(昨天|前天|今天|星期[一二三四五六日天]|周[一二三四五六日天])?\s*(上午|下午|中午|晚上|凌晨|早上)?\s*\d{1,2}[:：]\d{2}$"#,
            #"^\d{4}年\d{1,2}月\d{1,2}日.*$"#,
            #"^\d{1,2}月\d{1,2}日.*\d{1,2}[:：]\d{2}$"#,
            #"^\d{1,4}[/-]\d{1,2}([/-]\d{1,2})?\s+\d{1,2}[:：]\d{2}$"#,
            #"^(Yesterday|Today)\s+\d{1,2}:\d{2}(\s?[AP]M)?$"#
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// 引用块开头：“名字：” 或 “名字:”（名字可含空格、间隔号）。
    static func isQuoteLead(_ text: String) -> Bool {
        text.range(of: #"^[^：:]{1,30}[：:]"#, options: .regularExpression) != nil
    }

    /// 聊天页里的界面元素文字，不是消息。
    static func isChrome(_ text: String) -> Bool {
        if text.range(of: #"^\d+条新消息$"#, options: .regularExpression) != nil { return true }
        return ["按住 说话", "按住说话", "iMessage", "以下是新消息", "查看更多消息"].contains(text)
    }

    static func isSystemNotice(_ text: String) -> Bool {
        let keywords = [
            "撤回了一条消息", "你已添加了", "现在可以开始聊天了", "拍了拍", "加入了群聊",
            "消息已发出，但被对方拒收了", "开启了朋友验证", "以上是打招呼的内容"
        ]
        return keywords.contains { text.contains($0) }
    }

    static func cleanTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["‹", "<", "〈"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// 标题正在加载或只是临时状态，不能当作会话身份（安卓 isTransientTitle 的等价物）。
    static func isTransientTitle(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return true }
        let words = ["对方正在输入", "正在输入", "连接中", "正在连接", "未连接", "收取中", "加载中", "Connecting", "Loading"]
        return words.contains { title.localizedCaseInsensitiveContains($0) }
    }

    /// 去掉飞书等 App 粘在气泡尾部的已读标记和时间；语音条时长换成占位。
    static func cleanBubbleText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^\d{1,2}\s?["″”']{1,2}$"#, options: .regularExpression) != nil { return "[语音]" }
        var changed = true
        while changed && !text.isEmpty {
            changed = false
            for tail in ["已读", "未读"] where text.hasSuffix(tail) {
                text = String(text.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            if let range = text.range(of: #"\s*\d{1,2}[:：]\d{2}$"#, options: .regularExpression), range.lowerBound != text.startIndex {
                text = String(text[..<range.lowerBound])
                changed = true
            }
        }
        return text
    }

    /// 同一气泡的多行：中日韩字符之间直接相连，其他情况补空格。
    static func join(_ parts: [String]) -> String {
        parts.reduce("") { acc, part in
            guard let last = acc.last, let first = part.first else { return acc + part }
            return acc + (isCJK(last) || isCJK(first) ? "" : " ") + part
        }
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    /// Vision 偶尔把同一视觉行拆成几段（emoji、中英混排处），先按行合并。
    static func mergeFragments(_ lines: [OCRLine]) -> [OCRLine] {
        var result: [OCRLine] = []
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            let index = result.lastIndex { existing in
                let overlap = min(existing.rect.maxY, line.rect.maxY) - max(existing.rect.minY, line.rect.minY)
                let minHeight = min(existing.rect.height, line.rect.height)
                let gap = max(line.rect.minX - existing.rect.maxX, existing.rect.minX - line.rect.maxX)
                return overlap >= 0.6 * minHeight && gap < 1.2 * minHeight
            }
            guard let index else { result.append(line); continue }
            let existing = result[index]
            let ordered = existing.rect.minX <= line.rect.minX ? [existing, line] : [line, existing]
            result[index] = OCRLine(
                text: join(ordered.map(\.text)),
                rect: existing.rect.union(line.rect),
                confidence: min(existing.confidence, line.confidence)
            )
        }
        return result
    }
}
