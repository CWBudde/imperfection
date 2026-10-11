// accents.glsl - L3: dark accents and red paint painted over the blocks.
//
// Everything here is either a dark glaze (wedge, soot), ink drawn into wet
// paint (seam scratches) or red paint under the band: drips running off its
// lower edge and dry-brush flecks scraped into the soot (they replace the old
// 2 px specks). Directions follow the four fundamental angles: the wedge
// strokes run at 45 deg, scratches and drips at 90 deg, soot grain and
// flecks at 0 deg.
//
// Animation (docs/animation.md): the wedge edge breathes across and its
// strokes slide along 45 deg; the soot grain drifts sideways along 0 deg; the
// ink scratches are drawn top-down, hold and fade, one life per event slot;
// red drips run out of the band, slow down, hold and dry; flecks are brushed
// in left to right and ride the soot drift. All patterns that
// scroll are periodic in their scroll distance, so the loop is seamless.

#ifndef ACC_RED
#define ACC_RED 3 // red element under the band: 0 none, 1 drips, 2 dry-brush flecks, 3 both
#endif

// ---- wedge ----
const vec2  WEDGE_PT    = vec2(0.80, 0.675); // a point on the 45 deg wedge edge (uv)
const float WEDGE_LANE  = 3.0;    // width of one brush lane across the edge (reference px)
const float WEDGE_SEG   = 72.0;   // mean stroke segment length along the edge (reference px)
const float WEDGE_NSEG  = 8.0;    // segments per lane period (the lane pattern repeats after this)
const float WEDGE_FRAY  = 0.035;  // how far single dark strokes reach out of the wedge (uv)
const float WEDGE_BREATH = 0.010; // edge breathing amplitude across the edge (uv)
const float WEDGE_INK   = 0.92;   // opacity of the dark wedge paint

// ---- soot ----
const float SOOT_TOP    = 0.342;  // shadow strip under the red band: mean top edge (v)
const float SOOT_BOT    = 0.290;  // mean bottom edge (v)
const float SOOT_SCRAPE = 0.4;    // extra show-through in the scraped rows
const float SOOT_PERIOD = 512.0;  // sideways repeat of the soot pattern = drift per cycle (px)

// ---- ink scratches ----
const vec2  SCRATCH_CELL = vec2(10.0, 120.0); // ink scratch grid (reference px): across, along
const float SCRATCH_DENS = 0.62;  // share of cells holding a scratch (inside the seam zones)
const float SCRATCH_SLOTS = 1.0;  // lives per loop and cell
const float SCRATCH_GROW = 0.12;  // part of a life spent drawing the scratch
const float SCRATCH_FADE = 0.75;  // part of a life after which the ink fades
const float SCRATCH_BROAD = 0.4;  // share of broad dry-brush smudges among the scratches

// ---- red drips ----
const float DRIP_COL    = 7.0;    // one possible drip per column this wide (reference px)
const float DRIP_DENS   = 0.5;    // share of columns dripping per event slot
const float RED_DRIP_SLOTS  = 3.0;    // drips per loop and column
const float DRIP_RUN    = 0.45;   // part of a life the drip is running
const float DRIP_DRY    = 0.78;   // part of a life after which it dries away
const vec2  DRIP_U      = vec2(0.49, 0.76); // u range of the dripping band edge

// ---- dry-brush flecks (ACC_RED 2/3) ----
const vec2  FLECK_CELL  = vec2(32.0, 3.0); // fleck grid (reference px): along (tiles SOOT_PERIOD), across
const float FLECK_DENS  = 0.5;    // share of fleck cells holding a dash (at full cluster)
const float FLECK_TOP   = 0.312;  // flecks stay below this (v), the drips hang above
const float FLECK_SLOTS = 1.0;    // lives per loop and cell
const float FLECK_GROW  = 0.06;   // part of a life spent brushing the dash in
const float FLECK_FADE  = 0.80;   // part of a life after which it fades

// ---- helpers ----------------------------------------------------------------
// 1D value noise in [0, 1], periodic with n lattice cells, decorrelated by seed.
float accNoiseP(float x, float n, float seed) {
    float i = floor(x), f = fract(x);
    float a = hash11(mod(i, n) + seed);
    float b = hash11(mod(i + 1.0, n) + seed);
    return mix(a, b, f * f * (3.0 - 2.0 * f));
}

// ---- wedge ------------------------------------------------------------------
// Upper right: everything right of a 45 deg line through WEDGE_PT sinks into
// blue-black. The edge is brushed: lanes of dark strokes along 45 deg reach
// out of the wedge by a hashed amount, with ragged ends. The strokes slide
// along their lane and the whole edge breathes across.
vec3 layerWedge(vec2 uv, vec2 P, vec3 col) {
    const vec2 dir = vec2(0.70710678, 0.70710678);   // along the edge, 45 deg
    vec2 nrm = vec2(dir.y, -dir.x);                  // points into the wedge
    float vm = smoothstep(0.46, 0.56, uv.y) * (1.0 - smoothstep(0.90, 0.97, uv.y));
    if (vm <= 0.0) return col;
    float b = dot(P, nrm);
    float lane = floor(b / WEDGE_LANE);
    float hl = hash11(lane * 1.37 + 5.0);
    float d = dot(uv - WEDGE_PT, nrm)
            + WEDGE_BREATH * loopNoise(3.0, 2.0)               // whole edge breathes
            + 0.004 * loopNoise(lane * 0.37 + 9.0, 3.0)        // single lanes waver
            + (noise1(b / 9.0) - 0.5) * 0.02;                  // slow wander across lanes
    if (d < -WEDGE_FRAY - 0.01) return col;

    // stroke segments of this lane, sliding along 45 deg (1-2 lane periods per loop)
    float per = WEDGE_SEG * WEDGE_NSEG;
    float a = dot(P, dir) + loopScroll(1.0 + floor(hl * 2.0), per) + hl * per;
    float k = floor(a / WEDGE_SEG);
    float f = fract(a / WEDGE_SEG);
    vec3 hs = hash33(vec3(mod(k, WEDGE_NSEG), lane, 3.3));
    // ragged ends, soft over a few px
    float ext = smoothstep(hs.y * 0.35, hs.y * 0.35 + 0.06, f)
              * (1.0 - smoothstep(1.0 - hs.z * 0.35 - 0.06, 1.0 - hs.z * 0.35, f));
    // the lane is a bundle of 1.2 px bristles: each reaches its own distance
    // and carries its own load, so the stroke frays into hairlines
    float bi = floor(b / 1.2);
    float hb = hash11(bi * 1.37);
    float reach = WEDGE_FRAY * hs.x * hs.x * mix(0.4, 1.3, fract(hb * 7.9));
    float stroke = ext * step(-d, reach) * step(0.3, hb) * mix(0.45, 1.0, hb)
                 * mix(1.0, 0.5, smoothstep(0.0, WEDGE_FRAY, -d));
    // solid inside, with a few dry lanes letting the blue through near the edge
    float inside = smoothstep(-0.006, 0.012, d) * mix(1.0, 0.6, ext * step(0.8, hs.x) * (1.0 - smoothstep(0.0, 0.05, d)));
    float z = max(inside, stroke) * vm;
    if (z <= 0.0) return col;
    // the dark paint keeps a fine 45 deg grain (the same bristles)
    float g = hb - 0.5;
    vec3 ink = hexColor(0x03080f) * (1.0 + 0.7 * g);
    return mix(col, ink, WEDGE_INK * z);
}

// ---- soot -------------------------------------------------------------------
// Top edge of the soot strip (v) at reference column x, drifting sideways.
float sootTop(float x) {
    float xs = x + loopScroll(1.0, SOOT_PERIOD);
    float hc = hash11(mod(floor(xs), SOOT_PERIOD));
    // long, low swells (the strip stays a horizontal band) and a little
    // per-column fray
    return SOOT_TOP + (accNoiseP(xs / 64.0, SOOT_PERIOD / 64.0, 1.0) - 0.5) * 0.022
                    + (hc - 0.5) * 0.006;
}

// Near-black horizontal strip under the red band. Its edges wander with a
// little per-column fray; inside, horizontal grain whose rows drift sideways
// at slightly different speeds, so the soot seems to be wiped along.
vec3 layerSoot(vec2 uv, vec2 P, vec3 col) {
    float xs = P.x + loopScroll(1.0, SOOT_PERIOD);
    float top = sootTop(P.x);
    float hc = hash11(mod(floor(xs), SOOT_PERIOD) + 0.5);
    float bot = SOOT_BOT + (accNoiseP(xs / 64.0, SOOT_PERIOD / 64.0, 7.0) - 0.5) * 0.026
                         + (hc - 0.5) * 0.008;
    float zx = smoothstep(0.42, 0.50, uv.x);
    if (uv.y < bot || uv.y > top || zx <= 0.0) return col;
    float row = floor(P.y / 1.5);
    float hr = hash11(row * 3.1);
    // per-row grain period 8..64 px (power of two, so it tiles SOOT_PERIOD)
    float L = exp2(3.0 + floor(hr * 4.0));
    float xr = P.x + loopScroll(1.0 + floor(fract(hr * 7.3) * 2.0), SOOT_PERIOD);
    float g = accNoiseP(xr / L + hash11(row) * 50.0, SOOT_PERIOD / L, row * 0.71);
    vec3 soot = hexColor(0x0c0709) * (0.5 + 1.1 * g);
    // the grain lets the paint beneath show through in horizontal scrapes;
    // some rows are scraped thinner than others
    float thin = SOOT_SCRAPE * step(0.7, fract(hr * 13.7));
    return mix(col, soot, zx * mix(0.6 - thin, 0.94, smoothstep(0.3, 0.7, g)));
}

// ---- ink scratches ----------------------------------------------------------
// Dark ink drawn down the hot/cold seams: between the yellow core and the ice
// column, the ice column's right flank, and under the red band. Each cell of
// a vertical grid holds at most one scratch per event slot; the 3x3
// neighbourhood is searched for the frontmost one. A scratch is drawn top
// down with a pointed, growing tip, holds, then fades into the paint.
float zoneSeam(vec2 uv) {
    float z = box(uv, vec2(0.40, 0.50), vec2(0.47, 0.80), 0.02);
    z = max(z, box(uv, vec2(0.55, 0.55), vec2(0.66, 0.80), 0.03));
    z = max(z, box(uv, vec2(0.45, 0.12), vec2(0.62, 0.34), 0.03));
    return z;
}

// Dry ink inside a stroke. The stroke is a bundle of 1 px bristles, each
// with its own ink load, broken into short dashes along its length (2-6 px):
// where the envelope is strong the dashes merge into a solid line, toward the
// edges and the dry tail they fall apart into vertical flecks.
//   t   across the stroke in [-0.5, 0.5], s along in [0, 1] (0 = top)
//   dry 0 = wet, solid ink; 1 = very dry, sparse flecks
float inkDry(vec2 P, float t, float s, float seed, float dry) {
    float bh = hash12(vec2(floor(P.x), seed));
    float dl = mix(2.0, 6.0, fract(bh * 7.7));
    float dash = hash12(vec2(floor(P.x) * 1.7 + seed, floor(P.y / dl + bh * 5.0)));
    // each bristle touches down a little later: ragged top instead of a cut
    float start = smoothstep(0.0, 0.04 + 0.1 * fract(bh * 3.1), s);
    float env = (1.0 - smoothstep(0.18, 0.5, abs(t))) * mix(1.0, 0.55, smoothstep(0.45, 1.0, s)) * start;
    float v = env * mix(0.6, 1.0, bh) + (dash - 0.5) * mix(0.3, 0.9, dry);
    return smoothstep(0.25 + 0.3 * dry, 0.45 + 0.3 * dry, v);
}

vec3 layerScratches(vec2 uv, vec2 P, vec3 col) {
    float z = zoneSeam(uv);
    if (z < 0.01) return col;
    float density = SCRATCH_DENS * z;
    vec2 cell = SCRATCH_CELL;
    vec2 gi = floor(P / cell);
    float best = -1.0, cov = 0.0, wash = 0.0;
    for (int j = 0; j <= 2; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 c = gi + vec2(i, j);
        // whether a cell holds ink is fixed; each life re-rolls the stroke
        vec3 h2 = hash33(vec3(c + 3.7, 22.2));
        if (h2.z > density) continue;
        vec2 ev = loopEvent(SCRATCH_SLOTS, h2.z * 61.0);
        vec3 h = hash33(vec3(c, 13.0 + ev.x * 7.31));
        if (h.z <= best) continue;
        h2.xy = fract(h2.xy + h.yx * ev.x);
        // life: drawn top down (ease out), hold, fade; -D ANIM=0 shows it whole
        float gr = clamp(ev.y / SCRATCH_GROW, 0.0, 1.0);
        float grow = mix(1.0, 1.0 - (1.0 - gr) * (1.0 - gr), ANIM);
        float fade = 1.0 - ANIM * smoothstep(SCRATCH_FADE, 1.0, ev.y);
        float x0 = (c.x + 0.5 + (h.x - 0.5) * 0.8) * cell.x;
        float top = (c.y + h.y) * cell.y;
        float len = mix(0.5, 2.0, h2.x) * cell.y;
        float s = (top - P.y) / len;                 // 0 at the top, 1 at the bottom
        if (s < 0.0 || s > grow) continue;
        // pen lines (wet, narrow) or broad dry-brush smudges
        float broad = step(1.0 - SCRATCH_BROAD, h2.y);
        float hw = fract(h2.y * 9.7);
        float wpx = mix(mix(1.8, 3.6, hw), mix(8.0, 17.0, hw), broad);
        // ink load at the top, pointed at the bottom and at the growing front
        float w = wpx * mix(1.15, 0.5, smoothstep(0.55, 1.0, s))
                      * (0.75 + 0.5 * noise1(P.y / 9.0 + h.x * 70.0))  // pressure wavers
                      * mix(0.3, 1.0, smoothstep(0.0, 0.08, grow - s));
        float t = (P.x - x0) / w;
        if (abs(t) >= 0.5) continue;
        best = h.z;
        float dry = mix(0.28, 0.65, broad) + 0.3 * smoothstep(0.4, 1.0, s);
        cov = inkDry(P, t, s, h.z * 29.0, dry) * mix(0.95, 0.85, broad) * fade;
        // broad strokes leave a thin wash of diluted ink between the bristles
        wash = broad * (1.0 - smoothstep(0.05, 0.5, abs(t))) * 0.22 * fade
             * smoothstep(0.0, 0.15, s) * (1.0 - smoothstep(0.6, 1.0, s));
    }
    // ink is tinted by what lies beneath: navy-black or red-black. It takes
    // poorly on light warm paint (the reference keeps its yellow clean).
    float warmC = smoothstep(0.0, 0.1, col.r - col.b);
    vec3 ink = mix(hexColor(0x050c18), hexColor(0x12060a), warmC) + col * 0.05;
    float warmLight = smoothstep(0.05, 0.25, col.r - col.b) * smoothstep(0.2, 0.5, col.g);
    cov *= 1.0 - 0.9 * warmLight;
    // coverage is perceptual: blend in linear light with a gamma-shaped
    // weight, so half-loaded bristles read half dark, not barely dark
    col = mix(col, ink, 1.0 - pow(1.0 - wash * (1.0 - warmLight), 2.2));
    return mix(col, ink, 1.0 - pow(1.0 - cov * 0.95, 2.2));
}

// ---- red drips --------------------------------------------------------------
// Crimson runs out of the red band's lower edge into the soot: thin vertical
// threads that end in a heavier, elongated bead. Each drip column holds at
// most one drip per event slot: it leaves the band edge, runs down and slows,
// holds, then dries (sinks to maroon and into the soot). Most drips are a
// short fringe; a few become long runners.
vec3 layerRedDrips(vec2 uv, vec2 P, vec3 col) {
    if (uv.x < DRIP_U.x - 0.02 || uv.x > DRIP_U.y + 0.02
        || uv.y > SOOT_TOP + 0.04 || uv.y < SOOT_BOT - 0.05) return col;
    float ci = floor(P.x / DRIP_COL);
    vec2 ev = loopEvent(RED_DRIP_SLOTS, ci * 1.71 + 11.0);
    vec3 h = hash33(vec3(ci, ev.x, 41.0));
    vec3 h2 = hash33(vec3(ci, ev.x, 77.0));
    float zone = smoothstep(DRIP_U.x, DRIP_U.x + 0.03, uv.x) * (1.0 - smoothstep(DRIP_U.y - 0.04, DRIP_U.y, uv.x));
    // drips come in groups, and the groups move on with every slot
    float group = smoothstep(0.3, 0.7, noise1(ci * DRIP_COL / 50.0 + ev.x * 17.3 + 4.0));
    if (h.z > DRIP_DENS * zone * group) return col;
    float x0 = (ci + 0.5 + (h.x - 0.5) * 0.45) * DRIP_COL;
    // the band edge itself does not move (the soot drifts over it)
    float top = (SOOT_TOP + 0.010 + (noise1(x0 / 40.0) - 0.5) * 0.016) * REF_SIZE + (h2.z - 0.5) * 6.0;
    float L = mix(7.0, 46.0, pow(h.y, 2.5));          // final length (px), stays above the flecks
    float r = clamp(ev.y / DRIP_RUN, 0.0, 1.0);
    float run = L * mix(1.0, 1.0 - pow(1.0 - r, 2.5), ANIM);
    float dry = ANIM * smoothstep(DRIP_DRY, 1.0, ev.y);
    float y = top - P.y;                              // distance below the start
    float wT = mix(1.0, 2.6, h2.x * h2.x);            // thread width (px)
    float bl = 3.5 * wT;                              // bead length (px)
    if (y < -1.0 || y > run + 0.5 * bl) return col;
    // the thread thins as it runs and wavers in width; it pools at the
    // band edge and ends in an elongated bead (vertical, never round)
    float wob = 1.0 + 0.3 * (noise1(y / 5.0 + h.x * 40.0) - 0.5);
    float w = wT * wob * mix(1.0, 0.6, clamp(y / max(run, 1.0), 0.0, 1.0))
            * (1.0 + 0.8 * (1.0 - smoothstep(0.0, 7.0, y)));
    float bead = smoothstep(run - 1.4 * bl, run - 0.35 * bl, y) * (1.0 - smoothstep(run - 0.1 * bl, run + 0.5 * bl, y));
    w = max(w * step(y, run), wT * 1.45 * bead * smoothstep(5.0, 12.0, run));
    float dx = abs(P.x + 0.5 - x0);                   // sub-pixel centre of the thread
    float cov = 1.0 - smoothstep(0.5 * w - 0.6, 0.5 * w + 0.6, dx);
    if (cov <= 0.0) return col;
    // matte crimson: deeper at the thread's edges and in the thin run,
    // fullest in the pool and the bead; drying sinks it to maroon
    vec3 red = mix(hexColor(0x8e1214), hexColor(0xc8261c), h2.y);
    float body = max(bead, 1.0 - smoothstep(0.0, 8.0, y));
    red *= mix(0.6, 1.0, max(body, 1.0 - dx / max(0.5 * w, 0.5))) * mix(0.8, 1.0, body);
    red = mix(red, hexColor(0x3a0a10), 0.7 * dry);
    // paint thins toward the top, so the band edge melts into the run
    float a = mix(0.55, 0.92, smoothstep(0.0, 6.0, y)) * (1.0 - 0.85 * dry);
    return mix(col, red, cov * a);
}

// ---- dry-brush flecks -------------------------------------------------------
// Short horizontal dashes of dry crimson along the soot grain, clustered and
// thickest near the band. They ride the soot's sideways drift, are brushed
// in left to right and fade, one per cell and event slot.
vec3 layerRedFlecks(vec2 uv, vec2 P, vec3 col) {
    float zone = box(uv, vec2(0.49, SOOT_BOT - 0.01), vec2(0.75, FLECK_TOP), 0.008);
    if (zone <= 0.0) return col;
    float drift = loopScroll(1.0, SOOT_PERIOD);
    vec2 Q = vec2(P.x + drift, P.y);
    vec2 gi = floor(Q / FLECK_CELL);
    float nc = SOOT_PERIOD / FLECK_CELL.x;           // cells per drift period
    // nearer the band = more red
    float near = mix(0.5, 1.0, smoothstep(SOOT_BOT - 0.01, FLECK_TOP, uv.y));
    float cov = 0.0;
    vec3 red = vec3(0.0);
    for (int i = -1; i <= 0; i++) {
        vec2 c = vec2(mod(gi.x + float(i), nc), gi.y);
        vec2 ev = loopEvent(FLECK_SLOTS, hash12(c + 9.0) * 53.0);
        vec3 h = hash33(vec3(c, 5.0 + ev.x * 3.1));
        float cluster = smoothstep(0.4, 0.75, accNoiseP(c.x * FLECK_CELL.x / 48.0, SOOT_PERIOD / 48.0, c.y * 0.37));
        if (h.z > FLECK_DENS * cluster * zone * near) continue;
        float x0 = (gi.x + float(i) + h.x * 0.6) * FLECK_CELL.x;
        float len = mix(10.0, 40.0, h.y);
        float grow = mix(1.0, smoothstep(0.0, FLECK_GROW, ev.y), ANIM);
        float fade = 1.0 - ANIM * smoothstep(FLECK_FADE, 1.0, ev.y);
        float sx = (Q.x - x0) / len;
        if (sx < 0.0 || sx > grow) continue;
        float hy = mix(1.5, 3.0, fract(h.z * 17.0));
        float yc = (c.y + 0.5) * FLECK_CELL.y + (fract(h.z * 31.0) - 0.5) * 1.5;
        float ty = (Q.y - yc) / hy;
        if (abs(ty) > 0.5) continue;
        // 1 px bristles across, each breaking into dashes along the stroke;
        // the stroke starts loaded and runs dry to the right
        float bi = floor(Q.y);
        float bh = hash12(vec2(bi, h.z * 31.0));
        float dash = hash12(vec2(bi * 1.3 + h.x * 17.0, floor(Q.x / mix(2.0, 5.0, bh))));
        float env = (1.0 - smoothstep(0.55, 1.0, sx)) * smoothstep(0.0, 0.06, sx) * mix(0.5, 1.0, bh);
        float cv = smoothstep(0.35, 0.5, env + 0.6 * (dash - 0.5));
        float a = cv * fade * mix(0.6, 0.9, fract(h.y * 3.7));
        if (a > cov) {
            cov = a;
            red = mix(hexColor(0x7e1018), hexColor(0xc0242a), fract(h.y * 5.3)) * mix(0.75, 1.1, bh);
        }
    }
    return mix(col, red, cov);
}

// Kept for the layer interface: the old 2 px specks are replaced by the red
// element selected with ACC_RED.
vec3 layerSpecks(vec2 uv, vec2 P, vec3 col) {
#if ACC_RED == 1 || ACC_RED == 3
    col = layerRedDrips(uv, P, col);
#endif
#if ACC_RED == 2 || ACC_RED == 3
    col = layerRedFlecks(uv, P, col);
#endif
    return col;
}
