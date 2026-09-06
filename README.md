# omarchy-surface

Hardware enablement and tablet UI for **Intel Surface devices** running
[Omarchy](https://omarchy.org/).

Omarchy detects Surface hardware but its `install/hardware/surface.sh` only
installs `linux-firmware-marvell`. The touchscreen, on-screen keyboard, and
rotation are left to you. This repo fills that gap.

It is two halves, because an Omarchy plugin *cannot* do the hardware work —
the plugin installer "never runs plugin code, install hooks, or sudo":

| Half | What it is | How it installs |
|---|---|---|
| **Hardware** | `setup.sh` + helper commands | `./setup.sh` (as your user; it sudoes where needed) |
| **Tablet UI** | Bar widget (QML) | `omarchy plugin add <this repo> --enable --yes` |

## Status: what is actually verified

Honesty matters more than coverage here. A wrong `modprobe` option leaves
someone with a dead touchscreen and no obvious way back.

| Model | Touch | Verified? |
|---|---|---|
| **Surface Pro 7+** (Tiger Lake, `8086:a0d0`) | `ithc` + `iptsd`, **polling mode required** | ✅ Verified on real hardware |
| Other `ithc` controllers (ADL / RPL / etc.) | `ithc` + `iptsd` | ⚠️ Driver applies; polling need unknown — gated behind `surface-touch-doctor` or `--force` |
| Surface Pro 4/5/6, Book, Laptop 1/2 | IPTS | ❌ Needs the `linux-surface` kernel; mainline has no IPTS driver. The script says so rather than pretending |

## Hardware status

`surface-hw-report` prints this live, with the evidence behind each verdict, so
you can paste it straight into a bug report. Measured on Surface Pro 7+:

| Feature | Status | Detail |
|---|---|---|
| Touchscreen | ✅ | `ithc` (polling) + `iptsd` |
| Pen / stylus | ✅ | incl. IPTSD virtual stylus |
| Auto-rotate | ✅ | ISH accelerometer via `iio-hyprland` |
| Accel / gyro / orientation / gravity | ✅ | ISH sensor hub |
| Wi-Fi / Bluetooth / audio / battery | ✅ | stock kernel |
| Thermal profiles | ✅ | `surface_platform_profile` |
| Suspend + hibernate | ✅ | s2idle only — see below |
| **Ambient light sensor** | ❌ | driver binds, ADC never converts ([#2274](https://github.com/linux-surface/linux-surface/issues/2274)) |
| Auto-brightness | ⚠️ | no ALS, but `surface-autobrightness` drives it from the sun |
| **Cameras** | ❌ | IPU6 firmware boots, sensors mis-powered |
| **IR camera / Windows Hello** | ❌ | `ov7251` probe fails `-121` |
| **Type Cover backlight** | ❌ | no `kbd_backlight` in `/sys/class/leds` |
| **Battery charge limit** | ❌ | no `charge_control_end_threshold` |

Everything in the bottom block needs **kernel or firmware work** — none of it is
a configuration gap you can close from userspace.

### Ambient light sensor

The ALS is an APDS9960 at i2c `0x39`, ACPI id `MSHW0184`, and mainline
deliberately claims it (`alias: acpi*:MSHW0184:*`). It still returns nothing:

- `ENABLE (0x80) = 0x03` — power-on and ALS-enable are both set
- `STATUS (0x93) = 0x00` — `AVALID` never sets; the ADC never finishes a conversion
- `ID (0x92) = 0xdc` — a stock APDS9960 reports `0xab`
- its GPIO interrupt has **never fired** (`0` counts in `/proc/interrupts`)

Forcing 64x gain and ~103 ms integration after a clean power cycle changes
nothing. Either the optical front-end is unpowered or the part behind that ACPI
id is not really an APDS9960.

### Auto-brightness without a working ALS

Since the sensor returns nothing, `surface-autobrightness` drives the backlight
from solar position instead: full brightness in daylight, dim at night, and a
smooth ~90 minute ramp across dawn and dusk.

For a vehicle-mounted tablet this is arguably better than a real ALS, which
would swing every time you pass under a bridge or a streetlight sweeps the
cabin. Solar position is smooth and predictable.

Manual changes win. If the panel brightness stops matching what the script last
set, it assumes a human moved it deliberately and backs off (default 90 min)
rather than fighting them.

```bash
surface-autobrightness status      # what it would do, and why - changes nothing
systemctl --user enable --now surface-autobrightness.timer
```

It ships **disabled**, because enabling it at night immediately dims the screen.
Without `LAT`/`LON` it falls back to a fixed 07:00-19:00 window:

```ini
# ~/.config/surface-autobrightness.conf
LAT=47.61
LON=-122.33
DAY_PCT=100
NIGHT_PCT=15
RAMP_MIN=45
OVERRIDE_MIN=90
```

### Cameras

Worth correcting a common misconception: on Tiger Lake Surfaces this is **IPU6,
not IPU3**, and the kernel side gets impressively far — the firmware
authenticates and boots, three sensors are found, the media graph populates, and
`libcamera` enumerates a front and a back camera. Capture still yields empty
buffers, because:

```
int3472-discrete INT3472:01: GPIO type 0x08 unknown; the sensor may not work
ov5693/ov8865/ov7251: supply dovdd/dvdd not found, using dummy regulator
intel_ipu6_isys: csi2-4 error: Transfer FIFO overflow
```

`int3472` owns camera power and reset GPIOs. It does not recognise a GPIO type
on this board, so the sensors are never sequenced correctly and the CSI-2
receiver overflows on malformed data. Fixing that is a kernel quirk, not
configuration.

## The Surface Pro 7+ touchscreen finding

Worth stating plainly, because the internet will send you the wrong way.

On SP7+ the `ithc` probe fails:

```
ithc 0000:00:10.6: failed to read report descriptor   (x6)
ithc 0000:00:10.6: ithc_start: hid_add_device failed with -110
```

Upstream's README points SP7+ owners at the kernel parameter `intremap=nosid`.
**That is the fix for a different failure** — one that logs `source-id
verification failure` because the IOMMU is blocking the interrupt. On the
machine this was developed against, no such message ever appears. Applying
`intremap=nosid` there weakens DMA hardening and fixes nothing.

The actual problem is that the controller gets **no MSI**, sits on a legacy pin
IRQ, and never appears in `/proc/interrupts` — interrupts simply are not
delivered. The fix is polling mode:

```
options ithc poll=1     # /etc/modprobe.d/ithc.conf
```

`surface-touch-doctor` distinguishes the two cases from the kernel log instead
of guessing, and only offers the fix that matches.

Also worth knowing: `iptsd` is not optional. The raw HID nodes the kernel
creates advertise `ID_INPUT_TOUCHSCREEN` but emit **zero bytes** — the data is
IPTS-encoded and only `iptsd` can decode it.

## Commands

| Command | Purpose |
|---|---|
| `surface-touch-doctor [--fix]` | Diagnose a dead touchscreen; distinguishes the `-110` timeout from the IOMMU case and applies polling only when that is the real fault |
| `surface-osk [toggle\|show\|hide\|status\|is-visible]` | On-screen keyboard (`wvkbd`) |
| `surface-autorotate [toggle\|on\|off\|status\|is-locked]` | Accelerometer rotation lock |
| `surface-autobrightness [apply\|status]` | Sun-driven screen brightness, for machines whose ALS returns nothing |
| `surface-bt-connect [mac ...]` | Page paired Bluetooth input devices instead of waiting for them |

`is-visible` and `is-locked` communicate by **exit code** (0 = yes), which is
what the bar widget polls.

### Why `surface-bt-connect` exists

BlueZ never initiates a connection to a paired device at startup — it waits for
the peripheral to wake and page the host. A sleeping Bluetooth keyboard can
therefore appear dead for **minutes** after boot. Measured on the development
machine: **169 s** of BlueZ doing nothing, versus **~40 s** when the host pages
the keyboard instead. Pressing any key connects it instantly; this just removes
the need to know that.

Run it at boot:

```ini
# /etc/systemd/system/surface-bt-connect.service
[Unit]
After=bluetooth.service
Wants=bluetooth.service
[Service]
Type=simple
ExecStart=/usr/local/bin/surface-bt-connect
[Install]
WantedBy=multi-user.target
```

`Type=simple`, not `oneshot` — a keyboard that will not wake must never hold up
the boot.

## The bar widget

A tablet has no keyboard to press a shortcut on, so every action must be
reachable by touch:

- **left click** — toggle the on-screen keyboard
- **right click** — toggle rotation lock

State is polled from the helpers by exit code rather than cached locally,
because `wvkbd --auto` shows and hides the keyboard on its own when a text field
takes focus. A cached flag drifts and silently inverts the toggle.

## Non-goals

- **Installing the `linux-surface` kernel.** Arch's stock kernel is usually
  *newer*, and the only thing needed from the patched kernel here (`ithc`) is
  available via DKMS. The script never downgrades your kernel.
- **Setting `intremap=nosid`.** See above.
- **Cameras.** See above.

## Contributing

Verification on models other than Surface Pro 7+ is the most useful thing you
can add. If `surface-touch-doctor` gets your touchscreen working, please open an
issue with your `product_name`, the PCI id from `lspci -n | grep 0901`, and
whether polling was needed — that is exactly what the verified table needs.
