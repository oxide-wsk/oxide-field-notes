# Oracle Linux 8 and later on Oxide

This note walks through a path for taking an Oracle Linux 8, 9 or 10 install ISO and deploying it as an Oxide instance with working networking and SSH (via cloud-init key injection). In order to follow this, you need to have access to the ISO ([available from Oracle](https://yum.oracle.com/oracle-linux-isos.html)).

Tested end to end on a real rack with Oracle Linux 10.2. Oracle Linux 8.10 and 9.8 have been tested in a local UEFI virtual machine with NVMe disks, not yet on a rack. For Oracle Linux 7, see [ol7.md](ol7.md).

## Why is this necessary?

Oxide guests boot UEFI and provide a serial console for local administration. They have no VGA or VNC console. Oracle's installer menu isn't visible over serial and a stock install has no cloud-init. This mismatch is frustrating and leaves you without a clean way to set up a new instance out of the box.

What we will do below is remaster the stock ISO with small changes that:

1. Enable a serial console for compatibility with the Oxide management console and CLI console commands.
2. Embed a kickstart file (`ks-ol8plus.cfg`) that runs the install unattended, turns on DHCP at boot, uses plain partitions so the root filesystem can grow, and installs `cloud-init`, so SSH keys and first-boot setup come from the instance's user data instead of hand configuration in anaconda through the serial console.

The kickstart also deals with three things that changed after Oracle Linux 7:

- The ISO is attached as an NVMe disk rather than an optical drive, and Anaconda can't find packages on it via `cdrom`. The kickstart names the ISO's filesystem by its label instead.
- On newer kernels NVMe devices aren't named in attach order, so `nvme1n1` isn't reliably the blank disk. The kickstart finds the one NVMe disk that isn't the installer, and stops if it finds anything other than exactly one.
- The network profile Anaconda writes is tied to the NIC's name during the install, and that name changes once the installer disk is detached. The kickstart replaces it with a DHCP profile that matches any Ethernet NIC.

## Prep Work

- Download the DVD ISO for your release from Oracle and verify its checksum against Oracle's published value. Tested images:

  | Release | ISO | Volume label |
  | --- | --- | --- |
  | 8.10 | `OracleLinux-R8-U10-x86_64-dvd.iso` | `OL-8-10-0-BaseOS-x86_64` |
  | 9.8 | `OracleLinux-R9-U8-x86_64-dvd.iso` | `OL-9-8-0-BaseOS-x86_64` |
  | 10.2 | `OracleLinux-R10-U2-x86_64-dvd.iso` | `OL-10-2-0-BaseOS-x86_64` |

- Workstation setup:
  - On macOS: `brew install xorriso mtools gnu-sed`. GNU sed must be the `sed` on your PATH.
  - On Linux, xorriso and mtools from your package manager.
  - The `oxide` CLI authenticated to the silo and project you will use, and an SSH public key.
  - Scratch space a little larger than the stock ISO (12 to 17 GB).

## 1. Build the ISO

```
./build-iso.sh --input OracleLinux-R10-U2-x86_64-dvd.iso --output ol10-oxide-ks.iso
```

The script reads the release from the ISO's volume label, patches `grub.cfg` everywhere it exists (on the ISO, in the nested EFI image and, on OL10, in a hidden copy of that image), embeds the kickstart as `/ks.cfg` and keeps the original boot records. It fails if the patch doesn't apply or the release isn't one it knows. To change what gets installed, edit `ks-ol8plus.cfg` before running it.

## 2. Upload the ISO and create a blank target disk

```
oxide disk import --project PROJECT --disk ol10-installer \
  --description "OL10.2 kickstart installer" --path ol10-oxide-ks.iso
```

These ISOs are 12 to 17 GB, and the upload can take an hour or more. It has to stay connected until it finishes, so keep your workstation awake.

Then create a blank disk to install onto. The request body (`target.json`) should look like this:

```
{
  "name": "ol10-target",
  "description": "OL10 install target",
  "size": 21474836480,
  "disk_backend": {
    "type": "distributed",
    "disk_source": { "type": "blank", "block_size": 4096 }
  }
}
```

```
oxide disk create --project PROJECT --json-body target.json
```

Name the installer disk something that can't be confused with the target. Size the target for the OS (20 GiB was enough for the base install); the root filesystem can be grown later.

## 3. Create the instance and run the installer

Put your SSH key in a cloud-config file. Oxide builds a small CIDATA volume from it (it appears in the guest as a tiny `/dev/vda`), and cloud-init reads it on the installed system's first boot. The installer ignores it.

```
#cloud-config
users:
  - name: admin
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... you@example
ssh_pwauth: false
```

Create one instance with both disks attached, the cloud-config base64-encoded in `user_data`, and an ephemeral external IP. `instance.json` should look like this:

```
{
  "name": "ol10",
  "description": "OL10.2 from kickstart",
  "hostname": "ol10",
  "memory": 4294967296,
  "ncpus": 2,
  "disks": [
    { "type": "attach", "name": "ol10-installer" },
    { "type": "attach", "name": "ol10-target" }
  ],
  "network_interfaces": { "type": "default_ipv4" },
  "external_ips": [
    { "type": "ephemeral", "pool_selector": { "ip_version": "v4", "type": "auto" } }
  ],
  "user_data": "<base64 of the cloud-config>",
  "start": true
}
```

```
oxide instance create --project PROJECT --json-body instance.json
```

The blank target has no bootloader, so the instance boots the installer. Watch progress while the instance is running (the serial history is unavailable once it stops):

```
oxide instance serial history --project PROJECT --instance ol10 \
  --max-bytes 1048576 --json | jq -r '.data | implode'
```

Early on, look for a line like `ks-pre: installer /dev/nvme0n1, target candidates: /dev/nvme1n1`. That is the kickstart choosing the disk to wipe. The installer powers the guest off when it finishes. A run that fails stays at an Anaconda prompt and does not power off. For an interactive view use `oxide instance serial console`.

## 4. Detach the installer and boot

Once the instance has stopped:

```
oxide instance disk detach --project PROJECT --instance ol10 --disk ol10-installer
oxide instance start --project PROJECT --instance ol10
```

`ol10-target` is now the operating system. Keep `ol10-installer` to build more instances, or delete it.

## 5. Verify

On the serial console you should see, without any manual steps: the GRUB menu, the NIC taking an address from DHCP, cloud-init finishing with `DataSourceNoCloud`, and a login prompt. Then `ssh admin@<external-ip>`. On the guest, `sudo cloud-init status` should report `done`.

The NIC has a predictable name rather than `eth0` (for example `enp0s8`). The installed system boots Oracle's UEK kernel by default.

Turning the result into a reusable image needs an extra sealing step and isn't covered here. A snapshot taken as-is gives every clone the same `machine-id`.

## Troubleshooting

If the instance isn't reachable for some reason...

1. In the instance, via the serial console:
   1. Does the NIC have an `inet` address and a default route (`ip a`, `ip route`; `ip` lives in `/usr/sbin` and may not be on an unprivileged PATH)? No address means the guest never asked for one. `nmcli connection show` should list `oxide-dhcp` or a profile cloud-init wrote for the NIC. `sudo nmcli device connect enp0s8` (substitute your NIC's name) brings it up. OL10 has no `dhclient`.
   2. Are the host firewall and sshd configured for you to connect? Is your key in `authorized_keys` ?
2. Rack side, at the project level: is the external IP attached? Does the instance have a VPC network interface, and does the VPC firewall allow the inbound traffic? The default VPC rules allow inbound ICMP and TCP/22 only; consider narrowing `allow-ssh` to the source ranges you actually use.

On an Oxide rack with VPC networking, an instance only ever sees its private IP address (for example 172.30.0.x/32), with the default route and subnet routes delivered by DHCP. The external IP is translated to that private address on the sled hosting the instance, after the VPC firewall rules are applied, so the public address never appears in the guest.
