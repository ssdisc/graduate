function run_robust_unified_demo()
%RUN_ROBUST_UNIFIED_DEMO Interactive demo launcher for the robust_unified link.

repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

defaultImagePath = fullfile(repoRoot, "images", "maodie.png");
if ~isfile(defaultImagePath)
    defaultImagePath = "";
end
defaultResultsRoot = fullfile(repoRoot, "results", "robust_unified_demo");
if ~exist(defaultResultsRoot, "dir")
    mkdir(defaultResultsRoot);
end

ui = struct();
ui.fig = uifigure( ...
    "Name", "Robust Unified 演示", ...
    "Position", [100 60 1180 900], ...
    "Color", [0.98 0.98 0.98]);

mainGrid = uigridlayout(ui.fig, [6 1]);
mainGrid.RowHeight = {86, 86, 84, 112, 112, "1x"};
mainGrid.ColumnWidth = {"1x"};
mainGrid.Padding = [12 12 12 12];
mainGrid.RowSpacing = 10;

ui.imagePanel = uipanel(mainGrid, "Title", "源图像");
ui.imageGrid = uigridlayout(ui.imagePanel, [2 3]);
ui.imageGrid.RowHeight = {24, 24};
ui.imageGrid.ColumnWidth = {90, "1x", 100};
ui.imageGrid.Padding = [8 8 8 8];
ui.imageGrid.RowSpacing = 6;
ui.imageGrid.ColumnSpacing = 8;
ui.imagePathLabel = uilabel(ui.imageGrid, "Text", "图像路径", "HorizontalAlignment", "right");
ui.imagePathLabel.Layout.Row = 1;
ui.imagePathLabel.Layout.Column = 1;
ui.imagePath = uieditfield(ui.imageGrid, "text", "Value", char(defaultImagePath));
ui.imagePath.Layout.Row = 1;
ui.imagePath.Layout.Column = 2;
ui.browseButton = uibutton(ui.imageGrid, "push", "Text", "浏览...");
ui.browseButton.Layout.Row = 1;
ui.browseButton.Layout.Column = 3;
ui.imageNote = uilabel(ui.imageGrid, ...
    "Text", "TX 图像保持长宽比，并将长边缩放到 256。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.imageNote.Layout.Row = 2;
ui.imageNote.Layout.Column = [1 3];

ui.generalPanel = uipanel(mainGrid, "Title", "通用设置");
ui.generalGrid = uigridlayout(ui.generalPanel, [2 8]);
ui.generalGrid.RowHeight = {24, 24};
ui.generalGrid.ColumnWidth = {70, 120, 70, 120, 90, 120, 90, "1x"};
ui.generalGrid.Padding = [8 8 8 8];
ui.generalGrid.RowSpacing = 6;
ui.generalGrid.ColumnSpacing = 8;
ui.ebn0Label = uilabel(ui.generalGrid, "Text", "Eb/N0 (dB)", "HorizontalAlignment", "right");
ui.ebn0Label.Layout.Row = 1;
ui.ebn0Label.Layout.Column = 1;
ui.ebn0 = uieditfield(ui.generalGrid, "numeric", "Value", 6);
ui.ebn0.Layout.Row = 1;
ui.ebn0.Layout.Column = 2;
ui.jsrLabel = uilabel(ui.generalGrid, "Text", "JSR (dB)", "HorizontalAlignment", "right");
ui.jsrLabel.Layout.Row = 1;
ui.jsrLabel.Layout.Column = 3;
ui.jsr = uieditfield(ui.generalGrid, "numeric", "Value", 0);
ui.jsr.Layout.Row = 1;
ui.jsr.Layout.Column = 4;
ui.modulationLabel = uilabel(ui.generalGrid, "Text", "调制方式", "HorizontalAlignment", "right");
ui.modulationLabel.Layout.Row = 1;
ui.modulationLabel.Layout.Column = 5;
ui.modulation = uidropdown(ui.generalGrid, ...
    "Items", ["QPSK" "BPSK" "MSK"], ...
    "Value", "QPSK");
ui.modulation.Layout.Row = 1;
ui.modulation.Layout.Column = 6;
ui.resultsRootLabel = uilabel(ui.generalGrid, "Text", "结果目录", "HorizontalAlignment", "right");
ui.resultsRootLabel.Layout.Row = 1;
ui.resultsRootLabel.Layout.Column = 7;
ui.resultsRoot = uieditfield(ui.generalGrid, "text", "Value", defaultResultsRoot);
ui.resultsRoot.Layout.Row = 1;
ui.resultsRoot.Layout.Column = 8;
ui.generalNote = uilabel(ui.generalGrid, ...
    "Text", "固定链路：robust_unified + robust_combo + sample blanking + fh_erasure。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.generalNote.Layout.Row = 2;
ui.generalNote.Layout.Column = [1 8];

ui.impulsePanel = uipanel(mainGrid, "Title", "脉冲干扰");
ui.impulseGrid = uigridlayout(ui.impulsePanel, [2 4]);
ui.impulseGrid.RowHeight = {24, 24};
ui.impulseGrid.ColumnWidth = {90, 110, 90, "1x"};
ui.impulseGrid.Padding = [8 8 8 8];
ui.impulseGrid.RowSpacing = 6;
ui.impulseGrid.ColumnSpacing = 8;
ui.enableImpulse = uicheckbox(ui.impulseGrid, "Text", "启用", "Value", false);
ui.enableImpulse.Layout.Row = 1;
ui.enableImpulse.Layout.Column = 1;
ui.impulseProbLabel = uilabel(ui.impulseGrid, "Text", "impulseProb", "HorizontalAlignment", "right");
ui.impulseProbLabel.Layout.Row = 1;
ui.impulseProbLabel.Layout.Column = 2;
ui.impulseProb = uieditfield(ui.impulseGrid, "numeric", "Value", 0.03, ...
    "Limits", [eps, 1], "LowerLimitInclusive", true, "UpperLimitInclusive", true);
ui.impulseProb.Layout.Row = 1;
ui.impulseProb.Layout.Column = 3;
ui.impulseNote = uilabel(ui.impulseGrid, ...
    "Text", "保持基于 JSR 的功率标定；weight 固定为 1。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.impulseNote.Layout.Row = 2;
ui.impulseNote.Layout.Column = [1 4];

ui.nbPanel = uipanel(mainGrid, "Title", "窄带干扰");
ui.nbGrid = uigridlayout(ui.nbPanel, [3 6]);
ui.nbGrid.RowHeight = {24, 30, 24};
ui.nbGrid.ColumnWidth = {90, 110, 110, 110, 110, "1x"};
ui.nbGrid.Padding = [8 8 8 8];
ui.nbGrid.RowSpacing = 6;
ui.nbGrid.ColumnSpacing = 8;
ui.enableNarrowband = uicheckbox(ui.nbGrid, "Text", "启用", "Value", true);
ui.enableNarrowband.Layout.Row = 1;
ui.enableNarrowband.Layout.Column = 1;
ui.nbCenterLabel = uilabel(ui.nbGrid, "Text", "center", "HorizontalAlignment", "right");
ui.nbCenterLabel.Layout.Row = 1;
ui.nbCenterLabel.Layout.Column = 2;
ui.nbCenter = uieditfield(ui.nbGrid, "numeric", "Value", 0);
ui.nbCenter.Layout.Row = 1;
ui.nbCenter.Layout.Column = 3;
ui.nbBandwidthLabel = uilabel(ui.nbGrid, "Text", "bandwidth", "HorizontalAlignment", "right");
ui.nbBandwidthLabel.Layout.Row = 1;
ui.nbBandwidthLabel.Layout.Column = 4;
ui.nbBandwidth = uieditfield(ui.nbGrid, "text", "Value", "auto");
ui.nbBandwidth.Layout.Row = 1;
ui.nbBandwidth.Layout.Column = [5 6];
ui.nbNote1 = uilabel(ui.nbGrid, ...
    "Text", "bandwidth = auto 表示使用当前 robust_unified 的 prespread FH 带宽，单位为 FH point。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.nbNote1.Layout.Row = 2;
ui.nbNote1.Layout.Column = [1 6];
ui.nbNote2 = uilabel(ui.nbGrid, ...
    "Text", "运行前会检查 center 合法范围；超出范围直接报错。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.nbNote2.Layout.Row = 3;
ui.nbNote2.Layout.Column = [1 6];

ui.mpPanel = uipanel(mainGrid, "Title", "Rayleigh 多径");
ui.mpGrid = uigridlayout(ui.mpPanel, [3 6]);
ui.mpGrid.RowHeight = {24, 30, 24};
ui.mpGrid.ColumnWidth = {90, 130, 90, 150, 90, "1x"};
ui.mpGrid.Padding = [8 8 8 8];
ui.mpGrid.RowSpacing = 6;
ui.mpGrid.ColumnSpacing = 8;
ui.enableMultipath = uicheckbox(ui.mpGrid, "Text", "启用", "Value", false);
ui.enableMultipath.Layout.Row = 1;
ui.enableMultipath.Layout.Column = 1;
ui.mpDelaysLabel = uilabel(ui.mpGrid, "Text", "delays", "HorizontalAlignment", "right");
ui.mpDelaysLabel.Layout.Row = 1;
ui.mpDelaysLabel.Layout.Column = 2;
ui.mpDelays = uieditfield(ui.mpGrid, "text", "Value", "0 2 4");
ui.mpDelays.Layout.Row = 1;
ui.mpDelays.Layout.Column = 3;
ui.mpGainsLabel = uilabel(ui.mpGrid, "Text", "gains (dB)", "HorizontalAlignment", "right");
ui.mpGainsLabel.Layout.Row = 1;
ui.mpGainsLabel.Layout.Column = 4;
ui.mpGains = uieditfield(ui.mpGrid, "text", "Value", "0 -6 -10");
ui.mpGains.Layout.Row = 1;
ui.mpGains.Layout.Column = [5 6];
ui.mpNote1 = uilabel(ui.mpGrid, ...
    "Text", "使用空格或逗号分隔向量，例如 delays: 0 2 4，gains: 0 -6 -10。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.mpNote1.Layout.Row = 2;
ui.mpNote1.Layout.Column = [1 6];
ui.mpNote2 = uilabel(ui.mpGrid, ...
    "Text", "非法 CP/channel-memory 组合不做掩盖，运行时直接报错。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.mpNote2.Layout.Row = 3;
ui.mpNote2.Layout.Column = [1 6];

ui.bottomPanel = uipanel(mainGrid, "Title", "运行与信号监视");
ui.bottomGrid = uigridlayout(ui.bottomPanel, [3 4]);
ui.bottomGrid.RowHeight = {34, "1x", "1x"};
ui.bottomGrid.ColumnWidth = {160, 140, "1x", "1x"};
ui.bottomGrid.Padding = [8 8 8 8];
ui.bottomGrid.RowSpacing = 8;
ui.bottomGrid.ColumnSpacing = 8;
ui.runButton = uibutton(ui.bottomGrid, "push", "Text", "运行演示");
ui.runButton.Layout.Row = 1;
ui.runButton.Layout.Column = 1;
ui.clearButton = uibutton(ui.bottomGrid, "push", "Text", "清空状态");
ui.clearButton.Layout.Row = 1;
ui.clearButton.Layout.Column = 2;
ui.signalNote = uilabel(ui.bottomGrid, ...
    "Text", "TX 预览会在 RX 仿真前刷新；完整运行结束后再刷新最终图。", ...
    "FontColor", [0.35 0.35 0.35]);
ui.signalNote.Layout.Row = 1;
ui.signalNote.Layout.Column = [3 4];
ui.status = uitextarea(ui.bottomGrid, "Editable", "off");
ui.status.Layout.Row = [2 3];
ui.status.Layout.Column = [1 2];
ui.status.Value = {'就绪。'};
ui.timeAxis = uiaxes(ui.bottomGrid);
ui.timeAxis.Layout.Row = 2;
ui.timeAxis.Layout.Column = [3 4];
ui.freqAxis = uiaxes(ui.bottomGrid);
ui.freqAxis.Layout.Row = 3;
ui.freqAxis.Layout.Column = [3 4];
local_reset_signal_axes(ui, "等待运行");

ui.browseButton.ButtonPushedFcn = @(~, ~) local_browse_image(ui);
ui.enableImpulse.ValueChangedFcn = @(~, ~) local_refresh_enable_state(ui);
ui.enableNarrowband.ValueChangedFcn = @(~, ~) local_refresh_enable_state(ui);
ui.enableMultipath.ValueChangedFcn = @(~, ~) local_refresh_enable_state(ui);
ui.runButton.ButtonPushedFcn = @(~, ~) local_run_button(ui);
ui.clearButton.ButtonPushedFcn = @(~, ~) local_clear_status(ui);

local_refresh_enable_state(ui);
end

function local_browse_image(ui)
[fileName, folderPath] = uigetfile( ...
    {"*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff;*.jp2", "图像文件"; "*.*", "所有文件"}, ...
    "选择源图像", char(local_parent_or_pwd(ui.imagePath.Value)));
if isequal(fileName, 0)
    return;
end
ui.imagePath.Value = fullfile(folderPath, fileName);
end

function local_refresh_enable_state(ui)
local_set_enable(ui.impulseProb, ui.enableImpulse.Value);
local_set_enable(ui.nbCenter, ui.enableNarrowband.Value);
local_set_enable(ui.nbBandwidth, ui.enableNarrowband.Value);
local_set_enable(ui.mpDelays, ui.enableMultipath.Value);
local_set_enable(ui.mpGains, ui.enableMultipath.Value);
end

function local_set_enable(h, tf)
if tf
    h.Enable = "on";
else
    h.Enable = "off";
end
end

function local_run_button(ui)
progress = [];
cleanupObj = onCleanup(@() local_restore_run_button(ui));
ui.runButton.Enable = "off";
ui.fig.Pointer = "watch";
drawnow;

try
    cfg = local_collect_demo_cfg(ui);
    local_append_status(ui, "正在构建 robust_unified spec...");
    local_reset_signal_axes(ui, "正在运行...");
    drawnow;

    previewReport = local_build_demo_tx_preview_report(cfg);
    local_update_signal_axes(ui, previewReport);
    local_append_status(ui, sprintf("TX 预览已在 RX 仿真前刷新。%s burst %.3fs。", ...
        char(previewReport.modulationType), previewReport.signal.durationSec));
    drawnow;

    progress = uiprogressdlg(ui.fig, ...
        "Title", "运行 robust_unified 演示", ...
        "Message", "正在仿真链路...", ...
        "Indeterminate", "on");

    [~, report] = local_run_demo_case(cfg);
    if ~isempty(progress) && isvalid(progress)
        close(progress);
    end

    local_append_status(ui, sprintf( ...
        '运行完成。%s, BER=%.4g, rawPER=%.4g, PER=%.4g, PER_exact=%.4g, bitPerfect=%d, elapsed=%.3fs', ...
        char(report.modulationType), report.ber, report.rawPer, report.per, report.perExact, ...
        report.endToEndBitPerfect, report.elapsedSec));
    local_update_signal_axes(ui, report);
    local_append_status(ui, "已保存 RX 图像: " + string(report.savedImages.rxDisplay));
    local_append_status(ui, "已保存信号监视图: " + string(report.savedImages.signalMonitorFigure));
    local_show_comparison_figure(report);
    local_append_status(ui, "已保存对比图: " + string(report.savedImages.comparisonFigure));
    if report.per <= 1e-12 && report.ber > 1e-6
        local_append_status(ui, sprintf([ ...
            '警告：当前 PER 是 RS 后的 packet-level 指标，但 BER=%.4g 仍非零，' ...
            '因此图像质量可能仍然较差。'], report.ber));
    end
    if ~report.endToEndBitPerfect
        local_append_status(ui, sprintf( ...
            'Exact payload 仍未完全恢复：PER_exact=%.4g。判断图像质量时应看 BER/PER_exact，不能只看 PER。', ...
            report.perExact));
    end

catch ME
    if ~isempty(progress) && isvalid(progress)
        close(progress);
    end
    local_append_status(ui, "运行失败: " + string(ME.message));
    uialert(ui.fig, ME.message, "运行失败", "Icon", "error");
    rethrow(ME);
end
end

function local_restore_run_button(ui)
if isfield(ui, "runButton") && isvalid(ui.runButton)
    ui.runButton.Enable = "on";
end
if isfield(ui, "fig") && isvalid(ui.fig)
    ui.fig.Pointer = "arrow";
end
drawnow;
end

function local_append_status(ui, textLine)
oldLines = string(ui.status.Value(:));
if isscalar(oldLines) && strlength(oldLines) == 0
    oldLines = strings(0, 1);
end
timestamp = string(datetime("now", "Format", "HH:mm:ss"));
ui.status.Value = cellstr([oldLines; timestamp + "  " + string(textLine)]);
drawnow;
end

function local_clear_status(ui)
ui.status.Value = {''};
end

function cfg = local_collect_demo_cfg(ui)
cfg = struct();
cfg.imagePath = string(strtrim(ui.imagePath.Value));
cfg.resultsRoot = string(strtrim(ui.resultsRoot.Value));
cfg.ebN0dB = double(ui.ebn0.Value);
cfg.jsrDb = double(ui.jsr.Value);
cfg.modulationType = upper(string(ui.modulation.Value));
cfg.enableImpulse = logical(ui.enableImpulse.Value);
cfg.enableNarrowband = logical(ui.enableNarrowband.Value);
cfg.enableMultipath = logical(ui.enableMultipath.Value);
cfg.impulseProb = double(ui.impulseProb.Value);
cfg.nbCenter = double(ui.nbCenter.Value);
cfg.nbBandwidthText = string(strtrim(ui.nbBandwidth.Value));
cfg.mpDelays = local_parse_numeric_vector(ui.mpDelays.Value, true, "Multipath delays");
cfg.mpGains = local_parse_numeric_vector(ui.mpGains.Value, false, "Multipath gains");

if strlength(cfg.imagePath) == 0
    error("图像路径不能为空。");
end
if ~isfile(cfg.imagePath)
    error("找不到图像文件: %s", char(cfg.imagePath));
end
if strlength(cfg.resultsRoot) == 0
    error("结果目录不能为空。");
end
if ~exist(char(cfg.resultsRoot), "dir")
    mkdir(char(cfg.resultsRoot));
end
if ~(cfg.enableImpulse || cfg.enableNarrowband || cfg.enableMultipath)
    error("至少需要启用一种干扰。");
end
if ~(isscalar(cfg.ebN0dB) && isfinite(cfg.ebN0dB))
    error("Eb/N0 必须是有限标量。");
end
if ~(isscalar(cfg.jsrDb) && isfinite(cfg.jsrDb))
    error("JSR 必须是有限标量。");
end
if ~isscalar(cfg.modulationType) || ~any(cfg.modulationType == ["QPSK" "BPSK" "MSK"])
    error("不支持的调制方式: %s。", char(cfg.modulationType));
end
if cfg.enableImpulse
    if ~(isscalar(cfg.impulseProb) && isfinite(cfg.impulseProb) && cfg.impulseProb > 0 && cfg.impulseProb <= 1)
        error("impulseProb 必须位于 (0, 1]。");
    end
end
if cfg.enableMultipath
    if isempty(cfg.mpDelays)
        error("Multipath delays 不能为空。");
    end
    if isempty(cfg.mpGains)
        error("Multipath gains 不能为空。");
    end
    if numel(cfg.mpDelays) ~= numel(cfg.mpGains)
        error("Multipath delays 和 gains 的长度必须一致。");
    end
    if any(cfg.mpDelays < 0) || any(abs(cfg.mpDelays - round(cfg.mpDelays)) > 1e-12)
        error("Multipath delays 必须是非负整数。");
    end
end
if cfg.enableNarrowband
    if ~(isscalar(cfg.nbCenter) && isfinite(cfg.nbCenter))
        error("Narrowband center 必须是有限标量。");
    end
end
end

function [results, report] = local_run_demo_case(cfg)
spec = local_build_demo_spec(cfg);

timestampTag = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
runDir = fullfile(char(cfg.resultsRoot), char("robust_unified_demo_" + timestampTag));
mkdir(runDir);
spec.sim.resultsDir = runDir;
runtimeCfg = compile_runtime_config(spec);
validate_link_profile(spec);

elapsedTic = tic;
results = run_link_profile(spec);
elapsedSec = toc(elapsedTic);

if numel(results.methods) ~= 1
    error("results 中应只有一个 method，实际为 %d。", numel(results.methods));
end

methodName = string(results.methods(1));
methodField = char(methodName);
if ~(isfield(results, "example") && numel(results.example) >= 1 ...
        && isfield(results.example(1), "methods") ...
        && isfield(results.example(1).methods, methodField))
    error("缺少 method %s 对应的 example 图像。", methodField);
end

txImgOriginal = results.sourceImages.original;
txImgResized = results.sourceImages.resized;
exampleEntry = results.example(1).methods.(methodField);
requiredExampleFields = ["imgRxResized" "imgRx"];
for idx = 1:numel(requiredExampleFields)
    fieldName = requiredExampleFields(idx);
    if ~isfield(exampleEntry, fieldName)
        error("method %s 的 example entry 缺少字段 %s。", methodField, fieldName);
    end
end
rxImgResized = local_require_uint8_image(exampleEntry.imgRxResized, "example imgRxResized");
rxImgDisplay = local_require_uint8_image(exampleEntry.imgRx, "example imgRx");

savedImages = local_save_demo_images(runDir, txImgOriginal, txImgResized, rxImgResized, rxImgDisplay);
report = local_build_demo_report(results, cfg, runtimeCfg, runDir, savedImages, ...
    txImgOriginal, txImgResized, rxImgResized, rxImgDisplay, elapsedSec);
local_save_signal_monitor_figure(report);
save(fullfile(runDir, "demo_report.mat"), "report", "cfg", "results");
end

function previewReport = local_build_demo_tx_preview_report(cfg)
spec = local_build_demo_spec(cfg);
runtimeCfg = compile_runtime_config(spec);
validate_link_profile(spec);
txArtifacts = build_tx_artifacts(spec, runtimeCfg);
previewResults = struct("txArtifacts", txArtifacts);

previewReport = struct();
previewReport.modulationType = string(cfg.modulationType);
previewReport.ebN0dB = double(cfg.ebN0dB);
previewReport.jsrDb = double(cfg.jsrDb);
previewReport.signal = local_build_signal_monitor_report(previewResults, runtimeCfg);
end

function spec = local_build_demo_spec(cfg)
spec = default_link_spec( ...
    "linkProfileName", "robust_unified", ...
    "loadMlModels", string.empty(1, 0), ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false);

spec.commonTx.source.useBuiltinImage = false;
spec.commonTx.source.imagePath = cfg.imagePath;
spec.commonTx.modulation.type = cfg.modulationType;
spec.sim.nFramesPerPoint = 1;
spec.sim.saveFigures = false;
spec.sim.useParallel = false;
spec.linkBudget.ebN0dBList = cfg.ebN0dB;
spec.linkBudget.jsrDbList = cfg.jsrDb;

% Lock the demo to the currently validated fixed path.
spec.profileRx.cfg.methods = "robust_combo";
spec.profileRx.cfg.mitigation.robustMixed.narrowbandFrontend = "fh_erasure";
spec.profileRx.cfg.mitigation.robustMixed.enableFhSubbandExcision = false;
spec.profileRx.cfg.mitigation.robustMixed.enableScFdeNbiCancel = false;
spec.profileRx.cfg.mitigation.robustMixed.enableSampleNbiCancel = false;
spec.profileRx.cfg.mitigation.robustMixed.enableFhReliabilityFloorWithMultipath = false;

spec.channel.impulseProb = 0.0;
spec.channel.impulseWeight = 0.0;
spec.channel.impulseToBgRatio = 0.0;
spec.channel.narrowband.enable = false;
spec.channel.narrowband.weight = 0.0;
spec.channel.narrowband.centerFreqPoints = 0;
spec.channel.multipath.enable = false;

if cfg.enableImpulse
    spec.channel.impulseProb = cfg.impulseProb;
    spec.channel.impulseWeight = 1.0;
end
if cfg.enableNarrowband
    spec.channel.narrowband.enable = true;
    spec.channel.narrowband.weight = 1.0;
    spec.channel.narrowband.centerFreqPoints = cfg.nbCenter;
    spec.channel.narrowband.bandwidthFreqPoints = local_resolve_demo_narrowband_bandwidth(spec, cfg.nbBandwidthText);
end
if cfg.enableMultipath
    spec.channel.multipath.enable = true;
    spec.channel.multipath.pathDelaysSymbols = cfg.mpDelays;
    spec.channel.multipath.pathGainsDb = cfg.mpGains;
    spec.channel.multipath.rayleigh = true;
end

runtimeCfg = compile_runtime_config(spec);
if cfg.enableNarrowband
    [maxAbsCenter, ~] = narrowband_center_freq_points_limit( ...
        runtimeCfg.fh, runtimeCfg.waveform, spec.channel.narrowband.bandwidthFreqPoints);
    if abs(spec.channel.narrowband.centerFreqPoints) > maxAbsCenter
        error("Narrowband center %.6g 超出合法范围 [-%.6g, %.6g]。", ...
            spec.channel.narrowband.centerFreqPoints, maxAbsCenter, maxAbsCenter);
    end
end
if cfg.enableMultipath && ~(cfg.enableImpulse || cfg.enableNarrowband) && abs(cfg.jsrDb) > 1e-12
    error("仅启用 multipath 时，JSR 必须为 0。");
end
end

function bw = local_resolve_demo_narrowband_bandwidth(spec, rawText)
rawText = lower(strtrim(string(rawText)));
if rawText == "" || rawText == "auto"
    runtimeCfg = compile_runtime_config(spec);
    bw = narrowband_prespread_fh_bandwidth_points(runtimeCfg.fh, runtimeCfg.waveform, runtimeCfg.dsss);
    return;
end
value = str2double(rawText);
if ~(isscalar(value) && isfinite(value) && value > 0)
    error("Narrowband bandwidth 必须是正标量或 'auto'。");
end
bw = double(value);
end

function savedImages = local_save_demo_images(runDir, txImgOriginal, txImgResized, rxImgResized, rxImgDisplay)
savedImages = struct();
savedImages.txOriginal = string(fullfile(runDir, "tx_original.png"));
savedImages.txResized = string(fullfile(runDir, "tx_resized.png"));
savedImages.rxResized = string(fullfile(runDir, "rx_resized.png"));
savedImages.rxDisplay = string(fullfile(runDir, "rx_display.png"));
savedImages.comparisonFigure = string(fullfile(runDir, "comparison.png"));
savedImages.signalMonitorFigure = string(fullfile(runDir, "signal_monitor.png"));

imwrite(local_require_uint8_image(txImgOriginal, "tx original"), char(savedImages.txOriginal));
imwrite(local_require_uint8_image(txImgResized, "tx resized"), char(savedImages.txResized));
imwrite(local_require_uint8_image(rxImgResized, "rx resized"), char(savedImages.rxResized));
imwrite(local_require_uint8_image(rxImgDisplay, "rx display"), char(savedImages.rxDisplay));
end

function img = local_require_uint8_image(img, imageName)
if ~(isa(img, "uint8") && ndims(img) <= 3)
    error("%s 必须是 ndims <= 3 的 uint8 图像。", imageName);
end
end

function report = local_build_demo_report(results, cfg, runtimeCfg, runDir, savedImages, ...
        txImgOriginal, txImgResized, rxImgResized, rxImgDisplay, elapsedSec)
methodIdx = 1;
pointIdx = 1;

report = struct();
report.runDir = string(runDir);
report.method = string(results.methods(methodIdx));
report.imagePath = string(cfg.imagePath);
report.modulationType = string(cfg.modulationType);
report.savedImages = savedImages;
report.txImageOriginal = txImgOriginal;
report.txImageResized = txImgResized;
report.rxImageResized = rxImgResized;
report.rxImageDisplay = rxImgDisplay;
report.activeInterferences = local_active_interference_names(cfg);
report.interferenceConfig = struct( ...
    "enableImpulse", logical(cfg.enableImpulse), ...
    "impulseProb", double(cfg.impulseProb), ...
    "enableNarrowband", logical(cfg.enableNarrowband), ...
    "narrowbandCenter", double(cfg.nbCenter), ...
    "narrowbandBandwidth", local_safe_channel_bandwidth_local(results.linkSpec.channel), ...
    "enableMultipath", logical(cfg.enableMultipath), ...
    "multipathDelays", double(cfg.mpDelays(:).'), ...
    "multipathGainsDb", double(cfg.mpGains(:).'));
report.ebN0dB = double(results.ebN0dB(pointIdx));
report.jsrDb = double(results.jsrDb(pointIdx));
report.elapsedSec = double(elapsedSec);
report.burstSec = double(results.tx.burstDurationSec);
report.ber = double(results.ber(methodIdx, pointIdx));
report.rawPer = double(results.rawPer(methodIdx, pointIdx));
report.per = double(results.per(methodIdx, pointIdx));
if isfield(results, "perExact") && ~isempty(results.perExact)
    report.perExact = double(results.perExact(methodIdx, pointIdx));
else
    report.perExact = double(report.ber > 1e-12);
end
report.endToEndBitPerfect = logical(report.ber <= 1e-12);
report.frontEndSuccess = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(methodIdx, pointIdx));
report.phyHeaderSuccess = double(results.packetDiagnostics.bob.phyHeaderSuccessRateByMethod(methodIdx, pointIdx));
report.headerSuccess = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(methodIdx, pointIdx));
report.sessionTransportSuccess = double(results.packetDiagnostics.bob.sessionTransportSuccessRateByMethod(methodIdx, pointIdx));
report.packetSessionSuccess = double(results.packetDiagnostics.bob.packetSessionSuccessRateByMethod(methodIdx, pointIdx));
report.payloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(methodIdx, pointIdx));
report.spectrum = results.spectrum;
report.signal = local_build_signal_monitor_report(results, runtimeCfg);
report.runtime = struct( ...
    "profileName", string(runtimeCfg.linkProfile.name), ...
    "modulationType", string(runtimeCfg.mod.type), ...
    "sampleRateHz", double(runtimeCfg.waveform.sampleRateHz), ...
    "sps", double(runtimeCfg.waveform.sps), ...
    "rolloff", double(runtimeCfg.waveform.rolloff));
end

function bandwidth = local_safe_channel_bandwidth_local(channelCfg)
bandwidth = NaN;
if isstruct(channelCfg) && isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) ...
        && isfield(channelCfg.narrowband, "bandwidthFreqPoints")
    bandwidth = double(channelCfg.narrowband.bandwidthFreqPoints);
end
end

function names = local_active_interference_names(cfg)
names = strings(1, 0);
if cfg.enableImpulse
    names(end + 1) = "impulse";
end
if cfg.enableNarrowband
    names(end + 1) = "narrowband";
end
if cfg.enableMultipath
    names(end + 1) = "rayleigh_multipath";
end
end

function signal = local_build_signal_monitor_report(results, runtimeCfg)
if ~(isfield(results, "txArtifacts") && isstruct(results.txArtifacts) ...
        && isfield(results.txArtifacts, "burstForChannel"))
    error("信号监视需要 results.txArtifacts.burstForChannel。");
end
txWave = results.txArtifacts.burstForChannel(:);
if isempty(txWave)
    error("信号监视收到空的 TX burst。");
end
Fs = double(runtimeCfg.waveform.sampleRateHz);
if ~(isscalar(Fs) && isfinite(Fs) && Fs > 0)
    error("信号监视需要正数 waveform.sampleRateHz。");
end

viewSamples = min(numel(txWave), max(1, round(0.02 * Fs)));
idx = local_evenly_spaced_indices_local(viewSamples, 5000);
txView = txWave(idx);
timeSec = (double(idx(:)) - 1) / Fs;

hasSpectrum = isfield(results, "spectrum") && isstruct(results.spectrum) ...
    && isfield(results.spectrum, "freqHz") && isfield(results.spectrum, "psd");
if hasSpectrum
    freqHz = double(results.spectrum.freqHz(:));
    psd = double(results.spectrum.psd(:));
else
    freqHz = zeros(0, 1);
    psd = zeros(0, 1);
end
validSpectrum = hasSpectrum && numel(freqHz) == numel(psd) && ~isempty(freqHz) ...
    && any(isfinite(freqHz)) && any(isfinite(psd) & psd > 0);
if ~validSpectrum
    [psd, freqHz, bw99Hz, etaBpsHz] = estimate_spectrum( ...
        txWave, results.txArtifacts.commonMeta.modInfo, runtimeCfg.waveform, ...
        struct("payloadBits", numel(results.txArtifacts.payloadAssist.payloadBitsPlain)));
else
    bw99Hz = double(results.spectrum.bw99Hz);
    etaBpsHz = double(results.spectrum.etaBpsHz);
end
freqHz = double(freqHz(:));
psd = double(psd(:));
psdDbHz = 10 * log10(max(psd, realmin));

signal = struct( ...
    "sampleRateHz", Fs, ...
    "durationSec", double(numel(txWave)) / Fs, ...
    "timeSec", timeSec(:), ...
    "real", real(txView(:)), ...
    "imag", imag(txView(:)), ...
    "magnitude", abs(txView(:)), ...
    "freqHz", freqHz, ...
    "psdDbHz", psdDbHz, ...
    "bw99Hz", double(bw99Hz), ...
    "etaBpsHz", double(etaBpsHz));
end

function idx = local_evenly_spaced_indices_local(nAvailable, maxSamples)
nAvailable = max(1, round(double(nAvailable)));
maxSamples = max(1, round(double(maxSamples)));
if nAvailable <= maxSamples
    idx = (1:nAvailable).';
    return;
end
idx = unique(round(linspace(1, nAvailable, maxSamples))).';
idx = max(1, min(nAvailable, idx));
end

function local_reset_signal_axes(ui, message)
if ~(isfield(ui, "timeAxis") && isvalid(ui.timeAxis) && isfield(ui, "freqAxis") && isvalid(ui.freqAxis))
    return;
end
local_draw_empty_axis_local(ui.timeAxis, "时域", message);
local_draw_empty_axis_local(ui.freqAxis, "频域", message);
end

function local_draw_empty_axis_local(ax, titleText, message)
cla(ax, "reset");
ax.XLim = [0 1];
ax.YLim = [0 1];
ax.XTick = [];
ax.YTick = [];
title(ax, titleText);
text(ax, 0.5, 0.5, char(string(message)), ...
    "HorizontalAlignment", "center", ...
    "VerticalAlignment", "middle", ...
    "Color", [0.35 0.35 0.35]);
box(ax, "on");
end

function local_update_signal_axes(ui, report)
if ~(isfield(ui, "timeAxis") && isvalid(ui.timeAxis) && isfield(ui, "freqAxis") && isvalid(ui.freqAxis))
    return;
end
local_plot_signal_monitor_axes(ui.timeAxis, ui.freqAxis, report);
drawnow;
end

function local_plot_signal_monitor_axes(timeAx, freqAx, report)
if ~(isfield(report, "signal") && isstruct(report.signal))
    error("信号监视绘图需要 report.signal。");
end
sig = report.signal;

cla(timeAx, "reset");
tMs = double(sig.timeSec(:)) * 1e3;
plot(timeAx, tMs, double(sig.real(:)), "Color", [0.10 0.32 0.76], "LineWidth", 0.85);
hold(timeAx, "on");
plot(timeAx, tMs, double(sig.imag(:)), "Color", [0.78 0.18 0.16], "LineWidth", 0.85);
plot(timeAx, tMs, double(sig.magnitude(:)), "Color", [0.10 0.10 0.10], "LineStyle", ":", "LineWidth", 0.85);
hold(timeAx, "off");
grid(timeAx, "on");
box(timeAx, "on");
xlabel(timeAx, "时间 (ms)");
ylabel(timeAx, "幅度");
title(timeAx, sprintf("TX 时域 | %s | 前 %.2f ms", ...
    char(report.modulationType), max(tMs)));
legend(timeAx, ["实部" "虚部" "|x|"], "Location", "northeast");

cla(freqAx, "reset");
freqKhz = double(sig.freqHz(:)) / 1e3;
psdDbHz = double(sig.psdDbHz(:));
finiteUse = isfinite(freqKhz) & isfinite(psdDbHz);
if ~any(finiteUse)
    local_draw_empty_axis_local(freqAx, "频域", "没有有限 PSD 样本");
    return;
end
plot(freqAx, freqKhz(finiteUse), psdDbHz(finiteUse), "Color", [0.05 0.45 0.36], "LineWidth", 0.95);
grid(freqAx, "on");
box(freqAx, "on");
xlabel(freqAx, "频率 (kHz)");
ylabel(freqAx, "PSD (dB/Hz)");
if isfinite(double(sig.bw99Hz)) && double(sig.bw99Hz) > 0
    halfBwKhz = double(sig.bw99Hz) / 2e3;
    xline(freqAx, -halfBwKhz, "--", "Color", [0.35 0.35 0.35]);
    xline(freqAx, halfBwKhz, "--", "Color", [0.35 0.35 0.35]);
end
title(freqAx, sprintf("TX 频域 | BW99 %.1f kHz | eta %.3g bit/s/Hz", ...
    double(sig.bw99Hz) / 1e3, double(sig.etaBpsHz)));
end

function local_save_signal_monitor_figure(report)
fig = figure("Name", "Robust Unified 信号监视", ...
    "Color", "w", ...
    "NumberTitle", "off", ...
    "Visible", "off");
cleanupObj = onCleanup(@() close(fig));
t = tiledlayout(fig, 2, 1, "Padding", "compact", "TileSpacing", "compact");
timeAx = nexttile(t);
freqAx = nexttile(t);
local_plot_signal_monitor_axes(timeAx, freqAx, report);
sgtitle(t, sprintf("robust_unified 信号监视 | %s | Eb/N0 %.2f dB | JSR %.2f dB", ...
    char(report.modulationType), report.ebN0dB, report.jsrDb));
exportgraphics(fig, char(report.savedImages.signalMonitorFigure), "Resolution", 160);
end

function local_show_comparison_figure(report)
fig = figure("Name", "Robust Unified 演示对比", "Color", "w", "NumberTitle", "off");
t = tiledlayout(fig, 2, 2, "Padding", "compact", "TileSpacing", "compact");

nexttile(t);
imshow(report.txImageOriginal);
title("原始输入");

nexttile(t);
imshow(report.txImageResized);
title(sprintf('实际 TX (%dx%d)', size(report.txImageResized, 2), size(report.txImageResized, 1)));

nexttile(t);
imshow(report.rxImageResized);
title(sprintf('恢复 RX (%dx%d)', size(report.rxImageResized, 2), size(report.rxImageResized, 1)));

nexttile(t);
imshow(report.rxImageDisplay);
title(sprintf('显示 RX (%dx%d)', size(report.rxImageDisplay, 2), size(report.rxImageDisplay, 1)));

sgtitle(t, sprintf([ ...
    'robust_unified | %s | %s | Eb/N0 %.2f dB | JSR %.2f dB | BER %.3g | rawPER %.3g | ' ...
    'PER %.3g | PER_exact %.3g | bitPerfect %d | burst %.3fs | elapsed %.3fs'], ...
    strjoin(cellstr(report.activeInterferences), " + "), ...
    char(report.modulationType), report.ebN0dB, report.jsrDb, report.ber, report.rawPer, report.per, report.perExact, ...
    report.endToEndBitPerfect, report.burstSec, report.elapsedSec));

exportgraphics(fig, char(report.savedImages.comparisonFigure), "Resolution", 160);
end

function values = local_parse_numeric_vector(rawText, requireInteger, fieldName)
textValue = string(rawText);
textValue = regexprep(textValue, "[\\[\\],;]", " ");
values = sscanf(char(textValue), "%f").';
if isempty(values)
    error("%s 不能为空。", char(fieldName));
end
if any(~isfinite(values))
    error("%s 必须包含有限数值。", char(fieldName));
end
if requireInteger && any(abs(values - round(values)) > 1e-12)
    error("%s 必须包含整数。", char(fieldName));
end
if requireInteger
    values = round(values);
end
end

function p = local_parent_or_pwd(pathText)
pathText = string(pathText);
if strlength(pathText) == 0
    p = string(pwd);
    return;
end
if isfolder(pathText)
    p = pathText;
    return;
end
[folderPath, ~, ~] = fileparts(char(pathText));
if strlength(string(folderPath)) == 0
    p = string(pwd);
else
    p = string(folderPath);
end
end
