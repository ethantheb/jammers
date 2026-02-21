extends Area2D

# A file because the PackedScene's have hellish race conditions
@export_file("*.tscn") var scene_path: String = ""

func interact(_player: CharacterBody2D) -> void:
	$DoorOpenSound.play()
	$DoorSprite.play("open")
	await $DoorSprite.animation_finished
	if scene_path != "":
		Game.call_deferred("load_dream_scene", load(scene_path))

func interaction_prompt() -> String:
	return "Press E to enter"
