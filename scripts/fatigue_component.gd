extends PanelContainer
## Fatigue / productivity meter for intern Alexey.
##
## The component owns only presentation and the one-second Timer. Fatigue
## mutations live in GameState and come back through SignalBus, so the UI
## never polls game state directly. Every manual grind click adds a small flat
## amount of fatigue and opens a short window of extra fatigue ticks; the base
## recovery works continuously once interns are hired, otherwise it returns
## after an idle period. A temporary cheer buff keeps recovering fatigue even
## during active clicking.

@onready var _fatigue_bar: ProgressBar = %FatigueBar
@onready var _fatigue_percent: Label = %FatiguePercent
@onready var _efficiency_label: Label = %EfficiencyLabel
@onready var _recovery_label: Label = %RecoveryLabel
@onready var _warning_icon: TextureRect = %WarningIcon
@onready var _warning_label: Label = %WarningLabel
@onready var _cheer_button: Button = %CheerButton
@onready var _fatigue_timer: Timer = %FatigueTimer
@onready var _cheer_state_timer: Timer = %CheerStateTimer

var _warning_tween: Tween


func _ready() -> void:
	SignalBus.fatigue_changed.connect(_on_fatigue_changed)
	SignalBus.intern_efficiency_changed.connect(_on_efficiency_changed)
	SignalBus.intern_exhausted.connect(_on_intern_exhausted)
	SignalBus.intern_cheered.connect(_on_intern_cheered)
	SignalBus.natural_recovery_changed.connect(_on_natural_recovery_changed)
	SignalBus.coffee_changed.connect(_on_coffee_changed)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)
	_cheer_button.pressed.connect(_on_cheer_pressed)
	_fatigue_timer.timeout.connect(_on_fatigue_timer_timeout)
	_cheer_state_timer.timeout.connect(_on_cheer_state_timeout)
	_refresh_from_state()


func _on_fatigue_timer_timeout() -> void:
	GameState.tick_fatigue()
	_refresh_recovery_state()


func _on_cheer_pressed() -> void:
	GameState.cheer_up_intern()


func _on_cheer_state_timeout() -> void:
	_refresh_cheer_state()
	if (
		GameState.get_cheer_cooldown_remaining() <= 0.0
		and GameState.get_cheer_overuse_remaining() <= 0.0
	):
		_cheer_state_timer.stop()


func _on_fatigue_changed(new_value: float) -> void:
	_fatigue_bar.value = new_value
	_fatigue_percent.text = "%s%%" % String.num(new_value, 1)
	_apply_warning_state(new_value)
	_refresh_cheer_state()


func _on_efficiency_changed(new_efficiency: float) -> void:
	_efficiency_label.text = "ЭФФЕКТИВНОСТЬ: %d%%" % int(roundf(new_efficiency * 100.0))


func _on_intern_exhausted() -> void:
	_start_warning_blink()


func _on_intern_cheered(_boost: float, _cost: float, _buff_rate: float) -> void:
	_cheer_state_timer.start()
	_refresh_cheer_state()
	_refresh_recovery_state()


func _on_natural_recovery_changed(_rate: float, _active: bool) -> void:
	_refresh_recovery_state()


func _on_coffee_changed(_new_amount: float) -> void:
	_refresh_cheer_state()


func _on_game_loaded(_slot: StringName) -> void:
	_refresh_from_state()


func _on_game_reset() -> void:
	_refresh_from_state()


func _refresh_from_state() -> void:
	_fatigue_bar.value = GameState.intern_fatigue
	_fatigue_percent.text = "%s%%" % String.num(GameState.intern_fatigue, 1)
	_efficiency_label.text = "ЭФФЕКТИВНОСТЬ: %d%%" % int(
		roundf(GameState.intern_efficiency * 100.0)
	)
	_apply_warning_state(GameState.intern_fatigue)
	_refresh_recovery_state()


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


## Shows the total passive rate, the remaining cheer-buff time or the idle
## countdown. Updated once per second and when the recovery state changes.
func _refresh_recovery_state() -> void:
	var buff_rate := GameState.get_cheer_buff_rate()
	var buff_left := int(ceilf(GameState.get_cheer_buff_remaining()))
	var buff_active := buff_rate > 0.0
	var base_rate := GameState.get_base_recovery_rate()
	var base_left := int(ceilf(GameState.get_idle_seconds_remaining()))
	var total_rate := GameState.get_natural_recovery_rate()

	var base_text := ""
	if base_rate > 0.0:
		base_text = "Базовое восстановление +%s%%/с" % String.num(base_rate, 1)
	elif base_left > 0:
		base_text = (
			"Базовое восстановление +%s%%/с включится после %d с без ручного помола"
			% [String.num(GameState.NATURAL_RECOVERY_BASE, 1), base_left]
		)

	var buff_text := ""
	if buff_active:
		buff_text = "Бафф «Подбодрить» +%s%%/с, осталось %d с" % [
			String.num(buff_rate, 1), buff_left
		]

	if GameState.intern_fatigue <= 0.0:
		_recovery_label.text = "РЕГЕНЕРАЦИЯ: —"
		_recovery_label.tooltip_text = _join_tooltip(
			["Алексей полностью бодр.", base_text, buff_text]
		)
		return

	if total_rate > 0.0:
		_recovery_label.text = (
			"РЕГЕНЕРАЦИЯ: +%s%%/С" % String.num(total_rate, 1)
		)
		if buff_active:
			_recovery_label.text += " · БАФФ %d С" % buff_left
		_recovery_label.tooltip_text = _join_tooltip([base_text, buff_text])
		return

	_recovery_label.text = "ОТДЫХ ЧЕРЕЗ %d С" % base_left
	_recovery_label.tooltip_text = _join_tooltip([base_text, buff_text])


func _join_tooltip(parts: Array[String]) -> String:
	var filtered := PackedStringArray()
	for part in parts:
		if not part.is_empty():
			filtered.append(part)
	return ". ".join(filtered)


func _refresh_cheer_state() -> void:
	var cooldown := GameState.get_cheer_cooldown_remaining()
	var cost_value := GameState.get_cheer_cost()
	var cost := int(roundf(cost_value))
	var bonus := GameState.CHEER_RECOVERY_BONUS_STEP
	var duration := int(roundf(GameState.CHEER_BUFF_DURATION_SEC))
	var buff_rate := GameState.get_cheer_buff_rate()
	var buff_left := int(ceilf(GameState.get_cheer_buff_remaining()))
	var overuse := GameState.get_cheer_overuse_steps()
	var overuse_left := int(ceilf(GameState.get_cheer_overuse_remaining()))

	var extras := ""
	if buff_rate > 0.0:
		extras += ". Бафф +%s%%/с ещё %d с" % [String.num(buff_rate, 1), buff_left]
	if overuse > 0:
		extras += (
			". Цена повышена за частые перерывы (+%d CR), вернётся через %d с"
			% [cost - int(roundf(GameState.CHEER_BASE_COST)), overuse_left]
		)

	if cooldown > 0.0:
		_cheer_button.text = "ПЕРЕРЫВ: %d С" % int(ceilf(cooldown))
		_cheer_button.tooltip_text = "Алексей отдыхает, осталось %d с%s" % [
			int(ceilf(cooldown)), extras
		]
	elif GameState.coffee_coins < cost_value:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = "Нужно %d CR — не хватает кофе-койнов%s" % [
			cost, extras
		]
	else:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = (
			(
				"Дать бафф +%s%%/с к регенерации на %d с за %d CR. "
				+ "Перезарядка %d с%s"
			)
			% [
				String.num(bonus, 1),
				duration,
				cost,
				int(roundf(GameState.CHEER_COOLDOWN_SEC)),
				extras,
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
