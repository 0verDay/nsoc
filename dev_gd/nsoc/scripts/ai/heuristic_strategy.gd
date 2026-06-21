class_name HeuristicStrategy
extends AiStrategy

var spell_value_threshold: float = 1.0

func decide(view: AiGameView) -> Array:
	var actions: Array = []
	var mana_left: int = view.current_mana()
	var own_slot := view.own_slot()
	if own_slot == null:
		return [AiAction.end_turn()]

	# 费用 >= 2 才先施法；只有 1 费时优先出单位
	var targeted_cells: Array = []   # 本轮已锁定的目标格，避免两张箭射同一目标
	if mana_left >= 2:
		for card in _spells_sorted(view):
			if mana_left < card.cost:
				continue
			var tgt = _best_spell_target(view, card, targeted_cells)
			if tgt == null and String(card.target) != "":
				continue
			if _spell_value(view, card, tgt) < spell_value_threshold:
				continue
			var t_row: int = tgt.row if tgt != null else -1
			var t_col: int = tgt.col if tgt != null else -1
			var t_slot: String = String(tgt.slot_id) if tgt != null else own_slot.id
			actions.append(AiAction.play_spell(card.name, t_slot, t_row, t_col))
			if tgt != null:
				targeted_cells.append(tgt)
			mana_left -= card.cost

	# 单位部署（高费优先）
	var placed_cols: Array = []
	var placed_cells: Array = []
	for card in _units_sorted_by_cost_desc(view):
		if mana_left < card.cost:
			continue
		var cell = _best_deploy_cell(view, card, own_slot, placed_cols, placed_cells)
		if cell == null:
			continue
		actions.append(AiAction.play_unit(card.name, own_slot.id, cell.row, cell.col))
		placed_cols.append(cell.col)
		placed_cells.append(cell)
		mana_left -= card.cost

	# 剩余 1 费补一张法术
	if mana_left >= 1:
		for card in _spells_sorted(view):
			if mana_left < card.cost:
				continue
			var tgt = _best_spell_target(view, card, targeted_cells)
			if tgt == null and String(card.target) != "":
				continue
			if _spell_value(view, card, tgt) < spell_value_threshold:
				continue
			var t_row: int = tgt.row if tgt != null else -1
			var t_col: int = tgt.col if tgt != null else -1
			var t_slot: String = String(tgt.slot_id) if tgt != null else own_slot.id
			actions.append(AiAction.play_spell(card.name, t_slot, t_row, t_col))
			mana_left -= card.cost
			break

	actions.append(AiAction.end_turn())
	return actions

func choose_cross_target(view: AiGameView, _cell) -> String:
	var best_id: String = ""
	var best_score: float = -INF
	for s in view.opponent_slots():
		if not is_instance_valid(s):
			continue
		var hp: float = 9999.0
		if s.hero != null:
			hp = float(s.hero.health)
		var unit_count: int = 0
		if s.board != null:
			for c in s.board.grid_cells.values():
				if is_instance_valid(c) and c.has_card:
					unit_count += 1
		var score: float = -hp + float(3 - unit_count)
		if score > best_score:
			best_score = score
			best_id = s.id
	return best_id

# ── 内部评分 ───────────────────────────────────────────────────────────────

func _units_sorted_by_cost_desc(view: AiGameView) -> Array:
	var units: Array = []
	for card in view.hand_cards():
		if card is CardUnit:
			units.append(card)
	units.sort_custom(func(a, b): return a.cost > b.cost)
	return units

func _best_deploy_cell(view: AiGameView, _card, own_slot: BoardSlot,
		placed_cols: Array, placed_cells: Array = []):
	if own_slot == null or own_slot.board == null:
		return null

	# 前排 = 推进方向终点。ENEMY → row2；PLAYER/ALLY → row0
	var front_row: int = BoardModel.front_row_of_slot(own_slot)

	# 统计己方各行/列已有单位数
	var row_counts: Array = [0, 0, 0]
	var col_counts: Array = [0, 0, 0]
	for r in range(BoardModel.ROWS):
		for c in range(BoardModel.COLS):
			var occ = own_slot.board.get_cell(Vector2(r, c))
			if occ != null and occ.has_card:
				row_counts[r] += 1
				col_counts[c] += 1

	# 对手盘各列有无单位（净空列 → 直通英雄）
	var opp_col_has_unit: Array = [false, false, false]
	for opp in view.opponent_slots():
		if opp.board == null:
			continue
		for c in range(BoardModel.COLS):
			if opp_col_has_unit[c]:
				continue
			for r in range(BoardModel.ROWS):
				var oc = opp.board.get_cell(Vector2(r, c))
				if oc != null and oc.has_card and view.is_target_unit(oc):
					opp_col_has_unit[c] = true
					break

	var best_cell = null
	var best_score: float = -INF
	for r in range(BoardModel.ROWS):
		for c in range(BoardModel.COLS):
			var cell = own_slot.board.get_cell(Vector2(r, c))
			if cell == null or cell.has_card:
				continue
			if cell in placed_cells:
				continue

			# 行流水线：该行越空越优先（分散部署，持续输出）
			var pipeline: float = float(BoardModel.COLS - row_counts[r]) * 3.0

			# 前排加成：越靠近 front_row 越好（front_row 距离越小越好）
			var dist_to_front: int = abs(r - front_row)
			var front_bonus: float = float(BoardModel.ROWS - 1 - dist_to_front) * 1.0

			# 净空列：对手无单位 → 直通
			var lane_bonus: float = 6.0 if not opp_col_has_unit[c] else 0.0

			# 列分散
			var col_spread: float = float(BoardModel.ROWS - col_counts[c]) * 1.5

			# 本回合同列已落 → 惩罚
			var same_col: float = -3.0 if c in placed_cols else 0.0

			var total: float = pipeline + front_bonus + lane_bonus + col_spread + same_col
			if total > best_score:
				best_score = total
				best_cell = cell
	return best_cell

func _spells_sorted(view: AiGameView) -> Array:
	var spells: Array = []
	for card in view.hand_cards():
		if card is CardSpell:
			spells.append(card)
	spells.sort_custom(func(a, b): return a.cost > b.cost)
	return spells

func _best_spell_target(view: AiGameView, card: CardSpell, excluded: Array = []):
	match String(card.target):
		"":
			return null
		"enemy_unit":
			return _most_advanced_target(view, excluded)
		"friendly_unit":
			return _best_own_unit(view)
		"any_unit":
			return _most_advanced_target(view, excluded)
	return null

func _spell_value(_view: AiGameView, _card, tgt) -> float:
	if tgt == null:
		return 2.0
	return _view.threat_of(tgt) + 0.5

# 对手阵营中推进最深（最靠近己方英雄）的单位，excluded 中的格子跳过
func _most_advanced_target(view: AiGameView, excluded: Array = []):
	var best = null
	var best_score: float = -INF
	for opp in view.opponent_slots():
		if opp.board == null:
			continue
		var opp_front: int = BoardModel.front_row_of_slot(opp)
		for cell in opp.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card:
				continue
			if not view.is_target_unit(cell):
				continue
			if cell in excluded:
				continue
			var dist: int = abs(cell.row - opp_front)
			var advance: float = float(BoardModel.ROWS - 1 - dist) * 3.0
			var score: float = view.threat_of(cell) + advance
			if score > best_score:
				best_score = score
				best = cell
	return best

# 己方单位中攻击力最高的（强化/buff 目标）
func _best_own_unit(view: AiGameView):
	var best = null
	var best_score: float = -1.0
	var own := view.own_slot()
	if own == null or own.board == null:
		return null
	for cell in own.board.grid_cells.values():
		if not is_instance_valid(cell) or not cell.has_card:
			continue
		if not view.is_own_unit(cell):
			continue
		var score: float = float(cell.attack)
		if score > best_score:
			best_score = score
			best = cell
	return best
