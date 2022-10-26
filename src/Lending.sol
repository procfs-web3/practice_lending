// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/DreamOracle.sol";
import "forge-std/Test.sol";

contract DreamAcademyLending {

    IPriceOracle priceOracle;
    IERC20 usdc;
    uint256 totalUsdcDeposits;
    uint256 totalEthDeposits;
    mapping (address => DepositInfo) usdcDepositInfos;
    mapping (address => DepositInfo) ethDepositInfos;
    mapping (address => BorrowInfo) usdcBorrows;
    address[] usdcBorrowers;

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
        totalUsdcDeposits = 0;
        totalEthDeposits = 0;
    }

    function initializeLendingProtocol(address _usdc) public payable {
        usdc = IERC20(_usdc);
        usdc.transferFrom(msg.sender, address(this), 1);
    }

    function getAccruedSupplyAmountInner(address _usdc, address owner) internal view returns (uint256) {
        uint256 totalAccrued = 0;
        
        if (_usdc == address(usdc)) {
            for (uint i = 0; i < usdcBorrowers.length; i++) {
                BorrowInfo memory b = usdcBorrows[usdcBorrowers[i]];
                totalAccrued += calcPrincipleSum(b.amount, block.number * 12 - b.timestamp + b.timeRemainder) - b.amount;
            }
            DepositInfo memory d = usdcDepositInfos[owner];
            return d.amount + totalAccrued * d.amount / totalUsdcDeposits;
        }
        else {
            require(_usdc == address(0));
            DepositInfo memory d = ethDepositInfos[owner];
            return d.amount;
        }
    }

    function getAccruedSupplyAmount(address _usdc) public view returns (uint256) {
        return getAccruedSupplyAmountInner(_usdc, msg.sender);
    }

    function ethValue(uint256 ethAmount) internal view returns (uint256) {
        // ethereum address 0xeeeeeeee
        return ethAmount * priceOracle.getPrice(address(0));
    }

    function usdcValue(uint256 usdcAmount) internal view returns (uint256) {
        return usdcAmount * priceOracle.getPrice(address(usdc));
    }

    function calcPrincipleSum(uint256 initBalance, uint256 elapsedTime) internal view returns (uint256) {
        uint nDays = elapsedTime / 1 days;
        if (nDays == 0 && elapsedTime > 0) {
            nDays = 1;
        }
        uint balance = initBalance;
        for (uint i = 0; i < nDays; i++) {
            balance = balance * 1001 / 1000;
        }
        return balance;
    }

    function _depositUsdc(address provider, uint256 amount) internal {
        DepositInfo storage d = usdcDepositInfos[provider];
        if (d.amount > 0) {
            d.amount = calcPrincipleSum(d.amount, block.number * 12 - d.timestamp + d.timeRemainder) + amount;
            d.timeRemainder = (block.number * 12 - d.timestamp) % 1 days;
            d.timestamp = block.number * 12;
        }
        else {
            d.amount = amount;
            d.timestamp = block.number * 12;
            d.timeRemainder = 0;
        }
        totalUsdcDeposits += amount;
    }

    function _depositEth(address provider, uint256 amount) internal {
        DepositInfo storage d = ethDepositInfos[provider];
        if (d.amount > 0) {
            d.amount = calcPrincipleSum(d.amount, block.number * 12 - d.timestamp + d.timeRemainder) + amount;
            d.timeRemainder = (block.number * 12 - d.timestamp) % 1 days;
            d.timestamp = block.number * 12;
        }
        else {
            d.amount = amount;
            d.timestamp = block.number * 12;
            d.timeRemainder = 0;
        }
        totalEthDeposits += amount;
    }

   function deposit(address tokenAddress, uint256 amount) public payable {
        if (tokenAddress == address(0)) {
            require(msg.value > 0 && msg.value == amount);
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
            BorrowInfo storage b = usdcBorrows[msg.sender];
            uint additionalCollateralAmount = usdcValue(amount * 10 / 5) / ethValue(1);
            require(ethDepositInfos[msg.sender].amount >= additionalCollateralAmount, "borrow: not enough collateral");
            b.collateralAmount += additionalCollateralAmount;
            ethDepositInfos[msg.sender].amount -= additionalCollateralAmount;
            b.amount += amount;
            // Liquidation thresh is (value of collateral in USDC) such that liquidation occurs. It is 4/3 of the current value of the loan
            b.liquidationThresh = b.amount * 100 / 75;
            b.timestamp = block.number * 12;
            usdc.transfer(msg.sender, amount);
        }
        else {
            BorrowInfo storage b = usdcBorrows[msg.sender];
            b.collateralAmount = usdcValue(amount * 10 / 5) / ethValue(1);
            require(ethDepositInfos[msg.sender].amount >= b.collateralAmount, "borrow: not enough collateral");
            ethDepositInfos[msg.sender].amount -= b.collateralAmount;
            b.amount = amount;
            b.liquidationThresh = amount * 100 / 75;
            b.timestamp = block.number * 12;
            usdc.transfer(msg.sender, amount);
        }
        bool found = false;
        for (uint i = 0; i < usdcBorrowers.length; i++) {
            if (usdcBorrowers[i] == msg.sender) {
                found = true;
                break;
            }
        }
        if (!found) {
            usdcBorrowers.push(msg.sender);
        }
    }

    function repay(address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "repay: tokenAddress is not USDC");
        require(amount > 0, "repay: amount must be nonzero");
        BorrowInfo storage b = usdcBorrows[msg.sender];
        if (b.amount > 0) {
            uint256 paybackAmount = calcPrincipleSum(b.amount, block.number * 12 - b.timestamp + b.timeRemainder);
            usdc.transferFrom(msg.sender, address(this), amount);
            if (amount >= paybackAmount) {
                // fully return collateral
                ethDepositInfos[msg.sender].amount += b.collateralAmount;
                b.timeRemainder = 0;
            }
            else {
                // partially return collateral
                b.timeRemainder = (block.number * 12 - b.timestamp) % 1 days;
                b.timestamp = block.number * 12;
                b.amount = paybackAmount - amount;
                console.log("fucking: %d %d", b.collateralAmount * amount / paybackAmount, paybackAmount);
                ethDepositInfos[msg.sender].amount += b.collateralAmount * amount / paybackAmount;
            }
        }
    }

    function liquidate(address user, address tokenAddress, uint256 amount) public {
        require(tokenAddress == address(usdc), "liquidate: tokenAddress is not USDC");
        require(amount > 0, "liquidate: liquidation amount must be nonzero");
        BorrowInfo storage b = usdcBorrows[user];
        if (b.amount > 0) {
            uint usdcAmount = ethValue(b.collateralAmount) / usdcValue(1);
            require (usdcAmount <= b.liquidationThresh);
            require(amount <= usdcAmount, "liquidate: liquidation amount exceeds collateral amount");
            if (amount == usdcAmount) {
                usdc.transferFrom(msg.sender, address(this), usdcAmount);
            }
            else {
                b.collateralAmount -= usdcValue(amount) / ethValue(1);
                b.liquidationThresh = (b.amount - amount) * 100 / 75;
                usdc.transferFrom(msg.sender, address(this), amount);
            }
            uint256 ethAmount = amount / usdcAmount * b.collateralAmount;
            payable(msg.sender).transfer(ethAmount);
        }
    }

    function _withdrawUsdc(address user, uint256 amount) internal {
        DepositInfo storage d = usdcDepositInfos[user];
        if (d.amount > 0) {
            uint256 paybackAmount = getAccruedSupplyAmountInner(address(usdc), msg.sender);
            require(amount <= paybackAmount, "withdraw: excessive withdrawl");
            usdc.transfer(user, amount);
            d.timestamp = block.number * 12;
            d.timeRemainder = (block.number * 12 - d.timestamp) % 1 days;
            d.amount = paybackAmount - amount;
            totalUsdcDeposits -= amount;
        }
    }

    function _withdrawEth(address user, uint256 amount) internal {
        DepositInfo storage d = ethDepositInfos[user];
        BorrowInfo storage b = usdcBorrows[user];
        require(d.amount > 0 || b.collateralAmount > 0);
        uint256 paybackAmount = d.amount + b.collateralAmount - usdcValue(b.liquidationThresh) / ethValue(1);
        require(amount <= paybackAmount, "withdraw: excessive withdrawl");
        d.timestamp = block.number * 12;
        d.timeRemainder = (block.number * 12 - d.timestamp) % 1 days;
        d.amount = paybackAmount - amount;
        totalEthDeposits -= amount;
        payable(user).transfer(amount);
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
