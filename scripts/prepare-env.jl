# Rewrite [sources] {url, rev, subdir = "vendor/X"} to {path = <relative>} and drop [workspace].
using TOML
root = abspath(ARGS[1]); env = abspath(ARGS[2])
files = [joinpath(root, "Project.toml"); [joinpath(root, "vendor", d, "Project.toml") for d in readdir(joinpath(root, "vendor"))]]
for f in files
    isfile(f) || continue
    p = TOML.parsefile(f)
    delete!(p, "workspace")
    if haskey(p, "sources")
        for (name, s) in p["sources"]
            sub = get(s, "subdir", nothing)
            if haskey(s, "url") && sub !== nothing && startswith(sub, "vendor/")
                p["sources"][name] = Dict("path" => relpath(joinpath(root, sub), dirname(f)))
            elseif haskey(s, "path")
                # in-repo path source: must point inside vendor/ or the root
                target = normpath(joinpath(dirname(f), s["path"]))
                startswith(target, root) || error("$f: source $name points outside the tree: $target")
            else
                error("$f: unsupported source for $name: $s")
            end
        end
    end
    open(io -> TOML.print(io, p; sorted=true), f, "w")
end
# The environment the server runs in: just JETLS (+ TestRunner, run via `julia -m`).
proj = TOML.parsefile(joinpath(root, "Project.toml"))
deps = Dict("JETLS" => proj["uuid"], "TestRunner" => proj["deps"]["TestRunner"])
mkpath(env)
open(joinpath(env, "Project.toml"), "w") do io
    TOML.print(io, Dict(
        "deps" => deps,
        "sources" => Dict("JETLS" => Dict("path" => relpath(root, env)),
                          "TestRunner" => Dict("path" => relpath(joinpath(root, "vendor/TestRunner"), env))),
        "preferences" => get(proj, "preferences", Dict())))
end
