import AnalysisCore
import PlaybackCore
import SwiftUI
import VisualizationKit

/// Observation of 30Hz analysis lives here, keeping transport controls separate.
struct PlaybackVisualization: View {
    let playback: PlaybackController
    let driver: VisualizationDriver
    let visible: Bool
    private struct Stamp: Equatable { let generation: UUID; let sequence: UInt64 }
    private var stamp: Stamp? { playback.analysisFrame.map { Stamp(generation: $0.generation, sequence: $0.sequence) } }
    private var activity: VisualizationActivity {
        switch playback.state { case .playing: .playing; case .paused: .paused; default: .inactive }
    }
    var body: some View {
        LCMPDefaultGEQView(driver: driver)
            .onAppear { synchronize(); receive() }
            .onChange(of: playback.state) { _, _ in synchronize(); receive() }
            .onChange(of: visible) { _, _ in synchronize(); receive() }
            .onChange(of: playback.analysisResetID) { _, _ in driver.reset(); receive() }
            .onChange(of: stamp) { _, _ in receive() }
            .onDisappear { driver.synchronize(activity: .inactive, visible: false) }
    }
    private func synchronize() {
        let configuration = visible ? LCMPDefaultGEQ.configuration : nil
        if playback.analysisConfiguration != configuration { playback.configureAnalysis(configuration) }
        driver.synchronize(activity: activity, visible: visible)
    }
    private func receive() { if let frame = playback.analysisFrame { driver.receive(frame) } }
}
