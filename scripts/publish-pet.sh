#!/bin/bash
# Package an installed pet as a resource-center pack and print its catalog entry.
#
#   scripts/publish-pet.sh <pet name> <pack id> [--version N] [--out DIR] [--upload]
#
# Reads the pet from ~/Library/Application Support/PeachyPet/mascots.json, copies
# every local (file://) media file into the pack, rewrites those paths to be
# relative, zips it as <pack id>.zip and prints the entry to add to catalog.json.
# With --upload it also attaches the zip to the peachy-mascots Release
# "<pack id>-v<version>" via gh. Remote (https://) media is left as is.
# Spritesheet pets ship their sheet too; only locally imported ones may be
# published, never pets downloaded from OpenPets or Petdex.
set -euo pipefail

NAME="${1:?usage: publish-pet.sh <pet name> <pack id> [--version N] [--out DIR] [--upload]}"
PACK_ID="${2:?pack id required}"
shift 2
VERSION=1
OUT_DIR="dist/pets"
UPLOAD=0
REPO="Sebastian-Su/peachy-mascots"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --upload) UPLOAD=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

MASCOTS="$HOME/Library/Application Support/PeachyPet/mascots.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"

python3 -I - "$MASCOTS" "$NAME" "$WORK/pack" <<'PY'
import json, os, shutil, sys
from urllib.parse import urlparse, unquote

mascots_path, name, pack = sys.argv[1:4]
matches = [m for m in json.load(open(mascots_path)) if m.get("name") == name]
if len(matches) != 1:
    sys.exit(f"expected exactly one pet named {name!r}, found {len(matches)}")
config = matches[0]["config"]
sprite = config.get("sprite")
if sprite and sprite.get("source") != "local":
    sys.exit(f"{name!r} came from {sprite.get('source')}; only sprite pets you imported yourself can be published")
os.makedirs(pack)
copied = {}

def localize(value):
    if isinstance(value, dict):
        return {k: (pack_path(v) if k in ("hevc", "webm", "transparentThumbnailUrl", "url", "sheet") and isinstance(v, str) else localize(v))
                for k, v in value.items()}
    if isinstance(value, list):
        return [localize(v) for v in value]
    return value

def pack_path(url):
    parsed = urlparse(url)
    if parsed.scheme != "file":
        return url
    src = unquote(parsed.path)
    if src not in copied:
        rel = "media/" + os.path.basename(src)
        if not os.path.isfile(src):
            sys.exit(f"missing media file: {src}")
        os.makedirs(os.path.join(pack, "media"), exist_ok=True)
        shutil.copy2(src, os.path.join(pack, rel))
        copied[src] = rel
    return copied[src]

json.dump(localize(config), open(os.path.join(pack, "pet.json"), "w"), ensure_ascii=False)
print(f"packed {len(copied)} media files", file=sys.stderr)
PY

ZIP="$OUT_DIR/$PACK_ID.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k "$WORK/pack" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(stat -f %z "$ZIP")
TAG="$PACK_ID-v$VERSION"
DOWNLOAD="https://github.com/$REPO/releases/download/$TAG/$PACK_ID.zip"

cat <<JSON
{"id":"$PACK_ID","name":"$NAME","version":"$VERSION","preview":null,"download":"$DOWNLOAD","sha256":"$SHA","size":$SIZE}
JSON
echo "pack: $ZIP" >&2

if [ "$UPLOAD" = 1 ]; then
  # gh prints URLs on stdout; keep stdout for the catalog entry only.
  gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || gh release create "$TAG" -R "$REPO" --title "$NAME v$VERSION" --notes "$NAME pet pack" >&2
  gh release upload "$TAG" "$ZIP" -R "$REPO" --clobber >&2
  echo "uploaded to $DOWNLOAD" >&2
fi
