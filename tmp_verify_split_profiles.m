addpath(genpath('src'));

outDir = fullfile('results', 'profile_split_verify_20260424');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

narrowbandSummaryPath = fullfile('results', ...
    'scan_narrowband_centers_per_fullsweep_k2p11_sr450k_nf1', ...
    'center_scan_summary.csv');

profileRows = struct( ...
    'profileName', {}, ...
    'source', {}, ...
    'runOk', {}, ...
    'methodLabel', {}, ...
    'ebN0dB', {}, ...
    'ber', {}, ...
    'rawPer', {}, ...
    'per', {}, ...
    'frontEndSuccess', {}, ...
    'headerSuccess', {}, ...
    'payloadSuccess', {}, ...
    'burstDurationSec', {}, ...
    'extraInfo', {});

profileSummary = struct( ...
    'profileName', {}, ...
    'verifiedFrom', {}, ...
    'runOk', {}, ...
    'bestMethodLabel', {}, ...
    'bestPerAt8dB', {}, ...
    'allMethodsPer0At8dB', {}, ...
    'allCentersPer0At8dB', {}, ...
    'maxPerAt8dB', {}, ...
    'burstDurationSec', {}, ...
    'notes', {});

if ~isfile(narrowbandSummaryPath)
    error('Missing narrowband summary: %s', narrowbandSummaryPath);
end

tnb = readtable(narrowbandSummaryPath, 'TextType', 'string');
requiredNbVars = ["runOk", "perFhErasureEbN0_8", "rawPerFhErasureEbN0_8", "centerFreqPoints"];
for k = 1:numel(requiredNbVars)
    if ~ismember(requiredNbVars(k), string(tnb.Properties.VariableNames))
        error('Narrowband summary missing variable: %s', requiredNbVars(k));
    end
end

allNbRunOk = all(logical(tnb.runOk));
maxNbPer = max(double(tnb.perFhErasureEbN0_8));
allNbPer0 = all(abs(double(tnb.perFhErasureEbN0_8)) < 1e-12);

for i = 1:height(tnb)
    row = struct();
    row.profileName = "narrowband";
    row.source = "existing_fullsweep";
    row.runOk = logical(tnb.runOk(i));
    row.methodLabel = "fh_erasure";
    row.ebN0dB = 8;
    row.ber = double(tnb.berFhErasureEbN0_8(i));
    row.rawPer = double(tnb.rawPerFhErasureEbN0_8(i));
    row.per = double(tnb.perFhErasureEbN0_8(i));
    row.frontEndSuccess = double(tnb.frontFhErasureEbN0_8(i));
    row.headerSuccess = double(tnb.headerFhErasureEbN0_8(i));
    row.payloadSuccess = double(tnb.payloadFhErasureEbN0_8(i));
    row.burstDurationSec = 53.78512;
    row.extraInfo = "center=" + string(tnb.centerFreqPoints(i));
    profileRows(end + 1) = row; %#ok<AGROW>
end

nbSummary = struct();
nbSummary.profileName = "narrowband";
nbSummary.verifiedFrom = string(narrowbandSummaryPath);
nbSummary.runOk = allNbRunOk;
nbSummary.bestMethodLabel = "fh_erasure";
nbSummary.bestPerAt8dB = maxNbPer;
nbSummary.allMethodsPer0At8dB = allNbPer0;
nbSummary.allCentersPer0At8dB = allNbPer0;
nbSummary.maxPerAt8dB = maxNbPer;
nbSummary.burstDurationSec = 53.78512;
nbSummary.notes = "-3:0.5:3 full sweep";
profileSummary(end + 1) = nbSummary; %#ok<AGROW>

profilesToRun = ["impulse", "rayleigh_multipath"];
for ip = 1:numel(profilesToRun)
    profileName = profilesToRun(ip);
    fprintf('===== Verify profile: %s =====\n', profileName);

    p = default_params( ...
        'linkProfileName', profileName, ...
        'strictModelLoad', false, ...
        'requireTrainedMlModels', false, ...
        'loadMlModels', strings(1, 0));
    p.sim.nFramesPerPoint = 1;
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
        perNow = double(resultsNow.per(:, 1));
        [bestPer, bestIdx] = min(perNow);
        allPer0 = all(abs(perNow) < 1e-12);

        for im = 1:numel(methodsNow)
            row = struct();
            row.profileName = profileName;
            row.source = "fresh_run";
            row.runOk = true;
            row.methodLabel = methodsNow(im);
            row.ebN0dB = 8;
            row.ber = double(resultsNow.ber(im, 1));
            row.rawPer = double(resultsNow.rawPer(im, 1));
            row.per = double(resultsNow.per(im, 1));
            row.frontEndSuccess = double(resultsNow.packetDiagnostics.bob.frontEndSuccessRateByMethod(im, 1));
            row.headerSuccess = double(resultsNow.packetDiagnostics.bob.headerSuccessRateByMethod(im, 1));
            row.payloadSuccess = double(resultsNow.packetDiagnostics.bob.payloadSuccessRate(im, 1));
            row.burstDurationSec = double(resultsNow.tx.burstDurationSec);
            row.extraInfo = "";
            profileRows(end + 1) = row; %#ok<AGROW>
        end

        summaryRow = struct();
        summaryRow.profileName = profileName;
        summaryRow.verifiedFrom = "fresh_run";
        summaryRow.runOk = true;
        summaryRow.bestMethodLabel = methodsNow(bestIdx);
        summaryRow.bestPerAt8dB = bestPer;
        summaryRow.allMethodsPer0At8dB = allPer0;
        summaryRow.allCentersPer0At8dB = NaN;
        summaryRow.maxPerAt8dB = max(perNow);
        summaryRow.burstDurationSec = double(resultsNow.tx.burstDurationSec);
        summaryRow.notes = "log=" + string(logPath);
        profileSummary(end + 1) = summaryRow; %#ok<AGROW>
    catch ME
        summaryRow = struct();
        summaryRow.profileName = profileName;
        summaryRow.verifiedFrom = "fresh_run";
        summaryRow.runOk = false;
        summaryRow.bestMethodLabel = "";
        summaryRow.bestPerAt8dB = NaN;
        summaryRow.allMethodsPer0At8dB = false;
        summaryRow.allCentersPer0At8dB = NaN;
        summaryRow.maxPerAt8dB = NaN;
        summaryRow.burstDurationSec = NaN;
        summaryRow.notes = string(strrep(ME.message, newline, ' | '));
        profileSummary(end + 1) = summaryRow; %#ok<AGROW>
    end
end

writetable(struct2table(profileRows), fullfile(outDir, 'profile_methods_at_8dB.csv'));
writetable(struct2table(profileSummary), fullfile(outDir, 'profile_summary.csv'));

disp(struct2table(profileSummary));
