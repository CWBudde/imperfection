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

It renders in two passes. **Buffer A** (`paint.glsl`) paints L0–L2 crisp, in
linear colour, into an RGBA16F buffer. Its alpha packs, per pixel, the grain
direction index of the topmost paint (0/45/90/135°), the kind of paint
(background, grid block, hero block, glaze) and a wetness 0..1 into one exact
integer (`dir + 4·kind + 16·round(63·wet)`, ≤ 1023, exact in half floats). The
paint layers know each pixel's true grain, including block grain, so the post
pass does not recompute the direction field. The **Image** pass (`main.glsl`)
smears that paint where it is wet (W), then draws the dry accents (L3) and the
light (L4) on top, and encodes sRGB.

| Pass     | Layer | File           | Content                                                                                                                                                                                                                  |
| -------- | ----- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Buffer A | L0    | `field.glsl`   | B's anchor field (two colour families, hard switch) plus authored rectangles. Zone maps for the smear direction and block density. New: lighter blue drip anchors at the bottom, no blocks in the bottom left            |
| Buffer A | L1    | `smear.glsl`   | B's strand/line smear. New: a per-hairline warm/cool threshold that wanders along the grain (from A), red hue threads (from A), and thin strands for diagonal hatching                                                   |
| Buffer A | L2    | `blocks.glsl`  | B's four block grids and authored blocks. New: two translucent glaze bars in the upper right (grey "barcode" bar, steel-blue bar); the coral block carries 45° hatching                                                  |
| both     | W     | `wet.glsl`     | Buffer A: wetness map and alpha packing. Image: wet smear (directional bilateral line integral along the grain) and sub-pixel edge softening                                                                             |
| Image    | L3    | `accents.glsl` | 45° dark wedge painted from brush strokes (from A, snapped from ~52°; §8), soot strip with wandering edges (from A), ink scratches on the hot/cold seams (from C), red drips and dry-brush dabs; edges soft over ~1.5 px |
| Image    | L4    | `grade.glsl`   | soft warm glow over the yellow core (screen blend, warm pixels only), hue-split gain (from C)                                                                                                                            |

### The wet smear (W)

The single-pass shader looked "pixel hard": crisp 1 px grit and binary 1 px
edges everywhere. The reference has wet, smeared paint (blended runs, soft
glazes, streaks that blur along their length) next to a few crisp dry marks.
W works in three steps:

- **Edges.** No edge stays a binary pixel cut. Each pixel line along the
  grain, in pieces of 3–9 px, samples Buffer A at a hashed fractional offset
  (±0.7 px), and two bilinear taps on texel corners make a 3x3 tent around
  that point. Block sides, strand ends and drip tips get a 1–2 px transition
  at their own sub-pixel position: edgy, but not cut. This applies to dry
  paint too. The accents, drawn after the smear, soften their own edges
  analytically (coverage ramps instead of `step`/`if` cuts, dashes that end
  within a pixel, the ink supersampled twice across the stroke).
- **Run.** 12 bilinear taps along the grain, crowded toward the centre and
  72 % upstream (paint is dragged downstream). The run length is 4–40 ref px
  times the wetness, heavy-tailed per brush strand (mostly short, a few long
  runs), drifts slowly along the strand and breathes over the loop
  (`loopNoise`, ×ANIM). The taps alternate up to 0.9 ref px across the grain.
- **No mud.** Taps are weighted bilaterally by their similarity to the
  centre, in sqrt-RGB (where the average is also taken), with a tolerance
  that grows with wetness. Taps of the other colour family (warm vs cool) are
  dropped, except within 2 px, which is anti-aliasing. Warm and cool never
  blend into grey over a distance; strong edges survive while small grit
  melts.

Wetness map (`wetZone` × per-kind factor): the glow/core area, the lower
drips, the bottom-left drips and the smeared band are wettest. The ice column
is drier (0.55, §8), so its drips keep their dry-brush breaks. The navy right
side is fairly dry. Diagonal hatching (×0.75) and horizontal band grain (×0.6)
get shorter runs. Blocks get short runs along their grain (grid ×0.55, hero
×0.4, glaze ×0.5). `-D SHOW_WET=1` shows the map.

Both directional variants were tried. One uses the centre pixel's direction
for the whole run; the other is a true LIC that walks on along the direction
found under each tap (`-D WET_LIC=1`). They render practically the same image
(mean absolute difference 2e-5): directions are constant over whole zones,
and at zone borders the weights reject the taps anyway. The LIC costs ~0.9 ms
more, so the centre direction is the default.

| shader                           | col16 | col32 | palH  | palW  | dirC  | dirH  | texE  | texA  | score  | ms/frame |
| -------------------------------- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ------ | -------- |
| B (free angles)                  | 0.197 | 0.240 | 0.147 | 0.060 | 0.101 | 0.057 | 0.131 | 0.451 | 0.1688 | ~8.4     |
| B, angles snapped to 0/45/90/135 | 0.198 | 0.241 | 0.150 | 0.061 | 0.137 | 0.174 | 0.131 | 0.467 | 0.1880 | ~8.4     |
| first `main.glsl` (static)       | 0.204 | 0.244 | 0.156 | 0.073 | 0.124 | 0.208 | 0.138 | 0.500 | 0.1961 | ~8.6     |
| single pass (before W)           | 0.206 | 0.243 | 0.156 | 0.065 | 0.126 | 0.168 | 0.139 | 0.438 | 0.1872 | ~10.3    |
| **two passes with W**            | 0.206 | 0.243 | 0.154 | 0.074 | 0.128 | 0.176 | 0.125 | 0.518 | 0.1936 | ~11.9    |

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
- **The wet smear (W) costs +0.006 on the score but fixes the look.** The
  rows "single pass" and "two passes with W" are means over t = 0, 8, 16 and
  24 s. texE improves (0.139 → 0.125): the excess fine grit in the warm and
  ice areas melts. texA gets worse (0.44 → 0.52), and dirH a little. A
  directional blur sharpens whatever direction a cell already has. Most of
  the texA loss sits in cells whose direction was already wrong before W
  (the horizontal orange drag at u ≈ 0.5, v ≈ 0.4; the slate blocks at the
  left), and in the vertical areas, where the reference keeps more variation
  along the streaks than a blur leaves. Shorter runs buy back only 0.0015 and
  lose the smear, so the longer runs stay. Judged visually, W removes the
  pixel-hard look: runs, drip tips and block edges read as wet paint with
  edgy but soft edges, and warm and cool stay clean.
- **Remaining weaknesses:**
  - The upper ice and yellow columns are too anisotropic (W makes this a bit
    stronger), and the lower column lost some hairline crispness: the
    reference keeps sharp 1 px hairlines there.
  - The lower warm column still reads as uniform orange, now as smooth wet
    paint rather than "wood"; its cool threads are short blobs, not long
    thin lines.
  - The red flecks in the soot are thin bars with soft but straight edges;
    the reference's specks are blotchier.
  - The yellow core is less luminous and less varied than in the reference.
- **Rendering:** the frame at iTime = 0 is the judged still. The loop is
  seamless (t = 0 and t = 32 render identically), and `-D ANIM=0` freezes
  both passes. `just bundle` writes the Image and Buffer A files, renders
  identically to the include version, and both files pass `glslangValidator`
  as GLSL ES 3.00. GPU time at 1024x1024 on the Iris Xe: Buffer A ~8.6 ms,
  Image ~2.65 ms (W ~2 ms of that), ~11.9 ms per frame. Both passes compile
  to SIMD16 (Buffer A has a margin of about three live floats, see
  `paint.glsl`).

## 8. Polish

A final pass over the weaknesses listed above and a few more found in the
motion review. All directions stay at 0°, 45°, 90° and 135°.

- **Upper-right wedge (L3).** It was a flat, near-black triangle with a
  ruler-straight 45° edge. It is now painted from lanes of 45° strokes,
  3–11 px wide, in groups. Every stroke segment reaches its own distance out
  of the wedge or stops short of it. Whole groups step in or out in pieces
  along the edge, and each lane starts and ends such a piece at its own
  place, with the step tapering toward the piece ends. The edge is a ragged
  staircase of strokes, not a line, and stepped groups end like a brush
  lifting off rather than as rotated boxes. Inside, the strokes lie on a
  translucent dark ground whose opacity varies per lane; it is densest just
  behind the edge and thins deep in the corner. The bristles break into dry
  dashes, so the blue below shows through as 45° texture. Coverage is
  gamma-shaped, as for the ink. The strokes still slide along their lanes
  and the edge breathes.
- **Hero silhouettes (L2).** Hero hairline ends now scatter by only a few
  px and mostly fall short of the edge, and heroes no longer have bleeding
  hairlines. On the coral block's 45° grain those had made every edge hairy.
  A second cause of the "hairy pink blob" only showed in motion: the
  background's 45° smear and the grid blocks around the coral read the
  coral rectangle out of the field and dragged it outwards. This was visible
  whenever the grid blocks over it wiped out. `baseField` now has a
  background view (`thr + FIELD_BG`) that skips the rectangles in `BG_SKIP`
  (coral, both slate blocks). Only the heroes themselves see those. The
  re-sort sweep brightens its band less (`HERO_GLOW` 0.2). The hero lookup
  stays closer to its centre, so a hero no longer picks up stripes of an
  overlapping rectangle. The coral is a little redder and carries stronger
  45° streaks (grain 0.38). It now reads as a hatched rectangle with soft,
  painted edges at every instant.
- **Bottom left.** The two slate blocks read as calm rectangles with
  horizontal grain. Their paint is no longer dragged into stairs (see
  `BG_SKIP`). The horizontal background zone ends at u = 0.185, and grid
  blocks there are rarer and less often horizontal. The lighter block is a
  little lighter, so the pair separates.
- **Lower warm column.** The cool threads come from narrower, taller noise
  cells with a steep ramp, so they read as long 1–3 px lines instead of
  short blobs. The wet pass keeps the column's vertical hairlines crisp
  (`CRISP`): it uses an along-grain tent, cross jitter and cross taps are
  reduced to a quarter, and the runs are shorter. The strand contrast there
  is raised.
- **Ice and yellow columns.** Bristle skips (short breaks across several
  lines) are 4× as frequent in the cool top (`SKIP_COOL`), and the ice
  column is drier. texA in the worst ice cells drops from about 13 to about
  7–8; the reference has 2–5. The seam ink has more broad smudges and
  slightly lighter pen lines, which read less like graphic bars. The glaze
  bars are drier (×0.5), and their tone runs are shorter.
- **Navy bottom right.** The strand contrast in the bottom right is higher
  (texture gain +1.0), and one light drip anchor is a little lighter and
  wider. This gives more light and dark drips without lifting the mean
  colour; lifting all three anchors cost col16.
- **Red soot accents.** The flecks are now blotchy dabs, 2.5–13 px along 0°
  and 1.5–3.5 px across. Every pixel column has its own extent, and the
  interior is dry. They sit in tight clusters scattered over a wider band
  under the drips, no longer in one row. A third of the drips have no bead
  and simply taper out, and the bead weight varies, which breaks up the row
  of "pins".

Motion review (full loop at 512 px and 15 fps, full-resolution crop strips
at 0.5 s steps): the composition holds and nothing pops. The mean
frame-to-frame change is flat over the loop (median 0.0116, max 0.0126),
and the step across the loop seam (0.0121) is the same as any other step.
Grid blocks wipe in and out at staggered times, drips run, the wedge
strokes slide, and the flecks are dabbed in and fade. The coral and slate
heroes keep their silhouettes in every frame, also during sweeps. The
stills at t = 4, 12, 20 and 28 s are all sound.

| shader                    | col16 | col32 | palH  | palW  | dirC  | dirH  | texE  | texA  | score  |
| ------------------------- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- | ------ |
| before polish (mean of 4) | 0.209 | 0.246 | 0.155 | 0.078 | 0.128 | 0.188 | 0.120 | 0.503 | 0.1942 |
| **after polish**          | 0.218 | 0.252 | 0.176 | 0.078 | 0.127 | 0.138 | 0.106 | 0.487 | 0.1912 |

Means over t = 0, 8, 16 and 24 s. dirH gains most, mainly from the coral
and the clean hero edges. texE and texA improve. palH and col16 lose a
little, because the flat black wedge was a large share of the reference's
near-black. The painted wedge keeps the blue texture visible, which the eye
prefers.

Rendering: the loop is still seamless (t = 0 and t = 32 score 0.0000), and
`-D ANIM=0` freezes both passes (identical frames). `just bundle` renders
identically, and both files pass `glslangValidator` as GLSL ES 3.00. Both
passes compile to SIMD16. The GPU clock on the test machine drifted during
this session (the unchanged pre-polish shaders measured between 8.6 and
10.6 ms in Buffer A), so the cost is given against the snapshot measured
alternately under the same conditions: Buffer A ~9.4–9.7 ms (snapshot
~9.1), Image ~2.35 ms (snapshot ~2.25), ~12.2–12.6 ms per frame at
1024x1024.

Still open: the ice column is more anisotropic than the reference (texA
7–8 vs 2–5 in its worst cells), and its large strands with pointed drip
tips read more "icicle" than dry brush. The lower warm column is closer
to the reference's hairlines, but it is still more uniform orange than the
reference's patchwork of red, orange and blocks. The wedge sits where it
always did (its edge meets v = 0.61 at u ≈ 0.73; the reference's at
u ≈ 0.85).
