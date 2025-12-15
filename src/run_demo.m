function run_demo()
%RUN_DEMO  赛道一（初赛）基准MATLAB仿真。
%
% 用法（从仓库根目录）：
%   addpath(genpath('src'));
%   run_demo

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'link')));

p = default_params();

% 快速演示设置（按需修改）
p.sim.ebN0dBList = 0:2:10;
p.sim.nFramesPerPoint = 1;
p.sim.saveFigures = true;

results = simulate(p);

disp(results.summary);
end
