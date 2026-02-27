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
