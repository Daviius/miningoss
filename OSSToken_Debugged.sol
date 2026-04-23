// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract OSSToken {
    string public constant name = "OSS Token";
    string public constant symbol = "OSS";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    address public owner;
    address public liquidityWallet;

    uint256 public burnTaxBps = 200;       // 2%
    uint256 public reflectionTaxBps = 300; // 3%
    uint256 public liquidityTaxBps = 200;  // 2%
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public claimAmount = 0.5 ether;
    uint256 public claimCooldown = 1 days;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public lastClaimAt;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Claimed(address indexed user, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "OSS: not owner");
        _;
    }

    constructor(uint256 initialSupply, address _liquidityWallet) {
        require(_liquidityWallet != address(0), "OSS: invalid liquidity wallet");

        owner = msg.sender;
        liquidityWallet = _liquidityWallet;

        uint256 minted = initialSupply * (10 ** uint256(decimals));
        totalSupply = minted;
        balanceOf[msg.sender] = minted;

        emit Transfer(address(0), msg.sender, minted);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "OSS: insufficient allowance");

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }

        _transfer(from, to, amount);
        return true;
    }

    function claim() external returns (bool) {
        require(block.timestamp >= lastClaimAt[msg.sender] + claimCooldown, "OSS: claim cooldown");
        lastClaimAt[msg.sender] = block.timestamp;

        _transfer(address(this), msg.sender, claimAmount);
        emit Claimed(msg.sender, claimAmount);
        return true;
    }

    function fundClaimPool(uint256 amount) external onlyOwner returns (bool) {
        _transfer(msg.sender, address(this), amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "OSS: zero address");
        require(balanceOf[from] >= amount, "OSS: insufficient balance");

        bool takeFee = from != address(this) && to != address(this);
        uint256 burnAmount = takeFee ? (amount * burnTaxBps) / BPS_DENOMINATOR : 0;
        uint256 reflectionAmount = takeFee ? (amount * reflectionTaxBps) / BPS_DENOMINATOR : 0;
        uint256 liquidityAmount = takeFee ? (amount * liquidityTaxBps) / BPS_DENOMINATOR : 0;
        uint256 taxAmount = burnAmount + reflectionAmount + liquidityAmount;
        uint256 sendAmount = amount - taxAmount;

        // Fixed logic: deduct `amount` from sender exactly once.
        balanceOf[from] -= amount;

        balanceOf[to] += sendAmount;
        emit Transfer(from, to, sendAmount);

        if (burnAmount > 0) {
            totalSupply -= burnAmount;
            emit Transfer(from, address(0), burnAmount);
        }

        if (reflectionAmount > 0) {
            balanceOf[address(this)] += reflectionAmount;
            emit Transfer(from, address(this), reflectionAmount);
        }

        if (liquidityAmount > 0) {
            balanceOf[liquidityWallet] += liquidityAmount;
            emit Transfer(from, liquidityWallet, liquidityAmount);
        }
    }

    function setLiquidityWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "OSS: invalid wallet");
        liquidityWallet = newWallet;
    }

    function setClaimConfig(uint256 newClaimAmount, uint256 newCooldown) external onlyOwner {
        claimAmount = newClaimAmount;
        claimCooldown = newCooldown;
    }
}
