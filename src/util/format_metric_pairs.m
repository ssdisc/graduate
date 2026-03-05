function txt = format_metric_pairs(methods, values)
pairs = cell(1, numel(methods));
for k = 1:numel(methods)
    pairs{k} = sprintf('%s=%.3e', char(methods(k)), values(k));
end
txt = strjoin(pairs, ', ');
end

