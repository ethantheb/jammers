extends Area2D

@export var spin_speed_deg = 360

@export var hover_ampl = 5

@export var hover_freq_sec = 1

@export var target: PackedScene = null
@export_file("*.tscn") var target_path: String = ""

var init_pos = null
var lifetime = 0.0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	init_pos = global_position
	body_entered.connect(_on_body_entered)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	lifetime += delta
	rotate(deg_to_rad(spin_speed_deg) * delta)

	# Calculate hover offset based on lifetime and hover frequency
	var hover_offset = sin(PI * 2 * lifetime / hover_freq_sec) * hover_ampl
	global_position = init_pos + Vector2(0, hover_offset)


func _on_body_entered(body: Node2D) -> void:
	if body.name == "Player":
		var scene = target
		if scene == null and target_path != "":
			scene = load(target_path)
		Game.call_deferred("load_dream_scene", scene)
