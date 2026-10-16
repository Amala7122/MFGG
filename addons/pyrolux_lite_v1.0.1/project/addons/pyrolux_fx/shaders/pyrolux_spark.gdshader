// Sparks, embers and debris: streaks that follow a ballistic path with drag, buoyancy,
// turbulence and one bounce on the ground. Positions come from the element index.
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

uniform int mode = 0;
uniform int shape = 0;
uniform vec3 spawn_offset;
uniform vec3 shape_size = vec3(0.1, 0.0, 0.1);
uniform float lifetime = 1.0;
uniform float lifetime_var = 0.4;
uniform float spawn_window = 0.0;
uniform float delay = 0.0;
uniform vec3 velocity = vec3(0.0, 4.0, 0.0);
uniform int spread_mode = 0;
uniform float spread = 0.5;
uniform float speed_var = 0.5;
uniform float drag = 0.5;
uniform float buoyancy = 0.0;
uniform float gravity = 9.8;
uniform float wind_follow = 1.0;
uniform float turbulence = 0.0;
uniform float turb_freq = 1.5;
uniform float inherit = 1.0;
uniform float ground_y = -100000.0;
uniform float bounce = 0.0;

uniform float width = 0.02;
uniform float stretch = 0.04;
uniform float min_length = 0.02;
// 0 hot spark, 1 glowing ember (flickers, small), 2 debris (dark chunk with a hot core).
uniform int kind = 0;
uniform float heat = 1.0;
uniform float cool_rate = 1.0;
uniform float fade_out = 0.3;
uniform float near_fade = 0.2;

uniform int ign_count = 0;
uniform vec4 ign[8];
uniform float spread_speed = 0.6;
uniform float irregularity = 0.5;
uniform float burn_duration = 6.0;

uniform vec4 col_cool : source_color = vec4(0.85, 0.16, 0.02, 1.0);
uniform vec4 col_hot : source_color = vec4(1.0, 0.5, 0.08, 1.0);
uniform vec4 col_core : source_color = vec4(1.0, 0.9, 0.55, 1.0);
uniform vec4 col_smoke : source_color = vec4(0.16, 0.15, 0.15, 0.85);
uniform vec4 col_glow : source_color = vec4(1.0, 0.55, 0.2, 1.0);
uniform float emission = 2.2;

varying vec2 v_uv;
varying float v_alpha;
varying float v_heat;
varying float v_ratio;

float burn_arrival(vec3 p) {
	float best = 1.0e9;
	for (int i = 0; i < ign_count; i++) {
		float d = length(p - ign[i].xyz);
		float n = pyrolux_vnoise(p * 1.7 + float(i) * 3.1);
		best = min(best, ign[i].w + d * (1.0 + (n - 0.5) * 2.0 * irregularity) / max(spread_speed, 0.001));
	}
	return best;
}

vec3 spawn_local(vec4 h) {
	if (shape == 1) {
		float a = h.y * TAU;
		return vec3(cos(a), 0.0, sin(a)) * shape_size.x * sqrt(h.x);
	} else if (shape == 2) {
		return vec3((h.x * 2.0 - 1.0) * shape_size.x, (h.z - 0.5) * shape_size.y, (h.y * 2.0 - 1.0) * shape_size.z);
	} else if (shape == 3) {
		float a = h.y * TAU;
		return vec3(cos(a), 0.0, sin(a)) * shape_size.x;
	} else if (shape == 4) {
		return (h.xyz * 2.0 - 1.0) * shape_size;
	} else if (shape == 5) {
		float u = h.x * 2.0 - 1.0;
		float a = h.y * TAU;
		float sq = sqrt(max(1.0 - u * u, 0.0));
		return vec3(sq * cos(a), u, sq * sin(a)) * shape_size.x * pow(h.z, 0.33);
	}
	return vec3(0.0);
}

void vertex() {
	uint idx = uint(VERTEX.x + 0.5);
	vec3 surf_p = VERTEX;
	vec3 surf_n = NORMAL;
	if (shape == 6) {
		idx = uint(UV2.x + 0.5);
	}
	vec4 r = pyrolux_rand4(idx, uint(seed), 0u);
	vec4 r2 = pyrolux_rand4(idx, uint(seed), 1u);
	float s = (length(em_x) + length(em_y) + length(em_z)) / 3.0;
	mat3 B = mat3(em_x, em_y, em_z);
	vec3 up = vec3(0.0, 1.0, 0.0);
	float life = lifetime * (1.0 + (r.x * 2.0 - 1.0) * lifetime_var);
	float t;
	float f;
	float alive;
	uint key = idx;
	float clock = mode == 0 ? time : age;
	if (mode == 0) {
		float ph = time / life + r.y;
		float cyc = floor(ph);
		f = fract(ph);
		t = f * life;
		key = idx * 7919u + uint(int(mod(cyc, 65536.0)));
		vec4 hc = pyrolux_rand4(key, uint(seed), 5u);
		alive = smoothstep(hc.w - 0.08, hc.w + 0.02, level);
		if (shape == 6) {
			float ta = burn_arrival(surf_p);
			float spawn_at = time - t;
			float on = step(ta, spawn_at);
			if (burn_duration > 0.0) {
				on *= step(spawn_at, ta + burn_duration);
			}
			alive *= on;
		}
	} else {
		t = age - delay - r.y * spawn_window;
		f = t / max(life, 0.001);
		alive = (age >= 0.0 && t >= 0.0 && f < 1.0) ? 1.0 : 0.0;
	}
	vec4 h = pyrolux_rand4(key, uint(seed), 2u);
	vec4 h2 = pyrolux_rand4(key, uint(seed), 3u);
	vec3 local0 = (shape == 6 ? surf_p : spawn_local(h)) + spawn_offset;
	vec3 p0 = em_origin + B * local0;
	float u = h2.x * 2.0 - 1.0;
	float a = h2.y * TAU;
	float sq = sqrt(max(1.0 - u * u, 0.0));
	vec3 rd = vec3(sq * cos(a), u, sq * sin(a));
	float spd = length(velocity);
	vec3 vdir = spd > 0.0001 ? velocity / spd : vec3(0.0, 1.0, 0.0);
	vec3 dir;
	if (spread_mode == 1) {
		dir = normalize(mix(vec3(0.0, 1.0, 0.0), vec3(rd.x, abs(rd.y), rd.z), spread));
	} else if (spread_mode == 2) {
		dir = rd;
	} else if (spread_mode == 3) {
		dir = normalize(vec3(cos(a), (h2.z - 0.3) * spread, sin(a)));
	} else if (spread_mode == 4) {
		dir = normalize(surf_n + rd * spread);
	} else {
		dir = normalize(vdir + rd * spread * 1.5);
	}
	float speed = spd * (1.0 + (h2.z * 2.0 - 1.0) * speed_var) * s;
	vec3 v0 = normalize(B * dir) * speed;
	float tt = max(t, 0.0);
	float acc = (buoyancy - gravity) * s;
	float dd = pyrolux_drag_dist(tt, drag);
	vec3 p = p0 + v0 * dd + up * acc * 0.5 * tt * tt + wind * wind_follow * tt;
	vec3 vel = v0 * exp(-drag * tt) + up * acc * tt + wind * wind_follow;
	if (turbulence > 0.0) {
		vec3 tq = p0 * turb_freq / s + vec3(0.0, -clock * turb_freq * 0.5, 0.0) + r2.xyz * 11.0;
		p += pyrolux_curl(tq) * turbulence * s * tt;
		vel += pyrolux_curl(tq + 3.7) * turbulence * s;
	}
	if (mode == 0) {
		p -= em_velocity * tt * inherit;
	}
	if (p.y < ground_y) {
		if (bounce > 0.0) {
			// Time of the first impact, ignoring drag on the vertical axis.
			float vy = v0.y;
			float g = max(-acc, 0.001);
			float hgt = p0.y - ground_y;
			float th = (vy + sqrt(max(vy * vy + 2.0 * g * hgt, 0.0))) / g;
			float tau = max(tt - th, 0.0);
			vec3 ph = p0 + v0 * pyrolux_drag_dist(th, drag);
			vec3 vh = v0 * exp(-drag * th);
			float vy2 = (g * th - vy) * bounce;
			p = vec3(ph.x + vh.x * tau * 0.5, ground_y + max(vy2 * tau - 0.5 * g * tau * tau, 0.0), ph.z + vh.z * tau * 0.5);
			vel = vec3(vh.x * 0.5, vy2 - g * tau, vh.z * 0.5);
		} else {
			p.y = ground_y;
			vel = vec3(0.0);
		}
	}
	float temp = heat * (0.8 + 0.4 * r2.w) - cool_rate * f;
	if (kind == 1) {
		temp *= 0.75 + 0.25 * sin(clock * (6.0 + 6.0 * r.z) + r.w * 30.0);
	}
	v_heat = temp;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam - p;
	float dist = max(length(to_cam), 0.001);
	vec3 nrm = to_cam / dist;
	float wd = width * s * (kind == 2 ? 1.0 + 1.5 * r2.z : 0.6 + 0.8 * r2.z);
	float w = max(wd, dist * pixel_angle * 1.4);
	float vl = length(vel);
	vec3 vd = vl > 0.0001 ? vel / vl : up;
	vec3 along = vd - nrm * dot(vd, nrm);
	float al = length(along);
	along = al > 0.001 ? along / al : INV_VIEW_MATRIX[1].xyz;
	vec3 side = normalize(cross(along, nrm));
	float len = max(vl * stretch * al, min_length * s);
	if (kind == 2) {
		len = w;
	}
	v_ratio = (len + w) / w;
	v_alpha = alive * clamp(wd / w, 0.0, 1.0) * (1.0 - smoothstep(1.0 - fade_out, 1.0, f)) * smoothstep(near_fade * s, near_fade * s * 3.0, dist);
	vec3 c = p - along * len * 0.5;
	VERTEX = alive > 0.0 ? c + along * (UV.y - 0.5) * (len + w) + side * (UV.x - 0.5) * w : em_origin;
	NORMAL = nrm;
	v_uv = UV;
}

void fragment() {
	vec2 q = vec2(v_uv.x - 0.5, (v_uv.y - 0.5) * v_ratio);
	q.y = max(abs(q.y) - max(v_ratio * 0.5 - 0.5, 0.0), 0.0);
	float d = length(q) * 2.0;
	float a = exp(-d * d * 2.5) * (1.0 - smoothstep(0.8, 1.0, d));
	// Brighter head: the leading end of the streak.
	float head = mix(0.55, 1.0, v_uv.y);
	vec3 hot = pyrolux_ramp(clamp(v_heat, 0.0, 1.2), col_cool.rgb, col_hot.rgb, col_core.rgb) * emission * 1.6;
	vec3 rgb;
	float alpha;
	if (kind == 2) {
		vec3 rock = col_smoke.rgb * 0.6;
		float ga = clamp(v_heat, 0.0, 1.0);
		a = 1.0 - smoothstep(0.55, 0.95, d);
		rgb = (rock + hot * ga * 0.6) * a;
		alpha = a;
	} else {
		rgb = hot * a * head;
		alpha = a * 0.15;
	}
	ALBEDO = rgb * v_alpha;
	ALPHA = clamp(alpha * v_alpha, 0.0, 1.0);
}
