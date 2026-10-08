shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

uniform float rain = 0.0;
uniform float wetness = 0.0;
uniform vec2 wind = vec2(0.0);
uniform float strength = 1.0;
varying vec3 world_pos;
varying float slope;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	slope = (MODEL_NORMAL_MATRIX * NORMAL).y;
	VERTEX += NORMAL * 0.012;
}

void fragment() {
	vec2 p = world_pos.xz;
	float gust = clamp(length(wind), 0.0, 1.0);
	vec2 direction = gust > 0.001 ? wind / gust : vec2(1.0, 0.0);
	float along = dot(p, direction);
	float across = dot(p, vec2(-direction.y, direction.x));
	// Patchy water film: gentle ground receives water, steep faces remain dry.
	float patch = sin(p.x * 0.27 + sin(p.y * 0.39)) * sin(p.y * 0.21 + 0.7);
	float film = smoothstep(-0.45, 0.40, patch + wetness * 0.50);
	film *= smoothstep(0.87, 0.99, slope) * smoothstep(0.15, 0.8, wetness);
	// Irregular advancing gust fronts, not evenly spaced rings or a scrolling texture.
	float front = along * 1.9 - TIME * (1.0 + gust * 4.0)
		+ sin(across * 0.8 + TIME * 0.37) * 1.5 + sin(along * 0.31) * 1.1;
	float band = smoothstep(0.1, 0.9, sin(front));
	float warp = sin(dot(p, vec2(7.3, 5.7))) * 1.8 + sin(dot(p, vec2(-9.1, 4.3))) * 1.2;
	float phase = along * 35.0 + warp * 2.0 - TIME * (8.0 + gust * 20.0);
	float ripple = sin(phase) * sin(across * 18.0 + warp * 2.7 - TIME * 9.0);
	float aa = 1.0 - smoothstep(0.6, 3.0, fwidth(phase));
	float micro = pow(max(0.0, sin(p.x * 43.0 + TIME * 24.0)
		* sin(p.y * 39.0 - TIME * 19.0)), 6.0) * aa;
	float crest = smoothstep(0.30, 0.95, ripple) * aa;
	float heavy = smoothstep(0.35, 0.95, rain);
	float swept = band * gust * heavy;
	ALBEDO = mix(vec3(0.24, 0.29, 0.30), vec3(0.43, 0.48, 0.49), crest);
	ROUGHNESS = mix(0.40, 0.26, film);
	SPECULAR = 0.35;
	NORMAL_MAP = normalize(vec3(ripple * gust * 0.13, cos(phase) * 0.10, 1.0)) * 0.5 + 0.5;
	ALPHA = clamp(film * heavy * strength * (0.025 + micro * 0.20
		+ swept * (0.045 + crest * 0.32)), 0.0, 0.48);
}
