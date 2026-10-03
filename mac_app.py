from __future__ import annotations

import json
import queue
import re
import sys
import subprocess
import threading
import webbrowser
from datetime import datetime, timedelta
from pathlib import Path
from tkinter import BooleanVar, END, StringVar, Tk, messagebox, simpledialog
from tkinter import ttk
from urllib.parse import urlsplit


ROOT_DIR = Path(__file__).resolve().parent
if getattr(sys, "frozen", False) or ".app/Contents/Resources" in str(ROOT_DIR):
    CONFIG_PATH = Path.home() / "Library" / "Application Support" / "AppleStoreAssistant" / "mac_app_config.json"
else:
    CONFIG_PATH = ROOT_DIR / "mac_app_config.json"
PART_NUMBER_RE = re.compile(r"[A-Z0-9]+/A$")
APPLE_HOSTS = {"www.apple.com", "www.apple.com.cn"}


class MacAssistantApp:
    """A safe macOS desktop prototype for scheduled checkout handoff.

    It prepares and opens the official Apple page, but deliberately does not
    submit an order or payment and never stores credentials or card data.
    """

    def __init__(self, root: Tk) -> None:
        self.root = root
        self.root.title("Apple Store 抢购助手（MVP）")
        self.root.geometry("820x780")
        self.root.minsize(760, 730)
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.stop_event = threading.Event()
        self.worker: threading.Thread | None = None
        self.running = False

        self.storefront = StringVar(value="https://www.apple.com.cn")
        self.city = StringVar(value="上海")
        self.location = StringVar(value="上海 上海市 黄浦区")
        self.product_name = StringVar(value="待配置商品")
        self.part_number = StringVar(value="XXXXXXCH/A")
        self.product_url = StringVar(value="https://www.apple.com.cn/shop/buy-iphone/example")
        self.store_id = StringVar(value="R000")
        self.store_name = StringVar(value="待配置 Apple Store")
        self.sale_time = StringVar(value="09:00:00")
        self.prepare_seconds = StringVar(value="300")
        self.quiet_seconds = StringVar(value="120")
        self.managed_mode = BooleanVar(value=False)
        self.account_ready = BooleanVar(value=False)
        self.browser_mode = StringVar(value="专用 Chrome 配置（推荐）")
        self.account_status = StringVar(value="状态：未检查")
        self.active_preset = StringVar(value="（未选择）")
        self.presets: dict[str, dict[str, str]] = {}
        self.status = StringVar(value="尚未启动")

        self._build_ui()
        self._load_config_if_present()
        self.root.after(100, self._drain_events)

    def _build_ui(self) -> None:
        outer = ttk.Frame(self.root, padding=16)
        outer.pack(fill="both", expand=True)

        ttk.Label(outer, text="Apple Store 抢购助手", font=("SF Pro Display", 20, "bold")).pack(anchor="w")
        ttk.Label(
            outer,
            text="当前版本：定时准备 + 静默等待 + 到点打开官方结账页。不会保存密码、银行卡，也不会自动支付。",
            foreground="#555555",
        ).pack(anchor="w", pady=(4, 12))

        product = ttk.LabelFrame(outer, text="商品与门店配置", padding=10)
        product.pack(fill="x", pady=(0, 10))
        preset_bar = ttk.Frame(product)
        preset_bar.grid(row=0, column=0, columnspan=4, sticky="we", pady=(0, 6))
        ttk.Label(preset_bar, text="购买配置预设", width=14).pack(side="left")
        self.preset_selector = ttk.Combobox(
            preset_bar,
            textvariable=self.active_preset,
            values=(),
            state="readonly",
            width=25,
        )
        self.preset_selector.pack(side="left", padx=(0, 8))
        ttk.Button(preset_bar, text="应用", command=self.apply_preset, width=8).pack(side="left", padx=(0, 5))
        ttk.Button(preset_bar, text="新建预设", command=self.save_as_preset, width=10).pack(side="left", padx=(0, 5))
        ttk.Button(preset_bar, text="更新预设", command=self.update_preset, width=10).pack(side="left", padx=(0, 5))
        ttk.Button(preset_bar, text="删除", command=self.delete_preset, width=8).pack(side="left")

        self._field_pair(product, 1, "Apple 区域站点", self.storefront, 30, "城市", self.city, 12)
        self._field_pair(product, 2, "查询地点", self.location, 30, "门店编号", self.store_id, 12)
        self._field_pair(product, 3, "商品名称", self.product_name, 30, "型号编号", self.part_number, 18)
        self._field(product, 4, "商品页面 URL", self.product_url, 58)
        self._field(product, 5, "门店名称", self.store_name, 40)
        ttk.Label(
            product,
            text="预设保存商品、型号、门店和浏览器配置；开始托管后会锁定本次执行快照。",
            foreground="#555555",
        ).grid(row=6, column=0, columnspan=4, sticky="w", pady=(6, 0))

        schedule = ttk.LabelFrame(outer, text="抢购时间", padding=10)
        schedule.pack(fill="x", pady=(0, 10))
        self._field_pair(schedule, 0, "触发时间（本机时间）", self.sale_time, 16, "提前准备秒数", self.prepare_seconds, 10)
        self._field(schedule, 1, "静默等待秒数", self.quiet_seconds, 10)
        ttk.Label(
            schedule,
            text="示例：09:00:00、提前 300 秒开始准备，08:58:00 后停止请求，只保留本地计时。",
            foreground="#555555",
        ).grid(row=2, column=0, columnspan=4, sticky="w", pady=(6, 0))

        mode = ttk.LabelFrame(outer, text="托管与安全确认", padding=10)
        mode.pack(fill="x", pady=(0, 10))
        ttk.Checkbutton(
            mode,
            text="托管模式：按时间自动准备、静默等待，到点打开购物袋/结账页",
            variable=self.managed_mode,
            command=self._update_account_checkbox,
        ).grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Label(mode, text="账号浏览器", width=14).grid(row=1, column=0, sticky="w", pady=(6, 0))
        self.browser_selector = ttk.Combobox(
            mode,
            textvariable=self.browser_mode,
            values=("专用 Chrome 配置（推荐）", "系统默认浏览器"),
            state="readonly",
            width=28,
        )
        self.browser_selector.grid(row=1, column=1, sticky="w", pady=(6, 0))
        ttk.Button(mode, text="打开账号准备页", command=self.open_official_pages).grid(
            row=1, column=2, sticky="e", pady=(6, 0)
        )
        self.account_checkbox = ttk.Checkbutton(
            mode,
            text="我已在 Apple 官方页面人工确认账号、地址和付款方式可用",
            variable=self.account_ready,
            state="disabled",
            command=self._on_account_checkbox_changed,
        )
        self.account_checkbox.grid(row=2, column=0, columnspan=2, sticky="w", pady=(6, 0))
        self.account_indicator = ttk.Label(mode, textvariable=self.account_status, foreground="#6b7280")
        self.account_indicator.grid(row=2, column=2, sticky="e", pady=(6, 0))
        ttk.Label(
            mode,
            text="程序不能读取 Apple 账号或银行卡状态；这里只记录你的人工确认，不保存敏感信息。",
            foreground="#8a4b08",
        ).grid(row=3, column=0, columnspan=3, sticky="w", pady=(6, 0))

        buttons = ttk.Frame(outer)
        buttons.pack(fill="x", pady=(0, 8))
        ttk.Button(buttons, text="检查配置", command=self.check_config).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="打开账号准备页", command=self.open_official_pages).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="检查会话", command=self.check_session).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="保存配置", command=self.save_config).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="演示一次（不联网）", command=self.demo).pack(side="left", padx=(0, 8))
        self.start_button = ttk.Button(buttons, text="开始托管", command=self.start_schedule)
        self.start_button.pack(side="right")
        self.stop_button = ttk.Button(buttons, text="停止", command=self.stop_schedule, state="disabled")
        self.stop_button.pack(side="right", padx=(0, 8))

        status_frame = ttk.LabelFrame(outer, text="运行状态", padding=10)
        status_frame.pack(fill="x")
        status_frame.configure(height=145)
        status_frame.pack_propagate(False)
        ttk.Label(status_frame, textvariable=self.status, font=("SF Pro Text", 12, "bold")).pack(anchor="w")
        self.log = ttk.Treeview(status_frame, columns=("time", "message"), show="headings", height=5)
        self.log.heading("time", text="时间")
        self.log.heading("message", text="事件")
        self.log.column("time", width=100, anchor="center")
        self.log.column("message", width=570, anchor="w")
        self.log.pack(fill="both", expand=True, pady=(8, 0))

        ttk.Label(
            outer,
            text="边界：最终订单提交和支付必须由用户在 Apple 官方页面完成；订单号才代表成功。",
            foreground="#9b1c1c",
        ).pack(anchor="w", pady=(8, 0))

    def _field(self, parent: ttk.Widget, row: int, label: str, variable: StringVar, width: int) -> None:
        ttk.Label(parent, text=label, width=18).grid(row=row, column=0, sticky="w", pady=3)
        ttk.Entry(parent, textvariable=variable, width=width).grid(row=row, column=1, columnspan=3, sticky="we", pady=3)
        parent.columnconfigure(1, weight=1)

    def _field_pair(
        self,
        parent: ttk.Widget,
        row: int,
        label_left: str,
        variable_left: StringVar,
        width_left: int,
        label_right: str,
        variable_right: StringVar,
        width_right: int,
    ) -> None:
        ttk.Label(parent, text=label_left, width=14).grid(row=row, column=0, sticky="w", pady=3)
        ttk.Entry(parent, textvariable=variable_left, width=width_left).grid(row=row, column=1, sticky="we", pady=3, padx=(0, 12))
        ttk.Label(parent, text=label_right, width=11).grid(row=row, column=2, sticky="w", pady=3)
        ttk.Entry(parent, textvariable=variable_right, width=width_right).grid(row=row, column=3, sticky="we", pady=3)
        parent.columnconfigure(1, weight=2)
        parent.columnconfigure(3, weight=1)

    def _update_account_checkbox(self) -> None:
        if self.managed_mode.get():
            self.account_checkbox.configure(state="normal")
            self._set_account_status("状态：等待人工确认", "#b45309")
        else:
            self.account_ready.set(False)
            self.account_checkbox.configure(state="disabled")
            self._set_account_status("状态：未检查", "#6b7280")

    def _set_account_status(self, text: str, color: str) -> None:
        self.account_status.set(text)
        if hasattr(self, "account_indicator"):
            self.account_indicator.configure(foreground=color)

    def _on_account_checkbox_changed(self) -> None:
        if self.account_ready.get():
            self._set_account_status("状态：用户已确认（非程序验证）", "#2563eb")
        else:
            self._set_account_status("状态：等待人工确认", "#b45309")

    def _log(self, message: str) -> None:
        now = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        self.log.insert("", END, values=(now, message))
        self.log.yview_moveto(1.0)

    def _queue_log(self, message: str) -> None:
        self.events.put(("log", message))

    def _drain_events(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self._log(str(payload))
                elif kind == "status":
                    self.status.set(str(payload))
                elif kind == "open":
                    if isinstance(payload, dict):
                        self._open_url(str(payload["url"]), browser_mode=str(payload.get("browser_mode", "")))
                    else:
                        self._open_url(str(payload))
                elif kind == "finished":
                    self.running = False
                    self.start_button.configure(state="normal")
                    self.stop_button.configure(state="disabled")
        except queue.Empty:
            pass
        self.root.after(100, self._drain_events)

    def _config_payload(self) -> dict:
        return {
            "locale": "zh_CN" if "cn" in self.storefront.get().lower() else "en_US",
            "storefront_url": self.storefront.get().strip().rstrip("/"),
            "location": self.location.get().strip(),
            "city": self.city.get().strip(),
            "stores": {self.store_id.get().strip(): self.store_name.get().strip()},
            "products": [{
                "name": self.product_name.get().strip(),
                "part_number": self.part_number.get().strip().upper(),
                "url": self.product_url.get().strip(),
                "stores": [self.store_id.get().strip()],
            }],
            "interval_seconds": 30,
            "start_at": None,
            "open_bag_on_hit": True,
            "stop_on_hit": True,
            "desktop_notifications": True,
            "bark_urls": [],
            "runtime_dir": "runtime",
            "browser_mode": self.browser_mode.get(),
            "browser_profile_dir": str(self._profile_dir()),
            "presets": self.presets,
            "active_preset": self.active_preset.get() if self.active_preset.get() in self.presets else None,
        }

    def _current_preset_payload(self) -> dict[str, str]:
        return {
            "storefront_url": self.storefront.get().strip().rstrip("/"),
            "city": self.city.get().strip(),
            "location": self.location.get().strip(),
            "product_name": self.product_name.get().strip(),
            "part_number": self.part_number.get().strip().upper(),
            "product_url": self.product_url.get().strip(),
            "store_id": self.store_id.get().strip(),
            "store_name": self.store_name.get().strip(),
            "browser_mode": self.browser_mode.get().strip(),
        }

    @staticmethod
    def _normalise_preset(value: object) -> dict[str, str] | None:
        if not isinstance(value, dict):
            return None
        keys = (
            "storefront_url",
            "city",
            "location",
            "product_name",
            "part_number",
            "product_url",
            "store_id",
            "store_name",
            "browser_mode",
        )
        result: dict[str, str] = {}
        for key in keys:
            item = value.get(key)
            if not isinstance(item, str) or not item.strip():
                return None
            result[key] = item.strip()
        result["part_number"] = result["part_number"].upper()
        if result["browser_mode"] not in {"专用 Chrome 配置（推荐）", "系统默认浏览器"}:
            result["browser_mode"] = "专用 Chrome 配置（推荐）"
        return result

    def _refresh_preset_selector(self) -> None:
        if not hasattr(self, "preset_selector"):
            return
        names = tuple(self.presets)
        self.preset_selector.configure(values=names)
        if self.active_preset.get() not in self.presets:
            self.active_preset.set("（未选择）")

    def apply_preset(self, *, silent: bool = False) -> None:
        name = self.active_preset.get().strip()
        payload = self.presets.get(name)
        if payload is None:
            if not silent:
                messagebox.showinfo("应用购买配置", "请先选择一个购买配置预设。")
            return
        self.storefront.set(payload["storefront_url"])
        self.city.set(payload["city"])
        self.location.set(payload["location"])
        self.product_name.set(payload["product_name"])
        self.part_number.set(payload["part_number"])
        self.product_url.set(payload["product_url"])
        self.store_id.set(payload["store_id"])
        self.store_name.set(payload["store_name"])
        self.browser_mode.set(payload["browser_mode"])
        self.account_ready.set(False)
        self._set_account_status("状态：已应用预设，需重新人工确认", "#b45309")
        self.status.set(f"已应用购买配置：{name}")
        self._log(f"已应用购买配置预设：{name}")

    def save_as_preset(self) -> None:
        ok, message = self._validate()
        if not ok:
            messagebox.showerror("无法保存预设", message)
            return
        name = simpledialog.askstring(
            "新建购买配置预设",
            "请输入预设名称，例如：iPhone Pro 黑色 256G｜上海静安：",
            parent=self.root,
        )
        if name is None:
            return
        name = name.strip()
        if not name or len(name) > 50 or "\n" in name or "\r" in name:
            messagebox.showerror("无法保存预设", "预设名称不能为空，且不能超过 50 个字符。")
            return
        if name in self.presets and not messagebox.askyesno("覆盖预设", f"预设“{name}”已存在，是否覆盖？"):
            return
        self.presets[name] = self._current_preset_payload()
        self.active_preset.set(name)
        self._refresh_preset_selector()
        self.save_config()
        self.status.set(f"已保存购买配置：{name}")
        self._log(f"已保存购买配置预设：{name}")

    def update_preset(self) -> None:
        name = self.active_preset.get().strip()
        if name not in self.presets:
            messagebox.showinfo("更新购买配置", "请先选择一个已有预设；如果要新建，请点击“新建预设”。")
            return
        ok, message = self._validate()
        if not ok:
            messagebox.showerror("无法更新预设", message)
            return
        if not messagebox.askyesno("更新预设", f"是否用当前字段覆盖预设“{name}”？"):
            return
        self.presets[name] = self._current_preset_payload()
        self.save_config()
        self.status.set(f"已更新购买配置：{name}")
        self._log(f"已更新购买配置预设：{name}")

    def delete_preset(self) -> None:
        name = self.active_preset.get().strip()
        if name not in self.presets:
            messagebox.showinfo("删除购买配置", "请先选择一个已有预设。")
            return
        if not messagebox.askyesno("删除预设", f"确定删除购买配置预设“{name}”？"):
            return
        del self.presets[name]
        self.active_preset.set("（未选择）")
        self._refresh_preset_selector()
        self.save_config()
        self.status.set("已删除购买配置预设")
        self._log(f"已删除购买配置预设：{name}")

    def _validate(self) -> tuple[bool, str]:
        values = {
            "Apple 区域站点": self.storefront.get().strip(),
            "城市": self.city.get().strip(),
            "查询地点": self.location.get().strip(),
            "商品名称": self.product_name.get().strip(),
            "商品型号编号": self.part_number.get().strip().upper(),
            "商品页面 URL": self.product_url.get().strip(),
            "门店编号": self.store_id.get().strip(),
            "门店名称": self.store_name.get().strip(),
        }
        missing = [name for name, value in values.items() if not value]
        if missing:
            return False, "以下字段不能为空：" + "、".join(missing)
        site = urlsplit(values["Apple 区域站点"])
        product = urlsplit(values["商品页面 URL"])
        if site.scheme != "https" or site.hostname not in APPLE_HOSTS:
            return False, "Apple 区域站点必须是 Apple 官方 HTTPS 地址"
        if product.scheme != "https" or product.hostname != site.hostname:
            return False, "商品页面必须使用同一个 Apple 官方区域站点"
        if not PART_NUMBER_RE.fullmatch(values["商品型号编号"]):
            return False, "商品型号编号格式应类似 ABC123CH/A"
        try:
            datetime.strptime(self.sale_time.get().strip(), "%H:%M:%S")
        except ValueError:
            return False, "触发时间必须是 HH:MM:SS，例如 09:00:00"
        try:
            prepare = int(self.prepare_seconds.get())
            quiet = int(self.quiet_seconds.get())
        except ValueError:
            return False, "提前准备秒数和静默等待秒数必须是整数"
        if prepare < quiet or quiet < 0 or prepare > 86400:
            return False, "必须满足：提前准备秒数 ≥ 静默等待秒数 ≥ 0"
        return True, "配置完整"

    def check_config(self) -> None:
        ok, message = self._validate()
        if not ok:
            self.status.set("配置检查失败")
            self._log(message)
            messagebox.showerror("检查结果", message)
            return
        self.status.set("配置检查通过")
        self._log("配置检查通过：商品、门店、时间和官方链接格式有效")
        if self.managed_mode.get():
            self._log("托管模式：请人工确认账号、地址和付款方式，然后勾选确认框")
        if self.browser_mode.get().startswith("专用"):
            if self._chrome_binary():
                self._log("专用 Chrome 可用；账号会话由该浏览器配置管理")
            else:
                self._log("未找到 Google Chrome 或 Microsoft Edge，无法使用专用浏览器配置")
        else:
            self._log("当前使用系统默认浏览器；登录状态需要人工确认")
        messagebox.showinfo("检查结果", message)

    def open_official_pages(self) -> None:
        ok, message = self._validate()
        if not ok:
            messagebox.showerror("无法打开", message)
            return
        for url in (
            "https://account.apple.com/",
            self.product_url.get().strip(),
            self.storefront.get().strip() + "/shop/bag",
        ):
            self._open_url(url)
        if self.browser_mode.get().startswith("专用"):
            self._log("已打开专用 Chrome 配置：请在该窗口登录 Apple 账号并确认付款准备")
        else:
            self._log("已打开默认浏览器：请确认 Apple 账号登录和付款准备")
        self._set_account_status("状态：页面已打开，等待人工确认", "#b45309")

    def check_session(self) -> None:
        """Report only technical session facts; never claim Apple login success."""
        if self.browser_mode.get().startswith("专用"):
            chrome = self._chrome_binary()
            profile = self._profile_dir()
            if not chrome:
                self._set_account_status("状态：未找到 Chrome/Edge", "#b91c1c")
                messagebox.showwarning("会话检查", "没有找到 Google Chrome 或 Microsoft Edge。")
                return
            if not profile.exists():
                self._set_account_status("状态：专用配置尚未创建", "#b45309")
                messagebox.showinfo("会话检查", "Chrome 可用，但专用配置尚未创建。请先点击“打开账号准备页”。")
                return
            self._set_account_status("状态：配置存在，登录仍需人工确认", "#b45309")
            messagebox.showinfo(
                "会话检查",
                "程序已确认：Chrome 可用、专用配置目录存在。\n\n"
                "程序不会读取 Cookie、密码或银行卡，因此无法替你判断 Apple 是否已登录。"
                "请在官方页面确认后勾选“人工确认”。",
            )
            return
        self._set_account_status("状态：默认浏览器已选择，登录需人工确认", "#b45309")
        messagebox.showinfo(
            "会话检查",
            "当前使用系统默认浏览器。程序不会读取浏览器 Cookie 或账号信息，"
            "请在官方页面确认登录后勾选“人工确认”。",
        )

    def _profile_dir(self) -> Path:
        return Path.home() / "Library" / "Application Support" / "AppleStoreAssistant" / "ChromeProfile"

    def _chrome_binary(self) -> str | None:
        candidates = (
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        )
        return next((path for path in candidates if Path(path).is_file()), None)

    def _open_url(self, url: str, *, browser_mode: str | None = None) -> None:
        selected_browser_mode = browser_mode or self.browser_mode.get()
        if not selected_browser_mode.startswith("专用"):
            webbrowser.open(url, new=2)
            return
        chrome = self._chrome_binary()
        if not chrome:
            self._log("未找到 Chrome/Edge，改用系统默认浏览器打开：" + url)
            webbrowser.open(url, new=2)
            return
        profile = self._profile_dir()
        profile.mkdir(parents=True, exist_ok=True)
        subprocess.Popen(
            [chrome, f"--user-data-dir={profile}", "--new-window", url],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self._log("已使用专用浏览器配置打开官方页面")

    def save_config(self) -> None:
        ok, message = self._validate()
        if not ok:
            messagebox.showerror("无法保存", message)
            return
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(self._config_payload(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        self.status.set("配置已保存")
        self._log(f"已保存配置：{CONFIG_PATH.name}（不包含账号、密码、银行卡）")

    def _load_config_if_present(self) -> None:
        if not CONFIG_PATH.exists():
            return
        try:
            raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            product = raw["products"][0]
            store_id = product["stores"][0]
            self.storefront.set(raw["storefront_url"])
            self.city.set(raw["city"])
            self.location.set(raw["location"])
            self.product_name.set(product["name"])
            self.part_number.set(product["part_number"])
            self.product_url.set(product["url"])
            self.store_id.set(store_id)
            self.store_name.set(raw["stores"][store_id])
            self.browser_mode.set(raw.get("browser_mode", self.browser_mode.get()))
            raw_presets = raw.get("presets", {})
            if isinstance(raw_presets, dict):
                for name, value in raw_presets.items():
                    if isinstance(name, str) and name.strip():
                        preset = self._normalise_preset(value)
                        if preset is not None:
                            self.presets[name.strip()] = preset
            self._refresh_preset_selector()
            active = raw.get("active_preset")
            if isinstance(active, str) and active in self.presets:
                self.active_preset.set(active)
                self.apply_preset(silent=True)
            self._log("已加载上次保存的商品配置")
        except (OSError, KeyError, IndexError, TypeError, json.JSONDecodeError):
            self._log("上次配置读取失败，已使用默认字段")

    def _target_datetime(self) -> tuple[datetime, datetime, datetime]:
        now = datetime.now()
        parsed = datetime.strptime(self.sale_time.get().strip(), "%H:%M:%S").time()
        trigger = datetime.combine(now.date(), parsed)
        if trigger <= now:
            trigger += timedelta(days=1)
        prepare = trigger - timedelta(seconds=int(self.prepare_seconds.get()))
        quiet = trigger - timedelta(seconds=int(self.quiet_seconds.get()))
        return prepare, quiet, trigger

    def _wait_until(self, target: datetime) -> bool:
        while not self.stop_event.is_set():
            remaining = (target - datetime.now()).total_seconds()
            if remaining <= 0:
                return True
            self.stop_event.wait(min(remaining, 0.2))
        return False

    def start_schedule(self) -> None:
        if self.running:
            return
        ok, message = self._validate()
        if not ok:
            messagebox.showerror("无法开始", message)
            return
        if self.managed_mode.get() and not self.account_ready.get():
            messagebox.showwarning("需要人工确认", "托管模式开始前，请先打开官方页面确认账号、地址和付款方式，然后勾选确认框。")
            return
        preset_name = self.active_preset.get().strip()
        if preset_name not in self.presets:
            messagebox.showwarning("需要购买配置预设", "请先保存并选择一个购买配置预设，再开始托管。")
            return
        if self._current_preset_payload() != self.presets[preset_name]:
            messagebox.showwarning(
                "购买配置尚未同步",
                f"当前字段与预设“{preset_name}”不一致。\n\n"
                "请点击“应用”恢复已保存预设，或点击“更新预设”保存修改后再开始托管。",
            )
            return
        self.save_config()
        prepare, quiet, trigger = self._target_datetime()
        target_snapshot = self._current_preset_payload()
        self.running = True
        self.stop_event.clear()
        self.start_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        self.status.set("已排程，等待准备时间")
        self._log(
            f"已锁定购买配置：{preset_name}｜{target_snapshot['product_name']} "
            f"{target_snapshot['part_number']}｜{target_snapshot['store_name']}"
        )
        self._log(f"已排程：准备 {prepare:%Y-%m-%d %H:%M:%S}，静默 {quiet:%H:%M:%S}，触发 {trigger:%H:%M:%S}")
        product_url = self.product_url.get().strip()
        bag_url = self.storefront.get().strip() + "/shop/bag"
        self.worker = threading.Thread(
            target=self._schedule_worker,
            args=(prepare, quiet, trigger, product_url, bag_url, preset_name, target_snapshot),
            daemon=True,
        )
        self.worker.start()

    def _schedule_worker(
        self,
        prepare: datetime,
        quiet: datetime,
        trigger: datetime,
        product_url: str,
        bag_url: str,
        preset_name: str,
        target_snapshot: dict[str, str],
    ) -> None:
        if not self._wait_until(prepare):
            self.events.put(("finished", None))
            return
        self.events.put(("status", "准备阶段：打开官方商品页"))
        self.events.put(
            (
                "log",
                f"准备阶段开始：使用已锁定预设“{preset_name}”打开商品页 "
                f"（{target_snapshot['part_number']}｜{target_snapshot['store_name']}）",
            )
        )
        self.events.put(("open", {"url": product_url, "browser_mode": target_snapshot["browser_mode"]}))
        if not self._wait_until(quiet):
            self.events.put(("finished", None))
            return
        self.events.put(("status", "静默等待：不再发起库存请求"))
        self.events.put(("log", "进入静默等待：程序不再请求 Apple 接口，只保留本地计时"))
        if not self._wait_until(trigger):
            self.events.put(("finished", None))
            return
        self.events.put(("status", "到点：已打开官方购物袋，等待用户确认和支付"))
        self.events.put(("log", "触发时间到：打开购物袋；最终下单和支付由用户完成"))
        self.events.put(("open", {"url": bag_url, "browser_mode": target_snapshot["browser_mode"]}))
        self.events.put(("finished", None))

    def stop_schedule(self) -> None:
        if not self.running:
            return
        self.stop_event.set()
        self.running = False
        self.status.set("已停止")
        self._log("已停止排程")
        self.start_button.configure(state="normal")
        self.stop_button.configure(state="disabled")

    def close(self) -> None:
        self.stop_event.set()
        self.root.destroy()

    def demo(self) -> None:
        if self.running:
            messagebox.showinfo("演示进行中", "请先停止当前排程")
            return
        self.running = True
        self.start_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        self.stop_event.clear()
        self.status.set("离线演示：准备阶段")
        self._log("离线演示开始：不会访问 Apple，也不会打开浏览器")
        self.worker = threading.Thread(target=self._demo_worker, daemon=True)
        self.worker.start()

    def _demo_worker(self) -> None:
        stages = [
            ("准备阶段：模拟加载商品配置和官方页面", 1.0),
            ("静默等待：模拟停止请求", 1.5),
            ("触发阶段：模拟打开结账页，等待用户支付", 1.0),
        ]
        for message, delay in stages:
            if self.stop_event.wait(delay):
                self.events.put(("finished", None))
                return
            self.events.put(("log", message))
            self.events.put(("status", message))
        self.events.put(("log", "离线演示完成：订单提交和支付未执行"))
        self.events.put(("status", "演示完成"))
        self.events.put(("finished", None))


def main() -> None:
    root = Tk()
    app = MacAssistantApp(root)
    root.protocol("WM_DELETE_WINDOW", app.close)
    root.mainloop()


if __name__ == "__main__":
    main()
