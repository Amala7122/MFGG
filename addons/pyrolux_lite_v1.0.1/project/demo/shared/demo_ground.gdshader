// Demo ground: dark packed earth with stones and a faint grid of paving. Demo only.
shader_type spatial;
render_mode world_vertex_coords;

varying vec3 wpos;

float h2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vn(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h2(i), h2(i + vec2(1.0, 0.0)), f.x), mix(h2(i + vec2(0.0, 1.0)), h2(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	wpos = VERTEX;
}

void fragment() {
	vec2 p = wpos.xz;
	float n = vn(p * 0.6) * 0.5 + vn(p * 2.3) * 0.3 + vn(p * 9.0) * 0.2;
	vec3 dirt = mix(vec3(0.16, 0.13, 0.11), vec3(0.27, 0.23, 0.19), n);
	vec2 cell = fract(p * 0.5);
	float seam = smoothstep(0.03, 0.0, min(min(cell.x, 1.0 - cell.x), min(cell.y, 1.0 - cell.y)));
	float paved = smoothstep(9.0, 8.0, length(p));
	dirt = mix(dirt, dirt * 0.7, seam * paved * 0.6);
	ALBEDO = dirt;
	ROUGHNESS = 0.9 - n * 0.2;
}
