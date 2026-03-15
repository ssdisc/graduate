function cleanupObj = rng_scope(seed)
%RNG_SCOPE  Set a temporary RNG seed and restore the previous state on exit.
arguments
    seed (1,1) double
end

oldRng = rng;
cleanupObj = onCleanup(@() rng(oldRng));
rng(seed, "twister");
end

