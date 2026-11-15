{
  description = "JETLS.jl, the Julia language server, built and cached for every NixOS channel it supports";

  # No inputs: the nixpkgs channels are pinned in sources.json, which CI keeps
  # current and which lists only channels whose Julia satisfies JETLS's compat.
  outputs =
    { self }:
    let
      sources = builtins.fromJSON (builtins.readFile ./sources.json);
      channels = builtins.attrNames sources.channels;

      genAttrs =
        names: f:
        builtins.listToAttrs (
          map (name: {
            inherit name;
            value = f name;
          }) names
        );

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Same targets the official Julia sysimage is built for, so precompiled
      # caches load on any CPU instead of only on the builder's.
      cpuTargets = {
        x86_64-linux = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)";
        aarch64-linux = "generic;cortex-a57;thunderx2t99;carmel,clone_all;apple-m1,base(3);neoverse-512tvb,base(3)";
      };

      nixpkgsFor =
        channel:
        builtins.fetchTree {
          type = "github";
          owner = "NixOS";
          repo = "nixpkgs";
          inherit (sources.channels.${channel}) rev narHash;
        };

      pkgsFor = system: channel: import (nixpkgsFor channel) { inherit system; };

      build =
        pkgs:
        let
          # The official binaries, not nixpkgs' source build. JETLS loads the
          # analysed project's packages into its own process, and their
          # BinaryBuilder artifacts (JLLs) expect the compiler support libraries
          # upstream Julia bundles. The source build links Nix's GCC runtime
          # instead, whose libgfortran (GCC 14) no longer pulls in libquadmath,
          # so e.g. OpenSpecFun_jll (SpecialFunctions, Distributions) fails to load.
          julia = pkgs.julia-bin;
          juliaCpuTarget = cpuTargets.${pkgs.stdenv.hostPlatform.system};
        in
        {
          inherit julia;
          jetls = pkgs.callPackage ./package.nix {
            inherit julia juliaCpuTarget;
            source = sources.jetls;
          };
          jlfmt = pkgs.callPackage ./jlfmt.nix { inherit julia juliaCpuTarget; };
        };

      versionOf = channel: builtins.substring 6 5 channel; # "nixos-26.05" -> "26.05"
      stableChannels = builtins.sort (a: b: builtins.compareVersions (versionOf a) (versionOf b) < 0) (
        builtins.filter (c: c != "nixos-unstable") channels
      );
      newestStable =
        if stableChannels == [ ] then
          null
        else
          builtins.elemAt stableChannels (builtins.length stableChannels - 1);
      defaultChannel = if newestStable == null then "nixos-unstable" else newestStable;

      # nixos-unstable reports the *upcoming* release (e.g. 26.11), so a release
      # newer than every pinned stable channel means unstable.
      channelFor =
        release:
        if builtins.elem "nixos-${release}" channels then
          "nixos-${release}"
        else if
          builtins.elem "nixos-unstable" channels
          && (newestStable == null || builtins.compareVersions release (versionOf newestStable) > 0)
        then
          "nixos-unstable"
        else
          throw "jetls-nix: NixOS ${release} isn't supported (its Julia doesn't satisfy JETLS's compat ${sources.jetls.juliaCompat}). Available: ${builtins.concatStringsSep ", " channels}";
    in
    {
      # One set per channel: legacyPackages.<system>."nixos-26.05".{jetls,jlfmt,julia}
      legacyPackages = genAttrs systems (
        system: genAttrs channels (channel: build (pkgsFor system channel))
      );

      packages = genAttrs systems (
        system:
        let
          set = self.legacyPackages.${system}.${defaultChannel};
        in
        set // { default = set.jetls; }
      );

      lib = {
        inherit channels;
        # The cached set matching the consumer's NixOS release:
        #   (inputs.jetls-nix.lib.packagesFor pkgs).jetls
        packagesFor =
          pkgs:
          self.legacyPackages.${pkgs.stdenv.hostPlatform.system}.${channelFor pkgs.lib.trivial.release};
      };

      # Builds against the consumer's own Julia. Only cached if that nixpkgs
      # matches a pin in sources.json exactly; prefer lib.packagesFor.
      overlays.default = final: _prev: { inherit (build final) jetls jlfmt; };

      formatter = genAttrs systems (system: (pkgsFor system defaultChannel).nixfmt);
    };
}
