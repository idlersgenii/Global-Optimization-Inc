extends PanelContainer
## HR & Assets sidebar.
##
## GameState owns the registry and pushes full snapshots through
## SignalBus.hr_registry_changed. This panel only renders entries and never
## reaches into employee or production systems directly.

const ICON_WORKING: Texture2D = preload("res://assets/icons/hr_status_working.tres")
const ICON_BURNED_OUT: Texture2D = preload("res://assets/icons/hr_status_burned_out.tres")
const ICON_OPTIMIZED: Texture2D = preload("res://assets/icons/hr_status_optimized.tres")

const COLOR_WORKING: Color = Color(0.17, 0.47, 0.23, 1.0)
const COLOR_BURNED_OUT: Color = Color(0.62, 0.38, 0.0, 1.0)
const COLOR_OPTIMIZED: Color = Color(0.60, 0.16, 0.12, 1.0)
const COLOR_UNKNOWN: Color = Color(0.3, 0.35, 0.3, 1.0)

const ROW_HEIGHT: float = 36.0
const STATUS_WIDTH: float = 100.0
const ICON_SIZE: float = 22.0

@onready var _employees_list: VBoxContainer = %EmployeesList
@onready var _server_racks_list: VBoxContainer = %ServerRacksList
@onready var _employees_count: Label = %EmployeesCount
@onready var _server_racks_count: Label = %ServerRacksCount
@onready var _footer_summary: Label = %FooterSummary


func _ready() -> void:
	SignalBus.hr_registry_changed.connect(_on_hr_registry_changed)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)
	_refresh_from_state()


# --- Data ------------------------------------------------------------------

## Startup/load fallback. Normal updates arrive through the bus signal.
func _refresh_from_state() -> void:
	var registry: Dictionary = GameState.get_hr_registry()
	_render(
		registry.get("employees", []),
		registry.get("server_racks", [])
	)


func _on_hr_registry_changed(
	employees: Array[Dictionary], server_racks: Array[Dictionary]
) -> void:
	_render(employees, server_racks)


func _on_game_loaded(_slot: StringName) -> void:
	_refresh_from_state()


func _on_game_reset() -> void:
	_refresh_from_state()


func _render(employees: Array, server_racks: Array) -> void:
	_rebuild_list(_employees_list, employees)
	_rebuild_list(_server_racks_list, server_racks)
	_employees_count.text = str(employees.size())
	_server_racks_count.text = str(server_racks.size())

	var total := employees.size() + server_racks.size()
	var working := (
		_count_status(employees, SignalBus.HRStatus.WORKING)
		+ _count_status(server_racks, SignalBus.HRStatus.WORKING)
	)
	_footer_summary.text = "АКТИВОВ: %d · РАБОТАЮТ: %d" % [total, working]


func _count_status(entries: Array, status: int) -> int:
	var count := 0
	for entry in entries:
		if int((entry as Dictionary).get("status", -1)) == status:
			count += 1
	return count


# --- Row construction ------------------------------------------------------

func _rebuild_list(container: VBoxContainer, entries: Array) -> void:
	for child in container.get_children():
		child.free()

	for index in range(entries.size()):
		var entry: Dictionary = entries[index]
		container.add_child(_create_row(entry, index))


func _create_row(entry: Dictionary, index: int) -> PanelContainer:
	var status := int(entry.get("status", SignalBus.HRStatus.WORKING))
	var name_text := str(entry.get("name", "БЕЗ ИМЕНИ"))
	var detail_text := str(entry.get("detail", ""))

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CellPanelAlt" if index % 2 == 1 else &"CellPanel"
	panel.custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	panel.tooltip_text = "%s\n%s\nСТАТУС: %s" % [
		name_text,
		detail_text,
		_status_label(status),
	]

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.texture = _status_icon(status)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)

	var name_label := Label.new()
	name_label.theme_type_variation = &"CellLabel"
	name_label.text = name_text
	name_label.clip_text = true
	info.add_child(name_label)

	var detail_label := Label.new()
	detail_label.theme_type_variation = &"MutedLabel"
	detail_label.add_theme_font_size_override("font_size", 10)
	detail_label.text = detail_text
	detail_label.clip_text = true
	info.add_child(detail_label)

	var status_label := Label.new()
	status_label.custom_minimum_size = Vector2(STATUS_WIDTH, 0.0)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.add_theme_font_size_override("font_size", 10)
	status_label.add_theme_color_override("font_color", _status_color(status))
	status_label.text = _status_label(status)
	status_label.clip_text = true
	row.add_child(status_label)

	return panel


# --- Status presentation ---------------------------------------------------

func _status_label(status: int) -> String:
	match status:
		SignalBus.HRStatus.WORKING:
			return "РАБОТАЕТ"
		SignalBus.HRStatus.BURNED_OUT:
			return "ВЫГОРЕЛ"
		SignalBus.HRStatus.OPTIMIZED:
			return "ОПТИМИЗИРОВАН"
	return "НЕИЗВЕСТНО"


func _status_icon(status: int) -> Texture2D:
	match status:
		SignalBus.HRStatus.WORKING:
			return ICON_WORKING
		SignalBus.HRStatus.BURNED_OUT:
			return ICON_BURNED_OUT
		SignalBus.HRStatus.OPTIMIZED:
			return ICON_OPTIMIZED
	return ICON_OPTIMIZED


func _status_color(status: int) -> Color:
	match status:
		SignalBus.HRStatus.WORKING:
			return COLOR_WORKING
		SignalBus.HRStatus.BURNED_OUT:
			return COLOR_BURNED_OUT
		SignalBus.HRStatus.OPTIMIZED:
			return COLOR_OPTIMIZED
	return COLOR_UNKNOWN
