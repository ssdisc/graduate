function rxWindow = rx_slice_capture_window(rxCapture, startIdx, stopIdx)
%RX_SLICE_CAPTURE_WINDOW Slice a packet/session window from one or more branches.

startIdx = max(1, round(double(startIdx)));
stopIdx = round(double(stopIdx));
branches = rx_capture_branch_list(rxCapture);
windowBranches = cell(numel(branches), 1);
for idx = 1:numel(branches)
    branch = branches{idx};
    branchLen = numel(branch);
    if startIdx > branchLen || stopIdx < startIdx
        windowBranches{idx} = complex(zeros(1, 1));
        continue;
    end
    stopUse = min(branchLen, stopIdx);
    if stopUse < startIdx
        windowBranches{idx} = complex(zeros(1, 1));
    else
        windowBranches{idx} = branch(startIdx:stopUse);
    end
end
if isscalar(windowBranches)
    rxWindow = windowBranches{1};
else
    rxWindow = windowBranches;
end
end
