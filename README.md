# adfr-ltpo-kernel

OnePlus 15 (infiniti / SM8850 "canoe") OSS kernel CI that adds **kernel-side LTPO**
on top of pristine LineageOS trees.

This repo holds **only the patch overlay and the CI** — the kernel sources are
synced from LineageOS at build time, exactly as
[`txtyb/android_kernel_oneplus_sm8850`](https://github.com/txtyb/android_kernel_oneplus_sm8850)
does it.

📖 **Design, tuning and verification: [docs/kernel-ltpo.md](docs/kernel-ltpo.md)**

## What the patches change

| Patch | Tree | Effect |
|---|---|---|
| `0002-adfr-driver.diff` | `oplus_adfr.c/.h` | Adds a kernel-side ADFR floor: on every timing switch it derives `sa_min_fps` from the panel backlight table (or `adfr_auto_min_fps`) and arms `auto_mode`, so the panel manages idle transitions itself. Also carries the Infinity-X port (backlight table parsing, QSync driven floor) which stays inert on this panel. |
| `0003-adfr-panel.diff` | AD296 panel dtsi | Adds `qcom,dsi-qsync-mode-avr-step-fps` to every timing, restores the ADFR min-fps mapping tables + DSI command sequences for the 144 Hz and 165 Hz timings, adds the SA floor backlight table, and clears BIT14 of `oplus,adfr-config` so the TE GPIO interrupt is registered at probe time (that is what makes the real panel refresh rate measurable). |

## Why this is not just the Infinity-X patch

Infinity-X drives LTPO from userspace:
`oplus_adfr_init` (a vendor service) sends the control word `0x5cc18181`
(= auto mode ON + 1 Hz floor) through the QTI composer, which a patched
`display-core` turns into a write of the connector's `qsync_min_fps` DRM
property. That needs two HAL patches plus a device service.

LineageOS has none of those, and the generic QSync property is dropped by
`sde_connector` whenever the panel runs OA fixed TE. This repo produces the same
kernel end state from inside the driver instead — no HAL changes, no userspace
daemon, no polling.

## Runtime control

The feature is **off by default**; the patch is a no-op until it is armed.

```sh
# arm / disarm
echo 1 > /sys/module/msm_drm/parameters/adfr_auto_floor
echo 0 > /sys/module/msm_drm/parameters/adfr_auto_floor

# optional fixed floor (0 = use the backlight table)
echo 30 > /sys/module/msm_drm/parameters/adfr_auto_min_fps
```

Default backlight table (from the panel DTS):

```dts
oplus,adfr-sa-min-fps-bl-table = <1160 1>, <919 30>, <0 0>;
```

## Verification

```sh
dmesg | grep -E "auto floor|adfr-min-fps"
#   auto floor: refresh_rate:120 auto_min_fps:1, auto_mode:1
#   dsi_cmd: qcom,mdss-dsi-adfr-min-fps-5-command      <- 1 Hz really sent

cat /sys/kernel/oplus_display/min_fps                   # requested floor

# real panel rate, measured from the TE GPIO
echo 1 > /sys/kernel/oplus_display/test_te
cat /sys/kernel/oplus_display/test_te                   # 1 when idle at 1 Hz
```

## Artifacts and flashing

```
op15-images-*      boot.img, dtbo.img, vendor_dlkm.img, system_dlkm.*, *.dtb/.dtbo
op15-modules-*     the .ko set
op15-anykernel3-*  flashable zip (boot.img kernel only — not used here)
```

Flash the two images this change touches:

```bash
fastboot flash vendor_dlkm vendor_dlkm.img
fastboot flash dtbo        dtbo.img
```

`vendor_dlkm` is a logical partition inside `super`, so it needs **fastbootd**
(`adb reboot fastboot`).

⚠️ kleaf's own `vendor_dlkm.img` is ext4 and ~3x the partition size; the ROM
flashes an EROFS image. `.ci/70-vendor-dlkm-erofs.sh` rebuilds the correct one
from the dist (or repack the device's own image, see `docs/`).
