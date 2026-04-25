addpath(genpath('src'));

outDir = fullfile('results', 'profile_split_verify_20260424_nf5');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

profilesToRun = ["impulse", "rayleigh_multipath"];
rows = struct( ...
    'profileName', {}, ...
    'methodLabel', {}, ...
    'nFramesPerPoint', {}, ...
    'ebN0dB', {}, ...
    'runOk', {}, ...
    'ber', {}, ...
    'rawPer', {}, ...
    'per', {}, ...
    'frontEndSuccess', {}, ...
    'headerSuccess', {}, ...
    'payloadSuccess', {}, ...
    'burstDurationSec', {}, ...
    'logPath', {});

for ip = 1:numel(profilesToRun)
    profileName = profilesToRun(ip);
    fprintf('===== Verify profile nf5: %s =====\n', profileName);

    p = default_params( ...
        'linkProfileName', profileName, ...
        'strictModelLoad', false, ...
        'requireTrainedMlModels', false, ...
        'loadMlModels', strings(1, 0));
    p.sim.nFramesPerPoint = 5;
    p.sim.saveFigures = false;
    p.sim.useParallel = false;
    p.linkBudget.ebN0dBList = 8;
    p.linkBudget.jsrDbList = 0;
    p.sim.resultsDir = fullfile(outDir, char(profileName));

    validate_link_profile(p);

    logPath = fullfile(outDir, char(profileName) + "_simulate.log");
    try
        simText = evalc('resultsNow = simulate(p);');
        fid = fopen(logPath, 'w');
        if fid < 0
            error('Cannot open log file: %s', logPath);
        end
        fwrite(fid, simText);
        fclose(fid);

        methodsNow = string(resultsNow.methods(:));
        for im = 1:numel(methodsNow)
            row = struct();
            row.profileName = profileName;
            row.methodLabel = methodsNow(im);
            row.nFramesPerPoint = 5;
            row.ebN0dB = 8;
            row.runOk = true;
            row.ber = double(resultsNow.ber(im, 1));
            row.rawPer = double(resultsNow.rawPer(im, 1));
            row.per = double(resultsNow.per(im, 1));
            row.frontEndSuccess = double(resultsNow.packetDiagnostics.bob.frontEndSuccessRateByMethod(im, 1));
            row.headerSuccess = double(resultsNow.packetDiagnostics.bob.headerSuccessRateByMethod(im, 1));
            row.payloadSuccess = double(resultsNow.packetDiagnostics.bob.payloadSuccessRate(im, 1));
            row.burstDurationSec = double(resultsNow.tx.burstDurationSec);
            row.logPath = string(logPath);
            rows(end + 1) = row; %#ok<AGROW>
        end
    catch ME
        row = struct();
        row.profileName = profileName;
        row.methodLabel = "";
        row.nFramesPerPoint = 5;
        row.ebN0dB = 8;
        row.runOk = false;
        row.ber = NaN;
        row.rawPer = NaN;
        row.per = NaN;
        row.frontEndSuccess = NaN;
        row.headerSuccess = NaN;
        row.payloadSuccess = NaN;
        row.burstDurationSec = NaN;
        row.logPath = string(strrep(ME.message, newline, ' | '));
        rows(end + 1) = row; %#ok<AGROW>
    end
end

writetable(struct2table(rows), fullfile(outDir, 'profile_methods_at_8dB_nf5.csv'));
disp(struct2table(rows));
