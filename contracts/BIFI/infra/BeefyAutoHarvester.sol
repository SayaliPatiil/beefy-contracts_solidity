// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IStrategy {
    function lastHarvest() external view returns (uint256);

    function callReward() external view returns (uint256);

    function paused() external view returns (bool);

    function harvest(address callFeeRecipient) external view; // can be view as will only be executed off chain
}

interface IVaultRegistry {
    function allVaultAddresses() external view returns (address[] memory);
    // this will hardcoded for now, but maybe the gas used by harvest can be recorded on chain after x amount of harvests in strat contract (x amount to avoid writing to storage excessively after each harvest)
    function getVaultHarvestGasLimitEstimate(address _vaultAddress) external view returns (uint256);
}

interface IVault {
    function strategy() external view returns (address);
}

interface ITaskTreasury {
    function maxFee() external view returns (uint256);
}

interface IMultiHarvest {
    function harvest(address[] memory strategies) external;
}

contract BeefyAutoHarvester is KeeperCompatibleInterface {
    // contracts, only modifiable via setters
    IVaultRegistry private vaultRegistry;
    AggregatorV3Interface private gasFeed;

    // util vars, only modifiable via setters
    address private callFeeRecipient = address(this);
    uint256 private blockGasLimitBuffer = 100000; // not sure what this should be, will probably be trial and error at first.

    // state vars that will change across upkeeps
    uint256 private startIndex;

    constructor(
        address _vaultRegistry,
        address _gasFeed
    ) {
        vaultRegistry = IVaultRegistry(_vaultRegistry);
        gasFeed = AggregatorV3Interface(_gasFeed);
    }

  function checkUpkeep(
    bytes calldata checkData // unused
  )
    external view
    returns (
      bool upkeepNeeded,
      bytes memory performData // array of vaults + 
    ) {
        checkData; // dummy reference to get rid of unused parameter warning 

        // save harvest condition in variable as it will be reused in count and build
        function (address, uint256) view returns (bool, uint256) harvestCondition = _willHarvestVault;
        // get vaults to iterate over
        address[] memory vaults = vaultRegistry.allVaultAddresses();
        
        // get gas price to be able to calculate call rewards to break even on harvest
        ( , int256 answer, , , ) = gasFeed.latestRoundData();
        if (answer < 0) 
            return (false, bytes("Gas price is negative"));
        uint256 gasPrice = uint256(answer); // TODO: is this in wei or gwei

        // count vaults to harvest that will fit within block limit
        (uint256 numberOfVaultsToHarvest, uint256 newStartIndex) = _countVaultsToHarvest(vaults, gasPrice, harvestCondition);
        if (numberOfVaultsToHarvest == 0)
            return (false, bytes("BeefyAutoHarvester: No vaults to harvest"));

        // need to return strategies rather than vaults to harvest to avoid looking up strategy address on chain
        address[] memory vaultsToHarvest = _buildVaultsToHarvest(vaults, gasPrice, harvestCondition, numberOfVaultsToHarvest);

        performData = abi.encode(
            vaultsToHarvest,
            newStartIndex
        ); // how to decode this correctly later?

        return (true, performData);
    }

    function _buildVaultsToHarvest(address[] memory _vaults, uint256 _gasPrice, function (address, uint256) view returns (bool, uint256) _harvestCondition, uint256 numberOfVaultsToHarvest)
        internal
        view
        returns (address[] memory)
    {
        uint256 vaultPositionInArray;
        address[] memory strategiesToHarvest = new address[](
            numberOfVaultsToHarvest
        );

        // create array of strategies to harvest. Could reduce code duplication from _countVaultsToHarvest via a another function parameter called _loopPostProcess
        for (uint256 offset; offset < _vaults.length; ++offset) {
            uint256 vaultIndexToCheck = getCircularIndex(startIndex, offset, _vaults.length);
            address vaultAddress = _vaults[vaultIndexToCheck];

            // don't need to check gasLeft here as we know the exact number of vaults that will be harvested, and they will be linearly ordered in the array.
            (bool willHarvest, ) = _harvestCondition(vaultAddress, _gasPrice);

            if (willHarvest) {
                strategiesToHarvest[vaultPositionInArray] = address(IVault(vaultAddress).strategy()); // TODO: rename functions to strategy* as this will be returning strategies rather than vaults
                vaultPositionInArray += 1;
            }

            // no need to keep going if we've found our last vault to harvest
            if (vaultPositionInArray == numberOfVaultsToHarvest - 1) break;
        }

        return strategiesToHarvest;
    }

    function _countVaultsToHarvest(address[] memory _vaults, uint256 _gasPrice, function (address, uint256) view returns (bool, uint256) _harvestCondition)
        internal
        view
        returns (uint256, uint256)
    {
        uint256 gasLeft = block.gaslimit - blockGasLimitBuffer; // does block.gaslimit change when its an eth_call?
        uint256 latestIndexOfVaultToHarvest; // will be used to set newStartIndex
        uint256 numberOfVaultsToHarvest; // used to create fixed size array in _buildVaultsToHarvest

        // count the number of vaults to harvest.
        for (uint256 offset; offset < _vaults.length; ++offset) {
            // startIndex is where to start in the vaultRegistry array, offset is position from start index (in other words, number of vaults we've checked so far), 
            // then modulo to wrap around to the start of the array, until we've checked all vaults, or break early due to hitting gas limit
            // this logic is contained in getCircularIndex()
            uint256 vaultIndexToCheck = getCircularIndex(startIndex, offset, _vaults.length);
            address vaultAddress = _vaults[vaultIndexToCheck];

            (bool willHarvest, uint256 gasNeeded) = _harvestCondition(vaultAddress, _gasPrice);

            if (willHarvest && gasLeft >= gasNeeded) {
                gasLeft -= gasNeeded;
                numberOfVaultsToHarvest += 1;
                latestIndexOfVaultToHarvest = vaultIndexToCheck;
            }
        }

        uint256 newStartIndex = getCircularIndex(latestIndexOfVaultToHarvest, 1, _vaults.length);

        return (numberOfVaultsToHarvest, newStartIndex); // unnecessary return but return statements are always preferred even with named returns
    }

    // function used to iterate on an array in a circular way
    function getCircularIndex(uint256 index, uint256 offset, uint256 bufferLength) private pure returns (uint256) {
        return (index + offset) % bufferLength;
    }

    function _willHarvestVault(address _vaultAddress, uint256 _gasPrice) 
        internal
        view
        returns (bool, uint256)
    {
        (bool shouldHarvestVault, uint256 gasNeeded) = _shouldHarvestVault(_vaultAddress, _gasPrice);
        
        bool willHarvestVault = _canHarvestVault(_vaultAddress) && shouldHarvestVault;
        
        return (willHarvestVault, gasNeeded);
    }

    function _canHarvestVault(address _vaultAddress) 
        internal
        view
        returns (bool)
    {
        IVault vault = IVault(_vaultAddress);
        IStrategy strategy = IStrategy(vault.strategy());

        bool isPaused = strategy.paused();

        bool canHarvest = false;

        if (isPaused) 
        {
            canHarvest = false;
        }
        else 
        {
            // if offchain sim is subject to block gas limit, might not be able to make this call
            try strategy.harvest(callFeeRecipient)
            {
                canHarvest = true;
            }
            catch
            {
                canHarvest = false;
            }
        }

        return canHarvest;
    }

    function _shouldHarvestVault(address _vaultAddress, uint256 _gasPrice)
        internal
        view
        returns (bool, uint256)
    {
        IVault vault = IVault(_vaultAddress);
        IStrategy strategy = IStrategy(vault.strategy());
        uint256 harvestGasLimit = vaultRegistry.getVaultHarvestGasLimitEstimate(_vaultAddress);

        bool hasBeenHarvestedToday = strategy.lastHarvest() < 1 days;

        uint256 callRewardAmount = strategy.callReward();

        uint256 gasNeeded = _gasPrice * harvestGasLimit;
        bool isProfitableHarvest = callRewardAmount >= gasNeeded;

        bool shouldHarvest = isProfitableHarvest ||
            (!hasBeenHarvestedToday && callRewardAmount > 0);

        return (shouldHarvest, gasNeeded);
    }

    // PERFORM UPKEEP SECTION

    function performUpkeep(
        bytes calldata performData
    ) external {
        

    }
    
}