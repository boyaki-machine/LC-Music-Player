import MetalKit
import SwiftUI

public struct PuppetShowView: View {
    /// Loading usually ends within this; the notice is shown only when it takes longer (the first showing after an
    /// install, or a slow build), so that it does not flash every time.
    static let preparingDelay = Duration.milliseconds(500)

    let driver: PuppetShowDriver
    let loader: PuppetShowLoader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var delayPassed = false
    public init(driver: PuppetShowDriver) { self.init(driver: driver, loader: .shared) }
    init(driver: PuppetShowDriver, loader: PuppetShowLoader) { self.driver = driver; self.loader = loader }

    static func showsPreparing(loading: Bool, delayPassed: Bool) -> Bool { loading && delayPassed }

    public var body: some View {
        let preparing = Self.showsPreparing(loading: loader.loading, delayPassed: delayPassed)
        Group {
            if let renderer = loader.renderer {
                PuppetShowStageView(renderer: renderer, scene: driver.scene)
            } else {
                // While loading, and without Metal or the art, there is only the morning sky.
                ZStack {
                    Color(red: 124 / 255, green: 192 / 255, blue: 250 / 255)
                    if preparing { PuppetShowPreparingNotice() }
                }
            }
        }
        .onAppear { loader.request(); driver.reduceMotion = reduceMotion }
        .task { try? await Task.sleep(for: Self.preparingDelay); delayPassed = true }
        .onChange(of: reduceMotion) { _, value in driver.reduceMotion = value }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("教育番組、4人のパペットが音楽に合わせて歌い、背景の時間が移り変わるアニメーション")
        .accessibilityValue(preparing ? "舞台を準備中" : driver.waitingForData ? "解析データ待ち" : "")
        .allowsHitTesting(false)
    }
}

/// Shown over the sky while the stage is being prepared.
struct PuppetShowPreparingNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white)
            Text("舞台を準備しています…").font(.caption).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
        // Light on the dark capsule: the Mac's spinner takes its color from the scheme, not the tint.
        .environment(\.colorScheme, .dark)
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
