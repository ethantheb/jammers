extends CharacterBody2D

const PlayerPeeController = preload("res://scripts/player_pee_controller.gd")

const SPEED = 100.0
const CHASE_SPEED_BONUS = 30.0
const INTERACT_ACTION = "ui_interact"
const PEE_PUDDLE_GROUP = "player_pee_puddles"
const SCALE_MIN = 0.1
const SCALE_MAX = 3.0
const SCALE_STEP = 0.1
const TRACKPAD_SCROLL_THRESHOLD = 12.0
const SLOP_RESCAN_INTERVAL = 0.5

const BUMP_SOUND_PATH = "res://assets/sfx/bump.wav"
const STEP_SOUND_PATH = "res://assets/sfx/footsteps_wood.mp3"
const PUDDLE_STEP_SOUND_PATH = "res://assets/sfx/puddle_step.wav"
const PISS_SOUND_PATH = "res://assets/sfx/piss.wav"
const DOG_SPRITE_SHEET_PATH = "res://assets/dogpisser/shibainu.png"
const DOG_FRAME_WIDTH = 64
const DOG_FRAME_HEIGHT = 48
const DEFAULT_SPAWN_FACING_DIRECTION = Vector2(0, -1)

@onready var shadow = get_node_or_null("Shadow")
@onready var body = $Body
@onready var head = $Head
@onready var dog = get_node_or_null("Dog")
@onready var collision_shape = get_node_or_null("CollisionShape2D")

@onready var raycast = $PlayerRayCast
@onready var audio = $Audio

@export var pee_puddle_scene: PackedScene = preload("res://scenes/slop_puddle.tscn")
@export var pee_puddle_color: Color = Color(0.86, 0.76, 0.16, 0.62)
@export var dog_mode: bool = false
@export_range(12, 64, 1) var interaction_prompt_font_size: int = 40

@export var transparent_mode: bool = false
@export var transparent_move_multiplier: float = 3.3

@export var walk_noise_dps = 0.1
@export var piss_noise_dps = 0.3

@export var STEP_INTERVAL_WALK = 0.1
var STEP_INTERVAL_RUN = STEP_INTERVAL_WALK * 0.5

var last_direction: Vector2 = DEFAULT_SPAWN_FACING_DIRECTION
var facing_direction_snapped: Vector2 = DEFAULT_SPAWN_FACING_DIRECTION
var _last_movement: String = ""
var is_being_chased: bool = false
var is_sleeping: bool = false
var slop_slow_factor: float = 1.0
var _pee_controller: PlayerPeeController = null
var _prev_position: Vector2
var _step_timer: float = 0.0

var _bump_sound: AudioStream
var _step_sound: AudioStream
var _puddle_step_sound: AudioStream
var _piss_sound: AudioStream

var _trackpad_scroll_accumulator: float = 0.0
var _tracked_slop_sources: Dictionary = {}
var _slop_rescan_timer: float = 0.0
var _stored_borderless_flag: bool = false
var _stored_borderless_flag_valid: bool = false

signal position_changed(new_position: Vector2)

func _ready() -> void:
	# register self with Game singleton for global access
	Game.player = self

	_ensure_dog_sprite_frames()
	set_dog_mode(dog_mode)
	set_transparent_mode(transparent_mode)
	randomize()

	if dog_mode:
		# TODO: Remove these scales if we settle on dog mode
		$PlayerRayCast.scale = 2.0 * Vector2.ONE

	_prev_position = global_position
	_bump_sound = load(BUMP_SOUND_PATH)
	_step_sound = load(STEP_SOUND_PATH)
	_puddle_step_sound = load(PUDDLE_STEP_SOUND_PATH)
	_piss_sound = load(PISS_SOUND_PATH)
	_pee_controller = PlayerPeeController.new()
	_pee_controller.setup(self, pee_puddle_scene, pee_puddle_color, piss_noise_dps, audio, _piss_sound)
	_pee_controller.pee_remaining = Game.pee_remaining
	HUD.update_pee_remaining(_pee_controller.pee_remaining)
	_ensure_pee_action()
	_slop_rescan_timer = SLOP_RESCAN_INTERVAL
	last_direction = _snap_to_8_directions(last_direction)
	facing_direction_snapped = _snap_to_8_directions(last_direction)
	raycast.rotation = -atan2(last_direction.x, last_direction.y)
	_play_animation("idle_up")

func is_peeing() -> bool:
	return _pee_controller != null and _pee_controller._is_peeing

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
	var window_id := 0

	if enabled and OS.get_name() == "macOS":
		if not _stored_borderless_flag_valid:
			_stored_borderless_flag = DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, window_id)
			_stored_borderless_flag_valid = true
		# macOS transparent windows need borderless mode to render alpha properly.
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true, window_id)

	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, enabled, window_id)

	if (not enabled) and _stored_borderless_flag_valid:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, _stored_borderless_flag, window_id)
		_stored_borderless_flag_valid = false

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
	_update_slop_from_puddles(delta)


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
	if (global_position != _prev_position):
		position_changed.emit(global_position)

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
	if source != null and is_instance_valid(source):
		_tracked_slop_sources[source.get_instance_id()] = source
	slop_slow_factor = minf(slop_slow_factor, clampf(slow, 0.05, 1.0))

func exit_slop(source: Node = null) -> void:
	if source == null:
		return
	_tracked_slop_sources.erase(source.get_instance_id())

func _update_slop_from_puddles(delta: float) -> void:
	slop_slow_factor = 1.0
	var probe_point := _slop_probe_point()
	var checked_sources := _apply_slowdown_from_tracked_sources(probe_point)

	_slop_rescan_timer -= delta
	var should_rescan := _slop_rescan_timer <= 0.0 and (_tracked_slop_sources.is_empty() or slop_slow_factor >= 1.0)
	if should_rescan:
		_rescan_slop_sources(probe_point)
		checked_sources = _apply_slowdown_from_tracked_sources(probe_point)
		_slop_rescan_timer = SLOP_RESCAN_INTERVAL

func _apply_slowdown_from_tracked_sources(probe_point: Vector2) -> int:
	var stale_keys: Array = []
	var checked_sources := 0
	for key_variant in _tracked_slop_sources.keys():
		var source_variant: Variant = _tracked_slop_sources[key_variant]
		if source_variant == null or not is_instance_valid(source_variant):
			stale_keys.append(key_variant)
			continue
		var source := source_variant as Node
		if source == null:
			stale_keys.append(key_variant)
			continue
		if source.has_method("contains_world_point") and source.contains_world_point(probe_point):
			checked_sources += 1
			if source.has_method("get_slow_factor_value"):
				slop_slow_factor = minf(slop_slow_factor, float(source.get_slow_factor_value()))
			else:
				slop_slow_factor = minf(slop_slow_factor, 0.3)
		else:
			stale_keys.append(key_variant)

	for stale_key in stale_keys:
		_tracked_slop_sources.erase(stale_key)
	return checked_sources

func _rescan_slop_sources(probe_point: Vector2) -> void:
	_tracked_slop_sources.clear()
	var puddles := get_tree().get_nodes_in_group("slop_puddles")
	for puddle in puddles:
		if not is_instance_valid(puddle):
			continue
		if puddle.has_method("contains_world_point") and puddle.contains_world_point(probe_point):
			_tracked_slop_sources[puddle.get_instance_id()] = puddle

func _slop_probe_point() -> Vector2:
	if collision_shape:
		return collision_shape.global_position
	return global_position

func _handle_interaction() -> void:
	var target: Node = null
	if raycast.is_colliding():
		target = raycast.get_collider()

	if target == null:
		if HUD and HUD.has_method("set_interaction_prompt"):
			HUD.set_interaction_prompt("", interaction_prompt_font_size)
		return

	var prompt := _interaction_prompt(target)
	if HUD and HUD.has_method("set_interaction_prompt"):
		HUD.set_interaction_prompt(prompt, interaction_prompt_font_size)

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
	if _pee_controller == null:
		return
	_pee_controller.update(delta)

func _ensure_pee_action() -> void:
	if _pee_controller == null:
		return
	_pee_controller.ensure_input_action()

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
