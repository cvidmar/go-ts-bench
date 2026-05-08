# go-ts-bench

A reproducible benchmark for Docker image builds across machines and operating systems. Runs real-world projects - one Go, one TypeScript - through cold and warm build scenarios and emits a CSV you can collate across machines.

Built to compare bare-metal macOS, bare-metal Linux, and Linux VPSes on equal footing, but works anywhere Docker and Bash run.

## What it measures

For each project, two scenarios:

- **Cold build** - build cache wiped before each run (`docker builder prune -f`). Approximates a CI build from scratch. Base images are pulled once during an untimed warmup so the measurement isn't dominated by your network.
- **Warm build** - build cache kept, but a `cache-buster` file is touched between runs to invalidate the final `COPY` layer. Approximates the inner-loop "I changed one file, rebuild" experience. Dependency layers stay cached; source-dependent steps re-run.

[Hyperfine](https://github.com/sharkdp/hyperfine) drives the timing and reports median, mean, stddev, min, and max across runs.

## Profiles

The benchmark ships with two profiles - **light** (faster builds, more runs) and **heavy** (longer builds, fewer runs):

| Profile | Go project | TS project | Cold runs | Warm runs |
|---|---|---|---|---|
| `light` (default) | [Syncthing](https://github.com/syncthing/syncthing) `v2.0.16` | [Verdaccio](https://github.com/verdaccio/verdaccio) `v6.5.2` | 5 | 8 |
| `heavy` | [Hugo](https://github.com/gohugoio/hugo) `v0.139.0` | [Directus](https://github.com/directus/directus) `v11.17.4` | 3 | 5 |

The heavy profile uses fewer runs because longer builds are less susceptible to external noise, making each measurement more stable on its own.

| Project | Language | Why |
|---|---|---|
| [Syncthing](https://github.com/syncthing/syncthing) | Go | Pure Go, multi-stage Dockerfile that compiles from source. ~70s cold build. |
| [Verdaccio](https://github.com/verdaccio/verdaccio) | TypeScript | npm registry, full `pnpm install` + build from source. ~42s cold build. |
| [Hugo](https://github.com/gohugoio/hugo) | Go | Static site generator with CGO. Multi-stage build. ~160s cold build. |
| [Directus](https://github.com/directus/directus) | TypeScript | Large monorepo, full `pnpm install` + build. ~135s cold build. |

All projects are pinned to specific tags so every machine builds identical source. The actual commit SHA is recorded in the CSV regardless.

## Requirements

- Bash (the script uses only Bash 3.x-compatible features, so macOS's built-in Bash works)
- Git
- Docker, with the daemon running and your user able to talk to it
- [hyperfine](https://github.com/sharkdp/hyperfine)
- [jq](https://jqlang.github.io/jq/)
- ~10 GB free disk per project for the build cache and base images
- Network access on the first run to pull base images and clone repos

### Installing dependencies

**macOS** (Homebrew):

```bash
brew install git hyperfine jq
# Docker Desktop: https://www.docker.com/products/docker-desktop
```

**Ubuntu / Debian**:

```bash
sudo apt update
sudo apt install -y git docker.io jq
# hyperfine: grab the latest .deb from
# https://github.com/sharkdp/hyperfine/releases
sudo usermod -aG docker "$USER"   # then log out and back in
```

### Docker Hub authentication

The benchmark pulls base images and re-resolves metadata on cold runs. Without authentication, Docker Hub's rate limit (100 pulls per 6 hours) can cause failures during repeated runs. **Log in before benchmarking:**

```bash
docker login
```

A free Docker Hub account raises the limit to 200 pulls per 6 hours, which is sufficient for both profiles.

## Quick start

```bash
git clone https://github.com/cvidmar/go-ts-bench.git
cd go-ts-bench
chmod +x docker-bench.sh

# Light profile (default)
./docker-bench.sh my-macbook-m2

# Heavy profile
BENCH_PROFILE=heavy ./docker-bench.sh my-macbook-m2
```

The argument is a free-form machine label that ends up in the CSV. If omitted, the hostname is used. Results land in `~/docker-bench/results-<machine>-<profile>-<timestamp>.csv`.

A light run takes roughly 15–25 minutes; a heavy run takes 30–60 minutes on a modern machine, more on a small VPS.

## Configuration

Override any of these via environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `BENCH_PROFILE` | `light` | `light` or `heavy` - selects project set and run counts |
| `WORKDIR` | `$HOME/docker-bench` | Where repos are cloned and CSVs are written |
| `RUNS_COLD` | `5` (light) / `3` (heavy) | Iterations per cold-build measurement |
| `RUNS_WARM` | `8` (light) / `5` (heavy) | Iterations per warm-build measurement |
| `SYNCTHING_REF` | `v2.0.16` | Git ref for Syncthing (light Go) |
| `VERDACCIO_REF` | `v6.5.2` | Git ref for Verdaccio (light TS) |
| `HUGO_REF` | `v0.139.0` | Git ref for Hugo (heavy Go) |
| `DIRECTUS_REF` | `v11.17.4` | Git ref for Directus (heavy TS) |
| `MACHINE_NAME` | hostname | Label used in the CSV (also accepts a positional arg) |
| `BENCH_SCENARIO` | `both` | `cold`, `warm`, or `both` - which scenarios to benchmark |
| `BENCH_PROJECT` | `all` | `go`, `ts`, or `all` - which project to benchmark |
| `BENCH_DEBUG` | `0` | Set to `1` to run a single build with full Docker output (no benchmarking) |
| `BENCH_ARCH` | native | Target platform for `docker build` (e.g. `linux/arm64`, `linux/amd64`) |

Examples:

```bash
# More iterations for a tighter stddev
RUNS_COLD=8 RUNS_WARM=12 ./docker-bench.sh hetzner-ax41

# Heavy profile with custom refs
BENCH_PROFILE=heavy HUGO_REF=v0.140.0 ./docker-bench.sh dev-vm

# Use a different work directory (e.g. a fast NVMe)
WORKDIR=/mnt/nvme/bench ./docker-bench.sh workstation

# Build for amd64 on Apple Silicon (runs under emulation)
BENCH_ARCH=linux/amd64 ./docker-bench.sh m2-emulated

# Only run warm benchmarks for the Go project
BENCH_SCENARIO=warm BENCH_PROJECT=go ./docker-bench.sh my-macbook-m2

# Debug a failing build with full Docker output
BENCH_PROFILE=heavy BENCH_PROJECT=ts BENCH_DEBUG=1 ./docker-bench.sh
```

## Output format

One CSV row per project × scenario, with these columns:

| Column | Notes |
|---|---|
| `machine` | Label you passed in |
| `os` | e.g. `macOS 14.5` or `Ubuntu 24.04 LTS` |
| `cpu` | CPU brand string |
| `cores` | Logical core count |
| `arch` | `arm64`, `x86_64`, etc. |
| `ram_gb` | Total RAM, rounded |
| `docker_version` | Server version |
| `profile` | `light` or `heavy` |
| `project` | e.g. `syncthing`, `verdaccio`, `hugo`, `directus` |
| `scenario` | `cold` or `warm` |
| `commit` | Short SHA of what was actually built |
| `runs` | Number of measured iterations |
| `median_s`, `mean_s`, `stddev_s`, `min_s`, `max_s` | Seconds, from hyperfine |

### Combining results across machines

```bash
# Keep the first header, drop the rest
cat results-*.csv | awk 'NR==1 || !/^machine,/' > combined.csv
```

Open `combined.csv` in a spreadsheet, pivot on `project` + `scenario`, sort by `median_s`.

## Interpreting results

Report the **median**, not the mean. A single network hiccup or background process can pull the mean badly off; the median is robust to outliers.

The **stddev** matters as much as the median. A VPS with noisy neighbors can show a stddev of 20–30% of the median even when the median itself looks competitive - that's worth knowing. As a rough rule of thumb, anything above ~10% of the median means you should rerun, ideally at a different time of day.

The cold vs. warm gap tells you something different from absolute speed: it's roughly your dependency-fetch + compile cost. Two machines with similar warm times but very different cold times usually differ in network or disk, not CPU.

## Caveats

**Architecture matters.** On Apple Silicon, Docker builds for `arm64` by default. Comparing those numbers directly to x86 Linux is comparing different binaries on different ISAs. Either:
- Accept the difference and note `arch` in your write-up (the CSV records it), or
- Force a common platform with `BENCH_ARCH=linux/amd64` - Apple Silicon will then run under emulation and in some cases look much slower, but only in the Typescript benchmarks. This is expected and highlights a fundamental difference between Go and Node.js builds under Docker's cross-platform support. Go has native cross-compilation built into the compiler. When Docker builds with --platform linux/amd64 on arm64, the Go toolchain just sets GOARCH=amd64 and produces amd64 binaries directly on the native CPU. No emulation needed. The difference is essentially noise. In Typescript/Node.js there's no native cross-compilation. When you target linux/amd64 on arm64, Docker runs every Dockerfile instruction under QEMU userspace emulation: every npm install, every native addon compilation (node-gyp), every postinstall script runs as emulated x86_64. A 2x slowdown from QEMU is actually on the mild side; native module compilation (e.g. sharp, bcrypt, better-sqlite3) can be 3-5x slower under emulation.

**Run on an idle machine.** Browsers, Slack, Spotify, Time Machine, `apt unattended-upgrades`, and antivirus scans all add noise that easily swamps real hardware differences. Quit everything you can before benchmarking.

**Disk is often the bottleneck on cheap VPSes.** Network-attached block storage can be an order of magnitude slower than local NVMe for the small-file IO that `npm install` produces. A quick `fio` or `dd` baseline alongside these numbers helps explain anomalies.

**Docker Desktop vs. native.** macOS and Windows run Docker inside a VM. Comparing a Mac running Docker Desktop to a Linux box running native dockerd is partly a comparison of that VM layer. Worth keeping in mind, not necessarily a problem.

**The first ever run on a machine pulls base images over the network.** The script does an untimed warmup build to handle this, but if you wipe `~/docker-bench` or run `docker image prune -a`, the next cold measurement will include the pull again.

## Adding more projects

Open `docker-bench.sh` and add a `benchmark` call near the bottom:

```bash
benchmark "gitea" "https://github.com/go-gitea/gitea.git" "v1.22.3"
```

The function takes `name`, `git_url`, and `git_ref`. The repo must have a `Dockerfile` at its root and a `COPY . ...`-style step somewhere for the warm-build cache buster to take effect. Note that projects using a whitelist `.dockerignore` (e.g. `*` then `!src`) will ignore the `cache-buster` file - for those, you'll need to adjust the `--prepare` line to touch an actual source file instead.

## Sharing results

If you'd like to contribute results, open a PR adding your CSV under `results/` with a brief note about the machine (provider, instance type, anything notable). Keep one CSV per machine; don't pre-aggregate.

## License

MIT. See [LICENSE](LICENSE).
