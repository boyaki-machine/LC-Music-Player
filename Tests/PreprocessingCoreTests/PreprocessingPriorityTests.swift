import Foundation
import Testing
@testable import PreprocessingCore

/// A listener's request runs at its own priority; background preparation stays at utility.
@Suite struct PreprocessingPriorityTests {
    @Test func requestsKeepTheirTaskPriority() async {
        let urgent = await Task(priority: .userInitiated) { AudioPreprocessor.requestedQoS }.value
        let high = await Task(priority: .high) { AudioPreprocessor.requestedQoS }.value
        let background = await Task(priority: .utility) { AudioPreprocessor.requestedQoS }.value
        let lowest = await Task(priority: .background) { AudioPreprocessor.requestedQoS }.value
        #expect(urgent == .userInitiated && high == .userInitiated)
        #expect(background == .utility && lowest == .utility)
    }
}
