// rival_b.glsl - "Imperfection" as a smear field.
//
// Approach B: procedural pixel sort / line-integral smear. There is exactly one
// colour source, the hand-authored base field (rival_b_field.glsl). All
// structure - blocks, drips, hatching, grain - comes from DISTORTING THE LOOKUP
// into that field: each pixel asks "where did my paint come from?" and reads
// the field there. Because every pixel reads the same coherent field, colours
// stay consistent, and warm/cool transitions turn into interleaved streaks
// instead of mud.
//
// Layer stack, back to front:
//   L0 baseField    colour map following the cross composition (helper file)
//   L1 layerSmear   background: lookup dragged along a zoned direction field
//                   (vertical drips, "\" and "/" hatching, horizontal grain)
//   L2 layerBlocks  rectangles: lookup snapped to a single field point per
//                   block, with their own grain (four jittered grids, then the
//                   field's authored rectangles redrawn crisp on top)
//   L3 layerSoot    the shadow strip under the red band
//   L4 layerSpecks  red specks in the shadow strip
//
// iTime = 0 is the judged still; over time the drips creep slowly (DRIP_SPEED).
// Debug: -D SHOW_FIELD=1 renders L0 alone, -D NO_BLOCKS=1 skips L2.

#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif

#include "common.glsl"
#include "rival_b_field.glsl"

// ---- tunables ---------------------------------------------------------------
// All lengths are in reference pixels (the reference is 1024 px wide), so the
// image keeps its look at other render sizes.
const float REF_SIZE    = 1024.0;
const float SRC_FRAC    = 0.72;   // where in a smear segment the paint is picked (0 tail, 1 head)
const float DRAG_MIN    = 0.55;   // minimum drag strength per segment (1 = flat hold)
const float TEX_GAIN    = 0.8;    // global strength of all streak brightness variation
const float LUM_SPREAD  = 0.10;   // per-streak brightness variation
const float DARK_LUM    = 0.75;   // brightness factor of a dark scratch (perceptual, cubed later)
const float DARK_LINES  = 0.04;   // fraction of streak segments that are dark scratches
const float GRIT        = 1.6;    // bristle grit along a streak, relative to the strand variation
const float LINE_GRAIN  = 1.2;    // hairline flicker relative to the strand variation
const float THREAD_SPREAD = 22.0; // hairlines read the field up to this far across the grain (px)
const float DRIP_SPEED  = 4.0;    // animation: px per second the drips creep (0 = static)
const float TAPER       = 0.22;   // length of a drip's pointed tip (fraction of the segment)
const float RAGGED      = 0.25;   // per-line phase jitter inside a strand (ragged drip ends)

const float ANG_V       = 1.5707963; // vertical drips, paint carried downward
const float ANG_H       = 0.0;       // horizontal grain
const float ANG_FWD     = 0.85;      // "/" hatching (rises to the right), ~49 deg
// "\" hatching fans from ~150 deg near the band to ~118 deg at the top edge
const vec2  ANG_BACK    = vec2(2.62, 2.06);

const float SOOT_V0     = 0.275;  // shadow strip under the red band (v range)
const float SOOT_V1     = 0.345;
const float SPECK_DENS  = 0.035;  // probability of a red speck per speck cell

// ---- small helpers ----------------------------------------------------------
// Soft box mask: 1 inside [a, b], fading over `soft`.
float box(vec2 p, vec2 a, vec2 b, float soft) {
    vec2 s = smoothstep(a - soft, a + soft, p) * (1.0 - smoothstep(b - soft, b + soft, p));
    return s.x * s.y;
}

// Apply a streak brightness factor. Warm paint does not turn brown when it
// gets darker: green and blue fall faster, so yellow darkens through orange
// toward red and brightens toward cream. Cool paint is scaled as is.
vec3 shade(vec3 c, float lum) {
    float warm = smoothstep(0.0, 0.15, c.r - c.b);
    vec3 e = mix(vec3(1.0), vec3(0.75, 1.3, 1.7), warm);
    return c * pow(vec3(lum), e);
}

// ---- the smear operator -----------------------------------------------------
// Pixel P (reference px) is smeared along angle ang. The pixel belongs to a
// thin line (1-3 px wide) running along the smear axis; that line is cut into
// segments of hashed length. Each segment holds the paint picked at one point
// of the field (SRC_FRAC along the segment), mixed with a compressed copy of
// what is under the pixel (drag strength k). This is the 1D version of a pixel
// sort: long runs of one colour with ragged, independent ends per line.
struct Smear {
    vec2 q;     // field lookup point (reference px)
    float lum;  // brightness multiplier of this streak
};

Smear smearLookup(vec2 P, float ang, vec2 len, float spread, float dark, float seed) {
    vec2 d = vec2(cos(ang), sin(ang));
    vec2 n = vec2(-d.y, d.x);
    float s = dot(P, d);
    float t = dot(P, n);

    // strands: bundles of 6-36 px (one "bristle brush" each) share the
    // segment length and phase, so neighbouring lines carry the same paint
    float W = mix(6.0, 36.0, hash11(floor(t / 48.0) * 1.31 + seed));
    float strand = floor(t / W) + floor(t / 48.0) * 97.0;
    vec2 hb = hash22(vec2(strand, seed * 7.0 + 1.3));

    // lines inside a strand: 1-3 px wide, each with a slightly shifted phase,
    // which makes the strand's ends ragged
    float lw = 1.0 + floor(hash11(strand * 3.17 + seed) * 3.0);
    float line = floor(t / lw);
    vec2 hl = hash22(vec2(line, seed * 3.0 + 7.7));

    float L = mix(len.x, len.y, hb.x * hb.x);
    // calm zones (low spread) also get tidier strands
    float rough = clamp(spread / LUM_SPREAD, 0.25, 1.5);
    // animation: segment boundaries creep slowly downstream (t = 0 is the judged frame)
    float o = (hb.y + RAGGED * rough * (hl.x - 0.5)) * L + iTime * DRIP_SPEED * (0.5 + hb.x);
    float sid = floor((s + o) / L);
    float s0 = sid * L - o;

    // tapered tips: near the downstream end of a segment the strand's outer
    // lines are already cut, they still show the segment before it, so each
    // drip ends in a point instead of a flat edge
    float e = abs(fract(t / W) * 2.0 - 1.0);
    if (s - s0 < TAPER * L * (e + 0.4 * (hl.y - 0.5))) {
        sid -= 1.0;
        s0 -= L;
    }

    float hseg = hash12(vec2(strand * 1.37 + seed, sid));
    float k = mix(DRAG_MIN, 1.0, hseg);
    float sq = mix(s, s0 + L * SRC_FRAC, k);

    spread *= TEX_GAIN;

    // brightness: hairlines with their own, shorter segments (many starts
    // and ends = the fine streak texture), on top of a per-strand level and
    // broad bands across the grain
    float Ll = mix(8.0, 90.0, hl.x * hl.x);
    float lid = floor((s + hl.y * Ll) / Ll);
    float hline = hash12(vec2(line * 0.73 + seed, lid));
    float band = noise(vec2(t / 18.0, s / 600.0 + seed)) - 0.5;
    // bristle grit: 1 px wide, 2-6 px long dashes along the line, breaks up the barcode
    float grit = hash12(vec2(floor(t) * 2.1 + seed, floor(s / mix(2.0, 6.0, hl.x)))) - 0.5;
    float lum = 1.0 + spread * (0.9 * (hseg - 0.5) + 0.8 * band + LINE_GRAIN * (hline - 0.5)
                                + GRIT * rough * grit);
    // dark scratches run the length of a strand segment (long drips)
    lum *= hash12(vec2(line + 0.5, sid + seed)) < dark * rough ? DARK_LUM : 1.0;
    // in hatching zones (dark > 0.08) whole strands can be dark brush strokes
    lum *= fract(hseg * 7.31) < (dark - 0.08) * 3.0 ? 0.6 : 1.0;
    // lum is a factor on perceptual lightness (~ cube root of linear), so a
    // streak reads equally strong on navy and on yellow
    lum = max(lum, 0.2);
    lum = lum * lum * lum;

    // each hairline also reads the field slightly beside its strand, so at
    // a colour boundary threads of both colours interleave
    t += (hl.y - 0.5) * THREAD_SPREAD * rough;

    Smear r;
    r.q = d * sq + n * t;
    r.lum = lum;
    return r;
}

// ---- direction field --------------------------------------------------------
// Soft-edged zones select the smear axis. Returns the angle, the segment
// length range and the streak contrast for this pixel. A stretched noise
// dithers the zone borders, so hatching fields end in ragged, soft outlines.
void directionField(vec2 uv, out float ang, out vec2 len, out float spread, out float dark) {
    float nz = fbm(uv * vec2(9.0, 7.0) + 3.1, 3);

    // "\" hatching: left edge, upper half
    float back = box(uv, vec2(-0.1, 0.48), vec2(0.21, 1.1), 0.06);
    back = max(back, 0.85 * box(uv, vec2(0.05, 0.52), vec2(0.30, 0.76), 0.04));
    // "/" hatching: dark wedge upper right and the maroon part of the band
    float fwd = box(uv, vec2(0.84, 0.60), vec2(1.1, 0.88), 0.05);
    fwd = max(fwd, box(uv, vec2(0.60, 0.43), vec2(0.72, 0.56), 0.02));
    fwd = max(fwd, 0.8 * box(uv, vec2(0.72, 0.50), vec2(0.86, 0.62), 0.03));
    // horizontal grain: red band right, shadow strip, slate blocks left,
    // bottom right corner
    float hor = box(uv, vec2(0.74, 0.30), vec2(1.1, 0.60), 0.03);
    hor = max(hor, box(uv, vec2(0.48, 0.24), vec2(1.1, 0.40), 0.02));
    hor = max(hor, box(uv, vec2(-0.1, 0.36), vec2(0.21, 0.46), 0.01));
    hor = max(hor, 0.8 * box(uv, vec2(0.80, 0.11), vec2(1.1, 0.28), 0.03));

    // horizontal drag from the LEFT: the column's orange is pulled into the
    // lower part of the band
    float horL = box(uv, vec2(0.47, 0.355), vec2(0.72, 0.425), 0.015);
    hor = max(hor, horL);

    ang = ANG_V;
    len = vec2(60.0, 380.0);
    spread = LUM_SPREAD;
    // cool upper half: long drips with strong column-to-column brightness
    float coolTop = box(uv, vec2(0.40, 0.58), vec2(1.1, 1.1), 0.05);
    len = mix(len, vec2(120.0, 460.0), coolTop);
    spread = mix(spread, 0.13, coolTop);
    dark = mix(DARK_LINES, 0.10, coolTop);

    // hatching angles are constant per brush patch (a brick grid of ~70 px
    // cells); varying them per pixel would bend the lines into arcs
    vec2 pg = uv * vec2(12.0, 9.0);
    pg.x += hash11(floor(pg.y) + 3.0);
    vec2 pc = floor(pg);
    float pj = hash12(pc + 9.0) - 0.5;
    vec2 pcUV = (pc + 0.5) / vec2(12.0, 9.0);

    // texture gain: the reference is calm inside the warm column and
    // grainier in the dark right half and the top-left hatching
    float gain = 1.0 - 0.65 * box(uv, vec2(0.12, 0.55), vec2(0.60, 1.1), 0.05);
    gain += 0.6 * box(uv, vec2(0.72, -0.1), vec2(1.1, 1.1), 0.06);
    gain += 0.6 * box(uv, vec2(0.50, -0.1), vec2(1.1, 0.25), 0.05);
    spread *= gain;

    if (hor > nz) {
        // paint is dragged in from the outer edges (left zone from the left)
        ang = (uv.x < 0.3 || horL > nz) ? ANG_H + PI : ANG_H;
        len = horL > nz ? vec2(150.0, 420.0) : vec2(40.0, 260.0);
        spread = 0.10 * gain;
    }
    if (back > nz) {
        // fans out like a brush swung from the upper left
        ang = mix(ANG_BACK.x, ANG_BACK.y, smoothstep(0.55, 0.95, pcUV.y)) + 0.18 * pj;
        len = vec2(40.0, 260.0);
        spread = 0.06 + 0.25 * (1.0 - smoothstep(0.04, 0.17, uv.x));
        dark = 0.08 + 0.05 * (1.0 - smoothstep(0.06, 0.16, uv.x));
    }
    if (fwd > nz) {
        ang = ANG_FWD + 0.18 * pj;
        len = vec2(20.0, 140.0);
        spread = 0.25;
    }
}

// ---- L1: background smear ---------------------------------------------------
vec4 layerSmear(vec2 uv, vec2 P) {
    float ang, spread, dark;
    vec2 len;
    directionField(uv, ang, len, spread, dark);
    Smear sm = smearLookup(P, ang, len, spread, dark, 1.0);
    vec4 f = baseField(sm.q / REF_SIZE);
    f.rgb = shade(f.rgb, sm.lum);
    return f;
}

// ---- L2: blocks -------------------------------------------------------------
// Where blocks are likely: warm column, red band, steel bars upper right,
// slate blocks left.
float blockDensity(vec2 uv) {
    float d = 0.10;
    d = max(d, 0.45 * box(uv, vec2(0.20, 0.28), vec2(0.50, 0.95), 0.05));
    d *= 1.0 - 0.8 * box(uv, vec2(-0.1, 0.50), vec2(0.24, 1.1), 0.03); // keep the hatching open
    d = max(d, 0.80 * box(uv, vec2(0.50, 0.34), vec2(1.00, 0.58), 0.03));
    d = max(d, 0.70 * box(uv, vec2(0.60, 0.60), vec2(0.88, 1.00), 0.05));
    d *= 1.0 - 0.6 * box(uv, vec2(0.40, 0.62), vec2(0.58, 1.1), 0.02); // ice column: drips, few blocks
    d *= 1.0 - 0.8 * box(uv, vec2(0.47, 0.34), vec2(0.72, 0.43), 0.01); // keep the orange drag visible
    d = max(d, 0.35 * box(uv, vec2(0.00, 0.33), vec2(0.22, 0.47), 0.03));
    return d;
}

// One jittered grid of rectangles. Each cell may hold one axis-aligned block
// covering a random sub-rectangle of the cell. Inside, the lookup collapses to
// one field point (the block's paint), with a compressed smear for grain.
// Returns colour + coverage (0 none, 1 opaque, 0.5 glaze) and the block's warmth.
vec4 blockGrid(vec2 uv, vec2 P, vec2 cell, vec2 offs, float seed, out float warmth) {
    warmth = 0.0;
    vec2 g = (uv + offs) / cell;
    vec2 id = floor(g);
    vec2 f = fract(g);
    vec4 h = vec4(hash22(id + seed), hash22(id * 1.71 + seed + 5.3));

    // sub-rectangle inside the cell
    vec2 a = h.xy * 0.45;
    vec2 b = a + mix(vec2(0.35), vec2(0.95) - a, h.zw);
    if (any(lessThan(f, a)) || any(greaterThan(f, b))) return vec4(0.0);

    vec2 c = (id + 0.5 * (a + b)) * cell - offs; // block centre (uv)
    float hh = hash12(id * 2.13 + seed * 3.7);
    float dens = blockDensity(c);
    // wide, flat blocks only belong to the band and the warm cross
    if (cell.x > cell.y) dens *= box(c, vec2(0.0, 0.30), vec2(1.0, 0.62), 0.03);
    // tall bars only in the cool upper right
    if (cell.y > 0.25) dens = 0.75 * box(c, vec2(0.58, 0.55), vec2(0.92, 1.1), 0.03);
    // small blocks only in the warm column and the band
    if (cell.x < 0.1) dens *= max(box(c, vec2(0.15, 0.2), vec2(0.5, 0.9), 0.03),
                                  box(c, vec2(0.5, 0.33), vec2(1.0, 0.6), 0.03));
    if (hh > dens) return vec4(0.0);

    // paint picked at one point near the block, slightly above (drag source)
    vec2 src = c + (hash22(id + seed * 9.1) - 0.5) * vec2(0.10, 0.06) + vec2(0.0, 0.02);
    // tall bars drag their paint in from the lighter steel on their left
    if (cell.y > 0.25) src.x -= 0.03 + 0.10 * fract(hh * 91.7);

    // grain: horizontal in the band and the slate blocks, else mostly vertical
    float horP = 0.50 * box(c, vec2(0.48, 0.33), vec2(1.0, 0.60), 0.02)
                      + 0.40 * box(c, vec2(0.72, 0.33), vec2(1.0, 0.52), 0.02)
                      + 0.70 * box(c, vec2(0.0, 0.33), vec2(0.22, 0.47), 0.02)
                      + 0.25 * box(c, vec2(0.1, 0.40), vec2(0.5, 0.62), 0.02);
    float ang = fract(hh * 13.7) < horP ? ANG_H : ANG_V;
    // cool blocks carry more streak contrast than the calm warm ones
    float warmZone = max(box(c, vec2(0.15, 0.25), vec2(0.5, 1.0), 0.05), box(c, vec2(0.5, 0.33), vec2(1.0, 0.6), 0.03));
    Smear sm = smearLookup(P, ang, vec2(30.0, 220.0), mix(0.20, 0.10, warmZone), DARK_LINES, seed + 11.0);

    // compressed local coordinates: the block is nearly flat, the grain
    // carries a faint image of the field around the source point
    vec2 local = (sm.q / REF_SIZE - uv) * 0.6 + (uv - c) * 0.18;
    vec4 col = baseField(src + local);
    col.rgb = shade(col.rgb, sm.lum * mix(0.85, 1.15, fract(hh * 57.1)));

    warmth = col.a;
    return vec4(col.rgb, fract(hh * 31.3) < 0.3 ? 0.5 : 1.0);
}

// The authored rectangles of the field, redrawn as crisp blocks: the
// lookup collapses onto the rectangle's own paint, plus its grain.
vec3 authoredBlocks(vec2 uv, vec2 P, vec3 col) {
    for (int i = 0; i < N_RECT; i++) {
        vec4 r = RECT_BOX[i];
        if (all(greaterThan(uv, r.xy)) && all(lessThan(uv, r.zw))) {
            vec2 c = 0.5 * (r.xy + r.zw);
            Smear sm = smearLookup(P, RECT_ANG[i], vec2(40.0, 300.0), RECT_GRAIN[i], 0.08, 23.0 + float(i));
            vec2 local = (sm.q / REF_SIZE - uv) * 0.25 + (uv - c) * 0.3;
            col = shade(baseField(c + local).rgb, sm.lum);
        }
    }
    return col;
}

// Lay one block over the stack. Glazes (coverage 0.5) stay translucent only
// over paint of the same family; warm over cool would mix to mud, so the
// block becomes opaque there.
void composite(inout vec4 col, vec4 b, float bw) {
    if (b.a <= 0.0) return;
    bool same = (bw > 0.5) == (col.a > 0.5);
    float a = (b.a < 1.0 && same) ? 0.6 : 1.0;
    col = vec4(mix(col.rgb, b.rgb, a), a < 1.0 ? col.a : bw);
}

// col: rgb + warmth of the background smear
vec3 layerBlocks(vec2 uv, vec2 P, vec4 col) {
    // back to front: large, wide-flat, medium, tall bars
    float bw;
    vec4 b;
    b = blockGrid(uv, P, vec2(0.16, 0.22), vec2(0.03, 0.07), 1.0, bw);
    composite(col, b, bw);
    b = blockGrid(uv, P, vec2(0.21, 0.09), vec2(0.11, 0.02), 2.0, bw);
    composite(col, b, bw);
    b = blockGrid(uv, P, vec2(0.08, 0.13), vec2(0.05, 0.11), 3.0, bw);
    composite(col, b, bw);
    b = blockGrid(uv, P, vec2(0.075, 0.32), vec2(0.02, 0.05), 4.0, bw);
    composite(col, b, bw);
    return authoredBlocks(uv, P, col.rgb);
}

// ---- L3: soot ---------------------------------------------------------------
// Near-black horizontal grain under the red band.
vec3 layerSoot(vec2 uv, vec2 P, vec3 col) {
    float strip = box(uv, vec2(0.46, SOOT_V0), vec2(1.05, SOOT_V1), 0.015);
    float grain = noise(P * vec2(0.01, 0.9));
    float soot = strip * smoothstep(0.25, 0.7, grain + 0.3 * strip);
    return col * (1.0 - 0.85 * soot);
}

// ---- L4: specks -------------------------------------------------------------
vec3 layerSpecks(vec2 uv, vec2 P, vec3 col) {
    float zone = box(uv, vec2(0.48, SOOT_V0 - 0.03), vec2(0.75, SOOT_V1 + 0.02), 0.02);
    // 2 px specks, clustered by a coarse noise
    float h = hash12(floor(P / 2.0) + 71.0);
    float cluster = smoothstep(0.45, 0.8, noise(P / 24.0 + 5.0));
    if (h < SPECK_DENS * zone * cluster) col = mix(col, hexColor(0xc8202a), 0.8);
    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 P = uv * REF_SIZE;

#ifdef SHOW_FIELD
    fragColor = vec4(linearToSrgb(baseField(uv).rgb), 1.0);
    return;
#endif

    vec4 bg = layerSmear(uv, P);
    vec3 col = bg.rgb;
#ifndef NO_BLOCKS
    col = layerBlocks(uv, P, bg);
#endif
    col = layerSoot(uv, P, col);
    col = layerSpecks(uv, P, col);

    fragColor = vec4(linearToSrgb(col * EXPOSURE), 1.0);
}
