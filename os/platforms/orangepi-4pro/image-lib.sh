# Shared by build-base.sh and build-image.sh: attach an SD image, mount its root partition
# and prepare a chroot with network. Source it; it sets MNT and an EXIT trap that undoes it.

MNT=$(mktemp -d)
LOOP=

release_image() {
    set +e
    if [[ -e $MNT/usr/sbin/policy-rc.d.harness ]]; then
        rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/usr/sbin/policy-rc.d.harness"
    fi
    if [[ -n $RESOLV ]]; then
        rm -f "$MNT/etc/resolv.conf"
        if [[ -e $MNT/etc/resolv.conf.harness || -L $MNT/etc/resolv.conf.harness ]]; then
            mv "$MNT/etc/resolv.conf.harness" "$MNT/etc/resolv.conf"
        fi
    fi
    for m in dev/pts dev proc sys; do mountpoint -q "$MNT/$m" && umount "$MNT/$m"; done
    mountpoint -q "$MNT" && umount "$MNT"
    [[ -n $LOOP ]] && losetup -d "$LOOP"
    rmdir "$MNT" 2>/dev/null
    LOOP=
    RESOLV=
}
RESOLV=
trap release_image EXIT

# attach_image IMAGE [GROW]: GROW (e.g. +3G) enlarges the file and its root filesystem first.
# The partition table is edited in the file and partition 1 attached by its offset, so neither
# step needs the kernel to rescan a loop device: a container (build-docker.sh) cannot.
attach_image() {
    local image=$1 grow=${2:-} start size
    if [[ -n $grow ]]; then
        truncate -s "$grow" "$image"
        parted -s "$image" resizepart 1 100%
    fi
    read -r start size < <(sfdisk -J "$image" | python3 -c '
import json, sys
table = json.load(sys.stdin)["partitiontable"]
part = table["partitions"][0]
print(part["start"] * table.get("sectorsize", 512), part["size"] * table.get("sectorsize", 512))')
    LOOP=$(losetup -f --show --offset "$start" --sizelimit "$size" "$image")
    if [[ -n $grow ]]; then
        e2fsck -fy "$LOOP" >/dev/null || true
        resize2fs "$LOOP" >/dev/null
    fi
    mount "$LOOP" "$MNT"
    for m in dev dev/pts proc sys; do mount --bind "/$m" "$MNT/$m"; done
    # Network for the chroot, and no service starts from package scripts; both undone on release.
    if [[ -e $MNT/etc/resolv.conf || -L $MNT/etc/resolv.conf ]]; then
        mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.harness"
    fi
    RESOLV=1
    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
    [[ ! -e $MNT/usr/sbin/policy-rc.d ]] || { echo 'The image already has a policy-rc.d.' >&2; return 1; }
    printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"
    chmod 755 "$MNT/usr/sbin/policy-rc.d"
    touch "$MNT/usr/sbin/policy-rc.d.harness"
}
