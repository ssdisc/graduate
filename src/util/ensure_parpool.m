function pool = ensure_parpool(nWorkers)
%ENSURE_PARPOOL Ensure a parallel pool exists (optionally with a given size).
%
% pool = ensure_parpool(nWorkers)
%   - nWorkers <= 0: keep existing pool or start a default-size pool
%   - nWorkers > 0 : start/resize pool to exactly nWorkers (best effort)
%
% Returns:
%   pool - parallel.Pool object, or [] if parpool is unavailable / failed.

arguments
    nWorkers (1,1) double {mustBeFinite, mustBeNonnegative} = 0
end

pool = [];

if exist("parpool", "file") ~= 2 || exist("gcp", "file") ~= 2
    warning("Parallel Computing Toolbox not available (parpool/gcp not found). Running serial.");
    return;
end

try
    pool = gcp("nocreate");
catch
    pool = [];
end

if isempty(pool)
    try
        if nWorkers > 0
            pool = parpool("local", nWorkers);
        else
            pool = parpool();
        end
    catch ME
        warning('UTIL:ParpoolStartFailed', ...
            'Failed to start parpool: %s. Running serial.', ME.message);
        pool = [];
    end
    return;
end

if nWorkers > 0 && pool.NumWorkers ~= nWorkers
    try
        delete(pool);
        pool = parpool("local", nWorkers);
    catch ME
        warning('UTIL:ParpoolResizeFailed', ...
            'Failed to resize parpool to %d workers: %s. Using existing pool.', nWorkers, ME.message);
        try
            pool = gcp("nocreate");
        catch
            pool = [];
        end
    end
end

end
