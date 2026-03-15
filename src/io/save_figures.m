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
%             .example（按方法名的动态字段保存示例接收图）
%                 .<method>.EbN0dB - 示例图对应的Eb/N0（dB）
%                 .<method>.imgRxComm/.imgRxCompensated - 两种示例接收图像
%             .eve（可选，含 .example.<method>.EbN0dB/.headerOk/.imgRx）
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
exportgraphics(fig1, fullfile(outDir, "ber.png"));
close(fig1);

fig2 = local_create_line_figure("PSNR (Communication)");
ax2 = axes(fig2);
local_plot_series_matrix(ax2, EbN0dB, commMetrics.psnr, "linear");
local_apply_line_labels(ax2, "E_b/N_0 (dB)", "PSNR (dB, communication only)");
local_style_legend(ax2, methods, "southeast");
exportgraphics(fig2, fullfile(outDir, "psnr.png"));
exportgraphics(fig2, fullfile(outDir, "psnr_comm.png"));
close(fig2);

fig2m = local_create_line_figure("MSE (Communication)");
ax2m = axes(fig2m);
local_plot_series_matrix(ax2m, EbN0dB, commMetrics.mse, "logy");
local_apply_line_labels(ax2m, "E_b/N_0 (dB)", "MSE (communication only)");
local_style_legend(ax2m, methods, "northeast");
exportgraphics(fig2m, fullfile(outDir, "mse.png"));
exportgraphics(fig2m, fullfile(outDir, "mse_comm.png"));
close(fig2m);

if packetConcealActive
    fig2c = local_create_line_figure("PSNR (Compensated)");
    ax2c = axes(fig2c);
    local_plot_series_matrix(ax2c, EbN0dB, compMetrics.psnr, "linear");
    local_apply_line_labels(ax2c, "E_b/N_0 (dB)", "PSNR (dB, after concealment)");
    local_style_legend(ax2c, methods, "southeast");
    exportgraphics(fig2c, fullfile(outDir, "psnr_compensated.png"));
    close(fig2c);

    fig2cm = local_create_line_figure("MSE (Compensated)");
    ax2cm = axes(fig2cm);
    local_plot_series_matrix(ax2cm, EbN0dB, compMetrics.mse, "logy");
    local_apply_line_labels(ax2cm, "E_b/N_0 (dB)", "MSE (after concealment)");
    local_style_legend(ax2cm, methods, "northeast");
    exportgraphics(fig2cm, fullfile(outDir, "mse_compensated.png"));
    close(fig2cm);
end

if isfield(results, "kl")
    fig2k = local_create_line_figure("KL Divergence");
    ax2k = axes(fig2k);
    klValues = [results.kl.signalVsNoise(:).'; results.kl.symmetric(:).'];
    local_plot_series_matrix(ax2k, results.kl.ebN0dB, klValues, "linear");
    local_apply_line_labels(ax2k, "E_b/N_0 (dB)", "KL divergence");
    local_style_legend(ax2k, ["KL(P_{sig}||P_{noise})", "Symmetric KL"], "best");
    exportgraphics(fig2k, fullfile(outDir, "kl.png"));
    close(fig2k);
end


if isfield(results, "eve")
    [commMetricsEve, compMetricsEve] = local_get_image_metrics(results.eve);
    fig2b = local_create_line_figure("PSNR (Eve, Communication)");
    ax2b = axes(fig2b);
    local_plot_series_matrix(ax2b, results.eve.ebN0dB, commMetricsEve.psnr, "linear");
    local_apply_line_labels(ax2b, "E_b/N_0 at Eve (dB)", "PSNR (dB, communication only)");
    local_style_legend(ax2b, methods, "southeast");
    exportgraphics(fig2b, fullfile(outDir, "psnr_eve.png"));
    exportgraphics(fig2b, fullfile(outDir, "psnr_eve_comm.png"));
    close(fig2b);

    if isfield(commMetricsEve, "mse")
        fig2bm = local_create_line_figure("MSE (Eve, Communication)");
        ax2bm = axes(fig2bm);
        local_plot_series_matrix(ax2bm, results.eve.ebN0dB, commMetricsEve.mse, "logy");
        local_apply_line_labels(ax2bm, "E_b/N_0 at Eve (dB)", "MSE (communication only)");
        local_style_legend(ax2bm, methods, "northeast");
        exportgraphics(fig2bm, fullfile(outDir, "mse_eve.png"));
        exportgraphics(fig2bm, fullfile(outDir, "mse_eve_comm.png"));
        close(fig2bm);
    end

    if packetConcealActive
        fig2bc = local_create_line_figure("PSNR (Eve, Compensated)");
        ax2bc = axes(fig2bc);
        local_plot_series_matrix(ax2bc, results.eve.ebN0dB, compMetricsEve.psnr, "linear");
        local_apply_line_labels(ax2bc, "E_b/N_0 at Eve (dB)", "PSNR (dB, after concealment)");
        local_style_legend(ax2bc, methods, "southeast");
        exportgraphics(fig2bc, fullfile(outDir, "psnr_eve_compensated.png"));
        close(fig2bc);

        fig2bcm = local_create_line_figure("MSE (Eve, Compensated)");
        ax2bcm = axes(fig2bcm);
        local_plot_series_matrix(ax2bcm, results.eve.ebN0dB, compMetricsEve.mse, "logy");
        local_apply_line_labels(ax2bcm, "E_b/N_0 at Eve (dB)", "MSE (after concealment)");
        local_style_legend(ax2bcm, methods, "northeast");
        exportgraphics(fig2bcm, fullfile(outDir, "mse_eve_compensated.png"));
        close(fig2bcm);
    end

    fig1b = local_create_line_figure("BER (Eve)");
    ax1b = axes(fig1b);
    local_plot_series_matrix(ax1b, results.eve.ebN0dB, results.eve.ber, "logy");
    local_apply_line_labels(ax1b, "E_b/N_0 at Eve (dB)", "BER (payload)");
    local_format_ber_axis(ax1b, results.eve.ebN0dB, results.eve.ber);
    local_style_legend(ax1b, methods, "southwest");
    exportgraphics(fig1b, fullfile(outDir, "ber_eve.png"));
    close(fig1b);
end

fig3 = local_create_line_figure("Spectrum");
ax3 = axes(fig3);
local_plot_series_matrix(ax3, results.spectrum.freqHz(:).'/1e3, 10*log10(results.spectrum.psd(:)).', "linear", false, false);
local_apply_line_labels(ax3, ...
    "Frequency (kHz)", ...
    "PSD (dB/Hz)", ...
    sprintf("99%% OBW=%.1f Hz,  \\eta=%.3f b/s/Hz", results.spectrum.bw99Hz, results.spectrum.etaBpsHz));
exportgraphics(fig3, fullfile(outDir, "psd.png"));
close(fig3);

% ========== 分开保存每种方法的结果图片 ==========
% 创建images子目录
imagesDir = fullfile(outDir, "images");
if ~exist(imagesDir, 'dir')
    mkdir(imagesDir);
end

% 1. 保存原始发送图像
figTx = figure("Name", "TX Image", "Visible", "off");
imshow(imgTx);
title("TX (原图)", "FontSize", 14);
exportgraphics(figTx, fullfile(imagesDir, "00_tx_original.png"), 'Resolution', 200);
close(figTx);

exampleVariants = local_example_variants(packetConcealActive);

% 2. 为每种方法分别保存通信前/补偿后接收图像
for k = 1:numel(methods)
    if isfield(results.example, methods(k))
        exampleEntry = results.example.(methods(k));
        [exampleIdx, ebN0Mid] = local_get_example_index(exampleEntry, results.ebN0dB);

        for iv = 1:numel(exampleVariants)
            variant = exampleVariants(iv);
            imgVariant = local_get_example_image_variant(exampleEntry, variant.key);
            if isempty(imgVariant)
                continue;
            end

            figRx = figure("Name", sprintf("RX (%s) - %s", variant.shortLabel, methods(k)), "Visible", "off");
            imshow(imgVariant);
            title( ...
                local_example_title_lines( ...
                    sprintf("RX (%s) - %s", variant.shortLabel, methods(k)), ...
                    ebN0Mid, ...
                    local_example_metric_line(variant.key, commMetrics, compMetrics, k, exampleIdx, true)), ...
                "FontSize", 12);

            filename = sprintf("%02d_rx_%s_%s.png", k, variant.fileTag, lower(strrep(methods(k), " ", "_")));
            exportgraphics(figRx, fullfile(imagesDir, filename), 'Resolution', 200);
            close(figRx);
        end
    end
end

% 3. 保存TX与各方法RX的对比图（每种方法一张，补偿前后分栏）
for k = 1:numel(methods)
    if isfield(results.example, methods(k))
        figCmp = figure("Name", sprintf("Compare - %s", methods(k)), "Visible", "off");
        exampleEntry = results.example.(methods(k));
        [exampleIdx, ebN0Sel] = local_get_example_index(exampleEntry, results.ebN0dB);
        nTiles = 1 + numel(exampleVariants);
        figCmp.Position = [100 100 380*nTiles 420];

        tiledlayout(1, nTiles, 'TileSpacing', 'compact', 'Padding', 'compact');

        nexttile;
        imshow(imgTx);
        title("TX (原图)", "FontSize", 12);

        for iv = 1:numel(exampleVariants)
            variant = exampleVariants(iv);
            nexttile;
            imgVariant = local_get_example_image_variant(exampleEntry, variant.key);
            if isempty(imgVariant)
                text(0.1, 0.5, "No example", "Units", "normalized");
                axis off;
                title(sprintf("RX (%s) - %s", variant.shortLabel, methods(k)), "FontSize", 12);
            else
                imshow(imgVariant);
                title( ...
                    local_example_title_lines( ...
                        sprintf("RX (%s) - %s", variant.shortLabel, methods(k)), ...
                        ebN0Sel, ...
                        local_example_metric_line(variant.key, commMetrics, compMetrics, k, exampleIdx, true)), ...
                    "FontSize", 12);
            end
        end

        filename = sprintf("compare_%02d_%s.png", k, lower(strrep(methods(k), " ", "_")));
        exportgraphics(figCmp, fullfile(imagesDir, filename), 'Resolution', 200);
        close(figCmp);
    end
end

% 4. 保存所有方法的汇总对比图（通信前/补偿后分别导出）
nMethods = numel(methods);
nTotal = nMethods + 1;  % +1 for TX image
for iv = 1:numel(exampleVariants)
    variant = exampleVariants(iv);
    fig4 = figure("Name", sprintf("Images - %s", variant.shortLabel), "Visible", "off");
    nCols = ceil(nTotal / 2);
    nRows = 2;
    if nTotal <= 4
        nRows = 1;
        nCols = nTotal;
    end
    fig4.Position = [100 100 300*nCols 300*nRows];
    tiledlayout(nRows, nCols, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile;
    imshow(imgTx);
    title("TX");
    for k = 1:numel(methods)
        nexttile;
        if isfield(results.example, methods(k))
            imgVariant = local_get_example_image_variant(results.example.(methods(k)), variant.key);
            if ~isempty(imgVariant)
                imshow(imgVariant);
            else
                text(0.1, 0.5, "No example", "Units", "normalized");
                axis off;
            end
            title(sprintf("RX (%s) - %s", variant.shortLabel, methods(k)));
        else
            text(0.1, 0.5, "No example", "Units", "normalized");
            axis off;
            title(sprintf("RX (%s) - %s", variant.shortLabel, methods(k)));
        end
    end
    exportgraphics(fig4, fullfile(outDir, sprintf("images_%s.png", variant.summaryTag)), 'Resolution', 150);
    if variant.key == "communication"
        exportgraphics(fig4, fullfile(outDir, "images.png"), 'Resolution', 150);
    end
    close(fig4);
end


if isfield(results, "eve") && isfield(results.eve, "example")
    % 创建eve子目录
    eveDir = fullfile(outDir, "images_eve");
    if ~exist(eveDir, 'dir')
        mkdir(eveDir);
    end
    
    % 为每种方法单独保存Bob vs Eve对比图
    for k = 1:numel(methods)
        if isfield(results.example, methods(k)) && isfield(results.eve.example, methods(k))
            [exampleIdx, ebN0Bob] = local_get_example_index(results.example.(methods(k)), results.ebN0dB);
            [~, ebN0Eve] = local_get_example_index(results.eve.example.(methods(k)), results.eve.ebN0dB);

            figEve = figure("Name", sprintf("Bob vs Eve - %s", methods(k)), "Visible", "off");
            nTiles = 1 + 2 * numel(exampleVariants);
            figEve.Position = [100 100 330*nTiles 420];
            tiledlayout(1, nTiles, 'TileSpacing', 'compact', 'Padding', 'compact');

            nexttile;
            imshow(imgTx);
            title("TX (原图)", "FontSize", 12);

            for iv = 1:numel(exampleVariants)
                variant = exampleVariants(iv);
                nexttile;
                imgBobVariant = local_get_example_image_variant(results.example.(methods(k)), variant.key);
                if isempty(imgBobVariant)
                    text(0.1, 0.5, "No example", "Units", "normalized");
                    axis off;
                    title(sprintf("Bob (%s) - %s", variant.shortLabel, methods(k)), "FontSize", 12);
                else
                    imshow(imgBobVariant);
                    title( ...
                        local_example_title_lines( ...
                            sprintf("Bob (%s) - %s", variant.shortLabel, methods(k)), ...
                            ebN0Bob, ...
                            local_example_metric_line(variant.key, commMetrics, compMetrics, k, exampleIdx, false)), ...
                        "FontSize", 12);
                end
            end

            hdrTxt = "";
            if isfield(results.eve.example.(methods(k)), "headerOk")
                if results.eve.example.(methods(k)).headerOk
                    hdrTxt = " (hdr ok)";
                else
                    hdrTxt = " (hdr fail)";
                end
            end

            for iv = 1:numel(exampleVariants)
                variant = exampleVariants(iv);
                nexttile;
                imgEveVariant = local_get_example_image_variant(results.eve.example.(methods(k)), variant.key);
                if isempty(imgEveVariant)
                    text(0.1, 0.5, "No example", "Units", "normalized");
                    axis off;
                    title(sprintf("Eve (%s) - %s%s", variant.shortLabel, methods(k), hdrTxt), "FontSize", 12);
                else
                    imshow(imgEveVariant);
                    title( ...
                        local_example_title_lines( ...
                            sprintf("Eve (%s) - %s%s", variant.shortLabel, methods(k), hdrTxt), ...
                            ebN0Eve, ...
                            local_example_metric_line(variant.key, commMetricsEve, compMetricsEve, k, exampleIdx, false)), ...
                        "FontSize", 12);
                end
            end

            filename = sprintf("bob_vs_eve_%02d_%s.png", k, lower(strrep(methods(k), " ", "_")));
            exportgraphics(figEve, fullfile(eveDir, filename), 'Resolution', 200);
            close(figEve);
        end
    end
    
    % 保存汇总对比图（通信前/补偿后分别导出）
    for iv = 1:numel(exampleVariants)
        variant = exampleVariants(iv);
        fig5 = figure("Name", sprintf("Intercept - %s", variant.shortLabel), "Visible", "off");
        nCols = numel(methods) + 1;
        fig5.Position = [100 100 200*nCols 400];
        tiledlayout(2, nCols, 'TileSpacing', 'compact', 'Padding', 'compact');

        nexttile;
        imshow(imgTx);
        title("TX");
        for k = 1:numel(methods)
            nexttile;
            if isfield(results.example, methods(k))
                imgVariant = local_get_example_image_variant(results.example.(methods(k)), variant.key);
                if ~isempty(imgVariant)
                    imshow(imgVariant);
                else
                    text(0.1, 0.5, "No example", "Units", "normalized");
                    axis off;
                end
                title(sprintf("Bob (%s) - %s", variant.shortLabel, methods(k)));
            else
                text(0.1, 0.5, "No example", "Units", "normalized");
                axis off;
                title(sprintf("Bob (%s) - %s", variant.shortLabel, methods(k)));
            end
        end

        nexttile;
        if isfield(results.eve.example, methods(1)) && isfield(results.eve.example.(methods(1)), "EbN0dB")
            txt = {'Eve (intercept)', sprintf("Eb/N0=%.1f dB", results.eve.example.(methods(1)).EbN0dB)};
        else
            txt = {'Eve (intercept)'};
        end
        text(0.05, 0.5, txt, "Units", "normalized", "Interpreter", "none");
        axis off;
        title("Eve");

        for k = 1:numel(methods)
            nexttile;
            if isfield(results.eve.example, methods(k))
                imgVariant = local_get_example_image_variant(results.eve.example.(methods(k)), variant.key);
                if ~isempty(imgVariant)
                    imshow(imgVariant);
                else
                    text(0.1, 0.5, "No example", "Units", "normalized");
                    axis off;
                end
                hdrTxt = "";
                if isfield(results.eve.example.(methods(k)), "headerOk")
                    if results.eve.example.(methods(k)).headerOk
                        hdrTxt = "hdr ok";
                    else
                        hdrTxt = "hdr fail";
                    end
                end
                if strlength(hdrTxt) > 0
                    title(sprintf("Eve (%s) - %s (%s)", variant.shortLabel, methods(k), hdrTxt));
                else
                    title(sprintf("Eve (%s) - %s", variant.shortLabel, methods(k)));
                end
            else
                text(0.1, 0.5, "No example", "Units", "normalized");
                axis off;
                title(sprintf("Eve (%s) - %s", variant.shortLabel, methods(k)));
            end
        end
        exportgraphics(fig5, fullfile(outDir, sprintf("intercept_%s.png", variant.summaryTag)), 'Resolution', 150);
        if variant.key == "communication"
            exportgraphics(fig5, fullfile(outDir, "intercept.png"), 'Resolution', 150);
        end
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
    exportgraphics(fig6, fullfile(outDir, "warden.png"));
    close(fig6);
end
end

function fig = local_create_line_figure(name)
fig = figure("Name", name, "Color", "w");
fig.Position = [100 100 1000 632];
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
style = styles(mod(index - 1, numel(styles)) + 1);
end

function styles = local_series_styles()
styles = struct( ...
    "Color", {[213 94 0] / 255, [153 153 153] / 255, [230 159 0] / 255, ...
              [0 158 115] / 255, [204 121 167] / 255, [0 114 178] / 255, ...
              [86 180 233] / 255}, ...
    "LineStyle", {"-", ":", "-.", "--", ":", "--", "-."}, ...
    "Marker", {"s", "o", "v", "^", "d", "p", "x"});
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
    "shortLabel", "Comm", ...
    "fileTag", "comm", ...
    "summaryTag", "comm");
if packetConcealActive
    variants(2) = struct( ...
        "key", "compensated", ...
        "shortLabel", "Comp", ...
        "fileTag", "comp", ...
        "summaryTag", "compensated");
end
end

function [exampleIdx, ebN0Sel] = local_get_example_index(exampleEntry, ebN0List)
if isfield(exampleEntry, "EbN0dB")
    ebN0Sel = double(exampleEntry.EbN0dB);
    [~, exampleIdx] = min(abs(ebN0List - ebN0Sel));
else
    exampleIdx = numel(ebN0List);
    ebN0Sel = ebN0List(exampleIdx);
end
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

function txt = local_example_metric_line(variantKey, commMetrics, compMetrics, methodIdx, exampleIdx, includeSsim)
if nargin < 6
    includeSsim = true;
end

switch lower(string(variantKey))
    case "communication"
        txt = local_metric_line( ...
            "Comm", ...
            commMetrics.mse(methodIdx, exampleIdx), ...
            commMetrics.psnr(methodIdx, exampleIdx), ...
            commMetrics.ssim(methodIdx, exampleIdx), ...
            includeSsim);
    case "compensated"
        txt = local_metric_line( ...
            "Comp", ...
            compMetrics.mse(methodIdx, exampleIdx), ...
            compMetrics.psnr(methodIdx, exampleIdx), ...
            compMetrics.ssim(methodIdx, exampleIdx), ...
            includeSsim);
    otherwise
        error("save_figures:InvalidExampleVariant", ...
            "Unsupported example variant: %s", char(string(variantKey)));
end
end

function titleLines = local_example_title_lines(nameLine, ebN0Val, metricLine)
titleLines = { ...
    char(string(nameLine)); ...
    sprintf("Eb/N0=%.0fdB", ebN0Val); ...
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
