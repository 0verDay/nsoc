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
		hero_resolver = Callable(self, "damage_hero")
	allow_player_deploy = (faction == FACTION_PLAYER)

# 受到伤害：扣本盘 hero 血量并触发面板闪红。
func damage_hero(amount: int) -> void:
	if hero != null:
		hero.apply_damage(amount)
	_flash_hero_panel()

func _flash_hero_panel() -> void:
	if not is_instance_valid(hero_panel):
		return
	hero_panel.self_modulate = Color("#ffc9c9")
	var tree = Engine.get_main_loop()
	if tree == null or not (tree is SceneTree):
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
