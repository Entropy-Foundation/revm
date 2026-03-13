// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IERC20Supra {
    function mint(address _to, uint256 _amount) external;
    function burn(address _from, uint256 _amount) external;
    function approveFor(
        address _owner,
        address _spender,
        uint256 _amount
    ) external;
}
