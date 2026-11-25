#!/usr/bin/env bash
# Run the shop API in the language given as $1 (go, java, node or python) in
# the foreground. DB_HOST, DB_PORT and PORT pass through; scripts set DB_PORT to
# the recorder's or the mock's port.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lang=${1:?usage: app.sh go|java|node|python}
cd "$root_dir/apps/$lang"
case $lang in
  go) exec ./bin/shop ;;
  java) exec java -jar target/shop-java-1.0.0.jar ;;
  node) exec node server.js ;;
  python) exec .venv/bin/python server.py ;;
  *) echo "unknown language $lang; use go, java, node or python" >&2; exit 2 ;;
esac
