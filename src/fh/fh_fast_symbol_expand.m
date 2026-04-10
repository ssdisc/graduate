function [txExpanded, hopInfo] = fh_fast_symbol_expand(txSym, fhCfg)
%FH_FAST_SYMBOL_EXPAND  Repeat each base symbol across multiple fast-FH hops.

arguments
    txSym (:,1)
    fhCfg (1,1) struct
end

if ~(isfield(fhCfg, "enable") && fhCfg.enable)
    txExpanded = txSym(:);
    hopInfo = struct("enable", false);
    return;
end
if fh_mode(fhCfg) ~= "fast"
    error("fh_fast_symbol_expand only applies to fh.mode='fast'.");
end

hopsPerSymbol = fh_hops_per_symbol(fhCfg);
txExpanded = repelem(txSym(:), hopsPerSymbol, 1);
hopInfo = fh_fast_hop_info(fhCfg, numel(txSym));
end
