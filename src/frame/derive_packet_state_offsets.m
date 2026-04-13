function offsets = derive_packet_state_offsets(p, pktIdx)
%DERIVE_PACKET_STATE_OFFSETS  精确计算当前分包之前的连续状态偏移。
%
% 用途：
%   1) PN扰码：返回当前包起点对应的累计比特偏移；
%   2) 跳频：返回当前包起点对应的累计hop偏移。
%
% 该函数按“整个会话一条连续数据流”的语义计算偏移，但只依赖
% 当前配置和packetIndex，便于接收端按包重建状态。

arguments
    p (1,1) struct
    pktIdx (1,1) double {mustBePositive, mustBeInteger}
end

pktIdx = max(1, round(double(pktIdx)));

nominalPayloadBits = local_nominal_payload_bits(p);
sessionHeaderLenBits = local_session_header_length_bits(p.frame);
bitsPerSym = local_bits_per_symbol(p.mod);
fhEnabled = local_fh_enabled(p);
scFdeCfg = sc_fde_payload_config(p);

scrambleOffsetBits = 0;
dsssOffsetChips = 0;
fhOffsetHops = 0;

for prevIdx = 1:(pktIdx - 1)
    prevPacketBits = nominalPayloadBits;
    if local_has_session_header(p.frame, prevIdx)
        prevPacketBits = prevPacketBits + sessionHeaderLenBits;
    end
    scrambleOffsetBits = scrambleOffsetBits + prevPacketBits;

    if fhEnabled
        codedBitsLen = local_coded_bits_length(prevPacketBits, p.fec);
        [codedBitsInt, ~] = interleave_bits(zeros(codedBitsLen, 1, "uint8"), p.interleaver);
        nBaseSymPrev = ceil(numel(codedBitsInt) / bitsPerSym);
        nSymPrev = dsss_symbol_count(nBaseSymPrev, p.dsss);
        fhOffsetHops = fhOffsetHops + local_packet_fh_hop_count(p.fh, p.waveform, nSymPrev, scFdeCfg);
        dsssOffsetChips = dsssOffsetChips + nSymPrev;
    elseif isfield(p, "dsss") && isstruct(p.dsss)
        codedBitsLen = local_coded_bits_length(prevPacketBits, p.fec);
        [codedBitsInt, ~] = interleave_bits(zeros(codedBitsLen, 1, "uint8"), p.interleaver);
        nBaseSymPrev = ceil(numel(codedBitsInt) / bitsPerSym);
        dsssOffsetChips = dsssOffsetChips + dsss_symbol_count(nBaseSymPrev, p.dsss);
    end
end

offsets = struct();
offsets.packetIndex = pktIdx;
offsets.nominalPayloadBits = nominalPayloadBits;
offsets.sessionHeaderLenBits = sessionHeaderLenBits;
offsets.hasSessionHeader = local_has_session_header(p.frame, pktIdx);
offsets.scrambleOffsetBits = scrambleOffsetBits;
offsets.dsssOffsetChips = dsssOffsetChips;
offsets.fhOffsetHops = fhOffsetHops;
end

function tf = local_has_session_header(frameCfg, pktIdx)
tf = packet_has_session_header(frameCfg, pktIdx);
end

function nBits = local_nominal_payload_bits(p)
nBits = 0;
if isfield(p, "packet") && isstruct(p.packet) && isfield(p.packet, "enable") && p.packet.enable
    if isfield(p.packet, "payloadBitsPerPacket") && ~isempty(p.packet.payloadBitsPerPacket)
        nBits = max(8, round(double(p.packet.payloadBitsPerPacket)));
    else
        nBits = 4096;
    end
    nBits = 8 * floor(nBits / 8);
end
end

function nBits = local_session_header_length_bits(frameCfg)
if ~session_header_enabled(frameCfg)
    nBits = 0;
    return;
end
nBits = 16 + 16 + 16 + 8 + 8 + 32 + 16 + 16 + 16 + 16 + 16;
end

function tf = local_fh_enabled(p)
tf = isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && p.fh.enable;
end

function nHops = local_packet_fh_hop_count(fhCfg, ~, nSym, scFdeCfg)
nSym = max(0, round(double(nSym)));
if nSym <= 0
    nHops = 0;
    return;
end
if nargin >= 4 && isstruct(scFdeCfg) && isfield(scFdeCfg, "enable") && logical(scFdeCfg.enable)
    scFdePlan = sc_fde_payload_plan(nSym, scFdeCfg);
    nHops = double(scFdePlan.nHops);
    return;
end
if fh_is_fast(fhCfg)
    nHops = double(nSym) * double(fh_hops_per_symbol(fhCfg));
    return;
end
if ~(isfield(fhCfg, "symbolsPerHop") && ~isempty(fhCfg.symbolsPerHop))
    error("Slow FH requires fh.symbolsPerHop.");
end
nHops = ceil(double(nSym) / double(fhCfg.symbolsPerHop));
end

function nBits = local_coded_bits_length(nInfoBits, fec)
nBits = fec_coded_bits_length(nInfoBits, fec);
end

function bitsPerSym = local_bits_per_symbol(mod)
switch upper(string(mod.type))
    case "BPSK"
        bitsPerSym = 1;
    case "QPSK"
        bitsPerSym = 2;
    case "MSK"
        bitsPerSym = 1;
    otherwise
        error("Unsupported modulation for packet offset derivation: %s", mod.type);
end
end
