extends Control
## Main dashboard styled as a legacy spreadsheet application.
##
## The sheet is generated at runtime so the data grid can grow without a
## scene full of duplicated nodes. Live balances are pushed by GameState
## through SignalBus; decorative rows exist only to sell the spreadsheet look.

const WINDOW_MARGIN: int = 24
const ROW_COUNT: int = 19
const COLUMN_COUNT: int = 6
const ROW_HEADER_WIDTH: float = 40.0
const CELL_HEIGHT: float = 26.0
const CELL_WIDTHS: Array[float] = [170.0, 150.0, 74.0, 96.0, 70.0, 70.0]
const TICKER_LIMIT: int = 4

const CELL_COFFEE: Vector2i = Vector2i(1, 2)
const CELL_LOGIC: Vector2i = Vector2i(1, 3)
const CELL_MULTIPLIER: Vector2i = Vector2i(1, 4)
const CELL_CLICK: Vector2i = Vector2i(1, 5)
const CELL_STAGE: Vector2i = Vector2i(1, 6)

const STAGE_NAMES: Dictionary[int, String] = {
	SignalBus.GameScale.CAFE: "ПРИДОРОЖНОЕ КАФЕ",
	SignalBus.GameScale.CORPORATION: "КОРПОРАТИВНЫЙ СПРУТ",
	SignalBus.GameScale.SPACE_AUDIT: "КОСМИЧЕСКИЙ АУДИТ",
	SignalBus.GameScale.SINGULARITY: "СИНГУЛЯРНОСТЬ",
}

const STAGE_SHORT_NAMES: Dictionary[int, String] = {
	SignalBus.GameScale.CAFE: "КАФЕ",
	SignalBus.GameScale.CORPORATION: "КОРПОРАЦИЯ",
	SignalBus.GameScale.SPACE_AUDIT: "КОСМОС",
	SignalBus.GameScale.SINGULARITY: "СИНГУЛЯРНОСТЬ",
}

@onready var _sheet_grid: GridContainer = %SheetGrid
@onready var _coffee_value: Label = %CoffeeValue
@onready var _logic_value: Label = %LogicValue
@onready var _multiplier_value: Label = %MultiplierValue
@onready var _click_value: Label = %ClickValue
@onready var _stage_value: Label = %StageValue
@onready var _morale_bar: ProgressBar = %MoraleBar
@onready var _morale_percent: Label = %MoralePercent
@onready var _oxygen_bar: ProgressBar = %OxygenBar
@onready var _oxygen_percent: Label = %OxygenPercent
@onready var _grind_hint: Label = %GrindHint
@onready var _ticker_label: Label = %TickerLabel
@onready var _status_message: Label = %StatusMessageLabel
@onready var _save_status: Label = %SaveStatusLabel
@onready var _stage_status: Label = %StageStatusLabel
@onready var _clock_label: Label = %ClockLabel
@onready var _window_margin: MarginContainer = $WindowMargin

var _cells: Dictionary[Vector2i, Label] = {}
var _ticker_messages: Array[String] = []
var _maximized: bool = false
var _last_stage: int = SignalBus.GameScale.CAFE


func _ready() -> void:
	_build_sheet()
	_seed_ticker()
	_connect_signals()
	_connect_controls()
	_refresh_all()
	_update_clock()
	_set_status("ИНИЦИАЛИЗАЦИЯ АУДИТА...")
	_last_stage = GameState.current_stage

	if GameState.has_save():
		var error := GameState.load_game()
		if error == OK:
			_set_status("СЕССИЯ ВОССТАНОВЛЕНА ИЗ АРХИВА")
			_push_ticker("СЕЙВ ЗАГРУЖЕН: user://savegame.json")
		else:
			_set_status("ОШИБКА ЗАГРУЗКИ: %d" % error)
			_push_ticker("НЕ УДАЛОСЬ ЗАГРУЗИТЬ АРХИВ")
	else:
		_set_status("НОВАЯ СМЕНА. СОХРАНЕНИЙ НЕ НАЙДЕНО.")
		_push_ticker("СМЕНА №001 ОТКРЫТА. СТАЖЁР АЛЕКСЕЙ НА МЕСТЕ.")


func _connect_signals() -> void:
	SignalBus.coffee_changed.connect(_on_balance_changed)
	SignalBus.pure_logic_changed.connect(_on_balance_changed)
	SignalBus.production_multiplier_changed.connect(_on_multiplier_changed)
	SignalBus.click_multiplier_changed.connect(_on_multiplier_changed)
	SignalBus.scale_changed.connect(_on_stage_changed)
	SignalBus.game_saved.connect(_on_game_saved)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)


func _connect_controls() -> void:
	%SaveButton.pressed.connect(_on_save_pressed)
	%LoadButton.pressed.connect(_on_load_pressed)
	%GrindButton.pressed.connect(_on_grind_pressed)
	%MinimizeButton.pressed.connect(_on_minimize_pressed)
	%MaximizeButton.pressed.connect(_on_maximize_pressed)
	%CloseButton.pressed.connect(_on_close_pressed)
	$ClockTimer.timeout.connect(_update_clock)

	for child in %MenuLayout.get_children():
		if child is Button:
			var button: Button = child as Button
			button.pressed.connect(_on_menu_pressed.bind(button.text))


# --- Sheet construction ----------------------------------------------------

func _build_sheet() -> void:
	for child in _sheet_grid.get_children():
		child.free()
	_cells.clear()

	_add_header_cell(0, "№", ROW_HEADER_WIDTH)
	for column in range(COLUMN_COUNT):
		var letter := String.chr(65 + column)
		_add_header_cell(column + 1, letter, CELL_WIDTHS[column])

	for row in range(1, ROW_COUNT + 1):
		_add_row_header(row)
		for column in range(COLUMN_COUNT):
			_add_data_cell(column, row)

	_populate_sheet()


func _add_header_cell(column: int, text: String, width: float) -> void:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(width, CELL_HEIGHT)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.theme_type_variation = &"HeaderPanel"

	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HeaderLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cell.add_child(label)
	_sheet_grid.add_child(cell)


func _add_row_header(row: int) -> void:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(ROW_HEADER_WIDTH, CELL_HEIGHT)
	cell.theme_type_variation = &"RowHeaderPanel"

	var label := Label.new()
	label.text = str(row)
	label.theme_type_variation = &"RowHeaderLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cell.add_child(label)
	_sheet_grid.add_child(cell)


func _add_data_cell(column: int, row: int) -> void:
	var variation: StringName = &"CellPanel" if row % 2 == 0 else &"CellPanelAlt"
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(CELL_WIDTHS[column], CELL_HEIGHT)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.theme_type_variation = variation

	var label := Label.new()
	label.theme_type_variation = &"CellLabel"
	label.clip_text = true
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cell.add_child(label)
	_sheet_grid.add_child(cell)
	_cells[Vector2i(column, row)] = label


func _populate_sheet() -> void:
	var rows: Array[PackedStringArray] = [
		PackedStringArray(["ПОКАЗАТЕЛЬ", "ЗНАЧЕНИЕ", "ЕД.", "СТАТУС", "ТРЕНД", "КОД"]),
		PackedStringArray(["КОФЕ-КОЙНЫ", "0.00", "CR", "OK", "▲", "B02"]),
		PackedStringArray(["ЧИСТАЯ ЛОГИКА", "0.00", "PL", "OK", "—", "B03"]),
		PackedStringArray(["МНОЖИТЕЛЬ ПРОИЗВ.", "×1.00", "x", "OK", "—", "B04"]),
		PackedStringArray(["СИЛА КЛИКА", "1.00", "CR", "OK", "—", "B05"]),
		PackedStringArray(["СТАДИЯ", "ПРИДОРОЖНОЕ КАФЕ", "", "OK", "", "B06"]),
		PackedStringArray(["СТАЖЁР", "АЛЕКСЕЙ", "", "РАБОТАЕТ", "", "B07"]),
		PackedStringArray(["ПЕРЕРЫВ", "НЕ ПОЛОЖЕН", "", "OK", "", "B08"]),
		PackedStringArray(["КОФЕИН В КРОВИ", "0.21", "‰", "НИЗКО", "", "B09"]),
		PackedStringArray(["ПЛАН ОПТИМИЗАЦИИ", "=B2/10000", "%", "В РАБОТЕ", "", "B10"]),
		PackedStringArray(["ЗАТРАТЫ НА СМЕНУ", "100.00", "CR", "OK", "", "B11"]),
		PackedStringArray(["ИТОГО ПО ЛИСТУ", "=B11-B2", "CR", "OK", "", "B12"]),
		PackedStringArray(["ЖУРНАЛ", "=СУММ(B2:B12)", "", "OK", "", "B13"]),
		PackedStringArray(["СТАТУС", "ОПТИМИЗАЦИЯ", "", "АКТИВНА", "", "B14"]),
	]

	for row_index in range(rows.size()):
		var row: PackedStringArray = rows[row_index]
		for column in range(COLUMN_COUNT):
			_set_cell(column, row_index + 1, row[column])


func _set_cell(column: int, row: int, text: String) -> void:
	var label: Label = _get_cell_label(column, row)
	label.text = text
	label.theme_type_variation = &"FormulaLabel" if text.begins_with("=") else &"CellLabel"


func _update_cell(cell: Vector2i, text: String) -> void:
	_get_cell_label(cell.x, cell.y).text = text


func _get_cell_label(column: int, row: int) -> Label:
	return _cells[Vector2i(column, row)]


# --- Live data -------------------------------------------------------------

func _refresh_all() -> void:
	_coffee_value.text = _format_number(GameState.coffee_coins)
	_logic_value.text = _format_number(GameState.pure_logic_points)
	_multiplier_value.text = "×%.2f" % GameState.production_multiplier
	_click_value.text = _format_number(GameState.click_multiplier)
	_stage_value.text = _stage_short_name(GameState.current_stage)

	_grind_hint.text = "НАГРАДА: %s CR ЗА КЛИК" % _format_number(GameState.click_multiplier)
	_save_status.text = "СЕЙВ: %s" % ("ЕСТЬ" if GameState.has_save() else "НЕТ")
	_stage_status.text = "СТАДИЯ: %s" % _stage_short_name(GameState.current_stage)

	_update_cell(CELL_COFFEE, _format_number(GameState.coffee_coins))
	_update_cell(CELL_LOGIC, _format_number(GameState.pure_logic_points))
	_update_cell(CELL_MULTIPLIER, "×%.2f" % GameState.production_multiplier)
	_update_cell(CELL_CLICK, _format_number(GameState.click_multiplier))
	_update_cell(CELL_STAGE, _stage_name(GameState.current_stage))

	_morale_bar.value = 78.0
	_morale_percent.text = "78%"
	_oxygen_bar.value = 21.0
	_oxygen_percent.text = "21.0%"


func _on_balance_changed(_new_amount: float) -> void:
	_refresh_all()


func _on_multiplier_changed(_new_multiplier: float) -> void:
	_refresh_all()


func _on_stage_changed(new_stage: int) -> void:
	_refresh_all()
	if new_stage != _last_stage:
		_push_ticker("МАСШТАБ ИЗМЕНЁН: %s" % _stage_name(new_stage))
	_last_stage = new_stage


func _on_game_saved(_slot: StringName) -> void:
	_refresh_all()


func _on_game_loaded(_slot: StringName) -> void:
	_refresh_all()


func _on_game_reset() -> void:
	_refresh_all()
	_push_ticker("СОСТОЯНИЕ СБРОШЕНО")
	_set_status("СБРОС ЗАВЕРШЁН. НОВАЯ СМЕНА.")


# --- User actions ----------------------------------------------------------

func _on_save_pressed() -> void:
	var error := GameState.save_game()
	if error == OK:
		_set_status("СОСТОЯНИЕ СОХРАНЕНО В user://savegame.json")
		_push_ticker("СЕЙВ ЗАПИСАН НА ДИСК")
	else:
		_set_status("ОШИБКА СОХРАНЕНИЯ: %d" % error)
		_push_ticker("ОШИБКА ЗАПИСИ СЕЙВА")


func _on_load_pressed() -> void:
	if not GameState.has_save():
		_set_status("АРХИВ НЕ НАЙДЕН")
		_push_ticker("ЗАГРУЗКА ОТМЕНЕНА: СЕЙВ ОТСУТСТВУЕТ")
		return

	var error := GameState.load_game()
	if error == OK:
		_set_status("АРХИВ ЗАГРУЖЕН")
		_push_ticker("СЕССИЯ ВОССТАНОВЛЕНА")
	else:
		_set_status("ОШИБКА ЗАГРУЗКИ: %d" % error)
		_push_ticker("АРХИВ ПОВРЕЖДЁН")


func _on_grind_pressed() -> void:
	var reward := GameState.click_multiplier
	GameState.add_coffee(reward)
	_set_status("ПОМОЛ УСКОРЕН. БАЛАНС: %s CR" % _format_number(GameState.coffee_coins))
	_push_ticker("РУЧНОЙ ПОМОЛ: +%s CR" % _format_number(reward))


func _on_menu_pressed(title: String) -> void:
	_set_status("МОДУЛЬ «%s» В РАЗРАБОТКЕ" % title)


func _on_minimize_pressed() -> void:
	_set_status("СВЕРНУТЬ ОКНО НЕЛЬЗЯ: АУДИТ ПРОДОЛЖАЕТСЯ")


func _on_maximize_pressed() -> void:
	_maximized = not _maximized
	var margin: int = 0 if _maximized else WINDOW_MARGIN
	_window_margin.add_theme_constant_override("margin_left", margin)
	_window_margin.add_theme_constant_override("margin_top", margin)
	_window_margin.add_theme_constant_override("margin_right", margin)
	_window_margin.add_theme_constant_override("margin_bottom", margin)
	_set_status("ОКНО РАЗВЁРНУТО" if _maximized else "ОКНО ВОССТАНОВЛЕНО")


func _on_close_pressed() -> void:
	_set_status("ЗАКРЫТИЕ ЗАПРЕЩЕНО ДО ЗАВЕРШЕНИЯ ОПТИМИЗАЦИИ")
	_push_ticker("ЗАПРОС НА ЗАКРЫТИЕ ОТКЛОНЁН СИСТЕМОЙ")


# --- Utilities -------------------------------------------------------------

func _set_status(message: String) -> void:
	_status_message.text = "> " + message


func _seed_ticker() -> void:
	_ticker_messages.clear()
	_push_ticker("СИСТЕМА АУДИТА ЗАПУЩЕНА")
	_push_ticker("СТАЖЁР АЛЕКСЕЙ НА МЕСТЕ")
	_push_ticker("ОЖИДАНИЕ ОПТИМИЗАЦИИ")


func _push_ticker(message: String) -> void:
	var now: Dictionary = Time.get_datetime_dict_from_system()
	var stamp := "%02d:%02d" % [int(now["hour"]), int(now["minute"])]
	_ticker_messages.append("> [%s] %s" % [stamp, message])
	while _ticker_messages.size() > TICKER_LIMIT:
		_ticker_messages.pop_front()
	_ticker_label.text = "\n".join(PackedStringArray(_ticker_messages))


func _update_clock() -> void:
	var now: Dictionary = Time.get_datetime_dict_from_system()
	_clock_label.text = "%02d.%02d.%04d  %02d:%02d:%02d" % [
		int(now["day"]),
		int(now["month"]),
		int(now["year"]),
		int(now["hour"]),
		int(now["minute"]),
		int(now["second"]),
	]


func _format_number(value: float) -> String:
	var magnitude := absf(value)
	if magnitude >= 1_000_000_000.0:
		return "%.2fB" % (value / 1_000_000_000.0)
	if magnitude >= 1_000_000.0:
		return "%.2fM" % (value / 1_000_000.0)
	if magnitude >= 1_000.0:
		return "%.2fK" % (value / 1_000.0)
	return "%.2f" % value


func _stage_name(stage: int) -> String:
	if STAGE_NAMES.has(stage):
		return STAGE_NAMES[stage]
	return "НЕИЗВЕСТНО"


func _stage_short_name(stage: int) -> String:
	if STAGE_SHORT_NAMES.has(stage):
		return STAGE_SHORT_NAMES[stage]
	return "НЕИЗВЕСТНО"
