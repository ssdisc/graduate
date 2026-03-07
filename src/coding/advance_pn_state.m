function nextInit = advance_pn_state(polynomial, initState, nSamples)
%ADVANCE_PN_STATE  将PN序列状态向前推进指定采样数。

arguments
    polynomial
    initState
    nSamples (1,1) double {mustBeNonnegative, mustBeInteger}
end

if nSamples == 0
    nextInit = uint8(initState(:)).';
    return;
end

[~, nextInit] = pn_generate_bits(polynomial, initState, nSamples);
nextInit = uint8(nextInit(:)).';
end
