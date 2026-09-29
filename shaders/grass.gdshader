shader_type spatial;
render_mode cull_disabled;
// 草地专用材质。草是场上唯一带顶点动画的装饰，所以不再用 StandardMaterial3D：
//   - 顶点位移（被角色踩开 + 回弹摆动）必须在 vertex() 里做；
//   - 距离淡出必须【逐顶点按当前视口相机】算，不能粗略按"玩家距离"算。
//
// 平时没有风（u_wind 默认 0），只有角色走到附近才动。

// 淡出区间：fade_start 处完全实心，fade_end 处完全消失（CPU 端在同一距离整块剔除）。
uniform float u_fade_start: hint_range(1.0, 200.0) = 46.0;
uniform float u_fade_end: hint_range(1.0, 300.0) = 72.0;

// 踩踏：角色半径内把叶尖朝"远离角色"的方向推开，再叠一层随运动量增大的摆动。
uniform float u_trample_radius: hint_range(0.1, 8.0) = 1.7;
uniform float u_trample_bend: hint_range(0.0, 2.0) = 0.42;
uniform float u_sway_amplitude: hint_range(0.0, 1.0) = 0.13;
uniform float u_sway_frequency: hint_range(0.0, 30.0) = 6.5;
// 常态风。默认 0 —— 没人在附近时草地必须是静的。
uniform float u_wind: hint_range(0.0, 1.0) = 0.0;
uniform vec2 u_wind_direction = vec2(1.0, 0.0);

uniform float u_time = 0.0;
// 叶高。弯曲权重 = (局部高度 / 叶高)^1.6：叶根不动、叶尖动得最多。
// 三个 LOD 的网格共用同一个叶高，否则远处那级会整体弯过头。
uniform float u_tuft_height: hint_range(0.05, 3.0) = 0.55;

// 每个角色一个 vec4：(x, z, 强度, 运动量)。长度必须与 grass_field.gd 的
// MAX_TRAMPLERS 一致，多余的槽位由 CPU 填零并用 u_trample_count 截断。
uniform int u_trample_count = 0;
uniform vec4 u_trample[8];
uniform int u_ground_impulse_count = 0;
// x/z 世界中心、作用半径、短暂冲击包络；根部不动，事件消失后自然回弹。
uniform vec4 u_ground_impulse[8];

varying vec3 v_color;
varying float v_fade;

// 4x4 有序抖动（Bayer）。用屏幕坐标而不是随机 hash：图案相对屏幕固定，
// 相机移动时同一片草的阈值是连续变化的，不会像逐像素噪声那样闪烁。
float bayer2(vec2 a) {
	a = floor(a);
	return fract(a.x * 0.5 + a.y * a.y * 0.75);
}

float bayer4(vec2 a) {
	return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

void vertex() {
	v_color = COLOR.rgb;
	// MultiMesh 的实例变换已经并进 MODEL_MATRIX，所以这里拿到的就是世界坐标。
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float bend_weight = pow(clamp(VERTEX.y / max(u_tuft_height, 0.05), 0.0, 1.0), 1.6);

	// 【位移必须按这一株自身的高度缩放】
	// bend_weight 是按【局部】顶点高度算的，实例之间毫无差别；而 push / sway 是
	// 【世界空间】的米数。两者不同源就出问题：一株实例缩放 0.4 的矮草实际只有
	// 22 cm 高，却要和 83 cm 的高草一样被推开 0.42 m、压低 0.21 m —— 位移是它
	// 身高的两倍、压低量等于它的全部高度，于是它被整个按到地面以下，看上去就
	// 是"走过去之后草不见了"。取 MODEL_MATRIX 第二列的长度就是实例的竖直缩放。
	float shape = max(length(MODEL_MATRIX[1].xyz), 0.2);

	vec3 offset = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		if (i >= u_trample_count) {
			break;
		}
		vec4 trampler = u_trample[i];
		vec2 away = world.xz - trampler.xy;
		float dist = length(away);
		float influence = 1.0 - smoothstep(u_trample_radius * 0.25, u_trample_radius, dist);
		if (influence <= 0.0) {
			continue;
		}
		vec2 direction = dist > 0.0001 ? away / dist : vec2(1.0, 0.0);
		// 被踩开：向外倒，同时压低一点，才像被鞋面压过去而不是被风吹。
		float push = influence * trampler.z * u_trample_bend * bend_weight * shape;
		offset.xz += direction * push;
		offset.y -= push * 0.5;
		// 回弹摆动：只在角色有运动量时才明显，停下后强度衰减、草慢慢立回来。
		float phase = world.x * 1.7 + world.z * 1.31;
		float sway = sin(u_time * u_sway_frequency + phase)
			* u_sway_amplitude * influence * trampler.w * bend_weight * shape;
		offset.xz += direction * sway;
		offset.y -= abs(sway) * 0.35;
	}

	for (int i = 0; i < 8; i++) {
		if (i >= u_ground_impulse_count) { break; }
		vec4 pulse = u_ground_impulse[i];
		vec2 away = world.xz - pulse.xy;
		float dist = length(away);
		float influence = 1.0 - smoothstep(pulse.z * 0.2, max(pulse.z, 0.01), dist);
		vec2 direction = away / max(dist, 0.001);
		float push = influence * pulse.w * bend_weight * shape * 0.55;
		offset.xz += direction * push;
		offset.y -= push * 0.3;
	}

	if (u_wind > 0.0) {
		// 统一沿天气风向倾倒；两个不同尺度的波叠出阵风内的局部起伏，但振幅完全
		// 由 CPU 阵风包络控制，静风时不会偷偷保留“呼吸摆动”。
		vec2 wind_dir = normalize(u_wind_direction + vec2(0.0001, 0.0));
		float phase = dot(world.xz, vec2(-wind_dir.y, wind_dir.x));
		float gust_shape = 0.72
			+ sin(u_time * 3.1 + phase * 0.42) * 0.20
			+ sin(u_time * 6.7 + world.x * 0.19 + world.z * 0.23) * 0.08;
		offset.xz += wind_dir * u_wind * gust_shape * bend_weight * shape;
		offset.y -= abs(u_wind * gust_shape) * 0.16 * bend_weight * shape;
	}

	// 【位移必须收敛，不能被人数线性放大】
	// offset 是逐个角色累加的。一个角色最多把叶尖推开约半个叶高，这是设计值；
	// 但八个角色挤在同一小块草地上就是八倍 —— 横向 4 米、竖直 -2 米，草直接沉到
	// 地形以下看不见，现象就是"走过去之后那一片草凭空消失了"。
	// 群体同时经过的场景（玩家出生点周围敌人还没散开）最容易踩到。
	// 用 tanh 做软限幅：单角色时 tanh 在小量处接近线性，几乎无损；
	// 人多了自动压到 reach 以内，不会让几何跳变。
	float reach = max(u_tuft_height * shape * 1.4, 0.05);
	float lateral = length(offset.xz);
	if (lateral > 0.0001) {
		offset.xz *= reach * tanh(lateral / reach) / lateral;
	}
	// 竖直方向同理：压低量最多到叶片自身高度的一半（约等于单人时的压低量），
	// 再多就穿越地面了。
	offset.y = max(offset.y, -u_tuft_height * shape * 0.5);

	vec3 bent_world = world + offset;
	// 位移是在世界空间算的（方向要跟着角色走），算完再转回局部空间交给管线。
	VERTEX = (inverse(MODEL_MATRIX) * vec4(bent_world, 1.0)).xyz;

	// 相机位置用 INV_VIEW_MATRIX 取：它总是"当前视口"的值，
	// 所以淡出距离跟实际渲染视角一致。
	vec3 camera_position = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_fade = 1.0 - smoothstep(u_fade_start, u_fade_end, distance(camera_position, bent_world));
}

void fragment() {
	// 抖动淡出而不是半透明：草是不透明几何，走 alpha blend 会有排序问题，
	// 而 discard 让远处的草"溶解"掉，配合雾几乎看不出边界。
	if (v_fade <= 0.002 || v_fade < bayer4(FRAGCOORD.xy)) {
		discard;
	}
	ALBEDO = v_color;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
