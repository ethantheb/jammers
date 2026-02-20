extends CanvasLayer

@onready var timer_label = $MarginContainer/VBoxContainer/TimerLabel
@onready var progress_bar: ProgressBar = $MarginContainer/VBoxContainer/ProgressBar

var elapsed_time: float = 0.0
const NOISE_DECAY_RATE: float = 0.3
const RECENT_SOUND_WINDOW: float = 1.0
const BASE_SHAKE_MAGNITUDE: float = 30.0
var time_since_noise: float = 0.0
var shake_timer: float = 0.0
var shake_duration: float = 0.5
var original_bar_position: Vector2
var recent_noises: Array[Vector2] = []
var continuous_noises: Dictionary[String, float] = {}

func _ready() -> void:
	original_bar_position = progress_bar.position

func _process(delta: float) -> void:
	elapsed_time += delta
	time_since_noise += delta
	update_timer_display()
	_apply_continuous_noise(delta)
	if time_since_noise >= 1.0 and progress_bar.value > 0.0:
		progress_bar.value = max(0.0, progress_bar.value - (NOISE_DECAY_RATE * delta))
	
	# Handle shake
	var shake_magnitude = _update_recent_noises()
	if shake_timer > 0:
		shake_timer -= delta
		var shake_strength = (shake_timer / shake_duration) * shake_magnitude
		var shake_offset = Vector2(
			randf_range(-shake_strength, shake_strength),
			randf_range(-shake_strength, shake_strength)
		)
		progress_bar.position = original_bar_position + shake_offset
	else:
		progress_bar.position = original_bar_position

func update_timer_display() -> void:
	var total_seconds = int(elapsed_time)
	var minutes = total_seconds / 60 as int
	var seconds = total_seconds % 60
	timer_label.text = "Time: %d:%02d" % [minutes, seconds]

func make_one_noise(percent: float) -> void:
	progress_bar.value += percent
	if continuous_noises.size() == 0:
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
		progress_bar.value += total_rate * delta
		print(progress_bar.value)
		time_since_noise = 0.0
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

func reset_timer() -> void:
	elapsed_time = 0.0
	update_timer_display()
