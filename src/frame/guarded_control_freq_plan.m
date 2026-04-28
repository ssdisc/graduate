function plan = guarded_control_freq_plan(payloadFreqSet)
%GUARDED_CONTROL_FREQ_PLAN Build dedicated off-payload control FH tones.
%
% The payload FH set uses non-overlapping tones. For the control plane we
% shift each payload tone inward by half the FH spacing so preamble/session
% /PHY-header can live on dedicated frequencies instead of reusing payload
% tones that may be jammed directly.

arguments
    payloadFreqSet (1,:) double
end

freqSet = sort(double(payloadFreqSet(:).'));
if numel(freqSet) < 8
    error("guarded_control_freq_plan requires at least 8 payload FH tones, got %d.", numel(freqSet));
end

spacing = diff(freqSet);
spacing = spacing(spacing > 0);
if isempty(spacing)
    error("guarded_control_freq_plan requires at least two distinct payload FH tones.");
end
spacingRef = min(spacing);
spacingGrid = spacing / spacingRef;
if any(abs(spacingGrid - round(spacingGrid)) > 1e-9)
    error("guarded_control_freq_plan requires the payload FH set to lie on an integer-spaced grid.");
end

controlFreqSet = freqSet - sign(freqSet) * (spacingRef / 2);
controlFreqSet = unique(controlFreqSet, "stable");
controlFreqSet = controlFreqSet(abs(controlFreqSet) > 1e-12);

neg = controlFreqSet(controlFreqSet < 0);
pos = controlFreqSet(controlFreqSet > 0);
if numel(neg) < 4 || numel(pos) < 4
    error("guarded_control_freq_plan could not form enough dedicated control-tone pairs.");
end

plan = struct();
plan.payloadFreqSet = freqSet;
plan.controlOnlyFreqSet = controlFreqSet;
plan.spacing = spacingRef;
plan.preamblePair = [neg(end) pos(1)];
plan.sessionPair = [neg(end - 1) pos(2)];
plan.phyHeaderPair = [neg(1) pos(end)];
plan.reservePair = [neg(2) pos(end - 1)];
end
