extends Sprite2D

@onready var fire_light: PointLight2D = $Fire/FireLight
@onready var fire_sound: AudioStreamPlayer2D = $Fire/FireCracklingSound
@onready var fire_out_sound: AudioStreamPlayer2D = $Fire/FireExtinguishSound

@export var base_energy: float = 0.5
@export var flicker_speed: float = 40.0
@export var flicker_amt: float = 0.025


func _kill_fire() -> void:
	fire_light.enabled = false
	fire_sound.stop()

	fire_out_sound.play()
	var tween = create_tween()
	tween.tween_property(fire_out_sound, "volume_db", -50.0, 1.0)
	await tween.finished

	($Fire.material as ShaderMaterial).set_shader_parameter("particleCount", 0)
	($Fire.material as ShaderMaterial).set_shader_parameter("smokeCount", 10.0)
	($Fire.material as ShaderMaterial).set_shader_parameter("sparkCount", 0.0)
	await get_tree().create_timer(3.0).timeout
	($Fire.material as ShaderMaterial).set_shader_parameter("alpha", 0.0)


func _process(_delta: float) -> void:
	if fire_light.enabled:
		fire_light.energy = base_energy + sin(Time.get_ticks_msec() * 0.001 * flicker_speed) * flicker_amt

	if fire_light.enabled and not is_instance_valid($PissTarget):
		_kill_fire()
