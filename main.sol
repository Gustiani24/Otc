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
