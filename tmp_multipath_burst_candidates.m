addpath(genpath('src'));

rows = struct( ...
    'sampleRateHz', {}, ...
    'payloadBitsPerPacket', {}, ...
    'rsK', {}, ...
    'rsP', {}, ...
    'symbolsPerHop', {}, ...
    'cpLenSymbols', {}, ...
    'pilotLength', {}, ...
    'runOk', {}, ...
    'errorMessage', {}, ...
    'nTxPackets', {}, ...
    'burstDurationSec', {});

candidates = [ ...
    450e3 5400 2 11 64 12 12; ...
    600e3 5400 2 11 64 16 12; ...
    600e3 5400 2 11 64 16 16; ...
    600e3 5400 1 14 64 16 12; ...
    600e3 5400 2 11 96 16 12; ...
    600e3 5400 2 11 96 16 16; ...
    800e3 3600 2 11 64 16 12];

pBase = default_params( ...
    'linkProfileName', 'rayleigh_multipath', ...
    'strictModelLoad', false, ...
    'requireTrainedMlModels', false, ...
    'loadMlModels', strings(1, 0));

[imgTx, ~] = load_source_image(pBase.source);
[payloadBits, meta] = image_to_payload_bits(imgTx, pBase.payload);

for i = 1:size(candidates, 1)
    c = candidates(i, :);
    p = pBase;
    p.waveform.sampleRateHz = c(1);
    p.waveform.symbolRateHz = p.waveform.sampleRateHz / double(p.waveform.sps);
    p.fec.ldpc.rate = "1/3";
    p.packet.payloadBitsPerPacket = c(2);
    p.outerRs.dataPacketsPerBlock = c(3);
    p.outerRs.parityPacketsPerBlock = c(4);
    p.fh.symbolsPerHop = c(5);
    p.scFde.cpLenSymbols = c(6);
    p.scFde.pilotLength = c(7);

    row = struct();
    row.sampleRateHz = c(1);
    row.payloadBitsPerPacket = c(2);
    row.rsK = c(3);
    row.rsP = c(4);
    row.symbolsPerHop = c(5);
    row.cpLenSymbols = c(6);
    row.pilotLength = c(7);
    row.runOk = false;
    row.errorMessage = "";
    row.nTxPackets = NaN;
    row.burstDurationSec = NaN;

    try
        waveform = resolve_waveform_cfg(p);
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

T = struct2table(rows);
disp(T);
