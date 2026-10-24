# About this fork

The Redis Data Source in the Grafana plugin catalogue is still version 2.2.0, released in July 2023.
Its backend binaries are built with a 2023 Go standard library and 2023 dependencies, and security
scanners report well over a hundred known vulnerabilities in each of them. The source can be brought
current with a small change. This fork does that, and leaves the plugin's behaviour unchanged.

**The goal is to retire this fork, not maintain it.** Everything here has been offered upstream.
Once a fixed release is published to the Grafana catalogue, switch back to the publisher's signed
plugin. This fork will then be archived.

## The problem

- **The catalogue release is old.** `redis-datasource` 2.2.0 (2023-07-13) is built with go1.19.10
  and `grafana-plugin-sdk-go` v0.164.0.
  - Trivy reports 129 findings in each of its six platform binaries; the linux/amd64 binary has 4
    critical and 48 high.
  - 90 of the 129 are in the Go standard library, so no dependency bump alone would clear them.
- **The newer tag doesn't fix it.** v2.2.1 (tagged 2026-08-18) is on GitHub but was never published
  to the catalogue. Its binaries are built with go1.19.13 and the same SDK, so they carry the same
  findings.
- **Nothing pins the Go version.** The `go` line in `go.mod` sets the minimum language version, not
  the compiler a release is built with. A release links whichever standard library its build machine
  resolves, which is how a 2026 tag shipped a 2023 standard library. The release workflow asked for
  Go 1.19.
- **Signed users can't fix it themselves.** A Grafana plugin signature covers every file in the
  archive. Replacing a binary, or just deleting the five platforms you don't run, makes Grafana refuse
  the plugin as modified. So a team that scans its Grafana image can't clear these findings and keep
  the signed plugin.
- **It has been reported upstream.** Issue 318 reported vulnerabilities in 2024. Pull request 334
  (by monotek) updates the SDK and grpc. Neither has had a maintainer response yet.

## What this fork changes

Two branches, so the part offered upstream stays separate from the parts that only make sense here.

**`deps/go-toolchain-x-net`** is offered upstream. It sits on top of the head of pull request 334:

| Change | Why |
|---|---|
| Pull request 334: `grafana-plugin-sdk-go` v0.164.0 to v0.296.4, grpc v1.83.2, and three lines of Go to fit the new SDK | Brings the SDK and its dependency tree current |
| `golang.org/x/net` v0.59.0 to v0.60.0 | v0.59.0 carries GO-2026-6603, GO-2026-6611, GO-2026-6612 and GO-2026-6617, all reachable from the plugin |
| A `toolchain go1.27.3` line in `go.mod` | Makes the compiler, and so the standard library, part of the source rather than an accident of the build machine |
| Every workflow reads the toolchain with `go-version-file: go.mod`, and the Dockerfile matches | CI, the release build and local builds all link the same standard library. `main.yml`, the release workflow, asked for Go 1.19 |
| A `govulncheck` step in CI | A reachable advisory fails the build, instead of turning up later in a scan of a shipped binary |

**`customerscience`** (the default branch) adds, on top of that:

- [`NOTICE`](NOTICE), which records that this is a modified build, as the Apache License 2.0 asks.
- This file and a pointer to it at the top of the README.
- [`Dockerfile.plugin`](Dockerfile.plugin), which builds an installable plugin directory in one
  command (see below).

## What it doesn't change

- **No query or connection code.** The only Go changes are the three lines pull request 334 needs for
  the new SDK.
- **The frontend is the publisher's own.** `Dockerfile.plugin` takes the frontend from the upstream
  v2.2.1 release archive, unchanged, and checks its SHA-256. No scanner we ran flags it. Rebuilding it
  would need `@grafana/toolkit`, which is retired.
- **The plugin id stays `redis-datasource`.** Dashboards, provisioning files and alert rules that
  refer to it keep working without edits.

## Results

Measured 2026-10-24:

- **Vulnerabilities.** govulncheck (source mode, and binary mode on the built binaries) and trivy
  report **no findings** for linux/amd64 or linux/arm64. The catalogue 2.2.0 reports 129 per binary.
- **Tests.** `go test ./pkg/...` passes.
- **Behaviour.** We ran this build and the signed catalogue 2.2.0 side by side:
  - **Environment:** Grafana 13.2.4, against Redis 8.2 over TLS with a verified CA and a read-only
    ACL user.
  - **Queries:** `HGET`, `HKEYS`, `HGETALL`, query variables built on `HKEYS` and `HGET`, and a missing
    key all returned identical data frames.
  - **Dashboards:** across ten of our own dashboards, all 99 distinct query results were
    identical.
  - **Health and access:** the health check passes, and a write as the read-only user is refused
    with `NOPERM`.

We have only exercised the commands our own dashboards use. Every other command runs unchanged code
against the newer SDK, but we haven't tested it. Please open an issue here if you find a difference.

## Using it

### Build

You need Docker with BuildKit (any current Docker Desktop or Docker Engine):

```bash
git clone --branch customerscience https://github.com/Customer-Science/grafana-redis-datasource.git
cd grafana-redis-datasource
docker build -f Dockerfile.plugin --output type=local,dest=out .
```

This leaves an installable plugin in `out/redis-datasource/`, with backends for linux/amd64 and
linux/arm64. To build for other platforms, add `--build-arg PLATFORMS="linux/amd64 darwin/arm64
windows/amd64"`.

The build stops rather than produce something different from what is described here:

- **Wrong compiler:** the Go image must be the toolchain `go.mod` declares, and `GOTOOLCHAIN=local`
  stops Go downloading a different one.
- **Wrong frontend:** the frontend archive must match its recorded SHA-256.

For a build you can repeat exactly, check out a full commit id rather than the branch.

### Install

Replace any catalogue-installed copy: the new directory takes its place, with the same id. Grafana
only loads an unsigned plugin that you name, so allow this one id, never a wildcard:

```ini
[plugins]
allow_loading_unsigned_plugins = redis-datasource
```

or, as an environment variable:

```bash
GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=redis-datasource
```

In a container image:

```dockerfile
FROM grafana/grafana:13.2.4
COPY --chown=root:root --chmod=0755 out/redis-datasource /var/lib/grafana/plugins/redis-datasource
ENV GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=redis-datasource
```

Owning the files as root means the Grafana server process, which runs as the `grafana` user, can read
and run the plugin but can't change it. `--chmod` keeps the backends executable even when `out/` was
written on Windows, which doesn't record the execute bit.

### What you give up

**You lose the publisher's signature.** A Grafana signature proves that a plugin's files are the ones
its publisher built. With this build, you are trusting your own build of public source instead.
Grafana logs `Permitting unsigned plugin` each time it starts, and the plugin shows as unsigned on the
plugins page.

To get an equivalent assurance, build from a pinned commit, from inputs pinned by digest and hash, and
ship the result in an image you sign yourself. That is how we run it.

### Check it yourself

```bash
govulncheck -mode=binary out/redis-datasource/redis-datasource_linux_amd64
trivy rootfs out/redis-datasource
```

## Status

| | |
|---|---|
| **Upstream** | Offered on pull request 334, with a request for a catalogue release |
| **When to stop using this fork** | As soon as the catalogue has a release newer than 2.2.0 that clears these findings. Install it, signed, and remove the allow-list entry |
| **Issues and pull requests here** | Welcome for dependency and toolchain currency. Feature work and bug fixes belong upstream, so everyone gets them in the signed plugin |

Maintained by [Customer Science](https://github.com/Customer-Science). For questions about this fork,
open an issue here or contact [thegoodwinner](https://github.com/thegoodwinner).
