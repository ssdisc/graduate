function ctx = ml_capture_multipath_equalizer_reload_context(p)
%ML_CAPTURE_MULTIPATH_EQUALIZER_RELOAD_CONTEXT  Reload context for offline multipath equalizer models.

arguments
    p (1,1) struct
end

fullCtx = ml_capture_training_context(p);
ctx = struct();
ctx.domain = fullCtx.domain;
ctx.rxArchitecture = fullCtx.rxArchitecture;
ctx.mod = fullCtx.mod;
ctx.waveform = fullCtx.waveform;
ctx.fh = fullCtx.fh;
ctx.frame = fullCtx.frame;
ctx.rxSyncMultipathEq = local_eq_context(p);
ctx.channelMultipath = local_multipath_context(p);
end

function ctx = local_eq_context(p)
if ~(isfield(p, "rxSync") && isstruct(p.rxSync) ...
        && isfield(p.rxSync, "multipathEq") && isstruct(p.rxSync.multipathEq))
    error("ml_capture_multipath_equalizer_reload_context requires p.rxSync.multipathEq.");
end
cfg = p.rxSync.multipathEq;
ctx = struct( ...
    "nTaps", local_scalar(cfg, "nTaps"));
end

function ctx = local_multipath_context(p)
if ~(isfield(p, "channel") && isstruct(p.channel) ...
        && isfield(p.channel, "multipath") && isstruct(p.channel.multipath))
    error("ml_capture_multipath_equalizer_reload_context requires p.channel.multipath.");
end
mp = p.channel.multipath;
ctx = struct( ...
    "enable", local_logical(mp, "enable"), ...
    "pathDelaysSymbols", local_row(mp, "pathDelaysSymbols"), ...
    "pathGainsDb", local_row(mp, "pathGainsDb"));
end

function value = local_scalar(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value))
    error("%s must be a finite scalar.", fieldName);
end
end

function value = local_logical(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", fieldName);
end
value = logical(s.(fieldName));
if ~isscalar(value)
    error("%s must be a logical scalar.", fieldName);
end
end

function value = local_row(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", fieldName);
end
value = double(s.(fieldName)(:)).';
if any(~isfinite(value))
    error("%s must contain finite values.", fieldName);
end
end
