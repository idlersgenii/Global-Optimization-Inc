extends Node
## Central audio routing for the cafe.
##
## Other systems never create AudioStreamPlayer nodes. They request a short
## sound by string key through SignalBus.sound_requested, while GameState
## reports completed coffee sales through SignalBus.coffee_sold. The manager
## owns the UI/Ambient buses, the player nodes and the looping cooler hum.

const UI_BUS: StringName = &"UI"
const AMBIENT_BUS: StringName = &"Ambient"
## Linear bus volumes, applied through AudioServer on startup.
const DEFAULT_UI_VOLUME: float = 0.75
const DEFAULT_AMBIENT_VOLUME: float = 0.35
## The save sample is a long typing recording; keep only a short burst.
const SAVE_SOUND_BURST_SEC: float = 1.0
const SAVE_SOUND_MAX_OFFSET_SEC: float = 4.5

## Every key resolves to one or more stream variants. A random variant is
## picked on playback so repeated clicks do not sound mechanical.
const SOUND_LIBRARY: Dictionary[StringName, Array] = {
	&"cash_register": [
		preload("res://assets/audio/cash_register_1.wav"),
		preload("res://assets/audio/cash_register_2.wav"),
		preload("res://assets/audio/cash_register_3.wav"),
	],
	&"keyboard_click": [
		preload("res://assets/audio/keyboard_click1.wav"),
		preload("res://assets/audio/keyboard_click2.wav"),
		preload("res://assets/audio/keyboard_click3.wav"),
		preload("res://assets/audio/keyboard_click4.wav"),
	],
	&"keyboard_save": [
		preload("res://assets/audio/keyboard_longclicks1.wav"),
	],
}

const AMBIENT_STREAM: AudioStreamOggVorbis = preload("res://assets/audio/cooler_hum.ogg")

var _sfx_players: Dictionary[StringName, AudioStreamPlayer] = {}
var _ambient_player: AudioStreamPlayer
var _save_stop_timer: Timer


func _ready() -> void:
	_ensure_bus(UI_BUS)
	_ensure_bus(AMBIENT_BUS)
	set_ui_volume(DEFAULT_UI_VOLUME)
	set_ambient_volume(DEFAULT_AMBIENT_VOLUME)
	_create_save_stop_timer()
	_start_ambient()

	SignalBus.sound_requested.connect(_on_sound_requested)
	SignalBus.coffee_sold.connect(_on_coffee_sold)


## Plays a registered SFX by string key. Returns false for unknown keys.
func play_sound(sound_key: StringName) -> bool:
	var variants: Array = SOUND_LIBRARY.get(sound_key, [])
	if variants.is_empty():
		push_warning("AudioManager: unknown sound key '%s'." % sound_key)
		return false

	var player := _get_sfx_player(sound_key)
	player.stream = variants[randi_range(0, variants.size() - 1)] as AudioStream
	player.pitch_scale = (
		randf_range(0.94, 1.06) if sound_key == &"keyboard_click" else 1.0
	)

	if sound_key == &"keyboard_save":
		# Start somewhere inside the long recording and cut the burst short.
		var max_offset := maxf(
			minf(
				player.stream.get_length() - SAVE_SOUND_BURST_SEC,
				SAVE_SOUND_MAX_OFFSET_SEC
			),
			0.0
		)
		player.play(randf_range(0.0, max_offset))
		_save_stop_timer.start(SAVE_SOUND_BURST_SEC)
	else:
		player.play()
	return true


## Sets a bus volume using linear 0..1 values; the conversion to dB and the
## actual mixer mutation happen through AudioServer.
func set_bus_volume(bus_name: StringName, linear_volume: float) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		push_warning("AudioManager: bus '%s' does not exist." % bus_name)
		return

	var clamped := clampf(linear_volume, 0.0, 1.0)
	AudioServer.set_bus_mute(bus_index, clamped <= 0.0)
	AudioServer.set_bus_volume_db(bus_index, linear_to_db(maxf(clamped, 0.001)))


## Returns the current linear volume of a bus, or 0.0 when it is muted.
func get_bus_volume(bus_name: StringName) -> float:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0 or AudioServer.is_bus_mute(bus_index):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(bus_index))


func set_ui_volume(linear_volume: float) -> void:
	set_bus_volume(UI_BUS, linear_volume)


func set_ambient_volume(linear_volume: float) -> void:
	set_bus_volume(AMBIENT_BUS, linear_volume)


## Adds a named bus routed to Master when the layout does not contain it yet.
func _ensure_bus(bus_name: StringName) -> int:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index >= 0:
		return bus_index

	bus_index = AudioServer.bus_count
	AudioServer.add_bus(bus_index)
	AudioServer.set_bus_name(bus_index, bus_name)
	AudioServer.set_bus_send(bus_index, &"Master")
	return bus_index


func _get_sfx_player(sound_key: StringName) -> AudioStreamPlayer:
	if _sfx_players.has(sound_key):
		return _sfx_players[sound_key] as AudioStreamPlayer

	var player := AudioStreamPlayer.new()
	player.name = "Sfx_%s" % sound_key
	player.bus = UI_BUS
	add_child(player)
	_sfx_players[sound_key] = player
	return player


func _start_ambient() -> void:
	var ambient_stream := AMBIENT_STREAM.duplicate() as AudioStreamOggVorbis
	ambient_stream.loop = true
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.name = "AmbientPlayer"
	_ambient_player.bus = AMBIENT_BUS
	_ambient_player.stream = ambient_stream
	add_child(_ambient_player)
	_ambient_player.play()


func _create_save_stop_timer() -> void:
	_save_stop_timer = Timer.new()
	_save_stop_timer.name = "SaveSoundStopTimer"
	_save_stop_timer.one_shot = true
	_save_stop_timer.timeout.connect(_stop_save_sound)
	add_child(_save_stop_timer)


func _stop_save_sound() -> void:
	var player := _sfx_players.get(&"keyboard_save") as AudioStreamPlayer
	if player != null:
		player.stop()


func _on_sound_requested(sound_key: StringName) -> void:
	play_sound(sound_key)


func _on_coffee_sold(_amount: float) -> void:
	play_sound(&"cash_register")
