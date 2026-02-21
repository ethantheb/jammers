shader_type canvas_item;

uniform sampler2D vision_shape_tex : repeat_disable, filter_linear;
uniform vec2 vision_center_uv = vec2(0.5, 0.5);
uniform float vision_reach_px = 220.0;
uniform float vision_softness_px = 20.0;
uniform float ambient_radius_px = 44.0;
uniform float ambient_edge_softness_px = 10.0;
uniform float vision_rotation_rad = 0.0;
uniform vec2 viewport_size_px = vec2(1280.0, 720.0);

float sample_vision_raw(vec2 uv) {
	float reach = max(vision_reach_px, 1.0);
	vec2 delta_px = (uv - vision_center_uv) * viewport_size_px;
	float s = sin(-vision_rotation_rad);
	float c = cos(-vision_rotation_rad);
	vec2 rotated = vec2(
		delta_px.x * c - delta_px.y * s,
		delta_px.x * s + delta_px.y * c
	);
	vec2 shape_uv = vec2(0.5) + rotated / (2.0 * reach);
	if (shape_uv.x < 0.0 || shape_uv.x > 1.0 || shape_uv.y < 0.0 || shape_uv.y > 1.0) {
		return 0.0;
	}
	return texture(vision_shape_tex, shape_uv).a;
}

float sample_vision(vec2 uv) {
	float base = sample_vision_raw(uv);
	float blur_px = max(vision_softness_px * 0.35, 0.0);
	if (blur_px <= 0.001) {
		return base;
	}
	vec2 ofs = vec2(
		blur_px / max(viewport_size_px.x, 1.0),
		blur_px / max(viewport_size_px.y, 1.0)
	);
	float px = sample_vision_raw(uv + vec2(ofs.x, 0.0));
	float nx = sample_vision_raw(uv - vec2(ofs.x, 0.0));
	float py = sample_vision_raw(uv + vec2(0.0, ofs.y));
	float ny = sample_vision_raw(uv - vec2(0.0, ofs.y));
	return clamp(base * 0.5 + (px + nx + py + ny) * 0.125, 0.0, 1.0);
}

float sample_ambient_circle(vec2 uv) {
	vec2 delta_px = (uv - vision_center_uv) * viewport_size_px;
	float dist = length(delta_px);
	float edge = max(ambient_edge_softness_px, 0.001);
	return 1.0 - smoothstep(ambient_radius_px, ambient_radius_px + edge, dist);
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV) * COLOR;
	float visible = max(sample_vision(SCREEN_UV), sample_ambient_circle(SCREEN_UV));
	COLOR = tex;
	COLOR.a *= visible;
}
