function tf = session_frame_enabled(frameCfg)
%SESSION_FRAME_ENABLED  Whether session metadata uses a dedicated over-the-air session frame.

mode = session_transport_mode(frameCfg);
tf = any(mode == ["session_frame_repeat", "session_frame_strong"]);
end
