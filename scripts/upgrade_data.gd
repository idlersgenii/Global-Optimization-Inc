class_name UpgradeData
extends Resource
## Data-only description of one "dirty" corporate upgrade.
##
## UpgradeManager owns the catalog and translates these resources into
## GameState mutations. UpgradePanel reads the same resources to build its
## purchase cards, so adding a new upgrade is a matter of adding a .tres file.

@export var id: StringName = &""
@export var title: String = ""
@export_multiline var description: String = ""
@export var effect_text: String = ""
@export var icon: Texture2D
@export var coffee_cost: float = 0.0
@export var pure_logic_cost: float = 0.0
## The upgrade becomes visible at this GameScale or later.
@export var required_stage: int = 0

## Global multipliers applied on purchase. A value of 1.0 means "no change";
## UpgradeManager only forwards the entries that actually differ.
@export var production_multiplier_factor: float = 1.0
@export var click_multiplier_factor: float = 1.0
@export var automation_speed_factor: float = 1.0


## Factors for GameState.purchase_upgrade, keyed by the global multiplier name.
func get_effect_factors() -> Dictionary[StringName, float]:
	var factors: Dictionary[StringName, float] = {}
	if not is_equal_approx(production_multiplier_factor, 1.0):
		factors[&"production_multiplier"] = production_multiplier_factor
	if not is_equal_approx(click_multiplier_factor, 1.0):
		factors[&"click_multiplier"] = click_multiplier_factor
	if not is_equal_approx(automation_speed_factor, 1.0):
		factors[&"automation_speed"] = automation_speed_factor
	return factors


## True when the upgrade is gated behind a later visual stage.
func has_stage_requirement() -> bool:
	return required_stage > SignalBus.GameScale.CAFE


## Human-readable price for the UI and the corporate log.
func get_cost_text() -> String:
	var parts: PackedStringArray = []
	if coffee_cost > 0.0:
		parts.append("%s CR" % _format_cost(coffee_cost))
	if pure_logic_cost > 0.0:
		parts.append("%s PL" % _format_cost(pure_logic_cost))
	if parts.is_empty():
		return "БЕСПЛАТНО"
	return " + ".join(parts)


func _format_cost(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return String.num(value, 1)
