// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/DreamOracle.sol";

contract LendingService {

    IDreamOracle priceOracle;
    IERC20 usdc;
    DepositInfo[] usdcDepositInfos;
    DepositInfo[] ethDepositInfos;
    BorrowInfo[] borrowInfos;

    struct DepositInfo {
        address provider;
        uint256 amount;
        uint256 timestamp;
        bool isUsdc;
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

    function _depositUsdc(uint256 amount) internal {
        for (uint i = 0; i < usdcDepositInfos.length; i++) {
            if (usdcDepositInfos[i].provider == msg.sender) {
                DepositInfo storage d = usdcDepositInfos[i];
                d.amount = calcPrincipleSum(amount, d.timestamp) + amount;
                d.timestamp = block.timestamp;
                usdc.transferFrom(msg.sender, address(this), amount);
                return;
            }
        }
        DepositInfo memory d;
        d.provider = msg.sender;
        d.amount = amount;
        d.timestamp = block.timestamp;
        usdcDepositInfos.push(d);
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    function _depositEth(uint256 amount) internal {
        for (uint i = 0; i < ethDepositInfos.length; i++) {
            if (ethDepositInfos[i].provider == msg.sender) {
                DepositInfo storage d = ethDepositInfos[i];
                d.amount = calcPrincipleSum(amount, d.timestamp) + amount;
                d.timestamp = block.timestamp;
                return;
            }
        }
        DepositInfo memory d;
        d.provider = msg.sender;
        d.amount = amount;
        d.timestamp = block.timestamp;
        ethDepositInfos.push(d);
    }

   function deposit(address tokenAddress, uint256 amount) public payable {
        require((amount > 0 && msg.value == 0) || (amount == 0 && msg.value > 0), "deposit: amount must be nonzero and only one type of asset can be deposited");
        if (amount == 0) {
            _depositEth(msg.value);
        }
        else {
            require(tokenAddress == address(usdc), "deposit: tokenAddress is not USDC");
            _depositUsdc(amount);
        }
   }

    function borrow(address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "borrow: tokenAddress is not USDC");
        require(amount > 0, "borrow: amount must be nonzero");
        for (uint i = 0; i < borrowInfos.length; i++) {
            require(borrowInfos[i].borrower != msg.sender, "borrow: double borrow");
        }
        BorrowInfo memory b;
        b.borrower = msg.sender;
        b.collateralAmount = usdcToEth(amount * 10 / 5);
        for (uint i = 0; i < ethDepositInfos.length; i++) {
            if (ethDepositInfos[i].provider == msg.sender) {
                require(ethDepositInfos[i].amount >= b.collateralAmount, "borrow: not enough collateral");
                ethDepositInfos[i].amount -= b.collateralAmount;
            }
        }
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
        require(tokenAddress == address(usdc), "liquidate: tokenAddress is not USDC");
        require(amount > 0, "liquidate: liquidation amount must be nonzero");
        for (uint i = 0; i < borrowInfos.length; i++) {
            BorrowInfo storage b = borrowInfos[i];
            if (b.borrower == user) {
                uint usdcAmount = ethToUsdc(b.collateralAmount);
                if (usdcAmount <= b.liquidationThresh) {
                    require(amount <= b.collateralAmount, "liquidate: liquidation amount exceeds collateral amount");
                    if (amount == b.collateralAmount) {
                        payable(msg.sender).transfer(amount);
                        usdc.transferFrom(msg.sender, address(this), usdcAmount);
                        borrowInfos[i] = borrowInfos[borrowInfos.length - 1];
                        borrowInfos.pop();
                    }
                    else {
                        usdcAmount = usdcAmount * amount / b.collateralAmount;
                        b.collateralAmount -= amount;
                        payable(msg.sender).transfer(amount);
                        usdc.transferFrom(msg.sender, address(this), usdcAmount);
                    }
                }
                return;
            }
        }
        require(false, "liquidate: user not found");
    }

    function _withdrawUsdc(address user, uint256 amount) internal {
        for (uint i = 0; i < usdcDepositInfos.length; i++) {
            DepositInfo storage d = usdcDepositInfos[i];
            if (d.provider == user) {
                uint256 paybackAmount = calcPrincipleSum(d.amount, d.timestamp);
                require(amount <= paybackAmount, "withdraw: excessive withdrawl");
                usdc.transfer(d.provider, amount);
                if (paybackAmount == amount) {
                    usdcDepositInfos[i] = usdcDepositInfos[usdcDepositInfos.length - 1];
                    usdcDepositInfos.pop();
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

    function _withdrawEth(address user, uint256 amount) internal {
        for (uint i = 0; i < ethDepositInfos.length; i++) {
            DepositInfo storage d = ethDepositInfos[i];
            if (d.provider == user) {
                uint256 paybackAmount = calcPrincipleSum(d.amount, d.timestamp);
                require(amount <= paybackAmount, "withdraw: excessive withdrawl");
                payable(d.provider).transfer(amount);
                if (paybackAmount == amount) {
                    ethDepositInfos[i] = ethDepositInfos[ethDepositInfos.length - 1];
                    ethDepositInfos.pop();
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
