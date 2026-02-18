extends CharacterBody2D

const SPEED = 100.0
const CHASE_SPEED_BONUS = 30.0

@onready var shadow = get_node_or_null("Shadow")
@onready var body = $Body
@onready var head = $Head

@onready var raycast = $PlayerRayCast
@onready var label = $PlayerLabel

var last_direction: Vector2
var is_being_chased: bool = false

func _play_animation(animation: String) -> void:
	body.play(animation)
	head.play(animation)

func _physics_process(_delta: float) -> void:
	var direction := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")

	var speed = SPEED
	if is_being_chased:
		speed += CHASE_SPEED_BONUS
	velocity = direction * speed
	var movement: String = "walk"
	if Input.is_action_pressed("ui_sprint"):
		movement = "run"
		velocity *= 2

	move_and_slide()

	if velocity.length() <= 0:
		if last_direction.x < 0:
			_play_animation("idle_left")
		elif last_direction.x > 0:
			_play_animation("idle_right")
		elif last_direction.y < 0:
			_play_animation("idle_up")
		else:
			_play_animation("idle_down")
	else:
		last_direction = direction
		if velocity.x < 0:
			_play_animation(movement + "_left")
		elif velocity.x > 0:
			_play_animation(movement + "_right")
		elif velocity.y < 0:
			_play_animation(movement + "_up")
		elif velocity.y > 0:
			_play_animation(movement + "_down")

	raycast.rotation = -atan2(last_direction.x, last_direction.y)
	if $PlayerRayCast.is_colliding():
		var target = $PlayerRayCast.get_collider()
		
		if target != null and target.has_method("sleep"):
			label.text = "Press E to sleep"
	else:
		label.text = ""

func set_chased(chased: bool) -> void:
	is_being_chased = chased

