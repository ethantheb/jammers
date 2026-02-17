extends Node

func load_dream_scene(scene: PackedScene) -> void:
	assert(scene)
	
	# Clear all children from current scene
	for child in get_tree().current_scene.get_children():
		child.queue_free()
	
	# Instantiate and add the dream scene
	var scene_instance = scene.instantiate()
	get_tree().current_scene.add_child(scene_instance)
	
	# Instantiate and add the player
	var player_scene = load("res://scenes/player.tscn")
	var player_instance = player_scene.instantiate()
	get_tree().current_scene.add_child(player_instance)

func help_me() ->  void:
	get_tree().quit()
