// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "./libs/IBEP20.sol";
import "./IncubatorChef.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./libs/PancakeLibrary.sol";

import "./interfaces/IMintable.sol";
import "./interfaces/ITokenFactory.sol";
import "./interfaces/IHouseFactory.sol";
import "./interfaces/IFeeProcessorFactory.sol";
import "./interfaces/IIncubatorChefFactory.sol";
import "./interfaces/IIncubatorChef.sol";
import "./interfaces/IFeeProcessor.sol";
import "./libs/BscConstants.sol";
import "./FeeProcessor.sol";

contract LayerFactory is Ownable, ReentrancyGuard, BscConstants {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    struct LayerInfo {
        uint256 layerId;
        IIncubatorChef chef;
        IMintable token;
        address house;
        IFeeProcessor feeProcessor;
        uint256 createdAt;
        address createdBy;
    }

    LayerInfo[] public layers;
    address public timelock;
    address public schedulerAddr;
    address public gooseHolder;
    address public feeHolder;
    ITokenFactory public tokenFactory;
    IHouseFactory public houseFactory;
    IFeeProcessorFactory public feeProcessorFactory;
    IIncubatorChefFactory public incubatorChefFactory;

    IBEP20 public houseToken = IBEP20(busdAddr);
    uint256 public houseEmitRate = 1.5 ether;

    uint256 public totalMint = 20000 ether;
    uint256 public pricePerGoose = 1;

    uint16 public feeDevShareBP = 1000;
    uint16 public houseShareBP = 3000;

    address[] busdToBnbPath = [busdAddr, wbnbAddr];

    event CreateNewLayer(address indexed user, uint256 indexed layerId);
    event AddLiquidity(uint256 indexed layerId, address indexed gooseToken, address indexed priceToken, uint256 gooseAmount, uint256 priceAmount);
    event RemoveLiquidity(uint256 indexed layerId, address indexed gooseToken, address indexed priceToken, uint256 lpAmount);
    event SetFeeHolder(address indexed user, address feeHolder);
    event SetGooseHolder(address indexed user, address gooseHolder);
    event SetScheduler(address indexed user, address scheduler);
    event StartTimelock(address indexed user, uint256 indexed layerId);
    event UpdateNewLayerSettings(address indexed user);
    event FundsWithdraw(address indexed user, address indexed token, uint256 amount);

    constructor(
        address _schedulerAddr,
        address _feeHolder,
        address _gooseHolder,
        address _timelock,
        address _tokenFactory,
        address _houseFactory,
        address _feeProcessorFactory,
        address _incubatorChefFactory
    ) public {
        schedulerAddr = _schedulerAddr;
        feeHolder = _feeHolder;
        gooseHolder = _gooseHolder;
        timelock = _timelock;
        tokenFactory = ITokenFactory(_tokenFactory);
        houseFactory = IHouseFactory(_houseFactory);
        feeProcessorFactory = IFeeProcessorFactory(_feeProcessorFactory);
        incubatorChefFactory = IIncubatorChefFactory(_incubatorChefFactory);
    }

    modifier onlyAdmins(){
        require(msg.sender == owner() || msg.sender == schedulerAddr, "onlyAdmins: FORBIDDEN");
        _;
    }

    function layerCount() external view returns (uint256) {
        return layers.length;
    }

    function spawnNewToken(uint256 layerId, string calldata tokenName, string calldata tokenSymbol) private returns (IMintable){
        IMintable token = IMintable(tokenFactory.createNewToken(layerId, tokenName, tokenSymbol));
        require(address(token) != address(0), "createNewLayer: error token address");
        return token;
    }

    function getBnbBalance() private view returns (uint256){
        return IBEP20(wbnbAddr).balanceOf(address(this));
    }

    function getTxDeadline() private view returns (uint256){
        return block.timestamp + 60;
    }

    function addLiquidityBusd(uint256 layerId, IMintable token) private {
        uint256 tokenAmount = totalMint.div(2);
        IBEP20(token).safeApprove(routerAddr, tokenAmount);
        uint256 busdAmount = tokenAmount.mul(pricePerGoose);
        IBEP20(busdAddr).safeApprove(routerAddr, busdAmount);
        IPancakeRouter01(routerAddr).addLiquidity(address(token), busdAddr, tokenAmount, busdAmount, 0, 0, address(this), getTxDeadline());

        emit AddLiquidity(layerId, address(token), busdAddr, tokenAmount, busdAmount);
    }

    function addLiquidityBnb(uint256 layerId, IMintable token) private {
        address factory = IPancakeRouter01(routerAddr).factory();
        (uint reserveBusd, uint reserveBnb) = PancakeLibrary.getReserves(factory, busdAddr, wbnbAddr);

        uint256 tokenAmount = totalMint.div(2);
        IBEP20(token).safeApprove(routerAddr, tokenAmount);
        uint256 busdAmount = tokenAmount.mul(pricePerGoose);
        uint256 expectedBnbAmount = PancakeLibrary.quote(busdAmount, reserveBusd, reserveBnb);
        if (expectedBnbAmount > getBnbBalance()) {
            uint256 missingAmount = expectedBnbAmount - getBnbBalance();
            uint256 missingBUSDAmount = PancakeLibrary.quote(missingAmount, reserveBnb, reserveBusd);
            IBEP20(busdAddr).safeApprove(routerAddr, missingBUSDAmount);
            IPancakeRouter02(routerAddr).swapExactTokensForTokensSupportingFeeOnTransferTokens(missingBUSDAmount, 0, busdToBnbPath, address(this), getTxDeadline());
        }
        uint256 bnbAmount = Math.min(getBnbBalance(), expectedBnbAmount);
        IBEP20(wbnbAddr).safeApprove(routerAddr, bnbAmount);
        IPancakeRouter01(routerAddr).addLiquidity(address(token), wbnbAddr, tokenAmount, bnbAmount, 0, 0, address(this), getTxDeadline());

        emit AddLiquidity(layerId, address(token), wbnbAddr, tokenAmount, bnbAmount);
    }

    function spawnNewHouse(uint256 layerId, IMintable token, uint256 _startBlock) private returns (address){
        address house = houseFactory.createNewHouse(layerId, token, houseToken, houseEmitRate, _startBlock);
        require(address(house) != address(0), "spawnNewHouse: error house address");
        return house;
    }

    function spawnNewFeeProcessor(uint256 layerId, address houseChef, address gooseToken) private returns (IFeeProcessor){
        IFeeProcessor feeProcessor = feeProcessorFactory.createNewFeeProcessor(
            layerId,
            schedulerAddr,
            gooseToken,
            houseChef,
            address(houseToken),
            feeHolder,
            feeDevShareBP,
            houseShareBP
        );
        require(address(feeProcessor) != address(0), "spawnNewFeeProcessor: error feeProcessor address");
        return feeProcessor;
    }

    function spawnNewChef(uint256 layerId, IMintable token, address feeProcessor, uint256 _tokenPerBlock, uint256 _startBlock) private returns (IIncubatorChef){
        IIncubatorChef chef = incubatorChefFactory.createNewIncubatorChef(
            layerId,
            token,
            gooseHolder,
            feeProcessor,
            _tokenPerBlock,
            _startBlock
        );
        require(address(chef) != address(0), "spawnNewChef: error feeProcessor address");
        return chef;
    }

    function createNewLayer(uint256 _tokenPerBlock, uint256 _startBlock, string calldata tokenName, string calldata tokenSymbol) external onlyAdmins nonReentrant {
        uint256 layerId = layers.length;

        //Create a new token for new layer
        IMintable token = spawnNewToken(layerId, tokenName, tokenSymbol);
        token.mint(address(this), totalMint);

        //Provide initial liquidity
        addLiquidityBusd(layerId, token);
        addLiquidityBnb(layerId, token);

        //Create a new HouseChef for farming BUSD with deposit fees
        address house = spawnNewHouse(layerId, token, _startBlock);

        //Create a new fee handler
        IFeeProcessor feeProcessor = spawnNewFeeProcessor(layerId, house, address(token));

        //Create a new IncubatorChef for new layer
        IIncubatorChef chef = spawnNewChef(layerId, token, address(feeProcessor), _tokenPerBlock, _startBlock);

        //Give IncubatorChef ownership of token for minting rewards
        Ownable(address(token)).transferOwnership(address(chef));

        //Inform the FeeProcessor about the IncubatorChef address
        feeProcessor.setIncubatorChef(address(chef));

        //FeeProcessor is to be owned by deployer
        Ownable(address(feeProcessor)).transferOwnership(owner());

        layers.push(LayerInfo({
        layerId : layerId,
        chef : chef,
        token : token,
        house : house,
        feeProcessor : feeProcessor,
        createdAt : block.timestamp,
        createdBy : msg.sender
        }));

        emit CreateNewLayer(msg.sender, layerId);
    }

    modifier validLayer(uint256 layerId) {
        require(layerId < layers.length, "IncubatorFactory: Invalid Layer");
        _;
    }

    function removeBUSDLiquidity(uint256 layerId) external onlyAdmins validLayer(layerId) nonReentrant {
        LayerInfo storage layerInfo = layers[layerId];
        address factory = IPancakeRouter01(routerAddr).factory();
        address gooseToken = address(layerInfo.token);
        address lpToken = PancakeLibrary.pairFor(factory, gooseToken, busdAddr);
        uint256 balance = IBEP20(lpToken).balanceOf(address(this));
        IBEP20(lpToken).safeApprove(routerAddr, balance);
        IPancakeRouter01(routerAddr).removeLiquidity(gooseToken, busdAddr, balance, 0, 0, address(this), getTxDeadline());

        emit RemoveLiquidity(layerId, gooseToken, busdAddr, balance);
    }

    function removeWBNBLiquidity(uint256 layerId) external onlyAdmins validLayer(layerId) nonReentrant {
        LayerInfo storage layerInfo = layers[layerId];
        address factory = IPancakeRouter01(routerAddr).factory();
        address gooseToken = address(layerInfo.token);
        address lpToken = PancakeLibrary.pairFor(factory, gooseToken, wbnbAddr);
        uint256 balance = IBEP20(lpToken).balanceOf(address(this));
        IBEP20(lpToken).safeApprove(routerAddr, balance);
        IPancakeRouter01(routerAddr).removeLiquidity(gooseToken, wbnbAddr, balance, 0, 0, address(this), getTxDeadline());

        emit RemoveLiquidity(layerId, gooseToken, wbnbAddr, balance);
    }

    function addPool(uint256 layerId, uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) external onlyAdmins validLayer(layerId) nonReentrant {
        LayerInfo storage layerInfo = layers[layerId];
        layerInfo.chef.add(_allocPoint, _lpToken, _depositFeeBP, _maxDepositAmount, _withUpdate);
    }

    function setPool(uint256 layerId, uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) external onlyAdmins validLayer(layerId) nonReentrant {
        LayerInfo storage layerInfo = layers[layerId];
        layerInfo.chef.set(_pid, _allocPoint, _depositFeeBP, _maxDepositAmount, _withUpdate);
    }

    function massUpdatePools(uint256 layerId) external onlyAdmins validLayer(layerId) nonReentrant {
        LayerInfo storage layerInfo = layers[layerId];
        layerInfo.chef.massUpdatePools();
    }

    //Transfer ownership of IncubatorChef and HouseChef to timelock
    function startTimelock(uint256 layerId) external onlyAdmins validLayer(layerId) nonReentrant {
        LayerInfo storage layerInfo = layers[layerId];
        Ownable(address(layerInfo.chef)).transferOwnership(timelock);
        Ownable(address(layerInfo.house)).transferOwnership(timelock);

        emit StartTimelock(msg.sender, layerId);
    }

    function setGooseHolder(address newAddr) external nonReentrant {
        require(msg.sender == gooseHolder, "setGooseHolder: FORBIDDEN");
        gooseHolder = newAddr;

        emit SetGooseHolder(msg.sender, newAddr);
    }

    function setFeeHolder(address newAddr) external nonReentrant {
        require(msg.sender == feeHolder, "setFeeHolder: FORBIDDEN");
        feeHolder = newAddr;

        emit SetFeeHolder(msg.sender, newAddr);
    }

    function setSchedulerAddr(address newAddr) external onlyOwner nonReentrant {
        schedulerAddr = newAddr;

        emit SetScheduler(msg.sender, newAddr);
    }

    function updateNewLayerSettings(
        address _houseToken,
        uint256 _houseEmitRate,
        uint256 _totalMint,
        uint256 _pricePerGoose,
        uint16 _feeDevShareBP,
        uint16 _houseShareBP
    ) external onlyOwner nonReentrant {
        houseToken = IBEP20(_houseToken);
        houseEmitRate = _houseEmitRate;
        totalMint = _totalMint;
        pricePerGoose = _pricePerGoose;
        feeDevShareBP = _feeDevShareBP;
        houseShareBP = _houseShareBP;

        emit UpdateNewLayerSettings(msg.sender);
    }

    //Withdraw any excess funds used for providing initial LP
    function fundsWithdraw(IBEP20 token) external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(feeHolder, balance);

        emit FundsWithdraw(msg.sender, address(token), balance);
    }
}
