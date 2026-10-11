// Imperfection - rival A: "rectangle collage".
//
// The painting is rebuilt as a stack of axis-aligned rectangles painted back to
// front over a hand-authored colour field that follows the cross composition
// (warm column + red band, ice-blue column, navy right half). Every rectangle
// takes its colour from the field near its centre and is textured with 1D hash
// streaks along its grain, so the fine texture is anisotropic everywhere.
//
// Layer stack (back to front):
//   1. baseLayer     - colour field, smeared along the local grain per column
//   2. gridLayer x2  - large jittered rectangle grids (glazes and slabs)
//   3. dripLayer     - vertical drips carrying field colour downward
//   4. heroLayer     - hand-placed key blocks that pin the composition
//   5. gridLayer x1  - small tall rectangles, densest in the warm column
//   6. hatchLayer    - diagonal hatching confined to soft zones
//   7. accentLayer   - soot strip under the red band, dark scratches, red specks
//   8. grade         - contrast and sRGB output

#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif

#include "common.glsl"

// ---- palette (analysis section 2, sRGB hex) ----------------------------------
const int COL_BUTTER   = 0xf7c95a;
const int COL_SAFFRON  = 0xf0a23a;
const int COL_ORANGE   = 0xe8742f;
const int COL_VERMIL   = 0xd9442a;
const int COL_CORAL    = 0xe8705e;
const int COL_CRIMSON  = 0xb81e2a;
const int COL_MAROON   = 0x5e1420;
const int COL_OXBLOOD  = 0x3a0d15;
const int COL_ICE      = 0xbfe0f0;
const int COL_SKY      = 0x8fb8d4;
const int COL_INK      = 0x070d16;

// ---- tunables ---------------------------------------------------------------
const float REF_RES      = 1024.0; // texture scales are authored in reference pixels
const float STREAK_L     = 0.16;   // streak swing in OKLab lightness (peak to peak)
const float DRAG_MAX     = 0.07;   // max colour drag of the base smear along the grain (uv)
const float SEAM_DITHER  = 0.75;   // how ragged the warm/cool seam threads are (0 = smooth)
const float THREAD_JIT   = 0.025;  // per-column sideways sampling jitter (colour threads, uv)
const float THREAD_RED   = 0.12;   // share of warm column bundles that turn red
const float GRID_DENSITY = 0.65;   // global probability scale of procedural rectangles
const float DRIP_DENSITY = 0.4;    // share of column segments that carry a drip
const float HATCH_BACK   = 2.29;   // "\" grain of rectangles in the left hatch zone (rad, ~131 deg CCW)
const vec2  HATCH_PIVOT  = vec2(0.34, 0.40); // the left-edge hatching radiates from here
const float HATCH_FWD    = 0.95;   // "/" hatching direction (rad, ~54 deg CCW)
const float HATCH_AMT    = 0.8;    // hatching strength
const float CONTRAST     = 1.06;   // final lightness contrast

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

// ---- small helpers ----------------------------------------------------------
float vnoise1(float x) {
    float i = floor(x), f = fract(x);
    return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// Soft axis-aligned box mask: 1 inside [lo, hi], `s` = edge softness.
float sbox(vec2 p, vec2 lo, vec2 hi, vec2 s) {
    vec2 a = smoothstep(lo - s, lo + s, p) * (1.0 - smoothstep(hi - s, hi + s, p));
    return a.x * a.y;
}

// OKLab (Ottosson) for perceptual lightness jitter.
vec3 toLab(vec3 c) {
    vec3 lms = mat3(0.4122214708, 0.2119034982, 0.0883024619,
                    0.5363325363, 0.6806995451, 0.2817188376,
                    0.0514459929, 0.1073969566, 0.6299787005) * max(c, 0.0);
    lms = pow(lms, vec3(1.0 / 3.0));
    return mat3(0.2104542553, 1.9779984951, 0.0259040371,
                0.7936177850, -2.4285922050, 0.7827717662,
                -0.0040720468, 0.4505937099, -0.8086757660) * lms;
}
vec3 fromLab(vec3 c) {
    vec3 lms = mat3(1.0, 1.0, 1.0,
                    0.3963377774, -0.1055613458, -0.0894841775,
                    0.2158037573, -0.0638541728, -1.2914855480) * c;
    lms = lms * lms * lms;
    return mat3(4.0767416621, -1.2684380046, -0.0041960863,
                -3.3077115913, 2.6097574011, -0.7034186147,
                0.2309699292, -0.3413193965, 1.7076147010) * lms;
}

// Shift perceptual lightness by d while keeping hue: a cheap stand-in for an
// OKLab round trip (L ~ cbrt(luma), so scaling linear RGB by ((L+d)/L)^3).
vec3 shadeL(vec3 c, float d) {
    float L = pow(max(dot(c, LUMA), 1e-5), 1.0 / 3.0);
    float k = max(1.0 + d / L, 0.0);
    return c * k * k * k;
}

// Streak value in [0, 1]. `a` runs across the grain, `l` along it (both in
// reference pixels). Each 1 px column gets its own value, 3 px bundles add a
// coarser layer, a 1D noise along the grain lets a column fade in and out over
// 12-150 px, and a faint per-pixel grain keeps it from looking machine-made.
float streaks(float a, float l, float seed) {
    float c1 = floor(a);
    float h1 = hash11(c1 * 1.37 + seed);
    float h3 = hash11(floor(a / 3.0 + seed) * 7.13 + seed);
    float f  = mix(1.0 / 90.0, 1.0 / 6.0, hash11(c1 * 0.71 + seed * 5.7));
    float n  = vnoise1(l * f + h1 * 37.0);
    float g  = hash12(vec2(c1, floor(l / 2.0)) + seed);
    return clamp(0.17 * h1 + 0.13 * h3 + 0.4 * n + 0.3 * g, 0.0, 1.0);
}

// Hue threads: a few 2-4 px column bundles inside warm paint turn vermilion/red,
// the way the reference has red threads running through its orange.
vec3 hueThreads(vec3 c, float a, float seed) {
    float b = floor(a / mix(2.0, 4.0, hash11(seed + 0.5)));
    float h = hash11(b * 3.71 + seed);
    float warm = step(c.b * 1.6, c.r);
    return mix(c, c * vec3(1.0, 0.45, 0.4), warm * step(1.0 - THREAD_RED, h) * mix(0.5, 1.0, fract(h * 13.0)));
}

// ---- 1. colour field ----------------------------------------------------------
// How warm a point is (0 cool, 1 warm): the cross of warm column and red band.
float warmMask(vec2 p) {
    // lower column: edges wander with height, so the warm columns drip unevenly
    float wl = (vnoise1(p.y * 9.0) - 0.5) * 0.05, wr = (vnoise1(p.y * 7.0 + 3.0) - 0.5) * 0.06;
    float m = sbox(p, vec2(0.25 + wl, -0.1), vec2(0.42 + wr, 0.46), vec2(0.012, 0.03));
    float re = mix(0.53, 0.43, smoothstep(0.48, 0.70, p.y));                    // body leans left upward
    m = max(m, sbox(p, vec2(0.10, 0.44), vec2(re, 0.77), vec2(0.03, 0.02)));    // wide body
    m = max(m, sbox(p, vec2(-0.1, 0.50), vec2(0.2, 0.77), vec2(0.02)));         // left edge, upper half
    m = max(m, sbox(p, vec2(-0.1, 0.74), vec2(0.375, 1.1), vec2(0.02)));        // top-left
    m = max(m, sbox(p, vec2(0.47, 0.335), vec2(0.96, 0.50), vec2(0.03, 0.015))); // red band
    return m;
}

// Warm family colour at p: orange body, yellow core, coral->oxblood left edge,
// burnt-orange lower column, maroon red band.
vec3 warmColor(vec2 p) {
    vec3 c = hexColor(COL_ORANGE);
    // saffron halo and butter-yellow core around (0.32, 0.67)
    vec2 d = (p - vec2(0.32, 0.67)) / vec2(0.10, 0.16);
    c = mix(c, hexColor(COL_SAFFRON), exp(-dot(d, d) * 0.9));
    d = (p - vec2(0.32, 0.67)) / vec2(0.05, 0.09);
    c = mix(c, hexColor(COL_BUTTER), exp(-dot(d, d)));
    // upper column: peach / saffron up to the top edge
    c = mix(c, hexColor(0xd89a88), sbox(p, vec2(0.13, 0.86), vec2(0.36, 1.1), vec2(0.04)));
    // left edge: coral at the top, through red and maroon to oxblood near v = 0.5
    vec3 lc = hexColor(COL_CORAL);
    lc = mix(lc, hexColor(0xa84038), smoothstep(0.9, 0.76, p.y));
    lc = mix(lc, hexColor(0x7a2426), smoothstep(0.74, 0.64, p.y));
    lc = mix(lc, hexColor(COL_OXBLOOD), smoothstep(0.68, 0.58, p.y));
    lc = mix(lc, hexColor(0x14060a), smoothstep(0.56, 0.48, p.y));
    c = mix(c, lc, 1.0 - smoothstep(0.08, 0.16, p.x));
    // left body: vermilion-red between the coral edge and the column
    c = mix(c, hexColor(0xb04432), sbox(p, vec2(0.08, 0.44), vec2(0.21, 0.62), vec2(0.03)));
    // lower body (v 0.38-0.5): red-orange
    c = mix(c, hexColor(0xd2501e), sbox(p, vec2(0.2, 0.3), vec2(0.6, 0.5), vec2(0.03)));
    // lower column: burnt orange, a vermilion core, dark brown on its right side
    float low = 1.0 - smoothstep(0.36, 0.42, p.y);
    vec3 cc = mix(hexColor(0xa8582a), hexColor(0x945028), smoothstep(0.3, 0.0, p.y));
    cc = mix(cc, hexColor(0xb8401c), sbox(p, vec2(0.30, 0.2), vec2(0.37, 0.46), vec2(0.02)) * 0.8);
    cc = mix(cc, hexColor(0xa04420), smoothstep(0.36, 0.40, p.x));
    cc = mix(cc, hexColor(0x3a2018), smoothstep(0.36, 0.40, p.x) * smoothstep(0.30, 0.22, p.y));
    c = mix(c, cc, low);
    // red band: red-orange near the column, maroon, oxblood toward the right edge
    float band = smoothstep(0.46, 0.52, p.x);
    vec3 bc = mix(hexColor(0x7a2012), hexColor(0x3e0c14), smoothstep(0.5, 0.64, p.x));
    bc = mix(bc, hexColor(0x2e0a12), smoothstep(0.8, 0.96, p.x));
    c = mix(c, bc, band);
    return c;
}

// Cool family colour at p: four horizontal anchor rows blended vertically.
vec3 coolColor(vec2 p) {
    float u = p.x;
    // top row (v ~ 0.85): mauve-grey, ice column, sky, steel, navy
    vec3 t = hexColor(0xa09ab0);
    t = mix(t, hexColor(0xb0d4e8), smoothstep(0.36, 0.42, u));
    t = mix(t, hexColor(0x7aa0bc), smoothstep(0.47, 0.53, u));
    t = mix(t, hexColor(0x4e6e86), smoothstep(0.56, 0.66, u));
    t = mix(t, hexColor(0x1c4260), smoothstep(0.70, 0.78, u));
    t = mix(t, hexColor(0x04121f), smoothstep(0.82, 0.92, u));
    // middle row (v ~ 0.62): steel fading into near-black on the right
    vec3 m = hexColor(0x0c1a28);
    m = mix(m, hexColor(0x9aa8b0), smoothstep(0.30, 0.40, u));
    m = mix(m, hexColor(0x4a7a98), smoothstep(0.42, 0.48, u));
    m = mix(m, hexColor(0x203c54), smoothstep(0.52, 0.62, u));
    m = mix(m, hexColor(0x08162a), smoothstep(0.62, 0.72, u));
    m = mix(m, hexColor(0x010509), smoothstep(0.72, 0.84, u));
    // lower-middle row (v ~ 0.33): navy, black under the red band, blue-grey right
    vec3 lm = hexColor(0x0a1e30);
    lm = mix(lm, hexColor(0x14283a), smoothstep(0.15, 0.3, u));
    lm = mix(lm, hexColor(0x04070d), smoothstep(0.45, 0.55, u));
    lm = mix(lm, hexColor(0x1c2a3e), smoothstep(0.8, 1.0, u));
    // bottom row (v ~ 0.05): grey-blue left, navy right
    vec3 b = hexColor(0x5a6a78);
    b = mix(b, hexColor(0x3a4e62), smoothstep(0.08, 0.16, u));
    b = mix(b, hexColor(0x1a3044), smoothstep(0.16, 0.24, u));
    b = mix(b, hexColor(0x2a1e1e), smoothstep(0.34, 0.42, u));
    b = mix(b, hexColor(0x061a30), smoothstep(0.46, 0.52, u));
    b = mix(b, hexColor(0x0a2a46), smoothstep(0.50, 0.6, u));
    b = mix(b, hexColor(0x07223a), smoothstep(0.62, 0.72, u));

    vec3 c = mix(b, lm, smoothstep(0.08, 0.3, p.y));
    c = mix(c, m, smoothstep(0.42, 0.6, p.y));
    c = mix(c, t, smoothstep(0.64, 0.86, p.y));
    // dark "/" wedge in the upper right
    float w = dot(p - vec2(0.86, 0.70), normalize(vec2(-0.75, 1.0)));
    float wedge = (1.0 - smoothstep(0.0, 0.05, abs(w))) * smoothstep(0.55, 0.65, p.y) * smoothstep(0.74, 0.84, p.x);
    c = mix(c, hexColor(COL_INK), wedge * 0.85);
    return c;
}

// Crisp field for sampling rectangle colours: warm or cool, never mud.
vec3 fieldColor(vec2 p) {
    return warmMask(p) > 0.5 ? warmColor(p) : coolColor(p);
}

// Where the grain runs horizontally (0 = vertical, 1 = horizontal): the dark
// area right of the red band, the shadow strip and the blue blocks on the left.
float horizZone(vec2 p) {
    float z = sbox(p, vec2(0.72, 0.24), vec2(1.1, 0.58), vec2(0.04));
    z = max(z, sbox(p, vec2(0.46, 0.245), vec2(1.1, 0.37), vec2(0.03)));
    z = max(z, sbox(p, vec2(-0.1, 0.32), vec2(0.21, 0.5), vec2(0.03)));
    z = max(z, sbox(p, vec2(0.80, 0.12), vec2(1.1, 0.26), vec2(0.04)) * 0.8);
    return z;
}

// ---- 1. base layer ------------------------------------------------------------
// The field smeared along the local grain: each pixel column (or row, in the
// horizontal zones) drags the colour by its own amount (drips), samples a little
// sideways (colour threads), and resolves the warm/cool seam with a random
// threshold, so the seam becomes interleaved threads instead of grey.
vec3 baseLayer(vec2 p, vec2 pix) {
    bool horiz = horizZone(p) > 0.5 + (vnoise1(pix.x / 37.0 + pix.y / 53.0) - 0.5) * 0.4;
    float across = horiz ? pix.y : pix.x;
    float along  = horiz ? pix.x : pix.y;
    float col  = floor(across / 2.0);
    float drag = pow(hash11(col * 3.17), 2.5) * DRAG_MAX;
    float side = (hash11(col * 5.31 + 2.0) - 0.5) * THREAD_JIT;
    vec2  q    = horiz ? p + vec2(-drag, side) : p + vec2(side, drag);
    float tb   = floor(across / 2.0);
    float thr  = 0.5 + (vnoise1(along / mix(10.0, 60.0, hash11(tb * 2.3)) + hash11(tb * 1.91) * 50.0) - 0.5) * SEAM_DITHER * 1.4;
    thr        = clamp(thr, 0.06, 0.94);
    vec3  c    = warmMask(q) > thr ? warmColor(q) : coolColor(q);
    float s    = streaks(across, along, 11.0);
    c = hueThreads(c, across, 11.0);
    return shadeL(c, (s - 0.5) * STREAK_L);
}

// ---- rectangle painter -----------------------------------------------------------
// Paints one textured rectangle over dst. grain: 0 vertical, 1 horizontal,
// 2 diagonal "\", 3 diagonal "/". alpha < 1 makes a glaze: coverage is decided
// per streak column, so the colour beneath shows through as threads. rag
// recesses the along-grain ends per column bundle (fraction of the extent).
vec3 paintRect(vec3 dst, vec2 p, vec2 pix, vec4 box, vec3 col, float grain, float alpha, float rag, float seed) {
    vec2 lo = box.xy, hi = box.zw;
    float across, along;
    float pa = p.y, l0 = lo.y, l1 = hi.y;   // along-grain extent used for ragged ends
    if (grain < 0.5) {
        across = pix.x; along = pix.y;
    } else if (grain < 1.5) {
        across = pix.y; along = pix.x;
        pa = p.x; l0 = lo.x; l1 = hi.x;
    } else {
        float ang = grain < 2.5 ? HATCH_BACK : HATCH_FWD;
        vec2 t = vec2(cos(ang), sin(ang));
        across = dot(pix, vec2(-t.y, t.x)); along = dot(pix, t);
    }
    // ragged along-grain ends (bundles of 1-3 columns)
    float hc  = floor(across / mix(1.0, 3.0, hash11(seed)));
    float len = l1 - l0;
    float r0  = pow(hash11(hc * 1.13 + seed), 4.0) * rag * len;
    float r1  = pow(hash11(hc * 2.71 + seed + 5.0), 4.0) * rag * len;
    if (pa < l0 + r0 || pa > l1 - r1) return dst;

    float s   = streaks(across, along, seed);
    float amp = grain > 1.5 ? STREAK_L * 1.3 : STREAK_L;
    // the block's colour drifts slowly along the grain (not a gradient across it)
    float drift = (vnoise1(along / 140.0 + seed * 0.37) - 0.5) * 0.14;
    vec3  c   = shadeL(hueThreads(col, across, seed), (s - 0.5) * amp + drift);
    // glaze: per-column coverage decision softened a little
    float cov = mix(alpha, step(hash11(floor(across) * 0.37 + seed * 3.3), alpha), 0.7);
    // horizontal smears fade out toward their right end, each row at its own length
    if (grain > 0.5 && grain < 1.5) {
        float fl = len * mix(0.1, 0.45, hash11(floor(across / 2.0) * 3.9 + seed));
        cov *= smoothstep(l1, l1 - fl, pa);
    }
    return mix(dst, c, cov);
}

// ---- 2./4. procedural rectangle grid -------------------------------------------
// Where procedural rectangles may appear: densest in the warm column and the red
// band, sparse in the dark right half.
float rectDensity(vec2 p) {
    float w = warmMask(p);
    float band = sbox(p, vec2(0.45, 0.28), vec2(1.0, 0.62), vec2(0.04));
    return clamp(0.3 + 0.55 * w + 0.25 * band, 0.0, 1.0);
}

// Diagonal-hatch zones for rectangle grain: left edge top half ("\"), red band ("/").
float hatchZoneBack(vec2 p) { return sbox(p, vec2(-0.1, 0.5), vec2(0.22, 1.1), vec2(0.05)); }
float hatchZoneFwd(vec2 p)  { return sbox(p, vec2(0.55, 0.40), vec2(0.80, 0.62), vec2(0.03)); }

// One jittered grid of rectangles. cell = cell size (uv), off = grid offset, the
// rectangles reach up to half a cell into their neighbours, so the 2x2 nearest
// cells are tested and the one with the highest z wins.
vec3 gridLayer(vec3 dst, vec2 p, vec2 pix, vec2 cell, vec2 off, float seed, float dens, float glaze) {
    vec2 q  = (p - off) / cell;
    vec2 ci = floor(q);
    vec2 nb = step(0.5, fract(q)) * 2.0 - 1.0;
    float bestZ = -1.0;
    vec4  bestBox = vec4(0.0);
    vec3  bestH = vec3(0.0);
    for (int k = 0; k < 4; k++) {
        vec2 c  = ci + vec2(float(k & 1), float(k >> 1)) * nb;
        vec3 h  = hash33(vec3(c, seed));
        vec3 h2 = hash33(vec3(c + 17.0, seed + 3.1));
        vec2 ctr = c + 0.5 + (h.xy - 0.5) * 0.5;
        vec2 hs  = vec2(mix(0.22, 0.55, h2.x), mix(0.35, 0.75, h2.y));
        vec2 wc  = ctr * cell + off;
        if (h.z > dens * GRID_DENSITY * rectDensity(wc)) continue;
        if (all(lessThan(abs(q - ctr), hs)) && h2.z > bestZ) {
            bestZ = h2.z;
            bestBox = vec4((ctr - hs) * cell + off, (ctr + hs) * cell + off);
            bestH = hash33(vec3(c + 41.0, seed + 7.7));
        }
    }
    if (bestZ < 0.0) return dst;

    vec2 wc = 0.5 * (bestBox.xy + bestBox.zw);
    vec3 col = fieldColor(wc + (bestH.xy - 0.5) * cell * 0.6);
    col = shadeL(col, (bestH.z - 0.5) * 0.1);
    // grain follows the zone: horizontal right of the band, diagonal in hatch zones
    float grain = bestH.y < mix(0.75, 0.1, horizZone(wc)) ? 0.0 : 1.0;
    if (hatchZoneBack(wc) > 0.5 && bestH.x < 0.45) grain = 2.0;
    if (hatchZoneFwd(wc) > 0.5 && bestH.x < 0.45) grain = 3.0;
    float alpha = bestH.z < glaze ? mix(0.35, 0.65, bestH.x) : mix(0.85, 1.0, bestH.y);
    return paintRect(dst, p, pix, bestBox, col, grain, alpha, 0.06, seed + bestZ * 91.0);
}

// ---- 3. hero blocks -----------------------------------------------------------
// Hand-placed key rectangles that pin the composition (uv box: u0, v0, u1, v1).
// Parameters: x = sRGB hex colour, y = grain (0 v, 1 h, 2 "\", 3 "/"), z = alpha, w = rag.
const int HERO_N = 23;
const vec4 HERO_BOX[HERO_N] = vec4[](
    vec4(0.20, 0.64, 0.29, 0.88),  // upper orange column
    vec4(0.10, 0.70, 0.21, 0.91),  // saffron hatch block
    vec4(0.08, 0.56, 0.20, 0.71),  // salmon block
    vec4(0.02, 0.71, 0.12, 0.76),  // dark maroon smear
    vec4(0.11, 0.475, 0.25, 0.52), // tan horizontal block
    vec4(0.015, 0.35, 0.11, 0.45), // blue block left A
    vec4(0.085, 0.345, 0.205, 0.43), // blue block left B
    vec4(0.40, 0.64, 0.50, 0.98),  // ice core drips
    vec4(0.31, 0.41, 0.53, 0.525), // big orange block
    vec4(0.36, 0.52, 0.50, 0.565), // yellow-ochre horizontal block
    vec4(0.32, 0.22, 0.38, 0.40),  // vermilion column
    vec4(0.25, 0.00, 0.33, 0.30),  // lower orange column
    vec4(0.55, 0.52, 0.60, 0.60),  // crimson tall block
    vec4(0.64, 0.56, 0.72, 0.625), // dark red hatched block
    vec4(0.48, 0.335, 0.78, 0.41), // red-orange slab
    vec4(0.68, 0.43, 0.78, 0.53),  // coral pink block
    vec4(0.78, 0.375, 0.95, 0.46), // crimson wide block
    vec4(0.67, 0.72, 0.81, 0.94),  // grey-brown bars, upper right
    vec4(0.81, 0.72, 0.99, 0.90),  // mid-blue block, upper right
    vec4(0.84, 0.25, 1.00, 0.32),  // horizontal blue block, bottom right
    vec4(0.04, 0.00, 0.13, 0.20),  // light grey-blue drips, bottom left
    vec4(0.84, 0.00, 0.97, 0.10),  // light blue drips, bottom right
    vec4(0.22, 0.86, 0.37, 1.00)   // mauve glaze over the top of the column
);
const vec4 HERO_PRM[HERO_N] = vec4[](
    vec4(float(0xf09a48), 0.0, 0.75, 0.25),
    vec4(float(0xf0a23a), 2.0, 0.85, 0.05),
    vec4(float(0xd8704c), 0.0, 0.90, 0.05),
    vec4(float(0x4a1a22), 1.0, 0.80, 0.10),
    vec4(float(0xb88a62), 1.0, 0.85, 0.05),
    vec4(float(0x152840), 1.0, 0.95, 0.05),
    vec4(float(0x22425c), 1.0, 0.90, 0.05),
    vec4(float(0xa8cce0), 0.0, 0.75, 0.45),
    vec4(float(0xe07a2a), 0.0, 0.85, 0.08),
    vec4(float(0xe0a848), 1.0, 0.95, 0.03),
    vec4(float(0xb8381a), 0.0, 0.85, 0.20),
    vec4(float(0xc0702e), 0.0, 0.70, 0.30),
    vec4(float(0x9a121c), 0.0, 0.95, 0.05),
    vec4(float(0x5a121c), 3.0, 0.90, 0.05),
    vec4(float(0x5e1c10), 1.0, 0.85, 0.05),
    vec4(float(0xc85050), 3.0, 0.95, 0.03),
    vec4(float(0x74101a), 1.0, 0.90, 0.05),
    vec4(float(0x4a5e70), 0.0, 0.80, 0.10),
    vec4(float(0x12304a), 0.0, 0.80, 0.10),
    vec4(float(0x24405a), 1.0, 0.75, 0.05),
    vec4(float(0x5a6a80), 0.0, 0.70, 0.25),
    vec4(float(0x24486a), 0.0, 0.45, 0.50),
    vec4(float(0xa48a98), 0.0, 0.55, 0.30)
);

vec3 heroLayer(vec3 dst, vec2 p, vec2 pix) {
    for (int i = 0; i < HERO_N; i++) {
        vec4 b = HERO_BOX[i];
        if (p.x < b.x || p.x > b.z || p.y < b.y || p.y > b.w) continue;
        vec4 m = HERO_PRM[i];
        dst = paintRect(dst, p, pix, b, hexColor(int(m.x)), m.y, m.z, m.w, float(i) * 13.7 + 101.0);
    }
    return dst;
}

// ---- 5a. vertical drips ----------------------------------------------------------
// 3 px column bundles split into segments of 120-420 px. Some segments hold a
// drip: the field colour from the drip's top is carried down and fades out at
// its tip, a little lighter or darker than what lies beneath. Drips live where
// the grain is vertical and no hatching zone is active.
vec3 dripLayer(vec3 dst, vec2 p, vec2 pix) {
    float z = (1.0 - horizZone(p)) * (1.0 - hatchZoneBack(p)) * (1.0 - 0.7 * hatchZoneFwd(p));
    z *= 1.0 - 0.7 * sbox(p, vec2(0.72, 0.55), vec2(1.1, 0.78), vec2(0.04)); // the dark right stays dark
    if (z < 0.05) return dst;
    float cb = floor(pix.x / 3.0);
    vec3 h = hash33(vec3(cb, 3.0, 7.0));
    float L = mix(120.0, 420.0, h.x);
    float s = (pix.y + h.y * 997.0) / L;
    float si = floor(s), sf = fract(s);           // sf: 0 at segment bottom, 1 at top
    vec3 h2 = hash33(vec3(cb, si, 11.0));
    if (h2.x > DRIP_DENSITY * z) return dst;
    float len = mix(0.3, 0.95, h2.y);              // drip occupies the top part of the segment
    float t = (sf - (1.0 - len)) / len;            // 0 at the tip, 1 at the top
    if (t < 0.0) return dst;
    vec2 top = vec2(p.x, p.y + (1.0 - t) * len * L / REF_RES);
    vec3 c = fieldColor(top);
    // light or dark drip; below the ice column the drips are mostly dark navy
    float dk = sbox(p, vec2(0.48, 0.5), vec2(0.72, 0.8), vec2(0.04));
    c = shadeL(c, mix(-0.10, 0.12, h.z) - dk * 0.22 + (hash11(floor(pix.x) + si) - 0.5) * 0.08);
    float a = smoothstep(0.0, 0.4, t) * mix(0.4, 0.85, h2.z);
    return mix(dst, c, a);
}

// ---- 5b. diagonal hatching -----------------------------------------------------
// Short, nearly parallel strokes in a stroke-aligned frame (a = across in px,
// l = along in px): rows `spacing` px apart, each row split into segments of
// random length; a segment is a bright or dark stroke with tapered ends.
// Strokes come in bundles whose density swells and fades across the rows.
// Returns signed intensity (+ bright, - dark).
float hatchStrokes(float a, float l, float dens, float seed, float spacing) {
    a /= spacing;
    float row = floor(a);
    float hr = hash11(row * 1.7 + seed);
    float seg = mix(30.0, 120.0, hr);
    float s = (l + hr * 731.0) / seg;
    float si = floor(s), sf = fract(s);
    vec2 h = hash22(vec2(row, si) + seed);
    float bundle = smoothstep(0.25, 0.75, vnoise1(row / 9.0 + seed));
    if (h.x > dens * (0.3 + 1.2 * bundle)) return 0.0;
    float taper = smoothstep(0.0, 0.25, sf) * smoothstep(1.0, 0.6, sf);
    float across = 1.0 - abs(fract(a) - 0.5) * 2.0;
    // inside dense bundles the strokes are mostly dark (the soot clumps)
    float darkP = mix(0.45, 0.8, bundle);
    return (h.y < darkP ? -1.0 : 0.7) * taper * smoothstep(0.1, 0.6, across);
}

// Straight hatching at a fixed angle (rad, CCW in uv).
float hatchLinear(vec2 pix, float ang, float dens, float seed, float spacing) {
    vec2 t = vec2(cos(ang), sin(ang));
    return hatchStrokes(dot(pix, vec2(-t.y, t.x)), dot(pix, t), dens, seed, spacing);
}

// Fanned hatching: strokes radiate from HATCH_PIVOT, so they are steep (~120 deg)
// at the top-left corner and flatten (~150 deg) toward v = 0.5, like a brush
// swung from the upper left.
float hatchFan(vec2 p, float dens, float seed, float spacing) {
    vec2 d = p - HATCH_PIVOT;
    float r = length(d) * REF_RES;
    float th = atan(d.y, d.x);
    return hatchStrokes(th * 0.45 * REF_RES, r, dens, seed, spacing);
}

vec3 hatchLayer(vec3 dst, vec2 p, vec2 pix) {
    // "\" zone: left edge, upper half (strong at the edge, fading inward)
    float zb = sbox(p, vec2(-0.1, 0.47), vec2(0.17, 1.1), vec2(0.06, 0.05))
             + sbox(p, vec2(0.15, 0.55), vec2(0.30, 1.0), vec2(0.05)) * 0.2;
    // "/" zones: maroon part of the red band and the upper-right wedge
    float zf = sbox(p, vec2(0.55, 0.40), vec2(0.80, 0.62), vec2(0.03)) * 0.8;
    zf = max(zf, sbox(p, vec2(0.84, 0.62), vec2(1.05, 0.86), vec2(0.05)) * 0.9);
    // near-horizontal sweep in the dark bottom right
    float zh = sbox(p, vec2(0.62, 0.08), vec2(1.05, 0.30), vec2(0.06)) * 0.5;
    float h = 0.0;
    if (zb > 0.01) h += hatchFan(p, 0.85, 3.0, 2.0) * min(zb, 1.0);
    if (zf > 0.01) h += hatchLinear(pix, HATCH_FWD, 0.5, 9.0, 2.0) * zf;
    if (zh > 0.01) h += hatchLinear(pix, 3.0, 0.4, 17.0, 2.0) * zh;
    h *= HATCH_AMT;
    if (h == 0.0) return dst;
    // dark strokes go to red-black in warm areas and blue-black in cool ones
    vec3 dark = dst.r > dst.b ? hexColor(COL_OXBLOOD) : hexColor(COL_INK);
    return h < 0.0 ? mix(dst, dark * 0.6, -h) : shadeL(dst, 0.15 * h);
}

// ---- 6. accents -------------------------------------------------------------------
// Soot strip under the red band with horizontal grain, dark scratches on the
// hot/cold seam, sparse red specks in the dark strip.
vec3 accentLayer(vec3 dst, vec2 p, vec2 pix) {
    // soot strip: edges wander slowly, with a little per-column fray
    float top = 0.342 + (vnoise1(pix.x / 23.0) - 0.5) * 0.025 + (hash11(pix.x) - 0.5) * 0.006;
    float bot = 0.29 + (vnoise1(pix.x / 31.0 + 5.0) - 0.5) * 0.03 + (hash11(pix.x + 0.5) - 0.5) * 0.008;
    float zx = smoothstep(0.42, 0.50, p.x);
    if (p.y > bot && p.y < top && zx > 0.0) {
        float g = streaks(pix.y, pix.x, 23.0);
        vec3 soot = shadeL(hexColor(0x0c0709), (g - 0.5) * 0.12);
        dst = mix(dst, soot, 0.85 * zx);
    }
    // dark "/" wedge in the upper right: everything right of a diagonal through
    // (0.80, 0.60) and (1.0, 0.86) sinks into blue-black; the edge is frayed
    // along the stroke direction so it reads as a brushed boundary
    vec2 wn = vec2(0.79, -0.61);
    float wd = dot(p - vec2(0.80, 0.60), wn) + (vnoise1(dot(pix, vec2(0.61, 0.79)) / 9.0) - 0.5) * 0.03;
    float wz = smoothstep(-0.01, 0.03, wd) * smoothstep(0.46, 0.56, p.y) * (1.0 - smoothstep(0.88, 0.95, p.y));
    if (wz > 0.0) dst = mix(dst, shadeL(hexColor(0x03080f), (streaks(pix.x * 0.61 - pix.y * 0.79, 0.0, 41.0) - 0.5) * 0.1), wz * 0.8);

    // dark scratches between ice column and warm core
    float zs = sbox(p, vec2(0.425, 0.52), vec2(0.475, 0.74), vec2(0.01, 0.03));
    if (zs > 0.0) {
        // clusters of dark columns, each starting at its own height and fading down
        float c1 = floor(pix.x);
        float on = step(0.62, vnoise1(pix.x / 5.0 + 3.0)) * step(0.35, hash11(c1 * 4.1));
        float y0 = 0.5 + hash11(c1 * 5.3) * 0.22;
        float a  = on * smoothstep(y0, y0 + 0.06, p.y) * mix(0.5, 0.9, hash11(c1 * 7.7));
        dst = mix(dst, hexColor(0x0a1622), a * zs);
    }
    // red specks: clustered splatter of small, slightly horizontal flecks on a
    // 4 px grid in and around the soot strip
    float zp = sbox(p, vec2(0.45, 0.25), vec2(0.80, 0.40), vec2(0.03));
    if (zp > 0.0) {
        vec2 g = floor(pix / 4.0);
        vec3 h = hash33(vec3(g, 5.0));
        float cluster = smoothstep(0.55, 0.85, vnoise1(pix.x / 23.0) * vnoise1(pix.y / 9.0 + 4.0) * 1.6);
        if (h.z < 0.22 * zp * cluster) {
            vec2 o = (g + 0.2 + h.xy * 0.6) * 4.0;
            vec2 d = (pix - o) / vec2(mix(1.0, 3.0, h.x), 1.0);
            dst = mix(dst, hexColor(COL_CRIMSON) * mix(0.7, 1.4, h.y), 1.0 - smoothstep(0.5, 1.3, length(d)));
        }
    }
    return dst;
}

// ---- 7. grading ---------------------------------------------------------------------
vec3 grade(vec3 c) {
    vec3 lab = toLab(c);
    lab.x = clamp(0.5 + (lab.x - 0.5) * CONTRAST, 0.0, 1.0);
    return fromLab(lab);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 p   = fragCoord / iResolution.xy;   // uv, origin bottom left
    vec2 pix = p * REF_RES;                  // reference pixels

    vec3 c = baseLayer(p, pix);
    c = gridLayer(c, p, pix, vec2(0.16, 0.22), vec2(0.03, 0.05), 1.0, 0.55, 0.5);
    c = gridLayer(c, p, pix, vec2(0.11, 0.15), vec2(0.07, 0.02), 2.0, 0.6, 0.4);
    c = dripLayer(c, p, pix);
    c = heroLayer(c, p, pix);
    c = gridLayer(c, p, pix, vec2(0.05, 0.09), vec2(0.01, 0.04), 3.0, 0.45, 0.35);
    c = hatchLayer(c, p, pix);
    c = accentLayer(c, p, pix);
    c = grade(c);

    fragColor = vec4(linearToSrgb(c * EXPOSURE), 1.0);
}
