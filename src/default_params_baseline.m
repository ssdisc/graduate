function p = default_params_baseline()
%DEFAULT_PARAMS_BASELINE  论文主线基线配置。

p = default_params();

p.sim.nFramesPerPoint = 5;
p.packet.concealLostPackets = false;

p.channel.multipath.enable = false;
p.channel.doppler.enable = false;
p.channel.pathLoss.enable = false;

p.eve.enable = false;
p.covert.enable = false;

p.mitigation.methods = ["none" "blanking" "clipping" "ml_cnn" "ml_gru"];
end
