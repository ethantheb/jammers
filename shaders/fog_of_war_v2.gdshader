shader_type canvas_item;

uniform sampler2D base_world_tex;
uniform sampler2D enemy_tex;
uniform sampler2D vision_shape_tex : repeat_disable, filter_linear;

uniform vec2 vision_center_uv = vec2(0.5, 0.5);
uniform float vision_reach_px = 220.0;
uniform float vision_softness_px = 20.0;
uniform float ambient_radius_px = 44.0;
uniform float ambient_edge_softness_px = 10.0;
uniform float vision_rotation_rad = 0.0;
uniform vec2 viewport_size_px = vec2(1280.0, 720.0);

uniform float enemy_blur_radius_uv = 0.008;
uniform float enemy_blur_strength = 0.78;
uniform vec4 enemy_tint : source_color = vec4(0.72, 0.72, 0.75, 0.82);
uniform vec4 fog_color : source_color = vec4(0.20, 0.20, 0.22, 1.0);
uniform float fog_speed = 0.14;
uniform float fog_world_scale = 0.008;
uniform float fog_noise_strength = 0.18;
uniform float fog_tint_strength = 0.12;
uniform float edge_noise_strength = 0.08;
uniform float edge_noise_scale = 14.0;
uniform float seed = 42.0;
uniform vec2 world_from_screen_x = vec2(1.0, 0.0);
uniform vec2 world_from_screen_y = vec2(0.0, 1.0);
uniform vec2 world_from_screen_origin = vec2(0.0, 0.0);

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 17.0) * 43758.5453);
}

float noise2d(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += amplitude * noise2d(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

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

float sample_enemy_alpha(vec2 uv) {
	return texture(enemy_tex, uv).a;
}

void accum_enemy_alpha(inout float accum, inout float weight_sum, vec2 uv, float w) {
	accum += sample_enemy_alpha(uv) * w;
	weight_sum += w;
}

float sample_enemy_alpha_blur(vec2 uv, vec2 radius) {
	if (radius.x <= 0.000001 || radius.y <= 0.000001) {
		return sample_enemy_alpha(uv);
	}

	vec2 d1 = radius * 0.35;
	vec2 d2 = radius * 0.70;
	vec2 d3 = radius;

	float accum = 0.0;
	float wsum = 0.0;

	// Blur enemy alpha only, then render a flat-tinted silhouette blob.
	accum_enemy_alpha(accum, wsum, uv, 0.20);

	accum_enemy_alpha(accum, wsum, uv + vec2(d1.x, 0.0), 0.10);
	accum_enemy_alpha(accum, wsum, uv - vec2(d1.x, 0.0), 0.10);
	accum_enemy_alpha(accum, wsum, uv + vec2(0.0, d1.y), 0.10);
	accum_enemy_alpha(accum, wsum, uv - vec2(0.0, d1.y), 0.10);

	accum_enemy_alpha(accum, wsum, uv + vec2(d2.x, 0.0), 0.07);
	accum_enemy_alpha(accum, wsum, uv - vec2(d2.x, 0.0), 0.07);
	accum_enemy_alpha(accum, wsum, uv + vec2(0.0, d2.y), 0.07);
	accum_enemy_alpha(accum, wsum, uv - vec2(0.0, d2.y), 0.07);

	accum_enemy_alpha(accum, wsum, uv + vec2(d3.x, 0.0), 0.04);
	accum_enemy_alpha(accum, wsum, uv - vec2(d3.x, 0.0), 0.04);
	accum_enemy_alpha(accum, wsum, uv + vec2(0.0, d3.y), 0.04);
	accum_enemy_alpha(accum, wsum, uv - vec2(0.0, d3.y), 0.04);

	accum_enemy_alpha(accum, wsum, uv + vec2(d1.x, d1.y), 0.05);
	accum_enemy_alpha(accum, wsum, uv + vec2(-d1.x, d1.y), 0.05);
	accum_enemy_alpha(accum, wsum, uv + vec2(d1.x, -d1.y), 0.05);
	accum_enemy_alpha(accum, wsum, uv + vec2(-d1.x, -d1.y), 0.05);

	accum_enemy_alpha(accum, wsum, uv + vec2(d2.x, d2.y), 0.03);
	accum_enemy_alpha(accum, wsum, uv + vec2(-d2.x, d2.y), 0.03);
	accum_enemy_alpha(accum, wsum, uv + vec2(d2.x, -d2.y), 0.03);
	accum_enemy_alpha(accum, wsum, uv + vec2(-d2.x, -d2.y), 0.03);

	return accum / max(wsum, 0.000001);
}

void fragment() {
	float raw_visibility = max(sample_vision(SCREEN_UV), sample_ambient_circle(SCREEN_UV));
	float t = TIME * fog_speed * 3.0;
	float edge_noise = (noise2d(SCREEN_UV * edge_noise_scale + vec2(t * 0.4, t * 0.25)) - 0.5) * edge_noise_strength;
	float edge_band = smoothstep(0.06, 0.55, raw_visibility) * (1.0 - smoothstep(0.55, 0.95, raw_visibility));
	float visibility = clamp(raw_visibility + edge_noise * edge_band * 2.0, 0.0, 1.0);
	float outside = 1.0 - visibility;

	vec4 base_world = texture(base_world_tex, SCREEN_UV);
	vec2 screen_px = SCREEN_UV * viewport_size_px;
	vec2 world_pos = vec2(
		world_from_screen_x.x * screen_px.x + world_from_screen_y.x * screen_px.y + world_from_screen_origin.x,
		world_from_screen_x.y * screen_px.x + world_from_screen_y.y * screen_px.y + world_from_screen_origin.y
	);
	vec2 fog_uv = world_pos * fog_world_scale;
	vec2 flow = vec2(
		noise2d(fog_uv * 0.65 + vec2(t * 0.9, -t * 0.6)),
		noise2d(fog_uv * 0.65 + vec2(-t * 0.7, t * 0.8))
	) - vec2(0.5);
	fog_uv += flow * 0.9;
	float noise1 = fbm(fog_uv + vec2(t * 0.5, -t * 0.35));
	float noise2_val = fbm(fog_uv * 1.6 + vec2(-t * 0.45, t * 0.35) + vec2(97.0, 43.0));
	float noise3_val = fbm(fog_uv * 0.65 + vec2(t * 0.22, t * 0.5) + vec2(-53.0, 71.0));
	float fog_pattern = mix(mix(noise1, noise2_val, 0.5), noise3_val, 0.3);
	float inverse_density = pow(clamp(1.0 - fog_pattern, 0.0, 1.0), 1.25);
	float pattern_amount = clamp(fog_noise_strength, 0.0, 1.0);
	float pattern_dark = clamp(0.30 + inverse_density * 0.42 + fog_pattern * 0.38, 0.0, 1.0);
	float darkness = mix(0.56, pattern_dark, pattern_amount);
	vec3 fogged_world = base_world.rgb * darkness;
	float fog_mottle = (fog_pattern - 0.5) * 0.42 * pattern_amount;
	fogged_world = clamp(fogged_world + vec3(fog_mottle), 0.0, 1.0);
	float tint_amount = clamp(fog_tint_strength, 0.0, 1.0) * (0.45 + inverse_density * 0.55);
	fogged_world = mix(fogged_world, fog_color.rgb, tint_amount);
	vec3 world_rgb = mix(base_world.rgb, fogged_world, outside);
	// Keep the overlay transparent inside the vision cone so live scene sorting remains authoritative.
	float world_alpha = clamp(outside * base_world.a, 0.0, 1.0);

	vec2 blur_ofs = vec2(enemy_blur_radius_uv, enemy_blur_radius_uv);
	float enemy_alpha_blur = sample_enemy_alpha_blur(SCREEN_UV, blur_ofs);
	float enemy_blob = smoothstep(0.02, 0.30, enemy_alpha_blur);
	vec3 enemy_rgb = enemy_tint.rgb;
	float enemy_alpha = enemy_blob * outside * clamp(enemy_blur_strength, 0.0, 1.0) * enemy_tint.a;

	vec3 result_rgb = mix(world_rgb, enemy_rgb, clamp(enemy_alpha, 0.0, 1.0));
	float out_alpha = clamp(world_alpha + enemy_alpha * (1.0 - world_alpha), 0.0, 1.0);

	COLOR = vec4(result_rgb, out_alpha);
}
