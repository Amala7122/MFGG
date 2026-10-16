// Scorch mark lying on the ground: charred centre, ragged edge and glowing embers that cool.
// A plain quad, so it works where Decal does not (Compatibility).
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://addons/pyrolux_fx/shaders/pyrolux_common.gdshaderinc"

uniform int seed = 1;
uniform float time = 0.0;
uniform float level = 1.0;
uniform float age = -1.0;
uniform vec3 em_origin;
uniform vec3 em_x = vec3(1.0, 0.0, 0.0);
uniform vec3 em_y = vec3(0.0, 1.0, 0.0);
uniform vec3 em_z = vec3(0.0, 0.0, 1.0);
uniform vec3 em_velocity;
uniform vec3 wind;
uniform float pixel_angle = 0.002;

uniform float radius = 2.0;
uniform float delay = 0.0;
uniform float lifetime = 12.0;
uniform float fade_time = 3.0;
uniform float darkness = 0.85;
uniform float ember_amount = 0.6;
uniform float ember_cool = 4.0;
uniform float height_offset = 0.03;
// Use the node's own time instead of a one-shot age (for always-on scorch decals).
uniform bool persistent = false;

uniform vec4 col_cool : source_color = vec4(0.85, 0.16, 0.02, 1.0);
uniform vec4 col_hot : source_color = vec4(1.0, 0.5, 0.08, 1.0);
uniform vec4 col_core : source_color = vec4(1.0, 0.9, 0.55, 1.0);
uniform vec4 col_smoke : source_color = vec4(0.16, 0.15, 0.15, 0.85);
uniform vec4 col_glow : source_color = vec4(1.0, 0.55, 0.2, 1.0);
uniform float emission = 2.2;

varying vec2 v_q;
varying float v_t;

void vertex() {
	float s = (length(em_x) + length(em_y) + length(em_z)) / 3.0;
	float R = radius * s;
	vec2 c = UV * 2.0 - 1.0;
	vec3 up = normalize(em_y);
	VERTEX = em_origin + up * height_offset * s + (normalize(em_x) * c.x + normalize(em_z) * c.y) * R;
	v_q = c;
	v_t = persistent ? 1.0e3 : age - delay;
	if (!persistent && (age < 0.0 || v_t < 0.0)) {
		VERTEX = em_origin;
	}
	NORMAL = up;
}

void fragment() {
	vec2 q = v_q;
	float d = length(q);
	float fs = float(seed % 251);
	float n = pyrolux_fbm(vec3(q * 2.5, fs), 4);
	float edge = d + (n - 0.5) * 0.55;
	float grow = persistent ? 1.0 : smoothstep(0.0, 0.25, v_t);
	float mask = (1.0 - smoothstep(0.35 * grow, 0.95 * grow, edge)) * grow;
	float fade = persistent ? level : 1.0 - smoothstep(lifetime - fade_time, lifetime, v_t);
	float a = mask * darkness * fade * (0.75 + 0.35 * n);
	float n2 = pyrolux_fbm(vec3(q * 9.0, fs + 3.0), 3);
	float spots = smoothstep(0.62, 0.8, n2) * (1.0 - smoothstep(0.2, 0.8, d));
	float heat = persistent ? ember_amount * 0.5 * (0.6 + 0.4 * sin(time * 2.0 + n2 * 20.0)) : ember_amount * exp(-max(v_t, 0.0) / max(ember_cool, 0.01));
	vec3 glow = pyrolux_ramp(clamp(heat * spots * 1.2, 0.0, 1.0), col_cool.rgb, col_hot.rgb, col_core.rgb) * emission * spots;
	vec3 charcoal = vec3(0.02, 0.018, 0.016);
	ALBEDO = charcoal * a + glow * mask * fade;
	ALPHA = clamp(a, 0.0, 1.0);
}
