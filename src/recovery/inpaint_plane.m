function planeOut = inpaint_plane(planeIn, missingMask, mode)
known = ~missingMask;
plane = double(planeIn);
if all(known(:))
    planeOut = plane;
    return;
end
if ~any(known(:))
    planeOut = plane;
    return;
end

mode = lower(string(mode));
maxIter = size(plane, 1) + size(plane, 2);

for it = 1:maxIter
    missing = ~known;
    if ~any(missing(:))
        break;
    end

    leftKnown = [known(:, 1), known(:, 1:end-1)];
    rightKnown = [known(:, 2:end), known(:, end)];
    upKnown = [known(1, :); known(1:end-1, :)];
    downKnown = [known(2:end, :); known(end, :)];

    leftVal = [plane(:, 1), plane(:, 1:end-1)];
    rightVal = [plane(:, 2:end), plane(:, end)];
    upVal = [plane(1, :); plane(1:end-1, :)];
    downVal = [plane(2:end, :); plane(end, :)];

    neighCount = double(leftKnown) + double(rightKnown) + double(upKnown) + double(downKnown);
    canFill = missing & (neighCount > 0);
    if ~any(canFill(:))
        break;
    end

    fillVals = zeros(size(plane));
    switch mode
        case "nearest"
            assigned = false(size(plane));
            cand = canFill & leftKnown;
            fillVals(cand) = leftVal(cand);
            assigned = assigned | cand;

            cand = canFill & ~assigned & rightKnown;
            fillVals(cand) = rightVal(cand);
            assigned = assigned | cand;

            cand = canFill & ~assigned & upKnown;
            fillVals(cand) = upVal(cand);
            assigned = assigned | cand;

            cand = canFill & ~assigned & downKnown;
            fillVals(cand) = downVal(cand);
            assigned = assigned | cand;

            rem = canFill & ~assigned;
            if any(rem(:))
                sumVals = double(leftKnown) .* leftVal + double(rightKnown) .* rightVal + ...
                    double(upKnown) .* upVal + double(downKnown) .* downVal;
                fillVals(rem) = sumVals(rem) ./ max(neighCount(rem), 1);
            end

        otherwise % "blend"
            sumVals = double(leftKnown) .* leftVal + double(rightKnown) .* rightVal + ...
                double(upKnown) .* upVal + double(downKnown) .* downVal;
            fillVals(canFill) = sumVals(canFill) ./ max(neighCount(canFill), 1);
    end

    plane(canFill) = fillVals(canFill);
    known(canFill) = true;
end

if any(~known(:))
    fillVal = mean(plane(known));
    plane(~known) = fillVal;
end

planeOut = plane;
end

