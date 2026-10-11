// Imperfection - abstract painting of warm and cool brush blocks.
//
// The image is a smear field: there is exactly one colour source, the
// hand-authored base field, and all structure - blocks, drips, hatching,
// grain - comes from distorting the lookup into that field. Every direction
// is one of the four fundamental angles 0, 45, 90 and 135 deg. See
// docs/analysis.md for the analysis and the rival approaches this merges.
//
// Layer stack, back to front:
//   L0 field.glsl    colour map following the cross composition + zone maps
//   L1 smear.glsl    background: lookup dragged along the direction field
//   L2 blocks.glsl   rectangles: lookup collapsed to one field point per block
//   L3 accents.glsl  dark wedge, soot strip, seam ink scratches, red specks
//   L4 grade.glsl    soft glow over the yellow core, hue-split grade
//
// Animated on a seamless 32 s loop (anim.glsl, docs/animation.md): paint
// flows, blocks reassemble, ink is drawn, the core flickers. -D ANIM=0 freezes.
// Debug: -D SHOW_FIELD=1 renders L0 alone, -D NO_BLOCKS=1 skips L2.

#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif

#include "common.glsl"
#include "anim.glsl"
#include "field.glsl"
#include "smear.glsl"
#include "blocks.glsl"
#include "accents.glsl"
#include "grade.glsl"

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 P = uv * REF_SIZE;     // reference pixels

#ifdef SHOW_FIELD
    fragColor = vec4(linearToSrgb(baseField(uv).rgb), 1.0);
    return;
#endif

    // L1: rgb + warmth of the smeared background
    vec4 bg = layerSmear(uv, P);
    vec3 col = bg.rgb;
#ifndef NO_BLOCKS
    col = layerBlocks(uv, P, bg);           // L2
#endif
    col = layerWedge(uv, P, col);           // L3
    col = layerSoot(uv, P, col);
    col = layerScratches(uv, P, col);
    col = layerSpecks(uv, P, col);
    col = layerGlow(uv, col);               // L4
    col = layerGrade(col);

    fragColor = vec4(linearToSrgb(col * EXPOSURE), 1.0);
}
