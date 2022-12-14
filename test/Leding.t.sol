// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/Lending.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract USDC is ERC20 {
    uint public constant USDC_INITIAL_SUPPLY = 1000 ether;
    constructor() ERC20("USD Coin", "USDC") {
        super._mint(msg.sender, USDC_INITIAL_SUPPLY);
    }
}

contract LendingTest is Test {

    LendingService bank;
    DreamOracle oracle;
    ERC20 usdc;

    function setUp() public {
        oracle = new DreamOracle();
        usdc = new USDC();
        bank = new LendingService(address(usdc), address(oracle));
        // set up initial USDC pool for bank
        vm.deal(address(bank), 10 ether);
        usdc.transfer(address(bank), 10 ether);
    }

    function testDepositBasic1() public {
        address actor = address(0x11);
        usdc.transfer(actor, 1 ether);
        uint256 balPrev;
        uint256 balAfter;

        vm.startPrank(actor);
        vm.warp(0);
        usdc.approve(address(bank), 1 ether);
        bank.deposit(address(usdc), 1 ether);
        vm.warp(1 days);
        balPrev = usdc.balanceOf(actor);
        bank.withdraw(address(usdc), 1.001 ether);
        balAfter = usdc.balanceOf(actor);
        assertEq(balAfter - balPrev, 1.001 ether);
    }

    function testDepositBasic2() public {
        address actor = address(0x11);
        vm.deal(actor, 20 ether);
        uint256 balPrev;
        uint256 balAfter;

        vm.startPrank(actor);
        vm.warp(0);
        bank.deposit{value: 10 ether}(address(0), 0);
        vm.warp(1 days);
        balPrev = actor.balance;
        bank.withdraw(address(0), 10.01 ether);
        balAfter = actor.balance;
        assertEq(balAfter - balPrev, 10.01 ether);
    }


    function testLendBasic() public {
        address actor = address(0x11);
        usdc.transfer(actor, 10 ether);
        vm.deal(actor, 10 ether);
        uint256 balPrev;
        uint256 balAfter;
        uint256 etherAmount;
        oracle.setPrice(address(usdc), 2);

        vm.startPrank(actor);
        vm.warp(0);
        balPrev = usdc.balanceOf(actor);
        etherAmount = oracle.getPrice(address(usdc)) * 1 ether * 2;
        bank.deposit{value: etherAmount}(address(0), 0);
        bank.borrow(address(usdc), 1 ether);
        balAfter = usdc.balanceOf(actor);
        assertEq(balPrev + 1 ether, balAfter);
        vm.warp(1 days);
        
        // first, repay 1 ether
        balPrev = actor.balance;
        usdc.approve(address(bank), 1.001 ether);
        bank.repay(address(usdc), 1.000 ether);
        balAfter = actor.balance;
        assertEq(balPrev, balAfter);

        // repay the interest, resulting in the collateral being returned
        balPrev = actor.balance;
        bank.repay(address(usdc), 0.001 ether);
        balAfter = actor.balance;
        assertEq(balPrev + etherAmount, balAfter);
    }

    function testLiquidateBasic1() public {
        address actor1 = address(0x11);
        address actor2 = address(0x22);
        usdc.transfer(actor1, 10 ether);
        usdc.transfer(actor2, 10 ether);
        vm.deal(actor1, 10 ether);
        uint256 balPrev;
        uint256 balAfter;
        uint256 etherAmount;
        oracle.setPrice(address(usdc), 2);

        vm.startPrank(actor1);
        vm.warp(0);
        balPrev = usdc.balanceOf(actor1);
        etherAmount = oracle.getPrice(address(usdc)) * 1 ether * 2;
        bank.deposit{value: etherAmount}(address(0), 0);
        bank.borrow(address(usdc), 1 ether);
        balAfter = usdc.balanceOf(actor1);
        assertEq(balPrev + 1 ether, balAfter);
        vm.warp(1 days);
        vm.stopPrank();

        // lower the price of ETH so that liquidation is triggered
        oracle.setPrice(address(usdc), 4);
        vm.startPrank(actor2);
        balPrev = usdc.balanceOf(actor2);
        usdc.approve(address(bank), 10 ether);
        bank.liquidate(actor1, address(usdc), etherAmount);
        balAfter = usdc.balanceOf(actor2);
        assertGt(balPrev, balAfter);
        vm.stopPrank();
    }

    function testLiquidateBasic2() public {
        address actor1 = address(0x11);
        address actor2 = address(0x22);
        usdc.transfer(actor1, 10 ether);
        usdc.transfer(actor2, 10 ether);
        vm.deal(actor1, 10 ether);
        uint256 balPrev;
        uint256 balAfter;
        uint256 etherAmount;
        oracle.setPrice(address(usdc), 2);

        vm.startPrank(actor1);
        vm.warp(0);
        balPrev = usdc.balanceOf(actor1);
        etherAmount = oracle.getPrice(address(usdc)) * 1 ether * 2;
        bank.deposit{value: etherAmount}(address(0), 0);
        bank.borrow(address(usdc), 1 ether);
        balAfter = usdc.balanceOf(actor1);
        assertEq(balPrev + 1 ether, balAfter);
        vm.warp(1 days);
        vm.stopPrank();

        // liquidation is not triggered
        vm.startPrank(actor2);
        balPrev = usdc.balanceOf(actor2);
        usdc.approve(address(bank), 10 ether);
        bank.liquidate(actor1, address(usdc), etherAmount);
        balAfter = usdc.balanceOf(actor2);
        assertEq(balPrev, balAfter);
        vm.stopPrank();
    }

    function testDoubleDeposit() public {
        address actor = address(0x11);
        uint256 balPrev;
        uint256 balAfter;
        usdc.transfer(actor, 10 ether);
        oracle.setPrice(address(usdc), 2);

        vm.startPrank(actor);
        usdc.approve(address(bank), 2 ether);
        balPrev = usdc.balanceOf(address(bank));
        bank.deposit(address(usdc), 1 ether);
        bank.deposit(address(usdc), 1 ether);
        balAfter = usdc.balanceOf(address(bank));
        assertEq(balAfter, balPrev + 2 ether);
    }

    function testLiquidatePartial() public {
        address actor1 = address(0x11);
        address actor2 = address(0x22);
        address actor3 = address(0x33);
        usdc.transfer(actor1, 10 ether);
        usdc.transfer(actor2, 10 ether);
        usdc.transfer(actor3, 10 ether);
        vm.deal(actor1, 10 ether);
        uint256 balPrev;
        uint256 balAfter;
        uint256 etherAmount;
        uint256 liquidateUsdc1;
        uint256 liquidateUsdc2;
        oracle.setPrice(address(usdc), 2);

        vm.startPrank(actor1);
        vm.warp(0);
        balPrev = usdc.balanceOf(actor1);
        etherAmount = oracle.getPrice(address(usdc)) * 1 ether * 2;
        bank.deposit{value: etherAmount}(address(0), 0);
        bank.borrow(address(usdc), 1 ether);
        balAfter = usdc.balanceOf(actor1);
        assertEq(balPrev + 1 ether, balAfter);
        vm.warp(1 days);
        vm.stopPrank();

        // lower the price of ETH so that liquidation is triggered
        oracle.setPrice(address(usdc), 4);
        vm.startPrank(actor2);
        usdc.approve(address(bank), 10 ether);
        balPrev = usdc.balanceOf(actor2);
        bank.liquidate(actor1, address(usdc), etherAmount / 2);
        balAfter = usdc.balanceOf(actor2);
        liquidateUsdc1 = balPrev - balAfter;
        vm.stopPrank();

        vm.startPrank(actor3);
        usdc.approve(address(bank), 10 ether);
        balPrev = usdc.balanceOf(actor3);
        bank.liquidate(actor1, address(usdc), etherAmount / 4);
        balAfter = usdc.balanceOf(actor3);
        liquidateUsdc2 = balPrev - balAfter;
        vm.stopPrank();
        
        assertEq(liquidateUsdc1, liquidateUsdc2 * 2);
    }
}
