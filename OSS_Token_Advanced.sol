// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

contract OSS_Token_Advanced is ERC20, Ownable, AccessControl, Pausable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    uint16 public constant FEE_DENOMINATOR = 10_000;
    uint16 public constant MAX_TOTAL_FEE_BPS = 1_000; // hard cap: 10%
    uint256 private constant ACC_PRECISION = 1e36;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IUniswapV2Router02 public dexRouter;
    address public lpPair;
    address public liquidityReceiver;

    uint16 public burnFeeBps = 200; // 2%
    uint16 public reflectionFeeBps = 300; // 3%
    uint16 public liquidityFeeBps = 200; // 2%

    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;

    uint256 public swapTokensAtAmount;
    uint16 public liquiditySlippageBps = 300; // 3%
    bool public swapEnabled = true;
    bool private inSwap;

    uint256 public reflectionReserve;
    uint256 public liquidityReserve;
    uint256 public accReflectionPerToken;

    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isFeeExempt;
    mapping(address => bool) public isLimitExempt;

    mapping(address => uint256) public reflectionDebt;
    mapping(address => uint256) public pendingReflection;

    event AddressBlacklisted(address indexed account, bool indexed status);
    event FeesUpdated(uint16 burnFeeBps, uint16 reflectionFeeBps, uint16 liquidityFeeBps);
    event LimitsUpdated(uint256 maxTxAmount, uint256 maxWalletAmount);
    event FeeExemptionUpdated(address indexed account, bool indexed status);
    event LimitExemptionUpdated(address indexed account, bool indexed status);
    event RouterUpdated(address indexed router, address indexed pair);
    event SwapSettingsUpdated(bool swapEnabled, uint256 swapTokensAtAmount);
    event LiquidityReceiverUpdated(address indexed receiver);
    event LiquiditySlippageUpdated(uint16 slippageBps);
    event ReflectionDistributed(uint256 amount, uint256 accReflectionPerToken);
    event ReflectionPaid(address indexed account, uint256 amount);
    event AutoLiquidityAdded(uint256 tokenAmount, uint256 ethAmount, uint256 liquidityTokens);

    error BlacklistedAddress(address account);
    error TransferPaused();
    error MaxTxExceeded(uint256 amount, uint256 maxAllowed);
    error MaxWalletExceeded(uint256 newBalance, uint256 maxAllowed);
    error InvalidFeeConfig();
    error InvalidValue();
    error ProtectedAddress(address account);

    modifier lockSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address router_,
        address admin_
    ) ERC20(name_, symbol_) Ownable(admin_) {
        if (router_ == address(0) || admin_ == address(0) || totalSupply_ == 0) revert InvalidValue();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(BLACKLISTER_ROLE, admin_);
        _grantRole(CONFIG_ROLE, admin_);

        dexRouter = IUniswapV2Router02(router_);
        address factory = dexRouter.factory();
        address weth = dexRouter.WETH();
        lpPair = IUniswapV2Factory(factory).getPair(address(this), weth);
        if (lpPair == address(0)) {
            lpPair = IUniswapV2Factory(factory).createPair(address(this), weth);
        }
        liquidityReceiver = DEAD;

        maxTxAmount = totalSupply_ / 100; // 1%
        maxWalletAmount = totalSupply_ / 50; // 2%
        swapTokensAtAmount = totalSupply_ / 10_000; // 0.01%

        isFeeExempt[admin_] = true;
        isFeeExempt[address(this)] = true;
        isFeeExempt[DEAD] = true;

        isLimitExempt[admin_] = true;
        isLimitExempt[address(this)] = true;
        isLimitExempt[DEAD] = true;
        isLimitExempt[address(0)] = true;
        isLimitExempt[lpPair] = true;

        _mint(admin_, totalSupply_);
        _refreshDebt(admin_);
    }

    receive() external payable {}

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setBlacklist(address account, bool status) external onlyRole(BLACKLISTER_ROLE) {
        if (
            account == address(0) ||
            account == address(this) ||
            account == address(dexRouter) ||
            account == lpPair
        ) {
            revert ProtectedAddress(account);
        }
        isBlacklisted[account] = status;
        emit AddressBlacklisted(account, status);
    }

    function setFeeExempt(address account, bool status) external onlyRole(CONFIG_ROLE) {
        _accrue(account);
        isFeeExempt[account] = status;
        emit FeeExemptionUpdated(account, status);
        _refreshDebt(account);
    }

    function setLimitExempt(address account, bool status) external onlyRole(CONFIG_ROLE) {
        isLimitExempt[account] = status;
        emit LimitExemptionUpdated(account, status);
    }

    function setFees(uint16 burnBps, uint16 reflectionBps, uint16 liquidityBps) external onlyRole(CONFIG_ROLE) {
        if (uint256(burnBps) + uint256(reflectionBps) + uint256(liquidityBps) > MAX_TOTAL_FEE_BPS) {
            revert InvalidFeeConfig();
        }

        burnFeeBps = burnBps;
        reflectionFeeBps = reflectionBps;
        liquidityFeeBps = liquidityBps;

        emit FeesUpdated(burnBps, reflectionBps, liquidityBps);
    }

    function setLimits(uint256 maxTx, uint256 maxWallet) external onlyRole(CONFIG_ROLE) {
        if (maxTx == 0 || maxWallet == 0 || maxWallet < maxTx) revert InvalidValue();

        maxTxAmount = maxTx;
        maxWalletAmount = maxWallet;

        emit LimitsUpdated(maxTx, maxWallet);
    }

    function setRouter(address router) external onlyRole(CONFIG_ROLE) {
        if (router == address(0)) revert InvalidValue();

        dexRouter = IUniswapV2Router02(router);
        address factory = dexRouter.factory();
        address weth = dexRouter.WETH();
        lpPair = IUniswapV2Factory(factory).getPair(address(this), weth);
        if (lpPair == address(0)) {
            lpPair = IUniswapV2Factory(factory).createPair(address(this), weth);
        }

        isLimitExempt[lpPair] = true;
        emit RouterUpdated(router, lpPair);
    }

    function setSwapSettings(bool enabled, uint256 threshold) external onlyRole(CONFIG_ROLE) {
        if (threshold == 0) revert InvalidValue();

        swapEnabled = enabled;
        swapTokensAtAmount = threshold;

        emit SwapSettingsUpdated(enabled, threshold);
    }

    function setLiquidityReceiver(address receiver) external onlyRole(CONFIG_ROLE) {
        if (receiver == address(0)) revert InvalidValue();
        liquidityReceiver = receiver;
        emit LiquidityReceiverUpdated(receiver);
    }

    function setLiquiditySlippage(uint16 slippageBps) external onlyRole(CONFIG_ROLE) {
        if (slippageBps > 2_000) revert InvalidValue(); // <=20%
        liquiditySlippageBps = slippageBps;
        emit LiquiditySlippageUpdated(slippageBps);
    }

    function processLiquidity() external onlyRole(CONFIG_ROLE) {
        if (liquidityReserve > 0) {
            _swapAndLiquify(liquidityReserve);
        }
    }

    function totalFeeBps() public view returns (uint16) {
        return burnFeeBps + reflectionFeeBps + liquidityFeeBps;
    }

    function claimableReflection(address account) public view returns (uint256) {
        uint256 accumulated = (super.balanceOf(account) * accReflectionPerToken) / ACC_PRECISION;
        uint256 delta = accumulated > reflectionDebt[account] ? (accumulated - reflectionDebt[account]) : 0;
        return pendingReflection[account] + delta;
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Khi pause: chỉ chặn transfer thường, vẫn cho phép mint/burn nội bộ nếu có.
        if (paused() && from != address(0) && to != address(0)) revert TransferPaused();
        if (isBlacklisted[from]) revert BlacklistedAddress(from);
        if (isBlacklisted[to]) revert BlacklistedAddress(to);

        if (amount == 0 || inSwap || from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            if (from != address(0)) _refreshDebt(from);
            if (to != address(0)) _refreshDebt(to);
            return;
        }

        _accrue(from);
        _accrue(to);

        uint256 sendAmount = amount;
        uint256 burnAmount;
        uint256 reflectAmount;
        uint256 liqAmount;

        if (!isFeeExempt[from] && !isFeeExempt[to] && totalFeeBps() > 0) {
            burnAmount = (amount * burnFeeBps) / FEE_DENOMINATOR;
            reflectAmount = (amount * reflectionFeeBps) / FEE_DENOMINATOR;
            liqAmount = (amount * liquidityFeeBps) / FEE_DENOMINATOR;
            uint256 feeAmount = burnAmount + reflectAmount + liqAmount;

            sendAmount = amount - feeAmount;

            if (reflectAmount + liqAmount > 0) {
                super._update(from, address(this), reflectAmount + liqAmount);
                reflectionReserve += reflectAmount;
                liquidityReserve += liqAmount;
            }

            if (burnAmount > 0) {
                super._update(from, DEAD, burnAmount);
            }

            if (reflectAmount > 0) {
                _distributeReflection(reflectAmount);
            }
        }

        _enforceLimits(from, to, amount, sendAmount);

        super._update(from, to, sendAmount);

        if (swapEnabled && !inSwap && to == lpPair && liquidityReserve >= swapTokensAtAmount) {
            _swapAndLiquify(liquidityReserve);
        }

        _settleReflection(from);
        _settleReflection(to);

        _refreshDebt(from);
        _refreshDebt(to);
    }

    function _enforceLimits(address from, address to, uint256 amount, uint256 receivedAmount) internal view {
        if (!isLimitExempt[from] && !isLimitExempt[to] && amount > maxTxAmount) {
            revert MaxTxExceeded(amount, maxTxAmount);
        }

        if (!isLimitExempt[to] && to != lpPair && to != DEAD) {
            uint256 newBalance = super.balanceOf(to) + receivedAmount;
            if (newBalance > maxWalletAmount) revert MaxWalletExceeded(newBalance, maxWalletAmount);
        }
    }

    function _distributeReflection(uint256 amount) internal {
        uint256 supplyForReflection = totalSupply() - super.balanceOf(address(this)) - super.balanceOf(DEAD);
        if (supplyForReflection == 0) return;

        accReflectionPerToken += (amount * ACC_PRECISION) / supplyForReflection;
        emit ReflectionDistributed(amount, accReflectionPerToken);
    }

    function _accrue(address account) internal {
        if (account == address(0) || account == address(this) || account == DEAD) {
            return;
        }

        uint256 accumulated = (super.balanceOf(account) * accReflectionPerToken) / ACC_PRECISION;
        uint256 debt = reflectionDebt[account];
        if (accumulated > debt) {
            pendingReflection[account] += (accumulated - debt);
        }
        reflectionDebt[account] = accumulated;
    }

    function _settleReflection(address account) internal {
        if (account == address(0) || account == address(this) || account == DEAD) return;

        uint256 claimable = claimableReflection(account);
        if (claimable == 0 || reflectionReserve == 0) return;

        uint256 paid = claimable > reflectionReserve ? reflectionReserve : claimable;
        pendingReflection[account] = claimable - paid;
        reflectionReserve -= paid;

        if (paid > 0) {
            super._update(address(this), account, paid);
            emit ReflectionPaid(account, paid);
        }
    }

    function _refreshDebt(address account) internal {
        if (account == address(0) || account == address(this) || account == DEAD) return;
        reflectionDebt[account] = (super.balanceOf(account) * accReflectionPerToken) / ACC_PRECISION;
    }

    function _swapAndLiquify(uint256 tokenAmount) internal lockSwap {
        if (tokenAmount == 0) return;

        uint256 half = tokenAmount / 2;
        uint256 otherHalf = tokenAmount - half;
        uint256 initialEthBalance = address(this).balance;

        _approve(address(this), address(dexRouter), tokenAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = dexRouter.WETH();
        uint256[] memory quotedOut = dexRouter.getAmountsOut(half, path);
        uint256 minEthOut = (quotedOut[quotedOut.length - 1] * (FEE_DENOMINATOR - liquiditySlippageBps)) / FEE_DENOMINATOR;

        dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half,
            minEthOut,
            path,
            address(this),
            block.timestamp
        );

        uint256 ethReceived = address(this).balance - initialEthBalance;
        uint256 minToken = (otherHalf * (FEE_DENOMINATOR - liquiditySlippageBps)) / FEE_DENOMINATOR;
        uint256 minEth = (ethReceived * (FEE_DENOMINATOR - liquiditySlippageBps)) / FEE_DENOMINATOR;

        (uint256 amountTokenUsed, uint256 amountEthUsed, uint256 liquidity) = dexRouter.addLiquidityETH{value: ethReceived}(
            address(this),
            otherHalf,
            minToken,
            minEth,
            liquidityReceiver,
            block.timestamp
        );

        uint256 consumedLiquidityTokens = half + amountTokenUsed;
        if (consumedLiquidityTokens > liquidityReserve) {
            liquidityReserve = 0;
        } else {
            liquidityReserve -= consumedLiquidityTokens;
        }

        emit AutoLiquidityAdded(amountTokenUsed, amountEthUsed, liquidity);
    }
}
