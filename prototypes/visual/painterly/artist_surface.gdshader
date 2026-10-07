shader_type spatial;
render_mode specular_disabled;

uniform int artist_mode = 0;
uniform int surface_kind = 0;
uniform vec4 base_color : source_color;
uniform vec4 road_color : source_color;
uniform float brush_strength : hint_range(0.0, 1.0) = 0.65;
uniform float brush_scale = 2.0;
uniform float light_softness = 0.5;
uniform float ridge_wash_energy = 0.7;
varying vec3 paint_position;
varying vec3 paint_normal;

float hash(vec2 p) {
	vec3 h = fract(vec3(p.x, p.y, p.x) * 0.1031);
	h += dot(h, h.yzx + 33.33);
	return fract((h.x + h.y) * h.z);
}
float paint_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
vec3 brush(vec2 p) {
	if (artist_mode == 0) {
		// Dilute washes + broken dry-brush marks. Far ridges get less texture.
		float wash = paint_noise(p * 0.56) * 0.65 + paint_noise(p * 1.7) * 0.35;
		float flow = p.x * 4.5 + sin(p.y * 0.9) * 0.6 + paint_noise(p * 0.7) * 1.8;
		float dry = pow(1.0 - abs(sin(flow)), 18.0) * smoothstep(0.3, 0.6, paint_noise(p * 0.8));
		return vec3(wash - 0.5, dry, 0.0);
	}
	if (artist_mode == 1) {
		vec2 q = vec2(p.x + p.y * 0.35, p.y * 2.0);
		q += vec2(paint_noise(p), paint_noise(p + 11.0)) * 0.45;
		vec2 f = fract(q) - 0.5;
		float dab = 1.0 - smoothstep(0.25, 0.5, length(f * vec2(0.85, 1.8)));
		return vec3((hash(floor(q)) - 0.5) * dab, dab, hash(floor(q) + 23.0) - 0.5);
	}
	if (artist_mode == 2) {
		vec2 q = vec2(p.x + p.y * 0.55, p.y - p.x * 0.25) * 1.3;
		q += vec2(paint_noise(p * 0.6), paint_noise(p * 0.6 + 19.0)) * 1.8;
		vec2 f = fract(q);
		float seed = hash(floor(q));
		float patch = smoothstep(0.02, 0.12, f.x) * (1.0 - smoothstep(0.65 + seed * 0.2, 0.98, f.x));
		patch *= smoothstep(0.05, 0.18, f.y) * (1.0 - smoothstep(0.48 + seed * 0.18, 0.86, f.y));
		return vec3((seed - 0.5) * patch, patch, (hash(floor(q) + 31.0) - 0.5) * patch);
	}
	if (artist_mode == 3) {
		// Deterministic flowing hatches. No animation and no screen-space texture.
		float flow = sin(p.x * 0.9) * 0.65 + paint_noise(p * 0.5) * 0.8;
		vec2 q = vec2(p.x * 0.75 + paint_noise(p * 0.7) * 0.65, p.y * 2.6 + flow + sin(p.y * 0.8) * 0.65);
		vec2 f = fract(q);
		float stroke = pow(max(sin(f.y * PI), 0.0), 12.0 + hash(floor(q)) * 10.0) * smoothstep(0.02, 0.2, f.x) * (1.0 - smoothstep(0.65, 1.0, f.x));
		return vec3((stroke - 0.24) * 0.65, stroke, hash(floor(q)) - 0.5);
	}
	return vec3((paint_noise(p * 1.6) - 0.5) * 0.13, 0.0, 0.0);
}
void vertex() {
	paint_position = VERTEX;
	paint_normal = NORMAL;
}
void fragment() {
	vec3 weights = pow(abs(normalize(paint_normal)), vec3(4.0));
	weights /= max(dot(weights, vec3(1.0)), 0.001);
	vec3 p = paint_position * brush_scale;
	vec3 marks = brush(p.yz) * weights.x + brush(p.xz) * weights.y + brush(p.xy) * weights.z;
	vec3 color = base_color.rgb;
	if (surface_kind == 0) {
		float center = sin(paint_position.z * 0.095) * 1.7;
		float irregular = (paint_noise(paint_position.xz * 1.1) - 0.5) * 0.35;
		float road = 1.0 - smoothstep(2.0 + irregular, 2.38 + irregular, abs(paint_position.x - center));
		color = mix(color, road_color.rgb, road);
	}
	float silhouette = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	if (artist_mode == 0) {
		float strength = brush_strength * (surface_kind == 5 ? 0.35 : 1.0);
		if (surface_kind == 0) { marks.y = 0.0; }
		if (surface_kind == 2) {
			// Broken needle/leaf groups, not the same stone hatch pasted onto leaves.
			marks.y = smoothstep(0.48, 0.75, paint_noise(paint_position.xz * 10.0)) * 0.4;
		}
		color *= 1.0 + marks.x * strength * 0.48;
		float ink = (marks.y * 0.75 + smoothstep(-0.10, 0.24, marks.x) * 0.25 + pow(silhouette, 3.0) * 0.8) * strength;
		if (surface_kind == 0) { ink *= 0.25; }
		color = mix(color, vec3(0.004, 0.008, 0.006), clamp(ink, 0.0, 0.85));
		if (surface_kind == 5) {
			// Washes and vertical broken cun strokes describe the cliff, not
			// the underlying triangulation. These are attached to model space.
			float flow = paint_position.x * 38.0 + sin(paint_position.y * 8.0) * 1.3 + paint_noise(paint_position.xy * 5.0) * 3.0;
			float cun = pow(1.0 - abs(sin(flow)), 14.0) * smoothstep(0.35, 0.62, paint_noise(paint_position.xy * 11.0));
			float base_wash = paint_noise(paint_position.xz * 3.0 + paint_position.y) * 0.25;
			color = mix(base_color.rgb, vec3(0.06, 0.105, 0.095), (cun * 0.5 + base_wash) * brush_strength);
		}
	} else if (artist_mode == 1) {
		color *= 1.0 + marks.x * brush_strength * 0.8;
		color += vec3(0.065, -0.012, 0.11) * marks.z * marks.y * brush_strength;
	} else if (artist_mode == 2) {
		float strength = brush_strength * (surface_kind == 0 ? 0.6 : 1.0);
		color *= 1.0 + marks.x * strength * 0.8;
		color += vec3(0.065, 0.02, -0.065) * marks.z * strength;
	} else if (artist_mode == 3) {
		color *= 1.0 + marks.x * brush_strength * 0.7;
		color += vec3(0.05, 0.025, -0.025) * marks.y * (0.7 + marks.z) * brush_strength;
		color *= 1.0 - pow(silhouette, 6.0) * 0.35;
	} else {
		color *= 1.0 + marks.x * brush_strength;
		if (surface_kind != 0) {
			float ink_edge = smoothstep(0.77, 0.91, silhouette);
			color = mix(color, vec3(0.025, 0.058, 0.07), ink_edge * 0.82);
		}
	}
	ALBEDO = clamp(color, vec3(0.01), vec3(1.0));
	if (artist_mode == 0 && surface_kind == 5) {
		// A distant painted wash deliberately bypasses per-face sunlight.
		// Keep geometry/depth fog, including proper foreground occlusion.
		EMISSION = ALBEDO * ridge_wash_energy;
		ALBEDO = vec3(0.0);
	}
	ROUGHNESS = 1.0;
}
void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	float response = mix(ndl, smoothstep(0.0, 0.9, (ndl + 0.15) / 1.15), light_softness);
	if (artist_mode == 4) {
		float band = ndl < 0.25 ? 0.18 : (ndl < 0.70 ? 0.55 : 0.95);
		response = mix(ndl, band, 0.9);
	}
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * response / PI;
}
