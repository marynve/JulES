struct ClearingProblem
    prob
    states
    endstates # startstates in next iteration
end
get_prob(cp::ClearingProblem) = cp.prob
get_states(cp::ClearingProblem) = cp.states
get_endstates(cp::ClearingProblem) = cp.endstates

get_startstates_from_cp() = get_endstates(get_local_db().cp)

function create_cp(db::LocalDB)
    settings = get_settings(db)
    
    # horizons TODO

    elements = get_elements(db.input)
    modelobjects = make_obj(elements, hh, ph)
    add_PowerUpperSlack!(modelobjects)

    for (subix, core) in db.dist_mp # or get list of cuts from each core?
        future = @spawnat core get_cuts_from_sp(subix)
        cuts = fetch(future)

        # Change statevars so that they represents clearing version of objects
        for i in 1:length(cuts.statevars)
            statevar = getvarout(cuts.statevars[i])
            (varid, varix) = getvarout(statevar)

            newt = getnumperiods(gethorizon(modelobjects[varid]))
            cuts.statevars[i].varout = (id, newt)
        end
        cutid = getid(cuts)
        modelobjects[cutid] = cuts
    end

    probmethod = parse_methods(settings["problems"]["clearing"]["solver"])
    prob = buildprob(longprobmethod, longobjects)

    return
end

function solve_cp(T, t, delta, stepnr)
    db = get_local_db()

    if db.core_cp == db.core
        update_startstates_cp(db, stepnr, t)
        update_cuts(db)
        update_nonstoragestates_cp(db)
        update_statedependent_cp(db, stepnr, t)
        update!(db.cp.prob, t)
        set_minstoragevalue!(db.cp.prob, minstoragevaluerule)
        solve!(db.cp.prob)
    end
end

# Util functions for solve_cp ----------------------------------------------------------------------------------
function minstoragevaluerule(storage::Storage)
    minstoragevalues = Dict{String, Float64}()
    minstoragevalues["Battery"] = 0.0
    minstoragevalues["Hydro"] = 0.001
    commodity = getinstancename(getid(getcommodity(getbalance(storage))))
    return get(minstoragevalues, commodity, 0.0)
end

function set_minstoragevalue!(problem::Prob, costrule::Function)
    for modelobject in getobjects(problem)
        if modelobject isa Storage
            id = getid(modelobject)
            balance = getbalance(modelobject)
            horizon = gethorizon(balance)
            T = getnumperiods(horizon)
            coeff = getobjcoeff(problem, id, T)
            cost = costrule(modelobject)
            newcoeff = min(-cost, coeff)
            if !(coeff ≈ newcoeff)
                setobjcoeff!(problem, id, T, newcoeff)
            end
        end
    end
    return
end

function update_statedependent_cp(db, stepnr, t)
    settings = get_settings(db)

    # Statedependent prod and pumping
    init = false
    if stepnr == 1
        init = true
    end

    getstatedependentprod(settings["problems"]["clearing"]) && statedependentprod!(db.cp.prob, db.startstates, init=init)
    getstatedependentpump(settings["problems"]["clearing"]) && statedependentpump!(db.cp.prob, db.startstates)

    # Headlosscosts
    if getheadlosscost(settings["problems"]["clearing"])
        for (_subix, _core) in db.dist_stoch
            future = @spawnat _core get_headlosscost_data(subix, t)
            headlosscost_data = fetch(future)

            for (resid, headlosscost, T) in headlosscost_data
                obj = find_obj_by_id(getobjects(db.cp.prob), resid)
                T = getnumperiods(gethorizon(obj))
                
                setobjcoeff!(db.cp.prob, resid, T, headlosscost)
            end
        end
    end
end

function get_headlosscost_data(subix, t)
    db = get_local_db()

    mp = db.mp[subix]

    return getheadlosscost_data(ReservoirCurveSlopeMethod(), mp.prob, t)
end

function update_nonstoragestates_cp(db)
    scenix = 1 # which scenario to use?

    for (_scenix, _core) in db.dist_ppp
        if scenix == _scenix
            future = @spawnat _core get_nonstoragestates_short(scenix)
            nonstoragestates_short = fetch(future)
            setoutgoingstates!(db.cp.prob, nonstoragestates_short)
        end
    end
end

function get_nonstoragestates_short(scenix)
    db = get_local_db()

    return db.ppp[scenix].nonstoragestates_short
end

function update_cuts(db)
    for (_subix, _core) in db.dist_stoch
        future = @spawnat _core get_cutsdata(subix)
        cutid, constants, slopes = fetch(future)

        cuts_cp = find_obj_by_id(getobjects(db.cp.prob), cutid)
        cuts_cp.constants = constants
        cuts_cp.slopes = slopes

        updatecuts!(db.cp.prob, cuts_cp)
    end
end

function get_cutsdata(subix)
    db = get_local_db()

    cuts = db.mp[subix].cuts
    return (cuts.id, cuts.constants, cuts.slopes)
end

function update_startstates_cp(db, stepnr, t)
    if stepnr == 1 # TODO: Might already be done by stoch or evp
        get_startstates_stoch_from_input(db, t)
    else # TODO: Copies all startstates
        if stepnr != db.stepnr_startstates
            get_startstates_from_cp(db)
            db.stepnr_startstates = stepnr
        end
    end

    set_startstates!(db.cp.prob, get_storages(db.cp.prob), db.startstates)
end

# Util functions create_cp ------------------------------------------------------------------------------------


# TODO: Rename to update_startstates
function get_startstates!(clearing::Prob, detailedrescopl::Dict, enekvglobaldict::Dict, startstates::Dict{String, Float64})
    startstates_ = get_states(getobjects(clearing))
    getoutgoingstates!(clearing, startstates_)
    
    for var in keys(startstates_)
        value = round(startstates_[var], digits=10) # avoid approx 0 negative values, ignored by solvers so no problem?
        startstates[getinstancename(first(getvarout(var)))] = value
    end

    for area in Set(values(detailedrescopl))
        startstates["Reservoir_" * area * "_hydro_reservoir"] = 0.0
    end
    for res in keys(detailedrescopl)
        resname = "Reservoir_" * res
        areaname = "Reservoir_" * detailedrescopl[res] * "_hydro_reservoir"
        startstates[areaname] += startstates[resname] * enekvglobaldict[res]
    end

    # Avoid reservoirs being filled more than max, gives infeasible solution
    # - If aggregated reservoir capacity is lower than the sum capacities
    # - If reservoir is full in model, numerical tolerance can bring variable value slightly over cap
    # - TODO: Add warning/logging if this happens
    for resname in keys(startstates)
        resmax = resname * "_max"
        if haskey(startstates, resmax)
            if startstates[resname] > startstates[resmax]
                startstates[resname] = startstates[resmax]
            end
        end
    end
end