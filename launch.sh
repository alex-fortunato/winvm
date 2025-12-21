#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${1:-win10pro.qcow2}"

# Prefer the invoking user's home when running via sudo so the ISO default still points to their Downloads.
USER_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
USER_HOME="${USER_HOME:-$HOME}"
ISO="${ISO:-$USER_HOME/Downloads/Win10_22H2_English_x64v1.iso}"
# Attach the installer ISO only when explicitly requested (set ATTACH_ISO=1).
ATTACH_ISO="${ATTACH_ISO:-0}"
USB_DEVICES=(${USB_DEVICES:-sdd sde})
SAMPLES_DISK="${SAMPLES_DISK:-/dev/sda}"

if [[ ! -f "$DIR/$IMG" ]]; then
  echo "Image '$IMG' not found in $DIR" >&2
  exit 1
fi
if [[ ! -w "$DIR/$IMG" ]]; then
  echo "Image '$DIR/$IMG' is not writable (check permissions or run with sufficient privileges)" >&2
  exit 1
fi

MEM="${MEM:-64G}"
CPUS="${CPUS:-4}"
# Default to an emulated NIC with built-in Windows drivers; switch to virtio after installing its driver.
NIC_MODEL="${NIC_MODEL:-e1000}"
# Audio backend for the virtual HDA device (pa, alsa, sdl, none).
AUDIO_BACKEND="${AUDIO_BACKEND:-pa}"
# Network backend: bridge (qemu-bridge-helper), tap, or auto (bridge first, tap fallback).
NETWORK_MODE="${NETWORK_MODE:-auto}"
BRIDGE_NAME="${BRIDGE_NAME:-br0}"
TAP_IFACE="${TAP_IFACE:-tap0}"
# Set to 1 once virtio drivers are installed in Windows to use virtio-net.
PREFER_VIRTIO_NET="${PREFER_VIRTIO_NET:-0}"
# Choose how to attach USB devices: block passthrough (default) or host passthrough.
USB_MODE="${USB_MODE:-block}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

log() { echo "[winvm] $*"; }
warn() { echo "[winvm][warn] $*" >&2; }
die() { echo "[winvm][error] $*" >&2; exit 1; }

find_bridge_helper() {
  local helper
  helper=$(command -v qemu-bridge-helper 2>/dev/null || true)
  if [[ -z "$helper" && -x /usr/lib/qemu/qemu-bridge-helper ]]; then
    helper="/usr/lib/qemu/qemu-bridge-helper"
  fi
  echo "$helper"
}

netdev_exists() {
  [[ -n "$1" && -d "/sys/class/net/$1" ]]
}

NETDEV_HELP_CACHE=""
netdev_supported() {
  local backend="${1:-}"
  [[ -z "$backend" ]] && return 1
  if [[ -z "$NETDEV_HELP_CACHE" ]]; then
    NETDEV_HELP_CACHE=$("$QEMU_BIN" -netdev help 2>/dev/null || true)
  fi
  grep -qx "$backend" <<<"$NETDEV_HELP_CACHE"
}

default_iface() {
  ip route list default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

print_bridge_setup_help() {
  local helper_path
  helper_path=$(find_bridge_helper)
  [[ -z "$helper_path" ]] && helper_path="/usr/lib/qemu/qemu-bridge-helper"
  local uplink
  uplink=$(default_iface || true)
  cat <<EOF
One-time host setup for bridging (run as root):
  # Allow the bridge helper to touch ${BRIDGE_NAME}
  echo "allow ${BRIDGE_NAME}" >/etc/qemu/bridge.conf
  # Make sure qemu-bridge-helper can configure tap devices (setuid root or cap_net_admin)
  chmod u+s ${helper_path}
  # Create bridge ${BRIDGE_NAME} and enslave your physical NIC (${uplink:-<uplink>}):
    - NetworkManager:
        nmcli connection add type bridge ifname ${BRIDGE_NAME} con-name ${BRIDGE_NAME}
        nmcli connection add type bridge-slave ifname ${uplink:-<uplink>} master ${BRIDGE_NAME}
        nmcli connection modify ${BRIDGE_NAME} ipv4.method auto ipv6.method auto
        nmcli connection up ${BRIDGE_NAME}
    - systemd-networkd (drop these files):
        /etc/systemd/network/${BRIDGE_NAME}.netdev
          [NetDev]
          Name=${BRIDGE_NAME}
          Kind=bridge
        /etc/systemd/network/${BRIDGE_NAME}-uplink.link
          [Match]
          Name=${uplink:-<uplink>}
          [Network]
          Bridge=${BRIDGE_NAME}
        /etc/systemd/network/${BRIDGE_NAME}.network
          [Match]
          Name=${BRIDGE_NAME}
          [Network]
          DHCP=yes
        systemctl enable --now systemd-networkd
  # Tap fallback: create a persistent tap owned by this user
    ip tuntap add dev ${TAP_IFACE} mode tap user ${SUDO_USER:-$USER}
    ip link set ${TAP_IFACE} master ${BRIDGE_NAME}
    ip link set ${TAP_IFACE} up
EOF
}

[[ "${SHOW_NET_SETUP:-0}" == "1" ]] && { print_bridge_setup_help; exit 0; }

bridge_prereqs_ok() {
  local helper allow_line cap_out ok=0
  helper=$(find_bridge_helper)
  if [[ -z "$helper" ]]; then
    warn "qemu-bridge-helper not found (install qemu-base/qemu-full and ensure helper is installed)"
    ok=1
  else
    cap_out=$({ command -v getcap >/dev/null 2>&1 && getcap "$helper" 2>/dev/null; } || true)
  fi

  if [[ -n "$helper" && ! -u "$helper" && -z "$cap_out" ]]; then
    warn "$helper is not setuid root (run: sudo chmod u+s $helper) or grant cap_net_admin"
    ok=1
  fi

  if ! netdev_exists "$BRIDGE_NAME"; then
    warn "Bridge $BRIDGE_NAME is missing; attach your uplink to it"
    ok=1
  fi

  if [[ ! -f /etc/qemu/bridge.conf ]]; then
    warn "/etc/qemu/bridge.conf missing; add: allow $BRIDGE_NAME"
    ok=1
  else
    allow_line=$(grep -E "^allow[[:space:]]+$BRIDGE_NAME$" /etc/qemu/bridge.conf 2>/dev/null || true)
    if [[ -z "$allow_line" ]]; then
      warn "/etc/qemu/bridge.conf does not allow $BRIDGE_NAME (add: allow $BRIDGE_NAME)"
      ok=1
    fi
  fi

  [[ $ok -eq 0 ]]
}

tap_prereqs_ok() {
  local ok=0
  if ! netdev_exists "$BRIDGE_NAME"; then
    warn "Bridge $BRIDGE_NAME is missing; required even for tap mode"
    ok=1
  fi
  if ! netdev_exists "$TAP_IFACE"; then
    warn "Tap $TAP_IFACE is missing; create it and attach to $BRIDGE_NAME (see SHOW_NET_SETUP=1)"
    ok=1
  fi
  [[ $ok -eq 0 ]]
}

netdev_backend=""
netdev_arg=()

if [[ "$NETWORK_MODE" == "bridge" || "$NETWORK_MODE" == "auto" ]]; then
  if ! netdev_supported "bridge"; then
    warn "QEMU binary '$QEMU_BIN' does not support -netdev bridge (install qemu-bridge-helper-enabled build or use tap)"
  elif bridge_prereqs_ok; then
    netdev_backend="bridge"
    netdev_arg=(-netdev "bridge,id=net0,br=${BRIDGE_NAME}")
  elif [[ "$NETWORK_MODE" == "bridge" ]]; then
    die "Bridge backend requested but prerequisites are missing (set SHOW_NET_SETUP=1 for help)"
  fi
fi

if [[ -z "$netdev_backend" && ( "$NETWORK_MODE" == "tap" || "$NETWORK_MODE" == "auto" ) ]]; then
  if tap_prereqs_ok; then
    netdev_backend="tap"
    netdev_arg=(-netdev "tap,id=net0,ifname=${TAP_IFACE},script=no,downscript=no")
  elif [[ "$NETWORK_MODE" == "tap" ]]; then
    die "Tap backend requested but prerequisites are missing (set SHOW_NET_SETUP=1 for help)"
  fi
fi

[[ -n "$netdev_backend" ]] || die "No usable network backend; set SHOW_NET_SETUP=1 for bridge/tap setup instructions"

NIC_DEVICE="e1000"
if [[ "$PREFER_VIRTIO_NET" == "1" || "$NIC_MODEL" == "virtio" || "$NIC_MODEL" == "virtio-net-pci" ]]; then
  NIC_DEVICE="virtio-net-pci"
fi

tap_note=""
[[ "$netdev_backend" == "tap" ]] && tap_note=", tap=${TAP_IFACE}"
log "Network backend: ${netdev_backend} (bridge=${BRIDGE_NAME}${tap_note}), NIC=${NIC_DEVICE}"

# PulseAudio generally expects a user runtime dir; when running under sudo, default to the invoking user's.
audio_runtime_dir="${AUDIO_RUNTIME_DIR:-}"
if [[ -z "$audio_runtime_dir" && -n "${SUDO_USER:-}" ]]; then
  sudo_uid=$(id -u "$SUDO_USER" 2>/dev/null || true)
  if [[ -n "$sudo_uid" && -d "/run/user/$sudo_uid" ]]; then
    audio_runtime_dir="/run/user/$sudo_uid"
  fi
fi
if [[ -z "$audio_runtime_dir" ]]; then
  current_uid=$(id -u)
  if [[ -d "/run/user/$current_uid" ]]; then
    audio_runtime_dir="/run/user/$current_uid"
  fi
fi
if [[ -n "$audio_runtime_dir" ]]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$audio_runtime_dir}"
  export PULSE_SERVER="${PULSE_SERVER:-unix:$audio_runtime_dir/pulse/native}"
  export PULSE_COOKIE="${PULSE_COOKIE:-$audio_runtime_dir/pulse/cookie}"
  log "Audio runtime: $audio_runtime_dir"
fi

audio_dev_id="audio0"
audio_dev=()
case "$AUDIO_BACKEND" in
  pa) audio_dev=(-audiodev "pa,id=$audio_dev_id") ;;
  alsa) audio_dev=(-audiodev "alsa,id=$audio_dev_id") ;;
  sdl) audio_dev=(-audiodev "sdl,id=$audio_dev_id") ;;
  none) audio_dev=(-audiodev "none,id=$audio_dev_id") ;;
  *) die "Unknown AUDIO_BACKEND '$AUDIO_BACKEND' (use pa|alsa|sdl|none)" ;;
esac
log "Audio backend: ${AUDIO_BACKEND} (device=ich9-intel-hda)"

[[ -b "$SAMPLES_DISK" ]] || die "Samples disk $SAMPLES_DISK not found (set SAMPLES_DISK or attach the device)"

args=(
  -enable-kvm
  -m "$MEM"
  -smp "$CPUS"
  # Use AHCI/IDE so Windows sees the disk without extra drivers
  -drive "file=$DIR/$IMG,if=ide,index=0"
  # Attach dedicated samples disk (raw block device). Use IDE for out-of-box Windows support.
  -drive "file=$SAMPLES_DISK,if=ide,index=1,format=raw,cache=none,aio=native"
  # Prefer booting from the installed disk; menu stays available if you need to pick the CD later.
  -boot menu=on,order=c
  -display gtk
  -vga qxl
  -device virtio-tablet
  -device virtio-keyboard
  "${audio_dev[@]}"
  -device ich9-intel-hda
  -device hda-duplex,audiodev="$audio_dev_id"
  "${netdev_arg[@]}"
  -device "${NIC_DEVICE},netdev=net0"
)

if [[ -n "${UEFI_PATH:-}" ]]; then
  args+=(-bios "$UEFI_PATH")
fi

if [[ "$ATTACH_ISO" == "1" && -f "$ISO" ]]; then
  args+=(-drive "file=$ISO,media=cdrom,readonly=on")
fi

if [[ ${#USB_DEVICES[@]} -gt 0 ]]; then
  args+=(-device qemu-xhci,id=xhci)
  for dev in "${USB_DEVICES[@]}"; do
    if [[ -b "/dev/$dev" ]]; then
      if [[ "$USB_MODE" == "host" ]]; then
        sys_base="/sys/block/$dev/device/../../"
        busnum_file=$(readlink -f "$sys_base/busnum" 2>/dev/null || true)
        devnum_file=$(readlink -f "$sys_base/devnum" 2>/dev/null || true)
        if [[ -n "${busnum_file:-}" && -n "${devnum_file:-}" && -r "$busnum_file" && -r "$devnum_file" ]]; then
          busnum=$(<"$busnum_file")
          devnum=$(<"$devnum_file")
          if [[ -n "$busnum" && -n "$devnum" ]]; then
            args+=(-device "usb-host,bus=xhci.0,hostbus=$busnum,hostaddr=$devnum")
            continue
          fi
        fi
        echo "Warning: could not resolve host USB bus/addr for /dev/$dev; falling back to block passthrough" >&2
      fi
      args+=(-drive "if=none,file=/dev/$dev,format=raw,id=usb-$dev,cache=none")
      args+=(-device "usb-storage,bus=xhci.0,drive=usb-$dev")
    else
      echo "Warning: /dev/$dev not found; skipping" >&2
    fi
  done
fi

exec "$QEMU_BIN" "${args[@]}"
