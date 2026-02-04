function seq = chaos_generate(n, method, params)
%CHAOS_GENERATE  生成混沌序列。
%
% 输入:
%   n      - 序列长度
%   method - 混沌映射类型: 'logistic', 'henon', 'tent'
%   params - 参数结构体
%
% 输出:
%   seq    - 混沌序列 (n x 1)，值域 [0, 1]
%
% Logistic映射: x(n+1) = mu * x(n) * (1 - x(n))
%   参数: params.mu (3.57 < mu <= 4), params.x0 (初值)
%
% Henon映射: x(n+1) = 1 - a*x(n)^2 + y(n)
%            y(n+1) = b*x(n)
%   参数: params.a, params.b, params.x0, params.y0
%
% Tent映射: x(n+1) = mu*x(n)        if x(n) < 0.5
%                  = mu*(1-x(n))    if x(n) >= 0.5
%   参数: params.mu (0 < mu <= 2), params.x0

arguments
    n (1,1) double {mustBePositive, mustBeInteger}
    method (1,1) string = "logistic"
    params (1,1) struct = struct()
end

% 设置默认参数
switch lower(method)
    case "logistic"
        if ~isfield(params, 'mu'); params.mu = 3.9999; end
        if ~isfield(params, 'x0'); params.x0 = 0.1234567890123456; end
        seq = logistic_map(n, params.mu, params.x0);

    case "henon"
        if ~isfield(params, 'a'); params.a = 1.4; end
        if ~isfield(params, 'b'); params.b = 0.3; end
        if ~isfield(params, 'x0'); params.x0 = 0.1; end
        if ~isfield(params, 'y0'); params.y0 = 0.1; end
        seq = henon_map(n, params.a, params.b, params.x0, params.y0);

    case "tent"
        if ~isfield(params, 'mu'); params.mu = 1.9999; end
        if ~isfield(params, 'x0'); params.x0 = 0.1234567890123456; end
        seq = tent_map(n, params.mu, params.x0);

    otherwise
        error("未知的混沌映射类型: %s", method);
end

end

%% Logistic映射
function seq = logistic_map(n, mu, x0)
    % 跳过前1000个值以消除瞬态
    transient = 1000;
    total = n + transient;

    x = zeros(total, 1);
    x(1) = x0;

    for i = 2:total
        x(i) = mu * x(i-1) * (1 - x(i-1));
    end

    seq = x(transient+1:end);
end

%% Henon映射
function seq = henon_map(n, a, b, x0, y0)
    transient = 1000;
    total = n + transient;

    x = zeros(total, 1);
    y = zeros(total, 1);
    x(1) = x0;
    y(1) = y0;

    for i = 2:total
        x(i) = 1 - a * x(i-1)^2 + y(i-1);
        y(i) = b * x(i-1);
    end

    % 归一化到[0,1]
    seq = x(transient+1:end);
    seq = (seq - min(seq)) / (max(seq) - min(seq) + eps);
end

%% Tent映射
function seq = tent_map(n, mu, x0)
    transient = 1000;
    total = n + transient;

    x = zeros(total, 1);
    x(1) = x0;

    for i = 2:total
        if x(i-1) < 0.5
            x(i) = mu * x(i-1);
        else
            x(i) = mu * (1 - x(i-1));
        end
        % 防止退化到0或1
        if x(i) < 1e-10
            x(i) = 1e-10;
        elseif x(i) > 1 - 1e-10
            x(i) = 1 - 1e-10;
        end
    end

    seq = x(transient+1:end);
end
