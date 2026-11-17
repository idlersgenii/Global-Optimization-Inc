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
	var reward := maxf(click_multiplier, 0.0)
	if reward <= 0.0:
		return 0.0

	coffee_coins += reward
	coffee_cups += 1
	SignalBus.coffee_earned.emit(reward)
	SignalBus.grind_boost_requested.emit(reward)
	SignalBus.coffee_cups_changed.emit(coffee_cups)
	_emit_coffee_changed()
	return reward

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
	SignalBus.scale_changed.emit(current_stage)
