# Enterprise Linux on Oxide

Notes for getting Red Hat-family distributions onto Oxide from their install DVDs, one directory per distribution:

| Distribution | Releases tested |
| --- | --- |
| [Oracle Linux](oracle-linux/) | 7.9 and 10.2 on a real rack; 8.10 and 9.8 in local qemu |

The Oracle Linux note solves problems that come from Oxide and from Anaconda, not from Oracle, so most of it should carry over to RHEL, Rocky Linux and AlmaLinux. None of those has been tested yet. What should carry over:

- Oxide guests are UEFI-only with a serial console and no VGA, so the installer's GRUB menu has to be switched to serial on the ISO itself.
- The ISO is attached as an NVMe disk, not an optical drive. From EL8 on, the kickstart has to name the install source by filesystem label (`harddrive --partition=LABEL=...`) rather than `cdrom`.
- NVMe device names don't follow attach order on newer kernels, so the kickstart should find the target disk rather than assume `nvme1n1`.
- The NIC is renamed once the installer disk is detached, so the network profile Anaconda writes should be replaced with one that matches any Ethernet NIC.
- cloud-init reads keys and user data from Oxide's NoCloud CIDATA volume. Check each distribution's `cloud.cfg` for `ssh_deletekeys` before turning an install into an image; Oracle ships it off.
- EL10 requires x86-64-v3 CPU features. Oxide guests expose them (AVX2 confirmed with OL10.2).

What will differ is mostly in `build-iso.sh`: the volume labels it recognizes, the GRUB menu entry text it rewrites, and where each distribution keeps its EFI boot image.
