extends Node

const PEE_PUDDLE_GROUP := "player_pee_puddles"
const PEE_PUDDLE_SCENE: PackedScene = preload("res://scenes/slop_puddle.tscn")
const PEE_SAVE_VERSION := 2
const PEE_SAVE_MAX_RES := 512

var _scene_pee_puddle_state: Dictionary = {}
var _active_scene_root: Node = null
var _overlay: ColorRect = null

var score: float = 0.0
var pee_remaining: float = 1.0

var player: Node = null

func _ready() -> void:
	_active_scene_root = get_tree().current_scene
	var canvas = CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_overlay)

func add_score(amount: float) -> void:
	score += amount
	HUD.update_score(score)

func fade_to_black(duration: float = 0.8) -> void:
	var tween = create_tween()
	tween.tween_property(_overlay, "color:a", 1.0, duration)
	await tween.finished

func fade_from_black(duration: float = 0.8) -> void:
	var tween = create_tween()
	tween.tween_property(_overlay, "color:a", 0.0, duration)
	await tween.finished

func load_dream_scene(scene: PackedScene, fade: bool = false, spawn_point: Vector2 = Vector2.ZERO) -> void:
	assert(scene)

	if fade:
		await fade_to_black()

	var tree := get_tree()
	var current_root := tree.current_scene
	if current_root == null:
		return

	var previous_scene_root := _active_scene_root
	if previous_scene_root == null:
		previous_scene_root = current_root
	_capture_pee_puddles(previous_scene_root)

	# Save pee state before clearing the scene
	if player != null and player.get("_pee_controller") != null:
		pee_remaining = player._pee_controller.pee_remaining

	# Clear all children from current scene
	for child in current_root.get_children():
		child.queue_free()

	# Instantiate and add the dream scene
	var scene_instance = scene.instantiate()
	current_root.add_child(scene_instance)
	_active_scene_root = scene_instance
	_restore_pee_puddles(scene_instance)

	# If spawn_point given, it takes priority. Otherwise look for a SpawnPoint node.
	var spawn = scene_instance.find_child("SpawnPoint")
	var existing_player = scene_instance.find_child("Player")
	if existing_player:
		if spawn_point != Vector2.ZERO:
			existing_player.global_position = spawn_point
		if spawn:
			existing_player.global_position = spawn.global_position
	else:
		var player_scene = load("res://scenes/player.tscn")
		var player_instance = player_scene.instantiate()
		scene_instance.add_child(player_instance)
		if spawn_point != Vector2.ZERO:
			player_instance.global_position = spawn_point
		if spawn:
			player_instance.global_position = spawn.global_position

	if fade:
		await fade_from_black()

func help_me() ->  void:
	get_tree().quit()

func _capture_pee_puddles(scene_root: Node) -> void:
	if scene_root == null:
		return
	var scene_key := _scene_key(scene_root)
	if scene_key == "":
		return

	var puddles := _scene_puddles(scene_root)
	if puddles.is_empty():
		_scene_pee_puddle_state.erase(scene_key)
		return

	var primary := _primary_puddle(puddles)
	var payloads: Array[Dictionary] = []
	for puddle in puddles:
		if puddle.has_method("export_field_save_payload"):
			var payload_variant: Variant = puddle.call("export_field_save_payload")
			if typeof(payload_variant) == TYPE_DICTIONARY:
				var payload := payload_variant as Dictionary
				if not payload.is_empty():
					payloads.append(payload)

	if not payloads.is_empty():
		var combined_payload := _combine_field_payloads(payloads)
		if not combined_payload.is_empty():
			_scene_pee_puddle_state[scene_key] = {
				"version": PEE_SAVE_VERSION,
				"props": _serialize_puddle_props(primary),
				"field": combined_payload
			}
			return

	# Legacy fallback if a puddle does not expose field payloads.
	var entries: Array = []
	for puddle in puddles:
		entries.append(_serialize_pee_puddle(scene_root, puddle))
	_scene_pee_puddle_state[scene_key] = entries

func _restore_pee_puddles(scene_root: Node) -> void:
	if scene_root == null:
		return
	var scene_key := _scene_key(scene_root)
	if scene_key == "":
		return
	if not _scene_pee_puddle_state.has(scene_key):
		return

	var state_variant: Variant = _scene_pee_puddle_state.get(scene_key, null)
	if typeof(state_variant) == TYPE_DICTIONARY:
		var state := state_variant as Dictionary
		var state_version := int(state.get("version", 0))
		var field_variant: Variant = state.get("field", null)
		if state_version >= PEE_SAVE_VERSION and typeof(field_variant) == TYPE_DICTIONARY:
			var field_payload := field_variant as Dictionary
			var puddle_instance := PEE_PUDDLE_SCENE.instantiate()
			if puddle_instance is Node2D:
				var puddle := puddle_instance as Node2D
				scene_root.add_child(puddle)
				var props_variant: Variant = state.get("props", {})
				if typeof(props_variant) == TYPE_DICTIONARY:
					_apply_puddle_properties(puddle, props_variant as Dictionary)
				var rect_variant: Variant = field_payload.get("rect", null)
				if typeof(rect_variant) == TYPE_RECT2:
					var world_rect: Rect2 = rect_variant
					puddle.global_position = world_rect.position + world_rect.size * 0.5
				var restored := false
				if puddle.has_method("restore_field_save_payload"):
					restored = bool(puddle.call("restore_field_save_payload", field_payload))
				if restored:
					puddle.add_to_group(PEE_PUDDLE_GROUP)
					return
				puddle.queue_free()

	# Legacy restore fallback (older in-memory state format).
	var entries: Array = []
	if typeof(state_variant) == TYPE_ARRAY:
		entries = state_variant as Array
	var restored_fields: Array[Area2D] = []
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry := entry_variant as Dictionary

		var puddle_instance := PEE_PUDDLE_SCENE.instantiate()
		if not (puddle_instance is Node2D):
			continue
		var puddle := puddle_instance as Node2D

		var parent_node: Node = scene_root
		if entry.has("parent_path"):
			var parent_path: NodePath = entry["parent_path"]
			var found_parent := scene_root.get_node_or_null(parent_path)
			if found_parent != null:
				parent_node = found_parent
		parent_node.add_child(puddle)
		puddle.global_position = entry.get("position", Vector2.ZERO)

		_apply_puddle_properties(puddle, entry)
		_apply_puddle_shape(puddle, entry)

		if puddle.has_method("_refresh_source_shape"):
			puddle.call("_refresh_source_shape", true)
		if puddle.has_method("_sync_shape"):
			puddle.call("_sync_shape", 0.0)
		puddle.add_to_group(PEE_PUDDLE_GROUP)
		if puddle is Area2D:
			restored_fields.append(puddle as Area2D)

	_coalesce_restored_pee_fields(restored_fields)

func _scene_puddles(scene_root: Node) -> Array[Area2D]:
	var out: Array[Area2D] = []
	var all_puddles := get_tree().get_nodes_in_group(PEE_PUDDLE_GROUP)
	for node in all_puddles:
		if not (node is Area2D):
			continue
		var puddle := node as Area2D
		if not is_instance_valid(puddle):
			continue
		if scene_root != null and not scene_root.is_ancestor_of(puddle):
			continue
		out.append(puddle)
	return out

func _primary_puddle(puddles: Array[Area2D]) -> Area2D:
	var primary: Area2D = puddles[0]
	var primary_weight := _puddle_weight(primary)
	for puddle in puddles:
		var weight := _puddle_weight(puddle)
		if weight > primary_weight:
			primary = puddle
			primary_weight = weight
	return primary

func _serialize_puddle_props(puddle: Object) -> Dictionary:
	var props: Dictionary = {}
	if puddle == null:
		return props
	var prop_names := [
		"slow_factor",
		"base_radius",
		"shape_variation",
		"corner_rounding",
		"animation_speed",
		"edge_softness",
		"puddle_color",
		"seed",
		"use_field_renderer",
		"use_field_pee_renderer",
		"field_resolution",
		"field_world_size",
		"field_threshold",
		"edge_softness_px",
		"collision_probe_mask",
		"field_diffusion_hz",
		"field_diffusion_passes",
		"field_diffusion_strength",
		"field_collision_hz",
		"runtime_update_mode",
		"runtime_sync_hz",
		"runtime_sync_collision"
	]
	for prop_name in prop_names:
		if _has_property(puddle, prop_name):
			props[prop_name] = puddle.get(prop_name)
	return props

func _combine_field_payloads(payloads: Array[Dictionary]) -> Dictionary:
	if payloads.is_empty():
		return {}
	if payloads.size() == 1:
		return payloads[0].duplicate(true)

	var combined_rect: Rect2
	var has_rect := false
	var max_ppu_x := 0.0
	var max_ppu_y := 0.0
	var decoded_payloads: Array[Dictionary] = []

	for payload in payloads:
		var image := _payload_to_image(payload)
		if image == null:
			continue
		var rect_variant: Variant = payload.get("rect", null)
		if typeof(rect_variant) != TYPE_RECT2:
			continue
		var rect: Rect2 = rect_variant
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		if not has_rect:
			combined_rect = rect
			has_rect = true
		else:
			combined_rect = combined_rect.merge(rect)
		max_ppu_x = maxf(max_ppu_x, float(image.get_width()) / maxf(rect.size.x, 1.0))
		max_ppu_y = maxf(max_ppu_y, float(image.get_height()) / maxf(rect.size.y, 1.0))
		decoded_payloads.append({
			"image": image,
			"rect": rect
		})

	if decoded_payloads.is_empty() or not has_rect:
		return {}

	var res_x := clampi(int(ceil(combined_rect.size.x * maxf(max_ppu_x, 0.1))), 32, PEE_SAVE_MAX_RES)
	var res_y := clampi(int(ceil(combined_rect.size.y * maxf(max_ppu_y, 0.1))), 32, PEE_SAVE_MAX_RES)
	var combined_image := Image.create(res_x, res_y, false, Image.FORMAT_RGBA8)
	combined_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for decoded in decoded_payloads:
		var src_image := decoded["image"] as Image
		var src_rect: Rect2 = decoded["rect"]
		_blit_image_into_rect(src_image, src_rect, combined_image, combined_rect)

	return {
		"version": PEE_SAVE_VERSION,
		"rect": combined_rect,
		"width": combined_image.get_width(),
		"height": combined_image.get_height(),
		"format": int(Image.FORMAT_RGBA8),
		"data": combined_image.get_data()
	}

func _payload_to_image(payload: Dictionary) -> Image:
	var width := int(payload.get("width", 0))
	var height := int(payload.get("height", 0))
	var format := int(payload.get("format", int(Image.FORMAT_RGBA8)))
	var data_variant: Variant = payload.get("data", PackedByteArray())
	if not (data_variant is PackedByteArray):
		return null
	var data := data_variant as PackedByteArray
	if width <= 0 or height <= 0 or data.is_empty():
		return null
	var image := Image.create_from_data(width, height, false, format, data)
	if image == null:
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image

func _blit_image_into_rect(src_image: Image, src_rect: Rect2, dst_image: Image, dst_rect: Rect2) -> void:
	if src_image == null or dst_image == null:
		return
	var src_w := src_image.get_width()
	var src_h := src_image.get_height()
	var dst_w := dst_image.get_width()
	var dst_h := dst_image.get_height()
	for y: int in src_h:
		for x: int in src_w:
			var value := src_image.get_pixel(x, y).r
			if value <= 0.001:
				continue
			var world := Vector2(
				src_rect.position.x + ((float(x) + 0.5) / float(maxi(src_w, 1))) * src_rect.size.x,
				src_rect.position.y + ((float(y) + 0.5) / float(maxi(src_h, 1))) * src_rect.size.y
			)
			var uv := (world - dst_rect.position) / dst_rect.size
			var dx := clampi(int(round(uv.x * float(maxi(dst_w - 1, 0)))), 0, dst_w - 1)
			var dy := clampi(int(round(uv.y * float(maxi(dst_h - 1, 0)))), 0, dst_h - 1)
			var current := dst_image.get_pixel(dx, dy).r
			var out_v := maxf(current, value)
			dst_image.set_pixel(dx, dy, Color(out_v, out_v, out_v, out_v))

func _serialize_pee_puddle(scene_root: Node, puddle: Node2D) -> Dictionary:
	var entry: Dictionary = {}
	entry["position"] = puddle.global_position

	var parent_node := puddle.get_parent()
	if parent_node != null and scene_root.is_ancestor_of(parent_node):
		entry["parent_path"] = scene_root.get_path_to(parent_node)
	else:
		entry["parent_path"] = NodePath(".")

	var prop_names := [
		"slow_factor",
		"base_radius",
		"shape_variation",
		"corner_rounding",
		"animation_speed",
		"edge_softness",
		"puddle_color",
		"seed",
		"use_field_renderer",
		"use_field_pee_renderer",
		"field_resolution",
		"field_world_size",
		"field_threshold",
		"edge_softness_px",
		"collision_probe_mask",
		"field_diffusion_hz",
		"field_diffusion_passes",
		"field_diffusion_strength",
		"field_collision_hz",
		"runtime_update_mode",
		"runtime_sync_hz",
		"runtime_sync_collision"
	]
	for prop_name in prop_names:
		if _has_property(puddle, prop_name):
			entry[prop_name] = puddle.get(prop_name)

	if puddle.has_method("rebuild_collision_from_field"):
		puddle.call("rebuild_collision_from_field")

	if puddle.has_method("extract_field_snapshot"):
		var snapshot_variant: Variant = puddle.call("extract_field_snapshot")
		if typeof(snapshot_variant) == TYPE_DICTIONARY:
			var snapshot := snapshot_variant as Dictionary
			var snapshot_image := snapshot.get("image", null) as Image
			var snapshot_rect_variant: Variant = snapshot.get("rect", null)
			if snapshot_image != null and typeof(snapshot_rect_variant) == TYPE_RECT2:
				entry["field_snapshot_image"] = snapshot_image.duplicate()
				entry["field_snapshot_rect"] = snapshot_rect_variant

	var collision_node := puddle.get_node_or_null("CollisionPolygon2D")
	if collision_node is CollisionPolygon2D:
		var collision := collision_node as CollisionPolygon2D
		if collision.polygon.size() >= 3:
			entry["shape_polygon"] = collision.polygon
			entry["shape_position"] = Vector2.ZERO
			entry["shape_rotation"] = 0.0
			entry["shape_scale"] = Vector2.ONE

	if not entry.has("shape_polygon"):
		var shape_node := puddle.get_node_or_null("Shape2D")
		if shape_node is Polygon2D:
			var shape := shape_node as Polygon2D
			entry["shape_polygon"] = shape.polygon
			entry["shape_position"] = shape.position
			entry["shape_rotation"] = shape.rotation
			entry["shape_scale"] = shape.scale

	return entry

func _apply_puddle_properties(puddle: Object, entry: Dictionary) -> void:
	for key in entry.keys():
		if typeof(key) != TYPE_STRING:
			continue
		var name := String(key)
		if name.begins_with("shape_"):
			continue
		if name == "position" or name == "parent_path":
			continue
		if _has_property(puddle, name):
			puddle.set(name, entry[name])

	if puddle.has_method("set_runtime_mode"):
		var mode := int(entry.get("runtime_update_mode", puddle.get("runtime_update_mode")))
		var hz := float(entry.get("runtime_sync_hz", puddle.get("runtime_sync_hz")))
		var sync_collision := bool(entry.get("runtime_sync_collision", puddle.get("runtime_sync_collision")))
		puddle.call("set_runtime_mode", mode, hz, sync_collision)

func _apply_puddle_shape(puddle: Node2D, entry: Dictionary) -> void:
	if entry.has("field_snapshot_image") and entry.has("field_snapshot_rect"):
		var snapshot_image := entry["field_snapshot_image"] as Image
		var rect_variant: Variant = entry["field_snapshot_rect"]
		if snapshot_image != null and typeof(rect_variant) == TYPE_RECT2:
			if puddle.has_method("restore_field_snapshot"):
				var restored := bool(puddle.call("restore_field_snapshot", snapshot_image, rect_variant))
				if restored:
					return

	var shape_node := puddle.get_node_or_null("Shape2D")
	if not (shape_node is Polygon2D):
		return
	var shape := shape_node as Polygon2D
	if entry.has("shape_polygon"):
		shape.polygon = entry["shape_polygon"]
	if entry.has("shape_position"):
		shape.position = entry["shape_position"]
	if entry.has("shape_rotation"):
		shape.rotation = float(entry["shape_rotation"])
	if entry.has("shape_scale"):
		shape.scale = entry["shape_scale"]

func _scene_key(scene_root: Node) -> String:
	if scene_root == null:
		return ""
	var path := scene_root.scene_file_path
	if path != "":
		return path
	return scene_root.name

func _coalesce_restored_pee_fields(restored_fields: Array[Area2D]) -> void:
	if restored_fields.size() < 2:
		return
	var primary: Area2D = restored_fields[0]
	var primary_weight := _puddle_weight(primary)
	for field in restored_fields:
		if field == null or not is_instance_valid(field):
			continue
		var w := _puddle_weight(field)
		if w > primary_weight:
			primary = field
			primary_weight = w
	if primary == null or not is_instance_valid(primary):
		return
	if not primary.has_method("merge_from_puddle"):
		return
	for field in restored_fields:
		if field == null or not is_instance_valid(field) or field == primary:
			continue
		var merged_ok := bool(primary.call("merge_from_puddle", field))
		if merged_ok:
			field.queue_free()

func _puddle_weight(puddle: Area2D) -> float:
	if puddle == null or not is_instance_valid(puddle):
		return 0.0
	if puddle.has_method("get_field_world_rect"):
		var rect: Rect2 = puddle.call("get_field_world_rect")
		return maxf(rect.size.x * rect.size.y, 1.0)
	var collision_node := puddle.get_node_or_null("CollisionPolygon2D")
	if collision_node is CollisionPolygon2D:
		var poly := (collision_node as CollisionPolygon2D).polygon
		if poly.size() >= 3:
			return absf(_polygon_signed_area(poly))
	return 1.0

func _polygon_signed_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i: int in poly.size():
		var p0 := poly[i]
		var p1 := poly[(i + 1) % poly.size()]
		area += p0.x * p1.y - p1.x * p0.y
	return area * 0.5

func _has_property(target: Object, property_name: String) -> bool:
	for info in target.get_property_list():
		if str(info.get("name", "")) == property_name:
			return true
	return false
