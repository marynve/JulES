"""
In-memory process-local database for JulES.

We utilize some of Julia's reflection (names, getfield) 
and metaprogramming (eval, Expr) capabilities to implement 
a database object in the global scope of a Julia process.
We leared this technique from this package: 
https://github.com/ChrisRackauckas/ParallelDataTransfer.jl

The database is just a struct with fields for all the different
things we want to store on cores while running JulES. 
    
The input field holds read-only data that is identical on all cores

The horizons field holds horizon objects, where some of which are stateful 
and managed on a particular core, while others are syncronized copies of
horizons managed on other cores

Some fields hold optimization problems. A problem resides
at exactly one core at a time, but may be moved to antother core 
between time steps. See fields ppp, evp, mp, sp and cp.

Some fields hold info about on which cores problems are stored. 
This also enables transfer of data between e.g. optimizion problems
residing on different cores. See fields ppp_dist, evp_dist, mp_dist, 
sp_dist and cp_core.

Many of the fields contain timing data. This is useful both for results
and to inform dynamic load balancer.

The div field holds a Dict object. Possible extentions of JulES may use
this field to store data.
"""

const _LOCAL_DB_NAME = :_local_db

# TODO: Complete this (add more timings and maybe other stuff)
mutable struct LocalDB
    input::Union{Nothing, AbstractJulESInput}
    horizons::Dict{Tuple{ScenarioIx, TermName, CommodityName}, Horizon}

    dummyobjects::Tuple
    dummyprogobjects::Tuple # TODO: Move summyobjects, scenariogeneration and subsystems to io

    startstates::Dict{String, Float64}
    stepnr_startstates::Int

    subsystems::Vector{AbstractSubsystem}

    simscenmodmethod::AbstractScenarioModellingMethod
    progscenmodmethod::AbstractScenarioModellingMethod
    evscenmodmethod::AbstractScenarioModellingMethod
    stochscenmodmethod::AbstractScenarioModellingMethod

    ppp::Dict{ScenarioIx, PricePrognosisProblem}
    evp::Dict{Tuple{ScenarioIx, SubsystemIx}, EndValueProblem}
    mp::Dict{SubsystemIx, MasterProblem}
    sp::Dict{Tuple{ScenarioIx, SubsystemIx}, ScenarioProblem}
    cp::Union{Nothing, ClearingProblem}

    ppp_dist::Vector{Tuple{ScenarioIx, CoreId}}
    evp_dist::Vector{Tuple{ScenarioIx, SubsystemIx, CoreId}}
    mp_dist::Vector{Tuple{ScenarioIx, CoreId}}
    sp_dist::Vector{Tuple{ScenarioIx, SubsystemIx, CoreId}}
    cp_core::CoreId

    cp_time_solve::Float64
    cp_time_update::Float64
    cp_time_cuts::Float64
    cp_time_startstates::Float64
    cp_time_endstates::Float64

    div::Dict

    function LocalDB()
        return new(
            nothing,   # input
            Dict{Tuple{ScenarioIx, TermName, CommodityName}, Horizon}(),   # horizons

            (),   # dummyobjects
            (),   # dummyprogobjects

            Dict{String, Float64}(),    # startstates
            1,                          # stepnr_startstates

            AbstractSubsystem[],       # subsystems

            NothingScenarioModellingMethod(), # simscenariomodelling
            NothingScenarioModellingMethod(), # progscenariomodelling
            NothingScenarioModellingMethod(), # evscenariomodelling
            NothingScenarioModellingMethod(), # stochscenariomodelling

            Dict{ScenarioIx, PricePrognosisProblem}(),                 # ppp
            Dict{Tuple{ScenarioIx, SubsystemIx}, EndValueProblem}(),   # evp
            Dict{SubsystemIx, MasterProblem}(),                        # mp
            Dict{Tuple{ScenarioIx, SubsystemIx}, ScenarioProblem}(),   # sp
            nothing,   # cp

            Tuple{ScenarioIx, CoreId}[],                # ppp_dist
            Tuple{ScenarioIx, SubsystemIx, CoreId}[],   # evp_dist
            Tuple{SubsystemIx, CoreId}[],               # mp_dist
            Tuple{ScenarioIx, SubsystemIx, CoreId}[],   # sp_dist
            -1,   # cp_core

            -1.0,   # cp_time_solve
            -1.0,   # cp_time_update
            -1.0,   # cp_time_cuts
            -1.0,   # cp_time_startstates
            -1.0,   # cp_time_endstates

            Dict(),   # div
        )
    end
end

function create_local_db()
    if (_LOCAL_DB_NAME in names(Main)) 
        db = getfield(Main, _LOCAL_DB_NAME)
        isnothing(db) || error("$_LOCAL_DB_NAME already exists")
    end
    Core.eval(Main, Expr(:(=), _LOCAL_DB_NAME, LocalDB()))
    return
end

function get_local_db()
    (_LOCAL_DB_NAME in names(Main)) || error("$_LOCAL_DB_NAME has not been created")
    db = getfield(Main, _LOCAL_DB_NAME)
    isnothing(db) && error("$_LOCAL_DB_NAME has been freed")
    return db::LocalDB
end

function free_local_db()
    Core.eval(Main, Expr(:(=), _LOCAL_DB_NAME, nothing))
    return
end