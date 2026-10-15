#!/bin/sh
# Writes the pinned restic release, verified and universal, to <output> unless it is already there.
set -eu

version=0.19.1
base_url="https://github.com/restic/restic/releases/download/v${version}"

sha256() {
    case $1 in
    arm64) echo 7be0a144ccc377880f294204aa271d76e4b79554b42a751151d425ce6ebac143 ;;
    amd64) echo c38d579622cf602f665234c5a8c315030b6cf70656028fe6dc29a786b60e5f35 ;;
    esac
}

output=${1:?usage: fetch-restic.sh <output>}
case $(basename "$output") in
*"$version"*) ;;
*) echo "error: $output must name restic $version, so a version bump never reuses an old cache" >&2; exit 1 ;;
esac
[ -x "$output" ] && exit 0

mkdir -p "$(dirname "$output")"
work=$(mktemp -d "${TMPDIR:-/tmp}/fetch-restic.XXXXXX")
trap 'rm -rf "$work"' EXIT

for arch in arm64 amd64; do
    file="restic_${version}_darwin_${arch}.bz2"
    expected=$(sha256 "$arch")
    curl --fail --silent --show-error --location --retry 3 --output "$work/$file" "$base_url/$file"
    actual=$(shasum -a 256 "$work/$file" | cut -d ' ' -f 1)
    if [ "$actual" != "$expected" ]; then
        echo "error: $file has SHA-256 $actual, expected $expected" >&2
        exit 1
    fi
    bunzip2 "$work/$file"
done

lipo -create "$work/restic_${version}_darwin_arm64" "$work/restic_${version}_darwin_amd64" -output "$work/restic"
chmod 755 "$work/restic"
mv "$work/restic" "$output"
