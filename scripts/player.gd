extends CharacterBody2D

const SPEED = 100.0
const CHASE_SPEED_BONUS = 30.0

@onready var shadow = get_node_or_null("Shadow")
@onready var body = $Body
@onready var head = $Head
@onready var collision_shape = get_node_or_null("CollisionShape2D")

@onready var raycast = $PlayerRayCast
@onready var label = $PlayerLabel

var last_direction: Vector2
var is_being_chased: bool = false
var slop_slow_factor: float = 1.0

func _play_animation(animation: String) -> void:
	body.play(animation)
	head.play(animation)

func _physics_process(_delta: float) -> void:
	var direction := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	_update_slop_from_puddles()

	var speed = SPEED
	if is_being_chased:
		speed += CHASE_SPEED_BONUS
	velocity = direction * speed * slop_slow_factor
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
