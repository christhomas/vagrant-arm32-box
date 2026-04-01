#!/usr/bin/env bash
#
# build-linux.sh — Build a Debian ARM32 Vagrant box using debootstrap
#
# Runs directly on Linux (CI runner or build VM). Handles everything:
#   1. Create qcow2 disk image with ext4 filesystem
#   2. Debootstrap a fresh Debian bookworm armhf rootfs
#   3. Download QEMU-compatible kernel and extract vmlinuz + modules
#   4. Chroot to customize (vagrant user, SSH, networking, growpart)
#   5. Install kernel modules on disk for post-boot driver loading
#   6. Build initrd inside chroot with virtio drivers
#   7. Package .box file
#
# Output: ${PROJECT}/work/debian-arm32.box
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${BUILD_PROJECT:-$SCRIPT_DIR}"
WORK="/tmp/box-build"
OUTPUT="${PROJECT}/work"
NBD_DEV="/dev/nbd2"

# ─── Configuration ───────────────────────────────────────────────────────────────

DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
KERNEL_DEB_URL="http://ftp.us.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-42-armmp-lpae_6.1.159-1_armhf.deb"
DISK_SIZE="2G"

# ─── Helpers ─────────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
die()   { echo "FATAL: $*" >&2; exit 1; }

MNT_ROOT="${WORK}/mnt-root"

cleanup() {
    info "Cleaning up..."
    set +e
    pkill -9 gpg-agent 2>/dev/null || true
    sleep 1
    for mp in dev/pts dev/shm dev proc sys run; do
        umount -l "$MNT_ROOT/$mp" 2>/dev/null || true
    done
    umount -l "$MNT_ROOT" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    set -e
}
trap cleanup EXIT

# ─── Install build dependencies ──────────────────────────────────────────────────

info "Installing build dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-utils qemu-user-static binfmt-support kmod e2fsprogs \
    fdisk curl binutils xz-utils zstd python3 initramfs-tools debootstrap xxd
modprobe nbd max_part=8 || true

# Enable binfmt for cross-architecture chroot
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "armv7l" ]]; then
    info "Enabling binfmt for ARM chroot on ${HOST_ARCH}..."
    update-binfmts --enable qemu-arm 2>/dev/null || true
fi

mkdir -p "$WORK" "$OUTPUT"

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 1: Create disk image and bootstrap Debian
# ═════════════════════════════════════════════════════════════════════════════════

QCOW2="${WORK}/box.img"

info "Phase 1: Create disk image and bootstrap Debian armhf"

info "Creating ${DISK_SIZE} qcow2 image..."
qemu-img create -f qcow2 "$QCOW2" "$DISK_SIZE"

modprobe nbd max_part=8
qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 2

info "Connecting image to $NBD_DEV..."
qemu-nbd --connect="$NBD_DEV" "$QCOW2"
sleep 3

# Create partition table — single ext4 partition (no boot partition needed)
info "Creating partition table..."
echo 'type=83' | sfdisk "$NBD_DEV"
sleep 2

# Re-read partition table
qemu-nbd --disconnect "$NBD_DEV"
sleep 2
qemu-nbd --connect="$NBD_DEV" "$QCOW2"
sleep 3

for i in $(seq 1 10); do
    [[ -b "${NBD_DEV}p1" ]] && break
    sleep 1
done
[[ -b "${NBD_DEV}p1" ]] || die "Partition ${NBD_DEV}p1 did not appear"

info "Formatting ext4..."
mkfs.ext4 -q "${NBD_DEV}p1"

info "Mounting..."
mkdir -p "$MNT_ROOT"
mount "${NBD_DEV}p1" "$MNT_ROOT"

info "Running debootstrap (this takes a few minutes)..."
debootstrap --arch=armhf --foreign "$DEBIAN_RELEASE" "$MNT_ROOT" "$DEBIAN_MIRROR"

# Copy qemu-arm-static for second stage
QEMU_ARM="$(command -v qemu-arm-static)"
cp "$QEMU_ARM" "$MNT_ROOT/usr/bin/qemu-arm-static"

# Register binfmt_misc for ARM if not already registered
if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
    info "Registering binfmt_misc for ARM..."
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:F' \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
fi

info "Running debootstrap second stage..."
chroot "$MNT_ROOT" /debootstrap/debootstrap --second-stage

# Set up basic system config
echo "debian-arm32" > "$MNT_ROOT/etc/hostname"
cat > "$MNT_ROOT/etc/hosts" <<'EOF'
127.0.0.1       localhost
127.0.1.1       debian-arm32
EOF

cat > "$MNT_ROOT/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main
deb http://security.debian.org/debian-security $DEBIAN_RELEASE-security main
EOF

cat > "$MNT_ROOT/etc/fstab" <<'EOF'
/dev/vda1   /   ext4    defaults    0   1
EOF

info "Phase 1 complete."

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 2: Download QEMU-compatible kernel
# ═════════════════════════════════════════════════════════════════════════════════

KERNEL_DEB="${WORK}/kernel.deb"
KERNEL_EXTRACT="${WORK}/kernel-extract"

info "Phase 2: Download kernel"

if [[ ! -f "$KERNEL_DEB" ]]; then
    info "Downloading Debian armmp-lpae kernel..."
    curl -fsSL -o "$KERNEL_DEB" "$KERNEL_DEB_URL"
fi

rm -rf "$KERNEL_EXTRACT"
mkdir -p "$KERNEL_EXTRACT"
(cd "$KERNEL_EXTRACT" && ar x "$KERNEL_DEB" && tar xf data.tar.xz)

VMLINUZ=$(ls "${KERNEL_EXTRACT}"/boot/vmlinuz-*-armmp-lpae 2>/dev/null | sort -V | tail -1)
[[ -f "$VMLINUZ" ]] || die "vmlinuz not found in kernel package"

KVER=$(basename "$VMLINUZ" | sed 's/vmlinuz-//')
info "Kernel: $KVER"

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 3: Customize image via chroot
# ═════════════════════════════════════════════════════════════════════════════════

info "Phase 3: Customize image"

mount -t proc  proc  "$MNT_ROOT/proc"
mount -t sysfs sysfs "$MNT_ROOT/sys"
mount --bind /dev     "$MNT_ROOT/dev"
mount --bind /dev/pts "$MNT_ROOT/dev/pts"
mount --bind /run     "$MNT_ROOT/run"

cp /etc/resolv.conf "$MNT_ROOT/etc/resolv.conf"

# Install essential packages inside the chroot
chroot "$MNT_ROOT" /bin/bash -e <<'PKGEOF'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update -qq
apt-get install -y -qq sudo openssh-server systemd-sysv cloud-guest-utils \
    ifupdown net-tools iproute2 iputils-ping
PKGEOF

info "Running chroot customization..."
cp "${PROJECT}/chroot-debian.sh" "$MNT_ROOT/tmp/chroot-debian.sh"
chroot "$MNT_ROOT" /bin/bash /tmp/chroot-debian.sh
rm -f "$MNT_ROOT/tmp/chroot-debian.sh"

# ─── Install kernel modules on disk for post-boot driver loading ─────────────────

info "Installing kernel modules ($KVER) to disk..."
mkdir -p "$MNT_ROOT/lib/modules/${KVER}"
cp -r "${KERNEL_EXTRACT}/lib/modules/${KVER}/." "$MNT_ROOT/lib/modules/${KVER}/"

if [[ ! -f "$MNT_ROOT/lib/modules/${KVER}/kernel/drivers/block/virtio_blk.ko" ]]; then
    info "  Fixing missing virtio_blk.ko on disk..."
    mkdir -p "$MNT_ROOT/lib/modules/${KVER}/kernel/drivers/block"
    cp "${KERNEL_EXTRACT}/lib/modules/${KVER}/kernel/drivers/block/virtio_blk.ko" \
       "$MNT_ROOT/lib/modules/${KVER}/kernel/drivers/block/"
fi

chroot "$MNT_ROOT" depmod "${KVER}" 2>/dev/null || true

# ─── Build initrd inside chroot (correct architecture binaries) ──────────────────

info "Phase 4: Build initrd inside chroot"

INITRD="${WORK}/initrd.img"
CONFFILE="${KERNEL_EXTRACT}/boot/config-${KVER}"
cp "${CONFFILE}" "$MNT_ROOT/boot/config-${KVER}"

chroot "$MNT_ROOT" /bin/bash -e <<INITRDEOF
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq initramfs-tools 2>/dev/null || true

for mod in virtio virtio_ring virtio_pci virtio_blk virtio_net virtio_scsi virtiofs ext4; do
    echo "\$mod" >> /etc/initramfs-tools/modules
done

mkdir -p /etc/initramfs-tools/hooks
cat > /etc/initramfs-tools/hooks/virtio <<'HOOKEOF'
#!/bin/sh
set -e
. /usr/share/initramfs-tools/hook-functions
manual_add_modules virtio virtio_ring virtio_pci virtio_blk virtio_net virtio_scsi
HOOKEOF
chmod +x /etc/initramfs-tools/hooks/virtio

depmod -a "${KVER}"
mkinitramfs -o /tmp/initrd.img "${KVER}"
INITRDEOF

cp "$MNT_ROOT/tmp/initrd.img" "/tmp/initrd-base.img"
rm -f "$MNT_ROOT/tmp/initrd.img" "$MNT_ROOT/boot/config-${KVER}"

# ─── Patch initrd with insmod commands ───────────────────────────────────────────

info "Patching initrd with insmod commands..."
INITRD_WORK=/tmp/initrd-patch
rm -rf "$INITRD_WORK"
mkdir -p "$INITRD_WORK"
cd "$INITRD_WORK"

MAGIC=$(xxd -l 4 -p /tmp/initrd-base.img)
case "$MAGIC" in
    28b52ffd) zstd -d -c /tmp/initrd-base.img | cpio -id 2>/dev/null ;;
    1f8b*)    gzip -d -c /tmp/initrd-base.img | cpio -id 2>/dev/null ;;
    *)        cpio -id < /tmp/initrd-base.img 2>/dev/null ;;
esac

if [[ -d "${INITRD_WORK}/usr/lib/modules/${KVER}" ]]; then
    INITRD_MODPATH="usr/lib/modules/${KVER}/kernel/drivers"
else
    INITRD_MODPATH="lib/modules/${KVER}/kernel/drivers"
fi

SRCPATH="${KERNEL_EXTRACT}/lib/modules/${KVER}/kernel/drivers"
MODULES="virtio/virtio.ko virtio/virtio_ring.ko virtio/virtio_pci.ko
         virtio/virtio_pci_modern_dev.ko virtio/virtio_pci_legacy_dev.ko
         virtio/virtio_mmio.ko block/virtio_blk.ko net/virtio_net.ko"

for mod in $MODULES; do
    if [[ ! -f "${INITRD_WORK}/${INITRD_MODPATH}/${mod}" ]] && [[ -f "${SRCPATH}/${mod}" ]]; then
        info "  Injecting ${mod}"
        mkdir -p "${INITRD_WORK}/$(dirname "${INITRD_MODPATH}/${mod}")"
        cp "${SRCPATH}/${mod}" "${INITRD_WORK}/${INITRD_MODPATH}/${mod}"
    fi
done

if ! grep -q "Force-load virtio" "${INITRD_WORK}/init" 2>/dev/null; then
    python3 -c "
with open('${INITRD_WORK}/init') as f:
    content = f.read()

insmod = '''# Force-load virtio drivers for QEMU
MODBASE=/${INITRD_MODPATH}
/sbin/insmod \${MODBASE}/virtio/virtio.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_ring.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_pci_modern_dev.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_pci_legacy_dev.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_pci.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/block/virtio_blk.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/net/virtio_net.ko 2>/dev/null || true
'''

content = content.replace('load_modules', insmod + 'load_modules', 1)

with open('${INITRD_WORK}/init', 'w') as f:
    f.write(content)
"
fi

info "Repacking initrd..."
cd "$INITRD_WORK"
find . | cpio -o -H newc 2>/dev/null | zstd -f -o "$INITRD"

rm -rf /tmp/initrd-base.img "$INITRD_WORK"

# ─── Unmount ─────────────────────────────────────────────────────────────────────

info "Unmounting..."
for mp in dev/pts dev/shm dev proc sys run; do
    umount -l "$MNT_ROOT/$mp" 2>/dev/null || true
done
umount "$MNT_ROOT"
qemu-nbd --disconnect "$NBD_DEV"
sleep 2

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 5: Package .box
# ═════════════════════════════════════════════════════════════════════════════════

info "Phase 5: Package .box"

BOX_DIR="${WORK}/box-contents"
rm -rf "$BOX_DIR"
mkdir -p "$BOX_DIR"

info "Compacting qcow2..."
qemu-img convert -O qcow2 -c "$QCOW2" "$BOX_DIR/box.img"

cp "$VMLINUZ" "$BOX_DIR/vmlinuz"
cp "$INITRD"  "$BOX_DIR/initrd.img"

cat > "$BOX_DIR/metadata.json" <<'EOF'
{
  "provider": "qemu-customkernel",
  "format": "qcow2",
  "architecture": "arm"
}
EOF

cat > "$BOX_DIR/Vagrantfile" <<'VEOF'
Vagrant.configure("2") do |config|
  config.vm.provider :qemu do |qe|
    qe.arch = "arm"
    qe.machine = "virt"
    qe.cpu = "cortex-a7"
    qe.memory = "512M"

    box_dir = File.dirname(__FILE__)
    qe.extra_qemu_args = [
      "-kernel", "#{box_dir}/vmlinuz",
      "-initrd", "#{box_dir}/initrd.img",
      "-append", "root=/dev/vda1 console=ttyAMA0",
    ]
  end
end
VEOF

info "Creating .box archive..."
(cd "$BOX_DIR" && tar czf "${OUTPUT}/debian-arm32.box" metadata.json Vagrantfile box.img vmlinuz initrd.img)

BOX_SIZE=$(du -h "${OUTPUT}/debian-arm32.box" | cut -f1)
info "Box ready: ${OUTPUT}/debian-arm32.box ($BOX_SIZE)"
