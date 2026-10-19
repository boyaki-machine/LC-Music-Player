import SwiftUI

/// Colors of the charcoal plate and the LED glyphs of the widgets (the lock screen look of the mockup).
public enum ControlSurfaceColors {
    public static let plate = Color(red: 28 / 255, green: 31 / 255, blue: 34 / 255).opacity(0.94)
    public static let glyph = Color(red: 0x8d / 255, green: 0x95 / 255, blue: 0x9b / 255)
    public static let led = Color(red: 0x73 / 255, green: 0xf2 / 255, blue: 0x5c / 255)
    public static let amber = Color(red: 0xf2 / 255, green: 0xb4 / 255, blue: 0x5c / 255)
    public static let rule = Color.white.opacity(0.06)
}

/// The static app mark: three LED bars. Widgets cannot animate.
public struct MeterMark: View {
    var scale: CGFloat
    public init(scale: CGFloat = 1) { self.scale = scale }
    public var body: some View {
        HStack(alignment: .bottom, spacing: 2 * scale) {
            ForEach([6, 11, 8] as [CGFloat], id: \.self) { height in
                Rectangle().fill(ControlSurfaceColors.led).frame(width: 3 * scale, height: height * scale)
            }
        }
        .frame(height: 12 * scale, alignment: .bottom)
        .shadow(color: ControlSurfaceColors.led, radius: 1.5 * scale)
        .accessibilityLabel("LC Music Player")
    }
}

/// One LED glyph. The play glyph lights green while playing and amber while paused, like the main
/// window. With `state == nil` (the widgets without an App Group) it is one play/pause toggle that never lights.
public struct TransportGlyph: View {
    let command: TransportCommand
    let state: TransportState?
    let size: CGFloat
    public init(_ command: TransportCommand, state: TransportState?, size: CGFloat) {
        self.command = command; self.state = state; self.size = size
    }

    var symbol: String {
        switch command {
        case .previous: "backward.end.fill"
        case .playPause: state == nil ? "playpause.fill" : "play.fill"
        case .next: "forward.end.fill"
        case .stop: "stop.fill"
        case .menu: "line.3.horizontal"
        }
    }
    /// The light of the play glyph; nil when it is off.
    var light: Color? {
        guard command == .playPause else { return nil }
        switch state {
        case .playing: return ControlSurfaceColors.led
        case .paused: return ControlSurfaceColors.amber
        case .stopped, nil: return nil
        }
    }
    var accessibilityLabel: String {
        guard command == .playPause, let state else { return command.label }
        return state == .playing ? "一時停止" : state == .paused ? "再開" : "再生"
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * (command == .playPause ? 1.15 : 1), weight: .regular))
            .foregroundStyle(light ?? ControlSurfaceColors.glyph)
            .shadow(color: light?.opacity(0.8) ?? .clear, radius: size / 5)
            .accessibilityLabel(accessibilityLabel)
    }
}

/// The small home screen widget: play/pause and the menu above, previous and next below.
public struct SmallWidgetLayout<Control: View>: View {
    let state: TransportState?
    let control: (TransportCommand, TransportGlyph) -> Control
    public init(state: TransportState?, @ViewBuilder control: @escaping (TransportCommand, TransportGlyph) -> Control) {
        self.state = state; self.control = control
    }
    public var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { cell(.playPause); cell(.menu) }
            GridRow { cell(.previous); cell(.next) }
        }
    }
    private func cell(_ command: TransportCommand) -> some View {
        control(command, TransportGlyph(command, state: state, size: 34))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The medium home screen widget: the app mark, name and menu above;
/// previous, play/pause, next and stop below.
public struct MediumWidgetLayout<Control: View>: View {
    let state: TransportState?
    let control: (TransportCommand, TransportGlyph) -> Control
    public init(state: TransportState?, @ViewBuilder control: @escaping (TransportCommand, TransportGlyph) -> Control) {
        self.state = state; self.control = control
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MeterMark()
                Text("LC Music Player").font(.system(size: 13)).foregroundStyle(ControlSurfaceColors.glyph)
                Spacer(minLength: 0)
                control(.menu, TransportGlyph(.menu, state: state, size: 24)).frame(width: 52, height: 44)
            }.frame(height: 48)
            ControlSurfaceColors.rule.frame(height: 1).padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach([TransportCommand.previous, .playPause, .next, .stop], id: \.self) { command in
                    control(command, TransportGlyph(command, state: state, size: 34))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
