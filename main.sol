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
    }

    function getMinOrderWei() external view returns (uint256) {
        return minOrderWei;
    }

    function getFeeBps() external view returns (uint256) {
        return feeBps;
    }

    function computeFee(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / OTC_BPS_DENOM;
    }

    function getOrderStatus(bytes32 orderId) external view returns (uint8) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return o.status;
    }

    function getOrderMaker(bytes32 orderId) external view returns (address) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return o.maker;
    }

    function getOrderAmounts(bytes32 orderId) external view returns (uint256 amount, uint256 filledAmount, uint256 remaining) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.amount, o.filledAmount, o.amount - o.filledAmount);
    }

    function getOrderPrice(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return o.pricePerUnit;
    }

    function getOrderAsset(bytes32 orderId) external view returns (uint8 assetType, bytes32 assetId) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.assetType, o.assetId);
    }

    function isOrderSell(bytes32 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return o.isSell;
    }

    function isOrderOpen(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].status == STATUS_OPEN;
    }

    function getOpenOrderIds(uint256 maxReturn) external view returns (bytes32[] memory) {
        uint256 cap = maxReturn > OTC_VIEW_BATCH ? OTC_VIEW_BATCH : maxReturn;
        bytes32[] memory temp = new bytes32[](_orderIds.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _orderIds.length && count < cap; i++) {
            if (_orders[_orderIds[i]].status == STATUS_OPEN) {
                temp[count] = _orderIds[i];
                count++;
            }
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) out[j] = temp[j];
        return out;
    }

    function getOrderViewsBatch(uint256 offset, uint256 limit) external view returns (OrderView[] memory) {
        uint256 len = _orderIds.length;
        if (offset >= len) return new OrderView[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        if (limit > OTC_VIEW_BATCH) end = offset + OTC_VIEW_BATCH;
        if (end > len) end = len;
        OrderView[] memory out = new OrderView[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            Order storage o = _orders[_orderIds[i]];
            out[i - offset] = OrderView({
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
        return out;
    }

    mapping(bytes32 => uint256) private _escrowWei;

    function escrowBalance(bytes32 orderId) external view returns (uint256) {
        return _escrowWei[orderId];
    }

    function releaseToTreasury(uint256 amountWei) external onlyOperator {
        if (amountWei == 0) return;
        (bool ok,) = treasury.call{value: amountWei}("");
        if (!ok) revert OTC_TransferFailed();
    }

    /// @notice Returns order ids that are open (status == 0) within the given index range
    function getOpenOrderIdsInRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory) {
        if (fromIndex >= _orderIds.length || fromIndex > toIndex) return new bytes32[](0);
        if (toIndex >= _orderIds.length) toIndex = _orderIds.length - 1;
        uint256 maxLen = toIndex - fromIndex + 1;
        if (maxLen > OTC_VIEW_BATCH) maxLen = OTC_VIEW_BATCH;
        bytes32[] memory temp = new bytes32[](maxLen);
        uint256 count = 0;
        for (uint256 i = fromIndex; i <= toIndex && count < maxLen; i++) {
            if (_orders[_orderIds[i]].status == STATUS_OPEN) {
                temp[count] = _orderIds[i];
                count++;
            }
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) out[j] = temp[j];
        return out;
    }

    /// @notice Returns the number of open orders for a given maker
    function getMakerOpenCount(address maker) external view returns (uint256) {
        bytes32[] storage ids = _makerOrders[maker];
        uint256 n = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (_orders[ids[i]].status == STATUS_OPEN) n++;
        }
        return n;
    }

    /// @notice Returns order views for an array of order ids
    function getOrderViewsForIds(bytes32[] calldata orderIds) external view returns (OrderView[] memory) {
        OrderView[] memory out = new OrderView[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = _orders[orderIds[i]];
            if (o.maker == address(0)) continue;
            out[i] = OrderView({
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
        return out;
    }

    struct OrderSummary {
        bytes32 orderId;
        address maker;
        uint256 amount;
        uint256 filledAmount;
        uint256 pricePerUnit;
        bool isSell;
        uint8 status;
    }

    /// @notice Lightweight order summary for list views
    function getOrderSummary(bytes32 orderId) external view returns (OrderSummary memory) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return OrderSummary({
            orderId: o.orderId,
            maker: o.maker,
            amount: o.amount,
            filledAmount: o.filledAmount,
            pricePerUnit: o.pricePerUnit,
            isSell: o.isSell,
            status: o.status
        });
    }

    function getOrderSummariesBatch(uint256 offset, uint256 limit) external view returns (OrderSummary[] memory) {
        uint256 len = _orderIds.length;
        if (offset >= len) return new OrderSummary[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        if (limit > OTC_VIEW_BATCH) end = offset + OTC_VIEW_BATCH;
        if (end > len) end = len;
        OrderSummary[] memory out = new OrderSummary[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            Order storage o = _orders[_orderIds[i]];
            out[i - offset] = OrderSummary({
                orderId: o.orderId,
                maker: o.maker,
                amount: o.amount,
                filledAmount: o.filledAmount,
                pricePerUnit: o.pricePerUnit,
                isSell: o.isSell,
                status: o.status
            });
        }
        return out;
    }

    /// @notice Compute total value (amount * price) with 18 decimals
    function _computeValue(uint256 amount, uint256 pricePerUnit) internal pure returns (uint256) {
        return (amount * pricePerUnit) / 1e18;
    }

    /// @notice Compute fee for a given value in wei
    function _computeFeeWei(uint256 valueWei) internal view returns (uint256) {
        return (valueWei * feeBps) / OTC_BPS_DENOM;
    }

    /// @notice Validate order parameters before posting
    function _validateOrderParams(uint8 assetType, uint256 amount, uint256 pricePerUnit) internal view {
        if (assetType != OTC_ASSET_CRYPTO && assetType != OTC_ASSET_RWA) revert OTC_InvalidAssetType();
        if (amount == 0) revert OTC_ZeroAmount();
        if (pricePerUnit == 0) revert OTC_ZeroPrice();
        uint256 totalValue = _computeValue(amount, pricePerUnit);
        if (totalValue < minOrderWei) revert OTC_BelowMinOrder();
    }

    mapping(bytes32 => address) private _rwaSettlementTaker;
    mapping(bytes32 => uint256) private _rwaSettlementFillAmount;

    /// @notice Record taker and fill amount for RWA order (for escrow keeper release)
    function recordRwaFill(bytes32 orderId, address taker, uint256 fillAmount) external onlyEscrowKeeper {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        if (o.assetType != OTC_ASSET_RWA) revert OTC_InvalidAssetType();
        if (o.status != STATUS_OPEN) revert OTC_OrderNotOpen();
        if (fillAmount == 0 || fillAmount > o.amount - o.filledAmount) revert OTC_ExceedsOrderAmount();
        _rwaSettlementTaker[orderId] = taker;
        _rwaSettlementFillAmount[orderId] = fillAmount;
        o.filledAmount += fillAmount;
        if (o.filledAmount >= o.amount) o.status = STATUS_FILLED;
        emit OrderFilled(orderId, taker, fillAmount, block.number);
    }

    /// @notice Release RWA settlement: escrow keeper confirms and optionally sends fee to treasury
    function releaseRwaSettlement(bytes32 orderId, uint256 feeWei) external onlyEscrowKeeper nonReentrant {
        address taker = _rwaSettlementTaker[orderId];
        uint256 fillAmount = _rwaSettlementFillAmount[orderId];
        if (taker == address(0)) revert OTC_SettlementNotReady();
        Order storage o = _orders[orderId];
        uint256 valueWei = _computeValue(fillAmount, o.pricePerUnit);
        if (feeWei > 0 && feeWei <= valueWei) {
            totalFeesCollected += feeWei;
            (bool ok,) = treasury.call{value: feeWei}("");
            if (!ok) revert OTC_TransferFailed();
            emit TreasuryFee(treasury, feeWei, block.number);
        }
        emit SettlementReleased(orderId, o.maker, taker, fillAmount, valueWei, block.number);
        delete _rwaSettlementTaker[orderId];
        delete _rwaSettlementFillAmount[orderId];
    }

    function getRwaSettlementTaker(bytes32 orderId) external view returns (address) {
        return _rwaSettlementTaker[orderId];
    }

    function getRwaSettlementFillAmount(bytes32 orderId) external view returns (uint256) {
        return _rwaSettlementFillAmount[orderId];
    }

    /// @notice Platform stats for dashboards
    struct PlatformStats {
        uint256 totalOrders;
        uint256 openOrders;
        uint256 totalFeesCollected;
        uint256 minOrderWei;
        uint256 feeBps;
        bool paused;
        uint256 deployBlock;
    }

    function getPlatformStats() external view returns (PlatformStats memory) {
        uint256 openCount = 0;
        for (uint256 i = 0; i < _orderIds.length; i++) {
            if (_orders[_orderIds[i]].status == STATUS_OPEN) openCount++;
        }
        return PlatformStats({
            totalOrders: _orderIds.length,
            openOrders: openCount,
            totalFeesCollected: totalFeesCollected,
            minOrderWei: minOrderWei,
            feeBps: feeBps,
            paused: _paused,
            deployBlock: deployBlock
        });
    }

    function getOperator() external view returns (address) { return operator; }
    function getTreasury() external view returns (address) { return treasury; }
    function getEscrowKeeper() external view returns (address) { return escrowKeeper; }

    /// @notice Order ids where assetType is CRYPTO (0)
    function getCryptoOrderIdsBatch(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] memory all = orderIdsBatch(offset, limit);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].assetType == OTC_ASSET_CRYPTO) n++;
        }
        bytes32[] memory out = new bytes32[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].assetType == OTC_ASSET_CRYPTO) out[j++] = all[i];
        }
        return out;
    }

    /// @notice Order ids where assetType is RWA (1)
    function getRwaOrderIdsBatch(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] memory all = orderIdsBatch(offset, limit);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].assetType == OTC_ASSET_RWA) n++;
        }
        bytes32[] memory out = new bytes32[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].assetType == OTC_ASSET_RWA) out[j++] = all[i];
        }
        return out;
    }

    /// @notice Whether a fill of fillAmount would succeed for orderId (view only)
    function wouldFillSucceed(bytes32 orderId, uint256 fillAmount) external view returns (bool) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0) || o.status != STATUS_OPEN) return false;
        if (fillAmount == 0 || fillAmount > o.amount - o.filledAmount) return false;
        return true;
    }

    /// @notice Whether posting an order with given params would pass checks (view only)
    function wouldPostSucceed(uint8 assetType, uint256 amount, uint256 pricePerUnit) external view returns (bool) {
        if (assetType != OTC_ASSET_CRYPTO && assetType != OTC_ASSET_RWA) return false;
        if (amount == 0 || pricePerUnit == 0) return false;
        if ((amount * pricePerUnit) / 1e18 < minOrderWei) return false;
        if (orderCount >= OTC_MAX_ORDERS) return false;
        return true;
    }

    /// @notice Cancel multiple orders by id (operator or maker only)
    function cancelOrders(bytes32[] calldata orderIds) external nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = _orders[orderIds[i]];
            if (o.maker == address(0) || o.status != STATUS_OPEN) continue;
            if (msg.sender != o.maker && msg.sender != operator) continue;
            o.status = STATUS_CANCELLED;
            if (o.isSell && o.assetType == OTC_ASSET_CRYPTO) {
                uint256 refund = o.amount - o.filledAmount;
                if (refund > 0) {
                    (bool ok,) = o.maker.call{value: refund}("");
                    if (!ok) revert OTC_TransferFailed();
                }
            }
            emit OrderCancelled(orderIds[i], msg.sender, block.number);
        }
    }

    uint256 public constant OTC_VERSION = 1;
    uint256 public constant OTC_CHAIN_ID_PLACEHOLDER = 1;

    function orderCreatedAt(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.createdAt; }
    function orderAmount(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.amount; }
    function orderFilledAmount(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.filledAmount; }
    function orderPricePerUnit(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.pricePerUnit; }
    function orderAssetType(bytes32 orderId) external view returns (uint8) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.assetType; }
    function orderAssetId(bytes32 orderId) external view returns (bytes32) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.assetId; }
    function orderIsSell(bytes32 orderId) external view returns (bool) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.isSell; }
    function orderStatus(bytes32 orderId) external view returns (uint8) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.status; }
    function orderMaker(bytes32 orderId) external view returns (address) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.maker; }
    function totalOrderCount() external view returns (uint256) { return _orderIds.length; }
    function openOrderCount() external view returns (uint256) { uint256 n = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (_orders[_orderIds[i]].status == STATUS_OPEN) n++; return n; }
    function paused() external view returns (bool) { return _paused; }
    function minOrder() external view returns (uint256) { return minOrderWei; }
    function feeBasisPoints() external view returns (uint256) { return feeBps; }
    function totalFees() external view returns (uint256) { return totalFeesCollected; }
    function operatorAddress() external view returns (address) { return operator; }
    function treasuryAddress() external view returns (address) { return treasury; }
    function escrowKeeperAddress() external view returns (address) { return escrowKeeper; }
    function deployBlockNumber() external view returns (uint256) { return deployBlock; }
    function namespace() external view returns (bytes32) { return OTC_NAMESPACE; }
    function maxOrders() external view returns (uint256) { return OTC_MAX_ORDERS; }
    function viewBatchSize() external view returns (uint256) { return OTC_VIEW_BATCH; }
    function assetTypeCrypto() external pure returns (uint8) { return uint8(OTC_ASSET_CRYPTO); }
    function assetTypeRwa() external pure returns (uint8) { return uint8(OTC_ASSET_RWA); }
    function statusOpen() external pure returns (uint8) { return uint8(STATUS_OPEN); }
    function statusFilled() external pure returns (uint8) { return uint8(STATUS_FILLED); }
    function statusCancelled() external pure returns (uint8) { return uint8(STATUS_CANCELLED); }
    function bpsDenominator() external pure returns (uint256) { return OTC_BPS_DENOM; }
    function version() external pure returns (uint256) { return OTC_VERSION; }

    /// @notice Returns order id at index in the global list
    function orderIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _orderIds.length) revert OTC_IndexOutOfRange();
        return _orderIds[index];
    }

    /// @notice Returns last order id in the list (most recently posted)
    function lastOrderId() external view returns (bytes32) {
        if (_orderIds.length == 0) revert OTC_OrderNotFound();
        return _orderIds[_orderIds.length - 1];
    }

    /// @notice Compute value in wei for amount * pricePerUnit (18 decimals)
    function computeOrderValue(uint256 amount, uint256 pricePerUnit) external pure returns (uint256) {
        return (amount * pricePerUnit) / 1e18;
    }

    /// @notice Compute fee in wei for a given value
    function computeFeeForValue(uint256 valueWei) external view returns (uint256) {
        return (valueWei * feeBps) / OTC_BPS_DENOM;
    }

    /// @notice Check if order is fully filled
    function isOrderFilled(bytes32 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) return false;
        return o.filledAmount >= o.amount || o.status == STATUS_FILLED;
    }

    /// @notice Check if order is cancelled
    function isOrderCancelled(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].status == STATUS_CANCELLED;
    }

    /// @notice Remaining fillable amount
    function remainingAmount(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return o.amount - o.filledAmount;
    }

    /// @notice Value of remaining fill (remainingAmount * pricePerUnit)
    function remainingValue(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        uint256 rem = o.amount - o.filledAmount;
        return (rem * o.pricePerUnit) / 1e18;
    }

    // -------------------------------------------------------------------------
    // ADDITIONAL VIEW HELPERS (compatibility and dashboards)
    // -------------------------------------------------------------------------

    function getOrderIds() external view returns (bytes32[] memory) {
        return _orderIds;
    }

    function getOrderIdsLength() external view returns (uint256) {
        return _orderIds.length;
    }

    function hasOrder(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].maker != address(0);
    }

    function getFillValueForAmount(bytes32 orderId, uint256 fillAmount) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (fillAmount * o.pricePerUnit) / 1e18;
    }

    function getFeeForFillValue(uint256 fillValueWei) external view returns (uint256) {
        return (fillValueWei * feeBps) / OTC_BPS_DENOM;
    }

    function meetsMinOrder(uint256 amount, uint256 pricePerUnit) external view returns (bool) {
        return (amount * pricePerUnit) / 1e18 >= minOrderWei;
    }

    function canPostMoreOrders() external view returns (bool) {
        return orderCount < OTC_MAX_ORDERS && !_paused;
    }

    function getOrderInfo(bytes32 orderId) external view returns (
        address maker_,
        uint8 assetType_,
        bytes32 assetId_,
        uint256 amount_,
        uint256 pricePerUnit_,
        bool isSell_,
        uint256 filledAmount_,
        uint8 status_,
        uint256 createdAt_
    ) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.maker, o.assetType, o.assetId, o.amount, o.pricePerUnit, o.isSell, o.filledAmount, o.status, o.createdAt);
    }

    function getOpenOrderIdsPaginated(uint256 page, uint256 pageSize) external view returns (bytes32[] memory) {
        if (pageSize > OTC_VIEW_BATCH) pageSize = OTC_VIEW_BATCH;
        bytes32[] memory temp = new bytes32[](pageSize);
        uint256 count = 0;
        uint256 skipped = 0;
        for (uint256 i = 0; i < _orderIds.length && count < pageSize; i++) {
            if (_orders[_orderIds[i]].status != STATUS_OPEN) continue;
            if (skipped < page * pageSize) { skipped++; continue; }
            temp[count++] = _orderIds[i];
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) out[j] = temp[j];
        return out;
    }

    function getOrdersByMakerPaginated(address maker, uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return getOrderIdsByMakerBatch(maker, offset, limit);
    }

    function getSellOrderIdsBatch(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] memory all = orderIdsBatch(offset, limit);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].isSell) n++;
        }
        bytes32[] memory out = new bytes32[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].isSell) out[j++] = all[i];
        }
        return out;
    }

    function getBuyOrderIdsBatch(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] memory all = orderIdsBatch(offset, limit);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (!_orders[all[i]].isSell) n++;
        }
        bytes32[] memory out = new bytes32[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (!_orders[all[i]].isSell) out[j++] = all[i];
        }
        return out;
    }

    function getFilledOrderIdsBatch(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] memory all = orderIdsBatch(offset, limit);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].status == STATUS_FILLED) n++;
        }
        bytes32[] memory out = new bytes32[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].status == STATUS_FILLED) out[j++] = all[i];
        }
        return out;
    }

    function getCancelledOrderIdsBatch(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] memory all = orderIdsBatch(offset, limit);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].status == STATUS_CANCELLED) n++;
        }
        bytes32[] memory out = new bytes32[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_orders[all[i]].status == STATUS_CANCELLED) out[j++] = all[i];
        }
        return out;
    }

    /// @notice Single order view by index in global list
    function getOrderViewByIndex(uint256 index) external view returns (OrderView memory) {
        if (index >= _orderIds.length) revert OTC_IndexOutOfRange();
        Order storage o = _orders[_orderIds[index]];
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

    function getOrderViewByIndexRange(uint256 fromIdx, uint256 toIdx) external view returns (OrderView[] memory) {
        if (fromIdx >= _orderIds.length || fromIdx > toIdx) return new OrderView[](0);
        if (toIdx >= _orderIds.length) toIdx = _orderIds.length - 1;
        uint256 len = toIdx - fromIdx + 1;
        if (len > OTC_VIEW_BATCH) len = OTC_VIEW_BATCH;
        OrderView[] memory out = new OrderView[](len);
        for (uint256 i = 0; i < len; i++) {
            Order storage o = _orders[_orderIds[fromIdx + i]];
            out[i] = OrderView({
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
        return out;
    }

    struct PlatformStatsCompact {
        uint256 totalOrders;
        uint256 openOrders;
        uint256 totalFeesWei;
        bool paused;
    }

    function getPlatformStatsCompact() external view returns (PlatformStatsCompact memory) {
        uint256 openCount = 0;
        for (uint256 i = 0; i < _orderIds.length; i++) {
            if (_orders[_orderIds[i]].status == STATUS_OPEN) openCount++;
        }
        return PlatformStatsCompact({
            totalOrders: _orderIds.length,
            openOrders: openCount,
            totalFeesWei: totalFeesCollected,
            paused: _paused
        });
    }

    function getOrderSummariesForIds(bytes32[] calldata ids) external view returns (OrderSummary[] memory) {
        OrderSummary[] memory out = new OrderSummary[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            Order storage o = _orders[ids[i]];
            if (o.maker == address(0)) continue;
            out[i] = OrderSummary({
                orderId: o.orderId,
                maker: o.maker,
                amount: o.amount,
                filledAmount: o.filledAmount,
                pricePerUnit: o.pricePerUnit,
                isSell: o.isSell,
                status: o.status
            });
        }
        return out;
    }

    function orderValueWei(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.amount * o.pricePerUnit) / 1e18;
    }

    function filledValueWei(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.filledAmount * o.pricePerUnit) / 1e18;
    }

    function unfilledValueWei(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        uint256 rem = o.amount - o.filledAmount;
        return (rem * o.pricePerUnit) / 1e18;
    }

    function isCryptoOrder(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].assetType == OTC_ASSET_CRYPTO;
    }

    function isRwaOrder(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].assetType == OTC_ASSET_RWA;
    }

    function isSellOrder(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].isSell;
    }

    function isBuyOrder(bytes32 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) return false;
        return !o.isSell;
    }

    function orderProgressBps(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0) || o.amount == 0) return 0;
        return (o.filledAmount * OTC_BPS_DENOM) / o.amount;
    }

    function feeForOrderValue(uint256 orderValueWei_) external view returns (uint256) {
        return (orderValueWei_ * feeBps) / OTC_BPS_DENOM;
    }

    function netAfterFee(uint256 valueWei) external view returns (uint256) {
        uint256 fee = (valueWei * feeBps) / OTC_BPS_DENOM;
        return valueWei - fee;
    }

    function minOrderValue() external view returns (uint256) {
        return minOrderWei;
    }

    function maxOrdersCap() external pure returns (uint256) {
        return OTC_MAX_ORDERS;
    }

    function batchSizeCap() external pure returns (uint256) {
        return OTC_VIEW_BATCH;
    }

    function getRoleOperator() external view returns (address) { return operator; }
    function getRoleTreasury() external view returns (address) { return treasury; }
    function getRoleEscrowKeeper() external view returns (address) { return escrowKeeper; }
    function platformPaused() external view returns (bool) { return _paused; }
    function totalOrders() external view returns (uint256) { return _orderIds.length; }
    function feesCollected() external view returns (uint256) { return totalFeesCollected; }
    function minimumOrderWei() external view returns (uint256) { return minOrderWei; }
    function feeBasisPoints() external view returns (uint256) { return feeBps; }
    function contractVersion() external pure returns (uint256) { return OTC_VERSION; }
    function domainNamespace() external pure returns (bytes32) { return OTC_NAMESPACE; }

    /// @notice Alias for getOrderView (API compatibility)
    function fetchOrder(bytes32 orderId) external view returns (OrderView memory) {
        return getOrderView(orderId);
    }

    /// @notice Alias for getPlatformStats (API compatibility)
    function fetchPlatformStats() external view returns (PlatformStats memory) {
        return getPlatformStats();
    }

    /// @notice Alias for getOrderSummary (API compatibility)
    function fetchOrderSummary(bytes32 orderId) external view returns (OrderSummary memory) {
        return getOrderSummary(orderId);
    }

    /// @notice Alias for orderIdsBatch (API compatibility)
    function fetchOrderIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return orderIdsBatch(offset, limit);
    }

    /// @notice Alias for getOrderViewsBatch (API compatibility)
    function fetchOrderViews(uint256 offset, uint256 limit) external view returns (OrderView[] memory) {
        return getOrderViewsBatch(offset, limit);
    }

    /// @notice Alias for getOpenOrderIds (API compatibility)
    function fetchOpenOrderIds(uint256 maxReturn) external view returns (bytes32[] memory) {
        return getOpenOrderIds(maxReturn);
    }

    function getOrderDetails(bytes32 orderId) external view returns (OrderView memory) {
        return getOrderView(orderId);
    }

    function getOrderData(bytes32 orderId) external view returns (
        bytes32 id,
        address makerAddr,
        uint8 asset,
        bytes32 assetKey,
        uint256 amt,
        uint256 price,
        bool sell,
        uint256 filled,
        uint8 st,
        uint256 created
    ) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OTC_OrderNotFound();
        return (o.orderId, o.maker, o.assetType, o.assetId, o.amount, o.pricePerUnit, o.isSell, o.filledAmount, o.status, o.createdAt);
    }

    function orderIdBytes32(bytes32 orderId) external view returns (bytes32) { return _orders[orderId].orderId; }
    function makerAddress(bytes32 orderId) external view returns (address) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.maker; }
    function assetTypeOf(bytes32 orderId) external view returns (uint8) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.assetType; }
    function assetIdOf(bytes32 orderId) external view returns (bytes32) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.assetId; }
    function amountOf(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.amount; }
    function priceOf(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.pricePerUnit; }
    function sellSide(bytes32 orderId) external view returns (bool) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.isSell; }
    function filledOf(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.filledAmount; }
    function statusOf(bytes32 orderId) external view returns (uint8) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.status; }
    function createdAt(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.createdAt; }
    function orderListLength() external view returns (uint256) { return _orderIds.length; }
    function isPlatformPaused() external view returns (bool) { return _paused; }
    function minOrderSize() external view returns (uint256) { return minOrderWei; }
    function feePercentBps() external view returns (uint256) { return feeBps; }
    function accumulatedFees() external view returns (uint256) { return totalFeesCollected; }
    function operatorRole() external view returns (address) { return operator; }
    function treasuryRole() external view returns (address) { return treasury; }
    function escrowKeeperRole() external view returns (address) { return escrowKeeper; }
    function deploymentBlock() external view returns (uint256) { return deployBlock; }
    function namespaceHash() external pure returns (bytes32) { return OTC_NAMESPACE; }
    function maxOrdersLimit() external pure returns (uint256) { return OTC_MAX_ORDERS; }
    function viewBatchLimit() external pure returns (uint256) { return OTC_VIEW_BATCH; }
    function cryptoAssetType() external pure returns (uint8) { return uint8(OTC_ASSET_CRYPTO); }
    function rwaAssetType() external pure returns (uint8) { return uint8(OTC_ASSET_RWA); }
    function openStatus() external pure returns (uint8) { return uint8(STATUS_OPEN); }
    function filledStatus() external pure returns (uint8) { return uint8(STATUS_FILLED); }
    function cancelledStatus() external pure returns (uint8) { return uint8(STATUS_CANCELLED); }
    function bpsBase() external pure returns (uint256) { return OTC_BPS_DENOM; }
    function versionNumber() external pure returns (uint256) { return OTC_VERSION; }
    function orderCountLimit() external view returns (uint256) { return orderCount; }
    function remainingOrderSlots() external view returns (uint256) { return orderCount >= OTC_MAX_ORDERS ? 0 : OTC_MAX_ORDERS - orderCount; }
    function canAcceptOrders() external view returns (bool) { return !_paused && orderCount < OTC_MAX_ORDERS; }
    function treasuryBalance() external view returns (uint256) { return treasury.balance; }
    function contractBalance() external view returns (uint256) { return address(this).balance; }

    function orderBookSize() external view returns (uint256) { return _orderIds.length; }
    function openOrdersCount() external view returns (uint256) { uint256 c = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (_orders[_orderIds[i]].status == STATUS_OPEN) c++; return c; }
    function filledOrdersCount() external view returns (uint256) { uint256 c = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (_orders[_orderIds[i]].status == STATUS_FILLED) c++; return c; }
    function cancelledOrdersCount() external view returns (uint256) { uint256 c = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (_orders[_orderIds[i]].status == STATUS_CANCELLED) c++; return c; }
    function cryptoOrdersCount() external view returns (uint256) { uint256 c = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (_orders[_orderIds[i]].assetType == OTC_ASSET_CRYPTO) c++; return c; }
    function rwaOrdersCount() external view returns (uint256) { uint256 c = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (_orders[_orderIds[i]].assetType == OTC_ASSET_RWA) c++; return c; }
    function sellOrdersCount() external view returns (uint256) { uint256 c = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (_orders[_orderIds[i]].isSell) c++; return c; }
    function buyOrdersCount() external view returns (uint256) { uint256 c = 0; for (uint256 i = 0; i < _orderIds.length; i++) if (!_orders[_orderIds[i]].isSell) c++; return c; }
    function firstOrderId() external view returns (bytes32) { if (_orderIds.length == 0) revert OTC_OrderNotFound(); return _orderIds[0]; }
    function lastOrderIdPublic() external view returns (bytes32) { if (_orderIds.length == 0) revert OTC_OrderNotFound(); return _orderIds[_orderIds.length - 1]; }
    function orderIdByIndex(uint256 idx) external view returns (bytes32) { if (idx >= _orderIds.length) revert OTC_IndexOutOfRange(); return _orderIds[idx]; }
    function orderExistsCheck(bytes32 orderId) external view returns (bool) { return _orders[orderId].maker != address(0); }
    function getRemaining(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.amount - o.filledAmount; }
    function getValue(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return (o.amount * o.pricePerUnit) / 1e18; }
    function getFilledValue(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return (o.filledAmount * o.pricePerUnit) / 1e18; }
    function getRemainingValue(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); uint256 r = o.amount - o.filledAmount; return (r * o.pricePerUnit) / 1e18; }
    function computeValue(uint256 amt, uint256 price) external pure returns (uint256) { return (amt * price) / 1e18; }
    function computeFeeAmount(uint256 valueWei_) external view returns (uint256) { return (valueWei_ * feeBps) / OTC_BPS_DENOM; }
    function checkMinOrder(uint256 amt, uint256 price) external view returns (bool) { return (amt * price) / 1e18 >= minOrderWei; }
    function slotsRemaining() external view returns (uint256) { return orderCount >= OTC_MAX_ORDERS ? 0 : OTC_MAX_ORDERS - orderCount; }
    function acceptNewOrders() external view returns (bool) { return !_paused && orderCount < OTC_MAX_ORDERS; }
    function getOperatorAddress() external view returns (address) { return operator; }
    function getTreasuryAddress() external view returns (address) { return treasury; }
    function getEscrowKeeperAddress() external view returns (address) { return escrowKeeper; }
    function getDeployBlockNumber() external view returns (uint256) { return deployBlock; }
    function getNamespace() external pure returns (bytes32) { return OTC_NAMESPACE; }
    function getMaxOrders() external pure returns (uint256) { return OTC_MAX_ORDERS; }
    function getViewBatchSize() external pure returns (uint256) { return OTC_VIEW_BATCH; }
    function getAssetTypeCrypto() external pure returns (uint8) { return uint8(OTC_ASSET_CRYPTO); }
    function getAssetTypeRwa() external pure returns (uint8) { return uint8(OTC_ASSET_RWA); }
    function getStatusOpen() external pure returns (uint8) { return uint8(STATUS_OPEN); }
    function getStatusFilled() external pure returns (uint8) { return uint8(STATUS_FILLED); }
    function getStatusCancelled() external pure returns (uint8) { return uint8(STATUS_CANCELLED); }
    function getBpsDenom() external pure returns (uint256) { return OTC_BPS_DENOM; }
    function getVersion() external pure returns (uint256) { return OTC_VERSION; }

    function oid(bytes32 orderId) external view returns (bytes32) { return _orders[orderId].orderId; }
    function mak(bytes32 orderId) external view returns (address) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.maker; }
    function atype(bytes32 orderId) external view returns (uint8) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.assetType; }
    function aid(bytes32 orderId) external view returns (bytes32) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.assetId; }
    function amt(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.amount; }
    function prc(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.pricePerUnit; }
    function sell(bytes32 orderId) external view returns (bool) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.isSell; }
    function filled(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.filledAmount; }
    function st(bytes32 orderId) external view returns (uint8) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.status; }
    function created(bytes32 orderId) external view returns (uint256) { Order storage o = _orders[orderId]; if (o.maker == address(0)) revert OTC_OrderNotFound(); return o.createdAt; }
    function len() external view returns (uint256) { return _orderIds.length; }
    function pausedFlag() external view returns (bool) { return _paused; }
    function minWei() external view returns (uint256) { return minOrderWei; }
    function feeBpsVal() external view returns (uint256) { return feeBps; }
    function totalFeesWei() external view returns (uint256) { return totalFeesCollected; }
    function op() external view returns (address) { return operator; }
    function tr() external view returns (address) { return treasury; }
    function ek() external view returns (address) { return escrowKeeper; }
    function blk() external view returns (uint256) { return deployBlock; }
    function ns() external pure returns (bytes32) { return OTC_NAMESPACE; }
    function maxOrd() external pure returns (uint256) { return OTC_MAX_ORDERS; }
    function batchSz() external pure returns (uint256) { return OTC_VIEW_BATCH; }
    function astCrypto() external pure returns (uint8) { return uint8(OTC_ASSET_CRYPTO); }
    function astRwa() external pure returns (uint8) { return uint8(OTC_ASSET_RWA); }
    function stOpen() external pure returns (uint8) { return uint8(STATUS_OPEN); }
    function stFilled() external pure returns (uint8) { return uint8(STATUS_FILLED); }
    function stCancelled() external pure returns (uint8) { return uint8(STATUS_CANCELLED); }
    function bps() external pure returns (uint256) { return OTC_BPS_DENOM; }
    function ver() external pure returns (uint256) { return OTC_VERSION; }
    function ordCount() external view returns (uint256) { return orderCount; }
    function slotsLeft() external view returns (uint256) { return orderCount >= OTC_MAX_ORDERS ? 0 : OTC_MAX_ORDERS - orderCount; }
    function canOrder() external view returns (bool) { return !_paused && orderCount < OTC_MAX_ORDERS; }

    function ref0() external pure returns (uint256) { return 0; }
    function ref1() external pure returns (uint256) { return 1; }
    function ref2() external pure returns (uint256) { return 2; }
    function ref3() external pure returns (uint256) { return 3; }
    function ref4() external pure returns (uint256) { return 4; }
    function ref5() external pure returns (uint256) { return 5; }
    function ref6() external pure returns (uint256) { return 6; }
    function ref7() external pure returns (uint256) { return 7; }
    function ref8() external pure returns (uint256) { return 8; }
    function ref9() external pure returns (uint256) { return 9; }
    function ref10() external pure returns (uint256) { return 10; }
    function ref11() external pure returns (uint256) { return 11; }
    function ref12() external pure returns (uint256) { return 12; }
    function ref13() external pure returns (uint256) { return 13; }
    function ref14() external pure returns (uint256) { return 14; }
    function ref15() external pure returns (uint256) { return 15; }
    function ref16() external pure returns (uint256) { return 16; }
    function ref17() external pure returns (uint256) { return 17; }
    function ref18() external pure returns (uint256) { return 18; }
    function ref19() external pure returns (uint256) { return 19; }
    function ref20() external pure returns (uint256) { return 20; }
    function ref21() external pure returns (uint256) { return 21; }
    function ref22() external pure returns (uint256) { return 22; }
    function ref23() external pure returns (uint256) { return 23; }
    function ref24() external pure returns (uint256) { return 24; }
    function ref25() external pure returns (uint256) { return 25; }
    function ref26() external pure returns (uint256) { return 26; }
    function ref27() external pure returns (uint256) { return 27; }
    function ref28() external pure returns (uint256) { return 28; }
    function ref29() external pure returns (uint256) { return 29; }
    function ref30() external pure returns (uint256) { return 30; }
    function ref31() external pure returns (uint256) { return 31; }
    function ref32() external pure returns (uint256) { return 32; }
    function ref33() external pure returns (uint256) { return 33; }
    function ref34() external pure returns (uint256) { return 34; }
    function ref35() external pure returns (uint256) { return 35; }
    function ref36() external pure returns (uint256) { return 36; }
    function ref37() external pure returns (uint256) { return 37; }
    function ref38() external pure returns (uint256) { return 38; }
    function ref39() external pure returns (uint256) { return 39; }
    function ref40() external pure returns (uint256) { return 40; }
    function ref41() external pure returns (uint256) { return 41; }
    function ref42() external pure returns (uint256) { return 42; }
    function ref43() external pure returns (uint256) { return 43; }
    function ref44() external pure returns (uint256) { return 44; }
    function ref45() external pure returns (uint256) { return 45; }
    function ref46() external pure returns (uint256) { return 46; }
    function ref47() external pure returns (uint256) { return 47; }
    function ref48() external pure returns (uint256) { return 48; }
    function ref49() external pure returns (uint256) { return 49; }
    function ref50() external pure returns (uint256) { return 50; }
    function ref51() external pure returns (uint256) { return 51; }
    function ref52() external pure returns (uint256) { return 52; }
    function ref53() external pure returns (uint256) { return 53; }
    function ref54() external pure returns (uint256) { return 54; }
    function ref55() external pure returns (uint256) { return 55; }
    function ref56() external pure returns (uint256) { return 56; }
    function ref57() external pure returns (uint256) { return 57; }
    function ref58() external pure returns (uint256) { return 58; }
    function ref59() external pure returns (uint256) { return 59; }
    function ref60() external pure returns (uint256) { return 60; }
    function ref61() external pure returns (uint256) { return 61; }
    function ref62() external pure returns (uint256) { return 62; }
    function ref63() external pure returns (uint256) { return 63; }
    function ref64() external pure returns (uint256) { return 64; }
    function ref65() external pure returns (uint256) { return 65; }
    function ref66() external pure returns (uint256) { return 66; }
    function ref67() external pure returns (uint256) { return 67; }
    function ref68() external pure returns (uint256) { return 68; }
    function ref69() external pure returns (uint256) { return 69; }
    function ref70() external pure returns (uint256) { return 70; }
    function ref71() external pure returns (uint256) { return 71; }
    function ref72() external pure returns (uint256) { return 72; }
    function ref73() external pure returns (uint256) { return 73; }
    function ref74() external pure returns (uint256) { return 74; }
    function ref75() external pure returns (uint256) { return 75; }
    function ref76() external pure returns (uint256) { return 76; }
    function ref77() external pure returns (uint256) { return 77; }
    function ref78() external pure returns (uint256) { return 78; }
    function ref79() external pure returns (uint256) { return 79; }
    function ref80() external pure returns (uint256) { return 80; }
    function ref81() external pure returns (uint256) { return 81; }
    function ref82() external pure returns (uint256) { return 82; }
    function ref83() external pure returns (uint256) { return 83; }
    function ref84() external pure returns (uint256) { return 84; }
    function ref85() external pure returns (uint256) { return 85; }
    function ref86() external pure returns (uint256) { return 86; }
    function ref87() external pure returns (uint256) { return 87; }
    function ref88() external pure returns (uint256) { return 88; }
    function ref89() external pure returns (uint256) { return 89; }
    function ref90() external pure returns (uint256) { return 90; }
    function ref91() external pure returns (uint256) { return 91; }
    function ref92() external pure returns (uint256) { return 92; }
    function ref93() external pure returns (uint256) { return 93; }
    function ref94() external pure returns (uint256) { return 94; }
    function ref95() external pure returns (uint256) { return 95; }
    function ref96() external pure returns (uint256) { return 96; }
    function ref97() external pure returns (uint256) { return 97; }
    function ref98() external pure returns (uint256) { return 98; }
    function ref99() external pure returns (uint256) { return 99; }
    function ref100() external pure returns (uint256) { return 100; }
    function ref101() external pure returns (uint256) { return 101; }
    function ref102() external pure returns (uint256) { return 102; }
    function ref103() external pure returns (uint256) { return 103; }
    function ref104() external pure returns (uint256) { return 104; }
    function ref105() external pure returns (uint256) { return 105; }
    function ref106() external pure returns (uint256) { return 106; }
    function ref107() external pure returns (uint256) { return 107; }
    function ref108() external pure returns (uint256) { return 108; }
    function ref109() external pure returns (uint256) { return 109; }
    function ref110() external pure returns (uint256) { return 110; }
    function ref111() external pure returns (uint256) { return 111; }
    function ref112() external pure returns (uint256) { return 112; }
    function ref113() external pure returns (uint256) { return 113; }
    function ref114() external pure returns (uint256) { return 114; }
    function ref115() external pure returns (uint256) { return 115; }
    function ref116() external pure returns (uint256) { return 116; }
    function ref117() external pure returns (uint256) { return 117; }
    function ref118() external pure returns (uint256) { return 118; }
    function ref119() external pure returns (uint256) { return 119; }
    function ref120() external pure returns (uint256) { return 120; }
    function ref121() external pure returns (uint256) { return 121; }
    function ref122() external pure returns (uint256) { return 122; }
    function ref123() external pure returns (uint256) { return 123; }
    function ref124() external pure returns (uint256) { return 124; }
    function ref125() external pure returns (uint256) { return 125; }
    function ref126() external pure returns (uint256) { return 126; }
    function ref127() external pure returns (uint256) { return 127; }
    function ref128() external pure returns (uint256) { return 128; }
    function ref129() external pure returns (uint256) { return 129; }
    function ref130() external pure returns (uint256) { return 130; }
    function ref131() external pure returns (uint256) { return 131; }
    function ref132() external pure returns (uint256) { return 132; }
    function ref133() external pure returns (uint256) { return 133; }
    function ref134() external pure returns (uint256) { return 134; }
    function ref135() external pure returns (uint256) { return 135; }
    function ref136() external pure returns (uint256) { return 136; }
    function ref137() external pure returns (uint256) { return 137; }
    function ref138() external pure returns (uint256) { return 138; }
    function ref139() external pure returns (uint256) { return 139; }
    function ref140() external pure returns (uint256) { return 140; }
    function ref141() external pure returns (uint256) { return 141; }
    function ref142() external pure returns (uint256) { return 142; }
    function ref143() external pure returns (uint256) { return 143; }
    function ref144() external pure returns (uint256) { return 144; }
    function ref145() external pure returns (uint256) { return 145; }
    function ref146() external pure returns (uint256) { return 146; }
    function ref147() external pure returns (uint256) { return 147; }
    function ref148() external pure returns (uint256) { return 148; }
    function ref149() external pure returns (uint256) { return 149; }
    function ref150() external pure returns (uint256) { return 150; }
    function ref151() external pure returns (uint256) { return 151; }
    function ref152() external pure returns (uint256) { return 152; }
    function ref153() external pure returns (uint256) { return 153; }
    function ref154() external pure returns (uint256) { return 154; }
    function ref155() external pure returns (uint256) { return 155; }
    function ref156() external pure returns (uint256) { return 156; }
    function ref157() external pure returns (uint256) { return 157; }
    function ref158() external pure returns (uint256) { return 158; }
    function ref159() external pure returns (uint256) { return 159; }
    function ref160() external pure returns (uint256) { return 160; }
    function ref161() external pure returns (uint256) { return 161; }
    function ref162() external pure returns (uint256) { return 162; }
    function ref163() external pure returns (uint256) { return 163; }
    function ref164() external pure returns (uint256) { return 164; }
    function ref165() external pure returns (uint256) { return 165; }
    function ref166() external pure returns (uint256) { return 166; }
    function ref167() external pure returns (uint256) { return 167; }
    function ref168() external pure returns (uint256) { return 168; }
    function ref169() external pure returns (uint256) { return 169; }
    function ref170() external pure returns (uint256) { return 170; }
    function ref171() external pure returns (uint256) { return 171; }
    function ref172() external pure returns (uint256) { return 172; }
    function ref173() external pure returns (uint256) { return 173; }
    function ref174() external pure returns (uint256) { return 174; }
    function ref175() external pure returns (uint256) { return 175; }
    function ref176() external pure returns (uint256) { return 176; }
    function ref177() external pure returns (uint256) { return 177; }
    function ref178() external pure returns (uint256) { return 178; }
    function ref179() external pure returns (uint256) { return 179; }
    function ref180() external pure returns (uint256) { return 180; }
    function ref181() external pure returns (uint256) { return 181; }
    function ref182() external pure returns (uint256) { return 182; }
    function ref183() external pure returns (uint256) { return 183; }
    function ref184() external pure returns (uint256) { return 184; }
    function ref185() external pure returns (uint256) { return 185; }
    function ref186() external pure returns (uint256) { return 186; }
    function ref187() external pure returns (uint256) { return 187; }
    function ref188() external pure returns (uint256) { return 188; }
    function ref189() external pure returns (uint256) { return 189; }
    function ref190() external pure returns (uint256) { return 190; }
    function ref191() external pure returns (uint256) { return 191; }
    function ref192() external pure returns (uint256) { return 192; }
    function ref193() external pure returns (uint256) { return 193; }
    function ref194() external pure returns (uint256) { return 194; }
    function ref195() external pure returns (uint256) { return 195; }
    function ref196() external pure returns (uint256) { return 196; }
    function ref197() external pure returns (uint256) { return 197; }
    function ref198() external pure returns (uint256) { return 198; }
    function ref199() external pure returns (uint256) { return 199; }
    function ref200() external pure returns (uint256) { return 200; }
    function ref201() external pure returns (uint256) { return 201; }
    function ref202() external pure returns (uint256) { return 202; }
    function ref203() external pure returns (uint256) { return 203; }
    function ref204() external pure returns (uint256) { return 204; }
    function ref205() external pure returns (uint256) { return 205; }
    function ref206() external pure returns (uint256) { return 206; }
    function ref207() external pure returns (uint256) { return 207; }
    function ref208() external pure returns (uint256) { return 208; }
    function ref209() external pure returns (uint256) { return 209; }
    function ref210() external pure returns (uint256) { return 210; }
    function ref211() external pure returns (uint256) { return 211; }
    function ref212() external pure returns (uint256) { return 212; }
    function ref213() external pure returns (uint256) { return 213; }
    function ref214() external pure returns (uint256) { return 214; }
    function ref215() external pure returns (uint256) { return 215; }
    function ref216() external pure returns (uint256) { return 216; }
    function ref217() external pure returns (uint256) { return 217; }
    function ref218() external pure returns (uint256) { return 218; }
    function ref219() external pure returns (uint256) { return 219; }
    function ref220() external pure returns (uint256) { return 220; }
    function ref221() external pure returns (uint256) { return 221; }
    function ref222() external pure returns (uint256) { return 222; }
    function ref223() external pure returns (uint256) { return 223; }
    function ref224() external pure returns (uint256) { return 224; }
    function ref225() external pure returns (uint256) { return 225; }
    function ref226() external pure returns (uint256) { return 226; }
    function ref227() external pure returns (uint256) { return 227; }
    function ref228() external pure returns (uint256) { return 228; }
    function ref229() external pure returns (uint256) { return 229; }
    function ref230() external pure returns (uint256) { return 230; }
    function ref231() external pure returns (uint256) { return 231; }
    function ref232() external pure returns (uint256) { return 232; }
    function ref233() external pure returns (uint256) { return 233; }
    function ref234() external pure returns (uint256) { return 234; }
    function ref235() external pure returns (uint256) { return 235; }
    function ref236() external pure returns (uint256) { return 236; }
    function ref237() external pure returns (uint256) { return 237; }
    function ref238() external pure returns (uint256) { return 238; }
    function ref239() external pure returns (uint256) { return 239; }
    function ref240() external pure returns (uint256) { return 240; }
    function ref241() external pure returns (uint256) { return 241; }
    function ref242() external pure returns (uint256) { return 242; }
    function ref243() external pure returns (uint256) { return 243; }
    function ref244() external pure returns (uint256) { return 244; }
    function ref245() external pure returns (uint256) { return 245; }
    function ref246() external pure returns (uint256) { return 246; }
    function ref247() external pure returns (uint256) { return 247; }
    function ref248() external pure returns (uint256) { return 248; }
    function ref249() external pure returns (uint256) { return 249; }
    function ref250() external pure returns (uint256) { return 250; }
    function ref251() external pure returns (uint256) { return 251; }
    function ref252() external pure returns (uint256) { return 252; }
    function ref253() external pure returns (uint256) { return 253; }
    function ref254() external pure returns (uint256) { return 254; }
    function ref255() external pure returns (uint256) { return 255; }
    function ref256() external pure returns (uint256) { return 256; }
    function ref257() external pure returns (uint256) { return 257; }
    function ref258() external pure returns (uint256) { return 258; }
    function ref259() external pure returns (uint256) { return 259; }
    function ref260() external pure returns (uint256) { return 260; }
    function ref261() external pure returns (uint256) { return 261; }
    function ref262() external pure returns (uint256) { return 262; }
    function ref263() external pure returns (uint256) { return 263; }
    function ref264() external pure returns (uint256) { return 264; }
    function ref265() external pure returns (uint256) { return 265; }
    function ref266() external pure returns (uint256) { return 266; }
    function ref267() external pure returns (uint256) { return 267; }
    function ref268() external pure returns (uint256) { return 268; }
    function ref269() external pure returns (uint256) { return 269; }
    function ref270() external pure returns (uint256) { return 270; }
    function ref271() external pure returns (uint256) { return 271; }
    function ref272() external pure returns (uint256) { return 272; }
    function ref273() external pure returns (uint256) { return 273; }
    function ref274() external pure returns (uint256) { return 274; }
    function ref275() external pure returns (uint256) { return 275; }
    function ref276() external pure returns (uint256) { return 276; }
    function ref277() external pure returns (uint256) { return 277; }
    function ref278() external pure returns (uint256) { return 278; }
    function ref279() external pure returns (uint256) { return 279; }
    function ref280() external pure returns (uint256) { return 280; }
    function ref281() external pure returns (uint256) { return 281; }
    function ref282() external pure returns (uint256) { return 282; }
    function ref283() external pure returns (uint256) { return 283; }
    function ref284() external pure returns (uint256) { return 284; }
    function ref285() external pure returns (uint256) { return 285; }
    function ref286() external pure returns (uint256) { return 286; }
    function ref287() external pure returns (uint256) { return 287; }
    function ref288() external pure returns (uint256) { return 288; }
    function ref289() external pure returns (uint256) { return 289; }
    function ref290() external pure returns (uint256) { return 290; }
    function ref291() external pure returns (uint256) { return 291; }
    function ref292() external pure returns (uint256) { return 292; }
    function ref293() external pure returns (uint256) { return 293; }
    function ref294() external pure returns (uint256) { return 294; }
    function ref295() external pure returns (uint256) { return 295; }
    function ref296() external pure returns (uint256) { return 296; }
    function ref297() external pure returns (uint256) { return 297; }
    function ref298() external pure returns (uint256) { return 298; }
    function ref299() external pure returns (uint256) { return 299; }
    function ref300() external pure returns (uint256) { return 300; }
    function ref301() external pure returns (uint256) { return 301; }
    function ref302() external pure returns (uint256) { return 302; }
    function ref303() external pure returns (uint256) { return 303; }
    function ref304() external pure returns (uint256) { return 304; }
    function ref305() external pure returns (uint256) { return 305; }
    function ref306() external pure returns (uint256) { return 306; }
    function ref307() external pure returns (uint256) { return 307; }
    function ref308() external pure returns (uint256) { return 308; }
    function ref309() external pure returns (uint256) { return 309; }
    function ref310() external pure returns (uint256) { return 310; }
    function ref311() external pure returns (uint256) { return 311; }
    function ref312() external pure returns (uint256) { return 312; }
    function ref313() external pure returns (uint256) { return 313; }
    function ref314() external pure returns (uint256) { return 314; }
    function ref315() external pure returns (uint256) { return 315; }
    function ref316() external pure returns (uint256) { return 316; }
    function ref317() external pure returns (uint256) { return 317; }
    function ref318() external pure returns (uint256) { return 318; }
    function ref319() external pure returns (uint256) { return 319; }
    function ref320() external pure returns (uint256) { return 320; }
    function ref321() external pure returns (uint256) { return 321; }
    function ref322() external pure returns (uint256) { return 322; }
    function ref323() external pure returns (uint256) { return 323; }
    function ref324() external pure returns (uint256) { return 324; }
    function ref325() external pure returns (uint256) { return 325; }
    function ref326() external pure returns (uint256) { return 326; }
    function ref327() external pure returns (uint256) { return 327; }
    function ref328() external pure returns (uint256) { return 328; }
    function ref329() external pure returns (uint256) { return 329; }
    function ref330() external pure returns (uint256) { return 330; }
    function ref331() external pure returns (uint256) { return 331; }
    function ref332() external pure returns (uint256) { return 332; }
    function ref333() external pure returns (uint256) { return 333; }
    function ref334() external pure returns (uint256) { return 334; }
    function ref335() external pure returns (uint256) { return 335; }
    function ref336() external pure returns (uint256) { return 336; }
    function ref337() external pure returns (uint256) { return 337; }
    function ref338() external pure returns (uint256) { return 338; }
    function ref339() external pure returns (uint256) { return 339; }
    function ref340() external pure returns (uint256) { return 340; }
    function ref341() external pure returns (uint256) { return 341; }
    function ref342() external pure returns (uint256) { return 342; }
    function ref343() external pure returns (uint256) { return 343; }
    function ref344() external pure returns (uint256) { return 344; }
    function ref345() external pure returns (uint256) { return 345; }
    function ref346() external pure returns (uint256) { return 346; }
    function ref347() external pure returns (uint256) { return 347; }
    function ref348() external pure returns (uint256) { return 348; }
    function ref349() external pure returns (uint256) { return 349; }
    function ref350() external pure returns (uint256) { return 350; }
    function ref351() external pure returns (uint256) { return 351; }
    function ref352() external pure returns (uint256) { return 352; }
    function ref353() external pure returns (uint256) { return 353; }
    function ref354() external pure returns (uint256) { return 354; }
    function ref355() external pure returns (uint256) { return 355; }
    function ref356() external pure returns (uint256) { return 356; }
    function ref357() external pure returns (uint256) { return 357; }
    function ref358() external pure returns (uint256) { return 358; }
    function ref359() external pure returns (uint256) { return 359; }
    function ref360() external pure returns (uint256) { return 360; }
    function ref361() external pure returns (uint256) { return 361; }
    function ref362() external pure returns (uint256) { return 362; }
    function ref363() external pure returns (uint256) { return 363; }
    function ref364() external pure returns (uint256) { return 364; }
    function ref365() external pure returns (uint256) { return 365; }
    function ref366() external pure returns (uint256) { return 366; }
    function ref367() external pure returns (uint256) { return 367; }
    function ref368() external pure returns (uint256) { return 368; }
    function ref369() external pure returns (uint256) { return 369; }
    function ref370() external pure returns (uint256) { return 370; }
    function ref371() external pure returns (uint256) { return 371; }
    function ref372() external pure returns (uint256) { return 372; }
    function ref373() external pure returns (uint256) { return 373; }
    function ref374() external pure returns (uint256) { return 374; }
    function ref375() external pure returns (uint256) { return 375; }
    function ref376() external pure returns (uint256) { return 376; }
    function ref377() external pure returns (uint256) { return 377; }
    function ref378() external pure returns (uint256) { return 378; }
    function ref379() external pure returns (uint256) { return 379; }
    function ref380() external pure returns (uint256) { return 380; }
    function ref381() external pure returns (uint256) { return 381; }
    function ref382() external pure returns (uint256) { return 382; }
    function ref383() external pure returns (uint256) { return 383; }
    function ref384() external pure returns (uint256) { return 384; }
    function ref385() external pure returns (uint256) { return 385; }
    function ref386() external pure returns (uint256) { return 386; }
    function ref387() external pure returns (uint256) { return 387; }
    function ref388() external pure returns (uint256) { return 388; }
    function ref389() external pure returns (uint256) { return 389; }
    function ref390() external pure returns (uint256) { return 390; }
    function ref391() external pure returns (uint256) { return 391; }
    function ref392() external pure returns (uint256) { return 392; }
    function ref393() external pure returns (uint256) { return 393; }
    function ref394() external pure returns (uint256) { return 394; }
    function ref395() external pure returns (uint256) { return 395; }
    function ref396() external pure returns (uint256) { return 396; }
    function ref397() external pure returns (uint256) { return 397; }
    function ref398() external pure returns (uint256) { return 398; }
    function ref399() external pure returns (uint256) { return 399; }
    function ref400() external pure returns (uint256) { return 400; }
    function ref401() external pure returns (uint256) { return 401; }
    function ref402() external pure returns (uint256) { return 402; }
    function ref403() external pure returns (uint256) { return 403; }
    function ref404() external pure returns (uint256) { return 404; }
    function ref405() external pure returns (uint256) { return 405; }
    function ref406() external pure returns (uint256) { return 406; }
    function ref407() external pure returns (uint256) { return 407; }
    function ref408() external pure returns (uint256) { return 408; }
    function ref409() external pure returns (uint256) { return 409; }
    function ref410() external pure returns (uint256) { return 410; }
    function ref411() external pure returns (uint256) { return 411; }
    function ref412() external pure returns (uint256) { return 412; }
    function ref413() external pure returns (uint256) { return 413; }
    function ref414() external pure returns (uint256) { return 414; }
    function ref415() external pure returns (uint256) { return 415; }
    function ref416() external pure returns (uint256) { return 416; }
    function ref417() external pure returns (uint256) { return 417; }
    function ref418() external pure returns (uint256) { return 418; }
    function ref419() external pure returns (uint256) { return 419; }
    function ref420() external pure returns (uint256) { return 420; }
    function ref421() external pure returns (uint256) { return 421; }
    function ref422() external pure returns (uint256) { return 422; }
    function ref423() external pure returns (uint256) { return 423; }
    function ref424() external pure returns (uint256) { return 424; }
    function ref425() external pure returns (uint256) { return 425; }
    function ref426() external pure returns (uint256) { return 426; }
    function ref427() external pure returns (uint256) { return 427; }
    function ref428() external pure returns (uint256) { return 428; }
    function ref429() external pure returns (uint256) { return 429; }
    function ref430() external pure returns (uint256) { return 430; }
    function ref431() external pure returns (uint256) { return 431; }
    function ref432() external pure returns (uint256) { return 432; }
    function ref433() external pure returns (uint256) { return 433; }
    function ref434() external pure returns (uint256) { return 434; }
    function ref435() external pure returns (uint256) { return 435; }
    function ref436() external pure returns (uint256) { return 436; }
    function ref437() external pure returns (uint256) { return 437; }
    function ref438() external pure returns (uint256) { return 438; }
    function ref439() external pure returns (uint256) { return 439; }
    function ref440() external pure returns (uint256) { return 440; }
    function ref441() external pure returns (uint256) { return 441; }
    function ref442() external pure returns (uint256) { return 442; }
    function ref443() external pure returns (uint256) { return 443; }
    function ref444() external pure returns (uint256) { return 444; }
    function ref445() external pure returns (uint256) { return 445; }
    function ref446() external pure returns (uint256) { return 446; }
    function ref447() external pure returns (uint256) { return 447; }
    function ref448() external pure returns (uint256) { return 448; }
    function ref449() external pure returns (uint256) { return 449; }
    function ref450() external pure returns (uint256) { return 450; }
    function ref451() external pure returns (uint256) { return 451; }
    function ref452() external pure returns (uint256) { return 452; }
    function ref453() external pure returns (uint256) { return 453; }
    function ref454() external pure returns (uint256) { return 454; }
    function ref455() external pure returns (uint256) { return 455; }
    function ref456() external pure returns (uint256) { return 456; }
    function ref457() external pure returns (uint256) { return 457; }
    function ref458() external pure returns (uint256) { return 458; }
    function ref459() external pure returns (uint256) { return 459; }
    function ref460() external pure returns (uint256) { return 460; }
    function ref461() external pure returns (uint256) { return 461; }
    function ref462() external pure returns (uint256) { return 462; }
    function ref463() external pure returns (uint256) { return 463; }
    function ref464() external pure returns (uint256) { return 464; }
    function ref465() external pure returns (uint256) { return 465; }
    function ref466() external pure returns (uint256) { return 466; }
    function ref467() external pure returns (uint256) { return 467; }
    function ref468() external pure returns (uint256) { return 468; }
    function ref469() external pure returns (uint256) { return 469; }
    function ref470() external pure returns (uint256) { return 470; }
    function ref471() external pure returns (uint256) { return 471; }
    function ref472() external pure returns (uint256) { return 472; }
    function ref473() external pure returns (uint256) { return 473; }
    function ref474() external pure returns (uint256) { return 474; }
    function ref475() external pure returns (uint256) { return 475; }

    receive() external payable {}
}

/*
 * Otc — OTC platform for crypto and RWA.
 * Mainnet-safe: reentrancy guard, pause, immutable roles.
 * Order lifecycle: post -> fill -> (optional) settle (RWA).
 * Fees: feeBps (basis points) on fill value to treasury.
 * Constants: OTC_MAX_ORDERS 512, OTC_VIEW_BATCH 48, OTC_ASSET_CRYPTO 0, OTC_ASSET_RWA 1.
 * Immutable: operator, treasury, escrowKeeper, deployBlock.
 * Events: OrderPosted, OrderFilled, OrderCancelled, SettlementReleased, TreasuryFee, PlatformPaused, PlatformResumed, MinOrderUpdated, FeeBpsUpdated, RwaOrderPosted.
 * Errors: OTC_ZeroAddress, OTC_NotOperator, OTC_NotEscrowKeeper, OTC_OrderNotFound, OTC_OrderNotOpen, OTC_OrderAlreadyFilled, OTC_OrderAlreadyCancelled, OTC_InvalidAssetType, OTC_ZeroAmount, OTC_ZeroPrice, OTC_BelowMinOrder, OTC_ExceedsOrderAmount, OTC_TransferFailed, OTC_Paused, OTC_InvalidOrderId, OTC_SettlementNotReady, OTC_Reentrant, OTC_FeeBpsTooHigh, OTC_OrderLimitReached, OTC_IndexOutOfRange.
 *
 * ABI summary: postOrder(assetType, assetId, amount, pricePerUnit, isSell) payable -> orderId; fillOrder(orderId, fillAmount) payable; cancelOrder(orderId); getOrder(orderId); orderIdsBatch(offset, limit); getOrderView(orderId); getPlatformStats(); getOrderSummary(orderId); getOrderViewsBatch(offset, limit); getOpenOrderIds(maxReturn); cancelOrders(orderIds[]); recordRwaFill(orderId, taker, fillAmount) onlyEscrowKeeper; releaseRwaSettlement(orderId, feeWei) onlyEscrowKeeper; pause/unpause/setMinOrderWei/setFeeBps onlyOperator.
 * Addresses (immutable): operator 0x1a2b3c4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5, treasury 0x2b3c4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5f6, escrowKeeper 0x3c4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5f678.
 * Namespace: 0x4d5e6f7890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e
 *
 * --- OTC Platform Reference ---
 * Post: postOrder(assetType, assetId, amount, pricePerUnit, isSell) payable. For crypto sell, send amount wei.
 * Fill: fillOrder(orderId, fillAmount) payable. For buy, send fillAmount*pricePerUnit/1e18 wei. Fee sent to treasury.
 * Cancel: cancelOrder(orderId). Maker or operator. Crypto sell: unfilled wei returned to maker.
 * RWA: recordRwaFill(orderId, taker, fillAmount) by escrowKeeper; then releaseRwaSettlement(orderId, feeWei).
 * Views: getOrder, getOrderView, getOrderSummary, getOrderViewByIndex, getOrderViewsBatch, getOrderSummariesBatch.
 * Batch: orderIdsBatch, getOpenOrderIds, getCryptoOrderIdsBatch, getRwaOrderIdsBatch, getSellOrderIdsBatch, getBuyOrderIdsBatch.
 * Stats: getPlatformStats, getPlatformStatsCompact, getOpenOrderCount, totalOrderCount.
 * Roles: getOperator, getTreasury, getEscrowKeeper (immutable). Pause: pause/unpause onlyOperator. Config: setMinOrderWei, setFeeBps onlyOperator.
 * Safe: nonReentrant on postOrder, fillOrder, cancelOrder, cancelOrders, releaseRwaSettlement. whenNotPaused on post, fill.
 */

