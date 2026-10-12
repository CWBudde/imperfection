// Imperfection - WebGL2 player for the bundled Shadertoy passes.
//
// Mirrors the Go runner: shadertoy.glsl is the Image pass. If it names a
// Buffer A file in a `// #bufferA "..."` comment, that pass renders first into
// a half-float texture (filter linear, wrap clamp, no mipmaps) that the Image
// pass reads on iChannel0. Both files come from `go run . -bundle`. With ?lite
// the player runs lite.glsl instead, the single-pass version
// (shaders/lite.glsl), which is about three times cheaper.
//
// Buffer A packs integers up to 1023 into its alpha, which only a float target
// holds exactly, so the full version needs EXT_color_buffer_float.
//
// URL parameters: ?lite runs the lite version, ?scale=0.75 fixes the render
// scale (default: adaptive, at most 1080 lines), ?t=20 starts at iTime 20.
//
// Adaptive scale: the median frame interval over a window of frames decides,
// so single hitches (GC, tab switches) do not count. Vsync quantises the
// interval (a frame that misses 60 Hz shows at 33 ms), hence the wide gap
// between the two thresholds: one step down costs 0.64x the pixels, so a
// step up from below FAST_MS cannot land above SLOW_MS and oscillate.

const MAX_LINES = 1080; // render height cap at scale 1
const SCALE_STEP = 0.8; // scale ratio between adaptive levels
const MAX_LEVEL = 4; // lowest adaptive scale is SCALE_STEP^MAX_LEVEL (0.41)
const SLOW_MS = 45; // median frame interval above which the scale steps down
const FAST_MS = 20; // median frame interval below which it steps back up
const WINDOW = 90; // frame intervals per decision

const canvas = document.getElementById("view");
const params = new URLSearchParams(location.search);

function fail(msg) {
  const el = document.getElementById("error");
  el.textContent = msg;
  el.hidden = false;
  throw new Error(msg);
}

const gl = canvas.getContext("webgl2", {
  antialias: false,
  alpha: false,
  depth: false,
});
if (!gl) fail("WebGL2 is not available in this browser.");

// The link in the credits switches between the full and the lite version and
// keeps the other parameters.
const lite = params.has("lite");
const other = new URLSearchParams(params);
if (lite) other.delete("lite");
else other.set("lite", "");
const mode = document.getElementById("mode");
mode.textContent = lite ? "full version" : "lite version";
mode.href = "?" + other.toString().replace(/=(&|$)/g, "$1");

const vertexSource = `#version 300 es
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`;

// Same uniform set as the Go runner's fragmentPrefix.
const fragmentPrefix = `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
uniform vec3  iResolution;
uniform float iTime;
uniform float iTimeDelta;
uniform float iFrameRate;
uniform int   iFrame;
uniform vec4  iMouse;
uniform vec4  iDate;
uniform float iSampleRate;
uniform float iChannelTime[4];
uniform vec3  iChannelResolution[4];
uniform sampler2D iChannel0;
uniform sampler2D iChannel1;
uniform sampler2D iChannel2;
uniform sampler2D iChannel3;
out vec4 shadertoyFragColor;
`;

// Buffer A keeps its alpha (it carries packed data), the Image pass is opaque.
const bufferPostfix = `
void main() {
    shadertoyFragColor = vec4(0.0, 0.0, 0.0, 1.0);
    mainImage(shadertoyFragColor, gl_FragCoord.xy);
}
`;

const imagePostfix = `
void main() {
    shadertoyFragColor = vec4(0.0, 0.0, 0.0, 1.0);
    mainImage(shadertoyFragColor, gl_FragCoord.xy);
    shadertoyFragColor.a = 1.0;
}
`;

function compile(type, source, name) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, source);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    fail(`${name}: compile failed\n\n${gl.getShaderInfoLog(sh)}`);
  }
  return sh;
}

function buildPass(body, postfix, name) {
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl.VERTEX_SHADER, vertexSource, "vertex"));
  gl.attachShader(
    prog,
    compile(gl.FRAGMENT_SHADER, fragmentPrefix + body + postfix, name),
  );
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    fail(`${name}: link failed\n\n${gl.getProgramInfoLog(prog)}`);
  }
  const loc = {};
  for (const n of [
    "iResolution",
    "iTime",
    "iTimeDelta",
    "iFrameRate",
    "iFrame",
    "iMouse",
    "iDate",
    "iChannel0",
    "iChannelResolution",
  ]) {
    loc[n] = gl.getUniformLocation(prog, n);
  }
  return { prog, loc };
}

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) fail(`${url}: ${res.status} ${res.statusText}`);
  return res.text();
}

const imageSrc = await fetchText(lite ? "lite.glsl" : "shadertoy.glsl");
const bufferName = imageSrc.match(/^\s*\/\/\s*#bufferA\s+"([^"]+)"/m)?.[1];
if (bufferName && !gl.getExtension("EXT_color_buffer_float")) {
  fail(
    "This browser cannot render to float textures (EXT_color_buffer_float).\n" +
      "Try the lite version (?lite), which needs no buffer.",
  );
}
const bufA = bufferName
  ? buildPass(await fetchText(bufferName), bufferPostfix, bufferName)
  : null;
const image = buildPass(imageSrc, imagePostfix, "shadertoy.glsl");

gl.bindVertexArray(gl.createVertexArray());

// ---- Buffer A target ---------------------------------------------------------
let target = null; // { tex, fbo, w, h }

function makeTarget(w, h) {
  if (target) {
    gl.deleteFramebuffer(target.fbo);
    gl.deleteTexture(target.tex);
  }
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, w, h);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  const fbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(
    gl.FRAMEBUFFER,
    gl.COLOR_ATTACHMENT0,
    gl.TEXTURE_2D,
    tex,
    0,
  );
  if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
    fail("Buffer A framebuffer is incomplete.");
  }
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  target = { tex, fbo, w, h };
}

// ---- sizing ------------------------------------------------------------------
const fixedScale = params.has("scale")
  ? Math.min(Math.max(parseFloat(params.get("scale")) || 1, 0.1), 2)
  : null;
let level = 0; // adaptive level, scale = SCALE_STEP^level
let scale = fixedScale ?? 1;

function resize() {
  const dpr = window.devicePixelRatio || 1;
  let w = canvas.clientWidth * dpr;
  let h = canvas.clientHeight * dpr;
  const cap = Math.min(1, MAX_LINES / h);
  w = Math.max(1, Math.round(w * cap * scale));
  h = Math.max(1, Math.round(h * cap * scale));
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
  if (bufA && (!target || target.w !== w || target.h !== h)) makeTarget(w, h);
}

// ---- input -------------------------------------------------------------------
let paused = false;
window.addEventListener("keydown", (e) => {
  if (e.code === "Space") {
    paused = !paused;
    e.preventDefault();
  } else if (e.code === "KeyF") {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen();
  }
});
canvas.addEventListener("dblclick", () => {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen();
});

// ---- frame loop --------------------------------------------------------------
let time = parseFloat(params.get("t")) || 0;
let frame = 0;
let last = null;
let samples = []; // frame intervals (ms) since the last decision
let settle = 30; // frames to skip after start, a scale change or a hidden tab

document.addEventListener("visibilitychange", () => {
  last = null;
  samples = [];
  settle = 30;
});

function setUniforms(p, w, h, dt) {
  const now = new Date();
  gl.uniform3f(p.loc.iResolution, w, h, 1);
  gl.uniform1f(p.loc.iTime, time);
  gl.uniform1f(p.loc.iTimeDelta, dt);
  gl.uniform1f(p.loc.iFrameRate, dt > 0 ? 1 / dt : 60);
  gl.uniform1i(p.loc.iFrame, frame);
  gl.uniform4f(p.loc.iMouse, 0, 0, 0, 0);
  gl.uniform4f(
    p.loc.iDate,
    now.getFullYear(),
    now.getMonth(),
    now.getDate(),
    now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds(),
  );
}

function adapt(ms) {
  if (fixedScale !== null) return;
  if (settle > 0) {
    settle--;
    return;
  }
  samples.push(ms);
  if (samples.length < WINDOW) return;
  const median = samples.sort((a, b) => a - b)[WINDOW >> 1];
  samples = [];
  let next = level;
  if (median > SLOW_MS && level < MAX_LEVEL) next++;
  else if (median < FAST_MS && level > 0) next--;
  if (next === level) return;
  level = next;
  scale = SCALE_STEP ** level;
  settle = 30;
  console.info(
    `median frame ${median.toFixed(1)} ms, render scale now ${scale.toFixed(2)}`,
  );
}

function draw(nowMs) {
  const raw = last === null ? 0 : nowMs - last;
  const dt = Math.min(raw / 1000, 0.1);
  last = nowMs;
  if (!paused) {
    time += dt;
    if (raw > 0) adapt(raw);
  }
  resize();
  const w = canvas.width;
  const h = canvas.height;
  gl.viewport(0, 0, w, h);

  // Buffer A: the paint layers. Nothing is bound, so its iChannels read black.
  if (bufA) {
    gl.bindTexture(gl.TEXTURE_2D, null);
    gl.bindFramebuffer(gl.FRAMEBUFFER, target.fbo);
    gl.useProgram(bufA.prog);
    setUniforms(bufA, w, h, dt);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindTexture(gl.TEXTURE_2D, target.tex);
  }

  // Image: Buffer A (if any) on iChannel0.
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.useProgram(image.prog);
  setUniforms(image, w, h, dt);
  gl.uniform1i(image.loc.iChannel0, 0);
  const res = new Float32Array(12);
  if (bufA) res.set([w, h, 1]);
  gl.uniform3fv(image.loc.iChannelResolution, res);
  gl.drawArrays(gl.TRIANGLES, 0, 3);

  if (!paused) frame++;
  requestAnimationFrame(draw);
}

requestAnimationFrame(draw);
