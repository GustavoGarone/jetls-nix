# Drive a scripted LSP session against `jetls serve`, exercising the requests an
# editor sends while typing, so `--trace-compile` can record what gets compiled.
#
#   julia warmup-session.jl <jetls command...>
#
# Uses a throwaway stdlib-only project, so it runs offline (e.g. in the Nix
# sandbox). Exits non-zero if the server doesn't answer.



const CMD = Cmd(ARGS)

const SAMPLE = """
using Random, Statistics, LinearAlgebra

struct Model{T<:Real}
    weights::Vector{T}
    bias::T
end

predict(m::Model, x::AbstractVector) = dot(m.weights, x) + m.bias

function simulate(n::Int, μ::Float64, σ::Float64; rng = Random.default_rng())
    xs = μ .+ σ .* randn(rng, n)
    return mean(xs), std(xs)
end

function bootstrap(xs::Vector{Float64}, B::Int)
    n = length(xs)
    stats = Vector{Float64}(undef, B)
    for b in 1:B
        idx = rand(1:n, n)
        stats[b] = mean(view(xs, idx))
    end
    return quantile(stats, [0.025, 0.975])
end

function main()
    m, s = simulate(1000, 0.0, 1.0)
    model = Model([1.0, 2.0], 0.5)
    y = predict(model, [m, s])
    ci = bootstrap(randn(500), 200)
    println(y, " ", ci, undefined_name)
end
"""

function frame(io, msg::String)
    write(io, "Content-Length: ", string(ncodeunits(msg)), "\r\n\r\n", msg)
    flush(io)
end

# Minimal JSON writer for the request payloads below (Dicts, Vectors, Strings,
# numbers, Bools, nothing). Avoids depending on a JSON package.
json(x::Nothing) = "null"
json(x::Bool) = x ? "true" : "false"
json(x::Real) = string(x)
json(x::AbstractString) = "\"" * escape_string(x) * "\""
json(x::AbstractVector) = "[" * join(map(json, x), ",") * "]"
json(x::AbstractDict) = "{" * join(("$(json(string(k))):$(json(v))" for (k, v) in x), ",") * "}"

function read_message(io)
    len = 0
    while true
        line = readline(io)
        isempty(line) && eof(io) && return nothing
        line == "" && break
        k, v = split(line, ":"; limit = 2)
        lowercase(k) == "content-length" && (len = parse(Int, strip(v)))
    end
    return String(read(io, len))
end

function main()
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Sample\"\nuuid = \"0b6c5f3e-6f0c-4d9b-9a7e-3c2f1e0d4a5b\"\n")
    mkpath(joinpath(dir, "src"))
    file = joinpath(dir, "src", "Sample.jl")
    write(file, "module Sample\n" * SAMPLE * "end\n")
    root, uri = "file://" * dir, "file://" * file

    proc = open(setenv(`$CMD serve`; dir), "r+")
    inbox = Channel{String}(Inf)
    reader = @async while (m = read_message(proc)) !== nothing
        put!(inbox, m)
    end

    nextid = Ref(0)
    notify(method, params) = frame(proc, json(Dict("jsonrpc" => "2.0", "method" => method, "params" => params)))
    # Send a request and wait for its response, answering server->client
    # requests with null on the way.
    function request(method, params; timeout = 300)
        id = (nextid[] += 1)
        frame(proc, json(Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)))
        deadline = time() + timeout
        while time() < deadline
            isready(inbox) || (sleep(0.01); continue)
            m = take!(inbox)
            if occursin("\"method\"", m) && (r = match(r"\"id\"\s*:\s*(\d+|\"[^\"]*\")", m)) !== nothing &&
               !occursin("\"result\"", m)
                frame(proc, "{\"jsonrpc\":\"2.0\",\"id\":$(r[1]),\"result\":null}")
                continue
            end
            occursin(Regex("\"id\"\\s*:\\s*$id\\b"), m) && return m
        end
        error("no response to $method within $(timeout)s")
    end
    # Wait until the server publishes a non-empty diagnostics set.
    function wait_diagnostics(; timeout = 300)
        deadline = time() + timeout
        while time() < deadline
            isready(inbox) || (sleep(0.05); continue)
            m = take!(inbox)
            occursin("publishDiagnostics", m) && occursin("\"message\"", m) && return true
        end
        @warn "no diagnostics within $(timeout)s"
        return false
    end

    caps = Dict(
        "textDocument" => Dict(
            "publishDiagnostics" => Dict(),
            "completion" => Dict("completionItem" => Dict("snippetSupport" => true)),
            "hover" => Dict("contentFormat" => ["markdown", "plaintext"]),
            "signatureHelp" => Dict(), "definition" => Dict(), "references" => Dict(),
            "documentSymbol" => Dict(), "codeAction" => Dict(), "rename" => Dict(),
            "inlayHint" => Dict(), "documentHighlight" => Dict(), "formatting" => Dict(),
        ),
        "workspace" => Dict("workspaceFolders" => true, "configuration" => true),
    )
    request("initialize", Dict("processId" => getpid(), "rootUri" => root, "capabilities" => caps,
        "workspaceFolders" => [Dict("uri" => root, "name" => "sample")]))
    notify("initialized", Dict())

    text = read(file, String)
    lines = split(text, '\n')
    version = Ref(1)
    notify("textDocument/didOpen", Dict("textDocument" => Dict(
        "uri" => uri, "languageId" => "julia", "version" => 1, "text" => text)))
    wait_diagnostics()

    pos(line, col) = Dict("line" => line, "character" => col)
    td = Dict("uri" => uri)
    find(s) = findfirst(l -> occursin(s, l), lines) - 1
    L = find("ci = bootstrap")

    function edit(newline)
        version[] += 1
        new = [lines[1:L+1]; newline; lines[L+2:end]]
        notify("textDocument/didChange", Dict("textDocument" => Dict("uri" => uri, "version" => version[]),
            "contentChanges" => [Dict("text" => join(new, '\n'))]))
    end

    for round in 1:2
        for s in ("    z = m", "    z = me", "    z = mea", "    w = Model(", "    q = predict(model, ")
            edit(s)
            request("textDocument/completion", Dict("textDocument" => td, "position" => pos(L + 1, length(s))))
            request("textDocument/signatureHelp", Dict("textDocument" => td, "position" => pos(L + 1, length(s))))
        end
        for (needle, col) in (("y = predict", 9), ("ci = bootstrap", 11), ("m, s = simulate", 12), ("struct Model", 8))
            l = find(needle)
            p = Dict("textDocument" => td, "position" => pos(l, col))
            request("textDocument/hover", p)
            request("textDocument/definition", p)
            request("textDocument/references", merge(p, Dict("context" => Dict("includeDeclaration" => true))))
            request("textDocument/documentHighlight", p)
        end
        request("textDocument/documentSymbol", Dict("textDocument" => td))
        request("textDocument/codeAction", Dict("textDocument" => td,
            "range" => Dict("start" => pos(L, 0), "end" => pos(L, 10)), "context" => Dict("diagnostics" => [])))
        request("textDocument/inlayHint", Dict("textDocument" => td,
            "range" => Dict("start" => pos(0, 0), "end" => pos(length(lines), 0))))
        # Restore the text and save: triggers the full re-analysis.
        version[] += 1
        notify("textDocument/didChange", Dict("textDocument" => Dict("uri" => uri, "version" => version[]),
            "contentChanges" => [Dict("text" => text)]))
        notify("textDocument/didSave", Dict("textDocument" => td))
        wait_diagnostics()
    end

    request("shutdown", nothing)
    notify("exit", nothing)
    for _ in 1:300
        process_exited(proc) && break
        sleep(0.1)
    end
    process_exited(proc) || kill(proc)
    println(stderr, "warm-up session finished")
end

main()
