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

**Cameras are out of scope.** The `ov5693`/`ov7251`/`ov8865` sensors fail with
`-121` and need an IPU3 libcamera pipeline that does not work reliably. Windows
Hello IR face unlock depends on those same sensors. Claiming "full parity" while
these are broken would be a lie.

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
