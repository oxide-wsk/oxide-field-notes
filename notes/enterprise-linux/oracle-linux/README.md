# Oracle Linux on Oxide

Install Oracle Linux from Oracle's DVD ISO onto an Oxide instance, with a serial console, DHCP and cloud-init key injection, using a remastered ISO and an unattended kickstart.

| Guide | Releases | Tested |
| --- | --- | --- |
| [ol7.md](ol7.md) | 7.9 | Real rack |
| [ol8-plus.md](ol8-plus.md) | 8.10, 9.8, 10.2 | 10.2 on a real rack; 8.10 and 9.8 in a local UEFI VM |

Both guides use the same `build-iso.sh`, which picks `ks.cfg` (OL7) or `ks-ol8plus.cfg` (OL8 and later) from the ISO's volume label.
