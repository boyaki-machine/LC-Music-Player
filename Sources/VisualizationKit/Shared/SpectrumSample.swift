import Foundation

/// Display-normalized band data and its original audio timing.
public struct SpectrumSample: Sendable {
    public let generation: UUID
    public let sequence: UInt64
    public let levels: [Float]
    public let producedAt: Double
    public let presentationAt: Double?

    public init(generation: UUID, sequence: UInt64, levels: [Float], producedAt: Double,
                presentationAt: Double? = nil) {
        self.generation = generation; self.sequence = sequence; self.levels = levels
        self.producedAt = producedAt; self.presentationAt = presentationAt
    }

}
