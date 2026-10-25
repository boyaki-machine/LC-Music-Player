import Accelerate
import Foundation

/// Averages a stream of samples down by a whole factor, carrying the samples that do not fill an
/// average over to the next call. Non-finite averages become 0.
struct Decimator {
    let factor: Int
    private let box: [Float]
    private var carry: [Float] = []
    init(factor: Int) {
        self.factor = max(1, factor)
        box = Array(repeating: 1 / Float(self.factor), count: self.factor)
        carry.reserveCapacity(8192 + self.factor)
    }
    /// Appends the averages of `samples` (with any carried samples before them) to `output`.
    mutating func push(_ samples: UnsafePointer<Float>, count: Int, into output: inout [Float]) {
        carry.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        let outputs = carry.count / factor
        guard outputs > 0 else { return }
        let base = output.count
        output.append(contentsOf: repeatElement(0, count: outputs))
        output.withUnsafeMutableBufferPointer { out in
            vDSP_desamp(carry, vDSP_Stride(factor), box, out.baseAddress! + base, vDSP_Length(outputs), vDSP_Length(factor))
            for i in base..<out.count where !out[i].isFinite { out[i] = 0 }
        }
        carry.removeFirst(outputs * factor)
    }
}
