shader_type spatial;
// Separate expanded back-face hull. The visible model still uses ordinary
// back-face culling with independently validated winding; this is not a fix
// for inside-out geometry or a double-sided material.
render_mode unshaded, cull_front, shadows_disabled;
uniform vec4 ink_color : source_color = vec4(0.08, 0.13, 0.11, 1.0);
uniform float line_width = 0.025;
void vertex() {
	VERTEX += NORMAL * line_width;
}
void fragment() {
	ALBEDO = ink_color.rgb;
}
