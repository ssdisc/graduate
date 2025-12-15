function outDir = make_results_dir(rootDir)
%MAKE_RESULTS_DIR  Create a timestamped results folder.

ts = datetime("now", "Format", "yyyyMMdd_HHmmss");
outDir = fullfile(rootDir, "matlab_" + string(ts));
if ~exist(outDir, "dir")
    mkdir(outDir);
end
end

