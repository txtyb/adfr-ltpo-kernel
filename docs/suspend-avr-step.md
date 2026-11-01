# 息屏无法深睡：`avr-step` / ARR 与 s2idle 的冲突

> 2026-11-01 实机排查记录。结论：**不是 ADFR 本身的问题，而是 `avr-step` 广告出去之后
> 每次 commit 都被 `-EINVAL` 打回，SurfaceFlinger 无限重试把显示管道占住。**

## 一、现象

刷入 LTPO 补丁（含 `qcom,dsi-qsync-mode-avr-step-fps`）后：

```
/sys/power/suspend_stats:  21.5 小时里 success=9  fail=818
内核日志:                  PM: suspend entry (s2idle) → 0.5s → exit
                           Abort: Pending Wakeup Sources: common / gauge
熄屏电流:                  -120 mA
实际耗电:                  8.5 小时掉 30%
```

回退到原厂 dtbo + vendor_dlkm：20 分钟 940 次成功挂起，正常。

## 二、排查过程（记录方法论）

| 假设 | 验证方式 | 结果 |
|---|---|---|
| Wi-Fi 唤醒 | 关 Wi-Fi 测 5 分钟 | ✗ 电流和失败数都不变 |
| 蓝牙 | 再关蓝牙 | ✗ |
| 所有无线电 | 飞行模式 | ✗ |
| 第三方应用（闲鱼 23% CPU） | `am force-stop` | ✗ |
| 显示驱动（我们的改动） | 逐项回退 dtbo | ▸ 确认在 dtbo |
| `adfr-config` BIT14 | 二进制回退该位 | ✗ |
| **`avr-step`** | 属性名改成无效名 | **✓** |

关键工具：`/sys/power/suspend_stats`、`dmesg | grep "PM: suspend"`、
`dumpsys batterystats --history | grep wake_reason`、设备端脚本按 wall-clock 计时采样。

**踩过的坑**：手机插 USB 时 USB 控制器本身会阻止深睡，必须拔线测；`sleep N` 在频繁
挂起的系统上会被拉长（按清醒时间计），窗口要用 `date +%s` 判断。

## 三、根因

`avr-step` 在驱动里**不持有任何 PM 资源**（无 wakeup_source、无常驻 timer、无 runtime PM；
cmd 面板连 `freq_step_timer` 都没有）。真正的机制是：

```
面板 DTS 声明 qcom,dsi-qsync-mode-avr-step-fps
   ↓
composer 认为支持 ARR，置 CONNECTOR_PROP_AVR_STEP_STATE = ENABLE
   ↓
但 CONNECTOR_PROP_QSYNC_MODE 一直是 0
（OPPO ADFR 驱动在 OA fixed TE 面板上会丢弃这个 property）
   ↓
sde_encoder.c: _sde_encoder_avr_step_check()
       if (!qsync_mode && avr_step_state) return -EINVAL;
   ↓
每次 commit 的 atomic_check 都失败 → SurfaceFlinger 无限重试
   ↓
显示管道一直有活动 → 每一轮 60 秒的挂起窗口都被打断
   ↓
suspend_stats: success 0 / fail 818；failed_suspend=182（设备回调失败）
```

日志里的 `Abort: Pending Wakeup Sources: common / gauge` 是**信息性输出**
（`pm_get_active_wakeup_sources()` 打印"此刻谁 active"），不是原因。
`common` / `gauge` 是 OPPO 充电框架的 MMS topic。

## 四、修复

两处改动，都在 `.ci/patch/0002-adfr-driver.diff`：

### 4.1 `sde_encoder.c`（F6）—— 让 commit 不再必然失败

```c
- if (!qsync_mode && avr_step_state) {
-     SDE_ERROR("invalid config: avr-step enabled without qsync\n");
-     return -EINVAL;
+ if (!qsync_mode)
+     qsync_mode = SDE_RM_QSYNC_CONTINUOUS_MODE;   /* 与 arp/video-psr 分支一致 */

  _sde_encoder_get_qsync_fps_callback(...);
+ if (!min_fps)
+     min_fps = nom_fps;                            /* 没有 qsync 投票时用标称帧率 */
```

### 4.2 `oplus_adfr.c` —— 地板不再依赖 qsync

```c
- if ((qsync_mode != SDE_RM_QSYNC_DISABLED) && table_count) {
+ if (table_count && p->sa_min_fps_bl_table_count) {
```

LineageOS 只在 ARR 生效时才开 qsync，而 ARR 又是耗电问题的来源，所以地板改为
「只要面板声明了背光表就应用」。

### 4.3 `oplus_adfr.h`

补上 `qsync_mode` / `sa_min_fps_bl_table` / `sa_min_fps_bl_table_count` 成员和
`oplus_adfr_get_params()` 原型。

## 五、实测结果

| 配置 | 5 分钟深睡次数 | ARR（24/30 匹配） | ADFR 地板 |
|---|---|---|---|
| 原版 + avr-step | **0** | ✅ | ✅ |
| 去掉 avr-step | 273 | ❌ | ✅ |
| **avr-step + F6** | **193** | ✅ | ✅ |

地板分档实测（F6 版）：

```
bl=636  → min_fps=120   （不降频）
bl=925  → min_fps=30
bl=1600 → min_fps=1
```

`invalid config: avr-step enabled without qsync` 报错：**0 次**。

## 六、附：面板 DTS 的一个事实

本面板 DTS **没有** `qcom,mdss-dsi-adfr-auto-on-command`，所以驱动里的
`auto_mode = OPLUS_ADFR_AUTO_ON` 实际发不出任何 DCS 命令。地板完全依赖
`qcom,mdss-dsi-adfr-min-fps-N-command`（page 0x2D 的 `83` / `97` / `B1` / `A1` 写）。
`oplus_adfr_min_fps_update()` 的源码路径**完全不看 qsync**，这和解耦改动一致。

## 七、复现与验证

```sh
# 挂起统计
cat /sys/power/suspend_stats/{success,fail,last_failed_step,last_failed_errno}

# 5 分钟无人干预测试（拔线后运行）
sh /data/local/tmp/sleep_quick.sh 300
cat /data/local/tmp/sleep_quick.txt

# 地板分档
echo 925 > /sys/class/backlight/panel0-backlight/brightness
cat /sys/kernel/oplus_display/min_fps          # 期望 30
dmesg | grep adfr-min-fps
```
