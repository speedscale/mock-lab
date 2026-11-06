#!/usr/bin/env bash
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$lab/../.." && pwd)
config=${1:?Usage: run.sh /absolute/path/to/dev-config.yaml [output-directory]}
config=$(cd "$(dirname "$config")" && pwd)/$(basename "$config")
test -f "$config"
out=${2:-$lab/results/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$out"
out=$(cd "$out" && pwd)
context=$(mktemp -d "${TMPDIR:-/tmp}/mock-lab-ai-refactor.XXXXXX")
name="mock-lab-ai-refactor-$$"
cleanup() {
  docker rm -f "$name" > /dev/null 2>&1 || true
  rm -rf "$context"
}
trap cleanup EXIT
for command in docker git curl python3; do command -v "$command" > /dev/null; done
version=v2.5.1250
curl -fsSL "https://downloads.speedscale.com/proxymock/$version/proxymock-linux-amd64" -o "$context/proxymock"
python3 - "$context/proxymock" <<'PY'
import hashlib, sys
from pathlib import Path
assert hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() == '269064db8c9867c3aedd6f96cae403095bd868fa0279b3d6987d18c34d0dd1d0', 'CLI checksum mismatch'
PY
chmod +x "$context/proxymock"
mkdir -p "$context/source/original" "$context/source/fixed" "$context/workspace/proxymock"
git -C "$repo" show 382e4a79e1eb1ae65960f6bec0be8b4b9a546f65:languages/go/main.go > "$context/source/original/main.go"
cp "$repo/languages/go/go.mod" "$context/source/original/"
cp "$repo/languages/go/"*.go "$repo/languages/go/go.mod" "$context/source/fixed/"
cp -R "$context/source/fixed" "$context/source/broken"
python3 - "$context/source/broken/stats.go" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
assert s.count('`json:"maturity"`') == 1
p.write_text(s.replace('`json:"maturity"`', '`json:"lifecycle"`'))
PY
for dir in recording blueprints applications testconfigs; do
  cp -R "$repo/languages/go/proxymock/$dir" "$context/workspace/proxymock/"
done
cp "$lab/Dockerfile" "$lab/run-in-container.sh" "$lab/verify.py" "$context/"
image=mock-lab-ai-refactor:local
docker build --platform linux/amd64 --network none -t "$image" "$context" > "$out/build.log" 2>&1
docker image inspect "$image" --format '{{.Id}}' > "$out/image-id.txt"
docker create --platform linux/amd64 --name "$name" --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 --memory 2g --cpus 2 \
  --mount "type=bind,src=$config,dst=/run/proxymock.yaml,readonly" \
  "$image" > "$out/container-id.txt"
set +e
docker start -a "$name" > "$out/run.log" 2>&1
code=$?
set -e
docker inspect "$name" --format '{{json .HostConfig}}' > "$out/container-settings.json"
docker cp "$name:/work/proxymock/results/." "$out/"
cat "$out/run.log"
test "$code" = 0
python3 "$lab/verify.py" "$out"
echo "Evidence: $out"
