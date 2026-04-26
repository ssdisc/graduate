function chOut = freeze_channel_realization(chIn)
%FREEZE_CHANNEL_REALIZATION Freeze one packet-independent channel realization.

chOut = chIn;
if ~isfield(chOut, "multipath") || ~isstruct(chOut.multipath) ...
        || ~isfield(chOut.multipath, "enable") || ~chOut.multipath.enable
    return;
end
if ~isfield(chOut.multipath, "pathGainsDb") || isempty(chOut.multipath.pathGainsDb)
    error("multipath enabled requires pathGainsDb.");
end

gDb = double(chOut.multipath.pathGainsDb(:));
amp = 10.^(gDb / 20);
if isfield(chOut.multipath, "rayleigh") && chOut.multipath.rayleigh
    cplxAmp = amp .* (randn(size(amp)) + 1j * randn(size(amp))) / sqrt(2);
    chOut.multipath.pathGainsDb = 20 * log10(max(abs(cplxAmp), 1e-12));
    chOut.multipath.pathPhasesRad = angle(cplxAmp);
    chOut.multipath.rayleigh = false;
elseif ~isfield(chOut.multipath, "pathPhasesRad") || isempty(chOut.multipath.pathPhasesRad)
    chOut.multipath.pathPhasesRad = 2 * pi * rand(size(amp));
end
end
