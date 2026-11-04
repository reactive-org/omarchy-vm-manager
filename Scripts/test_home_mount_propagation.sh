#!/bin/bash
# Opt-in Linux mount regression: private container mounts, no host volumes.
set -euo pipefail
docker run --rm --network none --privileged --entrypoint /bin/bash \
  "${GUEST_BUILDER_IMAGE:-try-omarchy-guest-builder}" -c '
set -euo pipefail
mkdir -p /run/home-poc/staging /mnt/home-poc
mount --bind /run/home-poc /run/home-poc
mount --make-shared /run/home-poc
mount -t tmpfs -o nosuid,nodev tmpfs /run/home-poc/staging
mount -t tmpfs tmpfs /mnt/home-poc
if mount --move /run/home-poc/staging /mnt/home-poc >/tmp/move.log 2>&1; then
  echo "Expected MS_MOVE below a shared parent to fail" >&2; exit 1
fi
mount --bind /run/home-poc/staging /mnt/home-poc
umount /run/home-poc/staging
findmnt -n -o OPTIONS --mountpoint /mnt/home-poc | grep -q nosuid,nodev
umount /mnt/home-poc
umount /mnt/home-poc
umount /run/home-poc
echo "Shared-parent home bind mount: PASS"
truncate -s 128M /tmp/home-growth.img
mkfs.ext4 -q -F -b 4096 /tmp/home-growth.img
sleep 2
loop=$(losetup --find --show /tmp/home-growth.img)
trap '\''umount /mnt/home-poc 2>/dev/null || true; losetup -d "$loop" 2>/dev/null || true'\'' EXIT
mount -t ext4 "$loop" /mnt/home-poc
printf "synthetic growth fixture\n" >/mnt/home-poc/fixture
sha256sum /mnt/home-poc/fixture >/tmp/growth.sha
umount /mnt/home-poc
losetup -d "$loop"
truncate -s 192M /tmp/home-growth.img
loop=$(losetup --find --show /tmp/home-growth.img)
status=0; e2fsck -p "$loop" || status=$?
((status <= 1))
if resize2fs "$loop" >/tmp/resize.log 2>&1; then
  echo "Expected offline growth to require a full filesystem check" >&2; exit 1
fi
status=0; e2fsck -p -f "$loop" || status=$?
((status <= 1))
resize2fs "$loop"
mount -t ext4 "$loop" /mnt/home-poc
sha256sum -c /tmp/growth.sha
umount /mnt/home-poc
losetup -d "$loop"
trap - EXIT
echo "Forced preen before growth preserves data: PASS"
'
