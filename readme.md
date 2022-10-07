## Lending 패치
### deposits과 borrows를 array에서 mapping으로 변경
기존에는 deposit한 내역과 borrow한 내역을 provider/borrower의 주소가 담겨있는 구조체의 배열로 관리하였다. 그러나 이는 O(N)의 공간 복잡도 및 시간 복잡도를 가진다는 단점이 있어서 address를 key로 하는 매핑으로 수정하였다.

이 과정에서 멘토님께서 알려주신 critical 취약점 하나가 자연스럽게 사라졌다. 그 취약점은 borrow함수에 존재하는 것으로,
```solidity
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
```

depositInfo가 없으면 LTV 제약조건 없이 무조건 대출을 받을 수 있게 되는 중대한 취약점이다. mapping을 사용하게 되면, 모든 address마다 BorrowInfo 엔트리가 default로 존재하는 것과 같은 효과가 생기므로 위와 같은 취약점이 자연스럽게 사라진다.

```solidity
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
```

### 이자 계산 단위가 24시간으로 나누어떨어지지 않으면 발생하는 문제
기존 구현에서는 원리합계를 계산할 때 지나간 일수를 계산한 후, 불어난 빚 또는 예금을 `entry.amount`에 저장해준 후 timestamp를 최신화해주었다. 이러한 구현에는 허점이 존재하는데, 23시간 59분마다 나누어 상환을 할 경우 이자를 하나도 지불하지 않을 수 있다는 점이다. 따라서, 24시간으로 나누고 발생한 나머지 시간도 따로 관리해주어야 한다.

```solidity
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
```

따라서 위와 같이, `timeRemainder`라는 필드를 만들어 24시간으로 나누고 남은 시간을 저장하도록 하였다. `timeRemainder`가 사용되는 예시는 다음과 같다.

```solidity
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
```

새롭게 대출/예금을 하면 원리합계를 계산하여 amount에 넣어주고, timestamp를 최신화해주는 것은 동일하다. 다른 점은 원리합계를 계산할 때 흐른 시간에 `d.timeRemainder`를 넣어주고, `d.timeRemainder`를 재계산해준다는 점이다. 이러한 구현을 따를 경우 23시간 59분마다 대출을 받더라도 `block.timestamp - d.timestamp + d.timeRemainder`가 23시간 59분 + 23시간 59분 = 47시간 58분 이 되어 이자를 올바르게 정산받을 수 있다.

### transfer함수로 인해 발생하는 reentrancy 해결
기존의 repay함수를 보면
```solidity
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
```

transfer함수로 인해 reentrancy가 발생될 수 있다. 물론 이 코드에서는 reentrancy가 공격용으로 사용되기 어렵지만, 수정하여 check-update-call의 형식에 맞도록 순서를 조정하였다.

```solidity
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
```

### 부분 상환시 담보 unlock
기존의 repay구현에서는 부분 상환시에는 담보를 돌려주지 않고, 전부 상환했을 경우 한꺼번에 보내주었다. 여기에 부분상환시 상환한 양에 비례하는 담보를 돌려주도록 기능을 추가하였다. 

```solidity
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
```