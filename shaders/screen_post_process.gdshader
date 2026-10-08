shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear, repeat_disable;
uniform int style = 0;

float noise(vec2 pixel, float tick) {
	return fract(sin(dot(pixel + tick, vec2(12.9898, 78.233))) * 43758.5453);
}

float vignette(vec2 uv, float strength) {
	vec2 centered = uv * 2.0 - 1.0;
	return 1.0 - strength * smoothstep(0.35, 1.25, dot(centered, centered));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 pixels = 1.0 / SCREEN_PIXEL_SIZE;
	vec3 color = texture(screen_texture, uv).rgb;

	if (style == 1) {
		float luma = dot(color, vec3(0.299, 0.587, 0.114));
		float scan = 0.93 + 0.07 * sin(uv.y * pixels.y * 3.14159265);
		float grain = (noise(floor(uv * pixels), floor(TIME * 24.0)) - 0.5) * 0.065;
		color = vec3(clamp((luma + grain) * scan * vignette(uv, 0.28), 0.0, 1.0));
	} else if (style == 2) {
		vec2 centered = uv * 2.0 - 1.0;
		vec2 curved = centered * (1.0 + 0.055 * dot(centered, centered));
		vec2 sample_uv = curved * 0.5 + 0.5;
		if (any(lessThan(sample_uv, vec2(0.0))) || any(greaterThan(sample_uv, vec2(1.0)))) {
			color = vec3(0.008);
		} else {
			float fringe = SCREEN_PIXEL_SIZE.x * 1.2;
			color = vec3(
				texture(screen_texture, sample_uv + vec2(fringe, 0.0)).r,
				texture(screen_texture, sample_uv).g,
				texture(screen_texture, sample_uv - vec2(fringe, 0.0)).b
			);
			float scan = 0.90 + 0.10 * sin(sample_uv.y * pixels.y * 3.14159265);
			float phosphor = mod(floor(uv.x * pixels.x), 3.0);
			vec3 mask = vec3(
				phosphor < 1.0 ? 1.0 : 0.94,
				phosphor >= 1.0 && phosphor < 2.0 ? 1.0 : 0.94,
				phosphor >= 2.0 ? 1.0 : 0.94
			);
			color *= scan * mask * vignette(sample_uv, 0.34);
		}
	} else if (style == 3) {
		float luma = dot(color, vec3(0.299, 0.587, 0.114));
		vec3 sepia = vec3(luma * 1.10, luma * 0.94, luma * 0.72);
		float grain = (noise(floor(uv * pixels * 0.65), floor(TIME * 12.0)) - 0.5) * 0.075;
		color = clamp((mix(color, sepia, 0.88) * 0.85 + 0.10 + grain) * vignette(uv, 0.42), 0.0, 1.0);
	} else if (style == 4) {
		color = vec3(1.0) - color;
	}

	COLOR = vec4(color, 1.0);
}
