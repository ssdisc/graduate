function channelBank = freeze_rx_diversity_channel_bank(channelIn, rxDiversityCfg)
%FREEZE_RX_DIVERSITY_CHANNEL_BANK Freeze one channel realization per RX branch.

cfg = rx_validate_diversity_cfg(rxDiversityCfg, "rxDiversity");
channelBank = cell(double(cfg.nRx), 1);
for branchIdx = 1:double(cfg.nRx)
    channelBank{branchIdx} = freeze_channel_realization(channelIn);
end
end
