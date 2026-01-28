#!/usr/bin/env bash
set -euo pipefail

echo nouveau | tee /sys/bus/pci/devices/0000:84:00.0/driver_override
echo snd_hda_intel | tee /sys/bus/pci/devices/0000:84:00.1/driver_override

echo 0000:84:00.0 | tee /sys/bus/pci/devices/0000:84:00.0/driver/unbind
echo 0000:84:00.1 | tee /sys/bus/pci/devices/0000:84:00.1/driver/unbind

echo 0000:84:00.0 | tee /sys/bus/pci/drivers/nouveau/bind
echo 0000:84:00.1 | tee /sys/bus/pci/drivers/snd_hda_intel/bind
