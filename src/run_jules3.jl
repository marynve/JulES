abstract type AbstractJulESOutput end
abstract type AbstractJulESInput end
abstract type AbstractJulESData end
abstract type AbstractJulESProblems end

function run_jules(output::AbstractJulESOutput, input::AbstractJulESInput)
    data = init_data(output, input)
    problems = init_problems(output, input, data)
    (start, stop, delta) = get_simulation_period(input)
    (t, i) = (start, 1)
    while t < stop
        solve_step(output, input, data, problems, t, delta, i)
        t += delta
        i += 1
    end
    return
end

# Generic fallbacks
function init_data(output::AbstractJulESOutput, input::AbstractJulESInput)
    data = get_new_data(input)

    cores = get_cores(input)

    @sync for core in cores
        ref = @spawnat core input
        set_input(data, core, ref)
    end

    @sync for core in cores
        input_ref = get_input(data, core)
        ref = remotecall(get_new_transfer, core, fetch(input_ref))
        set_transfer(data, core, ref)
    end

    m = get_scenario_core_map(input)
    set_scenario_core_map(data, m)
    return data
end

function init_problems!(output::AbstractJulESOutput, input::AbstractJulESInput, data::AbstractJulESData)
    problems = get_new_problems(input)
    build_price_problems(problems, output, input, data)
    build_sys_endvalue_problems(problems, output, input, data)
    build_sys_planning_problems(problems, output, input, data)
    build_clearing_problem(problems, output, input, data)
    return problems
end

function build_price_problems(problems::AbstractJulESProblems, output::AbstractJulESOutput, input::AbstractJulESInput, data::AbstractJulESData)
    @sync for (scenario, core) in get_scenario_core_map(data)
        input_ref = get_input(data, core)
        transfer_ref = get_transfer(data, core)
        ref = remotecall(build_price_problem, core, fetch(input_ref), fetch(transfer_ref), scenario, core)
        set_price_problem(problems, scenario, core, ref)
    end
    return
end

function build_price_problem(input::AbstractJulESInput, transfer::AbstractJulESTransfer, scenario::Int, core::Int)
    elements = get_agg_elements(input)
    commodities = get_commodites(input)
    long_elements = copy(elements)
    
    # make elements that refers to initial state
end

# Our concrete implementation
const JULES_KEY_INPUT = "input"
const JULES_KEY_CORES = "cores"
const JULES_KEY_SIMPERIOD = "simperiod"

struct JulESOutput   <: AbstractJulESOutput   ; data::Dict ; JulESOutput()   = Dict() end
struct JulESInput    <: AbstractJulESInput    ; data::Dict ; JulESInput()    = Dict() end
struct JulESData     <: AbstractJulESData     ; data::Dict ; JulESData()     = Dict() end
struct JulESProblems <: AbstractJulESProblems ; data::Dict ; JulESProblems() = Dict() end
struct JulESTransfer <: AbstractJulESTransfer ; data::Dict ; JulESTransfer() = Dict() end

get_cores(input::JulESInput) = input.data[JULES_KEY_CORES]
get_simulation_period(input::JulESInput) = input.data[JULES_KEY_SIMPERIOD]
get_new_data(input::JulESInput) = JulESData()
get_new_problems(input::JulESInput) = JulESProblems()
get_new_transfer(input::JulESInput) = JulESTransfer()


set_input(data::JulESData, core::Int, ref) = data.data[(JULES_KEY_INPUT, core)] = ref ; return
get_input(data::JulESData, core::Int) = data.data[(JULES_KEY_INPUT, core)]
set_transfer(data, core, ref)
get_transfer(data, core, ref)

function build_price_problem()
end

build_sys_endvalue_problems(problems, output, input, data) = nothing
build_sys_planning_problems(problems, output, input, data) = nothing
build_clearing_problem(problems, output, input, data) = nothing


function spawn_horizons(input, owncore)
    d = Dict()
    horizons = gethorizons(input)
    for (scenario, core) in getscenarios(input)
        for ((term, commodity), horizon) in horizons
            horizon = deepcopy(horizon)
            if owncore != core
                horizon = ExternalHorizon(horizon)
            end
            d[(scenario, term, commodity)] = horizon
        end
    end
    return d
end

function spawn_prices(input)
    usedprices = getusedprices(input)
    horizons = gethorizons(input)
    d = Dict()
    for scenario in keys(getscenarios(input))
        for (term, commodity, area) in usedprices
            term == JULES_TERM_CLEARING && continue
            horizon = horizons[(term, commodity)]
            T = getnumperiods(horizon)
            d[(scenario, term, commodity, area)] = zeros(T)
        end
    end
    return d
end

"""
Dual storage balance values for aggregated storages in price prognosis problems.
Used to set endvalus in subsystems models.
"""
function spawn_aggstorageduals(input)
    aggstorages = getaggstorages(input)
    terms = getterms(input)
    horizons = gethorizons(input)
    scenarios = getscenarios(input)
    d = Dict()
    for term in terms
        term == JULES_TERM_SHORT    && continue 
        term == JULES_TERM_CLEARING && continue
        for (aggstorage, commodity) in aggstorages
            horizon = horizons[(term, commodity)]
            T = getnumperiods(horizon)
            for scenario in keys(scenarios)
                d[(scenario, term, aggstorage)] = zeros(T)
            end
        end
    end
    return d
end

function spawn_aggstoragevalues(input)
    storages = getaggstorages(input)
    terms = getterms(input)
    d = Dict()
    for scenario in keys(getscenarios(input))
        for term in terms
            for storage in storages
                d[(scenario, term, storage)] = Ref{Float64}()
            end
        end
    end
    return d
end

function spawn_nostoragevalues(input)
    nostorages = getnostorages(input)
    d = Dict()
    for scenario in keys(getscenarios(input))
        for nostorage in nostorages
            d[(scenario, nostorage)] = Ref{Float64}()
        end
    end
    return d
end
