extends Node
## Catalog and transaction controller for the dirty-upgrade tree.
##
## UpgradePanel emits SignalBus.upgrade_purchase_requested. This manager
## validates the request against its UpgradeData catalog, then asks GameState
## to perform the atomic purchase. GameState remains the single owner of
## currency, global multipliers and persistence, and broadcasts every
## multiplier change through SignalBus.

const CATALOG_PATHS: Array[String] = [
	"res://resources/upgrades/uranium_chairs.tres",
	"res://resources/upgrades/no_blinking_neuro_patch.tres",
]

var _catalog: Array[UpgradeData] = []
var _by_id: Dictionary[StringName, UpgradeData] = {}


func _ready() -> void:
	_load_catalog()
	SignalBus.upgrade_purchase_requested.connect(_on_upgrade_purchase_requested)


func _load_catalog() -> void:
	for path in CATALOG_PATHS:
		var resource := load(path)
		if resource is UpgradeData:
			var data: UpgradeData = resource
			_catalog.append(data)
			_by_id[data.id] = data
		else:
			push_error("UpgradeManager: '%s' is not an UpgradeData resource." % path)


# --- Catalog queries -------------------------------------------------------

func get_catalog() -> Array[UpgradeData]:
	return _catalog


func get_upgrade(upgrade_id: StringName) -> UpgradeData:
	return _by_id.get(upgrade_id) as UpgradeData


func is_purchased(upgrade_id: StringName) -> bool:
	return GameState.has_upgrade(upgrade_id)


func is_unlocked(data: UpgradeData) -> bool:
	return GameState.current_stage >= data.required_stage


func can_afford(data: UpgradeData) -> bool:
	return (
		GameState.coffee_coins >= data.coffee_cost
		and GameState.pure_logic_points >= data.pure_logic_cost
	)


## Empty when the card can be purchased; otherwise the reason shown on its
## disabled button.
func get_purchase_block_reason(data: UpgradeData) -> String:
	if is_purchased(data.id):
		return "ВНЕДРЕНО"
	if not is_unlocked(data):
		return "ЗАБЛОКИРОВАНО"
	if not can_afford(data):
		return "НУЖНО %s" % data.get_cost_text()
	return ""


# --- Purchases -------------------------------------------------------------

func _on_upgrade_purchase_requested(upgrade_id: StringName) -> void:
	var data := get_upgrade(upgrade_id)
	if data == null:
		push_warning("UpgradeManager: unknown upgrade '%s'." % upgrade_id)
		return
	if is_purchased(upgrade_id):
		return
	if not is_unlocked(data):
		SignalBus.log_message_received.emit(
			"R&D: «%s» ЗАБЛОКИРОВАН. НУЖНА СТАДИЯ ВЫШЕ." % data.title.to_upper()
		)
		return
	if not can_afford(data):
		SignalBus.log_message_received.emit(
			"R&D: «%s» ОТКЛОНЁН. НУЖНО %s."
			% [data.title.to_upper(), data.get_cost_text()]
		)
		return

	var effects := data.get_effect_factors()
	if not GameState.purchase_upgrade(
		upgrade_id, data.coffee_cost, data.pure_logic_cost, effects
	):
		SignalBus.log_message_received.emit(
			"R&D: СДЕЛКА ПО «%s» НЕ ПРОШЛА." % data.title.to_upper()
		)
		return

	SignalBus.log_message_received.emit(
		"R&D: «%s» ВНЕДРЁН. %s"
		% [data.title.to_upper(), data.effect_text.to_upper()]
	)
	SignalBus.notification_requested.emit(
		"ГРЯЗНЫЙ АПГРЕЙД",
		"%s\n%s" % [data.title, data.effect_text],
		SignalBus.HRSeverity.INFO
	)
