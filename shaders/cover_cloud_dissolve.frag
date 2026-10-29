// Pixel-equivalent alpha composition of desktop src/coverMix.js.
// Each mask layer is a feathered circle in physical pixels (1 -> .6 -> 0
// alpha at 45%, 70%, 100% radius), composited by source-over.
#version 460 core
precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform float u_progress;
// x,y normalized center; z stagger delay; w radius relative to shortest side.
uniform vec4 u_blob0;
uniform vec4 u_blob1;
uniform vec4 u_blob2;
uniform vec4 u_blob3;
uniform vec4 u_blob4;
uniform vec4 u_blob5;
uniform vec4 u_blob6;
uniform vec4 u_blob7;
uniform vec4 u_blob8;
uniform vec4 u_blob9;
uniform vec4 u_blob10;
uniform vec4 u_blob11;
uniform vec4 u_blob12;
uniform vec4 u_blob13;

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

float paint_blob(vec2 pixel, float alpha, vec4 blob) {
  float t = clamp(
    (u_progress - blob.z) / (1.0 - blob.z), 0.0, 1.0
  );
  float growth = 0.65 * ease_out(t) + 0.35 * ease_in_out(t);
  // UV coordinates are not isotropic on non-square artwork. Use physical
  // pixel distances and one shared radius so fullscreen covers stay circular.
  vec2 size_px = max(u_size, vec2(1.0));
  float radius_px = blob.w * growth * min(size_px.x, size_px.y);
  if (radius_px <= 0.000001) return alpha;
  float distance = length(pixel - blob.xy * size_px) / radius_px;
  float layer = blob_alpha(distance);
  return 1.0 - (1.0 - alpha) * (1.0 - layer);
}

void main() {
  vec2 pixel = FlutterFragCoord().xy;
  float alpha = 0.0;
  alpha = paint_blob(pixel, alpha, u_blob0);
  alpha = paint_blob(pixel, alpha, u_blob1);
  alpha = paint_blob(pixel, alpha, u_blob2);
  alpha = paint_blob(pixel, alpha, u_blob3);
  alpha = paint_blob(pixel, alpha, u_blob4);
  alpha = paint_blob(pixel, alpha, u_blob5);
  alpha = paint_blob(pixel, alpha, u_blob6);
  alpha = paint_blob(pixel, alpha, u_blob7);
  alpha = paint_blob(pixel, alpha, u_blob8);
  alpha = paint_blob(pixel, alpha, u_blob9);
  alpha = paint_blob(pixel, alpha, u_blob10);
  alpha = paint_blob(pixel, alpha, u_blob11);
  alpha = paint_blob(pixel, alpha, u_blob12);
  alpha = paint_blob(pixel, alpha, u_blob13);
  // Desktop's final translucent linear-gradient alpha layer.
  float fill = clamp((u_progress - 0.82) / 0.18, 0.0, 1.0);
  alpha = 1.0 - (1.0 - alpha) * (1.0 - fill);
  frag_color = vec4(alpha);
}
