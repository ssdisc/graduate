function [fdNorm, phi0] = resolve_doppler_profile(dopplerCfg, nPaths)
%RESOLVE_DOPPLER_PROFILE  生成每径多普勒（cycles/sample）与初相。

nPaths = max(1, round(double(nPaths)));
mode = "per_path_random";
if isfield(dopplerCfg, "mode")
    mode = lower(string(dopplerCfg.mode));
end

maxNorm = 0;
if isfield(dopplerCfg, "maxNorm")
    maxNorm = abs(double(dopplerCfg.maxNorm));
end
commonNorm = 0;
if isfield(dopplerCfg, "commonNorm")
    commonNorm = double(dopplerCfg.commonNorm);
end

if isfield(dopplerCfg, "pathNorm") && ~isempty(dopplerCfg.pathNorm)
    fdNorm = double(dopplerCfg.pathNorm(:));
    if numel(fdNorm) == 1
        fdNorm = repmat(fdNorm, nPaths, 1);
    elseif numel(fdNorm) ~= nPaths
        error("doppler.pathNorm长度需为1或与径数一致。");
    end
else
    switch mode
        case "common"
            fdNorm = commonNorm * ones(nPaths, 1);
        case "per_path_fixed"
            if nPaths == 1
                fdNorm = commonNorm;
            else
                fdNorm = linspace(-maxNorm, maxNorm, nPaths).';
            end
        case "per_path_random"
            fdNorm = (2*rand(nPaths, 1) - 1) * maxNorm;
        otherwise
            error("未知的doppler.mode: %s", string(mode));
    end
end

if isfield(dopplerCfg, "initialPhaseRad") && ~isempty(dopplerCfg.initialPhaseRad)
    phi0 = double(dopplerCfg.initialPhaseRad(:));
    if numel(phi0) == 1
        phi0 = repmat(phi0, nPaths, 1);
    elseif numel(phi0) ~= nPaths
        error("doppler.initialPhaseRad长度需为1或与径数一致。");
    end
else
    phi0 = 2*pi*rand(nPaths, 1);
end
end

