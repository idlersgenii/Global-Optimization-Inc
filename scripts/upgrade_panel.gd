extends PanelContainer
## Dirty-upgrade tree panel.
##
## The panel is data-driven: UpgradeManager exposes the catalog of
## UpgradeData resources, and every purchase card is generated at runtime.
## Clicks are requests on SignalBus; the manager completes the transaction
## and GameState broadcasts the resulting multiplier changes.

const CARD_ICON_SIZE: float = 52.0
const COLOR_EFFECT: Color = Color(0.17, 0.47, 0.23, 1.0)
const COLOR_LOCKED: Color = Color(0.42, 0.46, 0.4, 1.0)

@onready var _list: VBoxContainer = %UpgradeList
@onready var _count: Label = %UpgradeCount
@onready var _footer: Label = %UpgradeFooter
@onready var _status: Label = %UpgradeStatus

var _buttons: Dictionary[StringName, Button] = {}
var _last_purchase_title: String = ""


func _ready() -> void:
	SignalBus.upgrade_tree_changed.connect(_on_tree_changed)
	SignalBus.upgrade_purchased.connect(_on_upgrade_purchased)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)
	SignalBus.coffee_changed.connect(_on_currency_changed)
	SignalBus.pure_logic_changed.connect(_on_currency_changed)
	_rebuild_cards()


# --- Card construction -----------------------------------------------------

func _rebuild_cards() -> void:
	for child in _list.get_children():
		child.free()
	_buttons.clear()

	for data in UpgradeManager.get_catalog():
		_list.add_child(_create_card(data))

	_refresh_summary()
	_refresh_affordability()


func _create_card(data: UpgradeData) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CellPanel"
	panel.tooltip_text = "%s\n\n%s\n\nЭФФЕКТ: %s\nЦЕНА: %s" % [
		data.title,
		data.description,
		data.effect_text,
		data.get_cost_text(),
	]

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 4)
	panel.add_child(layout)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	layout.add_child(header)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(CARD_ICON_SIZE, CARD_ICON_SIZE)
	icon.texture = data.icon
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(icon)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 1)
	header.add_child(title_box)

	var title_label := Label.new()
	title_label.theme_type_variation = &"CellLabel"
	title_label.text = data.title.to_upper()
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_child(title_label)

	var cost_label := Label.new()
	cost_label.theme_type_variation = &"MutedLabel"
	cost_label.add_theme_font_size_override("font_size", 10)
	cost_label.text = "ЦЕНА: %s" % data.get_cost_text()
	title_box.add_child(cost_label)

	var description_label := Label.new()
	description_label.theme_type_variation = &"MutedLabel"
	description_label.add_theme_font_size_override("font_size", 9)
	description_label.text = data.description
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(description_label)

	var effect_label := Label.new()
	effect_label.add_theme_font_size_override("font_size", 9)
	effect_label.add_theme_color_override("font_color", COLOR_EFFECT)
	effect_label.text = "ЭФФЕКТ: %s" % data.effect_text
	effect_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(effect_label)

	var button := Button.new()
	button.custom_minimum_size = Vector2(0.0, 28.0)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_buy_pressed.bind(data.id))
	button.tooltip_text = "Внедрить «%s» за %s" % [
		data.title,
		data.get_cost_text(),
	]
	layout.add_child(button)
	_buttons[data.id] = button

	return panel


# --- State refresh ---------------------------------------------------------

func _refresh_summary() -> void:
	var total := UpgradeManager.get_catalog().size()
	var purchased := 0
	for data in UpgradeManager.get_catalog():
		if UpgradeManager.is_purchased(data.id):
			purchased += 1
	_count.text = "%d / %d" % [purchased, total]
	_footer.text = "ВНЕДРЕНО: %d ИЗ %d" % [purchased, total]
	if _last_purchase_title.is_empty():
		_status.text = "ДОСТУПНО: %d" % (total - purchased)
	else:
		_status.text = "ВНЕДРЕНО: %s" % _last_purchase_title


func _refresh_affordability() -> void:
	for data in UpgradeManager.get_catalog():
		var button: Button = _buttons.get(data.id)
		if button == null:
			continue

		var block_reason := UpgradeManager.get_purchase_block_reason(data)
		button.disabled = not block_reason.is_empty()
		if not block_reason.is_empty():
			button.text = block_reason
			button.add_theme_color_override(
				"font_disabled_color",
				COLOR_EFFECT if UpgradeManager.is_purchased(data.id) else COLOR_LOCKED
			)
		else:
			button.text = "ВНЕДРИТЬ · %s" % data.get_cost_text()
			button.remove_theme_color_override("font_disabled_color")


func _on_buy_pressed(upgrade_id: StringName) -> void:
	SignalBus.upgrade_purchase_requested.emit(upgrade_id)


func _on_currency_changed(_new_amount: float) -> void:
	_refresh_affordability()


func _on_tree_changed() -> void:
	_rebuild_cards()


func _on_game_loaded(_slot: StringName) -> void:
	_last_purchase_title = ""
	_rebuild_cards()


func _on_game_reset() -> void:
	_last_purchase_title = ""
	_rebuild_cards()


func _on_upgrade_purchased(upgrade_id: StringName, _cost: float) -> void:
	var data := UpgradeManager.get_upgrade(upgrade_id)
	if data != null:
		_last_purchase_title = data.title.to_upper()
