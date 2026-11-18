extends PanelContainer
## Fatigue / productivity meter for intern Alexey.
##
## The component owns only presentation and the one-second Timer. Fatigue
## mutations live in GameState and come back through SignalBus, so the UI
## never polls game state directly. Fatigue only grows during the short
## post-click window that GameState opens on every manual grind.
##
## A cheer does not snap fatigue down. It sets an absolute threshold that
## GameState approaches at a fixed percentage-per-second rate; the vertical
## marker on the bar shows that threshold while recovery is running.

const TARGET_MARKER_WIDTH: float = 3.0

@onready var _fatigue_bar: ProgressBar = %FatigueBar
@onready var _target_marker: ColorRect = %TargetMarker
@onready var _fatigue_percent: Label = %FatiguePercent
@onready var _efficiency_label: Label = %EfficiencyLabel
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
	SignalBus.fatigue_recovery_changed.connect(_on_fatigue_recovery_changed)
	SignalBus.coffee_changed.connect(_on_coffee_changed)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)
	_cheer_button.pressed.connect(_on_cheer_pressed)
	_fatigue_timer.timeout.connect(_on_fatigue_timer_timeout)
	_cheer_state_timer.timeout.connect(_on_cheer_state_timeout)
	_fatigue_bar.resized.connect(_update_target_marker)
	_refresh_from_state()


func _on_fatigue_timer_timeout() -> void:
	GameState.tick_fatigue()


func _on_cheer_pressed() -> void:
	GameState.cheer_up_intern()


func _on_cheer_state_timeout() -> void:
	_refresh_cheer_state()
	if (
		GameState.get_cheer_cooldown_remaining() <= 0.0
		and GameState.get_cheer_overuse_remaining() <= 0.0
		and not GameState.is_fatigue_recovering()
	):
		_cheer_state_timer.stop()


func _on_fatigue_changed(new_value: float) -> void:
	_fatigue_bar.value = new_value
	_fatigue_percent.text = "%d%%" % int(roundf(new_value))
	_apply_warning_state(new_value)
	_refresh_cheer_state()


func _on_efficiency_changed(new_efficiency: float) -> void:
	_efficiency_label.text = "ЭФФЕКТИВНОСТЬ: %d%%" % int(roundf(new_efficiency * 100.0))


func _on_intern_exhausted() -> void:
	_start_warning_blink()


func _on_intern_cheered(_recovery: float, _cost: float, _target: float) -> void:
	_cheer_state_timer.start()
	_refresh_cheer_state()


func _on_fatigue_recovery_changed(_target: float, active: bool) -> void:
	_update_target_marker()
	if active:
		_cheer_state_timer.start()
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
	_update_target_marker()
	_refresh_cheer_state()


func _apply_warning_state(fatigue: float) -> void:
	var exhausted := fatigue >= GameState.FATIGUE_MAX
	_warning_icon.visible = exhausted
	_warning_label.visible = exhausted
	_fatigue_bar.theme_type_variation = &"FatigueBarCritical" if exhausted else &"FatigueBar"

	if exhausted:
		_start_warning_blink()
	else:
		_stop_warning_blink()


## Places the threshold marker at the target percentage of the bar width.
## Repositioned on recovery changes and whenever the bar itself is resized.
func _update_target_marker() -> void:
	var active := GameState.is_fatigue_recovering()
	_target_marker.visible = active
	if not active:
		_fatigue_bar.tooltip_text = ""
		return

	var bar_width := _fatigue_bar.size.x
	var bar_height := _fatigue_bar.size.y
	if bar_width <= TARGET_MARKER_WIDTH or bar_height <= 0.0:
		# Layout has not run yet; the bar's `resized` signal will retry.
		_target_marker.visible = false
		return

	var target := GameState.get_fatigue_recovery_target()
	var ratio := clampf(target / maxf(_fatigue_bar.max_value, 1.0), 0.0, 1.0)
	var marker_x := clampf(
		ratio * bar_width - TARGET_MARKER_WIDTH * 0.5,
		0.0,
		bar_width - TARGET_MARKER_WIDTH
	)
	_target_marker.position = Vector2(marker_x, 0.0)
	_target_marker.size = Vector2(TARGET_MARKER_WIDTH, bar_height)
	_fatigue_bar.tooltip_text = (
		"Усталость снижается до %d%% со скоростью %d%%/с"
		% [
			int(roundf(target)),
			int(roundf(GameState.get_fatigue_recovery_rate())),
		]
	)


func _refresh_cheer_state() -> void:
	var cooldown := GameState.get_cheer_cooldown_remaining()
	var cost_value := GameState.get_cheer_cost()
	var cost := int(roundf(cost_value))
	var recovery_min := int(roundf(GameState.CHEER_RECOVERY_MIN))
	var recovery_max := int(roundf(GameState.CHEER_RECOVERY_MAX))
	var recovery_rate := int(roundf(GameState.get_fatigue_recovery_rate()))
	var overuse := GameState.get_cheer_overuse_steps()
	var overuse_left := int(ceilf(GameState.get_cheer_overuse_remaining()))
	var recovery_active := GameState.is_fatigue_recovering()
	var recovery_done := (
		recovery_active and GameState.get_fatigue_recovery_target() <= 0.0
	)
	var recovery_target := int(roundf(GameState.get_fatigue_recovery_target()))
	var recovery_left := int(ceilf(GameState.get_fatigue_recovery_remaining()))

	var extras := ""
	if recovery_active:
		extras += ". Восстановление до %d%%: ещё ~%d с" % [recovery_target, recovery_left]
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
	elif GameState.intern_fatigue <= 0.0:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = "Алексей и так бодр"
	elif recovery_done:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = "Алексей уже восстанавливается до 0%"
	elif GameState.coffee_coins < cost_value:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = "Нужно %d CR — не хватает кофе-койнов%s" % [
			cost, extras
		]
	else:
		_cheer_button.text = "ПОДБОДРИТЬ · %d CR" % cost
		_cheer_button.tooltip_text = (
			"Восстановить %d–%d%% усталости за %d CR. Скорость %d%%/с, перезарядка %d с%s"
			% [
				recovery_min,
				recovery_max,
				cost,
				recovery_rate,
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
