extends PanelContainer
## Fatigue / productivity meter for intern Alexey.
##
## The component owns only presentation and the one-second Timer. Fatigue
## mutations live in GameState and come back through SignalBus, so the UI
## never polls game state directly. Fatigue only grows during the short
## post-click window that GameState opens on every manual grind.

@onready var _fatigue_bar: ProgressBar = %FatigueBar
@onready var _fatigue_percent: Label = %FatiguePercent
@onready var _efficiency_label: Label = %EfficiencyLabel
@onready var _warning_icon: TextureRect = %WarningIcon
@onready var _warning_label: Label = %WarningLabel
@onready var _cheer_button: Button = %CheerButton
@onready var _fatigue_timer: Timer = %FatigueTimer
@onready var _cheer_cooldown_timer: Timer = %CheerCooldownTimer

var _warning_tween: Tween


func _ready() -> void:
	SignalBus.fatigue_changed.connect(_on_fatigue_changed)
	SignalBus.intern_efficiency_changed.connect(_on_efficiency_changed)
	SignalBus.intern_exhausted.connect(_on_intern_exhausted)
	SignalBus.intern_cheered.connect(_on_intern_cheered)
	SignalBus.coffee_changed.connect(_on_coffee_changed)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)
	_cheer_button.pressed.connect(_on_cheer_pressed)
	_fatigue_timer.timeout.connect(_on_fatigue_timer_timeout)
	_cheer_cooldown_timer.timeout.connect(_on_cheer_cooldown_timeout)
	_refresh_from_state()


func _on_fatigue_timer_timeout() -> void:
	GameState.tick_fatigue()


func _on_cheer_pressed() -> void:
	GameState.cheer_up_intern()


func _on_cheer_cooldown_timeout() -> void:
	_refresh_cheer_state()
	if GameState.get_cheer_cooldown_remaining() <= 0.0:
		_cheer_cooldown_timer.stop()


func _on_fatigue_changed(new_value: float) -> void:
	_fatigue_bar.value = new_value
	_fatigue_percent.text = "%d%%" % int(roundf(new_value))
	_apply_warning_state(new_value)
	_refresh_cheer_state()


func _on_efficiency_changed(new_efficiency: float) -> void:
	_efficiency_label.text = "ЭФФЕКТИВНОСТЬ: %d%%" % int(roundf(new_efficiency * 100.0))


func _on_intern_exhausted() -> void:
	_start_warning_blink()


func _on_intern_cheered(_recovery: float) -> void:
	_cheer_cooldown_timer.start()
	_refresh_cheer_state()


func _on_coffee_changed(_new_amount: float) -> void:
	_refresh_cheer_state()


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
	_refresh_cheer_state()

	if exhausted:
		_start_warning_blink()
	else:
		_stop_warning_blink()


func _refresh_cheer_state() -> void:
	var cooldown := GameState.get_cheer_cooldown_remaining()
	var cost := int(roundf(GameState.CHEER_COST))

	if cooldown > 0.0:
		_cheer_button.text = "ПЕРЕРЫВ: %d С" % int(ceilf(cooldown))
		_cheer_button.tooltip_text = "Алексей отдыхает, осталось %d с" % int(ceilf(cooldown))
	elif GameState.intern_fatigue <= 0.0:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = "Алексей и так бодр"
	elif GameState.coffee_coins < GameState.CHEER_COST:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = "Нужно %d CR — не хватает кофе-койнов" % cost
	else:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = (
			"Снять %d%% усталости за %d CR. Перезарядка %d с"
			% [
				int(roundf(GameState.CHEER_RECOVERY)),
				cost,
				int(roundf(GameState.CHEER_COOLDOWN_SEC)),
			]
		)

	_cheer_button.disabled = not GameState.can_cheer()


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
