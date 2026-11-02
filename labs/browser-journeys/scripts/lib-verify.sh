# Shared by the verify scripts. check <name> <want exit> <text the output must hold>... -- <command>
log_dir=${LOG_DIR:-proxymock/results/verify}
mkdir -p "$log_dir"
failures=0

check() {
  local name=$1 want=$2
  shift 2
  local patterns=()
  while [[ $1 != -- ]]; do
    patterns+=("$1")
    shift
  done
  shift

  local log="$log_dir/$name.log" got=0
  "$@" >"$log" 2>&1 || got=$?

  local ok=1 pattern
  [[ $got -eq $want ]] || ok=0
  for pattern in "${patterns[@]+"${patterns[@]}"}"; do
    grep -qF -- "$pattern" "$log" || { ok=0; echo "  missing from output: $pattern"; }
  done

  if [[ $ok -eq 1 ]]; then
    echo "ok    $name (exit $got)"
  else
    echo "FAIL  $name (exit $got, wanted $want), see $log"
    failures=$((failures + 1))
  fi
}

finish() {
  if [[ $failures -gt 0 ]]; then
    echo "$failures step(s) failed"
    exit 1
  fi
  echo "all steps passed"
}
