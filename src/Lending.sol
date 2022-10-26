// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/DreamOracle.sol";

contract DreamAcademyLending {

    IPriceOracle priceOracle;
    IERC20 usdc;
    mapping (address => DepositInfo) usdcDepositInfos;
    mapping (address => DepositInfo) ethDepositInfos;
    mapping (address => BorrowInfo) usdcBorrows;

    struct DepositInfo {
        uint256 amount;
        uint256 timestamp;
        uint256 timeRemainder;
    }

    struct BorrowInfo {
        uint256 amount;
        uint256 collateralAmount;
        uint256 liquidationThresh;
        uint256 timestamp;
        uint256 timeRemainder;
    }

    constructor(IPriceOracle _priceOracle, address _usdc) {
        priceOracle = _priceOracle;
        usdc = IERC20(_usdc);
    }

    function initializeLendingProtocol(address _usdc) public payable {
        usdc = IERC20(_usdc);
    }

    function getAccruedSupplyAmount(address _usdc) public view returns (uint256) {
        return 0;
    }

    function ethToUsdc(uint256 ethAmount) internal view returns (uint256) {
        // ethereum address 0xeeeeeeee
        uint256 ethPerUsdc = priceOracle.getPrice(address(usdc));
        return ethAmount / ethPerUsdc;
    }

    function usdcToEth(uint256 usdcAmount) internal view returns (uint256) {
        // ethereum address 0xeeeeeeee
        uint256 ethPerUsdc = priceOracle.getPrice(address(usdc));
        return usdcAmount * ethPerUsdc;
    }

    function calcPrincipleSum(uint256 initBalance, uint256 elapsedTime) internal view returns (uint256) {
        uint nDays = elapsedTime / 1 days;
        uint balance = initBalance;
        for (uint i = 0; i < nDays; i++) {
            balance = balance * 1001 / 1000;
        }
        return balance;
    }

    function _depositUsdc(address provider, uint256 amount) internal {
        DepositInfo storage d = usdcDepositInfos[provider];
        if (d.amount > 0) {
            d.amount = calcPrincipleSum(d.amount, block.timestamp - d.timestamp + d.timeRemainder) + amount;
            d.timeRemainder = (block.timestamp - d.timestamp) % 1 days;
            d.timestamp = block.timestamp;
        }
        else {
            d.amount = amount;
            d.timestamp = block.timestamp;
            d.timeRemainder = 0;
        }
    }

    function _depositEth(address provider, uint256 amount) internal {
        DepositInfo storage d = ethDepositInfos[provider];
        if (d.amount > 0) {
            d.amount = calcPrincipleSum(d.amount, block.timestamp - d.timestamp + d.timeRemainder) + amount;
            d.timeRemainder = (block.timestamp - d.timestamp) % 1 days;
            d.timestamp = block.timestamp;
        }
        else {
            d.amount = amount;
            d.timestamp = block.timestamp;
            d.timeRemainder = 0;
        }
    }

   function deposit(address tokenAddress, uint256 amount) public payable {
        require((amount > 0 && msg.value == 0) || (amount == 0 && msg.value > 0), "deposit: amount must be nonzero and only one type of asset can be deposited");
        if (amount == 0) {
            _depositEth(msg.sender, msg.value);
        }
        else {
            require(tokenAddress == address(usdc), "deposit: tokenAddress is not USDC");
            usdc.transferFrom(msg.sender, address(this), amount);
            _depositUsdc(msg.sender, amount);
        }
   }

    function borrow(address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "borrow: tokenAddress is not USDC");
        require(amount > 0, "borrow: amount must be nonzero");
        if (usdcBorrows[msg.sender].amount > 0) {
            revert("double borrow");
        }
        BorrowInfo storage b = usdcBorrows[msg.sender];
        b.collateralAmount = usdcToEth(amount * 10 / 5);
        require(ethDepositInfos[msg.sender].amount >= b.collateralAmount, "borrow: not enough collateral");
        ethDepositInfos[msg.sender].amount -= b.collateralAmount;
        b.amount = amount;
        // Liquidation thresh is (value of collateral in USDC) such that liquidation occurs. It is 4/3 of the current value of the loan
        b.liquidationThresh = amount * 100 / 75;
        b.timestamp = block.timestamp;
        usdc.transfer(msg.sender, amount);
    }

    function repay(address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "repay: tokenAddress is not USDC");
        require(amount > 0, "repay: amount must be nonzero");
        BorrowInfo storage b = usdcBorrows[msg.sender];
        if (b.amount > 0) {
            uint256 paybackAmount = calcPrincipleSum(b.amount, block.timestamp - b.timestamp + b.timeRemainder);
            usdc.transferFrom(msg.sender, address(this), amount);
            if (paybackAmount >= amount) {
                // fully return collateral
                payable(msg.sender).transfer(b.collateralAmount);
                b.timeRemainder = 0;
            }
            else {
                // partially return collateral
                b.timeRemainder = (block.timestamp - b.timestamp) % 1 days;
                b.timestamp = block.timestamp;
                b.amount = paybackAmount - amount;
                payable(msg.sender).transfer(b.collateralAmount * amount / paybackAmount);
            }
        }
    }

    function liquidate(address user, address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "liquidate: tokenAddress is not USDC");
        require(amount > 0, "liquidate: liquidation amount must be nonzero");
        BorrowInfo storage b = usdcBorrows[user];
        if (b.amount > 0) {
            uint usdcAmount = ethToUsdc(b.collateralAmount);
            if (usdcAmount <= b.liquidationThresh) {
                require(amount <= b.collateralAmount, "liquidate: liquidation amount exceeds collateral amount");
                if (amount == b.collateralAmount) {
                    usdc.transferFrom(msg.sender, address(this), usdcAmount);
                }
                else {
                    usdcAmount = usdcAmount * amount / b.collateralAmount;
                    b.collateralAmount -= amount;
                    usdc.transferFrom(msg.sender, address(this), usdcAmount);
                }
                payable(msg.sender).transfer(amount);
            }
        }
    }

    function _withdrawUsdc(address user, uint256 amount) internal {
        DepositInfo storage d = usdcDepositInfos[user];
        if (d.amount > 0) {
            uint256 paybackAmount = calcPrincipleSum(d.amount, block.timestamp - d.timestamp + d.timeRemainder);
            require(amount <= paybackAmount, "withdraw: excessive withdrawl");
            usdc.transfer(user, amount);
            d.timestamp = block.timestamp;
            d.timeRemainder = (block.timestamp - d.timestamp) % 1 days;
            d.amount = paybackAmount - amount;
        }
    }

    function _withdrawEth(address user, uint256 amount) internal {
        DepositInfo storage d = ethDepositInfos[user];
        if (d.amount > 0) {
            uint256 paybackAmount = calcPrincipleSum(d.amount, block.timestamp - d.timestamp);
            require(amount <= paybackAmount, "withdraw: excessive withdrawl");
            d.timestamp = block.timestamp;
            d.timeRemainder = (block.timestamp - d.timestamp) % 1 days;
            d.amount = paybackAmount - amount;
            payable(user).transfer(amount);
        }
    }

    function withdraw(address tokenAddress, uint256 amount) public {
        require(amount > 0, "withdraw: amount must be nonzero");
        if (tokenAddress == address(0)) {
            _withdrawEth(msg.sender, amount);
        }
        else {
            require(tokenAddress == address(usdc), "withdraw: token is not USDC");
            _withdrawUsdc(msg.sender, amount);
        }
        
    }
}
