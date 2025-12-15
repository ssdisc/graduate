function run_demo()
%RUN_DEMO  Baseline MATLAB simulation for Track 1 (preliminary round).
%
% Usage (from repo root):
%   addpath(genpath('src'));
%   run_demo

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'link')));

p = default_params();

% Quick demo settings (edit as needed)
p.sim.ebN0dBList = 0:2:10;
p.sim.nFramesPerPoint = 1;
p.sim.saveFigures = true;

results = simulate(p);

disp(results.summary);
end
