addpath(genpath('src'));

candidates = struct([]);

candidates(1).profileName = "impulse";
candidates(1).sampleRateHz = 300e3;
candidates(1).ldpcRate = "1/3";
candidates(1).payloadBitsPerPacket = 5400;
candidates(1).rsK = 3;
candidates(1).rsP = 9;

candidates(2).profileName = "impulse";
candidates(2).sampleRateHz = 450e3;
candidates(2).ldpcRate = "1/3";
candidates(2).payloadBitsPerPacket = 5400;
candidates(2).rsK = 2;
candidates(2).rsP = 11;

candidates(3).profileName = "rayleigh_multipath";
candidates(3).sampleRateHz = 300e3;
candidates(3).ldpcRate = "1/3";
candidates(3).payloadBitsPerPacket = 5400;
candidates(3).rsK = 3;
candidates(3).rsP = 9;

candidates(4).profileName = "rayleigh_multipath";
candidates(4).sampleRateHz = 450e3;
candidates(4).ldpcRate = "1/3";
candidates(4).payloadBitsPerPacket = 5400;
candidates(4).rsK = 2;
candidates(4).rsP = 11;

rows = struct( ...
    'profileName', {}, ...
    'sampleRateHz', {}, ...
    'ldpcRate', {}, ...
    'payloadBitsPerPacket', {}, ...
    'rsK', {}, ...
    'rsP', {}, ...
    'runOk', {}, ...
    'errorMessage', {}, ...
    'nTxPackets', {}, ...
    'burstDurationSec', {});

for i = 1:numel(candidates)
    c = candidates(i);
    p = default_params( ...
        'linkProfileName', c.profileName, ...
        'strictModelLoad', false, ...
        'requireTrainedMlModels', false, ...
        'loadMlModels', strings(1, 0));

    p.waveform.sampleRateHz = c.sampleRateHz;
    p.waveform.symbolRateHz = p.waveform.sampleRateHz / double(p.waveform.sps);
    p.fec.ldpc.rate = c.ldpcRate;
    p.packet.payloadBitsPerPacket = c.payloadBitsPerPacket;
    p.outerRs.dataPacketsPerBlock = c.rsK;
    p.outerRs.parityPacketsPerBlock = c.rsP;

    row = struct();
    row.profileName = c.profileName;
    row.sampleRateHz = c.sampleRateHz;
    row.ldpcRate = c.ldpcRate;
    row.payloadBitsPerPacket = c.payloadBitsPerPacket;
    row.rsK = c.rsK;
    row.rsP = c.rsP;
    row.runOk = false;
    row.errorMessage = "";
    row.nTxPackets = NaN;
    row.burstDurationSec = NaN;

    try
        waveform = resolve_waveform_cfg(p);
        [imgTx, ~] = load_source_image(p.source);
        [payloadBits, meta] = image_to_payload_bits(imgTx, p.payload);
        [~, plan] = build_tx_packets(payloadBits, meta, p, true, waveform);
        txReport = measure_tx_burst(plan.txBurstForChannel, waveform);
        row.runOk = true;
        row.nTxPackets = plan.nPackets;
        row.burstDurationSec = txReport.burstDurationSec;
    catch ME
        row.errorMessage = string(strrep(ME.message, newline, ' | '));
    end

    rows(end + 1) = row; %#ok<AGROW>
end

disp(struct2table(rows));
