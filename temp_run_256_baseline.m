addpath(genpath('src'));
profiles = {"impulse", "narrowband", "rayleigh_multipath"};
for k = 1:numel(profiles)
    rng(1200 + k, 'twister');
    t0 = tic;
    p = default_params('strictModelLoad', false, 'requireTrainedMlModels', false, 'loadMlModels', strings(1,0), 'linkProfileName', profiles{k});
    p.commonTx.source.maxDimension = 256;
    p.linkBudget.ebN0dBList = 6;
    p.linkBudget.jsrDbList = 0;
    p.sim.nFramesPerPoint = 1;
    if profiles{k} == "impulse"
        p.channel.impulseProb = 0.03;
        p.channel.impulseToBgRatio = 50;
    elseif profiles{k} == "narrowband"
        p.channel.narrowband.centerFreqPoints = 0;
        p.channel.narrowband.bandwidthFreqPoints = 1;
    elseif profiles{k} == "rayleigh_multipath"
        p.channel.multipath.pathDelaysSymbols = [0 2 4];
        p.channel.multipath.pathGainsDb = [0 -6 -10];
    end
    r = run_link_profile(p);
    fprintf('profile=%s elapsed=%.3f burst=%.3f per=%.6f rawPer=%.6f ber=%.6f header=%.6f\n', ...
        profiles{k}, toc(t0), double(r.tx.burstDurationSec), double(r.per(1)), double(r.rawPer(1)), double(r.ber(1)), double(r.packetDiagnostics.bob.headerSuccessRate(1)));
end
