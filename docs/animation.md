# Animation concept

The painting is alive, but its composition is fixed. Picture a canvas where
the paint is still wet and keeps flowing, and where the collage of rectangles
slowly reassembles itself. Motion has to be **clearly visible** at normal
playback speed, not a subtle creep. It must never move the big shapes: the
warm column, the red band, the ice column and the navy right side stay where
they are.

## Clock

`shaders/anim.glsl` is the only source of time. Do not use raw `iTime` in
layers.

| helper                       | use                                                                  |
| ---------------------------- | -------------------------------------------------------------------- |
| `loopPhase()`                | phase 0..1 of the seamless loop (`LOOP = 32 s`)                      |
| `loopScroll(cycles, period)` | flowing paint; travels a whole number of pattern periods per loop    |
| `loopNoise(seed, cycles)`    | smooth periodic wobble in −1..1 (flicker, breathing)                 |
| `loopEvent(slots, seed)`     | discrete events: (slot id, progress 0..1); a new hash per slot = a new event |

Two requirements follow from this:

- **Seamless:** the frame at `t = 32` must equal the frame at `t = 0`.
  Check: `go run . -shader X -shot out/a.png -times 0,32`, then
  `go run ./cmd/imgstat score out/a_t0.0.png out/a_t32.0.png` must give
  about 0.
- **`-D ANIM=0` freezes everything.** Layers multiply their amplitudes by
  `ANIM`, or use the helpers, which already do.

## Motion per layer

All motion runs along the fundamental directions only: 0°, 45°, 90° and 135°.
This holds for drift, wipes and growth as well as for strokes.

| layer           | motion                                                                                                                                                                                                                                                                                                                                                                                       |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L0 field, light | The warm/cool seam breathes (threshold wobble, bounded to about ±0.02 uv). The yellow core flickers like a low fire, slowly (2–6 cycles per loop) and by at most about ±12 % luminance, plus a faster, smaller shimmer. The anchor colours drift a little in hue and lightness. Nothing moves its position by more than about 0.015 uv.                                                    |
| L1 smear        | **Paint flows.** Vertical drips run downward at about 10–60 px/s, with a different speed per strand (an integer number of cycles per loop). Horizontal smears in the band drag rightward. Diagonal strands slide along their own direction. A pixel sees colour flowing past it, not the whole layer translating. |
| L2 blocks       | **The collage reassembles.** Random grid blocks have a life cycle per event slot: they wipe in along their grain (like a pixel-sort sweep), hold, then wipe or fade out, and the next slot brings a new block. A few blocks glitch-slide by quantized steps along 0° or 90°. The authored hero blocks stay, because they carry the composition, but get occasional re-sort sweeps through their grain.  |
| L3 accents      | Ink scratches are **drawn**: they grow along their length, hold, then fade. The soot strip drifts sideways. The wedge edge frays and breathes. The red specks are replaced (see the accents brief).                                                                                                                                                                                                    |

The rhythm should be calm overall, with a few accents: about 1–3 noticeable
events per second across the whole frame, with no strobing and no full-frame
pulsing.

## Evaluating motion

- `just clip 0 32 30 -shader X` renders a clip. On the slower machine, use
  `just clip 0 8 15` to look at a part of the loop.
- `just sheet` shows every n-th frame of `out/clip`; `crop` zooms into one
  area.
- Score several instants:
  `go run . -shader X -shot out/x.png -times 0,8,16,24` and then
  `go run ./cmd/imgstat score reference/reference.png out/x_t*.png`. Every
  frame must stay a good still: within about +0.01 of the static score.
