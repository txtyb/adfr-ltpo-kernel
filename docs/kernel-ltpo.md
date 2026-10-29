# 内核侧 LTPO 实现（kernel-side ADFR auto mode）

本文说明本仓库替 OnePlus 15（infiniti / SM8850）在 LineageOS 上补的那一层
LTPO 支持：为什么需要、原厂是怎么做的、我们做了什么、怎么调、怎么验证、怎么回滚。

---

## 1. 问题：LineageOS 上 LTPO 档位从不下发

面板（AD296，`oplus,adfr-min-fps-mapping-table = <120 60 30 20 10 1>`）完整支持
ADFR 低频档，驱动 `oplus_adfr.c` 也支持，但屏幕上永远只有 60/120 两档。

原因链：

1. 内核里真正把"地板帧率"发给面板的是 `oplus_adfr_min_fps_update()`；
2. 它只在 **frame kickoff**（`oplus_adfr_sa_handle`）时，若 `sa_min_fps_updated`
   为真才被调用 —— **静止画面没有提交，就没有下发时机**；
3. `sa_min_fps` 的值来自三个地方：
   - 用户态 sysfs `/sys/kernel/oplus_display/min_fps`（只改状态，需要下一次提交才生效）
   - connector 属性 `qsync_min_fps`（OPPO HAL 专用，见下）
   - `CONNECTOR_PROP_QSYNC_MODE`（标准 QSync）
4. 标准 QSync 在这块面板上**被驱动主动丢弃**：

```c
/* sde_connector.c */
case CONNECTOR_PROP_QSYNC_MODE:
    if (oplus_adfr_is_oa_use_fixed_te_c(c_conn)) {
        SDE_INFO("oplus_adfr_is_oa_use_fixed_te not set qsync_mode %d\n", (int)val);
        break;                      /* 属性被丢弃 */
    }
```

我们的面板 DTS 声明了 `oplus,adfr-oa-use-fixed-te`，所以 composer 发来的
qsync 全部被丢掉，`qsync_mode` 恒为 0，`auto_mode` 永远是 OFF。

实测日志：

```
sa status reset: auto_mode:0, sa_min_fps:120
```

---

## 2. 原厂（OxygenOS / Infinity-X）是怎么做的

对 `OP15InfinityX` 全部仓库的调研结论（源码级）：**五层**。

```
SurfaceFlinger          读 measured_fps，显示物理刷新率（诊断用）
      ↓
composer HAL            识别魔法字 0x5cc18181 并转发
      ↓
display-core (SDM)      写 DRM 属性 qsync_min_fps = 0x5cc18181
      ↓
内核 oplus_adfr         解码 → auto_mode = AUTO_ON + sa_min_fps = 1
      ↓
面板硬件                 auto 模式下自己管空闲过渡

设备服务 oplus_adfr_init（620 行）在上游决定何时发那个魔法字
```

### 2.1 魔法字的含义

```c
#define OPLUS_ADFR_SA_MAGIC              0x00800000
#define OPLUS_ADFR_AUTO_MODE_MAGIC       0x00400000
#define OPLUS_ADFR_AUTO_MODE_VALUE(v)    (((v) & 0x003F0000) >> 16)
#define OPLUS_ADFR_SA_MIN_FPS_MAGIC      0x00000080
#define OPLUS_ADFR_SA_MIN_FPS_VALUE(v)   ((v) & 0x7F)

0x5cc18181 → SA_MAGIC ✓ | AUTO_MODE = 1 (ON) | SA_MIN_FPS = 1 Hz
```

即：**「开启 auto 模式，地板 1Hz」**。

### 2.2 设备服务的策略（`oplus_adfr_init.cpp`）

依赖两个信号（LineageOS 内核本来就有）：

| 节点 | 用途 |
|---|---|
| `/sys/class/drm/card0-sde-crtc-0/measured_fps` | 主机出帧数；`frameCount == 0` 判定静止 |
| `/sys/kernel/oplus_display/power_status` | 面板电源状态（唤醒 / doze） |

发送时机：

| 事件 | 延迟 |
|---|---|
| 唤醒（power 0 → 非 0） | 1.5 秒 |
| 进入 doze（非 0 → 0） | 1.5 秒 |
| 静止（`frameCount == 0` 且 `min_fps > 1`） | 750 毫秒，失败每 5 秒重试 |

**注意：这不是降频阶梯。** 1.5s / 750ms 只是"等状态稳定后再发"的去抖；降频本身由面板
硬件 auto 模式完成。

### 2.3 为什么原厂需要那两层 HAL 补丁

`qsync_min_fps` 是 OPPO 私有属性，原厂 composer 不认识魔法字，会把它当作非法
`QsyncMode` 映射成 NONE 丢掉。所以 Infinity-X 改了：

- `hardware/qcom/display`：`setQsyncMode` 遇到魔法字直接透传给 SDM
- `vendor/qcom/opensource/display-core`：新增 `CONNECTOR_SET_OPLUS_ADFR`，
  把魔法字写进 `qsync_min_fps`，且**不碰标准 QSync 状态**（避免影响正常切帧率）

---

## 3. 我们的实现：把决策搬进内核

LineageOS 没有那两层 HAL 补丁，也没有那个设备服务。与其重编两个 HAL，不如直接
产生**同一个内核终态**：`auto_mode = ON` + 一个低地板。

### 3.1 补丁内容

`0002-adfr-driver.diff`（`oplus_adfr.c/.h`）：

| 改动 | 说明 |
|---|---|
| `oplus_adfr_get_sa_floor()` | 按背光查 `oplus,adfr-sa-min-fps-bl-table`，无表回落到 `qsync_min_fps` |
| `oplus_adfr_sa_floor_update()` | Infinity-X 原有逻辑：qsync 有效时启用 auto 模式（本机不生效，保留） |
| **`oplus_adfr_auto_floor_update()`** | 本实现核心：按背光表（或覆盖值）算出地板，`auto_mode = ON`，并置 `sa_min_fps_updated` |
| `status_reset()` 调用 | **每次切时序都重新武装**（关键：auto 模式会被时序切换清掉） |
| `oplus_adfr_get_params()` 导出 | 供后续扩展 |
| struct 成员 | `qsync_mode`、`sa_min_fps_bl_table*` |

`0003-adfr-panel.diff`（AD296 面板 dtsi）：

| 改动 | 说明 |
|---|---|
| 每个时序加 `qcom,dsi-qsync-mode-avr-step-fps` | 告诉 DSI 该时序的步进能力 |
| 144/165 时序补 ADFR 映射表与命令序列 | LineageOS 只带了三档 |
| 新增 `oplus,adfr-sa-min-fps-bl-table` | 背光 → 地板 |
| `qsync-min-refresh-rate` 30 → 1 | 允许对齐到 1Hz |
| **`oplus,adfr-config` 0x6e41 → 0x2e41** | 清 BIT14（software marker）→ probe 时注册 TE 中断，真实帧率可测 |

### 3.2 背光表

```dts
oplus,adfr-sa-min-fps-bl-table = <1160 1>, <919 30>, <0 0>;
```

| 背光 | 地板 |
|---|---|
| ≥ 1160 | 1 Hz |
| 919 ~ 1159 | 30 Hz |
| < 919 | 不降频（当前 mode 帧率） |

方向可能反直觉：**暗光不降频**，因为低亮度 PWM 调光叠加低刷新容易可见闪烁。

### 3.3 运行时参数（默认关闭，安全）

```sh
# 开关（默认 0 = 完全不改变行为）
echo 1 > /sys/module/msm_drm/parameters/adfr_auto_floor

# 固定地板（0 = 用背光表）
echo 30 > /sys/module/msm_drm/parameters/adfr_auto_min_fps
```

写 `adfr_auto_floor` 会**立即**尝试应用一次（设置标志，下一次提交时下发命令）。

### 3.4 状态机

```
任意 commit / 切时序
      ↓
status_reset()
      ↓
与 Infinity-X 的差异：这里不依赖 qsync
      ↓
auto_mode = ON, sa_min_fps = 背光表值 (或 adfr_auto_min_fps)
      ↓
下一次 commit → sa_handle() → oplus_adfr_min_fps_update()
      ↓
面板进入 auto 模式：有帧全速、无帧降到地板（硬件自理）
```

之后**不需要任何用户态轮询、重发或守护进程**。

---

## 4. 与原厂实现的差异

| 维度 | OxygenOS / Infinity-X | 本实现 |
|---|---|---|
| 决策位置 | 用户态服务（`oplus_adfr_init`） | 内核（`status_reset`） |
| 触发延迟 | 唤醒后 1.5s、静止后 750ms | 切时序当帧 |
| 状态丢失修复 | 轮询重发，最坏 5 秒 | 同帧重新武装 |
| 地板来源 | 固定魔法字 = 1Hz + HAL 侧场景表 | 背光表 / 固定值 |
| 依赖 | composer + display-core 补丁、vendor HAL 服务 | 无（纯内核 + DTS） |
| 场景自适应 | 有（XML 场景表 → HAL） | 无 |

结论：**核心状态完全一致**；本实现少了场景表，但触发和修复都更及时。

---

## 5. 调参

| 参数 | 位置 | 说明 |
|---|---|---|
| `adfr_auto_floor` | `/sys/module/msm_drm/parameters/` | 0/1 总开关 |
| `adfr_auto_min_fps` | 同上 | 固定地板，覆盖背光表 |
| `oplus,adfr-sa-min-fps-bl-table` | 面板 dtsi | 背光分档地板 |
| `oplus,adfr-min-fps-mapping-table` | 各时序 dtsi | 该时序允许的档位 |

常见调整：

- **想更省电**：把 `<919 30>` 改成 `<600 10>`，暗光也降频
- **想更顺滑**：把地板固定成 10 或 30（`adfr_auto_min_fps`），避免 1Hz 的首帧延迟
- **只想要 30Hz**：`echo 30 > .../adfr_auto_min_fps` 后 `echo 1 > .../adfr_auto_floor`

---

## 6. 验证

### 6.1 功能是否生效

```sh
# 1. 武装
echo 1 > /sys/module/msm_drm/parameters/adfr_auto_floor

# 2. 看内核日志（切一次时序后）
dmesg | grep -E "auto floor|adfr-min-fps"
#   期望： auto floor: refresh_rate:120 auto_min_fps:1, auto_mode:1
#           dsi_cmd: qcom,mdss-dsi-adfr-min-fps-5-command   ← 1Hz 命令真的发了

# 3. 看驱动状态
cat /sys/kernel/oplus_display/min_fps        # 期望 1（或表值）
```

### 6.2 面板真实刷新率（TE 测量）

`test_te` 是驱动自带的**真实测量**：用面板 TE 的 GPIO 中断算间隔
（`1000 / (now_ms - last_ms)`），且 **≤16Hz 时直接采用测量值**。

本仓库的 DTS 补丁已清掉 BIT14，所以 TE 中断在 probe 时就会注册。

```sh
echo 1 > /sys/kernel/oplus_display/test_te
cat /sys/kernel/oplus_display/test_te
#   静止 30 秒后期望 1（1Hz）
#   滑动时期望 120
echo 0 > /sys/kernel/oplus_display/test_te
```

已验证：`/proc/interrupts` 里应出现 `TEST_TE_GPIO_0` 这一行，计数随刷新变化。

### 6.3 功耗对比（最硬的证据）

静止亮屏、固定亮度，对比 `adfr_auto_floor` 0/1 的电池电流均值。参考值：120Hz 与
1Hz 地板的差约 40~60 mA。

---

## 7. 回滚

**运行时**（不刷机）：

```sh
echo 0 > /sys/module/msm_drm/parameters/adfr_auto_floor
# 下一帧生效，面板回到 mode 帧率
```

**彻底回滚**（刷回原分区）：

```sh
adb reboot fastboot
fastboot flash vendor_dlkm <备份>/vendor_dlkm_stock.img
fastboot flash dtbo        <备份>/dtbo_stock.img
fastboot reboot
```

---

## 8. 已知限制

1. **没有场景表**：原厂能按视频帧率/应用场景调地板，我们只有背光分档。
2. **1Hz 首帧延迟**：从 1Hz 回到 120Hz 由面板硬件完成，客观存在 100~300ms 的
   唤醒时间。介意就把地板设成 10 或 30。
3. **TE 测量依赖 GPIO**：`oplus,adfr-test-te-gpio = <&tlmm 85 0>` 必须有效，
   否则 `test_te` 恒为状态值而非测量值。
4. **位 14 关闭的副作用**：software marker 关闭后，RD_PTR 中断不再更新
   `test_te.refresh_rate`；该字段改由 TE 测量填充。功能路径不受影响。
