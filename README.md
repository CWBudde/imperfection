# Imperfection

A GLSL recreation of an abstract painting where a warm yellow, orange and red glow on
the left breaks up into rectangular brush blocks and vertical streaks, then fades
into dark blue on the right.

**▶ [Try it online](https://cwbudde.github.io/imperfection/)**: runs in any
browser with WebGL2 (`Space` pauses, `F` toggles fullscreen). On weaker GPUs, try the
**[lite version](https://cwbudde.github.io/imperfection/?lite)**: a single pass,
about three times cheaper.

The scene is written in Shadertoy form (`mainImage`) and split into include files.
A small Go runner (go-gl 4.1 core + GLFW 3.3, taken from `the-other-side`) renders it
in a window with hot reload. It can also render deterministic screenshots and
comparison montages, run benchmarks, and bundle everything into one file that you can
paste into Shadertoy.

## Layout

| Path                                                                 | Content                                                                                          |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `shaders/main.glsl`                                                  | Image pass: wet smear of Buffer A, then accents, glow, grade, sRGB (`#bufferA "paint.glsl"`)     |
| `shaders/paint.glsl`                                                 | Buffer A pass: the paint layers L0-L2, linear RGB; alpha packs grain direction, kind and wetness |
| `shaders/field.glsl`                                                 | L0: base colour field, authored rectangles, zone maps                                            |
| `shaders/smear.glsl`                                                 | L1: smear operator (procedural pixel sort), background layer                                     |
| `shaders/blocks.glsl`                                                | L2: rectangle grids, authored blocks and glazes                                                  |
| `shaders/wet.glsl`                                                   | W: wetness map and alpha packing (Buffer A), wet smear and sub-pixel edges (Image)               |
| `shaders/accents.glsl`                                               | L3: dark wedge, soot strip, seam ink scratches, red drips and flecks (Image, after the smear)    |
| `shaders/grade.glsl`                                                 | L4: glow over the yellow core, hue-split grade (Image)                                           |
| `shaders/anim.glsl`                                                  | the seamless loop clock shared by all layers                                                     |
| `shaders/common.glsl`                                                | constants, hashes, noise, colour helpers                                                         |
| `shaders/lite.glsl`                                                  | the lite version: everything in one pass, no buffer, ~3x cheaper                                 |
| `shaders/rival_{a,b,c}.glsl`                                         | the three competing prototypes (record, still renderable)                                        |
| `docs/analysis.md`                                                   | analysis of the reference, the rivals, the verdict                                               |
| `docs/animation.md`                                                  | the animation concept and rules                                                                  |
| `reference/reference.png`                                            | the target image (1024x1024)                                                                     |
| `main.go`, `render.go`, `pipeline.go`, `preprocess.go`, `compare.go` | the runner (`pipeline.go`: multipass)                                                            |
| `cmd/imgstat/`                                                       | image analysis and style scoring tool                                                            |
| `docs/reference-stats.txt`                                           | `imgstat analyze` of the reference                                                               |
| `web/`                                                               | WebGL2 player for the bundled passes (GitHub Pages)                                              |
| `.github/workflows/pages.yml`                                        | bundles the shaders and publishes `web/` to GitHub Pages                                         |
| `out/`                                                               | render output (git-ignored)                                                                      |

The painting renders in two passes. Buffer A (`paint.glsl`) paints L0-L2 crisp,
in linear colour, into the RGBA16F buffer; its alpha carries what the Image pass
needs per pixel. The Image pass (`main.glsl`) smears that paint along each pixel's
grain where it is wet (W), then draws the dry accents (L3) and the light (L4) on
top. Debug defines: `SHOW_FIELD`, `NO_BLOCKS`, `BLOCK_DEBUG`, `WET=0`,
`AA_EDGE=0`, `WET_LIC=1`, `SHOW_WET` (see the header of `main.glsl`).

`lite.glsl` paints the same picture in a single pass, at about a third of the cost
(1024x1024 on an Iris Xe: 4.4 instead of 14 ms/frame). It uses the same colour field,
directions and loop, but with less texture. Most of its savings come from the field:
`baseField` loops over its 83 colour anchors with a dynamic index into const arrays,
which costs ~7 ms per lookup at 1024x1024. `liteField` reads them unrolled, with
literal indices, in ~1 ms and gives the same colours. Each pixel needs exactly one
field lookup: a grid block, or the smeared background. There is no wet buffer pass.
In wet zones, the smear slides the lookup point toward the neighbouring segment near
a segment end, and the hairline offset becomes a smooth noise across the grain. The
lite version has one block grid instead of four, keeps the authored rectangles, the
wedge, the soot, the glow and the grade, and drops drips, ink scratches and flecks.
Render it with `-shader shaders/lite.glsl` (`-D ANIM=0`, `-D WET=0` and
`-D NO_BLOCKS=1` work as usual).

`main.glsl` grew out of a competition between three approaches: a rectangle
collage (A), a smear field (B) and stroke splatting (C). Each was prototyped as
`shaders/rival_*.glsl` and scored with `imgstat`. B won and became the base,
with parts of A and C merged in; `docs/analysis.md` documents the reasoning.
Render a rival with `-shader shaders/rival_b.glsl`.

## Build note: `-buildvcs=false`

There is a stray, empty `/mnt/projekte/Code/.git` above this project. Go detects it
as a repository, fails to stamp VCS information, and aborts the build. Pass
`-buildvcs=false` (or set `GOFLAGS=-buildvcs=false`; the justfile does this).

## Usage

```sh
go run -buildvcs=false . [flags]
```

| Flag                  | Meaning                                                                               |
| --------------------- | ------------------------------------------------------------------------------------- |
| `-shader FILE`        | main shader (default `shaders/main.glsl`)                                             |
| `-size WxH`           | window/render size (default `1024x1024`)                                              |
| `-D NAME=VALUE`       | inject a `#define` (repeatable)                                                       |
| `-shot OUT.png`       | render offscreen and exit                                                             |
| `-time T`             | `iTime` for `-shot`                                                                   |
| `-times a,b,c`        | several shots; files are named `OUT_tNN.N.png`                                        |
| `-frames N`, `-fps F` | with `-shot`: N frames from `-time` at F fps (default 30), named `OUT_00000.png`, ... |
| `-compare REF.png`    | with `-shot`: also write `OUT_cmp.png` (render left, `REF.png` right)                 |
| `-bench 3s`           | render offscreen for this long and print ms/frame (multipass: also GPU ms per pass)   |
| `-bundle OUT.glsl`    | write a self-contained Shadertoy file (includes inlined, defines applied), see below  |

Window mode (no `-shot`/`-bench`/`-bundle`) reloads the shader when any included file
changes. If the new version fails to compile, the runner prints the error log with
`file:line` and keeps rendering the last working version. Keys: `Space` pauses, `P`
saves a PNG, `Esc` quits. `iMouse` follows Shadertoy conventions.

`#include "file"` paths are relative to the including file and must stay inside the
directory of the main shader (they are read through an `os.Root`).

### Multipass: Buffer A

A shader can render in two passes, like a Shadertoy with a Buffer A tab. The Image
shader (the `-shader` file) names its buffer with a directive line:

```glsl
#bufferA "paint.glsl"
```

- The preprocessor removes the line. The path follows the `#include` rules: relative
  to the file that contains the directive, inside the directory of the main shader.
  The directive may appear once per shader, and Buffer A itself cannot declare one.
- Each frame, Buffer A renders first, with the same uniforms and `-D` defines, into
  an RGBA16F texture of the render size. Values above 1 and fine gradients survive.
- The Image pass reads Buffer A on `iChannel0` with linear filtering and clamp to
  edge, without mipmaps. `iChannelResolution[0]` holds the buffer size. The other
  channels, and all channels of Buffer A, read black.
- The buffer is reallocated when the window is resized.
- Hot reload watches the files of both passes. If either pass fails to compile,
  the runner keeps the last pair that worked. Errors in Buffer A start with
  `Buffer A pass:`.
- `-bench` prints the GPU time of each pass (timer queries) below the frame time.

Shaders without the directive render in one pass, exactly as before.

The directive is also recognised as a line comment, `// #bufferA "file"`. Bundles use
that form, see below. A commented-out directive is therefore still active: to make a
shader single-pass, delete the line.

### Shadertoy bundles

`-bundle OUT.glsl` inlines all includes and puts the `-D` defines on top as `#define`
lines. A single-pass shader gives one file for the Image tab.

A multipass shader gives two files:

- `OUT.glsl` goes into the Image tab.
- `OUT_bufferA.glsl` goes into the Buffer A tab.

The header of `OUT.glsl` says to set the Image tab's iChannel0 to Buffer A with
filter "linear" and wrap "clamp". It ends with `// #bufferA "OUT_bufferA.glsl"`.
Shadertoy treats that line as a comment, but the runner reads it, so
`-shader OUT.glsl` renders the bundle back with both passes. `just bundle` uses
that as its check. Keep the two files next to each other.

The lite version is a single pass, so `just bundle-lite` writes one file,
`out/shadertoy_lite.glsl`, for the Image tab. No Buffer A or channel setup is needed.

### justfile recipes

| Recipe                                                 | Does                                                                        |
| ------------------------------------------------------ | --------------------------------------------------------------------------- |
| `just run [args]`                                      | window mode with hot reload (also the default recipe)                       |
| `just shot [times] [args]`                             | offscreen shots into `out/`                                                 |
| `just compare [REF] [times] [args]`                    | shots plus `_cmp` montages against `REF` (default: the reference image)     |
| `just clip [start] [dur] [fps] [args]`                 | frame sequence into `out/clip/`, encoded as `out/clip.mp4` (needs ffmpeg)   |
| `just sheet [dir] [every] [grid] [crop] [width] [out]` | contact sheet of every n-th frame, for judging motion                       |
| `just bench [dur] [args]`                              | benchmark at 1024x1024 and 2048x2048 (lite: `-shader shaders/lite.glsl`)    |
| `just bundle [args]`                                   | write `out/shadertoy.glsl` (+ `_bufferA`) and render it back as a check     |
| `just bundle-lite [args]`                              | write `out/shadertoy_lite.glsl` (lite version, one file) and render it back |
| `just web [port] [args]`                               | bundle into `out/web` with the WebGL2 player and serve it on `:8000`        |
| `just stat [img]`                                      | `imgstat analyze` (default: the reference)                                  |
| `just stat-ref`                                        | regenerate `docs/reference-stats.txt`                                       |
| `just score [renders...]`                              | `imgstat score` against the reference (default: `out/shot.png`)             |
| `just diff [render] [out]`                             | `imgstat diff` montage (default: `out/shot.png` into `out/diff.png`)        |
| `just setup-deps`                                      | install treefmt, prettier, gofumpt, gci, shfmt, golangci-lint               |
| `just fmt`                                             | format with treefmt (`treefmt.toml`; GLSL is not formatted)                 |
| `just lint` / `just lint-fix`                          | golangci-lint with `.golangci.toml`                                         |
| `just fix`                                             | `lint-fix`, then `fmt`                                                      |
| `just check`                                           | formatted, lint, `go mod tidy -diff`, build and vet                         |

## Web version

Live at <https://cwbudde.github.io/imperfection/>. On every push to `main`,
the Pages workflow bundles the shaders and publishes them with the small WebGL2 player
in `web/`, which runs the same two passes as the Go runner (Buffer A in a half-float
texture, then the Image pass). It needs `EXT_color_buffer_float`, because the Buffer A
alpha packs integers that an 8-bit target would destroy. The canvas is the largest
centred square that fits the window. It renders at most 1080 lines and lowers the
resolution further when frames take longer than about 45 ms. `?scale=0.5` fixes the
render scale, `?t=20` sets the start time. `?lite` runs the single-pass lite version
(`lite.glsl`), which needs no float render target; the link in the corner switches
between both versions. Keys: `Space` pauses, `F` or a double click toggles fullscreen.
`just web` builds and serves the same site locally.

## Image statistics: `cmd/imgstat`

A stdlib-only tool that describes the reference in numbers and scores renders by
style and composition, not by pixel equality. The reference is always the first
image argument; renders of another size are resampled to its size.

```sh
go run ./cmd/imgstat analyze IMAGE.png
go run ./cmd/imgstat score REF.png RENDER.png [RENDER.png ...]
go run ./cmd/imgstat diff REF.png RENDER.png OUT.png
```

`analyze` prints a 10-colour k-means palette in OKLab (share and mean position), an
8x8 colour and lightness map, a structure-tensor stroke direction field with a global
orientation histogram, the strongest long horizontal and vertical block edges (with
the colours on either side) and fine texture energy and anisotropy per cell.
Positions are given as `uv` with the origin at the bottom left, as in the shader.
Grids are printed as seen on screen, with the top row at the highest `v`.
Orientations are measured along the stroke, counter-clockwise: 0 = horizontal,
90 = vertical. `docs/reference-stats.txt` holds the output for the reference.

`score` combines eight components, each normalised so that the reference scores 0
against itself and a flat image in the reference's mean colour scores about 1:

| key     | measures                                                             | weight |
| ------- | -------------------------------------------------------------------- | ------ |
| `col16` | mean OKLab dE of 16x16 box-filtered images (composition)             | 0.20   |
| `col32` | the same at 32x32                                                    | 0.15   |
| `palH`  | Hellinger distance of 8x8x8 OKLab histograms                         | 0.10   |
| `palW`  | sliced Wasserstein (earth mover) distance of the pixel colours       | 0.10   |
| `dirC`  | per-cell (8x8) stroke angle difference, weighted by ref coherence    | 0.15   |
| `dirH`  | circular earth mover distance of the global orientation histograms   | 0.10   |
| `texE`  | per-cell log ratio of high-pass energy (fine brush texture strength) | 0.12   |
| `texA`  | per-cell difference of vertical vs horizontal streak anisotropy      | 0.08   |

The score is the weighted mean, so lower is better. Reference values: the reference
itself 0, the reference mirrored horizontally about 0.61, flat mid-grey about 1.07.
Mirroring keeps palette and texture but moves everything to the wrong side, so the
composition terms go above 1. With one render `score` prints the raw values, scales
and contributions. With several it prints one table row per render.

`diff` writes a 2x2 montage: the render, the reference, a 32x32 OKLab dE heatmap
(black = equal, yellow = dE 0.3 or more) and a 32x32 stroke orientation difference
map (yellow = 90 degrees off). The orientation map is dimmed where the reference has
no clear direction.

## Credits

The hash functions in `common.glsl` follow Dave Hoskins' "Hash without Sine" (MIT).
