// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Otc
/// @notice Over-the-counter trading platform for crypto and RWA assets. Makers post buy or sell orders; takers fill at the stated price; fees go to treasury.
/// @dev Operator can pause, set min order size and fee bps. Escrow keeper records RWA fills and releases settlements. All role addresses are immutable.
///
/// Order flow (crypto): Maker posts order (sending wei if sell). Taker calls fillOrder with wei (if buying). Funds transfer immediately; fee sent to treasury.
/// Order flow (RWA): Maker posts order with assetId. Taker fills off-chain; escrow keeper calls recordRwaFill then releaseRwaSettlement.
///
/// Asset types: OTC_ASSET_CRYPTO (0) for native/ETH, OTC_ASSET_RWA (1) for tokenized real-world assets identified by bytes32 assetId.
/// Namespace: 0x4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e

contract Otc {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event OrderPosted(bytes32 indexed orderId, address indexed maker, uint8 assetType, bytes32 assetId, uint256 amount, uint256 pricePerUnit, bool isSell, uint256 atBlock);
    event OrderFilled(bytes32 indexed orderId, address indexed taker, uint256 fillAmount, uint256 atBlock);
    event OrderCancelled(bytes32 indexed orderId, address indexed by, uint256 atBlock);
    event SettlementReleased(bytes32 indexed orderId, address indexed maker, address indexed taker, uint256 makerAmount, uint256 takerAmount, uint256 atBlock);
    event TreasuryFee(address indexed treasury, uint256 amountWei, uint256 atBlock);
    event PlatformPaused(address indexed by, uint256 atBlock);
    event PlatformResumed(address indexed by, uint256 atBlock);
    event MinOrderUpdated(uint256 oldMin, uint256 newMin);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event RwaOrderPosted(bytes32 indexed orderId, bytes32 indexed rwaTokenId, uint256 amount, uint256 pricePerUnit);

    // -------------------------------------------------------------------------
    // ERRORS (unique OTC_ prefix)
    // -------------------------------------------------------------------------

    error OTC_ZeroAddress();
    error OTC_NotOperator();
    error OTC_NotEscrowKeeper();
    error OTC_OrderNotFound();
    error OTC_OrderNotOpen();
    error OTC_OrderAlreadyFilled();
    error OTC_OrderAlreadyCancelled();
    error OTC_InvalidAssetType();
    error OTC_ZeroAmount();
    error OTC_ZeroPrice();
    error OTC_BelowMinOrder();
    error OTC_ExceedsOrderAmount();
    error OTC_TransferFailed();
    error OTC_Paused();
    error OTC_InvalidOrderId();
    error OTC_SettlementNotReady();
    error OTC_Reentrant();
    error OTC_FeeBpsTooHigh();
    error OTC_OrderLimitReached();
    error OTC_IndexOutOfRange();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant OTC_MAX_ORDERS = 512;
    uint256 public constant OTC_VIEW_BATCH = 48;
    uint256 public constant OTC_BPS_DENOM = 10_000;
    uint256 public constant OTC_ASSET_CRYPTO = 0;
    uint256 public constant OTC_ASSET_RWA = 1;
    bytes32 public constant OTC_NAMESPACE = 0x4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e;
    uint256 public constant OTC_MIN_PRICE = 1;
    uint256 public constant OTC_MAX_PRICE_DECIMALS = 18;

    struct Order {
        bytes32 orderId;
        address maker;
        uint8 assetType;
        bytes32 assetId;
        uint256 amount;
        uint256 pricePerUnit;
        bool isSell;
        uint256 filledAmount;
        uint8 status; // 0 open, 1 filled, 2 cancelled
        uint256 createdAt;
    }

    address public immutable operator;
    address public immutable treasury;
    address public immutable escrowKeeper;
    uint256 public immutable deployBlock;

    mapping(bytes32 => Order) private _orders;
    bytes32[] private _orderIds;
    uint256 public orderCount;
    uint256 public minOrderWei;
    uint256 public feeBps;
    bool private _paused;
    uint256 private _reentrancyLock;

    uint256 public constant STATUS_OPEN = 0;
    uint256 public constant STATUS_FILLED = 1;
    uint256 public constant STATUS_CANCELLED = 2;

    modifier onlyOperator() {
        if (msg.sender != operator) revert OTC_NotOperator();
        _;
    }

    modifier onlyEscrowKeeper() {
        if (msg.sender != escrowKeeper) revert OTC_NotEscrowKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert OTC_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert OTC_Reentrant();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    constructor() {
        operator = address(0x1a2b3c4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5);
        treasury = address(0x2b3c4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5f6);
        escrowKeeper = address(0x3c4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5f678);
        deployBlock = block.number;
        if (operator == address(0) || treasury == address(0) || escrowKeeper == address(0)) revert OTC_ZeroAddress();
        minOrderWei = 1e15; // 0.001 ether
        feeBps = 25;
    }

    function pause() external onlyOperator {
        _paused = true;
        emit PlatformPaused(msg.sender, block.number);
    }

    function unpause() external onlyOperator {
        _paused = false;
        emit PlatformResumed(msg.sender, block.number);
    }

    function setMinOrderWei(uint256 _min) external onlyOperator {
        uint256 old = minOrderWei;
        minOrderWei = _min;
        emit MinOrderUpdated(old, _min);
    }

    function setFeeBps(uint256 _bps) external onlyOperator {
        if (_bps > OTC_BPS_DENOM) revert OTC_FeeBpsTooHigh();
        uint256 old = feeBps;
        feeBps = _bps;
        emit FeeBpsUpdated(old, _bps);
    }

    function _nextOrderId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.number, block.timestamp, orderCount, msg.sender));
    }

    function postOrder(
        uint8 assetType,
        bytes32 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        bool isSell
    ) external payable whenNotPaused nonReentrant returns (bytes32 orderId) {
        if (assetType != OTC_ASSET_CRYPTO && assetType != OTC_ASSET_RWA) revert OTC_InvalidAssetType();
        if (amount == 0) revert OTC_ZeroAmount();
        if (pricePerUnit == 0) revert OTC_ZeroPrice();
        uint256 totalValue = (amount * pricePerUnit) / 1e18;
        if (totalValue < minOrderWei) revert OTC_BelowMinOrder();
        if (orderCount >= OTC_MAX_ORDERS) revert OTC_OrderLimitReached();
        if (isSell && assetType == OTC_ASSET_CRYPTO && msg.value < amount) revert OTC_ZeroAmount();
        orderId = _nextOrderId();
        _orders[orderId] = Order({
            orderId: orderId,
            maker: msg.sender,
            assetType: assetType,
            assetId: assetId,
            amount: amount,
            pricePerUnit: pricePerUnit,
            isSell: isSell,
            filledAmount: 0,
            status: STATUS_OPEN,
            createdAt: block.number
        });
        _orderIds.push(orderId);
        orderCount++;
        _registerMakerOrder(msg.sender, orderId);
        if (isSell && assetType == OTC_ASSET_CRYPTO) {
            if (msg.value != amount) revert OTC_ZeroAmount();
        }
        if (assetType == OTC_ASSET_RWA) emit RwaOrderPosted(orderId, assetId, amount, pricePerUnit);
        emit OrderPosted(orderId, msg.sender, assetType, assetId, amount, pricePerUnit, isSell, block.number);
        return orderId;
    }

    function fillOrder(bytes32 orderId, uint256 fillAmount) external payable whenNotPaused nonReentrant {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        if (o.status != STATUS_OPEN) revert OTC_OrderNotOpen();
        if (fillAmount == 0 || fillAmount > o.amount - o.filledAmount) revert OTC_ExceedsOrderAmount();
        uint256 takerValue = (fillAmount * o.pricePerUnit) / 1e18;
        if (o.isSell) {
            if (msg.value < takerValue) revert OTC_ZeroAmount();
            (bool ok,) = o.maker.call{value: takerValue}("");
            if (!ok) revert OTC_TransferFailed();
            uint256 excess = msg.value - takerValue;
            if (excess > 0) {
                (bool ok2,) = msg.sender.call{value: excess}("");
                if (!ok2) revert OTC_TransferFailed();
            }
        } else {
            if (msg.value < takerValue) revert OTC_ZeroAmount();
        }
        o.filledAmount += fillAmount;
        if (o.filledAmount >= o.amount) o.status = STATUS_FILLED;
        uint256 fee = (takerValue * feeBps) / OTC_BPS_DENOM;
        if (fee > 0) {
            (bool feeOk,) = treasury.call{value: fee}("");
            if (!feeOk) revert OTC_TransferFailed();
            totalFeesCollected += fee;
            emit TreasuryFee(treasury, fee, block.number);
        }
        emit OrderFilled(orderId, msg.sender, fillAmount, block.number);
    }

    function cancelOrder(bytes32 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        if (o.status != STATUS_OPEN) revert OTC_OrderNotOpen();
        if (msg.sender != o.maker && msg.sender != operator) revert OTC_NotOperator();
        o.status = STATUS_CANCELLED;
        if (o.isSell && o.assetType == OTC_ASSET_CRYPTO && o.filledAmount < o.amount) {
            uint256 refund = o.amount - o.filledAmount;
            (bool ok,) = o.maker.call{value: refund}("");
            if (!ok) revert OTC_TransferFailed();
        }
        emit OrderCancelled(orderId, msg.sender, block.number);
    }

    function getOrder(bytes32 orderId) external view returns (
        address maker,
        uint8 assetType,
        bytes32 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        bool isSell,
        uint256 filledAmount,
        uint8 status,
        uint256 createdAt
    ) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.maker, o.assetType, o.assetId, o.amount, o.pricePerUnit, o.isSell, o.filledAmount, o.status, o.createdAt);
    }

    function getOrderAt(uint256 index) external view returns (bytes32) {
        if (index >= _orderIds.length) revert OTC_OrderNotFound();
        return _orderIds[index];
    }

    function orderIdsBatch(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        uint256 len = _orderIds.length;
        if (offset >= len) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        if (limit > OTC_VIEW_BATCH) end = offset + OTC_VIEW_BATCH;
        if (end > len) end = len;
        bytes32[] memory out = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) out[i - offset] = _orderIds[i];
        return out;
    }

    function isPaused() external view returns (bool) {
        return _paused;
    }

    mapping(address => bytes32[]) private _makerOrders;
    uint256 public totalFeesCollected;

    function _registerMakerOrder(address maker, bytes32 orderId) internal {
        _makerOrders[maker].push(orderId);
    }

    function getOrderCountByMaker(address maker) external view returns (uint256) {
        return _makerOrders[maker].length;
    }

    function getOrderIdByMakerAt(address maker, uint256 index) external view returns (bytes32) {
        bytes32[] storage ids = _makerOrders[maker];
        if (index >= ids.length) revert OTC_IndexOutOfRange();
        return ids[index];
    }

    function getOrderIdsByMakerBatch(address maker, uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] storage ids = _makerOrders[maker];
        uint256 len = ids.length;
        if (offset >= len) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        if (limit > OTC_VIEW_BATCH) end = offset + OTC_VIEW_BATCH;
        if (end > len) end = len;
        bytes32[] memory out = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) out[i - offset] = ids[i];
        return out;
    }

    struct OrderView {
        bytes32 orderId;
        address maker;
        uint8 assetType;
        bytes32 assetId;
        uint256 amount;
        uint256 pricePerUnit;
        bool isSell;
        uint256 filledAmount;
        uint8 status;
        uint256 createdAt;
    }

    function getOrderView(bytes32 orderId) external view returns (OrderView memory) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return OrderView({
            orderId: o.orderId,
            maker: o.maker,
            assetType: o.assetType,
            assetId: o.assetId,
            amount: o.amount,
            pricePerUnit: o.pricePerUnit,
            isSell: o.isSell,
            filledAmount: o.filledAmount,
            status: o.status,
            createdAt: o.createdAt
        });
    }

    function getOpenOrderCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _orderIds.length; i++) {
            if (_orders[_orderIds[i]].status == STATUS_OPEN) count++;
        }
        return count;
    }

    function getTotalOrderCount() external view returns (uint256) {
        return _orderIds.length;
    }

    function orderExists(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].maker != address(0);
    }

    function getRemainingAmount(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return o.amount - o.filledAmount;
    }

    function getOrderValue(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.amount * o.pricePerUnit) / 1e18;
    }

    function getFillValue(bytes32 orderId, uint256 fillAmount) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (fillAmount * o.pricePerUnit) / 1e18;
    }

    function getDeployBlock() external view returns (uint256) {
        return deployBlock;
