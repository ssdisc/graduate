function nSym = phy_header_symbol_length(frameCfg, fec)
%PHY_HEADER_SYMBOL_LENGTH  Return the symbol count occupied by the PHY header.

nSym = phy_header_single_symbol_length(frameCfg, fec) * phy_header_diversity_copies(frameCfg);
end
