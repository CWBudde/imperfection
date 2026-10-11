// rival_b_field.glsl - the base colour field for rival_b.glsl.
//
// One coherent, low-frequency colour map that follows the cross composition of
// the reference. Everything visible in the final image is this field, looked up
// at distorted coordinates (see rival_b.glsl), so it is the single source of
// colour. It returns linear RGB plus a "warmth" w in [0, 1].
//
// The field is built from two families of colour anchors (Shepard
// interpolation inside each family) and a hard family switch: warm and cool are
// never blended into each other, so a transition can only appear as
// interleaved streaks once the lookup is smeared.

// sRGB hex -> vec3 in [0, 1] (still sRGB; converted once per lookup)
#define HX(h) (vec3(float(((h) >> 16) & 255), float(((h) >> 8) & 255), float((h) & 255)) / 255.0)

// ---- anchors: (u, v, reach) + sRGB colour -----------------------------------
// reach scales the anchor's influence radius (1 = normal).
const int N_WARM = 35;
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
    vec3(0.40, 0.60, 0.8), vec3(0.27, 0.05, 0.9)                         // gold under the ice, orange foot
);
const vec3 WARM_COL[N_WARM] = vec3[](
    HX(0xd8665e), HX(0xe4745e), HX(0xb04a46),
    HX(0x8a2630), HX(0x200a12), HX(0x7a2c26),
    HX(0xc4573c), HX(0xf0a047), HX(0xf2b860),
    HX(0xf09048), HX(0xf8c050), HX(0xf8b848),
    HX(0xf2c47e), HX(0xe86a3a), HX(0xe0682a),
    HX(0xd8862f), HX(0x8a4030), HX(0xd4501c),
    HX(0xb84418), HX(0xa65628), HX(0x9a4220),
    HX(0xb06230), HX(0x3a2420),
    HX(0x7a2214), HX(0x4a1018), HX(0x3a0e16),
    HX(0x4a0e16), HX(0x30101a),
    HX(0x200a12), HX(0x40120e),
    HX(0x2a0e16), HX(0x1a0c12),
    HX(0xb53516),
    HX(0xd8a050), HX(0xa0602e)
);

const int N_COOL = 44;
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
    vec3(0.92, 0.12, 0.6), vec3(0.47, 0.04, 0.6)                         // ink pools at the bottom
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
    HX(0x02060c), HX(0x040a14)
);

// ---- explicit rectangles painted into the field -----------------------------
// (u0, v0, u1, v1) + sRGB colour + family (1 warm, 0 cool). They are the
// "anchor shapes" of the collage; the smear turns their edges into streaks.
const int N_RECT = 9;
const vec4 RECT_BOX[N_RECT] = vec4[](
    vec4(0.68, 0.45, 0.78, 0.53),  // coral pink block in the band
    vec4(0.78, 0.40, 0.94, 0.456), // crimson block, right
    vec4(0.55, 0.44, 0.60, 0.58),  // tall crimson block
    vec4(0.64, 0.54, 0.72, 0.62),  // maroon hatched block
    vec4(0.36, 0.52, 0.50, 0.565), // yellow-orange horizontal block
    vec4(0.02, 0.345, 0.12, 0.452), // dark slate block, left
    vec4(0.08, 0.354, 0.19, 0.428), // lighter slate block next to it
    vec4(0.079, 0.574, 0.20, 0.711), // coral-orange block, left
    vec4(0.03, 0.71, 0.11, 0.76)   // dark maroon strip, left
);
const vec3 RECT_COL[N_RECT] = vec3[](
    HX(0xb04248), HX(0x9a1a26), HX(0x8a1820), HX(0x2a0c18), HX(0xf0b048),
    HX(0x14243a), HX(0x2a4c66), HX(0xc4563e), HX(0x5a2026)
);
const float RECT_WARM[N_RECT] = float[](1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0);
// grain angle of each rectangle when it is redrawn as a crisp block (L2)
// grain contrast of each redrawn block
const float RECT_GRAIN[N_RECT] = float[](0.30, 0.10, 0.10, 0.45, 0.08, 0.10, 0.10, 0.08, 0.12);
const float RECT_ANG[N_RECT] = float[](0.85, 0.0, 1.5707963, 1.5707963, 0.0, 0.0, 0.0, 1.5707963, 0.0);

// Shepard weight with a steep falloff (~ d^-4), so each anchor owns a
// region and neighbours only blend near the boundary.
float anchorWeight(vec2 p, vec3 a) {
    vec2 d = p - a.xy;
    float q = a.z * a.z / (dot(d, d) + 2e-4);
    return q * q;
}

// Base colour field. p in uv. Returns vec4(linear rgb, warmth).
vec4 baseField(vec2 p) {
    vec3 cw = vec3(0.0), cc = vec3(0.0);
    float ww = 0.0, wc = 0.0;
    for (int i = 0; i < N_WARM; i++) {
        float w = anchorWeight(p, WARM_POS[i]);
        cw += w * WARM_COL[i];
        ww += w;
    }
    for (int i = 0; i < N_COOL; i++) {
        float w = anchorWeight(p, COOL_POS[i]);
        cc += w * COOL_COL[i];
        wc += w;
    }
    float warmth = ww / (ww + wc);
    // hard family switch (tiny AA width only)
    float sel = smoothstep(0.49, 0.51, warmth);
    vec3 col = mix(cc / wc, cw / ww, sel);

    for (int i = 0; i < N_RECT; i++) {
        vec4 b = RECT_BOX[i];
        if (all(greaterThan(p, b.xy)) && all(lessThan(p, b.zw))) {
            col = RECT_COL[i];
            warmth = RECT_WARM[i];
        }
    }
    return vec4(srgbToLinear(col), warmth);
}
