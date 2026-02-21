class_name ImpactLabel
extends Label

var magnitude: float = 0.0
@export var magnitude_decay_rate: float = 0.5 # per second
@export var max_shake_magnitude: float = 10.0
@export var max_scale_magnitude: float = 2.0

var base_position: Vector2
var recent_impacts: Array[Vector2] = []

func _ready() -> void:
	base_position = position

func _process(_delta: float) -> void:
	magnitude -= magnitude_decay_rate * get_process_delta_time()
	magnitude = max(0.0, magnitude)

	var shake_strength = pow(magnitude, 2) * max_shake_magnitude
	var shake_offset = Vector2(
		randf_range(-shake_strength, shake_strength),
		randf_range(-shake_strength, shake_strength)
	)
	position = base_position + shake_offset

	var scale_strength = pow(magnitude, 2) * max_scale_magnitude
	scale = Vector2(1, 1) + Vector2(scale_strength, scale_strength)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		add_impact(0.2)

func add_impact(impact: float) -> void:
	magnitude += impact
	magnitude = clamp(magnitude, 0, 1)
