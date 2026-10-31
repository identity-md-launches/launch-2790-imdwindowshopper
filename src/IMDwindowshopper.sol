// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMDwindowshopper
/// @notice Fixed-supply WWW token with standard, fee-free ERC-20 transfers.
/// @dev The immediate deployer receives the entire supply. No admin or post-deployment mint exists.
contract IMDwindowshopper is ERC20 {
    /// @notice One billion tokens expressed in the token's 18-decimal base units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("IMDwindowshopper", "WWW") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
