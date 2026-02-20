extends CharacterBody2D

const SPEED = 100.0
const CHASE_SPEED_BONUS = 30.0
const INTERACT_ACTION = "ui_interact"
const PEE_ACTION = "ui_pee"
const PEE_PUDDLE_GROUP = "player_pee_puddles"
const PEE_MIN_RADIUS = 12.0
const PEE_MAX_RADIUS = 72.0
const PEE_GROWTH_RATE = 10.0
const PEE_SHAPE_POINTS = 52
const PEE_EDGE_JITTER = 0.01
const PEE_WAVE_STRENGTH = 0.015
const PEE_FOOT_OFFSET = Vector2(0, 10)
const PEE_COLLISION_MARGIN = 1.5
const PEE_MIN_POINT_RADIUS = 2.0
const PEE_HOLD_WAVE_SPEED = 0.12
const SCALE_MIN = 0.1
const SCALE_MAX = 3.0
const SCALE_STEP = 0.1
const TRACKPAD_SCROLL_THRESHOLD = 12.0

const BUMP_SOUND_PATH = "res://assets/sfx/bump.wav"
const STEP_SOUND_PATH = "res://assets/sfx/footsteps_wood.mp3"
const PUDDLE_STEP_SOUND_PATH = "res://assets/sfx/puddle_step.wav"
const PISS_SOUND_PATH = "res://assets/sfx/piss.wav"
const DOG_SPRITE_SHEET_PATH = "res://assets/dogpisser/shibainu.png"
const DOG_FRAME_WIDTH = 64
const DOG_FRAME_HEIGHT = 48

@onready var shadow = get_node_or_null("Shadow")
@onready var body = $Body
@onready var head = $Head
@onready var dog = get_node_or_null("Dog")
@onready var collision_shape = get_node_or_null("CollisionShape2D")

@onready var raycast = $PlayerRayCast
@onready var label = $PlayerLabel
@onready var audio = $Audio

@export var pee_puddle_scene: PackedScene = preload("res://scenes/slop_puddle.tscn")
@export var pee_puddle_color: Color = Color(0.86, 0.76, 0.16, 0.62)
@export var dog_mode: bool = false

@export var transparent_mode: bool = false
@export var transparent_move_multiplier: float = 3.3

@export var walk_noise_dps = 0.1
@export var piss_noise_dps = 0.3

@export var STEP_INTERVAL_WALK = 0.1
var STEP_INTERVAL_RUN = STEP_INTERVAL_WALK * 0.5

var last_direction: Vector2
var facing_direction_snapped: Vector2 = Vector2(0, 1)
var _last_movement: String = ""
var is_being_chased: bool = false
var is_sleeping: bool = false
var slop_slow_factor: float = 1.0
var _is_peeing: bool = false
var _active_pee_puddle: Area2D = null
var _active_pee_shape: Polygon2D = null
var _active_pee_radius: float = PEE_MIN_RADIUS
var _active_pee_jitter: PackedFloat32Array = PackedFloat32Array()
var _active_pee_wave_phase: float = 0.0
var _active_pee_seed: float = 0.0
var _prev_position: Vector2
var _step_timer: float = 0.0
var _bump_sound: AudioStream
var _step_sound: AudioStream
var _puddle_step_sound: AudioStream
var _piss_sound: AudioStream
var _trackpad_scroll_accumulator: float = 0.0

func _ready() -> void:
	_ensure_dog_sprite_frames()
	set_dog_mode(dog_mode)
	set_transparent_mode(transparent_mode)
	_ensure_pee_action()
	randomize()

	if dog_mode:
		# TODO: Remove these scales if we settle on dog mode
		$PlayerRayCast.scale = 2.0 * Vector2.ONE
		$PlayerLabel.scale = 0.4 * Vector2.ONE

	_prev_position = global_position
	_bump_sound = load(BUMP_SOUND_PATH)
	_step_sound = load(STEP_SOUND_PATH)
	_puddle_step_sound = load(PUDDLE_STEP_SOUND_PATH)
	_piss_sound = load(PISS_SOUND_PATH)

func _play_animation(animation: String) -> void:
	if is_sleeping:
		return
	if dog_mode and dog:
		var dog_animation := "dog_" + animation
		if dog.sprite_frames and dog.sprite_frames.has_animation(dog_animation):
			dog.play(dog_animation)
			return
		return
	body.play(animation)
	head.play(animation)

func set_dog_mode(enabled: bool) -> void:
	dog_mode = enabled
	_ensure_dog_sprite_frames()
	body.visible = not enabled
	head.visible = not enabled
	if dog:
		dog.visible = enabled

func set_transparent_mode(enabled: bool) -> void:
	transparent_mode = enabled
	var _rid = get_tree().get_root().get_viewport_rid()
	RenderingServer.viewport_set_transparent_background(_rid, enabled)
	get_tree().get_root().set_transparent_background(enabled)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, enabled)

func _ensure_dog_sprite_frames() -> void:
	if dog == null:
		return

	var frames: SpriteFrames = dog.sprite_frames
	if frames != null and frames.has_animation("dog_idle_down"):
		return

	var sprite_sheet := load(DOG_SPRITE_SHEET_PATH) as Texture2D
	if sprite_sheet == null:
		push_warning("Dog sprite sheet missing at %s" % DOG_SPRITE_SHEET_PATH)
		return

	frames = SpriteFrames.new()
	var directions := {
		"down": 0,
		"left": 1,
		"right": 2,
		"up": 3,
	}
	var states := {
		"idle": 0.0,
		"walk": 20.0,
		"run": 40.0,
	}

	for state_name in states.keys():
		var speed := float(states[state_name])
		for direction_name in directions.keys():
			var row := int(directions[direction_name])
			var animation_name := "dog_%s_%s" % [state_name, direction_name]
			frames.add_animation(animation_name)
			frames.set_animation_speed(animation_name, speed)
			frames.set_animation_loop(animation_name, false)

			for col in 3:
				var atlas := AtlasTexture.new()
				atlas.atlas = sprite_sheet
				atlas.region = Rect2(
					float(col * DOG_FRAME_WIDTH),
					float(row * DOG_FRAME_HEIGHT),
					float(DOG_FRAME_WIDTH),
					float(DOG_FRAME_HEIGHT)
				)
				frames.add_frame(animation_name, atlas, 1.0)

	dog.sprite_frames = frames
	dog.animation = &"dog_idle_down"

func _physics_process(delta: float) -> void:
	if is_sleeping:
		return
	var direction := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	_update_slop_from_puddles()


	# movement
	var movement: String = "walk"

	var speed = SPEED
	if is_being_chased:
		speed += CHASE_SPEED_BONUS
	velocity = direction * speed * slop_slow_factor
	if Input.is_action_pressed("ui_sprint"):
		movement = "run"
		velocity *= 2
		
	var was_colliding = get_slide_collision_count() > 0
	move_and_slide()

	if get_slide_collision_count() > 0 and not was_colliding:
		if global_position.distance_to(_prev_position) < 0.5:
			if audio:
				audio.stream = _bump_sound
				audio.play()

	if transparent_mode:
		var dpos = global_position - _prev_position
		get_window().position += Vector2i(dpos * transparent_move_multiplier)

	_prev_position = global_position

	# Movement sound and animation
	if velocity.length() > 0:
		HUD.make_continuous_noise("walk", walk_noise_dps * (2.0 if movement == "run" else 1.0))
		_step_timer -= delta
		if _step_timer <= 0:
			var step_interval = STEP_INTERVAL_RUN if movement == "run" else STEP_INTERVAL_WALK
			_step_timer = step_interval

			# Reset audio stream when movement type changes
			if audio and (not audio.playing or movement != _last_movement):
				if slop_slow_factor < 1.0:
					audio.stream = _puddle_step_sound
				else:
					audio.stream = _step_sound
					audio.pitch_scale = 2.5 if movement == "walk" else 4.0
				_last_movement = movement
				audio.play()
		last_direction = direction
		facing_direction_snapped = _snap_to_8_directions(last_direction)

		if velocity.x < 0:
			_play_animation(movement + "_left")
		elif velocity.x > 0:
			_play_animation(movement + "_right")
		elif velocity.y < 0:
			_play_animation(movement + "_up")
		elif velocity.y > 0:
			_play_animation(movement + "_down")
	else:
		HUD.stop_continuous_noise("walk")
		_step_timer = 0.0
		if audio and (audio.stream == _step_sound or audio.stream == _puddle_step_sound):
			audio.stop()
		if last_direction.x < 0:
			_play_animation("idle_left")
		elif last_direction.x > 0:
			_play_animation("idle_right")
		elif last_direction.y < 0:
			_play_animation("idle_up")
		else:
			_play_animation("idle_down")

	raycast.rotation = -atan2(last_direction.x, last_direction.y)
	_handle_interaction()
	_update_pee_action(delta)

func set_chased(chased: bool) -> void:
	is_being_chased = chased

func wake_up() -> void:
	# TODO: better wakeup behavior (reverse sleep anim, push out of bed)
	var bedroom = load("res://scenes/bedroom.tscn")
	Game.load_dream_scene(bedroom)

func enter_slop(slow: float, source: Node = null) -> void:
	slop_slow_factor = minf(slop_slow_factor, clampf(slow, 0.05, 1.0))

func exit_slop(source: Node = null) -> void:
	# Slowdown is recomputed each physics tick from live puddle containment.
	pass

func _update_slop_from_puddles() -> void:
	slop_slow_factor = 1.0
	var probe_point := _slop_probe_point()
	var puddles = get_tree().get_nodes_in_group("slop_puddles")
	for puddle in puddles:
		if not is_instance_valid(puddle):
			continue
		if puddle.has_method("contains_world_point") and puddle.contains_world_point(probe_point):
			if puddle.has_method("get_slow_factor_value"):
				slop_slow_factor = minf(slop_slow_factor, float(puddle.get_slow_factor_value()))
			else:
				slop_slow_factor = minf(slop_slow_factor, 0.3)

func _slop_probe_point() -> Vector2:
	if collision_shape:
		return collision_shape.global_position
	return global_position

func _handle_interaction() -> void:
	var target: Node = null
	if raycast.is_colliding():
		target = raycast.get_collider()

	if target == null:
		label.text = ""
		return

	label.text = _interaction_prompt(target)
	if Input.is_action_just_pressed(INTERACT_ACTION):
		_try_interact(target)

func _interaction_prompt(target: Node) -> String:
	if target.has_method("interaction_prompt"):
		return str(target.interaction_prompt())
	if target.has_method("sleep"):
		return "Press E to sleep"
	if target.has_method("pee"):
		return "Press E to pee"
	return ""

func _try_interact(target: Node) -> void:
	if target.has_method("interact"):
		target.interact(self)
		return
	if target.has_method("pee"):
		target.pee(self)
		return
	if target.has_method("sleep"):
		target.sleep(self)

func _update_pee_action(delta: float) -> void:
	var holding := _is_pee_hold_active()
	if holding and not _is_peeing:
		_start_pee()
	elif holding and _is_peeing:
		_grow_pee(delta)
	elif _is_peeing and not holding:
		_finish_pee()

func _start_pee() -> void:
	if pee_puddle_scene == null:
		return

	var instance := pee_puddle_scene.instantiate()
	if not (instance is Area2D):
		return

	var puddle := instance as Area2D
	var target_parent := get_parent()
	if target_parent != null:
		target_parent.add_child(puddle)
	else:
		get_tree().current_scene.add_child(puddle)
	puddle.global_position = global_position + PEE_FOOT_OFFSET
	puddle.add_to_group(PEE_PUDDLE_GROUP)

	_active_pee_seed = randf_range(0.0, 999.0)
	_try_set_property(puddle, &"slow_factor", 0.8)
	_try_set_property(puddle, &"shape_variation", 0.0015)
	_try_set_property(puddle, &"animation_speed", 0.025)
	_try_set_property(puddle, &"corner_rounding", 0.95)
	_try_set_property(puddle, &"puddle_color", pee_puddle_color)
	_try_set_property(puddle, &"seed", _active_pee_seed)

	var shape_node := puddle.get_node_or_null("Shape2D")
	if not (shape_node is Polygon2D):
		puddle.queue_free()
		return

	_active_pee_puddle = puddle
	_active_pee_shape = shape_node as Polygon2D
	_active_pee_radius = PEE_MIN_RADIUS
	_active_pee_wave_phase = randf_range(0.0, TAU)
	_active_pee_jitter = _make_pee_jitter(PEE_SHAPE_POINTS, _active_pee_seed)
	_is_peeing = true
	_update_pee_shape(true)
	HUD.make_continuous_noise("piss", piss_noise_dps)
	HUD.set_pissing(true)

	# Play piss sound
	if audio and _piss_sound:
		audio.stream = _piss_sound
		audio.play()

func _grow_pee(delta: float) -> void:
	if not is_instance_valid(_active_pee_puddle) or not is_instance_valid(_active_pee_shape):
		_finish_pee()
		return

	_active_pee_radius = minf(_active_pee_radius + PEE_GROWTH_RATE * delta, PEE_MAX_RADIUS)
	_active_pee_wave_phase += delta * PEE_HOLD_WAVE_SPEED
	_update_pee_shape(false)

func _finish_pee() -> void:
	if is_instance_valid(_active_pee_puddle):
		_update_pee_shape(true)
	_is_peeing = false
	_active_pee_puddle = null
	_active_pee_shape = null
	HUD.stop_continuous_noise("piss")
	HUD.set_pissing(false)

	# Stop piss sound
	if audio and audio.stream == _piss_sound:
		audio.stop()

func _update_pee_shape(force_sync: bool) -> void:
	if not is_instance_valid(_active_pee_puddle) or not is_instance_valid(_active_pee_shape):
		return

	var polygon := PackedVector2Array()
	polygon.resize(PEE_SHAPE_POINTS)
	for i: int in PEE_SHAPE_POINTS:
		var t := float(i) / float(PEE_SHAPE_POINTS)
		var angle := t * TAU
		var wave := sin(angle * 3.0 + _active_pee_wave_phase) * PEE_WAVE_STRENGTH
		wave += cos(angle * 5.0 - _active_pee_wave_phase * 0.8) * 0.015
		var random_edge := _active_pee_jitter[i] * PEE_EDGE_JITTER
		var radius_scale := maxf(0.35, 1.0 + wave + random_edge)
		var dir := Vector2(cos(angle), sin(angle))
		var desired_radius := _active_pee_radius * radius_scale
		var clipped_radius := _clip_pee_radius_against_colliders(dir, desired_radius)
		polygon[i] = dir * clipped_radius

	_active_pee_shape.polygon = polygon

	if _active_pee_puddle.has_method("_refresh_source_shape"):
		_active_pee_puddle.call("_refresh_source_shape", true)
	if _active_pee_puddle.has_method("_sync_shape"):
		var t := 0.0 if force_sync else Time.get_ticks_msec() * 0.001
		_active_pee_puddle.call("_sync_shape", t)

func _clip_pee_radius_against_colliders(dir: Vector2, desired_radius: float) -> float:
	if desired_radius <= PEE_MIN_POINT_RADIUS:
		return desired_radius
	if not is_inside_tree() or not is_instance_valid(_active_pee_puddle):
		return desired_radius

	var world := get_world_2d()
	if world == null:
		return desired_radius

	var origin := _active_pee_puddle.global_position
	var destination := origin + dir * desired_radius

	var query := PhysicsRayQueryParameters2D.create(origin, destination)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]

	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return desired_radius

	var hit_position: Vector2 = hit["position"]
	var clipped := origin.distance_to(hit_position) - PEE_COLLISION_MARGIN
	return clampf(clipped, PEE_MIN_POINT_RADIUS, desired_radius)

func _make_pee_jitter(point_count: int, seed_value: float) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed_value * 1000.0) + 17
	var out := PackedFloat32Array()
	out.resize(point_count)
	for i: int in point_count:
		out[i] = rng.randf_range(-1.0, 1.0)
	return out

func _try_set_property(target: Object, property_name: StringName, value: Variant) -> void:
	for property_info in target.get_property_list():
		if str(property_info.get("name", "")) == String(property_name):
			target.set(property_name, value)
			return

func _is_pee_hold_active() -> bool:
	return Input.is_action_pressed(PEE_ACTION) \
		or Input.is_key_pressed(KEY_Q) \
		or Input.is_physical_key_pressed(KEY_Q)

func _ensure_pee_action() -> void:
	if InputMap.has_action(PEE_ACTION):
		return

	InputMap.add_action(PEE_ACTION)
	var key_event := InputEventKey.new()
	key_event.physical_keycode = KEY_Q
	key_event.keycode = KEY_Q
	InputMap.action_add_event(PEE_ACTION, key_event)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_apply_player_scale_step(1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_apply_player_scale_step(-1.0)
	elif event is InputEventPanGesture:
		# macOS trackpad scrolling frequently arrives as pan gestures, not wheel buttons.
		_trackpad_scroll_accumulator -= event.delta.y
		var steps := int(_trackpad_scroll_accumulator / TRACKPAD_SCROLL_THRESHOLD)
		if steps != 0:
			_apply_player_scale_step(float(steps))
			_trackpad_scroll_accumulator -= float(steps) * TRACKPAD_SCROLL_THRESHOLD

func _apply_player_scale_step(step_count: float) -> void:
	scale = clamp(
		scale + Vector2.ONE * SCALE_STEP * step_count,
		Vector2.ONE * SCALE_MIN,
		Vector2.ONE * SCALE_MAX
	)
func _snap_to_8_directions(dir: Vector2) -> Vector2:
	if dir.length_squared() < 0.001:
		return facing_direction_snapped
	var angle := dir.angle()
	var snapped_angle: float = round(angle / (PI / 4.0)) * (PI / 4.0)
	return Vector2.from_angle(snapped_angle)
