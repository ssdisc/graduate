function results = simulate(linkSpec)
%SIMULATE Unified top-level orchestrator entry.

arguments
    linkSpec (1,1) struct
end

results = run_link_profile(linkSpec);
end
