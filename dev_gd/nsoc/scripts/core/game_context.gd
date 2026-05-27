extends Node

# 全局游戏上下文。作为 autoload 单例（名字 "Game"）。
# 持有所有核心子系统；负责装配（不持有 UI）。
#
# 旧 main.gd 中散落的 player_health / current_mana / draw_pile / autophagy_counter
# 全部迁移到此处或对应子系统。

signal cards_loaded(cards: Array)
signal level_loaded(level: Dictionary)

var deck: DeckManager
var mana: ManaSystem
var turn: TurnSystem

# 多棋盘注册表。所有 BoardSlot 通过它统一管理。
var registry: BoardRegistry

# 关卡数据：DataLoader.load_level 解析后的多棋盘结构。
# {"boards": {<id>: {initial_units, spawners}}, "initial_units":[...], "spawners":[...]}
# 由 bootstrap 填充，main / test_main 读取后建立各 slot 的 spawner / 初始单位。
var level_data: Dictionary = {}

# 战斗英雄占位字典：bootstrap 解析 hero.json + enemy_default 后写入；
# main / test_main 在装配 slot 时读取并 setup 各盘 HeroState。
# 结构：
#   {"player_main": {hp, name_short, name_full, abilities},
#    "enemy_main":  {hp, name_short, name_full, abilities}}
var hero_specs: Dictionary = {}

# 卡牌主表（id -> CardBase）。用 dictionary 加速 _get_card_data。
var card_db: Dictionary = {}

# 通用计数器（替代 main.autophagy_counter 等零散字段）。
var counters: Dictionary = {}

# 本局来源：
#   ""            = 玩家备战卡组（旧路径，generate_battle_cards 用 decks.json）
#   chapter path  = 战役章节固定牌堆（新路径，generate_battle_cards_from_chapter）
# 由章节场景在切到 main.tscn 前赋值；bootstrap 末尾自动清空避免下次脏读。
var pending_chapter_config: String = ""

# 覆盖关卡 JSON 路径。非空时 bootstrap() 优先读此文件而非默认 test_level.json。
# 由调用方（test_main）在 bootstrap() 前赋值；bootstrap 末尾自动清空。
var pending_level_path: String = ""

# 由 main.gd 创建后注入。cell._can_drop_data 通过 Game.play 查询规则，避免对 main 的反向耦合。
var play: PlayController

# 由 main.gd 创建后注入。Effect 通过 ctx.combat() 访问以发起战斗动画/伤害。
var combat: CombatSystem

func _ready() -> void:
	_install_default_font()
	deck = DeckManager.new(); deck.name = "Deck"; add_child(deck)
	mana = ManaSystem.new(); mana.name = "Mana"; add_child(mana)
	turn = TurnSystem.new(); turn.name = "Turn"; add_child(turn)
	registry = BoardRegistry.new(); registry.name = "BoardRegistry"; add_child(registry)

# 取主玩家盘（手牌锚点）
func main_player_slot() -> BoardSlot:
	return registry.main_player() if registry != null else null

# 取主玩家英雄。无主玩家盘时返回 null。
func player_hero() -> HeroState:
	var slot: BoardSlot = main_player_slot()
	return slot.hero if slot != null else null

# 取主敌盘英雄（按 ROLE_MAIN_ENEMY 取第一个）。无则 null。
func enemy_main_hero() -> HeroState:
	if registry == null:
		return null
	for s in registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		return s.hero
	return null

func enemy_main_slot() -> BoardSlot:
	if registry == null:
		return null
	for s in registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		return s
	return null

# 注入项目级默认中文字体（覆盖 ThemeDB 全局 fallback）。
# 文件缺失时静默退出，开发期不影响桌面运行。
func _install_default_font() -> void:
	const FONT_CANDIDATES := [
		"res://assets/NotoSerifCJKsc-Regular.otf",
		"res://assets/fonts/NotoSansSC-Regular.otf",
		"res://assets/fonts/NotoSansSC-Regular.ttf",
		"res://assets/fonts/NotoSansSC-VariableFont_wght.ttf",
		"res://assets/fonts/NotoSerifCJKsc-Regular.otf",
	]
	for path in FONT_CANDIDATES:
		if ResourceLoader.exists(path):
			var font := load(path)
			if font is Font:
				ThemeDB.fallback_font = font
				return
	push_warning("Game: 未找到中文字体，安卓端中文将显示为方块。请放置 NotoSansSC 到 res://assets/fonts/")

func bootstrap() -> void:
	# 战斗启动：
	#   1. 玩家英雄 = hero.json[BATTLE_HERO_KEY]，HP/技能/abilities 从 JSON 读
	#   2. 敌方英雄 = hero.json.enemy_default
	#   3. 牌池：根据玩家在备战界面保存的卡组（decks.json[BATTLE_HERO_KEY]）
	#      + all_cards.json 原型库 → 生成 user://battle_cards.json，本局战斗读它
	var player_data: Dictionary = DataLoader.get_hero(BATTLE_HERO_KEY)
	var enemy_data: Dictionary = DataLoader.get_enemy_default()
	# display_name = 备战界面/长按详情用的完整名（如"往日之王：科因"）
	# battle_name  = 局内英雄面板用的精简名（如"科因"），未填则回落 display_name
	var player_display: String = String(player_data.get("display_name", BATTLE_HERO_KEY))
	var player_battle: String = String(player_data.get("battle_name", player_display))
	var enemy_display: String = String(enemy_data.get("display_name", "敌人"))
	var enemy_battle: String = String(enemy_data.get("battle_name", enemy_display))
	# 把英雄数据存到 hero_specs，由 main / test_main 装配各 slot 时读取。
	hero_specs = {
		"player_main": {
			"hp": int(player_data.get("max_health", 30)),
			"name_short": player_battle,
			"name_full": player_display,
			"abilities": _to_string_array(player_data.get("abilities", [])),
		},
		"enemy_main": {
			"hp": int(enemy_data.get("max_health", 30)),
			"name_short": enemy_battle,
			"name_full": enemy_display,
			"abilities": _to_string_array(enemy_data.get("abilities", [])),
		},
	}

	# 生成本局牌池文件（user://battle_cards.json），再加载玩家卡组。
	# pending_chapter_config 非空 → 战役章节固定牌堆；否则走玩家备战卡组旧路径。
	if pending_chapter_config != "":
		DataLoader.generate_battle_cards_from_chapter(pending_chapter_config)
	else:
		DataLoader.generate_battle_cards(BATTLE_HERO_KEY)
	var deck_cards := DataLoader.load_cards(DataLoader.BATTLE_CARDS_JSON)
	# card_db 装载所有卡片原型（all_cards.json），供关卡 initial_units / spawners
	# 按名字反查（test_level.json 仅存卡名索引）。deck 只装玩家牌组。
	var all_cards := DataLoader.load_cards(DataLoader.ALL_CARDS_JSON)
	card_db.clear()
	for c in all_cards:
		card_db[c.name] = c
	cards_loaded.emit(deck_cards)

	var level: Dictionary
	if pending_chapter_config != "":
		level = DataLoader.load_level_from_chapter(pending_chapter_config)
	elif pending_level_path != "":
		level = DataLoader.load_level_from_path(pending_level_path)
	else:
		level = DataLoader.load_level()
	level_data = level
	level_loaded.emit(level)

	deck.setup(deck_cards)
	mana.setup(1)
	counters.clear()
	# 重置英雄技能回合用量（防止上局退出时 HeroAbilities.reset_turn_usage 未执行导致残留）
	if has_node("/root/HeroAbilities"):
		HeroAbilities.reset_turn_usage()
	# 重置回合系统运行状态（防止上局退出时 is_running 残留为 true）
	if turn != null:
		turn.is_running = false
		turn.turn_number = 0

	# 一次性消费：清空 pending 字段，避免战斗结束返回主菜单后
	# 再次进入战斗（玩家牌组）误用上一局的配置。
	pending_chapter_config = ""
	pending_level_path = ""


# JSON 解出的 abilities 可能是 Array of String（理想）或混入 null 等；统一为 Array[String]。
static func _to_string_array(raw) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for item in raw:
		out.append(String(item))
	return out


# 测试关卡的固定参数（暂时不走主菜单 UI 选择）。
# 后续接入"选英雄/选关卡"后，BATTLE_HERO_KEY 应由调用方注入。
const BATTLE_HERO_KEY: String = "A"

func get_card(name_str: String):
	return card_db.get(name_str)

func make_effect_context() -> EffectContext:
	return EffectContext.new(self)
