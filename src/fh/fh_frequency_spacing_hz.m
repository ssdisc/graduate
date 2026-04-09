function spacingHz = fh_frequency_spacing_hz(fhCfg, waveform)
%FH_FREQUENCY_SPACING_HZ  Resolve the representative FH tone spacing in Hz.

arguments
    fhCfg (1,1) struct
    waveform (1,1) struct
end

if ~(isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet))
    error("fhCfg.freqSet is required to resolve FH frequency spacing.");
end
if ~(isfield(waveform, "symbolRateHz") && isfinite(double(waveform.symbolRateHz)) ...
        && double(waveform.symbolRateHz) > 0)
    error("waveform.symbolRateHz must be a positive finite scalar.");
end

freqSet = unique(sort(double(fhCfg.freqSet(:))));
if numel(freqSet) < 2
    error("fhCfg.freqSet must contain at least two distinct frequency points.");
end

spacingNorm = diff(freqSet);
spacingNorm = spacingNorm(spacingNorm > 0);
if isempty(spacingNorm)
    error("fhCfg.freqSet must contain at least two distinct frequency points.");
end

spacingHz = median(spacingNorm) * double(waveform.symbolRateHz);
if ~(isscalar(spacingHz) && isfinite(spacingHz) && spacingHz > 0)
    error("Resolved FH frequency spacing must be a positive finite scalar.");
end
end
