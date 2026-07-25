// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface ICurveStableSwap {

    function exchange(
        int128 i,
        int128 j,
        uint256 _dx,
        uint256 _min_dy
    ) external returns (uint256);

}
