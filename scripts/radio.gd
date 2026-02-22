extends Area2D

@onready var jazz: AudioStreamPlayer2D = $Audio

# Called when the node enters the scene tree for the first time.
func interact(_player: CharacterBody2D) -> void:
	if jazz.is_playing():
		jazz.stop()
	else:
		jazz.play()

func interaction_prompt() -> String:
	if jazz.is_playing():
		return "Press E to stop"
	else:
		return "Press E to play"
