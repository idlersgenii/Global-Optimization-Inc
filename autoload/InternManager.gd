extends Node
## Automation cycle for hired interns.
##
## The manager owns only timing and staff count. It learns about hires from
## SignalBus.intern_hire_state_changed and asks for automatic grinds through
## SignalBus.intern_auto_grind_requested. It never references GameState, so all
## economy mutations remain inside GameState and its persistence.
##
## Every hired intern performs one automatic grind per interval. The timer
## starts when the first intern is hired and stops when the staff is empty.

## Seconds between automatic grind cycles at base speed. Dirty upgrades can
## shorten the effective interval through automation_speed_multiplier.
const INTERN_AUTO_CLICK_INTERVAL_SEC: float = 3.0
## How often the countdown is pushed to the UI, in seconds.
const UI_TICK_SEC: float = 0.2

var _interns_hired: int = 0
var _automation_speed_multiplier: float = 1.0
var _click_timer: Timer
var _ui_timer: Timer


func _ready() -> void:
	_click_timer = Timer.new()
	_click_timer.name = "InternClickTimer"
	_click_timer.wait_time = get_automation_interval()
	_click_timer.one_shot = false
	_click_timer.timeout.connect(_on_click_timer_timeout)
	add_child(_click_timer)

	_ui_timer = Timer.new()
	_ui_timer.name = "InternUiTimer"
	_ui_timer.wait_time = UI_TICK_SEC
	_ui_timer.autostart = true
	_ui_timer.timeout.connect(_emit_automation_tick)
	add_child(_ui_timer)

	SignalBus.intern_hire_state_changed.connect(_on_intern_hire_state_changed)
	SignalBus.automation_speed_changed.connect(_on_automation_speed_changed)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)


## Effective seconds between automatic grinds after dirty-upgrade speed
## multipliers. Base interval divided by the global automation speed.
func get_automation_interval() -> float:
	return INTERN_AUTO_CLICK_INTERVAL_SEC / maxf(_automation_speed_multiplier, 0.01)


## Starts or stops the automation cycle when the staff size changes. Restarting
## the timer here also gives the player a full interval after every hire and
## after loading a save.
func _on_intern_hire_state_changed(interns_hired: int, _hire_cost: float) -> void:
	_interns_hired = maxi(interns_hired, 0)
	if _interns_hired > 0:
		_click_timer.start()
	else:
		_click_timer.stop()
	_emit_automation_tick()


func _on_automation_speed_changed(new_multiplier: float) -> void:
	_automation_speed_multiplier = maxf(new_multiplier, 0.01)
	_click_timer.wait_time = get_automation_interval()
	if _interns_hired > 0:
		_click_timer.start()
	_emit_automation_tick()


func _on_click_timer_timeout() -> void:
	if _interns_hired <= 0:
		_click_timer.stop()
		return

	SignalBus.intern_auto_grind_requested.emit(
		SignalBus.INTERN_ALEXEY_ID,
		_interns_hired
	)
	_emit_automation_tick()


func _emit_automation_tick() -> void:
	var seconds_left := 0.0
	if _interns_hired > 0 and not _click_timer.is_stopped():
		seconds_left = _click_timer.time_left
	SignalBus.intern_automation_tick.emit(
		_interns_hired,
		seconds_left,
		get_automation_interval()
	)


func _on_game_loaded(_slot: StringName) -> void:
	_emit_automation_tick()


func _on_game_reset() -> void:
	_interns_hired = 0
	_click_timer.stop()
	_emit_automation_tick()
