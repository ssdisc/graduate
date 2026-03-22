function tf = packet_has_session_header(frameCfg, pktIdx)
%PACKET_HAS_SESSION_HEADER  Whether a data packet carries embedded session metadata.

if nargin < 2
    pktIdx = 1; %#ok<NASGU>
else
    pktIdx = max(1, round(double(pktIdx))); %#ok<NASGU>
end

mode = session_transport_mode(frameCfg);
switch mode
    case "embedded_each_frame"
        tf = true;
    case {"preshared", "session_frame_repeat", "session_frame_strong"}
        tf = false;
    otherwise
        error("Unsupported sessionHeaderMode: %s", string(mode));
end
end
