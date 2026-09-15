extends Node

# 全局游戏上下文。作为 autoload 单例（名字 "Game"）。
# 持有所有核心子系统；负责装配（不持有 UI）。
#
# 旧 main.gd 中散落的 player_health / current_mana / draw_pile / autophagy_counter
# 全部迁移到此处或对应子系统。

# 多队伍 PVP 结算信号。任一英雄阵亡即判定对方获胜（见 board_slot._on_hero_died）。
# 本信号由本端确定性模拟直接触发 —— 所有客户端跑同一份锁步状态，必然得到同一结果，
# 因此结算 UI **不再依赖网络回声 game/end**（服务器已把 game/end 列为服务器专属消息，
# 客户端发来会被中继层丢弃；见重构文档 §4.1）。
signal match_result_decided(winning_team: String, loser_pid: String)

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

# 显式对局模式（BattleMode.Kind）。由 bootstrap() / bootstrap_pvp() 设置，
# 取代过去分散的隐式判断（见 scripts/core/battle_mode.gd 的语义说明）。
var battle_mode: int = BattleMode.Kind.CAMPAIGN

# PVP 模式开关。bootstrap() 末尾置 false；bootstrap_pvp() 置 true。
# 业务模块据此跳过 spawner / spell_caster / scripted_events / dialogue 等 PVE 专属流程。
var is_pvp: bool = false

# ── 规则随机源（重构文档.md §3.4-7）─────────────────────────────────────
# 所有"影响对局结果"的随机都必须走这里，不再使用全局 randi() / Array.shuffle()：
#   - PVP：由服务器下发的种子（bootstrap_pvp 的 rng_seed）决定 → 可复现、且客户端无法挑选
#   - PVE：pending_battle_seed 为 0 时 randomize()；测试/回放可显式指定种子
# 这样"随机由谁掌握"就不再是隐式的全局状态，服务器权威可以直接接管。
var battle_rng := RandomNumberGenerator.new()
var pending_battle_seed: int = 0


## 设定本局规则随机种子。seed_value == 0 表示不指定（随机化）。
func seed_battle_rng(seed_value: int = 0) -> void:
	if seed_value == 0:
		battle_rng.randomize()
	else:
		battle_rng.seed = seed_value


## 取 [0, n) 的随机下标（n <= 0 时返回 0，调用方保证数组非空才有意义）。
func rand_index(n: int) -> int:
	if n <= 0:
		return 0
	return battle_rng.randi_range(0, n - 1)


## 就地洗牌（确定性，走 battle_rng）。取代 Array.shuffle()。
func shuffle_in_place(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = battle_rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# ── 动画等待入口（重构文档.md §3.4-6）────────────────────────────────────
# 规则推进需要"等动画放完"的节拍，但服务器/无头批量结算不该真的等：
#   - 客户端：instant_battle = false → 按动画时长等待（表现与原来完全一致）
#   - 服务器/CI：instant_battle = true → 立即返回，瞬时推进
# 只跳过"等待"，不改变任何状态转移 —— 两种模式下两条黄金路径的状态哈希必须相同。
var instant_battle: bool = false


## 等待一段动画时长；instant_battle 时立即返回。
## 规则层的所有等待都必须走这里，不再直接 create_timer（由 CI 分层检查约束）。
func wait_delay(seconds: float) -> void:
	if instant_battle:
		return
	await get_tree().create_timer(seconds).timeout

# ── PVP 回合状态 ────────────────────────────────────────────────────────
# action_order：游戏开始时服务器分配的行动顺序（uuid 数组）。
# active_player_idx：当前行动玩家在 action_order 中的下标；结束回合后 +1 取模。
# 供 test_main / PlayController 判断本端是否当前轮到自己行动。
var pvp_action_order: Array  = []     # [uuid1, uuid2, ...]
var pvp_active_idx:   int    = 0
var pvp_room_id:      String = ""
# PVP 共同随机种子：由房主生成并在 game/start 中下发，
# 双方用相同种子初始化各自的 DeckManager，保证洗牌顺序一致。
var pvp_rng_seed:     int    = 0

# ── v2 权威模式（客户端接入权威路径）──────────────────────────────────────
# 打开后：客户端**不再本地结算**，操作变成 intent/*，盘面按 auth/state 重绘。
# 默认关闭 → 老路径（v1 锁步 + action/*）行为逐字不变。
var v2_authority: bool = false
var v2: V2BattleClient = null

## 打开 v2 权威模式：建客户端核心件、把 Net 的 auth/* 接到"更新镜像 + 重绘本地盘面"。
## 由大厅在权威进程就绪时调用；重复调用幂等（换局时 reset）。
func enable_v2_authority() -> void:
	if v2 == null:
		# V2BattleClient 是纯对象（RefCounted）：不入场景树，因此这里也没有 add_child
		v2 = V2BattleClient.new()
	v2.reset()
	v2_authority = true
	if has_node("/root/Net"):
		if not Net.auth_state.is_connected(_on_auth_state):
			Net.auth_state.connect(_on_auth_state)
		if not Net.auth_event.is_connected(_on_auth_event):
			Net.auth_event.connect(_on_auth_event)
		if not Net.auth_reject.is_connected(_on_auth_reject):
			Net.auth_reject.connect(_on_auth_reject)
		if not Net.auth_verdict.is_connected(_on_auth_verdict):
			Net.auth_verdict.connect(_on_auth_verdict)

func disable_v2_authority() -> void:
	v2_authority = false
	if has_node("/root/Net"):
		if Net.auth_state.is_connected(_on_auth_state):
			Net.auth_state.disconnect(_on_auth_state)
		if Net.auth_event.is_connected(_on_auth_event):
			Net.auth_event.disconnect(_on_auth_event)
		if Net.auth_reject.is_connected(_on_auth_reject):
			Net.auth_reject.disconnect(_on_auth_reject)
		if Net.auth_verdict.is_connected(_on_auth_verdict):
			Net.auth_verdict.disconnect(_on_auth_verdict)
	if v2 != null:
		v2.reset()

func _on_auth_state(payload: Dictionary) -> void:
	if v2 == null:
		return
	v2.apply_state(payload)
	# 服务器说盘面是什么样，就画成什么样（客户端不做任何本地裁决）
	AuthBoardRenderer.apply(payload.get("board", {}) if payload.has("board") else {}, registry)

func _on_auth_event(payload: Dictionary) -> void:
	if v2 != null:
		v2.apply_event(payload)

func _on_auth_reject(payload: Dictionary) -> void:
	if v2 != null:
		v2.apply_reject(payload)

func _on_auth_verdict(payload: Dictionary) -> void:
	if v2 != null:
		v2.apply_verdict(payload)
# ── 1v3 / 多队伍扩展字段 ─────────────────────────────────────────────
# 当前对局类型："1v1" / "1v3"；空串 = PVE。
var pvp_match_type: String = ""
# 队伍映射：{ team_id: [player_id, ...] }，如 {"defender": [pid1], "attacker": [pid2, pid3, pid4]}
var pvp_teams: Dictionary = {}
# 本局已阵亡玩家 uuid 列表（阵亡即加入，pvp_advance_turn 跳过，game/end 后可查）
var pvp_dead_players: Array = []

func pvp_active_player_id() -> String:
	if pvp_action_order.is_empty():
		return local_player_id
	return String(pvp_action_order[pvp_active_idx % pvp_action_order.size()])

func pvp_is_my_turn() -> bool:
	return pvp_active_player_id() == local_player_id

func pvp_advance_turn() -> void:
	if pvp_action_order.is_empty():
		return
	pvp_active_idx = (pvp_active_idx + 1) % pvp_action_order.size()

# 1v3+：跳过已阵亡玩家找到下一个存活玩家。
# 若全部阵亡（不应到此，game/end 应先发），循环后停止。
func pvp_advance_turn_skip_dead() -> void:
	if pvp_action_order.is_empty():
		return
	var n: int = pvp_action_order.size()
	for _i in range(n):
		pvp_active_idx = (pvp_active_idx + 1) % n
		if not pvp_dead_players.has(pvp_action_order[pvp_active_idx]):
			return

# 当前活跃玩家是否完成一整轮（即刚回到 index=0）。
# 用于判断 turn_number 是否该 +1（一轮 = 全部存活玩家走完一次）。
func is_round_complete() -> bool:
	return pvp_active_idx == 0

# 是否为多队伍 PVP（1v3 或 3v3）。
# 用于替换分散的 pvp_match_type == "1v3" 判断，统一支持 3v3 扩展。
func is_multi_team_pvp() -> bool:
	return pvp_match_type == "1v3" or pvp_match_type == "3v3"

# ── 队伍工具方法 ─────────────────────────────────────────────────────
func team_of_player(pid: String) -> String:
	for tid in pvp_teams.keys():
		var members: Array = pvp_teams[tid]
		if members.has(pid):
			return tid
	return ""

func players_of_team(team_id: String) -> Array:
	return pvp_teams.get(team_id, [])


func mark_player_dead(pid: String) -> void:
	if not pvp_dead_players.has(pid):
		pvp_dead_players.append(pid)

# ── 胜负广播 ────────────────────────────────────────────────────────
# 任一落败队伍 → 返回获胜队伍 id（pvp_teams 中第一个非落败队伍）。
# 测试期简化规则，兼容 1v3（defender/attacker）与 3v3（team_a/team_b）。
# 落败队伍未知 / 只有一支队伍时返回空串。
func winning_team_for(loser_team: String) -> String:
	if loser_team == "":
		return ""
	for tid in pvp_teams.keys():
		if tid != loser_team:
			return String(tid)
	return ""

# 房主调用：广播 game/end 并本端转结算 UI。
# winning_team: "defender" / "attacker" / pid（1v1 兼容时传 winner pid）
# loser_pid:    触发结算的阵亡玩家 uuid
#
# 注意：**本端先行结算**（emit match_result_decided），网络消息只作为对端兜底。
# 所有客户端都在本地确定性模拟同一批阵亡，因此即使 game/end 被中继层丢弃，
# 每端也能自行得出正确胜负 —— 结算画面不依赖任何对端消息。
func pvp_end_game(winning_team: String, loser_pid: String) -> void:
	if not is_pvp:
		return
	match_result_decided.emit(winning_team, loser_pid)
	Net.send_to_room("game/end", pvp_room_id, {
		"winning_team": winning_team,
		"loser_pid": loser_pid,
	}, "all")

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

# ── 帝国模式：将领出征对战 ───────────────────────────────────────────────────
# pending_empire_battle：进入战斗前由 EmpireTest 写入。bootstrap() 检测后走帝国分支：
#   - 玩家英雄血量 = hero_force（武力值），名字 = hero_display
#   - 敌方英雄 = 占位 10 血
#   - 玩家牌组 = EmpireDeckStorage.load_deck(hero_key)，原型库 = empire_cards.json
#   - 敌方 spawner：每回合在 enemy_main 后排（row=0）生一个填线宝宝
#   字段：{hero_key, hero_force, hero_display}
# bootstrap 末尾消费清零，避免脏读。
var pending_empire_battle: Dictionary = {}
# 战斗结束后由 main.gd 写入："win" / "lose"。EmpireTest._ready 消费后清空。
var empire_battle_result: String = ""
# EmpireTest 进入战斗前持久化的全图状态。结构：
#   {"deployed": {hero_key: node_id},
#    "exiled":   {hero_key: true},
#    "pending_campaign": {hero_key, source_id, target_id},
#    "faction_overrides": {node_id: faction_id},
#    "gold": int, "food": int}
# 重新加载 EmpireTest 时按此还原。空字典 = 未在战斗回流。
var empire_state: Dictionary = {}

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

# 清掉所有非当前 deck/mana 实例的额外副本（PVE 重新 bootstrap 或 PVP 战斗结束时调）。
# 判断标准：实例指针 == deck / mana → 保留；否则 queue_free。
# 注意：不依赖 local_player_id key，避免 bootstrap_pvp 先改 local_player_id 后调此
# 函数导致原始 deck/mana 被错误 free 的问题。
func clear_extra_decks_and_manas() -> void:
	for pid in decks.keys():
		var d = decks[pid]
		if d == deck:          # 保留原始实例
			continue
		if is_instance_valid(d):
			d.queue_free()
	decks.clear()
	if is_instance_valid(deck):
		decks[local_player_id] = deck
	for pid in manas.keys():
		var m = manas[pid]
		if m == mana:          # 保留原始实例
			continue
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

# ── 三段装配共用的私有步骤（重构文档.md §3.4-4：先消除重复，再抽 BattleSession）──
# 背景：bootstrap（PVE）/ _bootstrap_empire / bootstrap_pvp 原本各自复制了同一批
# "清旧状态"、"装载 card_db"、"清一次性输入"代码。这里先收敛为单一实现，
# 行为保持不变（冒烟 STATE_HASH 逐位一致可证）。

## 清旧子系统状态。必须在装配 deck / mana 之前调用。
func _reset_battle_subsystems() -> void:
	counters.clear()
	# 重置英雄技能回合用量（防止上局退出时 reset_turn_usage 未执行导致残留）
	if has_node("/root/HeroAbilities"):
		HeroAbilities.reset_turn_usage()
	# 清空玩家装备（防止上局残留）
	if has_node("/root/Equipments"):
		Equipments.clear_all()
	# 重置回合系统运行状态（防止上局退出时 is_running 残留为 true）
	if turn != null:
		turn.is_running = false
		turn.turn_number = 0


## 装载卡牌原型库到 card_db。
## cards 为空 → 从 all_cards.json 读（PVE / 帝国）；非空 → 用调用方给的实例（PVP 由服务器下发）。
func _load_card_db(cards: Array = []) -> void:
	var source: Array = cards
	if source.is_empty():
		source = DataLoader.load_cards(DataLoader.ALL_CARDS_JSON)
	card_db.clear()
	for c in source:
		card_db[c.name] = c


## 清空一次性输入：pending 关卡字段与场景注入的选择器引用。
## 避免战斗结束返回主菜单后，再次进入战斗时误用上一局的配置 / 悬空引用。
func _clear_pending_inputs() -> void:
	pending_chapter_config = ""
	pending_level_path = ""
	pending_battle_seed = 0
	_target_selector_node = null
	_hand_picker_node     = null


func bootstrap() -> void:
	# 规则随机源：pending_battle_seed 为 0 时随机化（测试/回放可显式指定）
	seed_battle_rng(pending_battle_seed)
	# 帝国模式出征：在所有标准 PVE 装载之前走专属分支
	if not pending_empire_battle.is_empty():
		battle_mode = BattleMode.Kind.EMPIRE
		_bootstrap_empire(pending_empire_battle)
		pending_empire_battle = {}
		return
	# 显式模式：脚本化关卡（章节/关卡 JSON）为 CAMPAIGN，否则为 SKIRMISH。
	# 该判断与 main.gd 既有的 _is_campaign 完全等价，保证行为不变。
	battle_mode = BattleMode.from_pending(pending_chapter_config, pending_level_path, false)
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

	# ② 决定玩家英雄 key：章节 hero_key 优先，否则读玩家在备战界面最后选定的英雄。
	var hero_key: String = String(level.get("hero_key", ""))
	if hero_key == "":
		hero_key = get_battle_hero_key()

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
	# pending_chapter_config 非空 → 战役章节固定牌堆；否则走玩家备战卡组。
	if pending_chapter_config != "":
		DataLoader.generate_battle_cards_from_chapter(pending_chapter_config)
	else:
		DataLoader.generate_battle_cards(get_battle_hero_key())
	var deck_cards := DataLoader.load_cards(DataLoader.BATTLE_CARDS_JSON)
	# card_db 装载所有卡片原型（all_cards.json），供关卡 initial_units / spawners
	# 按名字反查（test_level.json 仅存卡名索引）。deck 只装玩家牌组。
	_load_card_db()

	deck.setup(deck_cards)
	# 战役章节起始费（仅覆盖首回合 max=current=N，第二回合按正常 +1 走）
	var start_mana: int = int(level.get("initial_mana", 0))
	if start_mana <= 0:
		start_mana = 1
	# 章节级费用上限硬封顶（如街亭·王平协防：cap=5 永久不再 +1）。
	# 0 / 缺失时 ManaSystem 走默认 MAX_MANA_CAP=10。
	var max_cap: int = int(level.get("mana_max_cap", 0))
	if max_cap <= 0:
		max_cap = ManaSystem.MAX_MANA_CAP
	mana.setup(start_mana, max_cap)
	# 清旧子系统状态（counters / 技能回合用量 / 装备 / 回合运行态）
	_reset_battle_subsystems()

	# 装载战役章节胜利目标（无 objective 字段时清空，按默认胜负规则走）
	if has_node("/root/Objectives"):
		Objectives.setup_for_battle(level.get("objective", {}))

	# 初始化脚本化事件系统（解析 triggers / board_events.actions，接 turn_started 信号）
	if has_node("/root/Events"):
		Events.setup_for_battle(level_data)

	# 一次性消费：清空 pending 字段与选择器引用（防止误用上一局配置 / 引用悬空）
	_clear_pending_inputs()

	# PVE 模式：清掉上局 PVP 残留的额外 deck/mana 实例；本地玩家保留为别名。
	is_pvp = false
	local_player_id = "player_main"
	clear_extra_decks_and_manas()


# ── 帝国模式战斗装配 ─────────────────────────────────────────────────────────
# 由 EmpireTest 在写入 pending_empire_battle 后通过 bootstrap() 触发。
#   ctx：{ "target_id": int, "attackers": Array[{hero_key, hero_force, hero_display}] }
# 与标准 PVE bootstrap 的差异：
#   - 多棋盘按 N=len(attackers) 启用：N=1 仅主对主；N=2 加 ally_left/enemy_left；N=3 全部 6 盘
#   - 玩家主棋盘 = attackers[0]：hp = hero_force，可出牌；其余 aux 玩家盘 hp = 各自 force，
#     仅作 spawner 占位（不参与玩家主动出牌；但盘体仍存在以便游戏推进）
#   - 所有敌方棋盘 hero hp = 10，无技能
#   - 所有启用棋盘各自底线（玩家盘 row=2，敌方盘 row=0）每回合生 1 张填线宝宝
#   - 玩家牌组 = EmpireDeckStorage.load_deck(主将 hero_key)，原型库 = empire_cards.json
#   - card_db 仍用 all_cards.json（spawner 召唤填线宝宝按 name 反查）
#   - 跳过 Objectives / Events / 章节 hero/牌堆 路径
const _EMPIRE_PLAYER_BOARD_IDS: Array = ["ally_left", "player_main", "ally_right"]
const _EMPIRE_ENEMY_BOARD_IDS:  Array = ["enemy_left", "enemy_main", "enemy_right"]
# slot 索引：上排 0/1/2 = enemy_left/main/right，下排 3/4/5 = ally_left/player_main/ally_right
const _EMPIRE_PLAYER_SLOT_IDX:  Array = [3, 4, 5]
const _EMPIRE_ENEMY_SLOT_IDX:   Array = [0, 1, 2]
# N=1 主对主；N=2 主+左；N=3 全启用。这里给出每个 N 启用的棋盘下标（0=left, 1=main, 2=right）。
const _EMPIRE_ENABLE_BY_N: Dictionary = {
	1: [1],
	2: [1, 0],
	3: [1, 0, 2],
}


func _bootstrap_empire(ctx: Dictionary) -> void:
	battle_mode = BattleMode.Kind.EMPIRE
	is_pvp = false
	local_player_id = "player_main"
	clear_extra_decks_and_manas()

	var attackers: Array = ctx.get("attackers", [])
	if attackers.is_empty():
		push_error("_bootstrap_empire: empty attackers")
		return
	var n: int = clampi(attackers.size(), 1, 3)
	var enable_indices: Array = _EMPIRE_ENABLE_BY_N.get(n, [1])

	var main_attacker: Dictionary = attackers[0]
	var main_hero_key: String = String(main_attacker.get("hero_key", ""))
	var main_hero_display: String = String(main_attacker.get("hero_display", main_hero_key))

	hero_specs.clear()

	# 每个启用棋盘构造 hero 配置 + spawner（己方底线 row=2 / 敌方底线 row=0）
	var boards: Dictionary = {}
	for i in range(n):
		var slot_idx_in_layout: int = int(enable_indices[i])
		var att: Dictionary = attackers[i]
		var p_id: String = _EMPIRE_PLAYER_BOARD_IDS[slot_idx_in_layout]
		var e_id: String = _EMPIRE_ENEMY_BOARD_IDS[slot_idx_in_layout]
		var p_hp: int = max(int(att.get("hero_force", 1)), 1)
		var p_name: String = String(att.get("hero_display", att.get("hero_key", p_id)))
		var p_role: String = "main_player" if slot_idx_in_layout == 1 else "ally"
		var e_role: String = "main_enemy"  if slot_idx_in_layout == 1 else "enemy"
		# 主棋盘 = 玩家可出牌的那块（slot_idx_in_layout==1，即 player_main）
		boards[p_id] = {
			"id": p_id, "faction": 0, "role": p_role,
			"slot_index": _EMPIRE_PLAYER_SLOT_IDX[slot_idx_in_layout],
			"enabled": true,
			"hero": {},
			"initial_units": [],
			"spawners": [{
				"name": "填线宝宝",
				"faction": 0,
				"positions": [Vector2(2, 1)],
				"interval": 1,
			}],
			"spell_casters": [],
		}
		boards[e_id] = {
			"id": e_id, "faction": 1, "role": e_role,
			"slot_index": _EMPIRE_ENEMY_SLOT_IDX[slot_idx_in_layout],
			"enabled": true,
			"hero": {},
			"initial_units": [],
			"spawners": [{
				"name": "填线宝宝",
				"faction": 1,
				"positions": [Vector2(0, 1)],
				"interval": 1,
			}],
			"spell_casters": [],
		}
		# hero_specs 由下方统一注入（按 board id 索引）
		hero_specs[p_id] = {
			"hp": p_hp,
			"name_short": p_name,
			"name_full": p_name,
			"abilities": [],
		}
		hero_specs[e_id] = {
			"hp": 10,
			"name_short": "占位敌将",
			"name_full": "占位敌将",
			"abilities": [],
		}

	# 合成 level_data
	level_data = {
		"boards": boards,
		"initial_units": [],
		"spawners": [],
		"board_events": [],
		"triggers": [],
		"hero_key": "",
		"initial_mana": 1,
		"mana_max_cap": 0,
		"objective": {},
		"name": "帝国出征",
	}

	# card_db：原型库走 all_cards.json（spawner 与卡片回退同源）
	_load_card_db()

	# 玩家牌组：从 EmpireDeckStorage 拿主将的卡组配置，反查 empire_cards.json 原型，
	# 写入 user://battle_cards.json。仅主将卡组生效（其余攻方仅 spawner）。
	DataLoader.generate_battle_cards_from_empire(main_hero_key)
	var deck_cards := DataLoader.load_cards(DataLoader.BATTLE_CARDS_JSON)

	deck.setup(deck_cards)
	mana.setup(1, ManaSystem.MAX_MANA_CAP)
	_reset_battle_subsystems()

	# 帝国模式不走章节胜利目标 / 脚本化事件
	if has_node("/root/Objectives"):
		Objectives.setup_for_battle({})
	if has_node("/root/Events"):
		Events.setup_for_battle(level_data)

	_clear_pending_inputs()


# ── PVP 战斗装配（联机入口）──────────────────────────────────────────
# 由 NetworkManager 在收到服务器 game/start 时调用。
# - p_local_pid：本地玩家 uuid（NetworkManager 持有）
# - all_player_ids：房间内全部玩家 uuid（含本地），按服务器分配的行动顺序排列
# - per_player_deck_cards：每位玩家自己的牌组，格式 { pid: Array[CardBase] }
#   若第三参数传 Array（旧调用方式），则所有玩家共用该 Array
# - all_cards_db：可选，PVP 阶段若客户端未预加载 all_cards.json 时用于补 card_db
# - rng_seed：房主生成的 RNG 种子（0 = 不使用确定性洗牌）
# - per_player_heroes：每位玩家选定的英雄 key，格式 { pid: hero_key }
#   缺失的 pid 回退到 DeckStorage.get_selected_hero()
#
# 与 PVE bootstrap 的区别：
#   - 跳过章节加载、Objectives.setup_for_battle、Events.setup_for_battle
#   - 双方独立 DeckManager + ManaSystem，各持自己的牌组和英雄
#   - SpawnerSystem / SpellCasterSystem 不挂载（由场景装配方按 is_pvp 跳过）
#   - 不消费 pending_chapter_config / pending_level_path
func bootstrap_pvp(p_local_pid: String, all_player_ids: Array,
		per_player_deck_cards,  # Dictionary { pid: Array[CardBase] } 或 Array（向后兼容）
		all_cards_db: Array = [], rng_seed: int = 0,
		per_player_heroes: Dictionary = {},   # { pid: hero_key }，缺失时回退本地选中
		match_type: String = "1v1",           # "1v1" / "1v3"
		teams_map: Dictionary = {},           # { team_id: [pid,...] }，空=自动推断
		slot_layout: Array = []) -> void:     # [{ slot_id, owner_pid, team_id, slot_index }]
	battle_mode = BattleMode.Kind.PVP
	is_pvp = true
	local_player_id = p_local_pid
	# 规则随机源：PVP 由服务器下发的种子决定（可复现、客户端无法挑选）
	seed_battle_rng(rng_seed)

	# card_db 装载：PVP 模式服务器只下发牌组，客户端仍需 all_cards.json 解卡牌静态属性。
	if all_cards_db.size() > 0:
		_load_card_db(all_cards_db)
	elif card_db.size() == 0:
		# 客户端本地仍有 all_cards.json，自行加载兜底
		_load_card_db()

	# 兼容旧调用：第三参数为 Array 时视为所有玩家共用同一套牌组
	var deck_map: Dictionary = {}
	if typeof(per_player_deck_cards) == TYPE_DICTIONARY:
		deck_map = per_player_deck_cards
	else:
		# 旧路径：Array → 所有玩家共用
		var shared: Array = per_player_deck_cards if typeof(per_player_deck_cards) == TYPE_ARRAY else []
		for pid_raw in all_player_ids:
			deck_map[String(pid_raw)] = shared

	# 清旧：额外 deck/mana 实例 + 子系统状态
	clear_extra_decks_and_manas()
	_reset_battle_subsystems()

	# 逐玩家建 deck + mana，每人使用自己的牌组。
	# PVP 模式下每位玩家用 (rng_seed + slot_index) 作为确定性种子，
	# 保证同一牌组各自洗牌顺序不同但均可复现。
	pvp_rng_seed = rng_seed
	var pid_index: int = 0
	for pid_raw in all_player_ids:
		var pid: String = String(pid_raw)
		var pid_cards: Array = deck_map.get(pid, [])
		var d: DeckManager = add_deck(pid)
		if rng_seed != 0:
			# 每位玩家的种子 = base_seed + 玩家序号，保证各玩家洗牌结果不同
			d.setup_seeded(pid_cards.duplicate(), rng_seed + pid_index)
		else:
			d.setup(pid_cards.duplicate())
		pid_index += 1
		var m: ManaSystem = add_mana(pid)
		m.setup(1)

	# hero_specs：按 per_player_heroes 字典为每位玩家分配各自选定的英雄。
	# 若某玩家 hero_key 缺失 → 回退到本地存档的 selected_hero（DeckStorage）。
	hero_specs.clear()
	for pid_raw in all_player_ids:
		var pid: String = String(pid_raw)
		var hkey: String = String(per_player_heroes.get(pid, ""))
		if hkey == "":
			hkey = DeckStorage.get_selected_hero()
		var hdata: Dictionary = DataLoader.get_hero(hkey)
		var h_full: String    = String(hdata.get("display_name", hkey))
		var h_short: String   = String(hdata.get("battle_name", h_full))
		var h_abilities: Array = _to_string_array(hdata.get("abilities", []))
		var h_hp: int         = int(hdata.get("max_health", 30))
		hero_specs[pid] = {
			"hp":         h_hp,
			"name_short": h_short,
			"name_full":  h_full,
			"abilities":  h_abilities,
		}

	# level_data：PVP 不走章节关卡，留空让装配方按 is_pvp 走 PVP 专属布局。
	level_data = {}
	_clear_pending_inputs()
	# PVP 回合状态初始化
	pvp_action_order = []
	for pid_raw in all_player_ids:
		pvp_action_order.append(String(pid_raw))
	pvp_active_idx = 0
	# pvp_room_id 由 sparring_panel 在切场景前单独注入 Net，这里取回做镜像
	pvp_room_id = Net.get_current_room_id()

	# ── 1v3 多人字段初始化 ────────────────────────────────────────────
	pvp_match_type = match_type
	pvp_dead_players = []

	# teams_map：优先用外部传入；否则从 slot_layout 推断（最准确）；最后按位置兜底
	if not teams_map.is_empty():
		pvp_teams = teams_map.duplicate()
	elif not slot_layout.is_empty():
		# 从 slot_layout 提取 team 信息（1v3 / 3v3 通用）
		var inferred: Dictionary = {}
		for entry in slot_layout:
			var pid: String = String(entry.get("owner_pid", ""))
			var tid: String = String(entry.get("team_id", ""))
			if pid == "" or tid == "":
				continue
			if not inferred.has(tid):
				inferred[tid] = []
			inferred[tid].append(pid)
		pvp_teams = inferred
	elif match_type == "1v3" and all_player_ids.size() >= 4:
		pvp_teams = {
			"defender": [String(all_player_ids[0])],
			"attacker":  [String(all_player_ids[1]), String(all_player_ids[2]), String(all_player_ids[3])],
		}
	elif match_type == "1v1" and all_player_ids.size() == 2:
		pvp_teams = {}   # 1v1 不使用 team_id 判断，保留兼容
	else:
		pvp_teams = {}

	# slot_layout：存入 level_data 供 _inject_pvp_level_data 装配时读取
	# 格式：[{ "slot_id": str, "owner_pid": str, "team_id": str, "slot_index": int }]
	if not slot_layout.is_empty():
		level_data = {"pvp_slot_layout": slot_layout}
	else:
		level_data = {}


# JSON 解出的 abilities 可能是 Array of String（理想）或混入 null 等；统一为 Array[String]。
func _to_string_array(raw) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for item in raw:
		out.append(String(item))
	return out


# 测试关卡英雄 key：动态读取玩家在备战界面选定并退出时的英雄。
# DeckStorage.get_selected_hero() 返回 "A"/"B"/"C" 等，首次启动无记录时默认 "A"。
# 注意：此属性是运行时计算值，不缓存，每次 bootstrap 调用时都重新读取，
# 保证玩家在主菜单 → 备战界面修改选英雄 → 返回 → 点 Test 时能立刻生效。
static func get_battle_hero_key() -> String:
	return DeckStorage.get_selected_hero()

# 向后兼容：保留常量供外部可能的直接引用，但指向默认值（实际走 get_battle_hero_key()）。
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
