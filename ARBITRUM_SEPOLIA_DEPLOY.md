# Deploy `OSS_Token_Advanced.sol` lên Arbitrum Sepolia (ChainId 421614)

## 1) Chuẩn bị

- RPC: `https://sepolia-rollup.arbitrum.io/rpc`
- Chain ID: `421614`
- Ví deploy có ETH testnet
- Đã cài OpenZeppelin contracts trong project deploy:

```bash
npm install @openzeppelin/contracts
```

## 2) Constructor parameters

Constructor của contract:

```solidity
constructor(
  string name_,
  string symbol_,
  uint256 totalSupply_,
  address router_,
  address admin_
)
```

Ví dụ:
- `name_`: `OSS Advanced`
- `symbol_`: `OSSA`
- `totalSupply_`: `1000000000 ether` (1 tỷ token, 18 decimals)
- `router_`: địa chỉ router DEX tương thích UniswapV2 trên Arbitrum Sepolia (Pancake/Uniswap/Sushi tùy môi trường)
- `admin_`: ví quản trị

## 3) Script deploy mẫu (Hardhat + ethers v6)

Tạo file `scripts/deploy-arbitrum-sepolia.js` trong project deploy:

```js
const { ethers } = require("hardhat");

async function main() {
  const router = "0xYourRouterAddress";
  const admin = "0xYourAdminAddress";

  const Token = await ethers.getContractFactory("OSS_Token_Advanced");
  const token = await Token.deploy(
    "OSS Advanced",
    "OSSA",
    ethers.parseEther("1000000000"),
    router,
    admin
  );

  await token.waitForDeployment();
  console.log("OSS_Token_Advanced deployed at:", await token.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

Chạy deploy:

```bash
npx hardhat run scripts/deploy-arbitrum-sepolia.js --network arbitrumSepolia
```

## 4) Cấu hình network mẫu (hardhat.config.js)

```js
module.exports = {
  solidity: "0.8.24",
  networks: {
    arbitrumSepolia: {
      url: "https://sepolia-rollup.arbitrum.io/rpc",
      chainId: 421614,
      accounts: [process.env.PRIVATE_KEY]
    }
  }
};
```

## 5) Sau khi deploy

Thiết lập thêm (nếu cần):

- `setSwapSettings(bool enabled, uint256 threshold)`
- `setLiquiditySlippage(uint16 slippageBps)`
- `processLiquidity()` (trigger thủ công khi cần)
- `setLimits(uint256 maxTx, uint256 maxWallet)`
- `setFees(uint16 burnBps, uint16 reflectionBps, uint16 liquidityBps)`
- `setBlacklist(address account, bool status)`
- `pause()` / `unpause()`

> Mặc định `liquidityReceiver` đã là `0x000000000000000000000000000000000000dEaD` để LP lock vĩnh viễn.
