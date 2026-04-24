addpath(genpath('src'));

centers = [-1.5 -1 2];
cfg = struct();
cfg.name = "k2_p12_sr550k";
cfg.k = 2;
cfg.p = 12;
cfg.sr = 550e3;

outDir = fullfile('results', 'narrowband_bad_cfg_search_stage1');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
outCsv = fullfile(outDir, 'stage1_bad_centers_cfg3_resume.csv');

rows = struct('cfgName', {}, 'k', {}, 'p', {}, 'sampleRateHz', {}, ...
    'centerFreqPoints', {}, 'runOk', {}, 'errorMessage', {}, ...
    'ber', {}, 'rawPer', {}, 'per', {}, ...
    'frontEndSuccess', {}, 'headerSuccess', {}, 'payloadSuccess', {}, ...
    'burstDurationSec', {}, 'simElapsedSec', {}, 'logPath', {});

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
    row.logPath = "";

    fprintf('===== %s center=%.2f (%d/%d) =====\n', cfg.name, center, ix, numel(centers));
    tRun = tic;
    try
        p = default_params( ...
            'linkProfileName', 'narrowband', ...
            'strictModelLoad', false, ...
            'requireTrainedMlModels', false, ...
            'loadMlModels', strings(1, 0));
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

        simText = evalc('r = simulate(p);');
        logName = sprintf('%s_center_%+0.1f.log', char(cfg.name), center);
        logPath = fullfile(outDir, strrep(logName, '.', 'p'));
        fid = fopen(logPath, 'w');
        if fid < 0
            error('Cannot open log file: %s', logPath);
        end
        fwrite(fid, simText);
        fclose(fid);

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
        row.logPath = string(logPath);

        fprintf('OK: PER=%.4f rawPER=%.4f burst=%.3fs header=%.4f\n', ...
            row.per, row.rawPer, row.burstDurationSec, row.headerSuccess);
    catch ME
        row.errorMessage = string(strrep(ME.message, newline, ' | '));
        fprintf('FAIL: %s\n', char(row.errorMessage));
    end

    row.simElapsedSec = toc(tRun);
    rows(end + 1) = row; %#ok<AGROW>
    writetable(struct2table(rows), outCsv);
end

fprintf('Saved: %s\n', outCsv);
