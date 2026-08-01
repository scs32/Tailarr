#version 460 core
#include <flutter/runtime_effect.glsl>

// Fabric-mesh voice orb.
//
// Renders a sphere whose surface is a soft woven lattice (warp + weft threads,
// interlaced over/under) that gently undulates like cloth in a faint breeze —
// a playful nod to the tailnet mesh. Layered value-noise (fbm) displaces the
// weave for the drift; a simple diffuse + fresnel term gives the threads
// material depth. Mint/teal palette on the app's charcoal background.
//
// Uniforms are set positionally by the Dart painter, in this order:
//   0,1 -> uSize (canvas size in px)
//   2   -> uTime (seconds, monotonic)
//   3   -> uIntensity (0 idle .. 1 active)
precision mediump float;

uniform vec2 uSize;
uniform float uTime;
uniform float uIntensity;

out vec4 fragColor;

const vec3 kAccent = vec3(0.306, 0.800, 0.639); // #4ECCA3
const vec3 kBlue   = vec3(0.000, 0.659, 0.910); // #00A8E8
const vec3 kBg     = vec3(0.196, 0.196, 0.243); // #32323E

float hash(vec3 p) {
  p = fract(p * 0.3183099 + 0.1);
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(hash(i + vec3(0.0, 0.0, 0.0)), hash(i + vec3(1.0, 0.0, 0.0)), f.x),
        mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
    mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
        mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y),
    f.z);
}

float fbm(vec3 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * vnoise(p);
    p *= 2.0;
    a *= 0.5;
  }
  return v;
}

// Rounded thread coverage + height for one axis of the weave.
// cellCoord in [-0.5, 0.5]; returns a soft bump peaking at the thread centre.
float thread(float cellCoord) {
  return max(cos(cellCoord * 3.14159265), 0.0);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 center = uSize * 0.5;
  float baseR = min(uSize.x, uSize.y) * 0.5;

  // Whole-orb breathing — a touch faster/wider when active.
  float breath = 1.0 + (0.018 + 0.028 * uIntensity) * sin(uTime * 1.15);
  float radius = baseR * 0.86 * breath;

  vec2 p = (frag - center) / radius; // sphere space, unit disc
  float r2 = dot(p, p);

  vec3 col = vec3(0.0);
  float alpha = 0.0;

  if (r2 <= 1.0) {
    float z = sqrt(max(1.0 - r2, 0.0));
    vec3 nrm = vec3(p, z);

    // Sphere surface coordinates for the weave.
    float lon = atan(nrm.x, nrm.z);
    float lat = asin(clamp(nrm.y, -1.0, 1.0));

    // Undulation: two decorrelated fbm fields flowing over time.
    float t = uTime * (0.22 + 0.30 * uIntensity);
    vec2 flow = vec2(
      fbm(vec3(lon * 1.4, lat * 1.4, t)),
      fbm(vec3(lon * 1.4 + 4.7, lat * 1.4 + 2.1, t + 9.3))
    );
    float amp = 0.30 + 0.55 * uIntensity;

    float density = 19.0;
    vec2 g = vec2(lon, lat) * density + (flow - 0.5) * amp * 2.0;
    vec2 cell = fract(g) - 0.5;

    // Interlace: a checkerboard picks which thread rides on top in each cell.
    float checker = mod(floor(g.x) + floor(g.y), 2.0);
    float warpH = thread(cell.x) * mix(0.55, 1.0, checker);
    float weftH = thread(cell.y) * mix(1.0, 0.55, checker);
    float height = max(warpH, weftH);

    // Fabric coverage vs. the darker gaps between threads.
    float threadMask = smoothstep(0.08, 0.42, height);

    // Lighting — soft key light from upper-left, plus fresnel rim.
    vec3 lightDir = normalize(vec3(-0.45, 0.62, 0.75));
    float diff = clamp(dot(nrm, lightDir), 0.0, 1.0);
    float fres = pow(1.0 - z, 2.6);

    // Thread hue drifts subtly between mint and blue with the flow field.
    vec3 threadCol = mix(kAccent, kBlue, 0.28 * flow.x + 0.12);
    vec3 gapCol = kBg * 0.55;

    vec3 surf = mix(gapCol, threadCol, threadMask);
    surf *= (0.34 + 0.72 * diff);          // material shading
    surf += threadCol * height * 0.30 * (0.4 + diff); // thread self-highlight
    surf += kAccent * fres * 0.45;         // rim glow
    surf *= (1.0 + 0.35 * uIntensity);     // brighten when active

    col = surf;
    alpha = smoothstep(1.0, 0.975, r2);
  } else {
    // Soft outer glow ring beyond the sphere.
    float d = sqrt(r2);
    float glow = smoothstep(1.55, 1.0, d);
    float a = glow * (0.10 + 0.13 * uIntensity);
    col = mix(kAccent, kBlue, 0.15) * a;
    alpha = a;
  }

  // Premultiplied output.
  fragColor = vec4(col * alpha, alpha);
}
