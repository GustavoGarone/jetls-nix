{
  lib,
  writeText,
  writeShellApplication,
  julia,
  juliaCpuTarget,
}:
# A stdin -> stdout JuliaFormatter, as editors want it. The JuliaFormatter in
# a channel's pinned General snapshot may predate its own `jlfmt` CLI (2.2), so
# this only uses the long-stable public `format_file`.
let
  env = julia.withPackages.override { inherit juliaCpuTarget; } [ "JuliaFormatter" ];
  inherit (env) projectAndDepot;

  script = writeText "jlfmt.jl" ''
    using JuliaFormatter

    # Nearest .JuliaFormatter.toml from the working directory upwards; Helix
    # runs formatters from the workspace root.
    function find_config(dir)
        while true
            path = joinpath(dir, ".JuliaFormatter.toml")
            isfile(path) && return path
            parent = dirname(dir)
            parent == dir && return nothing
            dir = parent
        end
    end

    # format_file reads the config next to the file itself, so give it a copy.
    mktempdir() do tmp
        file = joinpath(tmp, "stdin.jl")
        write(file, read(stdin))
        config = find_config(pwd())
        config === nothing || cp(config, joinpath(tmp, ".JuliaFormatter.toml"))
        format_file(file)
        write(stdout, read(file))
    end
  '';
in
writeShellApplication {
  name = "jlfmt";
  text = ''
    export JULIA_LOAD_PATH="${projectAndDepot}/project/Project.toml:@stdlib"
    export JULIA_DEPOT_PATH="''${JULIA_DEPOT_PATH-}:${projectAndDepot}/depot"
    unset JULIA_PROJECT
    exec ${lib.getExe julia} --startup-file=no --history-file=no ${script} "$@"
  '';
  passthru = { inherit env julia; };
  meta = {
    description = "Format Julia code from stdin with JuliaFormatter.jl";
    mainProgram = "jlfmt";
  };
}
