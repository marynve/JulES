# abstract types
abstract type AbstractJulESOutput end
abstract type AbstractJulESInput end
abstract type AbstractJulESProblem end   # interface: solve(p, t) and wait(p)

# system constans
const JULES_KEY_INPUTS = "inputs"
const JULES_KEY_TRANSFERS = "transfers"
const JULES_KEY_SCENARIOS = "scenarios"
const JULES_KEY_SUBSYSTEMS = "subsystems"
const JULES_KEY_HORIZONS = "horizons"
const JULES_KEY_PRICEPROBLEMS = "priceproblems"
const JULES_KEY_ENDVALUEPROBLEMS = "endvalueproblems"
const JULES_KEY_PLANNINGPROBLEMS = "planningproblems"

function run_jules(output::AbstractJulESOutput, input::AbstractJulESInput)
    data = init_data(output, input)
    problems = init_problems(input, data)
    (start, N, delta) = get_simulation_period(input)
    t = start
    for i in 1:N
        solve_step(output, data, problems, t, delta, i)
        t += delta
    end
    return
end

function init_data(output::AbstractJulESOutput, input::AbstractJulESInput)
    default_init_data(output, input)
end

function init_problems(input::AbstractJulESInput, data::Dict)
    default_init_problems(input, data)
end

function solve_step(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    default_solve_step(output, data, problems, t, delta, i)
end

# Our default implementation

"""
Call wait on all values in (possibly nested) Dict
"""
dictwait(x::Any) = wait(x)
dictwait(x::Dict) = map(dictwait, values(x))

function default_init_data(output::AbstractJulESOutput, input::AbstractJulESInput)
    data = Dict()

    data[JULES_KEY_INPUTS] = spawn_inputs(input)
    data[JULES_KEY_TRANSFERS] = spawn_transfers(input)
    data[JULES_KEY_HORIZONS] = spawn_horizons(input)
    data[JULES_KEY_SCENARIOS] = get_scenarios(input)
    data[JULES_KEY_SUBSYSTEMS] = get_subsystems(input)

    # TODO: Maybe preallocate stuff in output here

    return data
end

function spawn_inputs(input::AbstractJulESInput)
    cores = get_cores(input)
    d = Dict()
    @sync for core in cores
        d[core] = @spawnat core input
    end
    return d
end

"""
Spawn an empty Dict on each core. Will be used by
other code to transfer data. E.g. price problems
will write prices to the dict, and subsystem models
will read and use these prices.
"""
function spawn_transfers(input::AbstractJulESInput)
    cores = get_cores(input)
    d = Dict()
    for core in cores
        d[core] = remotecall(Dict, core)
    end
    dictwait(d)
    return d
end

"""
Spawn horizons on all cores for all scenarios, terms and commodities.
For each scenario, we turn off update! behaviour for all horizons 
residing on other cores than the core housing the master version of 
the horizon for the scenario in question. Instead, these horizons are 
updated by other code in a way that keeps them in sync with the master 
version of the horizon.
"""
function spawn_horizons(input::AbstractJulESInput)
    d = Dict()
    cores = get_cores(input)
    horizons = get_horizons(input)
    scenarios = get_scenarios(input)
    for owncore in cores
        d[owncore] = Dict()
        for (scenario, core) in scenarios
            for ((term, commodity), horizon) in horizons
                horizon = deepcopy(horizon)
                if owncore != core
                    horizon = ExternalHorizon(horizon)
                end
                d[owncore][(scenario, term, commodity)] = @spawnat owncore horizon
            end
        end
    end
    dictwait(d)
    return d
end

function default_init_problems(input::AbstractJulESInput, data::Dict)
    problems = Dict()
    problems[JULES_KEY_PRICEPROBLEMS] = spawn_price_problems(input, data)
    problems[JULES_KEY_ENDVALUEPROBLEMS] = spawn_endvalue_problems(input, data)
    problems[JULES_KEY_PLANNINGPROBLEMS] = spawn_planning_problems(input, data)
    problems[JULES_KEY_CLEARINGPROBLEM] = spawn_clearing_problem(input, data)
    return problems
end

function spawn_price_problems(input::AbstractJulESInput, data::Dict)
    scenarios = data[JULES_KEY_SCENARIOS]
    d = Dict()
    for (scenario, core) in scenarios
        d[scenario] = DefaultPriceProblem(scenario, core, data)
    end
    dictwait(d)
    return d
end

function spawn_endvalue_problems(input::AbstractJulESInput, data::Dict)
    scenarios = data[JULES_KEY_SCENARIOS]
    subsystems = data[JULES_KEY_SUBSYSTEMS]
    d = Dict()
    for (scenario, core) in scenarios
        for subsystem in keys(subsystems)
            d[(scenario, subsystem)] = DefaultEndValueProblem(scenario, subsystem, core, data)
        end 
    end
    dictwait(d)
    return d
end

function spawn_planning_problems(input::AbstractJulESInput, data::Dict)
    scenarios = data[JULES_KEY_SCENARIOS]
    subsystems = data[JULES_KEY_SUBSYSTEMS]
    d = Dict()
    for (subsystem, cores) in subsystems
        d[subsystem] = DefaultPlanningProblem(subsystem, cores, data)
    end
    dictwait(d)
    return d
end

function spawn_clearing_problem(input::AbstractJulESInput, data::Dict)
    core = first(get_cores(input))
    problem = DefaultClearingProblem(core, data)
    wait(problem)
    return problem
end

function default_solve_step(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    solve_price_problems(output, data, problems, t, delta, i)
    update_horizons(output, data, problems, t, delta, i)
    transfer_prices(output, data, problems, t, delta, i)
    solve_endvalue_problems(output, data, problems, t, delta, i)
    transfer_endvalues(output, data, problems, t, delta, i)
    solve_planning_problems(output, data, problems, t, delta, i)
    transfer_cuts(output, data, problems, t, delta, i)
    solve_clearing_problem(output, input, data, problems, t, delta, i)
    transfer_state(output, data, problems, t, delta, i)
    update_output(output, data, t, delta, i)
end

function solve_price_problems(output::AbstractJulESOutput, input::AbstractJulESInput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    _solve_dictproblems(problems, t, JULES_KEY_PRICEPROBLEMS)
end

function _solve_dictproblems(problems, t, key)
    d = problems[key]
    for problem in values(d)
        solve(problem, t)
    end
    dictwait(d)
    return
end

function update_horizons(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    # Copy changes in horizons (if any) to all observers
    
    # Need new horizon interface functions in 
    # order to keep remote copies in sync
    # have_changed(::Horizon) = false
    # get_changes(::Horizon) = error()
    # set_changes(::Horizon, changes::Dict) = error()

    return
end

function transfer_prices(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    # write duals for 1:T to data on all cores for all scenarios
    # write states for 1:T to data on all cores for all scenarios
    return
end

function solve_endvalue_problems(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    _solve_dictproblems(problems, t, JULES_KEY_ENDVALUEPROBLEMS)
end

function transfer_endvalues(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    # write duals for endperiod(subsystem) to data on all cores for all scenarios and all subsystems
    return
end

function solve_planning_problems(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    _solve_dictproblems(problems, t, JULES_KEY_PLANNINGPROBLEMS)
end

function transfer_cuts(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    # write cuts from masterproblem to transferdata[clearing_cuts] 
    return
end

function solve_clearing_problem(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    problem = problems[JULES_KEY_CLEARINGPROBLEM]
    solve(problem, t)
    wait(problem)
    return 
end

function transfer_state(output::AbstractJulESOutput, data::Dict, problems::Dict, t::TimeDelta, delta::Millisecond, i::Int)
    # write startstates to transferdata[clearing_problem]
    # write startstates to transferdata[price_problems]
    # write startstates to transferdata[longterm_problems]
    # write startstates to transferdata[planning_problems]
    return
end

# objects needed in default implementation
#   DefaultPriceProblem
#   DefaultEndValueProblem
#   DefaultPlanningProblem
#   DefaultClearingProblem

# methods needed to support default implementation
"""
Returns Tuple{DateTime, DateTime, Millisecond}
"""
function get_simulation_period(input::AbstractJulESInput)
    error("Not implemented")
end

"""
Returns Vector{Int} with cores 
"""
function get_cores(input::AbstractJulESInput)
    error("Not implemented")
end

"""
Returns Dict{Int, Int} with scenario and core 
"""
function get_scenarios(input::AbstractJulESInput)
    error("Not implemented")
end

"""
Returns Dict{Int, Vector{Int}} with subsystem and cores per subsystem
"""
function get_subsystems(input::AbstractJulESInput)
    error("Not implemented")
end


# concrete types

#   input and output 
struct JulESOutput <: AbstractJulESOutput ; data::Dict ; JulESOutput() = Dict() end
struct JulESInput  <: AbstractJulESInput  ; data::Dict ; JulESInput()  = Dict() end

# TODO: Support default implementation for JulESOutput and JulESInput


