---
date: 2026-05-22
tags: [linux, power, cpu, proxmox, nodes, cka-adjacent]
---

# Proxmox node power management: amd-pstate-epp, fancontrol, PCIe ASPM

## Goal

Cut idle power on the Proxmox host (Gigabyte X570 AORUS PRO, Ryzen 9 5950X) from ~230W to a sane idle. Relevant to CKA because node resource pressure from a power-hungry host affects scheduling behaviour.

## Problem

Three compounding problems:
1. CPU governor stuck on `performance` — all cores pinned at 4.7 GHz at idle.
2. No fan control — ITE IT8792E chip unmanaged, fans spinning at BIOS default.
3. PCIe devices in full-power state always — no runtime PM, no ASPM.

## Solution

### 1. CPU governor + EPP

```bash
# Check current state
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver   # amd-pstate-epp
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # performance
cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference  # performance

# Fix governor
echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Fix EPP
echo balance_power | tee /sys/devices/system/cpu/cpufreq/*/energy_performance_preference

# Verify cores dropped
cat /proc/cpuinfo | grep MHz  # should show ~1700 MHz at idle
```

Persist via systemd oneshot at `/etc/systemd/system/power-profile.service`:
```ini
[Unit]
Description=AMD power profile — powersave governor + balance_power EPP + PCIe autosuspend
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null; \
  echo balance_power | tee /sys/devices/system/cpu/cpufreq/*/energy_performance_preference > /dev/null; \
  echo auto | tee /sys/bus/pci/devices/*/power/control > /dev/null'

[Install]
WantedBy=multi-user.target
```

### 2. Fan control (lm-sensors + fancontrol)

```bash
apt install lm-sensors fancontrol
sensors-detect --auto   # finds ITE IT8792E at 0xa60
modprobe it87
echo it87 >> /etc/modules  # persist across reboots
sensors                    # now shows fan1/fan2/fan3 RPM and pwm1/pwm2/pwm3
pwmconfig                  # interactive — defines fan curves → writes /etc/fancontrol
systemctl enable --now fancontrol
```

Note: IT8688 (ID 0x8688) also detected but listed as "unknown" — not supported by stock `it87` driver, no action needed.

### 3. PCIe runtime PM

```bash
echo auto | tee /sys/bus/pci/devices/*/power/control
# Verify
cat /sys/bus/pci/devices/*/power/control | sort | uniq -c
```

### 4. PCIe ASPM (requires reboot)

```bash
# Check current policy
cat /sys/module/pcie_aspm/parameters/policy   # [default]

# Edit /etc/default/grub — PRESERVE existing params (amd_iommu=on iommu=pt for GPU passthrough)
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt pcie_aspm=force pcie_aspm.policy=powersupersave"

update-grub
# reboot when convenient — expect further 10-15W reduction
```

## Why it works

`amd-pstate-epp` is the modern AMD driver (replaces `acpi-cpufreq`). It exposes two knobs:
- **scaling_governor**: `performance` (always max freq) vs `powersave` (let EPP/hardware decide)
- **energy_performance_preference**: hints to CPU microcode — `performance`, `balance_performance`, `balance_power`, `power`

With governor=`powersave` + EPP=`balance_power`, hardware drops cores to lowest P-state when idle. The 4.7 GHz → 1.7 GHz drop at idle is the expected result. Result: 230W → ~170W before ASPM reboot.

ASPM is the PCIe equivalent — link partners negotiate to power down the lane during idle periods. `powersupersave` is the most aggressive policy; `force` overrides any BIOS/firmware ASPM opt-out.

## CKA angle

CKA doesn't test power management directly, but node resource pressure is exam material:

- **Node conditions**: `kubectl describe node <node>` → look at `MemoryPressure`, `DiskPressure`, `PIDPressure`
- **Resource requests/limits**: a throttled CPU causes pod starvation — why `LimitRange` and resource quotas exist
- **Taints from node pressure**: kubelet applies `node.kubernetes.io/memory-pressure` taint automatically; pods without the right toleration get evicted

Useful sysfs paths to memorise:
```
/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
/sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference
/sys/bus/pci/devices/*/power/control
/sys/module/pcie_aspm/parameters/policy
```

## Revision prompts

1. What is the difference between `scaling_governor` and `energy_performance_preference` on an AMD system with `amd-pstate-epp`?
2. Why must `amd_iommu=on iommu=pt` be preserved when adding ASPM kernel params on this host?
3. What systemd service type is appropriate for a one-shot sysfs tuning script that should appear "active" after running?

## Anki

Q: What amd-pstate-epp governor setting lets hardware decide clock frequency based on EPP hints?
A: powersave (pairs with energy_performance_preference to let the CPU microcode govern P-states)

Q: What sysfs path sets the CPU scaling governor for all cores at once?
A: /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

Q: What sysfs path sets the AMD EPP hint for all policy domains?
A: /sys/devices/system/cpu/cpufreq/*/energy_performance_preference

Q: What kernel parameter enables PCIe ASPM with the most aggressive link power saving?
A: pcie_aspm=force pcie_aspm.policy=powersupersave

Q: What command detects hardware monitoring chips non-interactively on a Debian/Proxmox host?
A: sensors-detect --auto

Q: What kernel module exposes ITE Super I/O fan controllers (IT8792E etc.) to lm-sensors?
A: it87 (modprobe it87; persist with echo it87 >> /etc/modules)

Q: What sysfs path sets PCIe runtime power management to auto for all devices?
A: /sys/bus/pci/devices/*/power/control (echo auto | tee ...)
