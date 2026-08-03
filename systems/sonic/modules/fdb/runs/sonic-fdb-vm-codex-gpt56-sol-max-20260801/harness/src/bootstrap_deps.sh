#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: bootstrap_deps.sh PREFIX" >&2
    exit 2
fi

if [[ "$1" = /* ]]; then
    PREFIX=$1
else
    PREFIX="$PWD/$1"
fi
CACHE_DIR=${FDB_DEPS_CACHE_DIR:-"$(dirname -- "$PREFIX")/downloads"}
MARKER="$PREFIX/.fdb-harness-deps-v1"

if [[ -f "$MARKER" ]]; then
    exit 0
fi

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    echo "error: the pinned harness dependencies are amd64 packages" >&2
    exit 1
fi

for command_name in curl unzip dpkg-deb find apt-get; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command is missing: $command_name" >&2
        exit 1
    fi
done

mkdir -p "$PREFIX" "$CACHE_DIR" "$CACHE_DIR/extracted" "$CACHE_DIR/packages"

download() {
    local url=$1
    local output=$2
    if [[ -s "$output" ]]; then
        return
    fi
    echo "fetching $(basename -- "$output")"
    timeout 300 curl -fL --retry 3 --retry-delay 2 "$url" -o "$output.part"
    mv "$output.part" "$output"
}

unpack_zip() {
    local archive=$1
    local directory=$2
    mkdir -p "$directory"
    unzip -oq "$archive" -d "$directory"
}

extract_pattern() {
    local directory=$1
    local pattern=$2
    local matches=()
    mapfile -t matches < <(find "$directory" -type f -name "$pattern" | sort)
    if [[ ${#matches[@]} -ne 1 ]]; then
        echo "error: expected one package matching $pattern in $directory" >&2
        exit 1
    fi
    dpkg-deb -x "${matches[0]}" "$PREFIX"
}

SWSS_URL='https://artprodcus3.artifacts.visualstudio.com/Af91412a5-a906-4990-9d7c-f697b81fc04d/be1b070f-be15-4154-aade-b1d3bfb17054/_apis/artifact/cGlwZWxpbmVhcnRpZmFjdDovL21zc29uaWMvcHJvamVjdElkL2JlMWIwNzBmLWJlMTUtNDE1NC1hYWRlLWIxZDNiZmIxNzA1NC9idWlsZElkLzExODExNTYvYXJ0aWZhY3ROYW1lL3NvbmljLXN3c3MtY29tbW9uLWJvb2t3b3Jt0/content?format=zip'
SAIREDIS_URL='https://artprodcus3.artifacts.visualstudio.com/Af91412a5-a906-4990-9d7c-f697b81fc04d/be1b070f-be15-4154-aade-b1d3bfb17054/_apis/artifact/cGlwZWxpbmVhcnRpZmFjdDovL21zc29uaWMvcHJvamVjdElkL2JlMWIwNzBmLWJlMTUtNDE1NC1hYWRlLWIxZDNiZmIxNzA1NC9idWlsZElkLzExODEyMzEvYXJ0aWZhY3ROYW1lL3NvbmljLXNhaXJlZGlzLWJvb2t3b3Jt0/content?format=zip'
VPP_URL='https://artprodcus3.artifacts.visualstudio.com/Af91412a5-a906-4990-9d7c-f697b81fc04d/be1b070f-be15-4154-aade-b1d3bfb17054/_apis/artifact/cGlwZWxpbmVhcnRpZmFjdDovL21zc29uaWMvcHJvamVjdElkL2JlMWIwNzBmLWJlMTUtNDE1NC1hYWRlLWIxZDNiZmIxNzA1NC9idWlsZElkLzExMzkxNTcvYXJ0aWZhY3ROYW1lL3ZwcA2/content?format=zip'
DASH_URL='https://artprodcus3.artifacts.visualstudio.com/Af91412a5-a906-4990-9d7c-f697b81fc04d/be1b070f-be15-4154-aade-b1d3bfb17054/_apis/artifact/cGlwZWxpbmVhcnRpZmFjdDovL21zc29uaWMvcHJvamVjdElkL2JlMWIwNzBmLWJlMTUtNDE1NC1hYWRlLWIxZDNiZmIxNzA1NC9idWlsZElkLzExODExMjMvYXJ0aWZhY3ROYW1lL3NvbmljLWRhc2gtYXBp0/content?format=zip'
COMMON_URL='https://artprodcus3.artifacts.visualstudio.com/Af91412a5-a906-4990-9d7c-f697b81fc04d/be1b070f-be15-4154-aade-b1d3bfb17054/_apis/artifact/cGlwZWxpbmVhcnRpZmFjdDovL21zc29uaWMvcHJvamVjdElkL2JlMWIwNzBmLWJlMTUtNDE1NC1hYWRlLWIxZDNiZmIxNzA1NC9idWlsZElkLzExODE0MTkvYXJ0aWZhY3ROYW1lL2NvbW1vbi1saWI1/content?format=zip'

download "$SWSS_URL" "$CACHE_DIR/swss-common.zip"
download "$SAIREDIS_URL" "$CACHE_DIR/sairedis.zip"
download "$VPP_URL" "$CACHE_DIR/vpp.zip"
download "$DASH_URL" "$CACHE_DIR/dash-api.zip"
download "$COMMON_URL" "$CACHE_DIR/common-lib.zip"
download 'https://deb.debian.org/debian/pool/main/p/protobuf/libprotobuf32_3.21.12-3_amd64.deb' "$CACHE_DIR/packages/libprotobuf32_3.21.12-3_amd64.deb"
download 'https://deb.debian.org/debian/pool/main/p/protobuf/libprotobuf-dev_3.21.12-3_amd64.deb' "$CACHE_DIR/packages/libprotobuf-dev_3.21.12-3_amd64.deb"

unpack_zip "$CACHE_DIR/swss-common.zip" "$CACHE_DIR/extracted/swss-common"
unpack_zip "$CACHE_DIR/sairedis.zip" "$CACHE_DIR/extracted/sairedis"
unpack_zip "$CACHE_DIR/vpp.zip" "$CACHE_DIR/extracted/vpp"
unpack_zip "$CACHE_DIR/dash-api.zip" "$CACHE_DIR/extracted/dash-api"
unpack_zip "$CACHE_DIR/common-lib.zip" "$CACHE_DIR/extracted/common-lib"

extract_pattern "$CACHE_DIR/extracted/swss-common" 'libswsscommon_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/swss-common" 'libswsscommon-dev_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/sairedis" 'libsaimetadata_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/sairedis" 'libsaimetadata-dev_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/sairedis" 'libsairedis_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/sairedis" 'libsairedis-dev_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/sairedis" 'libsaivs_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/sairedis" 'libsaivs-dev_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/vpp" 'libvppinfra_[0-9]*_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/vpp" 'libvppinfra-dev_[0-9]*_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/vpp" 'vpp_[0-9]*_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/vpp" 'vpp-dev_[0-9]*_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/dash-api" 'libdashapi_1.0.0_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/common-lib/common-lib/target/debs/bookworm" 'libyang3_3.12.2-1_amd64.deb'
extract_pattern "$CACHE_DIR/extracted/common-lib/common-lib/target/debs/bookworm" 'libyang-dev_3.12.2-1_amd64.deb'
dpkg-deb -x "$CACHE_DIR/packages/libprotobuf32_3.21.12-3_amd64.deb" "$PREFIX"
dpkg-deb -x "$CACHE_DIR/packages/libprotobuf-dev_3.21.12-3_amd64.deb" "$PREFIX"

(
    cd "$CACHE_DIR/packages"
    apt-get download libjansson-dev libyaml-cpp-dev libyaml-cpp0.7 libboost-serialization1.74.0
)
extract_pattern "$CACHE_DIR/packages" 'libjansson-dev_*_amd64.deb'
extract_pattern "$CACHE_DIR/packages" 'libyaml-cpp-dev_*_amd64.deb'
extract_pattern "$CACHE_DIR/packages" 'libyaml-cpp0.7_*_amd64.deb'
extract_pattern "$CACHE_DIR/packages" 'libboost-serialization1.74.0_*_amd64.deb'

LIB_DIR="$PREFIX/usr/lib/x86_64-linux-gnu"
for library_name in vlib vlibapi vppapiclient vlibmemoryclient vppinfra; do
    if [[ ! -e "$LIB_DIR/lib${library_name}.so.25.06" ]]; then
        echo "error: missing pinned VPP library lib${library_name}.so.25.06" >&2
        exit 1
    fi
    ln -sfn "lib${library_name}.so.25.06" "$LIB_DIR/lib${library_name}.so.26.10"
done
ln -sfn libboost_serialization.so.1.74.0 "$LIB_DIR/libboost_serialization.so.1.83.0"

touch "$MARKER"
echo "dependencies ready in $PREFIX"
