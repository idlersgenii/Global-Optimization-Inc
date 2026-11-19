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
const SAVE_VERSION: int = 3
const DEFAULT_SAVE_SLOT: StringName = &"default"

const FATIGUE_MAX: float = 100.0
const FATIGUE_PER_TICK: float = 1.0
## Flat fatigue added by every manual grind click, on top of the post-click
## fatigue window. Upgrades will raise this value later.
const FATIGUE_PER_CLICK: float = 0.1
## Fatigue only grows for this many one-second ticks after a grind click.
## Re-clicking during the window restarts the countdown instead of stacking it.
const FATIGUE_CLICK_WINDOW_TICKS: int = 5
## Natural fatigue recovery stays at zero while the player works and turns on
## after this many seconds without a manual grind click. Upgrades will shorten
## the wait later.
const NATURAL_RECOVERY_IDLE_SEC: float = 30.0
## Percentage points of fatigue recovered per second while resting. Upgrades
## will raise this value later.
const NATURAL_RECOVERY_BASE: float = 0.5
## "Подбодрить" grants a temporary, stacking regeneration buff: each purchase
## adds CHEER_RECOVERY_BONUS_STEP percentage points per second for
## CHEER_BUFF_DURATION_SEC, and the buff keeps working during manual clicks.
const CHEER_RECOVERY_BONUS_STEP: float = 1.0
const CHEER_BUFF_DURATION_SEC: float = 30.0
const CHEER_BASE_COST: float = 5.0
## Every rapid cheer raises the next price by this step (temporary surcharge).
const CHEER_COST_STEP: float = 5.0
const CHEER_MAX_OVERUSE_STEPS: int = 3
const CHEER_COOLDOWN_SEC: float = 5.0
## Cheers closer than this window count as overuse; the surcharge expires
## after the player lets Alexey rest for this long.
const CHEER_OVERUSE_WINDOW_SEC: float = 20.0
## Efficiency steps as fatigue grows. Each entry is
## (minimum fatigue %, efficiency multiplier); the first matching tier wins.
const EFFICIENCY_TIERS: Array[Vector2] = [
	Vector2(98.0, 0.10),
	Vector2(95.0, 0.25),
	Vector2(90.0, 0.50),
	Vector2(85.0, 0.65),
	Vector2(80.0, 0.85),
]
## First hired intern (autoclicker). Every hire costs
## INTERN_BASE_COST * INTERN_COST_GROWTH^n, where n is the current staff size.
const INTERN_BASE_COST: float = 25.0
const INTERN_COST_GROWTH: float = 1.15

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

## Number of hired interns automating manual grinds.
var interns_hired: int = 0

## Intern Alexey: fatigue fills after clicks; efficiency drops in tiers.
var intern_fatigue: float = 0.0
var intern_efficiency: float = 1.0
## Temporary stacking regeneration buff bought with "Подбодрить".
var _cheer_buff_stacks: int = 0
var _cheer_buff_until_msec: int = 0

## One-second ticks left in the post-click fatigue window.
var _fatigue_window_ticks: int = 0
## Engine time (msec) of the last grind click, manual or automated.
var _last_activity_msec: int = 0
## Cached total-recovery state, used to emit edge-triggered changes.
var _natural_recovery_active: bool = false
var _last_recovery_rate: float = 0.0
## Engine time (msec) when the cheer cooldown expires.
var _cheer_ready_at_msec: int = 0
## Temporary cheer-price surcharge: steps and the time it wears off.
var _cheer_overuse_steps: int = 0
var _cheer_overuse_until_msec: int = 0


func _ready() -> void:
	_last_activity_msec = Time.get_ticks_msec()
	SignalBus.intern_auto_grind_requested.connect(_on_intern_auto_grind_requested)


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
## adds a flat FATIGUE_PER_CLICK fatigue, increments the cup counter and
## broadcasts the result through SignalBus. Returns the reward so the UI can
## show floating feedback.
func grind_coffee() -> float:
	register_activity()
	var reward := maxf(click_multiplier * intern_efficiency, 0.0)
	if reward <= 0.0:
		return 0.0

	coffee_coins += reward
	coffee_cups += 1
	# Each click adds a small flat amount of fatigue and restarts the
	# post-click window; clicks never stack extra window ticks.
	_fatigue_window_ticks = FATIGUE_CLICK_WINDOW_TICKS
	add_fatigue(FATIGUE_PER_CLICK)
	SignalBus.coffee_earned.emit(reward)
	SignalBus.grind_boost_requested.emit(reward)
	SignalBus.coffee_cups_changed.emit(coffee_cups)
	_emit_coffee_changed()
	return reward

# --- Intern hiring and automation ------------------------------------------

## Current price for the next intern: base cost scaled exponentially by the
## number of interns already on staff. Rounded to cents for UI consistency.
func get_intern_hire_cost() -> float:
	var raw_cost := INTERN_BASE_COST * pow(INTERN_COST_GROWTH, interns_hired)
	return roundf(raw_cost * 100.0) / 100.0


## True when the player can afford the next intern.
func can_hire_intern() -> bool:
	return coffee_coins >= get_intern_hire_cost()


## Adds one intern to the staff. Hiring itself is the only thing the UI calls
## directly; the automation cycle is owned by the InternManager autoload.
func hire_intern() -> bool:
	if not can_hire_intern():
		return false

	var cost := get_intern_hire_cost()
	if not spend_coffee(cost):
		return false

	interns_hired += 1
	SignalBus.intern_hire_state_changed.emit(interns_hired, get_intern_hire_cost())
	SignalBus.employee_hired.emit(SignalBus.INTERN_ALEXEY_ID)
	return true


## InternManager only requests grinds through SignalBus; the actual economy
## mutation stays in GameState so every balance change still has one owner.
func _on_intern_auto_grind_requested(employee_id: StringName, count: int) -> void:
	if employee_id != SignalBus.INTERN_ALEXEY_ID or count <= 0:
		return

	var total_reward := 0.0
	for _index in range(count):
		total_reward += grind_coffee()
	if total_reward > 0.0:
		SignalBus.intern_auto_grind_performed.emit(total_reward)

# --- Intern fatigue --------------------------------------------------------

## Per-frame passive recovery. The base portion runs after an idle period
## before the first hire; once interns are on staff it stays on permanently,
## because automation keeps resetting the idle timer. The temporary cheer buff
## keeps recovering fatigue even during active clicking.
func _process(delta: float) -> void:
	_expire_cheer_buff_if_needed()
	var rate := get_natural_recovery_rate()
	var active := rate > 0.0
	if active != _natural_recovery_active or not is_equal_approx(rate, _last_recovery_rate):
		_natural_recovery_active = active
		_last_recovery_rate = rate
		SignalBus.natural_recovery_changed.emit(rate, active)

	if not active:
		return

	intern_fatigue = maxf(intern_fatigue - rate * delta, 0.0)
	SignalBus.fatigue_changed.emit(intern_fatigue)
	_sync_efficiency_with_fatigue()


## Called on every grind click, manual or automated. Activity only pauses the
## base passive recovery; the temporary cheer buff keeps working through labor.
func register_activity() -> void:
	_last_activity_msec = Time.get_ticks_msec()


## Base passive recovery: before the first hire it only starts after
## NATURAL_RECOVERY_IDLE_SEC of rest. Hired interns let Alexey recover
## continuously, since automation would otherwise pause recovery forever.
func get_base_recovery_rate() -> float:
	if intern_fatigue <= 0.0:
		return 0.0
	if interns_hired <= 0 and get_idle_seconds_remaining() > 0.0:
		return 0.0
	return NATURAL_RECOVERY_BASE


## Temporary regeneration from "Подбодрить"; independent of the idle timer.
func get_cheer_buff_rate() -> float:
	if _cheer_buff_stacks <= 0 or get_cheer_buff_remaining() <= 0.0:
		return 0.0
	return float(_cheer_buff_stacks) * CHEER_RECOVERY_BONUS_STEP


## Total passive recovery: base plus the temporary cheer buff.
func get_natural_recovery_rate() -> float:
	if intern_fatigue <= 0.0:
		return 0.0
	return get_base_recovery_rate() + get_cheer_buff_rate()


## True while any passive recovery is running, base or cheer buff.
func is_natural_recovery_active() -> bool:
	return get_natural_recovery_rate() > 0.0


## Seconds since the last manual grind click.
func get_idle_seconds() -> float:
	return maxf(float(Time.get_ticks_msec() - _last_activity_msec) / 1000.0, 0.0)


## Seconds left before the base passive recovery turns on.
func get_idle_seconds_remaining() -> float:
	return maxf(NATURAL_RECOVERY_IDLE_SEC - get_idle_seconds(), 0.0)


## Seconds left on the temporary "Подбодрить" buff.
func get_cheer_buff_remaining() -> float:
	var remaining_msec := _cheer_buff_until_msec - Time.get_ticks_msec()
	return maxf(float(remaining_msec) / 1000.0, 0.0)


## Active stacks of the temporary "Подбодрить" buff.
func get_cheer_buff_stacks() -> int:
	return _cheer_buff_stacks if get_cheer_buff_remaining() > 0.0 else 0


## Clears expired stacks so the UI and saves never see a dead buff.
func _expire_cheer_buff_if_needed() -> void:
	if _cheer_buff_stacks > 0 and get_cheer_buff_remaining() <= 0.0:
		_cheer_buff_stacks = 0
		_cheer_buff_until_msec = 0


## Advances Alexey's fatigue. Crossing 100 % fires a one-shot exhaustion event
## for UI feedback; the efficiency penalty changes earlier, at fatigue tiers.
func add_fatigue(amount: float) -> void:
	if amount <= 0.0:
		return

	var was_exhausted := intern_fatigue >= FATIGUE_MAX
	intern_fatigue = clampf(intern_fatigue + amount, 0.0, FATIGUE_MAX)
	SignalBus.fatigue_changed.emit(intern_fatigue)
	_sync_efficiency_with_fatigue()
	if not was_exhausted and intern_fatigue >= FATIGUE_MAX:
		SignalBus.intern_exhausted.emit()


## Efficiency multiplier for the given fatigue. Tiers make the intern slower
## in steps instead of applying a single penalty at 100 %.
func get_efficiency_for_fatigue(fatigue: float) -> float:
	for tier in EFFICIENCY_TIERS:
		if fatigue >= tier.x:
			return tier.y
	return 1.0


## Keeps the tiered efficiency penalty in sync with the current fatigue.
func _sync_efficiency_with_fatigue() -> void:
	var next_efficiency := get_efficiency_for_fatigue(intern_fatigue)
	if is_equal_approx(intern_efficiency, next_efficiency):
		return

	intern_efficiency = next_efficiency
	SignalBus.intern_efficiency_changed.emit(intern_efficiency)


## Called once per second by the fatigue UI timer. Window fatigue only grows
## while a post-click window is active, so an idle player never gets tired.
## The flat per-click fatigue is applied immediately in grind_coffee().
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


## True when the player can pay the current price and the cooldown has
## expired. Cheering is allowed even at 0 % fatigue so the temporary buff can
## be prepared ahead of time.
func can_cheer() -> bool:
	return (
		coffee_coins >= get_cheer_cost()
		and get_cheer_cooldown_remaining() <= 0.0
	)


## Manual intervention: "Подбодрить" spends coffee coins and grants a temporary
## stacking +CHEER_RECOVERY_BONUS_STEP %/s regeneration buff for
## CHEER_BUFF_DURATION_SEC. The buff survives manual clicks; only the base
## idle recovery is paused by activity. Cheering again too soon raises the next
## price for a while. Returns true on success.
func cheer_up_intern() -> bool:
	if not can_cheer():
		return false

	var now_msec := Time.get_ticks_msec()
	var cost := get_cheer_cost()
	_cheer_buff_stacks += 1
	_cheer_buff_until_msec = now_msec + int(roundf(CHEER_BUFF_DURATION_SEC * 1000.0))
	# Starting a break also stops the current click-fatigue burst, so the bar
	# visibly turns around instead of ticking up for a few more seconds.
	_fatigue_window_ticks = 0
	_cheer_ready_at_msec = now_msec + int(roundf(CHEER_COOLDOWN_SEC * 1000.0))
	_cheer_overuse_steps = mini(get_cheer_overuse_steps() + 1, CHEER_MAX_OVERUSE_STEPS)
	_cheer_overuse_until_msec = now_msec + int(roundf(CHEER_OVERUSE_WINDOW_SEC * 1000.0))
	spend_coffee(cost)

	var rate := get_natural_recovery_rate()
	_natural_recovery_active = rate > 0.0
	_last_recovery_rate = rate
	if rate > 0.0:
		SignalBus.natural_recovery_changed.emit(rate, true)
	SignalBus.intern_cheered.emit(
		CHEER_RECOVERY_BONUS_STEP,
		cost,
		get_cheer_buff_rate()
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
		"cheer_buff_stacks": _cheer_buff_stacks,
		"cheer_buff_remaining_sec": get_cheer_buff_remaining(),
		"interns_hired": interns_hired,
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
	intern_efficiency = get_efficiency_for_fatigue(intern_fatigue)
	_cheer_buff_stacks = 0
	_cheer_buff_until_msec = 0
	if loaded_version >= 2:
		_cheer_buff_stacks = maxi(int(data.get("cheer_buff_stacks", 0)), 0)
		var buff_remaining := maxf(
			float(data.get("cheer_buff_remaining_sec", 0.0)), 0.0
		)
		if _cheer_buff_stacks > 0 and buff_remaining > 0.0:
			_cheer_buff_until_msec = (
				Time.get_ticks_msec() + int(roundf(buff_remaining * 1000.0))
			)
		else:
			_cheer_buff_stacks = 0
	else:
		# Older saves stored a permanent bonus; convert it into a fresh
		# temporary buff so existing progress is not lost.
		_cheer_buff_stacks = maxi(
			int(roundf(float(data.get("natural_recovery_bonus", 0.0)))), 0
		)
		if _cheer_buff_stacks > 0:
			_cheer_buff_until_msec = (
				Time.get_ticks_msec()
				+ int(roundf(CHEER_BUFF_DURATION_SEC * 1000.0))
			)
	_fatigue_window_ticks = 0
	_last_activity_msec = Time.get_ticks_msec()
	_natural_recovery_active = false
	_last_recovery_rate = 0.0
	_cheer_ready_at_msec = 0
	_cheer_overuse_steps = 0
	_cheer_overuse_until_msec = 0
	interns_hired = maxi(int(data.get("interns_hired", 0)), 0)
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
	_cheer_buff_stacks = 0
	_cheer_buff_until_msec = 0
	_fatigue_window_ticks = 0
	_last_activity_msec = Time.get_ticks_msec()
	_natural_recovery_active = false
	_last_recovery_rate = 0.0
	_cheer_ready_at_msec = 0
	_cheer_overuse_steps = 0
	_cheer_overuse_until_msec = 0
	interns_hired = 0
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
	_last_recovery_rate = get_natural_recovery_rate()
	_natural_recovery_active = _last_recovery_rate > 0.0
	SignalBus.natural_recovery_changed.emit(
		_last_recovery_rate,
		_natural_recovery_active
	)
	SignalBus.intern_hire_state_changed.emit(interns_hired, get_intern_hire_cost())
	SignalBus.scale_changed.emit(current_stage)
