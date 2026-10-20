import MediaPlayer
import UIKit

/// Sets the system volume through the slider of a system volume view. iOS has no public API for
/// this; the view is never shown, so the volume buttons keep the system's own indicator.
@MainActor final class SystemVolumeSlider {
    static let shared = SystemVolumeSlider()
    private let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 40))
    private var slider: UISlider? { view.subviews.lazy.compactMap { $0 as? UISlider }.first }
    func set(_ value: Float) {
        // The slider appears after the view's first layout.
        if slider == nil { view.layoutIfNeeded() }
        guard let slider else { return }
        slider.setValue(min(1, max(0, value)), animated: false)
        slider.sendActions(for: .valueChanged)
    }
}
