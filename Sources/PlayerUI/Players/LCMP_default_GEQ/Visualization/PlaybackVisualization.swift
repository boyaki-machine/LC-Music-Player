import AnalysisCore
import PlaybackCore
import SwiftUI
import VisualizationKit

/// Observation of 30Hz analysis lives here, keeping transport controls separate.
/// Only the selected design's driver runs; the others stay stopped.
struct PlaybackVisualization: View {
    let playback: PlaybackController
    let presentation: PlayerPresentation
    private var visible: Bool { presentation.visualizationVisible }
    private struct Stamp: Equatable { let generation: UUID; let sequence: UInt64 }
    private var stamp: Stamp? { playback.analysisFrame.map { Stamp(generation: $0.generation, sequence: $0.sequence) } }
    private var activity: VisualizationActivity {
        switch playback.state { case .playing: .playing; case .paused: .paused; default: .inactive }
    }
    var body: some View {
        Group {
            switch presentation.visualizationDesign {
            case .fluorescentLED: LCMPDefaultGEQView(driver: presentation.visualizationDriver)
            case .ermineChorus: ErmineChorusView(driver: presentation.ermineChorusDriver)
            case .puppetShow: PuppetShowView(driver: presentation.puppetShowDriver)
            }
        }
        .onAppear { presentation.visualizationHostAppeared(); synchronize(); receive() }
        .onChange(of: playback.state) { _, _ in synchronize(); receive() }
        .onChange(of: visible) { _, _ in synchronize(); receive() }
        .onChange(of: presentation.visualizationDesign) { _, _ in synchronize(); receive() }
        .onChange(of: playback.analysisResetID) { _, _ in presentation.activeVisualizationDriver.reset(); receive() }
        .onChange(of: stamp) { _, _ in receive() }
        .onDisappear {
            if presentation.visualizationHostDisappeared() {
                presentation.activeVisualizationDriver.synchronize(activity: .inactive, visible: false)
            }
        }
    }
    private func synchronize() {
        let configuration = visible ? VisualizationDesign.configuration : nil
        if playback.analysisConfiguration != configuration { playback.configureAnalysis(configuration) }
        presentation.activeVisualizationDriver.synchronize(activity: activity, visible: visible)
    }
    private func receive() { if let frame = playback.analysisFrame { presentation.activeVisualizationDriver.receive(frame) } }
}
