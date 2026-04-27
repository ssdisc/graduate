function profileName = normalize_link_profile_name(rawName)
%NORMALIZE_LINK_PROFILE_NAME  Normalize a link-profile name to the canonical key.

profileName = lower(string(rawName));
if strlength(profileName) == 0
    error("linkProfileName must be a non-empty string scalar.");
end

switch profileName
    case "impulse"
        profileName = "impulse";
    case "narrowband"
        profileName = "narrowband";
    case {"rayleigh_multipath", "rayleigh", "multipath"}
        profileName = "rayleigh_multipath";
    case {"robust_unified", "robust", "unified"}
        profileName = "robust_unified";
    otherwise
        error("Unsupported link profile: %s. Supported profiles: impulse, narrowband, rayleigh_multipath, robust_unified.", ...
            char(rawName));
end
end
