@tool
extends CharacterBody2D

enum State { IDLE, ALERT, CHASING, LOOKING_AROUND }
const HIDDEN_VISIBILITY_LAYER: int = 4 # layer 3
const VISIBLE_VISIBILITY_LAYER: int = 2 # layer 2
const V2_CHASE_VISIBILITY_LAYER: int = 1 # layer 1
const FOG_ENEMY_GROUP: StringName = &"fog_enemy"
const ALARM_AUDIO_BUS_PREFIX: String = "AlarmGuyBus_"

@export var detection_radius: float = 80.0
@export var chase_radius: float = 140.0
@export var chase_speed: float = 170.0
@export var idle_wobble_speed: float = 2.0
@export var idle_wobble_amount: float = 3.0
@export var detection_field_scale_multiplier: Vector2 = Vector2.ONE
@export var chase_field_scale_multiplier: Vector2 = Vector2.ONE
@export var debug_show_areas: bool = false
@export var debug_detection_color: Color = Color(1.0, 0.3, 0.3, 0.22)
@export var debug_chase_color: Color = Color(1.0, 0.0, 0.0, 0.12)
@export var chase_audio_ramp_seconds: float = 3.0
@export var chase_audio_distortion_curve_power: float = 0.3
@export var chase_audio_max_distortion_drive: float = 1.0
@export var chase_audio_max_distortion_pregain_db: float = 56.0
@export var chase_audio_max_distortion_postgain_db: float = -12.0

var state: State = State.IDLE
var player: CharacterBody2D = null
var look_timer: float = 0.0
var look_duration: float = 2.5
var wobble_time: float = 0.0
var _fog_overlay: Node = null
var _v2_enemy_registered: bool = false
var _base_detection_area_scale: Vector2 = Vector2.ONE
var _base_chase_area_scale: Vector2 = Vector2.ONE
var _last_debug_show_areas: bool = false
var _default_visibility_layer: int = HIDDEN_VISIBILITY_LAYER
var _chase_audio_elapsed: float = 0.0
var _base_scream_volume_db: float = -10.0
var _audio_bus_name: String = ""
var _audio_bus_index: int = -1
var _owns_audio_bus: bool = false
var _scream_distortion: AudioEffectDistortion = null

@onready var sprite: Sprite2D = $Sprite2D
@onready var detection_area: Area2D = $DetectionArea
@onready var detection_shape: CollisionShape2D = $DetectionArea/CollisionShape2D
@onready var chase_area: Area2D = $ChaseArea
@onready var chase_shape: CollisionShape2D = $ChaseArea/CollisionShape2D
@onready var scream_audio: AudioStreamPlayer2D = $ScreamAudio

func _ready() -> void:
	add_to_group(FOG_ENEMY_GROUP)
	if _sprite_alive():
		_default_visibility_layer = sprite.visibility_layer
	_base_detection_area_scale = detection_area.scale
	_base_chase_area_scale = chase_area.scale
	_sync_area_scale_to_authored_shape()
	if detection_shape.shape is CircleShape2D:
		detection_radius = (detection_shape.shape as CircleShape2D).radius
	if chase_shape.shape is CircleShape2D:
		chase_radius = (chase_shape.shape as CircleShape2D).radius
	if Engine.is_editor_hint():
		queue_redraw()
		return
	detection_area.body_entered.connect(_on_detection_entered)
	chase_area.body_exited.connect(_on_chase_exited)
	_setup_scream_audio()
	call_deferred("_try_register_v2_enemy")
	if _sprite_alive():
		sprite.visible = true
	_enter_idle()

func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	_sync_area_scale_to_authored_shape()
	queue_redraw()

func _exit_tree() -> void:
	_unregister_v2_enemy()
	_set_alarm_blob_mode(false)
	_teardown_scream_audio_bus()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		_sync_area_scale_to_authored_shape()
		if debug_show_areas or _last_debug_show_areas != debug_show_areas:
			queue_redraw()
		_last_debug_show_areas = debug_show_areas
		return
	_sync_area_scale_to_authored_shape()
	_try_register_v2_enemy()
	if debug_show_areas or _last_debug_show_areas != debug_show_areas:
		queue_redraw()
	_last_debug_show_areas = debug_show_areas
	match state:
		State.IDLE:
			_do_idle(delta)
		State.ALERT:
			_do_alert(delta)
		State.CHASING:
			_do_chasing(delta)
		State.LOOKING_AROUND:
			_do_looking_around(delta)

func _do_idle(delta: float) -> void:
	wobble_time += delta
	if _sprite_alive():
		sprite.rotation = sin(wobble_time * idle_wobble_speed) * deg_to_rad(idle_wobble_amount)

func _do_alert(_delta: float) -> void:
	_enter_chase()

func _do_chasing(delta: float) -> void:
	if not is_instance_valid(player):
		_enter_looking_around()
		return

	var to_player = player.global_position - global_position
	if to_player.length() < 15.0:
		var caught = player
		_enter_idle()
		caught.wake_up()
		return

	var dir = to_player.normalized()
	velocity = dir * chase_speed
	move_and_slide()

	# Face the player
	if _sprite_alive():
		sprite.flip_h = dir.x < 0

	# Shake while chasing for spookiness
	if _sprite_alive():
		sprite.rotation = sin(Time.get_ticks_msec() * 0.03) * deg_to_rad(8.0)

	if is_instance_valid(scream_audio):
		if not scream_audio.playing:
			scream_audio.play()
		_tick_chase_audio(delta)

func _do_looking_around(delta: float) -> void:
	velocity = Vector2.ZERO
	look_timer += delta

	# Swivel back and forth looking confused
	if _sprite_alive():
		sprite.rotation = sin(look_timer * 4.0) * deg_to_rad(15.0)

	if look_timer >= look_duration:
		_enter_idle()

func _enter_idle() -> void:
	state = State.IDLE
	_set_hidden_render_mode(true)
	_set_alarm_blob_mode(true)
	_set_v2_force_visible(false)
	look_timer = 0.0
	if is_instance_valid(scream_audio):
		scream_audio.stop()
	_reset_chase_audio()
	if _sprite_alive():
		sprite.rotation = 0.0
	# Tell player chase is over
	if is_instance_valid(player) and player.has_method("set_chased"):
		player.set_chased(false)
	player = null

func _enter_alert() -> void:
	state = State.ALERT
	_set_hidden_render_mode(true)
	_set_alarm_blob_mode(true)
	_set_v2_force_visible(false)

func _enter_chase() -> void:
	state = State.CHASING
	_set_hidden_render_mode(false)
	_set_alarm_blob_mode(false)
	_set_v2_force_visible(true)
	chase_shape.shape.radius = chase_radius
	if is_instance_valid(player) and player.has_method("set_chased"):
		player.set_chased(true)

func _enter_looking_around() -> void:
	state = State.LOOKING_AROUND
	_set_hidden_render_mode(true)
	_set_alarm_blob_mode(true)
	_set_v2_force_visible(false)
	look_timer = 0.0
	if is_instance_valid(scream_audio):
		scream_audio.stop()
	_reset_chase_audio()
	velocity = Vector2.ZERO
	if is_instance_valid(player) and player.has_method("set_chased"):
		player.set_chased(false)

func _on_detection_entered(body: Node2D) -> void:
	if body.name == "Player" and state == State.IDLE:
		player = body
		_enter_alert()

func _on_chase_exited(body: Node2D) -> void:
	if body.name == "Player" and state == State.CHASING:
		_enter_looking_around()

func _set_hidden_render_mode(hidden: bool) -> void:
	if not _sprite_alive():
		return
	if _fog_overlay == null or not is_instance_valid(_fog_overlay):
		_fog_overlay = _find_fog_overlay()
	if _is_v2_fog_overlay(_fog_overlay):
		# In v2, chase should render on always-visible layer 1.
		sprite.visibility_layer = _default_visibility_layer if hidden else V2_CHASE_VISIBILITY_LAYER
		return
	sprite.visibility_layer = HIDDEN_VISIBILITY_LAYER if hidden else VISIBLE_VISIBILITY_LAYER

	if _fog_overlay != null and _fog_overlay.has_method("set_hidden_visual"):
		_fog_overlay.call("set_hidden_visual", sprite, hidden)

func _set_alarm_blob_mode(enabled: bool) -> void:
	if not _sprite_alive():
		return
	if _fog_overlay == null or not is_instance_valid(_fog_overlay):
		_fog_overlay = _find_fog_overlay()
	if _is_v2_fog_overlay(_fog_overlay):
		return
	if _fog_overlay != null:
		if _fog_overlay.has_method("set_alarm_blob_target"):
			_fog_overlay.call("set_alarm_blob_target", sprite, enabled)
		elif _fog_overlay.has_method("set_chase_shadow_visual"):
			_fog_overlay.call("set_chase_shadow_visual", sprite, enabled, false)

func _sprite_alive() -> bool:
	return sprite != null and is_instance_valid(sprite)

func _find_fog_overlay() -> Node:
	var root := _get_level_root()
	if root == null:
		return null
	return root.find_child("FogOverlay", true, false)

func _get_level_root() -> Node:
	var n: Node = self
	while n.get_parent() != null:
		var p := n.get_parent()
		if p is Window:
			break
		n = p
	return n

func _is_v2_fog_overlay(node: Node) -> bool:
	return node != null and node.has_method("register_enemy_sprite") and node.has_method("unregister_enemy_sprite")

func _try_register_v2_enemy() -> void:
	if _v2_enemy_registered:
		return
	if not _sprite_alive():
		return
	if _fog_overlay == null or not is_instance_valid(_fog_overlay):
		_fog_overlay = _find_fog_overlay()
	if not _is_v2_fog_overlay(_fog_overlay):
		return
	_fog_overlay.call("register_enemy_sprite", sprite)
	_set_v2_force_visible(state == State.CHASING)
	_v2_enemy_registered = true

func _set_v2_force_visible(force_visible: bool) -> void:
	if not _sprite_alive():
		return
	if _fog_overlay == null or not is_instance_valid(_fog_overlay):
		_fog_overlay = _find_fog_overlay()
	if not _is_v2_fog_overlay(_fog_overlay):
		return
	if _fog_overlay.has_method("set_enemy_force_visible"):
		_fog_overlay.call("set_enemy_force_visible", sprite, force_visible)

func _unregister_v2_enemy() -> void:
	if not _v2_enemy_registered:
		return
	if _fog_overlay == null or not is_instance_valid(_fog_overlay):
		_fog_overlay = _find_fog_overlay()
	if _is_v2_fog_overlay(_fog_overlay) and _sprite_alive():
		_fog_overlay.call("unregister_enemy_sprite", sprite)
	_v2_enemy_registered = false

func _sync_area_scale_to_authored_shape() -> void:
	var global_s := global_scale
	var inv_global_s := Vector2(
		1.0 / global_s.x if absf(global_s.x) > 0.0001 else 1.0,
		1.0 / global_s.y if absf(global_s.y) > 0.0001 else 1.0
	)
	var detect_mul := _safe_scale_multiplier(detection_field_scale_multiplier)
	var chase_mul := _safe_scale_multiplier(chase_field_scale_multiplier)
	detection_area.scale = Vector2(
		_base_detection_area_scale.x * detect_mul.x * inv_global_s.x,
		_base_detection_area_scale.y * detect_mul.y * inv_global_s.y
	)
	chase_area.scale = Vector2(
		_base_chase_area_scale.x * chase_mul.x * inv_global_s.x,
		_base_chase_area_scale.y * chase_mul.y * inv_global_s.y
	)

func _safe_scale_multiplier(value: Variant) -> Vector2:
	if not (value is Vector2):
		return Vector2.ONE
	var mul: Vector2 = value
	return Vector2(
		maxf(absf(mul.x), 0.001),
		maxf(absf(mul.y), 0.001)
	)

func _draw() -> void:
	if not debug_show_areas:
		return
	_draw_area_circle(chase_shape, debug_chase_color)
	_draw_area_circle(detection_shape, debug_detection_color)

func _draw_area_circle(shape_node: CollisionShape2D, fill_color: Color) -> void:
	if shape_node == null or not is_instance_valid(shape_node):
		return
	if not (shape_node.shape is CircleShape2D):
		return

	var circle := shape_node.shape as CircleShape2D
	var segments := 64
	var points := PackedVector2Array()
	for i in range(segments):
		var angle := TAU * float(i) / float(segments)
		var shape_local := Vector2(cos(angle), sin(angle)) * circle.radius
		var world_p := shape_node.to_global(shape_local)
		points.append(to_local(world_p))

	if points.size() < 3:
		return
	draw_colored_polygon(points, fill_color)
	points.append(points[0])
	draw_polyline(points, fill_color.lightened(0.18), 1.5, true)

func _setup_scream_audio() -> void:
	if not is_instance_valid(scream_audio):
		return
	_base_scream_volume_db = scream_audio.volume_db
	if scream_audio.stream is AudioStreamMP3:
		var mp3_stream := scream_audio.stream as AudioStreamMP3
		mp3_stream.loop = true
	_ensure_scream_audio_bus()
	_reset_chase_audio()

func _ensure_scream_audio_bus() -> void:
	if not is_instance_valid(scream_audio):
		return
	_audio_bus_name = "%s%d" % [ALARM_AUDIO_BUS_PREFIX, get_instance_id()]
	_audio_bus_index = AudioServer.get_bus_index(_audio_bus_name)
	if _audio_bus_index == -1:
		AudioServer.add_bus(AudioServer.get_bus_count())
		_audio_bus_index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(_audio_bus_index, _audio_bus_name)
		AudioServer.set_bus_send(_audio_bus_index, "Master")
		_owns_audio_bus = true
	else:
		_owns_audio_bus = false
	scream_audio.bus = _audio_bus_name
	_scream_distortion = _find_or_add_distortion_effect(_audio_bus_index)
	_configure_distortion_defaults()

func _find_or_add_distortion_effect(bus_idx: int) -> AudioEffectDistortion:
	if bus_idx < 0:
		return null
	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		var effect := AudioServer.get_bus_effect(bus_idx, i)
		if effect is AudioEffectDistortion:
			return effect as AudioEffectDistortion
	var distortion := AudioEffectDistortion.new()
	AudioServer.add_bus_effect(bus_idx, distortion)
	return distortion

func _configure_distortion_defaults() -> void:
	if _scream_distortion == null:
		return
	_scream_distortion.mode = AudioEffectDistortion.MODE_OVERDRIVE
	_scream_distortion.keep_hf_hz = 8000.0
	_scream_distortion.drive = 0.0
	_scream_distortion.pre_gain = 0.0
	_scream_distortion.post_gain = 0.0

func _tick_chase_audio(delta: float) -> void:
	_chase_audio_elapsed += maxf(delta, 0.0)
	_apply_chase_audio_intensity()

func _reset_chase_audio() -> void:
	_chase_audio_elapsed = 0.0
	_apply_chase_audio_intensity()

func _apply_chase_audio_intensity() -> void:
	if not is_instance_valid(scream_audio):
		return
	var ramp_seconds := maxf(chase_audio_ramp_seconds, 0.01)
	var t := clampf(_chase_audio_elapsed / ramp_seconds, 0.0, 1.0)
	var distortion_t := pow(t, clampf(chase_audio_distortion_curve_power, 0.05, 2.0))
	# Keep loudness proximity-based; only distortion intensity ramps with chase time.
	scream_audio.volume_db = _base_scream_volume_db
	if _scream_distortion != null:
		_scream_distortion.drive = clampf(lerpf(0.0, chase_audio_max_distortion_drive, distortion_t), 0.0, 1.0)
		_scream_distortion.pre_gain = lerpf(0.0, chase_audio_max_distortion_pregain_db, distortion_t)
		_scream_distortion.post_gain = lerpf(0.0, chase_audio_max_distortion_postgain_db, distortion_t)

func _teardown_scream_audio_bus() -> void:
	if _audio_bus_name.is_empty():
		return
	if is_instance_valid(scream_audio):
		scream_audio.bus = "Master"
	if _owns_audio_bus:
		var bus_idx := AudioServer.get_bus_index(_audio_bus_name)
		if bus_idx > 0:
			AudioServer.remove_bus(bus_idx)
	_audio_bus_name = ""
	_audio_bus_index = -1
	_owns_audio_bus = false
	_scream_distortion = null
