import simd

/// Per-draw values shared by every shader mode. The layout matches `Uniforms` in the shader source.
struct PuppetShowUniforms {
    var mvp = matrix_identity_float4x4
    /// Multiplies the color; alpha is the opacity.
    var color = SIMD4<Float>(1, 1, 1, 1)
    var uvOffset = SIMD2<Float>(0, 0)
    /// Fragments below this alpha are discarded (cut-out parts); 0 keeps all.
    var alphaTest: Float = 0
    var mode: Int32 = 0
    var p0 = SIMD4<Float>(0, 0, 0, 0), p1 = SIMD4<Float>(0, 0, 0, 0), p2 = SIMD4<Float>(0, 0, 0, 0)
    var sky: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero)
}

enum PuppetShaderMode: Int32 {
    /// A puppet part: linear shading of sRGB-decoded textures, written back as sRGB like three.js.
    case puppet = 0
    /// A background picture: its colors are used as they are, as on a 2D canvas.
    case picture = 1
    /// A picture tinted by multiplying (the clouds and the sun).
    case multiply = 2
    case sky = 3
    case land = 4
    case moon = 5
    /// The tint color with the picture's alpha (paper shadows).
    case shadow = 6
}

enum PuppetShowShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex { packed_float3 position; packed_float2 uv; packed_float4 color; };
    struct Uniforms {
        float4x4 mvp; float4 color; float2 uvOffset; float alphaTest; int mode;
        float4 p0; float4 p1; float4 p2; float4 sky[6];
    };
    struct Out { float4 position [[position]]; float2 uv; float4 color; float2 stage; };

    vertex Out puppetVertex(uint id [[vertex_id]], const device Vertex* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        Out o;
        float3 p = float3(v[id].position);
        o.position = u.mvp * float4(p, 1);
        o.uv = float2(v[id].uv) + u.uvOffset;
        o.color = float4(v[id].color);
        o.stage = p.xy;
        return o;
    }

    float3 toSRGB(float3 c) {
        c = max(c, 0.0);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    // The land picture's column `x` (pixels of the picture, centers at .5) after the landmark alignment.
    float alignedU(float x, constant Uniforms& u) {
        float w = u.p0.z, m1 = u.p1.x, m2 = u.p1.y, n1 = u.p1.z, n2 = u.p1.w;
        float c = x - 0.5, s;
        if (c < n1) s = c * m1 / n1;
        else if (c < n2) s = m1 + (c - n1) * (m2 - m1) / (n2 - n1);
        else s = m2 + (c - n2) * (w - 1 - m2) / (w - 1 - n2);
        return (s + 0.5) / w;
    }

    // How much of the moon covers a point: inside the limb and on the lit side of the terminator.
    float moonCover(float2 p, float2 c, float r, float k, float side, float soft) {
        float2 d = p - c;
        float limb = r - length(d);
        float dy = clamp(d.y / r, -1.0, 1.0), s = sqrt(1 - dy * dy);
        float term = (side * d.x - k * r * s);
        return clamp(limb / soft + 0.5, 0.0, 1.0) * clamp(term / soft + 0.5, 0.0, 1.0);
    }

    fragment float4 puppetFragment(Out in [[stage_in]], constant Uniforms& u [[buffer(1)]],
                                   texture2d<float> tex [[texture(0)]], texture2d<float> grain [[texture(1)]],
                                   sampler smp [[sampler(0)]], sampler grainSampler [[sampler(1)]]) {
        switch (u.mode) {
        case 0: {
            float4 c = tex.sample(smp, in.uv) * in.color * u.color;
            if (c.a < u.alphaTest) discard_fragment();
            return float4(toSRGB(c.rgb), c.a);
        }
        case 1: return tex.sample(smp, in.uv) * in.color * u.color;
        case 2: {
            float4 t = tex.sample(smp, in.uv);
            return float4(u.color.rgb * mix(float3(1), t.rgb, t.a), t.a * u.color.a);
        }
        case 3: {
            float fx = clamp(in.uv.x, 0.0, 1.0) * 2, fy = clamp(in.uv.y, 0.0, 1.0);
            int i = min(int(fx), 1); float t = fx - float(i);
            float3 top = mix(u.sky[i].rgb, u.sky[i + 1].rgb, t), horizon = mix(u.sky[i + 3].rgb, u.sky[i + 4].rgb, t);
            return float4(mix(top, horizon, fy), 1);
        }
        case 4: {
            // A tile of the land: the picture aligned at its landmarks, its tail blended over its head so it repeats.
            float period = u.p0.x, seam = u.p0.y, h = u.p0.w;
            float x = in.uv.x * period, v = in.uv.y;
            float4 base = tex.sample(smp, float2(alignedU(x, u), v));
            float3 pc = base.rgb * base.a; float pa = base.a;
            if (x < seam) {
                float4 tail = tex.sample(smp, float2(alignedU(period + x, u), v));
                float ta = tail.a * (1 - x / seam);
                pc = tail.rgb * ta + pc * (1 - ta); pa = ta + pa * (1 - ta);
            }
            float2 gp = float2((in.stage.x - u.p2.z) * u.p2.x, in.stage.y * u.p2.x) / 128.0;
            float4 g = grain.sample(grainSampler, gp);
            pc = g.rgb * g.a * pa + pc * (1 - g.a);
            (void)h;
            return float4(pc, pa) * u.p2.y;
        }
        case 5: {
            float2 c = u.p0.xy; float r = u.p0.z, k = u.p0.w, side = u.p1.x, alpha = u.p1.y, px = u.p1.w;
            float cover = moonCover(in.stage, c, r, k, side, 1.0 / px);
            float shade = moonCover(in.stage - float2(0, 0.8), c, r, k, side, 2.0) * u.p1.z;
            float2 gp = in.stage * px / 128.0;
            float4 g = grain.sample(grainSampler, gp);
            float3 moon = mix(float3(241, 234, 211) / 255.0, g.rgb, g.a);
            float a = cover + shade * (1 - cover);
            return float4(moon * cover, a) * alpha;
        }
        default: {
            float4 t = tex.sample(smp, in.uv);
            return float4(u.color.rgb, t.a * u.color.a);
        }
        }
    }
    """
}
