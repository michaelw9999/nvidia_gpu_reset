NVIDIA GPU recovery without rebooting Linux

A standalone recovery script for NVIDIA Blackwell GPUs that become unresponsive after a crash. It attempts to bring the GPU back by requesting a firmware-controlled slot power-cycle, then reloading the driver, while keeping the computer running.

Related discussion: https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1151, covering reports of Xid 79, black screens, and GPUs becoming inaccessible.

This is a recovery workaround, not a fix for the crash. It does not prevent another failure or establish its cause. Recovery depends on the motherboard's firmware and the state of the GPU and driver.

Before running

Save your work and close GPU applications. Run from SSH or a text console, not a terminal inside your desktop. The script stops the graphical session and unloads drivers for ALL NVIDIA GPUs. A console displayed by the affected GPU may also go blank, so SSH is preferable when available. The script runs immediately; there is no confirmation prompt.

You need Linux with Bash 4.4+, systemd/udev, an installed NVIDIA driver and nvidia-smi, plus pciutils, psmisc, kmod, util-linux, and standard GNU utilities.

You also need the acpi_call kernel module installed for your running kernel. This is what lets the script call the firmware's power-control methods. Use your distribution's package or the project's installation guidance. Check that it loads:

sudo modprobe acpi_call

That command loads an installed module; it does not install one. The script and ZIP do not bundle dependencies or install them automatically. Secure Boot may require a signed module.

Run the script

Download only the .sh

Download gpu-recover.sh. On GitHub, use the file's Download raw file button so you save the script, not an HTML page.

From the directory containing the downloaded file, run:

sudo bash gpu-recover.sh

No executable permission change is needed when running it through bash. No settings need editing when detection succeeds.

Download the ZIP

The supplied gpu-recovery-windows.zip contains the same Linux script, this README, and an untested Windows helper. From the directory containing the ZIP:

unzip gpu-recovery-windows.zip

You can also extract it with your file manager. For GitHub's Code > Download ZIP, the extracted folder name will differ; run the same sudo bash gpu-recover.sh command from the folder containing the script.

Linux only needs the .sh file. The ZIP is a convenient bundle, not a different recovery method.

How automatic detection works

The script finds the NVIDIA display device using Linux's cached PCI information under /sys, then follows its device-tree path to the immediate upstream PCI bridge. It does not need a working nvidia-smi response to identify the card.

For power control, it follows the firmware's power_resources_D0 associations for the bridge and GPU functions. It requires one identifiable power resource and checks for known consumers outside the GPU and its bridge. It also refuses to reset a bridge containing unrelated PCI devices; the GPU's NVIDIA audio function is allowed.

If there are multiple NVIDIA GPUs, an ambiguous or missing power-resource mapping, or a known shared resource, it stops before shutting down the desktop rather than guessing. If the GPU has already disappeared entirely from Linux's device tree, automatic GPU detection cannot work.

The three commented lines at the top are there for verified manual overrides:

# GPU="0000:01:00.0"
# BRIDGE="0000:00:01.0"
# ACPI_POWER='\_SB.PCI0.PEG0.PG00'

These are examples, not universal settings. Use lspci -D and lspci -t to inspect PCI addresses and topology, ideally while the GPU is working. An ACPI override must be a registered power resource verified for that machine's GPU slot. Do not copy another person's firmware path or bypass the shared-resource checks.

What happens during recovery

The Linux script has eight stages:

Stage

What it does

1. Identify and check

Detects the GPU, bridge, and ACPI resource; rejects unrelated devices and known shared resources; records the existing BAR1 size; prevents two copies running at once.

2. Save diagnostic logs

Captures the kernel log, GPU/bridge PCI details, and available PCIe error counters. Attempts firmware log capture with nvidia-debugdump when installed, before unloading the driver.

3. Release the GPU

Stops active display-manager, nvidia-persistenced, nvidia-powerd, and lactd services. Checks NVIDIA and associated DRM device files for remaining clients. It reports those processes and stops instead of forcibly killing them.

4. Unload the driver

Records the loaded NVIDIA modules, pauses udev event execution, and unloads the NVIDIA driver stack. Pausing udev helps prevent automatic driver loading during rediscovery.

5. Cycle the slot resource

Removes the bridge and its children from Linux's PCI device tree, calls the firmware resource's _OFF method, waits 20 seconds, calls _ON, and rescans PCI devices.

6. Wait for a stable connection

Polls the GPU's vendor ID, PCIe link speed, and lane count until repeated readings are stable. It does not require or force a particular PCIe generation or lane count.

7. Restore BAR1

Attempts to restore the previously recorded BAR1 size when the kernel exposes resizing support. It does not automatically request the largest possible size. Failure to resize is reported but does not stop recovery.

8. Reconnect and check

Reloads the original modules, refreshes nvidia_uvm if used, resumes udev, and checks the selected GPU with nvidia-smi. If that succeeds, it attempts to restart only the services it stopped.

When restarting LACT, it removes a stale socket only after checking that no process owns it and the service has no main process. The script does not relaunch your applications or change BIOS settings, driver configuration, clocks, or power limits itself.

Why this can work when a driver reload does not

The GPU can retain a bad state

Restarting Linux's driver does not necessarily reset everything inside the GPU. NVIDIA's GSP management firmware can encounter an existing protected-memory state that prevents a fresh boot. In _kgspBootGspRm(), NVIDIA explicitly rejects an unexpected active WPR2 state with:

unexpected WPR2 already up, cannot proceed with booting GSP

The code then reports that the GPU may need resetting. This explains one way a driver reload can fail, not the cause of every Xid 79.

Firmware provides a different recovery path

Instead of relying only on the unresponsive GPU or a software driver restart, this script calls the motherboard firmware's power-resource methods through acpi_call. On a suitable platform, that transition can clear enough persistent device state for the GPU and driver to initialize again.

The important distinction is no computer reboot, not no power-cycle. A device-level power transition is the recovery mechanism.

ACPI power resources can control power, clocks, or other platform resources. A successful _OFF/_ON call does not prove that every GPU power rail was disconnected. The firmware's implementation determines what actually happens; automatic detection cannot guarantee an effective physical reset.

The sequence matters

Removing and rescanning a PCI device only changes Linux's device enumeration; it is not itself proof of power removal. This script combines PCI removal and rediscovery with the ACPI transition, then delays driver loading until the connection settles. Stable link readings are a readiness check, not proof that all firmware initialization has finished.

It also preserves evidence before teardown: NVIDIA's GSP logging code allocates buffers in host memory and frees them during cleanup. Capturing those buffers first may retain information that would otherwise be lost. Capture can still fail.

BAR1 is the PCI memory window used to expose GPU memory to the host. Restoring its previous size aims to preserve the earlier mapping after rediscovery, rather than impose a new configuration. Linux documents that BAR resizing is not guaranteed to succeed.

After recovery, and when it fails

A successful nvidia-smi check means the driver can communicate with the GPU. It does not prove that rendering, memory access, or your application works correctly. Open and test your application before resuming normal use.

Logs are saved in a new timestamped directory under:

/var/log/gpu-recovery/

system.log contains the kernel and PCI information. When firmware capture is attempted, nvlog.log contains its command output and nvlog.zip may contain the captured firmware data. Incomplete output is kept for inspection. Review logs for identifying information before posting them publicly; nothing is uploaded automatically.

If recovery fails, the script reports the failed step. On handled errors or interruptions, it attempts to restore slot power when needed and resume udev processing. Services may remain stopped; their names are printed. An unresponsive kernel or failed firmware transition can still require a reboot or full shutdown. Do not force the script past a failed safety check.

NVIDIA defines Xid 79 as the driver being unable to reach the GPU over PCIe. That symptom can have different causes. A successful recovery does not diagnose or repair the original fault, and this workaround is not a guarantee of compatibility across motherboards.

Windows helper: separate and untested

The ZIP includes gpu-restart-windows.ps1. It requests a Windows device restart using Microsoft's pnputil /restart-device. It does not implement the Linux ACPI power-cycle and has not been tested.

On Windows 10 version 2004 or newer, including Windows 11, open Windows PowerShell as Administrator and identify the adapter:

Get-PnpDevice -Class Display | Format-List FriendlyName, InstanceId, Status

Copy the NVIDIA adapter's full InstanceId into $GpuInstanceId at the top of the helper. Save your work, close GPU applications, and run it from its extracted folder:

.\gpu-restart-windows.ps1

Windows may still require a reboot; the helper does not initiate one automatically. A reported device status of OK is not an application test.

Reporting results

Successes and failures both help establish compatibility. Include your GPU model, motherboard and BIOS version, Linux kernel and NVIDIA driver versions, whether automatic detection worked, the last recovery message, and whether an actual application worked afterward. Attach relevant logs after reviewing them for private information.

For the underlying crash discussion, see [ NVIDIA issue #1151.](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1151)
