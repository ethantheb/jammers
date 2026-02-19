extends Area2D

@export var target: PackedScene = null

func sleep(player: CharacterBody2D) -> void:
	var sleep_position: Vector2 = $CollisionShape2D.global_position
	sleep_position.y -= 10
	sleep_position.x += 10
	player.global_position = sleep_position
	player.set_collision_layer_value(1, false)
	player.set_collision_mask_value(1, false)
	player.is_sleeping = true
	if player.dog_mode:
		if target != null:
			Game.call_deferred("load_dream_scene", target, true)
		return
	player.head.play("sleep")
	player.body.stop()
	player.head.animation_finished.connect(_on_sleep_animation_finished.bind(player), CONNECT_ONE_SHOT)

func _on_sleep_animation_finished(_player: CharacterBody2D) -> void:
	if target != null:
		Game.call_deferred("load_dream_scene", target, true)
