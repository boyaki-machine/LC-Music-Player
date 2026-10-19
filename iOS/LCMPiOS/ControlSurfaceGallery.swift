#if DEBUG
import SwiftUI
import ControlSurfaces

/// Simulator checks: `-LCMPControlSurfaces YES` shows the widgets at their iPhone 15 Pro Max sizes
/// in each state, because the home screen cannot be arranged from a script.
struct ControlSurfaceGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) { small(.playing); small(.paused) }
                HStack(spacing: 14) { small(.stopped); small(nil) }
                medium(.playing)
                medium(nil)
            }.padding(14)
        }.background(Color(white: 0.25))
    }
    private func small(_ state: TransportState?) -> some View {
        SmallWidgetLayout(state: state) { ControlSurfaceButton(command: $0, glyph: $1) }
            .padding(10).frame(width: 170, height: 170).background(ControlSurfaceColors.plate, in: RoundedRectangle(cornerRadius: 24))
    }
    private func medium(_ state: TransportState?) -> some View {
        MediumWidgetLayout(state: state) { ControlSurfaceButton(command: $0, glyph: $1) }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(width: 364, height: 170)
            .background(ControlSurfaceColors.plate, in: RoundedRectangle(cornerRadius: 24))
    }
}
#endif
