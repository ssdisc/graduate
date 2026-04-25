addpath(genpath('src'));

outDir = fullfile('results', 'profile_burst_grid_20260425');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

profiles = ["impulse", "rayleigh_multipath"];
sampleRates = [100e3 200e3 300e3 450e3];
ldpcRates = ["1/2" "1/3"];
payloadBitsList = [7200 5400 3600];
rsList = [12 4; 4 8; 3 9; 2 11];

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

for ip = 1:numel(profiles)
    pBase = default_params( ...
        'linkProfileName', profiles(ip), ...
        'strictModelLoad', false, ...
        'requireTrainedMlModels', false, ...
        'loadMlModels', strings(1, 0));
    waveform = resolve_waveform_cfg(pBase);
    [imgTx, ~] = load_source_image(pBase.source);
    [payloadBits, meta] = image_to_payload_bits(imgTx, pBase.payload);

    for isr = 1:numel(sampleRates)
        for il = 1:numel(ldpcRates)
            for ib = 1:numel(payloadBitsList)
                for ir = 1:size(rsList, 1)
                    p = pBase;
                    p.waveform.sampleRateHz = sampleRates(isr);
                    p.waveform.symbolRateHz = p.waveform.sampleRateHz / double(p.waveform.sps);
                    p.fec.ldpc.rate = ldpcRates(il);
                    p.packet.payloadBitsPerPacket = payloadBitsList(ib);
                    p.outerRs.dataPacketsPerBlock = rsList(ir, 1);
                    p.outerRs.parityPacketsPerBlock = rsList(ir, 2);

                    row = struct();
                    row.profileName = profiles(ip);
                    row.sampleRateHz = sampleRates(isr);
                    row.ldpcRate = ldpcRates(il);
                    row.payloadBitsPerPacket = payloadBitsList(ib);
                    row.rsK = rsList(ir, 1);
                    row.rsP = rsList(ir, 2);
                    row.runOk = false;
                    row.errorMessage = "";
                    row.nTxPackets = NaN;
                    row.burstDurationSec = NaN;

                    try
                        waveformNow = resolve_waveform_cfg(p);
                        [~, plan] = build_tx_packets(payloadBits, meta, p, true, waveformNow);
                        txReport = measure_tx_burst(plan.txBurstForChannel, waveformNow);
                        row.runOk = true;
                        row.nTxPackets = plan.nPackets;
                        row.burstDurationSec = txReport.burstDurationSec;
                    catch ME
                        row.errorMessage = string(strrep(ME.message, newline, ' | '));
                    end

                    rows(end + 1) = row; %#ok<AGROW>
                end
            end
        end
    end
end

T = sortrows(struct2table(rows), {'profileName', 'runOk', 'burstDurationSec'}, {'ascend', 'descend', 'ascend'});
writetable(T, fullfile(outDir, 'burst_grid.csv'));
disp(T);
