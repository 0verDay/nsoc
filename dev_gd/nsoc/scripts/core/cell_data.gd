class_name CellData
extends RefCounted

# 棋盘格子的**纯数据层**（重构文档.md §3.4-6「数据与表现分离」第一步）。
#
# 为什么需要它：`ui/cell.gd` 的 `Cell extends Panel` 同时充当"状态容器"和"视图"，
# 规则层（`TurnSystem` / `CombatSystem` / 效果 / AI）全靠鸭子类型读它的字段
# （`has_card` / `health` / `effects` / `team_id` …，见 tests/rules_test.gd 的 FakeCell）。
# 因此状态一旦能从 UI 节点里搬出来，同一套规则就能在**服务器上无头跑**。
#
# 本类与 `Cell` 的状态字段**逐条同构**（字段名、默认值、`set_card` / `clear_card`
# 的赋值语义、`to_dict` / `from_dict` 的键与类型转换），差别只有两点：
#   1. 不继承 Control，没有任何 UI / 动画 / 场景树依赖；
#   2. `team_id` 不由 `Game.registry` 反查 —— 服务器侧没有客户端 autoload，
#      归属队列由调用方（权威端 / 工厂）显式给出。
#
# 迁移路线：本类先与 `Cell` 并存（纯增量、客户端零改动），后续切片把规则层的读写
# 指向 `CellData`，`Cell` 退化为"渲染 + 输入"的视图。

var row: int = 0
var col: int = 0
var has_card: bool = false
## 阵营标识：0 = 玩家方（FACTION_PLAYER），1 = 敌方（FACTION_ENEMY）。
var faction: int = 0
## 向后兼容别名，读写自动同步到 faction（与 Cell 一致）。
var is_enemy: bool:
	get: return faction == 1
	set(value): faction = 1 if value else 0
## 格子物理位置所属盘 id。
var slot_id: String = ""
## 单位归属盘 id（跨盘后保持不变，死亡时入原属盘墓地）。
var owner_slot_id: String = ""
## PVP 队伍标识："defender" / "attacker" / "team_a" / "team_b"；PVE 为空串。
var team_id: String = ""
var origin: String = ""
var card_name: String = ""
var attack: int = 0
## 以单位视角 side 存储：{front, back, left, right}
var health: Dictionary = {"front": 0, "back": 0, "left": 0, "right": 0}
var effects: Array = []
var has_attacked: bool = false
var has_charged: bool = false
var is_phantom: bool = false
## 单位初始四维：set_card 时记录，受降等全恢复效果用。
var max_health: Dictionary = {"front": 0, "back": 0, "left": 0, "right": 0}


# ── 表现面（空实现）────────────────────────────────────────────────────────
# 规则层里有若干处会顺手调"表现"（`effects_changed.emit` / `play_*_effect` /
# `_update_hp_labels`）。它们在客户端 `Cell` 上是真表现，在纯数据格上**没有视图**，
# 若直接调用会抛 "Invalid access ... on a base object of type 'CellData'" ——
# 权威端跑关卡时就崩（例如法术施放器 `play_damage_effect()`、疑兵自爆
# `play_death_effect()`、`straight_in_ability` 的 `effects_changed.emit()`）。
#
# 因此这里提供**同名同签名的空实现**：数据格与视图格满足同一套鸭子类型接口，
# 规则层一份代码两种宿主都能跑；数据侧不产生任何表现副作用。
signal effects_changed(payload)

func _update_hp_labels() -> void:
	pass

func play_damage_effect() -> void:
	pass

func play_attack_effect() -> void:
	pass

func play_death_effect() -> void:
	pass


func is_hostile_to(viewer_team_id: String) -> bool:
	if team_id == "" or viewer_team_id == "":
		return is_enemy   # PVE 兼容路径
	return team_id != viewer_team_id


func is_friendly_to(viewer_team_id: String) -> bool:
	if team_id == "" or viewer_team_id == "":
		return not is_enemy   # PVE 兼容路径
	return team_id == viewer_team_id


## 布置单位。与 ui/cell.gd 的 set_card 状态语义逐条对齐（只做状态，不碰视图）；
## 额外多一个 p_team_id 形参（空串表示由调用方稍后显式设置，见类注释第 2 点）。
func set_card(cname: String, atk: int, hp: Dictionary, enemy: bool = false,
		effects_in: Array = [], owner_id: String = "", p_origin: String = "",
		p_team_id: String = "") -> void:
	has_card = true
	is_phantom = false
	card_name = cname
	attack = atk
	# hp 入参是单位视角 side dict（front/back/left/right），整盘统一 side 存储
	health = Orientation.clone_side_health(hp)
	max_health = Orientation.clone_side_health(hp)
	effects = effects_in.duplicate()
	is_enemy = enemy
	owner_slot_id = owner_id if owner_id != "" else slot_id
	if p_team_id != "":
		team_id = p_team_id
	if p_origin != "":
		origin = p_origin   # 不传则保留旧值（与 Cell 一致）


## 幻影预告：算牌面但不占位（spawner 用）。
func set_phantom(cname: String, atk: int, hp: Dictionary, enemy: bool = false,
		effects_in: Array = []) -> void:
	set_card(cname, atk, hp, enemy, effects_in)
	has_card = false
	is_phantom = true


## 清空格子。镜像 Cell._do_clear 的状态部分（不含 active_tween / inner_panel 复位）。
func clear_card() -> void:
	has_card = false
	card_name = ""
	is_enemy = false
	is_phantom = false
	has_charged = false
	owner_slot_id = ""
	team_id = ""
	origin = ""


## 序列化（键与 ui/cell.gd 的 to_dict 完全一致，PVP 联机与权威端共用同一份格式）。
func to_dict() -> Dictionary:
	return {
		"row":            row,
		"col":            col,
		"has_card":       has_card,
		"is_phantom":     is_phantom,
		"faction":        faction,
		"team_id":        team_id,
		"slot_id":        slot_id,
		"owner_slot_id":  owner_slot_id,
		"origin":         origin,
		"card_name":      card_name,
		"attack":         attack,
		"health":         health.duplicate(),
		"max_health":     max_health.duplicate(),
		"effects":        effects.duplicate(),
		"has_attacked":   has_attacked,
		"has_charged":    has_charged,
	}


## 原地还原。语义与 Cell.from_dict 对齐（含 JSON 往返后的 float → int 归一化），
## 但不清空"未携带字段"的旧值之外的东西：与 Cell 一样，空格走 clear。
func from_dict(d: Dictionary) -> void:
	var p_has_card:   bool = bool(d.get("has_card", false))
	var p_is_phantom: bool = bool(d.get("is_phantom", false))
	slot_id       = String(d.get("slot_id", ""))
	owner_slot_id = String(d.get("owner_slot_id", ""))
	team_id       = String(d.get("team_id", ""))
	origin        = String(d.get("origin", ""))
	has_attacked  = bool(d.get("has_attacked", false))
	has_charged   = bool(d.get("has_charged", false))

	if not p_has_card and not p_is_phantom:
		clear_card()
		return

	var p_faction: int = int(d.get("faction", 0))
	var raw_hp = d.get("health", {})
	var p_health: Dictionary = _int_dict(raw_hp) if typeof(raw_hp) == TYPE_DICTIONARY \
		else {"front": 0, "back": 0, "left": 0, "right": 0}
	var raw_mh = d.get("max_health", p_health)
	var p_max_health: Dictionary = _int_dict(raw_mh) if typeof(raw_mh) == TYPE_DICTIONARY else p_health
	var raw_eff = d.get("effects", [])

	has_card    = true
	is_phantom  = p_is_phantom
	card_name   = String(d.get("card_name", ""))
	attack      = int(d.get("attack", 0))
	health      = Orientation.clone_side_health(p_health)
	max_health  = Orientation.clone_side_health(p_max_health)
	effects     = raw_eff.duplicate() if typeof(raw_eff) == TYPE_ARRAY else []
	is_enemy    = (p_faction == 1)
	if p_is_phantom:
		has_card = false   # phantom 不算"真有牌"（与 Cell.from_dict 一致）


static func _int_dict(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		out[k] = int(src[k])
	return out
