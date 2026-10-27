import CoreGraphics
import Metal
import MetalKit
import SwiftUI
import simd

/// What one picture of the LED shows.
struct LCMPDefaultGEQFrame: Equatable {
    var snapshot = SpectrumSnapshot()
    var now = 0.0
    var reduceMotion = false
    var axisLabelSize: CGFloat = 9
}

/// One rectangle in pixels. Solid quads carry a premultiplied color; glow quads carry where to sample the glow
/// image and their opacity in `color.a`. The layout matches `Quad` in the shader source.
struct LCMPDefaultGEQQuad {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    var uv = SIMD4<Float>(0, 0, 0, 0)
}

/// Draws the LED with Metal. Per frame the CPU only lists rectangles: the unlit and lit faces, and the light
/// around them as copies of glow images. The glow images are made once per size with the same blurred
/// drawing as `LCMPDefaultGEQRenderer`, so the light looks the same without blurring every frame.
@MainActor
final class LCMPDefaultGEQMetal {
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    /// Nil when Metal is unavailable; the view then draws with Canvas.
    static let shared = LCMPDefaultGEQMetal()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let solid: MTLRenderPipelineState
    private let sprite: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return nil }
        func pipeline(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "geqVertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.colorFormat
            // Premultiplied source-over, in the stored sRGB values as Core Graphics blends.
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let solid = pipeline("geqSolid"), let sprite = pipeline("geqSprite") else { return nil }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToZero; s.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: s) else { return nil }
        self.device = device; self.queue = queue; self.solid = solid; self.sprite = sprite; self.sampler = sampler
    }

    static let clearColor = MTLClearColor(red: LCMPDefaultGEQRenderer.backgroundComponents.x / 255,
                                          green: LCMPDefaultGEQRenderer.backgroundComponents.y / 255,
                                          blue: LCMPDefaultGEQRenderer.backgroundComponents.z / 255, alpha: 1)

    /// Encodes one picture into a pass that was cleared to the background color.
    func encode(_ frame: LCMPDefaultGEQFrame, glow: LCMPDefaultGEQGlow, into encoder: MTLRenderCommandEncoder, scale: CGFloat) {
        let layout = glow.layout
        guard !layout.isEmpty else { return }
        let s = Float(scale)
        func rect(_ r: CGRect) -> SIMD4<Float> { SIMD4(Float(r.minX) * s, Float(r.minY) * s, Float(r.width) * s, Float(r.height) * s) }
        func premultiplied(_ c: SIMD3<Double>, _ alpha: Double) -> SIMD4<Float> {
            SIMD4(Float(c.x / 255 * alpha), Float(c.y / 255 * alpha), Float(c.z / 255 * alpha), Float(alpha))
        }
        var off: [LCMPDefaultGEQQuad] = [], faces: [LCMPDefaultGEQQuad] = []
        var near: [LCMPDefaultGEQQuad] = [], far: [LCMPDefaultGEQQuad] = [], afterglow: [LCMPDefaultGEQQuad] = []
        off.reserveCapacity(384); faces.reserveCapacity(384)
        for col in 0..<16 {
            let count = min(24, max(0, frame.snapshot.counts[col]))
            if count > 0 {
                near.append(glow.litQuad(column: col, count: count, image: 0, scale: s))
                far.append(glow.litQuad(column: col, count: count, image: 1, scale: s))
            }
            for row in 0..<24 {
                let cell = layout.cell(column: col, row: row)
                let color = LCMPDefaultGEQLayout.colorIndex(row: row)
                off.append(LCMPDefaultGEQQuad(rect: rect(cell), color: premultiplied(LCMPDefaultGEQRenderer.darkComponents[color], 1)))
                if row < count {
                    faces.append(LCMPDefaultGEQQuad(rect: rect(cell), color: premultiplied(LCMPDefaultGEQRenderer.onComponents[color], 1)))
                } else if !frame.reduceMotion {
                    let value = frame.snapshot.residual(column: col, row: row, now: frame.now)
                    guard value > 0 else { continue }
                    faces.append(LCMPDefaultGEQQuad(rect: rect(cell), color: premultiplied(LCMPDefaultGEQRenderer.onComponents[color], value)))
                    afterglow.append(glow.afterglowQuad(column: col, row: row, color: color, opacity: value, scale: s))
                }
            }
        }
        // The same order as the Canvas renderer: unlit faces, all diffuse light, then lit faces.
        let passes: [(quads: [LCMPDefaultGEQQuad], texture: MTLTexture?)] =
            [(off, nil), (near, glow.lit[0]), (far, glow.lit[1]), (afterglow, glow.afterglow), (faces, nil)]
        let all = passes.flatMap(\.quads)
        guard !all.isEmpty, let buffer = device.makeBuffer(bytes: all, length: all.count * MemoryLayout<LCMPDefaultGEQQuad>.stride,
                                                           options: .storageModeShared) else { return }
        var viewport = SIMD2<Float>(Float(layout.size.width) * s, Float(layout.size.height) * s)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var start = 0
        for pass in passes {
            defer { start += pass.quads.count }
            guard !pass.quads.isEmpty else { continue }
            var pad: Float = pass.texture == nil ? 1 : 0
            encoder.setRenderPipelineState(pass.texture == nil ? solid : sprite)
            encoder.setVertexBuffer(buffer, offset: start * MemoryLayout<LCMPDefaultGEQQuad>.stride, index: 0)
            encoder.setVertexBytes(&pad, length: MemoryLayout<Float>.size, index: 2)
            if let texture = pass.texture { encoder.setFragmentTexture(texture, index: 0) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pass.quads.count)
        }
    }

    /// Draws one picture off screen (tests and comparison images). The labels are not included.
    func image(_ frame: LCMPDefaultGEQFrame, size: CGSize, scale: CGFloat) -> CGImage? {
        guard let glow = LCMPDefaultGEQGlow(layout: LCMPDefaultGEQLayout(size: size, axisLabelSize: frame.axisLabelSize),
                                            scale: scale, device: device) else { return nil }
        return image(frame, glow: glow)
    }

    /// The same with glow images made beforehand, as the view keeps them between frames.
    func image(_ frame: LCMPDefaultGEQFrame, glow: LCMPDefaultGEQGlow) -> CGImage? {
        let scale = glow.scale
        let width = Int((glow.layout.size.width * scale).rounded()), height = Int((glow.layout.size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.clearColor
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(frame, glow: glow, into: encoder, scale: scale)
        encoder.endEncoding()
        guard let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        commands.commit(); commands.waitUntilCompleted()
        let data = Data(bytes: readback.contents(), count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad { float4 rect; float4 color; float4 uv; };
    struct Out { float4 position [[position]]; float2 pixel; float4 rect [[flat]]; float4 color [[flat]]; float2 uv; };

    // Four vertices per quad as a triangle strip. Solid quads grow by `pad` pixels so the edge coverage fits.
    vertex Out geqVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device Quad *quads [[buffer(0)]],
                         constant float2 &viewport [[buffer(1)]], constant float &pad [[buffer(2)]]) {
        Quad q = quads[iid];
        float2 corner = float2(vid & 1, vid >> 1);
        float2 p = mix(q.rect.xy - pad, q.rect.xy + q.rect.zw + pad, corner);
        Out out;
        out.position = float4(p.x / viewport.x * 2 - 1, 1 - p.y / viewport.y * 2, 0, 1);
        out.pixel = p; out.rect = q.rect; out.color = q.color;
        out.uv = mix(q.uv.xy, q.uv.zw, corner);
        return out;
    }

    // The area of the pixel covered by the rectangle, as Core Graphics antialiases a filled rectangle.
    fragment float4 geqSolid(Out in [[stage_in]]) {
        float2 lo = max(in.pixel - 0.5, in.rect.xy), hi = min(in.pixel + 0.5, in.rect.xy + in.rect.zw);
        float2 c = clamp(hi - lo, 0.0, 1.0);
        return in.color * (c.x * c.y);
    }

    // A premultiplied glow image scaled by the quad's opacity.
    fragment float4 geqSprite(Out in [[stage_in]], texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        return image.sample(s, in.uv) * in.color.a;
    }
    """
}

/// The glow images for one layout. Lit cells always fill a column from the bottom, so the light of a column
/// depends only on how many cells are lit: each image holds 24 columns lit 1…24 cells high, drawn with the
/// same blurred layer as the Canvas renderer. The afterglow image holds one blurred cell per color.
@MainActor
final class LCMPDefaultGEQGlow {
    let layout: LCMPDefaultGEQLayout
    let scale: CGFloat
    /// One image per entry of `LCMPDefaultGEQRenderer.litGlow`.
    let lit: [MTLTexture]
    let afterglow: MTLTexture
    private let litPad: [CGFloat]
    private let afterglowPad: CGFloat
    private static let slotsPerRow = 6
    /// The light is blurred by 4pt or more, so on a 3x screen images at 2x look the same as at 3x when
    /// stretched, and take less than half the memory. At 1x the gaps between cells drift visibly.
    static let imageScaleLimit: CGFloat = 2
    /// The wide light changes slowly enough to be kept at one pixel per point.
    static let wideRadius: CGFloat = 8
    var bytes: Int { (lit + [afterglow]).reduce(0) { $0 + $1.allocatedSize } }

    init?(layout: LCMPDefaultGEQLayout, scale: CGFloat, device: MTLDevice) {
        guard !layout.isEmpty, scale > 0 else { return nil }
        self.layout = layout; self.scale = scale
        let imageScale = min(scale, Self.imageScaleLimit)
        // The blur reaches about three radii; the stroke adds half the line width.
        litPad = LCMPDefaultGEQRenderer.litGlow.map { ceil($0.radius * 3.5 + $0.radius / 2) }
        afterglowPad = ceil(LCMPDefaultGEQRenderer.afterglowRadius * 3.5)
        var lit: [MTLTexture] = []
        for (index, glow) in LCMPDefaultGEQRenderer.litGlow.enumerated() {
            let pad = litPad[index], slot = Self.litSlot(layout, pad: pad)
            let size = CGSize(width: slot.width * CGFloat(Self.slotsPerRow), height: slot.height * CGFloat(24 / Self.slotsPerRow))
            let image = Self.render(size: size, scale: min(imageScale, glow.radius >= Self.wideRadius ? 1 : imageScale)) { context in
                var paths = [Path(), Path(), Path()]
                for count in 1...24 {
                    let origin = Self.litOrigin(count: count, slot: slot, pad: pad)
                    for row in 0..<count {
                        let cell = layout.cell(column: 0, row: row)
                        paths[LCMPDefaultGEQLayout.colorIndex(row: row)].addRect(cell.offsetBy(dx: origin.x - layout.columnX(0), dy: origin.y - Self.columnTop(layout)))
                    }
                }
                LCMPDefaultGEQRenderer.drawLitGlow(context, paths, radius: glow.radius, opacity: glow.opacity)
            }
            guard let image, let texture = Self.texture(image, device: device) else { return nil }
            lit.append(texture)
        }
        let cell = CGSize(width: layout.columnWidth + 2 * afterglowPad, height: layout.cellHeight + 2 * afterglowPad)
        let pad = afterglowPad
        let image = Self.render(size: CGSize(width: cell.width * 3, height: cell.height), scale: imageScale) { context in
            let residuals = (0..<3).map { color in
                (Path(CGRect(x: CGFloat(color) * cell.width + pad, y: pad, width: layout.columnWidth, height: layout.cellHeight)), color, 1.0)
            }
            LCMPDefaultGEQRenderer.drawAfterglowGlow(context, residuals)
        }
        guard let image, let afterglow = Self.texture(image, device: device) else { return nil }
        self.lit = lit; self.afterglow = afterglow
    }

    func matches(_ layout: LCMPDefaultGEQLayout, scale: CGFloat) -> Bool { self.layout == layout && self.scale == scale }

    func litQuad(column: Int, count: Int, image: Int, scale s: Float) -> LCMPDefaultGEQQuad {
        let pad = litPad[image], slot = Self.litSlot(layout, pad: pad)
        let origin = Self.litOrigin(count: count, slot: slot, pad: pad)
        let atlas = CGSize(width: slot.width * CGFloat(Self.slotsPerRow), height: slot.height * CGFloat(24 / Self.slotsPerRow))
        let source = CGRect(x: origin.x - pad, y: origin.y - pad, width: slot.width, height: slot.height)
        let target = CGRect(x: layout.columnX(column) - pad, y: Self.columnTop(layout) - pad, width: slot.width, height: slot.height)
        return Self.quad(target, source: source, atlas: atlas, opacity: 1, scale: s)
    }

    func afterglowQuad(column: Int, row: Int, color: Int, opacity: Double, scale s: Float) -> LCMPDefaultGEQQuad {
        let pad = afterglowPad
        let size = CGSize(width: layout.columnWidth + 2 * pad, height: layout.cellHeight + 2 * pad)
        let cell = layout.cell(column: column, row: row)
        return Self.quad(CGRect(x: cell.minX - pad, y: cell.minY - pad, width: size.width, height: size.height),
                         source: CGRect(x: CGFloat(color) * size.width, y: 0, width: size.width, height: size.height),
                         atlas: CGSize(width: size.width * 3, height: size.height), opacity: opacity, scale: s)
    }

    private static func quad(_ target: CGRect, source: CGRect, atlas: CGSize, opacity: Double, scale s: Float) -> LCMPDefaultGEQQuad {
        LCMPDefaultGEQQuad(rect: SIMD4(Float(target.minX) * s, Float(target.minY) * s, Float(target.width) * s, Float(target.height) * s),
                           color: SIMD4(0, 0, 0, Float(opacity)),
                           uv: SIMD4(Float(source.minX / atlas.width), Float(source.minY / atlas.height),
                                     Float(source.maxX / atlas.width), Float(source.maxY / atlas.height)))
    }

    private static func columnTop(_ layout: LCMPDefaultGEQLayout) -> CGFloat { layout.cell(column: 0, row: 23).minY }
    private static func litSlot(_ layout: LCMPDefaultGEQLayout, pad: CGFloat) -> CGSize {
        CGSize(width: layout.columnWidth + 2 * pad, height: layout.cell(column: 0, row: 0).maxY - columnTop(layout) + 2 * pad)
    }
    /// The top-left of the column lit `count` cells high inside its image.
    private static func litOrigin(count: Int, slot: CGSize, pad: CGFloat) -> CGPoint {
        let index = count - 1
        return CGPoint(x: CGFloat(index % slotsPerRow) * slot.width + pad, y: CGFloat(index / slotsPerRow) * slot.height + pad)
    }

    private static func render(size: CGSize, scale: CGFloat, _ draw: @escaping (GraphicsContext) -> Void) -> CGImage? {
        let renderer = ImageRenderer(content: Canvas { context, _ in draw(context) }.frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// Copies the picture as premultiplied sRGB BGRA, the values the blend works in.
    private static func texture(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LCMPDefaultGEQMetal.colorFormat, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        return texture
    }
}

/// Draws only when the picture changes: the view is paused and redrawn on demand. While following a
/// driver, it observes the driver itself, so a new frame redraws this layer without updating SwiftUI.
@MainActor
final class LCMPDefaultGEQStageCoordinator: NSObject, MTKViewDelegate {
    let metal: LCMPDefaultGEQMetal
    var frame = LCMPDefaultGEQFrame()
    weak var view: MTKView?
    private var glow: LCMPDefaultGEQGlow?
    private var driver: VisualizationDriver?
    /// Changes when the followed driver changes, so a pending observation of the old one is dropped.
    private var observation = 0
    init(metal: LCMPDefaultGEQMetal) { self.metal = metal }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: metal.device)
        view.colorPixelFormat = LCMPDefaultGEQMetal.colorFormat
        view.clearColor = LCMPDefaultGEQMetal.clearColor
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        #if os(macOS)
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #endif
        self.view = view
        return view
    }

    /// Follows `driver`'s frames with these settings; nil stops following.
    func follow(_ driver: VisualizationDriver?, reduceMotion: Bool, axisLabelSize: CGFloat) {
        let settings = frame.reduceMotion != reduceMotion || frame.axisLabelSize != axisLabelSize
        frame.reduceMotion = reduceMotion; frame.axisLabelSize = axisLabelSize
        if driver !== self.driver {
            self.driver = driver
            observation &+= 1
            observe(observation)
        } else if settings {
            redraw()
        }
    }

    /// Shows one frame, as a view that is not following a driver does.
    func show(_ frame: LCMPDefaultGEQFrame) {
        guard frame != self.frame else { return }
        self.frame = frame
        redraw()
    }

    private func observe(_ id: Int) {
        guard id == observation, let driver else { return }
        withObservationTracking {
            frame.snapshot = driver.snapshot
            frame.now = driver.drawTime
        } onChange: { [weak self] in
            // Called before the new value is stored, and the driver sets the time and the cells
            // together: read both on the main actor's next turn.
            Task { @MainActor [weak self] in self?.observe(id) }
        }
        redraw()
    }

    private func redraw() {
        #if os(macOS)
        view?.needsDisplay = true
        #else
        view?.setNeedsDisplay()
        #endif
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            let bounds = view.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = view.drawableSize.width / bounds.width
            let layout = LCMPDefaultGEQLayout(size: bounds, axisLabelSize: frame.axisLabelSize)
            if !layout.isEmpty, glow?.matches(layout, scale: scale) != true {
                glow = LCMPDefaultGEQGlow(layout: layout, scale: scale, device: metal.device)
            }
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commands = metal.queue.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            if let glow, !layout.isEmpty { metal.encode(frame, glow: glow, into: encoder, scale: scale) }
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
        }
    }
}

#if os(macOS)
/// The LED cells of `driver`'s frames. SwiftUI updates this view only when a setting changes.
struct LCMPDefaultGEQStageView: NSViewRepresentable {
    let metal: LCMPDefaultGEQMetal
    let driver: VisualizationDriver
    let reduceMotion: Bool
    let axisLabelSize: CGFloat
    func makeCoordinator() -> LCMPDefaultGEQStageCoordinator { LCMPDefaultGEQStageCoordinator(metal: metal) }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.follow(driver, reduceMotion: reduceMotion, axisLabelSize: axisLabelSize)
    }
    static func dismantleNSView(_ view: MTKView, coordinator: LCMPDefaultGEQStageCoordinator) {
        coordinator.follow(nil, reduceMotion: false, axisLabelSize: 9)
    }
}
#else
struct LCMPDefaultGEQStageView: UIViewRepresentable {
    let metal: LCMPDefaultGEQMetal
    let driver: VisualizationDriver
    let reduceMotion: Bool
    let axisLabelSize: CGFloat
    func makeCoordinator() -> LCMPDefaultGEQStageCoordinator { LCMPDefaultGEQStageCoordinator(metal: metal) }
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.follow(driver, reduceMotion: reduceMotion, axisLabelSize: axisLabelSize)
    }
    static func dismantleUIView(_ view: MTKView, coordinator: LCMPDefaultGEQStageCoordinator) {
        coordinator.follow(nil, reduceMotion: false, axisLabelSize: 9)
    }
}
#endif
