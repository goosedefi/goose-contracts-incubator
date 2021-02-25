// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IHouseChef.sol";
import "./libs/BscConstants.sol";

contract HouseChef is Ownable, ReentrancyGuard, IHouseChef, BscConstants {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of GOOSEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accRewardPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accRewardPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;                 // Address of LP token contract.
        uint256 allocPoint;             // How many allocation points assigned to this pool. GOOSEs to distribute per block.
        uint256 lastRewardBlock;        // Last block number that reward distribution occurs.
        uint256 accRewardPerShare;       // Accumulated reward per share, times 1e12. See below.
        uint256 currentDepositAmount;   // Current total deposit amount in this pool
    }

    // The reward token
    IBEP20 public rewardToken;
    // Reward tokens created per block.
    uint256 public rewardsPerBlock;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when mining starts.
    uint256 public startBlock;

    event Harvest(address indexed user, uint256 amount);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event UpdateEmissionRate(address indexed user, uint256 rewardsPerBlock);

    constructor(
        IBEP20 _stakeToken,
        IBEP20 _rewardToken,
        uint256 _rewardsPerBlock,
        uint256 _startBlock
    ) public {
        rewardToken = _rewardToken;
        rewardsPerBlock = _rewardsPerBlock;
        startBlock = _startBlock;

        poolInfo.push(PoolInfo({
        lpToken : _stakeToken,
        allocPoint : 100,
        lastRewardBlock : startBlock,
        accRewardPerShare : 0,
        currentDepositAmount : 0
        }));

        totalAllocPoint = 100;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) private pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending rewards on frontend.
    function pendingGoose(address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.currentDepositAmount;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            //calculate total rewards based on remaining funds
            uint256 balance = rewardToken.balanceOf(address(this));
            if (balance > 0) {
                uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
                uint256 totalRewards = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
                totalRewards = Math.min(totalRewards, balance);
                accRewardPerShare = accRewardPerShare.add(totalRewards.mul(1e12).div(lpSupply));
            }
        }
        return user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public {
        PoolInfo storage pool = poolInfo[0];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.currentDepositAmount;
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 balance = rewardToken.balanceOf(address(this));
        if(balance == 0){
            pool.lastRewardBlock = block.number;
            return;
        }

        //calculate total rewards based on remaining funds
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 totalRewards = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        totalRewards = Math.min(totalRewards, balance);
        pool.accRewardPerShare = pool.accRewardPerShare.add(totalRewards.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Refill rewards into chef
    function refillRewards(uint256 _amount) override external nonReentrant{
        updatePool();
        rewardToken.safeTransferFrom(address(msg.sender), address(this), _amount);
    }

    // Deposit LP tokens to Chef for GOOSE allocation.
    function deposit(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        updatePool();
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeRewardTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
            pool.currentDepositAmount = pool.currentDepositAmount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Deposit(msg.sender, _amount);
    }

    // Withdraw LP tokens from Chef.
    function withdraw(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool();
        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeRewardTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.currentDepositAmount = pool.currentDepositAmount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Withdraw(msg.sender, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.currentDepositAmount = pool.currentDepositAmount.sub(amount);
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // Safe goose transfer function, just in case if rounding error causes pool to not have enough GOOSEs.
    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 transferAmount = Math.min(balance, _amount);
        if(address(rewardToken) == wbnbAddr){
            //If the reward token is a wrapped native token, we will unwrap it and send native
            IWETH(wbnbAddr).withdraw(transferAmount);
            safeTransferETH(_to, transferAmount);
        }else{
            bool transferSuccess = rewardToken.transfer(_to, transferAmount);
            require(transferSuccess, "safeRewardTransfer: transfer failed");
        }
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'safeTransferETH: ETH_TRANSFER_FAILED');
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _rewardsPerBlock) public onlyOwner {
        updatePool();
        rewardsPerBlock = _rewardsPerBlock;
        emit UpdateEmissionRate(msg.sender, _rewardsPerBlock);
    }

    //New function to trigger harvest for a specific user and pool
    //A specific user address is provided to facilitate aggregating harvests on multiple chefs
    //Also, it is harmless monetary-wise to help someone else harvests
    function harvestFor(address _user) public nonReentrant{
        //Limit to self or delegated harvest to avoid unnecessary confusion
        require(msg.sender == _user || tx.origin == _user, "harvestFor: FORBIDDEN");
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[_user];
        updatePool();
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeRewardTransfer(_user, pending);
                user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
                emit Harvest(_user, pending);
            }
        }
    }
}
