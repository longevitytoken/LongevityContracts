pragma solidity ^0.4.18;

import './math/SafeMath.sol';
import './LongevityToken.sol';

/**
 * @title LongevityCrowdsale
 * @dev LongevityCrowdsale is a contract for managing a token crowdsale for Longevity project.
 * Crowdsale have phases with start and end timestamps, where investors can make
 * token purchases and the crowdsale will assign them tokens based
 * on a token per ETH rate and bonuses. Collected funds are forwarded to a wallet
 * as they arrive.
 */
contract LongevityCrowdsale {
    using SafeMath for uint256;

    // The token being sold
    LongevityToken public token;

    // External wallet where funds get forwarded
    address public wallet;

    // Crowdsale administrators
    mapping (address => bool) public owners;

    // External bots updating rates
    mapping (address => bool) public bots;

    // USD cents per ETH exchange rate
    uint256 public rateUSDcETH;

    // Phases list, see schedule in constructor
    mapping (uint => Phase) phases;

    // The total number of phases
    uint public totalPhases = 0;

    // Description for each phase
    struct Phase {
        uint256 startTime;
        uint256 endTime;
        uint256 bonusPercent;
    }

    // Minimum Deposit in USD cents
    uint256 public constant minContributionUSDc = 1000;


    // Amount of raised Ethers (in wei).
    uint256 public weiRaised;

    /**
     * event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param bonusPercent free tokens percantage for the phase
     * @param amount amount of tokens purchased
     */
    event TokenPurchase(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 bonusPercent, uint256 amount);

    // event for rate update logging
    event RateUpdate(uint256 rate);

    // event for wallet update
    event WalletSet(address indexed wallet);

    // owners management events
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed removedOwner);

    // bot management events
    event BotAdded(address indexed newBot);
    event BotRemoved(address indexed removedBot);

    // Phase edit events
    event TotalPhasesChanged(uint value);
    event SetPhase(uint index, uint256 _startTime, uint256 _endTime, uint256 _bonusPercent);
    event DelPhase(uint index);

    function LongevityCrowdsale(address _tokenAddress, uint256 _initialRate) public {
        require(_tokenAddress != address(0));
        token = LongevityToken(_tokenAddress);
        rateUSDcETH = _initialRate;
        wallet = msg.sender;
        owners[msg.sender] = true;
        bots[msg.sender] = true;
        phases[0].bonusPercent = 40;
        phases[0].startTime = 1520453700;
        phases[0].endTime = 1520460000;
    }

    /**
     * @dev Update collecting wallet address
     * @param _address The address to send collected funds
     */
    function setWallet(address _address) onlyOwner public {
        wallet = _address;
        WalletSet(_address);
    }


    // fallback function can be used to buy tokens
    function () external payable {
        buyTokens(msg.sender);
    }

    // low level token purchase function
    function buyTokens(address beneficiary) public payable {
        require(beneficiary != address(0));
        require(msg.value != 0);
        require(isInPhase(now));

        uint256 currentBonusPercent = getBonusPercent(now);

        uint256 weiAmount = msg.value;

        require(calculateUSDcValue(weiAmount) >= minContributionUSDc);

        // calculate token amount to be created
        uint256 tokens = calculateTokenAmount(weiAmount, currentBonusPercent);

        // update state
        weiRaised = weiRaised.add(weiAmount);

        token.mint(beneficiary, tokens);
        TokenPurchase(msg.sender, beneficiary, weiAmount, currentBonusPercent, tokens);

        forwardFunds();
    }

    // If phase exists return corresponding bonus for the given date
    // else return 0 (percent)
    function getBonusPercent(uint256 datetime) public view returns (uint256) {
        require(isInPhase(datetime));
        for (uint i = 0; i < totalPhases; i++) {
            if (datetime >= phases[i].startTime && datetime <= phases[i].endTime) {
                return phases[i].bonusPercent;
            }
        }
        return 0;
    }

    // If phase exists for the given date return true
    function isInPhase(uint256 datetime) public view returns (bool) {
        for (uint i = 0; i < totalPhases; i++) {
            if (datetime >= phases[i].startTime && datetime <= phases[i].endTime) {
                return true;
            }
        }
    }

    // set rate
    function setRate(uint256 _rateUSDcETH) public onlyBot {
        // don't allow to change rate more than 10%
        assert(_rateUSDcETH < rateUSDcETH.mul(110).div(100));
        assert(_rateUSDcETH > rateUSDcETH.mul(90).div(100));
        rateUSDcETH = _rateUSDcETH;
        RateUpdate(rateUSDcETH);
    }

    /**
     * @dev Adds administrative role to address
     * @param _address The address that will get administrative privileges
     */
    function addOwner(address _address) onlyOwner public {
        owners[_address] = true;
        OwnerAdded(_address);
    }

    /**
     * @dev Removes administrative role from address
     * @param _address The address to remove administrative privileges from
     */
    function delOwner(address _address) onlyOwner public {
        owners[_address] = false;
        OwnerRemoved(_address);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owners[msg.sender]);
        _;
    }

    /**
     * @dev Adds rate updating bot
     * @param _address The address of the rate bot
     */
    function addBot(address _address) onlyOwner public {
        bots[_address] = true;
        BotAdded(_address);
    }

    /**
     * @dev Removes rate updating bot address
     * @param _address The address of the rate bot
     */
    function delBot(address _address) onlyOwner public {
        bots[_address] = false;
        BotRemoved(_address);
    }

    /**
     * @dev Throws if called by any account other than the bot.
     */
    modifier onlyBot() {
        require(bots[msg.sender]);
        _;
    }

    // calculate deposit value in USD Cents
    function calculateUSDcValue(uint256 _weiDeposit) public view returns (uint256) {

        // wei per USD cent
        uint256 weiPerUSDc = 1 ether/rateUSDcETH;

        // Deposited value converted to USD cents
        uint256 depositValueInUSDc = _weiDeposit.div(weiPerUSDc);
        return depositValueInUSDc;
    }

    // calculates how much tokens will beneficiary get
    // for given amount of wei
    function calculateTokenAmount(uint256 _weiDeposit, uint256 _bonusTokensPercent) public view returns (uint256) {
        uint256 mainTokens = calculateUSDcValue(_weiDeposit);
        uint256 bonusTokens = mainTokens.mul(_bonusTokensPercent).div(100);
        return mainTokens.add(bonusTokens);
    }

    // send ether to the fund collection wallet
    // override to create custom fund forwarding mechanisms
    function forwardFunds() internal {
        wallet.transfer(msg.value);
    }

    //Change number of phases
    function setTotalPhases(uint value) onlyOwner public {
        totalPhases = value;
        TotalPhasesChanged(value);
    }

    // Set phase: index and values
    function setPhase(uint index, uint256 _startTime, uint256 _endTime, uint256 _bonusPercent) onlyOwner public {
        require(index <= totalPhases);
        phases[index] = Phase(_startTime, _endTime, _bonusPercent);
        SetPhase(index, _startTime, _endTime, _bonusPercent);
    }

    // Delete phase
    function delPhase(uint index) onlyOwner public {
        require(index <= totalPhases);
        delete phases[index];
        DelPhase(index);
    }

    // finalizeCrowdsale issues tokens for the Team.
    // Team gets 30/70 of harvested funds then token gets capped (upper emission boundary locked) to totalSupply * 2
    // The token split after finalization will be in % of total token cap:
    // 1. Tokens issued and distributed during pre-ICO and ICO = 35%
    // 2. Tokens issued for the team on ICO finalization = 30%
    // 3. Tokens for future in-app emission = 35%
    function finalizeCrowdsale(address _teamAccount) {
        uint256 soldTokens = token.totalSupply();
        uint256 teamTokens = soldTokens.div(70).mul(30);
        token.mint(_teamAccount, teamTokens);
        token.setCap();
    }
}
