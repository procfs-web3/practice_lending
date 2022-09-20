// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/DreamOracle.sol";

contract LendingService {

    IDreamOracle priceOracle;
    IERC20 usdc;
    DepositInfo[] depositInfos;
    BorrowInfo[] borrowInfos;

    struct DepositInfo {
        address provider;
        uint256 amount;
        uint256 timestamp;
    }

    struct BorrowInfo {
        address borrower;
        uint256 amount;
        uint256 collateralAmount;
        uint256 liquidationThresh;
        uint256 timestamp;
    }

    constructor(address usdcAddress, address oracleAddress) {
        priceOracle = IDreamOracle(oracleAddress);
        usdc = IERC20(usdcAddress);
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

    function calcPrincipleSum(uint256 initBalance, uint256 initTimestamp) internal view returns (uint256) {
        uint nDays = (block.timestamp - initTimestamp) / 1 days;
        uint balance = initBalance;
        for (uint i = 0; i < nDays; i++) {
            balance = balance * 1001 / 1000;
        }
        return balance;
    }

   function deposit(address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "deposit: tokenAddress is not USDC");
        require(amount > 0, "deposit: amount must be nonzero");
        for (uint i = 0; i < depositInfos.length; i++) {
            require(depositInfos[i].provider != msg.sender, "deposit: double deposit");
        }
        DepositInfo memory d;
        d.provider = msg.sender;
        d.amount = amount;
        d.timestamp = block.timestamp;
        depositInfos.push(d);
        usdc.transferFrom(msg.sender, address(this), amount);
   }

    function borrow(address tokenAddress, uint256 amount) public payable {
        require(tokenAddress == address(usdc), "borrow: tokenAddress is not USDC");
        require(amount > 0, "borrow: amount must be nonzero");
        for (uint i = 0; i < borrowInfos.length; i++) {
            require(borrowInfos[i].borrower != msg.sender, "borrow: double borrow");
        }
        
        BorrowInfo memory b;
        b.borrower = msg.sender;
        b.collateralAmount = usdcToEth(amount * 10 / 5);
        require(msg.value == b.collateralAmount, "borrow: msg.value must be equal to collateral amount");
        b.amount = amount;
        b.liquidationThresh = usdcToEth(amount) * 75 / 100;
        b.timestamp = block.timestamp;
        borrowInfos.push(b);
        usdc.transfer(msg.sender, amount);
    }

    function repay(address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "repay: tokenAddress is not USDC");
        require(amount > 0, "repay: amount must be nonzero");
        for (uint i = 0; i < borrowInfos.length; i++) {
            BorrowInfo storage b = borrowInfos[i];
            if (b.borrower == msg.sender) {
                uint256 paybackAmount = calcPrincipleSum(b.amount, b.timestamp);
                require(amount <= paybackAmount, "repay: excessive repayment");
                usdc.transferFrom(b.borrower, address(this), amount);
                if (paybackAmount == amount) {
                    // return collateral
                    payable(b.borrower).transfer(b.collateralAmount);
                    borrowInfos[i] = borrowInfos[borrowInfos.length - 1];
                    borrowInfos.pop();
                }
                else {
                    b.timestamp = block.timestamp;
                    b.amount = paybackAmount - amount;
                }
                return;
            }
        }
        require(false, "repay: user not found");
    }

    function liquidate(address user, address tokenAddress, uint256 amount) public {
        // argument amount is ignored.
        require(tokenAddress == address(usdc), "liquidate: tokenAddress is not USDC");
        for (uint i = 0; i < borrowInfos.length; i++) {
            if (borrowInfos[i].borrower == user) {
                if (_liquidate(msg.sender, borrowInfos[i].liquidationThresh, borrowInfos[i].collateralAmount)) {
                    borrowInfos[i] = borrowInfos[borrowInfos.length - 1];
                    borrowInfos.pop();
                }
                return;
            }
        }
        require(false, "liquidate: user not found");
    }

    function withdraw(address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "withdraw: tokenAddress is not USDC");
        require(amount > 0, "withdraw: amount must be nonzero");
        for (uint i = 0; i < depositInfos.length; i++) {
            DepositInfo storage d = depositInfos[i];
            if (d.provider == msg.sender) {
                uint256 paybackAmount = calcPrincipleSum(d.amount, d.timestamp);
                require(amount <= paybackAmount, "withdraw: excessive withdrawl");
                usdc.transfer(d.provider, amount);
                if (paybackAmount == amount) {
                    depositInfos[i] = depositInfos[depositInfos.length - 1];
                    depositInfos.pop();
                }
                else {
                    d.timestamp = block.timestamp;
                    d.amount = paybackAmount - amount;
                }
                return;
            }
        }
        require(false, "withdraw: user not found");
    }

    function _liquidate(address liquidator, uint256 liquidationThresh, uint256 collateralAmount) internal returns (bool) {
        uint usdcAmount = ethToUsdc(collateralAmount);
        if (usdcAmount <= liquidationThresh) {
            payable(liquidator).transfer(collateralAmount);
            usdc.transferFrom(liquidator, address(this), usdcAmount);
            return true;
        }
        else {
            return false;
        }
    }
}
