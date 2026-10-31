#!/usr/bin/env bash
set -euo pipefail

: "${KERNEL_RELEASE:?set KERNEL_RELEASE}"
: "${OUT_DIR:?set OUT_DIR}"

DISTRO="${DISTRO:-alpine}"
ROOTFS_LABEL="${ROOTFS_LABEL:-alpine}"

: "${KERNEL_MODULES_ARCHIVE:?set KERNEL_MODULES_ARCHIVE}"
: "${KERNEL_CONFIG_FILE:?set KERNEL_CONFIG_FILE}"
: "${KERNEL_SYSTEM_MAP_FILE:?set KERNEL_SYSTEM_MAP_FILE}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_ARCH="${ALPINE_ARCH:-aarch64}"
HOST_ARCH="$(uname -m)"

# Alpine version: an empty ALPINE_VERSION (the conf default) detects the
# latest stable release from the CDN's latest-stable listing; set
# ALPINE_VERSION in conf/rootfs.conf to pin a release for reproducible
# builds. The .sha256 sidecar still verifies every download.
if [ -z "${ALPINE_VERSION:-}" ]; then
  RELEASES_HTML="$(curl -fsSL --retry 3 "${ALPINE_MIRROR}/latest-stable/releases/${ALPINE_ARCH}/")"
  MINIROOTFS_FILE="$(printf '%s' "$RELEASES_HTML" | grep -oE "alpine-minirootfs-[0-9][0-9.]*-${ALPINE_ARCH}\.tar\.gz" | sort -uV | tail -1)"
  [ -n "$MINIROOTFS_FILE" ] || { echo "ERROR: could not detect the latest alpine minirootfs from ${ALPINE_MIRROR}/latest-stable" >&2; exit 1; }
  ALPINE_VERSION="${MINIROOTFS_FILE#alpine-minirootfs-}"
  ALPINE_VERSION="${ALPINE_VERSION%%-${ALPINE_ARCH}*}"
  echo "alpine: latest stable detected: ${ALPINE_VERSION}"
fi
ALPINE_BRANCH="v${ALPINE_VERSION%.*}"

# apk-tools-static: the host-side tool; detect the latest from the main
# repo listing for the host architecture.
if [ -z "${APK_TOOLS_STATIC_VERSION:-}" ]; then
  MAIN_HTML="$(curl -fsSL --retry 3 "${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${HOST_ARCH}/")"
  APK_STATIC_FILE="$(printf '%s' "$MAIN_HTML" | grep -oE "apk-tools-static-[0-9][0-9.r-]*\.apk" | sort -uV | tail -1)"
  [ -n "$APK_STATIC_FILE" ] || { echo "ERROR: could not detect the latest apk-tools-static from ${ALPINE_BRANCH}/main/${HOST_ARCH}" >&2; exit 1; }
  APK_TOOLS_STATIC_VERSION="${APK_STATIC_FILE#apk-tools-static-}"
  APK_TOOLS_STATIC_VERSION="${APK_TOOLS_STATIC_VERSION%.apk}"
  echo "alpine: apk-tools-static detected: ${APK_TOOLS_STATIC_VERSION}"
fi

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.work}"
ROOTFS="$WORK_DIR/rootfs"
KREL="$KERNEL_RELEASE"
MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
MINIROOTFS_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${MINIROOTFS}"
MINIROOTFS_PATH="$WORK_DIR/$MINIROOTFS"
MINIROOTFS_SHA_PATH="$MINIROOTFS_PATH.sha256"

mkdir -p "$WORK_DIR" "$OUT_DIR"
sudo rm -rf "$ROOTFS"
sudo mkdir -p "$ROOTFS"

#------------------------------------------------------------------#

curl -fsSL --retry 3 "$MINIROOTFS_URL" -o "$MINIROOTFS_PATH"
curl -fsSL --retry 3 "$MINIROOTFS_URL.sha256" -o "$MINIROOTFS_SHA_PATH"
(
  cd "$WORK_DIR"
  sha256sum -c "$(basename "$MINIROOTFS_SHA_PATH")"
)
sudo tar --numeric-owner -xzf "$MINIROOTFS_PATH" -C "$ROOTFS"

sudo tee "$ROOTFS/etc/apk/repositories" >/dev/null <<EOF
${ALPINE_MIRROR}/${ALPINE_BRANCH}/main
${ALPINE_MIRROR}/${ALPINE_BRANCH}/community
EOF

sudo cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
if [ -x /usr/bin/qemu-aarch64-static ]; then
  sudo install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/qemu-aarch64-static"
fi

APK_STATIC_PKG="$WORK_DIR/apk-tools-static-$APK_TOOLS_STATIC_VERSION.apk"
APK_STATIC_DIR="$WORK_DIR/apk-static"
APK_STATIC_URL="$ALPINE_MIRROR/$ALPINE_BRANCH/main/x86_64/apk-tools-static-$APK_TOOLS_STATIC_VERSION.apk"

rm -rf "$APK_STATIC_DIR"
mkdir -p "$APK_STATIC_DIR"
curl -fsSL --retry 3 "$APK_STATIC_URL" -o "$APK_STATIC_PKG"
tar -xzf "$APK_STATIC_PKG" -C "$APK_STATIC_DIR" sbin/apk.static
APK_STATIC="$APK_STATIC_DIR/sbin/apk.static"
test -x "$APK_STATIC"

# Package scripts/triggers run in the target root. Give them the normal /dev
# interface temporarily (notably /dev/null and getrandom consumers) without
# copying host device nodes into the final filesystem image.
cleanup_apk_dev() {
  sudo umount "$ROOTFS/dev" 2>/dev/null || true
}
trap cleanup_apk_dev EXIT
sudo mkdir -p "$ROOTFS/dev"
sudo mount --bind /dev "$ROOTFS/dev"

# Use the native static apk binary to perform package file operations. Target
# package scripts still run inside the aarch64 root through binfmt/QEMU, but
# ownership/mode/SUID handling is no longer emulated. This avoids QEMU failing
# while apk preserves dbus-daemon-launch-helper permissions.
sudo "$APK_STATIC" \
  --root "$ROOTFS" \
  --arch "$ALPINE_ARCH" \
  --keys-dir etc/apk/keys \
  -X "$ALPINE_MIRROR/$ALPINE_BRANCH/main" \
  -X "$ALPINE_MIRROR/$ALPINE_BRANCH/community" \
  --update-cache add \
    openrc busybox-openrc \
    eudev eudev-openrc udev-init-scripts udev-init-scripts-openrc \
    openssh-server openssh-client \
    iproute2 \
    dnsmasq dnsmasq-openrc \
    ca-certificates \
    kmod \
    e2fsprogs \
    procps \
    less nano \
    ethtool iw \
    dbus dbus-openrc \
    networkmanager networkmanager-openrc networkmanager-cli networkmanager-wifi \
    wpa_supplicant wireless-regdb \
    openssl \
    alsa-lib alsa-utils alsa-ucm-conf \
    parted e2fsprogs-extra tzdata \
    pulseaudio pulseaudio-alsa pulseaudio-utils alsa-plugins-pulse

sudo chroot "$ROOTFS" /usr/sbin/update-ca-certificates

#------------------------------------------------------------------#

sudo cp -a "$REPO_ROOT/distros/alpine/rootfs/." "$ROOTFS/"
sudo cp -a "$REPO_ROOT/common/rootfs/." "$ROOTFS/"
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
sudo chmod 0755 \
  "$ROOTFS/etc/init.d/usb-gadget" \
  "$ROOTFS/etc/init.d/usb-sshd" \
  "$ROOTFS/etc/init.d/pulseaudio-channel"

sudo install -d -m 0755 "$ROOTFS/etc/ssh/sshd_config.d"

printf '%s\n' channel | sudo tee "$ROOTFS/etc/hostname" >/dev/null
sudo tee "$ROOTFS/etc/hosts" >/dev/null <<'EOF'
127.0.0.1 localhost
127.0.1.1 channel
::1 localhost ip6-localhost ip6-loopback
EOF

sudo tee "$ROOTFS/etc/fstab" >/dev/null <<EOF
PARTLABEL=$ROOT_PARTITION_LABEL / ext4 rw,noatime 0 1
EOF

# Keep a stable per-image identifier for the USB serial fallback.
if [ ! -s "$ROOTFS/etc/machine-id" ]; then
  openssl rand -hex 16 | sudo tee "$ROOTFS/etc/machine-id" >/dev/null
fi

# USB-only open root SSH on Alpine (no PAM); local gettys are disabled below.
sudo sed -i 's|^root:[^:]*:|root::|' "$ROOTFS/etc/shadow"
if ! sudo grep -Fq 'Include /etc/ssh/sshd_config.d/*.conf' "$ROOTFS/etc/ssh/sshd_config"; then
  sudo sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' "$ROOTFS/etc/ssh/sshd_config"
fi

sudo chroot "$ROOTFS" /usr/bin/ssh-keygen -A

# Build an explicit OpenRC runlevel set. NetworkManager on Alpine requires
# eudev; never run mdev and udev as competing device managers.
sudo chroot "$ROOTFS" /sbin/rc-update del mdev sysinit 2>/dev/null || true
for service in devfs dmesg udev udev-trigger udev-settle; do
  sudo chroot "$ROOTFS" /sbin/rc-update add "$service" sysinit
done
for service in hwdrivers modules sysctl hostname bootmisc syslog localmount; do
  sudo chroot "$ROOTFS" /sbin/rc-update add "$service" boot
done
for service in udev-postmount dbus usb-gadget dnsmasq usb-sshd networkmanager pulseaudio-channel ntpd channel-grow-rootfs channel-zram; do
  sudo chroot "$ROOTFS" /sbin/rc-update add "$service" default
done


# NetworkManager owns wlan0 and launches the wpa_supplicant backend itself.
# Keep Alpine's legacy networking and standalone supplicant services disabled.
sudo chroot "$ROOTFS" /sbin/rc-update del networking boot 2>/dev/null || true
sudo chroot "$ROOTFS" /sbin/rc-update del wpa_supplicant boot 2>/dev/null || true

test -x "$ROOTFS/sbin/udevd"
test -L "$ROOTFS/etc/runlevels/sysinit/udev"
test -L "$ROOTFS/etc/runlevels/sysinit/udev-trigger"
test -L "$ROOTFS/etc/runlevels/sysinit/udev-settle"
test -L "$ROOTFS/etc/runlevels/default/udev-postmount"
test -L "$ROOTFS/etc/runlevels/default/usb-gadget"
test -L "$ROOTFS/etc/runlevels/default/usb-sshd"
test -L "$ROOTFS/etc/runlevels/default/pulseaudio-channel"
test -L "$ROOTFS/etc/runlevels/default/dnsmasq"
test -L "$ROOTFS/etc/runlevels/default/networkmanager"
test ! -e "$ROOTFS/etc/runlevels/sysinit/mdev"
test ! -e "$ROOTFS/etc/runlevels/boot/networking"
test ! -e "$ROOTFS/etc/runlevels/boot/wpa_supplicant"
grep -Fqx 'unmanaged-devices=interface-name:usb0' "$ROOTFS/etc/NetworkManager/conf.d/10-channel.conf"
grep -Fqx 'wifi.backend=wpa_supplicant' "$ROOTFS/etc/NetworkManager/conf.d/10-channel.conf"

# This image is intentionally headless. Alpine's init spawns gettys from
# /etc/inittab, independently of OpenRC runlevel links. Remove both forms so
# USB SSH must not expose the empty Unix root password on a local/serial console.
sudo sed -i -E '/::(respawn|askfirst):.*(a?getty)/d' "$ROOTFS/etc/inittab"
sudo rm -f "$ROOTFS"/etc/runlevels/default/agetty.* "$ROOTFS"/etc/runlevels/default/consolefont 2>/dev/null || true
if grep -Eq '::(respawn|askfirst):.*(a?getty)' "$ROOTFS/etc/inittab"; then
  echo "Refusing an Alpine image with a local getty enabled" >&2
  exit 1
fi

# Keep persistent logs for headless bring-up.
sudo install -d -m 0755 "$ROOTFS/var/log"

#------------------------------------------------------------------#

test -s "$KERNEL_MODULES_ARCHIVE"
sudo tar -I zstd -xf "$KERNEL_MODULES_ARCHIVE" -C "$ROOTFS"
test -d "$ROOTFS/lib/modules/$KREL"
sudo depmod -b "$ROOTFS" "$KREL"
sudo mkdir -p "$ROOTFS/boot"
sudo cp "$KERNEL_CONFIG_FILE" "$ROOTFS/boot/config-$KREL"
sudo cp "$KERNEL_SYSTEM_MAP_FILE" "$ROOTFS/boot/System.map-$KREL"

#------------------------------------------------------------------#

sudo chroot "$ROOTFS" /usr/sbin/sshd -t

# qemu-aarch64-static is a host-side helper and must not ship in the target image.
sudo rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# All target chroot operations are complete. Remove the temporary host /dev
# bind before materializing the filesystem image.
cleanup_apk_dev
trap - EXIT

#------------------------------------------------------------------#

# Remove apk's download/index cache, not installed packages, Wi-Fi firmware, or kernel modules.
# The existing gadget, NetworkManager and SSH configuration are kept intact.
if [ -d "$ROOTFS/var/cache/apk" ]; then
  sudo find "$ROOTFS/var/cache/apk" -maxdepth 1 -type f -delete
fi

USED_MB="$(sudo du -sm "$ROOTFS" | awk '{print $1}')"
IMAGE_MB=1024
MIN_FREE_MB=32
echo "Alpine staged rootfs: ${USED_MB} MiB; image target: ${IMAGE_MB} MiB; required free space: ${MIN_FREE_MB} MiB"

ROOTFS_IMG="$OUT_DIR/alpine-channel-rootfs.ext4"
truncate -s "${IMAGE_MB}M" "$ROOTFS_IMG"
# 16k inodes (the last successful image had only ~3.8k files) and an 8 MiB
# journal reduce ext4 metadata overhead without disabling journaling.
sudo mkfs.ext4 -F -m 0 -N 16384 -J size=8 -L "$ROOTFS_LABEL" -U random -d "$ROOTFS" "$ROOTFS_IMG"
test "$(stat -c %s "$ROOTFS_IMG")" -eq $((IMAGE_MB * 1024 * 1024))
ROOTFS_EXT4_UUID="$(blkid -p -o value -s UUID "$ROOTFS_IMG")"
test -n "$ROOTFS_EXT4_UUID"
sudo e2fsck -fn "$ROOTFS_IMG"
test "$(blkid -p -o value -s LABEL "$ROOTFS_IMG")" = "$ROOTFS_LABEL"

# mkfs -d accounts for actual file data, inodes, journal and ext4 metadata:
# unlike du alone, this prevents publishing a too-full image.
FS_STATS="$(sudo tune2fs -l "$ROOTFS_IMG")"
FREE_BLOCKS="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
[[ "$FREE_BLOCKS" =~ ^[0-9]+$ && "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || {
  echo "ERROR: Could not inspect ext4 free blocks" >&2
  exit 1
}
FREE_MB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))
echo "Alpine ext4: ${IMAGE_MB} MiB total, ${FREE_MB} MiB free"
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
  echo "ERROR: Alpine's 1024 MiB image leaves only ${FREE_MB} MiB free (minimum ${MIN_FREE_MB} MiB)." >&2
  echo "Reduce staged rootfs contents before building; refusing to publish a nearly-full image." >&2
  exit 1
fi
zstd -T0 -10 -f "$ROOTFS_IMG" -o "$ROOTFS_IMG.zst"
rm -f "$ROOTFS_IMG"

{
  echo "distribution=alpine"
  echo "alpine_version=$ALPINE_VERSION"
  echo "alpine_branch=$ALPINE_BRANCH"
  echo "apk_tools_static_version=$APK_TOOLS_STATIC_VERSION"
  echo "kernel_release=$KREL"
  echo "rootfs_label=$ROOTFS_LABEL"
  echo "rootfs_uuid=$ROOTFS_EXT4_UUID"
  echo "image_size_mib=$IMAGE_MB"
  echo "image_free_mib=$FREE_MB"
  echo "image_min_free_mib=$MIN_FREE_MB"
  echo "staged_rootfs_mib=$USED_MB"
  echo "init=openrc"
  echo "usb_device_ip=172.16.42.1"
  echo "usb_dhcp_range=172.16.42.2-172.16.42.20"
  echo "ssh_auth=ssh"
  echo "ssh_listen=172.16.42.1"
  echo "ssh_scope=usb-only"
  echo "wifi_manager=NetworkManager"
  echo "wifi_runtime_setup=nmcli"
  echo "usb_network_manager=unmanaged"
} > "$OUT_DIR/build-info.txt"

(
  cd "$OUT_DIR"
  sha256sum alpine-channel-rootfs.ext4.zst build-info.txt > SHA256SUMS.alpine
)
