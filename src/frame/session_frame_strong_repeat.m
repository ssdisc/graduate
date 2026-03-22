function repeat = session_frame_strong_repeat(frameCfg)
%SESSION_FRAME_STRONG_REPEAT  Bit-level repetition factor for strong session frames.

repeat = 8;
if isfield(frameCfg, "sessionStrongRepeat") && ~isempty(frameCfg.sessionStrongRepeat)
    repeat = round(double(frameCfg.sessionStrongRepeat));
end
if repeat < 2
    error("frame.sessionStrongRepeat must be an integer >= 2, got %g.", repeat);
end
end
