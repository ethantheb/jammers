shader_type canvas_item;

uniform vec4 puddle_color : source_color = vec4(0.3, 0.38, 0.08, 0.55);
uniform float animation_speed = 0.35;
uniform float edge_softness = 1.6;
uniform float seed = 0.0;
uniform vec2 shape_center = vec2(0.0, 0.0);
uniform float shape_radius = 18.0;
uniform int shape_point_count = 0;
uniform vec2 shape_points[64];

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

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

float segment_distance(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float denom = max(dot(ba, ba), 0.0001);
	float h = clamp(dot(pa, ba) / denom, 0.0, 1.0);
	return length(pa - ba * h);
}

float polygon_edge_distance(vec2 p) {
	float min_edge = 1e20;
	if (shape_point_count < 3) {
		return min_edge;
	}

	for (int i = 0; i < 64; i++) {
		if (i >= shape_point_count) {
			break;
		}

		int j = i + 1;
		if (j >= shape_point_count) {
			j = 0;
		}

		vec2 a = shape_points[i];
		vec2 b = shape_points[j];
		min_edge = min(min_edge, segment_distance(p, a, b));
	}
	return min_edge;
}

void fragment() {
	float t = TIME * animation_speed;

	vec2 centered = local_pos - shape_center;
	float edge_px = polygon_edge_distance(local_pos);

	float n = noise2d(centered * 0.11 + vec2(t * 0.18, -t * 0.14));
	float n2 = noise2d(centered * 0.23 + vec2(-t * 0.12, t * 0.09));
	float grime = 0.93 + (n - 0.5) * 0.10 + (n2 - 0.5) * 0.06;

	float alpha = 1.0;
	if (shape_point_count >= 3) {
		float px_soft = max(edge_softness * 0.45, 0.001);
		alpha = smoothstep(0.0, px_soft, edge_px);
	} else {
		float dist_n = clamp(length(centered) / max(shape_radius, 0.001), 0.0, 1.0);
		float edge_width = clamp(edge_softness * 0.06, 0.01, 0.3);
		float edge_mask = 1.0 - smoothstep(1.0 - edge_width, 1.0, dist_n);
		alpha = mix(0.75, 1.0, edge_mask);
	}

	vec3 final_color = puddle_color.rgb * grime;
	COLOR = vec4(final_color, puddle_color.a * alpha);
}
