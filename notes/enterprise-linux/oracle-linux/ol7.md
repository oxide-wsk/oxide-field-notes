# Oracle Linux 7 on Oxide

This note walks through a path for taking an Oracle Linux 7.9 install ISO and deploying it as an Oxide instance with working networking and SSH (via cloud-init key injection). In order to follow this, you need to have access to the ISO ([available from Oracle](https://yum.oracle.com/oracle-linux-isos.html)).

Tested end to end on a real rack with Oracle Linux 7.9. For Oracle Linux 8 and later, see [ol8-plus.md](ol8-plus.md).

## Why is this necessary?

Oxide guests boot UEFI and provide a serial console for local administration. They have no VGA or VNC console. Oracle's installer menu isn't visible over serial and a stock install has no cloud-init. This mismatch is frustrating and leaves you without a clean way to set up a new instance out of the box.

What we will do below is remaster the stock ISO with small changes that:

1. Enable a serial console for compatibility with the Oxide management console and CLI console commands.
2. Embed a kickstart file (`ks.cfg`) that runs the install unattended, turns on DHCP at boot, uses plain partitions so the root filesystem can grow, and installs `cloud-init`, so SSH keys and first-boot setup come from the instance's user data instead of hand configuration in anaconda through the serial console.

## Prep Work

- Download the Oracle Linux 7.9 server DVD ISO from Oracle (`OracleLinux-R7-U9-Server-x86_64-dvd.iso`, volume label `OL-7.9 Server.x86_64`). Verify its checksum against Oracle's published value.
- Workstation setup:
  - On macOS: `brew install xorriso mtools gnu-sed`. GNU sed must be the `sed` on your PATH.
  - On Linux, xorriso and mtools from your package manager.
  - The `oxide` CLI authenticated to the silo and project you will use, and an SSH public key.
  - About 5 GB of scratch space for the remastered ISO.

## 1. Build the ISO

```
./build-iso.sh --input OracleLinux-R7-U9-Server-x86_64-dvd.iso \
               --output ol7-oxide-ks.iso --target-disk nvme1n1
```

The script patches `grub.cfg` in both places it exists (on the ISO and in the nested EFI image), embeds `ks.cfg` and keeps the original boot records. It fails if the patch doesn't apply. `--target-disk` is the device the installer wipes; see step 3 for why `nvme1n1`. To change what gets installed, edit `ks.cfg` before running it.

## 2. Upload the ISO and create a blank target disk

```
oxide disk import --project PROJECT --disk ol7-installer \
  --description "OL7.9 kickstart installer" --path ol7-oxide-ks.iso
```

The upload may take as long as 15 to 20 minutes.

Then create a blank disk to install onto. You can use a file to pre-fill the various configurable values and then just pass that to the CLI. That file (`target.json`) should look like this:

```
{
  "name": "ol7-target",
  "description": "OL7 install target",
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

Name the installer disk something that can't be confused with the target disk that will have the root file system of your actual VM instance. Size the target for the OS (20 GiB was enough for the base install); the root filesystem can be grown later.

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

Create your new instance with the two disks attached (installer first, target OS disk second), the cloud-config base64-encoded in `user_data`, and an ephemeral external IP. We'll use a file again (`instance.json`) to keep things clean, which should look like this:

```
{
  "name": "ol7",
  "description": "OL7.9 from kickstart",
  "hostname": "ol7",
  "memory": 4294967296,
  "ncpus": 2,
  "disks": [
    { "type": "attach", "name": "ol7-installer" },
    { "type": "attach", "name": "ol7-target" }
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

The blank target has no bootloader, so the instance boots the installer. The installer disk is the first NVMe device (`nvme0n1`) and the target is the second (`nvme1n1`), which is why the kickstart file in this repo uses `nvme1n1` as the default disk.

Watch progress while the instance is running (the serial history is unavailable once it stops):

```
oxide instance serial history --project PROJECT --instance ol7 \
  --max-bytes 1048576 --json | jq -r '.data | implode'
```

The installer powers the guest off when it finishes, about 7 minutes after start. A run that fails stays at an Anaconda prompt and does not power off. For an interactive view use `oxide instance serial console`.

## 4. Detach the installer and boot

Once the instance has stopped:

```
oxide instance disk detach --project PROJECT --instance ol7 --disk ol7-installer
oxide instance start --project PROJECT --instance ol7
```

`ol7-target` is now the operating system. Keep `ol7-installer` to build more instances, or delete it.

## 5. Verify

On the serial console you should see, without any manual steps: the GRUB menu, `eth0` taking an address from DHCP, cloud-init finishing with `DataSourceNoCloud`, and a login prompt. Then `ssh admin@<external-ip>`. On the guest, `sudo cloud-init status` should report `done` (running it unprivileged crashes under cloud-init 19.4's Python 2; that is harmless).

Turning the result into a reusable image needs an extra sealing step and isn't covered here. A snapshot taken as-is gives every clone the same `machine-id`.

## Troubleshooting

If the instance isn't reachable for some reason...

1. In the instance, via the serial console:
   1. Does `eth0` have an `inet` address and a default route (`ip a`, `ip route`; `ip` lives in `/usr/sbin` and may not be on an unprivileged PATH)? No address means the guest never asked for one. Look at `/etc/sysconfig/network-scripts/ifcfg-eth0` for `ONBOOT=no` (this is an unhelpful default output of a manual install with the anaconda text interface). If eth0 is down or is not configured for DHCP, getting it up on the network can be as simple as turning it on with `sudo dhclient eth0`. That only lasts until the next boot; set `ONBOOT=yes` to make it stick.
   2. Are the host firewall and sshd configured for you to connect? Is your key in `authorized_keys` ?
2. Rack side, at the project level: is the external IP attached? Does the instance have a VPC network interface, and does the VPC firewall allow the inbound traffic? The default VPC rules allow inbound ICMP and TCP/22 only; consider narrowing `allow-ssh` to the source ranges you actually use.

On an Oxide rack with VPC networking, an instance only ever sees its private IP address (for example 172.30.0.x/32), with the default route and subnet routes delivered by DHCP. The external IP is translated to that private address on the sled hosting the instance, after the VPC firewall rules are applied, so the public address never appears in the guest.
