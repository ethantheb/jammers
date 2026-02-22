extends CanvasLayer

const HUD_CANVAS_LAYER: int = 120

@onready var score_label: ImpactLabel = $MarginContainer/VBoxContainer/ScoreLabel
@onready var noise_meter: ProgressBar = $MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/NoiseMeter
@onready var piss_meter: ProgressBar = $MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer2/PissMeter
@onready var interaction_prompt_label: Label = $InteractionPrompt

var elapsed_time: float = 0.0
const NOISE_DECAY_RATE: float = 0.3
const RECENT_SOUND_WINDOW: float = 1.0
const BASE_SHAKE_MAGNITUDE: float = 30.0
const IMPACT_LABEL_COOLDOWN: float = 0.5
var time_since_noise: float = 0.0
var shake_timer: float = 0.0
var shake_duration: float = 0.5
var original_bar_position: Vector2
var recent_noises: Array[Vector2] = []
var continuous_noises: Dictionary[String, float] = {}

var max_score_instance: float = 500.0

func _ready() -> void:
	layer = HUD_CANVAS_LAYER
	original_bar_position = noise_meter.position

func _process(delta: float) -> void:
	elapsed_time += delta
	time_since_noise += delta

	_apply_continuous_noise(delta)
	if time_since_noise >= 1.0 and noise_meter.value > 0.0 and continuous_noises.size() == 0:
		noise_meter.value = max(0.0, noise_meter.value - (NOISE_DECAY_RATE * delta))
	
	# Handle shake
	var shake_magnitude = _update_recent_noises()
	if shake_timer > 0:
		shake_timer -= delta
		var shake_strength = (shake_timer / shake_duration) * shake_magnitude
		var shake_offset = Vector2(
			randf_range(-shake_strength, shake_strength),
			randf_range(-shake_strength, shake_strength)
		)
		noise_meter.position = original_bar_position + shake_offset
	else:
		noise_meter.position = original_bar_position

func create_impact_label(screen_position: Vector2, text: String, magnitude: float = 1) -> ImpactLabel:
	var label = ImpactLabel.new()
	label.text = text
	label.position = screen_position
	#label.base_position = screen_position
	label.destroy_on_zero = true
	label.add_impact(magnitude)
	label.z_index = 100
	get_tree().get_root().add_child(label)
	label.global_position = screen_position
	label.destroy_on_zero = true
	label.rise_speed = -50
	label.magnitude_decay_rate = 0.8 # per second
	label.max_shake_magnitude = 3.0
	label.max_scale_magnitude = 1
	return label

func make_one_noise(percent: float) -> void:
	noise_meter.value += percent
	time_since_noise = 0.0
	shake_timer = shake_duration
	_record_noise_magnitude(abs(percent))

func make_continuous_noise(tag: String, value_per_sec: float) -> void:
	if is_zero_approx(value_per_sec):
		continuous_noises.erase(tag)
		return
	continuous_noises[tag] = value_per_sec

func stop_continuous_noise(tag: String) -> void:
	continuous_noises.erase(tag)

func _apply_continuous_noise(delta: float) -> void:
	if continuous_noises.size() == 0:
		return

	var total_rate: float = 0.0
	for value in continuous_noises.values():
		var rate = float(value)
		total_rate += rate
	if not is_zero_approx(total_rate):
		noise_meter.value += total_rate * delta
		shake_timer = shake_duration

func _record_noise_magnitude(magnitude: float) -> void:
	if magnitude <= 0.0:
		return
	recent_noises.append(Vector2(magnitude, elapsed_time))

func _update_recent_noises() -> float:
	var cutoff_time = elapsed_time - RECENT_SOUND_WINDOW
	var max_magnitude: float = 0.0
	var index = 0
	while index < recent_noises.size():
		var entry = recent_noises[index]
		if entry.y < cutoff_time:
			recent_noises.remove_at(index)
			continue
		if entry.x > max_magnitude:
			max_magnitude = entry.x
		index += 1

	for value in continuous_noises.values():
		var rate = abs(float(value))
		if rate > max_magnitude:
			max_magnitude = rate

	return BASE_SHAKE_MAGNITUDE * max_magnitude

func update_pee_remaining(remaining: float) -> void:
	piss_meter.value = remaining

func set_interaction_prompt(text: String, font_size: int = -1) -> void:
	if interaction_prompt_label == null:
		return
	interaction_prompt_label.text = text
	if font_size > 0:
		interaction_prompt_label.add_theme_font_size_override("font_size", font_size)

func update_score(score: float) -> void:
	score_label.text = "Score: " + str(round(score))
	score_label.add_impact(score / max_score_instance)
