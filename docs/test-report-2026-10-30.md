# 实机测试报告 — 2026-10-30

设备：OnePlus 15（infiniti），LineageOS 24，内核 `6.12.81-android16-6-g41a2024a9e2e-4k`

已刷：
- `vendor_dlkm_ltpo.img`（原分区 + `msm_drm.ko` 9,648,520）
- `dtbo_ltpo.img`（AD296 ADFR 表 + 背光表 + `adfr-config=0x2e41`）

---

## 一、结论：LTPO 背光分档已经生效

关掉我们新增的 `adfr_auto_floor`（默认值 0）也能工作，说明起作用的
是 **Infinity-X 那套 qsync + 背光表** 路径。

实测（每次改亮度后触发一次提交）：

| 背光 `bl_level` | 表中区间 | `min_fps` | 判定 |
|---|---|---|---|
| 1518 / 1520 | ≥ 1160 | **1** | ✅ |
| 925 | 919 – 1159 | **30** | ✅ |
| 636 | < 919 | **120** | ✅ |

跨时序切换（锁屏 → 解锁）后仍保持正确档位。下发确认：
`dmesg` 可见 `dsi_cmd: qcom,mdss-dsi-adfr-min-fps-5-command`。

## 二、我们的内核侧 auto floor 是冗余的

`adfr_auto_floor` 打开并把地板设为 30 时，状态会短暂变成 30，但下一次
提交后又被 qsync 路径按背光表改回 1。

原因：`oplus_adfr_set_osync_params()` 在**每次提交**都会调用
`oplus_adfr_sa_floor_update(panel, qsync_mode)`，它晚于 `status_reset` 里的
`oplus_adfr_auto_floor_update()` 执行，所以后者被覆盖。

**建议保持 `adfr_auto_floor=0`**（默认值），代码留着不影响任何行为。

## 三、TE 真实测量：此路不通（推翻此前的判断）

`/proc/interrupts` 里 `TEST_TE_GPIO_0` 确实注册成功（清 BIT14 生效），
但中断频率恒定 **~120 次/秒**，与 `min_fps=1/30/120` 无关。

原因：这块面板是 **OA fixed TE**（`oplus,adfr-oa-use-fixed-te`），TE 信号
由面板保持恒定频率，内部刷新率变化不反映在 TE 上。所以 `test_te` 在这块
面板上永远读不到"真实的 1Hz"。

仍然可用的观测手段：

| 手段 | 能看到什么 |
|---|---|
| `/sys/kernel/oplus_display/min_fps` | 驱动请求的地板 |
| `dmesg \| grep adfr-min-fps` | DSI 命令确实下发 |
| 背光表 → 地板 | 改变亮度即可验证分档逻辑 |
| 功耗对比 | 唯一能证明"面板真的降频了"的手段（见第四节） |

## 四、待验证：功耗

干净 A/B 方案（亮度保持不变，只切 ADFR）：

```sh
# A：ADFR 开启（当前）
echo 0x2e41 > /sys/kernel/oplus_display/adfr_config

# B：ADFR 关闭（对照组）
echo 0x0 > /sys/kernel/oplus_display/adfr_config
```

两次都在**拔线、静止亮屏**状态下各采样 60 秒的 `battery/current_now` 平均值。
预期差值 40~60 mA（与早期 LKM 实验一致）。

## 五、手感

1Hz 档（背光 ≥ 1160）下从静止到首次滑动，理论上有 100~300ms 的首帧延迟。
如果可感知，把亮度调到 30Hz 档区间（919~1159）或下调背光表行不行？——表在
DTS 里，需要重新构建 dtbo。

---

## 附：本次用到的诊断命令

```sh
# 查看当前档位
cat /sys/kernel/oplus_display/min_fps
cat /sys/class/backlight/panel0-backlight/brightness

# 打开 ADFR 调试日志（BIT3）
echo 8 > /sys/kernel/oplus_display/dsi_log_switch

# 观察下发
dmesg | grep -E "adfr-min-fps|min fps is|auto floor"

# 检查 TE 中断
grep TEST_TE /proc/interrupts
```

---

## 六、最终配置（2026-10-30 收尾）

### 设备状态

| 项 | 值 |
|---|---|
| vendor_dlkm | 原分区 + 新 `msm_drm.ko`（9,648,520） |
| dtbo | ADFR 映射表 + 背光表 + `adfr-config=0x2e41` |
| `peak_refresh_rate` | **165** |
| `min_refresh_rate` | 0 |
| 当前 mode | 120（桌面） |
| 当前地板 | 1 Hz（背光 1520） |

### 实际可达行为

| 场景 | 表现 |
|---|---|
| 桌面 / Chrome / 设置 | 120 Hz |
| QQ（请求 165 Exact） | 165 Hz |
| 视频 24 / 30 / 60 fps | 精确匹配（120 整数分频） |
| 静止 | 按背光表降到 1 / 30 Hz |
| 165 mode 下的地板 | 最低 11 Hz（表尾） |

### 发现：ARR 与 mode 的关系

`qcom,dsi-qsync-mode-avr-step-fps` 让每个 mode 向 HWC 公告自己的**整数分频阶梯**：

```
120 mode: [120, 60, 40, 30, 24, 20, 15, 10, 5, 2, 1]
165 mode: [165, 82.5, 55, 41.25, 33, 27.5, 23.57, ...]
```

因此出现非 mode 帧率（如 82.5）。案例：QQ 请求 165 Exact + `peak=120`
→ 留在 165 mode → 阶梯里 ≤120 的最大档 → **82.5 Hz**（比直接 120 更差）。

`peak=165` 时该问题消失（QQ 拿到 165）。`peak=120` 想要 QQ 跑 120 则需要
从 144/165 时序删掉 AVR step（未实施）。

### 已排除的控制手段

| 手段 | 结论 |
|---|---|
| DCS 0x45 Get Scanline | 面板不实现（恒返回 0） |
| `dynamic_float_te` | 打开后 TE 速率不变 |
| `cmd game set --fps` | 仅对 `android:appCategory="game"` 生效 |
| `device_config game_overlay` | 能写入，SF 不采纳 |
| per-app mode / 上限 | 内核无权干预，需改 framework 或 LSPosed hook |

### 建议

- 想更省电：调低背光表的 1Hz 门槛（需重构建 dtbo）
- per-app 控制只到"地板"这一层，不值得做
- 重启一次可清除本次调试遗留的 `dynamic_float_te` 等临时状态
