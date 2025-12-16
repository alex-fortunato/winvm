# Vienna Ensemble Pro VM Bridging Notes

## What we changed (host/QEMU)
- Switched `launch.sh` to prefer a bridged NIC so the Windows VM sits on the same L2/L3 network for VEP discovery; tap fallback available.
- Added env toggles: `NETWORK_MODE` (`auto`/`bridge`/`tap`), `BRIDGE_NAME` (default `br0`), `TAP_IFACE` (default `tap0`), `PREFER_VIRTIO_NET`/`NIC_MODEL` to pick `virtio-net` vs `e1000`, `QEMU_BIN` override.
- Added preflight checks (bridge exists, helper allowed/setuid/caps, tap exists) and a writable-image check. `SHOW_NET_SETUP=1 ./launch.sh` prints one-time setup instructions.
- Bridge helper discovery now looks at `/usr/lib/qemu/qemu-bridge-helper` if not on `PATH`.

## Host networking setup we applied
- Created `br0` via NetworkManager and enslaved `enp5s0f0`.
  - Commands run: `nmcli connection add type bridge ifname br0 con-name br0`; `nmcli connection add type bridge-slave ifname enp5s0f0 master br0`; `nmcli connection modify br0 ipv4.method auto ipv6.method auto`; `nmcli connection up br0`; `nmcli connection up bridge-slave-enp5s0f0`.
- `/etc/qemu/bridge.conf` contains `allow br0`.
- `qemu-bridge-helper` is present and setuid at `/usr/lib/qemu/qemu-bridge-helper`.
- `br0` currently has LAN IP `192.168.1.166/24` (DHCP from router).

## Launch usage
- Normal: `./launch.sh` (defaults to bridge, `QEMU_BIN=qemu-system-x86_64`).
- Force bridge or tap: `NETWORK_MODE=bridge ./launch.sh` or `NETWORK_MODE=tap ./launch.sh` (requires existing `tap0` attached to `br0`).
- If you need virtio NIC: `PREFER_VIRTIO_NET=1 ./launch.sh` (Windows must have virtio drivers). Otherwise default `e1000` works out of the box.

## Windows VM checklist for VEP discovery
- In Windows: `ipconfig` shows LAN IP (192.168.1.x). Network profile set to **Private**.
- Enable Network Discovery/File Sharing on Private.
- Allow VEP Server (64-bit) through Windows Firewall on Private (TCP/UDP) or add `netsh advfirewall` rules for `vvepsrv.exe`.
- Run the 64-bit VEP Server; keep “Advertise on local network” enabled.
- On macOS: ping the VM IP; VEP plugin should discover the server. If not, briefly disable the Windows firewall on Private to isolate rule issues, then re-enable with correct rules.

