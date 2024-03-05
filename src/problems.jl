
#   problems
mutable struct DefaultPriceProblem <: AbstractJulESProblem
    long
    medium
    short
    data
    core
    scenario
    long_t
    medium_t
    DefaultPriceProblem(scenario, core, data) = _create_default_price_problem(scenario, core, data)
end

wait(::DefaultPriceProblem) = nothing

# TODO: Add timeings
function solve(p::DefaultPriceProblem, t)
    remotecall_wait(update!, p.core, fetch(p.long), t)
    remotecall_wait(solve!, p.core, fetch(p.long))
    remotecall_wait(transfer_endvalues, p.core, fetch(p.long), fetch(p.medium), fetch(p.long_t))
    remotecall_wait(update!, p.core, fetch(p.medium), t)
    remotecall_wait(solve!, p.core, fetch(p.medium))
    remotecall_wait(transfer_endvalues, p.core, fetch(p.medium), fetch(p.short), fetch(p.medium_t))
    remotecall_wait(update!, p.core, fetch(p.short), t)
    remotecall_wait(solve!, p.core, fetch(p.short))
    return 
end

function transfer_endvalues(pfrom, pto, tfrom)
end