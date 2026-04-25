addpath(genpath('src'));

outDir = fullfile('results', 'tmp_multipath_burst_sweep_20260425');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

sampleRates = [300e3 450e3 600e3 800e3];
payloadBitsList = [5400 3600];
rsList = [3 9; 2 11; 1 14; 1 20];
scFdeList = [ ...
    64 8 8; ...
    64 12 12; ...
    64 16 12; ...
    64 16 16; ...
    80 16 12; ...
    96 16 12; ...
    96 16 16];

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

pBase = default_params( ...
    'linkProfileName', 'rayleigh_multipath', ...
    'strictModelLoad', false, ...
    'requireTrainedMlModels', false, ...
    'loadMlModels', strings(1, 0));

[imgTx, ~] = load_source_image(pBase.source);
[payloadBits, meta] = image_to_payload_bits(imgTx, pBase.payload);

for isr = 1:numel(sampleRates)
    for ip = 1:numel(payloadBitsList)
        for ir = 1:size(rsList, 1)
            for ic = 1:size(scFdeList, 1)
                p = pBase;
                p.waveform.sampleRateHz = sampleRates(isr);
                p.waveform.symbolRateHz = p.waveform.sampleRateHz / double(p.waveform.sps);
                p.fec.ldpc.rate = "1/3";
                p.packet.payloadBitsPerPacket = payloadBitsList(ip);
                p.outerRs.dataPacketsPerBlock = rsList(ir, 1);
                p.outerRs.parityPacketsPerBlock = rsList(ir, 2);
                p.fh.symbolsPerHop = scFdeList(ic, 1);
                p.scFde.cpLenSymbols = scFdeList(ic, 2);
                p.scFde.pilotLength = scFdeList(ic, 3);

                row = struct();
                row.sampleRateHz = sampleRates(isr);
                row.payloadBitsPerPacket = payloadBitsList(ip);
                row.rsK = rsList(ir, 1);
                row.rsP = rsList(ir, 2);
                row.symbolsPerHop = scFdeList(ic, 1);
                row.cpLenSymbols = scFdeList(ic, 2);
                row.pilotLength = scFdeList(ic, 3);
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
        end
    end
end

T = struct2table(rows);
T = sortrows(T, {'runOk', 'burstDurationSec', 'sampleRateHz'}, {'descend', 'ascend', 'ascend'});
writetable(T, fullfile(outDir, 'multipath_burst_grid.csv'));
disp(T(T.runOk & T.burstDurationSec < 60, :));
