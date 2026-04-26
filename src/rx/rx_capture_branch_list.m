function branches = rx_capture_branch_list(rxCapture)
%RX_CAPTURE_BRANCH_LIST Normalize a single- or multi-branch RX capture.

if iscell(rxCapture)
    branches = rxCapture(:);
else
    branches = {rxCapture};
end
if isempty(branches)
    error("RX capture must contain at least one branch.");
end
for idx = 1:numel(branches)
    if isempty(branches{idx})
        error("RX capture branch %d is empty.", idx);
    end
    branches{idx} = branches{idx}(:);
end
end
