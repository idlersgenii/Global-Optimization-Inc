extends PanelContainer
## Bottom-of-screen corporate console.
##
## Other systems publish plain-text lines through
## SignalBus.log_message_received. The console queues them, collapses
## consecutive duplicates into a repeat counter, reveals each line with a short
## typewriter effect and keeps the newest entry in view. A marquee row cycles
## satirical corporate slogans and reacts to the intern's fatigue tier.

const MAX_QUEUE: int = 64
const MAX_LOG_LINES: int = 80
const TYPE_CHARS_PER_SEC: float = 160.0
const TYPE_MAX_SEC: float = 0.55
const LINE_PAUSE_SEC: float = 0.06
const MARQUEE_SPEED: float = 55.0
const MARQUEE_GAP: float = 80.0
const AMBIENT_MIN_SEC: float = 24.0
const AMBIENT_MAX_SEC: float = 40.0

const COLOR_TIMESTAMP: String = "5f7a63"
const COLOR_INFO: String = "9fd8a4"
const COLOR_HR: String = "d8c27a"
const COLOR_WARNING: String = "e08a6a"
const COLOR_SYSTEM: String = "7fc9c0"
## Repeat counters use neutral grey so they read as metadata, not content.
const COLOR_COUNT: String = "a9b0ad"

const MARQUEE_MESSAGES: Array[String] = [
	"СИНЕРГИЯ — ЭТО КОГДА ДВА СТАЖЁРА РАБОТАЮТ ЗА ОДНУ ЗАРПЛАТУ",
	"КОФЕ ДЛЯ СОТРУДНИКОВ ОПЛАЧИВАЕТСЯ ИЗ ИХ ЖЕ ПРЕМИИ",
	"КИСЛОРОД В ОФИСЕ — ЧАСТЬ КОРПОРАТИВНОГО БОНУСА",
	"ОТДЫХ НЕ ПРЕДУСМОТРЕН РЕГЛАМЕНТОМ. УЛЫБАЙТЕСЬ.",
	"ЭФФЕКТИВНОСТЬ ВЫРОСЛА. ПРИЧИНА НЕ ВАЖНА.",
	"АУДИТ НЕ НАХОДИТ ПРОБЛЕМ. АУДИТ ИХ СОЗДАЁТ.",
	"ВАШ ПЕРЕРЫВ ПЕРЕНЕСЁН НА СЛЕДУЮЩИЙ КВАРТАЛ",
	"МЫ НЕ ЭКОНОМИМ НА ЛЮДЯХ. МЫ ЭКОНОМИМ ИХ ВРЕМЯ.",
]

## Fatigue thresholds and the overwork claim unlocked at each. Below 40 % the
## marquee uses only regular slogans; reaching a threshold escalates the claim.
const FATIGUE_MESSAGES: Dictionary[int, Array] = {
	40: [
		"НОРМА ПЕРЕРАБОТКИ ПРЕВЫШЕНА НА 40%. СПАСИБО ЗА ЛОЯЛЬНОСТЬ.",
		"HR: ДО 40% ПЕРЕРАБОТКИ — ЭТО ЕЩЁ ПРОИЗВОДСТВЕННАЯ ГИМНАСТИКА.",
	],
	60: [
		"НОРМА ПЕРЕРАБОТКИ ПРЕВЫШЕНА НА 60%. ВЫ ВОШЛИ ВО ВКУС КОРПОРАТИВНОЙ ЖИЗНИ.",
		"HR: 60% СВЕРХ НОРМЫ. ПРОГУЛКА ДО КУЛЕРА СЧИТАЕТСЯ ОТДЫХОМ.",
	],
	80: [
		"НОРМА ПЕРЕРАБОТКИ ПРЕВЫШЕНА НА 80%. ОТДЫХ ПЕРЕНЕСЁН НА СЛЕДУЮЩИЙ КВАРТАЛ.",
		"СЛУЖБА ЗАБОТЫ: 80% СВЕРХ НОРМЫ. МЫ УЖЕ ГОТОВИМ ВАМ КРУЖКУ С ЛОГОТИПОМ.",
	],
	95: [
		"НОРМА ПЕРЕРАБОТКИ ПРЕВЫШЕНА НА 95%. ВЫ ПОЧТИ ДОСТИГЛИ СИНЕРГИИ.",
		"СИСТЕМА: 95% СВЕРХ НОРМЫ. ОСТАЛОСЬ ВСЕГО НИЧЕГО. НЕ ОСТАНАВЛИВАЙТЕСЬ.",
	],
}

const AMBIENT_MESSAGES: Array[String] = [
	"HR: ОТДЫХ НЕ ВХОДИТ В KPI. УЛЫБАЙТЕСЬ ЭФФЕКТИВНО.",
	"IT: ВЕНТИЛЯЦИЯ РАБОТАЕТ ШТАТНО. ШУМ — ЧАСТЬ КУЛЬТУРЫ.",
	"БУХГАЛТЕРИЯ: КОФЕ-КОЙНЫ НЕ ОБЛАГАЮТСЯ НАЛОГОМ. ПОКА.",
	"СЛУЖБА БЕЗОПАСНОСТИ: УЛЫБКА СОТРУДНИКА — КОРПОРАТИВНАЯ ТАЙНА.",
	"ОПТИМИЗАЦИЯ: ИЗ ПЕРЕГОВОРНОЙ УБРАЛИ СТУЛЬЯ. СИНЕРГИЯ ВЫРОСЛА.",
	"СИСТЕМА: ЖАЛОБА ПРИНЯТА. ЖАЛОБА ПРОИГНОРИРОВАНА. СПАСИБО.",
	"АУДИТ: НАРУШЕНИЙ НЕ НАЙДЕНО. НАРУШИТЕЛИ НЕ НАЙДЕНЫ. ВСЁ ЧИСТО.",
	"HR: ВАКАНСИЯ «СТАЖЁР» ЗАКРЫТА. ОТКРЫТА ВАКАНСИЯ «СТАЖЁР-2».",
]

## One queued console line. Duplicates bump `count` and refresh `timestamp`.
class LogEntry:
	var text: String
	var count: int
	var timestamp: String

	func _init(message: String, stamp: String) -> void:
		text = message
		count = 1
		timestamp = stamp


@onready var _log: RichTextLabel = %LogText
@onready var _marquee_frame: Control = %MarqueeFrame
@onready var _marquee_label: Label = %MarqueeLabel
@onready var _live_dot: Label = %LiveDot
@onready var _blink_timer: Timer = $BlinkTimer
@onready var _ambient_timer: Timer = $AmbientTimer
@onready var _pump_timer: Timer = $PumpTimer

var _queue: Array[LogEntry] = []
var _lines: Array[String] = []
var _typing: bool = false
var _last_message: String = ""
var _last_count: int = 1
var _marquee_index: int = 0
var _marquee_show_fatigue: bool = true
var _marquee_x: float = 0.0
var _marquee_ready: bool = false
var _last_fatigue_band: int = -1
var _ambient_index: int = 0
var _reveal_tween: Tween


func _ready() -> void:
	_log.scroll_following = true
	SignalBus.log_message_received.connect(_on_log_message_received)
	SignalBus.fatigue_changed.connect(_on_fatigue_changed)
	SignalBus.game_loaded.connect(_on_game_loaded)
	SignalBus.game_reset.connect(_on_game_reset)
	_blink_timer.timeout.connect(_on_blink_timeout)
	_ambient_timer.timeout.connect(_on_ambient_timeout)
	_pump_timer.timeout.connect(_pump)

	_last_fatigue_band = _fatigue_band(GameState.intern_fatigue)
	_apply_fatigue_marquee()
	_seed_boot_log()
	_schedule_ambient()
	call_deferred("_begin_marquee")


func _process(delta: float) -> void:
	if not _marquee_ready or not is_visible_in_tree():
		return

	_marquee_x -= MARQUEE_SPEED * delta
	_marquee_label.position.x = _marquee_x
	if _marquee_x <= -(_marquee_label.size.x + MARQUEE_GAP):
		_advance_marquee()


# --- Log queue -------------------------------------------------------------

func _on_log_message_received(text: String) -> void:
	for raw_line in text.split("\n"):
		_enqueue(raw_line)


func _enqueue(text: String) -> void:
	var line := text.strip_edges()
	if line.is_empty():
		return

	var stamp := _current_stamp()
	if _queue.is_empty() and _last_message == line:
		_update_last_line(_last_count + 1, stamp)
		return

	if not _queue.is_empty():
		var tail := _queue[_queue.size() - 1]
		if tail.text == line:
			tail.count += 1
			tail.timestamp = stamp
			return

	var entry := LogEntry.new(line, stamp)
	if _queue.size() >= MAX_QUEUE:
		_queue.pop_front()
	_queue.append(entry)
	_pump()


func _pump() -> void:
	if _typing or _queue.is_empty():
		return
	_typing = true
	var entry: LogEntry = _queue.pop_front()
	_append_entry(entry)


func _append_entry(entry: LogEntry) -> void:
	_last_message = entry.text
	_last_count = entry.count

	var formatted := _format_line(entry.text, entry.timestamp, entry.count)
	var from := _log.get_total_character_count()
	# Keep a trailing newline so the newest line never touches the panel edge.
	_log.append_text(formatted + "\n")
	var to := _log.get_total_character_count()
	_log.visible_characters = from

	var reveal_chars := maxi(to - from, 1)
	var duration := minf(float(reveal_chars) / TYPE_CHARS_PER_SEC, TYPE_MAX_SEC)
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	_reveal_tween = create_tween()
	_reveal_tween.tween_property(_log, "visible_characters", to, duration)
	_reveal_tween.finished.connect(_on_line_revealed)

	_lines.append(formatted)
	_scroll_to_bottom()


## Re-renders the newest line in place when the same message arrives again.
func _update_last_line(count: int, stamp: String) -> void:
	if _lines.is_empty():
		return
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	_typing = false
	_last_count = count
	_lines[_lines.size() - 1] = _format_line(_last_message, stamp, count)
	_log.text = "\n".join(PackedStringArray(_lines)) + "\n"
	_log.visible_characters = -1
	_scroll_to_bottom()


func _on_line_revealed() -> void:
	_log.visible_characters = -1
	_typing = false
	_trim_history()
	_scroll_to_bottom()
	if not _queue.is_empty():
		_pump_timer.start(LINE_PAUSE_SEC)


func _trim_history() -> void:
	if _lines.size() <= MAX_LOG_LINES:
		return

	var removed := _lines.size() - MAX_LOG_LINES
	var trimmed: Array[String] = []
	for index in range(removed, _lines.size()):
		trimmed.append(_lines[index])
	_lines = trimmed
	_log.text = "\n".join(PackedStringArray(_lines)) + "\n"
	_log.visible_characters = -1
	_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	_log.scroll_to_line(maxi(_log.get_line_count() - 1, 0))


func _current_stamp() -> String:
	var now := Time.get_time_dict_from_system()
	return "%02d:%02d:%02d" % [
		int(now["hour"]),
		int(now["minute"]),
		int(now["second"]),
	]


func _format_line(message: String, stamp: String, count: int) -> String:
	var line := "[color=#%s]%s[/color] [color=#%s]%s[/color]" % [
		COLOR_TIMESTAMP,
		stamp,
		_message_color(message),
		message.replace("[", "[lb]"),
	]
	if count <= 1:
		return line
	return line + " [color=#%s]×%d[/color]" % [COLOR_COUNT, count]


func _message_color(message: String) -> String:
	var upper := message.to_upper()
	if (
		upper.contains("ОШИБК")
		or upper.contains("ОТКЛОН")
		or upper.contains("ЗАПРЕЩ")
		or upper.contains("ПОВРЕЖ")
		or upper.contains("КРИТ")
	):
		return COLOR_WARNING
	if upper.begins_with("HR:") or upper.begins_with("ПЕРЕРЫВ"):
		return COLOR_HR
	if (
		upper.begins_with("IT:")
		or upper.begins_with("БУХГАЛТЕРИЯ:")
		or upper.begins_with("СИСТЕМА")
		or upper.begins_with("BUREAUCRACY")
	):
		return COLOR_SYSTEM
	return COLOR_INFO


# --- Boot and ambient chatter ----------------------------------------------

func _seed_boot_log() -> void:
	_enqueue("BUREAUCRACY-OS 3.7 ЗАГРУЖЕН. ЛИЦЕНЗИЯ ИСТЕКАЕТ ЧЕРЕЗ 3 ДНЯ.")
	_enqueue("ПРОВЕРКА ЛОЯЛЬНОСТИ: ПРОЙДЕНА. ПРОВЕРКА ОПТИМИЗМА: ОЖИДАЕТ.")
	_enqueue("СОВЕТ ДНЯ: УЛЫБАЙТЕСЬ. КАМЕРА СЧИТАЕТ УЛЫБКИ.")


func _schedule_ambient() -> void:
	_ambient_timer.wait_time = randf_range(AMBIENT_MIN_SEC, AMBIENT_MAX_SEC)
	_ambient_timer.start()


func _on_ambient_timeout() -> void:
	if not AMBIENT_MESSAGES.is_empty():
		var message := AMBIENT_MESSAGES[_ambient_index % AMBIENT_MESSAGES.size()]
		_ambient_index += 1
		SignalBus.emit_signal("log_message_received", message)
	_schedule_ambient()


# --- Marquee ---------------------------------------------------------------

## Returns 0 while no overwork threshold is reached, then the highest reached
## threshold. The marquee only claims overwork once its band is above zero.
func _fatigue_band(fatigue: float) -> int:
	if fatigue >= 95.0:
		return 95
	if fatigue >= 80.0:
		return 80
	if fatigue >= 60.0:
		return 60
	if fatigue >= 40.0:
		return 40
	return 0


func _fatigue_marquee_text() -> String:
	var variants: Array = FATIGUE_MESSAGES.get(_fatigue_band(GameState.intern_fatigue), [])
	if variants.is_empty():
		return ""
	return variants[randi_range(0, variants.size() - 1)]


func _on_fatigue_changed(new_value: float) -> void:
	var band := _fatigue_band(new_value)
	if band == _last_fatigue_band:
		return
	_last_fatigue_band = band
	_apply_fatigue_marquee()


func _on_game_loaded(_slot: StringName) -> void:
	_refresh_fatigue_marquee()


func _on_game_reset() -> void:
	_refresh_fatigue_marquee()


## Re-reads fatigue after a load/reset, since those paths do not emit
## fatigue_changed for every field they restore.
func _refresh_fatigue_marquee() -> void:
	_last_fatigue_band = _fatigue_band(GameState.intern_fatigue)
	_apply_fatigue_marquee()


## Below 40 % there is no overwork claim to show, so fall back to slogans.
func _apply_fatigue_marquee() -> void:
	if _last_fatigue_band == 0:
		_marquee_show_fatigue = false
		_show_next_slogan()
		return
	_marquee_show_fatigue = true
	_set_marquee_text(_fatigue_marquee_text())


func _show_next_slogan() -> void:
	if MARQUEE_MESSAGES.is_empty():
		return
	var text := MARQUEE_MESSAGES[_marquee_index % MARQUEE_MESSAGES.size()]
	_marquee_index = (_marquee_index + 1) % MARQUEE_MESSAGES.size()
	_set_marquee_text(text)


func _begin_marquee() -> void:
	_marquee_ready = true
	_layout_marquee()
	_marquee_x = maxf(_marquee_frame.size.x, 1.0)
	_marquee_label.position = Vector2(_marquee_x, 0.0)


func _advance_marquee() -> void:
	_marquee_show_fatigue = not _marquee_show_fatigue
	if _marquee_show_fatigue:
		var text := _fatigue_marquee_text()
		if not text.is_empty():
			_set_marquee_text(text)
			return
		_marquee_show_fatigue = false
	_show_next_slogan()


func _set_marquee_text(text: String) -> void:
	if text.is_empty():
		return
	_marquee_label.text = text
	_layout_marquee()
	_marquee_x = maxf(_marquee_frame.size.x, 1.0)
	_marquee_label.position = Vector2(_marquee_x, 0.0)


func _layout_marquee() -> void:
	_marquee_label.reset_size()
	_marquee_label.size.y = _marquee_frame.size.y


func _on_blink_timeout() -> void:
	_live_dot.visible = not _live_dot.visible
