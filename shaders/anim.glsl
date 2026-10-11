// anim.glsl - shared animation clock. Every layer animates through these
// helpers so the whole painting runs on one seamless loop: the frame at
// iTime = LOOP is identical to the frame at iTime = 0.
//
// Rules for layers (see docs/animation.md):
//   - scrolls must travel a whole number of pattern periods per loop
//     (loopScroll), time noise must use a whole number of cycles per loop
//     (loopNoise), events live in a whole number of slots per loop
//     (loopEvent);
//   - motion is bounded: the composition (where warm, cool, band, column
//     sit) must hold at every instant;
//   - ANIM scales every motion amplitude; -D ANIM=0 freezes the painting.

#ifndef LOOP
#define LOOP 32.0 // seconds per seamless loop
#endif
#ifndef ANIM
#define ANIM 1.0 // global animation strength, 0 = still
#endif

// Loop phase in [0, 1).
float loopPhase() { return fract(iTime / LOOP); }

// Distance travelled by a scroll that runs `cycles` (integer) pattern
// periods of length `period` per loop. Seamless by construction.
float loopScroll(float cycles, float period) {
    return loopPhase() * floor(cycles + 0.5) * period * ANIM;
}

// Smooth periodic noise in [-1, 1] with `cycles` (integer >= 1)
// oscillations per loop, decorrelated by `seed`. Value noise on a ring of
// 4 * cycles knots.
float loopNoise(float seed, float cycles) {
    float n = 4.0 * max(floor(cycles + 0.5), 1.0);
    float x = loopPhase() * n;
    float i = floor(x), f = fract(x);
    float a = hash12(vec2(mod(i, n), seed));
    float b = hash12(vec2(mod(i + 1.0, n), seed));
    return (mix(a, b, f * f * (3.0 - 2.0 * f)) * 2.0 - 1.0) * ANIM;
}

// Event clock: the loop is cut into `slots` (integer) equal slots, each
// slot shifted by a per-seed offset so events do not fire in sync.
// Returns (slot index in [0, slots), progress in [0, 1) within the slot).
vec2 loopEvent(float slots, float seed) {
    float s = max(floor(slots + 0.5), 1.0);
    float x = loopPhase() * s + hash11(seed * 7.13);
    return vec2(mod(floor(x), s), fract(x));
}
