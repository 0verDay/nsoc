class_name SpawnerSystem
extends Node

# 管理 spawners 配置与 phantom 显示。
# 不直接持有 board / card_db，由调用方注入。

signal spawned(cell, card_data, faction)

var spawners: Array = []

func setup(configs: Array) -> void:
	spawners.clear()
	for sp in configs:
		spawners.append({
			"name": sp["name"],
			"faction": int(sp["faction"]),
			"positions": sp["positions"],
			"interval": int(sp["interval"]),
			"timer": 0
		})

# 推进一个回合的 spawner。返回 true 表示有任意单位生成（调用方可决定要不要等动画）。
# card_resolver: Callable，传入 name -> card_data
# 同一 spawner 配置的多个 positions 共享 timer / interval；
# 触发时对每个位置独立尝试生成（被占位则该位置本回合跳过，但 timer 仍重置）。
func advance(board: BoardModel, card_resolver: Callable) -> bool:
	var any_spawned: bool = false
	for sp in spawners:
		sp.timer += 1
		if sp.timer >= sp.interval:
			var cdata = card_resolver.call(sp.name)
			if cdata:
				for pos in sp.positions:
					var target_cell = board.get_cell(pos)
					if target_cell != null and not target_cell.has_card:
						target_cell.set_card(cdata.name, cdata.attack, cdata.health, sp.faction == 1, cdata.effects)
						any_spawned = true
						spawned.emit(target_cell, cdata, sp.faction)
			sp.timer = 0
	return any_spawned

# 在 spawner 即将触发时显示半透明 phantom 预告。
# 调用前先清理所有 phantom cell（用 clear_phantom 而非 clear_card，后者会触发 cleared 信号造成回调循环）。
func refresh_phantoms(board: BoardModel, card_resolver: Callable) -> void:
	for cell in board.grid_cells.values():
		if cell.is_phantom:
			cell.clear_phantom()
	for sp in spawners:
		if sp.timer >= sp.interval - 1:
			var cdata = card_resolver.call(sp.name)
			if cdata:
				for pos in sp.positions:
					var target_cell = board.get_cell(pos)
					if target_cell != null and not target_cell.has_card:
						target_cell.set_phantom(cdata.name, cdata.attack, cdata.health, sp.faction == 1, cdata.effects)
