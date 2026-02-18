extends Node

func load_dream_scene(scene: PackedScene) -> void:
	assert(scene)
	
	# Clear all children from current scene
	for child in get_tree().current_scene.get_children():
		child.queue_free()
	
	# Instantiate and add the dream scene
	var scene_instance = scene.instantiate()
	get_tree().current_scene.add_child(scene_instance)
	
	# Position player at SpawnPoint if one exists, or spawn one if the scene doesn't have one
	var spawn = scene_instance.find_child("SpawnPoint")
	var existing_player = scene_instance.find_child("Player")
	if existing_player:
		if spawn:
			existing_player.global_position = spawn.global_position
	else:
		var player_scene = load("res://scenes/player.tscn")
		var player_instance = player_scene.instantiate()
		get_tree().current_scene.add_child(player_instance)
		if spawn:
			player_instance.global_position = spawn.global_position

func help_me() ->  void:
	get_tree().quit()
