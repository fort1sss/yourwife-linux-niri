extends Window
# Linux/niri: контекстне меню Your Wife в ОДНОМУ вікні — зліва головні пункти, справа підменю
# пункту під курсором (наведення одразу перемикає підменю). Пункти й дії — з PopupMenu гри
# (id_pressed/index_pressed гри спрацьовують як і в рідному меню).
# Навіщо: під xwayland-satellite всі X-вікна гри для Wine стоять у (0,0), тож кілька окремих вікон
# меню «накладались» і Godot не розумів, над яким курсор. Одне вікно — жодних накладань.
# Закривається: вибір пункту, Esc, клік по прозорій частині вікна, втрата фокусу,
# команда closemenu (її шле niri-pin, коли фокус перейшов на інше вікно).
# Завжди в межах екрана: позицію курсора й розмір екрана дає yw-gaze (linux_cursor.txt); якщо справа
# немає місця — підменю ліворуч від головного. Куди поставити вікно, пишемо в linux_menu_pos.txt —
# niri-pin ставить його туди (для Wine вікно лишається в (0,0)).

var lk: Node                     # linux_key.gd — тема, шрифт, кольори
var _source: PopupMenu
var _bg: Control
var _left := false               # підменю ліворуч від головного
var _main_x := 0
var _sub_x := 0
var _win_y := 0
var _win_h := 600                # висота вікна меню — фіксована на весь час, поки меню відкрите
var _sub_anchor_y := 0.0         # верх пункту головного меню, чиє підменю показане
var _scr := Vector2i(1920, 1080)
var _main_panel: PanelContainer
var _sub_panel: PanelContainer
var _sub_scroll: ScrollContainer
var _main_box: VBoxContainer
var _sub_box: VBoxContainer
var _sub_for := -1               # індекс пункту головного меню, чиє підменю показане
var _opened_ms := 0
const ROW_H := 38
const FONT_SIZE := 19
const MAIN_W := 400
var _main_w := MAIN_W           # ширина головного меню — за найдовшим пунктом
const SUB_W := 430

func _init() -> void:
	borderless = true
	transparent = true
	transparent_bg = true
	unresizable = true
	always_on_top = true
	visible = false
	title = ""
	wrap_controls = false

func _ready() -> void:
	_bg = Control.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	# закривати лише справжнім кліком по прозорій частині; колесо миші (теж MouseButton) — ні,
	# інакше прокрутка списку до кінця «просочувалась» на тло й закривала меню
	_bg.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]: close())
	add_child(_bg)
	_main_panel = PanelContainer.new()
	_main_box = VBoxContainer.new()
	_main_box.add_theme_constant_override("separation", 0)
	_main_panel.add_child(_main_box)
	_bg.add_child(_main_panel)
	_sub_panel = PanelContainer.new()
	_sub_scroll = ScrollContainer.new()
	_sub_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_sub_box = VBoxContainer.new()
	_sub_box.add_theme_constant_override("separation", 0)
	_sub_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sub_scroll.add_child(_sub_box)
	_sub_panel.add_child(_sub_scroll)
	_bg.add_child(_sub_panel)
	_sub_panel.visible = false
	focus_exited.connect(_on_focus_lost)
	window_input.connect(_on_window_input)

func _on_window_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		if lk._capture_cb.is_valid() and window_input.is_connected(lk._capture_cb):
			return
		close()

func _on_focus_lost() -> void:
	# не закривати одразу після відкриття (фокус може «пострибати» під час появи вікна)
	if Time.get_ticks_msec() - _opened_ms > 250:
		close()

func close() -> void:
	if visible:
		hide()
	_sub_for = -1

# ───────────── побудова ─────────────
func open_menu(source: PopupMenu) -> void:
	_source = source
	_apply_style()
	_fill(_main_box, source, true)
	_sub_panel.visible = false
	_sub_for = -1
	_place()
	_resize()
	position = Vector2i.ZERO           # для Wine — (0,0), як і бачить XWayland; на екрані ставить niri-pin
	_opened_ms = Time.get_ticks_msec()
	show()
	grab_focus()

func _clear(box: VBoxContainer) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()

func _fill(box: VBoxContainer, menu: PopupMenu, is_main: bool) -> void:
	_clear(box)
	if is_main:
		var f: Font = lk._noto_font(400)
		var mw := 0.0
		for j in menu.item_count:
			if not menu.is_item_separator(j):
				mw = maxf(mw, f.get_string_size(menu.get_item_text(j), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x)
		_main_w = clampi(int(mw) + 80, MAIN_W, 760)
	for i in menu.item_count:
		if menu.is_item_separator(i):
			var txt := menu.get_item_text(i)
			if txt != "":
				var l := Label.new()
				l.text = txt
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				l.add_theme_font_override("font", lk._noto_font(400))
				l.add_theme_font_size_override("font_size", FONT_SIZE - 5)
				l.add_theme_color_override("font_color", lk.menu_color("second"))
				l.custom_minimum_size.y = 26
				box.add_child(l)
			else:
				var sep := HSeparator.new()
				var ln := StyleBoxLine.new()
				ln.color = lk.menu_color("line")
				ln.grow_begin = -8
				ln.grow_end = -8
				sep.add_theme_stylebox_override("separator", ln)
				sep.add_theme_constant_override("separation", 10)
				box.add_child(sep)
			continue
		var b := Button.new()
		b.flat = false
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2((_main_w if is_main else SUB_W) - 24, ROW_H)
		b.clip_text = true
		var mark := ""
		if menu.is_item_checkable(i) or menu.is_item_radio_checkable(i):
			mark = ("●  " if menu.is_item_checked(i) else "○  ")
		var sub := menu.get_item_submenu_node(i)
		b.text = mark + menu.get_item_text(i) + ("" if sub == null else "")
		if menu.get_item_icon(i):
			b.icon = menu.get_item_icon(i)
		b.disabled = menu.is_item_disabled(i)
		_style_button(b, sub != null)
		if is_main:
			# підсвітку в головному меню ведемо самі — завжди рівно один пункт
			b.add_theme_stylebox_override("hover", lk.menu_box("row"))
			b.add_theme_stylebox_override("pressed", lk.menu_box("row"))
			b.add_theme_stylebox_override("hover_pressed", lk.menu_box("row"))
			b.add_theme_color_override("font_hover_color", lk.menu_color("text"))
			b.add_theme_color_override("font_pressed_color", lk.menu_color("text"))
			b.mouse_entered.connect(_on_main_hover.bind(i))
		if sub:
			var arrow := Label.new()
			arrow.text = "›"
			arrow.add_theme_font_override("font", lk._noto_font(400))
			arrow.add_theme_font_size_override("font_size", FONT_SIZE + 2)
			arrow.add_theme_color_override("font_color", lk.menu_color("dim"))
			arrow.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
			arrow.position.x -= 14
			b.add_child(arrow)
			if is_main:
				b.pressed.connect(_on_main_hover.bind(i))
			else:
				# вкладене підменю (напр. «Основний колір») — показуємо в тій самій панелі з «‹ Назад»
				b.pressed.connect(_open_nested.bind(menu, sub))
		else:
			b.pressed.connect(_activate.bind(menu, i))
		box.add_child(b)

func _open_nested(parent: PopupMenu, nested: PopupMenu) -> void:
	nested.about_to_popup.emit()
	_fill(_sub_box, nested, false)
	var back := Button.new()
	back.text = "‹  " + lk._t("Назад", "Back")
	back.focus_mode = Control.FOCUS_NONE
	back.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back.custom_minimum_size = Vector2(SUB_W - 24, ROW_H)
	_style_button(back, false)
	back.add_theme_color_override("font_color", lk.menu_color("dim"))
	back.pressed.connect(func(): _fill(_sub_box, parent, false); _resize())
	_sub_box.add_child(back)
	_sub_box.move_child(back, 0)
	_sub_scroll.scroll_vertical = 0
	_resize()

func _on_main_hover(i: int) -> void:
	_highlight_main(i)
	var row := _main_box.get_child(i) if i < _main_box.get_child_count() else null
	if row is Control:
		_sub_anchor_y = row.position.y + 10.0
	if i == _sub_for:
		return
	var sub := _source.get_item_submenu_node(i)
	if sub == null:
		if _sub_panel.visible:
			_sub_panel.visible = false
			_sub_for = -1
			_resize()
		return
	_sub_for = i
	if str(sub.name).begins_with("Linux_keys"):
		_fill_keys()
		_sub_panel.visible = true
		_sub_scroll.scroll_vertical = 0
		_resize()
		_resize_later()
		return
	if str(sub.name).begins_with("Linux_size"):
		_fill_size_slider()
		_sub_panel.visible = true
		_sub_scroll.scroll_vertical = 0
		_resize()
		_resize_later()
		return
	# підменю живе: перед показом гра/наш скрипт можуть оновити галочки — повідомляємо, як рідному меню
	sub.about_to_popup.emit()
	_fill(_sub_box, sub, false)
	_sub_panel.visible = true
	_sub_scroll.scroll_vertical = 0
	_resize()
	_resize_later()
	_highlight_main(i)

# «Розмір»: повзунок 55-450% з кроком 1%, героїня змінюється, поки тягнеш (з невеликою паузою,
# щоб не смикати вікно на кожен піксель)
var _size_label: Label
var _size_pending := -1.0
func _fill_size_slider() -> void:
	_clear(_sub_box)
	var pct: int = int(round(float(lk._pet()._character_scale) * 100.0))
	_size_label = Label.new()
	_size_label.text = "%s: %d%%" % [lk._t("Розмір", "Size"), pct]
	_size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_size_label.add_theme_font_override("font", lk._noto_font(400))
	_size_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_size_label.add_theme_color_override("font_color", lk.menu_color("text"))
	_size_label.custom_minimum_size.y = ROW_H
	_sub_box.add_child(_size_label)
	var sl := HSlider.new()
	sl.min_value = 55
	sl.max_value = 450
	sl.step = 1
	sl.value = pct
	sl.custom_minimum_size = Vector2(SUB_W - 50, 34)
	sl.focus_mode = Control.FOCUS_NONE
	var grab: Color = lk.menu_color("hover_text")
	var track := StyleBoxFlat.new()
	track.bg_color = lk.menu_color("line")
	track.set_corner_radius_all(4)
	track.content_margin_top = 3; track.content_margin_bottom = 3
	var fill: StyleBoxFlat = track.duplicate()
	fill.bg_color = grab
	sl.add_theme_stylebox_override("slider", track)
	sl.add_theme_stylebox_override("grabber_area", fill)
	sl.add_theme_stylebox_override("grabber_area_highlight", fill)
	var knob := _circle(18, grab)
	sl.add_theme_icon_override("grabber", knob)
	sl.add_theme_icon_override("grabber_highlight", _circle(20, grab.lightened(0.15)))
	sl.value_changed.connect(_on_size_slider)
	_sub_box.add_child(sl)
	var hint := Label.new()
	hint.text = "55%                                        450%"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_override("font", lk._noto_font(400))
	hint.add_theme_font_size_override("font_size", FONT_SIZE - 5)
	hint.add_theme_color_override("font_color", lk.menu_color("dim"))
	_sub_box.add_child(hint)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for v in [75, 100, 150, 200]:
		var b := Button.new()
		b.text = "%d%%" % v
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(80, ROW_H)
		_style_button(b, false)
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.pressed.connect(func(): sl.value = v)
		row.add_child(b)
	_sub_box.add_child(row)

func _circle(d: int, c: Color) -> Texture2D:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var r := d / 2.0
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var a := clampf(r - dist, 0.0, 1.0)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a))
	return ImageTexture.create_from_image(img)

func _on_size_slider(v: float) -> void:
	if _size_label:
		_size_label.text = "%s: %d%%" % [lk._t("Розмір", "Size"), int(v)]
	var first := _size_pending < 0
	_size_pending = v / 100.0
	if first:
		get_tree().create_timer(0.12).timeout.connect(_apply_size_pending)

func _apply_size_pending() -> void:
	if _size_pending < 0:
		return
	var pet = lk._pet()
	pet._resize_character(clampf(_size_pending, 0.55, 4.5))
	pet._save_preferences()
	_size_pending = -1.0

func _highlight_main(i: int) -> void:
	# рядки головного меню відповідають пунктам 1:1 (роздільник = HSeparator/Label).
	# Активному — підсвітка в УСІХ станах (і під курсором теж), решті — прозорий фон у всіх станах.
	for k in _main_box.get_child_count():
		var c := _main_box.get_child(k)
		if c is Button:
			var on := k == i
			var box: StyleBox = lk.menu_box("hover") if on else lk.menu_box("row")
			var col: Color = lk.menu_color("hover_text") if on else lk.menu_color("text")
			for st in ["normal", "hover", "pressed", "hover_pressed"]:
				c.add_theme_stylebox_override(st, box)
			for fc in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
				c.add_theme_color_override(fc, col)

func _activate(menu: PopupMenu, i: int) -> void:
	var id := menu.get_item_id(i)
	close()
	if menu == _source and id == 10:
		lk.toggle_hide()
		return
	if menu == _source and id == 3:
		lk.toggle_lock()
		return
	if menu.is_item_checkable(i) and not menu.is_item_radio_checkable(i):
		pass  # стан галочки оновлює сама гра у своєму обробнику
	if str(menu.name) == "CharacterMenu":
		lk.fade_switch(func(): menu.id_pressed.emit(id))
		return
	if menu.id_pressed.get_connections().size() > 0:
		menu.id_pressed.emit(id)
	if menu.index_pressed.get_connections().size() > 0:
		menu.index_pressed.emit(i)

func _resize_later() -> void:
	await get_tree().process_frame
	if visible:
		_resize()

# «Гарячі клавіші»: поля для зміни клавіш (клік → натисни комбінацію; Esc — скасувати, Backspace — прибрати)
func _fill_keys() -> void:
	_clear(_sub_box)
	for k in ["hide", "menu"]:
		var l := Label.new()
		l.text = lk._t("Приховати/Показати персонажа", "Hide/Show character") if k == "hide" else lk._t("Відкрити меню", "Open menu")
		l.add_theme_font_override("font", lk._noto_font(400))
		l.add_theme_font_size_override("font_size", FONT_SIZE - 2)
		l.add_theme_color_override("font_color", lk.menu_color("second"))
		l.custom_minimum_size.y = 28
		_sub_box.add_child(l)
		var b := Button.new()
		b.text = lk.pretty_key(lk.get_hotkey(k))
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(SUB_W - 24, ROW_H)
		_style_button(b, false)
		b.add_theme_stylebox_override("normal", lk.menu_box("hover"))
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.pressed.connect(func(): lk._capture_key(self, k, b))
		_sub_box.add_child(b)
	var hint := Label.new()
	hint.text = lk._t("Клік по полю → натисни комбінацію.\nEsc — скасувати, Backspace — прибрати.", "Click a field, then press a combination.\nEsc cancels, Backspace clears.")
	hint.add_theme_font_override("font", lk._noto_font(400))
	hint.add_theme_font_size_override("font_size", FONT_SIZE - 6)
	hint.add_theme_color_override("font_color", lk.menu_color("dim"))
	_sub_box.add_child(hint)

func _read_cursor() -> Array:
	var p := FileAccess.get_file_as_string("user://linux_cursor.txt").split(" ", false)
	if p.size() >= 4:
		return [int(p[0]), int(p[1]), int(p[2]), int(p[3])]
	return [960, 540, 1920, 1080]

# вирішує, де стоятиме вікно на екрані й з якого боку підменю; пише позицію для niri-pin
func _place() -> void:
	var c := _read_cursor()
	var cx: int = c[0]
	var cy: int = c[1]
	_scr = Vector2i(c[2], c[3])
	var total := _main_w + 6 + SUB_W
	_left = cx + total > _scr.x
	var wx: int
	if _left:
		_main_x = SUB_W + 6
		_sub_x = 0
		wx = cx - _main_x
		if cx + _main_w > _scr.x:
			wx = _scr.x - total
	else:
		_main_x = 0
		_sub_x = _main_w + 6
		wx = cx
	wx = clampi(wx, 0, maxi(_scr.x - total, 0))
	var main_h := int(_main_box.get_combined_minimum_size().y) + 20
	_win_y = clampi(cy, 0, maxi(_scr.y - main_h - 8, 0))
	# вікно одразу на всю висоту до низу екрана й на ширину «головне + підменю» — і далі його розмір
	# не змінюється: niri не перераховує положення, тож головне меню не смикається від підменю
	_win_h = maxi(_scr.y - _win_y - 4, main_h)
	size = Vector2i(total, _win_h)
	var f := FileAccess.open("user://linux_menu_pos.txt", FileAccess.WRITE)
	if f:
		f.store_string("%d %d\n" % [wx, _win_y])
		f.close()

func _resize() -> void:
	# лише розкладка всередині вікна фіксованого розміру: головне меню — на місці,
	# підменю — навпроти пункту, з якого відкрите, підняте, якщо не влазить донизу
	var main_h := _main_box.get_combined_minimum_size().y + 20
	_main_panel.position = Vector2(_main_x, 0)
	_main_panel.size = Vector2(_main_w, main_h)
	if _sub_panel.visible:
		var sub_h := _sub_box.get_combined_minimum_size().y + 20
		var sh := mini(int(sub_h), _win_h)
		_sub_scroll.custom_minimum_size = Vector2(SUB_W - 20, sh - 20)
		_sub_panel.size = Vector2(SUB_W, sh)
		var sy := clampf(_sub_anchor_y - 10.0, 0.0, float(_win_h - sh))
		_sub_panel.position = Vector2(_sub_x, sy)

# ───────────── вигляд ─────────────
func _apply_style() -> void:
	for p in [_main_panel, _sub_panel]:
		p.add_theme_stylebox_override("panel", lk.menu_box("panel"))

func _style_button(b: Button, _has_sub: bool) -> void:
	b.add_theme_font_override("font", lk._noto_font(400))
	b.add_theme_font_size_override("font_size", FONT_SIZE)
	b.add_theme_color_override("font_color", lk.menu_color("text"))
	b.add_theme_color_override("font_hover_color", lk.menu_color("hover_text"))
	b.add_theme_color_override("font_pressed_color", lk.menu_color("hover_text"))
	b.add_theme_color_override("font_disabled_color", lk.menu_color("dim"))
	b.add_theme_stylebox_override("normal", lk.menu_box("row"))
	b.add_theme_stylebox_override("disabled", lk.menu_box("row"))
	b.add_theme_stylebox_override("hover", lk.menu_box("hover"))
	b.add_theme_stylebox_override("pressed", lk.menu_box("hover"))
	b.add_theme_stylebox_override("hover_pressed", lk.menu_box("hover"))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
