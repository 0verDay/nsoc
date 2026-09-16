extends Node

## 内容哈希一致性测试（重构文档.md §5.2 的 CONTENT_HASH）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/ContentHashTest.tscn
##
## 覆盖：
##   ✅ `data/content_manifest.json` 与 `content_hash_check.json` 可解析
##   ✅ GDScript 的 sha256 与构建脚本（PowerShell）**逐位一致**：拿清单里第一个文件
##      用两边各自的实现算一遍再比对（这是最容易出错的地方 —— 例如误把字节的 hex
##      文本再哈希一次，或 GDScript 的 `String.sha256_text()` 对字符串补 NUL 的差异）
##   ✅ `NetProtocol.content_hash(manifest.files)` 能算出 64 位十六进制
##   ✅ 与 `version.json` 的 `CONTENT_HASH` 逐位相等（两条实现的端到端一致性）
##   ✅ 算法本身的性质：与文件加入顺序无关（key 排序后可复现）
##
## 依赖构建侧产物（`tools/ci/build_release.ps1` 产出）。**没有产物时本测试打印 SKIP 并通过**
## （不是 FAIL）：全新检出、或还没跑过构建脚本时，版本三件套本来就不存在。想要真覆盖就先跑：
##   powershell -File tools\ci\build_release.ps1 -SkipExport
## 然后：
##   godot --headless --path dev_gd/nsoc res://tests/ContentHashTest.tscn
##
## 输出：
##   CHASH_CASE [PASS|FAIL] <用例名> <说明>
##   CONTENT_HASH <sha256>
##   CHASH_RESULT PASS|FAIL passed=N failed=M  或  CHASH_RESULT SKIP
##
## 注意：GDScript 运行时错误不会终止 _ready()，因此末尾校验用例总数（EXPECTED_CASES）。

const EXPECTED_CASES: int = 5

const MANIFEST_PATH: String = "res://data/content_manifest.json"
const CHECK_PATH: String = "res://data/content_hash_check.json"
const VERSION_PATH: String = "res://version.json"

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	# 产物缺失 => 跳过（不制造红 CI）。version.json 是构建脚本的哨兵产物。
	if not FileAccess.file_exists(VERSION_PATH) or not FileAccess.file_exists(MANIFEST_PATH):
		print("CHASH_CASE SKIP 构建产物不存在（先跑 tools/ci/build_release.ps1 -SkipExport）")
		print("CHASH_RESULT SKIP passed=0 failed=0")
		get_tree().quit(0)
		return

	var manifest := _load_json(MANIFEST_PATH)
	var sidecar := _load_json(CHECK_PATH)
	var ver := _load_json(VERSION_PATH)

	_check("清单: content_manifest.json 可解析且含 files 字典",
		not manifest.is_empty() and typeof(manifest.get("files")) == TYPE_DICTIONARY,
		"keys=%s（先跑 tools/ci/build_release.ps1 生成）" % str(manifest.keys()))
	var files: Dictionary = manifest.get("files", {}) if typeof(manifest.get("files")) == TYPE_DICTIONARY else {}

	# ① 逐位一致性：两条实现（PowerShell / GDScript）对同一个文件必须给同一哈希。
	var pair := _check_pair(sidecar)
	var gd_hash := _hash_file(String(pair.get("path", "")))
	_check("实现一致: 文件内容 sha256 与构建侧一致（PowerShell vs GDScript）",
		String(pair.get("path", "")) != "" and gd_hash == String(pair.get("sha256", "")),
		"path=%s gd=%s ps=%s" % [String(pair.get("path", "")), gd_hash, String(pair.get("sha256", ""))])

	# ② 算法：内容哈希本身
	var computed := NetProtocol.content_hash(files)
	_check("哈希: 定长 64 位十六进制", computed.length() == 64 and computed.is_valid_hex_number(false), computed)

	# ③ 顺序无关（打乱加入顺序必须复现同一值）
	var reordered: Dictionary = {}
	var rev_keys: Array = files.keys()
	rev_keys.sort()
	rev_keys.reverse()
	for rel in rev_keys:
		reordered[rel] = files[rel]
	_check("哈希: 与文件加入顺序无关", NetProtocol.content_hash(reordered) == computed, computed)

	# ④ 端到端：构建脚本写进 version.json 的值必须与 GDScript 算出来的一致
	var from_json := String(ver.get("CONTENT_HASH", ""))
	_check("构建: version.json 的 CONTENT_HASH 与本实现一致",
		from_json != "" and from_json == computed,
		"version.json=%s computed=%s" % [from_json, computed])

	print("CONTENT_HASH %s" % computed)
	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("CHASH_CASE FAIL 用例数量异常：期望 %d，实际 %d" % [EXPECTED_CASES, total])
	print("CHASH_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


## 从校验边车文件里取出"用哪个文件、期望哈希是多少"。
func _check_pair(sidecar: Dictionary) -> Dictionary:
	var files: Array = sidecar.get("files", []) if typeof(sidecar.get("files")) == TYPE_ARRAY else []
	if files.is_empty() or typeof(files[0]) != TYPE_DICTIONARY:
		return {}
	return files[0]


## 原始文件字节的 sha256（**不是**字节 hex 文本的哈希 —— 后者是常见错误）。
## 注意：Godot 4.7 的 PackedByteArray **没有** sha256_buffer()（已用反射核实），
## 所以用 HashingContext + HASH_SHA256 对原始字节做摘要。
func _hash_file(rel_path: String) -> String:
	if rel_path == "":
		return ""
	var abs_path := "res://" + rel_path
	if not FileAccess.file_exists(abs_path):
		return ""
	var bytes := FileAccess.get_file_as_bytes(abs_path)
	return _sha256_bytes(bytes)


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	var err := ctx.start(HashingContext.HASH_SHA256)
	if err != OK:
		push_error("HashingContext.start failed: %d" % err)
		return ""
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if typeof(d) == TYPE_DICTIONARY else {}


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("CHASH_CASE PASS %s" % name)
	else:
		_failed += 1
		print("CHASH_CASE FAIL %s | %s" % [name, detail])

