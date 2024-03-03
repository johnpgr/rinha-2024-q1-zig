#!/usr/bin/env bash
set -euo pipefail

BASE_URL='https://ziglang.org/download/index.json'

get_url() {
  local platform=$1
  local arch=$2

  local url=""

	url=$( \
		curl -s $BASE_URL \
		| sed -n 's/"tarball": "\(.*\/builds\/.*zig-'"$platform"'-'"$arch"'-[0-9\.]*.*\)",/\1/p' \
	)

  echo -n $url
}

my_mktemp() {
  local tempdir=""

	tempdir=$(mktemp -d zig.XXXX)

  echo -n $tempdir
}

install_zig() {
  local install_path=$1

  local platform="linux"
  local arch="x86_64"
  local tempdir=$(my_mktemp $platform)
	echo "tempdir: $tempdir"
  local url=$(get_url $platform $arch)

  echo "Downloading ${url}..."
  curl "${url}" -o "${tempdir}/archive"
  tar -C "$install_path" -xf "${tempdir}/archive" --strip-components=1

  mkdir "${install_path}/bin"
  ln -s "${install_path}/zig" "${install_path}/bin/zig"

  rm -rf "${tempdir}"
}

install_zig "/opt"
