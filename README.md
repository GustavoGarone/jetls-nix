# jetls-nix

[JETLS.jl](https://github.com/aviatesk/JETLS.jl), the compiler-powered Julia
language server, plus JuliaFormatter's `jlfmt`, built with Nix and cached for
**every maintained NixOS channel whose Julia JETLS supports**.

No `~/.julia` setup and no `Pkg.Apps`. The Julia is pinned by store path, so a
Julia upgrade plus garbage collection can't break the server.

## Use

```nix
# flake.nix: don't override this flake's inputs (it has none); its pinned
# nixpkgs are what makes the cache hit.
inputs.jetls-nix.url = "github:GustavoGarone/jetls-nix";
```

```nix
# Picks the set built for your NixOS release (nixos-26.05, …, or unstable).
let jl = inputs.jetls-nix.lib.packagesFor pkgs; in
{
  home.packages = [ jl.julia ];   # same Julia JETLS runs on (optional)

  programs.helix.languages = {
    language-server.jetls = { command = lib.getExe jl.jetls; args = [ "serve" ]; };
    language = [{
      name = "julia";
      language-servers = [ "jetls" ];
      auto-format = true;
      formatter.command = lib.getExe jl.jlfmt;
    }];
  };
}
```

Binary cache:

```nix
nix.settings = {
  substituters = [ "https://jetls-nix.cachix.org" ];
  trusted-public-keys = [ "jetls-nix.cachix.org-1:NV1wdLix0eRK1BXK+kslibtvBJqKc4DQ7RBcMHByIgs=" ];
};
```

Other outputs:
- `legacyPackages.<system>."nixos-26.05".{jetls,jlfmt,julia}`: every pinned channel.
- `packages.<system>.{jetls,jlfmt,julia}`: the newest stable channel.
- `overlays.default`: `jetls`/`jlfmt` built with *your* `julia`. It's only cached if your nixpkgs matches a pin exactly.

`lib.channels` lists the supported channels. If your release's Julia doesn't satisfy
JETLS's `julia` compat (e.g. nixos-25.11 ships 1.12.1), `packagesFor` throws an error
that says so.

## How it works

- JETLS release tags vendor all non-stdlib dependencies under `vendor/`.
  `package.nix` exposes them as a Julia implicit environment (a directory of
  packages). It precompiles `JETLS`, `JETLSCore` and `TestRunner` into a depot in the
  store for the same multi-CPU targets as the Julia sysimage. At runtime that
  depot is a read-only cache behind your `~/.julia`.
- `jlfmt` comes from `julia.withPackages ["JuliaFormatter"]`. When it reads stdin, it
  looks for `.JuliaFormatter.toml` upward from the working directory.
- `sources.json` pins the JETLS tag and one nixpkgs revision per channel.
  `scripts/update.sh` regenerates it. It takes the newest JETLS tag, then the two
  newest `nixos-YY.MM` branches plus `nixos-unstable`, and keeps those whose `julia`
  satisfies JETLS's compat (checked with `Pkg.Versions`).
- `.github/workflows/update.yml` runs daily. It updates the pins, builds every
  channel in parallel, pushes to Cachix, and commits `sources.json` only if all
  channels build.

## Setup (once)

1. Create a public cache at <https://app.cachix.org> (name it `jetls-nix`, or change
   `CACHIX_NAME` in the workflow).
2. Add a `CACHIX_AUTH_TOKEN` repository secret with a write token for it.
3. Put the cache's public key in the consumer's `trusted-public-keys`.

## Local

```sh
./scripts/update.sh                                      # needs nix, curl, jq
nix build '.#legacyPackages.x86_64-linux."nixos-26.05".jetls'
```
