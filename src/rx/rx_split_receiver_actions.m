function [sampleAction, symbolAction] = rx_split_receiver_actions(profileName, method)
%RX_SPLIT_RECEIVER_ACTIONS Split one receiver method into sample/symbol stages.

profileName = string(profileName);
method = lower(string(method));

sampleAction = "none";
symbolAction = "none";
if method == "none"
    return;
end

if profileName == "robust_unified" && method == "robust_combo"
    sampleAction = "blanking";
    symbolAction = "robust_combo";
    return;
end

sampleActions = ["blanking" "clipping" "ml_blanking" "ml_cnn" "ml_cnn_hard" "ml_gru" "ml_gru_hard" "robust_mixed_sample"];
symbolActions = ["adaptive_notch" "fft_notch" "fft_bandstop" "stft_notch" "fh_erasure" ...
    "narrowband_notch_soft" "narrowband_subband_excision_soft" "narrowband_cnn_residual_soft"];

if any(method == sampleActions)
    sampleAction = method;
    return;
end
if any(method == symbolActions) || profileName == "rayleigh_multipath"
    symbolAction = method;
    return;
end

error("Unsupported receiver method split for %s: %s.", char(profileName), char(method));
end
