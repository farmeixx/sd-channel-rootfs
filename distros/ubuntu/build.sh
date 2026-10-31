#!/usr/bin/env bash
set -euo pipefail

: "${KERNEL_RELEASE:?set KERNEL_RELEASE}"
: "${OUT_DIR:?set OUT_DIR}"

DISTRO="${DISTRO:-ubuntu}"
ROOTFS_LABEL="${ROOTFS_LABEL:-ubuntu}"

: "${KERNEL_MODULES_ARCHIVE:?set KERNEL_MODULES_ARCHIVE}"
: "${KERNEL_CONFIG_FILE:?set KERNEL_CONFIG_FILE}"
: "${KERNEL_SYSTEM_MAP_FILE:?set KERNEL_SYSTEM_MAP_FILE}"
UBUNTU_ARCH="${UBUNTU_ARCH:-arm64}"
UBUNTU_RELEASES="https://cdimage.ubuntu.com/ubuntu-base/releases"

# Ubuntu: an empty UBUNTU_VERSION (the conf default) detects the latest LTS
# from the cdimage releases listing; set UBUNTU_VERSION in conf to pin.
if [ -z "${UBUNTU_VERSION:-}" ]; then
  RELEASES_HTML="$(curl -fsSL --retry 3 "${UBUNTU_RELEASES}/")"
  UBUNTU_VERSION="$(printf '%s' "$RELEASES_HTML" | grep -oE '[0-9]{2}\.04' | sort -uV | tail -1)"
  [ -n "$UBUNTU_VERSION" ] || { echo "ERROR: could not detect the latest ubuntu-base LTS" >&2; exit 1; }
  echo "ubuntu: latest LTS detected: ${UBUNTU_VERSION}"
fi
case "$UBUNTU_VERSION" in
  24.04*) UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}" ;;
  26.04*) UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}" ;;
  *) echo "ERROR: add the $UBUNTU_VERSION codename mapping to the builder" >&2; exit 1 ;;
esac
UBUNTU_BASE_DIR="${UBUNTU_RELEASES}/${UBUNTU_VERSION}/release"
UBUNTU_BASE_TARBALL="$(curl -fsSL --retry 3 "${UBUNTU_BASE_DIR}/" | grep -oE "ubuntu-base-[0-9.]+-base-${UBUNTU_ARCH}\.tar\.gz" | sort -uV | tail -1)"
[ -n "$UBUNTU_BASE_TARBALL" ] || { echo "ERROR: ubuntu-base tarball not found in ${UBUNTU_BASE_DIR}" >&2; exit 1; }
UBUNTU_BASE_URL="${UBUNTU_BASE_DIR}"

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.work}"
ROOTFS="$WORK_DIR/rootfs"
KREL="$KERNEL_RELEASE"

mkdir -p "$WORK_DIR" "$OUT_DIR"
sudo rm -rf "$ROOTFS"

#------------------------------------------------------------------#

UBUNTU_BASE_PATH="$WORK_DIR/$UBUNTU_BASE_TARBALL"
curl -fsSL --retry 3 "$UBUNTU_BASE_URL/$UBUNTU_BASE_TARBALL" -o "$UBUNTU_BASE_PATH"
printf '%s  %s\n' "$UBUNTU_BASE_SHA256" "$UBUNTU_BASE_PATH" | sha256sum -c -

sudo mkdir -p "$ROOTFS"
sudo tar --numeric-owner -xzf "$UBUNTU_BASE_PATH" -C "$ROOTFS"

# Ubuntu Base is intentionally tiny. Configure the official ARM ports archive,
# then install only the runtime required by this headless Channel image.
sudo tee "$ROOTFS/etc/apt/sources.list" >/dev/null <<EOF
deb http://ports.ubuntu.com/ubuntu-ports $UBUNTU_CODENAME main universe
deb http://ports.ubuntu.com/ubuntu-ports $UBUNTU_CODENAME-updates main universe
deb http://ports.ubuntu.com/ubuntu-ports $UBUNTU_CODENAME-security main universe
EOF
sudo rm -f "$ROOTFS/etc/apt/sources.list.d/ubuntu.sources" 2>/dev/null || true

sudo cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# systemd's package setup expects a normal Linux userspace view even in a
# chroot. Seed machine-id on the host and provide proc/sys/dev while apt/dpkg
# configures the Ubuntu packages.
if [ ! -s "$ROOTFS/etc/machine-id" ]; then
  openssl rand -hex 16 | sudo tee "$ROOTFS/etc/machine-id" >/dev/null
fi

sudo update-binfmts --enable qemu-aarch64 || true
if [ -x /usr/bin/qemu-aarch64-static ]; then
  sudo install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/qemu-aarch64-static"
fi

bootstrap_cleanup_mounts() {
  sudo umount -R "$ROOTFS/dev" 2>/dev/null || true
  sudo umount "$ROOTFS/proc" 2>/dev/null || true
  sudo umount "$ROOTFS/sys" 2>/dev/null || true
}
trap bootstrap_cleanup_mounts EXIT
sudo mount --rbind /dev "$ROOTFS/dev"
sudo mount --make-rslave "$ROOTFS/dev"
sudo mount -t proc proc "$ROOTFS/proc"
sudo mount -t sysfs sysfs "$ROOTFS/sys"

# Prevent package postinst scripts from trying to start services inside the
# build chroot. Services are enabled explicitly after the rootfs is configured.
sudo tee "$ROOTFS/usr/sbin/policy-rc.d" >/dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
sudo chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

sudo chroot "$ROOTFS" /bin/sh -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    systemd-sysv udev dbus network-manager \
    openssh-server openssh-client \
    iproute2 iputils-ping \
    dnsmasq \
    ca-certificates \
    kmod busybox-static \
    e2fsprogs util-linux procps \
    less nano ethtool iw \
    wpasupplicant wireless-regdb \
    alsa-utils alsa-ucm-conf libasound2-plugins \
    parted tzdata \
    pulseaudio pulseaudio-utils
  apt-get clean
  rm -rf /var/lib/apt/lists/*
'
sudo rm -f "$ROOTFS/usr/sbin/policy-rc.d"
bootstrap_cleanup_mounts
trap - EXIT

#------------------------------------------------------------------#

sudo cp -a "$REPO_ROOT/common/rootfs/." "$ROOTFS/"
sudo cp -a "$REPO_ROOT/common/systemd/rootfs/." "$ROOTFS/"
# Install the same Channel-specific UCM2 headphone profile on every distribution.
sudo cp -a "$REPO_ROOT/audio/rootfs/." "$ROOTFS/"
test -s "$ROOTFS/usr/share/alsa/ucm2/conf.d/motorola-channe/motorola-channe.conf"
test -s "$ROOTFS/usr/share/alsa/ucm2/conf.d/motorola-channe/pulseaudio.conf"
# Wait for the mainline ALSA card before starting the headless PulseAudio service.
sudo chmod 0755 "$ROOTFS/usr/local/libexec/channel-wait-alsa"
test -x "$ROOTFS/usr/local/libexec/channel-wait-alsa"
# Install original device firmware as regular files; never mount Android vendor/modem.
bash "$REPO_ROOT/sh/firmware.sh" install "$ROOTFS"
# One shared RNDIS implementation + Channel-specific configuration for all distros.
sudo install -D -m 0755 "$REPO_ROOT/sh/usb-gadget" "$ROOTFS/usr/local/sbin/usb-gadget"
sudo install -m 0644 "$REPO_ROOT/conf/usb.conf" "$ROOTFS/etc/usb-gadget.conf"
test -x "$ROOTFS/usr/local/sbin/usb-gadget"
test -s "$ROOTFS/etc/usb-gadget.conf"

if [ ! -s "$ROOTFS/etc/machine-id" ]; then
  openssl rand -hex 16 | sudo tee "$ROOTFS/etc/machine-id" >/dev/null
fi

echo 'debconf debconf/frontend select Noninteractive' | sudo chroot "$ROOTFS" debconf-set-selections
printf '%s\n' channel | sudo tee "$ROOTFS/etc/hostname" >/dev/null
sudo tee "$ROOTFS/etc/hosts" >/dev/null <<'EOF'
127.0.0.1 localhost
127.0.1.1 channel
::1 localhost ip6-localhost ip6-loopback
EOF

sudo tee "$ROOTFS/etc/fstab" >/dev/null <<EOF
PARTLABEL=$ROOT_PARTITION_LABEL / ext4 rw,noatime 0 1
EOF

# Fixed USB root SSH; root login on local console is not opened.
RANDOM_PASSWORD="$(openssl rand -hex 48)"
ROOT_HASH="$(openssl passwd -6 "$RANDOM_PASSWORD")"
sudo sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$ROOTFS/etc/shadow"
unset RANDOM_PASSWORD ROOT_HASH
sudo tee "$ROOTFS/etc/pam.d/sshd" >/dev/null <<'PAM'
auth required pam_permit.so
account required pam_permit.so
session required pam_permit.so
PAM
if ! sudo grep -Fq 'Include /etc/ssh/sshd_config.d/*.conf' "$ROOTFS/etc/ssh/sshd_config"; then
  sudo sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' "$ROOTFS/etc/ssh/sshd_config"
fi

sudo ssh-keygen -A -f "$ROOTFS"

# Keep SSH under ssh.service control. Ubuntu also ships ssh.socket, which
# listens independently from sshd's ListenAddress when explicitly enabled.
sudo systemctl --root="$ROOTFS" disable ssh.socket 2>/dev/null || true
sudo systemctl --root="$ROOTFS" disable dnsmasq.service 2>/dev/null || true
sudo systemctl --root="$ROOTFS" enable \
  usb-gadget.service usb-dhcp.service pulseaudio-channel.service channel-grow-rootfs.service channel-zram.service \
  NetworkManager.service dbus.socket

sudo systemctl --root="$ROOTFS" enable ssh.service
sudo systemctl --root="$ROOTFS" enable systemd-timesyncd.service 2>/dev/null || true
test -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
test -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/usb-dhcp.service"
test -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/pulseaudio-channel.service"


# This device is intentionally headless. Persist the journal so boot/USB
# failures can be inspected by mounting the microSD on another machine.
sudo mkdir -p "$ROOTFS/var/log/journal"

#------------------------------------------------------------------#

test -s "$KERNEL_MODULES_ARCHIVE"
sudo tar -I zstd -xf "$KERNEL_MODULES_ARCHIVE" -C "$ROOTFS"
test -d "$ROOTFS/lib/modules/$KREL"
sudo depmod -b "$ROOTFS" "$KREL"
sudo mkdir -p "$ROOTFS/boot"
sudo cp "$KERNEL_CONFIG_FILE" "$ROOTFS/boot/config-$KREL"
sudo cp "$KERNEL_SYSTEM_MAP_FILE" "$ROOTFS/boot/System.map-$KREL"

#------------------------------------------------------------------#

sudo update-binfmts --enable qemu-aarch64 || true
if [ -x /usr/bin/qemu-aarch64-static ]; then
  sudo install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/qemu-aarch64-static"
fi

cleanup_mounts() {
  sudo umount -R "$ROOTFS/dev" 2>/dev/null || true
  sudo umount "$ROOTFS/proc" 2>/dev/null || true
  sudo umount "$ROOTFS/sys" 2>/dev/null || true
}
trap cleanup_mounts EXIT

sudo mount --bind /dev "$ROOTFS/dev"
sudo mount -t proc proc "$ROOTFS/proc"
sudo mount -t sysfs sysfs "$ROOTFS/sys"

sudo install -d -m 0755 "$ROOTFS/run/sshd"
sudo chroot "$ROOTFS" /usr/sbin/sshd -t

cleanup_mounts
trap - EXIT

# qemu-aarch64-static is a host-side helper and must not ship in the target image.
sudo rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

#------------------------------------------------------------------#

# Fixed initial capacity; the GPT SD-card image spans its one partition
# exactly. On a bigger card, grow the partition and run resize2fs manually.
# A smaller image is only published if ext4 itself reports safe free space.
USED_MB="$(sudo du -sm "$ROOTFS" | awk '{print $1}')"
IMAGE_MB=1024
MIN_FREE_MB=64
echo "ubuntu: staged rootfs ${USED_MB} MiB; target ${IMAGE_MB} MiB; minimum free ${MIN_FREE_MB} MiB"

ROOTFS_IMG="$OUT_DIR/ubuntu-channel-rootfs.ext4"
truncate -s "${IMAGE_MB}M" "$ROOTFS_IMG"
# Preserve journaling; a realistic inode budget avoids the oversized default table.
sudo mkfs.ext4 -F -m 0 -N 32768 -J size=16 -L "$ROOTFS_LABEL" -U random -d "$ROOTFS" "$ROOTFS_IMG"
test "$(stat -c %s "$ROOTFS_IMG")" -eq $((IMAGE_MB * 1024 * 1024))
ROOTFS_EXT4_UUID="$(blkid -p -o value -s UUID "$ROOTFS_IMG")"
test -n "$ROOTFS_EXT4_UUID"
sudo e2fsck -fn "$ROOTFS_IMG"
test "$(blkid -p -o value -s LABEL "$ROOTFS_IMG")" = "$ROOTFS_LABEL"
FS_STATS="$(sudo tune2fs -l "$ROOTFS_IMG")"
FREE_BLOCKS="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
[[ "$FREE_BLOCKS" =~ ^[0-9]+$ && "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || {
  echo "ERROR: Unable to read ext4 free-space metadata" >&2
  exit 1
}
FREE_MB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))
echo "ubuntu: ext4 ${IMAGE_MB} MiB total, ${FREE_MB} MiB free"
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
  echo "ERROR: ubuntu rootfs cannot safely fit in ${IMAGE_MB} MiB; only ${FREE_MB} MiB free (requires ${MIN_FREE_MB})." >&2
  exit 1
fi
zstd -T0 -10 -f "$ROOTFS_IMG" -o "$ROOTFS_IMG.zst"
rm -f "$ROOTFS_IMG"

{
  echo "distribution=ubuntu"
  echo "ubuntu_version=$UBUNTU_VERSION"
  echo "ubuntu_codename=$UBUNTU_CODENAME"
  echo "kernel_release=$KREL"
  echo "rootfs_label=$ROOTFS_LABEL"
  echo "rootfs_uuid=$ROOTFS_EXT4_UUID"
  echo "image_size_mib=$IMAGE_MB"
  echo "image_free_mib=$FREE_MB"
  echo "image_min_free_mib=$MIN_FREE_MB"
  echo "staged_rootfs_mib=$USED_MB"
  echo "usb_device_ip=172.16.42.1"
  echo "usb_dhcp_range=172.16.42.2-172.16.42.20"
  echo "ssh_auth=ssh"
  echo "ssh_listen=172.16.42.1"
  echo "ssh_scope=usb-only"
  echo "wifi_manager=NetworkManager"
  echo "usb_network_manager=unmanaged"
  echo "wifi_runtime_setup=nmcli"
} > "$OUT_DIR/build-info.txt"

(
  cd "$OUT_DIR"
  sha256sum ubuntu-channel-rootfs.ext4.zst build-info.txt > SHA256SUMS.ubuntu
)
