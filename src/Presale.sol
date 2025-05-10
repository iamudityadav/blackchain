// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title Presale contract
/// @notice This contract handles the presale for Black(BLK) where users can purchase tokens with ETH, and the tokens are subject to a vesting period after the presale ends.
contract Presale is UUPSUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable {

    /// @dev The maximum number of tokens available for presale (300 million Black(BLK)).
    uint256 public constant MAX_TOKENS_FOR_PRESALE = 300_000_000 * 10**18;  // 300 million

    /// @dev The ERC20 token contract for Black(BLK).
    IERC20 public black;

    /// @dev The price per token in ETH.
    uint256 public tokenPrice;

    /// @dev The total number of tokens sold during the presale.
    uint256 public tokensSold;

    /// @dev The start time of the presale.
    uint256 public presaleStartTime;

    /// @dev The end time of the presale.
    uint256 public presaleEndTime;

    /// @dev The duration of the vesting cliff (in days).
    uint256 public vestingCliffDuration = 90 days;  // 3 months cliff after presale ends

    /// @dev The duration of the vesting period after the cliff (in days).
    uint256 public vestingDuration = 365 days;  // 12 months vesting after the cliff

    /// @dev The address where funds (ETH) from the presale are withdrawn to.
    address public coldWallet;

    /// @dev Struct representing an investor's contribution and token details.
    struct Investor {
        uint256 amountContributed;  // Total ETH contributed by the investor
        uint256 totalTokens;        // Total tokens the investor is entitled to
        uint256 tokensClaimed;      // Tokens already claimed by the investor
        uint256 vestingStartTime;   // Time at which the investor's vesting starts
    }

    /// @dev Mapping of addresses to their corresponding Investor details.
    mapping(address => Investor) public investors;

    /// @dev Emitted when the cold wallet address is updated.
    event ColdWalletUpdated(address indexed _coldWallet);

    /// @dev Emitted when funds are withdrawn from the contract to the cold wallet.
    event FundsWithdrawn(address indexed _coldWallet, uint256 indexed _amount);

    /// @dev Emitted when tokens are purchased during the presale.
    event TokensPurchased(address indexed _buyer, uint256 indexed _amountETH, uint256 indexed _amountTokens);

    /// @dev Emitted when an investor claims tokens after the presale.
    event TokensClaimed(address indexed _investor, uint256 indexed _tokensClaimed);

    /// @dev Emitted when the presale end time is updated.
    event PresaleEndTimeUpdated(uint256 indexed _endTime);

    /// @dev Emitted when the vesting cliff duration is updated.
    event CliffDurationUpdated(uint256 indexed _cliffDuration);

    /// @dev Emitted when the vesting duration is updated.
    event VestingDurationUpdated(uint256 indexed _vestingDuration);

    /// @dev Emitted when the token price is updated.
    event TokenPriceUpdated(uint256 indexed _tokenPrice);

    /// @dev Emitted when the presale is finalized.
    event PresaleFinalized(uint256 indexed _timestamp);

    /// @dev Emitted when an investor's vesting starts.
    event VestingStarted(address indexed _investor, uint256 indexed _startTime);

    /// @dev Emitted when an investor has claimed all their vested tokens.
    event VestingCompleted(address indexed investor);


    /// @dev Disables the initialization for implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with the address of the Black token and the initial token price.
    /// @param _black The address of the Black token contract.
    /// @param _tokenPrice The initial price of each token in ETH.
    function initialize(address _black, uint256 _tokenPrice) public initializer {
        require(_black != address(0), "Invalid address");

        __Ownable2Step_init();
        __Pausable_init();

        black = IERC20(_black);
        tokenPrice = _tokenPrice;
        presaleStartTime = block.timestamp;
        presaleEndTime = presaleStartTime + 90 days;  // Presale duration is 90 days
    }

    /// @notice Allows users to purchase tokens during the presale.
    /// @param _tokensToBuy The number of tokens the user wants to purchase.
    /// @dev Only active during the presale period. Tokens are held in the contract and not immediately claimable.
    /// Vesting begins only after the cliff duration ends, which starts counting from the time of purchase.
    function purchaseTokens(uint256 _tokensToBuy) external payable whenNotPaused {
        require(block.timestamp >= presaleStartTime && block.timestamp <= presaleEndTime, "Presale not active");
        require(_tokensToBuy >= 100 * 10**18, "Minimum contribution is 100 BLK");
        require(msg.value == (_tokensToBuy * tokenPrice), "Incorrect ETH sent for token amount");

        require(tokensSold + _tokensToBuy <= MAX_TOKENS_FOR_PRESALE, "Not enough tokens left for presale");
        require(tokensSold + _tokensToBuy <= black.balanceOf(address(this)), "Not enough tokens available in the contract");

        // Update tokens sold
        tokensSold = tokensSold + _tokensToBuy;

        // Record investor details
        Investor storage investor = investors[msg.sender];
        investor.amountContributed = investor.amountContributed + msg.value;
        investor.totalTokens = investor.totalTokens + _tokensToBuy;

        // Set vesting start time if it's the first purchase
        if (investor.vestingStartTime == 0) {
            investor.vestingStartTime = block.timestamp;  // Vesting starts at the time of the first purchase

            emit VestingStarted(msg.sender, block.timestamp);
        }

        emit TokensPurchased(msg.sender, msg.value, _tokensToBuy);
    }

    /// @notice Allows investors to claim their vested tokens after the presale ends.
    /// @dev Investors must wait for the vesting cliff to end before they can claim tokens.
    function claimTokens() external whenNotPaused {
        Investor storage investor = investors[msg.sender];
        require(investor.totalTokens > 0, "No tokens to claim");

        require(block.timestamp > presaleEndTime + vestingCliffDuration, "Vesting cliff has not ended");

        uint256 vestedAmount = calculateVestedTokens(msg.sender);
        uint256 claimableAmount = vestedAmount - investor.tokensClaimed;

        require(claimableAmount > 0, "No tokens to claim yet");

        investor.tokensClaimed = investor.tokensClaimed + claimableAmount;
        black.transfer(msg.sender, claimableAmount);

        emit TokensClaimed(msg.sender, claimableAmount);

        // Emit when the investor has claimed all their vested tokens
        if (investor.tokensClaimed == investor.totalTokens) {
            emit VestingCompleted(msg.sender);
        }
    }

    /// @notice Calculates how many tokens an investor can claim based on the vesting schedule.
    /// @param _investor The address of the investor.
    /// @return The number of tokens the investor can claim.
    /// @dev This takes into account the cliff period and vesting duration.
    function calculateVestedTokens(address _investor) internal view returns (uint256) {
        Investor memory investor = investors[_investor];
        uint256 elapsedTime = block.timestamp - investor.vestingStartTime;
        
        if (elapsedTime < vestingCliffDuration) {
            return 0;  // No tokens vested yet (still in the cliff period)
        }

        uint256 vestingPeriodElapsed = elapsedTime - vestingCliffDuration;
        uint256 vestingAmount = (investor.totalTokens * vestingPeriodElapsed) / vestingDuration;

        return vestingAmount > investor.totalTokens ? investor.totalTokens : vestingAmount;
    }

    /// @notice Allows the owner to withdraw the ETH balance of the contract to a cold wallet address.
    /// @dev Only the owner can withdraw the funds. The cold wallet address must be set.
    function withdrawFunds() external onlyOwner {
        require(coldWallet != address(0), "Cold wallet address is not set");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
            
        payable(coldWallet).transfer(balance);

        emit FundsWithdrawn(coldWallet, balance);
    }

    /// @notice Finalizes the presale by setting the end time to the current block timestamp.
    /// @dev This function is callable only by the owner once the presale period has ended.
    function finalizePresale() external onlyOwner {
        require(block.timestamp > presaleEndTime, "Presale is still ongoing");
        presaleEndTime = block.timestamp;

        emit PresaleFinalized(block.timestamp);
    }

    /// @notice Allows the owner to update the presale end time.
    /// @param _endTime The new end time for the presale.
    function updatePresaleEndTime(uint256 _endTime) external onlyOwner {
        require(_endTime > block.timestamp, "End time must be in the future");
        presaleEndTime = _endTime;

        emit PresaleEndTimeUpdated(_endTime);
    }

    /// @notice Allows the owner to update the cliff duration for the vesting schedule.
    /// @param _cliffDuration The new cliff duration (in days).
    function updateCliffDuration(uint256 _cliffDuration) external onlyOwner {
        vestingCliffDuration = _cliffDuration * 1 days;

        emit CliffDurationUpdated(_cliffDuration);
    }

    /// @notice Allows the owner to update the vesting duration for the tokens.
    /// @param _vestingDuration The new vesting duration (in days).
    function updateVestingDuration(uint256 _vestingDuration) external onlyOwner {
        vestingDuration = _vestingDuration * 1 days;

        emit VestingDurationUpdated(_vestingDuration);
    }

    /// @notice Allows the owner to update the token price.
    /// @param _tokenPrice The new token price in ETH.
    function updateTokenPrice(uint256 _tokenPrice) external onlyOwner {
        require(_tokenPrice > 0, "Price must be greater than 0");
        tokenPrice = _tokenPrice;

        emit TokenPriceUpdated(_tokenPrice);
    }

    /// @notice Allows the owner to set the cold wallet address for ETH withdrawals.
    /// @param _coldWallet The address of the cold wallet.
    function setColdWallet(address _coldWallet) external onlyOwner {
        require(_coldWallet != address(0), "Cold wallet address cannot be zero");
        coldWallet = _coldWallet;
        
        emit ColdWalletUpdated(_coldWallet);
    }

    /// @notice Pauses the contract, disabling presale and claiming functionality.
    /// @dev Only the owner is authorized to perform this action.
    function pauseContract() external onlyOwner {
        _pause();
    }

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable.
    /// @param _newImplementation Address of the new implementation to upgrade to.
    function _authorizeUpgrade(address _newImplementation) internal virtual override onlyOwner{ }
}
