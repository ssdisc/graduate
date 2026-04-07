function bits = fec_decode(metrics, fec)
%FEC_DECODE  Payload FEC decode for convolutional or LDPC modes.
%
% 输入:
%   metrics - 译码输入（硬比特或软度量）
%   fec     - FEC参数结构体
%
% 输出:
%   bits - 译码后的比特流

% 确保所有数据都是double精度且在CPU上（非gpuArray）
metrics = double(gather(metrics(:)));
info = fec_get_info(fec);

switch info.kind
    case "conv"
        if strcmpi(fec.decisionType, "hard")
            hardBits = double(metrics ~= 0);
            bits = vitdec(hardBits, fec.trellis, fec.tracebackDepth, fec.opmode, 'hard');
        else
            nsdec = fec_payload_soft_bits(fec);
            % 软译码需要整数量化值，范围0到2^nsdec-1
            soft = round(metrics);
            soft = max(min(soft, 2^nsdec-1), 0);
            bits = vitdec(soft, fec.trellis, fec.tracebackDepth, fec.opmode, 'soft', nsdec);
        end

    case "ldpc"
        if numel(metrics) ~= info.blockLength
            error("LDPC译码输入长度必须等于一个完整码字长度 %d，当前为 %d。", ...
                info.blockLength, numel(metrics));
        end
        llr = local_ldpc_llr_from_metrics(metrics, fec);
        bits = ldpcDecode(llr, info.ldpcDecoderConfig, info.ldpcMaxIterations, ...
            OutputFormat="info", ...
            DecisionType="hard", ...
            MinSumScalingFactor=info.ldpcMinSumScalingFactor, ...
            MinSumOffset=info.ldpcMinSumOffset, ...
            Termination=info.ldpcTermination, ...
            Multithreaded=info.ldpcMultithreaded);

    otherwise
        error("Unsupported FEC kind: %s", info.kind);
end
bits = uint8(bits(:));
end

function llr = local_ldpc_llr_from_metrics(metrics, fec)
if strcmpi(fec.decisionType, "hard")
    hardBits = double(metrics ~= 0);
    llr = 1 - 2 * hardBits;
    return;
end

nsdec = fec_payload_soft_bits(fec);
maxv = 2^nsdec - 1;
soft = round(metrics);
soft = max(min(soft, maxv), 0);
llr = (maxv / 2) - soft;
end

