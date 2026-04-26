function nSample = rx_capture_total_samples(rxCapture)
%RX_CAPTURE_TOTAL_SAMPLES Return the sample length of a normalized RX capture.

branches = rx_capture_branch_list(rxCapture);
nSample = numel(branches{1});
for idx = 2:numel(branches)
    if numel(branches{idx}) ~= nSample
        error("All RX diversity branches must have the same sample length.");
    end
end
end
