function hopInfo = fh_hop_info_from_cfg(fhCfg, nSym)
%FH_HOP_INFO_FROM_CFG  Build symbol-domain hop metadata from FH config.

arguments
    fhCfg (1,1) struct
    nSym (1,1) double {mustBeNonnegative, mustBeInteger}
end

if ~(isfield(fhCfg, "enable") && fhCfg.enable)
    hopInfo = struct("enable", false);
    return;
end

nSym = round(double(nSym));
if fh_is_fast(fhCfg)
    hopInfo = fh_fast_hop_info(fhCfg, nSym);
    return;
end

if ~(isfield(fhCfg, "symbolsPerHop") && ~isempty(fhCfg.symbolsPerHop))
    error("slow FH requires fh.symbolsPerHop.");
end
if ~(isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet))
    error("fh.freqSet must not be empty when FH is enabled.");
end

hopLen = double(fhCfg.symbolsPerHop);
if ~(isscalar(hopLen) && isfinite(hopLen) && abs(hopLen - round(hopLen)) < 1e-12 && hopLen >= 1)
    error("fh.symbolsPerHop must be an integer scalar >= 1, got %g.", hopLen);
end
hopLen = round(hopLen);

nHops = ceil(double(nSym) / double(hopLen));
[freqIdx, pnState] = fh_generate_sequence(nHops, fhCfg);
freqOffsets = double(fhCfg.freqSet(freqIdx));

hopInfo = struct();
hopInfo.enable = true;
hopInfo.mode = "slow";
hopInfo.nHops = nHops;
hopInfo.hopLen = hopLen;
hopInfo.hopLenSamples = [];
hopInfo.freqIdx = freqIdx;
hopInfo.freqOffsets = freqOffsets;
hopInfo.pnState = pnState;
hopInfo.nFreqs = fhCfg.nFreqs;
hopInfo.freqSet = fhCfg.freqSet;
end
