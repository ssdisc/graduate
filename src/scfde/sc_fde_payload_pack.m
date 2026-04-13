function [txSymbols, plan] = sc_fde_payload_pack(dataSymbols, cfg, pktIdx)
%SC_FDE_PAYLOAD_PACK  Insert per-hop CP and pilots before slow FH.

arguments
    dataSymbols (:,1)
    cfg (1,1) struct
    pktIdx (1,1) double {mustBePositive, mustBeInteger}
end

dataSymbols = dataSymbols(:);
plan = sc_fde_payload_plan(numel(dataSymbols), cfg);
if ~plan.enable
    txSymbols = dataSymbols;
    return;
end

txSymbols = complex(zeros(plan.nTxSymbols, 1));
if plan.nTxSymbols == 0
    return;
end

srcPos = 1;
for hopIdx = 1:plan.nHops
    dataStop = min(numel(dataSymbols), srcPos + plan.dataSymbolsPerHop - 1);
    if dataStop >= srcPos
        dataChunk = dataSymbols(srcPos:dataStop);
    else
        dataChunk = complex(zeros(0, 1));
    end
    srcPos = dataStop + 1;
    if numel(dataChunk) < plan.dataSymbolsPerHop
        dataChunk = [dataChunk; complex(zeros(plan.dataSymbolsPerHop - numel(dataChunk), 1))];
    end

    pilot = sc_fde_payload_pilot_symbols(cfg, pktIdx, hopIdx);
    core = [pilot; dataChunk];
    if numel(core) ~= plan.coreLen
        error("SC-FDE core length mismatch while packing payload.");
    end

    if plan.cpLen > 0
        cp = core(end - plan.cpLen + 1:end);
    else
        cp = complex(zeros(0, 1));
    end
    block = [cp; core];
    dst = (hopIdx - 1) * plan.hopLen + (1:plan.hopLen);
    txSymbols(dst) = block;
end
end
