extends Node

const PEE_PUDDLE_GROUP := "player_pee_puddles"
const PEE_PUDDLE_SCENE: PackedScene = preload("res://scenes/slop_puddle.tscn")

var _scene_pee_puddle_state: Dictionary = {}
var _active_scene_root: Node = null
var _overlay: ColorRect = null

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

func fade_to_black(duration: float = 0.8) -> void:
	var tween = create_tween()
	tween.tween_property(_overlay, "color:a", 1.0, duration)
	await tween.finished

func fade_from_black(duration: float = 0.8) -> void:
	var tween = create_tween()
	tween.tween_property(_overlay, "color:a", 0.0, duration)
	await tween.finished

func load_dream_scene(scene: PackedScene, fade: bool = false) -> void:
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

	# Clear all children from current scene
	for child in current_root.get_children():
		child.queue_free()

	# Instantiate and add the dream scene
	var scene_instance = scene.instantiate()
	current_root.add_child(scene_instance)
	_active_scene_root = scene_instance
	_restore_pee_puddles(scene_instance)

	# Position player at SpawnPoint if one exists, or spawn one if the scene doesn't have one
	var spawn = scene_instance.find_child("SpawnPoint")
	var existing_player = scene_instance.find_child("Player")
	if existing_player:
		if spawn:
			existing_player.global_position = spawn.global_position
	else:
		var player_scene = load("res://scenes/player.tscn")
		var player_instance = player_scene.instantiate()
		scene_instance.add_child(player_instance)
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

	var entries: Array = []
	var puddles := get_tree().get_nodes_in_group(PEE_PUDDLE_GROUP)
	for node in puddles:
		if not (node is Node2D):
			continue
		var puddle := node as Node2D
		if not is_instance_valid(puddle):
			continue
		if not scene_root.is_ancestor_of(puddle):
			continue
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

	var entries: Array = _scene_pee_puddle_state.get(scene_key, [])
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
		"seed"
	]
	for prop_name in prop_names:
		if _has_property(puddle, prop_name):
			entry[prop_name] = puddle.get(prop_name)

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

func _apply_puddle_shape(puddle: Node2D, entry: Dictionary) -> void:
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

func _has_property(target: Object, property_name: String) -> bool:
	for info in target.get_property_list():
		if str(info.get("name", "")) == property_name:
			return true
	return false
