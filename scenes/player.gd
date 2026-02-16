extends CharacterBody2D

const SPEED = 100.0

@onready var shadow = $Shadow
@onready var body = $Body
@onready var head = $Head

func _play_animation(animation: String) -> void:
	shadow.play(animation)
	body.play(animation)
	head.play(animation)

func _physics_process(_delta: float) -> void:
	var direction := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	velocity = direction * SPEED
	move_and_slide()

	if velocity.length() > 0:
		_play_animation("walk_right")
	else:
		_play_animation("idle_fwd")
