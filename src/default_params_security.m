function p = default_params_security()
%DEFAULT_PARAMS_SECURITY  扩展安全/隐蔽分析配置。

p = default_params();

p.sim.nFramesPerPoint = 3;
p.packet.concealLostPackets = true;

p.channel.multipath.enable = true;

p.eve.enable = true;
p.covert.enable = true;
end
