addpath(genpath('src'));

tag = "per_fullsweep_k2p11_sr450k_nf1";
logDir = fullfile('results', 'scan_logs');
if ~exist(logDir, 'dir')
    mkdir(logDir);
end
logPath = fullfile(logDir, char(tag) + ".log");

scanCmd = "summaryTable = scan_narrowband_centers(" + ...
    """CenterFreqPoints"", -3:0.5:3, " + ...
    """EbN0dBList"", 8, " + ...
    """Methods"", ""fh_erasure"", " + ...
    """NFramesPerPoint"", 1, " + ...
    """SaveFigures"", false, " + ...
    """Tag"", """ + tag + """);";
scanText = evalc(scanCmd);

fid = fopen(logPath, 'w');
if fid < 0
    error('Cannot open log file: %s', logPath);
end
fwrite(fid, scanText);
fclose(fid);

disp(logPath);
disp(summaryTable(:, {'centerFreqPoints', 'rawPerFhErasureEbN0_8', 'perFhErasureEbN0_8'}));
