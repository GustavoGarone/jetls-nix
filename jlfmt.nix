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

  # Uses `format_text`, which JuliaFormatter precompiles: `format_file` would
  # handle the config for us but costs ~0.25s of JIT on every (fresh-process)
  # call, a third of the formatter's whole run time.
  script = writeText "jlfmt.jl" ''
    using JuliaFormatter, TOML

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

    # Built lazily: constructing every style up front costs ~0.8s of compilation.
    style(name) =
        name == "yas" ? YASStyle() :
        name == "blue" ? BlueStyle() :
        name == "sciml" ? SciMLStyle() :
        name == "minimal" ? MinimalStyle() :
        name == "default" ? DefaultStyle() :
        error("unknown JuliaFormatter style: $name")

    # Config keys are format_text's keyword arguments, except `style` (a name)
    # and `ignore` (file globs, meaningless for stdin); "nothing" means nothing.
    function options(path)
        path === nothing && return (;)
        kw = Pair{Symbol,Any}[]
        for (k, v) in TOML.parsefile(path)
            k == "ignore" && continue
            v = k == "style" ? style(v) : v == "nothing" ? nothing : v
            push!(kw, Symbol(k) => v)
        end
        return NamedTuple(kw)
    end

    write(stdout, format_text(read(stdin, String); options(find_config(pwd()))...))
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
