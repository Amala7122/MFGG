// Flame tongues: tall camera-facing ribbons rooted on the emitter shape. The silhouette is a
// domain-warped noise field that scrolls upward, so the flame licks and splits at the top.
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

// 0 point, 1 disk, 2 line, 3 ring, 4 box.
uniform int shape = 0;
uniform vec3 shape_size = vec3(0.3, 0.0, 0.3);
uniform float height = 1.0;
uniform float height_var = 0.35;
uniform float width = 0.5;
uniform float speed = 1.0;
uniform float lean = 0.15;
uniform float inherit = 0.15;
uniform float heat = 1.0;
uniform float flame_opacity = 0.1;
uniform float edge_breakup = 0.8;
uniform int octaves = 3;
uniform float near_fade = 0.2;
uniform float soft_distance = 0.3;
// Burst use (napalm): visible while age is inside [0, burn_time].
uniform float burn_time = -1.0;

uniform vec4 col_cool : source_color = vec4(0.85, 0.16, 0.02, 1.0);
uniform vec4 col_hot : source_color = vec4(1.0, 0.5, 0.08, 1.0);
uniform vec4 col_core : source_color = vec4(1.0, 0.9, 0.55, 1.0);
uniform vec4 col_smoke : source_color = vec4(0.16, 0.15, 0.15, 0.85);
uniform vec4 col_glow : source_color = vec4(1.0, 0.55, 0.2, 1.0);
uniform float emission = 2.2;

#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
#endif

varying vec2 v_uv;
varying vec3 v_seed;
varying float v_alpha;
varying float v_heat;

vec3 root_local(vec4 h) {
	if (shape == 1) {
		float a = h.y * TAU;
		return vec3(cos(a), 0.0, sin(a)) * shape_size.x * sqrt(h.x) * 0.85;
	} else if (shape == 2) {
		return vec3((h.x * 2.0 - 1.0) * shape_size.x, 0.0, (h.y * 2.0 - 1.0) * shape_size.z * 0.5);
	} else if (shape == 3) {
		float a = h.y * TAU;
		return vec3(cos(a), 0.0, sin(a)) * (shape_size.x + (h.x - 0.5) * shape_size.z * 0.5);
	} else if (shape == 4) {
		return vec3((h.x * 2.0 - 1.0) * shape_size.x, -shape_size.y, (h.y * 2.0 - 1.0) * shape_size.z);
	}
	return vec3((h.x - 0.5), 0.0, (h.y - 0.5)) * width * 0.25;
}

void vertex() {
	uint idx = uint(VERTEX.x + 0.5);
	vec4 r = pyrolux_rand4(idx, uint(seed), 0u);
	vec4 r2 = pyrolux_rand4(idx, uint(seed), 1u);
	float s = (length(em_x) + length(em_y) + length(em_z)) / 3.0;
	mat3 B = mat3(em_x, em_y, em_z);
	vec3 up = normalize(em_y);
	float on = smoothstep(r.w * 0.85, r.w * 0.85 + 0.15, level);
	if (burn_time >= 0.0) {
		on *= (age >= 0.0) ? (1.0 - smoothstep(burn_time * 0.7, burn_time, age)) * smoothstep(0.0, 0.15, age) : 0.0;
	}
	// Roots drift slowly so the fire never looks static.
	vec4 h = r;
	float drift = time * 0.07 * speed;
	h.xy = fract(h.xy + vec2(sin(drift + r2.x * 6.0), cos(drift * 0.8 + r2.y * 6.0)) * 0.03);
	vec3 base = em_origin + B * root_local(h);
	// Tongues further from the centre of a point / disk fire are shorter.
	float centre = shape <= 1 ? 1.0 - 0.45 * length(root_local(h).xz) / max(shape_size.x + width * 0.25, 0.001) : 1.0;
	float flick = 0.86 + 0.14 * sin(time * speed * (5.0 + 3.0 * r2.z) + r2.w * 20.0) + 0.1 * (pyrolux_vnoise(vec3(time * speed * 2.0, r.x * 10.0, 0.0)) - 0.5);
	float H = height * s * (1.0 + (r2.x * 2.0 - 1.0) * height_var) * centre * flick * mix(0.25, 1.0, on);
	float W = width * s * (0.7 + 0.5 * r2.y) * mix(0.5, 1.0, on);
	vec3 tip = up * H + wind * lean * H * 0.4 - em_velocity * inherit * H * 0.3;
	float tl = length(tip);
	vec3 axis = tl > 0.0001 ? tip / tl : up;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam - base;
	vec3 side = cross(axis, to_cam);
	float sl = length(side);
	side = sl > 0.0001 ? side / sl : INV_VIEW_MATRIX[0].xyz;
	float dist = max(length(to_cam), 0.001);
	float ww = max(W, dist * pixel_angle * 2.0);
	// Curve the ribbon a little so the top follows the wind.
	float along = UV.y;
	vec3 bend = (wind * lean * 0.25 - em_velocity * inherit * 0.15) * along * along * H;
	VERTEX = base + axis * along * tl + bend + side * (UV.x - 0.5) * ww;
	NORMAL = to_cam / dist;
	v_uv = vec2(UV.x * 2.0 - 1.0, along);
	v_seed = vec3(r.zw * 41.0, r2.w * 23.0);
	v_alpha = on * clamp(W / ww, 0.0, 1.0) * smoothstep(near_fade * s, near_fade * s * 3.0, dist);
	v_heat = heat * (0.9 + 0.2 * r2.z);
}

void fragment() {
	float x = v_uv.x;
	float y = v_uv.y;
	float t = time * speed;
	float n1 = pyrolux_fbm(vec3(x * 1.1 + v_seed.x, y * 1.5 - t * 1.25, v_seed.y + t * 0.15), octaves);
	float n2 = pyrolux_fbm(vec3(x * 2.4 + v_seed.z, y * 3.2 - t * 2.1, v_seed.x + t * 0.3), 2);
	float xw = x + (n1 - 0.5) * 1.3 * y + (n2 - 0.5) * 0.35 * y;
	float prof = pow(clamp(1.0 - y, 0.0, 1.0), 0.8) * mix(0.7, 1.0, smoothstep(0.0, 0.25, y)) * 0.85;
	float f = 1.0 - abs(xw) / max(prof, 0.001);
	float field = f + (n2 - 0.5) * edge_breakup - y * 0.35;
	float dens = smoothstep(0.0, 0.32, field) * smoothstep(0.0, 0.07, y);
#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
	if (soft_distance > 0.0) {
		float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
		vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		dens *= clamp((-vp.z / vp.w + VERTEX.z) / soft_distance, 0.0, 1.0);
	}
#endif
	float hp = smoothstep(0.0, 0.9, field) * (0.95 - y * 0.75) * v_heat;
	vec3 rgb = pyrolux_ramp(hp, col_cool.rgb, col_hot.rgb, col_core.rgb) * emission * 0.75 * dens;
	ALBEDO = rgb * v_alpha;
	ALPHA = clamp(dens * flame_opacity * v_alpha, 0.0, 1.0);
}
