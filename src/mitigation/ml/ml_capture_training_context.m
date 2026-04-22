function ctx = ml_capture_training_context(p)
%ML_CAPTURE_TRAINING_CONTEXT  提取离线训练与主链路对齐后的上下文快照。

arguments
    p (1,1) struct
end

waveform = resolve_waveform_cfg(p);

ctx = struct();
ctx.domain = "raw_samples";
ctx.rxArchitecture = "sample_mitigation_mf_2sps_sync_1sps_decode_scfde_rxdiv_v2";
ctx.trainingChainVersion = "build_tx_packets_full_burst_v2";
ctx.rngSeed = local_require_numeric_scalar(p, "rngSeed");
ctx.mod = local_capture_required_substruct(p, "mod");
ctx.waveform = local_capture_value(waveform, "waveform");
ctx.channel = local_capture_required_substruct(p, "channel");
ctx.fh = local_capture_required_substruct(p, "fh");
ctx.frame = local_capture_required_substruct(p, "frame");
ctx.dsss = local_capture_required_substruct(p, "dsss");
ctx.packet = local_capture_required_substruct(p, "packet");
ctx.outerRs = local_capture_required_substruct(p, "outerRs");
ctx.scramble = local_capture_required_substruct(p, "scramble");
ctx.interleaver = local_capture_required_substruct(p, "interleaver");
ctx.fec = local_capture_required_substruct(p, "fec");
ctx.softMetric = local_capture_required_substruct(p, "softMetric");
ctx.scFde = local_capture_required_substruct(p, "scFde");
ctx.rxDiversity = local_capture_required_substruct(p, "rxDiversity");
ctx.rxSync = local_capture_rx_sync_context(p);
ctx.chaosEncrypt = local_capture_required_substruct(p, "chaosEncrypt");
end

function value = local_require_numeric_scalar(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("ml_capture_training_context requires p.%s.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value))
    error("p.%s must be a finite scalar.", fieldName);
end
end

function out = local_capture_required_substruct(s, fieldName)
if ~(isfield(s, fieldName) && isstruct(s.(fieldName)) && isscalar(s.(fieldName)))
    error("ml_capture_training_context requires p.%s as a scalar struct.", fieldName);
end
out = local_capture_value(s.(fieldName), "p." + string(fieldName));
end

function out = local_capture_rx_sync_context(p)
if ~(isfield(p, "rxSync") && isstruct(p.rxSync) && isscalar(p.rxSync))
    error("ml_capture_training_context requires p.rxSync as a scalar struct.");
end
rxSyncCfg = p.rxSync;
if ~(isfield(rxSyncCfg, "multipathEq") && isstruct(rxSyncCfg.multipathEq) && isscalar(rxSyncCfg.multipathEq))
    error("ml_capture_training_context requires p.rxSync.multipathEq as a scalar struct.");
end
if ~isfield(rxSyncCfg.multipathEq, "mlMlp")
    error("ml_capture_training_context requires p.rxSync.multipathEq.mlMlp.");
end
rxSyncCfg.multipathEq = rmfield(rxSyncCfg.multipathEq, "mlMlp");
out = local_capture_value(rxSyncCfg, "p.rxSync");
end

function valueOut = local_capture_value(valueIn, path)
if nargin < 2
    path = "value";
end

if isstruct(valueIn)
    if isempty(valueIn)
        valueOut = struct();
        return;
    end
    if ~isscalar(valueIn)
        valueOut = local_capture_value(valueIn(1), path + "(" + string(1) + ")");
        valueOut = repmat(valueOut, size(valueIn));
        for idx = 2:numel(valueIn)
            valueOut(idx) = local_capture_value(valueIn(idx), path + "(" + string(idx) + ")");
        end
        return;
    end

    fields = sort(fieldnames(valueIn));
    valueOut = struct();
    for idx = 1:numel(fields)
        fieldName = fields{idx};
        valueOut.(fieldName) = local_capture_value(valueIn.(fieldName), path + "." + string(fieldName));
    end
    return;
end

if iscell(valueIn)
    valueOut = cell(size(valueIn));
    for idx = 1:numel(valueIn)
        valueOut{idx} = local_capture_value(valueIn{idx}, path + "{" + string(idx) + "}");
    end
    return;
end

if isstring(valueIn)
    valueOut = reshape(string(valueIn), size(valueIn));
    return;
end

if ischar(valueIn)
    valueOut = string(valueIn);
    return;
end

if isnumeric(valueIn)
    valueOut = double(valueIn);
    return;
end

if islogical(valueIn)
    valueOut = logical(valueIn);
    return;
end

if isa(valueIn, "categorical")
    valueOut = string(valueIn);
    return;
end

error("Unsupported training-context type at %s: %s.", char(string(path)), class(valueIn));
end
