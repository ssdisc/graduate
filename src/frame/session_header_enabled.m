function tf = session_header_enabled(frameCfg)
%SESSION_HEADER_ENABLED  Whether session metadata is transmitted on-air.

mode = local_session_header_mode(frameCfg);
switch mode
    case "preshared"
        tf = false;
    case {"inline", "legacy_inline"}
        tf = true;
    otherwise
        error("Unsupported sessionHeaderMode: %s", string(mode));
end
end

function mode = local_session_header_mode(frameCfg)
mode = "preshared";
if isfield(frameCfg, "sessionHeaderMode") && strlength(string(frameCfg.sessionHeaderMode)) > 0
    mode = lower(string(frameCfg.sessionHeaderMode));
end
end
