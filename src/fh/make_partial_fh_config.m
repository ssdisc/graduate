function fhOut = make_partial_fh_config(fhIn)
% 构造Eve“部分已知”场景：扰动序列种子/频点映射。
fhOut = fhIn;
seqType = "pn";
if isfield(fhOut, "sequenceType")
    seqType = lower(string(fhOut.sequenceType));
end
switch seqType
    case "pn"
        if isfield(fhOut, "pnInit") && ~isempty(fhOut.pnInit)
            fhOut.pnInit = circshift(fhOut.pnInit, 2);
            if all(fhOut.pnInit == 0)
                fhOut.pnInit(1) = 1;
            end
        end
    case {"chaos", "chaotic"}
        if ~isfield(fhOut, "chaosMethod") || strlength(string(fhOut.chaosMethod)) == 0
            fhOut.chaosMethod = "logistic";
        end
        if ~isfield(fhOut, "chaosParams") || ~isstruct(fhOut.chaosParams)
            fhOut.chaosParams = struct();
        end
        chaosMethod = lower(string(fhOut.chaosMethod));
        switch chaosMethod
            case {"logistic", "tent"}
                if ~isfield(fhOut.chaosParams, "x0") || isempty(fhOut.chaosParams.x0)
                    fhOut.chaosParams.x0 = 0.1234567890123456;
                end
                fhOut.chaosParams.x0 = wrap_unit_interval(double(fhOut.chaosParams.x0) + 1e-10);
            case "henon"
                if ~isfield(fhOut.chaosParams, "x0") || isempty(fhOut.chaosParams.x0)
                    fhOut.chaosParams.x0 = 0.1;
                end
                if ~isfield(fhOut.chaosParams, "y0") || isempty(fhOut.chaosParams.y0)
                    fhOut.chaosParams.y0 = 0.1;
                end
                fhOut.chaosParams.x0 = wrap_unit_interval(double(fhOut.chaosParams.x0) + 1e-10);
                fhOut.chaosParams.y0 = wrap_unit_interval(double(fhOut.chaosParams.y0) + 2e-10);
            otherwise
                if isfield(fhOut.chaosParams, "x0") && ~isempty(fhOut.chaosParams.x0)
                    fhOut.chaosParams.x0 = wrap_unit_interval(double(fhOut.chaosParams.x0) + 1e-10);
                end
        end
    otherwise
        if isfield(fhOut, "freqSet") && numel(fhOut.freqSet) > 1
            fhOut.freqSet = circshift(fhOut.freqSet, 1);
        end
end
end

