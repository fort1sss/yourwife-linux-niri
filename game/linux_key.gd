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
		"closemenu":
			if _menu_win:
				_menu_win.close()
			_say("ok closemenu")
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
	var lines := []
	for l in txt.split("\n"):
		if not l.begins_with("run/max_fps=") and l != "[application]":
			lines.append(l)
	while lines.size() > 0 and lines[-1] == "":
		lines.pop_back()
	lines.append_array(["", "[application]", "", "run/max_fps=%d" % fps, ""])
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

func _box(c: Color, radius: int, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
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

func _style_controls(n: Node, sc: Dictionary, acc: Color, sec: Color) -> void:
	for c in n.get_children():
		if c is ColorRect:
			if not c.has_meta("orig_color"):
				c.set_meta("orig_color", c.color)
			c.color = sc.bg if not sc.is_empty() else c.get_meta("orig_color")
		elif c is PanelContainer:
			if sc.is_empty():
				c.remove_theme_stylebox_override("panel")
			else:
				c.add_theme_stylebox_override("panel", _box(sc.panel, 14))
		elif c is Label:
			if sc.is_empty():
				c.remove_theme_color_override("font_color")
			else:
				c.add_theme_color_override("font_color", sec if c.name == "SettingsEyebrow" else sc.text)
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
		_style_controls(c, sc, acc, sec)

func _restyle_all() -> void:
	var pet := _pet()
	if pet == null:
		return
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
