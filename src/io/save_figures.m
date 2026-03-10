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

fig1 = figure("Name", "BER");
semilogy(EbN0dB, results.ber.', "o-");
grid on;
xlabel("E_b/N_0 (dB)");
ylabel("BER (payload)");
legend(methods, "Location", "southwest");
exportgraphics(fig1, fullfile(outDir, "ber.png"));
close(fig1);

fig2 = figure("Name", "PSNR (Communication)");
plot(EbN0dB, commMetrics.psnr.', "o-");
grid on;
xlabel("E_b/N_0 (dB)");
ylabel("PSNR (dB, communication only)");
legend(methods, "Location", "southeast");
exportgraphics(fig2, fullfile(outDir, "psnr.png"));
exportgraphics(fig2, fullfile(outDir, "psnr_comm.png"));
close(fig2);

fig2m = figure("Name", "MSE (Communication)");
semilogy(EbN0dB, commMetrics.mse.', "o-");
grid on;
xlabel("E_b/N_0 (dB)");
ylabel("MSE (communication only)");
legend(methods, "Location", "northeast");
exportgraphics(fig2m, fullfile(outDir, "mse.png"));
exportgraphics(fig2m, fullfile(outDir, "mse_comm.png"));
close(fig2m);

if packetConcealActive
    fig2c = figure("Name", "PSNR (Compensated)");
    plot(EbN0dB, compMetrics.psnr.', "o-");
    grid on;
    xlabel("E_b/N_0 (dB)");
    ylabel("PSNR (dB, after concealment)");
    legend(methods, "Location", "southeast");
    exportgraphics(fig2c, fullfile(outDir, "psnr_compensated.png"));
    close(fig2c);

    fig2cm = figure("Name", "MSE (Compensated)");
    semilogy(EbN0dB, compMetrics.mse.', "o-");
    grid on;
    xlabel("E_b/N_0 (dB)");
    ylabel("MSE (after concealment)");
    legend(methods, "Location", "northeast");
    exportgraphics(fig2cm, fullfile(outDir, "mse_compensated.png"));
    close(fig2cm);
end

if isfield(results, "kl")
    fig2k = figure("Name", "KL Divergence");
    plot(results.kl.ebN0dB, results.kl.signalVsNoise, "o-");
    hold on;
    plot(results.kl.ebN0dB, results.kl.symmetric, "s-");
    grid on;
    xlabel("E_b/N_0 (dB)");
    ylabel("KL divergence");
    legend("KL(P_{sig}||P_{noise})", "Symmetric KL", "Location", "best");
    exportgraphics(fig2k, fullfile(outDir, "kl.png"));
    close(fig2k);
end


if isfield(results, "eve")
    [commMetricsEve, compMetricsEve] = local_get_image_metrics(results.eve);
    fig2b = figure("Name", "PSNR (Eve, Communication)");
    plot(results.eve.ebN0dB, commMetricsEve.psnr.', "o-");
    grid on;
    xlabel("E_b/N_0 at Eve (dB)");
    ylabel("PSNR (dB, communication only)");
    legend(methods, "Location", "southeast");
    exportgraphics(fig2b, fullfile(outDir, "psnr_eve.png"));
    exportgraphics(fig2b, fullfile(outDir, "psnr_eve_comm.png"));
    close(fig2b);

    if isfield(commMetricsEve, "mse")
        fig2bm = figure("Name", "MSE (Eve, Communication)");
        semilogy(results.eve.ebN0dB, commMetricsEve.mse.', "o-");
        grid on;
        xlabel("E_b/N_0 at Eve (dB)");
        ylabel("MSE (communication only)");
        legend(methods, "Location", "northeast");
        exportgraphics(fig2bm, fullfile(outDir, "mse_eve.png"));
        exportgraphics(fig2bm, fullfile(outDir, "mse_eve_comm.png"));
        close(fig2bm);
    end

    if packetConcealActive
        fig2bc = figure("Name", "PSNR (Eve, Compensated)");
        plot(results.eve.ebN0dB, compMetricsEve.psnr.', "o-");
        grid on;
        xlabel("E_b/N_0 at Eve (dB)");
        ylabel("PSNR (dB, after concealment)");
        legend(methods, "Location", "southeast");
        exportgraphics(fig2bc, fullfile(outDir, "psnr_eve_compensated.png"));
        close(fig2bc);

        fig2bcm = figure("Name", "MSE (Eve, Compensated)");
        semilogy(results.eve.ebN0dB, compMetricsEve.mse.', "o-");
        grid on;
        xlabel("E_b/N_0 at Eve (dB)");
        ylabel("MSE (after concealment)");
        legend(methods, "Location", "northeast");
        exportgraphics(fig2bcm, fullfile(outDir, "mse_eve_compensated.png"));
        close(fig2bcm);
    end

    fig1b = figure("Name", "BER (Eve)");
    semilogy(results.eve.ebN0dB, results.eve.ber.', "o-");
    grid on;
    xlabel("E_b/N_0 at Eve (dB)");
    ylabel("BER (payload)");
    legend(methods, "Location", "southwest");
    exportgraphics(fig1b, fullfile(outDir, "ber_eve.png"));
    close(fig1b);
end

fig3 = figure("Name", "Spectrum");
plot(results.spectrum.freqHz/1e3, 10*log10(results.spectrum.psd));
grid on;
xlabel("Frequency (kHz)");
ylabel("PSD (dB/Hz)");
title(sprintf("99%% OBW=%.1f Hz,  \\eta=%.3f b/s/Hz", results.spectrum.bw99Hz, results.spectrum.etaBpsHz));
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

% 2. 为每种方法单独保存接收图像
for k = 1:numel(methods)
    if isfield(results.example, methods(k))
        figRx = figure("Name", sprintf("RX - %s", methods(k)), "Visible", "off");
        exampleEntry = results.example.(methods(k));
        mseCommVal = commMetrics.mse(k, :);
        psnrCommVal = commMetrics.psnr(k, :);
        ssimCommVal = commMetrics.ssim(k, :);
        mseCompVal = compMetrics.mse(k, :);
        psnrCompVal = compMetrics.psnr(k, :);
        ssimCompVal = compMetrics.ssim(k, :);
        % 与example图像保持一致的Eb/N0索引
        if isfield(exampleEntry, "EbN0dB")
            ebN0Sel = double(exampleEntry.EbN0dB);
            [~, exampleIdx] = min(abs(results.ebN0dB - ebN0Sel));
        else
            exampleIdx = numel(results.ebN0dB);
            ebN0Sel = results.ebN0dB(exampleIdx);
        end
        ebN0Mid = ebN0Sel;

        imshow(local_get_example_image(exampleEntry));
        titleLines = cell(3 + double(packetConcealActive), 1);
        titleLines{1} = sprintf("RX - %s", methods(k));
        titleLines{2} = sprintf("Eb/N0=%.0fdB", ebN0Mid);
        titleLines{3} = local_metric_line("Comm", mseCommVal(exampleIdx), psnrCommVal(exampleIdx), ssimCommVal(exampleIdx), true);
        if packetConcealActive
            titleLines{4} = local_metric_line("Comp", mseCompVal(exampleIdx), psnrCompVal(exampleIdx), ssimCompVal(exampleIdx), true);
        end
        title(titleLines, "FontSize", 12);
        
        % 文件名带序号，方便排序
        filename = sprintf("%02d_rx_%s.png", k, lower(strrep(methods(k), " ", "_")));
        exportgraphics(figRx, fullfile(imagesDir, filename), 'Resolution', 200);
        close(figRx);
    end
end

% 3. 保存TX与各方法RX的对比图（每种方法一张，左TX右RX）
for k = 1:numel(methods)
    if isfield(results.example, methods(k))
        figCmp = figure("Name", sprintf("Compare - %s", methods(k)), "Visible", "off");
        figCmp.Position = [100 100 800 400];
        exampleEntry = results.example.(methods(k));
        
        tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
        
        % 左：TX
        nexttile;
        imshow(imgTx);
        title("TX (原图)", "FontSize", 12);
        
        % 右：RX
        nexttile;
        imshow(local_get_example_image(exampleEntry));
        if isfield(exampleEntry, "EbN0dB")
            ebN0Sel = double(exampleEntry.EbN0dB);
            [~, exampleIdx] = min(abs(results.ebN0dB - ebN0Sel));
        else
            exampleIdx = numel(results.ebN0dB);
        end
        titleLines = cell(2 + double(packetConcealActive), 1);
        titleLines{1} = sprintf("RX - %s", methods(k));
        titleLines{2} = local_metric_line("Comm", commMetrics.mse(k, exampleIdx), commMetrics.psnr(k, exampleIdx), commMetrics.ssim(k, exampleIdx), true);
        if packetConcealActive
            titleLines{3} = local_metric_line("Comp", compMetrics.mse(k, exampleIdx), compMetrics.psnr(k, exampleIdx), compMetrics.ssim(k, exampleIdx), true);
        end
        title(titleLines, "FontSize", 12);
        
        filename = sprintf("compare_%02d_%s.png", k, lower(strrep(methods(k), " ", "_")));
        exportgraphics(figCmp, fullfile(imagesDir, filename), 'Resolution', 200);
        close(figCmp);
    end
end

% 4. 保存所有方法的汇总对比图（保留原有功能）
fig4 = figure("Name", "Images", "Visible", "off");
nMethods = numel(methods);
nTotal = nMethods + 1;  % +1 for TX image
% 使用2行布局以获得更好的显示效果
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
        imshow(local_get_example_image(results.example.(methods(k))));
        title(local_example_label("RX", methods(k), packetConcealActive));
    else
        text(0.1, 0.5, "No example", "Units", "normalized");
        axis off;
        title(local_example_label("RX", methods(k), packetConcealActive));
    end
end
exportgraphics(fig4, fullfile(outDir, "images.png"), 'Resolution', 150);
close(fig4);


if isfield(results, "eve") && isfield(results.eve, "example")
    % 创建eve子目录
    eveDir = fullfile(outDir, "images_eve");
    if ~exist(eveDir, 'dir')
        mkdir(eveDir);
    end
    
    % 为每种方法单独保存Bob vs Eve对比图
    for k = 1:numel(methods)
        if isfield(results.example, methods(k)) && isfield(results.eve.example, methods(k))
            if isfield(results.example.(methods(k)), "EbN0dB")
                ebN0Sel = double(results.example.(methods(k)).EbN0dB);
                [~, exampleIdx] = min(abs(results.ebN0dB - ebN0Sel));
            else
                exampleIdx = numel(results.ebN0dB);
            end

            figEve = figure("Name", sprintf("Bob vs Eve - %s", methods(k)), "Visible", "off");
            figEve.Position = [100 100 1200 400];
            
            tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
            
            % 左：TX原图
            nexttile;
            imshow(imgTx);
            title("TX (原图)", "FontSize", 12);
            
            % 中：Bob接收
            nexttile;
            imshow(local_get_example_image(results.example.(methods(k))));
            ebN0Bob = results.ebN0dB(exampleIdx);
            titleLinesBob = cell(3 + double(packetConcealActive), 1);
            titleLinesBob{1} = sprintf("Bob - %s", methods(k));
            titleLinesBob{2} = sprintf("Eb/N0=%.0fdB", ebN0Bob);
            titleLinesBob{3} = local_metric_line("Comm", commMetrics.mse(k, exampleIdx), commMetrics.psnr(k, exampleIdx), commMetrics.ssim(k, exampleIdx), false);
            if packetConcealActive
                titleLinesBob{4} = local_metric_line("Comp", compMetrics.mse(k, exampleIdx), compMetrics.psnr(k, exampleIdx), compMetrics.ssim(k, exampleIdx), false);
            end
            title(titleLinesBob, "FontSize", 12);
            
            % 右：Eve截获
            nexttile;
            imshow(local_get_example_image(results.eve.example.(methods(k))));
            ebN0Eve = results.eve.ebN0dB(exampleIdx);
            hdrTxt = "";
            if isfield(results.eve.example.(methods(k)), "headerOk")
                if results.eve.example.(methods(k)).headerOk
                    hdrTxt = " (hdr ok)";
                else
                    hdrTxt = " (hdr fail)";
                end
            end
            titleLinesEve = cell(3 + double(packetConcealActive), 1);
            titleLinesEve{1} = sprintf("Eve - %s%s", methods(k), hdrTxt);
            titleLinesEve{2} = sprintf("Eb/N0=%.0fdB", ebN0Eve);
            titleLinesEve{3} = local_metric_line("Comm", commMetricsEve.mse(k, exampleIdx), commMetricsEve.psnr(k, exampleIdx), commMetricsEve.ssim(k, exampleIdx), false);
            if packetConcealActive
                titleLinesEve{4} = local_metric_line("Comp", compMetricsEve.mse(k, exampleIdx), compMetricsEve.psnr(k, exampleIdx), compMetricsEve.ssim(k, exampleIdx), false);
            end
            title(titleLinesEve, "FontSize", 12);
            
            filename = sprintf("bob_vs_eve_%02d_%s.png", k, lower(strrep(methods(k), " ", "_")));
            exportgraphics(figEve, fullfile(eveDir, filename), 'Resolution', 200);
            close(figEve);
        end
    end
    
    % 保存汇总对比图（保留原有功能）
    fig5 = figure("Name", "Intercept", "Visible", "off");
    nCols = numel(methods) + 1;
    fig5.Position = [100 100 200*nCols 400];
    tiledlayout(2, nCols, 'TileSpacing', 'compact', 'Padding', 'compact');

    % Bob
    nexttile;
    imshow(imgTx);
    title("TX");
    for k = 1:numel(methods)
        nexttile;
        if isfield(results.example, methods(k))
            imshow(local_get_example_image(results.example.(methods(k))));
            title(local_example_label("Bob", methods(k), packetConcealActive));
        else
            text(0.1, 0.5, "No example", "Units", "normalized");
            axis off;
            title(local_example_label("Bob", methods(k), packetConcealActive));
        end
    end

    % Eve
    nexttile;
    txt = {'Eve (intercept)'};
    if isfield(results.eve.example, methods(1)) && isfield(results.eve.example.(methods(1)), "EbN0dB")
        txt{end+1} = sprintf("Eb/N0=%.1f dB", results.eve.example.(methods(1)).EbN0dB);
    end
    text(0.05, 0.5, txt, "Units", "normalized", "Interpreter", "none");
    axis off;
    title("Eve");

    for k = 1:numel(methods)
        nexttile;
        if isfield(results.eve.example, methods(k))
            imshow(local_get_example_image(results.eve.example.(methods(k))));
            hdrTxt = "";
            if isfield(results.eve.example.(methods(k)), "headerOk")
                if results.eve.example.(methods(k)).headerOk
                    hdrTxt = "hdr ok";
                else
                    hdrTxt = "hdr fail";
                end
            end
            if strlength(hdrTxt) > 0
                title(local_example_label("Eve", methods(k), packetConcealActive, hdrTxt));
            else
                title(local_example_label("Eve", methods(k), packetConcealActive));
            end
        else
            text(0.1, 0.5, "No example", "Units", "normalized");
            axis off;
            title(local_example_label("Eve", methods(k), packetConcealActive));
        end
    end
    exportgraphics(fig5, fullfile(outDir, "intercept.png"), 'Resolution', 150);
    close(fig5);
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    w = results.covert.warden;
    x = w.ebN0dB;
    xlab = "E_b/N_0 (dB)";
    if isfield(w, "eveEbN0dB")
        x = w.eveEbN0dB;
        xlab = "E_b/N_0 at Eve (dB)";
    end
    fig6 = figure("Name", "Warden");
    plot(x, w.pdEst, "o-");
    hold on;
    plot(x, w.pfaEst, "o-");
    plot(x, w.peEst, "o-");
    grid on;
    xlabel(xlab);
    ylabel("Probability");
    legend("P_D", "P_{FA}", "P_e", "Location", "best");
    title(sprintf("Energy detector: P_FA target=%.3g, nObs=%d, nTrials=%d", w.pfaTarget, round(w.nObs(1)), round(w.nTrials)));
    exportgraphics(fig6, fullfile(outDir, "warden.png"));
    close(fig6);
end
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

function img = local_get_example_image(exampleEntry)
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

function txt = local_example_label(prefix, methodName, packetConcealActive, varargin)
suffix = "";
if packetConcealActive
    suffix = " (comp)";
end
extra = "";
if nargin >= 4 && ~isempty(varargin{1}) && strlength(string(varargin{1})) > 0
    extra = sprintf(" (%s)", string(varargin{1}));
end
txt = sprintf("%s - %s%s%s", char(string(prefix)), char(string(methodName)), char(suffix), char(extra));
end
