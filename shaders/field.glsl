// field.glsl - L0: the base colour field and the zone maps.
//
// One coherent, low-frequency colour map that follows the cross composition of
// the reference. Every visible pixel is this field, looked up at distorted
// coordinates (smear.glsl, blocks.glsl), so it is the single source of colour.
// baseField returns linear RGB plus a "warmth" w in [0, 1].
//
// The field is built from two families of colour anchors (Shepard
// interpolation inside each family) and a hard family switch: warm and cool are
// never blended into each other, so a transition can only appear as
// interleaved streaks once the lookup is smeared.
//
// The zone maps below decide which way the paint is dragged where
// (directionField) and where blocks are likely (blockDensity).

// ---- small helpers ----------------------------------------------------------
// Soft box mask: 1 inside [a, b], fading over `soft`.
float box(vec2 p, vec2 a, vec2 b, float soft) {
    vec2 s = smoothstep(a - soft, a + soft, p) * (1.0 - smoothstep(b - soft, b + soft, p));
    return s.x * s.y;
}

// 1D value noise in [0, 1].
float noise1(float x) {
    float i = floor(x), f = fract(x);
    return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// sRGB hex -> vec3 in [0, 1] (still sRGB; converted once per lookup)
#define HX(h) (vec3(float(((h) >> 16) & 255), float(((h) >> 8) & 255), float((h) & 255)) / 255.0)

// ---- anchors: (u, v, reach) + sRGB colour -----------------------------------
// reach scales the anchor's influence radius (1 = normal).
const int N_WARM = 36;
const vec3 WARM_POS[N_WARM] = vec3[](
    vec3(0.04, 0.96, 1.0), vec3(0.11, 0.90, 1.0), vec3(0.04, 0.80, 1.0), // coral / salmon top left
    vec3(0.03, 0.66, 1.0), vec3(0.04, 0.53, 0.9), vec3(0.11, 0.56, 0.8), // maroon / oxblood left edge
    vec3(0.13, 0.70, 1.0), vec3(0.17, 0.85, 1.0), vec3(0.23, 0.96, 0.8), // orange, yellow top
    vec3(0.22, 0.74, 1.0), vec3(0.31, 0.70, 1.0), vec3(0.34, 0.61, 1.15), // yellow core
    vec3(0.36, 0.78, 0.8), vec3(0.24, 0.60, 1.0), vec3(0.30, 0.52, 1.0), // cream, orange
    vec3(0.42, 0.52, 1.1), vec3(0.20, 0.47, 1.0), vec3(0.32, 0.43, 1.0), // gold, burnt orange, vermilion
    vec3(0.42, 0.44, 0.8), vec3(0.29, 0.30, 1.0), vec3(0.37, 0.33, 0.8), // lower orange column
    vec3(0.31, 0.14, 1.0), vec3(0.40, 0.08, 0.8),                        // dripping orange, bottom
    vec3(0.55, 0.47, 0.8), vec3(0.63, 0.44, 0.9), vec3(0.72, 0.43, 1.0), // red band
    vec3(0.84, 0.42, 1.0), vec3(0.95, 0.41, 0.8),
    vec3(0.70, 0.36, 0.9), vec3(0.55, 0.36, 0.8),                        // oxblood under the band
    vec3(0.62, 0.53, 0.7), vec3(0.07, 0.48, 1.0),                        // red-blacks: above band, left edge
    vec3(0.50, 0.42, 0.7),                                               // vermilion where band meets column
    vec3(0.40, 0.60, 0.8), vec3(0.27, 0.05, 0.9),                        // gold under the ice, orange foot
    vec3(0.27, 0.75, 0.85)                                              // saffron-orange flank of the core
);
const vec3 WARM_COL[N_WARM] = vec3[](
    HX(0xd8665e), HX(0xe4745e), HX(0xb04a46),
    HX(0x8a2630), HX(0x200a12), HX(0x7a2c26),
    HX(0xc85238), HX(0xf0a047), HX(0xf2b860),
    HX(0xe8803c), HX(0xfcc654), HX(0xfcbe4c),
    HX(0xf2c47e), HX(0xe86a3a), HX(0xe0682a),
    HX(0xd8862f), HX(0x8a4030), HX(0xd4501c),
    HX(0xb84418), HX(0xa65628), HX(0x9a4220),
    HX(0xb06230), HX(0x3a2420),
    HX(0x7a2214), HX(0x4a1018), HX(0x3a0e16),
    HX(0x4a0e16), HX(0x30101a),
    HX(0x200a12), HX(0x40120e),
    HX(0x2a0e16), HX(0x1a0c12),
    HX(0xb53516),
    HX(0xd8a050), HX(0xa0602e),
    HX(0xe87432)
);

const int N_COOL = 47;
const vec3 COOL_POS[N_COOL] = vec3[](
    vec3(0.31, 0.95, 0.7),                                               // lilac grey, top
    vec3(0.44, 0.93, 1.0), vec3(0.44, 0.80, 1.0), vec3(0.46, 0.70, 0.8), // ice column
    vec3(0.55, 0.92, 1.0), vec3(0.54, 0.74, 1.0), vec3(0.50, 0.62, 0.7), // sky
    vec3(0.63, 0.92, 1.0), vec3(0.64, 0.75, 1.0),                        // steel
    vec3(0.72, 0.92, 0.9), vec3(0.71, 0.78, 0.9),                        // grey steel bars
    vec3(0.80, 0.96, 0.9), vec3(0.85, 0.82, 1.0), vec3(0.95, 0.95, 1.0), // navy top right
    vec3(0.93, 0.70, 1.0), vec3(0.78, 0.66, 0.9), vec3(0.65, 0.60, 0.7), // dark wedge
    vec3(0.95, 0.55, 0.9),
    vec3(0.03, 0.40, 0.9), vec3(0.12, 0.40, 0.9),                        // slate blocks left
    vec3(0.05, 0.25, 1.0), vec3(0.16, 0.22, 0.8),
    vec3(0.05, 0.08, 1.0), vec3(0.11, 0.06, 1.1), vec3(0.20, 0.08, 0.8), // slate drips bottom left
    vec3(0.47, 0.20, 0.55),                                               // ink seam right of the column
    vec3(0.58, 0.08, 1.0), vec3(0.68, 0.18, 1.0), vec3(0.84, 0.08, 1.0), // navy bottom right
    vec3(0.96, 0.08, 1.0), vec3(0.62, 0.28, 0.9), vec3(0.88, 0.27, 0.9),
    vec3(0.95, 0.20, 0.8),
    vec3(0.85, 0.58, 0.8), vec3(0.70, 0.61, 0.6), vec3(0.48, 0.56, 0.5), // darks above the band
    vec3(0.92, 0.33, 0.7),                                               // navy under the band, right
    vec3(0.13, 0.30, 1.1), vec3(0.16, 0.16, 0.9),                        // cool left of the column
    vec3(0.53, 0.55, 0.7),                                               // dusky purple at the seam
    vec3(0.80, 0.53, 0.8), vec3(0.10, 0.16, 0.9),                        // ink above the band, grey drip
    vec3(0.92, 0.12, 0.6), vec3(0.47, 0.04, 0.6),                        // ink pools at the bottom
    vec3(0.53, 0.12, 0.45), vec3(0.88, 0.05, 0.5), vec3(0.66, 0.06, 0.4) // lighter blue drips, bottom
);
const vec3 COOL_COL[N_COOL] = vec3[](
    HX(0x8a7e98),
    HX(0xbfe0f0), HX(0xaed8ea), HX(0x92a4a6),
    HX(0x8aaec4), HX(0x4f7c98), HX(0x3e5866),
    HX(0x6a8ea4), HX(0x3f6680),
    HX(0x46525c), HX(0x3c4c58),
    HX(0x1a4262), HX(0x12324c), HX(0x04142a),
    HX(0x020812), HX(0x081828), HX(0x2a3446),
    HX(0x03080f),
    HX(0x0a1b2e), HX(0x24486a),
    HX(0x10223a), HX(0x1a2c3a),
    HX(0x45596a), HX(0x6c7a86), HX(0x34485a),
    HX(0x0a0f18),
    HX(0x08294a), HX(0x05182e), HX(0x0a2238),
    HX(0x0a2236), HX(0x030a14), HX(0x0d1424),
    HX(0x142838),
    HX(0x060810), HX(0x1a1a2a), HX(0x2a2836),
    HX(0x1e2a3c),
    HX(0x141e2c), HX(0x203444),
    HX(0x30303e),
    HX(0x0a0810), HX(0x5a6a78),
    HX(0x02060c), HX(0x040a14),
    HX(0x1e4a6e), HX(0x30628a), HX(0x184266)
);

// ---- explicit rectangles painted into the field -----------------------------
// (u0, v0, u1, v1) + sRGB colour + family (1 warm, 0 cool). They are the
// "anchor shapes" of the collage; the smear turns their edges into streaks.
// The first N_FIELD_RECT rectangles are painted into the field; the rest
// are glazes that only exist in L2.
const int N_RECT = 11;
const int N_FIELD_RECT = 9;
// The background smear does not drag some rectangles (bit i set = rectangle
// i skipped): the coral block (0), where the 45 deg smear dragged its paint
// out in every direction and turned the hero into a hairy pink blob whenever
// the grid blocks around it wiped out, and the two slate blocks (5, 6),
// whose paint was dragged sideways and down into stairs. Grid blocks near
// them do not pick it up either (frayed pink combs). The heroes (L2) still
// paint them, as clean rectangles.
const int BG_SKIP = (1 << 0) | (1 << 5) | (1 << 6);
const float FIELD_BG = 2.0;     // baseField: thr offset that marks the background lookup
const vec4 RECT_BOX[N_RECT] = vec4[](
    vec4(0.68, 0.45, 0.78, 0.53),  // coral pink block in the band
    vec4(0.78, 0.40, 0.94, 0.456), // crimson block, right
    vec4(0.55, 0.44, 0.60, 0.58),  // tall crimson block
    vec4(0.64, 0.54, 0.72, 0.62),  // maroon hatched block
    vec4(0.36, 0.52, 0.50, 0.565), // yellow-orange horizontal block
    vec4(0.02, 0.345, 0.12, 0.452), // dark slate block, left
    vec4(0.08, 0.354, 0.19, 0.428), // lighter slate block next to it
    vec4(0.079, 0.574, 0.20, 0.711), // coral-orange block, left
    vec4(0.03, 0.71, 0.11, 0.76),  // dark maroon strip, left
    vec4(0.668, 0.62, 0.775, 0.941), // glaze: grey "barcode" bar, upper right
    vec4(0.812, 0.66, 0.966, 0.906)  // glaze: steel-blue bar, upper right
);
const vec3 RECT_COL[N_RECT] = vec3[](
    HX(0xbe423c), HX(0x9a1a26), HX(0x8a1820), HX(0x2a0c18), HX(0xf0b048),
    HX(0x1a3450), HX(0x36607e), HX(0xc4563e), HX(0x5a2026),
    HX(0x4a4440), HX(0x1a3e5a)
);
const float RECT_WARM[N_RECT] = float[](1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0);
// grain contrast and grain angle of each rectangle when it is redrawn as a
// crisp block (L2); angles are 0, 45, 90 or 135 deg only
const float RECT_GRAIN[N_RECT] = float[](0.38, 0.10, 0.10, 0.45, 0.08, 0.10, 0.10, 0.20, 0.12, 0.45, 0.16);
const float RECT_ANG[N_RECT] = float[](0.25 * PI, 0.0, 0.5 * PI, 0.5 * PI, 0.0, 0.0, 0.0, 0.75 * PI, 0.0,
                                       0.5 * PI, 0.5 * PI);

// Shepard weight with a steep falloff (~ d^-4), so each anchor owns a
// region and neighbours only blend near the boundary.
float anchorWeight(vec2 p, vec3 a) {
    vec2 d = p - a.xy;
    float q = a.z * a.z / (dot(d, d) + 2e-4);
    return q * q;
}

// ---- paint variation inside the warm family ---------------------------------
// The Shepard field alone is a smooth poster; the reference's warm column is
// a patchwork of saffron, orange, vermilion and red-brown runs. Narrow,
// tall noise cells (they turn into whole drips once the smear drags them)
// swing the hue along the warm ladder (g/r ratio: butter 0.8, saffron 0.68,
// orange 0.5, vermilion 0.3) and the lightness, darker runs leaning red.
// Both swings are zero-mean, so the coarse colour map is kept.
const vec2  WVAR_FREQ   = vec2(24.0, 2.6);  // hue cells: ~0.04 uv wide, ~0.4 tall
const vec2  WVAR_FREQ_L = vec2(21.0, 4.2);  // lightness cells
#ifndef WVAR_HUE
#define WVAR_HUE 0.20 // g/r swing
#endif
#ifndef WVAR_LIT
#define WVAR_LIT 0.11 // lightness swing (factor)
#endif
#ifndef WVAR_CHROMA
#define WVAR_CHROMA 0.3 // blue cut in the lower column (cleaner, hotter paint)
#endif
#ifndef WVAR_LOW_HUE
#define WVAR_LOW_HUE -0.05 // lower column: bias toward vermilion
#endif
#ifndef WVAR_LOW_LIT
#define WVAR_LOW_LIT 0.06 // lower column: lightness bias
#endif
// the yellow core: a narrower swing (butter <-> saffron), lifted and lighter
#ifndef CORE_HUE_AMP
#define CORE_HUE_AMP 0.55 // fraction of the hue swing kept in the core
#endif
#ifndef CORE_HUE
#define CORE_HUE 0.02 // core: bias toward butter
#endif
#ifndef CORE_LIT
#define CORE_LIT 0.03 // core: lightness lift
#endif
#ifndef WSEED_H
#define WSEED_H vec2(41.9, 9.1)
#endif
#ifndef WSEED_L
#define WSEED_L vec2(52.6, 14.2)
#endif
// cool threads: narrow runs inside the lower orange column where the warmth
// dips below the switch, so blue drips run through the orange
#ifndef COOL_THREADS
#define COOL_THREADS 0.62
#endif
#ifndef COOL_THREAD_CUT
#define COOL_THREAD_CUT 0.66 // noise level above which a cool thread starts
#endif

// Seam breathing, colour drift (animation, all amplitudes x ANIM). The Shepard weights are read at a displaced point, so the
// warm/cool seams creep back and forth; texture noise stays fixed.
#ifndef SEAM_BREATH
#define SEAM_BREATH 0.014 // uv, max displacement of the seams
#endif
const float DRIFT_HUE   = 0.05;   // warm g/r drift (saffron <-> orange)
const float DRIFT_LIT   = 0.06;   // lightness drift of both families

// Warm-family variation strength by zone: strong in the lower column and the
// core, light elsewhere (coral hatching, red band keep their own colour).
float warmVarMask(vec2 p) {
    float m = 0.25;
    m = max(m, box(p, vec2(0.19, -0.1), vec2(0.49, 0.50), 0.04));
    m = max(m, 0.75 * box(p, vec2(0.20, 0.50), vec2(0.46, 0.84), 0.04));
    return m;
}

// Shift a warm sRGB paint along the warm ladder (dh, g/r units) and in
// lightness (f, factor). Green and blue respond faster than red, so warm
// darks go red-brown (never olive) and warm lights go saffron/butter
// (never pink, and no clipping of the red channel).
vec3 warmShift(vec3 c, float dh, float f) {
    float r = max(c.r, 1e-3);
    float gr = c.g / r;
    float ngr = clamp(gr + dh, 0.10, 0.92);
    c.g = r * ngr;
    c.b *= pow(ngr / max(gr, 0.05), 1.3);
    return min(c * pow(vec3(f), vec3(0.8, 1.3, 1.7)), vec3(1.0));
}

// Base colour field. p in uv, thr = warmth at which the family switches
// (0.5 neutral; the smear dithers it per hairline, so a seam turns into
// interleaved threads). thr + FIELD_BG: the lookup of the background and the
// grid blocks, which do not see the rectangles in BG_SKIP. Returns
// vec4(linear rgb, warmth).
vec4 baseField(vec2 p, float thr) {
    bool bg = thr > 1.5;
    thr = bg ? thr - FIELD_BG : thr;
    // animation: smooth, spatially varying displacement of the anchor lookup
    // (two standing sines, 2 and 3 cycles per loop, whose sign and size vary
    // with a slow 1D noise of the position, so the seams breathe in and out
    // in different directions along their length; seamless, zero at t = 0
    // so the judged still keeps its composition; only two uniform sines)
    float ny = noise1(p.y * 4.0 + 2.0) * 2.0 - 1.0, nx = noise1(p.x * 4.0 + 9.0) * 2.0 - 1.0;
    float ph = TAU * loopPhase();
    vec2 s2 = sin(2.0 * ph) * vec2(ny, nx);
    vec2 s3 = sin(3.0 * ph) * vec2(nx, -ny);
    vec2 q = p + SEAM_BREATH * ANIM * vec2(0.6 * s2.x + 0.4 * s3.x, 0.3 * s2.y + 0.2 * s3.y);
    vec3 cw = vec3(0.0), cc = vec3(0.0);
    float ww = 0.0, wc = 0.0;
    for (int i = 0; i < N_WARM; i++) {
        float w = anchorWeight(q, WARM_POS[i]);
        cw += w * WARM_COL[i];
        ww += w;
    }
    for (int i = 0; i < N_COOL; i++) {
        float w = anchorWeight(q, COOL_POS[i]);
        cc += w * COOL_COL[i];
        wc += w;
    }
    float warmth = ww / (ww + wc);
    cw /= ww;
    cc /= wc;

    float dLit = DRIFT_LIT * ANIM * (0.6 * s3.y + 0.4 * s2.x);
    cc *= 1.0 + dLit;

    // cool threads through the lower column
    float lowCol = box(p, vec2(0.21, 0.0), vec2(0.47, 0.42), 0.04);
    if (lowCol > 0.0) {
        // cells ~7 px wide and ~0.9 uv tall: once smeared, long thin threads
        // (1-3 px), not short blobs; a steep ramp, so a thread is either cool
        // or warm and the hairline dither does not chop it into dashes
        float tn = noise(p * vec2(150.0, 1.1) + vec2(3.3, 0.0));
        warmth -= COOL_THREADS * lowCol * smoothstep(COOL_THREAD_CUT, COOL_THREAD_CUT + 0.1, tn);
    }

    // hard family switch (tiny AA width only)
    float sel = smoothstep(thr - 0.01, thr + 0.01, warmth);
    vec3 col = cc;
    if (sel > 0.0) {
        // warm paint variation (static) + slow drift (animated); skipped
        // where the cool family wins
        float m = warmVarMask(p);
        float hN = clamp((noise(p * WVAR_FREQ + WSEED_H) * 2.0 - 1.0) * 1.8, -1.0, 1.0);
        float lN = clamp((noise(p * WVAR_FREQ_L + WSEED_L) * 2.0 - 1.0) * 1.6, -1.0, 1.0);
        hN = mix(hN, lN, 0.35);                 // dark runs lean red, light runs saffron
        float dHue = DRIFT_HUE * ANIM * (0.6 * s2.y + 0.4 * s3.x);
        // the lower column: hotter paint, leaning vermilion
        cw.b *= 1.0 - WVAR_CHROMA * lowCol;
        float core = box(p, vec2(0.29, 0.53), vec2(0.43, 0.80), 0.04);
        float hueAmp = WVAR_HUE * m * mix(1.0, CORE_HUE_AMP, core);
        cw = warmShift(cw, hueAmp * hN + dHue + WVAR_LOW_HUE * lowCol + CORE_HUE * core,
                       1.0 + WVAR_LIT * m * lN + dLit + WVAR_LOW_LIT * lowCol + CORE_LIT * core);
        col = mix(cc, cw, sel);
    }

    for (int i = 0; i < N_FIELD_RECT; i++) {
        vec4 b = RECT_BOX[i];
        if ((!bg || ((BG_SKIP >> i) & 1) == 0) && all(greaterThan(p, b.xy)) && all(lessThan(p, b.zw))) {
            col = RECT_COL[i];
            warmth = RECT_WARM[i];
        }
    }
    return vec4(srgbToLinear(col), warmth);
}

vec4 baseField(vec2 p) { return baseField(p, 0.5); }

// ---- zone maps --------------------------------------------------------------
// All lengths are in reference pixels (the reference is 1024 px wide), so the
// image keeps its look at other render sizes.
const float REF_SIZE    = 1024.0;

// The painting is square. On other canvases (Shadertoy's 16:9 preview,
// fullscreen) it keeps its proportions - 45 deg stays 45 deg - and fills
// the canvas: the square spans the shorter side, centred, and the field
// simply continues beyond it on the longer side.
float canvasSide() { return min(iResolution.x, iResolution.y); }
vec2 canvasUV(vec2 fc) { return (fc - 0.5 * (iResolution.xy - canvasSide())) / canvasSide(); }
const float LUM_SPREAD  = 0.10;      // per-streak brightness variation
const float DARK_LINES  = 0.04;      // fraction of streak segments that are dark scratches

// Every direction in the image is one of four fundamental angles (and their
// 180 deg twins): no fanning, no per-stroke wobble. The reference's "\" fan
// (118-150 deg) and "/" hatching (~50 deg) are snapped to 135 and 45 deg.
const float ANG_H       = 0.0;            // horizontal grain
const float ANG_FWD     = 0.25 * PI;      // "/" hatching, 45 deg
const float ANG_V       = 0.5 * PI;       // vertical drips, paint carried downward
const float ANG_BACK    = 0.75 * PI;      // "\" hatching, 135 deg

// Direction field.
// Soft-edged zones select the smear axis. Returns the angle, the segment
// length range and the streak contrast for this pixel. A stretched noise
// dithers the zone borders, so hatching fields end in ragged, soft outlines.
void directionField(vec2 uv, out float ang, out vec2 len, out float spread, out float dark) {
    float nz = fbm(uv * vec2(9.0, 7.0) + 3.1, 3);

    // "\" hatching: left edge, upper half
    float back = box(uv, vec2(-0.1, 0.48), vec2(0.21, 1.1), 0.06);
    back = max(back, 0.85 * box(uv, vec2(0.05, 0.52), vec2(0.27, 0.76), 0.04));
    // "/" hatching: dark wedge upper right and the maroon part of the band
    float fwd = box(uv, vec2(0.84, 0.60), vec2(1.1, 0.88), 0.05);
    fwd = max(fwd, box(uv, vec2(0.60, 0.43), vec2(0.72, 0.56), 0.02));
    fwd = max(fwd, 0.8 * box(uv, vec2(0.72, 0.50), vec2(0.86, 0.62), 0.03));
    // horizontal grain: red band right, shadow strip, slate blocks left,
    // bottom right corner
    float hor = box(uv, vec2(0.74, 0.30), vec2(1.1, 0.60), 0.03);
    hor = max(hor, box(uv, vec2(0.48, 0.24), vec2(1.1, 0.40), 0.02));
    hor = max(hor, box(uv, vec2(-0.1, 0.36), vec2(0.185, 0.46), 0.01));
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

    // texture gain: the reference is calm inside the warm column and
    // grainier in the dark right half and the top-left hatching
    float gain = 1.0 - 0.65 * box(uv, vec2(0.12, 0.55), vec2(0.60, 1.1), 0.05);
    gain += 0.6 * box(uv, vec2(0.72, -0.1), vec2(1.1, 1.1), 0.06);
    gain += 1.0 * box(uv, vec2(0.50, -0.1), vec2(1.1, 0.25), 0.05);   // navy bottom: light and dark drips
    gain += 0.5 * box(uv, vec2(0.20, -0.1), vec2(0.48, 0.38), 0.04);   // lower column: hairline contrast
    spread *= gain;

    if (hor > nz) {
        // paint is dragged in from the outer edges (left zone from the left)
        ang = (uv.x < 0.3 || horL > nz) ? ANG_H + PI : ANG_H;
        len = horL > nz ? vec2(150.0, 420.0) : vec2(40.0, 260.0);
        spread = 0.10 * gain;
    }
    if (back > nz) {
        ang = ANG_BACK;
        len = vec2(40.0, 260.0);
        spread = 0.04 + 0.27 * (1.0 - smoothstep(0.04, 0.17, uv.x));
        dark = 0.08 + 0.05 * (1.0 - smoothstep(0.06, 0.16, uv.x));
    }
    if (fwd > nz) {
        ang = ANG_FWD;
        len = vec2(20.0, 140.0);
        spread = 0.25;
    }
}


// Block density.
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
    d = max(d, 0.20 * box(uv, vec2(0.00, 0.33), vec2(0.22, 0.47), 0.03));   // slate blocks: calm, the heroes carry them
    // bottom left is drips, not blocks
    d *= 1.0 - 0.9 * box(uv, vec2(-0.1, -0.1), vec2(0.24, 0.335), 0.02);
    return d;
}

