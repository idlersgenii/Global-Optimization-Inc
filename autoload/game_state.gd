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
## Natural fatigue recovery stays at zero while the player works and turns on
## after this many seconds without a manual grind click. Upgrades will shorten
## the wait later.
const NATURAL_RECOVERY_IDLE_SEC: float = 30.0
## Percentage points of fatigue recovered per second while resting. The cheer
## button permanently raises this rate; upgrades will raise both values later.
const NATURAL_RECOVERY_BASE: float = 0.5
const CHEER_RECOVERY_BONUS_STEP: float = 1.0
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
## Extra percentage points per second added to natural recovery by cheering.
var natural_recovery_bonus: float = 0.0

## One-second ticks left in the post-click fatigue window.
var _fatigue_window_ticks: int = 0
## Engine time (msec) of the last manual grind click.
var _last_activity_msec: int = 0
## Cached natural-recovery state, used to emit edge-triggered changes.
var _natural_recovery_active: bool = false
## Engine time (msec) when the cheer cooldown expires.
var _cheer_ready_at_msec: int = 0
## Temporary cheer-price surcharge: steps and the time it wears off.
var _cheer_overuse_steps: int = 0
var _cheer_overuse_until_msec: int = 0


func _ready() -> void:
	_last_activity_msec = Time.get_ticks_msec()


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
	register_activity()
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

## Per-frame passive recovery. It only runs after NATURAL_RECOVERY_IDLE_SEC
## without manual work; any grind click drops the current rate back to zero.
func _process(delta: float) -> void:
	var active := is_natural_recovery_active()
	if active != _natural_recovery_active:
		_natural_recovery_active = active
		SignalBus.natural_recovery_changed.emit(get_natural_recovery_rate(), active)

	if not active:
		return

	intern_fatigue = maxf(
		intern_fatigue - get_natural_recovery_rate() * delta,
		0.0
	)
	SignalBus.fatigue_changed.emit(intern_fatigue)
	_sync_efficiency_with_fatigue()


## Called on every manual grind click. Any activity resets natural recovery
## to zero and restarts the full idle wait.
func register_activity() -> void:
	_last_activity_msec = Time.get_ticks_msec()
	if _natural_recovery_active:
		_natural_recovery_active = false
		SignalBus.natural_recovery_changed.emit(0.0, false)


## True while Alexey is tired and has been left alone long enough.
func is_natural_recovery_active() -> bool:
	return intern_fatigue > 0.0 and get_idle_seconds_remaining() <= 0.0


## Current recovery rate in percentage points per second; zero while working
## or before the idle threshold is reached.
func get_natural_recovery_rate() -> float:
	if not is_natural_recovery_active():
		return 0.0
	return get_natural_recovery_potential_rate()


## Rate that applies once the idle wait is over: base plus cheer bonuses.
func get_natural_recovery_potential_rate() -> float:
	return NATURAL_RECOVERY_BASE + natural_recovery_bonus


## Seconds since the last manual grind click.
func get_idle_seconds() -> float:
	return maxf(float(Time.get_ticks_msec() - _last_activity_msec) / 1000.0, 0.0)


## Seconds left before natural recovery turns on.
func get_idle_seconds_remaining() -> float:
	return maxf(NATURAL_RECOVERY_IDLE_SEC - get_idle_seconds(), 0.0)


## Advances Alexey's fatigue. Crossing 100 % halves his efficiency and fires
## a one-shot exhaustion event for UI feedback.
func add_fatigue(amount: float) -> void:
	if amount <= 0.0:
		return

	intern_fatigue = clampf(intern_fatigue + amount, 0.0, FATIGUE_MAX)
	SignalBus.fatigue_changed.emit(intern_fatigue)
	_sync_efficiency_with_fatigue()


## Keeps the exhaustion penalty in sync with the current fatigue. Efficiency
## returns to 100 % as soon as natural recovery drops the bar below maximum.
func _sync_efficiency_with_fatigue() -> void:
	var exhausted := intern_fatigue >= FATIGUE_MAX
	var next_efficiency := EXHAUSTED_EFFICIENCY if exhausted else 1.0
	if is_equal_approx(intern_efficiency, next_efficiency):
		return

	intern_efficiency = next_efficiency
	SignalBus.intern_efficiency_changed.emit(intern_efficiency)
	if exhausted:
		SignalBus.intern_exhausted.emit()


## Called once per second by the fatigue UI timer. Fatigue only grows while
## a post-click window is active, so an idle player never gets tired.
func tick_fatigue() -> void:
	if _fatigue_window_ticks <= 0:
		return

	_fatigue_window_ticks -= 1
	add_fatigue(FATIGUE_PER_TICK)


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


## True when Alexey is tired, the player can pay the current price and the
## cooldown has expired.
func can_cheer() -> bool:
	return (
		intern_fatigue > 0.0
		and coffee_coins >= get_cheer_cost()
		and get_cheer_cooldown_remaining() <= 0.0
	)


## Manual intervention: "Подбодрить" spends coffee coins and permanently
## raises natural recovery by CHEER_RECOVERY_BONUS_STEP. Cheering again too
## soon raises the next price for a while. Returns true on success.
func cheer_up_intern() -> bool:
	if not can_cheer():
		return false

	var now_msec := Time.get_ticks_msec()
	var cost := get_cheer_cost()
	natural_recovery_bonus += CHEER_RECOVERY_BONUS_STEP
	_cheer_ready_at_msec = now_msec + int(roundf(CHEER_COOLDOWN_SEC * 1000.0))
	_cheer_overuse_steps = mini(get_cheer_overuse_steps() + 1, CHEER_MAX_OVERUSE_STEPS)
	_cheer_overuse_until_msec = now_msec + int(roundf(CHEER_OVERUSE_WINDOW_SEC * 1000.0))
	spend_coffee(cost)

	var recovery_active := is_natural_recovery_active()
	_natural_recovery_active = recovery_active
	SignalBus.natural_recovery_changed.emit(
		get_natural_recovery_rate(),
		recovery_active
	)
	SignalBus.intern_cheered.emit(
		CHEER_RECOVERY_BONUS_STEP,
		cost,
		get_natural_recovery_potential_rate()
	)
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
		"natural_recovery_bonus": natural_recovery_bonus,
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
	natural_recovery_bonus = maxf(float(data.get("natural_recovery_bonus", 0.0)), 0.0)
	_fatigue_window_ticks = 0
	_last_activity_msec = Time.get_ticks_msec()
	_natural_recovery_active = false
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
	natural_recovery_bonus = 0.0
	_fatigue_window_ticks = 0
	_last_activity_msec = Time.get_ticks_msec()
	_natural_recovery_active = false
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
	_natural_recovery_active = is_natural_recovery_active()
	SignalBus.natural_recovery_changed.emit(
		get_natural_recovery_rate(),
		_natural_recovery_active
	)
	SignalBus.scale_changed.emit(current_stage)
