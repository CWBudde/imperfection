// paint.glsl - Buffer A: the paint layers L0-L2, crisp and in linear colour.
//
// Renders the smear field and the blocks (layers L0-L2, see main.glsl) into
// the RGBA16F Buffer A. rgb is linear colour. Alpha carries what the wet
// smear of the Image pass needs per pixel, packed into one exact integer
// (wet.glsl: wetPack): the grain direction of the topmost paint (0, 45, 90
// or 135 deg), the kind of paint (background, grid block, hero, glaze) and
// its wetness.
//
// Register pressure: this pass sits just inside Mesa's SIMD16 budget (about
// three live floats of margin). After every change check that both passes
// still compile to SIMD16:
//   MESA_SHADER_CACHE_DISABLE=1 INTEL_DEBUG=fs go run . -shot out/simd.png
//     -size 64x64 2>&1 | grep -E "SIMD(8|16) shader"     (one line)

#include "common.glsl"
#include "anim.glsl"
#include "field.glsl"
#include "wet.glsl"        // packing, kinds and the wetness map
#include "smear.glsl"
#include "blocks.glsl"

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 P = uv * REF_SIZE;     // reference pixels

#ifdef SHOW_FIELD
    // L0 alone, dry
    fragColor = vec4(baseField(uv).rgb, 0.0);
    return;
#endif

    // L1 + L2: the smeared background and the blocks (blocks.glsl)
    vec4 col = layerPaint(uv, P);
    // the wetness map gets a fresh copy of uv (the max is a no-op, uv >= 0):
    // otherwise the compiler shares its zone terms with the paint layers and
    // keeps them live across L1 + L2 (register pressure, SIMD16)
    uv = max(uv, vec2(-1.0));
    fragColor = vec4(col.rgb, wetPack(col.a, wetness(uv, col.a)));
}
