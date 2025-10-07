#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 SLYD LLC
#
# SLYD Chainloader — minimal bootstrap that fetches wrapper scripts from GitHub and runs them.
# Goal: keep this file tiny; all heavy logic lives in your GitHub repo.
#
# Features:
# - Fetches a repository tarball from GitHub (no git needed)
# - Supports private repos with GIT_TOKEN
# - Selects branch/tag/commit via --ref (default: main)
# - Runs a specified entrypoint path within the repo
# - Pass-through args to entrypoint using the standard `--` separator
#
# Usage (example):
#   sudo bash slyd-chainloader.sh \
#     --repo https://github.com/slyd-cloud/ops-scripts.git \
#     --ref main \
#     --entrypoint scripts/n8n-bootstrap.sh \
#     -- --non-interactive --yes-sul --domain n8n.example.com --email ops@example.com
#
# Private repo:
#   GIT_TOKEN=ghp_xxx sudo -E bash slyd-chainloader.sh --repo https://github.com/slyd-cloud/ops-scripts.git --ref main --entrypoint scripts/n8n-bootstrap.sh -- --non-interactive --yes-sul
#
set -euo pipefail

REPO_URL=""
REF="main"
ENTRYPOINT="scripts/n8n-bootstrap.sh"
WORKDIR="/opt/slyd/chainloader"
DEBUG="${DEBUG:-}"

log() { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err]\033[0m %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (use sudo)."
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  sudo bash slyd-chainloader.sh --repo <URL> [--ref REF] [--entrypoint PATH] [--] [args...]

Options:
  --repo URL           GitHub repo URL (https://github.com/<org>/<repo>[.git])
  --ref REF            Branch / tag / commit (default: main)
  --entrypoint PATH    Path to script inside repo (default: scripts/n8n-bootstrap.sh)
  --workdir DIR        Extraction directory (default: /opt/slyd/chainloader)
  --help               Show help

Auth:
  For private repos over HTTPS, set env: GIT_TOKEN=ghp_xxx
  (uses header: Authorization: token $GIT_TOKEN)

Pass-through:
  Anything after a literal `--` is forwarded to the entrypoint unmodified.

Examples:
  # Public repo, non-interactive flags passed through:
  sudo bash slyd-chainloader.sh \
    --repo https://github.com/slyd-cloud/ops-scripts.git \
    --ref main \
    --entrypoint scripts/n8n-bootstrap.sh \
    -- --non-interactive --yes-sul --domain n8n.example.com --email ops@example.com

  # Private repo (HTTPS) with token:
  GIT_TOKEN=ghp_xxx sudo -E bash slyd-chainloader.sh --repo https://github.com/org/private.git -- --non-interactive --yes-sul
USAGE
}

parse_args() {
  # Split args at the first '--'
  PASS_ARGS=()
  POSITIONAL=()
  SEP_FOUND="no"
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then
      SEP_FOUND="yes"
      continue
    fi
    if [[ "$SEP_FOUND" == "yes" ]]; then
      PASS_ARGS+=("$a")
    else
      POSITIONAL+=("$a")
    fi
  done

  # Parse flags from POSITIONAL
  i=0
  while [[ $i -lt ${#POSITIONAL[@]} ]]; do
    k="${POSITIONAL[$i]}"
    case "$k" in
      -h|--help) usage; exit 0;;
      --repo) REPO_URL="${POSITIONAL[$((i+1))]:-}"; i=$((i+2));;
      --ref|--branch) REF="${POSITIONAL[$((i+1))]:-}"; i=$((i+2));;
      --entrypoint|--path) ENTRYPOINT="${POSITIONAL[$((i+1))]:-}"; i=$((i+2));;
      --workdir) WORKDIR="${POSITIONAL[$((i+1))]:-}"; i=$((i+2));;
      *) err "Unknown option: $k"; usage; exit 1;;
    esac
  done

  [[ -n "$REPO_URL" ]] || die "--repo is required"
}

prepare_system() {
  log "Installing minimal prerequisites (curl, ca-certificates, tar, gzip)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar gzip
}

derive_github_paths() {
  # Accepts: https://github.com/org/repo[.git]
  local url="$1"
  if [[ ! "$url" =~ ^https://github\.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    die "Only HTTPS GitHub URLs are supported by this minimal chainloader. Got: $url"
  fi
  GH_ORG="${BASH_REMATCH[1]}"
  GH_REPO="${BASH_REMATCH[2]}"
  # codeload tarball endpoint
  TARBALL_URL="https://codeload.github.com/${GH_ORG}/${GH_REPO}/tar.gz/${REF}"
}

download_and_extract() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"
  rm -rf repo && mkdir -p repo
  cd repo

  log "Fetching ${GH_ORG}/${GH_REPO}@${REF} tarball..."
  HDR=()
  if [[ -n "${GIT_TOKEN:-}" ]]; then
    HDR+=( -H "Authorization: token ${GIT_TOKEN}" )
    warn "Using GIT_TOKEN for authenticated download."
  fi

  # -L follow redirects, --fail for non-2xx, -o write to file
  curl -sSL --fail "${HDR[@]}" -o repo.tgz "${TARBALL_URL}"

  log "Extracting tarball..."
  tar -xzf repo.tgz
  rm -f repo.tgz

  # Determine top-level extracted folder (org-repo-<hash>)
  TOPDIR="$(find . -maxdepth 1 -mindepth 1 -type d | head -n1)"
  [[ -n "$TOPDIR" ]] || die "Extraction failed (top-level dir not found)."

  SRC="$TOPDIR/$ENTRYPOINT"
  [[ -f "$SRC" ]] || die "Entrypoint not found in repo: $ENTRYPOINT"
  chmod +x "$SRC"

  log "Executing entrypoint: $ENTRYPOINT ${PASS_ARGS[*]:-}"
  if [[ -n "$DEBUG" ]]; then
    set -x
  fi
  bash "$SRC" "${PASS_ARGS[@]}" || die "Entrypoint failed."
}

main() {
  require_root
  parse_args "$@"
  prepare_system
  derive_github_paths "$REPO_URL"
  download_and_extract
  log "Done."
}

main "$@"
