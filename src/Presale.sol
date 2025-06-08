// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title Black (BLK) Token Presale Contract
/// @notice Facilitates a time-bound token presale using USDC with a tiered vesting structure based on user contribution size.
contract Presale is UUPSUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable {
    
    /// @notice The total number of BLK tokens allocated for presale (300 million tokens).
    uint256 public constant MAX_TOKENS_FOR_PRESALE = 300_000_000 * 10**18;

    /// @notice The USDC stablecoin contract on Base.
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice The Black (BLK) token contract address.
    IERC20 public black;

    /// @notice Price of one BLK token in USDC (6 decimals).
    uint256 public tokenPrice;

    /// @notice The total number of tokens sold during the presale.
    uint256 public tokensSold;

    /// @notice Timestamp when the presale begins.
    uint256 public presaleStartTime;

    /// @notice Timestamp when the presale ends.
    uint256 public presaleEndTime;

    /// @notice The cold wallet address.  
    address public coldWallet;

    /// @notice Whether presale has started.
    bool public presaleStarted;

    /// @notice Whether presale has been finalized.
    bool public presaleFinalized;


    /// @notice Struct representing an investor's contribution and token details.
    struct Investor {
        uint256 amountContributed;  // Total USDC contributed by the investor.
        uint256 totalTokens;        // Total tokens the investor is entitled to.
        uint256 tokensClaimed;      // Tokens already claimed by the investor.
    }

    /// @notice Mapping of addresses to their corresponding Investor details.
    mapping(address => Investor) public investors;


    // ======================================================= EVENTS =======================================================

    /// @notice Emitted when the presale is started.
    event PresaleStarted(uint256 indexed _startTime, uint256 indexed _endTime);

    /// @notice Emitted when tokens are purchased during the presale.
    event TokensPurchased(address indexed _investor, uint256 indexed _amountUSDC, uint256 indexed _amountTokens);

    /// @notice Emitted when an investor claims tokens after the presale.
    event TokensClaimed(address indexed _investor, uint256 indexed _tokensClaimed);

    /// @notice Emitted when an investor has claimed all their vested tokens.
    event VestingCompleted(address indexed _investor, uint256 indexed _tokensClaimed);

    /// @notice Emitted when funds are withdrawn from the contract to the cold wallet.
    event FundsWithdrawn(address indexed _coldWallet, uint256 indexed _amount);

    /// @notice Emitted when the Black tokens are rescued from the contract to the cold wallet.
    event TokensRescued(address indexed _coldWallet, uint256 indexed _amount);

    /// @notice Emitted when the presale is finalized.
    event PresaleFinalized(uint256 indexed _timestamp);

    /// @notice Emitted when the presale end time is updated.
    event PresaleEndTimeUpdated(uint256 indexed _newEndTime);

    /// @notice Emitted when the token price is updated.
    event TokenPriceUpdated(uint256 indexed _newTokenPrice);

    /// @notice Emitted when the cold wallet address is updated.
    event ColdWalletUpdated(address indexed _newColdWallet);


    // ======================================================= MODIFIERS =======================================================

    /// @notice Modifier to restrict functions after presale has been finalized.
    modifier notFinalized() {
        require(!presaleFinalized, "Presale already finalized");
        _;
    }


    // ======================================================= CONSTRUCTOR =======================================================

    /// @dev Disables the initialization for implementation contract.
    constructor() {
        _disableInitializers();
    }


    // ======================================================= INITIALIZER =======================================================

    /// @notice Initializes the contract with the address of the Black token and the token price. Can only be called once.
    /// @param _black The address of the Black token.
    /// @param _tokenPrice The price of one BLK token in USDC (6 decimals).
    function initialize(address _black, uint256 _tokenPrice) public initializer {
        require(_black != address(0), "Invalid address");

        __Ownable2Step_init();
        __Pausable_init();

        black = IERC20(_black);
        tokenPrice = _tokenPrice;
    }


    // ======================================================= PRESALE LOGIC =======================================================

    /// @notice Starts the presale with a specified duration.
    /// @param _durationInDays Duration of the presale in days.
    function startPresale(uint256 _durationInDays) external onlyOwner notFinalized {
        require(!presaleStarted && presaleStartTime == 0, "Presale already started");
        require(_durationInDays > 0, "Duration must be greater than 0");

        presaleStartTime = block.timestamp;
        presaleEndTime = block.timestamp + (_durationInDays * 1 days);
        presaleStarted = true;

        emit PresaleStarted(presaleStartTime, presaleEndTime);
    }


    /// @notice Allows users to purchase tokens during the presale period using USDC.
    /// @notice Tokens purchased are subject to a tiered vesting schedule and can only be claimed after the presale ends.
    /// @param _tokensToBuy The number of tokens the user wants to purchase.
    function purchaseTokens(uint256 _tokensToBuy) external whenNotPaused {
        require(block.timestamp >= presaleStartTime && block.timestamp <= presaleEndTime, "Presale not active");
        require(_tokensToBuy >= 1 * 1e18, "Minimum purchase: 1 BLK");
        require(tokensSold + _tokensToBuy <= MAX_TOKENS_FOR_PRESALE, "Exceeds presale cap");
        require(tokensSold + _tokensToBuy <= black.balanceOf(address(this)), "Insufficient BLK tokens available in the contract");

        uint256 usdcAmount = (tokenPrice * _tokensToBuy) / 1e18;
        
        // Limit max USDC contribution per wallet to $6,000 (USDC has 6 decimals)
        require(investors[msg.sender].amountContributed + usdcAmount <= 6000 * 1e6, "Exceeds max contribution");

        // Transfer USDC from buyer to contract
        USDC.transferFrom(msg.sender, address(this), usdcAmount);

        // Update total tokens sold
        tokensSold = tokensSold + _tokensToBuy;

        // Record investor details
        Investor storage investor = investors[msg.sender];
        investor.amountContributed = investor.amountContributed + usdcAmount;
        investor.totalTokens = investor.totalTokens + _tokensToBuy;

        emit TokensPurchased(msg.sender, usdcAmount, _tokensToBuy);
    }


    // ======================================================= CLAIM / VESTING =======================================================

    /// @notice Allows investors to claim their vested tokens after the presale ends.
    function claimTokens() external whenNotPaused {
        uint256 vestedAmount = calculateVestedTokens(msg.sender);
        
        Investor storage investor = investors[msg.sender];
        uint256 claimableAmount = vestedAmount - investor.tokensClaimed;

        require(claimableAmount > 0, "No tokens to claim yet");

        investor.tokensClaimed = investor.tokensClaimed + claimableAmount;

        black.transfer(msg.sender, claimableAmount);

        emit TokensClaimed(msg.sender, claimableAmount);

        // Emit when the investor has claimed all their vested tokens
        if (investor.tokensClaimed == investor.totalTokens) {
            emit VestingCompleted(msg.sender, investor.tokensClaimed);
        }
    }

    /// @notice Calculates currently vested tokens for a given investor.
    /// @param _investor Address of the investor.
    /// @return Number of vested tokens.
    function calculateVestedTokens(address _investor) public view returns (uint256) {
        // Ensure presale has ended
        require(block.timestamp > presaleEndTime, "Presale still ongoing");

        uint256 totalTokens = investors[_investor].totalTokens;
        require(totalTokens > 0, "No tokens allocated");

        uint256 elapsedTime = block.timestamp - presaleEndTime;

        // Tier 1: 100% unlocked immediately after presale ends
        if (totalTokens <= 6000 * 1e18) {
            return totalTokens;
        }

        // Vesting schedules in percentages
        uint8[6] memory tier2Schedule = [15, 15, 20, 20, 15, 15]; // Tier 2
        uint8[6] memory tier3Schedule = [10, 15, 15, 20, 20, 20]; // Tier 3


        // Determine how many full 30-day periods have passed since the presale ended.
        // This value is used to calculate how many vesting periods have unlocked.
        // Capped at 5 to represent a maximum of 6 months (index 0 through 5).
        uint256 month = elapsedTime / 30 days;
        if (month > 5) {
            month = 5; 
        }

        // Sum unlocked percent
        uint256 unlockedPercent = 0;
        uint8[6] memory schedule = totalTokens <= 59999 * 1e18 ? tier2Schedule : tier3Schedule;
        for (uint256 i = 0; i <= month; i++) {
            unlockedPercent = unlockedPercent + schedule[i];
        }

        // Convert percent to basis points
        uint256 unlockedBps = unlockedPercent * 100;

        // Calculate unlocked tokens using basis points
        uint256 unlockedTokens = (totalTokens * unlockedBps) / 10000;

        return unlockedTokens;
    }


    // ======================================================= ADMIN FUNCTIONS =======================================================

    /// @notice Allows the owner to withdraw the USDC balance of the contract to the cold wallet address.
    /// @dev Only the owner can withdraw the funds. The cold wallet address must be set.
    function withdrawFunds() external onlyOwner {
        require(coldWallet != address(0), "Cold wallet address is not set");
        
        uint256 balance = USDC.balanceOf(address(this));
        require(balance > 0, "Insufficient USDC to withdraw");

        bool success = USDC.transfer(coldWallet, balance);
        require(success, "Failed to withdraw USDC");

        emit FundsWithdrawn(coldWallet, balance);
    }

    /// @notice Allows the owner to withdraw Black tokens held by this contract.
    /// @param _amount The number of tokens to withdraw.
    function rescueTokens(uint256 _amount) external onlyOwner {
        require(coldWallet != address(0), "Cold wallet address is not set");

        uint256 contractBalance = black.balanceOf(address(this));
        require(_amount <= contractBalance, "Insufficient BLK tokens in the contract");

        bool success = black.transfer(coldWallet, _amount);
        require(success, "Transfer failed");

        emit TokensRescued(coldWallet, _amount);
    }

    /// @notice Finalizes the presale after the end time.
    /// @dev This function is callable only by the owner once the presale period has ended.
    function finalizePresale() external onlyOwner notFinalized {
        require(block.timestamp > presaleEndTime, "Presale is still ongoing");
        
        presaleFinalized = true;
        presaleEndTime = block.timestamp;

        emit PresaleFinalized(block.timestamp);
    }

    /// @notice Allows the owner to update the presale end time.
    /// @param _endTime The new end time for the presale.
    function updatePresaleEndTime(uint256 _endTime) external onlyOwner notFinalized {
        require(_endTime > block.timestamp, "End time must be in the future");
        presaleEndTime = _endTime;

        emit PresaleEndTimeUpdated(_endTime);
    }

    /// @notice Allows the owner to update the token price.
    /// @param _tokenPrice The new token price in USDC.
    function updateTokenPrice(uint256 _tokenPrice) external onlyOwner notFinalized {
        require(_tokenPrice > 0, "Price must be greater than 0");
        tokenPrice = _tokenPrice;

        emit TokenPriceUpdated(_tokenPrice);
    }

    /// @notice Allows the owner to set the cold wallet address.
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
    /// @dev Called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable.
    /// @param _newImplementation Address of the new implementation to upgrade to.
    function _authorizeUpgrade(address _newImplementation) internal virtual override onlyOwner{ }
}
