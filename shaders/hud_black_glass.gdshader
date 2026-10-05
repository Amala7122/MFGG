shader_type canvas_item;
render_mode unshaded;

uniform sampler2D scene_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec2 corners[8];
uniform int corner_count = 4;
uniform vec2 panel_origin;
uniform vec2 panel_size;
varying vec2 local_position;

void vertex() {
	local_position = VERTEX;
}

void fragment() {
	float edge_distance = 10000.0;
	bool inside = true;
	for (int i = 0; i < 8; i++) {
		if (i >= corner_count) { break; }
		vec2 a = corners[i];
		vec2 b = corners[(i + 1) % corner_count];
		vec2 e = b - a;
		vec2 q = local_position - a;
		float t = clamp(dot(q, e) / max(dot(e, e), 0.0001), 0.0, 1.0);
		edge_distance = min(edge_distance, length(q - e * t));
		if (e.x * q.y - e.y * q.x < 0.0) { inside = false; }
	}
	float pixel = max(length(dFdx(local_position)), length(dFdy(local_position)));
	float signed_edge = inside ? edge_distance : -edge_distance;
	float mask = smoothstep(-pixel * 0.5, pixel * 0.5, signed_edge);
	vec2 p = (local_position - panel_origin) / panel_size;
	vec3 scene = textureLod(scene_texture, SCREEN_UV, 1.5).rgb;
	float luminance = dot(scene, vec3(0.2126, 0.7152, 0.0722));
	// 中性烟黑玻璃：保留背景关系，弱化背景色，避免在道路上变成棕色板。
	vec3 neutral = mix(scene, vec3(luminance), 0.86);
	vec3 glass = neutral * mix(0.33, 0.43, p.y) + vec3(0.025);
	// 连续的内部反射，不用锯齿碎片；形状遮罩同时裁切反光。
	float broad_sheen = 1.0 - smoothstep(0.0, 0.46, abs(p.x + p.y * 0.30 - 0.20));
	glass += vec3(broad_sheen * mix(0.10, 0.025, p.y));
	float diagonal = smoothstep(0.66, 0.69, p.x + p.y * 0.48);
	glass += vec3(diagonal * 0.04);
	float top_light = exp(-p.y * 18.0) * 0.055;
	glass += vec3(top_light);
	float edge = 1.0 - smoothstep(0.35 * pixel, 1.05 * pixel, edge_distance);
	glass = mix(glass, vec3(0.78, 0.83, 0.85), edge * (inside ? 0.48 : 0.32));
	COLOR = vec4(glass, mask);
}
