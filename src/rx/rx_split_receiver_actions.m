function [sampleAction, symbolAction] = rx_split_receiver_actions(profileName, method)
%RX_SPLIT_RECEIVER_ACTIONS Split one receiver method into sample/symbol stages.

profileName = string(profileName);
method = lower(string(method));

sampleAction = "none";
symbolAction = "none";
if method == "none"
    return;
end

sampleActions = ["blanking" "clipping" "ml_blanking" "ml_cnn" "ml_cnn_hard" "ml_gru" "ml_gru_hard"];
symbolActions = ["adaptive_notch" "fft_notch" "fft_bandstop" "stft_notch" "fh_erasure"];

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
