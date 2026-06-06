class_name BoardSlot
extends Node

# 一个棋盘的全部上下文。把 BoardModel + HeroState + SpawnerSystem + 视觉容器
# 聚合为一个领域对象，统一替代旧 (Game.board / Game.hero / Game.spawners) 与
# (TurnSystem._extra_board_configs[i]) 的双轨表示。
#
# 阶段 1：仅作为薄封装，BoardModel 仍是 6×3；后续阶段会把每个 BoardSlot 拆为 3×3。

# 阵营常量（与 TurnSystem.PLAYER/ENEMY 同义）
const FACTION_PLAYER: int = 0
const FACTION_ENEMY:  int = 1

# 角色：MAIN_PLAYER = 玩家本人盘（手牌起源、英雄技能锚点）
#       ALLY        = 玩家阵营友军盘
#       MAIN_ENEMY  = 当前关卡主敌盘（兼容阶段 1 的"敌方主棋盘"概念）
#       ENEMY       = 普通敌方盘（侧翼/援军等）
const ROLE_MAIN_PLAYER: int = 0
const ROLE_ALLY:        int = 1
const ROLE_MAIN_ENEMY:  int = 2
const ROLE_ENEMY:       int = 3

var id: String = ""
var faction: int = FACTION_PLAYER
var role: int = ROLE_MAIN_PLAYER
var slot_index: int = 0           # 屏幕水平槽位 0..N-1，用于排序与布局
# PVP 队伍标识："defender" / "attacker"；PVE 为空串。
# 用于效果/目标选择的友敌判定（is_hostile_to / is_friendly_to）。
var team_id: String = ""

# 该盘归属玩家 uuid（PVP 用）。
# PVE 默认空串 → 由 Game.local_player_id 兜底；PVP 装配时显式填入。
# 用于 PlayController / TurnSystem 通过 Game.get_deck(owner_player_id) /
# Game.get_mana(owner_player_id) 反查该盘玩家的牌库与费用。
var owner_player_id: String = ""

var board: BoardModel = null      # 数据层
var hero: HeroState = null        # 该盘所属英雄
var spawners: SpawnerSystem = null # 该盘的 spawner（可为空）
var spell_casters: SpellCasterSystem = null # 该盘的法术施放器（可为空）
var bg_panel: Panel = null        # 视觉背景，用于跨盘选择高亮 / 排序
var grid_node: Node = null        # cell 父容器（GridContainer / Control 等）

# 部署规则：玩家手牌能否落到本盘。MAIN_PLAYER / ALLY 默认 true；ENEMY 默认 false。
var allow_player_deploy: bool = false

# AI / 其他控制器（后续阶段使用）
var ai_controller: Node = null

# 该盘 hero 受击时调用的视觉反馈面板。可为空（无 UI 时静默扣血）。
# 由装配方注入（test_main / ExtraBoardController）。
var hero_panel: Panel = null

# 用于跨盘冲锋穿透时调用的英雄伤害结算回调。多盘体系下统一签名：
#   Callable(damage: int) -> void
# 默认在 setup 内绑定到 self.damage_hero；外部也可覆盖。
var hero_resolver: Callable = Callable()

# ── 该盘自己的墓地 / 除外（阶段 5）──────────────────────────────────
# 敌方盘累积本盘阵亡的敌方单位；玩家盘累积本盘阵亡的玩家阵营单位（若需要）。
# 玩家阵营单位通常仍走 Game.deck（玩家个人牌库）路径，本字段在玩家盘上不强制使用。
signal pile_changed(pile: String)   # "graveyard" / "banished"
var graveyard: Array = []
var banished: Array = []

func send_to_graveyard(card) -> void:
	graveyard.append(card)
	pile_changed.emit("graveyard")

func banish(card) -> void:
	banished.append(card)
	pile_changed.emit("banished")

func setup(p_id: String, p_faction: int, p_role: int,
		p_board: BoardModel, p_hero: HeroState,
		p_spawners: SpawnerSystem,
		p_hero_resolver: Callable = Callable()) -> void:
	id = p_id
	faction = p_faction
	role = p_role
	board = p_board
	hero = p_hero
	spawners = p_spawners
	if p_hero_resolver.is_valid():
		hero_resolver = p_hero_resolver
	else:
		# Callable(self, "damage_hero") 支持 (amount, source="") 两参数签名
		hero_resolver = Callable(self, "damage_hero")
	allow_player_deploy = (faction == FACTION_PLAYER)
	# 连接英雄死亡信号 → 通知 Events 系统
	if hero != null and not hero.died.is_connected(_on_hero_died):
		hero.died.connect(_on_hero_died)

# 英雄死亡时回调：通知 ScriptedEvents，触发 hero_died trigger。
# PVP 1v3：任意 slot 英雄死亡均触发胜负广播。
func _on_hero_died() -> void:
	# PVP 1v3：按 team_id 判断胜负，广播 game/end
	var g: Node = Engine.get_main_loop().root.get_node_or_null("/root/Game") \
		if Engine.get_main_loop() != null else null
	if g != null and g.is_pvp and g.pvp_match_type == "1v3" and team_id != "":
		g.mark_player_dead(owner_player_id)
		# 任一方死亡即判定对方获胜（测试期简化规则）
		var loser_team: String = team_id
		var winner_team: String = "attacker" if loser_team == "defender" else "defender"
		g.pvp_end_game(winner_team, owner_player_id)
		return
	# 主玩家英雄死亡不走 trigger（由 test_main 的 _on_player_hero_died 处理 PVE/1v1 胜负）
	if role == ROLE_MAIN_PLAYER:
		return
	var snap := {"slot_id": id, "hero_name": hero.name_short if hero != null else ""}
	if Engine.get_main_loop() != null and Engine.get_main_loop().root.has_node("/root/Events"):
		Events.notify_hero_died(snap)

# 受到伤害：扣本盘 hero 血量并触发面板闪红。
# source: 伤害来源标签。
#   ""            = 默认（不拦截任何免疫）
#   "unit_direct" = 单位直伤（战斗结算）→ 死守免疫
#   "spell_direct"= 法术直伤（法术 on_play）→ 死守免疫
#   "triggered"   = 触发型效果（援樊、蓄水、英雄技能等）→ 穿透死守
func damage_hero(amount: int, source: String = "") -> void:
	if hero != null:
		# die_hard（死守）：拦截单位/法术直伤
		if hero.has_flag("die_hard") and (source == "unit_direct" or source == "spell_direct"):
			return
		hero.apply_damage(amount)
	_flash_hero_panel()

func _flash_hero_panel() -> void:
	if not is_instance_valid(hero_panel):
		return
	hero_panel.self_modulate = Color("#ffc9c9")
	var tree = Engine.get_main_loop()
	if tree == null or not (tree is SceneTree):
		return
	# 防止面板节点已不在树中时调用 create_tween
	if not hero_panel.is_inside_tree():
		return
	var tw := (tree as SceneTree).create_tween()
	tw.tween_property(hero_panel, "self_modulate", Color.WHITE,
		CombatSystem.HERO_HIT_FADE)

func is_player_side() -> bool:
	return faction == FACTION_PLAYER

func is_enemy_side() -> bool:
	return faction == FACTION_ENEMY

# 视觉水平位置：以 bg_panel 为准，回退到任一 cell 的 global_position.x
func visual_x() -> float:
	if is_instance_valid(bg_panel):
		return bg_panel.global_position.x
	if board != null:
		for key in board.grid_cells.keys():
			var cell = board.grid_cells[key]
			if is_instance_valid(cell):
				return cell.global_position.x
	return INF

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# 把 board / hero / 本盘墓地除外打包；视觉节点（bg_panel / grid_node / hero_panel）
# 不序列化（由场景树持有）。spawners / spell_casters 在 PVP 不启用，序列化时空跳过。
# owner_player_id 留位（多人扩展用），1v1 阶段无字段对应。
func to_dict() -> Dictionary:
	var out: Dictionary = {
		"id":          id,
		"faction":     faction,
		"role":        role,
		"slot_index":  slot_index,
		"team_id":     team_id,
		"owner_player_id":     owner_player_id,
		"allow_player_deploy": allow_player_deploy,
		"graveyard":   _names_of(graveyard),
		"banished":    _names_of(banished),
	}
	if board != null:
		out["board"] = board.to_dict()
	if hero != null:
		out["hero"] = hero.to_dict()
	return out

func from_dict(d: Dictionary) -> void:
	id          = String(d.get("id", id))
	faction     = int(d.get("faction", faction))
	role        = int(d.get("role", role))
	slot_index  = int(d.get("slot_index", slot_index))
	team_id     = String(d.get("team_id", team_id))
	owner_player_id     = String(d.get("owner_player_id", owner_player_id))
	allow_player_deploy = bool(d.get("allow_player_deploy", allow_player_deploy))
	if d.has("board") and board != null:
		board.from_dict(d["board"])
	if d.has("hero") and hero != null:
		hero.from_dict(d["hero"])
	graveyard = _resolve_cards(d.get("graveyard", []))
	banished  = _resolve_cards(d.get("banished",  []))
	pile_changed.emit("graveyard")
	pile_changed.emit("banished")

static func _names_of(arr: Array) -> Array:
	var out: Array = []
	for c in arr:
		if c == null:
			continue
		out.append(String(c.name))
	return out

static func _resolve_cards(names) -> Array:
	var out: Array = []
	if typeof(names) != TYPE_ARRAY:
		return out
	if Engine.get_main_loop() == null:
		return out
	var root: Node = Engine.get_main_loop().root
	if not root.has_node("/root/Game"):
		return out
	for n in names:
		var c = Game.get_card(String(n))
		if c != null:
			out.append(c)
	return out
