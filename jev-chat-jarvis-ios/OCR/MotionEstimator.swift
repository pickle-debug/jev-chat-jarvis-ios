import CoreGraphics
import Foundation

/// 一帧的降采样灰度图，用于“没有文字可对齐”时的画面位移估计。
nonisolated struct MotionFrame: Sendable {
    let width: Int
    let height: Int
    /// 降采样后的灰度值，行优先。
    let gray: [UInt8]
    /// 参与比对的纵向范围（聊天内容区，降采样坐标）。
    let top: Int
    let bottom: Int
    let step: Int

    init?(bitmap: FrameBitmap, contentTop: CGFloat, contentBottom: CGFloat) {
        let step = max(2, Int((CGFloat(bitmap.width) / 160).rounded()))
        let width = bitmap.width / step, height = bitmap.height / step
        guard width > 8, height > 8 else { return nil }
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                gray[y * width + x] = UInt8(min(255, bitmap.luma(x: x * step, y: y * step)))
            }
        }
        self.width = width
        self.height = height
        self.gray = gray
        self.step = step
        self.top = max(0, Int(contentTop) / step)
        self.bottom = min(height, Int(contentBottom) / step)
    }
}

/// 没有文字可对齐时（整屏都是图片消息），用画面本身估计两帧之间的滚动量。
///
/// 关键在于聊天背景固定不动：直接整帧比对会被背景拉向“没滚动”。这里
/// ① 只取“这一帧与上一帧同位置明显不同”的像素——背景不变，它们一定来自随滚动移动的内容；
/// ② 用该像素自身的纵向对比度归一化误差，让强边缘说了算；
/// ③ 在文字对齐成功的帧对上学习静止掩码，之后直接跳过背景像素。
///
/// 成本函数在真位移处是明显的谷，所以先粗后细搜索：粗查大致位置，再逐步收敛到 1 个降采样像素。
/// 结果只作方向与大小的估计，文字证据始终优先。
nonisolated final class MotionEstimator {
    /// 每个降采样像素的累计证据：正 = 不随聊天滚动的背景，负 = 随内容移动。
    private var mask: [Int8] = []
    private var maskWidth = 0
    private var maskHeight = 0
    /// 累计到这个值才当作背景跳过，防止一两次噪声就把内容像素屏蔽掉。
    private let staticThreshold: Int8 = 2
    /// 一次位移最多覆盖内容区高度的比例（两帧之间常接近一屏，留一点重叠）。
    private let maxShiftRatio = 0.8
    /// 归一化误差的样本数下限。两帧至少要有一块足够大的重叠区域才算数，
    /// 否则少量像素（例如画面上下都有的相似结构）会给出假的位移。
    private let minPoints = 200
    /// 上一次估计中估算过成本的候选位移数量（用于诊断）。
    private(set) var lastCandidates = 0

    func reset() {
        mask = []
        maskWidth = 0
        maskHeight = 0
    }

    /// 已知位移时学习静止掩码。`shift`：当前帧坐标 + shift = 上一帧坐标（降采样像素）。
    func learn(current: MotionFrame, previous: MotionFrame, shift: Int) {
        guard current.width == previous.width, current.height == previous.height, shift != 0,
              abs(shift) < previous.height else { return }
        if mask.count != current.width * current.height {
            mask = [Int8](repeating: 0, count: current.width * current.height)
            maskWidth = current.width
            maskHeight = current.height
        }
        for y in current.top..<current.bottom {
            let prevY = y + shift
            guard prevY >= previous.top, prevY < previous.bottom else { continue }
            for x in 0..<current.width {
                let i = y * current.width + x
                let cur = Int(current.gray[i])
                let same = abs(cur - Int(previous.gray[y * previous.width + x]))
                let moved = abs(cur - Int(previous.gray[prevY * previous.width + x]))
                if same + 12 < moved {
                    mask[i] = min(mask[i] + 1, 8)    // 同位置更像 → 背景（静止）
                } else if moved + 12 < same {
                    mask[i] = max(mask[i] - 1, -8)   // 位移后更像 → 随滚动移动的内容
                }
            }
        }
    }

    /// 估计当前帧相对上一帧的纵向位移（原始帧像素）。返回 nil 表示证据不足。
    ///
    /// - Parameter predicted: 上一帧的位移（降采样像素）。对称匹配分不清正负时（例如相隔一屏、
    ///   图像上下都有相似结构），用它挑更接近常识的那个：滚动速度不会突变。没有预测值时取全局最优。
    func estimate(current: MotionFrame, previous: MotionFrame, predicted: Int? = nil) -> Int? {
        guard current.width == previous.width, current.height == previous.height else { return nil }
        let usable = current.bottom - current.top
        guard usable > 30 else { return nil }
        let maxShift = Int(Double(usable) * maxShiftRatio)

        lastCandidates = 0
        var best: (shift: Int, cost: Double)?
        var zeroCost: Double?
        // 先粗查（步长 5），再在最优附近逐步收敛到步长 1。
        var stride = 5
        var center = 0
        var range = maxShift
        while true {
            var candidate = center - range
            while candidate <= center + range {
                if abs(candidate) <= maxShift, let cost = cost(current: current, previous: previous, shift: candidate) {
                    lastCandidates += 1
                    if candidate == 0 { zeroCost = cost }
                    if best == nil || cost < best!.cost { best = (candidate, cost) }
                }
                candidate += stride
            }
            guard let currentBest = best else { return nil }
            if stride == 1 { break }
            center = currentBest.shift
            range = stride * 2
            stride = max(1, stride / 2)
        }
        guard var chosen = best else { return nil }
        // 对称歧义：另一侧有一个几乎一样好的候选，用预测位移（上一帧的滚动量）来消解。
        if let predicted, abs(predicted) > 4, (predicted < 0) != (chosen.shift < 0),
           let mirror = cost(current: current, previous: previous, shift: -chosen.shift),
           mirror < chosen.cost * 1.15 {
            chosen = (-chosen.shift, mirror)
        }
        let bestCost = chosen.cost
        // 零位移更优 = 画面基本没动，不是滚动。
        if let zeroCost, zeroCost <= bestCost { return nil }
        // 以最优点为中心，离得越远应越差：左右各取远近两档，逐档上升才算真的谷。
        func ring(_ distances: [Int]) -> Double? {
            var values: [Double] = []
            for d in distances {
                for sign in [-1, 1] {
                    if let value = cost(current: current, previous: previous, shift: chosen.shift + sign * d) {
                        values.append(value)
                    }
                }
            }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        var threshold = bestCost
        for level in [ring([2, 3]), ring([6, 8]), ring([14, 18])] {
            guard let level else { continue }
            guard level > threshold * 0.98 else { return nil }
            threshold = level
        }
        // 远处还有同样好的候选（画面重复，例如连续几张相似的图），且预测位移也帮不上忙：放弃。
        var rivalCost: Double?
        var rivalShift: Int?
        for shift in Swift.stride(from: -maxShift, through: maxShift, by: 3) where abs(shift - chosen.shift) > 8 {
            if let value = cost(current: current, previous: previous, shift: shift), value < (rivalCost ?? .infinity) {
                rivalCost = value
                rivalShift = shift
            }
        }
        if let rivalCost, let rivalShift, rivalCost < bestCost * 1.05 {
            guard let predicted, abs(predicted - chosen.shift) < abs(predicted - rivalShift) else { return nil }
        }
        return chosen.shift * current.step
    }

    /// 归一化对齐误差：只统计“同位置不同 + 有局部对比”的像素。越小越对齐。
    private func cost(current: MotionFrame, previous: MotionFrame, shift: Int) -> Double? {
        var total = 0.0
        var count = 0
        for row in current.top..<current.bottom {
            let previousY = row + shift
            guard previousY - 1 >= previous.top, previousY + 1 < previous.bottom else { continue }
            for x in Swift.stride(from: 1, to: current.width - 1, by: 2) {
                let index = row * current.width + x
                guard !isStatic(row, x) else { continue }
                let value = Int(current.gray[index])
                if abs(value - Int(previous.gray[index])) < 25 { continue }
                let gradient = abs(Int(current.gray[index - current.width]) - Int(current.gray[index + current.width]))
                if gradient < 20 { continue }
                let previousValue = Int(previous.gray[previousY * previous.width + x])
                total += abs(Double(value - previousValue)) / (Double(gradient) + 12)
                count += 1
            }
        }
        guard count >= minPoints else { return nil }
        return total / Double(count)
    }

    private func isStatic(_ y: Int, _ x: Int) -> Bool {
        guard mask.count == maskWidth * maskHeight, y >= 0, y < maskHeight, x >= 0, x < maskWidth else { return false }
        return mask[y * maskWidth + x] >= staticThreshold
    }
}
