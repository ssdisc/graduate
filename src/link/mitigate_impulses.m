function rOut = mitigate_impulses(rIn, method, mit)
%MITIGATE_IMPULSES  Simple blanking / clipping impulse mitigation.

r = rIn(:);

switch string(mit.thresholdStrategy)
    case "median"
        T = mit.thresholdAlpha * median(abs(r));
    case "fixed"
        T = mit.thresholdFixed;
    otherwise
        error("Unknown thresholdStrategy: %s", mit.thresholdStrategy);
end

switch lower(string(method))
    case "none"
        rOut = r;
    case "blanking"
        rOut = r;
        rOut(abs(r) > T) = 0;
    case "clipping"
        mag = abs(r);
        scale = ones(size(r));
        over = mag > T;
        scale(over) = T ./ mag(over);
        rOut = r .* scale;
    otherwise
        error("Unknown mitigation method: %s", method);
end
end

