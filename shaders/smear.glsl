// smear.glsl - L1: the smear operator and the background layer.
//
// A procedural pixel sort / line-integral smear. Each pixel asks "where did my
// paint come from?" and reads the base field there: it belongs to a thin line
// along the local smear direction, the line is cut into segments, and each
// segment holds the paint picked at one point of the field. Lines bundle into
// strands with shared phase and ragged, tapered ends (drips).
//
// Animation (layerSmear only): the paint flows. Every strand is a conveyor
// that carries its segments, hairline breaks and bristle texture downstream at
// its own speed, exactly one pattern period per loop. On top of that, drips
// grow out of the strands: a head advances from an origin, carrying the paint
// from the origin with a pointed tip, then the tail slides after it until the
// drip has run out. The composition holds, because every segment still picks
// its paint near where it is.

// ---- tunables ---------------------------------------------------------------
const float SRC_FRAC    = 0.72;   // where in a smear segment the paint is picked (0 tail, 1 head)
const float DRAG_MIN    = 0.55;   // minimum drag strength per segment (1 = flat hold)
const float TEX_GAIN    = 0.8;    // global strength of all streak brightness variation
const float DARK_LUM    = 0.78;   // brightness factor of a dark scratch (perceptual, cubed later)
const float SEAM_DITHER = 0.3;    // how far the warm/cool threshold wanders per hairline
const float THREAD_RED  = 0.16;   // share of hairline bundles in warm paint that turn red
const float LINE_GRAIN  = 0.9;    // hairline flicker relative to the strand variation
const float THREAD_SPREAD = 22.0; // hairlines read the field up to this far across the grain (px)
const float TAPER       = 0.22;   // length of a segment's pointed tip (fraction of the segment)
#ifndef HATCH_W
#define HATCH_W 0.35              // strand width of diagonal hatching, relative to drips
#endif
#ifndef STRAND_W
#define STRAND_W vec2(6.0, 36.0)  // strand (brush) width range in px
#endif
const float HATCH_DARK  = 0.8;    // brightness of a dark hatching stroke (perceptual)
const float RAGGED      = 0.25;   // per-line phase jitter inside a strand (ragged drip ends)
const float LINE_DRAG   = 0.5;    // per-line spread of the drag strength (comb-like strand ends)

// paint texture inside a strand (all relative to the strand variation)
const float SOFT_LINES  = 0.9;    // soft hairlines: smooth brightness ridges 2-5 px across
const float MOTTLE      = 1.6;    // dry-brush dashes: soft hairline dashes ~1 px across, 5-14 px along
const float DASH_EDGE   = 0.3;    // sharpness of the dash ends (1 = smooth, -> 0 = hard)
const float SKIP        = 1.8;    // bristle skips: short breaks across several lines
const float SKIP_RATE   = 0.16;   // share of skip cells that break
const float GRIT        = 0.5;    // residual 1 px grit (the old salt-and-pepper, kept faint)
const float TEX_FLOOR   = 0.06;   // strand variation for the texture terms above: minimum ...
const float TEX_CAP     = 0.20;   // ... and maximum
const float SKIP_CAP    = 0.14;   // skips stay faint in rough zones (no glitter)
const float SKIP_COOL   = 3.0;    // extra skip rate in the cool top (and the hatching)

// flow: each strand's texture repeats with a period of FLOW_PERIOD px (a whole
// number of its segments) and travels one period per loop
const vec2  FLOW_PERIOD = vec2(400.0, 1900.0); // -> 12.5 .. 60 px/s at LOOP = 32 s

// growing drips
const float DRIP_CELL   = 260.0;  // px along a strand per drip cell (a drip stays in its cell)
const float DRIP_SLOTS  = 4.0;    // drip life cycles per cell and loop
const float DRIP_ON     = 0.50;   // share of (strand, cell, slot) that drip
const vec2  DRIP_LEN    = vec2(50.0, 230.0); // run length of a drip (px)
const float DRIP_LUM    = 1.6;    // drip brightness offset, relative to the strand variation
const float DRIP_WET    = 0.10;   // wet highlight at the advancing head

// Apply a streak brightness factor. Warm paint does not turn brown when it
// gets darker: green and blue fall faster, so yellow darkens through orange
// toward red and brightens toward cream. Cool paint is scaled as is.
vec3 shade(vec3 c, float lum) {
    float warm = smoothstep(0.0, 0.15, c.r - c.b);
    vec3 e = mix(vec3(1.0), vec3(0.75, 1.3, 1.7), warm);
    return c * pow(vec3(lum), e);
}

// Red threads: a few hairline bundles inside warm paint turn vermilion/red,
// the way the reference has red threads running through its orange.
vec3 hueThread(vec3 c, float h) {
    float warm = step(c.b * 1.6, c.r);
    return mix(c, c * vec3(1.0, 0.45, 0.4), warm * h);
}

// Value noise in [0, 1] whose lattice repeats every `per` (integer) cells
// along y, so a texture scrolled by one period per loop is seamless.
// `edge` < 1 sharpens the steps along y (dash ends) while x stays smooth.
float pnoise(vec2 x, float per, float edge) {
    vec2 i = floor(x);
    vec2 f = fract(x);
    vec2 u = vec2(f.x * f.x * (3.0 - 2.0 * f.x), smoothstep(0.5 - 0.5 * edge, 0.5 + 0.5 * edge, f.y));
    float y0 = mod(i.y, per), y1 = mod(i.y + 1.0, per);
    float a = hash12(vec2(i.x, y0));
    float b = hash12(vec2(i.x + 1.0, y0));
    float c = hash12(vec2(i.x, y1));
    float d = hash12(vec2(i.x + 1.0, y1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float pnoise(vec2 x, float per) { return pnoise(x, per, 1.0); }

// 1D version: value noise in [0, 1] along x, period `per` (integer) cells.
float pnoise1(float x, float per, float seed) {
    float i = floor(x), f = fract(x);
    return mix(hash12(vec2(mod(i, per), seed)), hash12(vec2(mod(i + 1.0, per), seed)),
               f * f * (3.0 - 2.0 * f));
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
    float thr;  // warm/cool switch threshold of this hairline
    float hue;  // > 0: this hairline is a red thread in warm paint
};

// flow = 0: static (blocks use this); flow = 1: the paint runs (L1).
Smear smearFlow(vec2 P, float ang, vec2 len, float spread, float dark, float seed, float flow) {
    vec2 d = vec2(cos(ang), sin(ang));
    vec2 n = vec2(-d.y, d.x);
    float s = dot(P, d);
    float t = dot(P, n);

    // strands: bundles of 6-36 px (one "bristle brush" each) share the
    // segment length and phase, so neighbouring lines carry the same paint
    // (diagonal hatching uses thinner strands: fine lines, not planks)
    float W = mix(STRAND_W.x, STRAND_W.y, hash11(floor(t / 48.0) * 1.31 + seed)) * (abs(d.x * d.y) > 0.4 ? HATCH_W : 1.0);
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

    // flow direction along s: paint runs down (vertical and both diagonals)
    // and to the right (horizontal), whichever way the smear axis points
    float sgn = abs(d.y) > 0.3 ? -sign(d.y) : sign(d.x);
    // the strand's texture period: a whole number M of its segments; the
    // strand travels exactly one period per loop (seamless, own speed)
    float M = max(1.0, floor(mix(FLOW_PERIOD.x, FLOW_PERIOD.y, hash11(strand * 5.91 + seed * 3.3)) / L + 0.5));
    float Pd = M * L;
    float o = (hb.y + RAGGED * rough * (hl.x - 0.5)) * L - sgn * flow * loopScroll(1.0, Pd);
    float sid = floor((s + o) / L);
    float s0 = sid * L - o;

    // tapered tips: near the downstream end of a segment the strand's outer
    // lines are already cut, they still show the segment before it, so each
    // drip ends in a point instead of a flat edge
    float e = abs(fract(t / W) * 2.0 - 1.0);
    float cut = step(s - s0, TAPER * L * (e + 0.4 * (hl.y - 0.5)));
    sid -= cut;
    s0 -= cut * L;
    float sidm = mod(sid, M);

    float hseg = hash12(vec2(strand * 1.37 + seed, sidm));
    // per-line drag: the hairlines of one strand compress the field by
    // different amounts, so a strand crosses a colour boundary as a comb of
    // hairlines of different lengths, not as one flat plank end
    float hk = hash12(vec2(line * 1.91 + seed, sidm));
    float k = mix(DRAG_MIN, 1.0, hseg) * (1.0 - LINE_DRAG * hk * hk);
    float sq = mix(s, s0 + L * SRC_FRAC, k);

    // along-strand coordinate that travels with the paint, wrapped to the
    // strand period: every texture below is periodic in it
    float fs = mod(s + o, Pd);

    // ---- growing drips -----------------------------------------------------
    // A drip cell (fixed along the strand) holds one drip per event slot. The
    // drip starts at a hashed origin, its head runs downstream with a pointed,
    // ragged tip, the tail follows until the drip has run out. Inside the
    // drip the paint is the one picked at the origin, so colour is carried
    // across the boundaries it runs over. A drip never leaves its cell, so
    // one cell test per pixel is enough (and keeps the shader cheap).
    float drip = 0.0, dripLum = 0.0;
    if (flow * ANIM > 0.0) {
        float cid = floor(s / DRIP_CELL);
        vec2 ev = loopEvent(DRIP_SLOTS, hash12(vec2(strand * 0.71 + seed, cid)) * 61.0);
        vec3 hd = hash33(vec3(strand + seed * 13.0, cid, ev.x));
        float Lm = mix(DRIP_LEN.x, DRIP_LEN.y, hd.z);
        // origin: the drip's run [0, Lm] downstream of it stays inside the cell
        float so = cid * DRIP_CELL + hd.y * (DRIP_CELL - Lm) + (sgn < 0.0 ? Lm : 0.0);
        float head = Lm * smoothstep(0.0, 0.8, ev.y);
        float tail = Lm * smoothstep(0.5, 1.0, ev.y);
        float x = sgn * (s - so);                         // distance run downstream
        float wf = mix(0.45, 1.0, fract(hd.y * 7.7));     // drip width (share of strand)
        // pointed tip: outer lines lag behind the centre line
        float tip = min(head, 50.0) * (e / wf + RAGGED * (hl.y - 0.5));
        // (branchless: a divergent branch here costs several ms on the GPU)
        drip = step(hd.x, DRIP_ON) * step(e, wf) * step(tail, x) * step(x, head - tip);
        sq = mix(sq, so - sgn * 4.0, drip);               // paint from the origin
        fs = mix(fs, mod(x - head, Pd), drip);            // texture travels with the head
        hseg = mix(hseg, 0.5, drip);
        dripLum = drip * (DRIP_LUM * (fract(hd.z * 13.1) - 0.5) * 2.0
                + DRIP_WET / max(spread, 0.02) * (1.0 - smoothstep(0.0, 6.0, head - tip - x)));
    }

    spread *= TEX_GAIN;

    // ---- brightness: the paint texture of the strand -----------------------
    // (each term is folded into its sum as soon as it is known, and the
    // per-segment factors come first: few values stay live, which keeps the
    // shader within the SIMD16 register budget)
    // dark scratches run the length of a strand segment (long drips); they
    // are soft hairlines 1.5-3 px wide with a bell profile, one per 6 px cell
    float dc = floor(t / 6.0);
    vec3 hdk = hash33(vec3(dc + seed * 5.0, sidm, strand));
    float dx = (t - (dc + 0.2 + 0.6 * hdk.y) * 6.0) / mix(0.7, 1.5, hdk.z);
    float dprof = exp(-dx * dx);
    float darkF = hdk.x < 1.6 * dark * rough * (1.0 - drip) ? mix(1.0, DARK_LUM, dprof) : 1.0;
    // in hatching zones (dark > 0.08) whole strands can be dark brush strokes
    float hatchF = fract(hseg * 7.31) < (dark - 0.08) * 3.0 ? HATCH_DARK : 1.0;

    // the lookup point is settled here, so the axis and the segment are done
    // with: each hairline also reads the field slightly beside its strand,
    // so at a colour boundary threads of both colours interleave
    float tq = t + (hl.y - 0.5) * THREAD_SPREAD * rough;
    Smear r;
    r.q = d * sq + n * tq;
    float hb2 = hash11(floor(tq / mix(2.0, 4.0, hb.y)) * 3.71 + seed);

    // hairlines with their own, shorter segments (many starts and ends = the
    // fine streak texture), on top of a per-strand level and broad bands
    // across the grain
    float Ll = mix(8.0, 90.0, hl.x * hl.x);
    float Nl = max(1.0, floor(Pd / Ll + 0.5));
    float lid = mod(floor(fs * Nl / Pd + hl.y), Nl);
    float hline = hash12(vec2(line * 0.73 + seed, lid));
    float band = noise(vec2(t / 18.0, s / 600.0 + seed)) - 0.5;
    float strandVar = 0.9 * (hseg - 0.5) + 0.8 * band + LINE_GRAIN * (hline - 0.5) + dripLum;
    // soft hairlines: smooth brightness ridges across the grain (2-5 px)
    // that break every 20-60 px along it - paint, not pixels
    float sw = mix(2.0, 5.0, hb.y);
    float sn = max(1.0, floor(Pd / mix(20.0, 60.0, hl.x) + 0.5));
    float soft = pnoise(vec2(t / sw + seed * 5.0, fs * sn / Pd), sn) - 0.5;
    // dry-brush dashes: soft hairline dashes ~1 px across, 5-14 px along
    float mn = max(1.0, floor(Pd / mix(5.0, 14.0, hb.x) + 0.5));
    float mott = pnoise(vec2(t / 1.2 + seed * 3.0, fs * mn / Pd), mn, DASH_EDGE) - 0.5;
    float texVar = SOFT_LINES * soft + MOTTLE * mott;
    // bristle skips: short breaks 2-3 px along the grain that cut across
    // 2-5 px of lines at once (cross-grain variation), with soft edges
    float kn = max(1.0, floor(Pd / mix(2.0, 3.0, hb.y) + 0.5));
    float kw = mix(2.0, 5.0, hb.x);
    vec2 kp = vec2(t / kw, fs * kn / Pd);
    float kh = hash12(vec2(floor(kp.x) * 1.9 + seed, mod(floor(kp.y), kn)));
    vec2 kf = sin(PI * fract(kp));
    // (the cool top, dark > DARK_LINES, breaks more often: the reference's
    // ice and steel drips are dry-brushed, with many short breaks across)
    float skip = kh < SKIP_RATE * (1.0 + SKIP_COOL * smoothstep(0.05, 0.10, dark))
               ? (fract(kh * 31.7) > 0.4 ? -1.0 : 0.7) * sqrt(kf.x * kf.y) : 0.0;
    // residual grit: 1 px wide dashes, faint
    float gn = max(1.0, floor(Pd / mix(2.0, 6.0, hl.x) + 0.5));
    float grit = hash12(vec2(floor(t) * 2.1 + seed, mod(floor(fs * gn / Pd), gn))) - 0.5;

    float tex = clamp(spread, TEX_FLOOR, TEX_CAP);
    float lum = 1.0 + spread * strandVar + tex * (texVar + GRIT * grit)
                    + min(tex, SKIP_CAP) * SKIP * skip;
    lum *= darkF;
    lum *= hatchF;
    // lum is a factor on perceptual lightness (~ cube root of linear), so a
    // streak reads equally strong on navy and on yellow
    lum = max(lum, 0.2);
    lum = lum * lum * lum;

    r.lum = lum;
    // the warm/cool threshold wanders along each hairline, so where the two
    // families meet they alternate thread by thread instead of along one edge
    // (it travels with the paint, so the threads stream through the seam)
    float tnn = max(1.0, floor(Pd / mix(10.0, 60.0, hl.y) + 0.5));
    float tn = pnoise1(fs * tnn / Pd, tnn, hl.x * 50.0) - 0.5;
    r.thr = clamp(0.5 + SEAM_DITHER * tn, 0.08, 0.92);
    // red threads come and go along their length (30-90 px pieces)
    float rn = max(1.0, floor(Pd / mix(30.0, 90.0, fract(hb2 * 7.3)) + 0.5));
    float rOn = smoothstep(0.35, 0.6, pnoise1(fs * rn / Pd, rn, hb2 * 40.0));
    r.hue = step(1.0 - THREAD_RED, hb2) * mix(0.5, 1.0, fract(hb2 * 13.0)) * rOn;
    return r;
}

// ---- paint jobs ---------------------------------------------------------------
// The background (L1), the grid blocks and the hero blocks (L2) all paint the
// same way: a smear, a field lookup at the smeared point, a brightness and
// drift on the result. They only differ in their parameters, so the layers
// fill in a PaintJob and paintJob() runs the two expensive lookups
// (blocks.glsl: layerPaint calls it for the background, once inside the grid
// loop and once for the hero block).
// Register pressure: Mesa only builds the SIMD16 shader (about 1.5-2x faster
// than SIMD8 here) if a quick estimate of the values live at once stays
// under its limit, and the smear is where that peaks. Every job value that
// is still needed after the smear stays live across it, so the job carries
// as few of them as possible. Everything that only depends on the kind of
// job follows from `kind`, a compile-time constant at each call site, so each
// copy of paintJob() only contains what its kind needs (no drips in blocks).
const int   JOB_SMEAR    = 0;    // L1 background: flowing paint, field read at the smeared point
const int   JOB_GRID     = 1;    // grid block: field read at p0 + GRID_Q x the smeared point
const int   JOB_HERO     = 2;    // hero block: field read at p0 + HERO_Q x the smear offset,
                                 // softer grain (smear brightness ^ HERO_LUM_POW)
const float GRID_Q       = 0.6;  // compression of the smeared point into the field (blocks)
const float HERO_Q       = 0.25;
const float HERO_LUM_POW = 0.6;
const float FIXED_FAMILY = 2.0;  // cover >= FIXED_FAMILY: opaque, family = cover - FIXED_FAMILY

struct PaintJob {
    vec2  P;       // smear position (reference px)
    float ang;     // smear / grain angle
    vec2  len;     // segment length range (px)
    float spread;  // streak contrast
    float dark;    // share of dark scratches
    float seed;    // smear seed
    vec2  p0;      // field lookup origin (uv), see kind
    float lumK;    // brightness factor on top of the smear brightness (incl. drift)
    float tilt;    // hue tilt of the drift (blocks.glsl: driftAt().y)
    float cover;   // < 1: glaze opacity over its own family, 1: opaque, both with
                   // the family of the field paint; >= FIXED_FAMILY: see above;
                   // plus 4 x the grain's dirIndex (wet.glsl), which rides here
                   // because cover is live across the smear anyway (SIMD16)
#ifdef BLOCK_DEBUG
    vec4  dbg;     // debug colour, shown where .a > 0
#endif
};

// An empty job. Every job starts from this: a field left unwritten on some
// path (e.g. an early return of blockGrid) would be carried over from the
// previous iteration of the grid loop and stay live across the whole loop,
// which is enough to tip the shader out of SIMD16.
PaintJob noJob() {
    PaintJob j;
    j.P = vec2(0.0);
    j.ang = 0.0;
    j.len = vec2(0.0);
    j.spread = 0.0;
    j.dark = 0.0;
    j.seed = 0.0;
    j.p0 = vec2(0.0);
    j.lumK = 1.0;
    j.tilt = 0.0;
    j.cover = 1.0;
#ifdef BLOCK_DEBUG
    j.dbg = vec4(0.0);
#endif
    return j;
}

// Apply a streak brightness lum and the drift dr (blocks.glsl: driftAt) to
// paint c: lightness plus a hue tilt that stays inside the paint's family.
vec3 paintShade(vec3 c, float lum, vec2 dr) {
    c = shade(c, lum * dr.x);
    return c * vec3(1.0, 1.0 + 2.0 * dr.y, 1.0 + dr.y * (c.b > c.r ? 1.0 : -1.0));
}

// Run a paint job of the given kind: rgb + warmth. Flowing paint (L1) reads
// the field with its per-hairline warm/cool threshold and carries red
// threads; static paint (blocks) uses the neutral switch.
vec4 paintJob(PaintJob j, int kind) {
    bool flowing = kind == JOB_SMEAR, hero = kind == JOB_HERO;
    Smear sm = smearFlow(j.P, j.ang, j.len, j.spread, j.dark, j.seed, flowing ? 1.0 : 0.0);
    vec2 q = flowing ? sm.q / REF_SIZE
           : j.p0 + (hero ? (sm.q - j.P) / REF_SIZE * HERO_Q : sm.q / REF_SIZE * GRID_Q);
    // only the hero itself sees its rectangle in BG_SKIP (field.glsl); the
    // background and the grid blocks around it read the field without it
    vec4 f = baseField(q, (flowing ? sm.thr : 0.5) + (hero ? 0.0 : FIELD_BG));
    float lum = (hero ? pow(sm.lum, HERO_LUM_POW) : sm.lum) * j.lumK;
    f.rgb = paintShade(hueThread(f.rgb, flowing ? sm.hue : 0.0), lum, vec2(1.0, j.tilt));
    return f;
}

// ---- L1: background smear ---------------------------------------------------
// The paint job of the background: the lookup dragged along the direction
// field, flowing.
PaintJob layerSmear(vec2 uv, vec2 P) {
    PaintJob j = noJob();
    directionField(uv, j.ang, j.len, j.spread, j.dark);
    j.P = P;
    j.seed = 1.0;
    j.cover = 1.0 + 4.0 * dirIndex(j.ang);   // opaque, plus the grain direction
    return j;     // the rest as in noJob(): no drift
}
