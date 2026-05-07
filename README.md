# go-ts-bench

A reproducible benchmark for Docker image builds across machines and operating systems. Runs the same two real-world projects — one Go, one TypeScript — through cold and warm build scenarios and emits a CSV you can collate across machines.

Built to compare bare-metal macOS, bare-metal Linux, and Linux VPSes on equal footing, but works anywhere Docker and Bash run.

## What it measures

For each project, two scenarios:

- **Cold build** — build cache wiped before each run (`docker builder prune -af`). Approximates a CI build from scratch. Base images are pulled once during an untimed warmup so the measurement isn't dominated by your network.
- **Warm build** — build cache kept, but a `.cache-buster` file is touched between runs to invalidate the final `COPY` layer. Approximates the inner-loop "I changed one file, rebuild" experience. Dependency layers stay cached; source-dependent steps re-run.

[Hyperfine](https://github.com/sharkdp/hyperfine) drives the timing and reports median, mean, stddev, min, and max across runs.

## Sample projects

| Project | Language | Repo | Why |
|---|---|---|---|
| [Caddy](https://github.com/caddyserver/caddy) | Go | `caddyserver/caddy` | Real-world web server, clean multi-stage Dockerfile, ~1–3 min cold build on a modern laptop. |
| [Excalidraw](https://github.com/excalidraw/excalidraw) | TypeScript | `excalidraw/excalidraw` | Vite + React/TS app. `npm install` exercises small-file IO; the TS/bundler step exercises CPU. |

Both are pinned to specific tags by default (`v2.8.4` and `v0.17.6`) so every machine builds identical source. The actual commit SHA is recorded in the CSV regardless.

If you want longer, heavier workloads to amplify hardware differences, swap in [Gitea](https://github.com/go-gitea/gitea) (Go) and [Cal.com](https://github.com/calcom/cal.com) (TypeScript) — both are 5–15 minute builds.

## Requirements

- Bash 4+ (macOS ships 3.x but the script uses only 3.x-compatible features)
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

## Quick start

```bash
git clone https://github.com/cvidmar/docker-build-bench.git
cd docker-build-bench
chmod +x docker-bench.sh

./docker-bench.sh my-macbook-m2
```

The argument is a free-form machine label that ends up in the CSV. If omitted, the hostname is used. Results land in `~/docker-bench/results-<machine>-<timestamp>.csv`.

A full run takes roughly 15–40 minutes on a modern machine, more on a small VPS.

## Configuration

Override any of these via environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `WORKDIR` | `$HOME/docker-bench` | Where repos are cloned and CSVs are written |
| `RUNS_COLD` | `3` | Iterations per cold-build measurement |
| `RUNS_WARM` | `5` | Iterations per warm-build measurement |
| `CADDY_REF` | `v2.8.4` | Git ref (tag/branch/SHA) for Caddy |
| `EXCALIDRAW_REF` | `v0.17.6` | Git ref for Excalidraw |
| `MACHINE_NAME` | hostname | Label used in the CSV (also accepts a positional arg) |

Examples:

```bash
# More iterations for a tighter stddev
RUNS_COLD=5 RUNS_WARM=10 ./docker-bench.sh hetzner-ax41

# Pin to different versions
CADDY_REF=v2.7.6 EXCALIDRAW_REF=master ./docker-bench.sh dev-vm

# Use a different work directory (e.g. a fast NVMe)
WORKDIR=/mnt/nvme/bench ./docker-bench.sh workstation
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
| `project` | `caddy` or `excalidraw` |
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

The **stddev** matters as much as the median. A VPS with noisy neighbors can show a stddev of 20–30% of the median even when the median itself looks competitive — that's worth knowing. As a rough rule of thumb, anything above ~10% of the median means you should rerun, ideally at a different time of day.

The cold vs. warm gap tells you something different from absolute speed: it's roughly your dependency-fetch + compile cost. Two machines with similar warm times but very different cold times usually differ in network or disk, not CPU.

## Caveats

**Architecture matters.** On Apple Silicon, Docker builds for `arm64` by default. Comparing those numbers directly to x86 Linux is comparing different binaries on different ISAs. Either:
- Accept the difference and note `arch` in your write-up (the CSV records it), or
- Force `--platform=linux/amd64` everywhere — Apple Silicon will then run under emulation and look much slower, which is informative but a different question.

**Run on an idle machine.** Browsers, Slack, Spotify, Time Machine, `apt unattended-upgrades`, and antivirus scans all add noise that easily swamps real hardware differences. Quit everything you can before benchmarking.

**Disk is often the bottleneck on cheap VPSes.** Network-attached block storage can be an order of magnitude slower than local NVMe for the small-file IO that `npm install` produces. A quick `fio` or `dd` baseline alongside these numbers helps explain anomalies.

**Docker Desktop vs. native.** macOS and Windows run Docker inside a VM. Comparing a Mac running Docker Desktop to a Linux box running native dockerd is partly a comparison of that VM layer. Worth keeping in mind, not necessarily a problem.

**The first ever run on a machine pulls base images over the network.** The script does an untimed warmup build to handle this, but if you wipe `~/docker-bench` or run `docker image prune -a`, the next cold measurement will include the pull again.

## Adding more projects

Open `docker-bench.sh` and add a `benchmark` call near the bottom:

```bash
benchmark "gitea" "https://github.com/go-gitea/gitea.git" "v1.22.3"
```

The function takes `name`, `git_url`, and `git_ref`. The repo must have a `Dockerfile` at its root and a `COPY . ...`-style step somewhere for the warm-build cache buster to take effect. If your project's Dockerfile doesn't `COPY` the whole tree, you may need to adjust the `--prepare` line for the warm scenario.

## Sharing results

If you'd like to contribute results, open a PR adding your CSV under `results/` with a brief note about the machine (provider, instance type, anything notable). Keep one CSV per machine; don't pre-aggregate.

## License

MIT. See [LICENSE](LICENSE).
