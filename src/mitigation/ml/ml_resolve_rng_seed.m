function seed = ml_resolve_rng_seed(p, requestedSeed)
%ML_RESOLVE_RNG_SEED  Resolve the RNG seed used by ML training helpers.
arguments
    p (1,1) struct
    requestedSeed (1,1) double = NaN
end

if isfinite(requestedSeed)
    seed = double(requestedSeed);
elseif isfield(p, "rngSeed") && isfinite(p.rngSeed)
    seed = double(p.rngSeed);
else
    seed = 1;
end
end
