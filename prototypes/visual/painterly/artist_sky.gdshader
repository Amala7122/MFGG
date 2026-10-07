shader_type sky;
uniform int artist_mode = 0;
uniform vec4 sky_top : source_color;
uniform vec4 sky_horizon : source_color;
uniform float weather_brightness = 1.0;
uniform float brush_strength = 0.65;

float hash(vec2 p) {
	vec3 h = fract(vec3(p.x, p.y, p.x) * 0.1031);
	h += dot(h, h.yzx + 33.33);
	return fract((h.x + h.y) * h.z);
}
float paint_noise(vec2 p) {
	vec2 i = floor(p), f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
void sky() {
	vec2 p = vec2(atan(EYEDIR.x, EYEDIR.z), EYEDIR.y);
	float height = smoothstep(0.0, 0.75, max(EYEDIR.y, 0.0));
	vec3 color = mix(sky_horizon.rgb, sky_top.rgb, height);
	float cloud_band = smoothstep(0.12, 0.25, p.y) * (1.0 - smoothstep(0.53, 0.72, p.y));
	if (artist_mode == 0) {
		color *= 1.0 + (paint_noise(p * vec2(14.0, 45.0)) - 0.5) * 0.022;
	} else if (artist_mode == 3) {
		float flow = p.y * 58.0 + sin(p.x * 3.0) * 2.5 + paint_noise(p * 3.0) * 4.0;
		float strokes = pow(max(sin(flow), 0.0), 10.0);
		color = mix(color, vec3(0.72, 0.67, 0.34), strokes * cloud_band * brush_strength * 0.38);
	} else {
		float clouds = paint_noise(p * vec2(5.0, 13.0)) * 0.6 + paint_noise(p * vec2(12.0, 24.0)) * 0.4;
		float mask = smoothstep(0.46, 0.74, clouds) * cloud_band;
		if (artist_mode == 4) { mask = step(0.55, clouds) * cloud_band; }
		color = mix(color, sky_horizon.rgb * 1.05, mask * 0.7);
	}
	COLOR = color * weather_brightness;
}
