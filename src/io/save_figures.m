function save_figures(outDir, results)
%SAVE_FIGURES  将标准图形（BER/MSE/PSNR/KL/PSD/图像）保存到磁盘。
%
% 输入:
%   outDir  - 输出目录
%   results - 仿真结果结构体
%             .methods, .ebN0dB, .ber
%             .sourceImages.resized/.original
%             .imageMetrics.resized/original.communication/.compensated
%             .kl（含signalVsNoise/noiseVsSignal/symmetric）
%             .spectrum（freqHz, psd, bw99Hz, etaBpsHz）
%             .example（按Eb/N0点保存示例接收图）
%                 .example(i).EbN0dB - 第i个Eb/N0点
%                 .example(i).methods.<method>.imgRxComm/.imgRxCompensated - 恢复为原尺寸后的示例图
%             .eve（可选，含 .example(i).methods.<method>.headerOk/.imgRx）
%             .covert.warden（可选）
%
% 输出:
%   无（直接写图到磁盘）

methods = results.methods;
EbN0dB = results.ebN0dB;
scan = local_get_scan_descriptor(results);
sourceImages = local_get_source_images(results);
imageMetrics = local_get_image_metrics(results);
resizedMetrics = imageMetrics.resized;
originalMetrics = imageMetrics.original;
packetConcealActive = local_packet_conceal_active(results);

fig1 = local_create_point_metric_figure( ...
    "BER", methods, results.ber, scan, "logy", ...
    "BER (payload)", "BER", "southwest", ...
    "xLabelSingle", "E_b/N_0 (dB)", ...
    "xLabelGrid", "J/S (dB)", ...
    "subplotTitlePrefix", "E_b/N_0", ...
    "subplotTitleValues", scan.ebN0dBPoint, ...
    "applyBerFormatting", true);
local_export_figure(fig1, fullfile(outDir, "ber.png"), "");
close(fig1);

if logical(scan.isGrid)
    fig1e = local_create_fixed_jsr_metric_figure( ...
        "BER vs EbN0 (Fixed JSR)", methods, results.ber, scan, "logy", ...
        "BER (payload)", "BER vs E_b/N_0 @ Fixed J/S", "southwest", ...
        "xLabel", "E_b/N_0 (dB)", ...
        "subplotTitlePrefix", "J/S", ...
        "subplotTitleValues", scan.jsrDbList, ...
        "applyBerFormatting", true);
    local_export_figure(fig1e, fullfile(outDir, "ber_vs_ebn0_fixed_jsr.png"), "");
    close(fig1e);
end

fig1p = local_create_point_metric_figure( ...
    "PER", methods, results.per, scan, "logy", ...
    "PER (packet)", "PER", "southwest", ...
    "xLabelSingle", "E_b/N_0 (dB)", ...
    "xLabelGrid", "J/S (dB)", ...
    "subplotTitlePrefix", "E_b/N_0", ...
    "subplotTitleValues", scan.ebN0dBPoint, ...
    "applyBerFormatting", true);
local_export_figure(fig1p, fullfile(outDir, "per.png"), "");
close(fig1p);

fig1pr = local_create_point_metric_figure( ...
    "Raw PER", methods, results.rawPer, scan, "logy", ...
    "Raw PER (pre-outer-RS packet)", "Raw PER", "southwest", ...
    "xLabelSingle", "E_b/N_0 (dB)", ...
    "xLabelGrid", "J/S (dB)", ...
    "subplotTitlePrefix", "E_b/N_0", ...
    "subplotTitleValues", scan.ebN0dBPoint, ...
    "applyBerFormatting", true);
local_export_figure(fig1pr, fullfile(outDir, "raw_per.png"), "");
close(fig1pr);

if logical(scan.isGrid)
    fig1pe = local_create_fixed_jsr_metric_figure( ...
        "PER vs EbN0 (Fixed JSR)", methods, results.per, scan, "logy", ...
        "PER (packet)", "PER vs E_b/N_0 @ Fixed J/S", "southwest", ...
        "xLabel", "E_b/N_0 (dB)", ...
        "subplotTitlePrefix", "J/S", ...
        "subplotTitleValues", scan.jsrDbList, ...
        "applyBerFormatting", true);
    local_export_figure(fig1pe, fullfile(outDir, "per_vs_ebn0_fixed_jsr.png"), "");
    close(fig1pe);

    fig1pre = local_create_fixed_jsr_metric_figure( ...
        "Raw PER vs EbN0 (Fixed JSR)", methods, results.rawPer, scan, "logy", ...
        "Raw PER (pre-outer-RS packet)", "Raw PER vs E_b/N_0 @ Fixed J/S", "southwest", ...
        "xLabel", "E_b/N_0 (dB)", ...
        "subplotTitlePrefix", "J/S", ...
        "subplotTitleValues", scan.jsrDbList, ...
        "applyBerFormatting", true);
    local_export_figure(fig1pre, fullfile(outDir, "raw_per_vs_ebn0_fixed_jsr.png"), "");
    close(fig1pre);
end

local_export_image_metric_bundle_local(outDir, methods, scan, ...
    originalMetrics.communication, originalMetrics.compensated, packetConcealActive, struct( ...
    "figureLabel", "Bob, Original Reference", ...
    "fileTag", "original", ...
    "xLabelSingle", "E_b/N_0 (dB)", ...
    "subplotTitlePrefix", "E_b/N_0", ...
    "subplotTitleValues", scan.ebN0dBPoint, ...
    "psnrAlias", fullfile(outDir, "psnr.png"), ...
    "mseAlias", fullfile(outDir, "mse.png")));
local_copy_export_alias(fullfile(outDir, "psnr_original.png"), fullfile(outDir, "psnr_comm.png"));
local_copy_export_alias(fullfile(outDir, "mse_original.png"), fullfile(outDir, "mse_comm.png"));

local_export_image_metric_bundle_local(outDir, methods, scan, ...
    resizedMetrics.communication, resizedMetrics.compensated, packetConcealActive, struct( ...
    "figureLabel", "Bob, Resized Reference", ...
    "fileTag", "resized", ...
    "xLabelSingle", "E_b/N_0 (dB)", ...
    "subplotTitlePrefix", "E_b/N_0", ...
    "subplotTitleValues", scan.ebN0dBPoint, ...
    "psnrAlias", "", ...
    "mseAlias", ""));

if isfield(results, "kl")
    klValues = [results.kl.signalVsNoise(:).'; results.kl.symmetric(:).'];
    fig2k = local_create_point_metric_figure( ...
        "KL Divergence", ["KL(P_{sig}||P_{noise})", "Symmetric KL"], klValues, scan, "linear", ...
        "KL divergence", "KL Divergence", "best", ...
        "xLabelSingle", "E_b/N_0 (dB)", ...
        "xLabelGrid", "J/S (dB)", ...
        "subplotTitlePrefix", "E_b/N_0", ...
        "subplotTitleValues", scan.ebN0dBPoint);
    local_export_figure(fig2k, fullfile(outDir, "kl.png"), "");
    close(fig2k);
end


if isfield(results, "eve")
    eveImageMetrics = local_get_image_metrics(results.eve);
    local_export_image_metric_bundle_local(outDir, methods, scan, ...
        eveImageMetrics.original.communication, eveImageMetrics.original.compensated, packetConcealActive, struct( ...
        "figureLabel", "Eve, Original Reference", ...
        "fileTag", "eve_original", ...
        "xLabelSingle", "E_b/N_0 at Eve (dB)", ...
        "subplotTitlePrefix", "E_b/N_0 at Eve", ...
        "subplotTitleValues", results.eve.ebN0dB(:), ...
        "psnrAlias", fullfile(outDir, "psnr_eve.png"), ...
        "mseAlias", fullfile(outDir, "mse_eve.png")));
    local_copy_export_alias(fullfile(outDir, "psnr_eve_original.png"), fullfile(outDir, "psnr_eve_comm.png"));
    local_copy_export_alias(fullfile(outDir, "mse_eve_original.png"), fullfile(outDir, "mse_eve_comm.png"));

    local_export_image_metric_bundle_local(outDir, methods, scan, ...
        eveImageMetrics.resized.communication, eveImageMetrics.resized.compensated, packetConcealActive, struct( ...
        "figureLabel", "Eve, Resized Reference", ...
        "fileTag", "eve_resized", ...
        "xLabelSingle", "E_b/N_0 at Eve (dB)", ...
        "subplotTitlePrefix", "E_b/N_0 at Eve", ...
        "subplotTitleValues", results.eve.ebN0dB(:), ...
        "psnrAlias", "", ...
        "mseAlias", ""));

    fig1b = local_create_point_metric_figure( ...
        "BER (Eve)", methods, results.eve.ber, scan, "logy", ...
        "BER (payload)", "BER (Eve)", "southwest", ...
        "xLabelSingle", "E_b/N_0 at Eve (dB)", ...
        "xLabelGrid", "J/S (dB)", ...
        "subplotTitlePrefix", "E_b/N_0 at Eve", ...
        "subplotTitleValues", results.eve.ebN0dB(:), ...
        "applyBerFormatting", true);
    local_export_figure(fig1b, fullfile(outDir, "ber_eve.png"), "");
    close(fig1b);

    if logical(scan.isGrid)
        fig1be = local_create_fixed_jsr_metric_figure( ...
            "BER (Eve) vs EbN0 (Fixed JSR)", methods, results.eve.ber, scan, "logy", ...
            "BER (payload)", "BER (Eve) vs E_b/N_0 @ Fixed J/S", "southwest", ...
            "xLabel", "E_b/N_0 at Eve (dB)", ...
            "subplotTitlePrefix", "J/S", ...
            "subplotTitleValues", scan.jsrDbList, ...
            "applyBerFormatting", true);
        local_export_figure(fig1be, fullfile(outDir, "ber_eve_vs_ebn0_fixed_jsr.png"), "");
        close(fig1be);
    end

    fig1bp = local_create_point_metric_figure( ...
        "PER (Eve)", methods, results.eve.per, scan, "logy", ...
        "PER (packet)", "PER (Eve)", "southwest", ...
        "xLabelSingle", "E_b/N_0 at Eve (dB)", ...
        "xLabelGrid", "J/S (dB)", ...
        "subplotTitlePrefix", "E_b/N_0 at Eve", ...
        "subplotTitleValues", results.eve.ebN0dB(:), ...
        "applyBerFormatting", true);
    local_export_figure(fig1bp, fullfile(outDir, "per_eve.png"), "");
    close(fig1bp);

    fig1bpr = local_create_point_metric_figure( ...
        "Raw PER (Eve)", methods, results.eve.rawPer, scan, "logy", ...
        "Raw PER (pre-outer-RS packet)", "Raw PER (Eve)", "southwest", ...
        "xLabelSingle", "E_b/N_0 at Eve (dB)", ...
        "xLabelGrid", "J/S (dB)", ...
        "subplotTitlePrefix", "E_b/N_0 at Eve", ...
        "subplotTitleValues", results.eve.ebN0dB(:), ...
        "applyBerFormatting", true);
    local_export_figure(fig1bpr, fullfile(outDir, "raw_per_eve.png"), "");
    close(fig1bpr);

    if logical(scan.isGrid)
        fig1bpe = local_create_fixed_jsr_metric_figure( ...
            "PER (Eve) vs EbN0 (Fixed JSR)", methods, results.eve.per, scan, "logy", ...
            "PER (packet)", "PER (Eve) vs E_b/N_0 @ Fixed J/S", "southwest", ...
            "xLabel", "E_b/N_0 at Eve (dB)", ...
            "subplotTitlePrefix", "J/S", ...
            "subplotTitleValues", scan.jsrDbList, ...
            "applyBerFormatting", true);
        local_export_figure(fig1bpe, fullfile(outDir, "per_eve_vs_ebn0_fixed_jsr.png"), "");
        close(fig1bpe);

        fig1bpre = local_create_fixed_jsr_metric_figure( ...
            "Raw PER (Eve) vs EbN0 (Fixed JSR)", methods, results.eve.rawPer, scan, "logy", ...
            "Raw PER (pre-outer-RS packet)", "Raw PER (Eve) vs E_b/N_0 @ Fixed J/S", "southwest", ...
            "xLabel", "E_b/N_0 at Eve (dB)", ...
            "subplotTitlePrefix", "J/S", ...
            "subplotTitleValues", scan.jsrDbList, ...
            "applyBerFormatting", true);
        local_export_figure(fig1bpre, fullfile(outDir, "raw_per_eve_vs_ebn0_fixed_jsr.png"), "");
        close(fig1bpre);
    end
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
imshow(sourceImages.original);
title("TX (原尺寸)", "FontSize", 14);
local_export_figure(figTx, fullfile(imagesDir, "00_tx_original.png"), "", 'Resolution', 200);
close(figTx);

figTxResized = figure("Name", "TX Image Resized", "Visible", "off");
imshow(sourceImages.resized);
title("TX (缩小尺寸)", "FontSize", 14);
local_export_figure(figTxResized, fullfile(imagesDir, "01_tx_resized.png"), "", 'Resolution', 200);
close(figTxResized);

exampleVariants = local_example_variants(packetConcealActive);
nMethods = numel(methods);

for ie = 1:numel(EbN0dB)
    examplePoint = local_get_example_point(results.example, ie, EbN0dB(ie));
    pointTitle = local_point_title_suffix(scan, ie);
    exampleJsrVal = local_example_jsr_value(scan, ie);
    fig4 = figure("Name", sprintf("Images @ %s", pointTitle), "Visible", "off");
    fig4.Position = [100 100 320 * (nMethods + 1) 300 * numel(exampleVariants)];
    tl4 = tiledlayout(fig4, numel(exampleVariants), nMethods + 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl4, sprintf("Bob Integrated Images @ %s", pointTitle));

    for iv = 1:numel(exampleVariants)
        variant = exampleVariants(iv);

        nexttile(tl4);
        imshow(sourceImages.original);
        title(local_example_title_lines( ...
            sprintf("TX (%s)", variant.shortLabel), ...
            EbN0dB(ie), ...
            "Reference image", ...
            exampleJsrVal), "FontSize", 11);

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
                    local_example_metric_lines(variant.key, originalMetrics, resizedMetrics, k, ie, true), ...
                    exampleJsrVal), ...
                "FontSize", 10);
        end
    end

    fileTag = local_point_file_tag(scan, ie);
    local_export_figure(fig4, fullfile(imagesDir, sprintf("point_%02d_%s.png", ie, fileTag)), "", 'Resolution', 170);
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

        pointTitle = local_point_title_suffix(scan, ie);
        exampleJsrVal = local_example_jsr_value(scan, ie);
        fig5 = figure("Name", sprintf("Intercept @ %s", pointTitle), "Visible", "off");
        nRows = 2 * numel(exampleVariants);
        fig5.Position = [100 100 320 * (nMethods + 1) 270 * nRows];
        tl5 = tiledlayout(fig5, nRows, nMethods + 1, 'TileSpacing', 'compact', 'Padding', 'compact');
        title(tl5, sprintf("Bob vs Eve @ Bob %s, Eve Eb/N0=%.1f dB", ...
            pointTitle, results.eve.ebN0dB(ie)));

        for iv = 1:numel(exampleVariants)
            variant = exampleVariants(iv);

            nexttile(tl5);
            imshow(sourceImages.original);
            title(local_example_title_lines( ...
                sprintf("TX / Bob (%s)", variant.shortLabel), ...
                EbN0dB(ie), ...
                "Reference image", ...
                exampleJsrVal), "FontSize", 11);

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
                    local_example_metric_lines(variant.key, originalMetrics, resizedMetrics, k, ie, false), ...
                    exampleJsrVal), ...
                    "FontSize", 10);
            end

            nexttile(tl5);
            eveInfoLines = local_build_eve_info_lines(variant.shortLabel, results.eve.ebN0dB(ie), exampleJsrVal);
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
                    local_example_metric_lines(variant.key, eveImageMetrics.original, eveImageMetrics.resized, k, ie, false), ...
                    exampleJsrVal), ...
                    "FontSize", 10);
            end
        end

        fileTag = local_point_file_tag(scan, ie);
        local_export_figure(fig5, fullfile(eveDir, sprintf("point_%02d_%s.png", ie, fileTag)), "", 'Resolution', 170);
        close(fig5);
    end
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    w = results.covert.warden;
    if isfield(w, "layers") && isfield(w.layers, "energyNp")
        np = w.layers.energyNp;
        wardenValues = [np.pd(:).'; np.pfa(:).'; np.pe(:).'; np.xi(:).'];
        wardenStyles = [ ...
            local_get_warden_series_style("pd"), ...
            local_get_warden_series_style("pfa"), ...
            local_get_warden_series_style("pe"), ...
            local_get_warden_series_style("xi")];
    else
        wardenValues = [w.pdEst(:).'; w.pfaEst(:).'; w.peEst(:).'];
        wardenStyles = [ ...
            local_get_warden_series_style("pd"), ...
            local_get_warden_series_style("pfa"), ...
            local_get_warden_series_style("pe")];
    end

    covertValues = [];
    covertLabels = strings(1, 0);
    covertStyles = struct("Color", {}, "LineStyle", {}, "Marker", {});
    if isfield(w, "layers") && isfield(w.layers, "energyOpt")
        covertValues = [covertValues; w.layers.energyOpt.xi(:).'; w.layers.energyOpt.pe(:).'];
        covertLabels = [covertLabels, "\xi^* (opt)", "P_e^* (opt)"];
        covertStyles(end + 1) = local_get_warden_series_style("xiIdeal");
        covertStyles(end + 1) = local_get_warden_series_style("peIdeal");
    end
    if isfield(w, "layers") && isfield(w.layers, "energyOptUncertain")
        covertValues = [covertValues; ...
            w.layers.energyOptUncertain.xi(:).'; ...
            w.layers.energyOptUncertain.pe(:).'];
        covertLabels = [covertLabels, "\xi^* (opt+uncert.)", "P_e^* (opt+uncert.)"];
        covertStyles(end + 1) = local_get_warden_series_style("xi");
        covertStyles(end + 1) = local_get_warden_series_style("pe");
    end
    if isempty(covertValues)
        covertValues = [w.xiEst(:).'; w.peEst(:).'];
        covertLabels = ["\xi", "P_e"];
        covertStyles = [ ...
            local_get_warden_series_style("xi"), ...
            local_get_warden_series_style("pe")];
    end
    fig6 = local_create_warden_figure(scan, w, wardenValues, wardenStyles, covertValues, covertLabels, covertStyles);
    local_export_figure(fig6, fullfile(outDir, "warden.png"), "");
    close(fig6);
end
end

function local_export_image_metric_bundle_local(outDir, methods, scan, commMetrics, compMetrics, packetConcealActive, desc)
arguments
    outDir
    methods
    scan (1,1) struct
    commMetrics (1,1) struct
    compMetrics (1,1) struct
    packetConcealActive (1,1) logical
    desc (1,1) struct
end

requiredFields = ["figureLabel" "fileTag" "xLabelSingle" "subplotTitlePrefix" "subplotTitleValues" "psnrAlias" "mseAlias"];
for idx = 1:numel(requiredFields)
    if ~isfield(desc, requiredFields(idx))
        error("save_figures:MissingMetricBundleField", ...
            "Metric bundle descriptor is missing field %s.", requiredFields(idx));
    end
end

figPsnr = local_create_point_metric_figure( ...
    "PSNR (" + string(desc.figureLabel) + ", Communication)", methods, commMetrics.psnr, scan, "linear", ...
    "PSNR (dB, communication only)", "PSNR (" + string(desc.figureLabel) + ", Communication)", "southeast", ...
    "xLabelSingle", string(desc.xLabelSingle), ...
    "xLabelGrid", "J/S (dB)", ...
    "subplotTitlePrefix", string(desc.subplotTitlePrefix), ...
    "subplotTitleValues", double(desc.subplotTitleValues(:)));
local_export_figure(figPsnr, fullfile(outDir, "psnr_" + string(desc.fileTag) + ".png"), string(desc.psnrAlias));
close(figPsnr);

figMse = local_create_point_metric_figure( ...
    "MSE (" + string(desc.figureLabel) + ", Communication)", methods, commMetrics.mse, scan, "logy", ...
    "MSE (communication only)", "MSE (" + string(desc.figureLabel) + ", Communication)", "northeast", ...
    "xLabelSingle", string(desc.xLabelSingle), ...
    "xLabelGrid", "J/S (dB)", ...
    "subplotTitlePrefix", string(desc.subplotTitlePrefix), ...
    "subplotTitleValues", double(desc.subplotTitleValues(:)));
local_export_figure(figMse, fullfile(outDir, "mse_" + string(desc.fileTag) + ".png"), string(desc.mseAlias));
close(figMse);

if ~packetConcealActive
    return;
end

figPsnrComp = local_create_point_metric_figure( ...
    "PSNR (" + string(desc.figureLabel) + ", Compensated)", methods, compMetrics.psnr, scan, "linear", ...
    "PSNR (dB, after concealment)", "PSNR (" + string(desc.figureLabel) + ", Compensated)", "southeast", ...
    "xLabelSingle", string(desc.xLabelSingle), ...
    "xLabelGrid", "J/S (dB)", ...
    "subplotTitlePrefix", string(desc.subplotTitlePrefix), ...
    "subplotTitleValues", double(desc.subplotTitleValues(:)));
local_export_figure(figPsnrComp, fullfile(outDir, "psnr_" + string(desc.fileTag) + "_compensated.png"), "");
close(figPsnrComp);

figMseComp = local_create_point_metric_figure( ...
    "MSE (" + string(desc.figureLabel) + ", Compensated)", methods, compMetrics.mse, scan, "logy", ...
    "MSE (after concealment)", "MSE (" + string(desc.figureLabel) + ", Compensated)", "northeast", ...
    "xLabelSingle", string(desc.xLabelSingle), ...
    "xLabelGrid", "J/S (dB)", ...
    "subplotTitlePrefix", string(desc.subplotTitlePrefix), ...
    "subplotTitleValues", double(desc.subplotTitleValues(:)));
local_export_figure(figMseComp, fullfile(outDir, "mse_" + string(desc.fileTag) + "_compensated.png"), "");
close(figMseComp);
end

function fig = local_create_line_figure(name)
fig = figure("Name", name, "Color", "w", "Visible", "off");
fig.Position = [100 100 1000 632];
end

function scan = local_get_scan_descriptor(results)
scan = struct( ...
    "type", "single_axis", ...
    "isGrid", false, ...
    "nSnr", numel(results.ebN0dB), ...
    "nJsr", 1, ...
    "ebN0dBList", double(results.ebN0dB(:)), ...
    "jsrDbList", nan(0, 1), ...
    "ebN0dBPoint", double(results.ebN0dB(:)), ...
    "jsrDbPoint", nan(numel(results.ebN0dB), 1), ...
    "snrIndex", (1:numel(results.ebN0dB)).', ...
    "jsrIndex", ones(numel(results.ebN0dB), 1));

if ~(isfield(results, "scan") && isstruct(results.scan))
    return;
end

required = ["type" "ebN0dBList" "jsrDbList" "snrIndex" "jsrIndex" "nSnr" "nJsr"];
for k = 1:numel(required)
    if ~isfield(results.scan, required(k))
        error("save_figures:MissingScanField", ...
            "results.scan.%s is required.", required(k));
    end
end
if ~isfield(results, "jsrDb")
    error("save_figures:MissingJsrDb", "results.jsrDb is required when results.scan is present.");
end

scan.type = string(results.scan.type);
scan.isGrid = scan.type == "ebn0_jsr_grid";
scan.nSnr = double(results.scan.nSnr);
scan.nJsr = double(results.scan.nJsr);
scan.ebN0dBList = double(results.scan.ebN0dBList(:));
scan.jsrDbList = double(results.scan.jsrDbList(:));
scan.ebN0dBPoint = double(results.ebN0dB(:));
scan.jsrDbPoint = double(results.jsrDb(:));
scan.snrIndex = double(results.scan.snrIndex(:));
scan.jsrIndex = double(results.scan.jsrIndex(:));
if numel(scan.ebN0dBPoint) ~= numel(scan.jsrDbPoint) ...
        || numel(scan.snrIndex) ~= numel(scan.ebN0dBPoint) ...
        || numel(scan.jsrIndex) ~= numel(scan.ebN0dBPoint)
    error("save_figures:InvalidScanPointCount", ...
        "results.scan and point-wise Eb/N0/JSR vectors must have the same length.");
end
end

function fig = local_create_point_metric_figure(name, legendLabels, values, scan, scaleMode, yLabel, overallTitle, legendLocation, opts)
arguments
    name
    legendLabels
    values
    scan (1,1) struct
    scaleMode
    yLabel
    overallTitle
    legendLocation
    opts.xLabelSingle = "E_b/N_0 (dB)"
    opts.xLabelGrid = "J/S (dB)"
    opts.subplotTitlePrefix = "E_b/N_0"
    opts.subplotTitleValues = []
    opts.applyBerFormatting (1,1) logical = false
end

legendLabels = string(legendLabels(:).');
subplotTitleValues = double(opts.subplotTitleValues(:));

if ~logical(scan.isGrid)
    fig = local_create_line_figure(name);
    ax = axes(fig);
    local_plot_series_matrix(ax, scan.ebN0dBPoint(:).', values, scaleMode);
    local_apply_line_labels(ax, opts.xLabelSingle, yLabel);
    if opts.applyBerFormatting
        local_format_ber_axis(ax, scan.ebN0dBPoint(:).', values);
    end
    local_style_legend(ax, legendLabels, legendLocation);
    return;
end

fig = local_create_line_figure(name);
[nRows, nCols] = local_metric_subplot_shape(scan.nSnr);
fig.Position = [100 100 1040 * nCols 420 * nRows];
tl = tiledlayout(fig, nRows, nCols, "TileSpacing", "compact", "Padding", "compact");
title(tl, char(string(overallTitle)));

for snrIdx = 1:scan.nSnr
    ax = nexttile(tl);
    pointMask = scan.snrIndex == snrIdx;
    order = local_sort_indices(scan.jsrIndex(pointMask));
    x = scan.jsrDbPoint(pointMask);
    x = x(order).';
    valsNow = values(:, pointMask);
    valsNow = valsNow(:, order);
    local_plot_series_matrix(ax, x, valsNow, scaleMode);
    local_apply_line_labels(ax, opts.xLabelGrid, yLabel, ...
        sprintf("%s = %.1f dB", char(string(opts.subplotTitlePrefix)), subplotTitleValues(find(pointMask, 1, "first"))));
    if opts.applyBerFormatting
        local_format_ber_axis(ax, x, valsNow);
    end
    if snrIdx == 1
        local_style_legend(ax, legendLabels, legendLocation);
    end
end
end

function fig = local_create_fixed_jsr_metric_figure(name, legendLabels, values, scan, scaleMode, yLabel, overallTitle, legendLocation, opts)
arguments
    name
    legendLabels
    values
    scan (1,1) struct
    scaleMode
    yLabel
    overallTitle
    legendLocation
    opts.xLabel = "E_b/N_0 (dB)"
    opts.subplotTitlePrefix = "J/S"
    opts.subplotTitleValues = []
    opts.applyBerFormatting (1,1) logical = false
end

if ~logical(scan.isGrid)
    error("save_figures:FixedJsrFigureRequiresGrid", ...
        "Fixed-JSR figures require ebn0_jsr_grid scan results.");
end

legendLabels = string(legendLabels(:).');
subplotTitleValues = double(opts.subplotTitleValues(:));
if numel(subplotTitleValues) ~= scan.nJsr
    error("save_figures:FixedJsrTitleCountMismatch", ...
        "Expected %d fixed-JSR subplot titles, but received %d.", ...
        scan.nJsr, numel(subplotTitleValues));
end

fig = local_create_line_figure(name);
[nRows, nCols] = local_metric_subplot_shape(scan.nJsr);
fig.Position = [100 100 1040 * nCols 420 * nRows];
tl = tiledlayout(fig, nRows, nCols, "TileSpacing", "compact", "Padding", "compact");
title(tl, char(string(overallTitle)));

for jsrIdx = 1:scan.nJsr
    ax = nexttile(tl);
    pointMask = scan.jsrIndex == jsrIdx;
    order = local_sort_indices(scan.snrIndex(pointMask));
    x = scan.ebN0dBPoint(pointMask);
    x = x(order).';
    valsNow = values(:, pointMask);
    valsNow = valsNow(:, order);
    local_plot_series_matrix(ax, x, valsNow, scaleMode);
    local_apply_line_labels(ax, opts.xLabel, yLabel, ...
        sprintf("%s = %.1f dB", char(string(opts.subplotTitlePrefix)), subplotTitleValues(jsrIdx)));
    if opts.applyBerFormatting
        local_format_ber_axis(ax, x, valsNow);
    end
    if jsrIdx == 1
        local_style_legend(ax, legendLabels, legendLocation);
    end
end
end

function [nRows, nCols] = local_metric_subplot_shape(nPanels)
nPanels = max(1, round(double(nPanels)));
if nPanels <= 2
    nRows = 1;
    nCols = nPanels;
    return;
end
if nPanels <= 4
    nRows = 2;
    nCols = 2;
    return;
end
nCols = 3;
nRows = ceil(nPanels / nCols);
end

function order = local_sort_indices(values)
[~, order] = sort(double(values(:)), "ascend");
end

function suffix = local_point_title_suffix(scan, pointIdx)
pointIdx = round(double(pointIdx));
if ~logical(scan.isGrid)
    suffix = sprintf("Eb/N0=%.1f dB", scan.ebN0dBPoint(pointIdx));
    return;
end
suffix = sprintf("Eb/N0=%.1f dB, J/S=%.1f dB", scan.ebN0dBPoint(pointIdx), scan.jsrDbPoint(pointIdx));
end

function tag = local_point_file_tag(scan, pointIdx)
pointIdx = round(double(pointIdx));
ebTag = local_scalar_tag(scan.ebN0dBPoint(pointIdx));
if ~logical(scan.isGrid)
    tag = "ebn0_" + ebTag + "dB";
    return;
end
jsrTag = local_scalar_tag(scan.jsrDbPoint(pointIdx));
tag = "ebn0_" + ebTag + "dB_jsr_" + jsrTag + "dB";
end

function tag = local_scalar_tag(value)
tag = string(sprintf("%.1f", double(value)));
tag = replace(tag, "-", "neg");
tag = replace(tag, ".", "p");
end

function fig = local_create_warden_figure(scan, w, wardenValues, wardenStyles, covertValues, covertLabels, covertStyles)
if ~logical(scan.isGrid)
    [x, xlab] = local_get_warden_axis(w);
    fig = local_create_line_figure("Warden");
    tl = tiledlayout(fig, 2, 1, "TileSpacing", "compact", "Padding", "compact");
    axTop = nexttile(tl);
    hTop = local_plot_series_matrix(axTop, x, wardenValues, "linear");
    local_apply_series_styles(hTop, wardenStyles, true);
    local_apply_line_labels(axTop, xlab, "Probability", ...
        sprintf("Energy NP layer: P_FA target=%.3g, nObs=%d, nTrials=%d", w.pfaTarget, round(w.nObs(1)), round(w.nTrials)));
    if size(wardenValues, 1) >= 4
        local_style_legend(axTop, ["P_D", "P_{FA}", "P_e", "\xi"], "best");
    else
        local_style_legend(axTop, ["P_D", "P_{FA}", "P_e"], "best");
    end

    axBottom = nexttile(tl);
    hBottom = local_plot_series_matrix(axBottom, x, covertValues, "linear");
    local_apply_series_styles(hBottom, covertStyles, true);
    local_apply_line_labels(axBottom, xlab, "Covert metric", ...
        sprintf("Primary layer: %s", local_get_primary_warden_layer(w)));
    local_style_legend(axBottom, covertLabels, "best");
    return;
end

fig = local_create_line_figure("Warden");
[nRows, nCols] = local_metric_subplot_shape(scan.nSnr);
fig.Position = [100 100 1100 * nCols 360 * (2 * nRows)];
tl = tiledlayout(fig, 2 * nRows, nCols, "TileSpacing", "compact", "Padding", "compact");
title(tl, sprintf("Warden Metrics by J/S (%s)", local_get_primary_warden_layer(w)));

for snrIdx = 1:scan.nSnr
    ax = nexttile(tl, snrIdx);
    pointMask = scan.snrIndex == snrIdx;
    order = local_sort_indices(scan.jsrIndex(pointMask));
    x = scan.jsrDbPoint(pointMask);
    valsNow = wardenValues(:, pointMask);
    x = x(order).';
    valsNow = valsNow(:, order);
    hNow = local_plot_series_matrix(ax, x, valsNow, "linear");
    local_apply_series_styles(hNow, wardenStyles, true);
    local_apply_line_labels(ax, "J/S (dB)", "Probability", ...
        sprintf("E_b/N_0 = %.1f dB", scan.ebN0dBList(snrIdx)));
    if snrIdx == 1
        if size(wardenValues, 1) >= 4
            local_style_legend(ax, ["P_D", "P_{FA}", "P_e", "\xi"], "best");
        else
            local_style_legend(ax, ["P_D", "P_{FA}", "P_e"], "best");
        end
    end
end

for snrIdx = 1:scan.nSnr
    ax = nexttile(tl, nRows * nCols + snrIdx);
    pointMask = scan.snrIndex == snrIdx;
    order = local_sort_indices(scan.jsrIndex(pointMask));
    x = scan.jsrDbPoint(pointMask);
    valsNow = covertValues(:, pointMask);
    x = x(order).';
    valsNow = valsNow(:, order);
    hNow = local_plot_series_matrix(ax, x, valsNow, "linear");
    local_apply_series_styles(hNow, covertStyles, true);
    local_apply_line_labels(ax, "J/S (dB)", "Covert metric", ...
        sprintf("E_b/N_0 = %.1f dB", scan.ebN0dBList(snrIdx)));
    if snrIdx == 1
        local_style_legend(ax, covertLabels, "best");
    end
end
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

function hLines = local_plot_series_matrix(ax, x, values, scaleMode, useDiscreteXAxis, showMarkers)
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
hLines = gobjects(1, size(values, 1));
hold(ax, "on");
for idx = 1:size(values, 1)
    style = local_pick_series_style(idx);
    y = values(idx, :);
    if isLogY
        y(y <= 0) = NaN;
    end
    h = plot(ax, x, y);
    hLines(idx) = h;
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

function local_apply_series_styles(handles, styles, showMarkers)
if numel(handles) ~= numel(styles)
    error("save_figures:SeriesStyleCountMismatch", ...
        "Expected %d styles, but received %d handles.", numel(styles), numel(handles));
end

for idx = 1:numel(handles)
    local_apply_series_style(handles(idx), styles(idx), showMarkers);
end
end

function style = local_pick_series_style(index)
if index < 1 || index ~= floor(index)
    error("save_figures:InvalidSeriesStyleIndex", ...
        "Series style index must be a positive integer, but received %g.", index);
end

styles = local_series_styles();
if index > numel(styles)
    styles = [styles, local_generated_series_styles(styles)];
end

if index > numel(styles)
    error("save_figures:InsufficientSeriesStyles", ...
        "Only %d unique series styles are available, but series index %d was requested.", ...
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

function styles = local_generated_series_styles(baseStyles)
palette = local_series_color_palette();
lineStyles = {"-", "--", "-.", ":"};
markers = {"o", "s", "d", "^", "v", "p", "h", "x", "+", "*", ">", "<"};

styles = struct("Color", {}, "LineStyle", {}, "Marker", {});
for markerIdx = 1:numel(markers)
    for lineIdx = 1:numel(lineStyles)
        for colorIdx = 1:size(palette, 1)
            candidate = struct( ...
                "Color", palette(colorIdx, :), ...
                "LineStyle", lineStyles{lineIdx}, ...
                "Marker", markers{markerIdx});

            if local_series_style_exists(baseStyles, candidate) || local_series_style_exists(styles, candidate)
                continue;
            end

            styles(end + 1) = candidate; %#ok<AGROW>
        end
    end
end
end

function tf = local_series_style_exists(styles, candidate)
tf = false;
for idx = 1:numel(styles)
    if local_is_same_style(styles(idx), candidate)
        tf = true;
        return;
    end
end
end

function tf = local_is_same_style(styleA, styleB)
tf = strcmp(styleA.LineStyle, styleB.LineStyle) ...
    && strcmp(styleA.Marker, styleB.Marker) ...
    && all(abs(styleA.Color - styleB.Color) < 1e-12);
end

function palette = local_series_color_palette()
palette = [ ...
    213 94 0; ...
    153 153 153; ...
    230 159 0; ...
    0 158 115; ...
    204 121 167; ...
    0 114 178; ...
    86 180 233; ...
    240 228 66; ...
    68 119 170; ...
    17 119 51; ...
    102 204 238; ...
    221 204 119; ...
    204 102 119; ...
    136 34 85; ...
    170 68 153; ...
    51 34 136 ...
    ] / 255;
end

function style = local_get_warden_series_style(seriesName)
seriesName = lower(string(seriesName));
switch seriesName
    case "pd"
        style = struct("Color", [213 94 0] / 255, "LineStyle", "-", "Marker", "s");
    case "pfa"
        style = struct("Color", [153 153 153] / 255, "LineStyle", "-", "Marker", "o");
    case "pe"
        style = struct("Color", [230 159 0] / 255, "LineStyle", "-", "Marker", "v");
    case "peideal"
        style = struct("Color", [230 159 0] / 255, "LineStyle", "--", "Marker", "v");
    case "xi"
        style = struct("Color", [0 158 115] / 255, "LineStyle", "-", "Marker", "^");
    case "xiideal"
        style = struct("Color", [0 158 115] / 255, "LineStyle", "--", "Marker", "^");
    otherwise
        error("save_figures:UnsupportedWardenSeriesStyle", ...
            "Unsupported Warden series style name: %s", char(seriesName));
end
end

function sourceImages = local_get_source_images(results)
if ~(isfield(results, "sourceImages") && isstruct(results.sourceImages))
    error("save_figures:MissingSourceImages", "results.sourceImages is required.");
end
if ~(isfield(results.sourceImages, "resized") && isfield(results.sourceImages, "original"))
    error("save_figures:IncompleteSourceImages", ...
        "results.sourceImages must contain resized and original images.");
end
sourceImages = results.sourceImages;
end

function imageMetrics = local_get_image_metrics(results)
if ~(isfield(results, "imageMetrics") && isstruct(results.imageMetrics))
    error("save_figures:MissingImageMetrics", "results.imageMetrics is required.");
end
requiredRefs = ["resized" "original"];
requiredStates = ["communication" "compensated"];
for refIdx = 1:numel(requiredRefs)
    refName = requiredRefs(refIdx);
    if ~(isfield(results.imageMetrics, refName) && isstruct(results.imageMetrics.(refName)))
        error("save_figures:MissingImageMetricReference", ...
            "results.imageMetrics.%s is required.", refName);
    end
    for stateIdx = 1:numel(requiredStates)
        stateName = requiredStates(stateIdx);
        if ~(isfield(results.imageMetrics.(refName), stateName) && isstruct(results.imageMetrics.(refName).(stateName)))
            error("save_figures:MissingImageMetricState", ...
                "results.imageMetrics.%s.%s is required.", refName, stateName);
        end
    end
end
imageMetrics = results.imageMetrics;
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
        if ~isfield(exampleEntry, "imgRxComm")
            error("save_figures:MissingExampleImage", "exampleEntry.imgRxComm is required.");
        end
        img = exampleEntry.imgRxComm;
    case "compensated"
        if ~isfield(exampleEntry, "imgRxCompensated")
            error("save_figures:MissingExampleImage", "exampleEntry.imgRxCompensated is required.");
        end
        img = exampleEntry.imgRxCompensated;
    otherwise
        error("save_figures:InvalidExampleVariant", ...
            "Unsupported example variant: %s", char(variantKey));
    end
end

function lines = local_example_metric_lines(variantKey, originalMetrics, resizedMetrics, methodIdx, snrIdx, includeSsim)
if nargin < 6
    includeSsim = true;
end

switch lower(string(variantKey))
    case "communication"
        originalNow = originalMetrics.communication;
        resizedNow = resizedMetrics.communication;
    case "compensated"
        originalNow = originalMetrics.compensated;
        resizedNow = resizedMetrics.compensated;
    otherwise
        error("save_figures:InvalidExampleVariant", ...
            "Unsupported example variant: %s", char(string(variantKey)));
end

lines = { ...
    local_quality_line("Orig", originalNow.psnr(methodIdx, snrIdx), originalNow.ssim(methodIdx, snrIdx), includeSsim); ...
    local_quality_line("Rszd", resizedNow.psnr(methodIdx, snrIdx), resizedNow.ssim(methodIdx, snrIdx), includeSsim)};
end

function titleLines = local_example_title_lines(nameLine, ebN0Val, metricLines, jsrVal)
if nargin < 4 || isempty(jsrVal) || ~isfinite(double(jsrVal))
    pointLine = sprintf("Eb/N0=%.1f dB", ebN0Val);
else
    pointLine = sprintf("Eb/N0=%.1f dB, J/S=%.1f dB", ebN0Val, double(jsrVal));
end
if ischar(metricLines) || (isstring(metricLines) && isscalar(metricLines))
    metricLines = {char(string(metricLines))};
elseif isstring(metricLines)
    metricLines = cellstr(metricLines(:));
elseif ~iscell(metricLines)
    error("save_figures:InvalidMetricLines", "metricLines must be a text scalar or a cell array of text.");
end
titleLines = [{char(string(nameLine))}; {pointLine}; metricLines(:)];
end

function jsrVal = local_example_jsr_value(scan, pointIdx)
if ~logical(scan.isGrid)
    jsrVal = NaN;
    return;
end
jsrVal = scan.jsrDbPoint(pointIdx);
end

function lines = local_build_eve_info_lines(shortLabel, ebN0Val, jsrVal)
if nargin < 3 || isempty(jsrVal) || ~isfinite(double(jsrVal))
    pointLine = sprintf("Eb/N0=%.1f dB", ebN0Val);
else
    pointLine = sprintf("Eb/N0=%.1f dB, J/S=%.1f dB", ebN0Val, double(jsrVal));
end
lines = { ...
    char(sprintf("Eve (%s)", shortLabel)); ...
    pointLine; ...
    "Intercept view"};
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

function txt = local_quality_line(label, psnrVal, ssimVal, includeSsim)
if nargin < 4
    includeSsim = true;
end
label = char(string(label));
if includeSsim
    txt = sprintf("%s: PSNR=%.2fdB, SSIM=%.3f", label, psnrVal, ssimVal);
else
    txt = sprintf("%s: PSNR=%.2fdB", label, psnrVal);
end
end
