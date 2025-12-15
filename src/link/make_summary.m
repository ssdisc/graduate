function s = make_summary(results)
%MAKE_SUMMARY  Produce a compact summary for console display.

s = struct();
s.methods = results.methods;
s.ebN0dB = results.ebN0dB;
s.berAtMaxEbN0 = results.ber(:, end);
s.psnrAtMaxEbN0 = results.psnr(:, end);

if isfield(results, "eve")
    s.eveEbN0dB = results.eve.ebN0dB;
    s.eveBerAtMaxEbN0 = results.eve.ber(:, end);
    s.evePsnrAtMaxEbN0 = results.eve.psnr(:, end);
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    w = results.covert.warden;
    s.wardenPdAtMaxPoint = w.pdEst(end);
    s.wardenPeAtMaxPoint = w.peEst(end);
end

s.spectrum99ObwHz = results.spectrum.bw99Hz;
s.spectralEfficiency = results.spectrum.etaBpsHz;
end
