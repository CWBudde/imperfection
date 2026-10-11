// grade.glsl - L4: glow, core flicker and colour grade, applied to the
// finished stack.

#ifndef GLOW
#define GLOW 0.24     // strength of the soft light over the yellow core
#endif
#ifndef GRADE_WARM
#define GRADE_WARM 1.0  // gain on warm paint
#endif
#ifndef GRADE_COOL
#define GRADE_COOL 0.95 // gain on cool paint
#endif
#ifndef FLICKER
#define FLICKER 0.08    // low-fire flicker of the core: slow luminance swing (+-)
#endif
#ifndef SHIMMER
#define SHIMMER 0.03    // faster, finer shimmer on top of the flicker (+-)
#endif
const vec2  GLOW_CENTER = vec2(0.35, 0.68);  // the yellow core (uv)
const vec2  GLOW_RADIUS = vec2(0.10, 0.18);  // ellipse radii (uv)
const vec2  FIRE_RADIUS = vec2(0.16, 0.26);  // reach of the flicker (uv)
const float FIRE_COL_W  = 0.06;   // width of one flickering "tongue" (uv)
const float FIRE_CYCLES = 4.0;    // slow flicker cycles per loop (2-6 wanted)
const float FIRE_RISE   = 2.0;    // flicker phase per uv of height: the pattern rises
const float SHIM_COL_W  = 0.018;  // shimmer tongue width (uv)
const float SHIM_CYCLES = 37.0;   // shimmer cycles per loop (~1.2 Hz)
const float SHIM_RISE   = 9.0;

// Periodic value noise in [-1, 1] like loopNoise(), but with a phase shift
// (in knots) so neighbouring rows run late: a flicker that rises through
// the core. Seamless for any shift, the knot ring wraps at 4 * cycles.
float fireNoise(float seed, float cycles, float shift) {
    float n = 4.0 * cycles;
    float x = loopPhase() * n - shift;
    float i = floor(x), f = fract(x);
    float a = hash12(vec2(mod(i, n), seed));
    float b = hash12(vec2(mod(i + 1.0, n), seed));
    return (mix(a, b, f * f * (3.0 - 2.0 * f)) * 2.0 - 1.0) * ANIM;
}

// Flicker field over columns of width w: every column has its own noise
// seed, neighbours are blended smoothly so there is no vertical seam.
float fireField(vec2 uv, float w, float cycles, float rise, float seed) {
    float x = uv.x / w - 0.5;
    float k = floor(x), f = fract(x);
    float sh = uv.y * rise;
    float a = fireNoise(seed + k * 1.618, cycles, sh + k * 0.37);
    float b = fireNoise(seed + (k + 1.0) * 1.618, cycles, sh + (k + 1.0) * 0.37);
    return mix(a, b, f * f * (3.0 - 2.0 * f));
}

// Soft light over the yellow core: a screen blend of warm cream, limited
// to warm paint. Over blue it would turn green-grey, so cool pixels keep
// their colour and the seam stays clean. The core breathes like a low fire:
// a slow flicker per rising tongue plus a fine shimmer, as a luminance gain
// that leans yellow when it brightens and red when it dims (never grey).
vec3 layerGlow(vec2 uv, vec3 col) {
    float warm = smoothstep(0.0, 0.08, col.r - col.b);
    vec2 fd = (uv - GLOW_CENTER) / FIRE_RADIUS;
    float fm = exp(-dot(fd, fd)) * warm;
    float slow = 0.0;
    if (fm > 0.01) {
        slow = fireField(uv, FIRE_COL_W, FIRE_CYCLES, FIRE_RISE, 3.1);
        float fast = fireField(uv, SHIM_COL_W, SHIM_CYCLES, SHIM_RISE, 7.7);
        float F = 1.0 + fm * (FLICKER * slow + SHIMMER * fast);
        col *= pow(vec3(F), vec3(0.8, 1.2, 1.6));
    }

    vec2 d = (uv - GLOW_CENTER) / GLOW_RADIUS;
    float g = GLOW * exp(-dot(d, d)) * (1.0 + 0.4 * slow);
    vec3 light = hexColor(0xffc878) * g * warm;
    return 1.0 - (1.0 - col) * (1.0 - light);
}

// Hue-split gain: cool passages a touch deeper than warm ones. (Rival C also
// sank the darks toward ink here; on this stack that flattened the streak
// texture in the navy areas, so it was dropped.)
vec3 layerGrade(vec3 col) {
    // relative warmth, so near-black pixels do not flicker between the gains
    float warm = smoothstep(-0.4, 0.4, (col.r - col.b) / (col.r + col.b + 1e-3));
    return col * mix(GRADE_COOL, GRADE_WARM, warm);
}
