import SwiftUI

/// No synthetic audio levels: the future visualization owns drawing and analysis.
struct VisualizationPlaceholder: View {
    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.085, blue: 0.08)
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 28, weight: .ultraLight))
                Text("LCMP").font(.system(size: 10, design: .monospaced)).tracking(3)
            }.foregroundStyle(.white.opacity(0.25)).accessibilityHidden(true)
        }
    }
}
