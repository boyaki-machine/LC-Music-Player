import CoreGraphics
import Foundation
import Metal
import simd

/// What the stage shows in one picture.
struct PuppetShowScene: Sendable, Equatable {
    /// The time of day, 0…1 (0 morning, 0.25 noon, 0.5 evening, 0.75 night).
    var timeOfDay = 0.05
    /// Seconds of playback, which move the clouds, stars and passers-by.
    var time = 0.0
    var moonAge = 7.0
    var poses = Array(repeating: PuppetPose(), count: PuppetMember.all.count)
    var reduceMotion = false
    var event: PuppetSkyEvent?
}

/// Draws the stage with Metal: the scenery as 2D layers in stage points, then the puppets in 3D through the
/// mock's camera (12° field of view looking at the stage's center). Loading the art is done once and shared.
@MainActor
final class PuppetShowRenderer {
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float
    static let sampleCount = 4

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipelines: [PuppetBlend: MTLRenderPipelineState]
    private let premultiplied: MTLRenderPipelineState
    private let depthStates: (write: MTLDepthStencilState, read: MTLDepthStencilState, none: MTLDepthStencilState)
    private let clampSampler: MTLSamplerState, repeatSampler: MTLSamplerState, grainSampler: MTLSamplerState
    private var textures: [PuppetTexture: MTLTexture] = [:]
    private var pictures: [String: MTLTexture] = [:]
    /// Each cloud's shadow and where it lies around the cloud, in stage points.
    private var cloudShadows: [(texture: MTLTexture, pad: Double, width: Double, height: Double)] = []
    private let grain: MTLTexture, white: MTLTexture, glint: MTLTexture, halo: MTLTexture, streak: MTLTexture
    private(set) var rigs: [PuppetRig] = []
    private var rigBuffers: [[(vertices: MTLBuffer, indices: MTLBuffer, count: Int)]] = []

    init?(artwork: PuppetShowArtwork, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: PuppetShowShaders.source, options: nil) else { return nil }
        self.device = device; self.queue = queue
        func pipeline(_ blend: PuppetBlend?, premultiplied: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "puppetVertex")
            d.fragmentFunction = library.makeFunction(name: "puppetFragment")
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = Self.depthFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.colorFormat
            switch blend {
            case .cutout: d.isAlphaToCoverageEnabled = true
            case .normal, .additive, nil:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
                c.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = premultiplied ? .one : .sourceAlpha
                c.destinationAlphaBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
            case .opaque: break
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        var states: [PuppetBlend: MTLRenderPipelineState] = [:]
        for blend in [PuppetBlend.opaque, .cutout, .normal, .additive] {
            guard let state = pipeline(blend) else { return nil }
            states[blend] = state
        }
        guard let pre = pipeline(nil, premultiplied: true) else { return nil }
        pipelines = states; premultiplied = pre
        func depth(_ compare: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = compare; d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthStates = (depth(.less, true), depth(.less, false), depth(.always, false))
        func sampler(_ mode: MTLSamplerAddressMode, linear: Bool = true) -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = linear ? .linear : .nearest; d.magFilter = linear ? .linear : .nearest
            d.mipFilter = linear ? .linear : .notMipmapped
            d.sAddressMode = mode; d.tAddressMode = mode
            return device.makeSamplerState(descriptor: d)!
        }
        clampSampler = sampler(.clampToEdge); repeatSampler = sampler(.repeat); grainSampler = sampler(.repeat, linear: false)

        let upload = Uploader(device: device, queue: queue)
        grain = upload.texture(PuppetShowPatterns.grain(), srgb: false, mipmaps: false)
        white = upload.texture(PuppetShowPatterns.white, srgb: false, mipmaps: false)
        glint = upload.texture(PuppetShowPatterns.glint(), srgb: false)
        halo = upload.texture(PuppetShowPatterns.halo(), srgb: false)
        streak = upload.texture(PuppetShowPatterns.streak(), srgb: false)
        for (name, image) in artwork.pictures { pictures[name] = upload.texture(image, srgb: false) }
        cloudShadows = artwork.cloudShadows.map { (upload.texture($0.image, srgb: false), $0.pad, $0.width, $0.height) }
        for (key, image) in artwork.textures { textures[key] = upload.texture(image, srgb: key.isSRGB) }
        rigs = artwork.rigs
        rigBuffers = rigs.map { rig in
            rig.meshes.map { mesh in
                (device.makeBuffer(bytes: mesh.vertices, length: max(4, mesh.vertices.count * 4))!,
                 device.makeBuffer(bytes: mesh.indices, length: max(4, mesh.indices.count * 4))!, mesh.indices.count)
            }
        }
        upload.finish()
    }

    /// Copies pictures into textures and builds their mipmaps on the GPU.
    private struct Uploader {
        let device: MTLDevice
        let commands: MTLCommandBuffer
        let blit: MTLBlitCommandEncoder
        init(device: MTLDevice, queue: MTLCommandQueue) {
            self.device = device; commands = queue.makeCommandBuffer()!; blit = commands.makeBlitCommandEncoder()!
        }
        func texture(_ image: PuppetImage, srgb: Bool, mipmaps: Bool = true) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
                                                             width: image.width, height: image.height, mipmapped: mipmaps)
            d.usage = .shaderRead
            let t = device.makeTexture(descriptor: d)!
            image.pixels.withUnsafeBytes { bytes in
                t.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                          withBytes: bytes.baseAddress!, bytesPerRow: image.width * 4)
            }
            if mipmaps { blit.generateMipmaps(for: t) }
            return t
        }
        func finish() { blit.endEncoding(); commands.commit(); commands.waitUntilCompleted() }
    }

    // MARK: Drawing

    /// The stage's place in a drawable of `size` pixels: scaled to fit and centered.
    static func viewport(for size: CGSize) -> MTLViewport {
        let scale = min(size.width / PuppetBackdrop.width, size.height / PuppetBackdrop.height)
        let w = PuppetBackdrop.width * scale, h = PuppetBackdrop.height * scale
        return MTLViewport(originX: (size.width - w) / 2, originY: (size.height - h) / 2, width: w, height: h, znear: 0, zfar: 1)
    }

    /// Encodes the whole stage into a pass of the drawable size `size` (pixels).
    func encode(_ scene: PuppetShowScene, into encoder: MTLRenderCommandEncoder, size: CGSize) {
        let viewport = Self.viewport(for: size)
        encoder.setViewport(viewport)
        encoder.setScissorRect(MTLScissorRect(x: Int(viewport.originX.rounded()), y: Int(viewport.originY.rounded()),
                                              width: max(1, min(Int(size.width), Int(viewport.width.rounded()))),
                                              height: max(1, min(Int(size.height), Int(viewport.height.rounded())))))
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(grain, index: 1)
        encoder.setFragmentSamplerState(grainSampler, index: 1)
        let pixelsPerPoint = Float(viewport.width / PuppetBackdrop.width)
        drawBackdrop(scene, encoder, pixelsPerPoint: pixelsPerPoint)
        drawPuppets(scene, encoder)
    }

    private func draw(_ encoder: MTLRenderCommandEncoder, quad corners: [SIMD2<Float>], uv: [SIMD2<Float>], texture: MTLTexture,
                      _ u: PuppetShowUniforms, pipeline: MTLRenderPipelineState) {
        var vertices: [Float] = []
        for (p, t) in zip(corners, uv) { vertices += [p.x, p.y, 0, t.x, t.y, 1, 1, 1, 1] }
        var u = u
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthStates.none)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&u, length: MemoryLayout<PuppetShowUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<PuppetShowUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(clampSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// A rectangle in stage points, top-left first, as a triangle strip.
    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [SIMD2<Float>] {
        [SIMD2(Float(x), Float(y)), SIMD2(Float(x + w), Float(y)), SIMD2(Float(x), Float(y + h)), SIMD2(Float(x + w), Float(y + h))]
    }
    private static let fullUV: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
    /// A band of `width` from `a` to `b`.
    private static func band(_ a: SIMD2<Double>, _ b: SIMD2<Double>, width: Double) -> [SIMD2<Float>] {
        let d = b - a, n = simd_normalize(SIMD2(-d.y, d.x)) * width / 2
        return [a + n, b + n, a - n, b - n].map { SIMD2<Float>($0) }
    }

    private func drawBackdrop(_ scene: PuppetShowScene, _ encoder: MTLRenderCommandEncoder, pixelsPerPoint: Float) {
        let projection = PuppetMath.orthographic(width: Float(PuppetBackdrop.width), height: Float(PuppetBackdrop.height))
        let normal = pipelines[.normal]!, additive = pipelines[.additive]!
        func uniforms(_ mode: PuppetShaderMode, color: SIMD4<Float> = SIMD4(1, 1, 1, 1)) -> PuppetShowUniforms {
            var u = PuppetShowUniforms(); u.mvp = projection; u.mode = mode.rawValue; u.color = color; return u
        }
        let layers = PuppetBackdrop.layers(tod: scene.timeOfDay, time: scene.time, moonAge: scene.moonAge, reduceMotion: scene.reduceMotion,
                                             event: scene.event)
        for layer in layers {
            switch layer {
            case let .sky(top, horizon):
                var u = uniforms(.sky)
                let c = (top + horizon).map { SIMD4<Float>(SIMD3<Float>($0 / 255), 1) }
                u.sky = (c[0], c[1], c[2], c[3], c[4], c[5])
                // The horizon's color is reached at 0.6 of the height and continues below it.
                let bottom = Float(1 / 0.6)
                draw(encoder, quad: Self.rect(0, 0, PuppetBackdrop.width, PuppetBackdrop.height),
                     uv: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, bottom), SIMD2(1, bottom)], texture: white, u, pipeline: normal)
            case let .glint(x, y, radius, alpha):
                let r = radius * 2.6
                draw(encoder, quad: Self.rect(x - r, y - r, 2 * r, 2 * r), uv: Self.fullUV, texture: glint,
                     uniforms(.picture, color: SIMD4(1, 1, 1, Float(alpha))), pipeline: additive)
                if radius > 0.9 {
                    let cross = uniforms(.picture, color: SIMD4(1, 1, 250 / 255, Float(alpha * 0.6)))
                    for (a, b) in [(SIMD2(x - radius * 3, y), SIMD2(x + radius * 3, y)), (SIMD2(x, y - radius * 3), SIMD2(x, y + radius * 3))] {
                        draw(encoder, quad: Self.band(a, b, width: 0.25), uv: Self.fullUV, texture: white, cross, pipeline: additive)
                    }
                }
            case let .streak(from, to, alpha):
                draw(encoder, quad: Self.band(from, to, width: 0.7), uv: Self.fullUV, texture: streak,
                     uniforms(.picture, color: SIMD4(1, 1, 1, Float(alpha))), pipeline: additive)
            case let .picture(name, f, alpha, multiply, flip):
                guard let texture = pictures[name] else { continue }
                let uv: [SIMD2<Float>] = flip ? [SIMD2(1, 0), SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1)] : Self.fullUV
                let u = multiply.map { uniforms(.multiply, color: SIMD4(SIMD3<Float>($0 / 255), Float(alpha))) }
                    ?? uniforms(.picture, color: SIMD4(1, 1, 1, Float(alpha)))
                draw(encoder, quad: Self.rect(f.x, f.y, f.width, f.height), uv: uv, texture: texture, u, pipeline: normal)
            case let .halo(x, y, radius, color, alpha):
                draw(encoder, quad: Self.rect(x - radius, y - radius, 2 * radius, 2 * radius), uv: Self.fullUV, texture: halo,
                     uniforms(.picture, color: SIMD4(SIMD3<Float>(color / 255), Float(alpha))), pipeline: normal)
            case let .moon(x, y, radius, age, alpha):
                var u = uniforms(.moon)
                let k = cos(2 * .pi * age / PuppetBackdrop.synodicMonth), side = age < PuppetBackdrop.synodicMonth / 2 ? 1.0 : -1.0
                u.p0 = SIMD4(Float(x), Float(y), Float(radius), Float(k))
                u.p1 = SIMD4(Float(side), Float(alpha), 0.35, pixelsPerPoint)
                let m = radius + 4
                draw(encoder, quad: Self.rect(x - m, y - m, 2 * m, 2 * m), uv: Self.fullUV, texture: white, u, pipeline: premultiplied)
            case let .rainbow(x, y, radius, width, reveal, alpha):
                var u = uniforms(.rainbow)
                u.p0 = SIMD4(Float(x), Float(y), Float(radius), Float(width))
                u.p1 = SIMD4(Float(alpha), Float(reveal), pixelsPerPoint, 0)
                draw(encoder, quad: Self.rect(x - radius, y - radius, 2 * radius, radius), uv: Self.fullUV, texture: white, u, pipeline: premultiplied)
            case let .cloud(shape, f, tint, shadowAlpha):
                let name = PuppetBackdrop.cloudPictures[shape]
                guard let texture = pictures[name] else { continue }
                // The shadow was made for the cloud's drawn width; its height follows the same scale.
                let s = cloudShadows[shape], k = f.width / PuppetBackdrop.clouds.first { $0.shape == shape }!.width
                draw(encoder, quad: Self.rect(f.x - s.pad * k, f.y + 1.2 - s.pad * k, s.width * k, s.height * k), uv: Self.fullUV, texture: s.texture,
                     uniforms(.shadow, color: SIMD4(20 / 255, 20 / 255, 50 / 255, Float(shadowAlpha))), pipeline: normal)
                draw(encoder, quad: Self.rect(f.x, f.y, f.width, f.height), uv: Self.fullUV, texture: texture,
                     uniforms(.multiply, color: SIMD4(SIMD3<Float>(tint / 255), 1)), pipeline: normal)
            case let .land(index, offset, alpha):
                guard let texture = pictures[PuppetBackdrop.landPictures[index]] else { continue }
                var u = uniforms(.land)
                let size = PuppetBackdrop.landPictureSize, marks = PuppetBackdrop.landMarks
                u.p0 = SIMD4(Float(PuppetBackdrop.landPeriod), Float(PuppetBackdrop.landSeam), Float(size.width), Float(size.height))
                u.p1 = SIMD4(Float(marks[index].0), Float(marks[index].1), Float(marks[1].0), Float(marks[1].1))
                let tile = PuppetBackdrop.landTileWidth, y = PuppetBackdrop.height - PuppetBackdrop.landHeight
                var x = -offset
                while x < PuppetBackdrop.width {
                    u.p2 = SIMD4(pixelsPerPoint, Float(alpha), Float(x), 0)
                    draw(encoder, quad: Self.rect(x, y, tile + 0.5, PuppetBackdrop.landHeight), uv: Self.fullUV, texture: texture, u, pipeline: premultiplied)
                    x += tile
                }
            }
        }
    }

    /// The camera of the mock: 12° vertical field of view, looking at the stage's center from where it fills the view.
    static var camera: simd_float4x4 {
        let h = Float(PuppetBackdrop.height), w = Float(PuppetBackdrop.width)
        let distance = (h / 2) / tan(6 * Float.pi / 180)
        return PuppetMath.perspective(fovYDegrees: 12, aspect: w / h, near: 10, far: 4000)
            * PuppetMath.translation(SIMD3(-w / 2, -h / 2, -distance))
    }

    private func drawPuppets(_ scene: PuppetShowScene, _ encoder: MTLRenderCommandEncoder) {
        let camera = Self.camera
        let light = SIMD3<Float>(PuppetBackdrop.mix(PuppetBackdrop.light, PuppetBackdrop.weights(scene.timeOfDay)))
        struct Item { let rig: Int, piece: Int, matrix: simd_float4x4, z: Float, order: Int, sequence: Int }
        var opaque: [Item] = [], transparent: [Item] = []
        for r in rigs.indices {
            rigs[r].apply(scene.poses[r])
            let world = rigs[r].worldMatrices()
            for (i, piece) in rigs[r].pieces.enumerated() where piece.opacity > 0 {
                let m = world[piece.node]
                // The camera looks down −z without turning, so a smaller world z is farther away.
                let item = Item(rig: r, piece: i, matrix: m, z: m.columns.3.z,
                                order: piece.renderOrder, sequence: opaque.count + transparent.count)
                if piece.blend == .opaque || piece.blend == .cutout { opaque.append(item) } else { transparent.append(item) }
            }
        }
        // As three.js: opaque parts by render order; transparent ones by render order, then back to front.
        opaque.sort { ($0.order, $0.sequence) < ($1.order, $1.sequence) }
        transparent.sort { $0.order != $1.order ? $0.order < $1.order : $0.z != $1.z ? $0.z < $1.z : $0.sequence < $1.sequence }
        for item in opaque + transparent {
            let piece = rigs[item.rig].pieces[item.piece], buffers = rigBuffers[item.rig][piece.mesh]
            guard let texture = textures[piece.texture] else { continue }
            var u = PuppetShowUniforms()
            u.mvp = camera * item.matrix
            u.mode = PuppetShaderMode.puppet.rawValue
            u.color = SIMD4(piece.lit ? light : SIMD3(1, 1, 1), Float(piece.opacity))
            u.uvOffset = SIMD2<Float>(piece.uvOffset)
            u.alphaTest = piece.blend == .cutout ? 0.45 : 0
            encoder.setRenderPipelineState(pipelines[piece.blend]!)
            encoder.setDepthStencilState(!piece.depthTest ? depthStates.none : piece.blend == .opaque || piece.blend == .cutout ? depthStates.write : depthStates.read)
            encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<PuppetShowUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PuppetShowUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(piece.texture.repeats ? repeatSampler : clampSampler, index: 0)
            let count = min(buffers.count, piece.indexCount ?? buffers.count)
            guard count > 0 else { continue }
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: buffers.indices, indexBufferOffset: 0)
        }
    }

    // MARK: Offscreen

    /// Draws the scene into a picture of `width`×`height` pixels (tests, the selection card).
    func image(_ scene: PuppetShowScene, width: Int, height: Int) -> CGImage? {
        func target(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples; d.usage = usage
            #if os(macOS)
            d.storageMode = samples > 1 || format == Self.depthFormat ? .private : .managed
            #else
            d.storageMode = samples > 1 || format == Self.depthFormat ? .private : .shared
            #endif
            return device.makeTexture(descriptor: d)
        }
        guard let msaa = target(Self.colorFormat, samples: Self.sampleCount, usage: .renderTarget),
              let depth = target(Self.depthFormat, samples: Self.sampleCount, usage: .renderTarget),
              let resolved = target(Self.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead]),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa; pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(scene, into: encoder, size: CGSize(width: width, height: height))
        encoder.endEncoding()
        #if os(macOS)
        if let blit = commands.makeBlitCommandEncoder() { blit.synchronize(resource: resolved); blit.endEncoding() }
        #endif
        commands.commit(); commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolved.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
