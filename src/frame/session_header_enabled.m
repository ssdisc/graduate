function tf = session_header_enabled(frameCfg)
%SESSION_HEADER_ENABLED  Whether session metadata is transmitted on-air.

tf = session_transport_mode(frameCfg) ~= "preshared";
end
