// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// If you use OpenZeppelin, prefer these imports:
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";

// Using your local imports as you had:
import "./SafeERC20.sol";
import "./ReentrancyGuard.sol";
import "./KeeperCompatibleInterface.sol";

contract SubscriptionService is ReentrancyGuard, KeeperCompatibleInterface {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant SUBSCRIPTION_INTERVAL = 30 days;
    uint256 public constant MINIMUM_BALANCE = 0.1 ether; // Minimum balance to receive payments (display/UX only)

    // Structs
    struct Tier {
        uint256 price;
        string description;
    }

    struct CreatorInfo {
        Tier[] tiers;
        mapping(uint256 => uint256) tierPrices; // tierId => price
        uint256 nextTierId;
    }

    struct Subscription {
        uint256 tierId;
        bool active;
        uint256 lastPaymentTimestamp;
    }

    // State Variables
    IERC20 public paymentToken;
    mapping(address => CreatorInfo) public creators;
    mapping(address => mapping(address => Subscription)) public subscriptions;
    mapping(address => address[]) public creatorSubscribers;
    mapping(address => mapping(address => uint256)) public nextChargeTime;
    address[] public creatorKeys;

    // Track the globally next due subscription for efficient checkUpkeep
    uint256 public nextChargeTimestamp;
    address public nextChargeCreator;
    address public nextChargeSubscriber;

    // Events
    event SubscriptionCreated(
        address indexed creator,
        address indexed subscriber,
        uint256 tierId,
        uint256 price
    );
    event SubscriptionCharged(
        address indexed creator,
        address indexed subscriber,
        uint256 tierId,
        uint256 amount
    );
    event SubscriptionCancelled(
        address indexed creator,
        address indexed subscriber,
        uint256 tierId
    );

    // Modifiers
    modifier onlyActiveCreator() {
        bool isCreator = false;
        for (uint256 i = 0; i < creatorKeys.length; i++) {
            if (creatorKeys[i] == msg.sender) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Not a creator");
        _;
    }

    constructor(address _paymentToken) {
        paymentToken = IERC20(_paymentToken);
        nextChargeTimestamp = type(uint256).max;
        creatorKeys.push(msg.sender); // Auto-add deployer as creator
    }

    function addCreator(address _creator) public {
        // only existing creators can add a new creator
        bool isCreator = false;
        for (uint256 i = 0; i < creatorKeys.length; i++) {
            if (creatorKeys[i] == msg.sender) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Only creators can add other creators");

        // Add the new creator if not already added
        for (uint256 i = 0; i < creatorKeys.length; i++) {
            if (creatorKeys[i] == _creator) {
                return; // Already a creator
            }
        }
        creatorKeys.push(_creator);
    }

    // Creator functions
    function addTier(uint256 _price, string memory _description) external onlyActiveCreator {
        CreatorInfo storage creator = creators[msg.sender];
        uint256 newTierId = creator.nextTierId++;
        creator.tiers.push(Tier({price: _price, description: _description}));
        creator.tierPrices[newTierId] = _price;
    }

    function subscribe(address _creator, uint256 _tierId) external payable nonReentrant {
        require(creators[_creator].tierPrices[_tierId] > 0, "Invalid tier");
        require(!subscriptions[_creator][msg.sender].active, "Already subscribed");

        uint256 price = creators[_creator].tierPrices[_tierId];
        uint256 allowance = paymentToken.allowance(msg.sender, address(this));
        require(allowance >= price, "Insufficient allowance");

        // First payment
        paymentToken.safeTransferFrom(msg.sender, _creator, price);

        // Create subscription
        Subscription storage newSub = subscriptions[_creator][msg.sender];
        newSub.tierId = _tierId;
        newSub.active = true;
        newSub.lastPaymentTimestamp = block.timestamp;

        // Update tracking
        creatorSubscribers[_creator].push(msg.sender);
        uint256 nextCharge = block.timestamp + SUBSCRIPTION_INTERVAL;
        nextChargeTime[_creator][msg.sender] = nextCharge;

        // Update global next charge if this is the earliest
        if (nextCharge < nextChargeTimestamp) {
            nextChargeTimestamp = nextCharge;
            nextChargeCreator = _creator;
            nextChargeSubscriber = msg.sender;
        }

        emit SubscriptionCreated(_creator, msg.sender, _tierId, price);
    }

    // 🔧 FIX: remove nonReentrant here — it's an internal helper called by external nonReentrant functions
    function _cancelSubscription(address _creator, address _subscriber) internal {
        Subscription storage sub = subscriptions[_creator][_subscriber];
        require(sub.active, "Not subscribed");

        sub.active = false;
        delete nextChargeTime[_creator][_subscriber];

        // Remove from creator's subscriber list
        address[] storage subs = creatorSubscribers[_creator];
        for (uint256 i = 0; i < subs.length; i++) {
            if (subs[i] == _subscriber) {
                subs[i] = subs[subs.length - 1];
                subs.pop();
                break;
            }
        }

        // Update global tracking if needed
        if (_subscriber == nextChargeSubscriber && _creator == nextChargeCreator) {
            _updateNextCharge();
        }

        emit SubscriptionCancelled(_creator, _subscriber, sub.tierId);
    }

    function cancelSubscription(address _creator) external nonReentrant {
        _cancelSubscription(_creator, msg.sender);
    }

    // Keeper functions
    function checkUpkeep(bytes memory /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp >= nextChargeTimestamp);
        if (upkeepNeeded) {
            performData = abi.encode(nextChargeCreator, nextChargeSubscriber);
        }
    }

    function performUpkeep(bytes calldata performData)
        external
        override
        nonReentrant
    {
        require(performData.length >= 64, "Invalid performData");
        (address targetCreator, address targetSubscriber) = abi.decode(performData, (address, address));

        // Verify this is actually the next due subscription
        require(
            targetCreator == nextChargeCreator &&
            targetSubscriber == nextChargeSubscriber &&
            block.timestamp >= nextChargeTimestamp,
            "Invalid subscription"
        );

        _chargeSubscription(targetCreator, targetSubscriber);
    }

    // Internal functions
    function _chargeSubscription(address _creator, address _subscriber) internal {
        Subscription storage sub = subscriptions[_creator][_subscriber];
        require(sub.active, "Subscription inactive");

        uint256 price = creators[_creator].tierPrices[sub.tierId];
        uint256 allowance = paymentToken.allowance(_subscriber, address(this));

        if (allowance < price) {
            _cancelSubscription(_creator, _subscriber); // call internal (non-reentrant) helper
            return;
        }

        paymentToken.safeTransferFrom(_subscriber, _creator, price);
        sub.lastPaymentTimestamp = block.timestamp;
        uint256 nextCharge = block.timestamp + SUBSCRIPTION_INTERVAL;
        nextChargeTime[_creator][_subscriber] = nextCharge;

        emit SubscriptionCharged(_creator, _subscriber, sub.tierId, price);
        _updateNextCharge(); // Update global tracking
    }

    function _updateNextCharge() internal {
        uint256 earliestTime = type(uint256).max;
        address bestCreator = address(0);
        address bestSubscriber = address(0);

        // Loop through all creators
        for (uint256 i = 0; i < creatorKeys.length; i++) {
            address creator = creatorKeys[i];
            // Loop through all subscribers of this creator
            address[] storage subs = creatorSubscribers[creator];
            for (uint256 j = 0; j < subs.length; j++) {
                address subscriber = subs[j];
                uint256 nextTime = nextChargeTime[creator][subscriber];
                if (nextTime > block.timestamp && nextTime < earliestTime) {
                    earliestTime = nextTime;
                    bestCreator = creator;
                    bestSubscriber = subscriber;
                }
            }
        }

        nextChargeTimestamp = earliestTime;
        nextChargeCreator = bestCreator;
        nextChargeSubscriber = bestSubscriber;
    }

    // Optional helpers (good for frontend)
    function getTierPrice(address _creator, uint256 _tierId) external view returns (uint256) {
        return creators[_creator].tierPrices[_tierId];
    }

    function getSubscription(address _creator, address _subscriber)
        external
        view
        returns (uint256 tierId, bool active, uint256 lastPaymentTimestamp)
    {
        Subscription memory s = subscriptions[_creator][_subscriber];
        return (s.tierId, s.active, s.lastPaymentTimestamp);
    }

    // Fallback to receive ETH (if needed). You don't actually use ETH for charges; this just blocks accidental sends if you want.
    receive() external payable {
        require(address(paymentToken) != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), "Use ERC20 token");
    }
}
