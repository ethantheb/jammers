shader_type canvas_item;

// Vision mask — white = player can see, black = cannot see.
// Rendered by a SubViewport with the vision PointLight2D + occluders.
uniform sampler2D vision_mask;

// Hidden sprites — layer 7 content rendered in a separate SubViewport.
// These sprites are removed from the main scene entirely; the fog shader
// composites them back only where the vision cone clears the fog.
uniform sampler2D hidden_sprites;

uniform vec4 fog_color : source_color = vec4(0.20, 0.20, 0.22, 0.58);
uniform float fog_speed = 0.08;
uniform float edge_noise_strength = 0.18;
uniform float edge_width = 0.70;
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

	// Churning fog noise — two offset FBM layers, faster animation
	float t = TIME * fog_speed * 3.0;
	vec2 fog_uv = SCREEN_UV * 8.0;
	float noise1 = fbm(fog_uv + vec2(t * 0.5, -t * 0.35));
	float noise2_val = fbm(fog_uv * 1.4 + vec2(-t * 0.35, t * 0.25) + vec2(97.0, 43.0));
	float noise3_val = fbm(fog_uv * 0.7 + vec2(t * 0.15, t * 0.4) + vec2(-53.0, 71.0));
	float fog_pattern = mix(mix(noise1, noise2_val, 0.5), noise3_val, 0.3);

	// Noisy edge — distort the vision boundary with noise for smoky edges
	float edge_noise = noise2d(SCREEN_UV * 14.0 + vec2(t * 0.4, t * 0.25));
	float noisy_edge = (edge_noise - 0.5) * edge_noise_strength;

	// Visibility: 0 = fully fogged, 1 = fully clear
	// Wide transition band — fog fades in very gradually from clear to fully fogged
	float low = 0.02 + noisy_edge;
	float high = low + edge_width;
	float visibility = smoothstep(low, high, vision);

	// Fog overlay — semi-transparent Perlin noise, unchanged from before.
	vec3 fog_final = fog_color.rgb + (fog_pattern - 0.5) * 0.20;
	float pattern_opacity = 1.0 + (0.5 - fog_pattern) * 0.6;
	float fog_alpha = (1.0 - visibility) * fog_color.a * pattern_opacity;

	// Hidden sprites (layer 7) — completely separate system.
	// Sprite reveal uses the same noisy edge as the fog so the boundary
	// matches perfectly. Sprite is fully invisible until the fog is fully
	// gone (vision >= high), then fades in over a narrow band matching
	// the tail of the fog transition.
	vec4 sprite_color = texture(hidden_sprites, SCREEN_UV);
	// visibility is already the single source of truth for the vision shape,
	// noise, falloff, and edge — sprite uses it directly, no duplication.
	sprite_color.a *= visibility;

	// The fog composites over the scene. Sprite composites on top of that,
	// so it's always drawn over the fog — never visible through it.
	vec3 result = mix(fog_final, sprite_color.rgb, sprite_color.a);
	float result_alpha = clamp(fog_alpha + sprite_color.a, 0.0, 1.0);
	COLOR = vec4(result, result_alpha);
}
