// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.12;

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IIncubatorChef.sol";
import "./interfaces/IHouseChef.sol";
import "./interfaces/IWETH.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/BscConstants.sol";
import "./interfaces/IFeeProcessor.sol";

contract FeeProcessor is Ownable, ReentrancyGuard, BscConstants, IFeeProcessor {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    address public schedulerAddr;
    address public feeHolder;
    IBEP20 public gooseToken;
    IBEP20 public houseToken;
    IHouseChef public houseChef;
    IIncubatorChef public incubatorChef;

    uint16 public feeDevShareBP;
    uint16 public houseShareBP;

    //mapping(InputToken => mapping(OutputToken => path))
    mapping(address => mapping(address => address[])) paths;

    uint256 lastGasTaxTimestamp;

    event ProcessFees(address indexed user, address indexed token, uint256 amount);
    event EmergencyWithdraw(address indexed user, address indexed token, uint256 amount);
    event SetFeeDevShare(address indexed user, uint16 feeDevShareBP);
    event SetSchedulerAddress(address indexed user, address newAddr);
    event ProcessorDeprecate(address indexed user, address newAddr);
    event BurnTokens(address indexed token, uint256 amount);

    constructor(
        address _schedulerAddr,
        address _gooseToken,
        address _houseChef,
        address _houseToken,
        address _feeHolder,
        uint16 _feeDevShareBP,
        uint16 _houseShareBP
    ) public {
        schedulerAddr = _schedulerAddr;
        gooseToken = IBEP20(_gooseToken);
        houseChef = IHouseChef(_houseChef);
        houseToken = IBEP20(_houseToken);
        feeHolder = _feeHolder;
        feeDevShareBP = _feeDevShareBP;
        houseShareBP = _houseShareBP;

        if (address(houseToken) == busdAddr) {
            //Sell Tokens Paths
            paths[wbnbAddr][busdAddr] = [wbnbAddr, busdAddr];
            paths[usdtAddr][busdAddr] = [usdtAddr, busdAddr];
            paths[btcbAddr][busdAddr] = [btcbAddr, wbnbAddr, busdAddr];
            paths[wethAddr][busdAddr] = [wethAddr, wbnbAddr, busdAddr];
            paths[daiAddr][busdAddr] = [daiAddr, busdAddr];
            paths[usdcAddr][busdAddr] = [usdcAddr, busdAddr];
            paths[dotAddr][busdAddr] = [dotAddr, wbnbAddr, busdAddr];
            paths[cakeAddr][busdAddr] = [cakeAddr, wbnbAddr, busdAddr];
            paths[bscxAddr][busdAddr] = [bscxAddr, busdAddr];
            paths[autoAddr][busdAddr] = [autoAddr, wbnbAddr, busdAddr];
            paths[adaAddr][busdAddr] = [adaAddr, wbnbAddr, busdAddr];

            //Buy Goose Path
            paths[busdAddr][address(gooseToken)] = [busdAddr, address(gooseToken)];
        }
    }

    //Late binding call from IncubatorFactory because incubatorChef has not deployed yet during construction
    function setIncubatorChef(address _incubatorChef) override external onlyOwner nonReentrant {
        incubatorChef = IIncubatorChef(_incubatorChef);
    }

    modifier onlyAdmins(){
        require(msg.sender == owner() || msg.sender == schedulerAddr, "onlyAdmins: FORBIDDEN");
        _;
    }

    function setRouterPath(address inputToken, address outputToken, address[] calldata _path, bool overwrite) external onlyOwner {
        address[] storage path = paths[inputToken][outputToken];
        uint256 length = _path.length;
        if (!overwrite) {
            require(length == 0, "setRouterPath: ALREADY EXIST");
        }
        for (uint256 i = 0; i < length; i++) {
            path.push(_path[i]);
        }
    }

    function getRouterPath(address inputToken, address outputToken) private view returns (address[] storage){
        address[] storage path = paths[inputToken][outputToken];
        require(path.length > 0, "getRouterPath: MISSING PATH");
        return path;
    }

    function burnTokens(IBEP20 token) private {
        uint256 balance = token.balanceOf(address(this));
        token.transfer(burnAddr, balance);
        emit BurnTokens(address(token), balance);
    }

    function payGasTax() private {
        //In case of a scheduler breach, limit taxing to at most roughly once a day (timestamp doesn't need to be extremely accurate)
        if(block.timestamp - lastGasTaxTimestamp > 86400){
            uint256 balance = IBEP20(wbnbAddr).balanceOf(address(this));
            uint256 transferAmount = Math.min(balance, 5 ether);
            if(transferAmount > 0){
                IWETH(wbnbAddr).withdraw(transferAmount);
                safeTransferETH(schedulerAddr, transferAmount);
            }
            lastGasTaxTimestamp = block.timestamp;
        }
    }

    function processToken(IBEP20 token) external onlyAdmins nonReentrant returns (bool){

        //Tax some BNB for gas if Scheduler is running low
        if(msg.sender == schedulerAddr && schedulerAddr.balance < 5 ether){
            payGasTax();
        }

        //All EGGs coming in gets burned
        if (address(token) == eggAddr) {
            burnTokens(token);
            return true;
        }

        uint256 balance = token.balanceOf(address(this));

        //Process Dev Fee
        uint256 feeAmount = balance.mul(feeDevShareBP).div(10000);
        token.safeTransfer(feeHolder, feeAmount);

        //Process House Refill
        uint256 houseAmount = balance.mul(houseShareBP).div(10000);
        uint256 finalAmount = houseAmount;
        if (address(token) != address(houseToken)) {
            //Buy houseToken with token, and only spend the bought tokens
            uint256 startAmount = houseToken.balanceOf(address(this));
            token.safeApprove(routerAddr, houseAmount);
            swapTokens(houseAmount, token, houseToken);
            finalAmount = houseToken.balanceOf(address(this)).sub(startAmount);
        }
        houseToken.safeApprove(address(houseChef), finalAmount);
        houseChef.refillRewards(finalAmount);

        //Process Buyback
        uint256 buybackAmount = balance.sub(feeAmount).sub(houseAmount);
        finalAmount = buybackAmount;
        if (address(token) != busdAddr) {
            //Sell tokens for BUSD, and only spend the sold tokens
            uint256 startAmount = IBEP20(busdAddr).balanceOf(address(this));
            token.safeApprove(routerAddr, buybackAmount);
            swapTokens(buybackAmount, token, IBEP20(busdAddr));
            finalAmount = IBEP20(busdAddr).balanceOf(address(this)).sub(startAmount);
        }
        swapTokens(finalAmount, IBEP20(busdAddr), gooseToken);
        //Burn all goose tokens
        burnTokens(gooseToken);

        emit ProcessFees(msg.sender, address(token), balance);
        return true;
    }

    function getTxDeadline() private view returns (uint256){
        return block.timestamp + 60;
    }

    //Given X input tokens, return Y output tokens without concern about minimum/slippage
    function swapTokens(uint256 amount, IBEP20 inputToken, IBEP20 outputToken) private {
        IPancakeRouter02(routerAddr).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            0,
            getRouterPath(address(inputToken), address(outputToken)),
            address(this),
            getTxDeadline()
        );
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'safeTransferETH: ETH_TRANSFER_FAILED');
    }

    //In case of problems or deprecation of houseChef or other problems, withdraw fees instead of continue to refill
    function emergencyWithdraw(IBEP20 token) external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(feeHolder, balance);
        emit EmergencyWithdraw(msg.sender, address(token), balance);
    }

    function setFeeDevShare(uint16 _feeDevShareBP) external onlyOwner nonReentrant {
        feeDevShareBP = _feeDevShareBP;
        emit SetFeeDevShare(msg.sender, _feeDevShareBP);
    }

    function setSchedulerAddr(address newAddr) external onlyOwner nonReentrant{
        schedulerAddr = newAddr;
        emit SetSchedulerAddress(msg.sender, newAddr);
    }

    function upgradeFeeProcessor(address newAddr) external onlyOwner nonReentrant {
        incubatorChef.setFeeAddress(newAddr);
        emit ProcessorDeprecate(msg.sender, newAddr);
    }
}
