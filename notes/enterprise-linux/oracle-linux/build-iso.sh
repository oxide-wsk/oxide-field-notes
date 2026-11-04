#!/usr/bin/env bash
# Remaster a stock Oracle Linux 7.9, 8.x, 9.x or 10.x install ISO for Oxide: serial
# console on all GRUB copies and an embedded kickstart (ks.cfg for OL7,
# ks-ol8plus.cfg for OL8 and later) that installs cloud-init.
# Operators run this against an ISO they downloaded from Oracle themselves.
#
# Prereqs (macOS): brew install xorriso mtools
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: build-iso.sh --input STOCK.iso --output OUT.iso [--target-disk nvme1n1] [--json]

--target-disk applies to OL7 only; the OL8+ kickstart picks the disk itself.
EOF
}

input=""
output=""
target_disk="nvme1n1"
json=false
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while (($#)); do
	case "$1" in
	--input)
		input="$2"
		shift 2
		;;
	--output)
		output="$2"
		shift 2
		;;
	--target-disk)
		target_disk="$2"
		shift 2
		;;
	--json)
		json=true
		shift
		;;
	--help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done
[[ -n "$input" && -n "$output" ]] || {
	usage >&2
	exit 2
}
sed --version 2>/dev/null | grep --quiet GNU || {
	echo "GNU sed required (brew install gnu-sed)" >&2
	exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/build-iso.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# GRUB refers to the volume by label with spaces escaped as \x20 (OL7 has
# them, OL8+ does not). Doubled backslash because it lands in a sed pattern.
volid="$(xorriso -indev "$input" -pvd_info 2>/dev/null | sed --quiet 's/^Volume Id *: //p')"
label="${volid// /\\\\x20}"
case "$volid" in
OL-7.*) kickstart="$here/ks.cfg" ;;
OL-8-* | OL-9-* | OL-10-*) kickstart="$here/ks-ol8plus.cfg" ;;
*)
	echo "unsupported ISO volume id: '$volid'" >&2
	exit 1
	;;
esac

xorriso -osirrox on -indev "$input" \
	-extract /EFI/BOOT/grub.cfg "$work/grub.cfg" \
	-extract /images/efiboot.img "$work/efiboot.img" >/dev/null
chmod u+w "$work/grub.cfg" "$work/efiboot.img"

# Same edits as OL7-SERIAL-ISO-ON-OXIDE.md, plus inst.ks pointing at the
# kickstart embedded on the ISO itself.
sed --in-place \
	--expression 's/^set default="1"/set default="0"/' \
	--expression 's/^set gfxpayload=keep/set gfxpayload=text/' \
	--expression 's/^set timeout=60/insmod serial\nserial --unit=0 --speed=115200\nterminal_input serial\nterminal_output serial\n\nset timeout=5/' \
	--expression "s/^menuentry 'Install Oracle Linux \([0-9.]*\)'/menuentry 'Install Oracle Linux \1 (serial console, kickstart)'/" \
	--expression "0,/inst.stage2=hd:LABEL=${label} quiet/s//inst.stage2=hd:LABEL=${label} inst.ks=hd:LABEL=${label}:\/ks.cfg console=tty0 console=ttyS0,115200n8 inst.text quiet/" \
	"$work/grub.cfg"
grep --quiet 'inst.ks=' "$work/grub.cfg" || {
	echo "grub.cfg patch did not apply" >&2
	exit 1
}

# The UEFI path boots from a nested FAT image with its own grub.cfg. Patch in
# place with mtools; rebuilding it with hdiutil adds an MBR the original lacks.
mdel -i "$work/efiboot.img" ::/EFI/BOOT/grub.cfg
mcopy -i "$work/efiboot.img" "$work/grub.cfg" ::/EFI/BOOT/grub.cfg

sed --expression "s/__TARGET_DISK__/${target_disk}/g" \
	--expression "s/__ISO_LABEL__/${volid}/g" "$kickstart" >"$work/ks.cfg"

# OL8+ ISOs also carry the EFI image as a hidden GPT partition, and that copy
# is the one firmware boots. Replay would copy Oracle's bytes, so replace it.
efi_part=()
if xorriso -indev "$input" -report_el_torito as_mkisofs 2>/dev/null | grep --quiet '^-append_partition 2 '; then
	efi_part=(-append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$work/efiboot.img")
fi

# xorriso refuses to write over an existing image with a cryptic error.
rm -f "$output"
xorriso -indev "$input" -outdev "$output" \
	-boot_image any replay \
	${efi_part[@]+"${efi_part[@]}"} \
	-map "$work/grub.cfg" /EFI/BOOT/grub.cfg \
	-map "$work/efiboot.img" /images/efiboot.img \
	-map "$work/ks.cfg" /ks.cfg \
	-commit >/dev/null

size="$(wc -c <"$output" | tr -d " ")"
if $json; then
	printf '{"output":"%s","bytes":%s,"target_disk":"%s"}\n' "$output" "$size" "$target_disk"
else
	echo "wrote $output ($size bytes), install target /dev/$target_disk"
fi
