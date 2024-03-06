#!/usr/bin/env bash
set -euo pipefail
my_mktemp() {
  local tempdir=""

  tempdir=$(mktemp -d zig.XXXX)

  echo -n $tempdir
}

install_zig() {
  local install_path=$1

  local tempdir=$(my_mktemp $platform)
  echo "tempdir: $tempdir"
  local url="https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz"

  echo "Downloading ${url}..."
  curl "${url}" -o "${tempdir}/archive"
  tar -C "$install_path" -xf "${tempdir}/archive" --strip-components=1

  mkdir "${install_path}/bin"
  ln -s "${install_path}/zig" "${install_path}/bin/zig"

  rm -rf "${tempdir}"
}

install_zig "/opt"
