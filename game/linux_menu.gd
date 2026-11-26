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
	_bg.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: close())
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
		b.custom_minimum_size = Vector2((MAIN_W if is_main else SUB_W) - 24, ROW_H)
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
			b.pressed.connect(_on_main_hover.bind(i))
		else:
			b.pressed.connect(_activate.bind(menu, i))
		box.add_child(b)

func _on_main_hover(i: int) -> void:
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
	# підменю живе: перед показом гра/наш скрипт можуть оновити галочки — повідомляємо, як рідному меню
	sub.about_to_popup.emit()
	_fill(_sub_box, sub, false)
	_sub_panel.visible = true
	_sub_scroll.scroll_vertical = 0
	_resize()
	_highlight_main(i)

func _highlight_main(i: int) -> void:
	# рядки головного меню відповідають пунктам 1:1 (роздільник = HSeparator/Label)
	for k in _main_box.get_child_count():
		var c := _main_box.get_child(k)
		if c is Button:
			var on := k == i
			c.add_theme_stylebox_override("normal", lk.menu_box("hover") if on else lk.menu_box("row"))
			c.add_theme_color_override("font_color", lk.menu_color("hover_text") if on else lk.menu_color("text"))

func _activate(menu: PopupMenu, i: int) -> void:
	var id := menu.get_item_id(i)
	close()
	if menu.is_item_checkable(i) and not menu.is_item_radio_checkable(i):
		pass  # стан галочки оновлює сама гра у своєму обробнику
	if menu.id_pressed.get_connections().size() > 0:
		menu.id_pressed.emit(id)
	if menu.index_pressed.get_connections().size() > 0:
		menu.index_pressed.emit(i)

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
	var total := MAIN_W + 6 + SUB_W
	_left = cx + total > _scr.x
	var wx: int
	if _left:
		_main_x = SUB_W + 6
		_sub_x = 0
		wx = cx - _main_x
		if cx + MAIN_W > _scr.x:
			wx = _scr.x - total
	else:
		_main_x = 0
		_sub_x = MAIN_W + 6
		wx = cx
	wx = clampi(wx, 0, maxi(_scr.x - total, 0))
	var main_h := int(_main_box.get_combined_minimum_size().y) + 20
	_win_y = clampi(cy, 0, maxi(_scr.y - main_h - 8, 0))
	var f := FileAccess.open("user://linux_menu_pos.txt", FileAccess.WRITE)
	if f:
		f.store_string("%d %d\n" % [wx, _win_y])
		f.close()

func _resize() -> void:
	var main_h := _main_box.get_combined_minimum_size().y + 20
	var h := main_h
	if _sub_panel.visible:
		var sub_h := _sub_box.get_combined_minimum_size().y + 20
		var max_h := maxi(_scr.y - _win_y - 8, 200)
		var sh := mini(int(sub_h), max_h)
		_sub_scroll.custom_minimum_size = Vector2(SUB_W - 20, sh - 20)
		_sub_panel.size = Vector2(SUB_W, sh)
		h = maxf(h, sh)
	_main_panel.position = Vector2(_main_x, 0)
	_main_panel.size = Vector2(MAIN_W, main_h)
	_sub_panel.position = Vector2(_sub_x, 0)
	size = Vector2i(MAIN_W + 6 + SUB_W, int(h))

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
