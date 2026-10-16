// Shared helpers for PYROLUX shaders: hashing, value noise, fBm and the heat colour ramp.

uint pyrolux_pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float pyrolux_rand(uint n) {
	return float(pyrolux_pcg(n) >> 8u) / 16777215.0;
}

// Four independent randoms for element `index` of stream `stream`.
vec4 pyrolux_rand4(uint index, uint seed, uint stream) {
	uint h = pyrolux_pcg(index ^ pyrolux_pcg(seed + stream * 9973u));
	return vec4(pyrolux_rand(h), pyrolux_rand(h + 1u), pyrolux_rand(h + 2u), pyrolux_rand(h + 3u));
}

float pyrolux_hash3(vec3 p) {
	uvec3 q = uvec3(ivec3(floor(p)) + ivec3(32768));
	return pyrolux_rand(q.x * 73856093u ^ q.y * 19349663u ^ q.z * 83492791u);
}

float pyrolux_vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(pyrolux_hash3(i), pyrolux_hash3(i + vec3(1.0, 0.0, 0.0)), f.x);
	float b = mix(pyrolux_hash3(i + vec3(0.0, 1.0, 0.0)), pyrolux_hash3(i + vec3(1.0, 1.0, 0.0)), f.x);
	float c = mix(pyrolux_hash3(i + vec3(0.0, 0.0, 1.0)), pyrolux_hash3(i + vec3(1.0, 0.0, 1.0)), f.x);
	float d = mix(pyrolux_hash3(i + vec3(0.0, 1.0, 1.0)), pyrolux_hash3(i + vec3(1.0, 1.0, 1.0)), f.x);
	return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

float pyrolux_fbm(vec3 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	for (int i = 0; i < octaves; i++) {
		sum += pyrolux_vnoise(p) * amp;
		norm += amp;
		p = p * 2.07 + vec3(17.1, 5.3, 11.7);
		amp *= 0.5;
	}
	return sum / norm;
}

// Smooth 3D offset in [-1, 1] used for turbulence.
vec3 pyrolux_curl(vec3 p) {
	return vec3(pyrolux_vnoise(p), pyrolux_vnoise(p + vec3(31.4, 7.7, 2.9)), pyrolux_vnoise(p + vec3(5.1, 47.3, 13.7))) * 2.0 - 1.0;
}

// Heat colour ramp. h = 0 is cold (dark red, nearly invisible), 1 is the white-hot core.
vec3 pyrolux_ramp(float h, vec3 cool, vec3 hot, vec3 core) {
	vec3 c = mix(cool * 0.35, cool, smoothstep(0.0, 0.3, h));
	c = mix(c, hot, smoothstep(0.25, 0.65, h));
	c = mix(c, core, smoothstep(0.65, 1.0, h));
	return c * smoothstep(0.0, 0.18, h);
}

// Distance travelled under exponential drag k after time t with start speed v.
float pyrolux_drag_dist(float t, float k) {
	return k > 0.0001 ? (1.0 - exp(-k * t)) / k : t;
}
