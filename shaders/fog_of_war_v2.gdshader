shader_type canvas_item;

uniform sampler2D base_world_tex;
uniform sampler2D enemy_tex : filter_linear;
uniform sampler2D chase_enemy_tex : filter_linear;
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

// 13-tap 1D Gaussian weights (sigma ~4.0, normalized).
const int BLUR_TAPS = 13;
const float BLUR_OFFSETS[13] = float[13](
	-6.0, -5.0, -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0
);
const float BLUR_WEIGHTS[13] = float[13](
	0.0146, 0.0268, 0.0436, 0.0630, 0.0808, 0.0920, 0.0930,
	0.0920, 0.0808, 0.0630, 0.0436, 0.0268, 0.0146
);

// Two-pass separable Gaussian: 13 horizontal x 13 vertical = 169 effective
// samples, which properly dissolves the sprite into a smooth cloud.
vec4 sample_enemy_blur(vec2 uv, vec2 radius) {
	if (radius.x <= 0.000001 || radius.y <= 0.000001) {
		return texture(enemy_tex, uv);
	}

	// Step size: spread the 13 taps across the full radius.
	vec2 step_uv = radius / 6.0;

	vec4 accum = vec4(0.0);
	float wsum = 0.0;

	for (int y = 0; y < BLUR_TAPS; y++) {
		// First pass: horizontal blur at this vertical offset.
		vec4 row_accum = vec4(0.0);
		float row_wsum = 0.0;
		float wy = BLUR_WEIGHTS[y];
		vec2 row_uv = uv + vec2(0.0, BLUR_OFFSETS[y] * step_uv.y);

		for (int x = 0; x < BLUR_TAPS; x++) {
			vec2 sample_uv = row_uv + vec2(BLUR_OFFSETS[x] * step_uv.x, 0.0);
			vec4 s = texture(enemy_tex, sample_uv);
			float wx = BLUR_WEIGHTS[x];
			row_accum += vec4(s.rgb * s.a, s.a) * wx;
			row_wsum += wx;
		}

		vec4 row_result = row_accum / max(row_wsum, 0.000001);
		accum += row_result * wy;
		wsum += wy;
	}

	vec4 result = accum / max(wsum, 0.000001);
	float a = result.a;
	vec3 rgb = (a > 0.001) ? result.rgb / a : vec3(0.0);
	return vec4(rgb, a);
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
	vec4 enemy_blur = sample_enemy_blur(SCREEN_UV, blur_ofs);
	float enemy_blob = smoothstep(0.01, 0.55, enemy_blur.a);
	// Desaturate and darken the blurred sprite, then mix heavily with fog tint
	// so it reads as a dark shape in the fog, not a bright blob.
	float lum = dot(enemy_blur.rgb, vec3(0.299, 0.587, 0.114));
	float dark_lum = lum * 0.3;
	vec3 enemy_rgb = mix(vec3(dark_lum), enemy_tint.rgb, 0.7);
	float enemy_alpha = enemy_blob * outside * clamp(enemy_blur_strength, 0.0, 1.0) * enemy_tint.a;

	vec3 result_rgb = mix(world_rgb, enemy_rgb, clamp(enemy_alpha, 0.0, 1.0));
	float out_alpha = clamp(world_alpha + enemy_alpha * (1.0 - world_alpha), 0.0, 1.0);

	// Composite chase-mode enemies crisp on top of everything.
	vec4 chase = texture(chase_enemy_tex, SCREEN_UV);
	result_rgb = mix(result_rgb, chase.rgb, chase.a);
	out_alpha = clamp(out_alpha + chase.a * (1.0 - out_alpha), 0.0, 1.0);

	COLOR = vec4(result_rgb, out_alpha);
}
