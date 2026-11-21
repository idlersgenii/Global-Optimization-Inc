extends PanelContainer
## Bottom-of-screen corporate console.
##
## Other systems publish plain-text lines through
## SignalBus.log_message_received. The console queues them, reveals each line
## with a short typewriter effect and keeps the newest entry in view. A marquee
## row cycles satirical corporate slogans while a timer injects ambient
## bureaucracy into the log.

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

const MARQUEE_MESSAGES: Array[String] = [
	"СИНЕРГИЯ — ЭТО КОГДА ДВА СТАЖЁРА РАБОТАЮТ ЗА ОДНУ ЗАРПЛАТУ",
	"НОРМА ПЕРЕРАБОТКИ ПРЕВЫШЕНА НА 40%. СПАСИБО ЗА ЛОЯЛЬНОСТЬ.",
	"КОФЕ ДЛЯ СОТРУДНИКОВ ОПЛАЧИВАЕТСЯ ИЗ ИХ ЖЕ ПРЕМИИ",
	"КИСЛОРОД В ОФИСЕ — ЧАСТЬ КОРПОРАТИВНОГО БОНУСА",
	"ОТДЫХ НЕ ПРЕДУСМОТРЕН РЕГЛАМЕНТОМ. УЛЫБАЙТЕСЬ.",
	"ЭФФЕКТИВНОСТЬ ВЫРОСЛА. ПРИЧИНА НЕ ВАЖНА.",
	"АУДИТ НЕ НАХОДИТ ПРОБЛЕМ. АУДИТ ИХ СОЗДАЁТ.",
	"ВАШ ПЕРЕРЫВ ПЕРЕНЕСЁН НА СЛЕДУЮЩИЙ КВАРТАЛ",
	"МЫ НЕ ЭКОНОМИМ НА ЛЮДЯХ. МЫ ЭКОНОМИМ ИХ ВРЕМЯ.",
]

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

@onready var _log: RichTextLabel = %LogText
@onready var _marquee_frame: Control = %MarqueeFrame
@onready var _marquee_label: Label = %MarqueeLabel
@onready var _live_dot: Label = %LiveDot
@onready var _blink_timer: Timer = $BlinkTimer
@onready var _ambient_timer: Timer = $AmbientTimer
@onready var _pump_timer: Timer = $PumpTimer

var _queue: Array[String] = []
var _lines: Array[String] = []
var _typing: bool = false
var _marquee_index: int = 0
var _marquee_x: float = 0.0
var _marquee_ready: bool = false
var _ambient_index: int = 0
var _reveal_tween: Tween


func _ready() -> void:
	_log.scroll_following = true
	SignalBus.log_message_received.connect(_on_log_message_received)
	_blink_timer.timeout.connect(_on_blink_timeout)
	_ambient_timer.timeout.connect(_on_ambient_timeout)
	_pump_timer.timeout.connect(_pump)

	_seed_boot_log()
	_schedule_ambient()
	_marquee_label.text = MARQUEE_MESSAGES[0]
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
	if _queue.size() >= MAX_QUEUE:
		_queue.pop_front()
	_queue.append(line)
	_pump()


func _pump() -> void:
	if _typing or _queue.is_empty():
		return
	_typing = true
	_append_line(_queue.pop_front())


func _append_line(message: String) -> void:
	var formatted := _format_line(message)
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


func _format_line(message: String) -> String:
	var now := Time.get_time_dict_from_system()
	var stamp := "%02d:%02d:%02d" % [
		int(now["hour"]),
		int(now["minute"]),
		int(now["second"]),
	]
	return "[color=#%s]%s[/color] [color=#%s]%s[/color]" % [
		COLOR_TIMESTAMP,
		stamp,
		_message_color(message),
		message.replace("[", "[lb]"),
	]


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

func _begin_marquee() -> void:
	_marquee_ready = true
	_layout_marquee()
	_marquee_x = maxf(_marquee_frame.size.x, 1.0)
	_marquee_label.position = Vector2(_marquee_x, 0.0)


func _advance_marquee() -> void:
	if MARQUEE_MESSAGES.is_empty():
		return
	_marquee_index = (_marquee_index + 1) % MARQUEE_MESSAGES.size()
	_marquee_label.text = MARQUEE_MESSAGES[_marquee_index]
	_layout_marquee()
	_marquee_x = maxf(_marquee_frame.size.x, 1.0)
	_marquee_label.position = Vector2(_marquee_x, 0.0)


func _layout_marquee() -> void:
	_marquee_label.reset_size()
	_marquee_label.size.y = _marquee_frame.size.y


func _on_blink_timeout() -> void:
	_live_dot.visible = not _live_dot.visible
