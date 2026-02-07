function coded = fec_encode(bits, fec)
%FEC_ENCODE  卷积编码。
%
% 输入:
%   bits - 输入比特流
%   fec  - FEC参数结构体
%          .trellis - 卷积码网格结构
%
% 输出:
%   coded - 编码后的比特流

bits = uint8(bits(:) ~= 0);
coded = convenc(bits, fec.trellis);
end

