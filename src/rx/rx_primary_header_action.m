function action = rx_primary_header_action(method)
%RX_PRIMARY_HEADER_ACTION Map a receiver method to the action used for protected control decode.

method = lower(string(method));
if method == "robust_combo"
    action = "none";
    return;
end
symbolActions = ["adaptive_notch" "fft_notch" "fft_bandstop" "stft_notch"];
if any(method == ["narrowband_notch_soft" "narrowband_subband_excision_soft" "narrowband_cnn_residual_soft"])
    action = "fft_bandstop";
    return;
end
if any(method == symbolActions)
    action = method;
else
    action = "none";
end
end
