shader_type spatial;
render_mode cull_disabled,unshaded;
uniform sampler2D noise1;
uniform vec4 color : source_color;
uniform vec4 overlayColor : source_color;
void fragment() {
	// Called for every pixel the material is visible on.
	ALBEDO = color.rgb;
	float mixAmount = texture(noise1,vec2(UV.x,0.25*UV.y) + vec2(0,0.55*TIME)).r - 0.2;
	mixAmount = smoothstep(0.5,0.9,mixAmount);
	ALBEDO = mix(ALBEDO,overlayColor.rgb,mixAmount);
	ALPHA = mixAmount;
}
