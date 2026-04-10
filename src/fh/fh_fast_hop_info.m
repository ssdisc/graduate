function hopInfo = fh_fast_hop_info(fhCfg, nBaseSymbols)
%FH_FAST_HOP_INFO  Build hop metadata for fast FH with symbol-span repetition.

arguments
    fhCfg (1,1) struct
    nBaseSymbols (1,1) double {mustBeNonnegative, mustBeInteger}
end

if ~(isfield(fhCfg, "enable") && fhCfg.enable)
    hopInfo = struct("enable", false);
    return;
end
if fh_mode(fhCfg) ~= "fast"
    error("fh_fast_hop_info only applies to fh.mode='fast'.");
end

nBaseSymbols = round(double(nBaseSymbols));
hopsPerSymbol = fh_hops_per_symbol(fhCfg);
nHops = nBaseSymbols * hopsPerSymbol;
[freqIdx, pnState] = fh_generate_sequence(nHops, fhCfg);
freqOffsets = fhCfg.freqSet(freqIdx);

hopInfo = struct();
hopInfo.enable = true;
hopInfo.mode = "fast";
hopInfo.nBaseSymbols = nBaseSymbols;
hopInfo.hopsPerSymbol = hopsPerSymbol;
hopInfo.nHops = nHops;
hopInfo.nTxSymbols = nHops;
hopInfo.hopLen = 1;
hopInfo.freqIdx = freqIdx;
hopInfo.freqOffsets = freqOffsets;
hopInfo.pnState = pnState;
hopInfo.nFreqs = fhCfg.nFreqs;
hopInfo.freqSet = fhCfg.freqSet;
hopInfo.combineMode = "mean";
end
