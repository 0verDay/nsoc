"""
Empire Map Editor
-----------------
Controls:
  1 + Left Click       : Create triangle at cursor
  2 + Left Click       : Create circle at cursor
  3 + Left Click       : Create square at cursor
  Scroll Wheel Up/Down : Zoom in / out (centered on cursor)
  Left Drag (empty)    : Pan view
  Left Drag (on shape) : Move shape
  Click shape          : Select for connection (click two shapes to connect)
  Double-click shape   : Open properties panel
  Click connection line: Delete that connection
  1~4 + Right Click (square): Set category 大/商/农/军
  Right Click (square, no key): Clear category
  Export button        : Save map to JSON

Faction system:
  All maps have a built-in default faction: 中立 (grey, id=0, non-deletable).
  Use "势力管理" button to add/remove/rename/recolor custom factions.
  Each shape can be assigned a faction via the double-click properties panel.
  Faction data is included in the exported JSON under the "factions" key.
"""

import tkinter as tk
from tkinter import filedialog, messagebox, ttk, colorchooser
import json
import math

SHAPE_RADIUS = 24       # base radius in world units
LINE_HIT_DIST = 6       # pixels
ZOOM_FACTOR = 1.12
ZOOM_MIN = 0.1
ZOOM_MAX = 10.0

# Built-in neutral faction (always id=0, cannot be deleted or renamed freely)
NEUTRAL_FACTION_ID = 0
NEUTRAL_FACTION = {"id": NEUTRAL_FACTION_ID, "name": "中立", "color": "#808080"}


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def point_to_segment_dist(p, a, b):
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return dist(p, a)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    closest = (ax + t * dx, ay + t * dy)
    return dist(p, closest)


def hex_to_rgb(hex_color):
    """Convert #rrggbb to (r, g, b) floats 0-255."""
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))


def contrast_text_color(hex_color):
    """Return '#ffffff' or '#000000' depending on background luminance."""
    r, g, b = hex_to_rgb(hex_color)
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    return "#ffffff" if lum < 140 else "#000000"


class Shape:
    _id_counter = 0

    def __init__(self, kind, wx, wy):
        Shape._id_counter += 1
        self.id = Shape._id_counter
        self.kind = kind  # 'triangle' | 'circle' | 'square'
        self.wx = wx      # world x
        self.wy = wy      # world y
        self.category = None  # int 1-4, only for 'square'
        self.name = ""        # 地点名字
        self.gold = 0         # 资金产出（每回合）
        self.food = 0         # 粮食供应
        self.faction = NEUTRAL_FACTION_ID  # faction id

    def screen_pos(self, offset_x, offset_y, scale):
        return (self.wx * scale + offset_x, self.wy * scale + offset_y)


class MapEditor:
    def __init__(self, root):
        self.root = root
        root.title("Empire Map Editor")
        root.geometry("1024x768")

        # Faction list: always starts with the neutral faction.
        # Each entry: {"id": int, "name": str, "color": "#rrggbb"}
        self._next_faction_id = 1  # neutral is 0; custom factions start at 1
        self.factions = [dict(NEUTRAL_FACTION)]  # deep copy

        self.toolbar = tk.Frame(root, bg="#2b2b2b", height=40)
        self.toolbar.pack(side=tk.TOP, fill=tk.X)

        tk.Label(self.toolbar, text="1=Triangle  2=Circle  3=Square",
                 bg="#2b2b2b", fg="#cccccc", font=("Arial", 10)).pack(side=tk.LEFT, padx=10)
        tk.Label(self.toolbar, text="Click 2 shapes to connect | Click line to delete | Scroll=Zoom | 1~4+RClick square=category",
                 bg="#2b2b2b", fg="#cccccc", font=("Arial", 10)).pack(side=tk.LEFT, padx=10)

        export_btn = tk.Button(self.toolbar, text="Export JSON",
                               bg="#4a90d9", fg="white", relief=tk.FLAT,
                               padx=10, command=self.export_json)
        export_btn.pack(side=tk.RIGHT, padx=10, pady=5)

        import_btn = tk.Button(self.toolbar, text="Import JSON",
                               bg="#5a9e6f", fg="white", relief=tk.FLAT,
                               padx=10, command=self.import_json)
        import_btn.pack(side=tk.RIGHT, padx=5, pady=5)

        clear_btn = tk.Button(self.toolbar, text="Clear All",
                              bg="#d9534a", fg="white", relief=tk.FLAT,
                              padx=10, command=self.clear_all)
        clear_btn.pack(side=tk.RIGHT, padx=5, pady=5)

        faction_btn = tk.Button(self.toolbar, text="势力管理",
                                bg="#9b59b6", fg="white", relief=tk.FLAT,
                                padx=10, command=self.open_faction_manager)
        faction_btn.pack(side=tk.RIGHT, padx=5, pady=5)

        self.canvas = tk.Canvas(root, bg="#1e1e2e", cursor="crosshair")
        self.canvas.pack(fill=tk.BOTH, expand=True)

        self.shapes = []
        self.connections = []

        # view state
        self.offset_x = 0.0
        self.offset_y = 0.0
        self.scale = 1.0

        self.pressed_key = None

        # drag state
        self.drag_mode = None   # 'pan' | 'shape'
        self.drag_shape = None
        self.drag_start_mouse = None
        self.drag_start_world = None
        self.mouse_moved = False

        # connection selection
        self.selected_shape = None

        self._bind_events()
        self._draw()

    # ── Faction helpers ───────────────────────────────────────────────────────

    def _faction_by_id(self, fid):
        for f in self.factions:
            if f["id"] == fid:
                return f
        return self.factions[0]  # fallback to neutral

    def _faction_names(self):
        return [f["name"] for f in self.factions]

    def _faction_index(self, fid):
        for i, f in enumerate(self.factions):
            if f["id"] == fid:
                return i
        return 0

    # ── Faction manager window ────────────────────────────────────────────────

    def open_faction_manager(self):
        win = tk.Toplevel(self.root)
        win.title("势力管理")
        win.resizable(False, False)
        win.grab_set()

        # ── listbox ──────────────────────────────────────────────────────────
        frame_list = tk.Frame(win, bg="#2b2b2b")
        frame_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(12, 4), pady=12)

        tk.Label(frame_list, text="势力列表", bg="#2b2b2b", fg="#cccccc",
                 font=("Arial", 11, "bold")).pack(anchor="w")

        lb_frame = tk.Frame(frame_list)
        lb_frame.pack(fill=tk.BOTH, expand=True, pady=(4, 0))

        scrollbar = tk.Scrollbar(lb_frame, orient=tk.VERTICAL)
        listbox = tk.Listbox(lb_frame, width=22, height=12,
                             yscrollcommand=scrollbar.set,
                             selectmode=tk.SINGLE, font=("Arial", 11))
        scrollbar.config(command=listbox.yview)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        # color swatches: we'll redraw listbox items with colored tags
        def _refresh_listbox():
            listbox.delete(0, tk.END)
            for f in self.factions:
                label = f["name"]
                if f["id"] == NEUTRAL_FACTION_ID:
                    label += "  [默认]"
                listbox.insert(tk.END, label)
            # apply foreground colors
            for i, f in enumerate(self.factions):
                try:
                    listbox.itemconfig(i, fg=f["color"])
                except Exception:
                    pass

        _refresh_listbox()

        # ── right panel ───────────────────────────────────────────────────────
        frame_right = tk.Frame(win, bg="#2b2b2b", width=220)
        frame_right.pack(side=tk.LEFT, fill=tk.Y, padx=(4, 12), pady=12)
        frame_right.pack_propagate(False)

        # Add new faction section
        tk.Label(frame_right, text="新增势力", bg="#2b2b2b", fg="#cccccc",
                 font=("Arial", 11, "bold")).pack(anchor="w", pady=(0, 4))

        row_name = tk.Frame(frame_right, bg="#2b2b2b")
        row_name.pack(anchor="w", fill=tk.X, pady=2)
        tk.Label(row_name, text="名称：", bg="#2b2b2b", fg="#cccccc", width=6,
                 anchor="w").pack(side=tk.LEFT)
        name_var = tk.StringVar()
        name_entry = tk.Entry(row_name, textvariable=name_var, width=14)
        name_entry.pack(side=tk.LEFT)

        # color picker for new faction
        new_color_var = tk.StringVar(value="#4a90d9")
        color_preview = tk.Label(frame_right, bg=new_color_var.get(),
                                 width=4, relief=tk.GROOVE)
        color_preview.pack(anchor="w", pady=(4, 0))

        row_color = tk.Frame(frame_right, bg="#2b2b2b")
        row_color.pack(anchor="w", fill=tk.X, pady=2)
        tk.Label(row_color, text="颜色：", bg="#2b2b2b", fg="#cccccc", width=6,
                 anchor="w").pack(side=tk.LEFT)

        color_hex_var = tk.StringVar(value="#4a90d9")
        color_hex_entry = tk.Entry(row_color, textvariable=color_hex_var, width=10)
        color_hex_entry.pack(side=tk.LEFT, padx=(0, 4))

        def _pick_color_new():
            result = colorchooser.askcolor(
                color=new_color_var.get(), title="选择势力颜色", parent=win)
            if result and result[1]:
                hex_val = result[1].upper()
                new_color_var.set(hex_val)
                color_hex_var.set(hex_val)
                color_preview.config(bg=hex_val)

        def _sync_hex_to_preview(*_):
            val = color_hex_var.get().strip()
            if len(val) == 7 and val.startswith("#"):
                try:
                    int(val[1:], 16)
                    new_color_var.set(val.upper())
                    color_preview.config(bg=val)
                except ValueError:
                    pass

        color_hex_var.trace_add("write", _sync_hex_to_preview)

        tk.Button(row_color, text="选色…", command=_pick_color_new,
                  bg="#555577", fg="white", relief=tk.FLAT).pack(side=tk.LEFT)

        def _add_faction():
            n = name_var.get().strip()
            if not n:
                messagebox.showwarning("势力管理", "势力名称不能为空。", parent=win)
                return
            if any(f["name"] == n for f in self.factions):
                messagebox.showwarning("势力管理", f"势力名称「{n}」已存在。", parent=win)
                return
            fid = self._next_faction_id
            self._next_faction_id += 1
            self.factions.append({"id": fid, "name": n, "color": new_color_var.get().upper()})
            name_var.set("")
            _refresh_listbox()
            self._draw()

        tk.Button(frame_right, text="添加势力", command=_add_faction,
                  bg="#4a90d9", fg="white", relief=tk.FLAT,
                  padx=6, pady=4).pack(anchor="w", pady=(6, 12))

        tk.Separator(frame_right, orient=tk.HORIZONTAL).pack(fill=tk.X, pady=6)

        # Edit / delete selected faction
        tk.Label(frame_right, text="编辑选中势力", bg="#2b2b2b", fg="#cccccc",
                 font=("Arial", 11, "bold")).pack(anchor="w", pady=(0, 4))

        edit_name_var = tk.StringVar()
        row_ename = tk.Frame(frame_right, bg="#2b2b2b")
        row_ename.pack(anchor="w", fill=tk.X, pady=2)
        tk.Label(row_ename, text="名称：", bg="#2b2b2b", fg="#cccccc", width=6,
                 anchor="w").pack(side=tk.LEFT)
        edit_name_entry = tk.Entry(row_ename, textvariable=edit_name_var, width=14)
        edit_name_entry.pack(side=tk.LEFT)

        edit_color_var = tk.StringVar(value="#808080")
        edit_color_preview = tk.Label(frame_right, bg=edit_color_var.get(),
                                      width=4, relief=tk.GROOVE)
        edit_color_preview.pack(anchor="w", pady=(4, 0))

        row_ecolor = tk.Frame(frame_right, bg="#2b2b2b")
        row_ecolor.pack(anchor="w", fill=tk.X, pady=2)
        tk.Label(row_ecolor, text="颜色：", bg="#2b2b2b", fg="#cccccc", width=6,
                 anchor="w").pack(side=tk.LEFT)
        edit_color_hex_var = tk.StringVar(value="#808080")
        edit_color_hex_entry = tk.Entry(row_ecolor, textvariable=edit_color_hex_var, width=10)
        edit_color_hex_entry.pack(side=tk.LEFT, padx=(0, 4))

        def _pick_color_edit():
            result = colorchooser.askcolor(
                color=edit_color_var.get(), title="选择势力颜色", parent=win)
            if result and result[1]:
                hex_val = result[1].upper()
                edit_color_var.set(hex_val)
                edit_color_hex_var.set(hex_val)
                edit_color_preview.config(bg=hex_val)

        def _sync_edit_hex(*_):
            val = edit_color_hex_var.get().strip()
            if len(val) == 7 and val.startswith("#"):
                try:
                    int(val[1:], 16)
                    edit_color_var.set(val.upper())
                    edit_color_preview.config(bg=val)
                except ValueError:
                    pass

        edit_color_hex_var.trace_add("write", _sync_edit_hex)

        tk.Button(row_ecolor, text="选色…", command=_pick_color_edit,
                  bg="#555577", fg="white", relief=tk.FLAT).pack(side=tk.LEFT)

        def _load_selected_faction(*_):
            sel = listbox.curselection()
            if not sel:
                return
            f = self.factions[sel[0]]
            edit_name_var.set(f["name"])
            edit_color_var.set(f["color"])
            edit_color_hex_var.set(f["color"])
            edit_color_preview.config(bg=f["color"])

        listbox.bind("<<ListboxSelect>>", _load_selected_faction)

        def _apply_edit():
            sel = listbox.curselection()
            if not sel:
                messagebox.showwarning("势力管理", "请先在列表中选择一个势力。", parent=win)
                return
            f = self.factions[sel[0]]
            new_name = edit_name_var.get().strip()
            new_color = edit_color_var.get().upper()
            if not new_name:
                messagebox.showwarning("势力管理", "名称不能为空。", parent=win)
                return
            # Check duplicate name (ignore self)
            if any(other["name"] == new_name and other["id"] != f["id"]
                   for other in self.factions):
                messagebox.showwarning("势力管理",
                                       f"势力名称「{new_name}」已被其他势力使用。", parent=win)
                return
            f["name"] = new_name
            f["color"] = new_color
            _refresh_listbox()
            self._draw()

        tk.Button(frame_right, text="应用修改", command=_apply_edit,
                  bg="#e67e22", fg="white", relief=tk.FLAT,
                  padx=6, pady=4).pack(anchor="w", pady=(6, 4))

        def _delete_selected():
            sel = listbox.curselection()
            if not sel:
                messagebox.showwarning("势力管理", "请先选择一个势力。", parent=win)
                return
            f = self.factions[sel[0]]
            if f["id"] == NEUTRAL_FACTION_ID:
                messagebox.showwarning("势力管理", "默认中立势力不可删除。", parent=win)
                return
            if not messagebox.askyesno("删除势力",
                    f"确定删除势力「{f['name']}」？\n所有属于该势力的地点将重置为中立。",
                    parent=win):
                return
            # reset all shapes using this faction
            for s in self.shapes:
                if s.faction == f["id"]:
                    s.faction = NEUTRAL_FACTION_ID
            self.factions.remove(f)
            _refresh_listbox()
            self._draw()

        tk.Button(frame_right, text="删除选中势力", command=_delete_selected,
                  bg="#d9534a", fg="white", relief=tk.FLAT,
                  padx=6, pady=4).pack(anchor="w", pady=4)

        tk.Button(frame_right, text="关闭", command=win.destroy,
                  bg="#555577", fg="white", relief=tk.FLAT,
                  padx=6, pady=4).pack(anchor="w", pady=(12, 0))

    # ------------------------------------------------------------------
    def _bind_events(self):
        self.root.bind("<KeyPress>", self._on_key_press)
        self.root.bind("<KeyRelease>", self._on_key_release)
        self.root.bind("<Delete>", self._delete_selected)
        self.root.bind("<BackSpace>", self._delete_selected)
        self.canvas.bind("<ButtonPress-1>", self._on_mouse_press)
        self.canvas.bind("<B1-Motion>", self._on_mouse_drag)
        self.canvas.bind("<ButtonRelease-1>", self._on_mouse_release)
        self.canvas.bind("<Double-Button-1>", self._on_double_click)
        self.canvas.bind("<ButtonPress-3>", self._on_right_click)
        self.canvas.bind("<MouseWheel>", self._on_scroll)          # Windows
        self.canvas.bind("<Button-4>", self._on_scroll)            # Linux scroll up
        self.canvas.bind("<Button-5>", self._on_scroll)            # Linux scroll down

    # ------------------------------------------------------------------
    def _on_key_press(self, event):
        self.pressed_key = event.keysym

    def _on_key_release(self, event):
        if event.keysym == self.pressed_key:
            self.pressed_key = None

    def _delete_selected(self, event=None):
        if self.selected_shape is None:
            return
        s = self.selected_shape
        self.shapes.remove(s)
        self.connections = [(a, b) for a, b in self.connections if a is not s and b is not s]
        self.selected_shape = None
        self._draw()

    # ------------------------------------------------------------------
    def _screen_to_world(self, sx, sy):
        return ((sx - self.offset_x) / self.scale,
                (sy - self.offset_y) / self.scale)

    def _world_to_screen(self, wx, wy):
        return (wx * self.scale + self.offset_x,
                wy * self.scale + self.offset_y)

    # ------------------------------------------------------------------
    def _hit_shape(self, sx, sy):
        for shape in reversed(self.shapes):
            spx, spy = shape.screen_pos(self.offset_x, self.offset_y, self.scale)
            r_screen = SHAPE_RADIUS * self.scale
            if dist((sx, sy), (spx, spy)) <= r_screen:
                return shape
        return None

    def _hit_connection(self, sx, sy):
        for conn in self.connections:
            a, b = conn
            sa = a.screen_pos(self.offset_x, self.offset_y, self.scale)
            sb = b.screen_pos(self.offset_x, self.offset_y, self.scale)
            if point_to_segment_dist((sx, sy), sa, sb) < LINE_HIT_DIST:
                return conn
        return None

    # ------------------------------------------------------------------
    def _on_double_click(self, event):
        hit = self._hit_shape(event.x, event.y)
        if hit:
            self._open_properties(hit)

    def _open_properties(self, shape):
        win = tk.Toplevel(self.root)
        win.title("地点属性")
        win.resizable(False, False)
        win.grab_set()

        # ---------- 地点名字 ----------
        tk.Label(win, text="地点名字：", anchor="w").grid(
            row=0, column=0, sticky="w", padx=12, pady=(16, 4))
        name_var = tk.StringVar(value=shape.name)
        name_entry = tk.Entry(win, textvariable=name_var, width=24)
        name_entry.grid(row=0, column=1, columnspan=3, sticky="ew", padx=(0, 12), pady=(16, 4))

        # ---------- 地点类型 ----------
        tk.Label(win, text="地点类型：", anchor="w").grid(
            row=1, column=0, sticky="w", padx=12, pady=4)

        TYPE_OPTIONS = ["关隘", "乡镇", "大都市", "商业城市", "农业城市", "军事城市"]
        KIND_FROM_TYPE = {
            "关隘": ("triangle", None),
            "乡镇": ("circle",   None),
            "大都市":  ("square", 1),
            "商业城市": ("square", 2),
            "农业城市": ("square", 3),
            "军事城市": ("square", 4),
        }
        TYPE_FROM_KIND = {
            ("triangle", None): "关隘",
            ("circle",   None): "乡镇",
            ("square",   1):    "大都市",
            ("square",   2):    "商业城市",
            ("square",   3):    "农业城市",
            ("square",   4):    "军事城市",
        }
        current_type = TYPE_FROM_KIND.get((shape.kind, shape.category), "关隘")
        type_var = tk.StringVar(value=current_type)
        type_combo = ttk.Combobox(win, textvariable=type_var,
                                  values=TYPE_OPTIONS, state="readonly", width=14)
        type_combo.grid(row=1, column=1, columnspan=3, sticky="w", padx=(0, 12), pady=4)

        # ---------- 所属势力 ----------
        tk.Label(win, text="所属势力：", anchor="w").grid(
            row=2, column=0, sticky="w", padx=12, pady=4)

        faction_names = self._faction_names()
        faction_var = tk.StringVar(value=self._faction_by_id(shape.faction)["name"])

        # Color preview swatch next to combo
        swatch_color = self._faction_by_id(shape.faction)["color"]
        faction_swatch = tk.Label(win, bg=swatch_color, width=3, relief=tk.GROOVE)
        faction_swatch.grid(row=2, column=1, sticky="w", padx=(0, 4), pady=4)

        faction_combo = ttk.Combobox(win, textvariable=faction_var,
                                     values=faction_names, state="readonly", width=12)
        faction_combo.grid(row=2, column=2, columnspan=2, sticky="w", padx=(0, 12), pady=4)

        def _on_faction_change(*_):
            selected_name = faction_var.get()
            for f in self.factions:
                if f["name"] == selected_name:
                    faction_swatch.config(bg=f["color"])
                    break

        faction_combo.bind("<<ComboboxSelected>>", _on_faction_change)

        # ---------- 资源产出 ----------
        tk.Label(win, text="资金产出：", anchor="w").grid(
            row=3, column=0, sticky="w", padx=12, pady=4)
        gold_var = tk.StringVar(value=str(shape.gold))
        gold_entry = tk.Entry(win, textvariable=gold_var, width=10)
        gold_entry.grid(row=3, column=1, sticky="w", pady=4)
        tk.Label(win, text="/回合", anchor="w").grid(
            row=3, column=2, sticky="w", pady=4)

        tk.Label(win, text="粮食供应：", anchor="w").grid(
            row=4, column=0, sticky="w", padx=12, pady=(4, 16))
        food_var = tk.StringVar(value=str(shape.food))
        food_entry = tk.Entry(win, textvariable=food_var, width=10)
        food_entry.grid(row=4, column=1, sticky="w", pady=(4, 16))

        # ---------- 确定 / 取消 ----------
        def _apply():
            new_kind, new_cat = KIND_FROM_TYPE[type_var.get()]
            shape.name = name_var.get().strip()
            shape.kind = new_kind
            shape.category = new_cat
            # resolve faction id from name
            selected_fname = faction_var.get()
            shape.faction = NEUTRAL_FACTION_ID
            for f in self.factions:
                if f["name"] == selected_fname:
                    shape.faction = f["id"]
                    break
            try:
                shape.gold = int(gold_var.get())
            except ValueError:
                shape.gold = 0
            try:
                shape.food = int(food_var.get())
            except ValueError:
                shape.food = 0
            win.destroy()
            self._draw()

        btn_frame = tk.Frame(win)
        btn_frame.grid(row=5, column=0, columnspan=4, pady=(0, 12))
        tk.Button(btn_frame, text="确定", width=8, command=_apply).pack(side=tk.LEFT, padx=8)
        tk.Button(btn_frame, text="取消", width=8, command=win.destroy).pack(side=tk.LEFT, padx=8)

        win.columnconfigure(1, weight=1)
        name_entry.focus_set()

    # ------------------------------------------------------------------
    def _on_right_click(self, event):
        hit = self._hit_shape(event.x, event.y)
        if hit is None or hit.kind != 'square':
            return
        if self.pressed_key in ('1', '2', '3', '4'):
            hit.category = int(self.pressed_key)
        else:
            hit.category = None
        self._draw()

    # ------------------------------------------------------------------
    def _on_scroll(self, event):
        # determine zoom direction
        if event.num == 4:
            delta = 1
        elif event.num == 5:
            delta = -1
        else:
            delta = event.delta  # Windows: positive=up, negative=down

        if delta > 0:
            factor = ZOOM_FACTOR
        else:
            factor = 1.0 / ZOOM_FACTOR

        new_scale = self.scale * factor
        new_scale = max(ZOOM_MIN, min(ZOOM_MAX, new_scale))
        factor = new_scale / self.scale

        # zoom centered on cursor position
        mx, my = event.x, event.y
        self.offset_x = mx - factor * (mx - self.offset_x)
        self.offset_y = my - factor * (my - self.offset_y)
        self.scale = new_scale
        self._draw()

    # ------------------------------------------------------------------
    def _on_mouse_press(self, event):
        sx, sy = event.x, event.y
        self.drag_start_mouse = (sx, sy)
        self.mouse_moved = False

        hit = self._hit_shape(sx, sy)

        if self.pressed_key in ('1', '2', '3') and hit is None:
            kinds = {'1': 'triangle', '2': 'circle', '3': 'square'}
            wx, wy = self._screen_to_world(sx, sy)
            new_shape = Shape(kinds[self.pressed_key], wx, wy)
            self.shapes.append(new_shape)
            self.drag_mode = None
            self._draw()
            return

        if hit:
            self.drag_mode = 'shape'
            self.drag_shape = hit
            self.drag_start_world = (hit.wx, hit.wy)
        else:
            self.drag_mode = 'pan'
            self.drag_shape = None

    def _on_mouse_drag(self, event):
        if self.drag_start_mouse is None:
            return
        dx = event.x - self.drag_start_mouse[0]
        dy = event.y - self.drag_start_mouse[1]
        if abs(dx) > 3 or abs(dy) > 3:
            self.mouse_moved = True

        if self.drag_mode == 'pan':
            self.offset_x += event.x - self.drag_start_mouse[0]
            self.offset_y += event.y - self.drag_start_mouse[1]
            self.drag_start_mouse = (event.x, event.y)
            self._draw()
        elif self.drag_mode == 'shape' and self.drag_shape:
            # convert screen delta to world delta
            wdx = dx / self.scale
            wdy = dy / self.scale
            self.drag_shape.wx = self.drag_start_world[0] + wdx
            self.drag_shape.wy = self.drag_start_world[1] + wdy
            self._draw()

    def _on_mouse_release(self, event):
        if self.drag_mode is None:
            self.drag_start_mouse = None
            return

        if not self.mouse_moved:
            sx, sy = event.x, event.y
            hit_shape = self._hit_shape(sx, sy)

            if hit_shape:
                self._handle_shape_click(hit_shape)
            else:
                hit_conn = self._hit_connection(sx, sy)
                if hit_conn:
                    self.connections.remove(hit_conn)
                    self._draw()
                else:
                    self.selected_shape = None
                    self._draw()

        self.drag_mode = None
        self.drag_shape = None
        self.drag_start_mouse = None
        self.mouse_moved = False

    def _handle_shape_click(self, shape):
        if self.selected_shape is None:
            self.selected_shape = shape
        elif self.selected_shape is shape:
            self.selected_shape = None
        else:
            a, b = self.selected_shape, shape
            pair = (a, b)
            pair_r = (b, a)
            if pair not in self.connections and pair_r not in self.connections:
                self.connections.append(pair)
            self.selected_shape = None
        self._draw()

    # ------------------------------------------------------------------
    def _draw(self):
        self.canvas.delete("all")
        ox, oy, sc = self.offset_x, self.offset_y, self.scale

        cw = self.canvas.winfo_width() or 1024
        ch = self.canvas.winfo_height() or 728

        # grid
        grid_size = 60 * sc
        if grid_size > 4:
            start_x = ox % grid_size
            start_y = oy % grid_size
            x = start_x
            while x < cw:
                self.canvas.create_line(x, 0, x, ch, fill="#2a2a3e", width=1)
                x += grid_size
            y = start_y
            while y < ch:
                self.canvas.create_line(0, y, cw, y, fill="#2a2a3e", width=1)
                y += grid_size

        # reference frame 1920x1080 anchored at world (0,0)
        ref_x0 = ox
        ref_y0 = oy
        ref_x1 = ox + 1920 * sc
        ref_y1 = oy + 1080 * sc
        self.canvas.create_rectangle(ref_x0, ref_y0, ref_x1, ref_y1,
                                     outline="#555577", width=1, dash=(6, 4))
        self.canvas.create_text(ref_x0 + 4, ref_y0 + 4, text="(0,0)",
                                anchor="nw", fill="#555577", font=("Arial", 9))
        self.canvas.create_text(ref_x1 - 4, ref_y1 - 4, text="(1920,1080)",
                                anchor="se", fill="#555577", font=("Arial", 9))

        # connections
        for a, b in self.connections:
            ax, ay = a.screen_pos(ox, oy, sc)
            bx, by = b.screen_pos(ox, oy, sc)
            self.canvas.create_line(ax, ay, bx, by, fill="#7ec8e3", width=2)

        # shapes
        for shape in self.shapes:
            spx, spy = shape.screen_pos(ox, oy, sc)
            is_selected = (shape is self.selected_shape)
            self._draw_shape(shape, spx, spy, is_selected)

    def _draw_shape(self, shape, sx, sy, selected):
        kind = shape.kind
        r = SHAPE_RADIUS * self.scale
        outline = "#ffe066" if selected else "#ffffff"
        width = 3 if selected else 2

        # Use faction color as fill
        faction = self._faction_by_id(shape.faction)
        fill_color = faction["color"]
        text_color = contrast_text_color(fill_color)

        if kind == 'circle':
            self.canvas.create_oval(sx - r, sy - r, sx + r, sy + r,
                                    fill=fill_color, outline=outline, width=width)
        elif kind == 'square':
            self.canvas.create_rectangle(sx - r, sy - r, sx + r, sy + r,
                                         fill=fill_color, outline=outline, width=width)
            category_labels = {1: "大", 2: "商", 3: "农", 4: "军"}
            label = category_labels.get(shape.category)
            if label:
                font_size = max(8, int(r * 0.9))
                self.canvas.create_text(sx, sy, text=label, fill=text_color,
                                        font=("Arial", font_size, "bold"))
        elif kind == 'triangle':
            pts = [
                sx, sy - r,
                sx - r, sy + r,
                sx + r, sy + r,
            ]
            self.canvas.create_polygon(pts, fill=fill_color, outline=outline, width=width)

        if shape.name:
            font_size = max(7, int(r * 0.55))
            self.canvas.create_text(sx, sy + r + font_size + 2, text=shape.name,
                                    fill="#e8e8b0", font=("Arial", font_size))

    # ------------------------------------------------------------------
    def import_json(self):
        path = filedialog.askopenfilename(
            filetypes=[("JSON files", "*.json")],
            title="Import Map"
        )
        if not path:
            return
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            messagebox.showerror("Import", f"读取文件失败：\n{e}")
            return

        self.shapes.clear()
        self.connections.clear()
        self.selected_shape = None

        # ── Restore factions ─────────────────────────────────────────────────
        self.factions = [dict(NEUTRAL_FACTION)]
        self._next_faction_id = 1
        for f in data.get("factions", []):
            fid = int(f.get("id", 0))
            if fid == NEUTRAL_FACTION_ID:
                # Update neutral name/color if stored (preserve id=0)
                self.factions[0]["name"] = str(f.get("name", "中立"))
                self.factions[0]["color"] = str(f.get("color", "#808080"))
                continue
            self.factions.append({
                "id": fid,
                "name": str(f.get("name", f"势力{fid}")),
                "color": str(f.get("color", "#4a90d9")),
            })
            if fid >= self._next_faction_id:
                self._next_faction_id = fid + 1

        # ── Restore shapes ───────────────────────────────────────────────────
        id_to_shape = {}
        max_id = 0
        for entry in data.get("shapes", []):
            s = Shape.__new__(Shape)
            s.id = entry["id"]
            s.kind = entry["kind"]
            s.wx = entry["x"]
            s.wy = entry["y"]
            s.category = entry.get("category", None)
            s.name = entry.get("name", "")
            s.gold = entry.get("gold", 0)
            s.food = entry.get("food", 0)
            s.faction = int(entry.get("faction", NEUTRAL_FACTION_ID))
            self.shapes.append(s)
            id_to_shape[s.id] = s
            if s.id > max_id:
                max_id = s.id

        Shape._id_counter = max_id

        for conn in data.get("connections", []):
            a = id_to_shape.get(conn["from"])
            b = id_to_shape.get(conn["to"])
            if a and b:
                self.connections.append((a, b))

        self._draw()
        messagebox.showinfo("Import", f"地图已导入：\n{path}")

    # ------------------------------------------------------------------
    def export_json(self):
        if not self.shapes:
            messagebox.showwarning("Export", "No shapes to export.")
            return

        unclassified = [s for s in self.shapes if s.kind == 'square' and s.category is None]
        if unclassified:
            ids = ", ".join(str(s.id) for s in unclassified)
            messagebox.showwarning("Export", f"以下方形尚未分类，请先右键分配类别后再导出：\nID: {ids}")
            return

        # connectivity check (BFS)
        adj = {s.id: set() for s in self.shapes}
        for a, b in self.connections:
            adj[a.id].add(b.id)
            adj[b.id].add(a.id)
        start = self.shapes[0].id
        visited = {start}
        queue = [start]
        while queue:
            cur = queue.pop()
            for nb in adj[cur]:
                if nb not in visited:
                    visited.add(nb)
                    queue.append(nb)
        if len(visited) != len(self.shapes):
            isolated = [s for s in self.shapes if s.id not in visited]
            ids = ", ".join(str(s.id) for s in isolated)
            messagebox.showwarning("Export", f"场景中存在未连通的图形，无法导出。\n孤立图形 ID: {ids}")
            return

        min_x = min(s.wx for s in self.shapes)
        min_y = min(s.wy for s in self.shapes)

        data = {
            "factions": [
                {"id": f["id"], "name": f["name"], "color": f["color"]}
                for f in self.factions
            ],
            "shapes": [],
            "connections": [],
        }
        for shape in self.shapes:
            entry = {
                "id": shape.id,
                "kind": shape.kind,
                "x": round(shape.wx - min_x, 2),
                "y": round(shape.wy - min_y, 2),
                "name": shape.name,
                "gold": shape.gold,
                "food": shape.food,
                "faction": shape.faction,
            }
            if shape.kind == 'square':
                entry["category"] = shape.category
            data["shapes"].append(entry)

        for a, b in self.connections:
            data["connections"].append({
                "from": a.id,
                "to": b.id
            })

        path = filedialog.asksaveasfilename(
            defaultextension=".json",
            filetypes=[("JSON files", "*.json")],
            title="Export Map"
        )
        if path:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            messagebox.showinfo("Export", f"Map exported to:\n{path}")

    def clear_all(self):
        if messagebox.askyesno("Clear All", "Clear all shapes and connections?"):
            self.shapes.clear()
            self.connections.clear()
            self.selected_shape = None
            Shape._id_counter = 0
            # Reset factions to default (neutral only)
            self.factions = [dict(NEUTRAL_FACTION)]
            self._next_faction_id = 1
            self._draw()


def main():
    root = tk.Tk()
    app = MapEditor(root)
    root.mainloop()


if __name__ == "__main__":
    main()
