%% test_fh.m - 跳频功能验证测试
clear; clc;
addpath(genpath('src'));

fprintf('========================================\n');
fprintf('跳频功能验证测试\n');
fprintf('========================================\n\n');

%% 测试1：跳频序列生成
fprintf('测试1: 跳频序列生成\n');
fh = struct();
fh.nFreqs = 8;
fh.sequenceType = 'pn';
fh.pnPolynomial = [1 0 0 1 1];
fh.pnInit = [1 0 0 1];
fh.freqSet = linspace(-0.35, 0.35, 8);

[freqIdx, ~] = fh_generate_sequence(20, fh);
fprintf('  生成20跳的频率索引: ');
fprintf('%d ', freqIdx(1:10));
fprintf('...\n');
fprintf('  频率索引范围: [%d, %d]\n', min(freqIdx), max(freqIdx));
assert(all(freqIdx >= 1 & freqIdx <= fh.nFreqs), '频率索引超出范围!');
fprintf('  [通过] 序列生成正确\n\n');

%% 测试2：跳频调制/解调
fprintf('测试2: 跳频调制/解调\n');
fh.enable = true;
fh.symbolsPerHop = 64;

% 生成测试符号
nSym = 256;
txSym = (2*randi([0 1], nSym, 1) - 1) + 0j;  % BPSK

% 跳频调制
[txHopped, hopInfo] = fh_modulate(txSym, fh);
fprintf('  原始符号: %d个\n', numel(txSym));
fprintf('  跳频后符号: %d个\n', numel(txHopped));
fprintf('  跳数: %d\n', hopInfo.nHops);

% 跳频解调
rxDehopped = fh_demodulate(txHopped, hopInfo);

% 验证恢复
err = norm(txSym - rxDehopped);
fprintf('  解跳后误差: %.2e\n', err);
assert(err < 1e-10, '跳频解调误差过大!');
fprintf('  [通过] 调制/解调可逆\n\n');

%% 测试3：带噪声的跳频通信
fprintf('测试3: 带噪声的跳频通信\n');
p = default_params();
p.fh.enable = true;
p.fh.nFreqs = 8;
p.fh.symbolsPerHop = 32;
p.sim.ebN0dBList = [8];
p.sim.nFramesPerPoint = 1;
p.mitigation.methods = "none";
p.source.resizeTo = [32 32];
p.eve.enable = false;
p.covert.enable = false;
p.sim.saveFigures = false;

fprintf('  参数: Eb/N0=8dB, 图像32x32, 8频点跳频\n');
fprintf('  运行仿真...\n');
results = simulate(p);

fprintf('  BER: %.4f\n', results.ber);
fprintf('  PSNR: %.1f dB\n', results.psnr);
assert(results.ber < 0.1, 'BER过高!');
fprintf('  [通过] 跳频仿真正常\n\n');

%% 测试4：跳频 vs 非跳频对比
fprintf('测试4: 跳频 vs 非跳频对比\n');

% 非跳频
p1 = default_params();
p1.fh.enable = false;
p1.sim.ebN0dBList = [6 10];
p1.sim.nFramesPerPoint = 1;
p1.mitigation.methods = "blanking";
p1.source.resizeTo = [32 32];
p1.eve.enable = false;
p1.covert.enable = false;
p1.sim.saveFigures = false;

fprintf('  运行非跳频仿真...\n');
r1 = simulate(p1);

% 跳频
p2 = p1;
p2.fh.enable = true;
fprintf('  运行跳频仿真...\n');
r2 = simulate(p2);

fprintf('\n  结果对比:\n');
fprintf('  Eb/N0(dB)    非跳频BER    跳频BER    非跳频PSNR    跳频PSNR\n');
for i = 1:numel(p1.sim.ebN0dBList)
    fprintf('  %6.1f      %8.4f    %8.4f    %10.1f    %10.1f\n', ...
        p1.sim.ebN0dBList(i), r1.ber(i), r2.ber(i), r1.psnr(i), r2.psnr(i));
end
fprintf('  [通过] 对比测试完成\n\n');

%% 总结
fprintf('========================================\n');
fprintf('所有测试通过!\n');
fprintf('========================================\n');
