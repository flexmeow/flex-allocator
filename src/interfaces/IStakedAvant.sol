// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IStakedAvant {

    function cooldownShares(
        uint256 _shares
    ) external returns (uint256 _assets);

    function unstake(
        address _receiver
    ) external;

    function cooldowns(
        address _user
    ) external view returns (uint104 _cooldownEnd, uint152 _underlyingAmount);

    function cooldownDuration() external view returns (uint24);

}
