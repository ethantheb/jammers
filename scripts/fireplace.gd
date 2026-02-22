extends Sprite2D

@onready var fire_light: PointLight2D = $Fire/FireLight

@export var base_energy: float = 0.5
@export var flicker_speed: float = 40.0
@export var flicker_amt: float = 0.025

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	fire_light.energy = base_energy + sin(Time.get_ticks_msec() * 0.001 * flicker_speed) * flicker_amt
