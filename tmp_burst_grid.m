addpath(genpath('src'));
Ks = [2 3];
Ps = [10 11 12 13];
SR = [350e3 400e3 450e3 500e3 550e3];

p0 = default_params('linkProfileName','narrowband', ...
    'strictModelLoad',false, ...
    'requireTrainedMlModels',false, ...
    'loadMlModels',strings(1,0));

[imgTx, ~] = load_source_image(p0.source);
[payloadBits, meta] = image_to_payload_bits(imgTx, p0.payload);

for k = Ks
    for pp = Ps
        for sr = SR
            p = p0;
            p.outerRs.dataPacketsPerBlock = k;
            p.outerRs.parityPacketsPerBlock = pp;
            p.waveform.sampleRateHz = sr;
            p.waveform.symbolRateHz = sr / double(p.waveform.sps);
            [~, plan] = build_tx_packets(payloadBits, meta, p, true, resolve_waveform_cfg(p));
            txBaseReport = measure_tx_burst(plan.txBurstForChannel, resolve_waveform_cfg(p));
            fprintf('K=%d P=%d SR=%.0fk burst=%.3fs nTx=%d\n', ...
                k, pp, sr/1e3, txBaseReport.burstDurationSec, plan.nPackets);
        end
    end
end
