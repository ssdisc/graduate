function mode = session_transport_mode(frameCfg)
%SESSION_TRANSPORT_MODE  Resolve the configured session-metadata transport mode.

mode = "preshared";
if isfield(frameCfg, "sessionHeaderMode") && strlength(string(frameCfg.sessionHeaderMode)) > 0
    mode = lower(string(frameCfg.sessionHeaderMode));
end

supportedModes = [ ...
    "preshared", ...
    "embedded_each_frame", ...
    "session_frame_repeat", ...
    "session_frame_strong" ...
    ];
if ~any(mode == supportedModes)
    error("Unsupported sessionHeaderMode: %s", string(mode));
end
end
