function linkSpec = default_params(opts)
%DEFAULT_PARAMS Build the new linkSpec configuration model.

arguments
    opts.strictModelLoad (1,1) logical = true
    opts.requireTrainedMlModels (1,1) logical = true
    opts.allowBatchModelFallback (1,1) logical = true
    opts.linkProfileName (1,1) string = "narrowband"
    opts.loadMlModels string = ["lr" "cnn" "gru" "selector" "narrowband" "fh_erasure"]
end

linkSpec = default_link_spec( ...
    "strictModelLoad", opts.strictModelLoad, ...
    "requireTrainedMlModels", opts.requireTrainedMlModels, ...
    "allowBatchModelFallback", opts.allowBatchModelFallback, ...
    "linkProfileName", opts.linkProfileName, ...
    "loadMlModels", opts.loadMlModels);
end
