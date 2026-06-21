extends Node

# AI 注册中心（autoload "AiManager"）。
# 持有所有 AiAgent 映射；供 turn_system 查询「某 slot 是否 AI 控制」「取 agent」。

var _agents: Dictionary = {}   # slot_id -> AiAgent

func register(slot_id: String, agent: AiAgent) -> void:
	_agents[slot_id] = agent

func get_agent(slot_id: String) -> AiAgent:
	return _agents.get(slot_id)

func all_agents() -> Array:
	# 过滤掉已被 free 的节点（场景切换时 Agent 先于 AiManager 销毁）
	var out: Array = []
	for agent in _agents.values():
		if is_instance_valid(agent):
			out.append(agent)
	return out

func is_ai_slot(slot_id: String) -> bool:
	return _agents.has(slot_id) and is_instance_valid(_agents[slot_id])

func clear() -> void:
	_agents.clear()
