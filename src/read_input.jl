# Function registries
const _JULES_DATASETREADERS = Dict{String, Function}()
const _JULES_HORIZONBUILDERS = Dict{String, Function}()

# Parser constants
const _JULES_COMMODITIES = "commodities"
const _JULES_FUNCTION = "function"
const _JULES_DATASET = "dataset"
const _JULES_HORIZONS = "horizons"
const _JULES_SHRINKABLE = "shrinkable"
const _JULES_CLEARING = "clearing"
const _JULES_LONG = "long"
const _JULES_MEDIUM = "medium"
const _JULES_SHORT = "short"
const _JULES_PARTS = "parts"
const _JULES_SCENARIOS = "scenarios"

# Public API
function read_input(filepath)
    config = JSON.parsefile(filepath)
    ret = Dict{String, Any}()
    ret[_JULES_DATASET] = _read_dataset(config[_JULES_DATASET])
    ret[_JULES_HORIZONS] = _read_horizons(config[_JULES_HORIZONS])
    ret[_JULES_SCENARIOS] = _read_scenarios(config[_JULES_SCENARIOS])
    return ret
end

register_datasetreader(name, func) = _register_userfunction(name, func, _JULES_DATASETREADERS)
register_horizonbuilder(name, func) = _register_userfunction(name, func, _JULES_HORIZONBUILDERS)

# Internals
function _register_userfunction(name, func, registry)
    if haskey(registry, name)
        error("Name $name already exists")
    end
    registry[name] = func
    return nothing
end

function _read_dataset(config)
    key = config[_JULES_FUNCTION]
    f = _JULES_DATASETREADERS[key]
    return f(config)
end

function _read_horizons(config)
    horizons = Dict()
    for commodity in keys(config[_COMMODITIES])
        for term in keys(config[_COMMODITIES][commodity])
            if !haskey(horizons, term)
                horizons[term] = Dict()
            end
            key = config[_COMMODITIES][commodity][_JULES_FUNCTION]
            f = _JULES_HORIZONBUILDERS[key]
            horizons[term][commodity] = f(term, commodity, config)
        end
    end
    return horizons
end

function _read_scenarios(config)
    d = Dict()
    d["startyear"] = config["startyear"]
    d["num_years"] = config["num_years"]
    return d
end

# TODO: Clean up filenames
function _readdataset_nve_prognosis(args::Dict{String, Any})
    path = args["folder"]
    year = args["scenarioyear"]
    week = args["week"]

    folder_static = joinpath(path, "static_input")
    folder_week = joinpath(path, "Uke_$week", "input")

    # Aggregated data
    thermal = getelements(JSON.parsefile(joinpath(folder_static, "termisk1.json")), sti_dataset)
    wind_solar = getelements(JSON.parsefile(joinpath(folder_static, "vindsol.json")), sti_dataset)
    consumption = getelements(JSON.parsefile(joinpath(folder_static, "forbruk5.json")), sti_dataset)
    aggregated_hydro = getelements(JSON.parsefile(joinpath(folder_static, "aggdetd2.json")), sti_dataset)

    nuclear = getelements(JSON.parsefile(joinpath(folder_week, "nuclear.json")), sti_dataset1)
    exogenous_prices = getelements(JSON.parsefile(joinpath(folder_week, "exogenprices_prognose1.json")), sti_dataset1)
    fuel_prices = getelements(JSON.parsefile(joinpath(folder_week, "brenselspriser.json")), sti_dataset1)
    transmission = getelements(JSON.parsefile(joinpath(folder_week, "nett.json")))   
    aggregated_hydro_inflow = getelements(JSON.parsefile(joinpath(folder_week, "tilsigsprognoseragg$year.json")), sti_dataset1) 

    common_elements = vcat(exogenous_prices, wind_solar, transmission, consumption, thermal, nuclear, fuel_prices)

    aggregated_elements = vcat(common_elements, aggregated_hydro, aggregated_hydro_inflow)

    # Detailed data
    detailed_hydro_series = getelements(JSON.parsefile(joinpath(folder_static, "tidsserier_detd.json")), sti_dataset)
    detailed_hydro_structure = getelements(JSON.parsefile(joinpath(folder_static, "dataset_detd.json")))

    detailed_hydro_inflow = getelements(JSON.parsefile(joinpath(folder_week, "tilsigsprognoser$(scenarioyear).json")), sti_dataset1)

    detailed_elements = vcat(common_elements, detailed_hydro_series, detailed_hydro_structure, detailed_hydro_inflow)

    # Reservoirs
    reservoir_mapping = JSON.parsefile(joinpath(folder_static, "magasin_elspot.json"))
    detailed_startreservoirs = JSON.parsefile(joinpath(folder_week, "startmagdict.json"))
    aggregated_startreservoirs = JSON.parsefile(joinpath(folder_week, "aggstartmagdict.json"), dicttype=Dict{String, Float64});

    ret = Dict{String, Any}()
    ret["aggregated_elements"] = aggregated_elements
    ret["aggregated_startreservoirs"] = aggregated_startreservoirs
    ret["reservoir_mapping"] = reservoir_mapping
    ret["detailed_startreservoirs"] = detailed_startreservoirs
    ret["detailed_elements"] = detailed_elements

    return ret
end
_JULES_DATASETREADERS["nve_prognosis"] = _readdataset_nve_prognosis

function _buildhorizon_sequential(term, commodity, config)
    shrinkable = config[_JULES_SHRINKABLE]

    duration = config[_COMMODITIES][term]["step"]

    int_period = _get_int_period(term, duration, config, commodity)

    int_period = _get_int_period(term, config)

    horizon = SequentialHorizon(int_period...)

    if shrinkable
        horizon = ShrinkableHorizon(horizon)
    end

    return horizon
end
_JULES_HORIZONBUILDERS["sequential"] = _buildhorizon_sequential

function _buildhorizon_adaptive(term, commodity, config)
    d = config[_COMMODITIES][commodity][term]
    blocks = d["blocks"]
    unit_duration = d["unit_duration"]
    shrinkable = config[_JULES_SHRINKABLE]

    args = d["data"]
    key = args["type"]
    if key == "StaticRHSAHData"
        data = TuLiPa.StaticRHSAHData(
            args["commodity"], 
            todatetime(args["datatime"]), 
            todatetime(args["start"]), 
            todatetime(args["stop"]))

    elseif key == "DynamicExogenPriceAHData"
        data = TuLiPa.DynamicExogenPriceAHData(
            TuLiPa.Id(TuLiPa.BALANCE_CONCEPT, args["balance"]))

    elseif key == "DynamicRHSAHData"
        data = TuLiPa.DynamicRHSAHData(args["commodity"])

    else
        error("Unsupported data: $key")
    end

    args = d["method"]
    key = args["type"]
    if key == "KMeansAHMethod"
        method = TuLiPa.KMeansAHMethod()

    elseif key == "PercentilesAHMethod"
        method = TuLiPa.PercentilesAHMethod(args["percentiles"])

    else
        error("Unsupported method: $key")
    end

    duration = d["period"]

    int_period = _get_int_period(term, duration, config, commodity)

    horizon = AdaptiveHorizon(num_block, unit_duration, 
                              data, method, int_period...)

    if shrinkable
        horizon = ShrinkableHorizon(horizon)
    end

    return horizon
end
_JULES_HORIZONBUILDERS["adaptive"] = _buildhorizon_adaptive

function _get_int_period(term, duration, config, commodity)
    tup(part) = _get_n_duration(part, duration, config, commodity, term)

    if term == _JULES_CLEARING
        return [tup(_JULES_CLEARING)]

    elseif term == _JULES_SHORT
        return [tup(_JULES_CLEARING), tup(_JULES_SHORT)]

    elseif term == _JULES_MEDIUM
        return [tup(_JULES_CLEARING), tup(_JULES_SHORT), tup(_JULES_MEDIUM)]

    elseif term == _JULES_LONG
        return [tup(_JULES_CLEARING), tup(_JULES_SHORT), tup(_JULES_MEDIUM), tup(_JULES_LONG)]
    end
end

function _get_n_duration(part, duration, config, commodity, masterterm)
    len = config[_JULES_PARTS][part]
    if duration >= len
        return (1, len)
    else
        n = len.value / duration.value
        if !isinteger(n)
            error("Period ($duration) don't fit term ($len) for $commodity in $masterterm")
        end
        return (Int(n), duration)
    end
end

