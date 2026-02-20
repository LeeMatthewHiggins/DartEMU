#version 460 core

#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uResolution;
uniform float uMode;
uniform sampler2D uTexture;

out vec4 fragColor;

const float kHardScanSoft = -8.0;
const float kHardScanMedium = -12.0;
const float kHardPixSoft = -3.0;
const float kHardPixMedium = -4.0;
const vec2 kWarp = vec2(1.0 / 32.0, 1.0 / 24.0);
const float kMaskDark = 0.5;
const float kMaskLight = 1.5;
const vec2 kSourceRes = vec2(1024.0, 768.0);

const float kGlassCurvature = 0.15;
const float kChromaticAberration = 0.008;
const float kHighlightStrength = 0.25;
const float kFresnelStrength = 0.15;
const float kImperfectionFreq = 40.0;
const float kImperfectionStrength = 0.06;

float toLinear1(float c) {
    return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

vec3 toLinear(vec3 c) {
    return vec3(toLinear1(c.r), toLinear1(c.g), toLinear1(c.b));
}

float toSrgb1(float c) {
    return (c < 0.0031308) ? c * 12.92 : 1.055 * pow(c, 0.41666) - 0.055;
}

vec3 toSrgb(vec3 c) {
    return vec3(toSrgb1(c.r), toSrgb1(c.g), toSrgb1(c.b));
}

vec3 fetch(vec2 pos, vec2 off, vec2 res) {
    pos = (floor(pos * res) + off + 0.5) / res;
    if (pos.x < 0.0 || pos.x > 1.0 || pos.y < 0.0 || pos.y > 1.0) {
        return vec3(0.0);
    }
    return toLinear(texture(uTexture, pos).rgb);
}

vec2 dist(vec2 pos, vec2 res) {
    pos = pos * res;
    return -((pos - floor(pos)) - vec2(0.5));
}

float gaus(float pos, float scale) {
    return exp2(scale * pos * pos);
}

vec3 horz3(vec2 pos, float off, float hardPix, vec2 res) {
    vec3 b = fetch(pos, vec2(-1.0, off), res);
    vec3 c = fetch(pos, vec2(0.0, off), res);
    vec3 d = fetch(pos, vec2(1.0, off), res);
    float dst = dist(pos, res).x;
    float scale = hardPix;
    float wb = gaus(dst - 1.0, scale);
    float wc = gaus(dst + 0.0, scale);
    float wd = gaus(dst + 1.0, scale);
    return (b * wb + c * wc + d * wd) / (wb + wc + wd);
}

vec3 horz5(vec2 pos, float off, float hardPix, vec2 res) {
    vec3 a = fetch(pos, vec2(-2.0, off), res);
    vec3 b = fetch(pos, vec2(-1.0, off), res);
    vec3 c = fetch(pos, vec2(0.0, off), res);
    vec3 d = fetch(pos, vec2(1.0, off), res);
    vec3 e = fetch(pos, vec2(2.0, off), res);
    float dst = dist(pos, res).x;
    float scale = hardPix;
    float wa = gaus(dst - 2.0, scale);
    float wb = gaus(dst - 1.0, scale);
    float wc = gaus(dst + 0.0, scale);
    float wd = gaus(dst + 1.0, scale);
    float we = gaus(dst + 2.0, scale);
    return (a * wa + b * wb + c * wc + d * wd + e * we) / (wa + wb + wc + wd + we);
}

float scan(vec2 pos, float off, float hardScan, vec2 res) {
    float dst = dist(pos, res).y;
    return gaus(dst + off, hardScan);
}

vec3 tri(vec2 pos, float hardScan, float hardPix, vec2 res) {
    vec3 a = horz3(pos, -1.0, hardPix, res);
    vec3 b = horz5(pos, 0.0, hardPix, res);
    vec3 c = horz3(pos, 1.0, hardPix, res);
    float wa = scan(pos, -1.0, hardScan, res);
    float wb = scan(pos, 0.0, hardScan, res);
    float wc = scan(pos, 1.0, hardScan, res);
    return a * wa + b * wb + c * wc;
}

vec2 warp(vec2 pos) {
    pos = pos * 2.0 - 1.0;
    pos *= vec2(1.0 + (pos.y * pos.y) * kWarp.x, 1.0 + (pos.x * pos.x) * kWarp.y);
    return pos * 0.5 + 0.5;
}

vec3 mask(vec2 pos) {
    pos.x += pos.y * 3.0;
    vec3 m = vec3(kMaskDark);
    pos.x = fract(pos.x / 6.0);
    if (pos.x < 0.333) {
        m.r = kMaskLight;
    } else if (pos.x < 0.666) {
        m.g = kMaskLight;
    } else {
        m.b = kMaskLight;
    }
    return m;
}

vec3 mod289v3(vec3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 mod289v4(vec4 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 permute(vec4 x) {
    return mod289v4(((x * 34.0) + 1.0) * x);
}

vec4 taylorInvSqrt(vec4 r) {
    return 1.79284291400159 - 0.85373472095314 * r;
}

float snoise(vec3 v) {
    const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
    const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);

    vec3 i = floor(v + dot(v, C.yyy));
    vec3 x0 = v - i + dot(i, C.xxx);

    vec3 g = step(x0.yzx, x0.xyz);
    vec3 l = 1.0 - g;
    vec3 i1 = min(g.xyz, l.zxy);
    vec3 i2 = max(g.xyz, l.zxy);

    vec3 x1 = x0 - i1 + C.xxx;
    vec3 x2 = x0 - i2 + C.yyy;
    vec3 x3 = x0 - D.yyy;

    i = mod289v3(i);
    vec4 p = permute(permute(permute(
                i.z + vec4(0.0, i1.z, i2.z, 1.0))
              + i.y + vec4(0.0, i1.y, i2.y, 1.0))
              + i.x + vec4(0.0, i1.x, i2.x, 1.0));

    float n_ = 0.142857142857;
    vec3 ns = n_ * D.wyz - D.xzx;

    vec4 j = p - 49.0 * floor(p * ns.z * ns.z);

    vec4 x_ = floor(j * ns.z);
    vec4 y_ = floor(j - 7.0 * x_);

    vec4 x = x_ * ns.x + ns.yyyy;
    vec4 y = y_ * ns.x + ns.yyyy;
    vec4 h = 1.0 - abs(x) - abs(y);

    vec4 b0 = vec4(x.xy, y.xy);
    vec4 b1 = vec4(x.zw, y.zw);

    vec4 s0 = floor(b0) * 2.0 + 1.0;
    vec4 s1 = floor(b1) * 2.0 + 1.0;
    vec4 sh = -step(h, vec4(0.0));

    vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

    vec3 p0 = vec3(a0.xy, h.x);
    vec3 p1 = vec3(a0.zw, h.y);
    vec3 p2 = vec3(a1.xy, h.z);
    vec3 p3 = vec3(a1.zw, h.w);

    vec4 norm = taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x;
    p1 *= norm.y;
    p2 *= norm.z;
    p3 *= norm.w;

    vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

vec3 sampleCrt(vec2 pos, vec2 fragCoord, float hardScan, float hardPix, vec2 res) {
    vec3 color = tri(pos, hardScan, hardPix, res) * mask(fragCoord);
    return toSrgb(color);
}

vec3 getGlassNormal(vec2 uv) {
    vec2 centered = uv * 2.0 - 1.0;
    float nx = -centered.x * kGlassCurvature * 2.0;
    float ny = -centered.y * kGlassCurvature * 2.0;

    float eps = 0.002;
    vec3 pos = vec3(uv * kImperfectionFreq, 0.0);
    float noiseR = snoise(pos + vec3(eps, 0.0, 0.0));
    float noiseL = snoise(pos - vec3(eps, 0.0, 0.0));
    float noiseU = snoise(pos + vec3(0.0, eps, 0.0));
    float noiseD = snoise(pos - vec3(0.0, eps, 0.0));

    float dnx = (noiseR - noiseL) / (2.0 * eps) * kImperfectionStrength;
    float dny = (noiseU - noiseD) / (2.0 * eps) * kImperfectionStrength;

    nx += dnx;
    ny += dny;

    return normalize(vec3(nx, ny, 1.0));
}

vec3 applyGlassEffect(vec2 uv, vec2 fragCoord, float hardScan, float hardPix, vec2 res) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return vec3(0.0);
    }

    vec3 normal = getGlassNormal(uv);

    vec2 centered = uv * 2.0 - 1.0;
    float distFromCenter = length(centered);

    float aberration = kChromaticAberration * distFromCenter;

    vec2 offsetR = normal.xy * aberration * 1.2;
    vec2 offsetG = normal.xy * aberration * 0.0;
    vec2 offsetB = normal.xy * aberration * -1.2;

    vec2 coordR = clamp(uv + offsetR, 0.0, 1.0);
    vec2 coordG = clamp(uv + offsetG, 0.0, 1.0);
    vec2 coordB = clamp(uv + offsetB, 0.0, 1.0);

    vec2 fragCoordR = coordR * uResolution;
    vec2 fragCoordG = coordG * uResolution;
    vec2 fragCoordB = coordB * uResolution;

    vec3 crtR = sampleCrt(coordR, fragCoordR, hardScan, hardPix, res);
    vec3 crtG = sampleCrt(coordG, fragCoordG, hardScan, hardPix, res);
    vec3 crtB = sampleCrt(coordB, fragCoordB, hardScan, hardPix, res);

    vec3 color = vec3(crtR.r, crtG.g, crtB.b);

    float topHighlight = 1.0 - smoothstep(-0.8, 0.3, centered.y);
    topHighlight *= 1.0 - smoothstep(0.0, 1.0, abs(centered.x));
    topHighlight = pow(topHighlight, 2.0) * kHighlightStrength;
    color += vec3(topHighlight);

    vec3 viewDir = vec3(0.0, 0.0, 1.0);
    float fresnel = pow(1.0 - max(0.0, dot(normal, viewDir)), 4.0);
    color = mix(color, color * 1.1 + vec3(0.02), fresnel * kFresnelStrength);

    float edgeDarken = 1.0 - distFromCenter * 0.08;
    color *= edgeDarken;

    return color;
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;
    vec2 res = kSourceRes;

    int mode = int(uMode);

    if (mode == 0) {
        fragColor = texture(uTexture, uv);
    } else if (mode == 1) {
        vec2 warpedPos = warp(uv);
        vec3 color = tri(warpedPos, kHardScanSoft, kHardPixSoft, res) * mask(fragCoord);
        fragColor = vec4(toSrgb(color), 1.0);
    } else if (mode == 2) {
        vec3 color = tri(uv, kHardScanSoft, kHardPixSoft, res) * mask(fragCoord);
        fragColor = vec4(toSrgb(color), 1.0);
    } else {
        vec2 warpedPos = warp(uv);
        vec2 warpedFragCoord = warpedPos * uResolution;
        vec3 glassColor = applyGlassEffect(warpedPos, warpedFragCoord, kHardScanSoft, kHardPixSoft, res);
        fragColor = vec4(glassColor, 1.0);
    }
}
