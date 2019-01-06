using MathOptInterface
const MOI = MathOptInterface
const MOIU = MOI.Utilities

# indices
const VI = MOI.VariableIndex
const CI = MOI.ConstraintIndex
# supported functions
const SVF = MOI.SingleVariable
const SAF = MOI.ScalarAffineFunction{Float64}
# supported sets
const EQS = MOI.EqualTo{Float64}
const GTS = MOI.GreaterThan{Float64}
const LTS = MOI.LessThan{Float64}
const INS = MOI.Interval{Float64}
const BOUNDS = Union{EQS, GTS, LTS, INS}
const BINS = MOI.ZeroOne
const INTS = MOI.Integer
const TYPES = Union{BINS, INTS}
# support changes
const SCC = MOI.ScalarCoefficientChange{Float64}
# other MOI types
const SAT = MOI.ScalarAffineTerm{Float64}

const PtrMap = Dict{Ptr{Cvoid}, Int}
const ConsTypeMap = Dict{Tuple{DataType, DataType}, Vector{Int}}

mutable struct Optimizer <: MOI.AbstractOptimizer
    mscip::ManagedSCIP
    index::PtrMap
    constypes::ConsTypeMap
    params::Dict{String,Any}

    Optimizer() = new(ManagedSCIP(), PtrMap(), ConsTypeMap(), Dict())
end


## convenience functions (not part of MOI)

"Return pointer to SCIP instance."
scip(o::Optimizer) = scip(o.mscip)

"Return pointer to SCIP variable."
var(o::Optimizer, v::VI) = var(o.mscip, v.value)

"Return index of SCIP variable/constraint."
get_index(o::Optimizer, var::Ptr{Cvoid}) = o.index[var]

"Return pointer to SCIP constraint."
cons(o::Optimizer, c::CI{F,S}) where {F,S} = cons(o.mscip, c.value)

"Extract bounds from sets."
bounds(set::EQS) = (set.value, set.value)
bounds(set::GTS) = (set.lower, nothing)
bounds(set::LTS) = (nothing, set.upper)
bounds(set::INS) = (set.lower, set.upper)

"Make set from bounds."
from_bounds(::Type{EQS}, lower, upper) = EQS(lower) # should == upper
from_bounds(::Type{GTS}, lower, upper) = GTS(lower)
from_bounds(::Type{LTS}, lower, upper) = LTS(upper)
from_bounds(::Type{INS}, lower, upper) = INS(lower, upper)

"Register variable in mapping, return variable index."
function register!(o::Optimizer, var::Ptr{SCIP_VAR}, index::Int)
    @assert !haskey(o.index, var)
    o.index[var] = index
    return index
end

"Register constraint in mapping, return constraint index."
function register!(o::Optimizer, c::CI{F,S}) where {F,S}
    if haskey(o.constypes, (F, S))
        push!(o.constypes[F,S], c.value)
    else
        o.constypes[F,S] = [c.value]
    end
    return c
end

"Go back from solved stage to problem modification stage, invalidating results."
function allow_modification(o::Optimizer)
    if SCIPgetStage(scip(o)) != SCIP_STAGE_PROBLEM
        @SC SCIPfreeTransform(scip(o))
    end
    return nothing
end

## general queries and support

MOI.get(::Optimizer, ::MOI.SolverName) = "SCIP"

# variable bounds
MOI.supports_constraint(o::Optimizer, ::Type{SVF}, ::Type{<:BOUNDS}) = true
# variable types (binary, integer)
MOI.supports_constraint(o::Optimizer, ::Type{SVF}, ::Type{<:TYPES}) = true
# linear constraints
MOI.supports_constraint(o::Optimizer, ::Type{SAF}, ::Type{<:BOUNDS}) = true

MOI.supports(::Optimizer, ::MOI.ObjectiveSense) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveFunction{SAF}) = true

MOIU.supports_default_copy_to(model::Optimizer, copy_names::Bool) = !copy_names

struct Param <: MOI.AbstractOptimizerAttribute
    name::String
end
function MOI.set(o::Optimizer, param::Param, value)
    o.params[param.name] = value
    set_parameter(o.mscip, param.name, value)
    return nothing
end

## model creation, query and modification

function MOI.is_empty(o::Optimizer)
    length(o.mscip.vars) == 0 && length(o.mscip.conss) == 0
end

function MOI.empty!(o::Optimizer)
    # free the underlying problem
    finalize(o.mscip)
    # create a new one
    o.mscip = ManagedSCIP()
    # clear auxiliary mapping structures
    o.index = PtrMap()
    o.constypes = ConsTypeMap()
    # reapply parameters
    for pair in o.params
        set_parameter(o.mscip, pair.first, pair.second)
    end
    return nothing
end

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike; kws...)
    MOIU.automatic_copy_to(dest, src; kws...)
end

MOI.get(o::Optimizer, ::MOI.Name) = SCIPgetProbName(scip(o))
MOI.set(o::Optimizer, ::MOI.Name, name::String) = @SC SCIPsetProbName(scip(o), name)

function MOI.add_variable(o::Optimizer)
    allow_modification(o)
    i::Int = add_variable(o.mscip)
    var::Ptr{SCIP_VAR} = o.mscip.vars[i][] # i == end
    register!(o, var, i)
    return MOI.VariableIndex(i)
end

MOI.add_variables(o::Optimizer, n) = [MOI.add_variable(o) for i=1:n]
MOI.get(o::Optimizer, ::MOI.NumberOfVariables) = length(o.mscip.vars)
MOI.get(o::Optimizer, ::MOI.ListOfVariableIndices) = VI.(1:length(o.mscip.vars))
MOI.is_valid(o::Optimizer, vi::VI) = 1 <= vi.value <= length(o.mscip.vars)

MOI.get(o::Optimizer, ::MOI.VariableName, vi::VI) = SCIPvarGetName(var(o, vi))
function MOI.set(o::Optimizer, ::MOI.VariableName, vi::VI, name::String)
    @SC SCIPchgVarName(scip(o), var(o, vi), name)
end

scip_vartype(::Type{BINS}) = SCIP_VARTYPE_BINARY
scip_vartype(::Type{INTS}) = SCIP_VARTYPE_INTEGER
function MOI.add_constraint(o::Optimizer, func::SVF, set::S) where {S <: TYPES}
    allow_modification(o)
    v = var(o, func.variable)
    infeasible = Ref{Ptr{SCIP_Bool}}
    @SC SCIPchgVarType(scip(o), v, scip_vartype(S), infeasible[])
    if S <: BINS
        # need to adjust bounds for SCIP?!
        @SC SCIPchgVarLb(scip(o), v, 0.0)
        @SC SCIPchgVarUb(scip(o), v, 1.0)
    end
    # use var index for cons index of this type
    i = func.variable.value
    return register!(o, CI{SVF, S}(i))
end

function MOI.add_constraint(o::Optimizer, func::SVF, set::S) where S <: BOUNDS
    allow_modification(o)
    v = var(o, func.variable)
    lb, ub = bounds(set)
    lb == nothing || @SC SCIPchgVarLb(scip(o), v, lb)
    ub == nothing || @SC SCIPchgVarUb(scip(o), v, ub)
    # use var index for cons index of this type
    i = func.variable.value
    return register!(o, CI{SVF, S}(i))
end

function MOI.set(o::SCIP.Optimizer, ::MOI.ConstraintSet, ci::CI{SVF,S}, set::S) where {S <: BOUNDS}
    allow_modification(o)
    v = var(o, VI(ci.value)) # cons index is actually var index
    lb, ub = bounds(set)
    lb == nothing || @SC SCIPchgVarLb(scip(o), v, lb)
    ub == nothing || @SC SCIPchgVarUb(scip(o), v, ub)
    return nothing
end

function MOI.is_valid(o::Optimizer, ci::CI{SVF,<:BOUNDS})
    1 <= ci.value <= length(o.mscip.vars)
end

function MOI.add_constraint(o::Optimizer, func::SAF, set::S) where {S <: BOUNDS}
    if func.constant != 0.0
        msg = "SCIP does not support linear constraints with a constant offset."
        throw(MOI.AddConstraintNotAllowed{SAF, S}(msg))
    end

    allow_modification(o)

    varidx = [t.variable_index.value for t in func.terms]
    coefs = [t.coefficient for t in func.terms]

    lhs, rhs = bounds(set)
    lhs = lhs == nothing ? -SCIPinfinity(scip(o)) : lhs
    rhs = rhs == nothing ?  SCIPinfinity(scip(o)) : rhs

    i = add_linear_constraint(o.mscip, varidx, coefs, lhs, rhs)
    ci = CI{SAF, S}(i)
    register!(o, ci)
    register!(o, cons(o, ci), i)
    return ci
end

function MOI.set(o::SCIP.Optimizer, ::MOI.ConstraintSet, ci::CI{SAF,S}, set::S) where {S <: BOUNDS}
    allow_modification(o)

    lhs, rhs = bounds(set)
    lhs = lhs == nothing ? -SCIPinfinity(scip(o)) : lhs
    rhs = rhs == nothing ?  SCIPinfinity(scip(o)) : rhs

    @SC SCIPchgLhsLinear(scip(o), cons(o, ci), lhs)
    @SC SCIPchgRhsLinear(scip(o), cons(o, ci), rhs)

    return nothing
end

function MOI.is_valid(o::Optimizer, ci::CI{SAF,<:BOUNDS})
    1 <= ci.value <= length(o.mscip.cons)
end

function MOI.get(o::Optimizer, ::MOI.NumberOfConstraints{F,S}) where {F,S}
    haskey(o.constypes, (F, S)) ? length(o.constypes[F, S]) : 0
end

function MOI.get(o::Optimizer, ::MOI.ConstraintFunction, ci::CI{SVF, S}) where S <: BOUNDS
    SVF(ci)
end

function MOI.get(o::Optimizer, ::MOI.ConstraintSet, ci::CI{SVF, S}) where S <: BOUNDS
    v = var(o.mscip, ci.value)
    lb, ub = SCIPvarGetLbOriginal(v), SCIPvarGetUbOriginal(v)
    from_bounds(S, lb, ub)
end

function MOI.get(o::Optimizer, ::MOI.ConstraintFunction, ci::CI{SAF, S}) where S <: BOUNDS
    s, cons = scip(o), cons(o, ci)
    nvars::Int = SCIPgetNVarsLinear(s, cons)
    vars = unsafe_wrap(Array{Ptr{SCIP_VAR}}, SCIPgetVarsLinear(s, cons), nvars)
    vals = unsafe_wrap(Array{Float64}, SCIPgetValsLinear(s, cons), nvars)

    terms = [SAT(vals[i], VI(get_index(o, vars[i])))
             for i=1:nvars]
    # can not identify constant anymore (is merged with lhs,rhs)
    return SAF(terms, 0.0)
end

function MOI.get(o::Optimizer, ::MOI.ConstraintSet, ci::CI{SAF, S}) where S <: BOUNDS
    lhs = SCIPgetLhsLinear(scip(o), cons(o, ci))
    rhs = SCIPgetRhsLinear(scip(o), cons(o, ci))
    from_bounds(S, lhs, rhs)
end

function MOI.get(o::Optimizer, ::MOI.ConstraintName, ci::CI{SAF,<:BOUNDS})
    SCIPconsGetName(cons(o, ci))
end

function MOI.set(o::Optimizer, ::MOI.ConstraintName, ci::CI{SAF,<:BOUNDS}, name::String)
    @SC SCIPchgConsName(scip(o), cons(o, ci), name)
end

function MOI.set(o::Optimizer, ::MOI.ObjectiveFunction{SAF}, obj::SAF)
    allow_modification(o)
    s = scip(o)

    # reset objective coefficient of all variables first
    for v in o.mscip.vars
        @SC SCIPchgVarObj(s, v[], 0.0)
    end

    # set new objective coefficients, summing coefficients
    for t in obj.terms
        v = var(o, t.variable_index)
        oldcoef = SCIPvarGetObj(v)
        newcoef = oldcoef + t.coefficient
        @SC SCIPchgVarObj(s, v, newcoef)
    end

    @SC SCIPaddOrigObjoffset(s, obj.constant - SCIPgetOrigObjoffset(s))

    return nothing
end

function MOI.get(o::Optimizer, ::MOI.ObjectiveFunction{SAF})
    terms = SAT[]
    for i = 1:length(o.mscip.vars)
        vi = VI(i)
        coef = SCIPvarGetObj(var(o, vi))
        coef == 0.0 || push!(terms, SAT(coef, vi))
    end
    constant = SCIPgetOrigObjoffset(scip(o))
    return SAF(terms, constant)
end

function MOI.set(o::Optimizer, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense)
    allow_modification(o)
    if sense == MOI.MIN_SENSE
        @SC SCIPsetObjsense(scip(o), SCIP_OBJSENSE_MINIMIZE)
    elseif sense == MOI.MAX_SENSE
        @SC SCIPsetObjsense(scip(o), SCIP_OBJSENSE_MAXIMIZE)
    end
    return nothing
end

function MOI.get(o::Optimizer, ::MOI.ObjectiveSense)
    SCIPgetObjsense(scip(o)) == SCIP_OBJSENSE_MAXIMIZE ?
        MOI.MAX_SENSE :
        MOI.MIN_SENSE
end

function MOI.modify(o::Optimizer, ci::CI{SAF, <:BOUNDS}, change::SCC)
    allow_modification(o)
    @SC SCIPchgCoefLinear(scip(o), cons(o, ci),
                          var(o, change.variable), change.new_coefficient)
    return nothing
end

function MOI.modify(o::Optimizer, ::MOI.ObjectiveFunction{SAF}, change::SCC)
    allow_modification(o)
    @SC SCIPchgVarObj(scip(o), var(o, change.variable),
                      change.new_coefficient)
    return nothing
end

## optimization and results

function MOI.optimize!(o::Optimizer)
    @SC SCIPsolve(scip(o))
    return nothing
end

term_status_map = Dict(
    SCIP_STATUS_UNKNOWN => MOI.OPTIMIZE_NOT_CALLED,
    SCIP_STATUS_USERINTERRUPT => MOI.INTERRUPTED,
    SCIP_STATUS_NODELIMIT => MOI.NODE_LIMIT,
    SCIP_STATUS_TOTALNODELIMIT => MOI.NODE_LIMIT,
    SCIP_STATUS_STALLNODELIMIT => MOI.OTHER_LIMIT,
    SCIP_STATUS_TIMELIMIT => MOI.TIME_LIMIT,
    SCIP_STATUS_MEMLIMIT => MOI.MEMORY_LIMIT,
    SCIP_STATUS_GAPLIMIT => MOI.OTHER_LIMIT,
    SCIP_STATUS_SOLLIMIT => MOI.SOLUTION_LIMIT,
    SCIP_STATUS_BESTSOLLIMIT => MOI.OTHER_LIMIT,
    SCIP_STATUS_RESTARTLIMIT => MOI.OTHER_LIMIT,
    SCIP_STATUS_OPTIMAL => MOI.OPTIMAL,
    SCIP_STATUS_INFEASIBLE => MOI.INFEASIBLE,
    SCIP_STATUS_UNBOUNDED => MOI.DUAL_INFEASIBLE,
    SCIP_STATUS_INFORUNBD => MOI.INFEASIBLE_OR_UNBOUNDED,
    SCIP_STATUS_TERMINATE => MOI.INTERRUPTED,
)

function MOI.get(o::Optimizer, ::MOI.TerminationStatus)
    term_status_map[SCIPgetStatus(scip(o))]
end

function MOI.get(o::Optimizer, ::MOI.PrimalStatus)
    SCIPgetNSols(scip(o)) > 0 ? MOI.FEASIBLE_POINT : MOI.NO_SOLUTION
end

function MOI.get(o::Optimizer, ::MOI.ResultCount)
    status = SCIPgetStatus(scip(o))
    if status in [SCIP_STATUS_UNBOUNDED, SCIP_STATUS_INFORUNBD]
        return 0
    end
    return SCIPgetNSols(scip(o))
end

function MOI.get(o::Optimizer, ::MOI.ObjectiveValue)
    return SCIPgetSolOrigObj(scip(o), SCIPgetBestSol(scip(o)))
end

function MOI.get(o::Optimizer, ::MOI.VariablePrimal, vi::VI)
    return SCIPgetSolVal(scip(o), SCIPgetBestSol(scip(o)), var(o, vi))
end

function MOI.get(o::Optimizer, ::MOI.ConstraintPrimal, ci::CI{SVF,<:BOUNDS})
    return SCIPgetSolVal(scip(o), SCIPgetBestSol(scip(o)), var(o, VI(ci.value)))
end

function MOI.get(o::Optimizer, ::MOI.ConstraintPrimal, ci::CI{SAF,<:BOUNDS})
    return SCIPgetActivityLinear(scip(o), cons(o, ci), SCIPgetBestSol(scip(o)))
end

MOI.get(o::Optimizer, ::MOI.ObjectiveBound) = SCIPgetDualbound(scip(o))
MOI.get(o::Optimizer, ::MOI.RelativeGap) = SCIPgetGap(scip(o))
MOI.get(o::Optimizer, ::MOI.SolveTime) = SCIPgetSolvingTime(scip(o))
MOI.get(o::Optimizer, ::MOI.SimplexIterations) = SCIPgetNLPIterations(scip(o))
MOI.get(o::Optimizer, ::MOI.NodeCount) = SCIPgetNNodes(scip(o))
