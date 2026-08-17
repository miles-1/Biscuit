# Development entrypoint. Run with:
#   julia --project=. -t auto -i dev.jl
#
# Revise tracks changes under src/ after `using Biscuit`.
# Oxygen route macros only register on first load; for route edits, restart Julia.

using Revise
using Biscuit

function start_server()
    @async Biscuit.serveparallel(host="127.0.0.1", port=8080)
end

start_server()

stop() = Biscuit.terminate()

function restart()
    Biscuit.terminate()
    start_server()
end

if !isinteractive()
    println("Running in non-interactive mode. Run as `julia --project=. -t auto -i dev.jl` to keep a REPL.")
    exit(0)
end
