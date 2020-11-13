// SPDX-License-Identifier: MIT
pragma solidity >=0.6.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface PoolI {
    function rewardDistributed() external returns (uint256);

    function startPool() external;

    function periodFinish() external returns (uint256);
}

interface UnbaseI {
    function totalSupply() external view returns (uint256);

    function balanceOf(address who) external returns (uint256);

    function rebase(uint256 epoch, int256 supplyDelta)
        external
        returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);
}

interface UnbasePolicyI {
    function rebase() external;
}

interface UniV2PairI {
    function sync() external;
}

/**
 * @title Orchestrator
 * @notice The orchestrator is the main entry point for rebase operations. It coordinates the Unbase policy
 *         actions with external consumers.
 */
contract Orchestrator is Ownable, Initializable {
    using SafeMath for uint256;

    // Stable ordering is not guaranteed.
    UnbaseI public Unbase;
    UnbasePolicyI public unbasePolicy;

    PoolI public unbaseDaiPool;
    PoolI public unbaseDaiLpPool;

    PoolI public ungovDaiLpPool;
    bool public rebaseStarted;
    uint256 public maximumRebaseTime;
    uint256 public rebaseRequiredSupply;

    event LogRebaseStarted(uint256 timeStarted);
    event LogAddNewUniPair(address token1, address token2);
    event LogDeleteUniPair(bool enabled, address uniPair);
    event LogSetUniPairEnabled(uint256 index, bool enabled);

    uint256 constant SYNC_GAS = 50000;
    address constant uniFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    struct UniPair {
        bool enabled;
        UniV2PairI pair;
    }

    UniPair[] public uniSyncs;

    modifier indexInBounds(uint256 index) {
        require(
            index < uniSyncs.length,
            "Index must be less than array length"
        );
        _;
    }

    // https://uniswap.org/docs/v2/smart-contract-integration/getting-pair-addresses/
    function genUniAddr(address left, address right)
        internal
        pure
        returns (UniV2PairI)
    {
        address first = left < right ? left : right;
        address second = left < right ? right : left;
        address pair = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff",
                        uniFactory,
                        keccak256(abi.encodePacked(first, second)),
                        hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                    )
                )
            )
        );
        return UniV2PairI(pair);
    }

    function initialize(
        address unbase_,
        address unbasePolicy_,
        address unbaseDaiPool_,
        address unbaseDaiLpPool_,
        address ungovDaiLpPool_,
        uint256 rebaseRequiredSupply_,
        uint256 oracleStartTimeOffset
    ) external initializer {
        unbase = UnbaseI(unbase_);
        unbasePolicy = UnbasePolicyI(unbasePolicy_);

        unbaseDaiPool = PoolI(unbaseDaiPool_);
        unbaseDaiLpPool = PoolI(unbaseDaiLpPool_);
        ungovDaiLpPool = PoolI(ungovDaiLpPool_);

        maximumRebaseTime = block.timestamp + oracleStartTimeOffset;
        rebaseStarted = false;
        rebaseRequiredSupply = rebaseRequiredSupply_;
    }

    function addUniPair(address token1, address token2) external onlyOwner {
        uniSyncs.push(UniPair(true, genUniAddr(token1, token2)));

        emit LogAddNewUniPair(token1, token2);
    }

    function deleteUniPair(uint256 index)
        external
        onlyOwner
        indexInBounds(index)
    {
        UniPair memory instanceToDelete = uniSyncs[index];

        if (index < uniSyncs.length.sub(1)) {
            uniSyncs[index] = uniSyncs[uniSyncs.length.sub(1)];
        }
        emit LogDeleteUniPair(
            instanceToDelete.enabled,
            address(instanceToDelete.pair)
        );

        uniSyncs.pop();
        delete instanceToDelete;
    }

    function setUniPairEnabled(uint256 index, bool enabled)
        external
        onlyOwner
        indexInBounds(index)
    {
        UniPair storage instance = uniSyncs[index];
        instance.enabled = enabled;

        emit LogSetUniPairEnabled(index, enabled);
    }

    /**
     * @notice Main entry point to initiate a rebase operation.
     *         The Orchestrator calls rebase on the unbase policy and notifies downstream applications.
     *         Contracts are guarded from calling, to avoid flash loan attacks on liquidity
     *         providers.
     *         If a transaction in the transaction list reverts, it is swallowed and the remaining
     *         transactions are executed.
     */
    function rebase() external {
        // Rebase will only be called when 95% of the total supply has been distributed or current time is 3 weeks since the orchestrator was deployed.
        // To stop the rebase from getting stuck if no enough rewards are distributed. This will also start the ungov/unbase pool reward drops
        if (!rebaseStarted) {
            uint256 rewardsDistributed = unbaseDaiPool.rewardDistributed().add(
                unbaseDaiLpPool.rewardDistributed()
            );

            require(
                rewardsDistributed >= rebaseRequiredSupply ||
                    block.timestamp >= maximumRebaseTime,
                "Not enough rewards distributed or time less than start time"
            );

            //Start ungov reward drop
            ungovDaiLpPool.startPool();
            rebaseStarted = true;
            emit LogRebaseStarted(block.timestamp);
        }
        require(msg.sender == tx.origin); // solhint-disable-line avoid-tx-origin
        unbasePolicy.rebase();

        for (uint256 i = 0; i < uniSyncs.length; i++) {
            if (uniSyncs[i].enabled) {
                address(uniSyncs[i].pair).call{gas: SYNC_GAS}(
                    abi.encode(uniSyncs[i].pair.sync.selector)
                );
            }
        }
    }
}
