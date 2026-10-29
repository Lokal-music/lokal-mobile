// Pixel-equivalent alpha composition of desktop src/coverMix.js.
// Each mask layer is a feathered ellipse (1 -> .6 -> 0 alpha at
// 45%, 70%, 100% radius), combined by source-over. No hard clipping.
#version 460 core
precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform float u_progress;
// x,y normalized center; z stagger delay; w full-grown radius fraction.
uniform vec4 u_blobs[14];

out vec4 frag_color;

float ease_out(float t) {
  return 1.0 - pow(1.0 - t, 3.0);
}

float ease_in_out(float t) {
  return t < 0.5 ? 4.0 * t * t * t :
      1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0;
}

float blob_alpha(float distance) {
  if (distance <= 0.45) return 1.0;
  if (distance <= 0.70) {
    return mix(1.0, 0.6, (distance - 0.45) / 0.25);
  }
  if (distance <= 1.0) {
    return mix(0.6, 0.0, (distance - 0.70) / 0.30);
  }
  return 0.0;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / max(u_size, vec2(1.0));
  float alpha = 0.0;
  for (int i = 0; i < 14; i++) {
    vec4 blob = u_blobs[i];
    float t = clamp(
      (u_progress - blob.z) / (1.0 - blob.z), 0.0, 1.0
    );
    float growth = 0.65 * ease_out(t) + 0.35 * ease_in_out(t);
    float radius = blob.w * growth;
    if (radius <= 0.000001) continue;
    // The normalized ellipse exactly mirrors CSS's width%/height% radii.
    float distance = length((uv - blob.xy) / radius);
    float layer = blob_alpha(distance);
    alpha = 1.0 - (1.0 - alpha) * (1.0 - layer);
  }
  // Desktop's final linear-gradient alpha layer, not an oversized oval.
  float fill = clamp((u_progress - 0.82) / 0.18, 0.0, 1.0);
  alpha = 1.0 - (1.0 - alpha) * (1.0 - fill);
  frag_color = vec4(alpha);
}
