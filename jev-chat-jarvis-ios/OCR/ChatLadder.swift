import CoreGraphics
import Foundation

/// 会移动的长梯：一段会话最近 N 张采样帧（默认 10）在同一纵向坐标系里的拼接。
///
/// - 每一“级”是一帧的聊天内容区，位置来自 `ChatStitcher` 的偏移（文字对齐 + 气泡像素微调）；
/// - **去重**：旧级如果已被其他级（含新级）完整、首尾相接地覆盖，就删掉。用户停住不动、
///   来回小幅滑动时不会堆积重复画面，10 张额度只留给真正不同的位置；
/// - **会移动**：超出上限时，从梯子两端里删掉更旧的那一端。用户从下往上翻，底部旧画面依次掉出；
///   翻回底部，顶部掉出。中间的级不会被删，梯子始终连续；
/// - **新的覆盖旧的**：渲染时按采集时间从旧到新画，新帧覆盖重叠区域。新消息出现在旧画面空白处时，
///   以新帧为准；接缝挪到气泡之间的空隙，不切断气泡。
///
/// 只在内存中，停止或清空后丢弃；用户主动导出时才生成整图。
nonisolated final class ChatLadder {
    struct Rung {
        let id: UUID
        let capturedAt: Date
        let order: Int
        /// 内容区顶部在梯子坐标里的位置。
        var top: CGFloat
        let height: Int
        let jpeg: Data
        /// 气泡（含内边距和头像高度）占用的纵向区间，梯子坐标。接缝不能落在这些区间里。
        var bands: [(lower: CGFloat, upper: CGFloat)]
        /// 这一帧的标题栏和输入栏，渲染时给整张长图加头尾。
        let header: (jpeg: Data, height: Int)?
        let footer: (jpeg: Data, height: Int)?

        var bottom: CGFloat { top + CGFloat(height) }
    }

    static let defaultCapacity = 10

    let width: Int
    private(set) var capacity: Int
    private(set) var rungs: [Rung] = []
    private var nextOrder = 0

    init(width: Int, capacity: Int = ChatLadder.defaultCapacity) {
        self.width = width
        self.capacity = max(2, capacity)
    }

    var top: CGFloat? { rungs.map(\.top).min() }
    var bottom: CGFloat? { rungs.map(\.bottom).max() }
    var span: Int {
        guard let top, let bottom else { return 0 }
        return Int(bottom - top)
    }

    /// 放入一帧。`offset`：帧坐标 + offset = 梯子坐标。
    func add(
        bitmap: FrameBitmap, contentTop: CGFloat, contentBottom: CGFloat, offset: CGFloat,
        bubbleRects: [CGRect], capturedAt: Date, header: (jpeg: Data, height: Int)?, footer: (jpeg: Data, height: Int)?
    ) {
        guard bitmap.width == width else { return }
        let cropTop = Int(contentTop.rounded()), cropHeight = Int((contentBottom - contentTop).rounded())
        guard cropHeight > 40, let jpeg = bitmap.jpegStrip(y: cropTop, height: cropHeight) else { return }
        let shift = offset.rounded()
        let pad = max(12, 0.035 * CGFloat(width))
        let bands = bubbleRects.map { (lower: $0.minY - pad + shift, upper: $0.maxY + pad + shift) }
        let rung = Rung(
            id: UUID(), capturedAt: capturedAt, order: nextOrder, top: CGFloat(cropTop) + shift,
            height: cropHeight, jpeg: jpeg, bands: bands, header: header, footer: footer
        )
        nextOrder += 1
        rungs.append(rung)
        prune()
        enforceCapacity()
    }

    /// 合并另一段的梯子（`ChatStitcher` 判断两段重叠时）。other 坐标 + shift = 本梯坐标。
    func absorb(_ other: ChatLadder, shift rawShift: CGFloat) {
        guard other.width == width else { return }
        let shift = rawShift.rounded()
        for var rung in other.rungs {
            rung.top += shift
            rung.bands = rung.bands.map { ($0.lower + shift, $0.upper + shift) }
            rungs.append(rung)
        }
        prune()
        enforceCapacity()
    }

    /// 设置里调整张数后立即生效：调小时按同样规则从两端移出更旧的画面。
    func setCapacity(_ value: Int) {
        capacity = max(2, value)
        enforceCapacity()
    }

    // MARK: - 去重与移动

    private func isNewer(_ a: Rung, than b: Rung) -> Bool {
        a.capturedAt != b.capturedAt ? a.capturedAt > b.capturedAt : a.order > b.order
    }

    /// 删掉被其他级完整覆盖的旧级。最新的一级永远保留。
    private func prune() {
        guard rungs.count > 1 else { return }
        var changed = true
        while changed {
            changed = false
            guard let newest = rungs.max(by: { isNewer($1, than: $0) }) else { return }
            for candidate in rungs.sorted(by: { isNewer($1, than: $0) }) where candidate.id != newest.id {
                let others = rungs.filter { $0.id != candidate.id }
                if Self.isCovered(candidate, by: others) {
                    rungs.removeAll { $0.id == candidate.id }
                    changed = true
                    break
                }
            }
        }
    }

    /// 其他级能否首尾相接地覆盖 `rung` 的范围。相邻两级至少重叠 10%，保证能找到不切气泡的接缝。
    private static func isCovered(_ rung: Rung, by others: [Rung]) -> Bool {
        let tolerance: CGFloat = 6
        let minOverlap = 0.1 * CGFloat(rung.height)
        var reach: CGFloat?
        while true {
            let limit = reach.map { $0 - minOverlap } ?? (rung.top + tolerance)
            guard let next = others.filter({ $0.top <= limit }).map(\.bottom).max(),
                  next > (reach ?? -.greatestFiniteMagnitude) else { return false }
            reach = next
            if next >= rung.bottom - tolerance { return true }
        }
    }

    /// 超出上限时，从最上和最下两级里删掉更旧的那个，梯子保持连续。
    private func enforceCapacity() {
        while rungs.count > capacity {
            guard let upper = rungs.min(by: { $0.top < $1.top }),
                  let lower = rungs.max(by: { $0.bottom < $1.bottom }), upper.id != lower.id else { return }
            let drop = isNewer(upper, than: lower) ? lower : upper
            rungs.removeAll { $0.id == drop.id }
        }
    }

    // MARK: - 渲染

    /// 竖向拼成一张图：标题栏 + 梯子 + 输入栏。超过 `maxPixelHeight` 时整体等比缩小。
    func render(maxPixelHeight: Int) -> CGImage? {
        guard let top, let bottom else { return nil }
        let header = rungs.filter { $0.header != nil }.max(by: { isNewer($1, than: $0) })?.header
        // 输入栏只在最底部那一级自带时才加（它确实是会话底部的画面）。
        let footer = rungs.max(by: { $0.bottom < $1.bottom })?.footer
        let headerHeight = header?.height ?? 0, footerHeight = footer?.height ?? 0
        let bodyHeight = Int(bottom - top)
        let fullHeight = headerHeight + bodyHeight + footerHeight
        guard fullHeight > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixelHeight) / CGFloat(fullHeight))
        let outWidth = max(1, Int(CGFloat(width) * scale)), outHeight = max(1, Int(CGFloat(fullHeight) * scale))
        guard let context = CGContext(
            data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        // CGContext 原点在左下；y 为从整图顶部算起的像素。
        func draw(_ image: CGImage, y: CGFloat, height: CGFloat) {
            context.draw(image, in: CGRect(
                x: 0, y: CGFloat(outHeight) - (y + height) * scale, width: CGFloat(outWidth), height: height * scale
            ))
        }
        let bodyOrigin = CGFloat(headerHeight) - top

        var painted: [(lower: CGFloat, upper: CGFloat)] = []
        for rung in rungs.sorted(by: { isNewer($1, than: $0) }) {
            var lower = rung.top, upper = rung.bottom
            // 上边压在已画区域里：接缝往下挪到气泡空隙（新帧的上边缘可能正好切在气泡中间）。
            if let coveredTo = painted.filter({ $0.lower <= lower + 0.5 && $0.upper > lower }).map(\.upper).max() {
                lower = Self.gap(in: rung, from: lower + 4, to: min(coveredTo, upper) - 4, downward: true) ?? lower
            }
            if let coveredFrom = painted.filter({ $0.lower < upper && $0.upper >= upper - 0.5 }).map(\.lower).min() {
                upper = Self.gap(in: rung, from: upper - 4, to: max(coveredFrom, lower) + 4, downward: false) ?? upper
            }
            lower = max(lower, rung.top); upper = min(upper, rung.bottom)
            guard upper - lower >= 2, let image = FrameBitmap.decodeJPEG(rung.jpeg),
                  let slice = image.cropping(to: CGRect(
                    x: 0, y: Int(lower - rung.top), width: width, height: Int(upper - lower)))
            else { continue }
            draw(slice, y: bodyOrigin + lower, height: upper - lower)
            painted.append((lower, upper))
        }
        if let header, let image = FrameBitmap.decodeJPEG(header.jpeg) {
            draw(image, y: 0, height: CGFloat(header.height))
        }
        if let footer, let image = FrameBitmap.decodeJPEG(footer.jpeg) {
            draw(image, y: CGFloat(headerHeight + bodyHeight), height: CGFloat(footer.height))
        }
        return context.makeImage()
    }

    /// 在 [from, to] 里找一行不在任何气泡区间里的位置。downward：从 from 往下找，否则往上找。
    private static func gap(in rung: Rung, from: CGFloat, to: CGFloat, downward: Bool) -> CGFloat? {
        guard downward ? from <= to : from >= to else { return nil }
        var y = from
        while downward ? y <= to : y >= to {
            if !rung.bands.contains(where: { y >= $0.lower && y <= $0.upper }) { return y.rounded() }
            y += downward ? 2 : -2
        }
        return nil
    }
}
