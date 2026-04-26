function [threshold, chosenMetrics, selection] = ml_select_impulse_threshold(p, model, methodName, scores, truth, pfaTarget, opts)
%ML_SELECT_IMPULSE_THRESHOLD Select a sample-level impulse-detector threshold.
% Packet-level policies were removed from the refactored impulse ML front-end
% because they depended on the legacy simulator.

arguments
    p (1,1) struct %#ok<INUSA>
    model (1,1) struct %#ok<INUSA>
    methodName (1,1) string %#ok<INUSA>
    scores
    truth
    pfaTarget (1,1) double {mustBeGreaterThanOrEqual(pfaTarget, 0), mustBeLessThanOrEqual(pfaTarget, 1)}
    opts.policy (1,1) string = "min_pe_under_pfa"
    opts.pfaSlack (1,1) double {mustBeNonnegative} = 0
    opts.maxCandidates (1,1) double {mustBeInteger, mustBePositive} = 257
    opts.beta (1,1) double {mustBePositive} = 2.0
    opts.evalFramesPerPoint (1,1) double {mustBeInteger, mustBePositive} = 2
    opts.evalEbN0dBList double = [6 8 10]
    opts.evalJsrDbList double = 0
    opts.evalRngSeed (1,1) double = NaN
    opts.verbose (1,1) logical = false
end

policy = lower(string(opts.policy));
samplePolicies = ["min_pe_under_pfa", "max_pd_under_pfa", "max_fbeta_under_pfa", "min_pe"];
packetPolicies = ["min_packet_ber", "min_packet_per"];

if any(policy == samplePolicies)
    [threshold, chosenMetrics, selection] = ml_select_threshold_for_pfa(scores, truth, pfaTarget, ...
        "policy", policy, "pfaSlack", opts.pfaSlack, "maxCandidates", opts.maxCandidates, "beta", opts.beta);
    return;
end
if any(policy == packetPolicies)
    error("ml_select_impulse_threshold:PacketPolicyDisabled", ...
        "Packet-level threshold policy %s is disabled in the refactored impulse ML front-end. Use a sample-level policy.", ...
        char(policy));
end
error("ml_select_impulse_threshold:UnsupportedPolicy", ...
    "Unsupported impulse threshold policy: %s.", char(policy));
end
