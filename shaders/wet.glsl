// wet.glsl - W: the wet smear, the post pass between the paint (Buffer A)
// and the dry accents (Image pass).
//
// The paint pass (paint.glsl) renders L0-L2 crisp, down to 1 px grit. Wet
// paint does not look like that: the reference's runs, glazes and drips are
// blended along their length and soft across. So the Image pass smears
// Buffer A once more, along each pixel's own grain:
//
//   - Buffer A's alpha carries the grain direction of the topmost paint
//     (0/45/90/135 deg only), the kind of paint (background, grid block,
//     hero block, glaze) and a wetness 0..1 (wetPack). The paint pass knows
//     the true grain, including block grain, so nothing is re-derived here.
//   - Edges first: no edge stays a binary 1 px cut. Each pixel line along
//     the grain, in pieces of 3-9 px, samples the buffer at a hashed
//     fractional offset (up to AA_JIT px), and two bilinear taps on texel
//     corners make a 3x3 tent around it: block sides, strand ends and
//     thread tips get a 1-2 px transition at their own sub-pixel position,
//     edgy but not cut. All pixels get this, dry ones too (AA_EDGE).
//   - The run is a line integral along the grain: WET_TAPS bilinear taps
//     over 0-WET_LEN ref px, crowded toward the centre (peaked kernel) and
//     72 % upstream (paint is dragged downstream: drips down, band paint to
//     the right). Run lengths vary per brush strand (heavy-tailed: mostly
//     short, a few long runs) and slowly along it, so it reads as separate
//     wet runs, not as a uniform motion blur. Taps alternate up to
//     WET_CROSS px to either side, which melts the grit across the grain.
//     By default the run follows the centre pixel's direction; WET_LIC=1
//     walks on along the direction found under each tap (a true LIC). Both
//     look the same here (directions are constant over whole zones and the
//     weights reject taps across zone borders), the LIC costs ~0.9 ms more.
//   - Mud protection: taps are weighted by similarity to the centre pixel
//     (bilateral, in sqrt-RGB, a rough perceptual space where the average
//     is also taken), and taps of the other colour family (warm vs cool)
//     are dropped. Only taps within WET_NEAR px may cross an edge (that is
//     anti-aliasing, at most ~1.5 px, too short to make grey). Warm and cool
//     never blend over a distance, strong edges survive, small grit melts.
//   - The wetness map: the glow/core area, the lower drips, the bottom-left
//     drips and the smeared band get long, soft runs; the ice column is
//     drier (its dry-brush breaks survive); the top-left hatching and other
//     diagonal hatching stay short; horizontal band grain, blocks and glazes
//     get shorter runs along their grain; the navy right side stays fairly
//     dry. The lower warm column keeps crisp 1 px hairlines (CRISP): its
//     vertical paint is softened along the grain, hardly across it, and its
//     runs are shorter. The accents are drawn after this pass,
//     so ink, flecks and the wedge stay crisp (accents.glsl softens their
//     own edges).
//   - Animation: every strand's run length breathes (loopNoise, seamless,
//     x ANIM), so wet areas slowly drag and relax.
//
// Debug: -D WET=0 skips the run, -D AA_EDGE=0 the edge softening, -D
// SHOW_WET=1 (main.glsl) shows the wetness (grey) and direction (hue: red
// 0, yellow 45, green 90, blue 135 deg).

#ifndef WET
#define WET 1.0          // global wetness gain (0 = crisp, the old look)
#endif
#ifndef WET_LIC
#define WET_LIC 0        // 1: follow the direction of every tap (true LIC)
#endif

const int   WET_TAPS   = 12;                // taps per pixel
const vec2  WET_LEN    = vec2(4.0, 40.0);   // run length range at wetness 1 (ref px)
const float WET_UP     = 0.72;              // share of the run upstream of the pixel
const float WET_PEAK   = 1.5;               // > 1: taps crowd toward the centre (peaked kernel)
const float WET_CROSS  = 0.9;               // cross-grain softening at wetness 1 (ref px)
const float WET_NEAR   = 2.0;               // taps this close (ref px) may cross edges: anti-aliasing
const vec2  WET_SIGMA  = vec2(0.10, 0.26);  // bilateral tolerance (sqrt RGB), dry .. wet
const float WET_BREATH = 0.30;              // run length breathing (animation)
#ifndef AA_EDGE
#define AA_EDGE 1        // sub-pixel edges: hashed fractional offset + 3x3 tent
#endif
const float AA_JIT     = 0.7;               // max sub-pixel edge offset (buffer px)
const float CRISP      = 0.75;              // lower warm column: share of the cross-grain softening removed

// ---- what painted a pixel (paint pass) --------------------------------------
// layerPaint() (blocks.glsl) returns meta = dirIndex + 4 x kind of the
// topmost paint in .a.
const float KIND_SMEAR = 0.0;   // L1 background
const float KIND_GRID  = 1.0;   // grid block
const float KIND_HERO  = 2.0;   // authored field rectangle
const float KIND_GLAZE = 3.0;   // authored glaze bar

// Direction index of a grain angle: 0 = 0 deg, 1 = 45, 2 = 90, 3 = 135 (the
// 180 deg twins fold onto these).
float dirIndex(float ang) { return mod(floor(ang / (0.25 * PI) + 0.5), 4.0); }

// ---- packing (Buffer A alpha) ---------------------------------------------
// alpha = dir + 4 kind + 16 round(63 wet): an integer <= 1023, exact in the
// RGBA16F buffer (half floats hold integers up to 2048). Read the centre
// with texelFetch; bilinear taps mix it and must not decode it.
float wetPack(float meta, float wet) {
    return meta + 16.0 * floor(clamp(wet, 0.0, 1.0) * 63.0 + 0.5);
}
// -> (dir 0..3, kind 0..3, wetness 0..1)
vec3 wetUnpack(float a) {
    a = floor(a + 0.5);
    return vec3(mod(a, 4.0), mod(floor(a / 4.0), 4.0), floor(a / 16.0) / 63.0);
}

// ---- the wetness map (paint pass) -------------------------------------------
// Spatial wetness of the painting (uv), before the per-kind factor.
float wetZone(vec2 uv) {
    float w = 0.45;
    w = max(w, 1.00 * box(uv, vec2(0.22, 0.50), vec2(0.46, 0.86), 0.06)); // glow / yellow core
    w = max(w, 0.55 * box(uv, vec2(0.40, 0.58), vec2(0.64, 1.10), 0.04)); // ice column
    w = max(w, 0.95 * box(uv, vec2(0.19, -0.1), vec2(0.49, 0.44), 0.05)); // lower drips
    w = max(w, 0.85 * box(uv, vec2(0.47, 0.33), vec2(1.10, 0.60), 0.03)); // smeared band
    w = max(w, 0.90 * box(uv, vec2(-0.1, -0.1), vec2(0.24, 0.34), 0.04)); // bottom-left drips
    // the top-left hatch field and the wedge stay dry
    w *= 1.0 - 0.4 * box(uv, vec2(-0.1, 0.48), vec2(0.20, 1.10), 0.05);
    return w;
}

// Wetness of a pixel from where it is and what painted it (layerPaint().a).
float wetness(vec2 uv, float meta) {
    float dir = mod(meta, 4.0), kind = floor(meta / 4.0);
    // dry-brush hatching runs diagonal and the band's horizontal drag keeps
    // its grain: both shorter than the vertical drips
    float k = dir == 0.0 ? 0.6 : (dir == 1.0 || dir == 3.0) ? 0.75 : 1.0;
    k *= kind == KIND_GRID ? 0.55 : kind == KIND_HERO ? 0.40 : kind == KIND_GLAZE ? 0.50 : 1.0;
    return wetZone(uv) * k;
}

// ---- the wet smear (Image pass) ---------------------------------------------
// Colour family: 0 cool .. 1 warm (relative, so darks do not flip).
float wetFamily(vec3 c) {
    return smoothstep(-0.12, 0.12, (c.r - c.b) / (c.r + c.b + 1e-3));
}

vec2 wetDir(float dir) {
    float a = dir * 0.25 * PI;
    // pointing upstream: up for drips and both diagonals, left for horizontal
    // grain (band paint runs to the right)
    return dir < 0.5 ? vec2(-1.0, 0.0) : vec2(cos(a), sin(a));
}

// Smeared linear colour of Buffer A (iChannel0) at fragCoord fc.
vec3 layerWet(vec2 fc) {
    vec4 c0 = texelFetch(iChannel0, ivec2(fc), 0);
    vec3 m = wetUnpack(c0.a);
    float wet = m.z * WET;
#if AA_EDGE == 0
    if (wet <= 0.0) return c0.rgb;
#endif

    vec2 res = iResolution.xy;
    float sc = canvasSide() / REF_SIZE;          // px per reference px
    vec2 d = wetDir(m.x);
    vec2 n = vec2(-d.y, d.x);

    // the centre: no edge stays a binary 1 px cut. Every pixel line along
    // the grain, cut into pieces of 3-9 px, samples Buffer A at its own
    // fractional offset (up to AA_JIT px along and across), and two bilinear
    // taps on texel corners around that point make a 3x3 tent. Each edge
    // sits at a hashed sub-pixel position with a 1-2 px transition - edgy,
    // not cut - and the 1 px grit halves. The radius is too small to make
    // mud between warm and cool. (Buffer pixels, not reference px: this is
    // about the pixel grid. Dry paint gets this too.)
    vec3 cc = c0.rgb;
    // the lower warm column keeps the reference's crisp 1 px hairlines: its
    // vertical paint is softened along the grain, hardly across it
    float crisp = CRISP * box(canvasUV(fc), vec2(0.19, -0.1), vec2(0.49, 0.42), 0.03) * step(1.5, m.x) * step(m.x, 2.5);
#if AA_EDGE
    float ln = floor(dot(fc, n));
    float hl = hash11(ln * 0.618 + m.x * 7.1);
    vec2 hj = hash22(vec2(ln, floor(dot(fc, d) / mix(3.0, 9.0, hl) + 5.0 * hl))) * 2.0 - 1.0;
    vec2 j = (d * hj.x + n * hj.y * (1.0 - crisp)) * AA_JIT;
    // tent along the grain diagonal (crisp: along the grain only)
    vec2 e = mix(0.5 * vec2(1.0, sign(d.x * d.y + 0.5 * d.y)), 0.5 * d, crisp);
    cc = 0.5 * (textureLod(iChannel0, (fc + j + e) / res, 0.0).rgb + textureLod(iChannel0, (fc + j - e) / res, 0.0).rgb);
    if (wet <= 0.0) return cc;
#endif

    // brush strands 3-9 ref px wide, each with its own run length that also
    // drifts slowly along the strand
    vec2 Pr = fc / sc;
    float t = dot(Pr, n), s = dot(Pr, d);
    float W = mix(3.0, 9.0, hash11(floor(t / 16.0) + m.x * 17.0));
    float hs = hash11(floor(t / W) * 1.37 + m.x * 31.0 + 0.5);
    float run = noise1(s / 140.0 + hs * 50.0);
    float L = wet * mix(WET_LEN.x, WET_LEN.y, run * run * run)
            * (1.0 + WET_BREATH * loopNoise(hs * 97.0, 2.0)) * sc
            * (1.0 - 0.6 * crisp);   // crisp column: shorter runs keep the dash ends
    float cr = WET_CROSS * wet * sc * (1.0 - crisp);
    float sig = mix(WET_SIGMA.x, WET_SIGMA.y, wet);
    float isig = 1.0 / (sig * sig);

    vec3 r0 = sqrt(max(cc, 0.0));
    float f0 = wetFamily(cc);
    vec3 acc = r0;
    float wsum = 1.0;
    vec2 pu = fc, pd = fc, du = d, dd = d;   // WET_LIC walkers: upstream, downstream
    float lu = 0.0, ld = 0.0;               // distance walked on each side
    for (int k = 0; k < WET_TAPS; k++) {
        // taps alternate sides, near to far, and crowd toward the centre
        // (peaked kernel); sk > 0 is upstream
        bool up = (k & 1) == 1;
        float y = (float(k >> 1) + 0.5) / float(WET_TAPS / 2);
        float u = pow(y, WET_PEAK);
        float sk = (up ? WET_UP : WET_UP - 1.0) * u * L;
        float cj = (((k >> 1) & 1) == 0 ? cr : -cr) * (0.3 + 0.7 * fract(y * 5.3));
#if WET_LIC
        // true LIC: each side walks on along the grain found under its last
        // tap (sign kept continuous), so a run bends into a block's grain
        vec2 dk = up ? du : dd;
        vec2 tp = (up ? pu : pd) + dk * (sk - (up ? lu : ld));
        vec2 dn = wetDir(wetUnpack(texelFetch(iChannel0, ivec2(tp), 0).a).x);
        dn = dot(dn, dk) < 0.0 ? -dn : dn;
        if (up) { pu = tp; lu = sk; du = dn; } else { pd = tp; ld = sk; dd = dn; }
        vec2 o = tp - fc + vec2(-dk.y, dk.x) * cj;
#else
        vec2 o = d * sk + n * cj;
#endif
        vec3 c = textureLod(iChannel0, (fc + o) / res, 0.0).rgb;
        vec3 r = sqrt(max(c, 0.0));
        vec3 dc = r - r0;
        // close taps soften any edge (no stair steps), far taps only blend
        // similar paint of the same family (no mud)
        float near = 1.0 - smoothstep(0.5 * WET_NEAR, WET_NEAR, abs(sk) / sc);
        float w = (1.0 - 0.7 * u)                                 // run profile
                * exp(-dot(dc, dc) * isig * (1.0 - 0.85 * near))  // bilateral
                * mix(1.0 - smoothstep(0.2, 0.5, abs(wetFamily(c) - f0)), 1.0, near);
        acc += w * r;
        wsum += w;
    }
    acc /= wsum;
    return acc * acc;
}
