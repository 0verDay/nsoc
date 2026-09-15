class_name StateHash
extends RefCounted

## 对局状态哈希（重构文档.md §1 验收标准 / §7 阶段 0 安全网）。
##
## 用途：
##   1. headless 冒烟：一局能跑通
##   2. desync 检测：同种子 + 同输入必须得到同一哈希（跨进程、跨窗口尺寸）
##   3. 后续服务器权威的状态对账基线（阶段 1 起复用）
##
## 设计约束：
##   - 只覆盖"规则相关"状态，**不含**任何视觉字段（位置/尺寸/颜色/节点引用）
##   - 所有字典按键名排序、槽位按 id 排序，保证与装配顺序无关
##   - 牌堆保留抽牌顺序（顺序不同即为不同的对局状态）

const VERSION: int = 1


## 计算状态哈希（sha256 十六进制字符串）。
static func compute() -> String:
	return canonical_json().sha256_text()


## 规范化 JSON 文本（排障用：两次哈希不一致时可 diff 本文本定位差异）。
static func canonical_json() -> String:
	return JSON.stringify(canonical())


## 规范化状态字典。
static func canonical() -> Dictionary:
	var out: Dictionary = {
		"v": VERSION,
		"turn": _turn_number(),
		"counters": _sorted_dict(Game.counters if Game.counters != null else {}),
	}

	# 所有玩家：牌堆（含抽牌顺序）+ 费用。注意这里遍历 Game.decks 而非仅本地别名，
	# 以覆盖 PVE 的 AI 盘与 PVP 的全部对手。
	var decks: Dictionary = {}
	var manas: Dictionary = {}
	for pid in _player_ids():
		var dk = Game.decks.get(pid)
		if dk != null and dk.has_method("to_dict"):
			decks[pid] = dk.to_dict()
		var mn = Game.manas.get(pid)
		if mn != null and mn.has_method("to_dict"):
			manas[pid] = mn.to_dict()
	# 本地玩家别名必须单独覆盖：PVE 下 Game.decks 可能是空的（本地牌组只挂在
	# Game.deck / Game.mana 上），若漏掉就等于"洗牌结果不进哈希"，安全网会漏报。
	if Game.deck != null and Game.deck.has_method("to_dict"):
		decks["__local__"] = Game.deck.to_dict()
	if Game.mana != null and Game.mana.has_method("to_dict"):
		manas["__local__"] = Game.mana.to_dict()
	out["decks"] = decks
	out["manas"] = manas

	# 棋盘：按 slot id 排序，与装配顺序解耦。
	var slots: Array = []
	for slot in _slots():
		if slot != null and slot.has_method("to_dict"):
			slots.append(slot.to_dict())
	slots.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	out["slots"] = slots

	# 装备
	if _has_autoload("Equipments"):
		out["equipments"] = _sorted_dict(Equipments.to_dict())

	return out


## 人类可读摘要（冒烟日志用）。
static func summary() -> String:
	var lines: Array = []
	lines.append("turn=%d" % _turn_number())
	for slot in _slots():
		if slot == null:
			continue
		var hero_hp: int = -1
		if slot.hero != null:
			hero_hp = int(slot.hero.health)
		var units: int = 0
		if slot.board != null:
			for cell in slot.board.grid_cells.values():
				if cell != null and cell.has_card:
					units += 1
		lines.append("  %s(owner=%s) hero_hp=%d units=%d" % [
			String(slot.id), String(slot.owner_player_id), hero_hp, units,
		])
	return "\n".join(lines)


# ── 内部 ──────────────────────────────────────────────────────────────────

static func _turn_number() -> int:
	if Game == null or Game.turn == null:
		return -1
	return int(Game.turn.turn_number)


static func _player_ids() -> Array:
	var ids: Array = []
	if Game == null:
		return ids
	for k in Game.decks.keys():
		ids.append(String(k))
	ids.sort()
	return ids


static func _slots() -> Array:
	if Game == null or Game.registry == null:
		return []
	return Game.registry.slots


static func _has_autoload(name: String) -> bool:
	if Engine.get_main_loop() == null:
		return false
	var root: Node = Engine.get_main_loop().root
	return root != null and root.has_node("/root/" + name)


static func _sorted_dict(d: Dictionary) -> Dictionary:
	var keys: Array = []
	for k in d.keys():
		keys.append(String(k))
	keys.sort()
	var out: Dictionary = {}
	for k in keys:
		out[k] = d[k]
	return out
