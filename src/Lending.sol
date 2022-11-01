// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/DreamOracle.sol";

contract DreamAcademyLending {
    IPriceOracle priceOracle;
    IERC20 usdc;
    uint256 totalUsdcLoanWiInterest;
    uint256 totalUsdcLoanWoInterest;
    uint256 usdcLoanTs;
    uint256 totalUsdcDeposits;
    uint256 usdcDepositTs;
    uint256 totalEthDeposits;
    mapping(address => DepositInfo) usdcDepositInfos;
    mapping(address => DepositInfo) ethDepositInfos;
    mapping(address => BorrowInfo) usdcBorrows;

    address[] currentHolders;
    uint256 currentHoldersTs;

    struct DepositInfo {
        uint256 amount;
    }

    struct BorrowInfo {
        uint256 loanAmount;
        uint256 collateralAmount;
        uint256 timestamp;
        uint256 timeRemainder;
    }

    constructor(IPriceOracle _priceOracle, address _usdc) {
        priceOracle = _priceOracle;
        usdc = IERC20(_usdc);
        totalUsdcLoanWiInterest = 0;
        totalUsdcLoanWoInterest = 0;
        usdcLoanTs = 0;
        totalUsdcDeposits = 0;
        usdcDepositTs = 0;
        totalEthDeposits = 0;
    }

    function initializeLendingProtocol(address _usdc) public payable {
        usdc = IERC20(_usdc);
        usdc.transferFrom(msg.sender, address(this), 1);
    }

    function getAccruedSupplyAmountInner(address _usdc, address owner)
        internal
        view
        returns (uint256)
    {
        if (_usdc == address(usdc)) {
            uint256 totalAccrued = calcPrincipleSum(
                totalUsdcLoanWiInterest,
                block.number * 12 - usdcLoanTs
            ) - totalUsdcLoanWoInterest;
            DepositInfo memory d = usdcDepositInfos[owner];
            // amount of USDC that should be 'held' by owner ideally
            return d.amount + (totalAccrued * d.amount) / totalUsdcDeposits;
        } else {
            require(_usdc == address(0));
            DepositInfo memory d = ethDepositInfos[owner];
            return d.amount;
        }
    }

    function getAccruedSupplyAmount(address _usdc)
        public
        view
        returns (uint256)
    {
        return getAccruedSupplyAmountInner(_usdc, msg.sender);
    }

    function ethValue(uint256 ethAmount) internal view returns (uint256) {
        // ethereum address 0xeeeeeeee
        return ethAmount * priceOracle.getPrice(address(0));
    }

    function usdcValue(uint256 usdcAmount) internal view returns (uint256) {
        return usdcAmount * priceOracle.getPrice(address(usdc));
    }

    function calcPrincipleSum(uint256 initBalance, uint256 elapsedTime)
        internal
        view
        returns (uint256)
    {
        uint256 nDays = elapsedTime / 1 days;
        if (nDays == 0 && elapsedTime > 0) {
            nDays = 1;
        }
        uint256 balance = initBalance;
        for (uint256 i = 0; i < nDays; i++) {
            balance = (balance * 1001) / 1000;
        }
        return balance;
    }

    function _depositUsdc(address provider, uint256 amount) internal {
        if (currentHoldersTs == 0) {
            currentHolders.push(msg.sender);
            currentHoldersTs = block.number * 12;
        } else if (currentHoldersTs < block.number * 12) {
            // distribute current share to all holders
            if (currentHolders.length == 0) {
                currentHolders.push(msg.sender);
                return;
            }
            for (uint256 i = 0; i < currentHolders.length; i++) {
                address holder = currentHolders[i];
                uint256 balance = getAccruedSupplyAmountInner(
                    address(usdc),
                    holder
                );
                usdcDepositInfos[holder].amount = balance;
            }
            totalUsdcLoanWoInterest = calcPrincipleSum(
                totalUsdcLoanWiInterest,
                block.number * 12 - usdcLoanTs
            );
            totalUsdcLoanWiInterest = totalUsdcLoanWoInterest;
            usdcLoanTs = block.number * 12;
            delete currentHolders;
            currentHolders.push(msg.sender);
            currentHoldersTs = block.number * 12;
        } else {
            for (uint256 i = 0; i < currentHolders.length; i++) {
                if (currentHolders[i] == msg.sender) {
                    return;
                }
            }
            currentHolders.push(msg.sender);
        }

        DepositInfo storage d = usdcDepositInfos[provider];
        if (d.amount > 0) {
            d.amount += amount;
        } else {
            d.amount = amount;
        }
        if (usdcDepositTs == 0) {
            totalUsdcDeposits = amount;
            usdcDepositTs = block.number * 12;
        } else {
            uint256 before = totalUsdcDeposits;
            totalUsdcDeposits += amount;
            usdcDepositTs = block.number * 12;
        }
    }

    function _depositEth(address provider, uint256 amount) internal {
        DepositInfo storage d = ethDepositInfos[provider];
        if (d.amount > 0) {
            d.amount += amount;
        } else {
            d.amount = amount;
        }
        // for ETH, we do not consider interest rates because we cannot borrow ETH, and thus share calcalation is unnecessary
        totalEthDeposits += amount;
    }

    function deposit(address tokenAddress, uint256 amount) public payable {
        if (tokenAddress == address(0)) {
            require(msg.value > 0 && msg.value == amount);
            _depositEth(msg.sender, msg.value);
        } else {
            require(
                tokenAddress == address(usdc),
                "deposit: tokenAddress is not USDC"
            );
            usdc.transferFrom(msg.sender, address(this), amount);
            _depositUsdc(msg.sender, amount);
        }
    }

    function borrow(address tokenAddress, uint256 amount) public {
        require(
            tokenAddress == address(usdc),
            "borrow: tokenAddress is not USDC"
        );
        require(amount > 0, "borrow: amount must be nonzero");
        if (usdcBorrows[msg.sender].loanAmount > 0) {
            BorrowInfo storage b = usdcBorrows[msg.sender];
            uint256 additionalCollateralAmount = usdcValue((amount * 10) / 5) /
                ethValue(1);
            require(
                ethDepositInfos[msg.sender].amount >=
                    additionalCollateralAmount,
                "borrow: not enough collateral"
            );
            b.collateralAmount += additionalCollateralAmount;
            ethDepositInfos[msg.sender].amount -= additionalCollateralAmount;
            b.loanAmount += amount;
            b.timestamp = block.number * 12;
            usdc.transfer(msg.sender, amount);
        } else {
            BorrowInfo storage b = usdcBorrows[msg.sender];
            b.collateralAmount = usdcValue((amount * 10) / 5) / ethValue(1);
            require(
                ethDepositInfos[msg.sender].amount >= b.collateralAmount,
                "borrow: not enough collateral"
            );
            ethDepositInfos[msg.sender].amount -= b.collateralAmount;
            b.loanAmount = amount;
            b.timestamp = block.number * 12;
            usdc.transfer(msg.sender, amount);
        }
        if (usdcLoanTs == 0) {
            totalUsdcLoanWiInterest = amount;
            totalUsdcLoanWoInterest = amount;
            usdcLoanTs = block.number * 12;
        } else {
            totalUsdcLoanWiInterest =
                calcPrincipleSum(
                    totalUsdcLoanWiInterest,
                    block.number * 12 - usdcLoanTs
                ) +
                amount;
            totalUsdcLoanWoInterest += amount;
            usdcLoanTs = block.number * 12;
        }
    }

    function repay(address tokenAddress, uint256 amount) public {
        require(
            tokenAddress == address(usdc),
            "repay: tokenAddress is not USDC"
        );
        require(amount > 0, "repay: amount must be nonzero");
        BorrowInfo storage b = usdcBorrows[msg.sender];
        if (b.loanAmount > 0) {
            uint256 repayAmount = calcPrincipleSum(
                b.loanAmount,
                block.number * 12 - b.timestamp + b.timeRemainder
            );
            usdc.transferFrom(msg.sender, address(this), amount);
            if (amount >= repayAmount) {
                // fully return collateral
                ethDepositInfos[msg.sender].amount += b.collateralAmount;
                b.timeRemainder = 0;
            } else {
                // partially return collateral
                b.timeRemainder = (block.number * 12 - b.timestamp) % 1 days;
                b.timestamp = block.number * 12;
                b.loanAmount = repayAmount - amount;
                ethDepositInfos[msg.sender].amount +=
                    (b.collateralAmount * amount) /
                    repayAmount;
            }
        }
    }

    function liquidate(
        address user,
        address tokenAddress,
        uint256 amount
    ) public {
        require(
            tokenAddress == address(usdc),
            "liquidate: tokenAddress is not USDC"
        );
        require(amount > 0, "liquidate: liquidation amount must be nonzero");
        BorrowInfo storage b = usdcBorrows[user];
        DepositInfo memory d = ethDepositInfos[user];
        require(b.loanAmount > 0);
        uint256 collateralValueUsdc = ethValue(b.collateralAmount + d.amount) /
            usdcValue(1);
        uint256 realLoanAmount = calcPrincipleSum(
            b.loanAmount,
            block.number * 12 - b.timestamp + b.timeRemainder
        );
        require(
            collateralValueUsdc <= (realLoanAmount * 100) / 75,
            "liquidation threshold not reached"
        );
        if (b.loanAmount <= 100 ether) {
            require(
                amount <= realLoanAmount,
                "liquidate: liquidation amount exceeds collateral amount"
            );
        } else {
            require(
                amount * 4 <= realLoanAmount,
                "liquidate: liquidation amount exceeds collateral amount"
            );
        }
        if (amount == collateralValueUsdc) {
            b.loanAmount = 0;
            usdc.transferFrom(msg.sender, address(this), amount);
        } else {
            b.loanAmount -= amount;
            b.collateralAmount -= usdcValue(amount) / ethValue(1);
            usdc.transferFrom(msg.sender, address(this), amount);
        }
        uint256 ethAmount = (amount / collateralValueUsdc) * b.collateralAmount;
        payable(msg.sender).transfer(ethAmount);
    }

    function _withdrawUsdc(address user, uint256 amount) internal {
        DepositInfo storage d = usdcDepositInfos[user];
        if (d.amount > 0) {
            uint256 balance = getAccruedSupplyAmountInner(
                address(usdc),
                msg.sender
            );
            require(amount <= balance, "withdraw: excessive withdrawl");
            usdc.transfer(user, amount);
            d.amount = balance - amount;
            totalUsdcDeposits -= amount;
        }
    }

    function _withdrawEth(address user, uint256 amount) internal {
        DepositInfo storage d = ethDepositInfos[user];
        BorrowInfo storage b = usdcBorrows[user];
        // ETH can be 'locked', consider this into account
        require(d.amount > 0 || b.collateralAmount > 0);
        uint256 realLoanAmount = calcPrincipleSum(
            b.loanAmount,
            block.number * 12 - b.timestamp + b.timeRemainder
        );
        // this is the value of the collateral, in USDC such that liquidation occurs
        uint256 liquidationThresh = (realLoanAmount * 100) / 75;
        // ETH with amounts which have equivalent value to liquidationThresh must remain
        uint256 balance = d.amount +
            b.collateralAmount -
            usdcValue(liquidationThresh) /
            ethValue(1);
        require(amount <= balance, "withdraw: excessive withdrawl");
        d.amount = balance - amount;
        totalEthDeposits -= amount;
        payable(user).transfer(amount);
    }

    function withdraw(address tokenAddress, uint256 amount) public {
        require(amount > 0, "withdraw: amount must be nonzero");
        if (tokenAddress == address(0)) {
            _withdrawEth(msg.sender, amount);
        } else {
            require(
                tokenAddress == address(usdc),
                "withdraw: token is not USDC"
            );
            _withdrawUsdc(msg.sender, amount);
        }
    }
}
