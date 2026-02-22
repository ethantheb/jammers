extends RefCounted

const PEE_ACTION := "ui_pee"
const PEE_PUDDLE_GROUP := "player_pee_puddles"
const PEE_MIN_RADIUS := 12.0
const PEE_GROWTH_RATE := 10.0
const PEE_FOOT_OFFSET := Vector2(0, 10)
const PEE_TRAIL_POINT_SPACING := 2.5
const PEE_TRAIL_MOVE_THRESHOLD := 0.2
const PEE_TRAIL_CONNECTOR_RADIUS := 6.8
const PEE_TRAIL_BLOB_MAX_RADIUS := 42.0
const PEE_MOVE_FALLBACK_RADIUS := 3.2
const PEE_COLLISION_MARGIN := 1.5
const PEE_MIN_POINT_RADIUS := 2.0
const PEE_STATIONARY_JITTER := 1.2
const PEE_MOVE_STRENGTH := 0.90
const PEE_MOVE_SIDE_STRENGTH_SCALE := 0.68
const PEE_MOVE_SIDE_RADIUS_SCALE := 0.82
const PEE_MOVE_SIDE_OFFSET_SCALE := 0.56
const PEE_MOVE_WOBBLE_AMPLITUDE := 2.4
const PEE_MOVE_WOBBLE_EXTRA := 2.0
const PEE_MOVE_WOBBLE_FREQ := 0.18
const PEE_MOVE_WOBBLE_SPEED := 5.6
const PEE_MOVE_WOBBLE_DRIFT_LERP := 2.8
const PEE_IDLE_STRENGTH := 0.55
const PEE_IDLE_CLUSTER_SAMPLES := 7
const PEE_MERGE_CHECK_HZ := 4.0
const PEE_MERGE_MAX_PER_TICK := 3
const PEE_REUSE_RADIUS := 20.0
const ACTIVE_PEE_RUNTIME_SYNC_HZ := 22.0
const FINISHED_PEE_RUNTIME_SYNC_HZ := 3.0
const PUDDLE_RUNTIME_MODE_THROTTLED := 1

var _player: CharacterBody2D = null
var _pee_puddle_scene: PackedScene = null
var _pee_puddle_color: Color = Color(0.86, 0.76, 0.16, 0.62)
var _piss_noise_dps: float = 0.3
var piss_drain_rate: float = 0.2
var pee_remaining: float = 1.0
var _audio = null
var _piss_sound: AudioStream = null

var _is_peeing: bool = false
var _active_pee_puddle: Area2D = null
var _active_pee_seed: float = 0.0
var _active_pee_tip_world: Vector2 = Vector2.ZERO
var _active_pee_idle_radius: float = PEE_MIN_RADIUS
var _active_pee_spacing_accum: float = 0.0
var _active_pee_flow_phase: float = 0.0
var _active_pee_flow_drift: float = 0.0
var _active_pee_flow_distance: float = 0.0
var _active_pee_ray_query: PhysicsRayQueryParameters2D = null
var _pee_merge_check_accumulator: float = 0.0

func setup(
	player_ref: CharacterBody2D,
	puddle_scene: PackedScene,
	puddle_color: Color,
	piss_noise_dps: float,
	audio_node,
	piss_sound_stream: AudioStream
) -> void:
	_player = player_ref
	_pee_puddle_scene = puddle_scene
	_pee_puddle_color = puddle_color
	_piss_noise_dps = piss_noise_dps
	_audio = audio_node
	_piss_sound = piss_sound_stream

func ensure_input_action() -> void:
	if not InputMap.has_action(PEE_ACTION):
		InputMap.add_action(PEE_ACTION)

	var events := InputMap.action_get_events(PEE_ACTION)
	var has_p_binding := false
	for event in events:
		if not (event is InputEventKey):
			continue
		var key_event := event as InputEventKey
		var keycode := int(key_event.keycode)
		var physical_keycode := int(key_event.physical_keycode)
		if keycode == KEY_Q or physical_keycode == KEY_Q:
			InputMap.action_erase_event(PEE_ACTION, key_event)
			continue
		if keycode == KEY_P or physical_keycode == KEY_P:
			has_p_binding = true

	if has_p_binding:
		return
	var p_event := InputEventKey.new()
	p_event.physical_keycode = KEY_P
	p_event.keycode = KEY_P
	InputMap.action_add_event(PEE_ACTION, p_event)

func update(delta: float) -> void:
	if _player == null:
		return

	if pee_remaining <= 0.0:
		if _is_peeing:
			_finish_pee()
		return

	var holding := Input.is_action_pressed(PEE_ACTION)
	if holding and not _is_peeing:
		_start_pee()
	elif holding and _is_peeing:
		_grow_pee(delta)
	elif _is_peeing and not holding:
		_finish_pee()
	
	if _is_peeing:
		pee_remaining = max(0.0, pee_remaining - (piss_drain_rate * delta))
		HUD.update_pee_remaining(pee_remaining)


func _start_pee() -> void:
	var pee_origin := _player.global_position + PEE_FOOT_OFFSET
	var puddle := _get_or_create_scene_pee_field(pee_origin)
	if puddle == null:
		return

	_active_pee_puddle = puddle
	_active_pee_seed = randf_range(0.0, 999.0)
	_active_pee_tip_world = pee_origin
	_active_pee_idle_radius = PEE_MIN_RADIUS
	_active_pee_spacing_accum = 0.0
	_active_pee_flow_phase = randf_range(0.0, TAU)
	_active_pee_flow_drift = randf_range(-1.0, 1.0)
	_active_pee_flow_distance = 0.0
	_ensure_pee_ray_query()
	_pee_merge_check_accumulator = 0.0
	_set_puddle_runtime_mode(_active_pee_puddle, PUDDLE_RUNTIME_MODE_THROTTLED, ACTIVE_PEE_RUNTIME_SYNC_HZ, true)
	_is_peeing = true
	_emit_pee_splat(_active_pee_tip_world, _active_pee_idle_radius, 1.0, true)
	HUD.make_continuous_noise("piss", _piss_noise_dps)
	if _audio and _piss_sound:
		_audio.stream = _piss_sound
		_audio.play()

func _grow_pee(delta: float) -> void:
	if not is_instance_valid(_active_pee_puddle):
		_finish_pee()
		return

	var desired_tip := _player.global_position + PEE_FOOT_OFFSET
	var next_tip := _conform_tip_with_collisions(_active_pee_tip_world, desired_tip)
	var moved_distance := _active_pee_tip_world.distance_to(next_tip)
	var has_motion := _player.velocity.length() > 1.0 or moved_distance >= PEE_TRAIL_MOVE_THRESHOLD
	if has_motion:
		var move_speed_factor := clampf(_player.velocity.length() / 240.0, 0.0, 1.0)
		_active_pee_flow_phase += delta * (PEE_MOVE_WOBBLE_SPEED + move_speed_factor * 2.2)
		_active_pee_flow_drift = lerpf(_active_pee_flow_drift, randf_range(-1.0, 1.0), minf(1.0, delta * PEE_MOVE_WOBBLE_DRIFT_LERP))
		_emit_along_segment(delta, _active_pee_tip_world, next_tip)
		_active_pee_idle_radius = maxf(_active_pee_idle_radius - 20.0 * delta, PEE_TRAIL_CONNECTOR_RADIUS)
	else:
		_active_pee_flow_drift = lerpf(_active_pee_flow_drift, 0.0, minf(1.0, delta * 2.0))
		_active_pee_idle_radius = minf(_active_pee_idle_radius + PEE_GROWTH_RATE * delta, PEE_TRAIL_BLOB_MAX_RADIUS)
		_emit_stationary_collision_cluster(next_tip, _active_pee_idle_radius)
	_active_pee_tip_world = next_tip
	_pee_merge_check_accumulator += delta
	if _pee_merge_check_accumulator >= (1.0 / PEE_MERGE_CHECK_HZ):
		_pee_merge_check_accumulator = fposmod(_pee_merge_check_accumulator, 1.0 / PEE_MERGE_CHECK_HZ)
		_coalesce_scene_pee_fields(_active_pee_puddle)

func _finish_pee() -> void:
	if is_instance_valid(_active_pee_puddle):
		_emit_pee_splat(_active_pee_tip_world, _active_pee_idle_radius, 0.7, true)
		_coalesce_scene_pee_fields(_active_pee_puddle)
		_set_puddle_runtime_mode(_active_pee_puddle, PUDDLE_RUNTIME_MODE_THROTTLED, FINISHED_PEE_RUNTIME_SYNC_HZ, false)
	_is_peeing = false
	_active_pee_puddle = null
	_active_pee_tip_world = Vector2.ZERO
	_active_pee_idle_radius = PEE_MIN_RADIUS
	_active_pee_spacing_accum = 0.0
	_active_pee_flow_phase = 0.0
	_active_pee_flow_drift = 0.0
	_active_pee_flow_distance = 0.0
	_pee_merge_check_accumulator = 0.0
	HUD.stop_continuous_noise("piss")
	if _audio and _audio.stream == _piss_sound:
		_audio.stop()

func _conform_tip_with_collisions(origin_world: Vector2, target_world: Vector2) -> Vector2:
	var segment := target_world - origin_world
	var max_distance := segment.length()
	if max_distance <= PEE_MIN_POINT_RADIUS:
		return target_world
	var hit := _raycast_world(origin_world, target_world)
	if hit.is_empty():
		return target_world

	var hit_position: Vector2 = hit["position"]
	var dir := segment / maxf(max_distance, 0.001)
	var safe_distance := maxf(origin_world.distance_to(hit_position) - PEE_COLLISION_MARGIN, PEE_MIN_POINT_RADIUS)
	safe_distance = minf(safe_distance, max_distance)
	var safe_point := origin_world + dir * safe_distance

	var normal: Vector2 = hit["normal"]
	var remainder := target_world - safe_point
	var slide := remainder.slide(normal)
	if slide.length_squared() <= 0.0001:
		return safe_point

	var slide_target := safe_point + slide
	var hit_after_slide := _raycast_world(safe_point, slide_target)
	if hit_after_slide.is_empty():
		return slide_target
	var slide_dir := (slide_target - safe_point).normalized()
	var slide_hit_pos: Vector2 = hit_after_slide["position"]
	var slide_safe_dist := maxf(safe_point.distance_to(slide_hit_pos) - PEE_COLLISION_MARGIN, 0.0)
	return safe_point + slide_dir * slide_safe_dist

func _raycast_world(from_world: Vector2, to_world: Vector2) -> Dictionary:
	if _player == null or not _player.is_inside_tree():
		return {}
	var world := _player.get_world_2d()
	if world == null:
		return {}
	_ensure_pee_ray_query()
	if _active_pee_ray_query == null:
		return {}
	_active_pee_ray_query.from = from_world
	_active_pee_ray_query.to = to_world
	_active_pee_ray_query.collision_mask = _player.collision_mask
	return world.direct_space_state.intersect_ray(_active_pee_ray_query)

func _emit_along_segment(dt: float, from_world: Vector2, to_world: Vector2) -> int:
	var delta := to_world - from_world
	var distance := delta.length()
	if distance <= 0.1:
		return 0

	Game.add_score(randf_range(90, 110) * dt) # initialize score display in HUD

	var dir := delta / distance
	var perp := Vector2(-dir.y, dir.x)
	var speed_factor := clampf(_player.velocity.length() / 240.0, 0.0, 1.0)
	var distance_left := distance
	var traveled := 0.0
	var emitted := 0
	while _active_pee_spacing_accum + distance_left >= PEE_TRAIL_POINT_SPACING:
		var need := PEE_TRAIL_POINT_SPACING - _active_pee_spacing_accum
		traveled += need
		distance_left -= need
		_active_pee_spacing_accum = 0.0
		var point := from_world + dir * traveled
		var radius := _connector_radius_for_world(point)
		var wobble_offset := _moving_wobble_offset(point, _active_pee_flow_distance + traveled, speed_factor)
		var wobble_limit := maxf(radius * 0.95, 1.2)
		wobble_offset = clampf(wobble_offset, -wobble_limit, wobble_limit)
		var flow_point := point + perp * wobble_offset
		_emit_pee_splat(flow_point, radius, PEE_MOVE_STRENGTH)
		var side_offset := radius * PEE_MOVE_SIDE_OFFSET_SCALE
		side_offset += absf(wobble_offset) * 0.22
		var side_radius := radius * PEE_MOVE_SIDE_RADIUS_SCALE
		var side_strength := PEE_MOVE_STRENGTH * PEE_MOVE_SIDE_STRENGTH_SCALE
		var side_bias := clampf(wobble_offset / maxf(radius, 0.001), -0.7, 0.7)
		_emit_pee_splat(flow_point + perp * side_offset, side_radius, side_strength * (1.0 + side_bias * 0.22))
		_emit_pee_splat(flow_point - perp * side_offset, side_radius, side_strength * (1.0 - side_bias * 0.22))
		_emit_pee_splat(flow_point + perp * wobble_offset * 0.28, radius * 0.74, PEE_MOVE_STRENGTH * 0.52)
		emitted += 1
	_active_pee_spacing_accum += distance_left
	_active_pee_flow_distance += distance
	if emitted == 0 and distance >= PEE_TRAIL_MOVE_THRESHOLD:
		var fallback_wobble := _moving_wobble_offset(to_world, _active_pee_flow_distance, speed_factor)
		var fallback_point := to_world + perp * fallback_wobble * 0.45
		_emit_pee_splat(fallback_point, PEE_MOVE_FALLBACK_RADIUS, PEE_MOVE_STRENGTH * 0.6)
		emitted = 1
	return emitted

func _moving_wobble_offset(world_pos: Vector2, travel_distance: float, speed_factor: float) -> float:
	var base := sin(travel_distance * PEE_MOVE_WOBBLE_FREQ + _active_pee_flow_phase) * 0.70
	base += cos(travel_distance * PEE_MOVE_WOBBLE_FREQ * 0.57 - _active_pee_seed * 0.16 + _active_pee_flow_phase * 0.63) * 0.24
	base += sin(world_pos.x * 0.05 + _active_pee_seed * 0.22) * 0.14
	base += cos(world_pos.y * 0.045 - _active_pee_seed * 0.31) * 0.11
	base += _active_pee_flow_drift * 0.28
	var amplitude := PEE_MOVE_WOBBLE_AMPLITUDE + speed_factor * PEE_MOVE_WOBBLE_EXTRA
	return base * amplitude

func _emit_pee_splat(world_pos: Vector2, radius: float, strength: float, prefer_expand: bool = false) -> void:
	if not is_instance_valid(_active_pee_puddle):
		return
	var clamped_radius := _collision_clamped_splat_radius(world_pos, radius)
	if clamped_radius <= 0.25:
		return
	if _active_pee_puddle.has_method("deposit_splat"):
		_active_pee_puddle.call("deposit_splat", world_pos, clamped_radius, strength, prefer_expand)
		return
	if _active_pee_puddle.has_method("mark_shape_dirty"):
		_active_pee_puddle.call("mark_shape_dirty", true)

func _collision_clamped_splat_radius(world_pos: Vector2, desired_radius: float) -> float:
	var clamped := maxf(desired_radius, 0.0)
	if clamped <= 0.01:
		return 0.0
	var dirs := PackedVector2Array([
		Vector2.RIGHT,
		Vector2.LEFT,
		Vector2.UP,
		Vector2.DOWN,
		Vector2(1.0, 1.0).normalized(),
		Vector2(1.0, -1.0).normalized(),
		Vector2(-1.0, 1.0).normalized(),
		Vector2(-1.0, -1.0).normalized()
	])
	for dir in dirs:
		var hit := _raycast_world(world_pos, world_pos + dir * clamped)
		if hit.is_empty():
			continue
		var hit_position: Vector2 = hit["position"]
		var safe := maxf(world_pos.distance_to(hit_position) - PEE_COLLISION_MARGIN, 0.0)
		clamped = minf(clamped, safe)
		if clamped <= 0.25:
			return 0.0
	return minf(clamped, desired_radius)

func _emit_stationary_collision_cluster(center_world: Vector2, growth_radius: float) -> void:
	var spread_radius := maxf(growth_radius - PEE_TRAIL_CONNECTOR_RADIUS * 0.8, 0.0)
	var core_radius := clampf(growth_radius * 0.52, PEE_TRAIL_CONNECTOR_RADIUS * 1.15, growth_radius * 0.80)
	_emit_pee_splat(center_world, core_radius, PEE_IDLE_STRENGTH, true)

	for _i: int in PEE_IDLE_CLUSTER_SAMPLES:
		var angle := randf() * TAU
		var radial_unit := sqrt(randf())
		var desired := center_world + Vector2.from_angle(angle) * spread_radius * radial_unit
		var clipped := _conform_tip_with_collisions(center_world, desired)
		var splat_radius := lerpf(core_radius * 0.50, core_radius * 0.92, randf())
		_emit_pee_splat(clipped, splat_radius, PEE_IDLE_STRENGTH * 0.92, false)

func _connector_radius_for_world(world_pos: Vector2) -> float:
	var w := world_pos * 0.06
	var wobble := sin(w.x + _active_pee_seed * 0.13) * 0.7
	wobble += cos(w.y - _active_pee_seed * 0.19) * 0.45
	var radius := PEE_TRAIL_CONNECTOR_RADIUS + wobble * PEE_STATIONARY_JITTER
	return clampf(radius, PEE_TRAIL_CONNECTOR_RADIUS * 0.65, PEE_TRAIL_CONNECTOR_RADIUS + PEE_STATIONARY_JITTER * 1.25)

func _get_or_create_scene_pee_field(pee_origin: Vector2) -> Area2D:
	if _player == null:
		return null
	var scene_root := _player.get_parent()
	if scene_root == null:
		scene_root = _player.get_tree().current_scene

	var puddles := _scene_pee_fields(scene_root)
	if puddles.is_empty():
		return _spawn_new_pee_puddle(pee_origin)

	var primary: Area2D = puddles[0]
	for puddle in puddles:
		if _puddle_merge_weight(puddle) > _puddle_merge_weight(primary):
			primary = puddle
	_coalesce_scene_pee_fields(primary, true)
	return primary

func _scene_pee_fields(scene_root: Node) -> Array[Area2D]:
	if _player == null:
		return []
	var out: Array[Area2D] = []
	for node in _player.get_tree().get_nodes_in_group(PEE_PUDDLE_GROUP):
		if not (node is Area2D):
			continue
		var puddle := node as Area2D
		if not is_instance_valid(puddle):
			continue
		if scene_root != null and not scene_root.is_ancestor_of(puddle):
			continue
		out.append(puddle)
	return out

func _coalesce_scene_pee_fields(anchor: Area2D, force_all: bool = false) -> void:
	if anchor == null or not is_instance_valid(anchor):
		return
	if not anchor.has_method("merge_from_puddle"):
		return
	if _player == null:
		return
	var scene_root := _player.get_parent()
	var puddles := _scene_pee_fields(scene_root)
	if puddles.size() < 2:
		return

	var merged := 0
	for other in puddles:
		if other == anchor or not is_instance_valid(other):
			continue
		if not force_all and not _puddles_overlap_for_merge(anchor, other):
			continue
		var merged_ok := bool(anchor.call("merge_from_puddle", other))
		if merged_ok:
			other.queue_free()
			merged += 1
			if not force_all and merged >= PEE_MERGE_MAX_PER_TICK:
				break

func _puddles_overlap_for_merge(a: Area2D, b: Area2D) -> bool:
	if a == null or b == null:
		return false
	if not is_instance_valid(a) or not is_instance_valid(b):
		return false
	if a.has_method("get_field_world_rect") and b.has_method("get_field_world_rect"):
		var a_rect: Rect2 = a.call("get_field_world_rect")
		var b_rect: Rect2 = b.call("get_field_world_rect")
		if not a_rect.intersects(b_rect):
			return false
		var center_dist := a.global_position.distance_to(b.global_position)
		if center_dist <= (PEE_REUSE_RADIUS * 3.0):
			return true
	if _collision_polygons_overlap(a, b):
		return true
	if a.has_method("contains_world_point") and bool(a.call("contains_world_point", b.global_position)):
		return true
	if b.has_method("contains_world_point") and bool(b.call("contains_world_point", a.global_position)):
		return true
	if b.has_method("contains_world_point"):
		if bool(b.call("contains_world_point", _active_pee_tip_world)):
			return true
	return false

func _collision_polygons_overlap(a: Area2D, b: Area2D) -> bool:
	var a_world := _puddle_collision_polygon_world(a)
	var b_world := _puddle_collision_polygon_world(b)
	if a_world.size() >= 3 and b_world.size() >= 3:
		var intersections: Array = Geometry2D.intersect_polygons(a_world, b_world)
		for poly_variant in intersections:
			if not (poly_variant is PackedVector2Array):
				continue
			var poly := poly_variant as PackedVector2Array
			if poly.size() >= 3:
				return true
	return false

func _puddle_merge_weight(puddle: Area2D) -> float:
	var poly := _puddle_collision_polygon_world(puddle)
	if poly.size() >= 3:
		return absf(_polygon_signed_area_world(poly))
	if puddle.has_method("get_field_world_rect"):
		var rect: Rect2 = puddle.call("get_field_world_rect")
		return maxf(rect.size.x * rect.size.y, 1.0)
	return 1.0

func _polygon_signed_area_world(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i: int in poly.size():
		var p0 := poly[i]
		var p1 := poly[(i + 1) % poly.size()]
		area += p0.x * p1.y - p1.x * p0.y
	return area * 0.5

func _puddle_collision_polygon_world(puddle: Area2D) -> PackedVector2Array:
	var world_poly := PackedVector2Array()
	if puddle == null:
		return world_poly
	var collision_node := puddle.get_node_or_null("CollisionPolygon2D")
	if not (collision_node is CollisionPolygon2D):
		return world_poly
	var collision := collision_node as CollisionPolygon2D
	var local_poly := collision.polygon
	if local_poly.size() < 3:
		return world_poly
	world_poly.resize(local_poly.size())
	var xform := collision.global_transform
	for i: int in local_poly.size():
		world_poly[i] = xform * local_poly[i]
	return world_poly

func _spawn_new_pee_puddle(pee_origin: Vector2) -> Area2D:
	if _player == null or _pee_puddle_scene == null:
		return null
	var instance := _pee_puddle_scene.instantiate()
	if not (instance is Area2D):
		return null
	var puddle := instance as Area2D
	var target_parent := _player.get_parent()
	if target_parent != null:
		target_parent.add_child(puddle)
	else:
		_player.get_tree().current_scene.add_child(puddle)
	puddle.global_position = pee_origin
	puddle.add_to_group(PEE_PUDDLE_GROUP)

	_try_set_property(puddle, &"slow_factor", 0.8)
	_try_set_property(puddle, &"shape_variation", 0.0015)
	_try_set_property(puddle, &"animation_speed", 0.025)
	_try_set_property(puddle, &"corner_rounding", 0.95)
	_try_set_property(puddle, &"puddle_color", _pee_puddle_color)
	_try_set_property(puddle, &"seed", randf_range(0.0, 999.0))
	_try_set_property(puddle, &"use_field_renderer", true)
	_try_set_property(puddle, &"use_field_pee_renderer", true)
	_try_set_property(puddle, &"field_resolution", Vector2i(192, 192))
	_try_set_property(puddle, &"field_world_size", Vector2(320.0, 320.0))
	_try_set_property(puddle, &"field_threshold", 0.22)
	_try_set_property(puddle, &"edge_softness_px", 1.8)
	_try_set_property(puddle, &"collision_probe_mask", _player.collision_mask)
	_try_set_property(puddle, &"field_diffusion_hz", 0.0)
	_try_set_property(puddle, &"field_diffusion_passes", 0)
	_try_set_property(puddle, &"field_diffusion_strength", 0.0)
	_try_set_property(puddle, &"field_collision_hz", 5.0)
	if puddle.has_method("reset_field"):
		puddle.call("reset_field")
	return puddle

func _ensure_pee_ray_query() -> void:
	if _player == null or _active_pee_ray_query != null:
		return
	_active_pee_ray_query = PhysicsRayQueryParameters2D.create(Vector2.ZERO, Vector2.ZERO)
	_active_pee_ray_query.collide_with_bodies = true
	_active_pee_ray_query.collide_with_areas = false
	_active_pee_ray_query.collision_mask = _player.collision_mask
	_active_pee_ray_query.exclude = [_player.get_rid()]

func _set_puddle_runtime_mode(puddle: Object, mode: int, hz: float, sync_collision: bool) -> void:
	if puddle == null:
		return
	if puddle.has_method("set_runtime_mode"):
		puddle.call("set_runtime_mode", mode, hz, sync_collision)
		return
	_try_set_property(puddle, &"runtime_update_mode", mode)
	_try_set_property(puddle, &"runtime_sync_hz", hz)
	_try_set_property(puddle, &"runtime_sync_collision", sync_collision)
	if puddle.has_method("mark_shape_dirty"):
		puddle.call("mark_shape_dirty", true)

func _try_set_property(target: Object, property_name: StringName, value: Variant) -> void:
	for property_info in target.get_property_list():
		if str(property_info.get("name", "")) == String(property_name):
			target.set(property_name, value)
			return
