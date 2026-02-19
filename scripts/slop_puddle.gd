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

const PUDDLE_SHADER: Shader = preload("res://shaders/slop_puddle.gdshader")
const MAX_SHADER_POINTS: int = 64

@onready var shape_source: Polygon2D = null
@onready var puddle_visual: Polygon2D = get_node_or_null("VisualPolygon2D")
@onready var collision_polygon: CollisionPolygon2D = get_node_or_null("CollisionPolygon2D")
@onready var legacy_color_rect: ColorRect = get_node_or_null("ColorRect")

var _source_points: PackedVector2Array = PackedVector2Array()
var _shape_center: Vector2 = Vector2.ZERO
var _shape_radius: float = 1.0

func _ready() -> void:
	# Area/body overlap checks need non-zero collision layers on both sides.
	if collision_layer == 0:
		collision_layer = 1
	if collision_mask == 0:
		collision_mask = 1
	add_to_group("slop_puddles")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_ensure_nodes()
	_refresh_source_shape(true)
	_apply_shader_material()
	_sync_shape(0.0)
	set_process(true)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		_refresh_source_shape(false)
		_sync_shape(0.0)
	else:
		_sync_shape(Time.get_ticks_msec() * 0.001 * animation_speed)

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
	if shape_source.polygon.size() < 3:
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

func _refresh_source_shape(force: bool) -> void:
	if shape_source == null:
		return

	if shape_source.polygon.size() < 3:
		shape_source.polygon = _build_default_polygon()

	var transformed_points: PackedVector2Array = _get_transformed_source_points()
	if force or _source_points != transformed_points:
		_source_points = transformed_points
		_recompute_shape_metrics()

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

func _sync_shape(anim_time: float) -> void:
	if puddle_visual == null or collision_polygon == null or _source_points.size() < 3:
		return

	var collision_points := _build_deformed_polygon(anim_time)
	var visual_points := _build_visual_polygon(collision_points)
	puddle_visual.polygon = visual_points
	collision_polygon.polygon = collision_points

	var shader_material := puddle_visual.material as ShaderMaterial
	if shader_material:
		var shader_points: PackedVector2Array = _points_for_shader(visual_points, MAX_SHADER_POINTS)
		shader_material.set_shader_parameter("animation_speed", animation_speed)
		shader_material.set_shader_parameter("edge_softness", edge_softness)
		shader_material.set_shader_parameter("puddle_color", puddle_color)
		shader_material.set_shader_parameter("seed", seed)
		shader_material.set_shader_parameter("shape_center", _shape_center)
		shader_material.set_shader_parameter("shape_radius", _shape_radius)
		shader_material.set_shader_parameter("shape_point_count", shader_points.size())
		shader_material.set_shader_parameter("shape_points", shader_points)

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

func contains_world_point(world_point: Vector2) -> bool:
	if collision_polygon == null:
		return false
	var poly: PackedVector2Array = collision_polygon.polygon
	if poly.size() < 3:
		return false
	var local_point: Vector2 = collision_polygon.to_local(world_point)
	return Geometry2D.is_point_in_polygon(local_point, poly)

func get_slow_factor_value() -> float:
	return clampf(slow_factor, 0.05, 1.0)
