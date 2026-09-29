shader_type spatial;
render_mode diffuse_toon,cull_disabled;
uniform sampler2D noise;
uniform vec4 overlayColor : source_color;
void vertex() {
	VERTEX += 0.8 * texture(noise,UV + vec2(0.18*TIME,-0.8*TIME)).r * NORMAL;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
	float noi = texture(noise,0.2*UV + vec2(0.13*TIME,-0.15*TIME)).r;
	noi = smoothstep(0.3,0.5,noi);
	float noi2 = texture(noise,UV + vec2(0.13*TIME,-0.15*TIME)).r;
	noi2 = smoothstep(0.3,0.5,noi2 * COLOR.r);
	ALBEDO = mix(ALBEDO, overlayColor.rgb,0.4*noi2);
	ALPHA *= noi;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
