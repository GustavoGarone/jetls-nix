# Caches the code JETLS compiles while serving an editor. JETLS's own package
# images don't cover its request handlers, so each new server session JITs them
# on first use (seconds for the first completion, hover, save, ...). The
# statements in precompile.jl were recorded with --trace-compile during a
# scripted LSP session (scripts/warmup-session.jl); precompiling them here
# stores that code in this package's image, which Julia (>= 1.9) uses for
# methods owned by other packages too.
module JETLSWarmup

using JETLS: JETLS
using JETLSCore: JETLSCore

# The recorded statements name types by their full module paths; make every
# loaded module reachable from here.
for m in Base.loaded_modules_array()
    n = nameof(m)
    isdefined(@__MODULE__, n) || Core.eval(@__MODULE__, :(const $n = $m))
end

let ok = 0, skipped = 0
    for line in eachline(joinpath(@__DIR__, "precompile.jl"))
        startswith(line, "precompile(") || continue
        try
            Core.eval(@__MODULE__, Meta.parse(line)) ? (ok += 1) : (skipped += 1)
        catch
            # Mentions something not loaded here (e.g. the sample project).
            skipped += 1
        end
    end
    @info "JETLSWarmup: precompiled $ok statements, skipped $skipped"
end

(@main)(args::Vector{String}) = JETLS.main(args)

end
