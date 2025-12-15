function outDir = make_results_dir(rootDir)
%MAKE_RESULTS_DIR  创建带时间戳的结果文件夹。

ts = datetime("now", "Format", "yyyyMMdd_HHmmss");
outDir = fullfile(rootDir, "matlab_" + string(ts));
if ~exist(outDir, "dir")
    mkdir(outDir);
end
end

