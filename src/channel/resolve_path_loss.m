function [lossDb, lossLinear] = resolve_path_loss(pathLossCfg)
%RESOLVE_PATH_LOSS  计算大尺度路径损耗（dB与线性增益）。

model = "log_distance";
if isfield(pathLossCfg, "model")
    model = lower(string(pathLossCfg.model));
end

switch model
    case "fixed_db"
        lossDb = 0;
        if isfield(pathLossCfg, "fixedLossDb")
            lossDb = double(pathLossCfg.fixedLossDb);
        end
    case "log_distance"
        d0 = 1.0;
        d = 1.0;
        nExp = 2.0;
        pl0 = 0.0;
        shadowStd = 0.0;
        if isfield(pathLossCfg, "referenceDistance"); d0 = double(pathLossCfg.referenceDistance); end
        if isfield(pathLossCfg, "distance"); d = double(pathLossCfg.distance); end
        if isfield(pathLossCfg, "pathLossExp"); nExp = double(pathLossCfg.pathLossExp); end
        if isfield(pathLossCfg, "referenceLossDb"); pl0 = double(pathLossCfg.referenceLossDb); end
        if isfield(pathLossCfg, "shadowStdDb"); shadowStd = abs(double(pathLossCfg.shadowStdDb)); end

        d0 = max(d0, eps);
        d = max(d, d0);
        shadowDb = shadowStd * randn(1, 1);
        lossDb = pl0 + 10*nExp*log10(d / d0) + shadowDb;
    otherwise
        error("未知的pathLoss.model: %s", string(model));
end

lossLinear = 10.^(-lossDb/20);
end

