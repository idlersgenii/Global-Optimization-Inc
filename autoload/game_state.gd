extends Node
## Global autoload that owns the current run state and its persistence.
##
## Registered in Project Settings > Autoload as `GameState`.
## Every balance mutation goes through this node, so SignalBus observers
## (UI, audio, achievements) receive one typed event stream.
##
## The script deliberately does not auto-load on startup. The main scene
## decides whether to call `load_game()` when `has_save()` is true.

const SAVE_PATH: String = "user://savegame.json"
const SAVE_VERSION: int = 1
const DEFAULT_SAVE_SLOT: StringName = &"default"

const FATIGUE_MAX: float = 100.0
const FATIGUE_PER_TICK: float = 1.0
## Fatigue only grows for this many one-second ticks after a grind click.
## Re-clicking during the window restarts the countdown instead of stacking it.
const FATIGUE_CLICK_WINDOW_TICKS: int = 5
## Cheer recovery is rolled in this range; upgrades will widen it later.
const CHEER_RECOVERY_MIN: float = 10.0
const CHEER_RECOVERY_MAX: float = 30.0
## Recovery speed in percentage points per second. The time to reach the target
## is (current fatigue - target) / rate, so clicks during recovery extend it.
const CHEER_RECOVERY_RATE: float = 5.0
const CHEER_BASE_COST: float = 5.0
## Every rapid cheer raises the next price by this step (temporary surcharge).
const CHEER_COST_STEP: float = 5.0
const CHEER_MAX_OVERUSE_STEPS: int = 3
const CHEER_COOLDOWN_SEC: float = 5.0
## Cheers closer than this window count as overuse; the surcharge expires
## after the player lets Alexey rest for this long.
const CHEER_OVERUSE_WINDOW_SEC: float = 20.0
const EXHAUSTED_EFFICIENCY: float = 0.5

## Fiat credits, called "coffee coins" in the game.
var coffee_coins: float = 0.0
## Cups brewed by manual clicks, shown on the dashboard counter.
var coffee_cups: int = 0
var pure_logic_points: float = 0.0
var metaverse_shares: float = 0.0

## Global production multipliers applied by upgrades and HR events.
var production_multiplier: float = 1.0
var click_multiplier: float = 1.0

## One of the values in SignalBus.GameScale.
var current_stage: int = SignalBus.GameScale.CAFE

## Intern Alexey: fatigue fills after clicks; at 100 % his efficiency halves.
var intern_fatigue: float = 0.0
var intern_efficiency: float = 1.0

## One-second ticks left in the post-click fatigue window.
var _fatigue_window_ticks: int = 0
## Gradual cheer recovery: fatigue moves toward this threshold while active.
var _fatigue_recovery_target: float = 0.0
var _fatigue_recovery_active: bool = false
## Engine time (msec) when the cheer cooldown expires.
var _cheer_ready_at_msec: int = 0
## Temporary cheer-price surcharge: steps and the time it wears off.
var _cheer_overuse_steps: int = 0
var _cheer_overuse_until_msec: int = 0

# --- Coffee coins ----------------------------------------------------------

func add_coffee(amount: float) -> void:
	if amount <= 0.0:
		return
	coffee_coins += amount
	SignalBus.coffee_earned.emit(amount)
	_emit_coffee_changed()


func spend_coffee(amount: float) -> bool:
	if amount < 0.0:
		push_warning("GameState.spend_coffee: negative amount %.2f ignored." % amount)
		return false
	if coffee_coins < amount:
		return false
	coffee_coins -= amount
	SignalBus.coffee_spent.emit(amount)
	_emit_coffee_changed()
	return true


func set_coffee(amount: float) -> void:
	var clamped := maxf(amount, 0.0)
	if is_equal_approx(coffee_coins, clamped):
		return
	coffee_coins = clamped
	_emit_coffee_changed()


func _emit_coffee_changed() -> void:
	SignalBus.coffee_changed.emit(coffee_coins)
	SignalBus.currency_changed.emit(&"coffee", coffee_coins)


# --- Manual grind ----------------------------------------------------------

## Brews one cup on a manual click: credits `click_multiplier` coffee coins,
## increments the cup counter and broadcasts the result through SignalBus.
## Returns the reward so the UI can show floating feedback.
func grind_coffee() -> float:
	var reward := maxf(click_multiplier * intern_efficiency, 0.0)
	if reward <= 0.0:
		return 0.0

	coffee_coins += reward
	coffee_cups += 1
	# Each click restarts the fatigue window; clicks never stack extra ticks.
	_fatigue_window_ticks = FATIGUE_CLICK_WINDOW_TICKS
	SignalBus.coffee_earned.emit(reward)
	SignalBus.grind_boost_requested.emit(reward)
	SignalBus.coffee_cups_changed.emit(coffee_cups)
	_emit_coffee_changed()
	return reward

# --- Intern fatigue --------------------------------------------------------

## Per-frame driver for gradual cheer recovery. Recovery is rate-based, so a
## larger gap to the target simply takes longer; click-driven fatigue ticks
## keep running in parallel and are reflected in the bar immediately.
func _process(delta: float) -> void:
	if not _fatigue_recovery_active:
		return

	if intern_fatigue > _fatigue_recovery_target:
		intern_fatigue = maxf(
			intern_fatigue - CHEER_RECOVERY_RATE * delta,
			_fatigue_recovery_target
		)
		_sync_efficiency_with_fatigue()
		SignalBus.fatigue_changed.emit(intern_fatigue)

	if intern_fatigue <= _fatigue_recovery_target:
		_finish_fatigue_recovery()


## Keeps the exhaustion penalty in sync with the current fatigue. Efficiency
## also recovers gradually: it flips back to 100 % as soon as the bar drops
## below the maximum.
func _sync_efficiency_with_fatigue() -> void:
	var exhausted := intern_fatigue >= FATIGUE_MAX
	var next_efficiency := EXHAUSTED_EFFICIENCY if exhausted else 1.0
	if is_equal_approx(intern_efficiency, next_efficiency):
		return

	intern_efficiency = next_efficiency
	SignalBus.intern_efficiency_changed.emit(intern_efficiency)
	if exhausted:
		SignalBus.intern_exhausted.emit()


## Stops the recovery loop and tells the UI to hide the target marker.
func _finish_fatigue_recovery() -> void:
	_fatigue_recovery_active = false
	_fatigue_recovery_target = 0.0
	SignalBus.fatigue_recovery_changed.emit(0.0, false)
	SignalBus.fatigue_recovery_finished.emit()


## Advances Alexey's fatigue. Crossing 100 % halves his efficiency and fires
## a one-shot exhaustion event for UI feedback.
func add_fatigue(amount: float) -> void:
	if amount <= 0.0:
		return

	intern_fatigue = clampf(intern_fatigue + amount, 0.0, FATIGUE_MAX)
	SignalBus.fatigue_changed.emit(intern_fatigue)
	_sync_efficiency_with_fatigue()


## Called once per second by the fatigue UI timer. Fatigue only grows while
## a post-click window is active, so an idle player never gets tired.
func tick_fatigue() -> void:
	if _fatigue_window_ticks <= 0:
		return

	_fatigue_window_ticks -= 1
	add_fatigue(FATIGUE_PER_TICK)


## True while a cheer is gradually pulling fatigue down to its target.
func is_fatigue_recovering() -> bool:
	return _fatigue_recovery_active


## Absolute fatigue threshold the active recovery is moving toward.
func get_fatigue_recovery_target() -> float:
	return _fatigue_recovery_target


## Recovery speed in percentage points per second.
func get_fatigue_recovery_rate() -> float:
	return CHEER_RECOVERY_RATE


## Estimated seconds until the current target is reached. Recovery is
## rate-based, so this is (fatigue - target) / rate and grows whenever the
## player keeps clicking and adding fatigue during recovery.
func get_fatigue_recovery_remaining() -> float:
	if not _fatigue_recovery_active:
		return 0.0
	return maxf(intern_fatigue - _fatigue_recovery_target, 0.0) / CHEER_RECOVERY_RATE


## How many seconds remain before "Подбодрить" can be used again.
func get_cheer_cooldown_remaining() -> float:
	var remaining_msec := _cheer_ready_at_msec - Time.get_ticks_msec()
	return maxf(float(remaining_msec) / 1000.0, 0.0)


## How many seconds the temporary cheer-price surcharge is still active.
func get_cheer_overuse_remaining() -> float:
	var remaining_msec := _cheer_overuse_until_msec - Time.get_ticks_msec()
	return maxf(float(remaining_msec) / 1000.0, 0.0)


## Active surcharge steps; drops to zero once Alexey has rested long enough.
func get_cheer_overuse_steps() -> int:
	return _cheer_overuse_steps if get_cheer_overuse_remaining() > 0.0 else 0


## Current price: base plus a temporary surcharge for rapid repeat cheers.
func get_cheer_cost() -> float:
	return CHEER_BASE_COST + float(get_cheer_overuse_steps()) * CHEER_COST_STEP


## True when Alexey is tired, the player can pay the current price, the
## cooldown has expired and another cheer can still lower the threshold.
func can_cheer() -> bool:
	return (
		intern_fatigue > 0.0
		and not (_fatigue_recovery_active and _fatigue_recovery_target <= 0.0)
		and coffee_coins >= get_cheer_cost()
		and get_cheer_cooldown_remaining() <= 0.0
	)


## Manual intervention: "Подбодрить" spends coffee coins and sets a new
## fatigue threshold. The bar then slides down to it at CHEER_RECOVERY_RATE,
## so the duration follows the distance to the target instead of a fixed
## timer. A second cheer during recovery may only lower the threshold.
## Starts the cooldown and the overuse surcharge. Returns true on success.
func cheer_up_intern() -> bool:
	if not can_cheer():
		return false

	var now_msec := Time.get_ticks_msec()
	var cost := get_cheer_cost()
	var rolled_recovery := float(randi_range(
		int(roundf(CHEER_RECOVERY_MIN)), int(roundf(CHEER_RECOVERY_MAX))
	))
	var new_target := maxf(intern_fatigue - rolled_recovery, 0.0)
	if _fatigue_recovery_active:
		new_target = minf(_fatigue_recovery_target, new_target)

	_fatigue_recovery_target = new_target
	_fatigue_recovery_active = true
	_cheer_ready_at_msec = now_msec + int(roundf(CHEER_COOLDOWN_SEC * 1000.0))
	_cheer_overuse_steps = mini(get_cheer_overuse_steps() + 1, CHEER_MAX_OVERUSE_STEPS)
	_cheer_overuse_until_msec = now_msec + int(roundf(CHEER_OVERUSE_WINDOW_SEC * 1000.0))
	spend_coffee(cost)

	SignalBus.intern_cheered.emit(rolled_recovery, cost, new_target)
	SignalBus.fatigue_recovery_changed.emit(new_target, true)
	return true

# --- Pure logic points -----------------------------------------------------

func add_pure_logic(amount: float) -> void:
	if amount <= 0.0:
		return
	pure_logic_points += amount
	_emit_pure_logic_changed()


func spend_pure_logic(amount: float) -> bool:
	if amount < 0.0:
		push_warning("GameState.spend_pure_logic: negative amount %.2f ignored." % amount)
		return false
	if pure_logic_points < amount:
		return false
	pure_logic_points -= amount
	_emit_pure_logic_changed()
	return true


func set_pure_logic(amount: float) -> void:
	var clamped := maxf(amount, 0.0)
	if is_equal_approx(pure_logic_points, clamped):
		return
	pure_logic_points = clamped
	_emit_pure_logic_changed()


func _emit_pure_logic_changed() -> void:
	SignalBus.pure_logic_changed.emit(pure_logic_points)
	SignalBus.currency_changed.emit(&"pure_logic", pure_logic_points)

# --- Metaverse shares ------------------------------------------------------

func add_metaverse_shares(amount: float) -> void:
	if amount <= 0.0:
		return
	metaverse_shares += amount
	_emit_metaverse_shares_changed()


func set_metaverse_shares(amount: float) -> void:
	var clamped := maxf(amount, 0.0)
	if is_equal_approx(metaverse_shares, clamped):
		return
	metaverse_shares = clamped
	_emit_metaverse_shares_changed()


func _emit_metaverse_shares_changed() -> void:
	SignalBus.metaverse_shares_changed.emit(metaverse_shares)
	SignalBus.currency_changed.emit(&"metaverse_shares", metaverse_shares)

# --- Production multipliers ------------------------------------------------

func set_production_multiplier(value: float) -> void:
	var clamped := maxf(value, 0.0)
	if is_equal_approx(production_multiplier, clamped):
		return
	production_multiplier = clamped
	SignalBus.production_multiplier_changed.emit(production_multiplier)


func set_click_multiplier(value: float) -> void:
	var clamped := maxf(value, 0.0)
	if is_equal_approx(click_multiplier, clamped):
		return
	click_multiplier = clamped
	SignalBus.click_multiplier_changed.emit(click_multiplier)

# --- Simulation stage ------------------------------------------------------

func set_stage(new_stage: int) -> void:
	var clamped := clampi(
		new_stage,
		SignalBus.GameScale.CAFE,
		SignalBus.GameScale.SINGULARITY
	)
	if clamped == current_stage:
		return

	var previous_stage := current_stage
	current_stage = clamped
	SignalBus.scale_changed.emit(current_stage)

	if current_stage > previous_stage:
		SignalBus.scope_creep_triggered.emit(current_stage)

# --- Save / load -----------------------------------------------------------

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func save_game() -> Error:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		push_error(
			"GameState.save_game: could not open '%s' for writing (error %d)."
			% [SAVE_PATH, open_error]
		)
		return open_error

	file.store_string(JSON.stringify(to_dict(), "\t"))
	file.close()

	SignalBus.game_saved.emit(DEFAULT_SAVE_SLOT)
	return OK


func load_game() -> Error:
	if not FileAccess.file_exists(SAVE_PATH):
		push_warning("GameState.load_game: save file '%s' does not exist." % SAVE_PATH)
		return ERR_FILE_NOT_FOUND

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		var open_error := FileAccess.get_open_error()
		push_error(
			"GameState.load_game: could not open '%s' for reading (error %d)."
			% [SAVE_PATH, open_error]
		)
		return open_error

	var json_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_error := json.parse(json_text)
	if parse_error != OK:
		push_error(
			"GameState.load_game: JSON parse failed at line %d: %s"
			% [json.get_error_line(), json.get_error_message()]
		)
		return parse_error

	if not json.data is Dictionary:
		push_error("GameState.load_game: save root is not a Dictionary.")
		return ERR_INVALID_DATA

	_deserialize(json.data as Dictionary)
	SignalBus.game_loaded.emit(DEFAULT_SAVE_SLOT)
	return OK

# --- Serialization ---------------------------------------------------------

func to_dict() -> Dictionary[String, Variant]:
	return {
		"version": SAVE_VERSION,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"coffee_coins": coffee_coins,
		"coffee_cups": coffee_cups,
		"pure_logic_points": pure_logic_points,
		"metaverse_shares": metaverse_shares,
		"production_multiplier": production_multiplier,
		"click_multiplier": click_multiplier,
		"intern_fatigue": intern_fatigue,
		"intern_efficiency": intern_efficiency,
		"current_stage": current_stage,
	}


func _deserialize(data: Dictionary) -> void:
	var loaded_version := int(data.get("version", 0))
	if loaded_version > SAVE_VERSION:
		push_warning(
			"GameState: save version %d is newer than supported version %d."
			% [loaded_version, SAVE_VERSION]
		)

	coffee_coins = maxf(float(data.get("coffee_coins", 0.0)), 0.0)
	coffee_cups = maxi(int(data.get("coffee_cups", 0)), 0)
	pure_logic_points = maxf(float(data.get("pure_logic_points", 0.0)), 0.0)
	metaverse_shares = maxf(float(data.get("metaverse_shares", 0.0)), 0.0)
	production_multiplier = maxf(float(data.get("production_multiplier", 1.0)), 0.0)
	click_multiplier = maxf(float(data.get("click_multiplier", 1.0)), 0.0)
	intern_fatigue = clampf(float(data.get("intern_fatigue", 0.0)), 0.0, FATIGUE_MAX)
	intern_efficiency = EXHAUSTED_EFFICIENCY if intern_fatigue >= FATIGUE_MAX else 1.0
	_fatigue_window_ticks = 0
	_fatigue_recovery_target = 0.0
	_fatigue_recovery_active = false
	_cheer_ready_at_msec = 0
	_cheer_overuse_steps = 0
	_cheer_overuse_until_msec = 0
	current_stage = clampi(
		int(data.get("current_stage", SignalBus.GameScale.CAFE)),
		SignalBus.GameScale.CAFE,
		SignalBus.GameScale.SINGULARITY
	)

	_emit_all_changes()

# --- Reset -----------------------------------------------------------------

func reset_state() -> void:
	coffee_coins = 0.0
	coffee_cups = 0
	pure_logic_points = 0.0
	metaverse_shares = 0.0
	production_multiplier = 1.0
	click_multiplier = 1.0
	intern_fatigue = 0.0
	intern_efficiency = 1.0
	_fatigue_window_ticks = 0
	_fatigue_recovery_target = 0.0
	_fatigue_recovery_active = false
	_cheer_ready_at_msec = 0
	_cheer_overuse_steps = 0
	_cheer_overuse_until_msec = 0
	current_stage = SignalBus.GameScale.CAFE

	_emit_all_changes()
	SignalBus.game_reset.emit()


func _emit_all_changes() -> void:
	_emit_coffee_changed()
	SignalBus.coffee_cups_changed.emit(coffee_cups)
	_emit_pure_logic_changed()
	_emit_metaverse_shares_changed()
	SignalBus.production_multiplier_changed.emit(production_multiplier)
	SignalBus.click_multiplier_changed.emit(click_multiplier)
	SignalBus.fatigue_changed.emit(intern_fatigue)
	SignalBus.intern_efficiency_changed.emit(intern_efficiency)
	SignalBus.fatigue_recovery_changed.emit(
		_fatigue_recovery_target,
		_fatigue_recovery_active
	)
	SignalBus.scale_changed.emit(current_stage)
