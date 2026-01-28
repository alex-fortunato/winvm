#!/usr/bin/env bash
set -euo pipefail

modprobe vfio-pci

echo vfio-pci | tee /sys/bus/pci/devices/0000:84:00.0/driver_override
echo vfio-pci | tee /sys/bus/pci/devices/0000:84:00.1/driver_override

echo 0000:84:00.0 | tee /sys/bus/pci/devices/0000:84:00.0/driver/unbind
echo 0000:84:00.1 | tee /sys/bus/pci/devices/0000:84:00.1/driver/unbind

echo 0000:84:00.0 | tee /sys/bus/pci/drivers/vfio-pci/bind
echo 0000:84:00.1 | tee /sys/bus/pci/drivers/vfio-pci/bind
