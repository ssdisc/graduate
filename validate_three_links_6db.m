addpath(genpath(fullfile(pwd, 'src')));

timestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
resultsDir = fullfile(pwd, 'results', 'validate_three_links_6db', timestamp);
if ~exist(resultsDir, 'dir')
    mkdir(resultsDir);
end

records = repmat(local_empty_record(), 0, 1);

impulseProbs = [0.01 0.03 0.05];
impulseRatios = [20 50 80];
for prob = impulseProbs
    for ratio = impulseRatios
        caseName = sprintf('prob_%.2f_ratio_%d', prob, ratio);
        p = local_base_profile_cfg("impulse");
        p.channel.impulseProb = prob;
        p.channel.impulseWeight = 1.0;
        p.channel.impulseToBgRatio = ratio;
        records(end + 1, 1) = local_run_case(p, "impulse", caseName, resultsDir); %#ok<SAGROW>
    end
end

narrowbandCenters = -3:1:3;
for center = narrowbandCenters
    caseName = sprintf('center_%+.1f_bw_1.0', center);
    p = local_base_profile_cfg("narrowband");
    p.channel.narrowband.centerFreqPoints = center;
    p.channel.narrowband.bandwidthFreqPoints = 1.0;
    records(end + 1, 1) = local_run_case(p, "narrowband", caseName, resultsDir); %#ok<SAGROW>
end

mpDelays = { ...
    [0 1 2], ...
    [0 2 4], ...
    [0 3 5], ...
    [0 1 3 5]};
mpGains = { ...
    [0 -4 -8], ...
    [0 -6 -10], ...
    [0 -8 -14], ...
    [0 -3 -7 -12]};
for idx = 1:numel(mpDelays)
    caseName = sprintf('delay_%s_gain_%s', strrep(num2str(mpDelays{idx}), '  ', '_'), strrep(num2str(mpGains{idx}), '  ', '_'));
    p = local_base_profile_cfg("rayleigh_multipath");
    p.channel.multipath.pathDelaysSymbols = mpDelays{idx};
    p.channel.multipath.pathGainsDb = mpGains{idx};
    p.channel.multipath.rayleigh = true;
    records(end + 1, 1) = local_run_case(p, "rayleigh_multipath", caseName, resultsDir); %#ok<SAGROW>
end

tbl = struct2table(records);
writetable(tbl, fullfile(resultsDir, 'summary.csv'));

profileNames = ["impulse" "narrowband" "rayleigh_multipath"];
fprintf('\n===== Validation Summary =====\n');
for profileName = profileNames
    rows = tbl.profile == profileName;
    passCount = nnz(tbl.pass(rows));
    totalCount = nnz(rows);
    fprintf('%s: %d/%d pass, max PER=%.6f, max burst=%.3fs, max elapsed=%.3fs\n', ...
        profileName, ...
        passCount, totalCount, ...
        max(tbl.per(rows)), ...
        max(tbl.burstSec(rows)), ...
        max(tbl.elapsedSec(rows)));
end
fprintf('summary.csv: %s\n', fullfile(resultsDir, 'summary.csv'));

function p = local_base_profile_cfg(profileName)
p = default_params( ...
    'linkProfileName', profileName, ...
    'strictModelLoad', false, ...
    'requireTrainedMlModels', false, ...
    'loadMlModels', strings(1, 0));
p.linkBudget.ebN0dBList = 6;
p.linkBudget.jsrDbList = 0;
p.sim.nFramesPerPoint = 1;
p.commonTx.source.useBuiltinImage = true;
end

function rec = local_run_case(p, profileName, caseName, resultsDir)
tStart = tic;
r = simulate(p);
elapsedSec = toc(tStart);
burstSec = double(r.tx.burstDurationSec);
perVal = double(r.per(1));
rawPerVal = double(r.rawPer(1));
berVal = double(r.ber(1));
pass = perVal == 0 && burstSec < 60 && elapsedSec < 60;

fprintf('%s | %-28s | elapsed=%6.3fs burst=%6.3fs per=%8.6f rawPer=%8.6f ber=%10.4g pass=%d\n', ...
    profileName, caseName, elapsedSec, burstSec, perVal, rawPerVal, berVal, pass);

rec = local_empty_record();
rec.profile = string(profileName);
rec.caseName = string(caseName);
rec.elapsedSec = elapsedSec;
rec.burstSec = burstSec;
rec.per = perVal;
rec.rawPer = rawPerVal;
rec.ber = berVal;
rec.frontEndSuccess = double(r.packetDiagnostics.bob.frontEndSuccessRate(1));
rec.headerSuccess = double(r.packetDiagnostics.bob.headerSuccessRate(1));
rec.payloadSuccess = double(r.packetDiagnostics.bob.payloadSuccessRate(1));
rec.pass = logical(pass);
save(fullfile(resultsDir, sprintf('%s_%s.mat', profileName, caseName)), 'r');
end

function rec = local_empty_record()
rec = struct( ...
    'profile', "", ...
    'caseName', "", ...
    'elapsedSec', nan, ...
    'burstSec', nan, ...
    'per', nan, ...
    'rawPer', nan, ...
    'ber', nan, ...
    'frontEndSuccess', nan, ...
    'headerSuccess', nan, ...
    'payloadSuccess', nan, ...
    'pass', false);
end
