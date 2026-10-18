import SwiftUI

public struct ErmineChorusView: View {
    let driver: ErmineChorusDriver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(driver: ErmineChorusDriver) { self.driver = driver }
    public var body: some View {
        let drawings = driver.drawings, stage = driver.stage
        Canvas { context, size in
            ErmineChorusRenderer.draw(context: context, size: size, drawings: drawings, stage: stage, reduceMotion: reduceMotion)
        }
        .overlay(alignment: .topLeading) {
            if driver.waitingForData {
                Text("解析データを待っています").font(.system(size: 10)).foregroundStyle(Color(white: 0.65))
                    .padding(.leading, 18).padding(.top, 2)
            }
        }
        .onAppear { driver.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, value in driver.reduceMotion = value }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("オコジョ合唱団、5匹のオコジョが音域ごとに歌うアニメーション")
        .accessibilityValue(driver.waitingForData ? "解析データ待ち" : "")
        .allowsHitTesting(false)
    }
}
