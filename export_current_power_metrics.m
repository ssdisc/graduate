function metrics = export_current_power_metrics(varargin)
%EXPORT_CURRENT_POWER_METRICS Export current profile power metrics for thesis tables.

opts = local_parse_inputs(varargin{:});
addpath(genpath("src"));

outDir = char(opts.OutDir);
if ~exist(outDir, "dir")
    mkdir(outDir);
end

profiles = string(opts.Profiles(:).');
specs = cell(1, numel(profiles));
for idx = 1:numel(profiles)
    specs{idx} = default_link_spec( ...
        "linkProfileName", profiles(idx), ...
        "loadMlModels", string.empty(1, 0), ...
        "strictModelLoad", false, ...
        "requireTrainedMlModels", false);
end

metrics = build_link_power_metrics(specs, ...
    "EbN0dB", opts.EbN0dB, ...
    "JsrDb", opts.JsrDb, ...
    "NoiseFigureDb", opts.NoiseFigureDb, ...
    "ReferenceTemperatureK", opts.ReferenceTemperatureK, ...
    "PathLossDb", opts.PathLossDb, ...
    "TxGainDb", opts.TxGainDb, ...
    "RxGainDb", opts.RxGainDb, ...
    "EstimateSpectrum", opts.EstimateSpectrum);

csvPath = fullfile(outDir, "power_metrics.csv");
mdPath = fullfile(outDir, "power_metrics.md");
writetable(metrics, csvPath);
local_write_markdown(metrics, mdPath);

fprintf("[POWER] wrote %s\n", csvPath);
fprintf("[POWER] wrote %s\n", mdPath);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "export_current_power_metrics";
addParameter(p, "Profiles", ["impulse" "narrowband" "rayleigh_multipath" "robust_unified"], ...
    @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0dB", 6, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "JsrDb", 0, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "NoiseFigureDb", 5, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "ReferenceTemperatureK", 290, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
addParameter(p, "PathLossDb", 0, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "TxGainDb", 0, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "RxGainDb", 0, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "EstimateSpectrum", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "OutDir", fullfile("results", "power_metrics", ...
    "current_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss"))), ...
    @(x) ischar(x) || isstring(x));
parse(p, varargin{:});

opts = p.Results;
opts.Profiles = string(opts.Profiles(:).');
opts.EbN0dB = double(opts.EbN0dB(:).');
opts.JsrDb = double(opts.JsrDb(:).');
opts.OutDir = string(opts.OutDir);
opts.EstimateSpectrum = logical(opts.EstimateSpectrum);
end

function local_write_markdown(metrics, mdPath)
fid = fopen(mdPath, "w");
if fid < 0
    error("export_current_power_metrics:OpenFailed", ...
        "Failed to open markdown output: %s", mdPath);
end
cleanup = onCleanup(@() fclose(fid));

fprintf(fid, "# Power Metric Table\n\n");
fprintf(fid, "Assumption: dBm columns use the stated NF, temperature, path loss, and antenna gains. ");
fprintf(fid, "The main normalized thesis metric is `txEbN0NetDb`.\n\n");
fprintf(fid, "| Profile | Mod | Bob Eb/N0 dB | Tx net Eb/N0 dB | Penalty dB | Burst s | Net kbps | BW99 kHz | Eta b/s/Hz | Tx norm dB | Eq Tx dBm |\n");
fprintf(fid, "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");

for idx = 1:height(metrics)
    fprintf(fid, "| %s | %s | %.2f | %.2f | %.2f | %.3f | %.2f | %.1f | %.4f | %.2f | %.2f |\n", ...
        char(metrics.profile(idx)), ...
        char(metrics.modulation(idx)), ...
        metrics.bobEbN0dB(idx), ...
        metrics.txEbN0NetDb(idx), ...
        metrics.fullOverheadPenaltyDb(idx), ...
        metrics.burstSec(idx), ...
        metrics.netPayloadBitRateBps(idx) / 1e3, ...
        metrics.bw99Hz(idx) / 1e3, ...
        metrics.etaBpsHz(idx), ...
        metrics.txPowerNormDb(idx), ...
        metrics.eqTxPowerDbm(idx));
end

fprintf(fid, "\n## Column Definitions\n\n");
fprintf(fid, "- `Bob Eb/N0 dB`: configured receiver-side channel condition.\n");
fprintf(fid, "- `Tx net Eb/N0 dB`: transmit-side equivalent Eb/N0 after spreading all emitted energy over delivered payload bits.\n");
fprintf(fid, "- `Penalty dB`: full-overhead penalty from coding, packetization, control, synchronization, DSSS/FH/SC-FDE, pilots, CP, and burst duration.\n");
fprintf(fid, "- `Tx norm dB`: normalized complex-baseband average transmit power used by the simulator.\n");
fprintf(fid, "- `Eq Tx dBm`: engineering conversion under the stated thermal noise and link-budget assumptions.\n");
end
