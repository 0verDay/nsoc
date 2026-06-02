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

# ── 多实例（PVP 联机扩展）────────────────────────────────────────
# 字典存所有玩家的牌库 / 费用实例。PVE 模式下也填一份本地玩家。
# deck / mana 是 local_player_id 对应实例的别名，PVE 旧代码无需改动。
# 多人扩展时由 PlayController / TurnSystem 通过 get_deck(pid) / get_mana(pid) 取。
var decks: Dictionary = {}        # player_id -> DeckManager
var manas: Dictionary = {}        # player_id -> ManaSystem

# 当前本地玩家身份。PVE 固定 "player_main"；PVP 由 NetworkManager 在握手时注入 uuid。
var local_player_id: String = "player_main"

# PVP 模式开关。bootstrap() 末尾置 false；bootstrap_pvp() 置 true。
# 业务模块据此跳过 spawner / spell_caster / scripted_events / dialogue 等 PVE 专属流程。
var is_pvp: bool = false

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

# 退出到菜单的过渡 flag：
# pending_fade_in_from_white：退出动画白色盖满后切场景；下一个场景 _ready 检测此 flag，
# 播白色 overlay 渐隐，组成"渐白→切场景→白淡出"的无黑闪过渡。
# 由场景消费后清零，防止下次脏读。
# （旧 pending_fade_in_from_black 保留以兼容其他可能的调用方）
var pending_fade_in_from_black: bool = false
var pending_fade_in_from_white: bool = false

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
	# 把本地玩家的 deck / mana 挂到字典，多人扩展时其他玩家通过 add_deck/add_mana 加。
	decks[local_player_id] = deck
	manas[local_player_id] = mana

# ── 多实例 deck / mana 访问 ──────────────────────────────────────
# 取指定玩家的 deck。pid 为空时取本地玩家。无对应实例返回 null。
func get_deck(pid: String = "") -> DeckManager:
	var key: String = pid if pid != "" else local_player_id
	return decks.get(key)

func get_mana(pid: String = "") -> ManaSystem:
	var key: String = pid if pid != "" else local_player_id
	return manas.get(key)

# 按 BoardSlot 反查 deck / mana。
# slot.owner_player_id 为空时（PVE）回退到本地玩家 deck/mana。
# 多人模式下 PlayController / HandView 通过此 API 决定从哪个玩家牌库抽牌、扣谁的费。
func deck_of_slot(slot: BoardSlot) -> DeckManager:
	if slot == null:
		return deck
	var pid: String = slot.owner_player_id if slot.owner_player_id != "" else local_player_id
	return decks.get(pid, deck)

func mana_of_slot(slot: BoardSlot) -> ManaSystem:
	if slot == null:
		return mana
	var pid: String = slot.owner_player_id if slot.owner_player_id != "" else local_player_id
	return manas.get(pid, mana)

# 为玩家创建 deck（若已存在直接返回旧实例）。本地玩家命中时同步更新 deck 别名。
func add_deck(pid: String) -> DeckManager:
	if decks.has(pid):
		return decks[pid]
	var d := DeckManager.new()
	d.name = "Deck_" + pid
	add_child(d)
	decks[pid] = d
	if pid == local_player_id:
		deck = d
	return d

func add_mana(pid: String) -> ManaSystem:
	if manas.has(pid):
		return manas[pid]
	var m := ManaSystem.new()
	m.name = "Mana_" + pid
	add_child(m)
	manas[pid] = m
	if pid == local_player_id:
		mana = m
	return m

# 清掉所有非本地玩家的 deck / mana（PVE 重新 bootstrap 或 PVP 战斗结束时调）。
# 本地玩家实例保留并复位指针，避免悬空。
func clear_extra_decks_and_manas() -> void:
	for pid in decks.keys():
		if pid == local_player_id:
			continue
		var d = decks[pid]
		if is_instance_valid(d):
			d.queue_free()
	decks.clear()
	if is_instance_valid(deck):
		decks[local_player_id] = deck
	for pid in manas.keys():
		if pid == local_player_id:
			continue
		var m = manas[pid]
		if is_instance_valid(m):
			m.queue_free()
	manas.clear()
	if is_instance_valid(mana):
		manas[local_player_id] = mana

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
	#   1. 关卡：先解析 level（含战役章节专属字段 hero_key / initial_mana）
	#   2. 玩家英雄 = hero.json[hero_key]，hero_key 来自章节 JSON；缺失回退 BATTLE_HERO_KEY
	#   3. 敌方英雄 = hero.json.enemy_default
	#   4. 牌池：战役章节用章节固定牌堆；否则走玩家备战卡组（decks.json[BATTLE_HERO_KEY]）
	#      + all_cards.json 原型库 → 生成 user://battle_cards.json，本局战斗读它

	# ① 先加载关卡。战役章节的 hero_key / initial_mana 此时进入 level_data。
	var level: Dictionary
	if pending_chapter_config != "":
		level = DataLoader.load_level_from_chapter(pending_chapter_config)
	elif pending_level_path != "":
		level = DataLoader.load_level_from_path(pending_level_path)
	else:
		level = DataLoader.load_level()
	level_data = level

	# ② 决定玩家英雄 key：章节 hero_key 优先，否则回退默认。
	var hero_key: String = String(level.get("hero_key", ""))
	if hero_key == "":
		hero_key = BATTLE_HERO_KEY

	var player_data: Dictionary = DataLoader.get_hero(hero_key)
	var enemy_data: Dictionary = DataLoader.get_enemy_default()
	# display_name = 备战界面/长按详情用的完整名（如"往日之王：科因"）
	# battle_name  = 局内英雄面板用的精简名（如"科因"），未填则回落 display_name
	var player_display: String = String(player_data.get("display_name", hero_key))
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

	# ③ level 装载完成，发信号（顺序保留：listener 期望 cards_loaded 在前）
	level_loaded.emit(level)

	deck.setup(deck_cards)
	# 战役章节起始费（仅覆盖首回合 max=current=N，第二回合按正常 +1 走）
	var start_mana: int = int(level.get("initial_mana", 0))
	if start_mana <= 0:
		start_mana = 1
	mana.setup(start_mana)
	counters.clear()
	# 重置英雄技能回合用量（防止上局退出时 HeroAbilities.reset_turn_usage 未执行导致残留）
	if has_node("/root/HeroAbilities"):
		HeroAbilities.reset_turn_usage()
	# 清空玩家装备（防止上局残留）
	if has_node("/root/Equipments"):
		Equipments.clear_all()
	# 重置回合系统运行状态（防止上局退出时 is_running 残留为 true）
	if turn != null:
		turn.is_running = false
		turn.turn_number = 0

	# 装载战役章节胜利目标（无 objective 字段时清空，按默认胜负规则走）
	if has_node("/root/Objectives"):
		Objectives.setup_for_battle(level.get("objective", {}))

	# 初始化脚本化事件系统（解析 triggers / board_events.actions，接 turn_started 信号）
	if has_node("/root/Events"):
		Events.setup_for_battle(level_data)

	# 一次性消费：清空 pending 字段，避免战斗结束返回主菜单后
	# 再次进入战斗（玩家牌组）误用上一局的配置。
	pending_chapter_config = ""
	pending_level_path = ""
	# 清空上一局场景注入的选择器引用，防止场景 free 后引用悬空。
	# 新场景在 _install_controllers 末尾会重新调 register_selectors 注入。
	_target_selector_node = null
	_hand_picker_node     = null

	# PVE 模式：清掉上局 PVP 残留的额外 deck/mana 实例；本地玩家保留为别名。
	is_pvp = false
	local_player_id = "player_main"
	clear_extra_decks_and_manas()


# ── PVP 战斗装配（联机入口）──────────────────────────────────────────
# 由 NetworkManager 在收到服务器 game/start 时调用。
# - p_local_pid：本地玩家 uuid（NetworkManager 持有）
# - all_player_ids：房间内全部玩家 uuid（含本地），按服务器分配的行动顺序排列
# - deck_cards：服务器下发的预设牌组（CardBase 数组，已通过 card_db 解析）
# - all_cards_db：可选，PVP 阶段若客户端未预加载 all_cards.json 时用于补 card_db
#
# 与 PVE bootstrap 的区别：
#   - 跳过章节加载、Objectives.setup_for_battle、Events.setup_for_battle
#   - 双方独立 DeckManager + ManaSystem
#   - 全员同英雄 A「再起」（按决策 1.3）
#   - SpawnerSystem / SpellCasterSystem 不挂载（由场景装配方按 is_pvp 跳过）
#   - 不消费 pending_chapter_config / pending_level_path
func bootstrap_pvp(p_local_pid: String, all_player_ids: Array,
		deck_cards: Array, all_cards_db: Array = []) -> void:
	is_pvp = true
	local_player_id = p_local_pid

	# card_db 装载：PVP 模式服务器只下发牌组，客户端仍需 all_cards.json 解卡牌静态属性。
	if all_cards_db.size() > 0:
		card_db.clear()
		for c in all_cards_db:
			card_db[c.name] = c
	elif card_db.size() == 0:
		# 客户端本地仍有 all_cards.json，自行加载兜底
		var loaded := DataLoader.load_cards(DataLoader.ALL_CARDS_JSON)
		card_db.clear()
		for c in loaded:
			card_db[c.name] = c

	cards_loaded.emit(deck_cards)

	# 清旧
	clear_extra_decks_and_manas()
	counters.clear()
	if has_node("/root/HeroAbilities"):
		HeroAbilities.reset_turn_usage()
	if has_node("/root/Equipments"):
		Equipments.clear_all()
	if turn != null:
		turn.is_running = false
		turn.turn_number = 0

	# 逐玩家建 deck + mana（同一套预设牌组 → 各自独立洗牌）
	for pid_raw in all_player_ids:
		var pid: String = String(pid_raw)
		# 牌组按引用复制即可（CardBase 是不可变模板）；DeckManager.setup 内部会按 count 展开。
		var d: DeckManager = add_deck(pid)
		d.setup(deck_cards.duplicate())
		var m: ManaSystem = add_mana(pid)
		m.setup(1)

	# hero_specs：PVP 全员 A「再起」（决策 1.3）
	hero_specs.clear()
	var a_data: Dictionary = DataLoader.get_hero("A")
	var a_full: String  = String(a_data.get("display_name", "再起"))
	var a_short: String = String(a_data.get("battle_name", a_full))
	var a_abilities: Array = _to_string_array(a_data.get("abilities", []))
	var a_hp: int = int(a_data.get("max_health", 30))
	for pid_raw in all_player_ids:
		var pid: String = String(pid_raw)
		hero_specs[pid] = {
			"hp": a_hp,
			"name_short": a_short,
			"name_full": a_full,
			"abilities": a_abilities,
		}

	# level_data：PVP 不走章节关卡，留空让装配方按 is_pvp 走 PVP 专属布局。
	level_data = {}
	pending_chapter_config = ""
	pending_level_path = ""
	_target_selector_node = null
	_hand_picker_node     = null


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

# 注入交互式选择器到当前局内的 EffectContext 工厂。
# 由 main / test_main 在装配完控制器后调用。
var _target_selector_node: Node = null
var _hand_picker_node: Node     = null

func register_selectors(target_selector: Node, hand_picker: Node) -> void:
	_target_selector_node = target_selector
	_hand_picker_node     = hand_picker

# 重写工厂：创建 ctx 时自动注入选择器（仅注入仍有效的节点）
func make_effect_context_with_selectors() -> EffectContext:
	var ctx := EffectContext.new(self)
	if is_instance_valid(_target_selector_node):
		ctx._target_selector = _target_selector_node
	if is_instance_valid(_hand_picker_node):
		ctx._hand_picker = _hand_picker_node
	return ctx
