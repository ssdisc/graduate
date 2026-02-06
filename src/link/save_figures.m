function save_figures(outDir, imgTx, results)
%SAVE_FIGURES  将标准图形（BER/PSNR/PSD/图像）保存到磁盘。

methods = results.methods;
EbN0dB = results.ebN0dB;

fig1 = figure("Name", "BER");
semilogy(EbN0dB, results.ber.', "o-");
grid on;
xlabel("E_b/N_0 (dB)");
ylabel("BER (payload)");
legend(methods, "Location", "southwest");
exportgraphics(fig1, fullfile(outDir, "ber.png"));
close(fig1);

fig2 = figure("Name", "PSNR");
plot(EbN0dB, results.psnr.', "o-");
grid on;
xlabel("E_b/N_0 (dB)");
ylabel("PSNR (dB)");
legend(methods, "Location", "southeast");
exportgraphics(fig2, fullfile(outDir, "psnr.png"));
close(fig2);


if isfield(results, "eve")
    fig2b = figure("Name", "PSNR (Eve)");
    plot(results.eve.ebN0dB, results.eve.psnr.', "o-");
    grid on;
    xlabel("E_b/N_0 at Eve (dB)");
    ylabel("PSNR (dB)");
    legend(methods, "Location", "southeast");
    exportgraphics(fig2b, fullfile(outDir, "psnr_eve.png"));
    close(fig2b);

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
        
        % 获取该方法的PSNR和SSIM
        psnrVal = results.psnr(k, :);
        ssimVal = results.ssim(k, :);
        % 与example图像保持一致的Eb/N0索引
        if isfield(results.example.(methods(k)), "EbN0dB")
            ebN0Sel = double(results.example.(methods(k)).EbN0dB);
            [~, exampleIdx] = min(abs(results.ebN0dB - ebN0Sel));
        else
            exampleIdx = numel(results.ebN0dB);
            ebN0Sel = results.ebN0dB(exampleIdx);
        end
        psnrMid = psnrVal(exampleIdx);
        ssimMid = ssimVal(exampleIdx);
        ebN0Mid = ebN0Sel;
        
        imshow(results.example.(methods(k)).imgRx);
        titleStr = sprintf("RX - %s\nEb/N0=%.0fdB, PSNR=%.2fdB, SSIM=%.3f", ...
            methods(k), ebN0Mid, psnrMid, ssimMid);
        title(titleStr, "FontSize", 12);
        
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
        
        tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
        
        % 左：TX
        nexttile;
        imshow(imgTx);
        title("TX (原图)", "FontSize", 12);
        
        % 右：RX
        nexttile;
        imshow(results.example.(methods(k)).imgRx);
        if isfield(results.example.(methods(k)), "EbN0dB")
            ebN0Sel = double(results.example.(methods(k)).EbN0dB);
            [~, exampleIdx] = min(abs(results.ebN0dB - ebN0Sel));
        else
            exampleIdx = numel(results.ebN0dB);
        end
        psnrMid = results.psnr(k, exampleIdx);
        ssimMid = results.ssim(k, exampleIdx);
        title(sprintf("RX - %s\nPSNR=%.2fdB, SSIM=%.3f", methods(k), psnrMid, ssimMid), "FontSize", 12);
        
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
        imshow(results.example.(methods(k)).imgRx);
        title(sprintf("RX - %s", methods(k)));
    else
        text(0.1, 0.5, "No example", "Units", "normalized");
        axis off;
        title(sprintf("RX - %s", methods(k)));
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
            imshow(results.example.(methods(k)).imgRx);
            psnrBob = results.psnr(k, exampleIdx);
            ssimBob = results.ssim(k, exampleIdx);
            ebN0Bob = results.ebN0dB(exampleIdx);
            title(sprintf("Bob - %s\nEb/N0=%.0fdB, PSNR=%.2fdB", methods(k), ebN0Bob, psnrBob), "FontSize", 12);
            
            % 右：Eve截获
            nexttile;
            imshow(results.eve.example.(methods(k)).imgRx);
            psnrEve = results.eve.psnr(k, exampleIdx);
            ssimEve = results.eve.ssim(k, exampleIdx);
            ebN0Eve = results.eve.ebN0dB(exampleIdx);
            hdrTxt = "";
            if isfield(results.eve.example.(methods(k)), "headerOk")
                if results.eve.example.(methods(k)).headerOk
                    hdrTxt = " (hdr ok)";
                else
                    hdrTxt = " (hdr fail)";
                end
            end
            title(sprintf("Eve - %s%s\nEb/N0=%.0fdB, PSNR=%.2fdB", methods(k), hdrTxt, ebN0Eve, psnrEve), "FontSize", 12);
            
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
            imshow(results.example.(methods(k)).imgRx);
            title(sprintf("Bob - %s", methods(k)));
        else
            text(0.1, 0.5, "No example", "Units", "normalized");
            axis off;
            title(sprintf("Bob - %s", methods(k)));
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
            imshow(results.eve.example.(methods(k)).imgRx);
            hdrTxt = "";
            if isfield(results.eve.example.(methods(k)), "headerOk")
                if results.eve.example.(methods(k)).headerOk
                    hdrTxt = "hdr ok";
                else
                    hdrTxt = "hdr fail";
                end
            end
            if strlength(hdrTxt) > 0
                title(sprintf("Eve - %s (%s)", methods(k), hdrTxt));
            else
                title(sprintf("Eve - %s", methods(k)));
            end
        else
            text(0.1, 0.5, "No example", "Units", "normalized");
            axis off;
            title(sprintf("Eve - %s", methods(k)));
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
