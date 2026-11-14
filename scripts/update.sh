#!/usr/bin/env bash
# Pin sources.json to the newest JETLS release and to every maintained nixpkgs
# channel whose Julia satisfies that release's `julia` compat.
#
# Needs: nix (with flakes), curl, jq. Set GITHUB_TOKEN to avoid API rate limits.
# Writes `updated=true|false` to $GITHUB_OUTPUT when run in GitHub Actions.
set -euo pipefail

cd "$(dirname "$0")/.."
trap 'rm -f sources.json.tmp' EXIT

# How many stable channels to consider. Two covers the overlap month after a
# release, when the previous channel is still maintained.
STABLE_CHANNELS=${STABLE_CHANNELS:-2}

gh_api() {
  curl -sfL --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/$1"
}

prefetch() { nix flake prefetch --json "$1" | jq -r .hash; }

# --- JETLS ------------------------------------------------------------------
# Release tags are dates (2026-11-14); they're the only refs whose Project.toml
# points every dependency at the vendored copies.
tag=$(gh_api 'repos/aviatesk/JETLS.jl/tags?per_page=100' |
  jq -r '[.[].name | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))] | sort | last')
[[ $tag != null && -n $tag ]] || { echo "no JETLS release tag found" >&2; exit 1; }
jetls_rev=$(gh_api "repos/aviatesk/JETLS.jl/commits/$tag" | jq -r .sha)
jetls_hash=$(prefetch "github:aviatesk/JETLS.jl/$jetls_rev")
compat=$(curl -sfL --max-time 60 \
  "https://raw.githubusercontent.com/aviatesk/JETLS.jl/$jetls_rev/Project.toml" |
  sed -n '/^\[compat\]/,/^\[/{s/^julia *= *"\(.*\)"/\1/p}')
[[ -n $compat ]] || { echo "no julia compat in JETLS $tag" >&2; exit 1; }
echo "JETLS $tag ($jetls_rev), julia compat: $compat" >&2

# --- channels ---------------------------------------------------------------
mapfile -t candidates < <(
  gh_api 'repos/NixOS/nixpkgs/git/matching-refs/heads/nixos-' |
    jq -r '.[].ref | ltrimstr("refs/heads/")' |
    grep -E '^nixos-[0-9]{2}\.[0-9]{2}$' | sort -V | tail -n "$STABLE_CHANNELS"
)
candidates+=(nixos-unstable)

# One Julia to evaluate compat specs with Pkg's own semantics.
checker=$(nix build --no-link --print-out-paths "github:NixOS/nixpkgs/nixos-unstable#julia-bin")/bin/julia

channels='{}'
for ch in "${candidates[@]}"; do
  rev=$(gh_api "repos/NixOS/nixpkgs/git/ref/heads/$ch" | jq -r .object.sha)
  version=$(nix eval --raw "github:NixOS/nixpkgs/$rev#julia.version")
  if "$checker" --startup-file=no -e \
    'using Pkg; exit(VersionNumber(ARGS[1]) in Pkg.Versions.semver_spec(ARGS[2]) ? 0 : 1)' \
    "$version" "$compat"; then
    echo "  $ch: julia $version ok" >&2
    narHash=$(prefetch "github:NixOS/nixpkgs/$rev")
    channels=$(jq --arg ch "$ch" --arg rev "$rev" --arg nh "$narHash" --arg v "$version" \
      '.[$ch] = {rev: $rev, narHash: $nh, julia: $v}' <<<"$channels")
  else
    echo "  $ch: julia $version doesn't satisfy $compat, skipped" >&2
  fi
done

jq -n --arg tag "$tag" --arg rev "$jetls_rev" --arg hash "$jetls_hash" \
  --arg compat "$compat" --argjson channels "$channels" \
  '{jetls: {tag: $tag, rev: $rev, hash: $hash, juliaCompat: $compat}, channels: $channels}' \
  >sources.json.tmp

# Keep the old pin unless the new one has at least one channel.
jq -e '.channels | length > 0' sources.json.tmp >/dev/null ||
  { echo "no compatible channel found" >&2; exit 1; }

if [[ -f sources.json ]] && cmp -s sources.json sources.json.tmp; then
  updated=false
else
  mv sources.json.tmp sources.json
  updated=true
fi
echo "updated=$updated" >&2
[[ -n ${GITHUB_OUTPUT:-} ]] && echo "updated=$updated" >>"$GITHUB_OUTPUT"
exit 0
