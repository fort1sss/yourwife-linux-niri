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
	if FileAccess.file_exists("user://linux_noui"):
		return
	_linux_ui_setup.call_deferred()
	if _true_alpha:
		# стандартний колір заливки Godot — сірий (0.3) з нульовою альфою; niri вважає пікселі
		# premultiplied і додає цей сірий до фону — при зміні розміру видно сірі напівпрозорі смуги
		RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))

var _model_cache: Node = null
var _last_size := Vector2i.ZERO

# xwayland-satellite не пускає зміну розміру вікна від самої гри (колесо миші, yourwife size),
# тож повідомляємо бажаний розмір у файл — служба yw-gaze на боці niri виставляє його вікну.
var _guard_ms := 0
func _guard_scale() -> void:
	var now := Time.get_ticks_msec()
	if now - _guard_ms < 300:
		return
	_guard_ms = now
	var pet := _pet()
	if pet == null or pet.get("_character_scale") == null:
		return
	var lim := max_safe_scale()
	if float(pet._character_scale) > lim + 0.01:
		pet._resize_character(lim)
		pet._save_preferences()

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

# При запуску гра відкриває вікно на весь екран і не завжди зменшує його до героїні: прозоре вікно
# 1920x1044 перекривало б кліки по всьому екрану. Через 3 і 8 с після старту ще раз задаємо розмір героїні.
# Той самий масштаб гра ігнорує, тож спершу трохи інший (+0.1%), а за 0.3 с — справжній.
var _fit_marks := [[3000, 1.001], [3300, 1.0], [8000, 1.001], [8300, 1.0]]
var _fit_base := -1.0
func _startup_fit() -> void:
	if _fit_marks.is_empty() or Time.get_ticks_msec() < int(_fit_marks[0][0]):
		return
	var k: float = _fit_marks.pop_front()[1]
	var pet := _pet()
	if pet == null or pet.get("_character_scale") == null:
		return
	if _fit_base < 0.0:
		_fit_base = float(pet._character_scale)   # масштаб із налаштувань — запам'ятати до першої зміни
	pet._resize_character(clampf(_fit_base * k, 0.55, max_safe_scale()))

var _spikes: Array = []
var _last_event := ""
var _last_tick := 0
func _process(delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _last_tick > 0 and now - _last_tick > 40:
		_spikes.append("%d ms (frame at %d)" % [now - _last_tick, now])
		if _spikes.size() > 40:
			_spikes.pop_front()
	_last_tick = now
	_report_size()
	_guard_scale()
	_startup_fit()
	_watch_model_expr(delta)
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
		_ensure_menu_patched()
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

# ───────────── Емоції: вільне змішування + категорії для списку (для БУДЬ-ЯКОЇ моделі) ─────────────
# Емоції — файли *.exp3.json. Будь-які емоції можна вмикати разом: вони накладаються в порядку
# ввімкнення (як у VTube Studio: Add — додати, Multiply — помножити, Overwrite — замінити).
# Категорії — лише для зручного списку: кожну емоцію сортуємо за її назвою й «людськими» назвами
# параметрів моделі (DisplayInfo, *.cdi3.json) — Очі, Рот, Сльози, Одяг, Поза…
var _active: Array = []         # назви ввімкнених емоцій у порядку ввімкнення
var _expr_params := {}          # назва емоції -> {ParamId: [blend, value]}
var _expr_layers: Array = []    # параметри ввімкнених емоцій по черзі
var _param_names := {}          # ParamId -> назва з cdi3.json
var _groups := []               # [{name, items:[назви]}]
var _groups_key := ""

const CATS := [
	["Сльози", "Tears", ["tear", "cry", "sob", "weep"]],
	["Рум'янець", "Blush", ["blush", "cheek", "flush"]],
	["Очі", "Eyes", ["eye", "pupil", "iris", "xray", "gaze", "glow"]],
	["Брови", "Brows", ["brow"]],
	["Рот", "Mouth", ["mouth", "tongue", "smile", "teeth", "lip", "fang"]],
	["Волосся", "Hair", ["hair", "bald", "ponytail", "bang"]],
	["Голова й аксесуари", "Head & accessories", ["hat", "beret", "halo", "cap", "ear", "horn", "crown", "ribbon", "glasses", "mask"]],
	["Поза", "Pose", ["pose", "switch"]],
	["Верх одягу", "Top", ["shirt", "sleeve", "jacket", "coat", "top", "bra", "chest", "breast"]],
	["Сукня й низ", "Dress & bottom", ["dress", "skirt", "underwear", "pant", "short", "cloth", "outfit"]],
	["Ноги й взуття", "Legs & shoes", ["leg", "thigh", "sock", "stock", "shoe", "boot", "feet", "foot"]],
	["Руки", "Arms", ["arm", "hand", "glove", "finger"]],
	["Настрій", "Mood", ["angry", "sad", "happy", "shock", "confus", "mad", "gloom", "exit", "expression", "love", "smug", "fear", "surpr", "joy"]],
]

func _load_expr_params(files: Dictionary) -> void:
	_expr_params.clear()
	for name in files:
		var data = JSON.parse_string(FileAccess.get_file_as_string(files[name]))
		var pm := {}
		if typeof(data) == TYPE_DICTIONARY:
			for prm in data.get("Parameters", []):
				pm[str(prm.get("Id", ""))] = [str(prm.get("Blend", "Add")), float(prm.get("Value", 0.0))]
		_expr_params[name] = pm

func _load_param_names() -> void:
	_param_names.clear()
	var m := _model()
	if m == null:
		return
	var mpath := str(m.get("assets"))
	var mj = JSON.parse_string(FileAccess.get_file_as_string(mpath))
	if typeof(mj) != TYPE_DICTIONARY:
		return
	var di := str(mj.get("FileReferences", {}).get("DisplayInfo", ""))
	if di == "":
		return
	var cd = JSON.parse_string(FileAccess.get_file_as_string(mpath.get_base_dir().path_join(di)))
	if typeof(cd) == TYPE_DICTIONARY:
		for prm in cd.get("Parameters", []):
			_param_names[str(prm.get("Id", ""))] = str(prm.get("Name", ""))

# слова з назви: "EyeBallX" -> eye ball x, "Underwear Visibility" -> underwear visibility
func _words(t: String) -> PackedStringArray:
	var re := RegEx.new()
	re.compile("[A-Z]?[a-z]+|[A-Z]+(?![a-z])")
	var out := PackedStringArray()
	for mm in re.search_all(t):
		out.append(mm.get_string().to_lower())
	return out

func _cat_of(item: String) -> int:
	var name_words := _words(item)
	var param_words := PackedStringArray()
	for pid in _expr_params.get(item, {}):
		param_words.append_array(_words(str(_param_names.get(pid, pid))))
	var best := -1
	var best_score := 0
	for ci in CATS.size():
		var score := 0
		for kw in CATS[ci][2]:
			for w in name_words:
				if w.begins_with(kw):
					score += 3            # назва емоції важить більше
			for w in param_words:
				if w.begins_with(kw):
					score += 1
		if score > best_score:
			best_score = score
			best = ci
	return best

func expr_groups() -> Array:
	var files := _expr_files()
	var m := _model()
	var key := str(m.get("assets") if m else "") + "|" + str(files.size())
	if key == _groups_key:
		return _groups
	_groups_key = key
	_active.clear()
	_rebuild_expr()
	_load_expr_params(files)
	_load_param_names()
	_restore_expr(files)
	var names := files.keys()
	names.sort()
	var by_cat := {}
	for n in names:
		var ci := _cat_of(n)
		if not by_cat.has(ci):
			by_cat[ci] = []
		by_cat[ci].append(n)
	var cats := by_cat.keys()
	cats.sort_custom(func(x, y): return (x if x >= 0 else 99) < (y if y >= 0 else 99))
	_groups = []
	for ci in cats:
		var nm: String = _t("Інше", "Other") if ci < 0 else _t(CATS[ci][0], CATS[ci][1])
		_groups.append({"name": nm, "items": by_cat[ci]})
	return _groups

# ввімкнені емоції зберігаються окремо для кожного персонажа (user://linux_expr.json)
const EXPR_FILE := "user://linux_expr.json"
func _char_id() -> String:
	var pet := _pet()
	return str(pet.get("_selected_character_id")) if pet else ""

func _save_expr() -> void:
	var cid := _char_id()
	if cid == "":
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(EXPR_FILE)) if FileAccess.file_exists(EXPR_FILE) else {}
	if typeof(d) != TYPE_DICTIONARY:
		d = {}
	if _active.is_empty():
		d.erase(cid)
	else:
		d[cid] = _active.duplicate()
	var f := FileAccess.open(EXPR_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))
		f.close()

func _restore_expr(files: Dictionary) -> void:
	if not FileAccess.file_exists(EXPR_FILE):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(EXPR_FILE))
	if typeof(d) != TYPE_DICTIONARY:
		return
	for n in d.get(_char_id(), []):
		if files.has(n) and not (n in _active):
			_active.append(n)
	_rebuild_expr()

# після запуску й після зміни персонажа — підхопити збережені емоції (модель вантажиться не одразу)
var _expr_watch := 0.0
func _watch_model_expr(delta: float) -> void:
	_expr_watch += delta
	if _expr_watch < 0.5:
		return
	_expr_watch = 0.0
	var m := _model()
	if m and not _groups_key.begins_with(str(m.get("assets")) + "|"):
		expr_groups()

func is_expr_active(name: String) -> bool:
	return name in _active

func _rebuild_expr() -> void:
	_expr.clear()
	_expr_layers.clear()
	for n in _active:
		var pm: Dictionary = _expr_params.get(n, {})
		_expr_layers.append(pm)
		for pid in pm:
			_expr[pid] = pm[pid]
	_expr_name = ", ".join(PackedStringArray(_active))

# увімкнути/вимкнути емоцію (будь-які змішуються); "off" — скинути всі
func _set_expression(name: String) -> String:
	var groups := expr_groups()
	if name == "" or name == "off" or name == "none":
		_active.clear()
		_rebuild_expr()
		_save_expr()
		return "ok expr off"
	var key := ""
	for g in groups:
		for it in g["items"]:
			if str(it).to_lower() == name.to_lower():
				key = it
	if key == "":
		for g in groups:
			for it in g["items"]:
				if key == "" and str(it).to_lower().contains(name.to_lower()):
					key = it
	if key == "":
		return "error: no expression " + name
	if key in _active:
		_active.erase(key)
	else:
		_active.append(key)
	_rebuild_expr()
	_save_expr()
	return "ok expr " + (_expr_name if _expr_name != "" else "off")

func _hold_expression() -> void:
	if _expr_layers.is_empty():
		return
	var m := _model()
	if m == null:
		return
	for prm in m.get_parameters():
		var id = prm.get("id")
		if not _expr.has(id):
			continue
		var v: float = prm.get("default_value")
		for layer in _expr_layers:
			if layer.has(id):
				var b: String = layer[id][0]
				var val: float = layer[id][1]
				if b.contains("Multiply"):
					v *= val
				elif b.contains("Overwrite"):
					v = val
				else:
					v += val
		prm.set("value", v)

# Гра вантажить модель 1-3 с у головному потоці (розпакування текстур 4096 px), і весь цей час
# стара модель «замерзала». Тепер: стара плавно зникає, кадр порожній, далі завантаження, нова плавно з'являється.
var _switching := false
func _switch_character(pet: Node, id: String) -> void:
	if _switching:
		return
	_switching = true
	_expr.clear()
	_active.clear()
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
			safe_resize(arg.to_float())
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
			var t0 := Time.get_ticks_usec()
			_show_fast_menu(pet, Vector2(DisplayServer.mouse_get_position() - DisplayServer.window_get_position()))
			_say("ok menu %d us" % (Time.get_ticks_usec() - t0))
		"gamemenu":
			var t1 := Time.get_ticks_usec()
			pet._show_context_menu(DisplayServer.mouse_get_position())
			_say("ok gamemenu %d us" % (Time.get_ticks_usec() - t1))
		"menupos":
			var o := ""
			for m in [pet._context_menu, pet._tray_menu]:
				o += "%s visible=%s pos=%s DS=%s\n" % [m.name, m.visible, m.position, (DisplayServer.window_get_position(m.get_window_id()) if m.visible else Vector2i(-1, -1))]
			_say(o)
		"menuhover":
			if _menu_win and _menu_win.visible:
				_menu_win._on_main_hover(arg.to_int())
			_say("ok menuhover")
		"probe":
			var o := ""
			var sc0: float = pet._character_scale
			var ws0 := DisplayServer.window_get_size()
			pet._resize_character(4.5)
			o += "requested 4.5 -> scale %.3f, win %s (was %.3f %s)\n" % [pet._character_scale, DisplayServer.window_get_size(), sc0, ws0]
			pet._resize_character(sc0)
			pet._save_preferences()
			for w in _all_windows(get_tree().root):
				o += "window '%s' visible=%s size=%s min=%s content_scale=%s\n" % [w.title, w.visible, w.size, w.min_size, w.content_scale_size]
			o += "screen %s usable %s\n" % [DisplayServer.screen_get_size(), DisplayServer.screen_get_usable_rect()]
			_say(o)
		"togglehide":
			toggle_hide()
			_say("ok togglehide")
		"togglelock":
			toggle_lock()
			_say("ok lock=%s" % _locked)
		"audit":
			var o := ""
			var todo := [pet._context_menu]
			while todo.size() > 0:
				var m: PopupMenu = todo.pop_front()
				var ids := []
				for c in m.id_pressed.get_connections():
					ids.append(str(c.callable.get_method()))
				var idx := []
				for c in m.index_pressed.get_connections():
					idx.append(str(c.callable.get_method()))
				o += "%s: items=%d id_pressed=%s index_pressed=%s\n" % [m.name, m.item_count, str(ids), str(idx)]
				for i in m.item_count:
					var sub := m.get_item_submenu_node(i)
					if sub:
						todo.append(sub)
			_say(o)
		"menusizes":
			var o := ""
			if _menu_win:
				o += "sub_scroll %s, sub_box %s\n" % [_menu_win._sub_scroll.size, _menu_win._sub_box.size]
				for c in _menu_win._sub_box.get_children().slice(0, 4):
					o += "  sub %s pos=%s size=%s\n" % [c.get_class(), c.position, c.size]
				for c in _menu_win._main_box.get_children().slice(0, 3):
					o += "  main %s pos=%s size=%s\n" % [c.get_class(), c.position, c.size]
			_say(o)
		"wsbench":
			_spikes.clear()
			var t0 := Time.get_ticks_usec()
			pet._show_workshop()
			var ms := (Time.get_ticks_usec() - t0) / 1000
			await get_tree().create_timer(4.0).timeout
			var fonts := {}
			for w in _themed_windows():
				if w.visible:
					for c in _all_controls(w):
						var f = c.get_theme_font("font")
						if f:
							var k: String = f.get_class() + (" " + str(f.font_names) if f is SystemFont else "")
							fonts[k] = fonts.get(k, 0) + 1
			_say("show_workshop %d ms\nspikes after: %s\nfonts: %s" % [ms, ", ".join(PackedStringArray(_spikes)), str(fonts)])
		"wsitems":
			var svc = get_tree().root.get_node_or_null("DesktopPet/@Node@2")
			var o := ""
			if svc:
				for cat in ["browse", "subscribed"]:
					var items = svc.get_items(cat)
					o += "%s: %d items\n" % [cat, items.size()]
					if items.size() > 0:
						var it = items[0]
						for k in it:
							o += "  %s = %s\n" % [k, str(it[k]).left(110)]
				for pp in svc.get_script().get_script_property_list():
					if pp.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
						o += "v " + pp.name + " = " + str(svc.get(pp.name)).left(90) + "\n"
			_say(o)
		"wssignals":
			var svc = get_tree().root.get_node_or_null("DesktopPet/@Node@2")
			var o := ""
			for sg in svc.get_signal_list():
				var cons = svc.get_signal_connection_list(sg.name)
				if cons.size() > 0:
					var names := []
					for c in cons:
						names.append(str(c.callable.get_object()) + "::" + str(c.callable.get_method()))
					o += sg.name + " -> " + ", ".join(PackedStringArray(names)) + "\n"
			_say(o)
		"wsprobe":
			var w = get_tree().root.get_node_or_null("DesktopPet/@Window@153")
			var o := ""
			var keys = w.get("_preview_cache").keys()
			o += "cache %d, first: %s\n" % [keys.size(), str(keys[0]) if keys.size() > 0 else "-"]
			o += "svc first url: %s\n" % str(_ws_service.get("_items")["browse"][0]["preview_url"]) if _ws_service else "no svc\n"
			var t := Time.get_ticks_usec()
			w._render_items()
			o += "_render_items %d ms, cards=%d\n" % [(Time.get_ticks_usec() - t) / 1000, w.get("_grid").get_child_count()]
			_say(o)
		"wsrefresh":
			_spikes.clear()
			_restyle_ms = 0
			var t := Time.get_ticks_usec()
			_ws_service.refresh_all()
			var a := (Time.get_ticks_usec() - t) / 1000
			await get_tree().create_timer(5.0).timeout
			_say("refresh_all %d ms; restyle total %d ms; spikes: %s" % [a, _restyle_ms, ", ".join(PackedStringArray(_spikes))])
			_restyle_ms = 0
		"wsnorender":
			# те саме, але вікно Майстерні сховане (чи гальмує сама служба Steam)
			var w = get_tree().root.get_node_or_null("DesktopPet/@Window@153")
			w.hide()
			_spikes.clear()
			_ws_service.refresh_all()
			await get_tree().create_timer(5.0).timeout
			_say("hidden window; spikes: %s" % ", ".join(PackedStringArray(_spikes)))
		"subbench":
			var svc := _ws_service
			var o := ""
			var sig := []
			for sg in svc.get_script().get_script_signal_list():
				sig.append(sg.name + str(sg.args.map(func(x): return x.name)))
			o += "signals: " + str(sig) + "\n"
			var t := Time.get_ticks_usec()
			svc._rebuild_subscribed_content()
			o += "_rebuild_subscribed_content %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			pet._on_subscribed_characters_changed(svc.get_subscribed_characters())
			o += "pet._on_subscribed_characters_changed %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			svc._save_cached_subscriptions()
			o += "_save_cached_subscriptions %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			if _ws_render.is_valid():
				_ws_render.callv([null, null])
			o += "window render %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			svc.is_subscribed(3841007565)
			o += "is_subscribed %d us\n" % (Time.get_ticks_usec() - t)
			_say(o)
		"subbench2":
			var svc := _ws_service
			var st = svc.get("_steam")
			var o := ""
			var subs: Array = svc.get_items("subscribed")
			var t := Time.get_ticks_usec()
			var n := 0
			for it in subs:
				st.getItemInstallInfo(int(it["file_id"]))
				n += 1
			o += "getItemInstallInfo x%d: %d ms\n" % [n, (Time.get_ticks_usec() - t) / 1000]
			t = Time.get_ticks_usec()
			for it in subs:
				st.getItemState(int(it["file_id"]))
			o += "getItemState x%d: %d ms\n" % [n, (Time.get_ticks_usec() - t) / 1000]
			t = Time.get_ticks_usec()
			st.getSubscribedItems()
			o += "getSubscribedItems: %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			var files := 0
			for it in subs:
				var ip := str(it.get("install_path", ""))
				if ip != "":
					files += svc._find_files_recursive(ip, ".model3.json").size()
			o += "_find_files_recursive x%d: %d ms (%d model files)\n" % [n, (Time.get_ticks_usec() - t) / 1000, files]
			t = Time.get_ticks_usec()
			for it in subs:
				var ip := str(it.get("install_path", ""))
				if ip != "":
					FileAccess.get_file_as_string(ip.path_join("workshop_character.json"))
			o += "read workshop_character.json x%d: %d ms\n" % [n, (Time.get_ticks_usec() - t) / 1000]
			_say(o)
		"subbench3":
			var svc := _ws_service
			var o := ""
			var subs: Array = svc.get_items("subscribed")
			var t := Time.get_ticks_usec()
			var n := 0
			for it in subs:
				var ip := str(it.get("install_path", ""))
				if ip == "":
					continue
				var models: Array = svc._find_files_recursive(ip, ".model3.json")
				if models.size() > 0:
					svc._validate_model_package(ip, models[0])
					n += 1
			o += "_validate_model_package x%d: %d ms\n" % [n, (Time.get_ticks_usec() - t) / 1000]
			t = Time.get_ticks_usec()
			pet._refresh_native_character_checks()
			o += "_refresh_native_character_checks %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			pet._rebuild_context_menu()
			o += "_rebuild_context_menu %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			pet._all_characters()
			o += "_all_characters %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			t = Time.get_ticks_usec()
			pet._populate_menu(pet._context_menu) if false else null
			_say(o)
		"subbench4":
			var o := ""
			var cm: PopupMenu = pet._character_menu
			var t := Time.get_ticks_usec()
			for i in cm.item_count:
				if cm.is_item_checkable(i):
					cm.set_item_checked(i, cm.is_item_checked(i))
			o += "set_item_checked x%d: %d ms\n" % [cm.item_count, (Time.get_ticks_usec() - t) / 1000]
			var chars: Array = pet._all_characters()
			o += "chars %d, first: %s\n" % [chars.size(), str(chars[0]).left(150) if chars.size() > 0 else "-"]
			t = Time.get_ticks_usec()
			for c in chars:
				pet._character_display_name(c)
			o += "_character_display_name x%d: %d ms\n" % [chars.size(), (Time.get_ticks_usec() - t) / 1000]
			var sigs := []
			for cn in cm.get_signal_list():
				var cc = cm.get_signal_connection_list(cn.name)
				if cc.size() > 0:
					sigs.append(cn.name + ":" + str(cc.size()))
			o += "CharacterMenu signal conns: %s\n" % str(sigs)
			o += "tray popups: %s\n" % str(_all_popups(pet).map(func(x): return x.name + (" native" if x.prefer_native_menu else "")))
			_say(o)
		"rids":
			var o := ""
			for pp in pet.get_script().get_script_property_list():
				if pp.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
					var v = pet.get(pp.name)
					if typeof(v) == TYPE_RID or (typeof(v) == TYPE_DICTIONARY and str(v).contains("RID")) or (typeof(v) == TYPE_ARRAY and str(v).contains("RID")) or pp.name.contains("native") or pp.name.contains("tray"):
						o += "%s (%s) = %s\n" % [pp.name, type_string(typeof(v)), str(v).left(160)]
			var nm = NativeMenu
			o += "NativeMenu feature: %s\n" % str(nm.has_feature(NativeMenu.FEATURE_POPUP_MENU))
			_say(o)
		"subbench5":
			var o := ""
			var t := Time.get_ticks_usec()
			pet._refresh_native_character_checks()
			o += "refresh (as is) %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			var tcm: PopupMenu = pet._tray_character_menu
			var tc := tcm.item_count
			t = Time.get_ticks_usec()
			pet._character_menu.set_item_checked(1, pet._character_menu.is_item_checked(1))
			for k in 10:
				tcm.set_item_checked(1, tcm.is_item_checked(1))
			o += "10x tray set_item_checked %d ms (tray items %d, native=%s)\n" % [(Time.get_ticks_usec() - t) / 1000, tc, str(tcm.prefer_native_menu)]
			t = Time.get_ticks_usec()
			for k in 10:
				pet._character_menu.set_item_checked(1, pet._character_menu.is_item_checked(1))
			o += "10x ctx set_item_checked %d ms\n" % ((Time.get_ticks_usec() - t) / 1000)
			_say(o)
		"subbench6":
			var added := {}
			var cb := func(n): 
				var w = n.get_window()
				var k := str(w.title) if w else "?"
				added[k] = added.get(k, 0) + 1
			get_tree().node_added.connect(cb)
			var t := Time.get_ticks_usec()
			pet._refresh_native_character_checks()
			var ms := (Time.get_ticks_usec() - t) / 1000
			get_tree().node_added.disconnect(cb)
			var cnt := 0
			for c in pet.get_children():
				cnt += 1
			_say("refresh %d ms, nodes added: %s" % [ms, str(added)])
		"wsrender2":
			var w = get_tree().root.get_node_or_null("DesktopPet/@Window@153")
			_spikes.clear()
			var added := [0]
			var cb := func(_n): added[0] += 1
			get_tree().node_added.connect(cb)
			pet._refresh_native_character_checks()
			await get_tree().process_frame
			await get_tree().process_frame
			get_tree().node_added.disconnect(cb)
			_say("cards %d, nodes added %d, spikes %s\nstats %s" % [w.get("_grid").get_child_count(), added[0], ", ".join(PackedStringArray(_spikes)), str(w.get("lk_stats"))])
		"subtest":
			var svc := _ws_service
			var fid := 0
			var title := ""
			for it in svc.get_items("browse"):
				if not it.get("subscribed") and str(it.get("content_type")) == "character":
					fid = int(it["file_id"])
					title = str(it["title"])
					break
			_spikes.clear()
			svc.subscribe(fid)
			await get_tree().create_timer(8.0).timeout
			var s1 := ", ".join(PackedStringArray(_spikes))
			var subd: bool = svc.is_subscribed(fid)
			_spikes.clear()
			svc.unsubscribe(fid)
			await get_tree().create_timer(8.0).timeout
			_say("item %d '%s'\nsubscribe -> subscribed=%s, spikes: %s\nunsubscribe -> subscribed=%s, spikes: %s" % [fid, title, subd, s1, svc.is_subscribed(fid), ", ".join(PackedStringArray(_spikes))])
		"cardtest":
			var w = get_tree().root.get_node_or_null("DesktopPet/@Window@153")
			var grid = w.get("_grid")
			var o := ""
			var card: Node = null
			var target_fid = 0
			for c in grid.get_children():
				var fid = c.get_meta("lk_fid", 0)
				if not _ws_service.is_subscribed(int(fid)):
					card = c
					target_fid = fid
					break
			if card == null:
				_say("no card")
				return
			var btns := []
			for b in _all_controls(card):
				if b is Button:
					btns.append(b)
					o += "button '%s' disabled=%s conns=%s\n" % [b.text, b.disabled, str(b.pressed.get_connections().map(func(x): return str(x.callable.get_method())))]
			var act: Button = btns[-1] if btns.size() > 0 else null
			o += "press '%s' on %s\n" % [act.text, str(target_fid)]
			act.pressed.emit()
			await get_tree().create_timer(6.0).timeout
			o += "after: subscribed=%s\n" % str(_ws_service.is_subscribed(int(target_fid)))
			# повторно знайти картку (могла замінитись) і натиснути ще раз
			for c in grid.get_children():
				if c.get_meta("lk_fid", 0) == target_fid:
					var bb := []
					for b in _all_controls(c):
						if b is Button:
							bb.append(b)
					o += "card now: '%s'\n" % (bb[-1].text if bb.size() > 0 else "-")
					if bb.size() > 0:
						bb[-1].pressed.emit()
			await get_tree().create_timer(6.0).timeout
			o += "after 2nd press: subscribed=%s\n" % str(_ws_service.is_subscribed(int(target_fid)))
			_say(o)
		"closemenu":
			if _menu_win:
				_menu_win.close()
			_say("ok closemenu")
		"settings":
			pet._show_settings()
			_hook_themed_windows()
		"workshop":
			pet._show_workshop()
			_hook_themed_windows()
		"help":
			pet._show_help()
			_hook_themed_windows()
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
			var out := "емоції (можна змішувати будь-які; * — увімкнена):"
			var groups := expr_groups()
			for g in groups:
				out += "\n  [" + g["name"] + "]"
				for e in g["items"]:
					out += "\n    " + e + (" *" if is_expr_active(e) else "")
			if groups.is_empty():
				out += " (у цієї моделі немає)"
			out += "\nанімації:"
			if m:
				var ms = m.get_motions()
				for g in ms:
					out += "\n  " + str(g) + " x" + str(ms[g])
			_say(out)
		"show":
			pet._character_hidden = false
			pet._apply_character_visibility()
			pet._set_locked(false)
			_say("ok show")
		"theme":
			var tp := arg.split(" ", false)
			if tp.size() > 0 and tp[0] in ["light", "dark", "black"]:
				_theme.scheme = tp[0]
			if tp.size() > 1:
				_theme.accent = clampi(tp[1].to_int(), 0, PALETTE.size() - 1)
			if tp.size() > 2:
				_theme.second = clampi(tp[2].to_int(), 0, PALETTE.size() - 1)
			_save_theme()
			_restyle_all()
			_say("ok theme %s %d %d" % [_theme.scheme, _theme.accent, _theme.second])
		"spikes":
			_say("\n".join(_spikes))
			_spikes.clear()
		"bench8":
			var o := ""
			for names in [["Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI"], ["Segoe UI"], ["Noto Sans"], ["Tahoma"]]:
				for k in 2:
					var t := Time.get_ticks_usec()
					var sf := SystemFont.new()
					sf.font_names = PackedStringArray(names)
					var sz := sf.get_string_size("Item number 12", HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
					o += "%s #%d: %d us (w=%d)\n" % [str(names), k, Time.get_ticks_usec() - t, int(sz.x)]
			for nm in ["Microsoft YaHei UI", "Segoe UI", "Noto Sans", "Tahoma"]:
				var t2 := Time.get_ticks_usec()
				var path := OS.get_system_font_path(nm)
				o += "path %s -> %s (%d us)\n" % [nm, path, Time.get_ticks_usec() - t2]
			_say(o)
		"bench7":
			var w: Window = pet._pet_menu_window
			var o := ""
			w.show()
			var t := Time.get_ticks_usec()
			for i in 10:
				w.size = Vector2i(400, 300 + i * 20)
			o += "10x size (visible) %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			for i in 10:
				w.position = Vector2i(200 + i, 200)
			o += "10x position (visible) %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			for i in 10:
				var b := Button.new()
				b.text = "row %d" % i
				w.add_child(b)
			o += "10x add Button %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			for i in 10:
				w.mouse_passthrough_polygon = PackedVector2Array([Vector2(0,0), Vector2(100+i,0), Vector2(100,100), Vector2(0,100)])
			o += "10x passthrough polygon %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			for i in 10:
				w.min_size = Vector2i(10, 10 + i)
			o += "10x min_size %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			for i in 10:
				w.reset_size()
			o += "10x reset_size %d us\n" % (Time.get_ticks_usec() - t)
			w.hide()
			_say(o)
		"bench6":
			var w = pet._pet_menu_window
			var o := ""
			for kind in ["ascii", "ascii", "cyr", "cjk", "ascii5", "ascii60"]:
				var m := PopupMenu.new()
				add_child(m)
				var n := 33
				if kind == "ascii5":
					n = 5
				elif kind == "ascii60":
					n = 60
				for i in n:
					var txt := "Item number %d" % i
					if kind == "cyr":
						txt = "Пункт меню номер %d" % i
					elif kind == "cjk":
						txt = "八千代辉夜姬 %d" % i
					m.add_check_item(txt, i)
				var t := Time.get_ticks_usec()
				w.open_at(Vector2i(300, 300), m)
				var a := Time.get_ticks_usec() - t
				t = Time.get_ticks_usec()
				w.hide()
				o += "%s x%d: open %d us, hide %d us, nodes %d\n" % [kind, n, a, Time.get_ticks_usec() - t, _count(w)]
			_say(o)
		"fonttest":
			var w = pet._pet_menu_window
			w.open_at(Vector2i(300, 300), _small_menu())
			var sf: Font = null
			for c in _all_controls(w):
				var f = c.get_theme_font("font")
				if f is SystemFont:
					sf = f
			w.hide()
			var o := "systemfont found: %s\n" % str(sf != null)
			var txt := "八千代辉夜姬【雪熊企划】 Майстерня 金克丝Jinx"
			var t := Time.get_ticks_usec()
			if sf:
				sf.get_string_size(txt + str(randi()), HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
			o += "SystemFont string: %d us\n" % (Time.get_ticks_usec() - t)
			var ff := FontFile.new()
			var e := ff.load_dynamic_font("Z:/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc")
			o += "load noto err=%d name=%s\n" % [e, ff.get_font_name()]
			ff.allow_system_fallback = false
			t = Time.get_ticks_usec()
			ff.get_string_size(txt + str(randi()), HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
			o += "Noto FontFile string: %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			ff.get_string_size(txt + "x" + str(randi()), HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
			o += "Noto FontFile string2: %d us\n" % (Time.get_ticks_usec() - t)
			if sf:
				t = Time.get_ticks_usec()
				sf.get_string_size(txt + "y" + str(randi()), HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
				o += "SystemFont string2: %d us\n" % (Time.get_ticks_usec() - t)
			_say(o)
		"fonts":
			var o := ""
			var seen := {}
			var list := [ThemeDB.fallback_font]
			var pt = ThemeDB.get_project_theme()
			if pt and pt.default_font:
				list.append(pt.default_font)
			var w = pet._pet_menu_window
			w.open_at(Vector2i(300, 300), pet._settings_window.get_parent() if false else _small_menu())
			for c in _all_controls(w):
				list.append(c.get_theme_font("font"))
			w.hide()
			for c in _all_controls(pet._settings_window):
				list.append(c.get_theme_font("font"))
			for f in list:
				if f == null or seen.has(f.get_instance_id()):
					continue
				seen[f.get_instance_id()] = true
				o += "%s path=%s" % [f.get_class(), f.resource_path]
				if f is SystemFont:
					o += " names=%s" % str(f.font_names)
				if f is FontFile:
					o += " sysfallback=%s fallbacks=%d name=%s" % [f.allow_system_fallback, f.fallbacks.size(), f.get_font_name()]
				if f is FontVariation:
					o += " base=%s" % (f.base_font.get_class() if f.base_font else "null")
				o += "\n"
			_say(o)
		"bench5":
			var w = pet._pet_menu_window
			var o := ""
			var cm: PopupMenu = pet._context_menu
			o += "char items %d, icons: %s\n" % [pet._character_menu.item_count, str(pet._character_menu.get_item_icon(12) != null)]
			for k in ["chars", "chars", "ctx", "ctx_cached"]:
				var src: PopupMenu = pet._character_menu if k == "chars" else cm
				var t := Time.get_ticks_usec()
				w.open_at(Vector2i(300, 300), src)
				o += "open_at %s %d us, cached=%d\n" % [k, Time.get_ticks_usec() - t, w.get("_cached_submenus").size()]
				w.hide()
			_say(o)
		"bench4":
			var w = pet._pet_menu_window
			var small := PopupMenu.new()
			add_child(small)
			small.add_item("A", 1)
			small.add_item("B", 2)
			var o := ""
			for k in ["small", "small", "ctx"]:
				var src: PopupMenu = small if k == "small" else pet._context_menu
				var t := Time.get_ticks_usec()
				w.open_at(Vector2i(300, 300), src)
				o += "open_at %s %d us\n" % [k, Time.get_ticks_usec() - t]
				t = Time.get_ticks_usec()
				w.hide()
				o += "  hide %d us\n" % (Time.get_ticks_usec() - t)
			_say(o)
		"bench3":
			var w: Window = pet._pet_menu_window
			var o := "visible=%s flags: popup=%s transient=%s unfocusable=%s borderless=%s always_on_top=%s transparent=%s\n" % [w.visible, w.popup_window, w.transient, w.unfocusable, w.borderless, w.always_on_top, w.transparent]
			var steps := {
				"show": func(): w.show(),
				"size": func(): w.size = Vector2i(500, 600),
				"position": func(): w.position = Vector2i(200, 200),
				"grab_focus": func(): w.grab_focus(),
				"hide": func(): w.hide(),
				"show2": func(): w.show(),
				"hide2": func(): w.hide(),
			}
			for k in steps:
				var t := Time.get_ticks_usec()
				steps[k].call()
				o += "%s %d us\n" % [k, Time.get_ticks_usec() - t]
			_say(o)
		"bench2":
			var o := ""
			var tests := {
				"_refresh_wallpaper_menus": func(): pet._refresh_wallpaper_menus(),
				"_refresh_native_character_checks": func(): pet._refresh_native_character_checks(),
				"_get_desktop_wallpaper": func(): pet._get_desktop_wallpaper(),
				"screen_get_usable_rect": func(): DisplayServer.screen_get_usable_rect(),
				"screen_get_dpi": func(): DisplayServer.screen_get_dpi(),
				"screen_get_scale": func(): DisplayServer.screen_get_scale(),
				"mouse_get_position": func(): DisplayServer.mouse_get_position(),
				"_all_characters": func(): pet._all_characters(),
				"_rebuild_context_menu": func(): pet._rebuild_context_menu(),
				"measure ctx": func(): pet._pet_menu_window._measure_width(pet._context_menu, 320),
				"measure chars": func(): pet._pet_menu_window._measure_width(pet._character_menu, 280),
				"measure chars again": func(): pet._pet_menu_window._measure_width(pet._character_menu, 280),
				"open_at": func(): pet._pet_menu_window.open_at(Vector2i(300, 300), pet._context_menu),
				"open_at again": func(): pet._pet_menu_window.open_at(Vector2i(300, 300), pet._context_menu),
			}
			for k in tests:
				var t := Time.get_ticks_usec()
				tests[k].call()
				o += "%s %d us\n" % [k, Time.get_ticks_usec() - t]
			_say(o)
		"bench":
			var o := ""
			var t := Time.get_ticks_usec()
			_expr_files()
			o += "expr_files %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			_patch_context_menu(pet._tray_menu)
			o += "patch tray %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			_restyle_all()
			o += "restyle_all %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			_style_menu_window()
			o += "style_menu_window %d us\n" % (Time.get_ticks_usec() - t)
			t = Time.get_ticks_usec()
			pet._rebuild_context_menu()
			o += "game _rebuild_context_menu %d us\n" % (Time.get_ticks_usec() - t)
			o += "menu window nodes: %d\n" % _count(pet._pet_menu_window)
			_say(o)
		"inspect":
			_say(_inspect(pet))
		"menudump":
			_say("before:\n" + _menu_dump(pet._context_menu, 1))
			pet._show_context_menu(Vector2i(300, 300))
			var rows = pet._pet_menu_window.get("_rows")
			var o := "after:\n" + _menu_dump(pet._context_menu, 1) + "rows: " + str(rows.size() if rows else -1) + "\n"
			for r in (rows if rows else []):
				o += "  " + str(r).left(120) + "\n"
			_say(o)
		"dumpnode":
			var n := get_tree().root.get_node_or_null(arg)
			if n == null:
				_say("no node " + arg)
			else:
				var o := "%s [%s]\n" % [n.name, n.get_class()]
				var sc = n.get_script()
				if sc:
					for m in sc.get_script_method_list():
						var a := []
						for x in m.args:
							a.append(x.name)
						o += "  m " + m.name + "(" + ",".join(a) + ")\n"
					for pp in sc.get_script_property_list():
						if pp.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
							o += "  v " + pp.name + " = " + str(n.get(pp.name)).left(80) + "\n"
					for sg in sc.get_script_signal_list():
						o += "  s " + sg.name + "\n"
				o += _ctl_dump(n, 1)
				_say(o)
		_:
			_say("unknown: " + line)

# ───────────── Шрифти: головна причина «фрізів» меню під Wine ─────────────
# Меню й вікна гри малюються SystemFont("Microsoft YaHei UI", "Segoe UI"). Під Wine таких шрифтів
# немає, і для кожного нового рядка (особливо з китайськими/японськими іменами з Майстерні) Godot
# питає Wine про системні шрифти — ~50 мс на рядок, меню відкривалось 2-20 с. Підміняємо SystemFont
# на Noto Sans CJK з Linux (є латиниця, кирилиця, CJK) без пошуку системних шрифтів — ~0.1 мс на рядок.
const NOTO := {400: "Z:/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	500: "Z:/usr/share/fonts/noto-cjk/NotoSansCJK-Medium.ttc",
	700: "Z:/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc"}
var _noto := {}
var _fonts_ok := false

func _noto_font(weight: int) -> Font:
	var w := 700 if weight >= 650 else (500 if weight >= 500 else 400)
	if _noto.has(w):
		return _noto[w]
	# гра йде в контейнері Steam: шрифти хоста там у /run/host/fonts, тож шляхи питаємо в системи.
	# Основний — Noto Sans (латиниця + повна кирилиця з і/ї/є/ґ), запасний — Noto Sans CJK (китайські/японські імена).
	var base := _font_from(OS.get_system_font_path("Noto Sans", w))
	var cjk := _font_from(OS.get_system_font_path("Noto Sans CJK SC", w))
	if base == null:
		base = cjk
		cjk = null
	if base == null:
		_noto[w] = ThemeDB.fallback_font
		return ThemeDB.fallback_font
	if cjk:
		base.fallbacks = [cjk]
	_noto[w] = base
	return base

func _font_from(path: String) -> FontFile:
	if path == "":
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() == 0:
		return null
	var ff := FontFile.new()
	ff.data = bytes
	ff.allow_system_fallback = false
	return ff

func _swap_font(f: Font) -> Font:
	if f is SystemFont:
		return _noto_font(f.font_weight)
	return null

func _fix_theme(th: Theme) -> void:
	if th == null or th.has_meta("lk_fonts"):
		return
	th.set_meta("lk_fonts", true)
	var r := _swap_font(th.default_font)
	if r:
		th.default_font = r
	for t in th.get_font_type_list():
		for n in th.get_font_list(t):
			var rr := _swap_font(th.get_font(n, t))
			if rr:
				th.set_font(n, t, rr)

func _fix_node_font(n: Node) -> void:
	if n is Window or n is Control:
		_fix_theme(n.theme)
		if n is Control:
			for key in ["font", "normal_font", "bold_font"]:
				if n.has_theme_font_override(key):
					var r := _swap_font(n.get_theme_font(key))
					if r:
						n.add_theme_font_override(key, r)
			var cur: Font = n.get_theme_font("font")
			var r2 := _swap_font(cur)
			if r2:
				n.add_theme_font_override("font", r2)
		elif n is Window:
			var cur: Font = n.get_theme_font("font")
			var r3 := _swap_font(cur)
			if r3:
				n.add_theme_font_override("font", r3)

func _fix_fonts_tree(n: Node) -> void:
	_fix_node_font(n)
	for c in n.get_children():
		_fix_fonts_tree(c)

func _fonts_setup() -> void:
	if not FileAccess.file_exists(NOTO[400]):
		return
	_fonts_ok = true
	# запасний шрифт рушія (Open Sans) теж не повинен шукати системні шрифти через Wine
	var fb := ThemeDB.fallback_font
	if fb is FontFile:
		fb.allow_system_fallback = false
		var arr := fb.fallbacks
		arr.append(_noto_font(400))
		fb.fallbacks = arr
	_fix_theme(ThemeDB.get_project_theme())
	_fix_theme(ThemeDB.get_default_theme())
	get_tree().node_added.connect(_fix_node_font)
	_fix_fonts_tree.call_deferred(get_tree().root)

# ───────────── Меню й налаштування гри під Linux/niri ─────────────
# Контекстне меню (правий клік по героїні): без шпалер (на niri тло малює swaybg), зате з підменю
# «Розмір», «Емоції» (якщо в моделі є *.exp3.json) і «Відображення» (поверх вікон, частота кадрів).
# Вікно налаштувань: без «значка на панелі завдань» і «шпалер»; «Запускати з Windows» →
# «Запускати разом із системою» (прапорець user://linux_autostart, його перевіряє niri при старті).
const AUTOSTART_FLAG := "user://linux_autostart"
const SIZES := [0.55, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
var _ui_ready := false
var _size_menu: PopupMenu
var _expr_menu: PopupMenu
var _view_menu: PopupMenu
var _expr_names: Array = []

func _loc() -> bool:
	return str(_pet().get("_locale")).begins_with("uk")

func _t(uk: String, en: String) -> String:
	return uk if _loc() else en

func _linux_ui_setup() -> void:
	var pet := _pet()
	if pet == null or pet.get("_context_menu") == null:
		get_tree().create_timer(0.5).timeout.connect(_linux_ui_setup)
		return
	if _ui_ready:
		return
	_ui_ready = true
	var cm: PopupMenu = pet._context_menu
	_theme_setup(cm)
	cm.about_to_popup.connect(_patch_context_menu.bind(cm))
	# швидке меню: підміняємо скрипт ігрового вікна меню — гра сама вирішує, коли показати меню,
	# а показуємо його ми рідним PopupMenu (див. linux_menu_window.gd)
	var pmw = pet.get("_pet_menu_window")
	if pmw and FileAccess.file_exists("user://linux_menu_window.gd"):
		pmw.hide()
		for ch in pmw.get_children():
			ch.queue_free()
		pmw.set_script(load("user://linux_menu_window.gd"))
		pmw.set("linux", self)
	# гра показує меню власним вікном PetMenuWindow, яке будує пункти з cm у момент open_at —
	# тож cm має бути підготовлене заздалегідь (і після кожної перебудови грою)
	_patch_context_menu(cm)

	if pet.get("_tray_menu"):
		var tm: PopupMenu = pet._tray_menu
		tm.about_to_popup.connect(_patch_context_menu.bind(tm))
	# налаштування
	var t: CheckButton = pet._autostart_toggle
	for c in t.toggled.get_connections():
		t.toggled.disconnect(c.callable)
	t.toggled.connect(_on_linux_autostart)
	pet._settings_window.visibility_changed.connect(_patch_settings)
	_hook_themed_windows.call_deferred()
	_swap_workshop_script.call_deferred()
	_hook_workshop_previews.call_deferred()
	_no_native_menus.call_deferred()
	_fix_font(ThemeDB.fallback_font)
	var pt := ThemeDB.get_project_theme()
	if pt:
		_fix_font(pt.default_font)
	get_tree().node_added.connect(_on_node_added_theme)
	_load_keys()
	_locked = FileAccess.file_exists("user://linux_lock")
	_apply_lock()
	get_tree().root.window_input.connect(_on_root_click)
	_patch_settings()
	_restyle_all()

# ───────────── Швидке контекстне меню ─────────────
# Ігрове вікно меню (PetMenuWindow) при розкладці багато разів створює SystemFont на кожен пункт —
# під Wine це 2-20 мс за раз, і меню відкривалось секундами (і довше з кожним разом). Тож правий клік
# по героїні перехоплюємо й показуємо рідне PopupMenu рушія з тими самими пунктами й діями гри
# (id_pressed уже під'єднаний до _on_menu_item_pressed гри) — воно будується за мілісекунди.
# Під xwayland-satellite кожне X-вікно гри стоїть у (0,0), а Wine рахує координати миші від того
# місця, де, на його думку, вікно стоїть. Тож меню й підменю «ставимо» для Wine в (0,0) — тоді
# кліки й наведення збігаються з картинкою; на екрані їх розміщує niri-pin (біля курсора / праворуч).
var _menu_win: Window
var _keys_menu: PopupMenu

# ───────────── приховати/показати, блокування, гарячі клавіші ─────────────
# Гарячі клавіші живуть у niri: гра пише їх у user://linux_keys.json, служба yw-gaze перебудовує
# ~/.config/niri/yourwife-keys.kdl (і перевіряє niri validate). Формат — як у niri: "Mod+Ctrl+Y".
var _keys := {"hide": "Mod+Ctrl+Y", "menu": ""}
var _locked := false
const KEYS_FILE := "user://linux_keys.json"

func _load_keys() -> void:
	if FileAccess.file_exists(KEYS_FILE):
		var d = JSON.parse_string(FileAccess.get_file_as_string(KEYS_FILE))
		if typeof(d) == TYPE_DICTIONARY:
			for k in d:
				_keys[k] = str(d[k])
	else:
		_save_keys()

func _save_keys() -> void:
	var f := FileAccess.open(KEYS_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_keys))
		f.close()

func get_hotkey(name: String) -> String:
	return str(_keys.get(name, ""))

func set_hotkey(name: String, combo: String) -> void:
	_keys[name] = combo
	_save_keys()
	var pet := _pet()
	if pet:
		for m in [pet._context_menu, pet.get("_tray_menu")]:
			if m:
				_patch_context_menu(m)
	_patch_settings()

func pretty_key(combo: String) -> String:
	if combo == "":
		return _t("не задано", "not set")
	return combo.replace("+", " + ")

func _key_hint(name: String) -> String:
	var k := get_hotkey(name)
	return "" if k == "" else "  [" + pretty_key(k) + "]"

# вибір персонажа з меню: стара модель плавно зникає, далі гра вантажить нову, нова плавно з'являється
func fade_switch(cb: Callable) -> void:
	var pet := _pet()
	_expr.clear()
	_active.clear()
	_expr_name = ""
	var tw := create_tween()
	tw.tween_property(pet, "modulate:a", 0.0, 0.15)
	await tw.finished
	await get_tree().process_frame
	await get_tree().process_frame
	cb.call()
	await get_tree().process_frame
	var tw2 := create_tween()
	tw2.tween_property(pet, "modulate:a", 1.0, 0.25)

# Найбільший безпечний розмір: вікно героїні не вище за 2 екрани. Більше гра виносить вікно за
# екран і ховає його, а Vulkan під XWayland чекає видимого вікна — гра зависала.
func max_safe_scale() -> float:
	var pet := _pet()
	var cur: float = max(float(pet._character_scale), 0.01)
	var win := DisplayServer.window_get_size()
	var base_h := float(win.y) / cur
	var lim := 4.5
	if base_h > 0:
		lim = minf(4.5, (DisplayServer.screen_get_size().y * 2.0) / base_h)
	return maxf(lim, 0.6)

func safe_resize(s: float) -> void:
	var pet := _pet()
	pet._resize_character(clampf(s, 0.55, max_safe_scale()))
	pet._save_preferences()

func toggle_hide() -> void:
	var pet := _pet()
	if bool(pet._character_hidden):
		pet._character_hidden = false
		pet._apply_character_visibility()
	else:
		pet._on_menu_item_pressed(10)   # логіка гри «Приховати персонажа»
	pet._save_preferences()

# Блокування на Linux: героїня лишається на поточному робочому столі niri (niri-pin перестає
# переносити її за тобою). Стан — файл user://linux_lock, його перевіряє niri-pin. Перемикач —
# пункт меню або подвійний клік по героїні.
func toggle_lock() -> void:
	_locked = not _locked
	if _locked:
		var f := FileAccess.open("user://linux_lock", FileAccess.WRITE)
		if f:
			f.store_string("1")
			f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://linux_lock"))
	_apply_lock()

func is_locked() -> bool:
	return _locked

func _apply_lock() -> void:
	var pet := _pet()
	if pet == null:
		return
	pet.set_process_input(true)
	pet.set_process_unhandled_input(true)
	pet.modulate.a = 1.0

var _last_click_ms := 0
var _last_click_pos := Vector2(-999, -999)
func _on_root_click(e: InputEvent) -> void:
	if not (e is InputEventMouseButton) or e.button_index != MOUSE_BUTTON_LEFT or not e.pressed:
		return
	var now := Time.get_ticks_msec()
	if now - _last_click_ms < 380 and e.position.distance_to(_last_click_pos) < 8:
		_last_click_ms = 0
		toggle_lock()
	else:
		_last_click_ms = now
		_last_click_pos = e.position
func show_native_menu(source: PopupMenu, _point) -> void:
	_patch_context_menu(source)
	if _menu_win == null and FileAccess.file_exists("user://linux_menu.gd"):
		_menu_win = load("user://linux_menu.gd").new()
		_menu_win.lk = self
		get_tree().root.add_child(_menu_win)
	if _menu_win:
		_menu_win.open_menu(source)
		return
	_pin_popups_to_origin(source)
	if source.visible:
		source.hide()
	source.popup(Rect2i(Vector2i.ZERO, Vector2i.ZERO))

# кольори й стилі для меню (linux_menu.gd) за поточною схемою «Вигляд меню»
var _mstyle_cache := {}
var _mstyle_key := ""
func menu_color(what: String) -> Color:
	var sc := _scheme_colors()
	var acc: Color = PALETTE[_theme.accent][2]
	var sec: Color = PALETTE[_theme.second][2]
	if sc.is_empty():   # світла, як у грі
		return {"text": Color("#4a3b43"), "hover_text": Color("#c2416f"), "dim": Color("#a3929b"),
			"second": Color("#b48a9b"), "line": Color("#f0d3dd")}.get(what, Color.WHITE)
	return {"text": sc.text, "hover_text": acc.lightened(0.35), "dim": sc.dim,
		"second": sec, "line": sec.darkened(0.35)}.get(what, Color.WHITE)

func menu_box(what: String) -> StyleBox:
	var key := "%s|%d|%d" % [_theme.scheme, _theme.accent, _theme.second]
	if key != _mstyle_key:
		_mstyle_cache.clear()
		_mstyle_key = key
	if _mstyle_cache.has(what):
		return _mstyle_cache[what]
	var sc := _scheme_colors()
	var acc: Color = PALETTE[_theme.accent][2]
	var sb: StyleBox
	match what:
		"panel":
			if sc.is_empty():
				sb = _box(Color("#fffafc"), 16, Color("#f3c7d6"))
			else:
				sb = _box(sc.bg, 16, acc.darkened(0.55))
			sb.content_margin_left = 10; sb.content_margin_right = 10
			sb.content_margin_top = 10; sb.content_margin_bottom = 10
		"hover":
			var h := Color("#ffdce8") if sc.is_empty() else Color(acc.r, acc.g, acc.b, 0.28)
			sb = _box(h, 10)
		_:
			sb = _box(Color(0, 0, 0, 0), 10)
	_mstyle_cache[what] = sb
	return sb

func _pin_popups_to_origin(m: PopupMenu) -> void:
	if not m.has_meta("lk_origin"):
		m.set_meta("lk_origin", true)
		m.about_to_popup.connect(func(): m.set_deferred("position", Vector2i.ZERO))
		m.popup_window = true
	for c in m.get_children():
		if c is PopupMenu:
			_pin_popups_to_origin(c)

func _show_fast_menu(pet: Node, at: Vector2) -> void:
	var t := Time.get_ticks_usec()
	var cm: PopupMenu = pet._context_menu
	if pet.has_method("_refresh_native_character_checks"):
		pet._refresh_native_character_checks()
	_patching = true
	_patch_context_menu(cm)
	_patching = false
	var pos := DisplayServer.window_get_position() + Vector2i(at)
	cm.popup(Rect2i(pos, Vector2i.ZERO))
	_last_menu_us = Time.get_ticks_usec() - t

var _last_menu_us := 0

# гра перебудовує cm прямо перед показом (оновлює список персонажів) і затирала наші зміни.
# PopupMenu.menu_changed спрацьовує на кожен доданий пункт; щойно з'явився останній («Версія», id 6) —
# правимо меню, ще до того як вікно меню побудує з нього пункти.
var _patching := false
func _log(msg: String) -> void:
	var sf := FileAccess.open("user://linux_spikes.txt", FileAccess.READ_WRITE if FileAccess.file_exists("user://linux_spikes.txt") else FileAccess.WRITE)
	if sf:
		sf.seek_end()
		sf.store_line("%d %s" % [Time.get_ticks_msec(), msg])
		sf.close()

var _mc_count := 0
func _on_menu_changed(cm: PopupMenu) -> void:
	_last_event = "menu_changed"
	_mc_count += 1
	if _patching or cm.get_item_index(6) < 0 or FileAccess.file_exists("user://linux_nopatch"):
		return
	if cm.get_item_index(9) >= 0 or cm.get_item_index(9101) < 0:
		_patching = true
		var t := Time.get_ticks_usec()
		_patch_context_menu(cm)
		_log("patch %s %d us (menu_changed calls so far %d)" % [cm.name, Time.get_ticks_usec() - t, _mc_count])
		_patching = false

func _ensure_menu_patched() -> void:
	if not _ui_ready:
		return
	# лише якщо наших пунктів немає (гра перебудувала меню) — без «пінг-понгу» з грою
	for cm in [_pet()._context_menu, _pet().get("_tray_menu")]:
		if cm and cm.get_item_index(9101) < 0:
			_patch_context_menu(cm)

func _style_menu_window() -> void:
	var pmw = _pet().get("_pet_menu_window")
	if pmw == null:
		return
	_style_menu_controls(pmw, _scheme_colors(), PALETTE[_theme.accent][2], PALETTE[_theme.second][2])

func _style_menu_controls(n: Node, sc: Dictionary, acc: Color, sec: Color) -> void:
	for c in n.get_children():
		if c is Panel or c is PanelContainer:
			if sc.is_empty():
				c.remove_theme_stylebox_override("panel")
			else:
				c.add_theme_stylebox_override("panel", _box(sc.bg, 14, acc.darkened(0.55)))
		elif c is ColorRect:
			if not c.has_meta("orig_color"):
				c.set_meta("orig_color", c.color)
			c.color = c.get_meta("orig_color") if sc.is_empty() else sc.bg
		elif c is Button:
			var keys := ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color", "font_hover_pressed_color"]
			var sts := ["normal", "hover", "pressed", "focus", "hover_pressed", "disabled"]
			if sc.is_empty():
				for k in keys:
					c.remove_theme_color_override(k)
				for st in sts:
					c.remove_theme_stylebox_override(st)
			else:
				var h := acc
				h.a = 0.28
				c.add_theme_color_override("font_color", sc.text)
				c.add_theme_color_override("font_focus_color", sc.text)
				c.add_theme_color_override("font_hover_color", acc.lightened(0.35))
				c.add_theme_color_override("font_pressed_color", acc.lightened(0.35))
				c.add_theme_color_override("font_hover_pressed_color", acc.lightened(0.35))
				c.add_theme_color_override("font_disabled_color", sc.dim)
				c.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0), 9))
				c.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
				c.add_theme_stylebox_override("disabled", _box(Color(0, 0, 0, 0), 9))
				c.add_theme_stylebox_override("hover", _box(h, 9))
				c.add_theme_stylebox_override("pressed", _box(h, 9))
				c.add_theme_stylebox_override("hover_pressed", _box(h, 9))
		elif c is Label:
			if not c.has_meta("orig_font"):
				c.set_meta("orig_font", c.get_theme_color("font_color"))
			if sc.is_empty():
				c.remove_theme_color_override("font_color")
			else:
				# дрібні приглушені підписи (заголовки розділів, версія) — другим кольором
				var orig: Color = c.get_meta("orig_font")
				c.add_theme_color_override("font_color", sec if orig.v > 0.45 and orig.v < 0.8 else sc.text)
		elif c is HSeparator or c is VSeparator:
			if sc.is_empty():
				c.remove_theme_stylebox_override("separator")
			else:
				var ln := StyleBoxLine.new()
				ln.color = sec.darkened(0.35)
				c.add_theme_stylebox_override("separator", ln)
		_style_menu_controls(c, sc, acc, sec)

func _strip_wallpaper(pm: PopupMenu) -> void:
	var i := pm.get_item_index(9)          # «Вибрати шпалери»
	if i >= 0:
		pm.remove_item(i)

# у кожного меню (контекстне й трею) — власний набір підменю: вузол не може мати двох батьків
var _sets := {}
func _use_set(cm: PopupMenu) -> void:
	var k := cm.get_instance_id()
	if not _sets.has(k):
		var st := {}
		for nm in ["size", "expr", "view", "theme", "keys"]:
			var m := PopupMenu.new()
			m.name = "Linux_" + nm
			cm.add_child(m)
			st[nm] = m
		st.accent = PopupMenu.new(); st.accent.name = "Linux_accent"; st.theme.add_child(st.accent)
		st.second = PopupMenu.new(); st.second.name = "Linux_second"; st.theme.add_child(st.second)
		st.size.id_pressed.connect(_on_size_pressed)
		st.expr.id_pressed.connect(_on_expr_pressed)
		st.view.id_pressed.connect(_on_view_pressed)
		st.theme.id_pressed.connect(_on_theme_pressed)
		st.accent.id_pressed.connect(func(id): _theme.accent = id; _save_theme(); _restyle_all())
		st.second.id_pressed.connect(func(id): _theme.second = id; _save_theme(); _restyle_all())
		_sets[k] = st
		_style_tree_popups(cm)
	var cur: Dictionary = _sets[k]
	_size_menu = cur.size; _expr_menu = cur.expr; _view_menu = cur.view
	_theme_menu = cur.theme; _accent_menu = cur.accent; _second_menu = cur.second
	_keys_menu = cur["keys"]

func _patch_context_menu(cm: PopupMenu) -> void:
	_use_set(cm)
	_strip_wallpaper(cm)
	var ih := cm.get_item_index(10)
	if ih >= 0:
		cm.set_item_text(ih, _t("Приховати/Показати персонажа", "Hide/Show character") + _key_hint("hide"))
	var il := cm.get_item_index(3)
	if il >= 0:
		cm.set_item_text(il, _t("Заблокувати/Розблокувати персонажа [Подвійний клік по персонажу]",
			"Lock/Unlock character [Double-click the character]"))
	for id in [9101, 9102, 9103, 9104, 9105]:
		var i := cm.get_item_index(id)
		while i >= 0:
			cm.remove_item(i)
			i = cm.get_item_index(id)
	var after := cm.get_item_index(7)       # після «Виберіть Символ»
	var pos := after + 1 if after >= 0 else 1
	_fill_size_menu()
	cm.add_submenu_node_item(_t("Розмір", "Size"), _size_menu, 9101)
	cm.set_item_index(cm.get_item_index(9101), pos)
	pos += 1
	if _fill_expr_menu():
		cm.add_submenu_node_item(_t("Емоції", "Emotions"), _expr_menu, 9102)
		cm.set_item_index(cm.get_item_index(9102), pos)
		pos += 1
	_fill_view_menu()
	cm.add_submenu_node_item(_t("Відображення", "Display"), _view_menu, 9103)
	cm.set_item_index(cm.get_item_index(9103), pos)
	pos += 1
	_fill_theme_menu()
	cm.add_submenu_node_item(_t("Вигляд меню", "Menu style"), _theme_menu, 9104)
	cm.set_item_index(cm.get_item_index(9104), pos)
	pos += 1
	_keys_menu.clear()
	_keys_menu.add_item("keys", 0)          # вміст малює linux_menu.gd (поля для зміни клавіш)
	cm.add_submenu_node_item(_t("Гарячі клавіші", "Hotkeys"), _keys_menu, 9105)
	cm.set_item_index(cm.get_item_index(9105), pos)

func _fill_size_menu() -> void:
	_size_menu.clear()
	var cur: float = _pet()._character_scale
	for i in SIZES.size():
		_size_menu.add_radio_check_item("%d%%" % int(round(SIZES[i] * 100)), i)
		_size_menu.set_item_checked(i, absf(SIZES[i] - cur) < 0.03)
	_size_menu.add_separator()
	_size_menu.add_item(_t("Більше  (+10%)", "Bigger  (+10%)"), 100)
	_size_menu.add_item(_t("Менше  (−10%)", "Smaller  (−10%)"), 101)

func _on_size_pressed(id: int) -> void:
	var pet := _pet()
	var s: float = pet._character_scale
	if id < SIZES.size():
		s = SIZES[id]
	elif id == 100:
		s *= 1.1
	elif id == 101:
		s /= 1.1
	safe_resize(s)

func _fill_expr_menu() -> bool:
	_expr_menu.clear()
	var names := _expr_files().keys()
	names.sort()
	_expr_names = names
	if names.is_empty():
		return false
	_expr_menu.add_radio_check_item(_t("Без емоції", "No emotion"), 0)
	_expr_menu.set_item_checked(0, _expr_name == "")
	_expr_menu.add_separator()
	for i in names.size():
		_expr_menu.add_radio_check_item(names[i], i + 1)
		_expr_menu.set_item_checked(_expr_menu.get_item_index(i + 1), names[i] == _expr_name)
	return true

func _on_expr_pressed(id: int) -> void:
	if id == 0:
		_set_expression("off")
	elif id - 1 < _expr_names.size():
		_set_expression(_expr_names[id - 1])

func _fill_view_menu() -> void:
	var pet := _pet()
	_view_menu.clear()
	_view_menu.add_check_item(_t("Поверх усіх вікон", "Always on top"), 0)
	_view_menu.set_item_checked(0, bool(pet._always_on_top))
	_view_menu.add_separator(_t("Частота кадрів", "Frame rate"))
	_view_menu.add_radio_check_item(_t("30 к/с — економія заряду", "30 FPS — saves battery"), 30)
	_view_menu.add_radio_check_item(_t("60 к/с — плавніше", "60 FPS — smoother"), 60)
	_view_menu.set_item_checked(_view_menu.get_item_index(30), Engine.max_fps == 30)
	_view_menu.set_item_checked(_view_menu.get_item_index(60), Engine.max_fps != 30)

func _on_view_pressed(id: int) -> void:
	var pet := _pet()
	if id == 0:
		pet._on_topmost_toggled(not bool(pet._always_on_top))
		if pet._topmost_toggle:
			pet._topmost_toggle.set_pressed_no_signal(bool(pet._always_on_top))
	elif id == 30 or id == 60:
		_set_fps(id)

func _set_fps(fps: int) -> void:
	Engine.max_fps = fps
	# зберегти в override.cfg поруч із грою (на наступні запуски)
	var path := OS.get_executable_path().get_base_dir().path_join("override.cfg")
	var txt := FileAccess.get_file_as_string(path)
	# лише замінити/додати run/max_fps у секції [application], решту (boot_splash тощо) не чіпати
	var lines := Array(txt.split("\n"))
	var done := false
	for k in lines.size():
		if str(lines[k]).begins_with("run/max_fps="):
			lines[k] = "run/max_fps=%d" % fps
			done = true
	if not done:
		var at := lines.find("[application]")
		if at >= 0:
			lines.insert(at + 2 if at + 1 < lines.size() and lines[at + 1] == "" else at + 1, "run/max_fps=%d" % fps)
		else:
			lines.append_array(["", "[application]", "", "run/max_fps=%d" % fps])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines))
		f.close()

func _patch_settings() -> void:
	var pet := _pet()
	if pet == null:
		return
	# сховати рядки, які на niri не мають сенсу: значок на панелі завдань і шпалери
	for lbl in [pet._taskbar_icon_label, pet._wallpaper_label]:
		if lbl:
			var row: Control = lbl.get_parent()
			row.visible = false
			var idx := row.get_index()
			var box := row.get_parent()
			if idx + 1 < box.get_child_count() and box.get_child(idx + 1) is HSeparator:
				box.get_child(idx + 1).visible = false
	if pet._autostart_label:
		pet._autostart_label.text = _t("Запускати разом із системою", "Start with the system")
	if pet._autostart_toggle:
		pet._autostart_toggle.set_pressed_no_signal(FileAccess.file_exists(AUTOSTART_FLAG))
	_settings_fit(pet)
	if pet._settings_window.visible:
		_style_settings(pet._settings_window)

# Вікно налаштувань: заголовок переносимо (інакше довгий рядок розпирає вікно і все обрізається),
# додаємо рядки гарячих клавіш, а висоту підганяємо під вміст.
var _key_rows := {}
func _settings_fit(pet: Node) -> void:
	var w: Window = pet._settings_window
	if w == null:
		return
	var heading = pet.get("_settings_heading")
	if heading is Label:
		heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		heading.custom_minimum_size.x = 1
		heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var anchor: Control = pet._autostart_label.get_parent() if pet._autostart_label else null
	if anchor and _key_rows.is_empty():
		var box := anchor.get_parent()
		var at := anchor.get_index() + 1
		for k in ["menu", "hide"]:
			var sep := HSeparator.new()
			box.add_child(sep)
			box.move_child(sep, at)
			at += 1
			var row := HBoxContainer.new()
			var lbl := Label.new()
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lbl.add_theme_font_override("font", pet._autostart_label.get_theme_font("font"))
			lbl.add_theme_font_size_override("font_size", pet._autostart_label.get_theme_font_size("font_size"))
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(190, 40)
			btn.pressed.connect(_capture_key.bind(w, k, btn))
			row.add_child(lbl)
			row.add_child(btn)
			box.add_child(row)
			box.move_child(row, at)
			at += 1
			_key_rows[k] = [lbl, btn]
	for k in _key_rows:
		var lbl: Label = _key_rows[k][0]
		var btn: Button = _key_rows[k][1]
		lbl.text = _t("Відкрити меню клавішами", "Open menu with keys") if k == "menu" else _t("Приховати/Показати персонажа", "Hide/Show character")
		btn.text = pretty_key(get_hotkey(k))
	if w.visible:
		_fit_window.call_deferred(w)

func _fit_window(w: Window) -> void:
	await get_tree().process_frame
	var need := Vector2i(w.get_contents_minimum_size())
	var target := Vector2i(maxi(720, need.x), maxi(need.y, 300))
	if w.min_size.y > target.y:
		w.min_size = Vector2i(w.min_size.x, target.y)
	if w.size != target:
		w.size = target
	report_window_size(w)

# Вікна гри, крім головного: бажаний розмір пишемо у файл, yw-gaze виставляє його через niri
# (сама гра змінити розмір свого вікна під XWayland не може).
func report_window_size(w: Window) -> void:
	var f := FileAccess.open("user://linux_winsize_" + str(w.title.hash()) + ".txt", FileAccess.WRITE)
	if f:
		f.store_string("%d %d %s\n" % [w.size.x, w.size.y, w.title])
		f.close()

# Захоплення комбінації: наступне натискання з модифікаторами у вікні w стає гарячою клавішею.
# Esc — скасувати, Backspace/Delete — прибрати клавішу.
var _capture_cb: Callable
func _capture_key(w: Window, name: String, btn: Button) -> void:
	btn.text = _t("Натисніть комбінацію…", "Press a combination…")
	if _capture_cb.is_valid() and w.window_input.is_connected(_capture_cb):
		w.window_input.disconnect(_capture_cb)
	_capture_cb = func(e: InputEvent):
		if not (e is InputEventKey) or not e.pressed or e.echo:
			return
		if e.keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			return
		w.window_input.disconnect(_capture_cb)
		w.set_input_as_handled()
		if e.keycode == KEY_ESCAPE:
			btn.text = pretty_key(get_hotkey(name))
			return
		if e.keycode in [KEY_BACKSPACE, KEY_DELETE]:
			set_hotkey(name, "")
			btn.text = pretty_key("")
			return
		var parts := []
		if e.meta_pressed: parts.append("Mod")
		if e.ctrl_pressed: parts.append("Ctrl")
		if e.alt_pressed: parts.append("Alt")
		if e.shift_pressed: parts.append("Shift")
		var kn := OS.get_keycode_string(e.keycode)
		if kn == "":
			kn = OS.get_keycode_string(e.physical_keycode)
		parts.append(kn)
		var combo := "+".join(parts)
		set_hotkey(name, combo)
		btn.text = pretty_key(combo)
	w.window_input.connect(_capture_cb)

func _on_linux_autostart(on: bool) -> void:
	if on:
		var f := FileAccess.open(AUTOSTART_FLAG, FileAccess.WRITE)
		if f:
			f.store_string("1\n")
			f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(AUTOSTART_FLAG))

# ───────────── Вигляд меню: схема (світла/темна/чорна) і два кольори ─────────────
const THEME_FILE := "user://linux_theme.json"
const PALETTE := [
	["Червоний", "Red", Color("#e8574a")], ["Рожевий", "Pink", Color("#f27ea6")],
	["Фіолетовий", "Purple", Color("#a77bf3")], ["Синій", "Blue", Color("#5b8def")],
	["Бірюзовий", "Teal", Color("#3cc6c0")], ["Зелений", "Green", Color("#5fbf6a")],
	["Золотий", "Gold", Color("#e0b44c")], ["Білий", "White", Color("#e9e9ee")],
]
var _theme := {"scheme": "light", "accent": 0, "second": 7}
var _theme_menu: PopupMenu
var _accent_menu: PopupMenu
var _second_menu: PopupMenu

func _load_theme() -> void:
	if not FileAccess.file_exists(THEME_FILE):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(THEME_FILE))
	if typeof(d) == TYPE_DICTIONARY:
		for k in d:
			_theme[k] = d[k]
	_theme.accent = int(_theme.accent)
	_theme.second = int(_theme.second)

func _save_theme() -> void:
	var f := FileAccess.open(THEME_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_theme))
		f.close()

func _theme_setup(_cm: PopupMenu) -> void:
	_load_theme()

func _fill_theme_menu() -> void:
	_theme_menu.clear()
	_theme_menu.add_separator(_t("Схема", "Scheme"))
	for s in [["light", "Світла (як у грі)", "Light (original)"], ["dark", "Темна", "Dark"], ["black", "Чорна", "Black"]]:
		var id := ["light", "dark", "black"].find(s[0])
		_theme_menu.add_radio_check_item(_t(s[1], s[2]), id)
		_theme_menu.set_item_checked(_theme_menu.get_item_index(id), _theme.scheme == s[0])
	_theme_menu.add_separator(_t("Кольори", "Colors"))
	for m in [_accent_menu, _second_menu]:
		m.clear()
		for i in PALETTE.size():
			m.add_radio_check_item(_t(PALETTE[i][0], PALETTE[i][1]), i)
			m.set_item_icon(i, _swatch(PALETTE[i][2]))
		m.set_item_checked(_theme.accent if m == _accent_menu else _theme.second, true)
	_theme_menu.add_submenu_node_item(_t("Основний колір (підсвітка)", "Main color (highlight)"), _accent_menu, 50)
	_theme_menu.add_submenu_node_item(_t("Другий колір (заголовки)", "Second color (headings)"), _second_menu, 51)

var _swatches := {}
func _swatch(c: Color) -> Texture2D:
	var k := c.to_html()
	if not _swatches.has(k):
		var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
		img.fill(c)
		_swatches[k] = ImageTexture.create_from_image(img)
	return _swatches[k]

func _on_theme_pressed(id: int) -> void:
	if id >= 0 and id <= 2:
		_theme.scheme = ["light", "dark", "black"][id]
		_save_theme()
		_restyle_all()

func _scheme_colors() -> Dictionary:
	match _theme.scheme:
		"dark":
			return {"bg": Color("#1f1d24"), "panel": Color("#29262f"), "text": Color("#ece9f1"), "dim": Color("#9a95a3")}
		"black":
			return {"bg": Color("#050505"), "panel": Color("#111111"), "text": Color("#f2f2f2"), "dim": Color("#8a8a8a")}
	return {}

var _box_cache := {}
func _box(c: Color, radius: int, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var k := "%s|%d|%s" % [c.to_html(), radius, border.to_html()]
	if _box_cache.has(k):
		return _box_cache[k]
	var sbx := _box_new(c, radius, border)
	_box_cache[k] = sbx
	return sbx

func _box_new(c: Color, radius: int, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 10; sb.content_margin_right = 10
	sb.content_margin_top = 6; sb.content_margin_bottom = 6
	if border.a > 0:
		sb.border_color = border
		sb.set_border_width_all(1)
	return sb

func _style_popup(pm: PopupMenu) -> void:
	var sc := _scheme_colors()
	var names := ["panel", "hover", "separator", "labeled_separator_left", "labeled_separator_right"]
	var cols := ["font_color", "font_hover_color", "font_separator_color", "font_disabled_color", "font_accelerator_color"]
	if sc.is_empty():
		# «Світла (як у грі)»: білий фон, темний текст, рожева підсвітка — як ігрове меню
		sc = {"bg": Color("#fffafc"), "panel": Color("#fff0f5"), "text": Color("#4a3b43"), "dim": Color("#a3929b")}
		pm.add_theme_stylebox_override("panel", _box(sc.bg, 14, Color("#f3c7d6")))
		pm.add_theme_stylebox_override("hover", _box(Color("#ffdce8"), 9))
		var lsep := StyleBoxLine.new()
		lsep.color = Color("#f0d3dd")
		pm.add_theme_stylebox_override("separator", lsep)
		pm.add_theme_stylebox_override("labeled_separator_left", lsep)
		pm.add_theme_stylebox_override("labeled_separator_right", lsep)
		pm.add_theme_color_override("font_color", sc.text)
		pm.add_theme_color_override("font_hover_color", Color("#c2416f"))
		pm.add_theme_color_override("font_separator_color", Color("#b48a9b"))
		pm.add_theme_color_override("font_disabled_color", sc.dim)
		pm.add_theme_color_override("font_accelerator_color", sc.dim)
		return
	var acc: Color = PALETTE[_theme.accent][2]
	var sec: Color = PALETTE[_theme.second][2]
	pm.add_theme_stylebox_override("panel", _box(sc.bg, 14, acc.darkened(0.55)))
	var hv := acc
	hv.a = 0.28
	pm.add_theme_stylebox_override("hover", _box(hv, 9))
	var sep := StyleBoxLine.new()
	sep.color = sec.darkened(0.35)
	sep.thickness = 1
	pm.add_theme_stylebox_override("separator", sep)
	pm.add_theme_stylebox_override("labeled_separator_left", sep)
	pm.add_theme_stylebox_override("labeled_separator_right", sep)
	pm.add_theme_color_override("font_color", sc.text)
	pm.add_theme_color_override("font_hover_color", acc.lightened(0.35))
	pm.add_theme_color_override("font_separator_color", sec)
	pm.add_theme_color_override("font_disabled_color", sc.dim)
	pm.add_theme_color_override("font_accelerator_color", sc.dim)

func _style_tree_popups(n: Node) -> void:
	if n is PopupMenu:
		_style_popup(n)
	for c in n.get_children():
		_style_tree_popups(c)

func _style_settings(w: Window) -> void:
	var sc := _scheme_colors()
	var acc: Color = PALETTE[_theme.accent][2]
	var sec: Color = PALETTE[_theme.second][2]
	_style_controls(w, sc, acc, sec)

func _style_node(c: Node, sc: Dictionary, acc: Color, sec: Color) -> void:
	if true:
		if c is ColorRect:
			if not c.has_meta("orig_color"):
				c.set_meta("orig_color", c.color)
			c.color = sc.bg if not sc.is_empty() else c.get_meta("orig_color")
		elif c is PanelContainer:
			if sc.is_empty():
				c.remove_theme_stylebox_override("panel")
			else:
				c.add_theme_stylebox_override("panel", _box(sc.panel, 14))
		elif c is Panel:
			if sc.is_empty():
				c.remove_theme_stylebox_override("panel")
			else:
				c.add_theme_stylebox_override("panel", _box(sc.panel, 14))
		elif c is Label:
			if sc.is_empty():
				c.remove_theme_color_override("font_color")
			else:
				c.add_theme_color_override("font_color", sec if c.name == "SettingsEyebrow" or str(c.text).begins_with("♥") else sc.text)
		elif c is RichTextLabel:
			if sc.is_empty():
				c.remove_theme_color_override("default_color")
			else:
				c.add_theme_color_override("default_color", sc.text)
		elif c is LineEdit or c is TextEdit:
			if sc.is_empty():
				for st in ["normal", "focus", "read_only"]:
					c.remove_theme_stylebox_override(st)
				for k in ["font_color", "font_placeholder_color"]:
					c.remove_theme_color_override(k)
			else:
				c.add_theme_stylebox_override("normal", _box(sc.panel.lightened(0.06), 10, acc.darkened(0.4)))
				c.add_theme_stylebox_override("focus", _box(sc.panel.lightened(0.06), 10, acc))
				c.add_theme_stylebox_override("read_only", _box(sc.panel, 10))
				c.add_theme_color_override("font_color", sc.text)
				c.add_theme_color_override("font_placeholder_color", sc.dim)
		elif c is ItemList:
			if sc.is_empty():
				c.remove_theme_stylebox_override("panel")
				c.remove_theme_color_override("font_color")
			else:
				c.add_theme_stylebox_override("panel", _box(sc.panel, 12))
				c.add_theme_color_override("font_color", sc.text)
		elif c is TabBar or c is TabContainer:
			for k in ["font_selected_color", "font_unselected_color", "font_hovered_color"]:
				if sc.is_empty():
					c.remove_theme_color_override(k)
				else:
					c.add_theme_color_override(k, acc.lightened(0.3) if k == "font_selected_color" else sc.text)
			if c is TabContainer:
				if sc.is_empty():
					c.remove_theme_stylebox_override("panel")
				else:
					c.add_theme_stylebox_override("panel", _box(sc.bg, 12))
		elif c is Button:
			for k in ["font_color", "font_hover_color", "font_pressed_color"]:
				if sc.is_empty():
					c.remove_theme_color_override(k)
				else:
					c.add_theme_color_override(k, sc.text if k == "font_color" else acc.lightened(0.3))
			if c is CheckButton:
				pass
			elif sc.is_empty():
				for st in ["normal", "hover", "pressed"]:
					c.remove_theme_stylebox_override(st)
			elif c is OptionButton or c is Button:
				var h := acc
				h.a = 0.35
				c.add_theme_stylebox_override("normal", _box(sc.panel.lightened(0.06), 10, acc.darkened(0.4)))
				c.add_theme_stylebox_override("hover", _box(h, 10, acc))
				c.add_theme_stylebox_override("pressed", _box(h, 10, acc))

func _style_controls(n: Node, sc: Dictionary, acc: Color, sec: Color) -> void:
	for c in n.get_children():
		_style_node(c, sc, acc, sec)
		_style_controls(c, sc, acc, sec)

# вікна гри, що беруть тему меню: налаштування, довідка, Майстерня, завантаження, підтвердження
func _themed_windows() -> Array:
	var pet := _pet()
	var out := []
	if pet == null:
		return out
	for w in _all_windows(pet):
		if w is FileDialog or w is PopupMenu or w == _menu_win or str(w.title) == "":
			continue
		out.append(w)
	return out

var _themed_hooked := {}
var _restyle_pending := {}
func _hook_themed_windows() -> void:
	for w in _themed_windows():
		var k: int = w.get_instance_id()
		if _themed_hooked.has(k):
			continue
		_themed_hooked[k] = true
		w.visibility_changed.connect(func(): if w.visible: _on_themed_shown(w))
		if w.visible:
			_queue_restyle(w)
			_report_later(w)

# Майстерня довантажує картки поступово — перефарбовуємо нові елементи (не частіше раза на кадр)
func _on_node_added_theme(n: Node) -> void:
	if not (n is Control) or FileAccess.file_exists("user://linux_notheme"):
		return
	var w: Window = n.get_window()
	if w and _themed_hooked.has(w.get_instance_id()):
		if _theme.scheme == "light":
			return            # «як у грі»: нічого перефарбовувати не треба
		_style_queue.append(n)
		if not _style_queue_armed:
			_style_queue_armed = true
			_flush_style_queue.call_deferred()

# розмір вікна, який хоче гра (Майстерня 1200x720 тощо), — у файл, yw-gaze виставляє його через niri
func _report_later(w: Window) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(w) and w.visible:
		var need := Vector2i(w.get_contents_minimum_size())
		w.size = Vector2i(maxi(w.size.x, need.x), maxi(w.size.y, need.y))
		report_window_size(w)

# нові елементи вікон гри фарбуємо пачкою раз на кадр (кожна зміна теми окремо змушує Godot
# перераховувати вигляд — по одному це давало ~0.2 с на перебудову карток Майстерні)
var _style_queue: Array = []
var _style_queue_armed := false
func _flush_style_queue() -> void:
	_style_queue_armed = false
	var sc := _scheme_colors()
	var acc: Color = PALETTE[_theme.accent][2]
	var sec: Color = PALETTE[_theme.second][2]
	var q := _style_queue
	_style_queue = []
	for n in q:
		if is_instance_valid(n):
			_style_node(n, sc, acc, sec)

var _styled_scheme := {}       # вікно -> схема, якою його вже пофарбовано
func _on_themed_shown(w: Window) -> void:
	_fix_window_fonts(w)
	var key := "%s|%d|%d" % [_theme.scheme, _theme.accent, _theme.second]
	var done: String = _styled_scheme.get(w.get_instance_id(), "light-orig" if _theme.scheme == "light" else "")
	if done != key and not (done == "light-orig" and _theme.scheme == "light"):
		_queue_restyle(w)
	_report_later(w)

func _queue_restyle(w: Window) -> void:
	var k: int = w.get_instance_id()
	if _restyle_pending.has(k):
		return
	_restyle_pending[k] = true
	_do_restyle.call_deferred(w)

# Шрифти вікон гри (FontFile, напр. Open Sans) за замовчуванням шукають відсутні символи
# (китайські/японські назви в Майстерні) серед системних шрифтів — під Wine це сотні мс на кадр.
# Даємо їм запасний Noto (кирилиця + CJK) і забороняємо пошук через Wine.
var _fixed_fonts := {}
func _fix_font(f: Font) -> void:
	if f == null or _fixed_fonts.has(f.get_instance_id()):
		return
	_fixed_fonts[f.get_instance_id()] = true
	var base: Font = f
	if f is FontVariation and f.base_font:
		base = f.base_font
	if base is FontFile and base != _noto_font(400):
		var fb: Array = base.fallbacks
		var noto := _noto_font(400)
		if not (noto in fb):
			fb.append(noto)
			base.fallbacks = fb
		base.allow_system_fallback = false

func _fix_window_fonts(w: Window) -> void:
	_fix_font(w.get_theme_font("font"))
	for c in _all_controls(w):
		_fix_font(c.get_theme_font("font"))

# ───────────── Майстерня: маленькі прев'ю замість повнорозмірних ─────────────
# Вікно Майстерні розпаковує кожне прев'ю в головному потоці; прев'ю Steam — сотні КБ, і гра
# зависала на 0.2-1 с на кожній картці. Steam CDN віддає зменшену копію за параметрами адреси
# (~18 КБ замість ~480 КБ) — підміняємо preview_url ДО того, як вікно побудує картки.
const PREVIEW_Q := "?imw=360&imh=270&ima=fit&impolicy=Letterbox&imcolor=%23000000&letterbox=false"
var _ws_service: Node = null
# Меню трею гра дзеркалить у системні меню Windows (NativeMenu). Під Wine кожне оновлення пункту
# такого меню повільне: оновлення галочок персонажів займало ~0.4 с і фрізило гру після кожної
# підписки/відписки. Трей на Linux не працює, тож вимикаємо дзеркалення для всіх меню гри.
func _no_native_menus() -> void:
	var pet := _pet()
	if pet == null:
		return
	for n in _all_popups(pet):
		if n.prefer_native_menu:
			n.prefer_native_menu = false
	var si = pet.get("status_indicator")
	if si and si.get("menu") != null:
		si.set("menu", NodePath(""))

func _all_popups(n: Node) -> Array:
	var r := []
	for c in n.get_children():
		if c is PopupMenu:
			r.append(c)
		r.append_array(_all_popups(c))
	return r

# вікно Майстерні — на прискорений нащадок оригінального скрипту (linux_workshop_window.gd):
# повторне використання карток замість перебудови всіх ~2300 елементів на кожну підписку
func _swap_workshop_script() -> void:
	if not FileAccess.file_exists("user://linux_workshop_window.gd"):
		return
	var w: Node = null
	for c in _pet().get_children():
		if c.get_script() and str(c.get_script().resource_path).ends_with("workshop_window.gd"):
			w = c
	if w == null:
		return
	var props := {}
	for pp in w.get_script().get_script_property_list():
		if pp.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			props[pp.name] = w.get(pp.name)
	var before := {}
	for c in w.get_children():
		before[c.get_instance_id()] = true
	var sc = load("user://linux_workshop_window.gd")
	if sc == null:
		return
	w.set_script(sc)
	for k in props:
		w.set(k, props[k])
	for c in w.get_children():
		if not before.has(c.get_instance_id()):
			c.queue_free()            # якщо _init нового скрипту щось збудував удруге
	if w.has_method("lk_setup"):
		w.lk_setup()
		w._render_items()

func _hook_workshop_previews() -> void:
	var pet := _pet()
	for c in pet.get_children():
		if c.get_script() and str(c.get_script().resource_path).ends_with("workshop_service.gd"):
			_ws_service = c
	if _ws_service == null:
		return
	_shrink_previews()
	# наш обробник — першим, решта (вікно Майстерні) — після нього
	var cons: Array = _ws_service.get_signal_connection_list("items_changed")
	for c in cons:
		_ws_service.items_changed.disconnect(c.callable)
	_ws_service.items_changed.connect(func(_a = null, _b = null): _shrink_previews())
	# Підписка/відписка: Steam шле кілька подій поспіль (підписано, завантажено, встановлено), і
	# головне вікно щоразу перебудовувало список персонажів (~0.4 с). Збираємо в одну.
	var scc: Array = _ws_service.get_signal_connection_list("subscribed_characters_changed")
	for c in scc:
		_ws_service.subscribed_characters_changed.disconnect(c.callable)
		var cb: Callable = c.callable
		_ws_service.subscribed_characters_changed.connect(func(_chars = null): _debounce("subs", 0.25, func(): cb.call(_ws_service.get_subscribed_characters())))
	# Steam шле дані сторінками, і вікно Майстерні після КОЖНОЇ заново будувало всі картки.
	# Збираємо в одну перебудову (через 0.15 с тиші); якщо вікно сховане — до його відкриття.
	for c in cons:
		var obj = c.callable.get_object()
		if obj is Window and str(c.callable.get_method()) == "_on_items_changed":
			_ws_window = obj
			_ws_render = c.callable
			_ws_service.items_changed.connect(_on_ws_items_changed)
			obj.visibility_changed.connect(func(): if obj.visible and _ws_dirty: _ws_flush())
		else:
			_ws_service.items_changed.connect(c.callable, c.flags)

var _debounce_cb := {}
func _debounce(key: String, sec: float, cb: Callable) -> void:
	var token := Time.get_ticks_usec()
	_debounce_cb[key] = token
	get_tree().create_timer(sec).timeout.connect(func(): if _debounce_cb.get(key) == token: _debounce_cb.erase(key); cb.call())

var _ws_window: Window = null
var _ws_render: Callable
var _ws_dirty := false
var _ws_args := []
var _ws_timer: SceneTreeTimer = null
func _on_ws_items_changed(a = null, b = null) -> void:
	_ws_args = [a, b]
	_ws_dirty = true
	if _ws_timer == null:
		_ws_timer = get_tree().create_timer(0.15)
		_ws_timer.timeout.connect(func(): _ws_timer = null; if _ws_window and _ws_window.visible: _ws_flush())
	elif _ws_timer:
		_ws_timer.time_left = 0.15

func _ws_flush() -> void:
	_ws_dirty = false
	if _ws_render.is_valid():
		_ws_render.callv(_ws_args if _ws_args.size() == 2 else [null, null])

func _shrink_previews() -> void:
	if _ws_service == null:
		return
	var all = _ws_service.get("_items")
	if typeof(all) != TYPE_DICTIONARY:
		return
	for cat in all:
		for it in all[cat]:
			if typeof(it) == TYPE_DICTIONARY:
				var u := str(it.get("preview_url", ""))
				if u.begins_with("https://images.steamusercontent.com/") and not u.contains("?"):
					it["preview_url"] = u + PREVIEW_Q
				if FileAccess.file_exists("user://linux_nopreview"):
					it["preview_url"] = ""

var _restyle_ms := 0
func _do_restyle(w: Window) -> void:
	_restyle_pending.erase(w.get_instance_id())
	var _t0 := Time.get_ticks_msec()
	if is_instance_valid(w):
		_fix_window_fonts(w)
		_style_settings(w)
		_style_tree_popups(w)
		_styled_scheme[w.get_instance_id()] = "%s|%d|%d" % [_theme.scheme, _theme.accent, _theme.second]
	_restyle_ms += Time.get_ticks_msec() - _t0

func _restyle_all() -> void:
	var pet := _pet()
	if pet == null:
		return
	for w in _themed_windows():
		if w.visible:
			_queue_restyle(w)
	_style_tree_popups(pet._context_menu)
	_style_menu_window()
	if pet.get("_tray_menu"):
		_style_tree_popups(pet._tray_menu)
	if pet.get("_settings_window"):
		_style_settings(pet._settings_window)
		_style_tree_popups(pet._settings_window)

func _small_menu() -> PopupMenu:
	var m := PopupMenu.new()
	add_child(m)
	m.add_item("A", 1)
	return m

func _all_controls(n: Node) -> Array:
	var r := []
	for c in n.get_children():
		if c is Control:
			r.append(c)
		r.append_array(_all_controls(c))
	return r

func _all_windows(n: Node) -> Array:
	var r := []
	for c in n.get_children():
		if c is Window:
			r.append(c)
		r.append_array(_all_windows(c))
	return r

func _count_windows(n: Node) -> int:
	var c := 1 if n is Window else 0
	for k in n.get_children():
		c += _count_windows(k)
	return c

func _count(n: Node) -> int:
	var c := 1
	for k in n.get_children():
		c += _count(k)
	return c

func _menu_dump(pm: PopupMenu, depth: int) -> String:
	var out := ""
	if pm == null:
		return out
	for i in pm.item_count:
		var sub := pm.get_item_submenu_node(i) if pm.has_method("get_item_submenu_node") else null
		out += "%s[%d] id=%d sep=%s check=%s '%s'%s\n" % ["  ".repeat(depth), i, pm.get_item_id(i), pm.is_item_separator(i), pm.is_item_checkable(i), pm.get_item_text(i), (" -> " + sub.name) if sub else ""]
	return out

func _ctl_dump(n: Node, depth: int) -> String:
	var out := ""
	for c in n.get_children():
		var t := ""
		if c is Label or c is Button:
			t = " '" + str(c.text) + "'"
		out += "%s%s [%s]%s\n" % ["  ".repeat(depth), c.name, c.get_class(), t]
		out += _ctl_dump(c, depth + 1)
	return out

func _inspect(pet: Node) -> String:
	var out := "== context menu\n" + _menu_dump(pet._context_menu, 1)
	for c in pet._context_menu.get_children():
		if c is PopupMenu:
			out += "== sub " + c.name + "\n" + _menu_dump(c, 1)
	out += "== tray menu\n" + _menu_dump(pet._tray_menu, 1)
	out += "== signals context id_pressed: " + str(pet._context_menu.id_pressed.get_connections()) + "\n"
	out += "== settings window\n" + _ctl_dump(pet._settings_window, 1)
	out += "== autostart toggle signals: " + str(pet._autostart_toggle.toggled.get_connections()) + "\n"
	return out
