// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface ILockedVault {

    function startCooldown(
        uint256 _shares
    ) external;

    function getCooldownStatus(
        address _user
    ) external view returns (uint256 _cooldownEnd, uint256 _windowEnd, uint256 _shares);

    function cooldownDuration() external view returns (uint256);

    function withdrawalWindow() external view returns (uint256);

}
