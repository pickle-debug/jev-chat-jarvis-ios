import CoreGraphics
import Foundation

/// 对话列表里的一条（消息或时间分隔线）。`top/bottom` 是片段内的全局 y（帧像素单位）。
nonisolated struct TranscriptEntry: Sendable {
    let id: UUID
    let kind: BubbleKind
    var variants: [String: (text: String, count: Int)]
    var normalized: String
    var side: BubbleSide
    var sideConfidence: Double
    var top: CGFloat
    var bottom: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
    var clippedTop: Bool
    var clippedBottom: Bool
    var senderName: String?
    var quote: String?
    var observations: Int
    var misses: Int
    var firstSeen: Date
    var lastSeen: Date

    var clipped: Bool { clippedTop || clippedBottom }

    /// 多帧投票后的文字：出现次数最多的识别结果，避免单帧 OCR 抖动触发重新分析。
    var text: String {
        variants.values.max { $0.count < $1.count }?.text ?? ""
    }
}

/// 一段连续的对话。快速滚动、跳转历史导致没有重叠时，另起一段，不硬拼。
nonisolated struct TranscriptSegment: Sendable {
    let id: UUID
    var entries: [TranscriptEntry] = []
    /// 是否包含最新消息（进入会话时看到的底部那段）。只有它的新消息会触发自动分析。
    var isLive: Bool
    var coveredTop: CGFloat = .greatestFiniteMagnitude
    var coveredBottom: CGFloat = -.greatestFiniteMagnitude
    let createdAt: Date
}

/// 一帧放进哪段、放在什么位置。
nonisolated struct StitchPlacement: Sendable {
    enum Kind: Sendable {
        case extended       // 和当前段有重叠，平移后合入
        case rejoined       // 回到之前的某一段
        case newSegment     // 没有任何重叠，另起一段（上下文可能有缺口）
    }

    let kind: Kind
    let segmentID: UUID
    /// 帧坐标 + offset = 片段全局坐标。
    let offset: CGFloat
    /// 本帧相对上一帧的滚动量（同一段内才有）。负值 = 往上翻历史，正值 = 往下看更新的消息。
    let scrollDelta: CGFloat?
    /// 与本段合并掉的其他段：id 与平移量（被合并段坐标 + shift = 本段坐标）。
    let merged: [(id: UUID, shift: CGFloat)]
    let changed: Bool
}

/// 跨帧消息拼接：用多条气泡的文字 + 位置投票估计滚动偏移，几何复核后，再用气泡内部像素微调，
/// 最后把这一屏的气泡合入片段。结果是一条去重、有序、可持续维护的对话列表。
///
/// 规则对应架构文档 §6.2：
/// - 同一画面重复出现不新增消息；
/// - 有可靠重叠时只补新增部分（向上翻补历史，向下补新消息）；
/// - 没有重叠时另起一段并标记缺口，不追加到最新消息尾部；
/// - 相同文字出现在不同位置保留两条，不做全局字符串去重。
///
/// 为什么不用整行像素对齐：微信等 App 的聊天背景（尤其是照片壁纸）固定不动，只有气泡在滚动，
/// 整行亮度曲线会被背景拉向“没滚动”。这里只比对气泡文字区域内的像素。
nonisolated final class ChatStitcher {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var currentSegmentID: UUID?
    private var last: (segmentID: UUID, offset: CGFloat, bitmap: FrameBitmap, top: CGFloat, bottom: CGFloat)?

    static let maxSegments = 6
    /// 每段最多保留的条目数。超出时丢掉离当前画面最远的一端。
    static let maxEntriesPerSegment = 400

    var currentSegment: TranscriptSegment? {
        segments.first { $0.id == currentSegmentID }
    }

    var liveSegment: TranscriptSegment? {
        segments.first { $0.isLive }
    }

    func reset() {
        segments = []
        currentSegmentID = nil
        last = nil
    }

    /// 离开聊天页后回来：保留片段，但上一帧不能再作为像素微调参考。
    func markInterrupted() {
        last = nil
    }

    func ingest(_ frame: ParsedChatFrame, bitmap: FrameBitmap, preferLiveOnNewSegment: Bool) -> StitchPlacement? {
        guard !frame.messageBubbles.isEmpty else { return nil }

        var kind: StitchPlacement.Kind = .extended
        var target: UUID
        var offset: CGFloat

        let current = currentSegmentID.flatMap { id in segments.firstIndex { $0.id == id } }
        let hint = last.flatMap { $0.segmentID == currentSegmentID ? $0.offset : nil }
        if let current, var found = estimateOffset(frame.bubbles, into: segments[current], hint: hint) {
            if let last, last.segmentID == segments[current].id {
                found = refine(found, frame: frame, bitmap: bitmap, previous: last)
            }
            target = segments[current].id
            offset = found
        } else if let (index, found) = bestOtherSegment(frame.bubbles, excluding: currentSegmentID) {
            kind = .rejoined
            target = segments[index].id
            offset = found
        } else {
            kind = .newSegment
            let hasLive = segments.contains { $0.isLive }
            let segment = TranscriptSegment(id: UUID(), isLive: !hasLive || preferLiveOnNewSegment, createdAt: frame.capturedAt)
            if segment.isLive {
                for i in segments.indices { segments[i].isLive = false }
            }
            segments.append(segment)
            if segments.count > Self.maxSegments,
               let drop = segments.firstIndex(where: { !$0.isLive && $0.id != segment.id }) {
                segments.remove(at: drop)
            }
            target = segment.id
            offset = 0
        }

        guard let index = segments.firstIndex(where: { $0.id == target }) else { return nil }
        let scrollDelta: CGFloat? = {
            guard let last, last.segmentID == target, kind == .extended else { return nil }
            return offset - last.offset
        }()
        let changed = merge(frame, offset: offset, into: index)
        currentSegmentID = target
        last = (target, offset, bitmap, frame.contentTop, frame.contentBottom)

        let merged = absorbOverlappingSegments(
            into: target, viewTop: frame.contentTop + offset, viewBottom: frame.contentBottom + offset
        )
        return StitchPlacement(
            kind: kind, segmentID: target, offset: offset, scrollDelta: scrollDelta,
            merged: merged, changed: changed || !merged.isEmpty
        )
    }

    /// 画面没变（缩略图相同）时调用：可见范围内的消息多观察一次，用于判断稳定。
    func confirmStable() {
        guard let last, let index = segments.firstIndex(where: { $0.id == last.segmentID }) else { return }
        let top = last.top + last.offset, bottom = last.bottom + last.offset
        for i in segments[index].entries.indices {
            let entry = segments[index].entries[i]
            guard entry.top >= top - 1, entry.bottom <= bottom + 1, !entry.clipped else { continue }
            segments[index].entries[i].observations += 1
        }
    }

    /// 当前画面是否就是实时段的底部附近（没有在翻历史）。
    var isViewingLiveTail: Bool {
        guard let last, let live = liveSegment, last.segmentID == live.id,
              let newest = live.entries.last else { return false }
        return newest.bottom <= last.bottom + last.offset + 1 && newest.top >= last.top + last.offset - 1
    }

    // MARK: - 偏移估计

    /// 在片段里找这一屏的位置。返回帧 → 片段的平移量；证据不足返回 nil。
    private func estimateOffset(_ bubbles: [ChatBubble], into segment: TranscriptSegment, hint: CGFloat?) -> CGFloat? {
        guard !segment.entries.isEmpty else { return nil }
        struct Vote { let delta: CGFloat; let weight: Double; let entry: Int }
        var votes: [Vote] = []
        for bubble in bubbles {
            let normalized = TextMatch.normalize(bubble.text)
            guard !normalized.isEmpty else { continue }
            for (entryIndex, entry) in segment.entries.enumerated() where entry.kind == bubble.kind {
                if bubble.side != .unknown, entry.side != .unknown, bubble.side != entry.side,
                   bubble.sideConfidence >= 0.8, entry.sideConfidence >= 0.8 { continue }
                let similarity = TextMatch.similarity(normalized, entry.normalized)
                guard similarity >= 0.72 else { continue }
                // 被裁切的边不可信：优先用双方都完整的顶边对齐，否则用底边。
                let delta: CGFloat
                if !bubble.clippedTop && !entry.clippedTop {
                    delta = entry.top - bubble.rect.minY
                } else if !bubble.clippedBottom && !entry.clippedBottom {
                    delta = entry.bottom - bubble.rect.maxY
                } else {
                    continue
                }
                // 时间分隔线字数少、同一天里可能重复，只作辅助证据。
                let kindWeight = bubble.kind == .time ? 0.4 : 1.0
                let weight = similarity * min(Double(normalized.count), 12) / 12 * (bubble.clipped ? 0.5 : 1) * kindWeight
                votes.append(Vote(delta: delta, weight: weight, entry: entryIndex))
            }
        }
        guard !votes.isEmpty else { return nil }

        // 按偏移量聚类：同一真实偏移下，多条消息的 delta 应该落在一个行高以内。
        let tolerance = max(12, (bubbles.map(\.rect.height).min() ?? 20) * 0.8)
        struct Cluster { let center: CGFloat; let weight: Double; let distinct: Int }
        let clusters: [Cluster] = votes.map { seed in
            let members = votes.filter { abs($0.delta - seed.delta) <= tolerance }
            let weight = members.reduce(0) { $0 + $1.weight }
            let center = members.reduce(CGFloat(0)) { $0 + $1.delta * CGFloat($1.weight) } / CGFloat(max(weight, 0.0001))
            return Cluster(center: center, weight: weight, distinct: Set(members.map(\.entry)).count)
        }
        guard var chosen = clusters.max(by: { $0.weight < $1.weight }) else { return nil }
        let rival = clusters
            .filter { abs($0.center - chosen.center) > 2 * tolerance }
            .max { $0.weight < $1.weight }
        // 两个位置证据接近（常见于“好”“嗯”这类短句重复），靠上一帧位置消歧，无提示就放弃。
        if let rival, rival.weight > 0.8 * chosen.weight {
            guard let hint else { return nil }
            chosen = abs(rival.center - hint) < abs(chosen.center - hint) ? rival : chosen
        }
        // 至少两条消息互相印证，或者一条足够长的消息（短句单独出现不足以确认重叠）。
        guard chosen.distinct >= 2 || chosen.weight >= 0.7 else { return nil }
        // 几何复核：按这个偏移，落在片段已覆盖范围内的其他气泡也必须在对应位置找到同一条消息。
        // 格式化、相似度高的不同消息（“第 3 条…”“第 30 条…”）会给出看似一致的错误偏移，这里拦下。
        guard verify(bubbles, in: segment, offset: chosen.center) else { return nil }
        return chosen.center
    }

    private func verify(_ bubbles: [ChatBubble], in segment: TranscriptSegment, offset: CGFloat) -> Bool {
        var agree = 0, conflict = 0
        for bubble in bubbles where !bubble.clipped && bubble.kind == .message {
            let top = bubble.rect.minY + offset, bottom = bubble.rect.maxY + offset
            guard top >= segment.coveredTop + 4, bottom <= segment.coveredBottom - 4 else { continue }
            let normalized = TextMatch.normalize(bubble.text)
            let tolerance = max(14, 0.9 * bubble.rect.height)
            let atPosition = segment.entries.filter { abs($0.top - top) < tolerance && !$0.clipped && $0.kind == .message }
            if atPosition.contains(where: { TextMatch.similarity($0.normalized, normalized) >= 0.9 }) {
                agree += 1
            } else {
                conflict += 1
            }
        }
        return agree >= 1 && conflict <= agree / 3
    }

    /// 用气泡文字区域内的像素在文字估计附近 ±8 像素微调，让长截图接缝更准。
    /// 只比对气泡内部：聊天背景固定不动，整行比对会被背景拉偏。
    private func refine(
        _ offset: CGFloat, frame: ParsedChatFrame, bitmap: FrameBitmap,
        previous: (segmentID: UUID, offset: CGFloat, bitmap: FrameBitmap, top: CGFloat, bottom: CGFloat)
    ) -> CGFloat {
        guard previous.bitmap.width == bitmap.width, previous.bitmap.height == bitmap.height else { return offset }
        let base = offset - previous.offset   // 帧坐标 y → 上一帧坐标 y + base... 即 prevY = y + base
        let patches = frame.messageBubbles
            .filter { !$0.clipped && $0.rect.width > 40 }
            .filter { bubble in
                let prevTop = bubble.rect.minY + base
                return prevTop - 10 > previous.top && bubble.rect.maxY + base + 10 < previous.bottom
            }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            .prefix(3)
        guard !patches.isEmpty else { return offset }

        var totals = [Double](repeating: 0, count: 17)
        for patch in patches {
            let rect = patch.rect.insetBy(dx: 2, dy: -2).integral
            for (i, s) in (-8...8).enumerated() {
                var cost = 0.0, n = 0
                var y = Int(rect.minY)
                while y < Int(rect.maxY) {
                    let prevY = y + Int(base.rounded()) + s
                    var x = Int(rect.minX)
                    while x < Int(rect.maxX) {
                        cost += abs(bitmap.luma(x: x, y: y) - previous.bitmap.luma(x: x, y: prevY))
                        n += 1
                        x += 3
                    }
                    y += 2
                }
                totals[i] += n > 0 ? cost / Double(n) : 0
            }
        }
        let current = totals[8]
        guard let best = totals.indices.min(by: { totals[$0] < totals[$1] }), totals[best] < current * 0.8 else { return offset }
        return previous.offset + base.rounded() + CGFloat(best - 8)
    }

    private func bestOtherSegment(_ bubbles: [ChatBubble], excluding: UUID?) -> (Int, CGFloat)? {
        for (index, segment) in segments.enumerated().reversed() where segment.id != excluding {
            if let offset = estimateOffset(bubbles, into: segment, hint: nil) { return (index, offset) }
        }
        return nil
    }

    // MARK: - 合并

    /// 把这一屏的气泡合入片段。返回片段内容是否变化（新消息、文字修正或删除幽灵条目）。
    private func merge(_ frame: ParsedChatFrame, offset: CGFloat, into index: Int) -> Bool {
        var segment = segments[index]
        var changed = false
        var matched = Set<UUID>()
        let viewTop = frame.contentTop + offset, viewBottom = frame.contentBottom + offset

        for bubble in frame.bubbles {
            let normalized = TextMatch.normalize(bubble.text)
            guard !normalized.isEmpty else { continue }
            let top = bubble.rect.minY + offset, bottom = bubble.rect.maxY + offset
            let tolerance = max(14, 0.9 * bubble.rect.height)
            let candidate = segment.entries.indices
                .filter { !matched.contains(segment.entries[$0].id) && segment.entries[$0].kind == bubble.kind }
                .compactMap { i -> (Int, Double)? in
                    let entry = segment.entries[i]
                    let overlap = min(entry.bottom, bottom) - max(entry.top, top)
                    let close = abs(entry.top - top) < tolerance || overlap > 0.5 * min(entry.bottom - entry.top, bottom - top)
                    guard close else { return nil }
                    let similarity = TextMatch.similarity(normalized, entry.normalized)
                    let prefix = bubble.clipped || entry.clipped
                        ? (entry.normalized.contains(normalized) || normalized.contains(entry.normalized)) : false
                    guard similarity >= 0.6 || prefix else { return nil }
                    return (i, max(similarity, prefix ? 0.7 : 0))
                }
                .max { $0.1 < $1.1 }

            if let (i, _) = candidate {
                var entry = segment.entries[i]
                let before = entry.text
                let beforeQuote = entry.quote
                entry.observations += 1
                entry.misses = 0
                entry.lastSeen = frame.capturedAt
                if !bubble.clipped && entry.clipped {
                    // 之前只看到一半，现在看到完整气泡：以完整版本为准。
                    entry.variants = [normalized: (bubble.text, 2)]
                    entry.normalized = normalized
                    entry.top = top; entry.bottom = bottom
                    entry.clippedTop = false; entry.clippedBottom = false
                } else if !bubble.clipped {
                    var variant = entry.variants[normalized] ?? (bubble.text, 0)
                    variant.count += 1
                    variant.text = bubble.text
                    entry.variants[normalized] = variant
                    if entry.variants.count > 4,
                       let weakest = entry.variants.min(by: { $0.value.count < $1.value.count })?.key {
                        entry.variants.removeValue(forKey: weakest)
                    }
                    entry.normalized = TextMatch.normalize(entry.text)
                    entry.top = entry.top * 0.7 + top * 0.3
                    entry.bottom = entry.bottom * 0.7 + bottom * 0.3
                } else if entry.clipped {
                    // 两次都只看到一部分：保留更长的那次，完整的边以本帧为准。
                    if normalized.count > entry.normalized.count {
                        entry.variants = [normalized: (bubble.text, 1)]
                        entry.normalized = normalized
                    }
                    if !bubble.clippedTop { entry.top = top; entry.clippedTop = false }
                    if !bubble.clippedBottom { entry.bottom = bottom; entry.clippedBottom = false }
                }
                if bubble.sideConfidence > entry.sideConfidence {
                    entry.side = bubble.side
                    entry.sideConfidence = bubble.sideConfidence
                }
                // 引用块在消息下方，可能这一帧才露出来。
                if let quote = bubble.quote, (entry.quote?.count ?? 0) < quote.count { entry.quote = quote }
                entry.minX = bubble.rect.minX; entry.maxX = bubble.rect.maxX
                if entry.senderName == nil { entry.senderName = bubble.senderName }
                if entry.text != before || entry.quote != beforeQuote { changed = true }
                segment.entries[i] = entry
                matched.insert(entry.id)
            } else {
                let entry = TranscriptEntry(
                    id: UUID(), kind: bubble.kind, variants: [normalized: (bubble.text, 1)], normalized: normalized,
                    side: bubble.side, sideConfidence: bubble.sideConfidence,
                    top: top, bottom: bottom, minX: bubble.rect.minX, maxX: bubble.rect.maxX,
                    clippedTop: bubble.clippedTop, clippedBottom: bubble.clippedBottom,
                    senderName: bubble.senderName, quote: bubble.quote,
                    observations: 1, misses: 0, firstSeen: frame.capturedAt, lastSeen: frame.capturedAt
                )
                segment.entries.append(entry)
                matched.insert(entry.id)
                changed = true
            }
        }

        // 应该在可见范围却没对上的条目：只见过一次、连续三帧都不在，视为误识别（例如画中画文字）删除。
        segment.entries = segment.entries.compactMap { entry in
            guard !matched.contains(entry.id), entry.top >= viewTop, entry.bottom <= viewBottom else { return entry }
            var missed = entry
            missed.misses += 1
            if missed.observations <= 1 && missed.misses >= 3 { changed = true; return nil }
            return missed
        }
        // 之前被误当成独立消息的引用块（父消息当时不在屏内）：现在已挂到父消息上，删掉那条。
        let quotes = segment.entries.compactMap { $0.quote.map(TextMatch.normalize) }
        if !quotes.isEmpty {
            let before = segment.entries.count
            segment.entries.removeAll { entry in
                entry.kind == .message && entry.quote == nil && ChatLayoutParser.isQuoteLead(entry.text)
                    && quotes.contains { TextMatch.similarity($0, entry.normalized) >= 0.85 }
                    && entry.top >= viewTop && entry.bottom <= viewBottom
            }
            if segment.entries.count != before { changed = true }
        }
        segment.entries.sort { $0.top < $1.top }
        // 条目上限：丢掉离当前画面最远的一端。
        while segment.entries.count > Self.maxEntriesPerSegment, let first = segment.entries.first, let lastEntry = segment.entries.last {
            if viewTop - first.top > lastEntry.bottom - viewBottom {
                segment.entries.removeFirst()
                segment.coveredTop = segment.entries.first?.top ?? segment.coveredTop
            } else {
                segment.entries.removeLast()
                segment.coveredBottom = segment.entries.last?.bottom ?? segment.coveredBottom
            }
        }
        segment.coveredTop = min(segment.coveredTop, viewTop)
        segment.coveredBottom = max(segment.coveredBottom, viewBottom)
        segments[index] = segment
        return changed
    }

    /// 当前段和其他段有可靠重叠时合并（用户翻回之前看过的位置）。
    private func absorbOverlappingSegments(
        into target: UUID, viewTop: CGFloat, viewBottom: CGFloat
    ) -> [(id: UUID, shift: CGFloat)] {
        var merged: [(id: UUID, shift: CGFloat)] = []
        guard segments.count > 1, let targetIndex = segments.firstIndex(where: { $0.id == target }) else { return merged }
        // 只用当前可见的这一屏去比对，片段再长也只做一屏的计算量。
        let visible = segments[targetIndex].entries.filter { $0.top >= viewTop - 1 && $0.bottom <= viewBottom + 1 }
        let probe = visible.map { entry in
            ChatBubble(
                kind: entry.kind, text: entry.text,
                rect: CGRect(x: entry.minX, y: entry.top, width: entry.maxX - entry.minX, height: entry.bottom - entry.top),
                side: entry.side, sideConfidence: entry.sideConfidence,
                clippedTop: entry.clippedTop, clippedBottom: entry.clippedBottom,
                senderName: nil, quote: nil, color: nil
            )
        }
        for other in segments where other.id != target {
            // other 的坐标 + (-offset) = target 坐标
            guard let offset = estimateOffset(probe, into: other, hint: nil) else { continue }
            let shift = -offset
            guard var targetSegment = segments.first(where: { $0.id == target }) else { break }
            for entry in other.entries {
                let top = entry.top + shift, bottom = entry.bottom + shift
                let duplicate = targetSegment.entries.contains { existing in
                    existing.kind == entry.kind
                        && abs(existing.top - top) < max(14, 0.9 * (bottom - top))
                        && TextMatch.similarity(existing.normalized, entry.normalized) >= 0.6
                }
                if duplicate { continue }
                var moved = entry
                moved.top = top; moved.bottom = bottom
                targetSegment.entries.append(moved)
            }
            targetSegment.entries.sort { $0.top < $1.top }
            targetSegment.isLive = targetSegment.isLive || other.isLive
            targetSegment.coveredTop = min(targetSegment.coveredTop, other.coveredTop + shift)
            targetSegment.coveredBottom = max(targetSegment.coveredBottom, other.coveredBottom + shift)
            if let i = segments.firstIndex(where: { $0.id == target }) { segments[i] = targetSegment }
            segments.removeAll { $0.id == other.id }
            merged.append((other.id, shift))
        }
        return merged
    }
}
