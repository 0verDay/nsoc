extends Node

# 全局游戏上下文。作为 autoload 单例（名字 "Game"）。
# 持有所有核心子系统；负责装配（不持有 UI）。
#
# 旧 main.gd 中散落的 player_health / current_mana / draw_pile / autophagy_counter
# 全部迁移到此处或对应子系统。

signal cards_loaded(cards: Array)
signal level_loaded(level: Dictionary)

var deck: DeckManager
var hero: HeroState
var mana: ManaSystem
var board: BoardModel
var spawners: SpawnerSystem
var turn: TurnSystem

# 卡牌主表（id -> CardBase）。用 dictionary 加速 _get_card_data。
var card_db: Dictionary = {}

# 通用计数器（替代 main.autophagy_counter 等零散字段）。
var counters: Dictionary = {}

# 关卡初始单位配置缓存（main 初始化棋盘时用）。
var initial_units: Array = []

# 由 main.gd 创建后注入。cell._can_drop_data 通过 Game.play 查询规则，避免对 main 的反向耦合。
var play: PlayController

# 由 main.gd 创建后注入。Effect 通过 ctx.combat() 访问以发起战斗动画/伤害。
var combat: CombatSystem

func _ready() -> void:
	_install_default_font()
	deck = DeckManager.new(); deck.name = "Deck"; add_child(deck)
	hero = HeroState.new(); hero.name = "Hero"; add_child(hero)
	mana = ManaSystem.new(); mana.name = "Mana"; add_child(mana)
	board = BoardModel.new(); board.name = "Board"; add_child(board)
	spawners = SpawnerSystem.new(); spawners.name = "Spawners"; add_child(spawners)
	turn = TurnSystem.new(); turn.name = "Turn"; add_child(turn)

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
	# 从 JSON 装配初始状态。
	var hero_info := DataLoader.load_hero_info()
	hero.setup(int(hero_info.player.health), int(hero_info.enemy.health),
		String(hero_info.player.name), String(hero_info.enemy.name),
		hero_info.player.get("abilities", []), hero_info.enemy.get("abilities", []))

	var cards := DataLoader.load_cards()
	card_db.clear()
	for c in cards:
		card_db[c.name] = c
	cards_loaded.emit(cards)

	var level := DataLoader.load_level()
	initial_units = level.initial_units
	spawners.setup(level.spawners)
	level_loaded.emit(level)

	deck.setup(cards)
	mana.setup(1)
	counters.clear()

func get_card(name_str: String):
	return card_db.get(name_str)

func make_effect_context() -> EffectContext:
	return EffectContext.new(self)
