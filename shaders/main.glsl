// Imperfection - abstract painting of warm and cool brush blocks.
//
// The image is a smear field: there is exactly one colour source, the
// hand-authored base field, and all structure - blocks, drips, hatching,
// grain - comes from distorting the lookup into that field. Every direction
// is one of the four fundamental angles 0, 45, 90 and 135 deg. See
// docs/analysis.md for the analysis and the rival approaches this merges.
//
// Two passes (Shadertoy: Buffer A feeds the Image tab's iChannel0, filter
// linear, wrap clamp):
//
// Buffer A, paint.glsl - the paint, crisp, linear colour; alpha packs grain
// direction, paint kind and wetness per pixel (wet.glsl):
//   L0 field.glsl    colour map following the cross composition + zone maps
//   L1 smear.glsl    background: lookup dragged along the direction field
//   L2 blocks.glsl   rectangles: lookup collapsed to one field point per block
//
// Image, this file - wet paint, then the dry marks on top, then the light:
//   W  wet.glsl      wet smear: Buffer A blurred along each pixel's grain,
//                    length by wetness, without mixing warm and cool
//   L3 accents.glsl  dark wedge, soot strip, seam ink scratches, red drips
//                    and flecks (drawn after the smear, so they stay crisp)
//   L4 grade.glsl    soft glow over the yellow core, hue-split grade, sRGB
//
// Animated on a seamless 32 s loop (anim.glsl, docs/animation.md): paint
// flows, blocks reassemble, wet runs drag, ink is drawn, the core flickers.
// -D ANIM=0 freezes.
// Debug: -D SHOW_FIELD=1 renders L0 alone (no smear, no accents),
// -D NO_BLOCKS=1 skips L2, -D BLOCK_DEBUG=1 colours living blocks (L2),
// -D WET=0 skips the wet smear, -D AA_EDGE=0 the sub-pixel edge softening
// (both = the crisp paint), -D WET_LIC=1 follows the grain at every tap,
// -D SHOW_WET=1 shows the wetness map (grey) and direction (hue).

#bufferA "paint.glsl"

#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif

#include "common.glsl"
#include "anim.glsl"
#include "field.glsl"
#include "wet.glsl"
#include "accents.glsl"
#include "grade.glsl"

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 P = uv * REF_SIZE;     // reference pixels

#ifdef SHOW_FIELD
    fragColor = vec4(linearToSrgb(texelFetch(iChannel0, ivec2(fragCoord), 0).rgb), 1.0);
    return;
#endif
#ifdef SHOW_WET
    vec3 m = wetUnpack(texelFetch(iChannel0, ivec2(fragCoord), 0).a);
    vec3 hue = m.x == 0.0 ? vec3(1.0, 0.2, 0.2) : m.x == 1.0 ? vec3(1.0, 0.9, 0.2)
             : m.x == 2.0 ? vec3(0.2, 1.0, 0.3) : vec3(0.3, 0.4, 1.0);
    fragColor = vec4(mix(vec3(m.z), hue * m.z, 0.5), 1.0);
    return;
#endif

#ifdef BLOCK_DEBUG
    vec3 col = texelFetch(iChannel0, ivec2(fragCoord), 0).rgb;   // debug colours unsmeared
#else
    vec3 col = layerWet(fragCoord);         // W: the wet paint
#endif
    col = layerWedge(uv, P, col);           // L3: dry marks on top
    col = layerSoot(uv, P, col);
    col = layerScratches(uv, P, col);
    col = layerSpecks(uv, P, col);
    col = layerGlow(uv, col);               // L4
    col = layerGrade(col);

    fragColor = vec4(linearToSrgb(col * EXPOSURE), 1.0);
}
