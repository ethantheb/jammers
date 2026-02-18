extends CharacterBody2D

const SPEED = 100.0

@onready var shadow = $Shadow
@onready var body = $Body
@onready var head = $Head

@onready var raycast = $PlayerRayCast
@onready var label = $PlayerLabel

var last_direction: Vector2

func _play_animation(animation: String) -> void:
	shadow.play(animation)
	body.play(animation)
	head.play(animation)

func _physics_process(_delta: float) -> void:
	var direction := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	velocity = direction * SPEED
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
			_play_animation("walk_left")
		elif velocity.x > 0:
			_play_animation("walk_right")
		elif velocity.y < 0:
			_play_animation("walk_up")
		elif velocity.y > 0:
			_play_animation("walk_down")

	raycast.rotation = -atan2(last_direction.x, last_direction.y)
	if $PlayerRayCast.is_colliding():
		var target = $PlayerRayCast.get_collider()
		
		if target != null and target.has_method("sleep"):
			label.text = "Press E to sleep"
	else:
		label.text = ""
		
