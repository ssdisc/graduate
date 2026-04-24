addpath(genpath('src'));

centers = [-3 -2 -1.5 -1 2];

cfgs = struct([]);
cfgs(1).name = "k2_p11_sr450k";
cfgs(1).k = 2;
cfgs(1).p = 11;
cfgs(1).sr = 450e3;

cfgs(2).name = "k2_p12_sr500k";
cfgs(2).k = 2;
cfgs(2).p = 12;
cfgs(2).sr = 500e3;

cfgs(3).name = "k2_p12_sr550k";
cfgs(3).k = 2;
cfgs(3).p = 12;
cfgs(3).sr = 550e3;

outDir = fullfile('results', 'narrowband_bad_cfg_search_stage1');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
outCsv = fullfile(outDir, 'stage1_bad_centers.csv');

rows = struct('cfgName', {}, 'k', {}, 'p', {}, 'sampleRateHz', {}, ...
    'centerFreqPoints', {}, 'runOk', {}, 'errorMessage', {}, ...
    'ber', {}, 'rawPer', {}, 'per', {}, ...
    'frontEndSuccess', {}, 'headerSuccess', {}, 'payloadSuccess', {}, ...
    'burstDurationSec', {}, 'simElapsedSec', {});

for ic = 1:numel(cfgs)
    cfg = cfgs(ic);
    fprintf('===== CFG %d/%d: %s (K=%d P=%d SR=%.0fk) =====\n', ...
        ic, numel(cfgs), cfg.name, cfg.k, cfg.p, cfg.sr/1e3);

    for ix = 1:numel(centers)
        center = centers(ix);
        row = struct();
        row.cfgName = string(cfg.name);
        row.k = cfg.k;
        row.p = cfg.p;
        row.sampleRateHz = cfg.sr;
        row.centerFreqPoints = center;
        row.runOk = false;
        row.errorMessage = "";
        row.ber = NaN;
        row.rawPer = NaN;
        row.per = NaN;
        row.frontEndSuccess = NaN;
        row.headerSuccess = NaN;
        row.payloadSuccess = NaN;
        row.burstDurationSec = NaN;
        row.simElapsedSec = NaN;

        fprintf('--- center=%.2f (%d/%d)\n', center, ix, numel(centers));
        tRun = tic;
        try
            p = default_params( ...
                'linkProfileName', 'narrowband', ...
                'strictModelLoad', false, ...
                'requireTrainedMlModels', false, ...
                'loadMlModels', strings(1,0));
            p.sim.nFramesPerPoint = 1;
            p.sim.saveFigures = false;
            p.sim.useParallel = false;
            p.linkBudget.ebN0dBList = 8;
            p.linkBudget.jsrDbList = 0;
            p.mitigation.methods = "fh_erasure";

            p.outerRs.dataPacketsPerBlock = cfg.k;
            p.outerRs.parityPacketsPerBlock = cfg.p;
            p.waveform.sampleRateHz = cfg.sr;
            p.waveform.symbolRateHz = p.waveform.sampleRateHz / double(p.waveform.sps);

            p.channel.narrowband.centerFreqPoints = center;

            r = simulate(p);

            mIdx = find(string(r.methods(:)) == "fh_erasure", 1, 'first');
            if isempty(mIdx)
                error('fh_erasure method not found in results.methods');
            end

            row.runOk = true;
            row.ber = double(r.ber(mIdx, 1));
            row.rawPer = double(r.rawPer(mIdx, 1));
            row.per = double(r.per(mIdx, 1));
            row.frontEndSuccess = double(r.packetDiagnostics.bob.frontEndSuccessRateByMethod(mIdx, 1));
            row.headerSuccess = double(r.packetDiagnostics.bob.headerSuccessRateByMethod(mIdx, 1));
            row.payloadSuccess = double(r.packetDiagnostics.bob.payloadSuccessRate(mIdx, 1));
            row.burstDurationSec = double(r.tx.burstDurationSec);

            fprintf('    OK: PER=%.4f rawPER=%.4f burst=%.3fs header=%.4f\n', ...
                row.per, row.rawPer, row.burstDurationSec, row.headerSuccess);
        catch ME
            row.errorMessage = string(ME.message);
            fprintf('    FAIL: %s\n', ME.message);
        end
        row.simElapsedSec = toc(tRun);

        rows(end + 1) = row; %#ok<AGROW>
        writetable(struct2table(rows), outCsv);
    end
end

T = struct2table(rows);
writetable(T, outCsv);

fprintf('\\nSaved: %s\\n', outCsv);
