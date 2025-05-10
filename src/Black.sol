// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract Black is ERC20, Ownable2Step {
    uint256 public constant TOTAL_SUPPLY_CAP = 1_000_000_000 * 10 ** 18;
    uint256 public constant MIN_SUPPLY = 210_000_000 * 10 ** 18;

    // Burn rate in basis points (100 = 1%, 10000 = 100%)
    uint256 public burnRate = 200;

    event BurnRateUpdated(uint256 indexed newRate);

    constructor(address _owner) ERC20("Black", "BLK") Ownable(_owner) {
    }

    /// @notice Allows the owner to set a new burn rate
    function setBurnRate(uint256 newRate) external onlyOwner {
        burnRate = newRate;
        emit BurnRateUpdated(newRate);
    }

    /// @notice Owner can mint new tokens, up to the original cap
    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= TOTAL_SUPPLY_CAP, "Exceeds total supply cap");
        _mint(to, amount);
    }

    /// @notice Allows token holders to burn their own tokens manually
    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    /// @dev Overridden transfer function with burn mechanism
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 burnAmount = (amount * burnRate) / 10_000;
        uint256 sendAmount = amount - burnAmount;

        // Prevent burning below the deflationary cap (210 million)
        if (totalSupply() <= MIN_SUPPLY) {
            burnAmount = 0;  // No burn allowed if we're already at or below the deflationary cap
            sendAmount = amount; // All tokens are sent to the recipient
        } else if (totalSupply() - burnAmount < MIN_SUPPLY) {
            // Adjust burn amount to ensure total supply doesn't drop below the cap
            burnAmount = totalSupply() - MIN_SUPPLY;
            sendAmount = amount - burnAmount;
        }

        // Perform burn if any
        if (burnAmount > 0) {
            _burn(msg.sender, burnAmount);
        }

        // Proceed with the transfer
        _transfer(msg.sender, to, sendAmount);
        return true;
    }

    /// @dev Overridden transferFrom function with burn mechanism
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 burnAmount = (amount * burnRate) / 10_000;
        uint256 sendAmount = amount - burnAmount;

        // Prevent burning below the deflationary cap (210 million)
        if (totalSupply() <= MIN_SUPPLY) {
            burnAmount = 0;  // No burn allowed if we're already at or below the deflationary cap
            sendAmount = amount; // All tokens are sent to the recipient
        } else if (totalSupply() - burnAmount < MIN_SUPPLY) {
            // Adjust burn amount to ensure total supply doesn't drop below the cap
            burnAmount = totalSupply() - MIN_SUPPLY;
            sendAmount = amount - burnAmount;
        }

        // Perform burn if any
        if (burnAmount > 0) {
            _burn(from, burnAmount);
        }

        // Spend the allowance before executing the transfer
        _spendAllowance(from, _msgSender(), amount);

        // Proceed with the transfer
        _transfer(from, to, sendAmount);
        return true;
    }
}
