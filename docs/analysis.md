# Reference analysis

`reference/reference.png`, 1024x1024. This document describes the image's
composition, colours, directions and building blocks. It skips painting
technique. Coordinates use shader uv: origin bottom left, `v = 1` at the top.
Measured numbers are in `docs/reference-stats.txt`, produced by
`go run ./cmd/imgstat analyze`.

## 1. Composition

The image reads as a **cross**. A warm **vertical column** rises from the bottom
edge to the top-left corner, and a warm-to-red **horizontal band** runs from the
column to the right edge, just below the centre. Everything else is cool.

```
 v=1 +-----------------------------------------------+
     | coral/red  | yellow-orange | ICE BLUE | mid blue | navy   |
     | diag hatch | blocks        | drips    | vertical | diag   |
     |            |   YELLOW CORE |          | bars     | dark   |
 v=.5|  red/maroon| orange blocks |== RED BAND (blocks) ======== |
     |  slate blue| orange column | dark shadow strip / specks   |
     | blue-grey  | orange drips  | navy, vertical drips         |
 v=0 +-----------------------------------------------+
     u=0         .25            .5                .75          1
```

- **Warm mass**: centred near `u ≈ 0.33`. It is widest at `v ≈ 0.45–0.75`, where
  it spans `u ≈ 0–0.55`. The brightest part, the **yellow core**, sits at
  `u ≈ 0.30–0.42`, `v ≈ 0.55–0.75`. Below `v ≈ 0.4` the warm mass narrows to
  orange columns at `u ≈ 0.22–0.45`, which drip down to the bottom edge.
- **Left edge, top half**: coral and salmon red fading to deep maroon. Dense
  diagonal hatching.
- **Ice-blue column**: `u ≈ 0.40–0.62`, `v ≈ 0.6–1.0`. It is the brightest cool
  area (almost white-cyan) and is made of vertical drips that fade out downward
  at about `v ≈ 0.6`.
- **Upper right**: mid blue to steel blue in vertical bars. Toward the top-right
  corner it darkens to navy, and a dark diagonal wedge runs through it.
- **Red band**: `v ≈ 0.33–0.6`, `u ≈ 0.5–1.0`. It is built from distinct
  rectangles: crimson, coral pink, and maroon with dark hatching.
- **Shadow strip**: a near-black horizontal line of soot under the red band at
  `v ≈ 0.3–0.35`, scattered with tiny red specks.
- **Bottom left**: slate blue and grey-blue vertical drips. A few horizontal
  blue blocks reach into the warm area at `v ≈ 0.35–0.45`.
- **Bottom right**: navy and black, with lighter blue vertical drips and diagonal
  hatching.

The overall luminance peaks in two places: the yellow core (warm) and the ice-blue
column (cool). They sit **side by side** near `u ≈ 0.4`, `v ≈ 0.7`. The image's
main tension is this hot/cold seam in the upper middle. The darkest region is the
right third, below the red band.

## 2. Colour

The palette has roughly three families. Hex values are approximate; see the
k-means output in the stats file.

| Family | Tones                                                                                              |
| ------ | -------------------------------------------------------------------------------------------------- |
| warm   | butter yellow `#f7c95a`, saffron `#f0a23a`, orange `#e8742f`, vermilion `#d9442a`, coral `#e8705e` |
| red    | crimson `#b81e2a`, maroon `#5e1420`, oxblood `#3a0d15`                                             |
| cool   | ice `#bfe0f0`, sky `#8fb8d4`, steel `#4f7896`, slate `#3a5a78`, navy `#14263c`, ink `#070d16`      |

- The warm and cool families do **not** mix into grey. The transition is
  hard-edged. Either blocks with hard edges overlap, or interleaved vertical
  streaks of both colours fill it (orange threads inside the blue drips, blue
  under the orange). Interpolating linearly between orange and blue therefore
  looks wrong, because it passes through mud.
- Within a block the colour varies along the grain direction (streaks), not as
  a gradient.
- Darks are **blue-black** in the cool half and **red-black** (oxblood) in the
  warm half. There is no neutral black.
- Saturation is high in the warms and moderate in the blues. The ice blue is
  close to white.

## 3. Directions

Three orientation families, in order of area:

1. **Vertical (90°)**: dominant. Drips and pixel-sort streaks in the ice-blue
   column, the upper right, the orange columns and the bottom half.
2. **Diagonal (about 35–50°, "\\", falling to the right)**: the hatching on the
   left edge (upper half) and on the maroon and dark parts of the red band. The
   strokes fan out a little, like a brush swung from the upper left. A second,
   mirrored diagonal ("/") appears as a dark wedge in the upper right and as
   hatching in the bottom right.
3. **Horizontal (0°)**: the grain inside some blocks (the yellow-orange block at
   `v ≈ 0.53`, the red band rectangles, the slate-blue blocks on the left) and the
   shadow strip.

Every rectangle edge is **axis-aligned**.

## 4. Building blocks

From back to front:

1. **Base colour field**: a low-frequency warm/cool map following the cross
   composition. On its own it would be a blurry poster.
2. **Rectangular blocks**: axis-aligned rectangles from about `0.04` to `0.25`
   uv on a side, often taller than wide. Each has a nearly flat colour picked
   from the field near it, its own grain (vertical or horizontal streaks), and
   hard edges. Some look semi-transparent, like glazes over what lies beneath.
   They are densest in the warm column and along the red band, where they look
   stacked like a collage or a glitch.
3. **Vertical smear streaks**: 1–3 px wide columns that hold a colour over a
   long vertical run (50–400 px) and end raggedly or taper, like dripping or
   pixel sorting. Brightness varies strongly from column to column. This is the
   main fine texture in the cool areas and the lower warm columns.
4. **Diagonal hatching**: fields of fine, nearly parallel lines, bright and
   dark, at about 40°. They are confined to soft-edged zones (left edge, red
   band, upper-right wedge, bottom right).
5. **Horizontal grain**: fine horizontal streaks inside some blocks and along the
   shadow strip.
6. **Dark accents**: near-black scratches and soot along the warm/cool seams,
   mainly under the red band and between the ice column and the warm core.
7. **Speckle**: sparse red dots in the dark strip under the red band.

The fine texture is **anisotropic** everywhere. There is almost no isotropic
noise, so value noise or fbm looks wrong unless it is stretched hard along one
axis.

## 5. Digitisation ideas

These are rival approaches. Each was prototyped and scored (see section 6).

- **A: Rectangle collage.** Several layers of jittered rectangle grids, painted
  back to front. Each rectangle picks a colour from the base field at its centre,
  gets a grain direction and alpha, and is textured with 1D hash streaks along
  the grain. Composition comes from the base field; structure comes from the
  rectangles.
- **B: Smear field (procedural pixel sort / LIC).** Evaluate the base field with
  domain distortion: coordinates are quantised into blocks, and each pixel column
  gets a random vertical offset ("drag"), so colour is carried along the grain.
  A direction field picks vertical, horizontal or diagonal smearing per zone. In
  effect this is a line-integral convolution along a direction field.
- **C: Stroke splatting.** Each cell of a grid at several scales scatters oriented
  brush stroke quads (length, width, angle from the direction field). Strokes in
  the 3x3 neighbourhood are evaluated and composited by depth. This is the
  classic painterly approach.

## 6. Verdict

Scores from `go run ./cmd/imgstat score` (lower is better). The placeholder
scored 0.62 and a mirrored reference 0.61.

| rival            | col16 | col32 | palH  | palW  | dirC  | dirH  | texE  | texA  | score      | ms/frame |
| ---------------- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ---------- | -------- |
| A: collage       | 0.223 | 0.262 | 0.135 | 0.067 | 0.093 | 0.130 | 0.123 | 0.460 | 0.1827     | ~7.0     |
| B: smear field   | 0.197 | 0.240 | 0.147 | 0.060 | 0.101 | 0.057 | 0.131 | 0.451 | **0.1688** | ~8.1     |
| C: stroke splats | 0.204 | 0.239 | 0.149 | 0.070 | 0.122 | 0.078 | 0.142 | 0.409 | 0.1745     | ~8.9     |

The scores are close: the gap between B and C is about as large as the metric's
noise. The visual comparison therefore decides.

- **A** reads like a clean digital mosaic. The rectangles are too opaque and too
  regular, and the glow is missing.
- **C** has the best stroke texture (texA) and convincing ink scratches along the
  seams. However, its warm column looks woven or tiled, and its upper right
  dissolves into flat squares.
- **B** has the most painterly gesture: a fanned hatch at the top left, ice drips
  with pointed tips, paint dragged from the column into the band, and seams made
  of interleaved threads. All of this comes from smearing **one** coherent field,
  which keeps the colours consistent. Its weaknesses are a few flat dark blocks at
  the bottom left and a fine texture that is slightly glitchy or pixelated.

**Winner: B (smear field).** It becomes the base of `shaders/main.glsl`. These
parts of the other rivals are merged in:

- from C: the `bristles()` stroke texture, to soften B's pixelated grit inside
  blocks; the ink scratches along the yellow/ice seam; and the hue-split grade
  with dark sink.
- from A: the per-column warm/cool threshold that varies along the grain, the
  frayed "/" wedge, and the soot strip with a wandering edge.

## 7. Final shader

`shaders/main.glsl` is rival B, split into one include file per layer and
extended with parts of A and C. Every direction is one of the four fundamental
angles: 0°, 45°, 90° or 135°.

| Layer | File           | Content                                                                                                                                                                                                       |
| ----- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L0    | `field.glsl`   | B's anchor field (two colour families, hard switch) plus authored rectangles. Zone maps for the smear direction and block density. New: lighter blue drip anchors at the bottom, no blocks in the bottom left |
| L1    | `smear.glsl`   | B's strand/line smear. New: a per-hairline warm/cool threshold that wanders along the grain (from A), red hue threads (from A), and thin strands for diagonal hatching                                        |
| L2    | `blocks.glsl`  | B's four block grids and authored blocks. New: two translucent glaze bars in the upper right (grey "barcode" bar, steel-blue bar); the coral block carries 135° hatching                                      |
| L3    | `accents.glsl` | 45° frayed dark wedge (from A, snapped from ~52°), soot strip with wandering edges (from A), ink scratches on the hot/cold seams (from C), red specks (from B)                                                |
| L4    | `grade.glsl`   | soft warm glow over the yellow core (screen blend, warm pixels only), hue-split gain (from C)                                                                                                                 |

| shader                           | col16 | col32 | palH  | palW  | dirC  | dirH  | texE  | texA  | score  | ms/frame |
| -------------------------------- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ------ | -------- |
| B (free angles)                  | 0.197 | 0.240 | 0.147 | 0.060 | 0.101 | 0.057 | 0.131 | 0.451 | 0.1688 | ~8.4     |
| B, angles snapped to 0/45/90/135 | 0.198 | 0.241 | 0.150 | 0.061 | 0.137 | 0.174 | 0.131 | 0.467 | 0.1880 | ~8.4     |
| **final `main.glsl`**            | 0.204 | 0.244 | 0.156 | 0.073 | 0.124 | 0.208 | 0.138 | 0.500 | 0.1961 | ~8.6     |

Some notes on these numbers:

- **The angle constraint has a cost.** The reference's direction histogram
  spreads over 118–150° and 46–66°, so snapping every stroke to 45° or 135°
  costs about 0.02 on its own (dirH 0.057 → 0.174 for B). The fair baseline for
  the final shader is therefore "B snapped" (0.188), not B (0.169).
- **The final shader scores slightly worse than "B snapped" (+0.008).** The
  difference is at the metric's noise level, and it comes from changes that
  look clearly better:
  - thin 135° hatching lines instead of wide planks, and a hatched coral block
    (dirH rises because more mass sits exactly at 135°);
  - the glaze bars;
  - drips instead of flat blocks at the bottom left.
- **Two of C's ideas were tried and dropped.** On this stack, C's dark sink
  flattened the streak texture in the navy areas (dirC +0.04). C's bristle
  hairlines inside the smear pushed the vertical anisotropy further away from
  the reference (texA +0.05) and looked like sand. Only the bristle coverage in
  the ink scratches remains.
- **Remaining weaknesses:**
  - The upper ice and yellow columns are far too anisotropic (vertical/horizontal
    energy ratio 15–30, reference 4–5).
  - The lower warm column still reads as uniform orange "wood".
  - The yellow core is less luminous and less varied than in the reference.
- **Rendering:** the frame at iTime = 0 is the judged still, and the drips
  creep slowly over time. `just bundle` renders identically to the include
  version, and the bundle passes `glslangValidator` as GLSL ES 3.00.
