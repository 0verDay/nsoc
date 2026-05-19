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

func _ready() -> void:
	deck = DeckManager.new(); deck.name = "Deck"; add_child(deck)
	hero = HeroState.new(); hero.name = "Hero"; add_child(hero)
	mana = ManaSystem.new(); mana.name = "Mana"; add_child(mana)
	board = BoardModel.new(); board.name = "Board"; add_child(board)
	spawners = SpawnerSystem.new(); spawners.name = "Spawners"; add_child(spawners)
	turn = TurnSystem.new(); turn.name = "Turn"; add_child(turn)

func bootstrap() -> void:
	# 从 JSON 装配初始状态。
	var hero_hp := DataLoader.load_hero_health()
	hero.setup(int(hero_hp.player), int(hero_hp.enemy))

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
