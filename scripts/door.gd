extends StaticBody2D

# A file because the PackedScene's have hellish race conditions
@export_file("*.tscn") var scene_path: String = ""
@export var spawn_location: Vector2 = Vector2.ZERO

func interact(_player: CharacterBody2D) -> void:
	$DoorOpenSound.play()
	$DoorSprite.play("open")
	await $DoorSprite.animation_finished
	if scene_path != "":
		Game.call_deferred("load_dream_scene", load(scene_path), false, spawn_location)

func interaction_prompt() -> String:
	return "Press E to enter"
