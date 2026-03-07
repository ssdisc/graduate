function [bits, nextState] = pn_generate_bits(polynomial, initState, nSamples)
%PN_GENERATE_BITS  使用Fibonacci LFSR生成PN比特，并返回推进后的状态。

arguments
    polynomial
    initState
    nSamples (1,1) double {mustBeNonnegative, mustBeInteger}
end

coeff = uint8(polynomial(:).' ~= 0);
state = uint8(initState(:).' ~= 0);
m = numel(state);

if numel(coeff) ~= m + 1
    error("PN多项式长度应为寄存器长度+1，当前为%d和%d。", numel(coeff), m);
end
if coeff(1) ~= 1 || coeff(end) ~= 1
    error("PN多项式首项和常数项必须为1。");
end

tapIdx = find(coeff(2:end-1) ~= 0);
bits = zeros(nSamples, 1, "uint8");

for k = 1:nSamples
    bits(k) = state(end);
    feedback = state(end);
    for t = tapIdx
        feedback = bitxor(feedback, state(t));
    end
    state = [feedback, state(1:end-1)];
end

nextState = state;
end
