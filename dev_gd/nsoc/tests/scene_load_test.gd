extends Node

## 场景装配冒烟：逐个 load + instantiate 所有 .tscn（重构文档.md §7 阶段 2 的测试网）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/SceneLoadTest.tscn
##
## 输出：
##   SCENE_CASE [PASS|FAIL] <场景路径> <说明>
##   SCENE_RESULT PASS|FAIL loaded=N failed=M
##
## 只做 load + instantiate + free，**不加入场景树**，因此不会触发 _ready 里的副作用
## （章节面板的 loading 动画会 change_scene，加入树会污染测试）。
## 覆盖：脚本引用是否可解析、@onready 之外的结构是否完整、ext_resource 是否缺失。

const SCENES_DIR := "res://scenes"
const MIN_EXPECTED_SCENES := 20

var _loaded: int = 0
var _failed: int = 0


func _ready() -> void:
	var paths: Array = []
	_collect(SCENES_DIR, paths)
	paths.sort()
	if paths.size() < MIN_EXPECTED_SCENES:
		_fail("场景收集", "只找到 %d 个场景（少于下限 %d），目录遍历可能失效"
			% [paths.size(), MIN_EXPECTED_SCENES])

	for path in paths:
		_check_scene(String(path))

	_check_chapter_scenes()

	print("SCENE_RESULT %s loaded=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _loaded, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


# ── 内部 ──────────────────────────────────────────────────────────────────

func _collect(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		_fail("目录", "无法打开 " + dir_path)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path + "/" + name
		if dir.current_is_dir():
			_collect(full, out)
		elif name.ends_with(".tscn"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _check_scene(path: String) -> void:
	var packed := load(path) as PackedScene
	if packed == null:
		_fail(path, "load 失败（脚本引用或 ext_resource 缺失？）")
		return
	var inst: Node = packed.instantiate()
	if inst == null:
		_fail(path, "instantiate 失败")
		return
	_loaded += 1
	inst.free()
	print("SCENE_CASE PASS %s" % path)


## 章节入口面板：合并为基类 + 子类后，确认脚本仍能被解析出章节参数。
func _check_chapter_scenes() -> void:
	var cases := {
		"res://scenes/chapters/Changbanpo.tscn": "长坂坡",
		"res://scenes/chapters/Jieting.tscn": "街亭遗恨",
		"res://scenes/chapters/Weizhenhuaxia.tscn": "威震华夏",
	}
	for path in cases.keys():
		var packed := load(path) as PackedScene
		if packed == null:
			_fail(path, "章节场景 load 失败")
			continue
		var inst: Node = packed.instantiate()
		if inst == null:
			_fail(path, "章节场景 instantiate 失败")
			continue
		if not inst.has_method("chapter_name"):
			_fail(path, "脚本未提供 chapter_name()（章节面板基类未生效？）")
		else:
			var got := String(inst.call("chapter_name"))
			if got == "":
				_fail(path, "chapter_name() 返回空")
			else:
				print("SCENE_CASE PASS %s chapter_name=%s" % [path, got])
		inst.free()


func _fail(where: String, detail: String) -> void:
	_failed += 1
	print("SCENE_CASE FAIL %s | %s" % [where, detail])
