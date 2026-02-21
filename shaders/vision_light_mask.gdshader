shader_type canvas_item;

// Vision mask from the fog overlay's SubViewport.
// White = visible, black = fogged.
uniform sampler2D vision_mask;

void light() {
	float vision = max(
		texture(vision_mask, SCREEN_UV).r,
		max(texture(vision_mask, SCREEN_UV).g, texture(vision_mask, SCREEN_UV).b)
	);
	LIGHT *= vision;
}
