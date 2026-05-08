#!/usr/bin/env bash
# docker-bench.sh — benchmark cold/warm Docker builds for Go and TypeScript
# projects on macOS and Linux. Writes one CSV per run.
#
# Usage:
#   ./docker-bench.sh [machine_name]
#
# Env overrides:
#   BENCH_PROFILE   (default: light) — "light" or "heavy"
#                     light: Syncthing (Go) + Verdaccio (TS), more runs
#                     heavy: Hugo (Go) + Directus (TS), fewer runs
#   WORKDIR         (default: $HOME/docker-bench)
#   RUNS_COLD       (default: 5 light, 3 heavy)
#   RUNS_WARM       (default: 8 light, 5 heavy)
#   SYNCTHING_REF   (default: v2.0.16)   — light Go project
#   VERDACCIO_REF   (default: v6.5.2)    — light TS project
#   HUGO_REF        (default: v0.139.0)  — heavy Go project
#   DIRECTUS_REF    (default: v11.17.4)  — heavy TS project
#   BENCH_SCENARIO  (default: both) — "cold", "warm", or "both"
#   BENCH_ARCH      (default: native)    — target platform for docker build
#                     e.g. linux/arm64, linux/amd64
#
# Requires: git, docker, hyperfine, jq
#   macOS:  brew install git hyperfine jq   (Docker Desktop installs docker)
#   Ubuntu: sudo apt install -y git docker.io jq
#           hyperfine: download .deb from https://github.com/sharkdp/hyperfine/releases

set -euo pipefail

# ---------- configuration ----------
MACHINE_NAME="${1:-${MACHINE_NAME:-$(hostname -s 2>/dev/null || hostname)}}"
WORKDIR="${WORKDIR:-$HOME/docker-bench}"
BENCH_PROFILE="${BENCH_PROFILE:-light}"
BENCH_ARCH="${BENCH_ARCH:-}"
BENCH_SCENARIO="${BENCH_SCENARIO:-both}"

case "$BENCH_SCENARIO" in
  cold|warm|both) ;;
  *)
    echo "ERROR: unknown BENCH_SCENARIO '$BENCH_SCENARIO' (use 'cold', 'warm', or 'both')" >&2
    exit 1
    ;;
esac

# Profile-specific defaults
case "$BENCH_PROFILE" in
  light)
    RUNS_COLD="${RUNS_COLD:-5}"
    RUNS_WARM="${RUNS_WARM:-8}"
    GO_PROJECT=syncthing
    GO_URL="https://github.com/syncthing/syncthing.git"
    GO_REF="${SYNCTHING_REF:-v2.0.16}"
    TS_PROJECT=verdaccio
    TS_URL="https://github.com/verdaccio/verdaccio.git"
    TS_REF="${VERDACCIO_REF:-v6.5.2}"
    ;;
  heavy)
    RUNS_COLD="${RUNS_COLD:-3}"
    RUNS_WARM="${RUNS_WARM:-5}"
    GO_PROJECT=hugo
    GO_URL="https://github.com/gohugoio/hugo.git"
    GO_REF="${HUGO_REF:-v0.139.0}"
    TS_PROJECT=directus
    TS_URL="https://github.com/directus/directus.git"
    TS_REF="${DIRECTUS_REF:-v11.17.4}"
    ;;
  *)
    echo "ERROR: unknown BENCH_PROFILE '$BENCH_PROFILE' (use 'light' or 'heavy')" >&2
    exit 1
    ;;
esac

mkdir -p "$WORKDIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_CSV="$WORKDIR/results-${MACHINE_NAME}-${BENCH_PROFILE}-${TIMESTAMP}.csv"

# ---------- platform detection ----------
uname_s=$(uname -s)

os_string() {
  case "$uname_s" in
    Darwin) echo "macOS $(sw_vers -productVersion)" ;;
    Linux)
      if [ -r /etc/os-release ]; then
        ( . /etc/os-release && echo "$PRETTY_NAME" )
      else
        echo "Linux $(uname -r)"
      fi
      ;;
    *) echo "$uname_s $(uname -r)" ;;
  esac
}

cpu_string() {
  case "$uname_s" in
    Darwin) sysctl -n machdep.cpu.brand_string ;;
    Linux)  awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo ;;
    *)      echo "unknown" ;;
  esac
}

core_count() {
  case "$uname_s" in
    Darwin) sysctl -n hw.ncpu ;;
    Linux)  nproc ;;
    *)      echo "?" ;;
  esac
}

ram_gb() {
  case "$uname_s" in
    Darwin) echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) ;;
    Linux)  awk '/^MemTotal:/ { printf "%.0f", $2 / 1024 / 1024 }' /proc/meminfo ;;
    *)      echo "?" ;;
  esac
}

OS=$(os_string)
CPU=$(cpu_string)
CORES=$(core_count)
RAM=$(ram_gb)
ARCH=$(uname -m)
DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
PLATFORM_FLAG=()
if [ -n "$BENCH_ARCH" ]; then
  PLATFORM_FLAG=(--platform "$BENCH_ARCH")
fi

# ---------- preflight ----------
for cmd in git docker hyperfine jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' is not in PATH" >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: cannot talk to the Docker daemon." >&2
  echo "  - macOS:  start Docker Desktop" >&2
  echo "  - Linux:  ensure dockerd is running and your user is in the 'docker' group" >&2
  exit 1
fi

cat <<EOF
============================================================
 Docker build benchmark
============================================================
 Machine:   $MACHINE_NAME
 OS:        $OS
 CPU:       $CPU
 Cores:     $CORES
 Arch:      $ARCH
 Target:    ${BENCH_ARCH:-native}
 RAM:       ${RAM} GB
 Docker:    $DOCKER_VER
 Profile:   $BENCH_PROFILE
 Go:        $GO_PROJECT ($GO_REF)
 TS:        $TS_PROJECT ($TS_REF)
 Scenario:  $BENCH_SCENARIO
 Runs:      cold=$RUNS_COLD, warm=$RUNS_WARM
 Workdir:   $WORKDIR
 Output:    $RESULTS_CSV
============================================================
EOF

# ---------- CSV header ----------
echo "machine,os,cpu,cores,arch,ram_gb,docker_version,profile,project,scenario,commit,runs,median_s,mean_s,stddev_s,min_s,max_s" \
  > "$RESULTS_CSV"

# ---------- helpers ----------
clone_or_update() {
  local name="$1" url="$2" ref="$3"
  local dir="$WORKDIR/$name"
  if [ ! -d "$dir/.git" ]; then
    GIT_CONFIG_GLOBAL=/dev/null git clone --quiet "$url" "$dir"
  fi
  ( cd "$dir" && GIT_CONFIG_GLOBAL=/dev/null git fetch --tags --quiet --all || true )
  if ! ( cd "$dir" && git checkout --quiet "$ref" ) 2>/dev/null; then
    echo "  WARNING: ref '$ref' not found for $name; using current HEAD." >&2
  fi
  ( cd "$dir" && git rev-parse --short HEAD )
}

run_scenario() {
  local project="$1" scenario="$2" commit="$3" runs="$4" prepare="$5" cmd="$6"
  local json="$WORKDIR/${project}-${scenario}.json"

  echo ""
  echo ">> $project / $scenario ($runs runs)"
  hyperfine \
    --runs "$runs" \
    --prepare "$prepare" \
    --export-json "$json" \
    "$cmd"

  local median mean stddev min max
  median=$(jq -r '.results[0].median' "$json")
  mean=$(jq   -r '.results[0].mean'   "$json")
  stddev=$(jq -r '.results[0].stddev' "$json")
  min=$(jq    -r '.results[0].min'    "$json")
  max=$(jq    -r '.results[0].max'    "$json")

  printf '%s,"%s","%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$MACHINE_NAME" "$OS" "$CPU" "$CORES" "$ARCH" "$RAM" "$DOCKER_VER" \
    "$BENCH_PROFILE" "$project" "$scenario" "$commit" "$runs" \
    "$median" "$mean" "$stddev" "$min" "$max" \
    >> "$RESULTS_CSV"
}

benchmark() {
  local name="$1" url="$2" ref="$3"
  echo ""
  echo "============================================================"
  echo " Project: $name  (ref: $ref)"
  echo "============================================================"
  local commit
  commit=$(clone_or_update "$name" "$url" "$ref")
  cd "$WORKDIR/$name"

  if [ ! -f Dockerfile ]; then
    echo "  ERROR: no Dockerfile at repo root for $name; skipping." >&2
    return
  fi

  # Untimed warmup build: pulls base images so the first cold measurement
  # isn't dominated by network. `docker builder prune` later only clears
  # build cache, not pulled base images.
  echo ">> warmup build (untimed, pulls base layers)..."
  docker build ${PLATFORM_FLAG[@]+"${PLATFORM_FLAG[@]}"} -t "bench-${name}-warmup" . >/dev/null 2>&1 || \
    echo "  (warmup build failed; cold runs may include base-image pull time)"

  if [[ "$BENCH_SCENARIO" == cold || "$BENCH_SCENARIO" == both ]]; then
    # Cold: build cache wiped, base images retained.
    run_scenario "$name" "cold" "$commit" "$RUNS_COLD" \
      "docker builder prune -f >/dev/null" \
      "docker build ${PLATFORM_FLAG[*]+${PLATFORM_FLAG[*]}} --no-cache -t bench-${name} ."
  fi

  if [[ "$BENCH_SCENARIO" == warm || "$BENCH_SCENARIO" == both ]]; then
    # Prime the build cache for warm runs (cold scenario's --no-cache leaves
    # the cache empty, so the first warm run would otherwise be a cold build).
    echo ">> priming cache for warm runs..."
    docker build ${PLATFORM_FLAG[@]+"${PLATFORM_FLAG[@]}"} -t "bench-${name}" . >/dev/null 2>&1

    # Warm: bust the final COPY layer with a tiny file change so source-dependent
    # steps re-run; dependency layers stay cached.
    run_scenario "$name" "warm" "$commit" "$RUNS_WARM" \
      "date > cache-buster" \
      "docker build ${PLATFORM_FLAG[*]+${PLATFORM_FLAG[*]}} -t bench-${name} ."

    rm -f cache-buster
  fi
}

# ---------- run ----------
benchmark "$GO_PROJECT" "$GO_URL" "$GO_REF"
benchmark "$TS_PROJECT" "$TS_URL" "$TS_REF"

echo ""
echo "============================================================"
echo " Done."
echo "============================================================"
cat "$RESULTS_CSV"
echo ""
echo "Saved to: $RESULTS_CSV"
