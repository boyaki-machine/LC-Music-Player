import MetalKit
import SwiftUI

public struct PuppetShowView: View {
    let driver: PuppetShowDriver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(driver: PuppetShowDriver) { self.driver = driver }
    public var body: some View {
        Group {
            if let renderer = PuppetShowLoader.shared.renderer {
                PuppetShowStageView(renderer: renderer, scene: driver.scene)
            } else {
                // While loading, and without Metal or the art, there is only the morning sky.
                Color(red: 124 / 255, green: 192 / 255, blue: 250 / 255)
            }
        }
        .overlay(alignment: .topLeading) {
            if driver.waitingForData {
                Text("解析データを待っています").font(.system(size: 10)).foregroundStyle(Color(white: 0.2))
                    .padding(.leading, 18).padding(.top, 2)
            }
        }
        .onAppear { PuppetShowLoader.shared.request(); driver.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, value in driver.reduceMotion = value }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("教育番組、4人のパペットが音楽に合わせて歌い、背景の時間が移り変わるアニメーション")
        .accessibilityValue(driver.waitingForData ? "解析データ待ち" : "")
        .allowsHitTesting(false)
    }
}

/// Draws only when the driver publishes a new scene: the view is paused and redrawn on demand.
@MainActor
final class PuppetShowStageCoordinator: NSObject, MTKViewDelegate {
    let renderer: PuppetShowRenderer
    var scene = PuppetShowScene()
    init(renderer: PuppetShowRenderer) { self.renderer = renderer }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = PuppetShowRenderer.colorFormat
        view.depthStencilPixelFormat = PuppetShowRenderer.depthFormat
        view.sampleCount = PuppetShowRenderer.sampleCount
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        #if os(macOS)
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #endif
        return view
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commands = renderer.queue.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            renderer.encode(scene, into: encoder, size: view.drawableSize)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
        }
    }
}

#if os(macOS)
struct PuppetShowStageView: NSViewRepresentable {
    let renderer: PuppetShowRenderer
    let scene: PuppetShowScene
    func makeCoordinator() -> PuppetShowStageCoordinator { PuppetShowStageCoordinator(renderer: renderer) }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.scene = scene
        view.needsDisplay = true
    }
}
#else
struct PuppetShowStageView: UIViewRepresentable {
    let renderer: PuppetShowRenderer
    let scene: PuppetShowScene
    func makeCoordinator() -> PuppetShowStageCoordinator { PuppetShowStageCoordinator(renderer: renderer) }
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.scene = scene
        view.setNeedsDisplay()
    }
}
#endif
