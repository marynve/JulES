
abstract type JulES_Scenario end
abstract type JulES_Input end
abstract type JulES_Output end
abstract type JulES_PricePrognosisModel end
abstract type JulES_LongTermSubsystemModel end
abstract type JulES_StochasticSubsystemModel end

const _JULES_PRICES = "prices"

function run_jules!(output, input, procs)
    datasets = spawn_datasets(input, procs)

    scenarios = get_scenarios()

    subsystems = get_subsystems()

    horizons = get_horizons()

    price_startstates = spawn_price_prognosis()

    price_prognosis = spawn_price_prognosis()

    subsystem_endvalues = spawn_subsystem_endvalues()

    clearing_cuts = spawn_clearing_cuts()

    procmaps = get_procmaps(procs, input)

    horizons = spawn_horizons(input, procmaps)

    transfers = spawn_transfers(datasets, procmaps, horizons)

    price_problems = build_price_problems(procmaps, datasets, horizons, transfers)

    endvalue_problems = build_endvalue_problems(procmaps, datasets, horizons, transfers)

    planning_problems = build_planning_problems()

    clearing_problem = build_clearing_problem()

    _init_output(output, problems, datasets, proc_scenarios, horizons, transfers)

    t = _get_simulation_starttime(input)
    steps = _get_simulation_steps(input)
    delta = _get_simulation_delta(input)

    for step in 1:steps
        _solve_step!(output, t, step, delta, datasets, proc_scenarios, horizons, transfers, problems)
        t += delta
    end

    return
end


"""
Uses input and procs to simulate JulES and writes
results to output
"""
function run_jules!(output, input, procs)
    datasets = _spawn_datasets(input, procs)

    scenarios = _get_scenarios(input)

    subsystems = _get_subsystems(input)

    proc_scenarios = _get_proc_scenarios(procs, scenarios)


    horizons = _spawn_horizons(input, procs, proc_scenarios)

    transfers = _spawn_transfers(input, procs, proc_scenarios, horizons)

    problems = _remotebuild_problems(input, datasets, horizons, transfers)

    _init_output(output, problems, datasets, proc_scenarios, horizons, transfers)

    t = _get_simulation_starttime(input)
    steps = _get_simulation_steps(input)
    delta = _get_simulation_delta(input)

    for step in 1:steps
        _solve_step!(output, t, step, delta, datasets, proc_scenarios, horizons, transfers, problems)
        t += delta
    end

    return
end

"""
Spawn a copy of the dataset to all procs.
This will enable us to create many optimization problems
locally on procs and let them share data. The data sharing
saves memory, and the local builds is good for performance
due to less data communication.
"""
function _spawn_datasets(input, procs)
    dataset = input[_JULES_DATASET]
    datasets = Dict()
    for p in procs
        datasets[p] = @spawnat p dataset
    end
    return datasets
end

"""
Returns a sequence of historical years.

At the moment we use historical years as scenarios.
In the future, we should support more general scenarios.
E.g. we should suppors scenarios being a combination of 
historical years and e.g. three fuel price levels (high, medium, low).
"""
function _get_scenarios(input)
    startyear = input[_JULES_SCENARIOS]["startyear"]
    num_years = input[_JULES_SCENARIOS]["num_years"]    
    return startyear:(startyear + num_years - 1)
end

"""
Allocate scenarios to procs as evenly as possible.

If the number of procs are greater than the 
number of scenarios, some procs will not be used, and
those that are used, will hold only one scenario.

If the number of scenarios is greater than the number 
of procs, then some or all procs will hold more than one 
scenario.
"""
function _get_proc_scenarios(procs, scenarios)
    d = Dict{Int, Vector{Int}}()
    for (i, s) in enumerate(scenarios)
        j = (i - 1) % length(procs) + 1
        p = procs[j]
        if !haskey(d, p)
            d[p] = Int[]
        end
        push!(d[p], s)
    end
    return d
end

"""
Spawn horizons for all scenarios, terms and commodities on all procs.
Some procs hold the master version of an horizon for one or more scenarios. 
All other versions of the same horizon, are external observers, meaning we
will update the master version and then make sure all observers on other procs
get syncronized with the master version. 
"""
function _spawn_horizons(input, procs, proc_scenarios)
    input_horizons = input[_JULES_HORIZONS]
    output_horizons = Dict()
    for term in keys(input_horizons)
        if !haskey(output_horizons, term)
            output_horizons[term] = Dict()
        end
        for commodity in keys(input_horizons[term])
            if !haskey(output_horizons[term], commodity)
                output_horizons[term][commodity] = Dict()
            end
            for own_p in procs
                for (p, scenarios) in proc_scenarios
                    for s in scenarios
                        # get horizon dependent on proc ownership
                        horizon = input_horizons[term][commodity]
                        if p != own_p
                            horizon = ExternalHorizon(horizon)
                        end
                        # store remote reference
                        if !haskey(output_horizons[term][commodity], s)
                            output_horizons[term][commodity][s] = Dict()
                        end
                        output_horizons[term][commodity][s][p] = @spawnat p horizon
                    end
                end
            end
        end
    end
    return output_horizons
end

"""
With transfers, we mean transfers of data between optimization problems, residing on 
possibly different procs. E.g. price prognosis problems generate prices for scenarios and areas 
that we need to use as input in subsystem models. We store the same transfer data on each proc,
and keep these syncronized. This simplifies moving subsystems around between procs 
in order to balance loads. Model objects in optimization problems will
have references to transfer data residing on the same proc.
"""
function _spawn_transfers(input, procs, proc_scenarios, horizons)
    transfers = Dict()

    # used_prices for term, commodity, scenario
    d = Dict()
    for (term, commodity, scenario, area) in get_used_prices(input)
        T = getnumperiods(input, term, commodity)
        p = scenario_proc[scenario]
        d[(term, commodity, scenario, area)] = remotecall(zeros, p, T)
    end
    transfers["used_prices"] = d

    # price_startstates for term, commodity
    d = Dict()
    for (term, commodity, scenario, area) in get_price_startstates(input)
        T = getnumperiods(input, term, commodity)
        p = scenario_proc[scenario]
        d[(term, commodity, scenario, area)] = remotecall(zeros, p, T)
    end
    transfers["used_prices"] = d

    # price_endstates for term, commodity, scenario

    # price_endvalues for term, commodity, scenario

    # subsystem_endvalues for term, subsystem, scenario

    # subsystem_endstats for term, subsystem, scenario

    # subsystem_startstates for term, subsystem

    # subsystem_cuts for subsystem, scenario

end

function _remotebuild_problems(input, datasets, horizons, transfers)
end

function _init_output(output, problems, datasets, proc_scenarios, horizons, transfers)
end

function _get_simulation_starttime(input)
end

function _get_simulation_steps(input)
end

function _get_simulation_delta(input)
end

function _solve_step!(output, t, step, delta, datasets, proc_scenarios, horizons, transfers, problems)
    _solve_price_problems(output, problems, transfers)

    _update_price_horizons(problems, horizons)

    _transfer_price_horizons(problems, horizons)

    _transfer_price_states(problems, states, horizons)

    _solve_system_problems(output, problems, transfers)

    _transfer_system_states(problems, states, horizons)

    _solve_market_problem(output, problems, transfers)

    _update_market_states(problems, states)
end