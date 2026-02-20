shader_type canvas_item;

// Vision mask — white = player can see, black = cannot see.
// Rendered by a SubViewport with the vision PointLight2D + occluders.
uniform sampler2D vision_mask;

// Hidden sprites — layer 7 content rendered in a separate SubViewport.
// These sprites are removed from the main scene entirely; the fog shader
// composites them back only where the vision cone clears the fog.
uniform sampler2D hidden_sprites;

uniform vec4 fog_color : source_color = vec4(0.20, 0.20, 0.22, 0.42);
uniform float fog_speed = 0.14;
uniform float edge_noise_strength = 0.10;
uniform float edge_width = 100;
uniform float edge_width_to_mask = 0.02;
uniform float visible_core_threshold = 0.82;
uniform float inverse_opacity_strength = 0.72;
uniform float hidden_reveal_threshold = 0.01;
uniform float hidden_reveal_softness = 0.22;
uniform float hidden_cone_expand = 0.20;
uniform float hidden_reveal_curve = 0.80;
uniform float hidden_edge_blur_uv = 0.0025;
uniform float seed = 42.0;

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

void fragment() {
	// Sample the vision mask — brightness = how visible this pixel is
	vec4 mask_color = texture(vision_mask, SCREEN_UV);
	float vision = max(mask_color.r, max(mask_color.g, mask_color.b));
	float vision_px = max(texture(vision_mask, SCREEN_UV + vec2(hidden_edge_blur_uv, 0.0)).r, max(texture(vision_mask, SCREEN_UV + vec2(hidden_edge_blur_uv, 0.0)).g, texture(vision_mask, SCREEN_UV + vec2(hidden_edge_blur_uv, 0.0)).b));
	float vision_nx = max(texture(vision_mask, SCREEN_UV + vec2(-hidden_edge_blur_uv, 0.0)).r, max(texture(vision_mask, SCREEN_UV + vec2(-hidden_edge_blur_uv, 0.0)).g, texture(vision_mask, SCREEN_UV + vec2(-hidden_edge_blur_uv, 0.0)).b));
	float vision_py = max(texture(vision_mask, SCREEN_UV + vec2(0.0, hidden_edge_blur_uv)).r, max(texture(vision_mask, SCREEN_UV + vec2(0.0, hidden_edge_blur_uv)).g, texture(vision_mask, SCREEN_UV + vec2(0.0, hidden_edge_blur_uv)).b));
	float vision_ny = max(texture(vision_mask, SCREEN_UV + vec2(0.0, -hidden_edge_blur_uv)).r, max(texture(vision_mask, SCREEN_UV + vec2(0.0, -hidden_edge_blur_uv)).g, texture(vision_mask, SCREEN_UV + vec2(0.0, -hidden_edge_blur_uv)).b));
	float blurred_vision = vision * 0.5 + (vision_px + vision_nx + vision_py + vision_ny) * 0.125;

	// Churning fog noise with flow-warped UVs for livelier motion.
	float t = TIME * fog_speed * 3.0;
	vec2 fog_uv = SCREEN_UV * 9.0;
	vec2 flow = vec2(
		noise2d(fog_uv * 0.65 + vec2(t * 0.9, -t * 0.6)),
		noise2d(fog_uv * 0.65 + vec2(-t * 0.7, t * 0.8))
	) - vec2(0.5);
	fog_uv += flow * 0.9;
	float noise1 = fbm(fog_uv + vec2(t * 0.5, -t * 0.35));
	float noise2_val = fbm(fog_uv * 1.6 + vec2(-t * 0.45, t * 0.35) + vec2(97.0, 43.0));
	float noise3_val = fbm(fog_uv * 0.65 + vec2(t * 0.22, t * 0.5) + vec2(-53.0, 71.0));
	float fog_pattern = mix(mix(noise1, noise2_val, 0.5), noise3_val, 0.3);

	// Noisy edge — distort the vision boundary with noise for smoky edges
	float edge_noise = noise2d(SCREEN_UV * 14.0 + vec2(t * 0.4, t * 0.25));
	float noisy_edge = (edge_noise - 0.5) * edge_noise_strength;

	// Visibility model:
	// 1) Inner shape (core) is fully clear.
	// 2) Outer cloned shape provides only the falloff band.
	// edge_width is border size in user units scaled into mask space.
	float core_threshold = clamp(visible_core_threshold + noisy_edge, 0.01, 0.98);
	float edge_span = max(edge_width * edge_width_to_mask, 0.0001);
	float outer_threshold = max(core_threshold - edge_span, 0.0);
	float visibility = smoothstep(outer_threshold, core_threshold, blurred_vision);

	// Lighter base fog plus stronger inverse pockets.
	float inverse_density = pow(clamp(1.0 - fog_pattern, 0.0, 1.0), 1.25);
	vec3 fog_final = fog_color.rgb + (fog_pattern - 0.5) * 0.24 - vec3(inverse_density * 0.08);
	float pattern_opacity = 0.62 + inverse_density * inverse_opacity_strength;
	float fog_alpha = (1.0 - visibility) * fog_color.a * pattern_opacity;

	// Hidden sprites (layer 7) share the same border-size system as world fog.
	vec4 sprite_color = texture(hidden_sprites, SCREEN_UV);
	float hidden_vision = blurred_vision;
	float hidden_expand = max(hidden_cone_expand, 0.0) * edge_span;
	float hidden_outer_threshold = max(outer_threshold - hidden_expand, 0.0);
	float hidden_edge_span = max(edge_span * (1.0 + max(hidden_reveal_softness, 0.0)), 0.0005);
	float hidden_core_threshold = min(hidden_outer_threshold + hidden_edge_span, 0.99);
	float sprite_visibility = smoothstep(hidden_outer_threshold, hidden_core_threshold, hidden_vision);
	float hidden_gate = smoothstep(
		max(hidden_reveal_threshold * 0.5, 0.00005),
		max(hidden_reveal_threshold * 1.5, 0.0001),
		hidden_vision
	);
	sprite_visibility *= hidden_gate;
	sprite_visibility = pow(clamp(sprite_visibility, 0.0, 1.0), hidden_reveal_curve);
	float sprite_alpha = sprite_color.a * sprite_visibility;
	// Hidden-layer pixels should not carry fog/perlin on top of them.
	fog_alpha *= (1.0 - sprite_alpha);

	// The fog composites over the scene. Sprite composites on top of that,
	// so it's always drawn over the fog — never visible through it.
	vec3 result = mix(fog_final, sprite_color.rgb, sprite_alpha);
	float result_alpha = clamp(fog_alpha + sprite_alpha, 0.0, 1.0);
	COLOR = vec4(result, result_alpha);
}
