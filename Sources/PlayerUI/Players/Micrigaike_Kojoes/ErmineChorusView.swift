import SwiftUI

public struct ErmineChorusView: View {
    let driver: ErmineChorusDriver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(driver: ErmineChorusDriver) { self.driver = driver }
    public var body: some View {
        let drawings = driver.drawings, stage = driver.stage, dust = driver.dust
        Canvas { context, size in
            ErmineChorusRenderer.draw(context: context, size: size, drawings: drawings, stage: stage, dust: dust, reduceMotion: reduceMotion)
        }
        .onAppear { driver.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, value in driver.reduceMotion = value }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("オコジョ合唱団、5匹のオコジョが音域ごとに歌うアニメーション")
        .accessibilityValue(driver.waitingForData ? "解析データ待ち" : "")
        .allowsHitTesting(false)
    }
}
