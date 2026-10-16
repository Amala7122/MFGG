shader_type spatial;
render_mode diffuse_burley, specular_disabled;

uniform vec4 base_color : source_color = vec4(0.35, 0.5, 0.23, 1.0);
uniform float brush_strength : hint_range(0.0, 1.0) = 0.35;
uniform float brush_scale = 2.0;
uniform float light_softness : hint_range(0.0, 1.0) = 0.45;
uniform bool ground_surface = false;
varying vec3 paint_position;
varying vec3 paint_normal;

// A bounded arithmetic hash avoids the large sin()*constant precision loss
// which produced visible hard cell boundaries on the tested D3D12 renderer.
float hash(vec2 p) {
	vec3 h = fract(vec3(p.x, p.y, p.x) * 0.1031);
	h += dot(h, h.yzx + 33.33);
	return fract((h.x + h.y) * h.z);
}
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
		mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
// Broad, tapered brush dabs rather than per-pixel grain. No screen coordinates
// or TIME: pigment is attached to each object's surface when the camera moves.
float pigment(vec2 p) {
	vec2 q = vec2(p.x * 0.8 + p.y * 0.24, p.y * 2.3);
	q += vec2(noise(p * 0.55), noise(p * 0.55 + 17.0)) * 0.7;
	vec2 cell = floor(q);
	vec2 f = fract(q);
	float seed = hash(cell);
	float center = 0.35 + seed * 0.3;
	float width = 0.10 + hash(cell + 8.0) * 0.22;
	float taper = sin(f.x * 3.14159);
	float dab = 1.0 - smoothstep(width * taper, width * taper + 0.16,
		abs(f.y - center - 0.05 * sin(f.x * 7.0 + seed * 10.0)));
	float bristles = sin(q.y * 72.0 + noise(p * 2.0) * 4.0) * dab;
	return (noise(p * 0.46) - 0.5) * 0.8 + dab * (seed - 0.5) * 0.28 + bristles * 0.025;
}
void vertex() {
	paint_position = VERTEX;
	paint_normal = NORMAL;
}
void fragment() {
	vec3 weights = pow(abs(normalize(paint_normal)), vec3(4.0));
	weights /= max(dot(weights, vec3(1.0)), 0.001);
	vec3 p = paint_position * brush_scale;
	float marks = pigment(p.yz) * weights.x + pigment(p.xz) * weights.y + pigment(p.xy) * weights.z;
	vec3 color = base_color.rgb;
	if (ground_surface) {
		float center = sin(paint_position.z * 0.095) * 1.7;
		float edge = abs(paint_position.x - center);
		float irregular = (noise(paint_position.xz * 1.1) - 0.5) * 0.35;
		float road = 1.0 - smoothstep(2.0 + irregular, 2.38 + irregular, edge);
		vec3 meadow = mix(color * 0.92, color * 1.06, noise(paint_position.xz * 0.18));
		color = mix(meadow, vec3(0.69, 0.42, 0.22), road);
	}
	ALBEDO = clamp(color * (1.0 + marks * brush_strength * 0.65)
		+ vec3(0.024, 0.015, -0.008) * marks * brush_strength, vec3(0.0), vec3(1.0));
	ROUGHNESS = 1.0;
}
void light() {
	float ndl = dot(NORMAL, LIGHT);
	float wrapped = clamp((ndl + light_softness * 0.32) / (1.0 + light_softness * 0.32), 0.0, 1.0);
	float painted_ramp = smoothstep(0.02, 0.93, wrapped);
	// Preserve real light color, attenuation, shadows and flashlight direction.
	// Godot applies ALBEDO to the accumulated diffuse result afterwards.
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * mix(max(ndl, 0.0), painted_ramp, light_softness) / PI;
}
