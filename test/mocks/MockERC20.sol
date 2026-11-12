// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Plain mintable ERC-20 with configurable decimals, for tests only.
contract MockERC20 is ERC20 {
    uint8 private immutable i_decimals;

    constructor(uint8 decimals_) ERC20("Mock", "MOCK") {
        i_decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IPoolReserves {
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
}

/// Behaves like a token with transfer hooks (ERC-777 style): in the middle of every transfer that
/// involves the pool it records the reserves the pool reports at that moment.
contract SnoopingToken is ERC20 {
    address public pool;
    uint256 public reserve0WhenPaidOut;
    uint256 public reserve1WhenPaidOut;
    uint256 public reserve0WhenPulledIn;
    uint256 public reserve1WhenPulledIn;

    constructor() ERC20("Snoop", "SNP") {}

    function setPool(address pool_) external {
        pool = pool_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (pool == address(0) || from == address(0)) return;
        if (from == pool) {
            reserve0WhenPaidOut = IPoolReserves(pool).reserve0();
            reserve1WhenPaidOut = IPoolReserves(pool).reserve1();
        }
        if (to == pool) {
            reserve0WhenPulledIn = IPoolReserves(pool).reserve0();
            reserve1WhenPulledIn = IPoolReserves(pool).reserve1();
        }
    }
}

/// A malicious token that tries to call back into the pool in the middle of a transfer.
contract ReentrantToken is ERC20 {
    address public pool;
    bytes public attack;
    bool public attacked;
    bytes public revertData;

    constructor() ERC20("Reenter", "RE") {}

    function arm(address pool_, bytes calldata attack_) external {
        pool = pool_;
        attack = attack_;
        attacked = false;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (pool != address(0) && !attacked && (from == pool || to == pool)) {
            attacked = true;
            (bool ok, bytes memory data) = pool.call(attack);
            if (ok) revert("reentrancy succeeded");
            revertData = data;
        }
    }
}
