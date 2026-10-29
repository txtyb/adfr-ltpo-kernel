# adfr-ltpo-kernel

OnePlus 15 (infiniti / SM8850 "canoe") OSS kernel CI that overlays the
**Project Infinity-X LTPO/ADFR implementation** on top of pristine
LineageOS trees.

This repo holds **only the patch overlay and the CI** — the kernel sources are
synced from LineageOS at build time, exactly as
[`txtyb/android_kernel_oneplus_sm8850`](https://github.com/txtyb/android_kernel_oneplus_sm8850)
does it.

## What the patches change

| Patch | Tree | Effect |
|---|---|---|
| `0002-adfr-driver.diff` | `oplus_adfr.c/.h` | Derives the ADFR SA min-fps floor from the QSync state requested by SDE, picks it from a backlight table (`oplus,adfr-sa-min-fps-bl-table`), turns on `auto_mode` while qsync is active, and recomputes the floor after every timing switch |
| `0003-adfr-panel.diff` | AD296 panel dtsi | Adds `qcom,dsi-qsync-mode-avr-step-fps` to every timing, restores the ADFR min-fps mapping tables + DSI command sequences for the 144 Hz and 165 Hz timings, and adds the SA floor backlight table |

The floor table ported from Infinity-X is

```
oplus,adfr-sa-min-fps-bl-table = <1160 1>, <919 30>, <0 0>;
```

meaning: backlight ≥ 1160 → 1 Hz, ≥ 919 → 30 Hz, dimmer than that → stay at
the mode rate (low-refresh PWM artefacts at low brightness).

Implementation reference: [Project Infinity-X](https://github.com/ProjectInfinity-X),
trees at [infiniti-labs](https://github.com/infiniti-labs).

## Why it works without a userspace daemon

The QTI composer already tracks whether the display is idle and asks SDE for a
QSync mode (`sde_connector->qsync_mode`). The patch simply translates that state
into the ADFR floor, so the framework needs no changes and no polling loop is
involved.

## Artifacts and flashing

The build produces the same artifacts as the upstream CI:

```
op15-images-*      boot.img, dtbo.img, vendor_dlkm.img, system_dlkm.*, *.dtb/.dtbo
op15-modules-*     the .ko set
op15-anykernel3-*  flashable zip (boot.img kernel only — not used here)
```

Flash the two images this change actually touches:

```bash
fastboot flash vendor_dlkm vendor_dlkm.img
fastboot flash dtbo        dtbo.img
```

Staged testing:

1. `vendor_dlkm.img` alone — the driver falls back to
   `qsync_min_refresh_rate` (30 Hz) because no backlight table exists yet.
   This proves the QSync → ADFR path works without touching the panel tables.
2. `dtbo.img` as well — the backlight table and the 144/165 Hz tables come
   into play, unlocking 1 Hz.

## Checking it took effect

```bash
# after a reboot, with the screen on and idle
cat /sys/kernel/oplus_display/min_fps          # should drop to 1 or 30
dmesg | grep -E 'sa_min_fps_bl_table_count|adfr-min-fps'
```

`sa_min_fps_bl_table_count:3` in dmesg means the backlight table was parsed from
the DTB (stage 2); `adfr-min-fps-5-command` means the panel actually received a
1 Hz command.
