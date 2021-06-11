// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IUniswapRouter.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/pancake/IMasterChef.sol";
import "../../interfaces/snob/ISnobLP.sol";

/**
 * @dev Strategy to farm snob through a MasterChef based rewards contract.
 */
contract StrategySnowball3Pool is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wavax, usdt} - Required for liquidity routing when doing swaps.
     * {snob} - Token generated by staking our funds. In this case it's the snob token.
     * {want} - Token that the strategy maximizes. The same token that users deposit in the vault. s3D BUSD/USDT/DAI
     */
    address constant public wavax = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    address constant public usdt = address(0xde3A24028580884448a5397872046a019649b084);
    address constant public snob = address(0xC38f41A296A4493Ff429F1238e030924A1542e50);
    address constant public want = address(0xdE1A11C331a0E45B9BA8FeE04D4B51A745f1e4A4);

    /**
     * @dev Third Party Contracts:
     * {pngrouter} - Pangolin router
     * {icequeen} - snob MasterChef contract IceQueen
     * {poolLP} - 3Pool LP contract to deposit BUSD/USDC/USDT and mint {want}
     * {poolId} - PoolId for MasterChef contract
     */
    address constant public pngrouter = address(0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106);
    address constant public icequeen  = address(0xB12531a2d758c7a8BF09f44FC88E646E1BF9D375);
    address constant public poolLp    = address(0x6B41E5c07F2d382B921DE5C34ce8E2057d84C042);
    uint8 constant public poolId = 7;

    /**
     * @dev Beefy Contracts:
     * {treasury} - Address of the Beefy treasury. Rewards accumulate here and are then sent to BSC.
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     */
    address constant public treasury = address(0xA3e3Af161943CfB3941B631676134bb048739727);
    address public vault;
    address public strategist;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {TREASURY_FEE} - 3.75% goes to BIFI holders through the {treasury}.
     * {CALL_FEE} - 0.25% goes to whoever executes the harvest function as gas subsidy.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public CALL_FEE       = 55;
    uint constant public TREASURY_FEE   = 833;
    uint constant public STRATEGIST_FEE = 112;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using Pangolin.
     * {snobToWavaxRoute} - Route we take to get from {snob} into {wbnb}.
     * {snobToUsdtRoute} - Route we take to get from {snob} into {usdt}.
     */
    address[] public snobToWavaxRoute = [snob, wavax];
    address[] public snobToUsdtRoute = [snob, wavax, usdt];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _vault, address _strategist) {
        vault = _vault;
        strategist = _strategist;

        IERC20(want).safeApprove(icequeen, type(uint).max);
        IERC20(snob).safeApprove(pngrouter, type(uint).max);
        IERC20(usdt).safeApprove(poolLp, type(uint).max);
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {want} in the Reward Pool to farm {snob}
     */
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IMasterChef(icequeen).deposit(poolId, wantBal);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {want} from the Reward Pool.
     * The available {want} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMasterChef(icequeen).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFee = wantBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFee));
        }
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the Reward Pool.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {snob} token for {usdt}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IMasterChef(icequeen).deposit(poolId, 0);
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards.
     * 0.25% -> Call Fee
     * 3.75% -> Treasury fee
     * 0.5% -> Strategist fee
     */
    function chargeFees() internal {
        uint256 toWavax = IERC20(snob).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouter(pngrouter).swapExactTokensForTokens(toWavax, 0, snobToWavaxRoute, address(this), block.timestamp.add(600));

        uint256 wavaxBal = IERC20(wavax).balanceOf(address(this));

        uint256 treasuryFee = wavaxBal.mul(TREASURY_FEE).div(MAX_FEE);
        IERC20(wavax).safeTransfer(treasury, treasuryFee);

        uint256 callFee = wavaxBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wavax).safeTransfer(msg.sender, callFee);

        uint256 strategistFee = wavaxBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wavax).safeTransfer(strategist, strategistFee);

    }

    /**
     * @dev Swaps {snob} rewards earned for {usdt} and adds to 3Pool LP.
     */
    function addLiquidity() internal {
        uint256 snobBal = IERC20(snob).balanceOf(address(this));
        IUniswapRouter(pngrouter).swapExactTokensForTokens(snobBal, 0, snobToUsdtRoute, address(this), block.timestamp.add(600));

        uint256 usdtBal = IERC20(usdt).balanceOf(address(this));
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = usdtBal;
        ISnobLP(poolLp).addLiquidity(amounts, 0, block.timestamp.add(600));
    }

    /**
     * @dev Function to calculate the total underlying {want} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the MasterChef.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {want} the contract holds.
     */
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {want} the strategy has allocated in the Reward Pool
     */
    function balanceOfPool() public view returns (uint256) {
         (uint256 _amount, ) = IMasterChef(icequeen).userInfo(poolId, address(this));
         return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(icequeen).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the Reward Pool, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IMasterChef(icequeen).emergencyWithdraw(poolId);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(want).safeApprove(icequeen, 0);
        IERC20(snob).safeApprove(pngrouter, 0);
        IERC20(usdt).safeApprove(poolLp, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(want).safeApprove(icequeen, type(uint).max);
        IERC20(snob).safeApprove(pngrouter, type(uint).max);
        IERC20(usdt).safeApprove(poolLp, type(uint).max);
    }

    /**
     * @dev Updates address where strategist fee earnings will go.
     * @param _strategist new strategist address.
     */
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
    }
}