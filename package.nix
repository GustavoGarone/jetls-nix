{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeWrapper,
  cacert,
  julia,
  juliaCpuTarget,
  source,
}:
# JETLS release tags vendor every non-stdlib dependency under `vendor/`, and
# point at them with `[sources]` URLs into the same repo. scripts/prepare-env.jl
# turns those into local `path` sources and drops the upstream `[workspace]`
# (whose docs/test projects need unvendored packages), so Pkg resolves the
# server's environment offline, without a registry.
stdenvNoCC.mkDerivation {
  pname = "jetls";
  version = source.tag;

  src = fetchFromGitHub {
    owner = "aviatesk";
    repo = "JETLS.jl";
    inherit (source) rev hash;
  };

  nativeBuildInputs = [
    julia
    makeWrapper
  ];

  dontConfigure = true;

  # The precompile cache is only valid for the exact Julia it was built with,
  # and for the CPU targets listed here. Using the same multi-target list as the
  # Julia sysimage lets one cache serve every machine instead of only the CI's
  # CPU ("native").
  env.JULIA_CPU_TARGET = juliaCpuTarget;

  buildPhase = ''
    runHook preBuild

    share=$out/share/jetls
    mkdir -p $share
    cp -r . $share/src
    chmod -R u+w $share/src

    # An explicit environment (Project + Manifest), not just a directory of
    # packages: Julia can only locate package extensions (e.g. Pkg's REPLExt,
    # which JETLSCore's cache records) through a manifest. Without one, the
    # cache is rejected and rebuilt on every launch.
    julia --startup-file=no ${./scripts/prepare-env.jl} $share/src $share/env

    export HOME=$TMPDIR
    # The trailing ":" appends Julia's default depots, which hold the stdlibs'
    # bundled caches; without them every stdlib (Pkg, ...) would be recompiled.
    # New caches still go to the first entry.
    export JULIA_DEPOT_PATH=$out/share/julia/depot:
    # LibGit2 (loaded by Pkg) wants CA certificates at init, even offline.
    export JULIA_SSL_CA_ROOTS_PATH=${cacert}/etc/ssl/certs/ca-bundle.crt
    export JULIA_PKG_OFFLINE=true JULIA_PKG_PRECOMPILE_AUTO=0 JULIA_PKG_SERVER=""
    # Pkg installs General before resolving if no registry exists, although
    # path sources and stdlibs need none. An empty one satisfies it.
    mkdir -p $out/share/julia/depot/registries/Empty
    cat > $out/share/julia/depot/registries/Empty/Registry.toml <<EOF
    name = "Empty"
    uuid = "6b1b4a6e-7c1c-4a3e-9d43-0d5c1b6c9e10"
    repo = "https://example.invalid/Empty"
    [packages]
    EOF
    export JULIA_LOAD_PATH=$share/env/Project.toml:@stdlib
    # Precompiles every package in the manifest, JETLSCore included: `JETLS` is
    # only a launcher that `Base.require`s it for serve/check/test.
    julia --startup-file=no --history-file=no --project=$share/env -e '
      using Pkg
      Pkg.instantiate()
      Pkg.precompile(; strict = true)
    '

    # Only the compile cache is useful at runtime; drop logs and registries.
    find $out/share/julia/depot -mindepth 1 -maxdepth 1 ! -name compiled -exec rm -rf {} +

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Mirrors the Pkg.Apps shim: an isolated LOAD_PATH (JETLS swaps in the
    # user's `@:@v#.#:@stdlib` itself when analysing a project) and the user's
    # writable depot first, with ours as a read-only cache behind it.
    makeWrapper ${lib.getExe julia} $out/bin/jetls \
      --set JULIA_LOAD_PATH "$share/env/Project.toml:@stdlib" \
      --set JULIA_DEPOT_PATH ":$out/share/julia/depot" \
      --unset JULIA_PROJECT \
      --add-flags "--startup-file=no --history-file=no --threads=auto -m JETLS"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    HOME=$TMPDIR $out/bin/jetls --version | grep -F 'jetls version ${source.tag}'
    runHook postInstallCheck
  '';

  passthru = { inherit julia; };

  meta = {
    description = "Language server for Julia, built on the compiler (JETLS.jl)";
    homepage = "https://github.com/aviatesk/JETLS.jl";
    license = lib.licenses.mit;
    mainProgram = "jetls";
    platforms = julia.meta.platforms;
  };
}
