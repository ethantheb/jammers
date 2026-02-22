extends Node2D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	## Set new path from owner to dog
	var player = get_node("AboveFloor/Player")
	player.position_changed.connect(_reset_path)
	pass


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _reset_path(new_position: Vector2) -> void:
	var owner = get_node("AboveFloor/Owner")
	owner.setup_path(new_position)
