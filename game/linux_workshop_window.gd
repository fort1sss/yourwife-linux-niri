extends "res://scripts/workshop_window.gd"
# Linux/niri: прискорене вікно Майстерні (нащадок оригінального скрипту гри).
# Оригінал на кожну зміну (підписка, відписка, нова сторінка від Steam, оновлення галочок) заново
# будував УСІ картки — ~2300 елементів, ~0.3 с фрізу. Тут:
#  - незмінені картки використовуються повторно, заново будуються лише змінені;
#  - кілька перебудов за кадр зливаються в одну;
#  - поки вікно сховане — не будуємо, а при відкритті будуємо один раз.

var _lk_pool := {}          # file_id -> [підпис, картка] з попередньої побудови
var _lk_pending := false
var _lk_dirty := false
var lk_stats := {"hit": 0, "miss": 0, "nopool": 0, "why": ""}

func _lk_sig(item) -> String:
	if typeof(item) != TYPE_DICTIONARY:
		return ""
	# статус підписки гра тримає в службі Steam, а не в даних картки — тож беремо і його,
	# і той самий текст кнопки, який рахує гра (оновлюється одразу після підписки/відписки)
	var svc = get("_service")
	var fid = item.get("file_id")
	var subd = svc.is_subscribed(int(fid)) if svc and fid != null else false
	var action := str(_card_action_text(item)) if has_method("_card_action_text") else ""
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % [fid, item.get("subscribed"), item.get("installed"),
		item.get("title"), item.get("preview_url"), item.get("votes_up"), item.get("content_type"),
		item.get("animated"), _category, subd, action]

func _render_items() -> void:
	if not visible:
		_lk_dirty = true
		return
	if _lk_pending:
		return
	_lk_pending = true
	_lk_render_now.call_deferred()

# швидкий шлях: список карток той самий (категорія, порядок, без пошуку) — замінюємо лише змінені
func _lk_try_in_place() -> bool:
	var grid = get("_grid")
	var search = get("_search")
	if grid == null or (search and str(search.text).strip_edges() != ""):
		return false
	var svc = get("_service")
	if svc == null:
		return false
	var items: Array = svc.get_items(_category)
	var sel := ""
	if has_method("_selected_content_type"):
		sel = str(_selected_content_type())
	var want := []
	for it in items:
		if sel == "" or sel == "all" or str(it.get("content_type", "")) == sel:
			want.append(it)
	var have: Array = grid.get_children()
	if want.size() != have.size() or want.is_empty():
		return false
	for i in want.size():
		if not have[i].has_meta("lk_fid") or have[i].get_meta("lk_fid") != want[i].get("file_id"):
			return false
	for i in want.size():
		var sig := _lk_sig(want[i])
		if have[i].get_meta("lk_sig") != sig:
			var card = super._create_item_card(want[i])
			if card is Node:
				card.set_meta("lk_sig", sig)
				card.set_meta("lk_fid", want[i].get("file_id"))
				grid.add_child(card)
				grid.move_child(card, i)
				have[i].queue_free()
				lk_stats.hit += 0
				lk_stats.miss += 1
	if has_method("_refresh_counts"):
		_refresh_counts()
	return true

func _lk_render_now() -> void:
	_lk_pending = false
	_lk_dirty = false
	if _lk_try_in_place():
		return
	# зняти теперішні картки з сітки (не знищуючи) — оригінал побудує сітку заново,
	# а _create_item_card віддасть збережену картку, якщо в ній нічого не змінилось
	var grid = get("_grid")
	if grid:
		for c in grid.get_children():
			grid.remove_child(c)
			if not c.has_meta("lk_sig"):
				c.queue_free()
	super._render_items()
	# картки, які не знадобились, — прибрати
	for k in _lk_pool:
		var card = _lk_pool[k][1]
		if is_instance_valid(card) and card.get_parent() == null:
			card.queue_free()
	_lk_pool.clear()
	if grid:
		for c in grid.get_children():
			if c.has_meta("lk_sig"):
				_lk_pool[c.get_meta("lk_fid")] = [c.get_meta("lk_sig"), c]

func _create_item_card(item):
	var fid = item.get("file_id") if typeof(item) == TYPE_DICTIONARY else null
	var sig := _lk_sig(item)
	if fid != null and _lk_pool.has(fid):
		var entry: Array = _lk_pool[fid]
		_lk_pool.erase(fid)
		if entry[0] == sig and is_instance_valid(entry[1]) and entry[1].get_parent() == null:
			lk_stats.hit += 1
			return entry[1]
		lk_stats.miss += 1
		lk_stats.why = "old=%s new=%s" % [entry[0], sig]
		if is_instance_valid(entry[1]) and entry[1].get_parent() == null:
			entry[1].queue_free()
	else:
		lk_stats.nopool += 1
	var card = super._create_item_card(item)
	if card is Node and fid != null:
		card.set_meta("lk_sig", sig)
		card.set_meta("lk_fid", fid)
	return card

func _lk_on_visibility() -> void:
	if visible and _lk_dirty:
		_render_items()

func lk_setup() -> void:
	if not visibility_changed.is_connected(_lk_on_visibility):
		visibility_changed.connect(_lk_on_visibility)
	# зібрати вже побудовані картки в пул (щоб перша ж перебудова була дешевою)
	var grid = get("_grid")
	if grid:
		for c in grid.get_children():
			if not c.has_meta("lk_sig"):
				c.queue_free()
