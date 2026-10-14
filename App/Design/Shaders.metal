#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// A soft glow in a Bot's colour, made of three slowly drifting lobes that fade to
/// nothing inside the frame. Returned premultiplied, so it composites cleanly on any canvas.
[[ stitchable ]] half4 botAura(float2 position, half4 color, float2 size, float time, half4 tint, float intensity) {
    float2 c = position / size - 0.5;
    c.x *= size.x / max(size.y, 1.0);
    float t = time * 0.35;
    float2 p1 = float2(sin(t) * 0.12, cos(t * 1.3) * 0.10);
    float2 p2 = float2(cos(t * 0.8 + 2.0) * 0.14, sin(t * 1.1 + 1.0) * 0.12);
    float2 p3 = float2(sin(t * 1.4 + 4.0) * 0.10, cos(t * 0.7 + 3.0) * 0.14);
    float glow = exp(-pow(length(c - p1) / 0.22, 2.0)) * 0.6
               + exp(-pow(length(c - p2) / 0.19, 2.0)) * 0.5
               + exp(-pow(length(c - p3) / 0.25, 2.0)) * 0.45;
    // Reaches zero before the frame's edge, so no clipping ever shows.
    float falloff = smoothstep(0.5, 0.08, length(c));
    float alpha = clamp(glow * falloff, 0.0, 1.0) * intensity * float(tint.a);
    return half4(tint.rgb * half(alpha), half(alpha));
}

/// A water ripple spreading from `origin`: samples the layer along the ripple's normal
/// and brightens the crests a little. After Apple's SwiftUI shader sample.
[[ stitchable ]] half4 ripple(float2 position, SwiftUI::Layer layer, float2 origin, float time,
                              float amplitude, float frequency, float decay, float speed) {
    float distance = length(position - origin);
    float local = max(0.0, time - distance / speed);
    float amount = amplitude * sin(frequency * local) * exp(-decay * local);
    float2 direction = distance > 0.0 ? (position - origin) / distance : float2(0.0);
    half4 sampled = layer.sample(position + amount * direction);
    sampled.rgb += half(0.3 * (amount / max(amplitude, 0.001))) * sampled.a;
    return sampled;
}

/// Resolves a hidden QR code from its centre outwards. Before `progress` reaches a pixel it shows
/// a soft, fogged mosaic (`block`-pixel cells, far too coarse to scan); the resolving edge carries
/// a thin bright sheen. `progress` runs 0 → 1; at 1 the layer passes through untouched.
[[ stitchable ]] half4 pairingReveal(float2 position, SwiftUI::Layer layer, float2 size, float progress, float block) {
    float2 centre = size * 0.5;
    float reach = length(size) * 0.5;
    float d = length(position - centre) / reach;           // 0 at the centre, ~1 in the corners
    float edge = progress * 1.25 - 0.1;                    // starts just before the centre, ends past the corners
    float resolved = smoothstep(edge + 0.02, edge - 0.06, d);

    half4 sharp = layer.sample(position);
    float2 cell = (floor(position / block) + 0.5) * block;  // sample each mosaic cell at its centre
    half4 mosaic = layer.sample(cell);
    half fog = 0.78h;
    half4 hidden = half4(mix(mosaic.rgb, half3(0.93h), fog), mosaic.a);
    half4 color = mix(hidden, sharp, half(resolved));

    float sheen = exp(-pow((d - edge) / 0.045, 2.0)) * step(0.001, progress) * (1.0 - step(0.999, progress));
    color.rgb = min(color.rgb + half(sheen * 0.55) * color.a, color.a);
    return color;
}
