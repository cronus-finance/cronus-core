// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

/**
 * @title Stable Cronus Staking
 * @author Cronus devs
 * @notice StableCronusStaking is a contract that allows CRN deposits and receives stablecoins sent by MoneyMaker's daily
 * harvests. Users deposit CRN and receive a share of what has been sent by MoneyMaker based on their participation of
 * the total deposited CRN. It is similar to a MasterChef, but we allow for claiming of different reward tokens
 * (in case at some point we wish to change the stablecoin rewarded).
 * Every time `updateReward(token)` is called, We distribute the balance of that tokens as rewards to users that are
 * currently staking inside this contract, and they can claim it using `withdraw(0)`
 */
contract StableCronusStaking is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Info of each user
    struct UserInfo {
        uint256 amount;
        mapping(IERC20 => uint256) rewardDebt;
        /**
         * @notice We do some fancy math here. Basically, any point in time, the amount of CRNs
         * entitled to a user but is pending to be distributed is:
         *
         *   pending reward = (user.amount * accRewardPerShare) - user.rewardDebt[token]
         *
         * Whenever a user deposits or withdraws CRN. Here's what happens:
         *   1. accRewardPerShare (and `lastRewardBalance`) gets updated
         *   2. User receives the pending reward sent to his/her address
         *   3. User's `amount` gets updated
         *   4. User's `rewardDebt[token]` gets updated
         */
    }

    IERC20 public CRN;

    /// @dev Internal balance of CRN, this gets updated on user deposits / withdrawals
    /// this allows to reward users with CRN
    uint256 public internalCronusBalance;

    /// @notice Array of tokens that users can claim
    IERC20[] public rewardTokens;

    /// @notice used to check a reward token is valid 
    mapping(IERC20 => uint256) tokenIndex;

    /// @notice Last reward balance of `token`
    mapping(IERC20 => uint256) public lastRewardBalance;

    address public feeCollector;

    /// @notice The deposit fee, scaled to `DEPOSIT_FEE_PERCENT_PRECISION`
    uint256 public depositFeePercent;

    /// @notice Accumulated `token` rewards per share, scaled to `ACC_REWARD_PER_SHARE_PRECISION`
    mapping(IERC20 => uint256) public accRewardPerShare;

    /// @dev Info of each user that stakes CRN
    mapping(address => UserInfo) private userInfo;

    /// @notice The precision of `depositFeePercent`
    uint256 public constant DEPOSIT_FEE_PERCENT_PRECISION = 1e18;

    /// @notice The precision of `accRewardPerShare`
    uint256 public constant ACC_REWARD_PER_SHARE_PRECISION = 1e24;

    /// @notice Emitted when a user deposits CRN
    event Deposit(address indexed user, uint256 amount, uint256 fee);

    /// @notice Emitted when owner changes the deposit fee percentage
    event DepositFeeChanged(uint256 newFee, uint256 oldFee);

    /// @notice Emitted when a user withdraws CRN
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims reward
    event RewardClaimed(address indexed user, address indexed rewardToken, uint256 amount);

    /// @notice Emitted when a user emergency withdraws its CRN
    event EmergencyWithdraw(address indexed user, uint256 amount);

    /// @notice Emitted when owner adds a token to the reward tokens list
    event RewardTokenAdded(address token, uint256 index);

    /// @notice Emitted when owner removes a token from the reward tokens list
    event RewardTokenRemoved(address token);

    /**
     * @dev This contract needs to receive an ERC20 `_rewardToken` in order to distribute them
     * (with MoneyMaker in our case)
     * @param _rewardToken The address of the ERC20 reward token
     * @param _crn The address of the CRN token
     * @param _feeCollector The address where deposit fees will be sent
     * @param _depositFeePercent The deposit fee percent, scalled to 1e18, e.g. 3% is 3e16
     */
    constructor(
        IERC20 _rewardToken,
        IERC20 _crn,
        address _feeCollector,
        uint256 _depositFeePercent
    ) public {
        require(address(_rewardToken) != address(0), "StableCronusStaking: reward token can't be address(0)");
        require(address(_crn) != address(0), "StableCronusStaking: crn can't be address(0)");
        require(_feeCollector != address(0), "StableCronusStaking: fee collector can't be address(0)");
        require(_depositFeePercent <= 5e17, "StableCronusStaking: max deposit fee can't be greater than 50%");

        CRN = _crn;
        depositFeePercent = _depositFeePercent;
        feeCollector = _feeCollector;

        rewardTokens.push(_rewardToken);
        tokenIndex[_rewardToken] = rewardTokens.length;
    }

    /**
     * @notice Deposit CRN for reward token allocation
     * @param _amount The amount of CRN to deposit
     */
    function deposit(uint256 _amount) external {
        UserInfo storage user = userInfo[_msgSender()];

        uint256 _fee = _amount.mul(depositFeePercent).div(DEPOSIT_FEE_PERCENT_PRECISION);
        uint256 _amountMinusFee = _amount.sub(_fee);

        uint256 _previousAmount = user.amount;
        uint256 _newAmount = user.amount.add(_amountMinusFee);
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20 _token = rewardTokens[i];
            updateReward(_token);

            uint256 _previousRewardDebt = user.rewardDebt[_token];
            user.rewardDebt[_token] = _newAmount.mul(accRewardPerShare[_token]).div(ACC_REWARD_PER_SHARE_PRECISION);

            if (_previousAmount != 0) {
                uint256 _pending = _previousAmount
                    .mul(accRewardPerShare[_token])
                    .div(ACC_REWARD_PER_SHARE_PRECISION)
                    .sub(_previousRewardDebt);
                if (_pending != 0) {
                    safeTokenTransfer(_token, _msgSender(), _pending);
                    emit RewardClaimed(_msgSender(), address(_token), _pending);
                }
            }
        }

        internalCronusBalance = internalCronusBalance.add(_amountMinusFee);
        CRN.safeTransferFrom(_msgSender(), feeCollector, _fee);
        CRN.safeTransferFrom(_msgSender(), address(this), _amountMinusFee);
        emit Deposit(_msgSender(), _amountMinusFee, _fee);
    }

    /**
     * @notice Get user info
     * @param _user The address of the user
     * @param _rewardToken The address of the reward token
     * @return The amount of CRN user has deposited
     * @return The reward debt for the chosen token
     */
    function getUserInfo(address _user, IERC20 _rewardToken) external view returns (uint256, uint256) {
        UserInfo storage user = userInfo[_user];
        return (user.amount, user.rewardDebt[_rewardToken]);
    }

    /**
     * @notice Get the number of reward tokens
     * @return The length of the array
     */
    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    /**
     * @notice Add a reward token
     * @param _rewardToken The address of the reward token
     */
    function addRewardToken(IERC20 _rewardToken) external onlyOwner {
        uint256 valueIndex = tokenIndex[_rewardToken]; // 0 index is reserve as null identifier
        require(valueIndex, "StableCronusStaking: rewardToken already exists.");
        
        rewardTokens.push(_rewardToken);
        tokenIndex[_rewardToken] = rewardTokens.length;
        
        updateReward(_rewardToken);
        emit RewardTokenAdded(address(_rewardToken), rewardTokens.length);
    }

    /**
     * @notice Remove a reward token
     * @param _rewardToken The address of the reward token
     */
    function removeRewardToken(IERC20 _rewardToken) external onlyOwner {
        uint256 valueIndex = tokenIndex[_rewardToken];
        require(valueIndex, "StableCronusStaking: rewardToken does not exist.");
        
        updateReward(_rewardToken);
        
        uint256 toDeleteIndex = tokenIndex[_rewardToken] - 1;
        uint256 lastIndex = rewardTokens.length - 1;
        
        if (lastIndex != toDeleteIndex) {
            address lastValue = rewardTokens[lastIndex];
            rewardTokens[toDeleteIndex] = lastValue;    // update last value to the removed value
            tokenIndex[lastValue] = valueIndex;    // update index
        }
        
        rewardTokens.pop();
        delete tokenIndex[_rewardToken];
        
        emit RewardTokenRemoved(address(_rewardToken));
    }

    /**
     * @notice Set the deposit fee percent
     * @param _depositFeePercent The new deposit fee percent
     */
    function setDepositFeePercent(uint256 _depositFeePercent) external onlyOwner {
        require(_depositFeePercent <= 5e17, "StableCronusStaking: deposit fee can't be greater than 50%");
        uint256 oldFee = depositFeePercent;
        depositFeePercent = _depositFeePercent;
        emit DepositFeeChanged(_depositFeePercent, oldFee);
    }

    /**
     * @notice View function to see pending reward token on frontend
     * @param _user The address of the user
     * @param _token The address of the token
     * @return `_user`'s pending reward token
     */
    function pendingReward(address _user, IERC20 _token) external view returns (uint256) {
        require(tokenIndex[_token] != 0, "StableCronusStaking: wrong reward token");
        UserInfo storage user = userInfo[_user];
        uint256 _totalCrn = internalCronusBalance;
        uint256 _accRewardTokenPerShare = accRewardPerShare[_token];

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == CRN ? _currRewardBalance.sub(_totalCrn) : _currRewardBalance;

        if (_rewardBalance != lastRewardBalance[_token] && _totalCrn != 0) {
            uint256 _accruedReward = _rewardBalance.sub(lastRewardBalance[_token]);
            _accRewardTokenPerShare = _accRewardTokenPerShare.add(
                _accruedReward.mul(ACC_REWARD_PER_SHARE_PRECISION).div(_totalCrn)
            );
        }
        return
            user.amount.mul(_accRewardTokenPerShare).div(ACC_REWARD_PER_SHARE_PRECISION).sub(user.rewardDebt[_token]);
    }

    /**
     * @notice Withdraw CRN and harvest the rewards
     * @param _amount The amount of CRN to withdraw
     */
    function withdraw(uint256 _amount) external {
        UserInfo storage user = userInfo[_msgSender()];
        uint256 _previousAmount = user.amount;
        require(_amount <= _previousAmount, "StableCronusStaking: withdraw amount exceeds balance");
        uint256 _newAmount = user.amount.sub(_amount);
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        if (_previousAmount != 0) {
            for (uint256 i; i < _len; i++) {
                IERC20 _token = rewardTokens[i];
                updateReward(_token);

                uint256 _pending = _previousAmount
                    .mul(accRewardPerShare[_token])
                    .div(ACC_REWARD_PER_SHARE_PRECISION)
                    .sub(user.rewardDebt[_token]);
                user.rewardDebt[_token] = _newAmount.mul(accRewardPerShare[_token]).div(ACC_REWARD_PER_SHARE_PRECISION);

                if (_pending != 0) {
                    safeTokenTransfer(_token, _msgSender(), _pending);
                    emit RewardClaimed(_msgSender(), address(_token), _pending);
                }
            }
        }

        internalCronusBalance = internalCronusBalance.sub(_amount);
        CRN.safeTransfer(_msgSender(), _amount);
        emit Withdraw(_msgSender(), _amount);
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY
     */
    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[_msgSender()];

        uint256 _amount = user.amount;
        user.amount = 0;
        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20 _token = rewardTokens[i];
            user.rewardDebt[_token] = 0;
        }
        internalCronusBalance = internalCronusBalance.sub(_amount);
        CRN.safeTransfer(_msgSender(), _amount);
        emit EmergencyWithdraw(_msgSender(), _amount);
    }

    /**
     * @notice Update reward variables
     * @param _token The address of the reward token
     * @dev Needs to be called before any deposit or withdrawal
     */
    function updateReward(IERC20 _token) public {
        require(tokenIndex[_token] != 0, "StableCronusStaking: wrong reward token");

        uint256 _totalCrn = internalCronusBalance;

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == CRN ? _currRewardBalance.sub(_totalCrn) : _currRewardBalance;

        // Did StableCronusStaking receive any token
        if (_rewardBalance == lastRewardBalance[_token] || _totalCrn == 0) {
            return;
        }

        uint256 _accruedReward = _rewardBalance.sub(lastRewardBalance[_token]);

        accRewardPerShare[_token] = accRewardPerShare[_token].add(
            _accruedReward.mul(ACC_REWARD_PER_SHARE_PRECISION).div(_totalCrn)
        );
        lastRewardBalance[_token] = _rewardBalance;
    }

    /**
     * @notice Safe token transfer function, just in case if rounding error
     * causes pool to not have enough reward tokens
     * @param _token The address of then token to transfer
     * @param _to The address that will receive `_amount` `rewardToken`
     * @param _amount The amount to send to `_to`
     */
    function safeTokenTransfer(
        IERC20 _token,
        address _to,
        uint256 _amount
    ) internal {
        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == CRN ? _currRewardBalance.sub(internalCronusBalance) : _currRewardBalance;

        if (_amount > _rewardBalance) {
            lastRewardBalance[_token] = lastRewardBalance[_token].sub(_rewardBalance);
            _token.safeTransfer(_to, _rewardBalance);
        } else {
            lastRewardBalance[_token] = lastRewardBalance[_token].sub(_amount);
            _token.safeTransfer(_to, _amount);
        }
    }
}