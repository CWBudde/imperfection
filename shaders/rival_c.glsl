// rival_c.glsl - "Stroke splatting": the painting rebuilt from brush strokes.
//
// A hand-authored base colour field (the warm/cool cross) and a direction field
// (zones) are sampled by several passes of explicit stroke primitives. Layer
// stack, back to front (see mainImage):
//
//   base       streaked underpainting (no holes left between strokes)
//   drips      long thin vertical strokes that carry their colour downward
//   smears     the same strokes turned horizontal, inside the horizontal zones
//   hatch      diagonal strokes in soft zones, fanned by the direction field
//   blocks     axis-aligned collage rectangles with hard edges and grain
//   hero       authored signature rectangles at the reference's strongest edges
//   hatch      a sparser second hatch pass crossing over the blocks
//   blocks     a finer collage grid
//   drips      fine drips and fine smears on top
//   scratches  dark ink drips along the hot/cold seams
//   accents    soot strip under the red band, red specks
//
// Every stroke pass works the same way: the plane is cut into (possibly rotated,
// elongated) cells, each cell scatters one stroke, and the 3x3 neighbourhood is
// searched for the frontmost stroke covering the pixel (random depth). Only that
// winner is shaded, so the base field is evaluated once per pass, not per cell.

#include "common.glsl"

// ---- tunables ---------------------------------------------------------------
const float SEAM_SOFT       = 0.018;             // warm/cool mask edge width (uv)
const float BLOCK_CELL_A    = 0.16;              // coarse collage grid (uv)
const float BLOCK_CELL_B    = 0.09;              // finer collage grid (uv)
const vec2  DRIP_CELL       = vec2(0.014, 0.20); // drip grid: across (x), along (y)
const vec2  DRIP_CELL_F     = vec2(0.008, 0.07); // fine drip grid
const vec2  SMEAR_CELL      = vec2(0.012, 0.22); // horizontal smears: across (y), along (x)
const vec2  SMEAR_CELL_F    = vec2(0.006, 0.12); // fine horizontal smears
const vec2  SCRATCH_CELL    = vec2(0.010, 0.12); // dark ink scratches at the seams
const vec2  HATCH_CELL      = vec2(0.075, 0.006); // hatch grid: along, across
const float BRISTLE_PX      = 1.3;               // average bristle width in pixels
const float DRIP_SAMPLE_JIT = 0.07;              // sideways jitter of a drip's colour sample (uv)
#ifndef WARM_HGRAIN
#define WARM_HGRAIN 0.3
#endif
#ifndef BASE_GRAIN
#define BASE_GRAIN 0.5
#endif
const float SOOT_V          = 0.315;             // centre line of the shadow strip

// ---- palette (sRGB hex, see docs/analysis.md section 2) ----------------------
// Named tones; the anchors below also use in-between hex values directly.
// warm family
const int C_SAFFRON = 0xf2a440;
const int C_ORANGE  = 0xec7a38;
const int C_VERMIL  = 0xd6502c;
const int C_CORAL   = 0xe0706a;
const int C_APRICOT = 0xdca07a;
// red family
const int C_MAROON  = 0x5e1420;
const int C_OXBLOOD = 0x2e0a12;
// cool family
const int C_ICE     = 0xc4e4f2;
const int C_INK     = 0x040b16;

// ---- small helpers ----------------------------------------------------------
// Box mask with soft edges: 1 inside [lo, hi], 0 outside.
float boxMask(vec2 p, vec2 lo, vec2 hi, float soft) {
    vec2 d = max(lo - p, p - hi);
    return 1.0 - smoothstep(-soft, soft, max(d.x, d.y));
}

// Gaussian anchor weight with anisotropic radius r.
float anchor(vec2 p, vec2 c, vec2 r) {
    vec2 d = (p - c) / r;
    return exp(-dot(d, d));
}

// ---- base colour field -------------------------------------------------------
// The cross: warm mask (upper-left mass + column + red band) over a cool field.
// Warm and cool colours are blended only inside their own family; the two
// families meet through the mask, whose seam is ragged so that strokes sampling
// near it pick one side or the other (no grey mud).
float warmMask(vec2 uv) {
    // ragged, vertically streaked seam
    float jag = (noise(vec2(uv.x * 38.0, uv.y * 2.5)) - 0.5) * 0.05;
    vec2 p = uv + vec2(jag, jag * 0.4);
    // upper-left mass; its right edge leans from u=0.37 (top) to 0.47 (v=0.5)
    float right = mix(0.47, 0.37, smoothstep(0.5, 1.0, p.y));
    float m = boxMask(p, vec2(-1.0, 0.49), vec2(right, 2.0), SEAM_SOFT);
    // the column dripping to the bottom edge
    float colR = mix(0.39, 0.43, smoothstep(0.08, 0.26, p.y));
    m = max(m, boxMask(p, vec2(mix(0.25, 0.22, smoothstep(0.2, 0.4, p.y)), -1.0), vec2(colR, 0.52), SEAM_SOFT));
    // horizontal red band to the right edge, thinning toward u = 1
    // stepped top edge: band root, crimson blocks, coral-pink block, low right part
    float top = mix(0.56, 0.535, step(0.60, p.x));
    top = mix(top, 0.46, step(0.79, p.x));
    float bot = mix(0.35, 0.385, smoothstep(0.70, 1.0, p.x));
    m = max(m, boxMask(p, vec2(0.44, bot), vec2(2.0, top), SEAM_SOFT));
    // left edge below the warm mass is cool
    m *= 1.0 - boxMask(p, vec2(-1.0, -1.0), vec2(0.18, 0.47), SEAM_SOFT);
    return m;
}

vec3 warmColor(vec2 uv) {
    vec3 acc = vec3(0.0);
    float wsum = 1e-4, w;
    // left edge: coral at the top fading into maroon and oxblood
    w = anchor(uv, vec2(0.05, 0.97), vec2(0.12, 0.10)); acc += w * hexColor(0xc8625e); wsum += w;
    w = anchor(uv, vec2(0.10, 0.95), vec2(0.04, 0.05)); acc += w * hexColor(0xe2786e); wsum += w;
    w = anchor(uv, vec2(0.16, 0.98), vec2(0.03, 0.03)); acc += w * hexColor(0xb08898); wsum += w;
    w = anchor(uv, vec2(0.17, 0.84), vec2(0.04, 0.05)); acc += w * hexColor(0xf4a24a); wsum += w;
    w = anchor(uv, vec2(0.22, 0.86), vec2(0.04, 0.10)); acc += w * hexColor(0xeca050); wsum += w;
    w = anchor(uv, vec2(0.04, 0.75), vec2(0.07, 0.07)); acc += w * hexColor(0x7a2228); wsum += w;
    w = anchor(uv, vec2(0.15, 0.78), vec2(0.05, 0.06)); acc += w * hexColor(0xd0603e); wsum += w;
    w = anchor(uv, vec2(0.06, 0.62), vec2(0.07, 0.05)); acc += w * hexColor(0x6e1e24); wsum += w;
    w = anchor(uv, vec2(0.04, 0.51), vec2(0.08, 0.04)); acc += w * hexColor(C_OXBLOOD); wsum += w;
    w = anchor(uv, vec2(0.17, 0.62), vec2(0.05, 0.07)); acc += w * hexColor(C_VERMIL); wsum += w;
    // orange ring and yellow core
    w = anchor(uv, vec2(0.25, 0.82), vec2(0.06, 0.08)); acc += w * hexColor(C_ORANGE); wsum += w;
    w = anchor(uv, vec2(0.25, 0.67), vec2(0.05, 0.06)); acc += w * hexColor(0xf47c3c); wsum += w;
    w = anchor(uv, vec2(0.30, 0.88), vec2(0.05, 0.06)); acc += w * hexColor(C_APRICOT); wsum += w;
    w = anchor(uv, vec2(0.35, 0.98), vec2(0.04, 0.04)); acc += w * hexColor(0x7c7890); wsum += w;
    w = anchor(uv, vec2(0.30, 0.97), vec2(0.04, 0.05)); acc += w * hexColor(0xa08494); wsum += w;
    w = anchor(uv, vec2(0.35, 0.69), vec2(0.07, 0.09)); acc += w * hexColor(0xffcc64); wsum += w;
    w = anchor(uv, vec2(0.38, 0.57), vec2(0.06, 0.05)); acc += w * hexColor(C_SAFFRON); wsum += w;
    w = anchor(uv, vec2(0.44, 0.52), vec2(0.04, 0.04)); acc += w * hexColor(0xd8862e); wsum += w;
    // column: orange-red at the band height, darker orange to the bottom
    w = anchor(uv, vec2(0.28, 0.48), vec2(0.07, 0.05)); acc += w * hexColor(0xdc5a20); wsum += w;
    w = anchor(uv, vec2(0.34, 0.39), vec2(0.06, 0.05)); acc += w * hexColor(0xc8481a); wsum += w;
    w = anchor(uv, vec2(0.30, 0.20), vec2(0.06, 0.10)); acc += w * hexColor(0xa85a2c); wsum += w;
    w = anchor(uv, vec2(0.38, 0.10), vec2(0.05, 0.10)); acc += w * hexColor(0x8a5230); wsum += w;
    // red band: crimson near the column, maroon / coral blocks, oxblood at the edge
    w = anchor(uv, vec2(0.52, 0.45), vec2(0.06, 0.06)); acc += w * hexColor(0xb0301a); wsum += w;
    w = anchor(uv, vec2(0.60, 0.48), vec2(0.05, 0.06)); acc += w * hexColor(C_MAROON); wsum += w;
    w = anchor(uv, vec2(0.73, 0.49), vec2(0.05, 0.05)); acc += w * hexColor(0x8a2c34); wsum += w;
    w = anchor(uv, vec2(0.65, 0.38), vec2(0.08, 0.04)); acc += w * hexColor(0x4a1018); wsum += w;
    w = anchor(uv, vec2(0.86, 0.43), vec2(0.07, 0.05)); acc += w * hexColor(0x64121c); wsum += w;
    w = anchor(uv, vec2(0.98, 0.44), vec2(0.04, 0.06)); acc += w * hexColor(0x2e0a12); wsum += w;
    return acc / wsum;
}

vec3 coolColor(vec2 uv) {
    vec3 acc = vec3(0.0);
    float wsum = 1e-4, w;
    // ice column and the blues to its right
    w = anchor(uv, vec2(0.47, 0.88), vec2(0.06, 0.12)); acc += w * hexColor(C_ICE);   wsum += w;
    w = anchor(uv, vec2(0.44, 0.70), vec2(0.04, 0.07)); acc += w * hexColor(0x7898a8); wsum += w;
    w = anchor(uv, vec2(0.56, 0.84), vec2(0.04, 0.10)); acc += w * hexColor(0x7aa2bc);   wsum += w;
    w = anchor(uv, vec2(0.62, 0.70), vec2(0.05, 0.08)); acc += w * hexColor(0x3a6280); wsum += w;
    w = anchor(uv, vec2(0.68, 0.92), vec2(0.05, 0.08)); acc += w * hexColor(0x4a6478); wsum += w;
    w = anchor(uv, vec2(0.75, 0.76), vec2(0.04, 0.08)); acc += w * hexColor(0x223648); wsum += w;
    w = anchor(uv, vec2(0.84, 0.94), vec2(0.04, 0.06)); acc += w * hexColor(0x12304a); wsum += w;
    w = anchor(uv, vec2(0.86, 0.78), vec2(0.05, 0.08)); acc += w * hexColor(0x081c30); wsum += w;
    w = anchor(uv, vec2(0.97, 0.78), vec2(0.05, 0.10)); acc += w * hexColor(0x0e2840);   wsum += w;
    w = anchor(uv, vec2(0.80, 0.58), vec2(0.16, 0.06)); acc += w * hexColor(0x020810); wsum += w;
    w = anchor(uv, vec2(0.98, 0.55), vec2(0.03, 0.04)); acc += w * hexColor(0x0a1a2c); wsum += w;
    w = anchor(uv, vec2(0.58, 0.60), vec2(0.04, 0.03)); acc += w * hexColor(0x283850); wsum += w;
    // below the band: ink fading into navy toward the bottom
    w = anchor(uv, vec2(0.62, 0.27), vec2(0.12, 0.05)); acc += w * hexColor(C_INK);   wsum += w;
    w = anchor(uv, vec2(0.90, 0.28), vec2(0.08, 0.05)); acc += w * hexColor(0x1c2c40); wsum += w;
    w = anchor(uv, vec2(0.62, 0.08), vec2(0.08, 0.08)); acc += w * hexColor(0x082848); wsum += w;
    w = anchor(uv, vec2(0.80, 0.14), vec2(0.06, 0.08)); acc += w * hexColor(0x03101e); wsum += w;
    w = anchor(uv, vec2(0.95, 0.12), vec2(0.05, 0.04)); acc += w * hexColor(0x030a14); wsum += w;
    w = anchor(uv, vec2(0.88, 0.01), vec2(0.10, 0.03)); acc += w * hexColor(0x0c2a44); wsum += w;
    // left: navy and slate blue blocks, grey-blue at the bottom
    w = anchor(uv, vec2(0.04, 0.38), vec2(0.07, 0.05)); acc += w * hexColor(0x081828); wsum += w;
    w = anchor(uv, vec2(0.12, 0.42), vec2(0.05, 0.04)); acc += w * hexColor(0x18324c); wsum += w;
    w = anchor(uv, vec2(0.05, 0.22), vec2(0.06, 0.08)); acc += w * hexColor(0x22405a); wsum += w;
    w = anchor(uv, vec2(0.09, 0.08), vec2(0.03, 0.10)); acc += w * hexColor(0x6c7e8c); wsum += w;
    w = anchor(uv, vec2(0.17, 0.25), vec2(0.04, 0.08)); acc += w * hexColor(0x10202e); wsum += w;
    w = anchor(uv, vec2(0.46, 0.14), vec2(0.04, 0.14)); acc += w * hexColor(0x1a1214); wsum += w;
    return acc / wsum;
}

vec3 baseField(vec2 uv) {
    // the mask is 0 or 1 almost everywhere: only evaluate the family needed
    float m = warmMask(uv);
    if (m < 0.002) return coolColor(uv);
    if (m > 0.998) return warmColor(uv);
    return mix(coolColor(uv), warmColor(uv), m);
}

// ---- direction field ----------------------------------------------------------
// Vertical is the default everywhere. These zones override it (weights 0..1):
//   left edge (upper half)   "\" hatching, fanning from ~60 deg below horizontal
//                            at the top to ~30 deg lower down
//   red band (coral part)    "/" hatching, ~52 deg
//   upper-right wedge        "/" hatching, ~55 deg
//   horizontal smears        right half of the band, shadow strip, slate blocks
//                            on the left, bottom-right corner
float zoneLeft(vec2 uv)  { return boxMask(uv, vec2(-1.0, 0.50), vec2(mix(0.17, 0.25, smoothstep(0.55, 0.65, uv.y)), 1.1), 0.05); }
float zoneBand(vec2 uv)  { return boxMask(uv, vec2(0.58, 0.42), vec2(0.78, 0.56), 0.03); }
float zoneWedge(vec2 uv) { return boxMask(uv, vec2(0.87, 0.62), vec2(1.1, 0.88), 0.04); }
float zoneHoriz(vec2 uv) {
    float z = boxMask(uv, vec2(0.76, 0.26), vec2(1.1, 0.58), 0.03);   // band right + strip
    z = max(z, boxMask(uv, vec2(0.47, 0.28), vec2(0.78, 0.41), 0.03)); // strip centre
    z = max(z, boxMask(uv, vec2(-1.0, 0.33), vec2(0.22, 0.48), 0.02)); // slate blocks
    z = max(z, boxMask(uv, vec2(0.76, 0.14), vec2(1.1, 0.30), 0.03));  // bottom right
    z = max(z, boxMask(uv, vec2(0.88, 0.04), vec2(1.1, 0.14), 0.03));
    z = max(z, boxMask(uv, vec2(0.93, 0.48), vec2(1.1, 0.70), 0.03));  // right edge
    return z;
}

// ---- stroke machinery -----------------------------------------------------------
// Winner of a stroke search: alpha, local coordinates (s along in [-0.5, 0.5],
// t across in [-0.5, 0.5]), stroke hash and stroke centre in uv.
struct Hit {
    float a;
    vec2  st;
    vec3  h;
    vec2  c;
};

// Bristle texture inside a stroke: 1D hash across the width, correlated along
// the length, with ragged ends and dry-brush gaps. Returns (coverage, value).
vec2 bristles(vec2 st, float widthPx, float seed, float dry, float gapFreq) {
    float nb = max(widthPx / BRISTLE_PX, 1.0);
    float bi = floor((st.y + 0.5) * nb);
    float bh = hash12(vec2(bi, seed));
    float bh2 = hash12(vec2(bi + 17.0, seed));
    // ragged ends: every bristle starts and stops at its own place
    float cov = step(-0.5 + 0.18 * bh, st.x) * step(st.x, 0.5 - 0.25 * bh2);
    // dry-brush gaps along the bristle
    float g = noise(vec2(st.x * gapFreq + bh * 31.0, bi * 1.7 + seed));
    cov *= step(dry, g + 0.35 * bh);
    return vec2(cov, 0.45 + 0.85 * bh * bh2 + 0.2 * bh);
}

// Blend a shaded stroke over the canvas.
vec3 over(vec3 dst, vec3 src, float a) { return mix(dst, src, clamp(a, 0.0, 1.0)); }

// ---- layer 0: underpainting ---------------------------------------------------
// The base field, dragged down per pixel column so even the background reads
// as vertical streaks instead of a smooth poster gradient.
vec3 layerBase(vec2 uv, vec2 px) {
    float col = floor(px.x / 2.0);
    float drag = hash11(col * 1.37) * 0.035;
    vec3 c = baseField(uv + vec2(0.0, drag));
    float streak = noise(vec2(col * 0.9, uv.y * 3.0 + hash11(col) * 7.0));
    // short dry-brush grain so the streaks break up along their length
    streak = mix(streak, noise(vec2(col * 0.9, uv.y * 60.0)), BASE_GRAIN);
    // dark passages get more streak contrast (light blue threads on ink)
    float k = 1.0 - smoothstep(0.0, 0.08, dot(c, vec3(0.2126, 0.7152, 0.0722)));
    return c * mix(0.75 + 0.48 * streak, 0.45 + 1.2 * streak, k);
}

// ---- layer 1: collage blocks ------------------------------------------------
// Probability that a block grid cell holds a rectangle: dense in the warm
// column and along the red band, sparse in the cool areas.
float blockDensity(vec2 uv) {
    float d = 0.2;
    d += 0.6 * boxMask(uv, vec2(0.15, 0.25), vec2(0.50, 0.85), 0.08);
    d += 0.45 * boxMask(uv, vec2(0.48, 0.32), vec2(1.00, 0.60), 0.05);
    return d;
}

Hit searchBlocks(vec2 uv, float cell, float seed) {
    Hit hit = Hit(0.0, vec2(0.0), vec3(0.0), vec2(0.0));
    float best = -1.0;
    vec2 gi = floor(uv / cell);
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 c = gi + vec2(i, j);
        vec3 h = hash33(vec3(c, seed));
        vec3 h2 = hash33(vec3(c + 7.3, seed + 3.1));
        vec2 ctr = (c + 0.5 + (h.xy - 0.5) * 0.7) * cell;
        if (h2.z > blockDensity(ctr)) continue;
        // often taller than wide
        vec2 size = cell * vec2(mix(0.35, 1.0, h2.x), mix(0.45, 1.5, h2.y));
        vec2 d = abs(uv - ctr) - 0.5 * size;
        if (max(d.x, d.y) < 0.0 && h.z > best) {
            best = h.z;
            hit = Hit(1.0, (uv - ctr) / size, h2, ctr);
        }
    }
    return hit;
}

vec3 layerBlocks(vec3 col, vec2 uv, vec2 px, float cell, float seed) {
    Hit b = searchBlocks(uv, cell, seed);
    if (b.a <= 0.0) return col;
    vec3 c = baseField(b.c + (b.h.xy - 0.5) * 0.03);
    // horizontal grain mostly where the direction field is horizontal
    // (and in some warm-column blocks, like the yellow-orange slab at v ~ 0.53)
    float hp = 0.03 + 0.85 * zoneHoriz(b.c) + WARM_HGRAIN * boxMask(b.c, vec2(0.22, 0.3), vec2(0.45, 0.7), 0.05);
    bool horiz = fract(b.h.z * 7.13) < hp;
    float lineId = horiz ? floor(px.y / (1.0 + 2.0 * b.h.x)) : floor(px.x / (1.0 + 2.0 * b.h.y));
    float along = horiz ? uv.x : uv.y;
    float g = hash12(vec2(lineId, b.h.z * 91.0));
    g = mix(g, noise(vec2(along * 25.0, lineId * 0.37)), 0.35);
    c *= 0.5 + 1.0 * g;
    float alpha = mix(0.55, 1.0, fract(b.h.x * 13.7));
    return over(col, c, alpha);
}

// Authored "hero" blocks: the signature rectangles of the collage, placed
// where the reference has its strongest straight edges. xy = lower-left,
// zw = upper-right (uv); colour (sRGB hex); horizontal grain flag; alpha.
const int HERO_N = 13;
const vec4 HERO_BOX[HERO_N] = vec4[HERO_N](
    vec4(0.080, 0.575, 0.205, 0.722),   // coral block, left
    vec4(0.670, 0.456, 0.790, 0.531),   // coral-pink block in the band
    vec4(0.770, 0.403, 0.948, 0.456),   // crimson rectangle, band right
    vec4(0.408, 0.525, 0.506, 0.565),   // yellow-orange horizontal block
    vec4(0.100, 0.354, 0.205, 0.428),   // slate blue block
    vec4(0.020, 0.342, 0.125, 0.452),   // navy block, left edge
    vec4(0.450, 0.433, 0.527, 0.522),   // red-orange block at the band root
    vec4(0.552, 0.540, 0.600, 0.600),   // crimson tall block
    vec4(0.672, 0.720, 0.795, 0.940),   // dark bar, upper right
    vec4(0.810, 0.750, 0.966, 0.906),   // navy block, upper right
    vec4(0.300, 0.140, 0.383, 0.223),   // orange block in the column
    vec4(0.338, 0.230, 0.378, 0.500),   // vermilion strip in the column
    vec4(0.640, 0.570, 0.715, 0.625));  // dark block with red scratches
const int HERO_COL[HERO_N] = int[HERO_N](
    0xd8704a, 0x983a44, 0x7e1620, 0xd09040, 0x2a5068, 0x173248,
    0xb03a18, 0xa81c24, 0x46586a, 0x1a3c58, 0xa0502a, 0xc8381e, 0x5a2030);
const float HERO_HORIZ[HERO_N] = float[HERO_N](0., 0., 1., 1., 1., 1., 0., 0., 0., 1., 0., 0., 0.);

vec3 layerHeroBlocks(vec3 col, vec2 uv, vec2 px) {
    for (int k = 0; k < HERO_N; k++) {
        vec4 b = HERO_BOX[k];
        vec2 d = max(b.xy - uv, uv - b.zw);   // hard edges, like the collage
        if (max(d.x, d.y) > 0.0) continue;
        bool horiz = HERO_HORIZ[k] > 0.5;
        float fk = float(k);
        float lineId = horiz ? floor(px.y / 1.5) : floor(px.x / 1.5);
        float along = horiz ? uv.x : uv.y;
        float g = hash12(vec2(lineId, fk * 13.0));
        g = mix(g, noise(vec2(along * 30.0, lineId * 0.41 + fk)), 0.4);
        vec3 c = hexColor(HERO_COL[k]) * (0.5 + g);
        col = over(col, c, 0.9);
    }
    return col;
}

// ---- layer 2: vertical drips --------------------------------------------------
// Each cell drops a drip: top somewhere in the cell, length up to ~2 cells,
// tapered and ragged at the lower end. Colour is sampled near the top and
// carried down, which gives the pixel-sort smear.
float dripDensity(vec2 uv) {
    float d = 0.85;
    d -= 0.7 * zoneLeft(uv);
    d -= 0.75 * zoneBand(uv);
    d -= 0.4 * zoneWedge(uv);
    d -= 0.7 * zoneHoriz(uv);
    return d;
}

// q is in stroke space: q.y runs along the stroke (uv.yx for horizontal smears).
// density is the probability that a stroke is kept, evaluated once at the pixel
// (the zones are soft, so cutting strokes there is invisible).
Hit searchDrips(vec2 q, vec2 cell, float seed, float density) {
    vec2 uv = q;
    Hit hit = Hit(0.0, vec2(0.0), vec3(0.0), vec2(0.0));
    float best = -1.0;
    vec2 gi = floor(uv / cell);
    for (int j = 0; j <= 2; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 c = gi + vec2(i, j);
        vec3 h = hash33(vec3(c, seed));
        vec3 h2 = hash33(vec3(c + 3.7, seed + 9.2));
        float x0 = (c.x + 0.5 + (h.x - 0.5) * 0.8) * cell.x;
        float top = (c.y + h.y) * cell.y;
        float len = mix(0.5, 2.0, h2.x) * cell.y;
        float wid = mix(0.25, 1.0, h2.y) * cell.x;
        float s = (top - uv.y) / len;           // 0 at the top, 1 at the bottom
        if (s < 0.0 || s > 1.0) continue;
        // taper toward the lower end
        float w = wid * mix(1.0, 0.7, smoothstep(0.6, 1.0, s));
        float t = (uv.x - x0) / w;
        if (abs(t) < 0.5 && h.z > best) {
            if (h2.z > density) continue;
            vec2 top2 = vec2(x0, top - 0.15 * len);
            best = h.z;
            hit = Hit(1.0, vec2(0.5 - s, t), h2, top2);
        }
    }
    return hit;
}

vec3 layerDrips(vec3 col, vec2 uv, vec2 px, vec2 cell, float seed, float opacity, bool horiz) {
    // horizontal smears are the same strokes with the axes swapped
    float density = horiz ? 0.95 * zoneHoriz(uv) : dripDensity(uv);
    if (density < 0.01) return col;
    Hit d = searchDrips(horiz ? uv.yx : uv, cell, seed, density);
    if (d.a <= 0.0) return col;
    float widthPx = cell.x * mix(0.25, 1.0, d.h.y) * iResolution.x;
    vec2 br = bristles(d.st, widthPx, d.h.z * 57.0, 0.42, 30.0);
    // the colour sample is jittered across the grain: near a warm/cool seam,
    // neighbouring drips land on different sides and interleave as streaks
    vec2 sp = d.c + vec2((fract(d.h.z * 3.7) - 0.5) * DRIP_SAMPLE_JIT, 0.0);
    vec3 c = baseField(horiz ? sp.yx : sp);
    float k = 1.0 - smoothstep(0.0, 0.08, dot(c, vec3(0.2126, 0.7152, 0.0722)));
    c *= br.y * mix(0.75, 1.3, fract(d.h.x * 11.0)) * (1.0 + k * (fract(d.h.y * 7.0) * 1.2 - 0.3));
    return over(col, c, br.x * opacity * mix(0.6, 1.0, d.h.z));
}

// ---- layer 3: diagonal hatching -----------------------------------------------
// The grid is rotated into the hatch direction (cells long along the stroke,
// narrow across it). The rotation angle drifts slowly with position, so the
// strokes fan out like a brush swung from the upper left.
Hit searchHatch(vec2 uv, float ang, vec2 pivot, float seed) {
    Hit hit = Hit(0.0, vec2(0.0), vec3(0.0), vec2(0.0));
    float best = -1.0;
    mat2 toLocal = rot(-ang);           // rot(a) * v rotates v by +a
    vec2 q = toLocal * (uv - pivot);
    vec2 gi = floor(q / HATCH_CELL);
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 c = gi + vec2(i, j);
        vec3 h = hash33(vec3(c, seed));
        vec2 ctr = (c + 0.5 + (h.xy - 0.5) * vec2(0.8, 0.6)) * HATCH_CELL;
        float len = mix(0.9, 1.9, h.z) * HATCH_CELL.x;
        float wid = mix(0.5, 1.3, fract(h.x * 7.7)) * HATCH_CELL.y;
        // per-stroke wobble of the angle
        vec2 d = rot((h.y - 0.5) * 0.18) * (q - ctr);
        float s = d.x / len;
        float w = wid * (1.0 - 0.45 * smoothstep(0.3, 0.5, abs(s)));  // tapered ends
        float t = d.y / w;
        float depth = fract(h.z * 31.7);
        if (abs(s) < 0.5 && abs(t) < 0.5 && depth > best) {
            best = depth;
            hit = Hit(1.0, vec2(s, t), h, pivot + transpose(toLocal) * ctr);
        }
    }
    return hit;
}

// One hatch family: angle, pivot of the fan, fan strength, share of dark strokes.
vec3 hatchFamily(vec3 col, vec2 uv, float zone, float ang, vec2 pivot, float darkShare, float seed, float opacity) {
    if (zone < 0.02) return col;
    // fan: the angle bends with the distance from the pivot
    float a = ang + 0.1 * (length(uv - pivot) - 0.1);
    Hit h = searchHatch(uv, a, pivot, seed);
    if (h.a <= 0.0) return col;
    float widthPx = HATCH_CELL.y * iResolution.x;
    vec2 br = bristles(h.st, widthPx, h.h.z * 43.0, 0.3, 9.0);
    vec3 c = baseField(h.c);
    bool dark = fract(h.h.y * 23.1) < darkShare;
    // darks are family-tinted: red-black in warm parts, blue-black in cool parts
    c = dark ? c * c * 0.5 + vec3(0.002, 0.001, 0.003) : c * (0.95 + 0.4 * fract(h.h.z * 5.3));
    return over(col, c * br.y, br.x * smoothstep(0.0, 0.7, zone) * opacity);
}

// pass 0 is the dense hatching under the blocks, pass 1 a sparser layer that
// crosses over them.
vec3 layerHatch(vec3 col, vec2 uv, float pass) {
    float op = pass < 0.5 ? 0.95 : 0.6;
    float sd = pass * 101.0;
    float leftAng = mix(-0.40, -1.00, smoothstep(0.50, 0.95, uv.y));
    float sweep = boxMask(uv, vec2(-1.0, 0.5), vec2(0.13, 0.62), 0.05);
    col = hatchFamily(col, uv, zoneLeft(uv),  leftAng, vec2(0.10, 0.75), 0.2 + 0.5 * sweep, 11.0 + sd, op);
    col = hatchFamily(col, uv, zoneBand(uv),  0.91,    vec2(0.68, 0.49), 0.72, 23.0 + sd, op);
    col = hatchFamily(col, uv, zoneWedge(uv), 0.95,    vec2(0.95, 0.75), 0.80, 37.0 + sd, op);
    return col;
}

// ---- layer 4: dark accents ------------------------------------------------------
// Where dark ink scratches gather: the hot/cold seam between the yellow core
// and the ice column, the ice column's right flank, and under the red band.
float zoneSeam(vec2 uv) {
    float z = boxMask(uv, vec2(0.40, 0.50), vec2(0.47, 0.80), 0.02);
    z = max(z, boxMask(uv, vec2(0.55, 0.55), vec2(0.66, 0.80), 0.03));
    z = max(z, boxMask(uv, vec2(0.45, 0.12), vec2(0.62, 0.34), 0.03));
    return z;
}

// Thin dark drips: same stroke search as the drips, but painted in ink.
vec3 layerScratches(vec3 col, vec2 uv, vec2 px) {
    float z = zoneSeam(uv);
    if (z < 0.01) return col;
    Hit d = searchDrips(uv, SCRATCH_CELL, 13.0, 0.6 * z);
    if (d.a <= 0.0) return col;
    vec2 br = bristles(d.st, 4.0, d.h.z * 29.0, 0.45, 12.0);
    // ink is tinted by what lies beneath: blue-black or red-black
    vec3 ink = col * col * 0.6 + hexColor(0x03060c) * 0.5;
    return over(col, ink, br.x * 0.85);
}

// Soot strip under the red band: horizontal dark grain, plus sparse red specks.
vec3 layerAccents(vec3 col, vec2 uv, vec2 px) {
    float strip = boxMask(uv, vec2(0.44, SOOT_V - 0.04), vec2(0.88, SOOT_V + 0.035), 0.04);
    if (strip > 0.0) {
        float row = floor(px.y / 1.5);
        float g = noise(vec2(uv.x * 14.0 + hash11(row) * 50.0, row * 0.3));
        float soot = strip * smoothstep(0.35, 0.7, g);
        col = mix(col, hexColor(0x04060b), soot * 0.9 + strip * 0.1);
        // red specks: sparse dots
        vec2 cellp = floor(px / 9.0);
        vec3 sp = hash33(vec3(cellp, 3.0));
        float r = length(px - (cellp + 0.2 + 0.6 * sp.xy) * 9.0);
        if (sp.z > 0.86) col = mix(col, hexColor(0xb81e2a), strip * (1.0 - smoothstep(0.6, 1.6, r)));
    }
    return col;
}

// ---- layer 5: grade --------------------------------------------------------------
// Hue-split gain (warm passages a touch hotter, cool ones a touch deeper), then
// the darks sink toward ink while lights stay put, so the cool half gets the
// reference's near-black instead of a lifted navy.
#ifndef GRADE_WARM
#define GRADE_WARM 1.1
#endif
#ifndef GRADE_COOL
#define GRADE_COOL 0.85
#endif
#ifndef GRADE_DARK
#define GRADE_DARK 0.5
#endif
#ifndef GRADE_KNEE
#define GRADE_KNEE 0.04
#endif
vec3 layerGrade(vec3 col) {
    float warm = smoothstep(-0.02, 0.02, col.r - col.b);
    col *= mix(GRADE_COOL, GRADE_WARM, warm);
    float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
    return col * mix(GRADE_DARK, 1.0, smoothstep(0.0, GRADE_KNEE, l));
}

// ---- compositing -----------------------------------------------------------------
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 px = fragCoord;

    vec3 col = layerBase(uv, px);
    col = layerDrips(col, uv, px, DRIP_CELL, 5.0, 0.9, false);
    col = layerDrips(col, uv, px, SMEAR_CELL, 6.0, 0.9, true);
    col = layerHatch(col, uv, 0.0);
    col = layerBlocks(col, uv, px, BLOCK_CELL_A, 1.0);
    col = layerHeroBlocks(col, uv, px);
    col = layerHatch(col, uv, 1.0);
    col = layerBlocks(col, uv, px, BLOCK_CELL_B, 2.0);
    col = layerDrips(col, uv, px, DRIP_CELL_F, 7.0, 0.55, false);
    col = layerDrips(col, uv, px, SMEAR_CELL_F, 8.0, 0.6, true);
    col = layerScratches(col, uv, px);
    col = layerAccents(col, uv, px);
    col = layerGrade(col);

    fragColor = vec4(linearToSrgb(col), 1.0);
}
