import Foundation
import simd

/// Parameter block shared with the fragment shader. Laid out as four `float4`s
/// so Swift and Metal agree on alignment without padding guesswork.
struct CRTParams {
    /// xyz = tint, w = tint intensity (mix toward tint)
    var tint: SIMD4<Float> = .zero
    /// x = scanline intensity, y = scanline pitch (px), z = curvature, w = vignette
    var effects: SIMD4<Float> = .zero
    /// x = bloom, y = flicker, z = time, w = 1 when a captured frame is bound
    var post: SIMD4<Float> = .zero
    /// x = width, y = height in pixels
    var size: SIMD4<Float> = .zero
}

/// Compiled at runtime with `makeLibrary(source:)` rather than as a `.metal`
/// build product: SwiftPM's Metal handling has been inconsistent across
/// toolchains, and a runtime compile removes that whole class of build failure.
enum CRTShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex VSOut crt_vertex(uint vid [[vertex_id]]) {
        float2 pts[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        VSOut o;
        o.pos = float4(pts[vid], 0.0, 1.0);
        o.uv  = float2((pts[vid].x + 1.0) * 0.5, 1.0 - (pts[vid].y + 1.0) * 0.5);
        return o;
    }

    struct CRTParams {
        float4 tint;
        float4 effects;
        float4 post;
        float4 size;
    };

    fragment float4 crt_fragment(VSOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant CRTParams &P [[buffer(0)]]) {
        constexpr sampler smp(mag_filter::linear,
                              min_filter::linear,
                              address::clamp_to_edge);

        bool hasCapture = P.post.w > 0.5;

        float2 uv = in.uv;
        float2 centered = uv - 0.5;
        float r2 = dot(centered, centered);

        // Barrel curvature with the corners pinned. The radial scale is exactly
        // 1.0 at the corner (r2 == 0.5) and shrinks toward the middle, so the
        // centre bulges while every sample stays inside [0,1].
        //
        // An earlier version did the usual `uv += centered * r2 * k`, which
        // pushes edge samples past the frame, and painted those pixels black.
        // That silently cropped whatever sat near the screen edges — menu bar
        // ends, window borders, dock corners. This form cannot crop: the
        // offset magnitude is |centered| * radial, and radial <= 1 everywhere
        // on the frame, so it can never exceed the corner offset.
        float radial = 1.0 - P.effects.z * (0.5 - r2);
        uv = 0.5 + centered * radial;

        // --- shading shared by both engines ---
        float scan = 1.0;
        if (P.effects.x > 0.0) {
            float pitch = max(P.effects.y, 1.0);
            float s = sin(uv.y * P.size.y / pitch * M_PI_F);
            scan = 1.0 - P.effects.x * 0.5 * (1.0 - s);
        }
        float vig = clamp(1.0 - P.effects.w * r2 * 2.6, 0.0, 1.0);
        float flick = 1.0 - P.post.y * (0.5 + 0.5 * sin(P.post.z * 41.0));

        if (!hasCapture) {
            // No capture: emit black with alpha = amount of darkening, so the
            // window server composites us as scanlines/vignette on top of the
            // live desktop. The colour cast comes from the LUT engine.
            float shade = clamp(scan * vig * flick, 0.0, 1.0);
            return float4(0.0, 0.0, 0.0, 1.0 - shade);
        }

        float3 c = src.sample(smp, uv).rgb;

        // Cheap 8-tap phosphor bloom. Not a real gaussian, but it reads as glow
        // and costs one loop instead of a second render pass.
        if (P.post.x > 0.0) {
            float3 glow = float3(0.0);
            float radius = 3.0 / max(P.size.y, 1.0);
            for (int i = 0; i < 8; ++i) {
                float a = float(i) * 0.7853981634;
                glow += src.sample(smp, uv + float2(cos(a), sin(a)) * radius).rgb;
            }
            glow /= 8.0;
            c += P.post.x * max(glow - 0.35, 0.0) * 1.6;
        }

        // True per-pixel desaturation. This is the step the LUT engine cannot do.
        float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(c, P.tint.rgb * lum, P.tint.w);

        c *= scan * vig * flick;
        return float4(clamp(c, 0.0, 1.0), 1.0);
    }
    """
}
