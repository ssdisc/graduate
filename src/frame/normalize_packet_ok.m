function ok = normalize_packet_ok(packetOk, nPacketsLocal)
ok = logical(packetOk(:).');
if numel(ok) < nPacketsLocal
    ok = [ok, false(1, nPacketsLocal - numel(ok))];
elseif numel(ok) > nPacketsLocal
    ok = ok(1:nPacketsLocal);
end
end

