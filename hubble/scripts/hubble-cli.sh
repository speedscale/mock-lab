#!/usr/bin/env bash
set -euo pipefail
# Installs the pinned hubble CLI into the lab's bin/ directory. Nothing is
# written outside this lab.

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=${HUBBLE_CLI_VERSION:-v1.19.4}
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
esac

mkdir -p "$root_dir/bin"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

base="https://github.com/cilium/hubble/releases/download/${version}"
archive="hubble-${os}-${arch}.tar.gz"
curl --fail --location --silent --show-error \
  "${base}/${archive}" -o "$tmp_dir/${archive}"
curl --fail --location --silent --show-error \
  "${base}/${archive}.sha256sum" -o "$tmp_dir/${archive}.sha256sum"

# The checksum file names the archive, so verify from inside the temp dir.
(cd "$tmp_dir" && shasum -a 256 -c "${archive}.sha256sum")
tar -xzf "$tmp_dir/${archive}" -C "$root_dir/bin" hubble
chmod +x "$root_dir/bin/hubble"

"$root_dir/bin/hubble" version
