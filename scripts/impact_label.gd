class_name ImpactLabel
extends Label

var magnitude: float = 0.0
@export var magnitude_decay_rate: float = 0.5 # per second
@export var max_shake_magnitude: float = 10.0
@export var max_scale_magnitude: float = 2.0

@export var rise_speed: float = -30.0 # pixels per second
var curr_rise_offset: float = 0.0

var destroy_on_zero: bool = false

var base_position: Vector2
var recent_impacts: Array[Vector2] = []

func _ready() -> void:
	base_position = position

func _process(delta: float) -> void:
	magnitude -= magnitude_decay_rate * delta
	magnitude = max(0.0, magnitude)

	if destroy_on_zero and is_zero_approx(magnitude):
		queue_free()
		return

	var shake_strength = pow(magnitude, 2) * max_shake_magnitude
	var shake_offset = Vector2(
		randf_range(-shake_strength, shake_strength),
		randf_range(-shake_strength, shake_strength)
	)

	curr_rise_offset += rise_speed * delta
	position = base_position + shake_offset + Vector2(0, curr_rise_offset)

	var scale_strength = pow(magnitude, 2) * max_scale_magnitude
	scale = Vector2(1, 1) + Vector2(scale_strength, scale_strength)

func add_impact(impact: float) -> void:
	magnitude += impact
	magnitude = clamp(magnitude, 0, 1)
