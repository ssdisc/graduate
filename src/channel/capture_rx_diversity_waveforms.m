function [rxCapture, chState] = capture_rx_diversity_waveforms(tx, N0, channelBank, rxDiversityCfg)
%CAPTURE_RX_DIVERSITY_WAVEFORMS Capture one waveform per RX branch.

cfg = rx_validate_diversity_cfg(rxDiversityCfg, "rxDiversity");
if ~iscell(channelBank) || numel(channelBank) ~= double(cfg.nRx)
    error("RX diversity channel bank must contain %d branches.", double(cfg.nRx));
end

rxBranches = cell(double(cfg.nRx), 1);
branchStates = cell(double(cfg.nRx), 1);
for branchIdx = 1:double(cfg.nRx)
    [rxBranches{branchIdx}, ~, branchStates{branchIdx}] = channel_bg_impulsive(tx, N0, channelBank{branchIdx});
end

rxCapture = rxBranches;
chState = branchStates{1};
chState.rxDiversity = cfg;
chState.branchStates = branchStates;
chState.channelBank = channelBank;
end
