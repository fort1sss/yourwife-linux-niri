extends Window
# Linux/niri: заміна скрипту ігрового вікна меню (PetMenuWindow). Ігрове вікно при розкладці
# багато разів створює SystemFont на кожен пункт — під Wine це секунди фрізу. Тут те саме API,
# але меню показує linux_key.gd рідним PopupMenu рушія (ті самі пункти й дії гри, 7-15 мс).
var linux: Node

func open_at(point, source) -> void:
	if linux and source:
		linux.show_native_menu(source, point)

func _ready() -> void:
	pass
func _dismiss_on_focus_loss() -> void:
	pass
func _on_input(_event) -> void:
	pass
func _measure_width(_source, minimum) -> int:
	return int(minimum)
func _panel(_source, _main) -> Control:
	return null
func _hover_main(_source, _index, _button) -> void:
	pass
func _close_submenu(_layout) -> void:
	pass
func _layout() -> void:
	pass
func _activate(_source, _index, _button) -> void:
	pass
