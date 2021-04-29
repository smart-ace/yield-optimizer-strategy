//SPDX-License-Identifier: Unlicense
pragma solidity >0.6.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/IStrategy.sol";
import "./interfaces/IPancakeRouter.sol";

/**
 * @dev Implementation of a vault to deposit funds for yield optimizing.
 * This is the contract that receives funds and that users interface with.
 * The yield optimizing strategy itself is implemented in a separate 'Strategy.sol' contract.
 */
contract WaultBtcbVault is ERC20, Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct StratCandidate {
        address implementation;
        uint proposedTime;
    }

    // The last proposed strategy to switch to.
    StratCandidate public stratCandidate; 
    // The strategy currently in use by the vault.
    address public strategy;
    // The token the vault accepts and looks to maximize.
    IERC20 public token;
    address public wault = address(0x6Ff2d9e5891a7a7c554b80e0D1B791483C78BcE9);
    address public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    // The minimum time it has to pass before a strat candidate can be approved.
    uint256 public approvalDelay = 0;

    address public strategist = address(0xC627D743B1BfF30f853AE218396e6d47a4f34ceA);

    bool public enabledWaultReward = true;
    uint256 public startForDistributeWault;
    uint256 public endForDistributeWault;
    uint256 public waultFeeFactor = uint256(1e12);
    // 100 WAULT rewards per month in default
    uint256 public waultRewardPerBlock = uint256(100 ether).div(864000);
    uint256 public lastRewardBlock;
    uint256 public accWaultPerShare;

    address public pancakeRouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address[] public tokenToWaultPath;
    uint256 public swapMinAmount = uint256(1e6);

    // Info of each user
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastClaim;
    }

    // Info of each user in vaults
    mapping (address => UserInfo) public userInfo;

    event NewStratCandidate(address implementation);
    event UpgradeStrat(address implementation);
    event Claim(address indexed user, uint256 amount);

    modifier onlyAdmin {
        require(_msgSender() == owner() || _msgSender() == strategist, "!authorized");
        _;
    }
    
    /**
     * @dev Sets the value of {token} to the token that the vault will
     * hold as underlying value. It initializes the vault's own 'moo' token.
     * This token is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _token the token to maximize.
     */
    constructor (
        address _token
    ) ERC20(
        string(abi.encodePacked("Wault ", ERC20(_token).name())),
        string(abi.encodePacked("wault", ERC20(_token).symbol()))
    ) {
        token = IERC20(_token);

        tokenToWaultPath = [_token, wbnb, wault];

        IERC20(_token).safeApprove(pancakeRouter, uint256(-1));
    }

    function setStrategy(address _strategy) external onlyOwner {
        strategy = _strategy;
    }

    /**
     * @dev It calculates the total underlying value of {token} held by the system.
     * It takes into account the vault contract balance, the strategy contract balance
     *  and the balance deployed in other contracts as part of the strategy.
     */
    function balance() public view returns (uint256) {
        return token.balanceOf(address(this)).add(IStrategy(strategy).wantLockedTotal());
    }

    function balanceOfWault() public view returns (uint256) {
        return IERC20(wault).balanceOf(address(this));
    }

    /**
     * @dev Custom logic in here for how much the vault allows to be borrowed.
     * We return 100% of tokens for now. Under certain conditions we might
     * want to keep some of the system funds at hand in the vault, instead
     * of putting them to work.
     */
    function available() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @dev Function for various UIs to display the current value of one of our yield tokens.
     * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply() == 0 ? 1e18 : balance().mul(1e18).div(totalSupply());
    }

    /**
     * @dev A helper function to call deposit() with all the sender's funds.
     */
    function depositAll() external {
        deposit(token.balanceOf(msg.sender));
    }

    /**
     * @dev The entrypoint of funds into the system. People deposit with this function
     * into the vault. The vault is then in charge of sending funds into the strategy.
     */
    function deposit(uint _amount) public {
        if (enabledWaultReward) {
            _updateRewardRate();
            _updatePendingReward(msg.sender);
        }

        uint256 _pool = balance();
        uint256 _before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _after = token.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint256 shares = 0;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalSupply())).div(_pool);
        }
        _mint(msg.sender, shares);

        earn();

        if (enabledWaultReward) _updateUserInfo(msg.sender, shares, true);
    }

    /**
     * @dev Function to send funds into the strategy and put them to work. It's primarily called
     * by the vault's deposit() function.
     */
    function earn() public {
        uint _bal = available();
        // token.safeTransfer(strategy, _bal);
        token.safeApprove(strategy, _bal);
        IStrategy(strategy).deposit(_bal);
    }

    /**
     * @dev A helper function to call withdraw() with all the sender's funds.
     */
    function withdrawAll() external {
        withdraw(balanceOf(msg.sender));
    }

    /**
     * @dev Function to exit the system. The vault will withdraw the required tokens
     * from the strategy and pay up the token holder. A proportional number of IOU
     * tokens are burned in the process.
     */
    function withdraw(uint256 _shares) public {
        if (enabledWaultReward) {
            _updateRewardRate();
            _updatePendingReward(msg.sender);
        }

        uint256 r = (balance().mul(_shares)).div(totalSupply());
        _burn(msg.sender, _shares);

        uint b = token.balanceOf(address(this));
        if (b < r) {
            uint _withdraw = r.sub(b);
            IStrategy(strategy).withdraw(_withdraw);
            uint _after = token.balanceOf(address(this));
            uint _diff = _after.sub(b);
            if (_diff < _withdraw) {
                r = b.add(_diff);
            }
        }

        uint256 interest = 0;
        if (enabledWaultReward && r >= swapMinAmount && _shares < r.sub(swapMinAmount)) interest = r.sub(_shares);

        token.safeTransfer(msg.sender, r.sub(interest));
        if (interest > 0) {
            _sendAsWault(msg.sender, interest);
        }

        if (enabledWaultReward) _updateUserInfo(msg.sender, _shares, false);
    }

    function claim() public {
        if (!enabledWaultReward) return;

        _updateRewardRate();
        _updatePendingReward(msg.sender);
        UserInfo storage user = userInfo[msg.sender];
        if (user.pendingRewards > 0) {
            uint256 claimedAmount = _safeWaultTransfer(msg.sender, user.pendingRewards);
            emit Claim(msg.sender, claimedAmount);
            user.pendingRewards = user.pendingRewards.sub(claimedAmount);
            user.lastClaim = block.timestamp;
        }
       _updateUserInfo(msg.sender, 0, false);
    }

    function claimable(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 pending = 0;
        if (block.number <= endForDistributeWault
        && block.number >= startForDistributeWault
        && lastRewardBlock != 0
        && totalSupply() > 0) {
            uint256 blocks = block.number.sub(lastRewardBlock);
            uint256 waultReward = blocks.mul(waultRewardPerBlock);
            uint256 currentAccWaultPerShare = accWaultPerShare.add(waultReward.mul(1e12).div(totalSupply()));
            pending = user.amount.mul(currentAccWaultPerShare).div(1e12).sub(user.rewardDebt);
        }
        return user.pendingRewards + pending;
    }

    function _updatePendingReward(address _user) internal {
        if (balanceOf(_user) == 0) return;
        UserInfo storage user = userInfo[_user];

        uint256 pending = user.amount.mul(accWaultPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }
    }

    function _updateUserInfo(address _user, uint256 _amount, bool isDeposit) internal {
        if (block.number > endForDistributeWault || block.number < startForDistributeWault) return;

        UserInfo storage user = userInfo[_user];
        if (isDeposit) user.amount = user.amount.add(_amount);
        else user.amount = user.amount > _amount ? user.amount.sub(_amount) : 0;
        user.rewardDebt = user.amount.mul(accWaultPerShare).div(1e12);
    }

    function _updateRewardRate() internal {
        if (block.number > endForDistributeWault || block.number < startForDistributeWault) return;

        if (lastRewardBlock == 0) {
            lastRewardBlock = block.number;
            return;
        }

        if (totalSupply() > 0) {
            uint256 blocks = block.number.sub(lastRewardBlock);
            uint256 waultReward = blocks.mul(waultRewardPerBlock);
            accWaultPerShare = accWaultPerShare.add(waultReward.mul(1e12).div(totalSupply()));
        }
        lastRewardBlock = block.number;
    }

    function _safeWaultTransfer(address _to, uint256 _amount) internal returns (uint256) {
        uint256 waultBal = balanceOfWault();
        if (_amount > waultBal) {
            _amount = waultBal;
        }
        _amount = _amount > waultFeeFactor ? _amount.sub(waultFeeFactor) : 0;
        if (_amount > 0) IERC20(wault).safeTransfer(_to, _amount);
        return _amount;
    }

    function withdrawWault(uint256 _amount) public onlyAdmin returns (uint256) {
        uint256 waultBal = balanceOfWault();
        if (_amount > waultBal) {
            _amount = waultBal;
        }
        if (_amount > 0) IERC20(wault).safeTransfer(msg.sender, _amount);
        return _amount;
    }

    function _sendAsWault(address _to, uint256 _amount) internal returns (uint256 _out) {
        if (_amount < swapMinAmount) return 0;

        _out = IPancakeRouter(pancakeRouter).swapExactTokensForTokens(
            _amount,
            uint256(0),
            tokenToWaultPath,
            _to,
            block.timestamp.add(1800)
        )[2];
    }

    function setWaultRewardFactors(uint256 _amount, uint256 _start, uint256 _blocks) external onlyAdmin {
        require(_amount > 0, "invalid amount");
        startForDistributeWault = _start;
        endForDistributeWault = _start.add(_blocks);
        waultRewardPerBlock = _amount.div(endForDistributeWault.sub(startForDistributeWault));
    }

    function setWaultFeeFactor(uint256 _factor) external onlyAdmin {
        waultFeeFactor = _factor;
    }

    function setWaultRewardMode(bool _flag) external onlyAdmin {
        enabledWaultReward = _flag;
    }

    function setSwapMinAmount(uint256 _amount) external onlyAdmin {
        swapMinAmount = _amount;
    }

    /** 
     * @dev Sets the candidate for the new strat to use with this vault.
     * @param _implementation The address of the candidate strategy.  
     */
    function proposeStrat(address _implementation) public onlyAdmin {
        stratCandidate = StratCandidate({ 
            implementation: _implementation,
            proposedTime: block.timestamp
         });

        emit NewStratCandidate(_implementation);
    }

    /** 
     * @dev It switches the active strat for the strat candidate. After upgrading, the 
     * candidate implementation is set to the 0x00 address, and proposedTime to a time 
     * happening in +100 years for safety. 
     */

    function upgradeStrat() public onlyAdmin {
        require(stratCandidate.implementation != address(0), "There is no candidate");
        require(stratCandidate.proposedTime.add(approvalDelay) < block.timestamp, "Delay has not passed");
        
        emit UpgradeStrat(stratCandidate.implementation);

        IStrategy(strategy).retireStrat();
        strategy = stratCandidate.implementation;
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;
        
        earn();
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param _token address of the token to rescue.
     */
    function inCaseTokensGetStuck(address _token) external onlyAdmin {
        require(_token != address(token), "!token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }

    function emergencyWithdraw(address _token) external onlyAdmin {
        require(_token == address(token) || _token == wault, "!token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }

    function setApprovalDelay(uint256 _delay) external onlyAdmin {
        approvalDelay = _delay;
    }
}