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

fig4 = figure("Name", "Images");
tiledlayout(1, numel(methods) + 1);
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
exportgraphics(fig4, fullfile(outDir, "images.png"));
close(fig4);

if isfield(results, "eve") && isfield(results.eve, "example")
    fig5 = figure("Name", "Intercept");
    tiledlayout(2, numel(methods) + 1);

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
    exportgraphics(fig5, fullfile(outDir, "intercept.png"));
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
