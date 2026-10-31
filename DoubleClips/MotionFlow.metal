#include <metal_stdlib>
using namespace metal;

// Optical flow + motion blur for the Motion panel (EditingView+Motion.swift). A direct port of the desktop's GLSL passes
// (opticalflow_search.frag, opticalflow_compose.frag, motionblur_streak.frag), as compute kernels: one thread per output pixel.
// The textures follow the desktop's: frames A and B are mipmapped (the pyramid reads them at coarser sizes), the flow textures
// are RGBA16F: RG = displacement d (A -> B, in that level's pixels), B = matching cost, A = contrast of the block.

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::nearest);

struct SearchParams {
    int lod;
    int hasPrev;
    int radius;      // candidates: start + step * (i, j), i and j from -radius to +radius
    int win;         // the block reaches win pixels each side of the pixel
    int stride;      // ... and is sampled every stride pixels
    float alpha;     // where between A (0) and B (1) the picture to be made is
    float step;
    float bias;      // cost added per pixel a candidate moves away from the start
};

struct ComposeParams {
    float alpha;
    float costLo;
    float costHi;
    float incLo;
    float incHi;
};

struct StreakParams {
    float length;    // 0 ... 1: how much of the frame-to-frame motion the exposure covers
    int direction;   // 0 both, 1 forward, 2 backward
    float blend;     // 0 ... 1: the sharp picture mixed back in (the last pass only)
    float costLo;
    float costHi;
    int maxTaps;
};

// (2 * win / stride + 1) squared must not be more than this
constant int MAX_SAMPLES = 64;

static inline float lumaOf(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}

// One pyramid level: a symmetric block match at the new frame's own pixels (no holes). Coarse to fine: texPrev (the level above,
// half the size) gives the start, this level refines it. The cost is the mean absolute luma difference over the block AFTER
// taking out its average difference, so a fade or an exposure change doesn't pull the match away from the real motion.
kernel void flowSearch(texture2d<float, access::sample> texA [[texture(0)]],
                       texture2d<float, access::sample> texB [[texture(1)]],
                       texture2d<float, access::sample> texPrev [[texture(2)]],
                       texture2d<float, access::write> outFlow [[texture(3)]],
                       constant SearchParams &prm [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    uint w = outFlow.get_width(), h = outFlow.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(float(w), float(h));
    float2 p = float2(float(gid.x), float(gid.y)) + 0.5;
    float2 start = float2(0.0);
    if (prm.hasPrev == 1) {
        float2 prevSize = float2(float(texPrev.get_width()), float(texPrev.get_height()));
        start = texPrev.sample(linearSampler, p / size).xy * (size / prevSize);
    }
    float lod = float(prm.lod);
    float best = 1e9;
    float2 bestD = start;
    float diffs[MAX_SAMPLES];
    for (int j = -prm.radius; j <= prm.radius; j++) {
        for (int i = -prm.radius; i <= prm.radius; i++) {
            float2 off = prm.step * float2(float(i), float(j));
            float2 d = start + off;
            float2 pa = p - prm.alpha * d;
            float2 pb = p + (1.0 - prm.alpha) * d;
            int n = 0;
            for (int y = -prm.win; y <= prm.win; y += prm.stride) {
                for (int x = -prm.win; x <= prm.win; x += prm.stride) {
                    float2 o = float2(float(x), float(y));
                    float a = lumaOf(texA.sample(linearSampler, (pa + o) / size, level(lod)).rgb);
                    float b = lumaOf(texB.sample(linearSampler, (pb + o) / size, level(lod)).rgb);
                    if (n < MAX_SAMPLES) {
                        diffs[n] = a - b;
                        n++;
                    }
                }
            }
            float mean = 0.0;
            for (int k = 0; k < n; k++) mean += diffs[k];
            mean /= float(n);
            float sad = 0.0;
            for (int k = 0; k < n; k++) sad += abs(diffs[k] - mean);
            float cost = sad / float(n) + prm.bias * length(off);
            if (cost < best) {
                best = cost;
                bestD = d;
            }
        }
    }
    // the contrast of frame A's block where the best match was found
    float2 pa0 = p - prm.alpha * bestD;
    float sumA = 0.0;
    int m = 0;
    for (int y = -prm.win; y <= prm.win; y += prm.stride) {
        for (int x = -prm.win; x <= prm.win; x += prm.stride) {
            if (m < MAX_SAMPLES) {
                diffs[m] = lumaOf(texA.sample(linearSampler, (pa0 + float2(float(x), float(y))) / size, level(lod)).rgb);
                sumA += diffs[m];
                m++;
            }
        }
    }
    float meanA = sumA / float(m);
    float contrast = 0.0;
    for (int k = 0; k < m; k++) contrast += abs(diffs[k] - meanA);
    outFlow.write(float4(bestD, best, contrast / float(m)), gid);
}

// The new frame: A pulled forward and B pulled back along the motion, mixed by alpha. Where the match is bad (cost against the
// block's contrast) or the motion jumps from one pixel of the flow to the next, a plain cross-fade of A and B instead.
kernel void flowCompose(texture2d<float, access::sample> texA [[texture(0)]],
                        texture2d<float, access::sample> texB [[texture(1)]],
                        texture2d<float, access::sample> flow [[texture(2)]],
                        texture2d<float, access::write> outColor [[texture(3)]],
                        constant ComposeParams &prm [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    uint w = outColor.get_width(), h = outColor.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(float(gid.x), float(gid.y)) + 0.5) / float2(float(w), float(h));
    float4 f = flow.sample(linearSampler, uv);
    float2 flowSize = float2(float(flow.get_width()), float(flow.get_height()));
    float2 duv = f.xy / flowSize;
    float4 a = texA.sample(linearSampler, uv - prm.alpha * duv, level(0));
    float4 b = texB.sample(linearSampler, uv + (1.0 - prm.alpha) * duv, level(0));
    float4 warped = mix(a, b, prm.alpha);
    float4 plain = mix(texA.sample(linearSampler, uv, level(0)), texB.sample(linearSampler, uv, level(0)), prm.alpha);
    float2 px = 1.0 / flowSize;
    float jump = max(max(length(flow.sample(linearSampler, uv + float2(px.x, 0.0)).xy - f.xy),
                         length(flow.sample(linearSampler, uv - float2(px.x, 0.0)).xy - f.xy)),
                     max(length(flow.sample(linearSampler, uv + float2(0.0, px.y)).xy - f.xy),
                         length(flow.sample(linearSampler, uv - float2(0.0, px.y)).xy - f.xy)));
    float bad = max(smoothstep(prm.costLo, prm.costHi, f.z / (f.w + 0.015)), smoothstep(prm.incLo, prm.incHi, jump));
    outColor.write(mix(warped, plain, bad), gid);
}

// Motion blur, one pass: the picture smeared along the way things move. A moving object seen over a time t after the frame is the
// picture shifted by t * d, so the smear is the average of the picture at p - t * d for t over the exposure:
//   Both     t from -0.5 to +0.5      Forward  t from 0 to +1      Backward  t from -1 to 0
// Where the match was bad the flow is not trusted and the pixel is left alone, so noise doesn't draw streaks.
kernel void motionStreak(texture2d<float, access::sample> src [[texture(0)]],
                         texture2d<float, access::sample> sharp [[texture(1)]],
                         texture2d<float, access::sample> flow [[texture(2)]],
                         texture2d<float, access::write> outColor [[texture(3)]],
                         constant StreakParams &prm [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    uint w = outColor.get_width(), h = outColor.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(float(w), float(h));
    float2 uv = (float2(float(gid.x), float(gid.y)) + 0.5) / size;
    float4 f = flow.sample(linearSampler, uv);
    float2 duv = f.xy / float2(float(flow.get_width()), float(flow.get_height()));
    float trust = 1.0 - smoothstep(prm.costLo, prm.costHi, f.z / (f.w + 0.015));
    float2 s = duv * prm.length * trust;
    float lengthPx = length(s * size);

    float t0 = -0.5, t1 = 0.5;
    if (prm.direction == 1) { t0 = 0.0; t1 = 1.0; }
    else if (prm.direction == 2) { t0 = -1.0; t1 = 0.0; }

    int taps = clamp(int(ceil(lengthPx)) + 1, 1, prm.maxTaps);   // about one tap per pixel of streak
    float4 sum = float4(0.0);
    for (int i = 0; i < taps; i++) {
        float t = mix(t0, t1, (float(i) + 0.5) / float(taps));
        sum += src.sample(linearSampler, uv - t * s, level(0));
    }
    float4 smeared = sum / float(taps);
    outColor.write(mix(smeared, sharp.sample(linearSampler, uv, level(0)), prm.blend), gid);
}
