function action = rx_primary_header_action(method)
%RX_PRIMARY_HEADER_ACTION Map a receiver method to the action used for protected control decode.

method = lower(string(method));
symbolActions = ["adaptive_notch" "fft_notch" "fft_bandstop" "stft_notch"];
if method == "narrowband_notch_soft"
    action = "fft_bandstop";
    return;
end
if any(method == symbolActions)
    action = method;
else
    action = "none";
end
end
