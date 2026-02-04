function imgOut = arnold_transform(imgIn, iterations, inverse)
%ARNOLD_TRANSFORM  Arnold猫映射图像置乱/逆置乱。
%
% Arnold变换（猫映射）是一种经典的图像置乱方法，具有周期性。
% 对于N×N图像，变换公式为:
%   [x']   [1 1] [x]
%   [y'] = [1 2] [y]  (mod N)
%
% 输入:
%   imgIn      - 输入图像（必须为正方形）
%   iterations - 迭代次数（正整数）
%   inverse    - 是否为逆变换（默认false）
%
% 输出:
%   imgOut     - 置乱/逆置乱后的图像
%
% 注意: Arnold变换具有周期性，对于N×N图像，存在周期T使得
%       经过T次变换后图像恢复原状。

arguments
    imgIn (:,:) {mustBeNumeric}
    iterations (1,1) double {mustBePositive, mustBeInteger} = 1
    inverse (1,1) logical = false
end

[N, M] = size(imgIn);
if N ~= M
    error('Arnold变换要求输入图像为正方形，当前尺寸: %d x %d', N, M);
end

imgOut = imgIn;

% Arnold变换矩阵
A = [1 1; 1 2];
% 逆变换矩阵
A_inv = [2 -1; -1 1];

for iter = 1:iterations
    imgTemp = zeros(N, N, class(imgIn));

    for x = 0:N-1
        for y = 0:N-1
            if inverse
                % 逆变换
                newCoord = mod(A_inv * [x; y], N);
            else
                % 正变换
                newCoord = mod(A * [x; y], N);
            end
            newX = newCoord(1);
            newY = newCoord(2);

            % MATLAB索引从1开始
            imgTemp(newX+1, newY+1) = imgOut(x+1, y+1);
        end
    end

    imgOut = imgTemp;
end

end
