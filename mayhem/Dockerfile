# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. uber-go/atomic is a pure-Go project, so the base
# (C/C++ only — NO Go toolchain) needs Go added here as a USER root step, then the OSS-Fuzz
# Go fuzzing tooling (go-118-fuzz-build) that turns the native Go fuzz harness into a
# libFuzzer-instrumented binary linked with $LIB_FUZZING_ENGINE.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t atomic-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# NOTE: the OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); the Go fuzz
# binary is built with ASan and links the libFuzzer engine. build.sh handles the Go specifics.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the Go toolchain version AND its tarball sha256 (reproducible fetch).
# atomic's module is `go 1.18`; GOTOOLCHAIN=local keeps this exact toolchain.
# Go 1.23.4 satisfies the `go 1.18` directive and builds cleanly with go-118-fuzz-build.
ARG GO_VERSION=1.23.4
ARG GO_SHA256=6924efde5de86fe277676e929dc9917d466efa02fb934197bc2eba35d5680971

# Pin go-118-fuzz-build by COMMIT (not @latest) so the module cache populated at this build is
# deterministic and reproducible across rebuilds. NOTE: the repo's "release" git TAG is a stale
# 2022 snapshot (predates the .../testing subpackage this harness needs, and still shells out to
# a "gotip" binary that isn't on PATH here) — pin to a specific commit on `main` instead (resolved
# 2026-07-04; contains the /testing shim and the "go" (not gotip) exec.Command path).
ARG GO118_FUZZ_BUILD_VERSION=a70c2aa677fa43583571959478decabe02a96cd6

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ──────────────────────────────────
# SPEC §6.2 item 8 + §6.5: commit build and PATCH re-run run under different $HOMEs.
# Pinning GOROOT/GOPATH/GOMODCACHE/GOCACHE under /opt/toolchains ensures the module cache
# populated during the first (online) image build is found again when build.sh re-runs offline.
ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin

# ── Install Go + the OSS-Fuzz Go fuzzing build tool (root step) ────────────────────────────────
# The base image is C/C++-only; replicate OSS-Fuzz base-builder-go's install_go.sh:
#   * official go tarball -> /opt/toolchains/go (PATH'd, $HOME-independent)
#   * go-118-fuzz-build    — builds the native `func FuzzX(f *testing.F)` harness
#     (atomic's OSS-Fuzz target FuzzTest is this native style: compile_native_go_fuzzer)
#   Pinned by commit (GO118_FUZZ_BUILD_VERSION), not @latest, for a deterministic module cache.
USER root
RUN install -d /opt/toolchains/go-path \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && go version \
    && go install "github.com/AdamKorcz/go-118-fuzz-build@${GO118_FUZZ_BUILD_VERSION}" \
    && ls -la "$(go env GOPATH)/bin" \
    && chmod -R a+rX /opt/toolchains/go \
    && chown -R 2000:2000 /opt/toolchains/go-path \
    && go clean -cache 2>/dev/null || true

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run atomic's own Go test suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
