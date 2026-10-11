// blocks.glsl - L2: rectangular blocks.
//
// Blocks are a collapse of the lookup: inside a rectangle every pixel reads
// (nearly) the same field point, so the block is one paint, carrying only a
// compressed grain. Four jittered grids, then the field's authored rectangles
// redrawn on top.
//
// Blocks are painted, not pasted: each one is a bundle of hairlines running
// along its grain. The hairlines end at slightly different places (frayed
// ends along the grain, straight edges across it), break up like a dry brush
// near the end of the stroke, and drift in colour along their length.
// Glazes are translucent per hairline, so the threads below show through.
//
// Animation ("the collage reassembles", docs/animation.md): a share of the
// grid cells is alive. Per event slot such a cell gets a new block (new
// hash = new size, position and paint) that wipes in along its grain like a
// pixel-sort sweep, holds, then wipes out or dissolves thread by thread.
// A few of them glitch-slide in quantised steps along 0 or 90 deg. The
// authored hero blocks stay in place and get occasional re-sort sweeps
// through their grain.
//
// Performance note: the Intel compiler drops to SIMD8 (1.5-2x slower)
// when register pressure gets too high. So no dynamic vector indexing, the
// smear + field lookup is inlined only three times (background, grid loop,
// hero; smear.glsl: paintJob), the hero paint is evaluated at most twice per
// pixel, and everything but the field lookup is settled before it. Check
// with INTEL_DEBUG=fs for "SIMD16 shader".
// Debug: -D BLOCK_DEBUG=1 shows living blocks green, wipes magenta, slides
// cyan and hero sweeps yellow.

#ifndef GLAZE
#define GLAZE 0.35 // opacity of the authored glaze rectangles
#endif

const float LINE_PX     = 2.0;    // hairline width across the grain (px)
const float FRAY_PX     = 7.0;    // how far hairline ends scatter along the grain (px)
const float BLEED_PX    = 26.0;   // occasional hairline that runs on past the block end (px)
const float BLEED_P     = 0.06;   // share of hairlines that bleed
const float DRY_END     = 0.45;   // dry-brush break-up near the end of a stroke (0 = none)
const float BLK_DRIFT_LUM   = 0.10;   // lightness drift along the grain
const float BLK_DRIFT_HUE   = 0.10;   // hue drift along the grain (within the paint's family)
const float DRIFT_PX    = 260.0;  // wavelength of the drift along the grain (px)
const float GLAZE_A     = 0.74;   // mean opacity of a grid glaze over its own family
const float GLAZE_VAR   = 0.45;   // per-hairline opacity spread of glazes

// animation
const float LIVE_FRAC   = 0.70;   // share of grid cells whose block is replaced per slot
const float LIFE_SLOTS  = 3.0;    // block generations per loop in a living cell
const float WIPE_IN     = 0.09;   // wipe-in duration (fraction of a slot)
const float WIPE_OUT    = 0.08;   // wipe-out / dissolve duration (fraction of a slot)
const float RAG         = 0.35;   // raggedness of a wipe front (fraction of block length)
const float SORT_BAND   = 0.40;   // pixel-sort smear behind a front (fraction of block length)
const float SORT_GLOW   = 0.45;   // brightness lift of the sorted band at its front
const float SLIDE_FRAC  = 0.22;   // share of living blocks that glitch-slide once
const float SLIDE_DUR   = 0.05;   // duration of a slide (fraction of a slot)
const float HERO_SLOTS  = 2.0;    // re-sort sweep slots per loop of a hero block
const float HERO_P      = 0.75;   // chance that a hero slot carries a sweep
const float SWEEP_DUR   = 0.10;   // duration of a hero sweep (fraction of a slot)
const float HERO_FRAY   = 0.45;   // hero hairline ends: short and mostly inside the silhouette (x FRAY_PX)
const float HERO_GLOW   = 0.20;   // brightness lift of a hero's sorted band (calmer than SORT_GLOW)
const float HERO_STREAK = 0.8;    // long brush streaks in hero blocks, relative to their grain

// glaze bars (the authored glazes in the upper right)
const vec2  BAR_RUN     = vec2(30.0, 180.0);  // run length of one barcode line tone (px)
const float BAR_UMBER   = 0.08;   // share of umber threads in the grey bar
const vec3  UMBER       = vec3(0.36, 0.25, 0.17); // sRGB umber thread colour
const vec3  BAR_TINT    = vec3(0.70, 1.00, 1.35); // grey bar: the reference reads steel grey, not warm grey

// ---- painted-block helpers ---------------------------------------------------

// Colour drift along the grain: lightness plus a hue tilt that stays inside
// the paint's family (warm tilts between red and yellow, cool between navy
// and teal), so a block never drifts into grey. Split in two halves so the
// drift is computed before the expensive field lookup and only two floats
// stay live across it (keeps the shader within SIMD16 register limits).
// driftAt: one drift curve per brush strand (strands 48 / 90 px wide).
vec2 driftAt(vec2 P, vec2 d, float seed) {
    vec2 n = vec2(-d.y, d.x);
    float s = dot(P, d);
    float x = noise1(s / DRIFT_PX + 50.0 * hash11(floor(dot(P, n) / 48.0) + seed)) - 0.5;
    float y = noise1(s / (0.6 * DRIFT_PX) + 50.0 * hash11(floor(dot(P, n) / 90.0) - seed)) - 0.5;
    return vec2(1.0 + 2.0 * BLK_DRIFT_LUM * x, BLK_DRIFT_HUE * y);
}

// Ragged hairline end: how far this hairline's end sits beyond (> 0) or
// short of (< 0) the block edge, in px.
float frayPx(float line, float seed) {
    vec2 h = hash22(vec2(line * 0.37 + seed, seed * 1.9 + 3.1));
    return FRAY_PX * (h.x - 0.65) + (h.y < BLEED_P ? BLEED_PX * fract(h.y * 97.0) : 0.0);
}

// Wipe front of hairline `line` at progress pr (0..1): every hairline has
// its own lag, so the front is ragged like a pixel-sort sweep. Returns the
// front position in block-length units (u in 0..1 is covered when u < front).
float wipeFront(float pr, float line, float seed) {
    return pr * (1.0 + RAG) - RAG * hash12(vec2(line, seed * 5.3 + 0.7));
}

// ---- grid blocks ---------------------------------------------------------------

// One jittered grid of rectangles. Each cell may hold one axis-aligned block
// covering a random sub-rectangle of the cell. Inside, the lookup collapses to
// one field point (the block's paint), with a compressed smear for grain.
// Returns false where the cell has no block at this pixel, else fills the
// block's paint job bp (run by layerPaint).
bool blockGrid(vec2 uv, vec2 P, vec2 cell, vec2 offs, float seed, out PaintJob bp) {
    bp = noJob();
    vec2 g = (uv + offs) / cell;
    vec2 id = floor(g);
    vec2 f = fract(g);

    // life cycle: living cells take a new block per slot; key 0 is the still
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

    // sub-rectangle inside the cell
    vec2 a = h.xy * 0.45;
    vec2 b = a + mix(vec2(0.35), vec2(0.95) - a, h.zw);
    // cheap reject with room for frayed ends (and slides of living blocks)
    float hh = hash12(kid * 2.13 + seed * 3.7);
    bool slide = alive && fract(hh * 71.3) < SLIDE_FRAC;
    vec2 m = (FRAY_PX * 0.35 + BLEED_PX) / (cell * REF_SIZE) + (slide ? 0.3 : 0.0);
    if (any(lessThan(f, a - m)) || any(greaterThan(f, b + m))) return false;

    vec2 c = (id + 0.5 * (a + b)) * cell - offs; // block centre (uv)
    float dens = blockDensity(c);
    // wide, flat blocks only belong to the band and the warm cross
    if (cell.x > cell.y) dens *= box(c, vec2(0.0, 0.30), vec2(1.0, 0.62), 0.03);
    // tall bars only in the cool upper right
    if (cell.y > 0.25) dens = 0.75 * box(c, vec2(0.58, 0.55), vec2(0.92, 1.1), 0.03);
    // small blocks only in the warm column and the band
    if (cell.x < 0.1) dens *= max(box(c, vec2(0.15, 0.2), vec2(0.5, 0.9), 0.03),
                                  box(c, vec2(0.5, 0.33), vec2(1.0, 0.6), 0.03));
    if (hh > dens) return false;

    // grain: horizontal in the band and the slate blocks, else mostly vertical
    float horP = 0.50 * box(c, vec2(0.48, 0.33), vec2(1.0, 0.60), 0.02)
                      + 0.40 * box(c, vec2(0.72, 0.33), vec2(1.0, 0.52), 0.02)
                      + 0.35 * box(c, vec2(0.0, 0.33), vec2(0.22, 0.47), 0.02)
                      + 0.25 * box(c, vec2(0.1, 0.40), vec2(0.5, 0.62), 0.02);
    bool hor = fract(hh * 13.7) < horP;
    float ang = hor ? ANG_H : ANG_V;
    vec2 d = hor ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    // cell coordinates along (.x) and across (.y) the grain; selects instead
    // of dynamic vector indexing, which costs registers
    vec2 aG = hor ? a : a.yx;
    vec2 bG = hor ? b : b.yx;

    // glitch slide: a few living blocks jump in quantised steps along 0 or
    // 90 deg into the free room of their cell, then stay there
    vec2 off = vec2(0.0);
    if (slide) {
        bool sx = fract(hh * 5.91) < 0.5;
        float up = 0.98 - (sx ? b.x : b.y), dn = (sx ? a.x : a.y) - 0.02;
        float dist = min(max(up, dn) * 0.9, 0.3) * (up > dn ? 1.0 : -1.0);
        float n = 3.0 + floor(fract(hh * 3.17) * 3.0);
        float t0 = mix(0.25, 0.6, fract(hh * 41.9));
        float pr = clamp((ev.y - t0) / SLIDE_DUR, 0.0, 1.0);
        off = (sx ? vec2(1.0, 0.0) : vec2(0.0, 1.0)) * dist * floor(pr * n) / n;
    }
    vec2 fG = hor ? f - off : (f - off).yx;
    vec2 uvB = uv - off * cell;   // block-space position: the paint moves along
    vec2 PB = uvB * REF_SIZE;

    // across the grain the edges stay straight
    if (fG.y < aG.y || fG.y > bG.y) return false;
    // along the grain each hairline ends on its own: frayed ends
    float across = hor ? PB.y : PB.x;
    float line = floor(across / LINE_PX);
    float lenPx = (hor ? cell.x : cell.y) * REF_SIZE;
    float lo = aG.x - frayPx(line, hh * 31.0 + 1.0) / lenPx;
    float hi = bG.x + frayPx(line, hh * 31.0 + 2.0) / lenPx;
    if (fG.x < lo || fG.x > hi) return false;

    // stroke direction along the grain (vertical strokes mostly run down)
    float dir = fract(hh * 23.1) < (hor ? 0.5 : 0.7) ? -1.0 : 1.0;
    float u = (fG.x - lo) / (hi - lo);
    if (dir < 0.0) u = 1.0 - u;
    float blen = (hi - lo) * lenPx;   // block length along the grain (px)

    // dry brush: near the end of the stroke hairlines break into dashes
    float dash = hash12(vec2(line * 1.3 + hh, floor(dot(PB, d) / mix(6.0, 26.0, hash11(line + hh)))));
    if (dash < DRY_END * smoothstep(0.82, 1.0, u)) return false;

    // life cycle: wipe in along the grain, hold, wipe out or dissolve
    float sortD = 0.0;   // pixel-sort smear: distance behind the front (u units)
    if (alive) {
        float pin = ev.y / WIPE_IN;
        if (pin < 1.0) {
            float fr = wipeFront(pin, line, hh);
            if (u > fr) return false;
            sortD = fr - u;
        }
        float pout = (ev.y - (1.0 - WIPE_OUT)) / WIPE_OUT;
        if (pout > 0.0) {
            if (fract(hh * 17.9) < 0.5) {
                // the tail retracts in the stroke direction
                float fr = wipeFront(pout, line, hh + 0.5);
                if (u < fr) return false;
            } else {
                // dissolve thread by thread (hard per hairline, no fade = no mud)
                if (hash12(vec2(line, floor(u * blen / 24.0) + hh * 7.0)) < pout) return false;
            }
        }
    }

    // pixel-sort smear behind a wipe front: the hairline repeats the paint
    // found at its front, stretched backwards, brightest at the front
    float sortK = 0.0;
    if (sortD > 0.0 && sortD < SORT_BAND) {
        sortK = 1.0 - sortD / SORT_BAND;
        PB += d * dir * sortD * blen;
        uvB = PB / REF_SIZE;
    }

    // paint picked at one point near the block, slightly above (drag source)
    vec2 src = c + (hash22(kid + seed * 9.1) - 0.5) * vec2(0.10, 0.06) + vec2(0.0, 0.02);
    // tall bars drag their paint in from the lighter steel on their left
    if (cell.y > 0.25) src.x -= 0.03 + 0.10 * fract(hh * 91.7);

    // everything but the smear and the paint itself is settled before those
    // two expensive lookups, so few values stay live across them (keeps the
    // shader within SIMD16 register limits). Paint gathers at the start of
    // the stroke: a slightly darker lip.
    float lumF = mix(0.85, 1.15, fract(hh * 57.1)) * (1.0 + SORT_GLOW * sortK)
               * (1.0 - 0.10 * (1.0 - smoothstep(0.0, 0.06, u)));
    vec2 dr = driftAt(PB, d, hh * 17.0);
    // glaze: opacity varies per hairline and along it, so threads below show
    float ga = fract(hh * 31.3) >= 0.3 ? 1.0
             : clamp(GLAZE_A * (1.0 + GLAZE_VAR * (2.0 * hash11(floor(across / 3.0) + hh * 13.0) - 1.0))
                     * (0.8 + 0.4 * noise(vec2(dot(PB, d) / 60.0, line))), 0.08, 0.95);
    // compressed local coordinates: the block is nearly flat, the grain
    // carries a faint image of the field around the source point
    vec2 p0 = src + (uvB - c) * 0.18 - uvB * 0.6;

    // cool blocks carry more streak contrast than the calm warm ones
    float warmZone = max(box(c, vec2(0.15, 0.25), vec2(0.5, 1.0), 0.05), box(c, vec2(0.5, 0.33), vec2(1.0, 0.6), 0.03));
    bp.P = PB;
    bp.ang = ang;
    bp.len = vec2(30.0, 220.0);
    bp.spread = mix(0.20, 0.10, warmZone);
    bp.dark = DARK_LINES;
    bp.seed = seed + 11.0;
    bp.p0 = p0;
    bp.lumK = lumF * dr.x;
    bp.tilt = dr.y;
    bp.cover = ga + 4.0 * dirIndex(ang);   // + grain direction, see PaintJob.cover
#ifdef BLOCK_DEBUG
    // debug: living blocks in green, transitions in magenta, slides in cyan
    bp.dbg = vec4(0.0);
    if (alive) bp.dbg = vec4((ev.y < WIPE_IN || ev.y > 1.0 - WIPE_OUT) ? vec3(1.0, 0.0, 1.0)
                             : (off != vec2(0.0) ? vec3(0.0, 1.0, 1.0) : vec3(0.0, 0.6, 0.0)), 1.0);
#endif
    return true;
}

// ---- authored hero blocks ------------------------------------------------------

// Barcode texture of a glaze bar: hairlines 1-4 px wide in bundles, each
// line with its own tone and opacity that hold over long runs along the grain
// (no grit: a glaze is laid with a soft, wide brush). contrast scales the
// tone spread. Returns (lum factor, opacity factor, thread hash, -).
vec4 barcode(vec2 P, vec2 d, float seed, float contrast) {
    vec2 n = vec2(-d.y, d.x);
    float t = dot(P, n), s = dot(P, d);
    float bundle = floor(t / 14.0);
    float lw = 1.0 + floor(hash11(bundle * 1.37 + seed) * 4.0);
    float line = floor(t / lw) + bundle * 31.0;
    vec2 hl = hash22(vec2(line, seed * 3.3 + 0.9));
    float L = mix(BAR_RUN.x, BAR_RUN.y, hl.x);
    float seg = floor((s + hl.y * L) / L);
    float tone = mix(hash12(vec2(line * 0.71 + seed, seg)), hash11(bundle * 2.9 + seed), 0.35);
    float lum = 1.0 + 3.0 * contrast * (tone - 0.5);
    lum = max(lum, 0.25);
    lum = lum * lum * lum;
    float a = mix(0.7, 2.3, fract(tone * 7.31)) * (0.85 + 0.3 * noise(vec2(s / 90.0, line)));
    return vec4(lum, clamp(a, 0.0, 2.6), hl.y, 0.0);
}

// Hit test of hero rectangle i. Hero blocks carry the composition, so they
// keep a readable rectangular silhouette: hairline ends only scatter by a
// few px, mostly short of the edge (no bleeding hairlines, which on
// diagonal grain turned every edge hairy), and the dry-brush break-up at the
// downstream end stays inside. The wet pass softens the edges to 1-2 px.
// Returns the position along the grain (0..1), or -1 outside.
float heroHit(int i, vec2 uv, vec2 P) {
    const float M = 2.0 / REF_SIZE;
    vec4 r = RECT_BOX[i];
    if (any(lessThan(uv, r.xy - M)) || any(greaterThan(uv, r.zw + M))) return -1.0;
    float fi = float(i);
    vec2 d = vec2(cos(RECT_ANG[i]), sin(RECT_ANG[i]));
    vec2 c = 0.5 * (r.xy + r.zw);
    float line = floor(dot(P, vec2(-d.y, d.x)) / LINE_PX);
    float s = dot(uv - c, d);
    float j = HERO_FRAY * FRAY_PX * (hash12(vec2(line * 0.37 + fi, s > 0.0 ? 41.0 : 43.0)) - 0.75) / REF_SIZE;
    vec2 q = uv - d * sign(s) * j;
    if (any(lessThan(q, r.xy)) || any(greaterThan(q, r.zw))) return -1.0;
    vec2 hs = 0.5 * (r.zw - r.xy);
    float u = 0.5 + 0.5 * s / (abs(d.x) * hs.x + abs(d.y) * hs.y);
    float dash = hash12(vec2(line * 1.3 + fi, floor(dot(P, d) / mix(6.0, 26.0, hash11(line + fi)))));
    return dash < DRY_END * 0.4 * smoothstep(0.88, 1.0, u) ? -1.0 : u;
}

// Re-sort sweep through hero rectangle i at a pixel heroHit accepted (u
// along the grain): now and then a ragged front runs through the grain;
// behind it each hairline repeats the paint at its front (a pixel-sort
// band). Returns the shifted lookup point (px) and the band strength.
vec3 heroSweep(int i, float u, vec2 P) {
    if (ANIM <= 0.0) return vec3(P, 0.0);
    float fi = float(i);
    vec2 ev = loopEvent(HERO_SLOTS, 71.0 + fi * 3.1);
    float hs = hash12(vec2(fi * 1.7, ev.x + 3.0));
    if (hs >= HERO_P || ev.y >= SWEEP_DUR) return vec3(P, 0.0);
    vec4 r = RECT_BOX[i];
    vec2 d = vec2(cos(RECT_ANG[i]), sin(RECT_ANG[i]));
    float len = dot(abs(d), r.zw - r.xy) * REF_SIZE;   // length along the grain (px)
    float sg = fract(hs * 13.1) < 0.5 ? 1.0 : -1.0;
    float line = floor(dot(P, vec2(-d.y, d.x)) / LINE_PX);
    float sd = wipeFront(ev.y / SWEEP_DUR, line, fi + ev.x) - (sg > 0.0 ? u : 1.0 - u);
    if (sd <= 0.0 || sd >= SORT_BAND) return vec3(P, 0.0);
    return vec3(P + d * sg * sd * len, 1.0 - sd / SORT_BAND);
}

// Paint of field hero rectangle i: the lookup collapses onto the
// rectangle's own paint, plus its grain and long brush streaks. (Inside the
// rectangle the field returns the rectangle's colour, the topmost field
// rectangle winning, so the plain field lookup is the rectangle's paint.)
PaintJob heroPaint(int i, float u, vec2 P) {
    vec3 sw = heroSweep(i, u, P);
    vec2 Pq = sw.xy;
    float fi = float(i);
    vec4 r = RECT_BOX[i];
    float ang = RECT_ANG[i];
    vec2 d = vec2(cos(ang), sin(ang));
    PaintJob bp = noJob();
    bp.P = Pq;
    bp.ang = ang;
    bp.len = vec2(40.0, 300.0);
    bp.spread = RECT_GRAIN[i];
    bp.dark = 0.08;
    bp.seed = 23.0 + fi;
    // the lookup stays near the rectangle's centre, so it does not wander
    // into a neighbouring or overlapping rectangle (stripes of foreign paint)
    bp.p0 = 0.5 * (r.xy + r.zw) * 0.85 + Pq / REF_SIZE * 0.15;
    // the smear grain alone reads mottled on a flat rectangle: add streaks
    float lumF = barcode(Pq, d, fi + 0.5, RECT_GRAIN[i] * HERO_STREAK).x * (1.0 + HERO_GLOW * sw.z);
    vec2 dr = driftAt(Pq, d, fi * 5.0);
    bp.lumK = lumF * dr.x;
    bp.tilt = dr.y;
    bp.cover = FIXED_FAMILY + RECT_WARM[i] + 4.0 * dirIndex(ang);
#ifdef BLOCK_DEBUG
    bp.dbg = vec4(1.0, 1.0, 0.0, sw.z > 0.0 ? 1.0 : 0.0);
#endif
    return bp;
}

// Glaze hero rectangle i over col: long barcode lines, lighter toward the
// top; translucent per hairline over its own family, opaque over the other.
vec4 heroGlaze(int i, float u, vec2 uv, vec2 P, vec4 col) {
    vec3 sw = heroSweep(i, u, P);
#ifdef BLOCK_DEBUG
    if (sw.z > 0.0) return vec4(1.0, 1.0, 0.0, col.a);
#endif
    float meta = dirIndex(RECT_ANG[i]) + 4.0 * KIND_GLAZE;
    vec2 Pq = sw.xy;
    float fi = float(i);
    vec4 r = RECT_BOX[i];
    vec2 d = vec2(cos(RECT_ANG[i]), sin(RECT_ANG[i]));
    vec4 bc = barcode(Pq, d, fi, RECT_GRAIN[i]);
    float top = clamp((uv.y - r.y) / (r.w - r.y), 0.0, 1.0);
    bool grey = i == N_RECT - 2;
    // a few threads of the grey bar are umber: other family, so opaque
    bool umber = grey && bc.z < BAR_UMBER;
    vec3 gc = umber ? srgbToLinear(UMBER) : srgbToLinear(RECT_COL[i]) * (grey ? BAR_TINT : vec3(1.0));
    float lum = umber ? min(bc.x, 1.1) : bc.x * (1.0 + HERO_GLOW * sw.z) * mix(0.9, 1.3, top);
    gc = paintShade(gc, lum, driftAt(Pq, d, fi * 5.0));
    float fam = umber ? 1.0 : RECT_WARM[i];
    float w = mod(col.a, 2.0);   // col.a = warmth + 2 meta, see composite
    bool same = (fam > 0.5) == (w > 0.5);
    float ga = same ? GLAZE * bc.y : 1.0;
    return vec4(mix(col.rgb, gc, ga), (same ? w : fam) + 2.0 * meta);
}

// Lay one block (rgb, coverage; warmth bw) over the stack. Glazes (coverage
// < 1) stay translucent only over paint of the same family; warm over cool
// would mix to mud, so the block becomes opaque there.
// The stack's alpha is warmth + 2 x meta: the warmth (0..1) decides the
// family, meta = dirIndex + 4 x kind of the topmost paint is what the wet
// smear needs (wet.glsl). Both share one float, because one more value live
// across the grid loop tips the shader out of SIMD16.
void composite(inout vec4 col, vec4 b, float bw, float meta) {
    if (b.a <= 0.0) return;
    float w = mod(col.a, 2.0);
    bool same = (bw > 0.5) == (w > 0.5);
    float a = (b.a < 1.0 && same) ? b.a : 1.0;
    col = a < 1.0 ? vec4(mix(col.rgb, b.rgb, a), w + 2.0 * meta)
                  : vec4(b.rgb, clamp(bw, 0.0, 1.0) + 2.0 * meta);
}

// The four block grids, back to front: large, wide-flat, medium, tall bars.
const vec2 GRID_CELL[4] = vec2[](vec2(0.16, 0.22), vec2(0.21, 0.09), vec2(0.08, 0.13), vec2(0.075, 0.32));
const vec2 GRID_OFFS[4] = vec2[](vec2(0.03, 0.07), vec2(0.11, 0.02), vec2(0.05, 0.11), vec2(0.02, 0.05));

// Lay a finished paint job f (rgb + field warmth) of the given kind
// (KIND_*, wet.glsl) over the stack.
void layJob(inout vec4 col, PaintJob j, vec4 f, float kind) {
#ifdef BLOCK_DEBUG
    if (j.dbg.a > 0.0) f.rgb = j.dbg.rgb;
#endif
    float dir = floor(j.cover / 4.0);
    float cover = j.cover - 4.0 * dir;
    bool fixedFam = cover >= FIXED_FAMILY;
    composite(col, vec4(f.rgb, fixedFam ? 1.0 : cover), fixedFam ? cover - FIXED_FAMILY : f.a,
              dir + 4.0 * kind);
}

// L1 + L2: the background smear, then the four grids back to front, then
// the topmost hero field rectangle; the hero glazes go on top. Field
// rectangles are opaque, so only the topmost hit is painted. Returns the
// colour and, in .a, the grain direction and kind of the topmost paint
// (dirIndex + 4 x KIND_*, wet.glsl); with NO_BLOCKS only the background is painted.
vec4 layerPaint(vec2 uv, vec2 P) {
    PaintJob bj = layerSmear(uv, P);
    vec4 col = paintJob(bj, JOB_SMEAR);
    // warmth + 2 x meta (see composite); the background's grain direction
    // rides in its cover like the blocks' (KIND_SMEAR = 0)
    col.a = clamp(col.a, 0.0, 1.0) + 2.0 * floor(bj.cover / 4.0);
#ifndef NO_BLOCKS
    // one loop instead of four inlined copies keeps the shader small
    for (int k = 0; k < 4; k++) {
        PaintJob j;
        if (blockGrid(uv, P, GRID_CELL[k], GRID_OFFS[k], float(k + 1), j))
            layJob(col, j, paintJob(j, JOB_GRID), KIND_GRID);
    }

    // hit tests of the field rectangles (cheap)
    int hit = -1;
    float uh = 0.0;
    for (int i = 0; i < N_FIELD_RECT; i++) {
        float u = heroHit(i, uv, P);
        if (u >= 0.0) { hit = i; uh = u; }
    }
    if (hit >= 0) {
        PaintJob j = heroPaint(hit, uh, P);
        layJob(col, j, paintJob(j, JOB_HERO), KIND_HERO);
    }

    // the glazes (the rectangles after the field ones), topmost hit only
    int hitG = -1;
    float uG = 0.0;
    for (int i = N_FIELD_RECT; i < N_RECT; i++) {
        float u = heroHit(i, uv, P);
        if (u >= 0.0) { hitG = i; uG = u; }
    }
    if (hitG >= 0) col = heroGlaze(hitG, uG, uv, P, col);
#endif
    return vec4(col.rgb, floor(col.a * 0.5));
}
