extends Area2D

@export var score: float = 50
@export var short_desc: String = "piss target"

var player_inside: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _process(delta: float) -> void:
	if player_inside and Game.player.is_peeing():
		Game.add_score(score)
		HUD.create_impact_label(global_position, "+" + str(score) + "!\nPeed on " + short_desc + "!\nWhat a strange place!")
		queue_free()

func _on_body_entered(body: Node2D) -> void:
	if body.name == "Player":
		player_inside = true

func _on_body_exited(body: Node2D) -> void:
	if body.name == "Player":
		player_inside = false
