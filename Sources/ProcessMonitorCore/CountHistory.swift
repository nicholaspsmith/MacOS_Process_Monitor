import Foundation

// MARK: - Sparkline history

public final class CountHistory {
    private var values: [Int] = []
    private let maxLen: Int
    public init(maxLen: Int) { self.maxLen = maxLen }

    public func record(_ v: Int) {
        values.append(v)
        if values.count > maxLen { values.removeFirst() }
    }

    public func sparkline() -> String {
        let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        guard !values.isEmpty else { return "" }
        let lo = values.min()!
        let hi = values.max()!
        guard hi > lo else {
            return String(repeating: bars[3], count: values.count)
        }
        let span = Double(hi - lo)
        return values.map { v in
            let frac = Double(v - lo) / span
            let idx = min(bars.count - 1, Int(frac * Double(bars.count)))
            return bars[idx]
        }.joined()
    }

    public var range: (min: Int, max: Int)? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return (lo, hi)
    }
}
