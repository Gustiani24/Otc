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
