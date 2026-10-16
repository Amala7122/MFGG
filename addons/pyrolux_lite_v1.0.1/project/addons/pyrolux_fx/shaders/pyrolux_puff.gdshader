// Billboard puffs for flames, smoke, fireballs and dust. Every position is computed here
// from the element index, the seed and the time, so the mesh is a static list of quads and
// the CPU does no per-particle work. Premultiplied alpha: hot parts add light, smoke covers.
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

// 0 = loop, 1 = one-shot burst driven by `age`.
uniform int mode = 0;
// 0 point, 1 disk, 2 line, 3 ring, 4 box, 5 sphere, 6 surface samples (VERTEX / NORMAL).
uniform int shape = 0;
uniform vec3 spawn_offset;
uniform vec3 shape_size = vec3(0.3, 0.1, 0.3);
uniform float lifetime = 1.0;
uniform float lifetime_var = 0.3;
uniform float spawn_window = 0.0;
uniform float delay = 0.0;
uniform vec3 velocity = vec3(0.0, 1.5, 0.0);
// 0 cone around velocity, 1 hemisphere, 2 sphere, 3 outward ring, 4 along surface normal.
uniform int spread_mode = 0;
uniform float spread = 0.2;
uniform float speed_var = 0.3;
uniform float drag = 0.0;
uniform float buoyancy = 0.0;
uniform float gravity = 0.0;
uniform float wind_follow = 1.0;
uniform float turbulence = 0.2;
uniform float turb_freq = 1.0;
uniform float inherit = 1.0;
uniform float ground_y = -100000.0;

uniform float size_start = 0.3;
uniform float size_end = 0.6;
uniform float size_var = 0.3;
uniform float size_curve = 1.0;
uniform float stretch = 0.0;
uniform float spin = 0.5;

// 0 flame, 1 smoke, 2 fireball (flame that cools into smoke), 3 dust.
uniform int kind = 0;
uniform float heat = 1.0;
uniform float heat_var = 0.25;
uniform float cool_rate = 1.0;
uniform float smoke_opacity = 0.8;
uniform float flame_opacity = 0.12;
uniform float fade_in = 0.1;
uniform float fade_out = 0.4;
uniform float noise_scale = 1.6;
uniform float noise_speed = 0.8;
uniform float erosion = 0.6;
uniform int octaves = 3;
uniform float softness = 0.45;
uniform float glow_under = 0.5;
uniform float smoke_light = 0.55;
uniform float near_fade = 0.25;
uniform float soft_distance = 0.4;

// Burst only: pull particles into a mushroom cloud (stem + rolling cap).
uniform float mushroom = 0.0;
uniform float mushroom_height = 6.0;
uniform float mushroom_rise = 1.2;

// Surface mode (burning objects): when each sample starts and stops burning.
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
// Brightness of the hot parts of this layer.
uniform float intensity = 1.0;
// Multiplies the smoke colour of this layer (dust, steam).
uniform vec4 tint = vec4(1.0);

#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
#endif

varying vec2 v_q;
varying vec3 v_seed;
varying float v_heat;
varying float v_env;
varying float v_f;
varying float v_glow;
varying vec2 v_light;

vec3 spawn_local(vec4 h, vec4 h2) {
	if (shape == 1) {
		float a = h.y * TAU;
		return vec3(cos(a), 0.0, sin(a)) * shape_size.x * sqrt(h.x) + vec3(0.0, (h.z - 0.5) * shape_size.y, 0.0);
	} else if (shape == 2) {
		return vec3((h.x * 2.0 - 1.0) * shape_size.x, (h.z - 0.5) * shape_size.y, (h.y * 2.0 - 1.0) * shape_size.z);
	} else if (shape == 3) {
		float a = h.y * TAU;
		return vec3(cos(a), 0.0, sin(a)) * (shape_size.x + (h.x - 0.5) * shape_size.z) + vec3(0.0, (h.z - 0.5) * shape_size.y, 0.0);
	} else if (shape == 4) {
		return (h.xyz * 2.0 - 1.0) * shape_size;
	} else if (shape == 5) {
		float u = h.x * 2.0 - 1.0;
		float a = h.y * TAU;
		float s = sqrt(max(1.0 - u * u, 0.0));
		return vec3(s * cos(a), u, s * sin(a)) * shape_size.x * pow(h.z, 0.33);
	}
	return vec3(0.0);
}

vec3 rand_dir(vec4 h2) {
	float u = h2.x * 2.0 - 1.0;
	float a = h2.y * TAU;
	float s = sqrt(max(1.0 - u * u, 0.0));
	return vec3(s * cos(a), u, s * sin(a));
}

// Seconds after ignition at which the surface point `p` (emitter space) catches fire.
float burn_arrival(vec3 p) {
	float best = 1.0e9;
	for (int i = 0; i < ign_count; i++) {
		float d = length(p - ign[i].xyz);
		float n = pyrolux_vnoise(p * 1.7 + float(i) * 3.1);
		best = min(best, ign[i].w + d * (1.0 + (n - 0.5) * 2.0 * irregularity) / max(spread_speed, 0.001));
	}
	return best;
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
	float t = 0.0;
	float f = 0.0;
	float alive = 0.0;
	uint cyc_key = idx;
	float clock = mode == 0 ? time : age;
	float surf_heat = 1.0;
	if (mode == 0) {
		float ph = time / life + r.y;
		float cyc = floor(ph);
		f = fract(ph);
		t = f * life;
		cyc_key = idx * 7919u + uint(int(mod(cyc, 65536.0)));
		vec4 hc = pyrolux_rand4(cyc_key, uint(seed), 5u);
		alive = smoothstep(hc.w - 0.08, hc.w + 0.02, level);
		if (shape == 6) {
			// Surface: only while this sample is burning.
			float ta = burn_arrival(surf_p);
			float spawn_at = time - t;
			float on = step(ta, spawn_at);
			if (burn_duration > 0.0) {
				on *= step(spawn_at, ta + burn_duration);
				surf_heat = 1.0 - smoothstep(ta + burn_duration * 0.6, ta + burn_duration, spawn_at) * 0.6;
			}
			alive *= on;
		}
	} else {
		float start = delay + r.y * spawn_window;
		t = age - start;
		f = t / max(life, 0.001);
		alive = (age >= 0.0 && t >= 0.0 && f < 1.0) ? 1.0 : 0.0;
	}
	vec4 h = pyrolux_rand4(cyc_key, uint(seed), 2u);
	vec4 h2 = pyrolux_rand4(cyc_key, uint(seed), 3u);

	vec3 local0 = (shape == 6 ? surf_p : spawn_local(h, h2)) + spawn_offset;
	vec3 p0 = em_origin + B * local0;
	float spd = length(velocity);
	vec3 vdir = spd > 0.0001 ? velocity / spd : vec3(0.0, 1.0, 0.0);
	vec3 rd = rand_dir(h2);
	vec3 dir;
	if (spread_mode == 1) {
		dir = normalize(mix(vec3(0.0, 1.0, 0.0), vec3(rd.x, abs(rd.y), rd.z), spread));
	} else if (spread_mode == 2) {
		dir = rd;
	} else if (spread_mode == 3) {
		vec2 radial = normalize(local0.xz + vec2(h2.x - 0.5, h2.y - 0.5) * 0.001);
		dir = normalize(vec3(radial.x, (h2.z - 0.3) * spread, radial.y));
	} else if (spread_mode == 4) {
		dir = normalize(surf_n + rd * spread);
	} else {
		dir = normalize(vdir + rd * spread * 1.5);
	}
	float speed = spd * (1.0 + (h2.z * 2.0 - 1.0) * speed_var);
	vec3 v0 = spread_mode == 4 ? normalize(B * dir) * speed * s : B * (dir * speed);
	if (spread_mode == 4) {
		v0 += up * spd * 0.5 * s;
	}
	float tt = max(t, 0.0);
	float dd = pyrolux_drag_dist(tt, drag);
	vec3 p = p0 + v0 * dd;
	p += up * (buoyancy - gravity) * s * 0.5 * tt * tt / (1.0 + drag * tt * 0.5);
	p += wind * wind_follow * tt * min(tt * 2.0, 1.0);
	p += pyrolux_curl(p0 * turb_freq / s + vec3(0.0, -clock * turb_freq * 0.6, 0.0) + r2.xyz * 13.0) * turbulence * s * tt;
	if (mode == 0) {
		p -= em_velocity * tt * inherit;
	}

	if (mode == 1 && mushroom > 0.0) {
		float H = mushroom_height * s * (1.0 - exp(-tt / max(mushroom_rise, 0.01)));
		vec3 pm;
		float a = h.y * TAU;
		vec3 radial = cos(a) * normalize(em_x) + sin(a) * normalize(em_z);
		if (r2.w < 0.32) {
			pm = em_origin + up * H * h.x * 0.9 + radial * H * (0.05 + 0.07 * h.z);
		} else {
			float R = H * 0.42;
			float rr = H * 0.24 * (0.55 + 0.45 * h.z);
			float th = h.x * TAU + tt * 1.6;
			pm = em_origin + up * (H + sin(th) * rr) + radial * (R + cos(th) * rr);
		}
		pm += wind * tt * 0.5;
		p = mix(p, pm, smoothstep(0.0, 0.9, tt) * mushroom);
	}

	float sz = mix(size_start, size_end, pow(clamp(f, 0.0, 1.0), size_curve)) * s * (1.0 + (r2.z * 2.0 - 1.0) * size_var);
	if (mode == 0) {
		sz *= mix(0.55, 1.0, level);
	}
	p.y = max(p.y, ground_y + sz * 0.25);

	float temp = heat * (1.0 + (r2.y * 2.0 - 1.0) * heat_var) * surf_heat;
	temp -= mode == 0 ? cool_rate * f : cool_rate * tt;
	v_heat = temp;
	v_f = clamp(f, 0.0, 1.0);
	v_env = alive * smoothstep(0.0, max(fade_in, 0.001), f) * (1.0 - smoothstep(1.0 - fade_out, 1.0, f));
	v_seed = vec3(r.zw * 37.0, r2.x * 19.0);
	v_glow = glow_under * exp(-f * 3.0);

	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam - p;
	float dist = max(length(to_cam), 0.001);
	float w = max(sz, dist * pixel_angle * 1.5);
	v_env *= clamp(sz / w, 0.0, 1.0) * smoothstep(near_fade * s, near_fade * s * 3.0, dist);

	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 vup = INV_VIEW_MATRIX[1].xyz;
	vec2 c = UV * 2.0 - 1.0;
	vec3 offs;
	if (stretch > 0.0) {
		// Align with the current velocity on screen.
		vec3 vel = v0 * exp(-drag * tt) + up * (buoyancy - gravity) * s * tt + wind * wind_follow;
		vec2 sv = vec2(dot(vel, right), dot(vel, vup));
		float sl = length(sv);
		vec2 ax = sl > 0.0001 ? sv / sl : vec2(0.0, 1.0);
		float len = 1.0 + stretch * sl / max(s, 0.001);
		vec3 a_up = right * ax.x + vup * ax.y;
		vec3 a_side = right * ax.y - vup * ax.x;
		offs = a_side * c.x * w + a_up * c.y * w * len;
		v_light = vec2(dot(up, a_side), dot(up, a_up));
	} else {
		float ang = r.z * TAU + spin * tt * (r2.x * 2.0 - 1.0);
		float ca = cos(ang);
		float sa = sin(ang);
		vec2 rc = vec2(c.x * ca - c.y * sa, c.x * sa + c.y * ca);
		offs = right * rc.x * w + vup * rc.y * w;
		// World up expressed in the rotated quad space, for the fake smoke lighting.
		vec2 wu = vec2(dot(up, right), dot(up, vup));
		v_light = vec2(wu.x * ca + wu.y * sa, -wu.x * sa + wu.y * ca);
	}
	v_q = c;
	VERTEX = alive > 0.0 ? p + offs : em_origin;
	NORMAL = to_cam / dist;
}

void fragment() {
	vec2 q = v_q;
	float scroll = kind == 0 ? time * noise_speed * 1.5 : 0.0;
	vec3 nc = vec3(q * noise_scale + v_seed.xy, v_seed.z + time * noise_speed * 0.5);
	nc.y -= scroll;
	vec2 warp = vec2(pyrolux_vnoise(nc * 0.9), pyrolux_vnoise(nc * 0.9 + 7.3)) - 0.5;
	vec2 qw = q + warp * (kind == 0 ? 0.9 : 0.6);
	if (kind == 0) {
		// Teardrop: narrow toward the leading (upper) end so flames come to a point.
		qw.x /= mix(1.05, 0.3, clamp(qw.y * 0.5 + 0.5, 0.0, 1.0));
		qw.y = qw.y * 0.9 + 0.08;
	}
	float n = pyrolux_fbm(nc + vec3(warp * 1.5, 0.0), octaves);
	float d = length(qw);
	float base = smoothstep(0.0, softness + 0.01, clamp(1.0 - d, 0.0, 1.0));
	float v;
	float th;
	float dens;
	if (kind == 1 || kind == 2 || kind == 3) {
		// Smoke and fireballs: mostly noise, soft and billowy, thinning as it ages.
		v = base * (0.25 + n * 1.25);
		th = 0.22 + erosion * v_f * 0.5;
		dens = smoothstep(th, th + 0.55, v);
	} else {
		v = base * (0.45 + n * 1.1);
		th = 0.18 + erosion * v_f * 0.55;
		dens = smoothstep(th, th + 0.45, v);
	}
#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
	if (soft_distance > 0.0) {
		float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
		vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		float scene_z = -vp.z / vp.w;
		dens *= clamp((scene_z + VERTEX.z) / soft_distance, 0.0, 1.0);
	}
#endif
	float env = v_env;
	float hp = v_heat * (0.35 + 0.75 * dens) * (0.7 + 0.5 * n);
	vec3 flame = pyrolux_ramp(clamp(hp, 0.0, 1.1), col_cool.rgb, col_hot.rgb, col_core.rgb) * emission * intensity * dens;

	vec3 nq = vec3(qw, sqrt(max(1.0 - d * d, 0.0)));
	vec3 L = normalize(vec3(v_light, 0.6));
	float lit = clamp(dot(nq, L) * 0.5 + 0.5, 0.0, 1.0);
	float shade = mix(1.0 - smoke_light, 1.0, lit) * (0.65 + 0.7 * n);
	vec3 smoke_rgb = col_smoke.rgb * tint.rgb * shade + col_glow.rgb * v_glow * (1.0 - lit * 0.6) * 0.1;
	float smoke_a = dens * col_smoke.a * tint.a * smoke_opacity;

	vec3 rgb;
	float a;
	if (kind == 0) {
		rgb = flame;
		a = dens * flame_opacity;
	} else if (kind == 1 || kind == 3) {
		rgb = smoke_rgb * smoke_a;
		a = smoke_a;
	} else {
		// Fireball: hot puffs glow, cooling puffs turn into dark smoke instead of flat red.
		// Fireball: hot puffs glow with billowing detail, cooling puffs turn into dark smoke.
		float hot = smoothstep(0.15, 0.7, v_heat);
		float glow_part = smoothstep(0.3, 0.85, hp);
		float billow = (0.45 + 0.9 * n) * mix(0.55, 1.0, lit) * (0.6 + 0.4 * base);
		rgb = flame * billow * hot * glow_part + smoke_rgb * smoke_a * (1.0 - hot * glow_part * 0.85);
		a = smoke_a * (1.0 - 0.6 * hot * glow_part) + dens * max(flame_opacity, 0.3) * hot * glow_part * 0.6;
	}
	ALBEDO = rgb * env;
	ALPHA = clamp(a * env, 0.0, 1.0);
}
