function count = session_frame_repeat_count(frameCfg)
%SESSION_FRAME_REPEAT_COUNT  Dedicated session-frame burst count.

count = 3;
if isfield(frameCfg, "sessionFrameRepeatCount") && ~isempty(frameCfg.sessionFrameRepeatCount)
    count = round(double(frameCfg.sessionFrameRepeatCount));
end
if count < 3 || count > 5
    error("frame.sessionFrameRepeatCount must be an integer in [3, 5], got %g.", count);
end
end
