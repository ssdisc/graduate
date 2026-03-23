function save_figures(outDir, imgTx, results)
%SAVE_FIGURES  将标准图形（BER/MSE/PSNR/KL/PSD/图像）保存到磁盘。
%
% 输入:
%   outDir  - 输出目录
%   imgTx   - 发送端原图
%   results - 仿真结果结构体
%             .methods, .ebN0dB, .ber
%             .imageMetrics.communication/.compensated（或兼容字段.mse/.psnr/.ssim）
%             .kl（含signalVsNoise/noiseVsSignal/symmetric）
%             .spectrum（freqHz, psd, bw99Hz, etaBpsHz）
%             .example（按Eb/N0点保存示例接收图）
%                 .example(i).EbN0dB - 第i个Eb/N0点
%                 .example(i).methods.<method>.imgRxComm/.imgRxCompensated - 该点该方法示例图
%             .eve（可选，含 .example(i).methods.<method>.headerOk/.imgRx）
%             .covert.warden（可选）
%
% 输出:
%   无（直接写图到磁盘）

methods = results.methods;
EbN0dB = results.ebN0dB;
[commMetrics, compMetrics] = local_get_image_metrics(results);
packetConcealActive = local_packet_conceal_active(results);

fig1 = local_create_line_figure("BER");
ax1 = axes(fig1);
local_plot_series_matrix(ax1, EbN0dB, results.ber, "logy");
local_apply_line_labels(ax1, "E_b/N_0 (dB)", "BER (payload)");
local_format_ber_axis(ax1, EbN0dB, results.ber);
local_style_legend(ax1, methods, "southwest");
local_export_figure(fig1, fullfile(outDir, "ber.png"), "");
close(fig1);

fig2 = local_create_line_figure("PSNR (Communication)");
ax2 = axes(fig2);
local_plot_series_matrix(ax2, EbN0dB, commMetrics.psnr, "linear");
local_apply_line_labels(ax2, "E_b/N_0 (dB)", "PSNR (dB, communication only)");
local_style_legend(ax2, methods, "southeast");
local_export_figure(fig2, fullfile(outDir, "psnr.png"), fullfile(outDir, "psnr_comm.png"));
close(fig2);

fig2m = local_create_line_figure("MSE (Communication)");
ax2m = axes(fig2m);
local_plot_series_matrix(ax2m, EbN0dB, commMetrics.mse, "logy");
local_apply_line_labels(ax2m, "E_b/N_0 (dB)", "MSE (communication only)");
local_style_legend(ax2m, methods, "northeast");
local_export_figure(fig2m, fullfile(outDir, "mse.png"), fullfile(outDir, "mse_comm.png"));
close(fig2m);

if packetConcealActive
    fig2c = local_create_line_figure("PSNR (Compensated)");
    ax2c = axes(fig2c);
    local_plot_series_matrix(ax2c, EbN0dB, compMetrics.psnr, "linear");
    local_apply_line_labels(ax2c, "E_b/N_0 (dB)", "PSNR (dB, after concealment)");
    local_style_legend(ax2c, methods, "southeast");
    local_export_figure(fig2c, fullfile(outDir, "psnr_compensated.png"), "");
    close(fig2c);

    fig2cm = local_create_line_figure("MSE (Compensated)");
    ax2cm = axes(fig2cm);
    local_plot_series_matrix(ax2cm, EbN0dB, compMetrics.mse, "logy");
    local_apply_line_labels(ax2cm, "E_b/N_0 (dB)", "MSE (after concealment)");
    local_style_legend(ax2cm, methods, "northeast");
    local_export_figure(fig2cm, fullfile(outDir, "mse_compensated.png"), "");
    close(fig2cm);
end

if isfield(results, "kl")
    fig2k = local_create_line_figure("KL Divergence");
    ax2k = axes(fig2k);
    klValues = [results.kl.signalVsNoise(:).'; results.kl.symmetric(:).'];
    local_plot_series_matrix(ax2k, results.kl.ebN0dB, klValues, "linear");
    local_apply_line_labels(ax2k, "E_b/N_0 (dB)", "KL divergence");
    local_style_legend(ax2k, ["KL(P_{sig}||P_{noise})", "Symmetric KL"], "best");
    local_export_figure(fig2k, fullfile(outDir, "kl.png"), "");
    close(fig2k);
end


if isfield(results, "eve")
    [commMetricsEve, compMetricsEve] = local_get_image_metrics(results.eve);
    fig2b = local_create_line_figure("PSNR (Eve, Communication)");
    ax2b = axes(fig2b);
    local_plot_series_matrix(ax2b, results.eve.ebN0dB, commMetricsEve.psnr, "linear");
    local_apply_line_labels(ax2b, "E_b/N_0 at Eve (dB)", "PSNR (dB, communication only)");
    local_style_legend(ax2b, methods, "southeast");
    local_export_figure(fig2b, fullfile(outDir, "psnr_eve.png"), fullfile(outDir, "psnr_eve_comm.png"));
    close(fig2b);

    if isfield(commMetricsEve, "mse")
        fig2bm = local_create_line_figure("MSE (Eve, Communication)");
        ax2bm = axes(fig2bm);
        local_plot_series_matrix(ax2bm, results.eve.ebN0dB, commMetricsEve.mse, "logy");
        local_apply_line_labels(ax2bm, "E_b/N_0 at Eve (dB)", "MSE (communication only)");
        local_style_legend(ax2bm, methods, "northeast");
        local_export_figure(fig2bm, fullfile(outDir, "mse_eve.png"), fullfile(outDir, "mse_eve_comm.png"));
        close(fig2bm);
    end

    if packetConcealActive
        fig2bc = local_create_line_figure("PSNR (Eve, Compensated)");
        ax2bc = axes(fig2bc);
        local_plot_series_matrix(ax2bc, results.eve.ebN0dB, compMetricsEve.psnr, "linear");
        local_apply_line_labels(ax2bc, "E_b/N_0 at Eve (dB)", "PSNR (dB, after concealment)");
        local_style_legend(ax2bc, methods, "southeast");
        local_export_figure(fig2bc, fullfile(outDir, "psnr_eve_compensated.png"), "");
        close(fig2bc);

        fig2bcm = local_create_line_figure("MSE (Eve, Compensated)");
        ax2bcm = axes(fig2bcm);
        local_plot_series_matrix(ax2bcm, results.eve.ebN0dB, compMetricsEve.mse, "logy");
        local_apply_line_labels(ax2bcm, "E_b/N_0 at Eve (dB)", "MSE (after concealment)");
        local_style_legend(ax2bcm, methods, "northeast");
        local_export_figure(fig2bcm, fullfile(outDir, "mse_eve_compensated.png"), "");
        close(fig2bcm);
    end

    fig1b = local_create_line_figure("BER (Eve)");
    ax1b = axes(fig1b);
    local_plot_series_matrix(ax1b, results.eve.ebN0dB, results.eve.ber, "logy");
    local_apply_line_labels(ax1b, "E_b/N_0 at Eve (dB)", "BER (payload)");
    local_format_ber_axis(ax1b, results.eve.ebN0dB, results.eve.ber);
    local_style_legend(ax1b, methods, "southwest");
    local_export_figure(fig1b, fullfile(outDir, "ber_eve.png"), "");
    close(fig1b);
end

fig3 = local_create_line_figure("Spectrum");
ax3 = axes(fig3);
local_plot_series_matrix(ax3, results.spectrum.freqHz(:).'/1e3, 10*log10(results.spectrum.psd(:)).', "linear", false, false);
local_apply_line_labels(ax3, ...
    "Frequency (kHz)", ...
    "PSD (dB/Hz)", ...
    sprintf("99%% OBW=%.1f Hz,  \\eta=%.3f b/s/Hz", results.spectrum.bw99Hz, results.spectrum.etaBpsHz));
local_export_figure(fig3, fullfile(outDir, "psd.png"), "");
close(fig3);

% ========== 按Eb/N0点保存整合图 ==========
imagesDir = fullfile(outDir, "images");
if ~exist(imagesDir, 'dir')
    mkdir(imagesDir);
end

figTx = figure("Name", "TX Image", "Visible", "off");
imshow(imgTx);
title("TX (原图)", "FontSize", 14);
local_export_figure(figTx, fullfile(imagesDir, "00_tx_original.png"), "", 'Resolution', 200);
close(figTx);

exampleVariants = local_example_variants(packetConcealActive);
nMethods = numel(methods);

for ie = 1:numel(EbN0dB)
    examplePoint = local_get_example_point(results.example, ie, EbN0dB(ie));
    fig4 = figure("Name", sprintf("Images @ %.1f dB", EbN0dB(ie)), "Visible", "off");
    fig4.Position = [100 100 320 * (nMethods + 1) 300 * numel(exampleVariants)];
    tl4 = tiledlayout(fig4, numel(exampleVariants), nMethods + 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl4, sprintf("Bob Integrated Images @ Eb/N0=%.1f dB", EbN0dB(ie)));

    for iv = 1:numel(exampleVariants)
        variant = exampleVariants(iv);

        nexttile(tl4);
        imshow(imgTx);
        title(local_example_title_lines( ...
            sprintf("TX (%s)", variant.shortLabel), ...
            EbN0dB(ie), ...
            "Reference image"), "FontSize", 11);

        for k = 1:nMethods
            exampleEntry = local_get_method_example(examplePoint, methods(k));
            imgVariant = local_get_example_image_variant(exampleEntry, variant.key);
            if isempty(imgVariant)
                error("save_figures:MissingExampleImage", ...
                    "Missing %s image for method %s at Eb/N0=%.3f dB.", ...
                    char(variant.key), char(methods(k)), EbN0dB(ie));
            end

            nexttile(tl4);
            imshow(imgVariant);
            title(local_example_title_lines( ...
                sprintf("RX (%s) - %s", variant.shortLabel, methods(k)), ...
                EbN0dB(ie), ...
                local_example_metric_line(variant.key, commMetrics, compMetrics, k, ie, true)), ...
                "FontSize", 10);
        end
    end

    fileTag = local_snr_file_tag(EbN0dB(ie));
    local_export_figure(fig4, fullfile(imagesDir, sprintf("snr_%02d_%sdB.png", ie, fileTag)), "", 'Resolution', 170);
    close(fig4);
end

if isfield(results, "eve") && isfield(results.eve, "example")
    eveDir = fullfile(outDir, "images_eve");
    if ~exist(eveDir, 'dir')
        mkdir(eveDir);
    end

    for ie = 1:numel(EbN0dB)
        bobPoint = local_get_example_point(results.example, ie, EbN0dB(ie));
        evePoint = local_get_example_point(results.eve.example, ie, results.eve.ebN0dB(ie));

        fig5 = figure("Name", sprintf("Intercept @ %.1f dB", EbN0dB(ie)), "Visible", "off");
        nRows = 2 * numel(exampleVariants);
        fig5.Position = [100 100 320 * (nMethods + 1) 270 * nRows];
        tl5 = tiledlayout(fig5, nRows, nMethods + 1, 'TileSpacing', 'compact', 'Padding', 'compact');
        title(tl5, sprintf("Bob vs Eve @ Bob Eb/N0=%.1f dB, Eve Eb/N0=%.1f dB", ...
            EbN0dB(ie), results.eve.ebN0dB(ie)));

        for iv = 1:numel(exampleVariants)
            variant = exampleVariants(iv);

            nexttile(tl5);
            imshow(imgTx);
            title(local_example_title_lines( ...
                sprintf("TX / Bob (%s)", variant.shortLabel), ...
                EbN0dB(ie), ...
                "Reference image"), "FontSize", 11);

            for k = 1:nMethods
                bobEntry = local_get_method_example(bobPoint, methods(k));
                imgBobVariant = local_get_example_image_variant(bobEntry, variant.key);
                if isempty(imgBobVariant)
                    error("save_figures:MissingExampleImage", ...
                        "Missing Bob %s image for method %s at Eb/N0=%.3f dB.", ...
                        char(variant.key), char(methods(k)), EbN0dB(ie));
                end

                nexttile(tl5);
                imshow(imgBobVariant);
                title(local_example_title_lines( ...
                    sprintf("Bob (%s) - %s", variant.shortLabel, methods(k)), ...
                    EbN0dB(ie), ...
                    local_example_metric_line(variant.key, commMetrics, compMetrics, k, ie, false)), ...
                    "FontSize", 10);
            end

            nexttile(tl5);
            eveInfoLines = { ...
                char(sprintf("Eve (%s)", variant.shortLabel)); ...
                char(sprintf("Eb/N0=%.1f dB", results.eve.ebN0dB(ie))); ...
                "Intercept view"};
            text(0.05, 0.5, eveInfoLines, "Units", "normalized", "Interpreter", "none", "FontSize", 11);
            axis off;
            title("Eve");

            for k = 1:nMethods
                eveEntry = local_get_method_example(evePoint, methods(k));
                imgEveVariant = local_get_example_image_variant(eveEntry, variant.key);
                if isempty(imgEveVariant)
                    error("save_figures:MissingExampleImage", ...
                        "Missing Eve %s image for method %s at Eb/N0=%.3f dB.", ...
                        char(variant.key), char(methods(k)), results.eve.ebN0dB(ie));
                end

                nexttile(tl5);
                imshow(imgEveVariant);
                title(local_example_title_lines( ...
                    sprintf("Eve (%s) - %s%s", variant.shortLabel, methods(k), local_example_header_status(eveEntry)), ...
                    results.eve.ebN0dB(ie), ...
                    local_example_metric_line(variant.key, commMetricsEve, compMetricsEve, k, ie, false)), ...
                    "FontSize", 10);
            end
        end

        fileTag = local_snr_file_tag(EbN0dB(ie));
        local_export_figure(fig5, fullfile(eveDir, sprintf("snr_%02d_%sdB.png", ie, fileTag)), "", 'Resolution', 170);
        close(fig5);
    end
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    w = results.covert.warden;
    [x, xlab] = local_get_warden_axis(w);
    fig6 = local_create_line_figure("Warden");
    tl6 = tiledlayout(fig6, 2, 1, "TileSpacing", "compact", "Padding", "compact");

    ax6a = nexttile(tl6);
    if isfield(w, "layers") && isfield(w.layers, "energyNp")
        np = w.layers.energyNp;
        wardenValues = [np.pd(:).'; np.pfa(:).'; np.pe(:).'; np.xi(:).'];
    else
        wardenValues = [w.pdEst(:).'; w.pfaEst(:).'; w.peEst(:).'];
    end
    local_plot_series_matrix(ax6a, x, wardenValues, "linear");
    local_apply_line_labels(ax6a, ...
        xlab, ...
        "Probability", ...
        sprintf("Energy NP layer: P_FA target=%.3g, nObs=%d, nTrials=%d", w.pfaTarget, round(w.nObs(1)), round(w.nTrials)));
    if size(wardenValues, 1) >= 4
        local_style_legend(ax6a, ["P_D", "P_{FA}", "P_e", "\xi"], "best");
    else
        local_style_legend(ax6a, ["P_D", "P_{FA}", "P_e"], "best");
    end

    ax6b = nexttile(tl6);
    covertValues = [];
    covertLabels = strings(1, 0);
    if isfield(w, "layers") && isfield(w.layers, "energyOpt")
        covertValues = [covertValues; w.layers.energyOpt.xi(:).'; w.layers.energyOpt.pe(:).'];
        covertLabels = [covertLabels, "\xi^* (opt)", "P_e^* (opt)"];
    end
    if isfield(w, "layers") && isfield(w.layers, "energyOptUncertain")
        covertValues = [covertValues; ...
            w.layers.energyOptUncertain.xi(:).'; ...
            w.layers.energyOptUncertain.pe(:).'];
        covertLabels = [covertLabels, "\xi^* (opt+uncert.)", "P_e^* (opt+uncert.)"];
    end
    if isempty(covertValues)
        covertValues = [w.xiEst(:).'; w.peEst(:).'];
        covertLabels = ["\xi", "P_e"];
    end
    local_plot_series_matrix(ax6b, x, covertValues, "linear");
    local_apply_line_labels(ax6b, ...
        xlab, ...
        "Covert metric", ...
        sprintf("Primary layer: %s", local_get_primary_warden_layer(w)));
    local_style_legend(ax6b, covertLabels, "best");
    local_export_figure(fig6, fullfile(outDir, "warden.png"), "");
    close(fig6);
end
end

function fig = local_create_line_figure(name)
fig = figure("Name", name, "Color", "w", "Visible", "off");
fig.Position = [100 100 1000 632];
end

function local_export_figure(fig, primaryPath, aliasPath, varargin)
fprintf('[SIM][FIG] 导出 %s\n', char(string(primaryPath)));
exportgraphics(fig, primaryPath, varargin{:});
if nargin >= 3 && strlength(string(aliasPath)) > 0
    local_copy_export_alias(primaryPath, aliasPath);
end
end

function local_copy_export_alias(primaryPath, aliasPath)
fprintf('[SIM][FIG] 复制 %s\n', char(string(aliasPath)));
[ok, msg] = copyfile(primaryPath, aliasPath, 'f');
if ~ok
    error("save_figures:AliasCopyFailed", ...
        "Failed to copy exported figure from %s to %s: %s", ...
        char(string(primaryPath)), char(string(aliasPath)), msg);
end
end

function local_plot_series_matrix(ax, x, values, scaleMode, useDiscreteXAxis, showMarkers)
if nargin < 5
    useDiscreteXAxis = true;
end
if nargin < 6
    showMarkers = true;
end

values = local_align_series_matrix(x, values);
isLogY = string(scaleMode) == "logy";
if isLogY
    ax.YScale = "log";
end
hold(ax, "on");
for idx = 1:size(values, 1)
    style = local_pick_series_style(idx);
    y = values(idx, :);
    if isLogY
        y(y <= 0) = NaN;
    end
    h = plot(ax, x, y);
    local_apply_series_style(h, style, showMarkers);
end
hold(ax, "off");

local_apply_axes_style(ax);
if useDiscreteXAxis
    local_style_discrete_x_axis(ax, x);
end
grid(ax, "on");
end

function values = local_align_series_matrix(x, values)
nX = numel(x);

if isvector(values)
    values = reshape(values, 1, []);
end

if size(values, 2) == nX
    return;
end

if size(values, 1) == nX
    values = values.';
    return;
end

error("save_figures:InvalidSeriesShape", ...
    "Series data shape does not match x-axis length (%d).", nX);
end

function local_apply_axes_style(ax)
ax.FontName = "Times New Roman";
ax.FontSize = 18;
ax.LineWidth = 1.0;
ax.Box = "on";
ax.TickLabelInterpreter = "tex";
ax.GridLineStyle = "-";
ax.GridAlpha = 0.3;
ax.MinorGridAlpha = 0.15;
ax.XMinorGrid = "on";
ax.YMinorGrid = "on";
ax.Layer = "bottom";
end

function local_format_ber_axis(ax, x, values)
if nargin < 3
    yLim = ylim(ax);
    if any(~isfinite(yLim)) || yLim(1) <= 0 || yLim(2) <= 0
        return;
    end
    expMin = floor(log10(yLim(1)));
    expMax = ceil(log10(yLim(2)));
    yTicks = 10 .^ (expMin:expMax);
    yLabels = arrayfun(@(tick) sprintf("10^{%d}", round(log10(tick))), yTicks, "UniformOutput", false);
    ax.YTick = yTicks;
    ax.YTickLabel = yLabels;
    return;
end

x = x(:).';
values = local_align_series_matrix(x, values);
positiveVals = values(values > 0 & isfinite(values));

if isempty(positiveVals)
    zeroTick = 1e-2;
    positiveTicks = [1e-1 1];
else
    minPositive = min(positiveVals);
    maxPositive = max(positiveVals);
    expMinPositive = floor(log10(minPositive));
    expMaxPositive = ceil(log10(maxPositive));
    expMaxPositive = min(expMaxPositive, 0);
    if expMinPositive > expMaxPositive
        expMaxPositive = expMinPositive;
    end
    zeroTick = 10 ^ (expMinPositive - 1);
    positiveTicks = 10 .^ (expMinPositive:expMaxPositive);
end

positiveTicks = unique(positiveTicks, "stable");
positiveTicks = positiveTicks(positiveTicks > zeroTick);
if isempty(positiveTicks)
    positiveTicks = [zeroTick * 10, max(zeroTick * 100, 1)];
end

zeroPlotLevel = zeroTick * 1.15;
topLimit = max([positiveTicks, 1]);
ylim(ax, [zeroTick, topLimit]);

hold(ax, "on");
for idx = 1:size(values, 1)
    zeroMask = isfinite(values(idx, :)) & values(idx, :) == 0;
    if any(zeroMask)
        style = local_pick_series_style(idx);
        hZero = plot(ax, x(zeroMask), zeroPlotLevel * ones(1, nnz(zeroMask)));
        local_apply_series_style(hZero, style, true);
        hZero.LineStyle = "none";
        hZero.HandleVisibility = "off";
        hZero.Clipping = "on";
    end
end
hold(ax, "off");

yTicks = [zeroTick, positiveTicks];
yLabels = [{"0"}, arrayfun(@(tick) sprintf("10^{%d}", round(log10(tick))), positiveTicks, "UniformOutput", false)];
ax.YTick = yTicks;
ax.YTickLabel = yLabels;
end

function local_apply_line_labels(ax, xText, yText, titleText)
xlabel(ax, xText, "FontName", "Times New Roman", "FontSize", 16);
ylabel(ax, yText, "FontName", "Times New Roman", "FontSize", 16);
if nargin >= 4 && strlength(string(titleText)) > 0
    title(ax, titleText, "FontName", "Times New Roman", "FontSize", 18);
end
end

function local_style_legend(ax, labels, location)
leg = legend(ax, labels, "Location", location, "FontSize", 11);
leg.FontName = "Times New Roman";
leg.Box = "on";
leg.EdgeColor = [0 0 0];
leg.Color = [1 1 1];
end

function local_style_discrete_x_axis(ax, x)
xTicks = unique(x, "stable");
if isempty(xTicks) || numel(xTicks) > 10
    return;
end

ax.XTick = xTicks;
if isnumeric(xTicks)
    xMin = min(xTicks);
    xMax = max(xTicks);
    if xMin ~= xMax
        xlim(ax, [xMin - 1, xMax + 1]);
    end
end
end

function local_apply_series_style(h, style, showMarkers)
set(h, ...
    "Color", style.Color, ...
    "LineStyle", style.LineStyle, ...
    "LineWidth", 2.5);

if showMarkers
    set(h, ...
        "Marker", style.Marker, ...
        "MarkerSize", 9, ...
        "MarkerFaceColor", "none", ...
        "MarkerEdgeColor", style.Color);
else
    set(h, "Marker", "none");
end
end

function style = local_pick_series_style(index)
styles = local_series_styles();
if index > numel(styles)
    error("save_figures:InsufficientSeriesStyles", ...
        "Only %d unique series styles are defined, but series index %d was requested.", ...
        numel(styles), index);
end
style = styles(index);
end

function styles = local_series_styles()
styles = struct( ...
    "Color", {[213 94 0] / 255, [153 153 153] / 255, [230 159 0] / 255, ...
              [0 158 115] / 255, [204 121 167] / 255, [0 114 178] / 255, ...
              [86 180 233] / 255, [240 228 66] / 255}, ...
    "LineStyle", {"-", ":", "-.", "--", ":", "--", "-.", "-"}, ...
    "Marker", {"s", "o", "v", "^", "d", "p", "x", "h"});
end

function [commMetrics, compMetrics] = local_get_image_metrics(results)
commMetrics = struct("mse", results.mse, "psnr", results.psnr, "ssim", results.ssim);
compMetrics = commMetrics;

if isfield(results, "imageMetrics") && isstruct(results.imageMetrics)
    if isfield(results.imageMetrics, "communication")
        commMetrics = results.imageMetrics.communication;
    end
    if isfield(results.imageMetrics, "compensated")
        compMetrics = results.imageMetrics.compensated;
    end
end

if isfield(results, "mseCompensated")
    compMetrics.mse = results.mseCompensated;
end
if isfield(results, "psnrCompensated")
    compMetrics.psnr = results.psnrCompensated;
end
if isfield(results, "ssimCompensated")
    compMetrics.ssim = results.ssimCompensated;
end
end

function tf = local_packet_conceal_active(results)
tf = false;
if isfield(results, "packetConceal") && isfield(results.packetConceal, "active")
    tf = logical(results.packetConceal.active);
end
end

function variants = local_example_variants(packetConcealActive)
variants = struct( ...
    "key", "communication", ...
    "shortLabel", "Comm");
if packetConcealActive
    variants(2) = struct( ...
        "key", "compensated", ...
        "shortLabel", "Comp");
end
end

function examplePoint = local_get_example_point(examplePoints, pointIdx, expectedEbN0)
if ~isstruct(examplePoints) || numel(examplePoints) < pointIdx
    error("save_figures:InvalidExamplePoints", ...
        "results.example must be a struct array with one entry per Eb/N0 point.");
end

examplePoint = examplePoints(pointIdx);
if ~isfield(examplePoint, "methods") || ~isstruct(examplePoint.methods)
    error("save_figures:InvalidExamplePoint", ...
        "results.example(%d) must contain a struct field named methods.", pointIdx);
end

if ~isfield(examplePoint, "EbN0dB") || ~isfinite(double(examplePoint.EbN0dB))
    error("save_figures:InvalidExamplePoint", ...
        "results.example(%d).EbN0dB must be a finite scalar.", pointIdx);
end

if abs(double(examplePoint.EbN0dB) - double(expectedEbN0)) > 1e-9
    error("save_figures:ExampleEbN0Mismatch", ...
        "results.example(%d).EbN0dB=%.6f does not match expected Eb/N0 %.6f.", ...
        pointIdx, double(examplePoint.EbN0dB), double(expectedEbN0));
end
end

function exampleEntry = local_get_method_example(examplePoint, methodName)
methodName = char(string(methodName));
if ~isfield(examplePoint.methods, methodName)
    error("save_figures:MissingMethodExample", ...
        "Missing example entry for method %s at Eb/N0=%.6f dB.", ...
        methodName, double(examplePoint.EbN0dB));
end
exampleEntry = examplePoint.methods.(methodName);
if ~isstruct(exampleEntry)
    error("save_figures:InvalidMethodExample", ...
        "Example entry for method %s at Eb/N0=%.6f dB must be a struct.", ...
        methodName, double(examplePoint.EbN0dB));
end
end

function statusTxt = local_example_header_status(exampleEntry)
statusTxt = "";
if isfield(exampleEntry, "headerOk")
    if logical(exampleEntry.headerOk)
        statusTxt = " (hdr ok)";
    else
        statusTxt = " (hdr fail)";
    end
end
end

function tag = local_snr_file_tag(ebN0Val)
tag = char(string(sprintf("%.1f", double(ebN0Val))));
tag = strrep(tag, "-", "neg");
tag = strrep(tag, ".", "p");
end

function img = local_get_example_image_variant(exampleEntry, variantKey)
variantKey = lower(string(variantKey));
switch variantKey
    case "communication"
        if isfield(exampleEntry, "imgRxComm")
            img = exampleEntry.imgRxComm;
        elseif isfield(exampleEntry, "imgRx")
            img = exampleEntry.imgRx;
        elseif isfield(exampleEntry, "imgRxCompensated")
            img = exampleEntry.imgRxCompensated;
        else
            img = [];
        end
    case "compensated"
        if isfield(exampleEntry, "imgRxCompensated")
            img = exampleEntry.imgRxCompensated;
        elseif isfield(exampleEntry, "imgRx")
            img = exampleEntry.imgRx;
        elseif isfield(exampleEntry, "imgRxComm")
            img = exampleEntry.imgRxComm;
        else
            img = [];
        end
    otherwise
        if isfield(exampleEntry, "imgRxCompensated")
            img = exampleEntry.imgRxCompensated;
        elseif isfield(exampleEntry, "imgRx")
            img = exampleEntry.imgRx;
        elseif isfield(exampleEntry, "imgRxComm")
            img = exampleEntry.imgRxComm;
        else
            img = [];
        end
end
end

function txt = local_example_metric_line(variantKey, commMetrics, compMetrics, methodIdx, snrIdx, includeSsim)
if nargin < 6
    includeSsim = true;
end

switch lower(string(variantKey))
    case "communication"
        txt = local_metric_line( ...
            "Comm", ...
            commMetrics.mse(methodIdx, snrIdx), ...
            commMetrics.psnr(methodIdx, snrIdx), ...
            commMetrics.ssim(methodIdx, snrIdx), ...
            includeSsim);
    case "compensated"
        txt = local_metric_line( ...
            "Comp", ...
            compMetrics.mse(methodIdx, snrIdx), ...
            compMetrics.psnr(methodIdx, snrIdx), ...
            compMetrics.ssim(methodIdx, snrIdx), ...
            includeSsim);
    otherwise
        error("save_figures:InvalidExampleVariant", ...
            "Unsupported example variant: %s", char(string(variantKey)));
end
end

function titleLines = local_example_title_lines(nameLine, ebN0Val, metricLine)
titleLines = { ...
    char(string(nameLine)); ...
    sprintf("Eb/N0=%.1f dB", ebN0Val); ...
    char(string(metricLine))};
end

function [x, xlab] = local_get_warden_axis(w)
x = w.ebN0dB;
xlab = "E_b/N_0 at Bob (dB)";
if isfield(w, "wardenEbN0dB")
    x = w.wardenEbN0dB;
    ref = "warden";
    if isfield(w, "referenceLink")
        ref = lower(string(w.referenceLink));
    end
    switch ref
        case "bob"
            xlab = "E_b/N_0 at Bob (dB)";
        case "eve"
            xlab = "E_b/N_0 at Eve/Warden (dB)";
        otherwise
            xlab = "E_b/N_0 at Warden (dB)";
    end
elseif isfield(w, "eveEbN0dB")
    x = w.eveEbN0dB;
    xlab = "E_b/N_0 at Eve/Warden (dB)";
end
end

function layerName = local_get_primary_warden_layer(w)
layerName = "energyNp";
if isfield(w, "primaryLayer") && strlength(string(w.primaryLayer)) > 0
    layerName = string(w.primaryLayer);
end
end

function txt = local_metric_line(label, mseVal, psnrVal, ssimVal, includeSsim)
if nargin < 5
    includeSsim = true;
end
label = char(string(label));
if includeSsim
    txt = sprintf("%s: MSE=%.3g, PSNR=%.2fdB, SSIM=%.3f", label, mseVal, psnrVal, ssimVal);
else
    txt = sprintf("%s: MSE=%.3g, PSNR=%.2fdB", label, mseVal, psnrVal);
end
end
