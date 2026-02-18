extends CharacterBody2D

enum State { IDLE, ALERT, CHASING, LOOKING_AROUND }

@export var detection_radius: float = 80.0
@export var chase_radius: float = 140.0
@export var chase_speed: float = 170.0
@export var idle_wobble_speed: float = 2.0
@export var idle_wobble_amount: float = 3.0

var state: State = State.IDLE
var player: CharacterBody2D = null
var look_timer: float = 0.0
var look_duration: float = 2.5
var wobble_time: float = 0.0
var alert_grow_speed: float = 120.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var detection_area: Area2D = $DetectionArea
@onready var detection_shape: CollisionShape2D = $DetectionArea/CollisionShape2D
@onready var chase_area: Area2D = $ChaseArea
@onready var chase_shape: CollisionShape2D = $ChaseArea/CollisionShape2D
@onready var scream_audio: AudioStreamPlayer2D = $ScreamAudio

func _ready() -> void:
	detection_shape.shape.radius = detection_radius
	chase_shape.shape.radius = chase_radius
	detection_area.body_entered.connect(_on_detection_entered)
	chase_area.body_exited.connect(_on_chase_exited)

func _physics_process(delta: float) -> void:
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
	sprite.rotation = sin(wobble_time * idle_wobble_speed) * deg_to_rad(idle_wobble_amount)

func _do_alert(delta: float) -> void:
	# Grow the chase radius outward quickly to "engulf" the player
	var current_r = chase_shape.shape.radius
	if current_r < chase_radius:
		chase_shape.shape.radius = min(current_r + alert_grow_speed * delta, chase_radius)
	# Immediately transition to chasing
	_enter_chase()

func _do_chasing(delta: float) -> void:
	if not is_instance_valid(player):
		_enter_looking_around()
		return

	var dir = (player.global_position - global_position).normalized()
	velocity = dir * chase_speed
	move_and_slide()

	# Face the player
	sprite.flip_h = dir.x < 0

	# Shake while chasing for spookiness
	sprite.rotation = sin(Time.get_ticks_msec() * 0.03) * deg_to_rad(8.0)

	if not scream_audio.playing:
		scream_audio.play()

func _do_looking_around(delta: float) -> void:
	velocity = Vector2.ZERO
	look_timer += delta

	# Swivel back and forth looking confused
	sprite.rotation = sin(look_timer * 4.0) * deg_to_rad(15.0)

	if look_timer >= look_duration:
		_enter_idle()

func _enter_idle() -> void:
	state = State.IDLE
	look_timer = 0.0
	scream_audio.stop()
	sprite.rotation = 0.0
	# Reset chase area to small so it can re-detect
	chase_shape.shape.radius = detection_radius
	# Tell player chase is over
	if is_instance_valid(player) and player.has_method("set_chased"):
		player.set_chased(false)
	player = null

func _enter_alert() -> void:
	state = State.ALERT
	# Start chase radius small, will grow
	chase_shape.shape.radius = detection_radius

func _enter_chase() -> void:
	state = State.CHASING
	chase_shape.shape.radius = chase_radius
	if is_instance_valid(player) and player.has_method("set_chased"):
		player.set_chased(true)

func _enter_looking_around() -> void:
	state = State.LOOKING_AROUND
	look_timer = 0.0
	scream_audio.stop()
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
