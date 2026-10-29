#!/usr/bin/env bash
# Rootfs builder: one script, three distros. Conf-driven, zero validation
# layers; consumes the published mainline kernel checkpoint and produces a
# GPT SD-card disk image (never touching the kernel sources or compile).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/cache"
BUILDS="$ROOT/build"
export LC_ALL=C

DISTRO="${1:-}"
usage(){ cat <<EOF
Usage: bash sh/build.sh <alpine|debian|ubuntu>

Reuses the kernel checkpoint in cache/mainline/checkpoint (built by the
main branch; on GitHub Actions the newest successful mainline artifact is
downloaded instead). Creates build/rootfs/<distro>/<distro>-STAMP.img
(GPT SD-card disk image).
EOF
}
case "$DISTRO" in alpine|debian|ubuntu) ;; *) usage; exit 2;; esac

CHECKPOINT="${KERNEL_CHECKPOINT_DIR:-$CACHE/mainline/checkpoint}"

# Device + image policy from the conf surface; empty values keep defaults.
source "$ROOT/conf/device.conf"
source "$ROOT/conf/rootfs.conf"
: "${DEVICE:=channel}"
case "$DISTRO" in
  alpine) export IMAGE_FREE_MIN="${IMAGE_FREE_MIN_ALPINE:-32}";;
  *)      export IMAGE_FREE_MIN="${IMAGE_FREE_MIN_DEBIAN_UBUNTU:-64}";;
esac
export IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-1024}"

say() { printf '\n[%s] %s\n' "$DEVICE" "$*"; }

# On CI, when no checkpoint exists yet: reuse the newest successful mainline
# artifact (never dispatch a kernel build from any rootfs workflow).
if [ "${GITHUB_ACTIONS:-}" = true ] && [ ! -s "$CHECKPOINT/kernel-release.txt" ]; then
  command -v gh >/dev/null || { echo 'ERROR: GitHub CLI missing.' >&2; exit 1; }
  mainline_workflow_id="$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/mainline.yml" --jq '.id')"
  is_mainline_run() {
    local run="$1"
    gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" \
      --jq "select(.conclusion == \"success\" and .head_branch == \"main\" and .workflow_id == $mainline_workflow_id) | .id" | grep -Fxq "$run"
  }
  artifact_for_run() {
    gh api "repos/$GITHUB_REPOSITORY/actions/runs/$1/artifacts?per_page=100" \
      --jq '[.artifacts[] | select(.expired == false and (.name | startswith("channel-mainline-kernel-"))) | .name] | first // empty'
  }
  selected_run=''
  selected_artifact=''
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    is_mainline_run "$candidate" || continue
    artifact="$(artifact_for_run "$candidate")"
    if [ -n "$artifact" ]; then
      selected_run="$candidate"
      selected_artifact="$artifact"
      break
    fi
  done < <(gh run list --repo "$GITHUB_REPOSITORY" --workflow mainline.yml \
      --branch main --status success --limit 50 --json databaseId --jq '.[].databaseId')
  [ -n "$selected_run" ] || { echo 'ERROR: No usable successful mainline kernel checkpoint. Run the mainline workflow once.' >&2; exit 1; }
  rm -rf "$CHECKPOINT"
  mkdir -p "$CHECKPOINT"
  echo "Reusing kernel checkpoint $selected_artifact (run $selected_run)"
  gh run download "$selected_run" --repo "$GITHUB_REPOSITORY" --name "$selected_artifact" --dir "$CHECKPOINT"
fi

KREL="$(cat "$CHECKPOINT/kernel-release.txt")"
MODULES="${KERNEL_MODULES_ARCHIVE:-$CHECKPOINT/${MODULES_ARCHIVE_BASE:-kernel-modules}-$KREL.tar.zst}"

# Build host dependencies for the distro profile.
source "$ROOT/sh/deps.sh"
install_host_deps "$DISTRO"

# Raw generator: an adapted COPY of the distro builder (GPT SD-card disk
# image, no zstd), with the sizes and partition label from conf/rootfs.conf.
# Scratch, never committed.
OUT_DIR="$CACHE/rootfs/$DISTRO/out"
WORK_DIR="$CACHE/rootfs/$DISTRO/work"
BUILDER="$ROOT/.work/rootfs/$DISTRO/raw/.local-raw-build.sh"
mkdir -p "$OUT_DIR" "$WORK_DIR" "$(dirname "$BUILDER")" "$BUILDS/rootfs/$DISTRO"
rm -f "$OUT_DIR"/*
export ROOT_PARTITION_LABEL="${ROOT_PARTITION_LABEL:-sdcard}"
python3 "$ROOT/sh/lib/raw-rootfs-builder.py" "$ROOT/distros/$DISTRO/build.sh" "$BUILDER" "$DISTRO" "$DEVICE"

export DISTRO ROOTFS_LABEL="$DISTRO" KERNEL_RELEASE="$KREL" WORK_DIR OUT_DIR REPO_ROOT="$ROOT"
export KERNEL_MODULES_ARCHIVE="$MODULES"
export KERNEL_CONFIG_FILE="$CHECKPOINT/kernel.config" KERNEL_SYSTEM_MAP_FILE="$CHECKPOINT/System.map"
say "Building $DEVICE $DISTRO from the cached kernel modules; no kernel compile."
bash "$BUILDER"

# Date the raw image into build/ and carry its metadata along.
RAW="$OUT_DIR/$DISTRO-$DEVICE-rootfs.img"
STAMP="$(date -u +%Y%m%d%H%M%S)"
NAME="$DISTRO-$STAMP"
DEST="$BUILDS/rootfs/$DISTRO"
mv "$RAW" "$DEST/$NAME.img"
cp "$OUT_DIR/build-info.txt" "$DEST/$NAME.build-info.txt"
cp "$CHECKPOINT/boot-$DEVICE.img" "$DEST/$NAME.boot.img"
printf 'device=%s\ndistribution=%s\nbuild_utc=%s\nkernel_release=%s\nmodules_archive=%s\n' \
  "$DEVICE" "$DISTRO" "$STAMP" "$KREL" "${MODULES#"$ROOT/"}" > "$DEST/$NAME.local-build.txt"
# Checksum the dated set itself (the distro builder's SHA256SUMS refers to
# the pre-dating filenames in OUT_DIR, so it is not published as-is).
(cd "$DEST" && sha256sum "$NAME.img" "$NAME.build-info.txt" \
  "$NAME.boot.img" "$NAME.local-build.txt" > "$NAME.SHA256SUMS")
say "Finished: $DEST/$NAME.img"
say "Matching boot image: $DEST/$NAME.boot.img"
