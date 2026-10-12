// Imperfection, lite - the painting in a single pass, without a buffer.
//
// The full version (main.glsl) paints into Buffer A and smears that buffer
// once more in the Image pass. This one paints and smears in the same pass
// with exactly one field lookup per pixel, at about a third of the cost (4.4
// instead of 14 ms/frame at 1024^2 on an Iris Xe), so it runs on weaker GPUs
// and pastes into Shadertoy as one Image tab. Same composition, same colour
// field, same 32 s loop; less texture.
//
// Register pressure: like paint.glsl, this pass sits just inside Mesa's
// SIMD16 budget. After a change check that it still compiles to SIMD16:
//   MESA_SHADER_CACHE_DISABLE=1 INTEL_DEBUG=fs go run . -shader shaders/lite.glsl
//     -shot out/simd.png -size 64x64 2>&1 | grep -E "SIMD(8|16) shader"   (two lines)
//
//   L0 liteField   baseField (field.glsl) with its loops unrolled - the same
//                  colours. Indexing the anchor arrays inside a loop is what
//                  makes baseField slow (~7 ms at 1024^2): the unrolled reads
//                  use literal indices, which fold into immediates (<1 ms).
//   L1 liteSmear   the smear operator of smear.glsl (strands, segments,
//                  drag, flow, hairline threads, warm/cool dither, red
//                  threads), without drips, dark scratches, soft lines,
//                  bristle skips and grit.
//   W  wet ends    instead of the buffer smear (wet.glsl): in wet zones the
//                  lookup point of a pixel near a segment end slides toward
//                  the neighbouring segment's, further downstream than
//                  upstream, so a run end fades through the field between
//                  the two. The field's hard warm/cool switch keeps it from
//                  making mud. No extra lookup, no buffer.
//   L2 liteBlock   one grid of opaque living blocks (blocks.glsl has four,
//                  with glazes) and the authored rectangles as crisp blocks
//                  with a sliding barcode grain (no sweeps).
//   L3             the dark wedge and the soot strip (accents.glsl); no ink
//                  scratches, red drips or flecks.
//   L4             glow, flicker and grade (grade.glsl).
//
// -D ANIM=0 freezes, -D WET=0 drops the wet ends, -D NO_BLOCKS=1 skips L2.

#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif
#ifndef CLIP_SQUARE
#define CLIP_SQUARE 1
#endif

#include "common.glsl"
#include "anim.glsl"
#include "field.glsl"
#include "wet.glsl"        // WET, the wetness map, wetFamily
#include "smear.glsl"      // smear tunables, shade, pnoise
#include "blocks.glsl"     // block tunables, frayPx, wipeFront, driftAt
#include "accents.glsl"    // layerWedge, layerSoot
#include "grade.glsl"

// ---- L0: the field, unrolled ------------------------------------------------
// One anchor (warm / cool) and one field rectangle at a literal index.
#define LW(i) { vec2 d_ = q - WARM_POS[i].xy; float w_ = WARM_POS[i].z * WARM_POS[i].z / (dot(d_, d_) + 2e-4); w_ *= w_; cw += w_ * WARM_COL[i]; ww += w_; }
#define LC(i) { vec2 d_ = q - COOL_POS[i].xy; float w_ = COOL_POS[i].z * COOL_POS[i].z / (dot(d_, d_) + 2e-4); w_ *= w_; cc += w_ * COOL_COL[i]; wc += w_; }
#define LR(i) if ((!bg || ((BG_SKIP >> (i)) & 1) == 0) && all(greaterThan(p, RECT_BOX[i].xy)) && all(lessThan(p, RECT_BOX[i].zw))) { col = RECT_COL[i]; warmth = RECT_WARM[i]; }

// baseField(p, thr) of field.glsl, line by line, with the loops unrolled.
// Keep the two in sync (N_WARM = 36, N_COOL = 47, N_FIELD_RECT = 9).
vec4 liteField(vec2 p, float thr) {
    bool bg = thr > 1.5;
    thr = bg ? thr - FIELD_BG : thr;
    float ny = noise1(p.y * 4.0 + 2.0) * 2.0 - 1.0, nx = noise1(p.x * 4.0 + 9.0) * 2.0 - 1.0;
    float ph = TAU * loopPhase();
    vec2 s2 = sin(2.0 * ph) * vec2(ny, nx);
    vec2 s3 = sin(3.0 * ph) * vec2(nx, -ny);
    vec2 q = p + SEAM_BREATH * ANIM * vec2(0.6 * s2.x + 0.4 * s3.x, 0.3 * s2.y + 0.2 * s3.y);
    // the drifts before the anchors: two values live across them, not four
    // (register pressure, SIMD16)
    float dLit = DRIFT_LIT * ANIM * (0.6 * s3.y + 0.4 * s2.x);
    float dHue = DRIFT_HUE * ANIM * (0.6 * s2.y + 0.4 * s3.x);
    vec3 cw = vec3(0.0), cc = vec3(0.0);
    float ww = 0.0, wc = 0.0;
    LW(0) LW(1) LW(2) LW(3) LW(4) LW(5) LW(6) LW(7) LW(8) LW(9) LW(10) LW(11)
    LW(12) LW(13) LW(14) LW(15) LW(16) LW(17) LW(18) LW(19) LW(20) LW(21) LW(22) LW(23)
    LW(24) LW(25) LW(26) LW(27) LW(28) LW(29) LW(30) LW(31) LW(32) LW(33) LW(34) LW(35)
    LC(0) LC(1) LC(2) LC(3) LC(4) LC(5) LC(6) LC(7) LC(8) LC(9) LC(10) LC(11)
    LC(12) LC(13) LC(14) LC(15) LC(16) LC(17) LC(18) LC(19) LC(20) LC(21) LC(22) LC(23)
    LC(24) LC(25) LC(26) LC(27) LC(28) LC(29) LC(30) LC(31) LC(32) LC(33) LC(34) LC(35)
    LC(36) LC(37) LC(38) LC(39) LC(40) LC(41) LC(42) LC(43) LC(44) LC(45) LC(46)
    float warmth = ww / (ww + wc);
    cw /= ww;
    cc /= wc;

    cc *= 1.0 + dLit;

    float lowCol = box(p, vec2(0.21, 0.0), vec2(0.47, 0.42), 0.04);
    if (lowCol > 0.0) {
        float tn = noise(p * vec2(150.0, 1.1) + vec2(3.3, 0.0));
        warmth -= COOL_THREADS * lowCol * smoothstep(COOL_THREAD_CUT, COOL_THREAD_CUT + 0.1, tn);
    }

    float sel = smoothstep(thr - 0.01, thr + 0.01, warmth);
    vec3 col = cc;
    if (sel > 0.0) {
        float m = warmVarMask(p);
        float hN = clamp((noise(p * WVAR_FREQ + WSEED_H) * 2.0 - 1.0) * 1.8, -1.0, 1.0);
        float lN = clamp((noise(p * WVAR_FREQ_L + WSEED_L) * 2.0 - 1.0) * 1.6, -1.0, 1.0);
        hN = mix(hN, lN, 0.35);
        cw.b *= 1.0 - WVAR_CHROMA * lowCol;
        float core = box(p, vec2(0.29, 0.53), vec2(0.43, 0.80), 0.04);
        float hueAmp = WVAR_HUE * m * mix(1.0, CORE_HUE_AMP, core);
        cw = warmShift(cw, hueAmp * hN + dHue + WVAR_LOW_HUE * lowCol + CORE_HUE * core,
                       1.0 + WVAR_LIT * m * lN + dLit + WVAR_LOW_LIT * lowCol + CORE_LIT * core);
        col = mix(cc, cw, sel);
    }

    LR(0) LR(1) LR(2) LR(3) LR(4) LR(5) LR(6) LR(7) LR(8)
    return vec4(srgbToLinear(col), warmth);
}

// ---- L1 + W: the smear with wet ends ----------------------------------------
const float LITE_WET_DOWN = 0.4;    // fade back upstream, relative to the fade downstream

struct LiteSmear {
    vec2  q;     // field lookup point (reference px)
    float lum;   // brightness factor (linear)
    float thr;   // warm/cool threshold of this hairline
    float hue;   // > 0: red thread
};

// smearFlow (smear.glsl) for the background, flowing, trimmed; wet 0..1.
LiteSmear liteSmear(vec2 P, float ang, vec2 len, float spread, float dark, float wet) {
    const float seed = 1.0;
    vec2 d = vec2(cos(ang), sin(ang));
    vec2 n = vec2(-d.y, d.x);
    float s = dot(P, d);
    float t = dot(P, n);

    // strands of 6-36 px (thinner in the hatching), lines of 1-3 px inside
    float W = mix(STRAND_W.x, STRAND_W.y, hash11(floor(t / 48.0) * 1.31 + seed)) * (abs(d.x * d.y) > 0.4 ? HATCH_W : 1.0);
    float strand = floor(t / W) + floor(t / 48.0) * 97.0;
    vec2 hb = hash22(vec2(strand, seed * 7.0 + 1.3));
    float lw = 1.0 + floor(hash11(strand * 3.17 + seed) * 3.0);
    float line = floor(t / lw);
    vec2 hl = hash22(vec2(line, seed * 3.0 + 7.7));

    float L = mix(len.x, len.y, hb.x * hb.x);
    float rough = clamp(spread / LUM_SPREAD, 0.25, 1.5);

    // flow: down for vertical and diagonal grain, right for horizontal; one
    // strand period per loop
    float sgn = abs(d.y) > 0.3 ? -sign(d.y) : sign(d.x);
    float M = max(1.0, floor(mix(FLOW_PERIOD.x, FLOW_PERIOD.y, hash11(strand * 5.91 + seed * 3.3)) / L + 0.5));
    float Pd = M * L;
    float o = (hb.y + RAGGED * rough * (hl.x - 0.5)) * L - sgn * loopScroll(1.0, Pd);
    float sid = floor((s + o) / L);
    float s0 = sid * L - o;
    // tapered tips: the outer lines are cut first
    float e = abs(fract(t / W) * 2.0 - 1.0);
    float cut = step(s - s0, TAPER * L * (e + 0.4 * (hl.y - 0.5)));
    sid -= cut;
    s0 -= cut * L;

    // wet ends: the neighbour across the nearer segment end. Its weight is
    // 0.5 right at the end and falls off over the reach; paint is dragged
    // downstream, so the upstream segment reaches far into this one, this
    // one only a little back into it.
    float a0 = s - s0, a1 = s0 + L - s;
    bool low = a0 < a1;
    float sidN = sid + (low ? -1.0 : 1.0);
    float s0N = s0 + (low ? -L : L);
    bool upEnd = low == (sgn > 0.0);
    float run = fract(hb.x * 7.31);
    float reach = wet * mix(WET_LEN.x, WET_LEN.y, run * run * run)
                * (1.0 + WET_BREATH * loopNoise(strand * 0.37 + 5.0, 2.0)) * (upEnd ? 1.0 : LITE_WET_DOWN);
    float w2 = reach > 0.0 ? 0.5 * (1.0 - smoothstep(0.0, reach, max(min(a0, a1), 0.0))) : 0.0;

    // drag per segment and line (comb-like ends)
    float sm = mod(sid, M), smN = mod(sidN, M);
    float hseg = hash12(vec2(strand * 1.37 + seed, sm));
    float hsegN = hash12(vec2(strand * 1.37 + seed, smN));
    float hk = hash12(vec2(line * 1.91 + seed, sm));
    float hkN = hash12(vec2(line * 1.91 + seed, smN));
    float sq = mix(s, s0 + L * SRC_FRAC, mix(DRAG_MIN, 1.0, hseg) * (1.0 - LINE_DRAG * hk * hk));
    float sqN = mix(s, s0N + L * SRC_FRAC, mix(DRAG_MIN, 1.0, hsegN) * (1.0 - LINE_DRAG * hkN * hkN));
    // hairlines read the field beside their strand (interleaved threads at
    // a seam). Dry, every line jumps by its own hash; wet, the offset is a
    // smooth noise across the grain, so neighbouring lines read neighbouring
    // paint: soft hairlines instead of 1 px cuts (the cross-grain half of
    // the wet smear)
    float off = mix(hl.y, noise1(t / mix(2.0, 5.0, hb.y) + strand * 7.3), wet) - 0.5;
    float tq = t + off * THREAD_SPREAD * rough * (1.0 - 0.3 * wet);
    LiteSmear r;
    r.q = d * mix(sq, sqN, w2) + n * tq;

    // brightness: strand level, broad bands, hairline segments and dry-brush
    // dashes (the dashes melt where the paint is wet)
    float fs = mod(s + o, Pd);
    spread *= TEX_GAIN;
    float Nl = max(1.0, floor(Pd / mix(8.0, 90.0, hl.x * hl.x) + 0.5));
    float lid = mod(floor(fs * Nl / Pd + hl.y), Nl);
    float hline = hash12(vec2(line * 0.73 + seed, lid));
    float band = noise(vec2(t / 18.0, s / 600.0 + seed)) - 0.5;
    float mn = max(1.0, floor(Pd / mix(5.0, 14.0, hb.x) + 0.5));
    float mott = pnoise(vec2(t / 1.2 + seed * 3.0, fs * mn / Pd), mn, DASH_EDGE) - 0.5;
    float tex = clamp(spread, TEX_FLOOR, TEX_CAP);
    float lum = 1.0 + spread * (0.8 * band + LINE_GRAIN * (1.0 - 0.6 * wet) * (hline - 0.5))
              + tex * MOTTLE * mott * (1.0 - 0.7 * wet);
    // per segment: its level and, in the hatching, whole dark strokes
    float l1 = max((lum + spread * 0.9 * (hseg - 0.5)) * (fract(hseg * 7.31) < (dark - 0.08) * 3.0 ? HATCH_DARK : 1.0), 0.2);
    float l2 = max((lum + spread * 0.9 * (hsegN - 0.5)) * (fract(hsegN * 7.31) < (dark - 0.08) * 3.0 ? HATCH_DARK : 1.0), 0.2);
    r.lum = mix(l1 * l1 * l1, l2 * l2 * l2, w2);

    // warm/cool threshold wandering along each hairline, red threads
    float tnn = max(1.0, floor(Pd / mix(10.0, 60.0, hl.y) + 0.5));
    r.thr = clamp(0.5 + SEAM_DITHER * (pnoise1(fs * tnn / Pd, tnn, hl.x * 50.0) - 0.5), 0.08, 0.92);
    float hb2 = hash11(floor(tq / mix(2.0, 4.0, hb.y)) * 3.71 + seed);
    float rn = max(1.0, floor(Pd / mix(30.0, 90.0, fract(hb2 * 7.3)) + 0.5));
    r.hue = step(1.0 - THREAD_RED, hb2) * mix(0.5, 1.0, fract(hb2 * 13.0))
          * smoothstep(0.35, 0.6, pnoise1(fs * rn / Pd, rn, hb2 * 40.0));
    return r;
}

// ---- L2: blocks -------------------------------------------------------------
const vec2  LITE_CELL = vec2(0.12, 0.16);  // the one block grid (uv)
const vec2  LITE_OFFS = vec2(0.03, 0.07);
const float LITE_Q    = 0.18;              // compression of the field image inside a block

// One grid of living blocks, after blockGrid (blocks.glsl): a block covers a
// random sub-rectangle of its cell, hairline ends frayed, dry-brush break-up
// at the stroke end, wiped in and out once per slot. Its paint is one field
// point near the block with a compressed image of the field around it, and
// a per-hairline brightness with a slow drift along the grain. All blocks
// are opaque, so a pixel needs one field lookup either way. Geometry only:
// the caller runs the lookup (see mainImage).
struct LiteBlock {
    bool  hit;  // a block covers this pixel
    vec2  q;    // field lookup point (uv)
    float lum;  // brightness factor (linear), drift included
    float tilt; // hue tilt of the drift (blocks.glsl: driftAt().y)
};

LiteBlock liteBlock(vec2 uv, vec2 P) {
    const float seed = 5.0;
    LiteBlock bk;
    bk.hit = false;
    bk.q = vec2(0.0);
    bk.lum = 1.0;
    bk.tilt = 0.0;
#ifdef NO_BLOCKS
    return bk;
#endif
    vec2 g = (uv + LITE_OFFS) / LITE_CELL;
    vec2 id = floor(g);
    vec2 f = fract(g);

    vec2 ev = vec2(0.0, 0.5);
    float key = 0.0;
    float hl = hash12(id * 3.31 + seed * 1.7);
    bool alive = ANIM > 0.0 && hl < LIVE_FRAC;
    if (alive) {
        ev = loopEvent(LIFE_SLOTS, hl * 113.0 + seed);
        key = ev.x + 1.0;
    }
    vec2 kid = id + key * vec2(17.31, 5.77);
    vec4 h = vec4(hash22(kid + seed), hash22(kid * 1.71 + seed + 5.3));
    vec2 a = h.xy * 0.45;
    vec2 b = a + mix(vec2(0.35), vec2(0.95) - a, h.zw);
    vec2 m = (FRAY_PX * 0.35 + BLEED_PX) / (LITE_CELL * REF_SIZE);
    if (any(lessThan(f, a - m)) || any(greaterThan(f, b + m))) return bk;

    vec2 c = (id + 0.5 * (a + b)) * LITE_CELL - LITE_OFFS;   // block centre (uv)
    float hh = hash12(kid * 2.13 + seed * 3.7);
    if (hh > blockDensity(c)) return bk;

    // grain: horizontal in the band and the slate blocks, else mostly vertical
    float horP = 0.50 * box(c, vec2(0.48, 0.33), vec2(1.0, 0.60), 0.02)
               + 0.40 * box(c, vec2(0.72, 0.33), vec2(1.0, 0.52), 0.02)
               + 0.35 * box(c, vec2(0.0, 0.33), vec2(0.22, 0.47), 0.02)
               + 0.25 * box(c, vec2(0.1, 0.40), vec2(0.5, 0.62), 0.02);
    bool hor = fract(hh * 13.7) < horP;
    vec2 d = hor ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec2 aG = hor ? a : a.yx;
    vec2 bG = hor ? b : b.yx;
    vec2 fG = hor ? f : f.yx;
    if (fG.y < aG.y || fG.y > bG.y) return bk;
    float across = hor ? P.y : P.x;
    float line = floor(across / LINE_PX);
    float lenPx = (hor ? LITE_CELL.x : LITE_CELL.y) * REF_SIZE;
    float lo = aG.x - frayPx(line, hh * 31.0 + 1.0) / lenPx;
    float hi = bG.x + frayPx(line, hh * 31.0 + 2.0) / lenPx;
    if (fG.x < lo || fG.x > hi) return bk;

    float dir = fract(hh * 23.1) < (hor ? 0.5 : 0.7) ? -1.0 : 1.0;
    float u = (fG.x - lo) / (hi - lo);
    if (dir < 0.0) u = 1.0 - u;
    float blen = (hi - lo) * lenPx;
    float dash = hash12(vec2(line * 1.3 + hh, floor(dot(P, d) / mix(6.0, 26.0, hash11(line + hh)))));
    if (dash < DRY_END * smoothstep(0.82, 1.0, u)) return bk;

    // wipe in along the grain, hold, then retract or dissolve thread by thread
    if (alive) {
        float pin = ev.y / WIPE_IN;
        if (pin < 1.0 && u > wipeFront(pin, line, hh)) return bk;
        float pout = (ev.y - (1.0 - WIPE_OUT)) / WIPE_OUT;
        if (pout > 0.0) {
            if (fract(hh * 17.9) < 0.5) {
                if (u < wipeFront(pout, line, hh + 0.5)) return bk;
            } else if (hash12(vec2(line, floor(u * blen / 24.0) + hh * 7.0)) < pout) {
                return bk;
            }
        }
    }

    vec2 src = c + (hash22(kid + seed * 9.1) - 0.5) * vec2(0.10, 0.06) + vec2(0.0, 0.02);
    bk.q = src + (uv - c) * LITE_Q;
    // per-hairline brightness, stronger in the cool blocks
    float warmZone = max(box(c, vec2(0.15, 0.25), vec2(0.5, 1.0), 0.05), box(c, vec2(0.5, 0.33), vec2(1.0, 0.6), 0.03));
    float l = mix(0.85, 1.15, fract(hh * 57.1)) * (1.0 + mix(0.40, 0.20, warmZone) * (hash11(line * 1.37 + hh * 9.0) - 0.5))
            * (1.0 - 0.10 * (1.0 - smoothstep(0.0, 0.06, u)));   // darker lip at the stroke start
    vec2 dr = driftAt(P, d, hh * 17.0);
    bk.lum = l * l * l * dr.x;
    bk.tilt = dr.y;
    bk.hit = true;
    return bk;
}

// Authored rectangle i (field.glsl: RECT_*) as a crisp block: hairlines
// along its grain, ragged ends for 0 and 90 deg grain, a barcode of tone
// runs (BAR_RUN) sliding along each hairline. The glazes (i >=
// N_FIELD_RECT) lie over the paint at GLAZE. Call with a literal i.
vec3 liteHero(int i, vec2 uv, vec2 P, vec3 col) {
    vec4 bx = RECT_BOX[i];
    // cheap reject with room for the frayed ends (frayPx < 0.35 FRAY_PX + BLEED_PX)
    const float m = (0.35 * FRAY_PX + BLEED_PX) * HERO_FRAY / REF_SIZE;
    if (any(lessThan(uv, bx.xy - m)) || any(greaterThan(uv, bx.zw + m))) return col;
    float fi = float(i);
    float ang = RECT_ANG[i];
    vec2 d = vec2(cos(ang), sin(ang));
    vec2 n = vec2(-d.y, d.x);
    float line = floor(dot(P, n) / LINE_PX);
    vec2 fr = vec2(frayPx(line, fi * 7.0 + 1.0), frayPx(line, fi * 7.0 + 2.0)) * HERO_FRAY / REF_SIZE;
    vec2 ax = abs(d.x * d.y) > 0.4 ? vec2(0.0) : abs(d);   // diagonal grain keeps its edges
    vec2 lo = bx.xy - fr.x * ax, hi = bx.zw + fr.y * ax;
    if (any(lessThan(uv, lo)) || any(greaterThan(uv, hi))) return col;

    float run = mix(BAR_RUN.x, BAR_RUN.y, hash11(line * 1.7 + fi));
    float s = dot(P, d) + hash11(line + fi * 3.1) * 8.0 * run + loopScroll(1.0, 8.0 * run);
    float tone = hash12(vec2(line * 0.91 + fi, mod(floor(s / run), 8.0))) - 0.5;
    float l = 1.0 + 2.0 * RECT_GRAIN[i] * tone;
    vec3 c = shade(srgbToLinear(RECT_COL[i]), l * l * l);
    return i >= N_FIELD_RECT ? mix(col, c, GLAZE) : c;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = canvasUV(fragCoord);
#if CLIP_SQUARE
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
#endif
    vec2 P = uv * REF_SIZE;     // reference pixels

    // what paints this pixel: a grid block (L2) or the smeared background
    // (L1 + W). Exactly one of them, so a pixel needs one field lookup, and
    // only the merged lookup point and shading wait for it (few live values
    // keep the shader within SIMD16 on Mesa).
    vec2 q;
    float thr, lum, hue = 0.0, tilt = 0.0;
    LiteBlock bk = liteBlock(uv, P);
    if (bk.hit) {
        q = bk.q;
        thr = 0.5;
        lum = bk.lum;
        tilt = bk.tilt;
    } else {
        float ang, spread, dark;
        vec2 len;
        directionField(uv, ang, len, spread, dark);
        LiteSmear sm = liteSmear(P, ang, len, spread, dark, wetness(uv, dirIndex(ang)) * WET);
        q = sm.q / REF_SIZE;
        thr = sm.thr;
        lum = sm.lum;
        hue = sm.hue;
    }
    vec3 c = liteField(q, thr + FIELD_BG).rgb;
    // a fresh copy of uv (the max is a no-op): otherwise the compiler shares
    // terms of the layers below with the ones above and keeps them live
    // across the field (register pressure, SIMD16)
    uv = max(uv, vec2(-8.0));
    P = uv * REF_SIZE;
    vec3 col = paintShade(hueThread(c, hue), lum, vec2(1.0, tilt));

#ifndef NO_BLOCKS
    // L2: the authored rectangles, crisp, on top
    col = liteHero(0, uv, P, col);
    col = liteHero(1, uv, P, col);
    col = liteHero(2, uv, P, col);
    col = liteHero(3, uv, P, col);
    col = liteHero(4, uv, P, col);
    col = liteHero(5, uv, P, col);
    col = liteHero(6, uv, P, col);
    col = liteHero(7, uv, P, col);
    col = liteHero(8, uv, P, col);
    col = liteHero(9, uv, P, col);
    col = liteHero(10, uv, P, col);
#endif
    col = layerWedge(uv, P, col);           // L3
    col = layerSoot(uv, P, col);
    col = layerGlow(uv, col);               // L4
    col = layerGrade(col);

    fragColor = vec4(linearToSrgb(col * EXPOSURE), 1.0);
}
