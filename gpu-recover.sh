#!/usr/bin/env bash
# Attempt NVIDIA GPU recovery on Linux without rebooting the computer.
# Automatically finds the GPU, its bridge, and its ACPI power resource.
# Save your work. Run over SSH or from a text console, not a desktop terminal.
# This stops the desktop and unloads drivers for ALL NVIDIA GPUs.

# Normally, leave these commented out. Override only if detection is ambiguous.
# GPU="0000:01:00.0"      # NVIDIA display device; full address from lspci -D.
# BRIDGE="0000:00:01.0"   # Its immediate upstream PCI bridge; see lspci -t.
# ACPI_POWER='\_SB.PCI0.PEG0.PG00'  # Example only, NOT a portable firmware path.
# A manual ACPI override must be verified for this machine's GPU slot.
GPU=${GPU:-}
BRIDGE=${BRIDGE:-}
ACPI_POWER=${ACPI_POWER:-}

set -u -o pipefail
shopt -s nullglob
umask 077
say() { printf '%s\n' "$*"; }
die() { say "Error: $*" >&2; exit 1; }

acpi() {
    local result
    printf '%s\n' "$1" > /proc/acpi/call || return 1
    result=$(tr -d '\0' < /proc/acpi/call) || return 1
    case "$result" in
        ''|Error:*) say "ACPI $1: ${result:-no response}" >&2; return 1 ;;
    esac
    printf '%s\n' "$result"
}

# Read the existing BAR1 size, rather than assuming every card wants the maximum.
bar1_index() {
    local start end bytes index=0
    read -r start end _ < <(sed -n '2p' "$gpu/resource" 2>/dev/null) || return 1
    (( start > 0 && end >= start )) || return 1
    bytes=$((end - start + 1))
    (( bytes >= 1048576 && (bytes & (bytes - 1)) == 0 )) || return 1
    while (( bytes > 1048576 )); do bytes=$((bytes / 2)); index=$((index + 1)); done
    printf '%s\n' "$index"
}

stopped=()
slot_removed=0
udev_paused=0
cleanup() {
    local status=$?
    trap - EXIT
    if (( slot_removed )); then
        acpi "$ACPI_POWER._ON" >/dev/null || say "Warning: slot power-on failed. A full shutdown may be needed."
        echo 1 > /sys/bus/pci/rescan || say "Warning: PCI rescan failed."
    fi
    if (( udev_paused )); then
        udevadm control --start-exec-queue || say "Warning: run: sudo udevadm control --start-exec-queue"
    fi
    if (( status != 0 && ${#stopped[@]} > 0 )); then
        say "Services left stopped: ${stopped[*]}"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# 1. Detect the target and check that its bridge contains no unrelated devices.
[[ $EUID == 0 ]] || die "Run with sudo."
(( $# == 0 )) || die "Usage: sudo bash gpu-recover.sh"
for command in modprobe timeout fuser setpci lspci readlink flock nvidia-smi systemctl udevadm; do
    command -v "$command" >/dev/null || die "Missing command: $command"
done
[[ -d /run/systemd/system ]] || die "This script requires systemd and udev."
exec 9>/run/gpu-recovery.lock
flock -n 9 || die "Another recovery is already running."
if [[ -z "$GPU" ]]; then
    gpus=()
    # Use cached sysfs IDs: a hung card may no longer answer lspci or nvidia-smi.
    for device in /sys/bus/pci/devices/*; do
        [[ $(cat "$device/vendor") == 0x10de && $(cat "$device/class") == 0x03* ]] || continue
        gpus+=("${device##*/}")
    done
    (( ${#gpus[@]} > 0 )) || die "No NVIDIA GPU found in sysfs. Automatic detection is not possible."
    (( ${#gpus[@]} == 1 )) || die "Multiple NVIDIA GPUs: ${gpus[*]}. Uncomment GPU to select one."
    GPU=${gpus[0]}
fi
GPU=${GPU,,}
if [[ -z "$BRIDGE" ]]; then
    path=$(readlink -e "/sys/bus/pci/devices/$GPU") || die "GPU is absent; specify its known GPU and BRIDGE addresses."
    path=${path%/*}
    BRIDGE=${path##*/}
fi
BRIDGE=${BRIDGE,,}
for address in "$GPU" "$BRIDGE"; do
    [[ "$address" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || die "No valid PCI address/bridge: $address. Use full addresses from lspci -D."
done
gpu="/sys/bus/pci/devices/$GPU"
bridge=$(readlink -e "/sys/bus/pci/devices/$BRIDGE") || die "Bridge not found."
[[ $(cat "$bridge/class") == 0x0604* ]] || die "BRIDGE is not a PCI bridge."
if [[ -d "$gpu" ]]; then
    [[ $(cat "$gpu/vendor") == 0x10de && $(cat "$gpu/class") == 0x03* ]] || die "GPU is not an NVIDIA display device."
    [[ $(readlink -e "$gpu") == "$bridge/$GPU" ]] || die "GPU is not directly under BRIDGE."
    [[ ! -L "$gpu/driver" || $(readlink "$gpu/driver") == */nvidia ]] || die "GPU uses a different driver."
else
    bus=${GPU#*:}; bus=${bus%%:*}
    [[ ${GPU%%:*} == "${BRIDGE%%:*}" && $(setpci -s "$BRIDGE" SECONDARY_BUS) == "$bus" ]] || die "GPU address does not match the bridge's bus."
    say "GPU is absent. Its identity cannot be checked; use addresses recorded while it was working."
fi
for device in /sys/bus/pci/devices/*; do
    path=$(readlink -e "$device") || die "Cannot inspect $device."
    [[ "$path" == "$bridge/"* ]] || continue
    [[ "$path" == "$bridge/$GPU" ]] && continue
    [[ ${device##*/} == "${GPU%.*}".* && $(cat "$device/vendor") == 0x10de && $(cat "$device/class") == 0x040300 ]] ||
        die "Bridge also contains ${device##*/}; refusing to reset it."
done
saved_bar=$(bar1_index) || saved_bar=-1

# Follow firmware-declared power dependencies, not guessed ACPI method names.
declare -A slot_nodes=() power_resources=()
for device in "$bridge" /sys/bus/pci/devices/"${GPU%.*}".*; do
    node=$(readlink -e "$device/firmware_node") || continue
    slot_nodes["$node"]=1
    for link in "$node"/power_resources_D0/LNXPOWER:*; do
        resource=$(readlink -e "$link") || die "Cannot resolve ACPI power resource: $link"
        power_resources["$resource"]=1
    done
done
if [[ -z "$ACPI_POWER" ]]; then
    (( ${#power_resources[@]} == 1 )) || die "No unique GPU power resource exposed by firmware. A verified ACPI_POWER override is required."
    for resource in "${!power_resources[@]}"; do
        ACPI_POWER=$(cat "$resource/path") || die "Cannot read the ACPI resource path."
    done
else
    # ACPI names can be written with or without trailing underscore padding.
    requested=$(printf '%s\n' "$ACPI_POWER" | sed -E 's/_+(\.|$)/\1/g')
    resource=''
    for entry in /sys/bus/acpi/devices/LNXPOWER:*; do
        name=$(sed -E 's/_+(\.|$)/\1/g' "$entry/path") || continue
        [[ "$name" == "$requested" ]] || continue
        resource=$(readlink -e "$entry")
        ACPI_POWER=$(cat "$entry/path")
        break
    done
    [[ -n "$resource" ]] || die "ACPI_POWER does not identify a registered power resource."
fi
# Reject any known consumer outside this GPU and its immediate bridge.
for link in /sys/bus/acpi/devices/*/power_resources_*/"${resource##*/}"; do
    [[ $(readlink -e "$link") == "$resource" ]] || continue
    owner=$(readlink -e "${link%/power_resources_*}") || die "Cannot identify an ACPI resource owner."
    [[ -n ${slot_nodes[$owner]:-} ]] || die "ACPI power is shared with ${owner##*/}; refusing to switch it off."
done
say "GPU: $GPU | Bridge: $BRIDGE | ACPI: $ACPI_POWER"

# 2. Save the kernel log first, then firmware logs, before unloading anything.
mkdir -p /var/log/gpu-recovery || die "Cannot create the log directory."
logs=$(mktemp -d "/var/log/gpu-recovery/$(date +%Y%m%d-%H%M%S).XXXXXX") || die "Cannot create a log folder."
{
    dmesg -T
    lspci -s "$GPU" -vv
    lspci -s "$BRIDGE" -vv
    for file in "$bridge"/aer_dev_*; do echo "--- $file"; cat "$file"; done
} > "$logs/system.log" 2>&1
if command -v nvidia-debugdump >/dev/null; then
    timeout -k 5 120 nvidia-debugdump --ioctl --nvlogonly -f "$logs/nvlog.zip" > "$logs/nvlog.log" 2>&1 ||
        say "Firmware log capture reported an error; its output was kept."
    if command -v unzip >/dev/null && [[ -s "$logs/nvlog.zip" ]]; then
        unzip -t "$logs/nvlog.zip" >/dev/null 2>&1 || say "Firmware archive is incomplete; kept for inspection."
    fi
fi
say "Logs: $logs"
modprobe acpi_call || die "Install the acpi_call module for your running kernel, then rerun."
[[ -w /proc/acpi/call ]] || die "acpi_call is unavailable."
acpi "$ACPI_POWER._STA" >/dev/null || die "Cannot read the ACPI power resource."

# 3. Stop common GPU services. Other applications must already be closed.
for unit in display-manager.service nvidia-persistenced.service nvidia-powerd.service lactd.service; do
    if systemctl is-active --quiet "$unit"; then
        stopped+=("$unit")
        say "Stopping $unit"
        timeout -k 5 60 systemctl stop "$unit" || die "Could not stop $unit."
    fi
done
nodes=(/dev/nvidia* /dev/nvidia-caps/*)
for node in /sys/class/drm/*; do
    [[ -e "/dev/dri/${node##*/}" && -r "$node/device/vendor" ]] || continue
    [[ $(cat "$node/device/vendor") != 0x10de ]] || nodes+=("/dev/dri/${node##*/}")
done
if (( ${#nodes[@]} > 0 )) && fuser -v "${nodes[@]}"; then
    die "GPU clients remain. Close the listed processes and try again."
fi

# 4. Unload drivers. Pause udev so the rescan cannot reload them too early.
modules=(nvidia)
for module in nvidia_uvm nvidia_modeset nvidia_drm nvidia_peermem; do
    [[ ! -d "/sys/module/$module" ]] || modules+=("$module")
done
udev_paused=1
udevadm control --stop-exec-queue || die "Cannot pause udev."
for module in nvidia_peermem nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
    [[ -d "/sys/module/$module" ]] || continue
    say "Unloading $module"
    timeout -k 5 45 modprobe -r "$module" || die "Cannot unload $module. A reboot may be needed."
    [[ ! -d "/sys/module/$module" ]] || die "$module is still loaded."
done

# 5. Remove the bridge, power-cycle the slot, then rediscover the devices.
say "Power-cycling the GPU slot. Do not interrupt this step."
slot_removed=1
echo 1 > "$bridge/remove" || die "Cannot remove the bridge."
sleep 3
acpi "$ACPI_POWER._OFF" >/dev/null || die "Slot power-off failed."
sleep 20
acpi "$ACPI_POWER._ON" >/dev/null || die "Slot power-on failed."
sleep 4
echo 1 > /sys/bus/pci/rescan || die "PCI rescan failed."
slot_removed=0
sleep 8

# 6. Wait for stable config access and link readings, not a particular PCIe generation.
say "Waiting for the GPU's PCIe connection to settle."
stable=0
previous=''
for ((attempt=0; attempt<30; attempt++)); do
    vendor=$(setpci -s "$GPU" VENDOR_ID 2>/dev/null)
    speed=$(cat "$gpu/current_link_speed" 2>/dev/null)
    width=$(cat "$gpu/current_link_width" 2>/dev/null)
    current="$vendor|$speed|$width"
    if [[ "$vendor" == 10de && "$speed" =~ ^[1-9][0-9]*(\.[0-9]+)?\ GT/s && "$width" =~ ^[1-9][0-9]*$ && "$current" == "$previous" ]]; then
        stable=$((stable + 1))
    else
        stable=0
    fi
    previous="$current"
    (( stable >= 5 )) && break
    sleep 2
done
(( stable >= 5 )) || die "GPU connection did not stabilize. A full shutdown may be needed."
say "Link: $speed x$width. This is not proof of full recovery."
[[ ! -L "$gpu/driver" ]] || die "A driver attached unexpectedly; stopping before BAR changes."

# 7. Restore the previous BAR1 size when it was available before the reset.
resize="$gpu/resource1_resize"
if (( saved_bar >= 0 )) && [[ -w "$resize" ]]; then
    if [[ $(bar1_index) != "$saved_bar" ]]; then
        if echo "$saved_bar" > "$resize"; then
            say "Restored BAR1 to $((1 << saved_bar)) MiB."
        else
            say "Warning: BAR1 restoration was refused; continuing with the current size."
        fi
    fi
else
    say "Previous BAR1 size or resize support unavailable; leaving it unchanged."
fi

# 8. Reload the original modules, refresh UVM if used, and check this GPU.
for module in "${modules[@]}"; do
    timeout -k 5 45 modprobe "$module" || die "Cannot load $module."
done
if [[ -d /sys/module/nvidia_uvm ]]; then
    timeout -k 5 30 modprobe -r nvidia_uvm || die "Cannot refresh nvidia_uvm."
    timeout -k 5 45 modprobe nvidia_uvm || die "Cannot reload nvidia_uvm."
fi
udevadm control --start-exec-queue || die "Cannot resume udev."
udev_paused=0
udevadm settle --timeout=15 || say "Warning: device events are still pending."
timeout -k 5 60 nvidia-smi -i "$GPU" --query-gpu=name,pci.bus_id --format=csv,noheader ||
    die "GPU is not responding to the driver. A reboot or full shutdown may be needed."
for ((index=${#stopped[@]}-1; index>=0; index--)); do
    unit=${stopped[index]}
    # Remove LACT's stale socket only when no process owns it.
    if [[ "$unit" == lactd.service && -S /run/lactd.sock ]] &&
       [[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] && ! fuser /run/lactd.sock >/dev/null 2>&1; then
        rm -- /run/lactd.sock
    fi
    say "Starting $unit"
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    timeout -k 5 60 systemctl start "$unit" || say "Warning: could not start $unit."
done
say "GPU responds to nvidia-smi. Test your application before resuming normal use."
