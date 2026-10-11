# Imperfection

A GLSL recreation of `reference/reference.png`: an abstract painting where a warm
yellow, orange and red glow on the left breaks up into rectangular brush blocks and
vertical streaks, then fades into dark blue on the right.

The scene is written in Shadertoy form (`mainImage`) and split into include files.
A small Go runner (go-gl 4.1 core + GLFW 3.3, taken from `the-other-side`) renders it
in a window with hot reload. It can also render deterministic screenshots and
comparison montages, run benchmarks, and bundle everything into one file that you can
paste into Shadertoy.

## Layout

| Path                                                  | Content                                                      |
| ----------------------------------------------------- | ------------------------------------------------------------ |
| `shaders/main.glsl`                                   | the layer stack, composited back to front                    |
| `shaders/field.glsl`                                  | L0: base colour field, authored rectangles, zone maps        |
| `shaders/smear.glsl`                                  | L1: smear operator (procedural pixel sort), background layer |
| `shaders/blocks.glsl`                                 | L2: rectangle grids, authored blocks and glazes              |
| `shaders/accents.glsl`                                | L3: dark wedge, soot strip, seam ink scratches, red specks   |
| `shaders/grade.glsl`                                  | L4: glow over the yellow core, hue-split grade               |
| `shaders/common.glsl`                                 | constants, hashes, noise, colour helpers                     |
| `shaders/rival_{a,b,c}.glsl`                          | the three competing prototypes (record, still renderable)    |
| `docs/analysis.md`                                    | analysis of the reference, the rivals, the verdict           |
| `reference/reference.png`                             | the target image (1024x1024)                                 |
| `main.go`, `render.go`, `preprocess.go`, `compare.go` | the runner                                                   |
| `cmd/imgstat/`                                        | image analysis and style scoring tool                        |
| `docs/reference-stats.txt`                            | `imgstat analyze` of the reference                           |
| `out/`                                                | render output (git-ignored)                                  |

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
| `-bench 3s`           | render offscreen for this long and print ms/frame                                     |
| `-bundle OUT.glsl`    | write one self-contained Shadertoy file (includes inlined, defines applied)           |

Window mode (no `-shot`/`-bench`/`-bundle`) reloads the shader when any included file
changes. If the new version fails to compile, the runner prints the error log with
`file:line` and keeps rendering the last working version. Keys: `Space` pauses, `P`
saves a PNG, `Esc` quits. `iMouse` follows Shadertoy conventions.

`#include "file"` paths are relative to the including file and must stay inside the
directory of the main shader (they are read through an `os.Root`).

### justfile recipes

| Recipe                                                 | Does                                                                      |
| ------------------------------------------------------ | ------------------------------------------------------------------------- |
| `just run [args]`                                      | window mode with hot reload (also the default recipe)                     |
| `just shot [times] [args]`                             | offscreen shots into `out/`                                               |
| `just compare [REF] [times] [args]`                    | shots plus `_cmp` montages against `REF` (default: the reference image)   |
| `just clip [start] [dur] [fps] [args]`                 | frame sequence into `out/clip/`, encoded as `out/clip.mp4` (needs ffmpeg) |
| `just sheet [dir] [every] [grid] [crop] [width] [out]` | contact sheet of every n-th frame, for judging motion                     |
| `just bench [dur] [args]`                              | benchmark at 1024x1024 and 2048x2048                                      |
| `just bundle [args]`                                   | write `out/shadertoy.glsl` and render it back as a check                  |
| `just stat [img]`                                      | `imgstat analyze` (default: the reference)                                |
| `just stat-ref`                                        | regenerate `docs/reference-stats.txt`                                     |
| `just score [renders...]`                              | `imgstat score` against the reference (default: `out/shot.png`)           |
| `just diff [render] [out]`                             | `imgstat diff` montage (default: `out/shot.png` into `out/diff.png`)      |
| `just setup-deps`                                      | install treefmt, prettier, gofumpt, gci, shfmt, golangci-lint             |
| `just fmt`                                             | format with treefmt (`treefmt.toml`; GLSL is not formatted)               |
| `just lint` / `just lint-fix`                          | golangci-lint with `.golangci.toml`                                       |
| `just fix`                                             | `lint-fix`, then `fmt`                                                    |
| `just check`                                           | formatted, lint, `go mod tidy -diff`, build and vet                       |

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
