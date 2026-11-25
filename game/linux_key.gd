extends Node
# Linux/niri доповнення для Your Wife (підключається через override.cfg як autoload).
# 1) Фон: гра малює його чистим пурпуровим #FF00FF замість прозорого (Wine губить альфа-канал),
#    а шейдер niri (magenta-key.frag) вирізає саме цей колір — точна прозорість для будь-якої моделі.
# 2) Команди без перезапуску гри: команда yourwife пише рядки у user://linux_cmd.txt,
#    тут вони виконуються через внутрішні функції гри. Відповіді — у user://linux_out.txt.
#      char <id>          героїня (character_01..08 або workshop_<id>)
#      size <0.55..4.5>   розмір
#      top on|off         поверх усіх вікон
#      lock on|off        клік крізь героїню
#      reset              стандартне місце, розмір і героїня
#      menu | settings | workshop | help   відкрити вікна гри
#      expr <назва>|off   емоція з файлів .exp3.json поруч із моделлю (тримається, доки не off)
#      motion <група> [n] анімація моделі
#      list-expr          записати в linux_out.txt емоції й анімації поточної моделі
const KEY := Color(1, 0, 1, 1)
const CMD := "user://linux_cmd.txt"
const OUT := "user://linux_out.txt"
# Режим справжньої прозорості: Wine з ScreenDepth=32 передає альфа-канал — тоді пурпуровий фон не потрібен.
# Файл user://linux_alpha вмикає цей режим (його створює install / yourwife alpha on).
var _true_alpha := FileAccess.file_exists("user://linux_alpha")
var _poll := 0.0
var _expr := {}          # ParamId -> [blend, value]: активна емоція з файлу .exp3.json
var _expr_name := ""

func _ready() -> void:
	process_priority = 1000
	if _true_alpha:
		# стандартний колір заливки Godot — сірий (0.3) з нульовою альфою; niri вважає пікселі
		# premultiplied і додає цей сірий до фону — при зміні розміру видно сірі напівпрозорі смуги
		RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))

var _model_cache: Node = null
var _last_size := Vector2i.ZERO

# xwayland-satellite не пускає зміну розміру вікна від самої гри (колесо миші, yourwife size),
# тож повідомляємо бажаний розмір у файл — служба yw-gaze на боці niri виставляє його вікну.
func _report_size() -> void:
	# позицією вікна на Linux керує niri; гра ж зсуває вікно при зміні розміру й за кілька змін
	# «виїжджала» за екран і ховалась. Тримаємо її уявлення про позицію в (0,0), як і є для XWayland.
	if DisplayServer.window_get_position() != Vector2i.ZERO:
		DisplayServer.window_set_position(Vector2i.ZERO)
	var sz := DisplayServer.window_get_size()
	if sz != _last_size:
		_last_size = sz
		var f := FileAccess.open("user://linux_winsize.txt", FileAccess.WRITE)
		if f:
			f.store_string("%d %d\n" % [sz.x, sz.y])
			f.close()

# Гра змінює масштаб героїні одразу, а справжнє вікно (через niri) доростає на кадр-два пізніше —
# героїню обрізало. yw-gaze пише справжній розмір у user://linux_actual.txt; поки він інший за
# бажаний, малюємо все в масштабі справжнього вікна — героїня виглядає незмінною, поки вікно не наздожене.
var _fit_scale := 1.0
func _fit_to_actual() -> void:
	var r := 1.0
	var txt := FileAccess.get_file_as_string("user://linux_actual.txt")
	var p := txt.split(" ", false)
	if p.size() >= 2 and _last_size.x > 0:
		var aw := p[0].to_float()
		var ah := p[1].to_float()
		if aw > 0 and ah > 0 and (int(aw) != _last_size.x or int(ah) != _last_size.y):
			r = minf(aw / _last_size.x, ah / _last_size.y)
	if not is_equal_approx(r, _fit_scale):
		_fit_scale = r
		get_tree().root.canvas_transform = Transform2D.IDENTITY.scaled(Vector2(r, r))

func _process(delta: float) -> void:
	_report_size()
	_fit_to_actual()
	_hold_expression()
	_poll += delta
	if _poll > 0.15:
		_poll = 0.0
		# фон і прозорість вікон гра може перевстановити (нове вікно, зміна героїні) — перевіряємо зрідка
		if not _true_alpha:
			RenderingServer.set_default_clear_color(KEY)
			_fix(get_tree().root)
		else:
			RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
		if FileAccess.file_exists(CMD):
			var text := FileAccess.get_file_as_string(CMD)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(CMD))
			for line in text.split("\n", false):
				_run(line.strip_edges())

func _fix(n: Node) -> void:
	if n is Viewport and n.transparent_bg:
		n.transparent_bg = false
	for c in n.get_children():
		if c is Viewport or c is Window:
			_fix(c)

func _model() -> Node:
	if is_instance_valid(_model_cache) and _model_cache.is_inside_tree():
		return _model_cache
	_model_cache = _find_class(get_tree().root, "GDCubismUserModel")
	return _model_cache

func _find_class(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for c in n.get_children():
		var r := _find_class(c, cls)
		if r:
			return r
	return null

# емоції .exp3.json, що лежать поруч із моделлю (формат Live2D/VTube Studio)
func _expr_files() -> Dictionary:
	var out := {}
	var m := _model()
	if m == null:
		return out
	var dir := str(m.get("assets")).get_base_dir()
	for root in [dir, dir.get_base_dir()]:
		var da := DirAccess.open(root)
		if da == null:
			continue
		for f in da.get_files():
			if f.ends_with(".exp3.json"):
				out[f.trim_suffix(".exp3.json")] = root.path_join(f)
	return out

func _set_expression(name: String) -> String:
	_expr.clear()
	_expr_name = ""
	if name == "" or name == "off" or name == "none":
		return "ok expr off"
	var files := _expr_files()
	var key := ""
	for k in files:
		if k.to_lower() == name.to_lower():
			key = k
	if key == "":
		for k in files:
			if k.to_lower().contains(name.to_lower()):
				key = k
				break
	if key == "":
		return "error: no expression " + name
	var data = JSON.parse_string(FileAccess.get_file_as_string(files[key]))
	if typeof(data) != TYPE_DICTIONARY:
		return "error: bad file " + files[key]
	for p in data.get("Parameters", []):
		_expr[p["Id"]] = [str(p.get("Blend", "Add")), float(p["Value"])]
	_expr_name = key
	return "ok expr " + key

func _hold_expression() -> void:
	if _expr.is_empty():
		return
	var m := _model()
	if m == null:
		return
	for prm in m.get_parameters():
		var id = prm.get("id")
		if _expr.has(id):
			var b: String = _expr[id][0]
			var v: float = _expr[id][1]
			var base: float = prm.get("default_value")
			if b.contains("Multiply"):
				prm.set("value", base * v)
			elif b.contains("Overwrite"):
				prm.set("value", v)
			else:
				prm.set("value", base + v)

# Гра вантажить модель 1-3 с у головному потоці (розпакування текстур 4096 px), і весь цей час
# стара модель «замерзала». Тепер: стара плавно зникає, кадр порожній, далі завантаження, нова плавно з'являється.
var _switching := false
func _switch_character(pet: Node, id: String) -> void:
	if _switching:
		return
	_switching = true
	_expr.clear()
	_expr_name = ""
	var tw := create_tween()
	tw.tween_property(pet, "modulate:a", 0.0, 0.15)
	await tw.finished
	await get_tree().process_frame
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	pet._select_character(id)
	var ms := Time.get_ticks_msec() - t0
	pet._save_preferences()
	await get_tree().process_frame
	var tw2 := create_tween()
	tw2.tween_property(pet, "modulate:a", 1.0, 0.25)
	_switching = false
	_say("ok char %s (завантаження %d мс)" % [id, ms])

func _pet() -> Node:
	return get_tree().root.get_node_or_null("DesktopPet")

func _say(msg: String) -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(msg + "\n")
		f.close()

func _run(line: String) -> void:
	var pet := _pet()
	if pet == null or line == "":
		return
	var parts := line.split(" ", false, 1)
	var cmd := parts[0]
	var arg := parts[1] if parts.size() > 1 else ""
	match cmd:
		"char":
			_switch_character(pet, arg)
		"size":
			pet._resize_character(clampf(arg.to_float(), 0.55, 4.5))
			pet._save_preferences()
			_say("ok size " + arg)
		"top":
			pet._on_topmost_toggled(arg != "off")
			_say("ok top " + arg)
		"lock":
			pet._set_locked(arg != "off")
			_say("ok lock " + arg)
		"reset":
			pet._reset_character(true)
			_say("ok reset")
		"menu":
			pet._show_context_menu(DisplayServer.mouse_get_position())
		"settings":
			pet._show_settings()
		"workshop":
			pet._show_workshop()
		"help":
			pet._show_help()
		"expr":
			_say(_set_expression(arg))
		"motion":
			var mp := arg.split(" ", false)
			var mm := _model()
			if mm and mp.size() > 0:
				var no := mp[1].to_int() if mp.size() > 1 else 0
				mm.start_motion(mp[0], no, 3)
				_say("ok motion " + arg)
			else:
				_say("error: no motion")
		"fps":
			_say("FPS %d, ліміт %d" % [Engine.get_frames_per_second(), Engine.max_fps])
		"maxfps":
			Engine.max_fps = arg.to_int()
			_say("ліміт FPS %d" % Engine.max_fps)
		"list-expr":
			var m := _model()
			var out := "емоції:"
			var names := _expr_files().keys()
			names.sort()
			for e in names:
				out += "\n  " + e + (" *" if e == _expr_name else "")
			if names.is_empty():
				out += " (у цієї моделі немає)"
			out += "\nанімації:"
			if m:
				var ms = m.get_motions()
				for g in ms:
					out += "\n  " + str(g) + " x" + str(ms[g])
			_say(out)
		_:
			_say("unknown: " + line)
