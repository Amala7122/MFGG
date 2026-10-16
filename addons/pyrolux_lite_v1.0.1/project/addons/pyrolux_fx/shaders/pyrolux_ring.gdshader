// Expanding rings: a hot shock ring or a dust ring lying on the ground, or a camera-facing
// shock flash in the air. One quad per ring; `age` drives the radius and the fade.
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

// 0 = flat on the ground plane of the emitter, 1 = facing the camera.
uniform int facing = 0;
uniform float delay = 0.0;
uniform float radius = 4.0;
uniform float expand = 4.0;
uniform float duration = 0.6;
uniform float thickness = 0.25;
uniform float height_offset = 0.05;
// 0 = hot (adds light), 1 = dust (covers), 2 = bright flash disc.
uniform int kind = 0;
uniform float intensity = 1.0;

uniform vec4 col_cool : source_color = vec4(0.85, 0.16, 0.02, 1.0);
uniform vec4 col_hot : source_color = vec4(1.0, 0.5, 0.08, 1.0);
uniform vec4 col_core : source_color = vec4(1.0, 0.9, 0.55, 1.0);
uniform vec4 col_smoke : source_color = vec4(0.16, 0.15, 0.15, 0.85);
uniform vec4 col_glow : source_color = vec4(1.0, 0.55, 0.2, 1.0);
uniform float emission = 2.2;

varying vec2 v_q;
varying float v_r;
varying float v_t;

void vertex() {
	float s = (length(em_x) + length(em_y) + length(em_z)) / 3.0;
	float t = age - delay;
	v_t = t / max(duration, 0.001);
	float r = radius * s * (1.0 - exp(-max(t, 0.0) * expand));
	if (kind == 2) {
		r = radius * s * (0.6 + 0.4 * smoothstep(0.0, 1.0, v_t));
	}
	v_r = r;
	float R = r + thickness * s * 2.0 + 0.001;
	vec2 c = UV * 2.0 - 1.0;
	vec3 p;
	if (facing == 1) {
		p = em_origin + (INV_VIEW_MATRIX[0].xyz * c.x + INV_VIEW_MATRIX[1].xyz * c.y) * R;
	} else {
		p = em_origin + normalize(em_y) * height_offset * s + (normalize(em_x) * c.x + normalize(em_z) * c.y) * R;
	}
	v_q = c * R;
	bool on = age >= 0.0 && t >= 0.0 && v_t < 1.0;
	VERTEX = on ? p : em_origin;
	NORMAL = normalize(INV_VIEW_MATRIX[3].xyz - p);
}

void fragment() {
	float s = (length(em_x) + length(em_y) + length(em_z)) / 3.0;
	float d = length(v_q);
	float ang = atan(v_q.y, v_q.x);
	float n = pyrolux_fbm(vec3(cos(ang) * 2.0, sin(ang) * 2.0, float(seed % 97) + v_t * 2.0), 3);
	float th = thickness * s * (0.6 + 0.8 * n);
	float fade = 1.0 - smoothstep(0.0, 1.0, v_t);
	vec3 rgb;
	float a;
	if (kind == 2) {
		float disc = exp(-pow(d / max(v_r, 0.001), 2.0) * 3.0);
		rgb = mix(col_hot.rgb, col_core.rgb, disc) * disc * emission * intensity * pow(fade, 1.5);
		a = 0.0;
	} else {
		float x = (d - v_r) / max(th, 0.001);
		float ring = exp(-x * x * 2.0) * (d < v_r ? 1.0 : 1.0) + (d < v_r ? 0.25 * exp(-abs(x) * 0.6) : 0.0);
		if (kind == 0) {
			rgb = pyrolux_ramp(0.35 + fade * 0.55, col_cool.rgb, col_hot.rgb, col_core.rgb) * ring * emission * intensity * (0.5 + 0.6 * n) * fade;
			a = ring * 0.1 * fade;
		} else {
			a = clamp(ring * (0.5 + n * 0.8), 0.0, 1.0) * col_smoke.a * intensity * fade;
			rgb = col_smoke.rgb * (0.8 + 0.4 * n) * a;
		}
		rgb *= fade;
	}
	ALBEDO = rgb;
	ALPHA = clamp(a, 0.0, 1.0);
}
