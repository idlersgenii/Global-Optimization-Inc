extends PanelContainer
## Fatigue / productivity meter for intern Alexey.
##
## The component owns only presentation and the one-second Timer. Fatigue
## mutations live in GameState and come back through SignalBus, so the UI
## never polls game state directly.

@onready var _fatigue_bar: ProgressBar = %FatigueBar
@onready var _fatigue_percent: Label = %FatiguePercent
@onready var _efficiency_label: Label = %EfficiencyLabel
@onready var _warning_icon: TextureRect = %WarningIcon
@onready var _warning_label: Label = %WarningLabel
@onready var _cheer_button: Button = %CheerButton
@onready var _fatigue_timer: Timer = %FatigueTimer

var _warning_tween: Tween


func _ready() -> void:
	SignalBus.fatigue_changed.connect(_on_fatigue_changed)
	SignalBus.intern_efficiency_changed.connect(_on_efficiency_changed)
	SignalBus.intern_exhausted.connect(_on_intern_exhausted)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)
	_cheer_button.pressed.connect(_on_cheer_pressed)
	_fatigue_timer.timeout.connect(_on_fatigue_timer_timeout)
	_refresh_from_state()


func _on_fatigue_timer_timeout() -> void:
	GameState.add_fatigue(GameState.FATIGUE_PER_TICK)


func _on_cheer_pressed() -> void:
	GameState.cheer_up_intern()


func _on_fatigue_changed(new_value: float) -> void:
	_fatigue_bar.value = new_value
	_fatigue_percent.text = "%d%%" % int(roundf(new_value))
	_apply_warning_state(new_value)


func _on_efficiency_changed(new_efficiency: float) -> void:
	_efficiency_label.text = "ЭФФЕКТИВНОСТЬ: %d%%" % int(roundf(new_efficiency * 100.0))


func _on_intern_exhausted() -> void:
	_start_warning_blink()


func _on_game_loaded(_slot: StringName) -> void:
	_refresh_from_state()


func _on_game_reset() -> void:
	_refresh_from_state()


func _refresh_from_state() -> void:
	_fatigue_bar.value = GameState.intern_fatigue
	_fatigue_percent.text = "%d%%" % int(roundf(GameState.intern_fatigue))
	_efficiency_label.text = "ЭФФЕКТИВНОСТЬ: %d%%" % int(
		roundf(GameState.intern_efficiency * 100.0)
	)
	_apply_warning_state(GameState.intern_fatigue)


func _apply_warning_state(fatigue: float) -> void:
	var exhausted := fatigue >= GameState.FATIGUE_MAX
	_warning_icon.visible = exhausted
	_warning_label.visible = exhausted
	_fatigue_bar.theme_type_variation = &"FatigueBarCritical" if exhausted else &"FatigueBar"
	_cheer_button.disabled = fatigue <= 0.0

	if exhausted:
		_start_warning_blink()
	else:
		_stop_warning_blink()


func _start_warning_blink() -> void:
	if _warning_tween != null and _warning_tween.is_valid():
		return

	_warning_icon.modulate.a = 1.0
	_warning_tween = create_tween().set_loops()
	_warning_tween.tween_property(_warning_icon, "modulate:a", 0.35, 0.45)
	_warning_tween.tween_property(_warning_icon, "modulate:a", 1.0, 0.45)


func _stop_warning_blink() -> void:
	if _warning_tween != null and _warning_tween.is_valid():
		_warning_tween.kill()
	_warning_tween = null
	_warning_icon.modulate.a = 1.0
