extends Node2D

@export_range(32.0, 1200.0, 1.0) var vision_radius_px: float = 481.0
@export_range(0.0, 200.0, 1.0) var vision_softness_px: float = 87.0
@export_range(0.0, 300.0, 1.0) var ambient_radius_px: float = 18.0
@export_range(0.05, 3.0, 0.01) var ambient_softness_power: float = 0.05
@export_range(0.0, 120.0, 1.0) var ambient_edge_softness_px: float = 60.0
@export_range(20.0, 360.0, 1.0) var cone_angle_degrees: float = 123.0
@export_range(0.0, 0.95, 0.01) var cone_distance_falloff_start_ratio: float = 0.0
@export_range(1, 4, 1) var cone_distance_falloff_smoothing_passes: int = 1
@export_range(0.0, 0.95, 0.01) var cone_angle_falloff_start_ratio: float = 0.09
@export_range(0.0, 4.0, 0.01) var vision_energy: float = 1.8
@export_range(0.0, 120.0, 1.0) var enemy_blur_radius_px: float = 7.0
@export_range(0.0, 1.0, 0.01) var enemy_blur_strength: float = 0.78
@export var enemy_tint: Color = Color(0.72, 0.72, 0.75, 0.82)
@export var fog_color: Color = Color(0.20, 0.20, 0.22, 1.0)
@export_range(0.0, 2.0, 0.01) var fog_speed: float = 0.15
@export_range(0.001, 0.05, 0.001) var fog_world_scale: float = 0.008
@export_range(0.0, 1.0, 0.01) var fog_noise_strength: float = 1.0
@export_range(0.0, 1.0, 0.01) var fog_tint_strength: float = 0.29
@export_range(0.0, 0.5, 0.01) var edge_noise_strength: float = 0.45

const FOG_CANVAS_LAYER: int = 90
const ENEMY_GROUP: StringName = &"fog_enemy"
const PEE_PUDDLE_GROUP: StringName = &"player_pee_puddles"
const VISION_TEXTURE_SIZE: int = 128
const STATIC_BASE_SYNC_INTERVAL_SEC: float = 0.5

var _player: CharacterBody2D = null

var _base_viewport: SubViewport = null
var _base_root: Node2D = null
var _base_bindings: Array[Dictionary] = []

var _enemy_viewport: SubViewport = null
var _enemy_root: Node2D = null

var _overlay_material: ShaderMaterial = null
var _enemy_visibility_shader: Shader = null
var _vision_shape_texture: ImageTexture = null
var _vision_texture_key: String = ""
var _static_base_sync_timer: float = 0.0

# source_id -> {"source_ref": WeakRef, "clone_ref": WeakRef, "source_material": Material}
var _enemy_entries: Dictionary = {}

func _ready() -> void:
	_enemy_visibility_shader = load("res://shaders/enemy_visibility_mask_v2.gdshader") as Shader
	_ensure_vision_texture()
	_build_base_viewport()
	_build_enemy_viewport()
	_build_overlay()
	call_deferred("_clone_base_world")
	call_deferred("_register_group_enemies")

func _process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
	_static_base_sync_timer -= delta
	var sync_static_now := false
	if _static_base_sync_timer <= 0.0:
		sync_static_now = true
		_static_base_sync_timer = STATIC_BASE_SYNC_INTERVAL_SEC
	_ensure_vision_texture()
	_sync_base_viewport()
	_sync_enemy_viewport()
	_sync_dynamic_base_sources()
	_sync_base_clones(sync_static_now)
	_sync_enemy_clones()
	_sync_material_parameters()

func register_enemy_sprite(source: Sprite2D) -> void:
	if source == null or not is_instance_valid(source):
		return
	if _enemy_root == null:
		return
	var source_id := source.get_instance_id()
	if _enemy_entries.has(source_id):
		return

	var clone := Sprite2D.new()
	clone.name = "%sFogClone" % source.name
	_enemy_root.add_child(clone)

	_enemy_entries[source_id] = {
		"source_ref": weakref(source),
		"clone_ref": weakref(clone),
		# Legacy direct refs are kept for compatibility with older live entries.
		"source": source,
		"clone": clone,
		"source_material": source.material,
	}

	_apply_enemy_visibility_material(source)
	_sync_enemy_clone(source, clone)

func unregister_enemy_sprite(source: Sprite2D) -> void:
	if source == null:
		return
	var source_id := source.get_instance_id()
	if not _enemy_entries.has(source_id):
		return

	var entry: Dictionary = _enemy_entries[source_id]
	var clone: Sprite2D = _entry_sprite(entry, "clone_ref", "clone")
	var source_material: Material = entry.get("source_material") as Material
	if is_instance_valid(source):
		source.material = source_material
	if clone != null and is_instance_valid(clone):
		clone.queue_free()
	_enemy_entries.erase(source_id)

func _build_base_viewport() -> void:
	_base_viewport = SubViewport.new()
	_base_viewport.name = "BaseWorldViewport"
	_base_viewport.transparent_bg = true
	_base_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_base_viewport.canvas_cull_mask = 0xFFFFFFFF
	var main_size := get_viewport().get_visible_rect().size
	_base_viewport.size = Vector2i(int(main_size.x), int(main_size.y))

	_base_root = Node2D.new()
	_base_root.name = "BaseWorldRoot"
	_base_viewport.add_child(_base_root)
	add_child(_base_viewport)

func _build_enemy_viewport() -> void:
	_enemy_viewport = SubViewport.new()
	_enemy_viewport.name = "EnemyViewport"
	_enemy_viewport.transparent_bg = true
	_enemy_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_enemy_viewport.canvas_cull_mask = 0xFFFFFFFF
	var main_size := get_viewport().get_visible_rect().size
	_enemy_viewport.size = Vector2i(int(main_size.x), int(main_size.y))

	_enemy_root = Node2D.new()
	_enemy_root.name = "EnemyRoot"
	_enemy_viewport.add_child(_enemy_root)
	add_child(_enemy_viewport)

func _build_overlay() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = FOG_CANVAS_LAYER
	add_child(canvas)

	var fog_shader := load("res://shaders/fog_of_war_v2.gdshader") as Shader
	_overlay_material = ShaderMaterial.new()
	_overlay_material.shader = fog_shader
	_overlay_material.set_shader_parameter("base_world_tex", _base_viewport.get_texture())
	_overlay_material.set_shader_parameter("enemy_tex", _enemy_viewport.get_texture())
	_overlay_material.set_shader_parameter("vision_shape_tex", _vision_shape_texture)

	var rect := ColorRect.new()
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.material = _overlay_material
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(rect)

func _sync_base_viewport() -> void:
	if _base_viewport == null:
		return
	var main_vp := get_viewport()
	var main_size := main_vp.get_visible_rect().size
	var target_size := Vector2i(int(main_size.x), int(main_size.y))
	if _base_viewport.size != target_size:
		_base_viewport.size = target_size
		_static_base_sync_timer = 0.0
	_base_viewport.canvas_transform = main_vp.canvas_transform

func _sync_enemy_viewport() -> void:
	if _enemy_viewport == null:
		return
	var main_vp := get_viewport()
	var main_size := main_vp.get_visible_rect().size
	var target_size := Vector2i(int(main_size.x), int(main_size.y))
	if _enemy_viewport.size != target_size:
		_enemy_viewport.size = target_size
	_enemy_viewport.canvas_transform = main_vp.canvas_transform

func _clone_base_world() -> void:
	if _base_root == null:
		return
	for child in _base_root.get_children():
		child.queue_free()
	_base_bindings.clear()

	var scene_root := _get_level_root()
	if scene_root == null:
		return
	_clone_base_world_recursive(scene_root)
	_sync_base_clones(true)

func _clone_base_world_recursive(node: Node) -> void:
	if _is_overlay_child(node):
		return

	if node is CanvasItem:
		var ci := node as CanvasItem
		_ensure_base_clone(ci)

	for child in node.get_children(true):
		_clone_base_world_recursive(child)

func _should_clone_to_base(ci: CanvasItem) -> bool:
	if not (ci is Node2D):
		return false
	if _is_puddle_helper_shape(ci):
		return false
	if _is_player_pee_node(ci):
		return _is_player_pee_visual(ci)
	if ci is Light2D:
		return false
	if ci is LightOccluder2D:
		return false
	if ci is Camera2D:
		return false
	if ci is CollisionObject2D:
		return false
	if ci is CollisionShape2D:
		return false
	if ci is CollisionPolygon2D:
		return false
	if ci is RayCast2D:
		return false
	if ci is AudioStreamPlayer2D:
		return false
	if _is_enemy_visual(ci):
		return false

	if ci is TileMapLayer:
		return true
	if ci is TileMap:
		return true
	if ci is Sprite2D:
		return true
	if ci is AnimatedSprite2D:
		return true
	if ci is Polygon2D:
		return true
	if ci is Line2D:
		return true
	if ci is MeshInstance2D:
		return true
	if ci is GPUParticles2D:
		return true
	if ci is CPUParticles2D:
		return true
	if ci is Label:
		return true
	if ci is RichTextLabel:
		return true
	if ci is TextureRect:
		return true
	if ci is ColorRect:
		return true
	if ci is NinePatchRect:
		return true

	return false

func _is_puddle_helper_shape(node: Node) -> bool:
	if not (node is Polygon2D):
		return false
	if node.name != "Shape2D":
		return false
	var parent := node.get_parent()
	if parent == null:
		return false
	return parent.has_method("mark_shape_dirty")

func _is_player_pee_node(node: Node) -> bool:
	var n := node
	while n != null:
		if n.is_in_group(PEE_PUDDLE_GROUP):
			return true
		n = n.get_parent()
	return false

func _is_effectively_visible(ci: CanvasItem) -> bool:
	var n: Node = ci
	while n != null:
		if n is CanvasItem:
			var item := n as CanvasItem
			if not item.visible:
				return false
		n = n.get_parent()
	return true

func _is_player_pee_visual(node: Node) -> bool:
	if node is Polygon2D and node.name == "VisualPolygon2D":
		return true
	# Legacy puddle fallback in case a scene still uses ColorRect visuals.
	if node is ColorRect and node.name == "ColorRect":
		return true
	return false

func _is_enemy_visual(node: Node) -> bool:
	var n := node
	while n != null:
		if n.is_in_group(ENEMY_GROUP):
			return true
		n = n.get_parent()
	return false

func _ensure_base_clone(ci: CanvasItem) -> void:
	if _base_root == null:
		return
	if not _should_clone_to_base(ci):
		return
	if _find_base_binding_index(ci) != -1:
		return
	var clone := ci.duplicate() as CanvasItem
	if clone == null:
		return
	_base_root.add_child(clone)
	clone.light_mask = 0
	var is_dynamic := _is_base_source_dynamic(ci)
	_base_bindings.append({
		"source": ci,
		"clone": clone,
		"dynamic": is_dynamic,
	})

func _find_base_binding_index(source: CanvasItem) -> int:
	for i in range(_base_bindings.size()):
		var entry: Dictionary = _base_bindings[i]
		if entry.get("source") == source:
			return i
	return -1

func _sync_dynamic_base_sources() -> void:
	if _base_root == null:
		return
	var tree := get_tree()
	if tree == null:
		return
	var scene_root := _get_level_root()
	if scene_root == null:
		return
	for node in tree.get_nodes_in_group(PEE_PUDDLE_GROUP):
		if not (node is Node):
			continue
		var puddle_node := node as Node
		if puddle_node == null or not is_instance_valid(puddle_node):
			continue
		if not scene_root.is_ancestor_of(puddle_node):
			continue
		_clone_base_world_recursive(puddle_node)

func _is_base_source_dynamic(ci: CanvasItem) -> bool:
	if ci is AnimatedSprite2D:
		return true
	if ci is GPUParticles2D:
		return true
	if ci is CPUParticles2D:
		return true
	if _is_player_pee_node(ci):
		return true
	return false

func _sync_base_clones(sync_static: bool = false) -> void:
	if _base_bindings.is_empty():
		return
	for i in range(_base_bindings.size() - 1, -1, -1):
		var binding: Dictionary = _base_bindings[i]
		var source: CanvasItem = binding.get("source") as CanvasItem
		var clone: CanvasItem = binding.get("clone") as CanvasItem
		if source == null or not is_instance_valid(source) or clone == null or not is_instance_valid(clone):
			if clone != null and is_instance_valid(clone):
				clone.queue_free()
			_base_bindings.remove_at(i)
			continue
		var is_dynamic: bool = binding.get("dynamic", false)
		if not is_dynamic and not sync_static:
			continue

		clone.visible = _is_effectively_visible(source)
		clone.modulate = source.modulate
		clone.self_modulate = source.self_modulate
		clone.z_index = source.z_index
		clone.z_as_relative = source.z_as_relative
		clone.y_sort_enabled = source.y_sort_enabled
		clone.material = source.material
		clone.texture_filter = source.texture_filter
		clone.texture_repeat = source.texture_repeat

		if source is Node2D and clone is Node2D:
			(clone as Node2D).global_transform = (source as Node2D).global_transform

		if source is Sprite2D and clone is Sprite2D:
			var src := source as Sprite2D
			var dst := clone as Sprite2D
			dst.texture = src.texture
			dst.region_enabled = src.region_enabled
			dst.region_rect = src.region_rect
			dst.hframes = src.hframes
			dst.vframes = src.vframes
			dst.frame = src.frame
			dst.frame_coords = src.frame_coords
			dst.centered = src.centered
			dst.offset = src.offset
			dst.flip_h = src.flip_h
			dst.flip_v = src.flip_v

		if source is AnimatedSprite2D and clone is AnimatedSprite2D:
			var src_anim := source as AnimatedSprite2D
			var dst_anim := clone as AnimatedSprite2D
			dst_anim.sprite_frames = src_anim.sprite_frames
			dst_anim.animation = src_anim.animation
			dst_anim.frame = src_anim.frame
			dst_anim.frame_progress = src_anim.frame_progress
			dst_anim.flip_h = src_anim.flip_h
			dst_anim.flip_v = src_anim.flip_v

		if source is Polygon2D and clone is Polygon2D:
			var src_poly := source as Polygon2D
			var dst_poly := clone as Polygon2D
			dst_poly.polygon = src_poly.polygon
			dst_poly.uv = src_poly.uv
			dst_poly.texture = src_poly.texture
			dst_poly.texture_offset = src_poly.texture_offset
			dst_poly.texture_scale = src_poly.texture_scale
			dst_poly.texture_rotation = src_poly.texture_rotation
			dst_poly.color = src_poly.color
			dst_poly.invert_enabled = src_poly.invert_enabled
			dst_poly.invert_border = src_poly.invert_border
			dst_poly.antialiased = src_poly.antialiased

func _register_group_enemies() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group(ENEMY_GROUP):
		if not (node is Node):
			continue
		var enemy_node := node as Node
		var sprite := enemy_node.get_node_or_null("Sprite2D")
		if sprite is Sprite2D:
			register_enemy_sprite(sprite as Sprite2D)

func _sync_enemy_clones() -> void:
	if _enemy_entries.is_empty():
		return
	var ids: Array = _enemy_entries.keys()
	for id_variant in ids:
		var source_id := int(id_variant)
		if not _enemy_entries.has(source_id):
			continue
		var entry: Dictionary = _enemy_entries[source_id]
		var source: Sprite2D = _entry_sprite(entry, "source_ref", "source")
		var clone: Sprite2D = _entry_sprite(entry, "clone_ref", "clone")
		if source == null or clone == null:
			if clone != null and is_instance_valid(clone):
				clone.queue_free()
			_enemy_entries.erase(source_id)
			continue
		_sync_enemy_clone(source, clone)

func _entry_sprite(entry: Dictionary, weak_key: String, legacy_key: String) -> Sprite2D:
	var weak_value: Variant = entry.get(weak_key, null)
	if weak_value is WeakRef:
		var weak_obj: Object = (weak_value as WeakRef).get_ref()
		if weak_obj != null and is_instance_valid(weak_obj) and weak_obj is Sprite2D:
			return weak_obj as Sprite2D

	var legacy_value: Variant = entry.get(legacy_key, null)
	if typeof(legacy_value) != TYPE_OBJECT:
		return null
	if not is_instance_valid(legacy_value):
		return null
	if legacy_value is Sprite2D:
		return legacy_value as Sprite2D
	return null

func _sync_enemy_clone(source: Sprite2D, clone: Sprite2D) -> void:
	clone.global_transform = source.global_transform
	clone.visible = source.visible
	clone.texture = source.texture
	clone.region_enabled = source.region_enabled
	clone.region_rect = source.region_rect
	clone.hframes = source.hframes
	clone.vframes = source.vframes
	clone.frame = source.frame
	clone.frame_coords = source.frame_coords
	clone.centered = source.centered
	clone.offset = source.offset
	clone.flip_h = source.flip_h
	clone.flip_v = source.flip_v
	clone.modulate = source.modulate
	clone.self_modulate = source.self_modulate
	clone.z_index = source.z_index
	clone.z_as_relative = source.z_as_relative
	clone.y_sort_enabled = source.y_sort_enabled

func _apply_enemy_visibility_material(source: Sprite2D) -> void:
	if _enemy_visibility_shader == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = _enemy_visibility_shader
	mat.set_shader_parameter("vision_shape_tex", _vision_shape_texture)
	source.material = mat

func _sync_material_parameters() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var vp_size := vp.get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return

	var min_dim := maxf(minf(vp_size.x, vp_size.y), 1.0)
	var blur_uv := maxf(enemy_blur_radius_px / min_dim, 0.0)
	var reach_px := maxf(vision_radius_px, 1.0)

	var center_uv := Vector2(-10.0, -10.0)
	var rotation_rad := 0.0
	if _player != null and is_instance_valid(_player):
		var screen_pos: Vector2 = vp.canvas_transform * _player.global_position
		center_uv = Vector2(screen_pos.x / vp_size.x, screen_pos.y / vp_size.y)
		center_uv.x = clampf(center_uv.x, -2.0, 2.0)
		center_uv.y = clampf(center_uv.y, -2.0, 2.0)
		var facing_dir := Vector2(0, 1)
		var facing_value: Variant = _player.get("facing_direction_snapped")
		if facing_value is Vector2:
			facing_dir = facing_value as Vector2
		if facing_dir.length_squared() < 0.0001:
			facing_dir = Vector2(0, 1)
		else:
			facing_dir = facing_dir.normalized()
		rotation_rad = Vector2(0, 1).angle_to(facing_dir)

	if _overlay_material != null:
		_apply_common_vision_params(_overlay_material, center_uv, reach_px, rotation_rad, vp_size)
		_overlay_material.set_shader_parameter("enemy_blur_radius_uv", blur_uv)
		_overlay_material.set_shader_parameter("enemy_blur_strength", clampf(enemy_blur_strength, 0.0, 1.0))
		_overlay_material.set_shader_parameter("enemy_tint", enemy_tint)
		_overlay_material.set_shader_parameter("fog_color", fog_color)
		_overlay_material.set_shader_parameter("fog_speed", maxf(fog_speed, 0.0))
		_overlay_material.set_shader_parameter("fog_world_scale", maxf(fog_world_scale, 0.001))
		_overlay_material.set_shader_parameter("fog_noise_strength", clampf(fog_noise_strength, 0.0, 1.0))
		_overlay_material.set_shader_parameter("fog_tint_strength", clampf(fog_tint_strength, 0.0, 1.0))
		_overlay_material.set_shader_parameter("edge_noise_strength", clampf(edge_noise_strength, 0.0, 0.5))
		var inv_canvas: Transform2D = vp.canvas_transform.affine_inverse()
		_overlay_material.set_shader_parameter("world_from_screen_x", inv_canvas.x)
		_overlay_material.set_shader_parameter("world_from_screen_y", inv_canvas.y)
		_overlay_material.set_shader_parameter("world_from_screen_origin", inv_canvas.origin)

	for entry_variant in _enemy_entries.values():
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry := entry_variant as Dictionary
		var source: Sprite2D = _entry_sprite(entry, "source_ref", "source")
		if source == null or not is_instance_valid(source):
			continue
		if source.material is ShaderMaterial:
			var sm := source.material as ShaderMaterial
			if sm.shader == _enemy_visibility_shader:
				_apply_common_vision_params(sm, center_uv, reach_px, rotation_rad, vp_size)

func _apply_common_vision_params(material: ShaderMaterial, center_uv: Vector2, reach_px: float, rotation_rad: float, viewport_size: Vector2) -> void:
	if material == null:
		return
	material.set_shader_parameter("vision_shape_tex", _vision_shape_texture)
	material.set_shader_parameter("vision_center_uv", center_uv)
	material.set_shader_parameter("vision_reach_px", reach_px)
	material.set_shader_parameter("vision_softness_px", maxf(vision_softness_px, 0.0))
	material.set_shader_parameter("ambient_radius_px", maxf(ambient_radius_px, 0.0))
	material.set_shader_parameter("ambient_edge_softness_px", maxf(ambient_edge_softness_px, 0.0))
	material.set_shader_parameter("vision_rotation_rad", rotation_rad)
	material.set_shader_parameter("viewport_size_px", viewport_size)

func _ensure_vision_texture() -> void:
	var key := _vision_texture_params_key()
	if _vision_shape_texture != null and key == _vision_texture_key:
		return
	_vision_shape_texture = _generate_vision_texture()
	_vision_texture_key = key
	if _overlay_material != null:
		_overlay_material.set_shader_parameter("vision_shape_tex", _vision_shape_texture)
	for entry_variant in _enemy_entries.values():
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry := entry_variant as Dictionary
		var source: Sprite2D = _entry_sprite(entry, "source_ref", "source")
		if source == null or not is_instance_valid(source):
			continue
		if source.material is ShaderMaterial:
			var sm := source.material as ShaderMaterial
			if sm.shader == _enemy_visibility_shader:
				sm.set_shader_parameter("vision_shape_tex", _vision_shape_texture)

func _vision_texture_params_key() -> String:
	return "%.3f|%.3f|%.3f|%.3f|%d|%.3f|%.3f" % [
		vision_radius_px,
		ambient_radius_px,
		ambient_softness_power,
		cone_angle_degrees,
		cone_distance_falloff_smoothing_passes,
		cone_distance_falloff_start_ratio,
		cone_angle_falloff_start_ratio,
	]

func _generate_vision_texture() -> ImageTexture:
	var img := Image.create(VISION_TEXTURE_SIZE, VISION_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(VISION_TEXTURE_SIZE / 2.0, VISION_TEXTURE_SIZE / 2.0)
	var tex_radius := VISION_TEXTURE_SIZE * 0.5
	var cone_reach := maxf(vision_radius_px, 1.0)
	var ambient_tex := (ambient_radius_px / cone_reach) * tex_radius
	var cone_tex := tex_radius * 0.95
	var cone_half_angle := deg_to_rad(cone_angle_degrees / 2.0)
	var cone_direction := Vector2(0, 1)

	for y in range(VISION_TEXTURE_SIZE):
		for x in range(VISION_TEXTURE_SIZE):
			var pos := Vector2(x, y) - center
			var dist := pos.length()
			var alpha := 0.0

			if dist < ambient_tex:
				var ambient_falloff := 1.0 - clampf(dist / maxf(ambient_tex, 0.0001), 0.0, 1.0)
				alpha = pow(clampf(ambient_falloff, 0.0, 1.0), maxf(ambient_softness_power, 0.01))

			if dist < cone_tex and dist > 0.01:
				var angle_to_cone := absf(pos.normalized().angle_to(cone_direction))
				if angle_to_cone < cone_half_angle:
					var fade_start := cone_tex * clampf(cone_distance_falloff_start_ratio, 0.0, 0.95)
					var dist_t := _smooth(fade_start, cone_tex, dist)
					for i in range(maxi(cone_distance_falloff_smoothing_passes - 1, 0)):
						dist_t = _smooth(0.0, 1.0, dist_t)
					var dist_falloff := 1.0 - dist_t
					var angle_fade_start := cone_half_angle * clampf(cone_angle_falloff_start_ratio, 0.0, 0.95)
					var angle_falloff := 1.0 - _smooth(angle_fade_start, cone_half_angle, angle_to_cone)
					var cone_alpha := clampf(dist_falloff * angle_falloff, 0.0, 1.0)
					alpha = clampf(alpha + cone_alpha * (1.0 - alpha), 0.0, 1.0)

			alpha = clampf(alpha * maxf(vision_energy, 0.0), 0.0, 1.0)
			img.set_pixel(x, y, Color(alpha, alpha, alpha, alpha))

	return ImageTexture.create_from_image(img)

func _smooth(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / maxf(edge1 - edge0, 0.0001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _find_player() -> CharacterBody2D:
	var scene_root := _get_level_root()
	if scene_root == null:
		return null
	var node := scene_root.find_child("Player", true, false)
	if node is CharacterBody2D:
		return node as CharacterBody2D
	return null

func _get_level_root() -> Node:
	var parent := get_parent()
	if parent != null:
		return parent
	return get_tree().current_scene

func _is_overlay_child(node: Node) -> bool:
	var n := node
	while n != null:
		if n == self:
			return true
		n = n.get_parent()
	return false
