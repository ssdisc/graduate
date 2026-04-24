function [results, report] = run_defense_demo(varargin)
%RUN_DEFENSE_DEMO One-shot defense presentation script.
%
% Each run enforces:
% - exactly one Eb/N0 point
% - exactly one JSR point
% - exactly one frame
% - exactly one active interference type
% - exactly one mitigation method
%
% Example:
% run_defense_demo( ...
%     "ImagePath", "images/maodie.png", ...
%     "InterferenceType", "narrowband", ...
%     "EbN0dB", 8, ...
%     "JsrDb", 0, ...
%     "MitigationMethod", "fh_erasure", ...
%     "InterferenceParams", struct( ...
%         "centerFreqPoints", 0, ...
%         "bandwidthFreqPoints", 1, ...
%         "weight", 1));

opts = local_parse_inputs(varargin{:});

addpath(genpath(fullfile(fileparts(mfilename("fullpath")), "src")));

requiredMlModels = local_required_ml_models(opts.MitigationMethod);
p = default_params( ...
    "linkProfileName", opts.InterferenceType, ...
    "strictModelLoad", true, ...
    "requireTrainedMlModels", true, ...
    "allowBatchModelFallback", false, ...
    "loadMlModels", requiredMlModels);

p.source.useBuiltinImage = false;
p.source.imagePath = opts.ImagePath;
p.sim.nFramesPerPoint = 1;
p.sim.saveFigures = false;
p.sim.useParallel = false;
p.linkBudget.ebN0dBList = opts.EbN0dB;
p.linkBudget.jsrDbList = opts.JsrDb;
p.mitigation.methods = opts.MitigationMethod;

[p, expectedActiveType, interferenceInfo] = local_apply_single_interference( ...
    p, opts.InterferenceType, opts.InterferenceParams, opts.JsrDb);

[activeMethods, activeTypes, allowedMethods] = resolve_mitigation_methods(p.mitigation, p.channel);
if numel(activeTypes) ~= 1
    error("run_defense_demo:ActiveInterferenceCount", ...
        "Exactly one active interference type is required, got %d (%s).", ...
        numel(activeTypes), strjoin(cellstr(activeTypes), ", "));
end
if activeTypes(1) ~= expectedActiveType
    error("run_defense_demo:InterferenceTypeMismatch", ...
        "Interference type mismatch: expected %s, resolved %s.", ...
        expectedActiveType, activeTypes(1));
end
if numel(activeMethods) ~= 1 || activeMethods(1) ~= opts.MitigationMethod
    error("run_defense_demo:MitigationMethodInvalid", ...
        "Method %s is not valid for active interference type %s. Allowed methods: %s.", ...
        opts.MitigationMethod, activeTypes(1), strjoin(cellstr(allowedMethods), ", "));
end
p.mitigation.methods = activeMethods;

timestampTag = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
runDir = fullfile(char(opts.ResultsRoot), char("defense_demo_" + timestampTag));
if ~exist(runDir, "dir")
    mkdir(runDir);
end
p.sim.resultsDir = runDir;

fprintf("========================================\n");
fprintf("Defense demo config\n");
fprintf("========================================\n");
fprintf("Image path: %s\n", char(opts.ImagePath));
fprintf("Interference type: %s\n", char(opts.InterferenceType));
fprintf("Interference params: %s\n", jsonencode(interferenceInfo));
fprintf("Mitigation method: %s\n", char(opts.MitigationMethod));
fprintf("Eb/N0: %.3f dB\n", opts.EbN0dB);
fprintf("JSR: %.3f dB\n", opts.JsrDb);
fprintf("Frames per point: %d\n", p.sim.nFramesPerPoint);
fprintf("Output directory: %s\n", runDir);
fprintf("========================================\n\n");

results = simulate(p);

if numel(results.methods) ~= 1
    error("run_defense_demo:UnexpectedMethodCount", ...
        "Expected one method in results, got %d.", numel(results.methods));
end
if numel(results.ebN0dB) ~= 1
    error("run_defense_demo:UnexpectedPointCount", ...
        "Expected one Eb/N0 point in results, got %d.", numel(results.ebN0dB));
end

methodName = string(results.methods(1));
examplePoint = results.example(1);
methodField = char(methodName);
if ~isfield(examplePoint.methods, methodField)
    error("run_defense_demo:MissingMethodExample", ...
        "results.example(1).methods.%s is missing.", methodField);
end
exampleEntry = examplePoint.methods.(methodField);

imageFiles = local_save_images(results, exampleEntry, runDir);
report = local_build_report(results, exampleEntry, opts, interferenceInfo, imageFiles, runDir);

save(fullfile(runDir, "defense_demo_report.mat"), "results", "report", "opts");
local_print_report(report);

if nargout == 0
    clear results report
end
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "run_defense_demo";

addParameter(p, "ImagePath", "images/maodie.png", @(x) (ischar(x) || isstring(x)) && strlength(string(x)) > 0);
addParameter(p, "InterferenceType", "narrowband", @(x) (ischar(x) || isstring(x)) && strlength(string(x)) > 0);
addParameter(p, "EbN0dB", 8, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "JsrDb", 0, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "MitigationMethod", "none", @(x) (ischar(x) || isstring(x)) && strlength(string(x)) > 0);
addParameter(p, "InterferenceParams", struct(), @(x) isstruct(x) && isscalar(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results"), @(x) (ischar(x) || isstring(x)) && strlength(string(x)) > 0);

parse(p, varargin{:});

opts = p.Results;
opts.ImagePath = string(opts.ImagePath);
opts.InterferenceType = local_normalize_interference_type(string(opts.InterferenceType));
opts.EbN0dB = double(opts.EbN0dB);
opts.JsrDb = double(opts.JsrDb);
opts.MitigationMethod = lower(string(opts.MitigationMethod));
opts.InterferenceParams = opts.InterferenceParams;
opts.ResultsRoot = string(opts.ResultsRoot);

if ~isfile(opts.ImagePath)
    error("run_defense_demo:ImageNotFound", "Image file not found: %s", char(opts.ImagePath));
end
if ~isfolder(opts.ResultsRoot)
    mkdir(char(opts.ResultsRoot));
end
end

function interferenceType = local_normalize_interference_type(rawType)
typeLower = lower(string(rawType));
switch typeLower
    case "impulse"
        interferenceType = "impulse";
    case "narrowband"
        interferenceType = "narrowband";
    case {"rayleigh_multipath", "rayleigh", "multipath"}
        interferenceType = "rayleigh_multipath";
    otherwise
        error("run_defense_demo:UnsupportedInterferenceType", ...
            "Unsupported InterferenceType: %s. Supported types: impulse, narrowband, rayleigh_multipath.", ...
            char(rawType));
end
end

function [p, expectedActiveType, info] = local_apply_single_interference(p, interferenceType, rawParams, jsrDb)
p = apply_link_profile(p, interferenceType);

switch interferenceType
    case "impulse"
        params = local_impulse_params(rawParams);
        p.channel.impulseProb = params.impulseProb;
        p.channel.impulseWeight = params.impulseWeight;
        if isfield(params, "impulseToBgRatio")
            p.channel.impulseToBgRatio = params.impulseToBgRatio;
        end
        expectedActiveType = "impulse";
        info = params;

    case "narrowband"
        params = local_narrowband_params(rawParams);
        p.channel.narrowband.enable = true;
        p.channel.narrowband.weight = params.weight;
        p.channel.narrowband.centerFreqPoints = params.centerFreqPoints;
        p.channel.narrowband.bandwidthFreqPoints = params.bandwidthFreqPoints;

        waveform = resolve_waveform_cfg(p);
        [maxAbsCenter, ~] = narrowband_center_freq_points_limit( ...
            p.fh, waveform, p.channel.narrowband.bandwidthFreqPoints);
        if abs(p.channel.narrowband.centerFreqPoints) > maxAbsCenter
            error("run_defense_demo:NarrowbandCenterOutOfRange", ...
                "centerFreqPoints %.6g exceeds valid range [-%.6g, %.6g].", ...
                p.channel.narrowband.centerFreqPoints, maxAbsCenter, maxAbsCenter);
        end
        expectedActiveType = "narrowband";
        info = params;

    case "rayleigh_multipath"
        if abs(double(jsrDb)) > 1e-12
            error("run_defense_demo:InvalidJsrForMultipath", ...
                "JsrDb must be 0 when InterferenceType is rayleigh_multipath.");
        end
        params = local_rayleigh_multipath_params(rawParams);
        p.channel.multipath.enable = true;
        p.channel.multipath.pathDelaysSymbols = params.pathDelaysSymbols;
        p.channel.multipath.pathGainsDb = params.pathGainsDb;
        p.channel.multipath.rayleigh = true;
        expectedActiveType = "multipath";
        info = params;

    otherwise
        error("run_defense_demo:InternalTypeError", ...
            "Unexpected normalized interference type: %s", char(interferenceType));
end
end

function params = local_impulse_params(rawParams)
allowed = ["impulseProb" "impulseWeight" "impulseToBgRatio"];
local_validate_param_fields(rawParams, allowed, "impulse");

params = struct();
params.impulseProb = 0.03;
params.impulseWeight = 1;
if isfield(rawParams, "impulseProb")
    params.impulseProb = double(rawParams.impulseProb);
end
if isfield(rawParams, "impulseWeight")
    params.impulseWeight = double(rawParams.impulseWeight);
end
if isfield(rawParams, "impulseToBgRatio")
    params.impulseToBgRatio = double(rawParams.impulseToBgRatio);
end

if ~(isscalar(params.impulseProb) && isfinite(params.impulseProb) ...
        && params.impulseProb > 0 && params.impulseProb <= 1)
    error("run_defense_demo:InvalidImpulseProb", ...
        "impulseProb must be a finite scalar in (0, 1].");
end
if ~(isscalar(params.impulseWeight) && isfinite(params.impulseWeight) && params.impulseWeight > 0)
    error("run_defense_demo:InvalidImpulseWeight", ...
        "impulseWeight must be a positive finite scalar.");
end
if isfield(params, "impulseToBgRatio")
    if ~(isscalar(params.impulseToBgRatio) && isfinite(params.impulseToBgRatio) ...
            && params.impulseToBgRatio > 0)
        error("run_defense_demo:InvalidImpulseToBgRatio", ...
            "impulseToBgRatio must be a positive finite scalar.");
    end
end
end

function params = local_narrowband_params(rawParams)
allowed = ["centerFreqPoints" "bandwidthFreqPoints" "weight"];
local_validate_param_fields(rawParams, allowed, "narrowband");

params = struct();
params.centerFreqPoints = 0;
params.bandwidthFreqPoints = 1;
params.weight = 1;
if isfield(rawParams, "centerFreqPoints")
    params.centerFreqPoints = double(rawParams.centerFreqPoints);
end
if isfield(rawParams, "bandwidthFreqPoints")
    params.bandwidthFreqPoints = double(rawParams.bandwidthFreqPoints);
end
if isfield(rawParams, "weight")
    params.weight = double(rawParams.weight);
end

if ~(isscalar(params.centerFreqPoints) && isfinite(params.centerFreqPoints))
    error("run_defense_demo:InvalidNarrowbandCenter", ...
        "centerFreqPoints must be a finite scalar.");
end
if ~(isscalar(params.bandwidthFreqPoints) && isfinite(params.bandwidthFreqPoints) ...
        && params.bandwidthFreqPoints > 0)
    error("run_defense_demo:InvalidNarrowbandBandwidth", ...
        "bandwidthFreqPoints must be a positive finite scalar.");
end
if ~(isscalar(params.weight) && isfinite(params.weight) && params.weight > 0)
    error("run_defense_demo:InvalidNarrowbandWeight", ...
        "weight must be a positive finite scalar.");
end
end

function params = local_rayleigh_multipath_params(rawParams)
allowed = ["pathDelaysSymbols" "pathGainsDb"];
local_validate_param_fields(rawParams, allowed, "rayleigh_multipath");

params = struct();
params.pathDelaysSymbols = [0 1 2];
params.pathGainsDb = [0 -12 -18];
if isfield(rawParams, "pathDelaysSymbols")
    params.pathDelaysSymbols = double(rawParams.pathDelaysSymbols(:).');
end
if isfield(rawParams, "pathGainsDb")
    params.pathGainsDb = double(rawParams.pathGainsDb(:).');
end

if isempty(params.pathDelaysSymbols)
    error("run_defense_demo:InvalidMultipathDelays", ...
        "pathDelaysSymbols must be non-empty.");
end
if isempty(params.pathGainsDb)
    error("run_defense_demo:InvalidMultipathGains", ...
        "pathGainsDb must be non-empty.");
end
if numel(params.pathDelaysSymbols) ~= numel(params.pathGainsDb)
    error("run_defense_demo:MultipathLengthMismatch", ...
        "pathDelaysSymbols and pathGainsDb must have the same length.");
end
if any(~isfinite(params.pathDelaysSymbols)) || any(params.pathDelaysSymbols < 0) ...
        || any(abs(params.pathDelaysSymbols - round(params.pathDelaysSymbols)) > 1e-12)
    error("run_defense_demo:InvalidMultipathDelays", ...
        "pathDelaysSymbols must contain nonnegative integers.");
end
if any(~isfinite(params.pathGainsDb))
    error("run_defense_demo:InvalidMultipathGains", ...
        "pathGainsDb must contain finite values.");
end
end

function local_validate_param_fields(rawParams, allowedFields, interferenceType)
allFields = string(fieldnames(rawParams));
invalid = setdiff(allFields, allowedFields);
if ~isempty(invalid)
    error("run_defense_demo:UnsupportedInterferenceParam", ...
        "Unsupported %s interference params: %s", ...
        interferenceType, strjoin(cellstr(invalid), ", "));
end
end

function requiredModels = local_required_ml_models(methodName)
methodName = lower(string(methodName));
switch methodName
    case "ml_blanking"
        requiredModels = "lr";
    case {"ml_cnn", "ml_cnn_hard"}
        requiredModels = "cnn";
    case {"ml_gru", "ml_gru_hard"}
        requiredModels = "gru";
    case "ml_narrowband"
        requiredModels = "narrowband";
    case "ml_fh_erasure"
        requiredModels = "fh_erasure";
    case "adaptive_ml_frontend"
        requiredModels = ["selector" "gru" "narrowband"];
    otherwise
        requiredModels = strings(1, 0);
end
requiredModels = string(requiredModels(:).');
end

function imageFiles = local_save_images(results, exampleEntry, runDir)
if ~(isfield(results, "sourceImages") && isstruct(results.sourceImages) ...
        && isfield(results.sourceImages, "original") && isfield(results.sourceImages, "resized"))
    error("run_defense_demo:MissingSourceImages", ...
        "results.sourceImages.original/resized are required.");
end
if ~(isfield(exampleEntry, "imgRx") && isfield(exampleEntry, "imgRxComm") ...
        && isfield(exampleEntry, "imgRxCompensated"))
    error("run_defense_demo:MissingExampleImages", ...
        "exampleEntry.imgRx/imgRxComm/imgRxCompensated are required.");
end

imageFiles = struct();
imageFiles.sourceOriginal = string(fullfile(runDir, "tx_source_original.png"));
imageFiles.sourceResized = string(fullfile(runDir, "tx_source_resized.png"));
imageFiles.rxCurrent = string(fullfile(runDir, "rx_current.png"));
imageFiles.rxCommunication = string(fullfile(runDir, "rx_comm.png"));
imageFiles.rxCompensated = string(fullfile(runDir, "rx_comp.png"));

local_write_uint8_image(results.sourceImages.original, imageFiles.sourceOriginal, "results.sourceImages.original");
local_write_uint8_image(results.sourceImages.resized, imageFiles.sourceResized, "results.sourceImages.resized");
local_write_uint8_image(exampleEntry.imgRx, imageFiles.rxCurrent, "exampleEntry.imgRx");
local_write_uint8_image(exampleEntry.imgRxComm, imageFiles.rxCommunication, "exampleEntry.imgRxComm");
local_write_uint8_image(exampleEntry.imgRxCompensated, imageFiles.rxCompensated, "exampleEntry.imgRxCompensated");
end

function local_write_uint8_image(img, targetPath, imageLabel)
if ~(isa(img, "uint8") && ndims(img) <= 3)
    error("run_defense_demo:InvalidImageType", ...
        "%s must be a uint8 image with ndims <= 3.", imageLabel);
end
imwrite(img, char(targetPath));
end

function report = local_build_report(results, exampleEntry, opts, interferenceInfo, imageFiles, runDir)
methodIdx = 1;
pointIdx = 1;

bobDiag = results.packetDiagnostics.bob;
if isfield(bobDiag, "frontEndSuccessRateByMethod")
    frontEndRate = double(bobDiag.frontEndSuccessRateByMethod(methodIdx, pointIdx));
else
    frontEndRate = double(bobDiag.frontEndSuccessRate(pointIdx));
end
if isfield(bobDiag, "headerSuccessRateByMethod")
    headerRate = double(bobDiag.headerSuccessRateByMethod(methodIdx, pointIdx));
else
    headerRate = double(bobDiag.headerSuccessRate(pointIdx));
end
payloadRate = double(bobDiag.payloadSuccessRate(methodIdx, pointIdx));

imgMetrics = results.imageMetrics;
report = struct();
report.runDir = string(runDir);
report.method = string(results.methods(methodIdx));
report.interferenceType = string(opts.InterferenceType);
report.interferenceParams = interferenceInfo;
report.ebN0dB = double(results.ebN0dB(pointIdx));
report.jsrDb = double(results.jsrDb(pointIdx));
report.ber = double(results.ber(methodIdx, pointIdx));
report.rawPer = double(results.rawPer(methodIdx, pointIdx));
report.per = double(results.per(methodIdx, pointIdx));
report.frontEndSuccessRate = frontEndRate;
report.headerSuccessRate = headerRate;
report.payloadSuccessRate = payloadRate;
report.packetSuccessRate = double(exampleEntry.packetSuccessRate);
report.rawPacketSuccessRate = double(exampleEntry.rawPacketSuccessRate);
report.headerOk = logical(exampleEntry.headerOk);
report.kl = struct( ...
    "signalVsNoise", double(results.kl.signalVsNoise(pointIdx)), ...
    "noiseVsSignal", double(results.kl.noiseVsSignal(pointIdx)), ...
    "symmetric", double(results.kl.symmetric(pointIdx)));
report.imageMetrics = struct( ...
    "original", struct( ...
        "communication", struct( ...
            "mse", double(imgMetrics.original.communication.mse(methodIdx, pointIdx)), ...
            "psnr", double(imgMetrics.original.communication.psnr(methodIdx, pointIdx)), ...
            "ssim", double(imgMetrics.original.communication.ssim(methodIdx, pointIdx))), ...
        "compensated", struct( ...
            "mse", double(imgMetrics.original.compensated.mse(methodIdx, pointIdx)), ...
            "psnr", double(imgMetrics.original.compensated.psnr(methodIdx, pointIdx)), ...
            "ssim", double(imgMetrics.original.compensated.ssim(methodIdx, pointIdx)))), ...
    "resized", struct( ...
        "communication", struct( ...
            "mse", double(imgMetrics.resized.communication.mse(methodIdx, pointIdx)), ...
            "psnr", double(imgMetrics.resized.communication.psnr(methodIdx, pointIdx)), ...
            "ssim", double(imgMetrics.resized.communication.ssim(methodIdx, pointIdx))), ...
        "compensated", struct( ...
            "mse", double(imgMetrics.resized.compensated.mse(methodIdx, pointIdx)), ...
            "psnr", double(imgMetrics.resized.compensated.psnr(methodIdx, pointIdx)), ...
            "ssim", double(imgMetrics.resized.compensated.ssim(methodIdx, pointIdx)))));
report.imageFiles = imageFiles;
end

function local_print_report(report)
fprintf("\n========================================\n");
fprintf("Defense demo result\n");
fprintf("========================================\n");
fprintf("Run dir: %s\n", char(report.runDir));
fprintf("Interference: %s\n", char(report.interferenceType));
fprintf("Method: %s\n", char(report.method));
fprintf("Eb/N0: %.3f dB, JSR: %.3f dB\n", report.ebN0dB, report.jsrDb);
fprintf("\n");
fprintf("BER/PER metrics\n");
fprintf("  BER: %.6g\n", report.ber);
fprintf("  Raw PER: %.6g\n", report.rawPer);
fprintf("  PER: %.6g\n", report.per);
fprintf("  Front-end success: %.4f\n", report.frontEndSuccessRate);
fprintf("  Header success: %.4f\n", report.headerSuccessRate);
fprintf("  Payload success: %.4f\n", report.payloadSuccessRate);
fprintf("\n");
fprintf("Image quality metrics (original size)\n");
fprintf("  Comm      MSE=%.6g  PSNR=%.4f dB  SSIM=%.6f\n", ...
    report.imageMetrics.original.communication.mse, ...
    report.imageMetrics.original.communication.psnr, ...
    report.imageMetrics.original.communication.ssim);
fprintf("  Compens.  MSE=%.6g  PSNR=%.4f dB  SSIM=%.6f\n", ...
    report.imageMetrics.original.compensated.mse, ...
    report.imageMetrics.original.compensated.psnr, ...
    report.imageMetrics.original.compensated.ssim);
fprintf("\n");
fprintf("Image quality metrics (resized tx size)\n");
fprintf("  Comm      MSE=%.6g  PSNR=%.4f dB  SSIM=%.6f\n", ...
    report.imageMetrics.resized.communication.mse, ...
    report.imageMetrics.resized.communication.psnr, ...
    report.imageMetrics.resized.communication.ssim);
fprintf("  Compens.  MSE=%.6g  PSNR=%.4f dB  SSIM=%.6f\n", ...
    report.imageMetrics.resized.compensated.mse, ...
    report.imageMetrics.resized.compensated.psnr, ...
    report.imageMetrics.resized.compensated.ssim);
fprintf("\n");
fprintf("KL metrics\n");
fprintf("  KL(signal||noise): %.6g\n", report.kl.signalVsNoise);
fprintf("  KL(noise||signal): %.6g\n", report.kl.noiseVsSignal);
fprintf("  KL symmetric: %.6g\n", report.kl.symmetric);
fprintf("\n");
fprintf("Output images\n");
fprintf("  Source original : %s\n", char(report.imageFiles.sourceOriginal));
fprintf("  Source resized  : %s\n", char(report.imageFiles.sourceResized));
fprintf("  RX current      : %s\n", char(report.imageFiles.rxCurrent));
fprintf("  RX communication: %s\n", char(report.imageFiles.rxCommunication));
fprintf("  RX compensated  : %s\n", char(report.imageFiles.rxCompensated));
fprintf("========================================\n");
end
