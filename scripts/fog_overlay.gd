extends Node2D
## Reusable fog of war overlay — a pure VISION system layered on top of the scene.
##
## The scene renders completely normally (layer 1 lighting untouched).
## A separate SubViewport renders a black-and-white vision mask using a
## PointLight2D on layer 2 with shadow_enabled + cloned LightOccluder2D
## polygons. The fog shader samples that mask: fog where black, clear where white.
##
## Requires the Player node to have a `facing_direction_snapped` Vector2 property.

# ----- Vision shape tunables -----
@export var ambient_radius: float = 30
@export var ambient_softness_power: float = 0.65
@export var cone_reach: float = 200.0
@export var cone_angle_degrees: float = 210
@export var vision_energy: float = 1.0

# ----- Internal refs (built at runtime) -----
var _player: CharacterBody2D = null
var _camera: Camera2D = null

# SubViewport for the vision mask
var _mask_viewport: SubViewport = null
var _mask_canvas_mod: CanvasModulate = null
var _mask_light: PointLight2D = null
var _mask_fill: ColorRect = null  # white target to be lit
var _mask_occluder_root: Node2D = null

# SubViewport for hidden sprites (layer 7 content rendered in isolation)
var _hidden_viewport: SubViewport = null
var _hidden_sprite_root: Node2D = null

# Fog overlay
var _fog_rect: ColorRect = null
var _fog_material: ShaderMaterial = null

var _vision_texture: ImageTexture = null

const FOG_LIGHT_LAYER: int = 2
const FOG_CANVAS_LAYER: int = 90

# =====================================================================
# Lifecycle
# =====================================================================

func _ready() -> void:
	_vision_texture = _generate_vision_texture()
	_build_mask_viewport()
	_build_hidden_viewport()
	_build_fog_overlay()
	# Clone occluders and reparent hidden sprites after siblings are ready
	call_deferred("_clone_occluders_into_mask")
	call_deferred("_reparent_hidden_sprites")

func _process(_delta: float) -> void:
	if _player == null:
		_player = _find_player()
		if _player == null:
			return
	if _camera == null or not is_instance_valid(_camera):
		_camera = _resolve_active_camera()

	_sync_mask_viewport()
	_sync_hidden_viewport()

# =====================================================================
# Build the SubViewport that renders the vision mask
# =====================================================================

func _build_mask_viewport() -> void:
	_mask_viewport = SubViewport.new()
	_mask_viewport.transparent_bg = false
	_mask_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_mask_viewport.canvas_cull_mask = 0xFFFFFFFF
	# Size will be synced to main viewport each frame
	var main_size := get_viewport().get_visible_rect().size
	_mask_viewport.size = Vector2i(int(main_size.x), int(main_size.y))

	# CanvasModulate makes the SubViewport black by default.
	# The vision light will paint white where the player can see.
	_mask_canvas_mod = CanvasModulate.new()
	_mask_canvas_mod.color = Color(0, 0, 0, 1)
	_mask_viewport.add_child(_mask_canvas_mod)

	# A large white ColorRect that the vision light illuminates.
	# Needs to be enormous to cover wherever the camera looks.
	_mask_fill = ColorRect.new()
	_mask_fill.color = Color.WHITE
	_mask_fill.size = Vector2(10000, 10000)
	_mask_fill.position = Vector2(-5000, -5000)
	_mask_fill.light_mask = FOG_LIGHT_LAYER
	_mask_viewport.add_child(_mask_fill)

	# The vision PointLight2D — cone + circle shape, shadow enabled.
	_mask_light = PointLight2D.new()
	_mask_light.texture = _vision_texture
	_mask_light.range_item_cull_mask = FOG_LIGHT_LAYER
	_mask_light.shadow_enabled = true
	_mask_light.shadow_color = Color(0, 0, 0, 1)
	_mask_light.energy = vision_energy
	_mask_light.color = Color.WHITE
	var tex_radius := 128.0
	_mask_light.texture_scale = cone_reach / tex_radius
	_mask_viewport.add_child(_mask_light)

	# Container for cloned occluders
	_mask_occluder_root = Node2D.new()
	_mask_occluder_root.name = "Occluders"
	_mask_viewport.add_child(_mask_occluder_root)

	add_child(_mask_viewport)

# =====================================================================
# Build the SubViewport that renders hidden sprites (layer 7) in isolation
# =====================================================================

func _build_hidden_viewport() -> void:
	_hidden_viewport = SubViewport.new()
	_hidden_viewport.transparent_bg = true  # transparent so we only see sprites
	_hidden_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_hidden_viewport.canvas_cull_mask = 0xFFFFFFFF
	var main_size := get_viewport().get_visible_rect().size
	_hidden_viewport.size = Vector2i(int(main_size.x), int(main_size.y))

	# Root node for reparented hidden sprites
	_hidden_sprite_root = Node2D.new()
	_hidden_sprite_root.name = "HiddenSprites"
	_hidden_viewport.add_child(_hidden_sprite_root)

	add_child(_hidden_viewport)

# =====================================================================
# Build the fog overlay (CanvasLayer + shader ColorRect)
# =====================================================================

func _build_fog_overlay() -> void:
	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = FOG_CANVAS_LAYER
	add_child(canvas_layer)

	var shader := load("res://shaders/fog_of_war.gdshader") as Shader
	_fog_material = ShaderMaterial.new()
	_fog_material.shader = shader

	# Pass the SubViewport textures
	_fog_material.set_shader_parameter("vision_mask", _mask_viewport.get_texture())
	_fog_material.set_shader_parameter("hidden_sprites", _hidden_viewport.get_texture())

	_fog_rect = ColorRect.new()
	_fog_rect.material = _fog_material
	_fog_rect.anchor_right = 1.0
	_fog_rect.anchor_bottom = 1.0
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas_layer.add_child(_fog_rect)

# =====================================================================
# Clone LightOccluder2D nodes from the scene into the mask SubViewport
# =====================================================================

func _clone_occluders_into_mask() -> void:
	var scene_root := _get_level_root()
	if scene_root == null:
		return
	_clone_occluders_recursive(scene_root)

func _clone_occluders_recursive(node: Node) -> void:
	if node is LightOccluder2D and not _is_fog_overlay_child(node):
		var src := node as LightOccluder2D
		if src.occluder != null:
			var clone := LightOccluder2D.new()
			clone.occluder = src.occluder
			clone.occluder_light_mask = FOG_LIGHT_LAYER
			clone.global_position = src.global_position
			clone.global_rotation = src.global_rotation
			clone.global_scale = src.global_scale
			# Store a reference to the source so we can sync transforms if needed
			clone.set_meta("source_node", src.get_path())
			_mask_occluder_root.add_child(clone)
	for child in node.get_children():
		_clone_occluders_recursive(child)

func _is_fog_overlay_child(node: Node) -> bool:
	var n := node
	while n != null:
		if n == self:
			return true
		n = n.get_parent()
	return false

# =====================================================================
# Sync the mask viewport camera to the main camera each frame
# =====================================================================

func _sync_mask_viewport() -> void:
	if _mask_viewport == null or _player == null:
		return

	# Match SubViewport size to main viewport
	var main_vp := get_viewport()
	var main_size := main_vp.get_visible_rect().size
	var target_size := Vector2i(int(main_size.x), int(main_size.y))
	if _mask_viewport.size != target_size:
		_mask_viewport.size = target_size

	# Position the vision light at the player position
	_mask_light.global_position = _player.global_position

	# Rotate cone to match facing direction.
	# Texture cone points DOWN (+Y). Rotation = angle from +Y to facing dir.
	var dir: Vector2 = _player.facing_direction_snapped
	if dir.length_squared() < 0.0001:
		dir = Vector2(0, 1)
	_mask_light.rotation = Vector2(0, 1).angle_to(dir)

	# The SubViewport has its own canvas transform.
	# We need it to match the main viewport's so the mask aligns pixel-perfect.
	var main_canvas_transform := main_vp.canvas_transform
	_mask_viewport.canvas_transform = main_canvas_transform

# =====================================================================
# Player discovery
# =====================================================================

func _find_player() -> CharacterBody2D:
	var scene_root := _get_level_root()
	if scene_root == null:
		return null
	var player := scene_root.find_child("Player")
	if player is CharacterBody2D:
		return player as CharacterBody2D
	return null

func _get_level_root() -> Node:
	var parent := get_parent()
	if parent != null:
		return parent
	return get_tree().current_scene

func _resolve_active_camera() -> Camera2D:
	if _player != null:
		var player_camera := _player.get_node_or_null("Camera2D")
		if player_camera is Camera2D:
			return player_camera as Camera2D
	var viewport_camera := get_viewport().get_camera_2d()
	if viewport_camera != null:
		return viewport_camera
	return null

# =====================================================================
# Sync the hidden-sprite SubViewport to the main camera each frame
# =====================================================================

func _sync_hidden_viewport() -> void:
	if _hidden_viewport == null:
		return
	var main_vp := get_viewport()
	var main_size := main_vp.get_visible_rect().size
	var target_size := Vector2i(int(main_size.x), int(main_size.y))
	if _hidden_viewport.size != target_size:
		_hidden_viewport.size = target_size
	_hidden_viewport.canvas_transform = main_vp.canvas_transform

# =====================================================================
# Reparent layer-7 sprites into the hidden SubViewport.
# They are removed from the main scene so they don't render there,
# and instead render only inside the hidden SubViewport. The fog
# shader composites them back where the vision cone clears the fog.
# =====================================================================

const FOG_HIDDEN_LAYER_BIT: int = 64  # bit 6 = layer 7

var _hidden_reparented: bool = false

## Tracks source nodes and their clones so we can sync transforms each frame.
var _hidden_clones: Array[Dictionary] = []

func _reparent_hidden_sprites() -> void:
	if _hidden_reparented:
		return
	_hidden_reparented = true
	var scene_root := _get_level_root()
	if scene_root:
		_collect_hidden_sprites_recursive(scene_root)

func _collect_hidden_sprites_recursive(node: Node) -> void:
	# Collect children first (avoid issues with tree modification during iteration)
	var children := node.get_children()
	for child in children:
		_collect_hidden_sprites_recursive(child)

	if node is CanvasItem and not _is_fog_overlay_child(node):
		var ci := node as CanvasItem
		if ci.visibility_layer & FOG_HIDDEN_LAYER_BIT:
			_move_to_hidden_viewport(ci)

func _move_to_hidden_viewport(ci: CanvasItem) -> void:
	if not (ci is Node2D):
		return
	if _is_fog_overlay_child(ci):
		return
	var n2d := ci as Node2D

	# Remember the global transform before reparenting
	var gpos: Vector2 = n2d.global_position
	var grot: float = n2d.global_rotation
	var gscale: Vector2 = n2d.global_scale

	# Remove from main scene and add to hidden viewport
	var old_parent := ci.get_parent()
	if old_parent:
		old_parent.remove_child(ci)
	_hidden_sprite_root.add_child(ci)

	# Restore world transform
	n2d.global_position = gpos
	n2d.global_rotation = grot
	n2d.global_scale = gscale

# =====================================================================
# Procedural vision texture generation
# =====================================================================

func _generate_vision_texture() -> ImageTexture:
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size / 2.0, size / 2.0)

	var tex_radius := 128.0
	var ambient_tex := (ambient_radius / cone_reach) * tex_radius
	var cone_tex := tex_radius * 0.95  # use nearly full texture
	var cone_half_angle := deg_to_rad(cone_angle_degrees / 2.0)
	var cone_direction := Vector2(0, 1)  # +Y = down in Godot 2D

	for y in size:
		for x in size:
			var pos := Vector2(x, y) - center
			var dist := pos.length()
			var alpha := 0.0

			# Ambient circle — bright near player, gentle fade
			if dist < ambient_tex:
				# True center-origin fade: intensity starts decreasing immediately from center.
				var ambient_falloff := 1.0 - clampf(dist / maxf(ambient_tex, 0.0001), 0.0, 1.0)
				alpha = pow(clampf(ambient_falloff, 0.0, 1.0), maxf(ambient_softness_power, 0.01))

			# Directional cone — super gradual distance taper
			if dist < cone_tex and dist > 0.01:
				var angle_to_cone := absf(pos.normalized().angle_to(cone_direction))
				if angle_to_cone < cone_half_angle:
					# Start bright, begin fading at 20% of range, reach 0 at 100%
					var dist_falloff := 1.0 - _smooth(cone_tex * 0.2, cone_tex, dist)
					# Soft angle edges — start fading at 50% of half-angle
					var angle_falloff := 1.0 - _smooth(cone_half_angle * 0.5, cone_half_angle, angle_to_cone)
					alpha = maxf(alpha, dist_falloff * angle_falloff)

			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0)))

	return ImageTexture.create_from_image(img)

func _smooth(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / maxf(edge1 - edge0, 0.0001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
