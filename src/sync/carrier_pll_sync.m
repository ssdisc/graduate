function [yOut, info] = carrier_pll_sync(yIn, modCfg, pllCfg)
%CARRIER_PLL_SYNC  决策导向载波PLL（残余频偏/相位跟踪）。
%
% 输入:
%   yIn    - 输入符号（列向量）
%   modCfg - 调制配置（.type: 'BPSK'/'QPSK'/'MSK'）
%   pllCfg - PLL配置
%            .enable   - 是否启用
%            .alpha    - 相位环比例增益
%            .beta     - 频率环积分增益
%            .maxFreq  - 频率估计限幅（rad/sample）
%
% 输出:
%   yOut - 补偿后的符号
%   info - 诊断信息（error/freq/phase轨迹）

arguments
    yIn (:,1)
    modCfg (1,1) struct
    pllCfg (1,1) struct
end

if ~isfield(pllCfg, "enable"); pllCfg.enable = false; end
if ~isfield(pllCfg, "alpha"); pllCfg.alpha = 0.02; end
if ~isfield(pllCfg, "beta"); pllCfg.beta = 3e-4; end
if ~isfield(pllCfg, "maxFreq"); pllCfg.maxFreq = 0.1; end

yIn = yIn(:);
if ~pllCfg.enable || isempty(yIn)
    yOut = yIn;
    info = struct("enabled", false);
    return;
end

nSym = numel(yIn);
yOut = complex(zeros(size(yIn)));
errHist = zeros(nSym, 1);
freqHist = zeros(nSym, 1);
phaseHist = zeros(nSym, 1);

alpha = double(pllCfg.alpha);
beta = double(pllCfg.beta);
maxFreq = abs(double(pllCfg.maxFreq));

theta = 0;
omega = 0;

for k = 1:nSym
    y = yIn(k) * exp(-1j * theta);
    d = slicer_symbol(y, modCfg);
    err = imag(y * conj(d)); % 判决导向相位误差

    omega = omega + beta * err;
    omega = min(max(omega, -maxFreq), maxFreq);
    theta = theta + omega + alpha * err;

    yOut(k) = y;
    errHist(k) = err;
    freqHist(k) = omega;
    phaseHist(k) = theta;
end

info = struct();
info.enabled = true;
info.error = errHist;
info.freqRadPerSample = freqHist;
info.phaseRad = phaseHist;
info.finalFreqRadPerSample = omega;
info.finalPhaseRad = theta;
end

function d = slicer_symbol(y, modCfg)
switch upper(string(modCfg.type))
    case "BPSK"
        b = sign(real(y));
        if b == 0
            b = 1;
        end
        d = complex(b, 0);
    case "QPSK"
        bi = sign(real(y));
        bq = sign(imag(y));
        if bi == 0; bi = 1; end
        if bq == 0; bq = 1; end
        d = (bi + 1j * bq) / sqrt(2);
    case "MSK"
        % MSK为连续相位调制，使用四象限相位判决提供相位误差方向。
        bi = sign(real(y));
        bq = sign(imag(y));
        if bi == 0; bi = 1; end
        if bq == 0; bq = 1; end
        d = (bi + 1j * bq) / sqrt(2);
    otherwise
        error("carrier_pll_sync不支持该调制: %s", string(modCfg.type));
end
end
