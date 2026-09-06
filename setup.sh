#!/bin/bash
# omarchy-surface: hardware enablement for Intel Surface tablets on Omarchy.
#
# Run as your normal user, NOT as root. Privileged steps call sudo themselves,
# and AUR builds must not run as root.
#
#   ./setup.sh                 # detect, then set up what this model needs
#   ./setup.sh --dry-run       # show what would happen, change nothing
#   ./setup.sh --force         # apply untested settings on unverified models
#
# What this deliberately does NOT do:
#   - install the linux-surface kernel. Arch's stock kernel is usually newer,
#     and the only thing it was needed for here (ithc) is available via DKMS.
#   - set intremap=nosid. That weakens IOMMU protection and only fixes the
#     "source-id verification failure" case. surface-touch-doctor tells you if
#     you are actually in that case.
#   - touch the cameras. The IPU3 sensors on these machines need a libcamera
#     pipeline that does not work reliably; pretending otherwise helps nobody.

set -uo pipefail

DRY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] && { echo "Run as your normal user, not root. Privileged steps use sudo." >&2; exit 1; }

STEP=0
step() { STEP=$((STEP+1)); printf '\n\033[1m==> %d. %s\033[0m\n' "$STEP" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33mWARNING:\033[0m %s\n' "$*"; }
run()  { if ((DRY)); then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# ---------------------------------------------------------------- detection --
step "Detect hardware"
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
info "vendor : ${VENDOR:-unknown}"
info "model  : ${MODEL:-unknown}"

if [[ $VENDOR != "Microsoft Corporation" ]]; then
  echo "This is not a Microsoft Surface. Nothing to do." >&2
  exit 1
fi

# PCI class 0901 is "Digitizer Pen" - the Touch Host Controller on SP7+ and
# newer. Surface Pro 4/5/6 instead expose IPTS, which mainline does not drive.
THC_ID=$(lspci -n 2>/dev/null | awk '$2 ~ /^0901:/ {print $3}' | head -1)

# Device ids where polling mode is CONFIRMED necessary, i.e. the controller
# never delivers its interrupt and probe dies with -110. Verified on hardware.
declare -A POLL_VERIFIED=(
  [8086:a0d0]="Tiger Lake-LP THC (Surface Pro 7+)"
  [8086:a0d1]="Tiger Lake-LP THC, second controller"
)

TOUCH_STACK="none"
if [[ -n $THC_ID ]]; then
  TOUCH_STACK="thc"
  info "touch  : Intel Touch Host Controller $THC_ID -> ithc + iptsd"
elif [[ $MODEL =~ (Surface\ Pro\ [456]|Surface\ Book|Surface\ Laptop\ [12]|Surface\ Studio) ]]; then
  TOUCH_STACK="ipts"
  info "touch  : IPTS-era device"
else
  info "touch  : no touch controller detected"
fi

# ------------------------------------------------------------- surface repo --
step "linux-surface package repository"
if grep -q '^\[linux-surface\]' /etc/pacman.conf 2>/dev/null; then
  info "already configured"
else
  warn "not configured. iptsd comes from it."
  info "Add it by following https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup#arch"
  info "(this script will not import a signing key on your behalf)"
fi

# -------------------------------------------------------------------- iptsd --
step "iptsd (decodes the proprietary touch data)"
if pacman -Qq iptsd >/dev/null 2>&1; then
  info "installed: $(pacman -Q iptsd)"
else
  run "sudo pacman -S --needed --noconfirm iptsd"
fi

# --------------------------------------------------------------------- ithc --
if [[ $TOUCH_STACK == thc ]]; then
  step "ithc kernel module (out-of-tree, via DKMS)"
  if dkms status 2>/dev/null | grep -q '^ithc'; then
    info "DKMS reports: $(dkms status | grep '^ithc' | head -1)"
  else
    warn "ithc is not installed via DKMS."
    info "Install it so it rebuilds automatically on kernel updates:"
    info "    omarchy pkg aur add ithc-dkms-git"
    info "  (or: yay -S ithc-dkms-git)"
    info "A hand-built copy in /usr/src will work but never receives updates."
  fi

  step "Polling mode for the touch controller"
  if [[ -n ${POLL_VERIFIED[$THC_ID]:-} ]]; then
    info "$THC_ID is a known-affected controller: ${POLL_VERIFIED[$THC_ID]}"
    if [[ -f /etc/modprobe.d/ithc.conf ]] && grep -q 'poll=1' /etc/modprobe.d/ithc.conf; then
      info "already configured"
    else
      run "printf '# %s: interrupts are never delivered, so probe fails with -110.\\n# Polling avoids the interrupt path with no IOMMU trade-off.\\noptions ithc poll=1\\n' '$THC_ID' | sudo tee /etc/modprobe.d/ithc.conf >/dev/null"
      info "wrote /etc/modprobe.d/ithc.conf"
    fi
  else
    warn "$THC_ID is not in the verified list - polling may or may not be needed."
    if ((FORCE)); then
      run "printf 'options ithc poll=1\\n' | sudo tee /etc/modprobe.d/ithc.conf >/dev/null"
      info "applied anyway because --force was given"
    else
      info "Run 'surface-touch-doctor' after a reboot: it inspects the actual"
      info "failure and tells you whether polling is the right fix."
    fi
  fi
elif [[ $TOUCH_STACK == ipts ]]; then
  step "IPTS touch"
  warn "Mainline Arch kernels do not include the IPTS driver."
  info "On this model the touchscreen needs the patched kernel:"
  info "    sudo pacman -S linux-surface linux-surface-headers"
  info "then add its entry to your bootloader. iptsd alone is not enough here."
fi

# ------------------------------------------------------------ tablet extras --
step "Tablet userspace (on-screen keyboard, rotation)"
PKGS=()
pacman -Qq wvkbd            >/dev/null 2>&1 || PKGS+=(wvkbd)
pacman -Qq iio-sensor-proxy >/dev/null 2>&1 || PKGS+=(iio-sensor-proxy)
if ((${#PKGS[@]})); then run "sudo pacman -S --needed --noconfirm ${PKGS[*]}"; else info "wvkbd and iio-sensor-proxy present"; fi
command -v iio-hyprland >/dev/null 2>&1 \
  && info "iio-hyprland present" \
  || info "iio-hyprland missing (AUR): omarchy pkg aur add iio-hyprland-git"

# ---------------------------------------------------------------- helpers ----
step "Install helper commands to /usr/local/bin"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin"
for f in "$SRC"/*; do
  [[ -f $f ]] || continue
  run "sudo install -Dm755 '$f' '/usr/local/bin/$(basename "$f")'"
  info "$(basename "$f")"
done

# ------------------------------------------------------------------ summary --
step "Summary"
info "touch stack   : $TOUCH_STACK"
info "iptsd         : $(pacman -Q iptsd 2>/dev/null || echo 'not installed')"
info "ithc dkms     : $(dkms status 2>/dev/null | grep '^ithc' | head -1 || echo 'not installed')"
info "poll override : $([[ -f /etc/modprobe.d/ithc.conf ]] && echo present || echo absent)"
printf '\nNext:\n'
printf '  1. Reboot, then run: surface-touch-doctor\n'
printf '  2. Add the bar widget: omarchy plugin add <this repo url> --enable --yes\n'
((DRY)) && printf '\n(dry run - nothing was changed)\n'
