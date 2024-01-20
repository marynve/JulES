
function run_jules!(output, input, cores)
    # extract from input
    dataset = getdataset(input)
    horizons = gethorizons(input)
    subsystems = getsubsystems(input)
    scenarios = getscenarios(input)
    usedprices = getusedprices(subsystems)
    nostorage = getnostorage(input) # states that is not storage

    # initial mappings to cores
    map_scenario_core = get_map_scenario_core(scenarios, cores)
    map_subsystem_cores = get_map_subsystem_cores(subsystems, cores)

    # setup remote storage
    rs_datasets = init_rs_datasets(dataset, cores)
    rs_horizons = init_rs_horizons(horizons, cores, map_scenario_core)
    rs_prices = init_rs_prices(cores, horizons, usedprices)
    rs_endvalues = init_rs_endvalues(subsystems, horizons)
    rs_endstates = init_rs_endstates(nostorage, horizons)
    rs_cuts = init_rs_cuts(subsystems, horizons)

    # setup remote problems
    rp_prices = init_rp_price(map_scenario_core, rs_datasets, rs_horizons) 
    rp_endvalues = init_rp_endvalues(map_scenario_core, subsystems, rs_datasets, rs_horizons)
    rp_stochastic = init_rp_stochastic(map_scenario_core, subsystems, rs_datasets, rs_horizons)

    # setup output
    init_output(output, other_inputs...)

    # simulate
    t = get_simulation_starttime(input)
    steps = get_simulation_steps(input)
    delta = get_simulation_delta(input)
    for step in 1:steps
        solve_price(rp_prices, rs_prices, rs_horizons, t, delta)
        solve_endvalue(rp_endvalues, rs_endvalues, rs_horizons, t, delta)
        solve_stochastic()
        solve_clearing()

        _solve_step!(output, t, step, delta, datasets, proc_scenarios, horizons, transfers, problems)
        t += delta
    end
end


"""
Spawn a copy of the dataset to all cores.
This will enable us to create many optimization problems
locally on a core and let them share data. The data sharing
saves memory, and the local builds is good for performance
due to less data communication.
"""
function spawn_datasets(local_dataset, cores)
    remote_datasets = Dict()
    for core in cores
        remote_datasets[core] = @spawnat core local_dataset
    end
    return datasets
end



function build_price_problems(remote_datasets, remote_horizons, map_scenario_core)
    d = Dict()
    for (s, core) in map_scenario_core
        dataset = remote_datasets[core]
        horizons = remote_horizons[core]
        d[s] = remotecall(build_price_problem, core, fetch(dataset), fetch(horizons))
    end
    return d
end

function build_price_problem(dataset, horizons)
    # build and return priceproblem struct
end


function build_endvalue_problems(remote_datasets, remote_horizons, map_scenario_core, subsystems)
    d = Dict()
    for (s, core) in map_scenario_core
        dataset = remote_datasets[core]
        horizons = remote_horizons[core]
        for sys in subsystems
            d[(sys, s)] = remotecall(build_endvalue_problem, core, fetch(dataset), fetch(horizons), sys)
        end
    end
    return d
end

function build_endvalue_problem(dataset, horizons, sys)
    # build and return priceproblem struct
end

function solve_price_problems(price_problems, t)
    @sync for (core, problem) in price_problems
        @async remotecall(solve!, core, fetch(problem), t)
    end
end

struct PriceProblem
    short
    medium
    long
    endvalues_medium
    endvalues_short
end

function solve!(p::PriceProblem, t)
    update!(p.long, t)
    solve!(p.long)
    transfer_endvalues_long!(p)
    update!(p.medium, t)
    solve!(p.medium)
    transfer_endvalues_medium!(p)
    update!(p.short, t)
    solve!(p.short)
    return
end


function solve_price_problem(problem, t)
    solve!(problem, t)
end
