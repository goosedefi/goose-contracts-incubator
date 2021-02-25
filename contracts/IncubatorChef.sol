// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IMintable.sol";
import "./interfaces/IIncubatorChef.sol";

contract IncubatorChef is Ownable, ReentrancyGuard, IIncubatorChef  {
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
        //   pending reward = (user.amount * pool.accGoosePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGoosePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;                 // Address of LP token contract.
        uint256 allocPoint;             // How many allocation points assigned to this pool. GOOSEs to distribute per block.
        uint256 lastRewardBlock;        // Last block number that GOOSEs distribution occurs.
        uint256 accGoosePerShare;       // Accumulated GOOSEs per share, times 1e12. See below.
        uint256 depositFeeBP;           // Deposit fee in basis points
        uint256 maxDepositAmount;       // Maximum deposit quota (0 means no limit)
        uint256 currentDepositAmount;   // Current total deposit amount in this pool
    }

    // The reward token
    IMintable public goose;
    // Dev address.
    address public devAddress;
    // GOOSE tokens created per block.
    uint256 public goosePerBlock;
    // Bonus multiplier for early goose makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when GOOSE mining starts.
    uint256 public startBlock;

    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 goosePerBlock);

    constructor(
        IMintable _goose,
        address _devAddress,
        address _feeAddress,
        uint256 _goosePerBlock,
        uint256 _startBlock
    ) public {
        goose = _goose;
        devAddress = _devAddress;
        feeAddress = _feeAddress;
        goosePerBlock = _goosePerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) override external onlyOwner {
        require(_depositFeeBP <= 2000, "add: FEES CANNOT EXCEED 20%");
        if (_withUpdate) {
            _massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accGoosePerShare: 0,
            depositFeeBP: _depositFeeBP,
            maxDepositAmount: _maxDepositAmount,
            currentDepositAmount: 0
        }));
    }

    // Update the given pool's GOOSE allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) override external onlyOwner {
        require(_depositFeeBP <= 2000, "add: FEES CANNOT EXCEED 20%");
        if (_withUpdate) {
            _massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].maxDepositAmount = _maxDepositAmount;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending GOOSEs on frontend.
    function pendingGoose(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGoosePerShare = pool.accGoosePerShare;
        uint256 lpSupply = pool.currentDepositAmount;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 gooseReward = multiplier.mul(goosePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accGoosePerShare = accGoosePerShare.add(gooseReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accGoosePerShare).div(1e12).sub(user.rewardDebt);
    }

    function massUpdatePools() override external {
        _massUpdatePools();
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function _massUpdatePools() private {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.currentDepositAmount;
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 gooseReward = multiplier.mul(goosePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        goose.mint(devAddress, gooseReward.div(10));
        goose.mint(address(this), gooseReward);
        pool.accGoosePerShare = pool.accGoosePerShare.add(gooseReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit tokens to chef for GOOSE allocation.
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accGoosePerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeGooseTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
            uint256 depositAmount = _amount.sub(depositFee);

            //Ensure adequate deposit quota if there is a max cap
            if(pool.maxDepositAmount > 0){
                uint256 remainingQuota = pool.maxDepositAmount.sub(pool.currentDepositAmount);
                require(remainingQuota >= depositAmount, "deposit: reached maximum limit");
            }

            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (depositFee > 0) {
                pool.lpToken.safeTransfer(feeAddress, depositFee);
            }
            user.amount = user.amount.add(depositAmount);
            pool.currentDepositAmount = pool.currentDepositAmount.add(depositAmount);
        }
        user.rewardDebt = user.amount.mul(pool.accGoosePerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accGoosePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeGooseTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.currentDepositAmount = pool.currentDepositAmount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accGoosePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.currentDepositAmount = pool.currentDepositAmount.sub(amount);
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe goose transfer function, just in case if rounding error causes pool to not have enough GOOSEs.
    function safeGooseTransfer(address _to, uint256 _amount) internal {
        uint256 gooseBal = goose.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > gooseBal) {
            transferSuccess = goose.transfer(_to, gooseBal);
        } else {
            transferSuccess = goose.transfer(_to, _amount);
        }
        require(transferSuccess, "safeGooseTransfer: transfer failed");
    }

    function setDevAddress(address _devAddress) external {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        devAddress = _devAddress;
        emit SetDevAddress(msg.sender, _devAddress);
    }

    function setFeeAddress(address _feeAddress) override external {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _goosePerBlock) external onlyOwner {
        _massUpdatePools();
        goosePerBlock = _goosePerBlock;
        emit UpdateEmissionRate(msg.sender, _goosePerBlock);
    }

    //New function to trigger harvest for a specific user and pool
    //A specific user address is provided to facilitate aggregating harvests on multiple chefs
    //Also, it is harmless monetary-wise to help someone else harvests
    function harvestFor(uint256 _pid, address _user) public nonReentrant {
        //Limit to self or delegated harvest to avoid unnecessary confusion
        require(msg.sender == _user || tx.origin == _user, "harvestFor: FORBIDDEN");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accGoosePerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeGooseTransfer(_user, pending);
                user.rewardDebt = user.amount.mul(pool.accGoosePerShare).div(1e12);
                emit Harvest(_user, _pid, pending);
            }
        }
    }

    function bulkHarvestFor(uint256[] calldata pidArray, address _user) external {
        uint256 length = pidArray.length;
        for (uint256 index = 0; index < length; ++index) {
            uint256 _pid = pidArray[index];
            harvestFor(_pid, _user);
        }
    }
}
