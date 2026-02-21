@tool
extends Area2D

## Slop puddle - slows the player when they walk through it.
## Also alerts nearby SlopCreatures when the player is sloshing around.

@export var slow_factor: float = 0.3
@export var base_radius: float = 18.0
@export_range(0.0, 0.5, 0.01) var shape_variation: float = 0.03
@export_range(0.0, 1.0, 0.01) var corner_rounding: float = 0.35
@export var animation_speed: float = 0.35
@export_range(12, 96, 1) var collision_samples: int = 28
@export var edge_softness: float = 1.6
@export var puddle_color: Color = Color(0.3, 0.38, 0.08, 0.55)
@export var seed: float = 0.0
@export_enum("continuous", "throttled", "on_shape_change") var runtime_update_mode: int = 0
@export_range(1.0, 60.0, 1.0) var runtime_sync_hz: float = 8.0
@export var runtime_sync_collision: bool = true

@export var use_field_renderer: bool = false
@export var use_field_pee_renderer: bool = false
@export_flags_2d_physics var collision_probe_mask: int = 1
@export var field_resolution: Vector2i = Vector2i(144, 144)
@export var field_world_size: Vector2 = Vector2(320.0, 320.0)
@export_range(0.01, 0.95, 0.01) var field_threshold: float = 0.22
@export_range(0.1, 8.0, 0.1) var edge_softness_px: float = 1.8
@export_range(0.0, 20.0, 0.1) var field_diffusion_hz: float = 4.0
@export_range(0, 6, 1) var field_diffusion_passes: int = 1
@export_range(0.0, 1.0, 0.01) var field_diffusion_strength: float = 0.16
@export_range(1.0, 20.0, 1.0) var field_collision_hz: float = 5.0

const PUDDLE_SHADER: Shader = preload("res://shaders/slop_puddle.gdshader")
const MAX_SHADER_POINTS: int = 64
const RUNTIME_MODE_CONTINUOUS := 0
const RUNTIME_MODE_THROTTLED := 1
const RUNTIME_MODE_ON_SHAPE_CHANGE := 2

const FIELD_MIN_SIZE := Vector2(64.0, 64.0)
const FIELD_EXPAND_MARGIN := 20.0
const FIELD_RESIZE_PADDING := 72.0
const FIELD_COLLISION_MIN_AREA := 6.0
const FIELD_DIFFUSION_ACTIVE_WINDOW := 0.30
const FIELD_OBSTACLE_DILATE_PX := 1
const FIELD_OBSTACLE_SAMPLE_STEP := 4
const FIELD_OBSTACLE_QUERY_MAX_RESULTS := 4
const FIELD_MAX_RESOLUTION := 512
const FIELD_COLLISION_MARGIN := 1.2
const FIELD_SAVE_VERSION := 2

@onready var shape_source: Polygon2D = null
@onready var puddle_visual: Polygon2D = get_node_or_null("VisualPolygon2D")
@onready var collision_polygon: CollisionPolygon2D = get_node_or_null("CollisionPolygon2D")
@onready var legacy_color_rect: ColorRect = get_node_or_null("ColorRect")

var _source_points: PackedVector2Array = PackedVector2Array()
var _shape_center: Vector2 = Vector2.ZERO
var _shape_radius: float = 1.0
var _shape_dirty: bool = true
var _visual_dirty: bool = true
var _collision_dirty: bool = true
var _runtime_tick_interval: float = 1.0 / 8.0
var _runtime_tick_timer: float = 0.0
var _local_collision_bounds: Rect2 = Rect2()
var _has_local_collision_bounds: bool = false
var _shader_cache: Dictionary = {}

var _field_image: Image = null
var _field_texture: ImageTexture = null
var _obstacle_mask: Image = null
var _field_world_rect: Rect2 = Rect2()
var _field_dirty_visual: bool = true
var _field_dirty_collision: bool = true
var _field_diffuse_timer: float = 0.0
var _field_collision_timer: float = 0.0
var _field_recent_deposit_timer: float = 0.0
var _last_valid_collision_polygon: PackedVector2Array = PackedVector2Array()

func _ready() -> void:
	# Area/body overlap checks need non-zero collision layers on both sides.
	if collision_layer == 0:
		collision_layer = 1
	if collision_mask == 0:
		collision_mask = 1
	if collision_probe_mask == 0:
		collision_probe_mask = collision_mask
	add_to_group("slop_puddles")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_ensure_nodes()
	_refresh_source_shape(true)
	_apply_shader_material()
	set_runtime_mode(runtime_update_mode, runtime_sync_hz, runtime_sync_collision)
	if use_field_pee_renderer:
		use_field_renderer = true
	if use_field_renderer:
		_ensure_field_initialized(true)
		_field_dirty_visual = true
		_field_dirty_collision = true
	mark_shape_dirty(true)
	set_process(true)

func _process(delta: float) -> void:
	if use_field_pee_renderer and not use_field_renderer:
		use_field_renderer = true
		mark_shape_dirty(true)

	_refresh_source_shape(false)
	if Engine.is_editor_hint():
		if use_field_renderer:
			_sync_field(0.0)
		else:
			_sync_shape(0.0)
		return

	var anim_time := Time.get_ticks_msec() * 0.001 * animation_speed
	if use_field_renderer:
		_process_field(delta, anim_time)
	else:
		_process_legacy(anim_time, delta)

func _process_legacy(anim_time: float, delta: float) -> void:
	match runtime_update_mode:
		RUNTIME_MODE_CONTINUOUS:
			_sync_shape(anim_time)
		RUNTIME_MODE_THROTTLED:
			_runtime_tick_timer -= delta
			if _runtime_tick_timer <= 0.0:
				_sync_shape(anim_time)
				while _runtime_tick_timer <= 0.0:
					_runtime_tick_timer += _runtime_tick_interval
		_:
			if _shape_dirty or _visual_dirty or _collision_dirty:
				_sync_shape(anim_time)

func _process_field(delta: float, anim_time: float) -> void:
	if _field_image == null:
		_ensure_field_initialized(true)

	_field_recent_deposit_timer = maxf(_field_recent_deposit_timer - delta, 0.0)
	if _field_recent_deposit_timer > 0.0 and field_diffusion_hz > 0.0 and field_diffusion_passes > 0:
		_field_diffuse_timer += delta
		var diffuse_interval := 1.0 / field_diffusion_hz
		if _field_diffuse_timer >= diffuse_interval:
			_field_diffuse_timer = fposmod(_field_diffuse_timer, diffuse_interval)
			_diffuse_field()

	var can_refresh_collision := true
	if field_collision_hz > 0.0:
		_field_collision_timer -= delta
		can_refresh_collision = _field_collision_timer <= 0.0
		if can_refresh_collision:
			var collision_interval := 1.0 / field_collision_hz
			while _field_collision_timer <= 0.0:
				_field_collision_timer += collision_interval

	match runtime_update_mode:
		RUNTIME_MODE_CONTINUOUS:
			_sync_field(anim_time, can_refresh_collision)
		RUNTIME_MODE_THROTTLED:
			_runtime_tick_timer -= delta
			if _runtime_tick_timer <= 0.0:
				_sync_field(anim_time, can_refresh_collision)
				while _runtime_tick_timer <= 0.0:
					_runtime_tick_timer += _runtime_tick_interval
		_:
			if _shape_dirty or _field_dirty_visual or _field_dirty_collision:
				_sync_field(anim_time, can_refresh_collision)

func _sync_field(_anim_time: float, allow_collision_refresh: bool = true) -> void:
	if puddle_visual == null or collision_polygon == null or _field_image == null:
		return
	if puddle_visual.material != null:
		puddle_visual.material = null
	puddle_visual.color = puddle_color
	puddle_visual.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	puddle_visual.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED

	var needs_visual := _field_dirty_visual or _visual_dirty or runtime_update_mode != RUNTIME_MODE_ON_SHAPE_CHANGE
	var needs_collision_base := _field_dirty_collision or _collision_dirty or runtime_sync_collision
	var needs_collision := needs_collision_base and allow_collision_refresh
	if not needs_visual and not needs_collision:
		return

	if needs_visual:
		refresh_visual_texture()
		_field_dirty_visual = false
		_visual_dirty = false

	if needs_collision:
		rebuild_collision_from_field()
		_field_dirty_collision = false
		_collision_dirty = false

	_shape_dirty = needs_collision_base and not allow_collision_refresh

func _on_body_entered(body: Node2D) -> void:
	if body.name == "Player":
		if body.has_method("enter_slop"):
			body.enter_slop(slow_factor, self)
		_alert_slop_creatures(body.global_position)

func _on_body_exited(body: Node2D) -> void:
	if body.name == "Player":
		if body.has_method("exit_slop"):
			body.exit_slop(self)

func _alert_slop_creatures(player_pos: Vector2) -> void:
	var creatures = get_tree().get_nodes_in_group("slop_creatures")
	for creature in creatures:
		if creature.has_method("on_slop_disturbed"):
			creature.on_slop_disturbed(player_pos)

func _ensure_nodes() -> void:
	if legacy_color_rect:
		legacy_color_rect.visible = false

	shape_source = _find_shape_source()

	if collision_polygon == null:
		collision_polygon = CollisionPolygon2D.new()
		collision_polygon.name = "CollisionPolygon2D"
		_add_generated_child(collision_polygon)

	var seed_points := PackedVector2Array()
	if collision_polygon.polygon.size() >= 3:
		seed_points = collision_polygon.polygon
	if seed_points.size() < 3:
		seed_points = _build_default_polygon()

	if shape_source == null:
		shape_source = Polygon2D.new()
		shape_source.name = "Shape2D"
		shape_source.color = Color(0.45, 0.8, 0.35, 0.2)
		add_child(shape_source)
	if shape_source.polygon.size() < 3 and not use_field_renderer:
		shape_source.polygon = seed_points

	if puddle_visual == null:
		puddle_visual = Polygon2D.new()
		puddle_visual.name = "VisualPolygon2D"
		_add_generated_child(puddle_visual)

func _find_shape_source() -> Polygon2D:
	var named_shape_2d := get_node_or_null("Shape2D")
	if named_shape_2d is Polygon2D:
		return named_shape_2d as Polygon2D

	var named_shape := get_node_or_null("Shape")
	if named_shape is Polygon2D:
		return named_shape as Polygon2D

	for child in get_children():
		if not (child is Polygon2D):
			continue
		var polygon_child := child as Polygon2D
		if polygon_child.name == "VisualPolygon2D":
			continue
		return polygon_child
	return null

func _add_generated_child(node: Node) -> void:
	# Keep generated helpers out of the authored scene hierarchy.
	add_child(node, false, Node.INTERNAL_MODE_BACK)

func _apply_shader_material() -> void:
	var shader_material := puddle_visual.material as ShaderMaterial
	if shader_material == null:
		shader_material = ShaderMaterial.new()
	if shader_material.shader != PUDDLE_SHADER:
		shader_material.shader = PUDDLE_SHADER
	puddle_visual.material = shader_material
	puddle_visual.color = Color.WHITE
	_shader_cache.clear()

func _refresh_source_shape(force: bool) -> void:
	if shape_source == null:
		return

	if shape_source.polygon.size() < 3 and not use_field_renderer:
		shape_source.polygon = _build_default_polygon()

	var transformed_points: PackedVector2Array = _get_transformed_source_points()
	if force or _source_points != transformed_points:
		_source_points = transformed_points
		_recompute_shape_metrics()
		if use_field_renderer and force and shape_source.polygon.size() >= 3:
			_rebuild_field_from_shape_source()
		mark_shape_dirty(false)

	shape_source.visible = Engine.is_editor_hint()

func _get_transformed_source_points() -> PackedVector2Array:
	var transformed: PackedVector2Array = PackedVector2Array()
	if shape_source == null:
		return transformed
	var raw_points: PackedVector2Array = shape_source.polygon
	if raw_points.size() < 3:
		return transformed

	transformed.resize(raw_points.size())
	var shape_transform: Transform2D = shape_source.transform
	for i: int in raw_points.size():
		transformed[i] = shape_transform * raw_points[i]
	return transformed

func _recompute_shape_metrics() -> void:
	if _source_points.size() < 3:
		_shape_center = Vector2.ZERO
		_shape_radius = max(base_radius, 1.0)
		return

	var center := Vector2.ZERO
	for point in _source_points:
		center += point
	center /= float(_source_points.size())
	_shape_center = center

	var radius := 1.0
	for point in _source_points:
		radius = max(radius, point.distance_to(_shape_center))
	_shape_radius = radius

func set_runtime_mode(mode: int, hz: float = 8.0, sync_collision: bool = true) -> void:
	runtime_update_mode = clampi(mode, RUNTIME_MODE_CONTINUOUS, RUNTIME_MODE_ON_SHAPE_CHANGE)
	runtime_sync_hz = clampf(hz, 1.0, 60.0)
	runtime_sync_collision = sync_collision
	_runtime_tick_interval = 1.0 / runtime_sync_hz
	_runtime_tick_timer = _runtime_tick_interval * _runtime_phase_from_seed()
	if field_collision_hz > 0.0:
		_field_collision_timer = (1.0 / field_collision_hz) * _runtime_phase_from_seed()
	else:
		_field_collision_timer = 0.0
	mark_shape_dirty(false)

func mark_shape_dirty(force: bool = false) -> void:
	_shape_dirty = true
	_visual_dirty = true
	_collision_dirty = true
	_field_dirty_visual = true
	_field_dirty_collision = true
	if force:
		var anim_time := 0.0 if Engine.is_editor_hint() else Time.get_ticks_msec() * 0.001 * animation_speed
		if use_field_renderer:
			_sync_field(anim_time)
		else:
			_sync_shape(anim_time)

func _sync_shape(anim_time: float) -> void:
	if use_field_renderer:
		_sync_field(anim_time)
		return
	var shader_material := puddle_visual.material as ShaderMaterial
	if shader_material == null or shader_material.shader != PUDDLE_SHADER:
		_apply_shader_material()
	if puddle_visual == null or collision_polygon == null or _source_points.size() < 3:
		return

	var needs_visual := _visual_dirty or runtime_update_mode != RUNTIME_MODE_ON_SHAPE_CHANGE
	var needs_collision := _collision_dirty or runtime_sync_collision
	if not needs_visual and not needs_collision:
		return

	var deformed_points := _build_deformed_polygon(anim_time)
	if needs_collision:
		collision_polygon.polygon = deformed_points
		_cache_collision_bounds(deformed_points)
		_collision_dirty = false

	if needs_visual:
		var visual_points := _build_visual_polygon(deformed_points)
		puddle_visual.polygon = visual_points
		puddle_visual.texture = null
		_sync_shader_parameters_legacy(visual_points)
		_visual_dirty = false

	_shape_dirty = false

func _sync_shader_parameters_legacy(visual_points: PackedVector2Array) -> void:
	var shader_material := puddle_visual.material as ShaderMaterial
	if shader_material == null:
		return

	var shader_points: PackedVector2Array = _points_for_shader(visual_points, MAX_SHADER_POINTS)
	_set_shader_parameter_if_changed(shader_material, &"use_field_tex", 0.0)
	_set_shader_parameter_if_changed(shader_material, &"animation_speed", animation_speed)
	_set_shader_parameter_if_changed(shader_material, &"edge_softness", edge_softness)
	_set_shader_parameter_if_changed(shader_material, &"puddle_color", puddle_color)
	_set_shader_parameter_if_changed(shader_material, &"seed", seed)
	_set_shader_parameter_if_changed(shader_material, &"shape_center", _shape_center)
	_set_shader_parameter_if_changed(shader_material, &"shape_radius", _shape_radius)
	_set_shader_parameter_if_changed(shader_material, &"shape_point_count", shader_points.size())
	_set_shader_parameter_if_changed(shader_material, &"shape_points", shader_points)

func _sync_shader_parameters_field() -> void:
	var shader_material := puddle_visual.material as ShaderMaterial
	if shader_material == null:
		return
	var field_center_world := _field_world_rect.position + _field_world_rect.size * 0.5
	var field_center_local := to_local(field_center_world)
	var field_radius := maxf(_field_world_rect.size.x, _field_world_rect.size.y) * 0.5
	_set_shader_parameter_if_changed(shader_material, &"use_field_tex", 1.0)
	_set_shader_parameter_if_changed(shader_material, &"animation_speed", animation_speed)
	_set_shader_parameter_if_changed(shader_material, &"puddle_color", puddle_color)
	_set_shader_parameter_if_changed(shader_material, &"seed", seed)
	_set_shader_parameter_if_changed(shader_material, &"shape_center", field_center_local)
	_set_shader_parameter_if_changed(shader_material, &"shape_radius", field_radius)
	_set_shader_parameter_if_changed(shader_material, &"field_threshold", field_threshold)
	_set_shader_parameter_if_changed(shader_material, &"edge_softness_px", edge_softness_px)
	_set_shader_parameter_if_changed(shader_material, &"shape_point_count", 0)
	if _field_texture != null:
		_set_shader_parameter_if_changed(shader_material, &"field_tex", _field_texture)

func _set_shader_parameter_if_changed(material: ShaderMaterial, key: StringName, value: Variant) -> void:
	var cache_key := String(key)
	if _shader_cache.has(cache_key) and _shader_cache[cache_key] == value:
		return
	_shader_cache[cache_key] = value
	material.set_shader_parameter(key, value)

func _cache_collision_bounds(points: PackedVector2Array) -> void:
	if points.size() < 3:
		_has_local_collision_bounds = false
		return

	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y
	for point in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_y = minf(min_y, point.y)
		max_y = maxf(max_y, point.y)

	_local_collision_bounds = Rect2(
		Vector2(min_x, min_y),
		Vector2(max_x - min_x, max_y - min_y)
	)
	_has_local_collision_bounds = true

func _runtime_phase_from_seed() -> float:
	var phase := fposmod(absf(seed) * 1.6180339, 1.0)
	if phase <= 0.0:
		phase = randf()
	return phase

func _build_visual_polygon(points: PackedVector2Array) -> PackedVector2Array:
	if corner_rounding <= 0.001 or points.size() < 4:
		return points

	var rounded: PackedVector2Array = points
	# Increase point density until corners render as smooth arcs (not octagon/chamfer look).
	var target_points: int = int(lerpf(8.0, float(MAX_SHADER_POINTS), clampf(corner_rounding, 0.0, 1.0)))
	target_points = clampi(target_points, 8, MAX_SHADER_POINTS)
	var cut: float = lerpf(0.10, 0.20, clampf(corner_rounding, 0.0, 1.0))
	while rounded.size() < target_points:
		if rounded.size() * 2 > MAX_SHADER_POINTS:
			break
		rounded = _chaikin_closed(rounded, cut)
	return rounded

func _chaikin_closed(points: PackedVector2Array, cut: float) -> PackedVector2Array:
	var count: int = points.size()
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(count * 2)
	for i: int in count:
		var p0: Vector2 = points[i]
		var p1: Vector2 = points[(i + 1) % count]
		out[i * 2] = p0.lerp(p1, cut)
		out[i * 2 + 1] = p0.lerp(p1, 1.0 - cut)
	return out

func _points_for_shader(points: PackedVector2Array, max_points: int) -> PackedVector2Array:
	if points.size() <= max_points:
		return points

	var reduced: PackedVector2Array = PackedVector2Array()
	reduced.resize(max_points)
	var step: float = float(points.size()) / float(max_points)
	var cursor: float = 0.0
	for i: int in max_points:
		var idx: int = mini(int(floor(cursor)), points.size() - 1)
		reduced[i] = points[idx]
		cursor += step
	return reduced

func _build_default_polygon() -> PackedVector2Array:
	var samples: int = maxi(collision_samples, 12)
	var points: PackedVector2Array = PackedVector2Array()
	points.resize(samples)
	for i: int in samples:
		var angle: float = float(i) * TAU / float(samples)
		points[i] = Vector2(cos(angle), sin(angle)) * base_radius
	return points

func _build_deformed_polygon(anim_time: float) -> PackedVector2Array:
	var points: PackedVector2Array = PackedVector2Array()
	points.resize(_source_points.size())
	for i: int in _source_points.size():
		var base_point: Vector2 = _source_points[i]
		var centered: Vector2 = base_point - _shape_center
		var base_distance: float = maxf(centered.length(), 0.001)
		var dir: Vector2 = centered / base_distance
		var angle: float = atan2(dir.y, dir.x)

		var noise: float = sin(angle * 3.0 + anim_time * 1.8 + seed) * 0.6
		noise += cos(angle * 5.0 - anim_time * 1.2 + seed * 1.7) * 0.4

		var scale: float = clampf(1.0 + shape_variation * noise, 0.25, 2.0)
		points[i] = _shape_center + dir * base_distance * scale
	return points

func deposit_splat(world_pos: Vector2, radius: float, strength: float, prefer_expand: bool = false) -> void:
	if not use_field_renderer:
		use_field_renderer = true
		use_field_pee_renderer = true
		mark_shape_dirty(true)
	_ensure_field_initialized(false)

	var deposit_radius := maxf(radius, 1.0)
	var deposit_strength := clampf(strength, 0.02, 1.0)
	_ensure_field_covers(world_pos, deposit_radius + FIELD_EXPAND_MARGIN)
	var center_density := _sample_field_value_at_world(_field_image, _field_world_rect, world_pos)
	var effective_radius := deposit_radius
	var effective_strength := deposit_strength
	if center_density >= field_threshold:
		var radius_scale := 1.18
		var strength_scale := 0.90
		if prefer_expand:
			radius_scale = 1.36
			strength_scale = 0.98
		effective_radius = deposit_radius * radius_scale
		effective_strength = deposit_strength * strength_scale
		if prefer_expand:
			var edge_probe := _nearest_puddle_edge_probe(world_pos, deposit_radius * 6.0)
			if bool(edge_probe.get("found", false)):
				var edge_dist := float(edge_probe.get("distance", 0.0))
				var edge_dir := edge_probe.get("direction", Vector2.RIGHT) as Vector2
				effective_radius = maxf(effective_radius, deposit_radius * 1.55)
				effective_strength = maxf(effective_strength, deposit_strength * 0.92)
				var boundary_world := world_pos + edge_dir * edge_dist
				var outward_world := boundary_world + edge_dir * maxf(deposit_radius * 0.95, 1.8)
				var constrained_target := _constrain_segment_to_colliders(boundary_world, outward_world)
				_apply_splat_to_field(constrained_target, deposit_radius * 0.92, deposit_strength * 0.72)
	_apply_splat_to_field(world_pos, effective_radius, effective_strength)
	_field_recent_deposit_timer = FIELD_DIFFUSION_ACTIVE_WINDOW
	_field_dirty_visual = true
	_field_dirty_collision = true
	_shape_dirty = true

func refresh_visual_texture() -> void:
	if _field_image == null or puddle_visual == null:
		return

	var width := _field_image.get_width()
	var height := _field_image.get_height()
	var visual := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var lo := maxf(field_threshold - 0.08, 0.0)
	var hi := minf(field_threshold + 0.08, 1.0)
	for y: int in height:
		for x: int in width:
			var v := _field_image.get_pixel(x, y).r
			var alpha := smoothstep(lo, hi, v)
			visual.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))

	if _field_texture == null:
		_field_texture = ImageTexture.create_from_image(visual)
	else:
		if _field_texture.get_size() == Vector2(float(width), float(height)):
			_field_texture.update(visual)
		else:
			_field_texture.set_image(visual)

	puddle_visual.texture = _field_texture
	puddle_visual.polygon = _field_rect_polygon_local()
	var tex_w := float(maxi(_field_image.get_width(), 1))
	var tex_h := float(maxi(_field_image.get_height(), 1))
	puddle_visual.uv = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(tex_w, 0.0),
		Vector2(tex_w, tex_h),
		Vector2(0.0, tex_h)
	])

func rebuild_collision_from_field() -> void:
	if _field_image == null or collision_polygon == null:
		return
	var candidate := _largest_polygon_from_field()
	if candidate.size() >= 3 and _is_polygon_valid(candidate):
		collision_polygon.polygon = candidate
		_last_valid_collision_polygon = candidate
		_cache_collision_bounds(candidate)
		if shape_source != null:
			shape_source.position = Vector2.ZERO
			shape_source.rotation = 0.0
			shape_source.scale = Vector2.ONE
			shape_source.polygon = candidate
		return
	if _last_valid_collision_polygon.size() >= 3 and _is_polygon_valid(_last_valid_collision_polygon):
		collision_polygon.polygon = _last_valid_collision_polygon
		_cache_collision_bounds(_last_valid_collision_polygon)

func merge_from_puddle(other: Area2D) -> bool:
	if other == null or not is_instance_valid(other) or other == self:
		return false
	if not use_field_renderer:
		return false
	if not other.has_method("extract_field_snapshot") and not other.has_method("extract_field_snapshot_shared"):
		return false

	var payload: Variant = {}
	if other.has_method("extract_field_snapshot_shared"):
		payload = other.call("extract_field_snapshot_shared")
	else:
		payload = other.call("extract_field_snapshot")
	if typeof(payload) != TYPE_DICTIONARY:
		return false
	var data := payload as Dictionary
	if data.is_empty():
		return false
	if not data.has("image") or not data.has("rect"):
		return false

	var src_image := data["image"] as Image
	if src_image == null:
		return false
	var rect_variant: Variant = data["rect"]
	if typeof(rect_variant) != TYPE_RECT2:
		return false
	var src_rect: Rect2 = rect_variant
	if src_rect.size.x <= 0.0 or src_rect.size.y <= 0.0:
		return false

	_ensure_field_initialized(false)
	_ensure_field_covers_rect(src_rect.grow(FIELD_EXPAND_MARGIN))
	_blit_field_image(src_image, src_rect)
	_field_dirty_visual = true
	_field_dirty_collision = true
	_shape_dirty = true
	return true

func extract_field_snapshot() -> Dictionary:
	if not use_field_renderer or _field_image == null:
		return {}
	return {
		"image": _field_image.duplicate(),
		"rect": _field_world_rect
	}

func extract_field_snapshot_shared() -> Dictionary:
	if not use_field_renderer or _field_image == null:
		return {}
	return {
		"image": _field_image,
		"rect": _field_world_rect
	}

func export_field_save_payload() -> Dictionary:
	if not use_field_renderer or _field_image == null:
		return {}
	var save_image := _field_image
	if save_image.get_format() != Image.FORMAT_RGBA8:
		save_image = save_image.duplicate()
		save_image.convert(Image.FORMAT_RGBA8)
	return {
		"version": FIELD_SAVE_VERSION,
		"rect": _field_world_rect,
		"width": save_image.get_width(),
		"height": save_image.get_height(),
		"format": int(save_image.get_format()),
		"data": save_image.get_data()
	}

func restore_field_save_payload(payload: Dictionary) -> bool:
	if payload.is_empty():
		return false
	var payload_version := int(payload.get("version", 0))
	if payload_version != FIELD_SAVE_VERSION:
		return false
	if typeof(payload.get("rect", null)) != TYPE_RECT2:
		return false
	var world_rect: Rect2 = payload["rect"]
	var width := int(payload.get("width", 0))
	var height := int(payload.get("height", 0))
	var format := int(payload.get("format", int(Image.FORMAT_RGBA8)))
	var data_variant: Variant = payload.get("data", PackedByteArray())
	if not (data_variant is PackedByteArray):
		return false
	var data := data_variant as PackedByteArray
	if width <= 0 or height <= 0 or data.is_empty():
		return false
	var expected_bytes := width * height * 4
	if format == int(Image.FORMAT_R8):
		expected_bytes = width * height
	if data.size() < expected_bytes:
		return false
	var image := Image.create_from_data(width, height, false, format, data)
	if image == null:
		return false
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return restore_field_snapshot(image, world_rect)

func restore_field_snapshot(image: Image, world_rect: Rect2) -> bool:
	if image == null:
		return false
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return false
	use_field_renderer = true
	use_field_pee_renderer = true
	_field_world_rect = world_rect
	field_world_size = world_rect.size
	field_resolution = Vector2i(
		clampi(image.get_width(), 32, FIELD_MAX_RESOLUTION),
		clampi(image.get_height(), 32, FIELD_MAX_RESOLUTION)
	)
	_field_image = image.duplicate()
	if _field_texture == null:
		_field_texture = ImageTexture.create_from_image(_field_image)
	else:
		if _field_texture.get_size() == Vector2(float(_field_image.get_width()), float(_field_image.get_height())):
			_field_texture.update(_field_image)
		else:
			_field_texture.set_image(_field_image)
	_rebuild_obstacle_mask()
	_field_dirty_visual = true
	_field_dirty_collision = true
	_shape_dirty = true
	refresh_visual_texture()
	rebuild_collision_from_field()
	_field_dirty_visual = false
	_field_dirty_collision = false
	_shape_dirty = false
	return true

func get_field_world_rect() -> Rect2:
	return _field_world_rect

func reset_field() -> void:
	use_field_renderer = true
	use_field_pee_renderer = true
	_ensure_field_initialized(true)
	if _field_image != null:
		_field_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	if shape_source != null:
		shape_source.polygon = PackedVector2Array()
	_field_dirty_visual = true
	_field_dirty_collision = true
	_last_valid_collision_polygon = PackedVector2Array()
	collision_polygon.polygon = PackedVector2Array()
	_has_local_collision_bounds = false
	mark_shape_dirty(true)

func _ensure_field_initialized(force_rebuild: bool) -> void:
	if not force_rebuild and _field_image != null:
		return
	var target_res := _sanitized_field_resolution()
	field_world_size = Vector2(
		maxf(field_world_size.x, FIELD_MIN_SIZE.x),
		maxf(field_world_size.y, FIELD_MIN_SIZE.y)
	)
	_field_world_rect = Rect2(global_position - field_world_size * 0.5, field_world_size)
	_field_image = Image.create(target_res.x, target_res.y, false, Image.FORMAT_RGBA8)
	_field_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_field_texture = ImageTexture.create_from_image(_field_image)
	_rebuild_obstacle_mask()

func _sanitized_field_resolution() -> Vector2i:
	return Vector2i(maxi(field_resolution.x, 32), maxi(field_resolution.y, 32))

func _ensure_field_covers(world_pos: Vector2, margin: float) -> void:
	var required := Rect2(world_pos - Vector2.ONE * margin, Vector2.ONE * margin * 2.0)
	_ensure_field_covers_rect(required)

func _ensure_field_covers_rect(required_world_rect: Rect2) -> void:
	if _field_image == null:
		_ensure_field_initialized(true)
	if _field_world_rect.encloses(required_world_rect):
		return
	var expanded_required := required_world_rect.grow(FIELD_RESIZE_PADDING)
	var merged := _field_world_rect.merge(expanded_required)
	if merged == _field_world_rect:
		return
	_resize_field_world_rect(merged)

func _resize_field_world_rect(new_world_rect: Rect2) -> void:
	var target_res := _target_resolution_for_world_rect(new_world_rect)
	var new_image := Image.create(target_res.x, target_res.y, false, Image.FORMAT_RGBA8)
	new_image.fill(Color(0.0, 0.0, 0.0, 0.0))

	if _field_image != null and _field_world_rect.size.x > 0.0 and _field_world_rect.size.y > 0.0:
		var old_rect := _field_world_rect
		var old_res := Vector2i(_field_image.get_width(), _field_image.get_height())
		for y: int in old_res.y:
			for x: int in old_res.x:
				var value := _field_image.get_pixel(x, y).r
				if value <= 0.001:
					continue
				var world := _field_cell_world(old_rect, old_res, x, y)
				var dst := _world_to_field_for_rect(world, new_world_rect, target_res)
				var px := clampi(int(round(dst.x)), 0, target_res.x - 1)
				var py := clampi(int(round(dst.y)), 0, target_res.y - 1)
				_set_image_alpha_max(new_image, px, py, value)
				if px + 1 < target_res.x:
					_set_image_alpha_max(new_image, px + 1, py, value * 0.92)
				if py + 1 < target_res.y:
					_set_image_alpha_max(new_image, px, py + 1, value * 0.92)

	_field_world_rect = new_world_rect
	_field_image = new_image
	if _field_texture == null:
		_field_texture = ImageTexture.create_from_image(_field_image)
	else:
		if _field_texture.get_size() == Vector2(float(_field_image.get_width()), float(_field_image.get_height())):
			_field_texture.update(_field_image)
		else:
			_field_texture.set_image(_field_image)
	_rebuild_obstacle_mask()

func _target_resolution_for_world_rect(world_rect: Rect2) -> Vector2i:
	if _field_image == null or _field_world_rect.size.x <= 0.0 or _field_world_rect.size.y <= 0.0:
		return _sanitized_field_resolution()
	var ppu_x := float(_field_image.get_width()) / maxf(_field_world_rect.size.x, 1.0)
	var ppu_y := float(_field_image.get_height()) / maxf(_field_world_rect.size.y, 1.0)
	var target_x := int(ceil(world_rect.size.x * ppu_x))
	var target_y := int(ceil(world_rect.size.y * ppu_y))
	return Vector2i(
		clampi(target_x, 32, FIELD_MAX_RESOLUTION),
		clampi(target_y, 32, FIELD_MAX_RESOLUTION)
	)

func _field_cell_world(world_rect: Rect2, res: Vector2i, x: int, y: int) -> Vector2:
	var uv := Vector2(
		(float(x) + 0.5) / float(maxi(res.x, 1)),
		(float(y) + 0.5) / float(maxi(res.y, 1))
	)
	return world_rect.position + world_rect.size * uv

func _world_to_field(world_pos: Vector2) -> Vector2:
	if _field_world_rect.size.x <= 0.0 or _field_world_rect.size.y <= 0.0:
		return Vector2.ZERO
	var uv := (world_pos - _field_world_rect.position) / _field_world_rect.size
	var max_x := float(maxi(_field_image.get_width() - 1, 0))
	var max_y := float(maxi(_field_image.get_height() - 1, 0))
	return Vector2(uv.x * max_x, uv.y * max_y)

func _field_to_world(field_pos: Vector2) -> Vector2:
	var width := float(maxi(_field_image.get_width() - 1, 1))
	var height := float(maxi(_field_image.get_height() - 1, 1))
	var uv := Vector2(field_pos.x / width, field_pos.y / height)
	return _field_world_rect.position + _field_world_rect.size * uv

func _world_to_field_for_rect(world_pos: Vector2, world_rect: Rect2, res: Vector2i) -> Vector2:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return Vector2.ZERO
	var uv := (world_pos - world_rect.position) / world_rect.size
	var max_x := float(maxi(res.x - 1, 0))
	var max_y := float(maxi(res.y - 1, 0))
	return Vector2(uv.x * max_x, uv.y * max_y)

func _apply_splat_to_field(world_pos: Vector2, radius: float, strength: float) -> void:
	if _field_image == null:
		return
	var center := _world_to_field(world_pos)
	var px_per_world_x := float(_field_image.get_width()) / maxf(_field_world_rect.size.x, 1.0)
	var px_per_world_y := float(_field_image.get_height()) / maxf(_field_world_rect.size.y, 1.0)
	var radius_px := maxf(radius * (px_per_world_x + px_per_world_y) * 0.5, 1.0)
	_apply_splat_px(center, radius_px, strength)

func _apply_splat_px(center: Vector2, radius_px: float, strength: float) -> void:
	if _field_image == null:
		return
	var r_sq := radius_px * radius_px

	var min_x := maxi(int(floor(center.x - radius_px - 1.0)), 0)
	var max_x := mini(int(ceil(center.x + radius_px + 1.0)), _field_image.get_width() - 1)
	var min_y := maxi(int(floor(center.y - radius_px - 1.0)), 0)
	var max_y := mini(int(ceil(center.y + radius_px + 1.0)), _field_image.get_height() - 1)

	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			if _is_obstacle_cell(x, y):
				continue
			var dx := float(x) - center.x
			var dy := float(y) - center.y
			var dist_sq := dx * dx + dy * dy
			if dist_sq > r_sq:
				continue
			var falloff := 1.0 - sqrt(dist_sq) / maxf(radius_px, 0.001)
			falloff = clampf(falloff, 0.0, 1.0)
			var previous := _field_image.get_pixel(x, y).r
			var next := clampf(previous + strength * falloff * 0.32, 0.0, 1.0)
			_field_image.set_pixel(x, y, Color(next, next, next, next))

func _is_obstacle_cell(x: int, y: int) -> bool:
	if _obstacle_mask == null:
		return false
	if x < 0 or y < 0 or x >= _obstacle_mask.get_width() or y >= _obstacle_mask.get_height():
		return false
	return _obstacle_mask.get_pixel(x, y).r > 0.5

func _diffuse_field() -> void:
	if _field_image == null:
		return
	if field_diffusion_strength <= 0.0:
		return
	var width := _field_image.get_width()
	var height := _field_image.get_height()
	if width < 3 or height < 3:
		return

	for _pass_idx: int in field_diffusion_passes:
		var source := _field_image.duplicate()
		for y: int in range(1, height - 1):
			for x: int in range(1, width - 1):
				if _is_obstacle_cell(x, y):
					continue
				var center: float = source.get_pixel(x, y).r
				var neighbors: float = source.get_pixel(x - 1, y).r
				neighbors += source.get_pixel(x + 1, y).r
				neighbors += source.get_pixel(x, y - 1).r
				neighbors += source.get_pixel(x, y + 1).r
				var avg: float = neighbors * 0.25
				# Non-eroding smoothing: spread into nearby empty cells but never
				# reduce already deposited density (prevents old puddles fading out).
				var mixed: float = maxf(center, lerpf(center, avg, field_diffusion_strength))
				var mixed_clamped: float = clampf(mixed, 0.0, 1.0)
				_field_image.set_pixel(x, y, Color(mixed_clamped, mixed_clamped, mixed_clamped, mixed_clamped))
	_field_dirty_visual = true
	_field_dirty_collision = true
	_shape_dirty = true

func _largest_polygon_from_field() -> PackedVector2Array:
	var bitmap := BitMap.new()
	var alpha_image := Image.create(_field_image.get_width(), _field_image.get_height(), false, Image.FORMAT_RGBA8)
	for y: int in _field_image.get_height():
		for x: int in _field_image.get_width():
			var v := _field_image.get_pixel(x, y).r
			alpha_image.set_pixel(x, y, Color(1.0, 1.0, 1.0, v))
	bitmap.create_from_image_alpha(alpha_image, field_threshold)

	var contours: Array = bitmap.opaque_to_polygons(Rect2i(0, 0, _field_image.get_width(), _field_image.get_height()), 1.5)
	if contours.is_empty():
		return PackedVector2Array()

	var best := PackedVector2Array()
	var best_area := 0.0
	for contour_variant in contours:
		if not (contour_variant is PackedVector2Array):
			continue
		var contour := contour_variant as PackedVector2Array
		if contour.size() < 3:
			continue
		var poly := _bitmap_polygon_to_local(contour)
		var area := absf(_polygon_signed_area(poly))
		if area > best_area:
			best_area = area
			best = poly
	return best

func _bitmap_polygon_to_local(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(points.size())
	for i: int in points.size():
		var px := points[i]
		var world := Vector2(
			_field_world_rect.position.x + ((px.x + 0.5) / float(maxi(_field_image.get_width(), 1))) * _field_world_rect.size.x,
			_field_world_rect.position.y + ((px.y + 0.5) / float(maxi(_field_image.get_height(), 1))) * _field_world_rect.size.y
		)
		out[i] = to_local(world)
	return out

func _is_polygon_valid(poly: PackedVector2Array) -> bool:
	if poly.size() < 3:
		return false
	if absf(_polygon_signed_area(poly)) <= FIELD_COLLISION_MIN_AREA:
		return false
	var tris: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
	return tris.size() >= 3

func _polygon_signed_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i: int in poly.size():
		var p0 := poly[i]
		var p1 := poly[(i + 1) % poly.size()]
		area += p0.x * p1.y - p1.x * p0.y
	return area * 0.5

func _field_rect_polygon_local() -> PackedVector2Array:
	var tl := to_local(_field_world_rect.position)
	var tr := to_local(Vector2(_field_world_rect.end.x, _field_world_rect.position.y))
	var br := to_local(_field_world_rect.end)
	var bl := to_local(Vector2(_field_world_rect.position.x, _field_world_rect.end.y))
	return PackedVector2Array([tl, tr, br, bl])

func _sample_field_value_at_world(image: Image, world_rect: Rect2, world_pos: Vector2) -> float:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return 0.0
	var uv := (world_pos - world_rect.position) / world_rect.size
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return 0.0
	var x := clampi(int(round(uv.x * float(maxi(image.get_width() - 1, 0)))), 0, image.get_width() - 1)
	var y := clampi(int(round(uv.y * float(maxi(image.get_height() - 1, 0)))), 0, image.get_height() - 1)
	return image.get_pixel(x, y).r

func _nearest_puddle_edge_probe(world_pos: Vector2, max_search_dist: float) -> Dictionary:
	if _field_image == null:
		return {"found": false}
	var sample_count := 16
	var step := maxf(max_search_dist / 22.0, 1.25)
	var best := INF
	var best_dir := Vector2.RIGHT
	for i: int in sample_count:
		var angle := (float(i) / float(sample_count)) * TAU
		var dir := Vector2.from_angle(angle)
		var steps := int(ceil(max_search_dist / step))
		for s in range(1, steps + 1):
			var dist := float(s) * step
			var sample_world := world_pos + dir * dist
			var v := _sample_field_value_at_world(_field_image, _field_world_rect, sample_world)
			if v < field_threshold:
				if dist < best:
					best = dist
					best_dir = dir
				break
	if best == INF:
		return {"found": false}
	return {
		"found": true,
		"distance": best,
		"direction": best_dir
	}

func _set_image_alpha_max(image: Image, x: int, y: int, value: float) -> void:
	var current := image.get_pixel(x, y).r
	var next := maxf(current, clampf(value, 0.0, 1.0))
	if next <= current:
		return
	image.set_pixel(x, y, Color(next, next, next, next))

func _constrain_segment_to_colliders(origin_world: Vector2, target_world: Vector2) -> Vector2:
	var segment := target_world - origin_world
	var distance := segment.length()
	if distance <= 0.001:
		return target_world
	var hit := _raycast_world(origin_world, target_world)
	if hit.is_empty():
		return target_world
	var hit_position: Vector2 = hit["position"]
	var safe_distance := maxf(origin_world.distance_to(hit_position) - FIELD_COLLISION_MARGIN, 0.0)
	return origin_world + segment.normalized() * safe_distance

func _raycast_world(from_world: Vector2, to_world: Vector2) -> Dictionary:
	if not is_inside_tree():
		return {}
	var world := get_world_2d()
	if world == null:
		return {}
	var query := PhysicsRayQueryParameters2D.create(from_world, to_world)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	var mask := collision_probe_mask
	if mask == 0:
		mask = collision_mask
	query.collision_mask = mask
	return world.direct_space_state.intersect_ray(query)

func _blit_field_image(src_image: Image, src_rect: Rect2) -> void:
	if _field_image == null or src_image == null:
		return
	var overlap_world := _field_world_rect.intersection(src_rect)
	if overlap_world.size.x <= 0.0 or overlap_world.size.y <= 0.0:
		return
	var src_w := src_image.get_width()
	var src_h := src_image.get_height()
	var src_min_uv := (overlap_world.position - src_rect.position) / src_rect.size
	var src_max_uv := (overlap_world.end - src_rect.position) / src_rect.size
	var min_x := clampi(int(floor(src_min_uv.x * float(maxi(src_w - 1, 0)))) - 1, 0, src_w - 1)
	var max_x := clampi(int(ceil(src_max_uv.x * float(maxi(src_w - 1, 0)))) + 1, 0, src_w - 1)
	var min_y := clampi(int(floor(src_min_uv.y * float(maxi(src_h - 1, 0)))) - 1, 0, src_h - 1)
	var max_y := clampi(int(ceil(src_max_uv.y * float(maxi(src_h - 1, 0)))) + 1, 0, src_h - 1)

	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			var value := src_image.get_pixel(x, y).r
			if value <= 0.001:
				continue
			var world := Vector2(
				src_rect.position.x + ((float(x) + 0.5) / float(maxi(src_w, 1))) * src_rect.size.x,
				src_rect.position.y + ((float(y) + 0.5) / float(maxi(src_h, 1))) * src_rect.size.y
			)
			var dst := _world_to_field(world)
			var px := clampi(int(round(dst.x)), 0, _field_image.get_width() - 1)
			var py := clampi(int(round(dst.y)), 0, _field_image.get_height() - 1)
			if _is_obstacle_cell(px, py):
				continue
			var current := _field_image.get_pixel(px, py).r
			var out_v: float = maxf(current, value)
			_field_image.set_pixel(px, py, Color(out_v, out_v, out_v, out_v))

func _rebuild_field_from_shape_source() -> void:
	if shape_source == null or shape_source.polygon.size() < 3:
		return
	_ensure_field_initialized(true)
	_field_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_rebuild_obstacle_mask()
	var shape_poly := shape_source.polygon
	var inv_transform := shape_source.transform.affine_inverse()

	var image_res := Vector2i(_field_image.get_width(), _field_image.get_height())
	for y: int in _field_image.get_height():
		for x: int in _field_image.get_width():
			if _is_obstacle_cell(x, y):
				continue
			var world := _field_cell_world(_field_world_rect, image_res, x, y)
			var local_area := to_local(world)
			var local_shape := inv_transform * local_area
			if Geometry2D.is_point_in_polygon(local_shape, shape_poly):
				_field_image.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0))

	_field_dirty_visual = true
	_field_dirty_collision = true
	mark_shape_dirty(true)

func _rebuild_obstacle_mask() -> void:
	if _field_image == null:
		return
	_obstacle_mask = Image.create(_field_image.get_width(), _field_image.get_height(), false, Image.FORMAT_R8)
	_obstacle_mask.fill(Color(0.0, 0.0, 0.0, 1.0))

	if not is_inside_tree():
		return
	var world := get_world_2d()
	if world == null:
		return
	var space := world.direct_space_state
	var query := PhysicsPointQueryParameters2D.new()
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var mask := collision_probe_mask
	if mask == 0:
		mask = collision_mask
	query.collision_mask = mask
	query.exclude = [get_rid()]

	var res := Vector2i(_field_image.get_width(), _field_image.get_height())
	var step := maxi(FIELD_OBSTACLE_SAMPLE_STEP, 1)
	var half_step := int(step / 2)
	for y: int in range(0, res.y, step):
		for x: int in range(0, res.x, step):
			var sample_x: int = mini(x + half_step, res.x - 1)
			var sample_y: int = mini(y + half_step, res.y - 1)
			query.position = _field_cell_world(_field_world_rect, res, sample_x, sample_y)
			var hits: Array = space.intersect_point(query, FIELD_OBSTACLE_QUERY_MAX_RESULTS)
			var blocked := false
			for hit_variant in hits:
				if typeof(hit_variant) != TYPE_DICTIONARY:
					continue
				var hit := hit_variant as Dictionary
				var collider_value: Variant = hit.get("collider", null)
				if not (collider_value is Object):
					continue
				var collider := collider_value as Object
				if collider == null or collider == self:
					continue
				if collider is Area2D and (collider as Area2D).is_in_group("slop_puddles"):
					continue
				if collider is CharacterBody2D:
					continue
				blocked = true
				break
			if blocked:
				var max_x := mini(x + step, res.x)
				var max_y := mini(y + step, res.y)
				for yy: int in range(y, max_y):
					for xx: int in range(x, max_x):
						_obstacle_mask.set_pixel(xx, yy, Color(1.0, 0.0, 0.0, 1.0))
	_dilate_obstacle_mask(FIELD_OBSTACLE_DILATE_PX)

func _dilate_obstacle_mask(iterations: int) -> void:
	if _obstacle_mask == null:
		return
	var width := _obstacle_mask.get_width()
	var height := _obstacle_mask.get_height()
	if width <= 0 or height <= 0:
		return
	for _iter: int in maxi(iterations, 0):
		var source := _obstacle_mask.duplicate()
		for y: int in height:
			for x: int in width:
				if source.get_pixel(x, y).r > 0.5:
					continue
				var blocked_neighbor := false
				for oy in range(-1, 2):
					for ox in range(-1, 2):
						if ox == 0 and oy == 0:
							continue
						var nx := x + ox
						var ny := y + oy
						if nx < 0 or ny < 0 or nx >= width or ny >= height:
							continue
						if source.get_pixel(nx, ny).r > 0.5:
							blocked_neighbor = true
							break
					if blocked_neighbor:
						break
				if blocked_neighbor:
					_obstacle_mask.set_pixel(x, y, Color(1.0, 0.0, 0.0, 1.0))

func contains_world_point(world_point: Vector2) -> bool:
	if collision_polygon == null:
		return false
	var poly: PackedVector2Array = collision_polygon.polygon
	if poly.size() < 3:
		return false
	var local_point: Vector2 = collision_polygon.to_local(world_point)
	if _has_local_collision_bounds and not _local_collision_bounds.has_point(local_point):
		return false
	return Geometry2D.is_point_in_polygon(local_point, poly)

func get_slow_factor_value() -> float:
	return clampf(slow_factor, 0.05, 1.0)
