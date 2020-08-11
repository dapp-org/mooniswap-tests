// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.6.12;

import {DSMath} from "ds-math/math.sol";
import {DSTest} from "ds-test/test.sol";
import {DSToken} from "ds-token/token.sol";
import {Mooniswap} from "mooniswap/contracts/Mooniswap.sol";
import {MooniFactory} from "mooniswap/contracts/MooniFactory.sol";
import {IERC20} from "mooniswap/contracts/libraries/UniERC20.sol";
import {Sqrt} from "mooniswap/contracts/libraries/Sqrt.sol";

abstract contract Hevm {
    function warp(uint) public virtual;
}

contract User {
    Mooniswap pair;

    constructor(Mooniswap _pair) public {
        pair = _pair;
    }

    receive() payable external {}

    function approve(address token, address who) public {
        DSToken(token).approve(who);
    }

    function deposit(uint256 amount0, uint256 amount1, uint256 minReturn)
        external payable returns(uint256 fairSupply)
    {
        uint[] memory amounts = new uint[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;
        // handle ETH
        if (address(pair.tokens(0)) == address(0)) {
            return pair.deposit{value: amount0}(amounts, minReturn);
        } else {
            return pair.deposit(amounts, minReturn);
        }
    }

    function withdraw(uint256 amount, uint256 minReturn0, uint256 minReturn1) external {
        uint[] memory minimums = new uint[](2);
        minimums[0] = minReturn0;
        minimums[1] = minReturn1;
        pair.withdraw(amount, minimums);
    }

    function swap(DSToken src, DSToken dst, uint256 amount)
        external payable returns(uint256 result)
    {
        // handle ETH
        if (address(src) == address(0)) {
            return pair.swap{value: amount}(IERC20(address(src)), IERC20(address(dst)), amount, 0, address(0));
        } else {
            return pair.swap(IERC20(address(src)), IERC20(address(dst)), amount, 0, address(0));
        }
    }

    function swapReferall(DSToken src, DSToken dst, uint256 amount, address referal)
        external payable returns(uint256 result)
    {
        return pair.swap(IERC20(address(src)), IERC20(address(dst)), amount, 0, referal);
    }
}

contract MooniswapTest is DSTest, DSMath {

    Hevm hevm;
    User userA;
    User userB;
    User userC;
    Mooniswap pair;
    MooniFactory factory;
    DSToken token0;
    DSToken token1;

    function setUp() public {
        DSToken tokenA = new DSToken("TST-0");
        DSToken tokenB = new DSToken("TST-1");
        factory = new MooniFactory();
        pair = Mooniswap(factory.deploy(IERC20(address(tokenA)), IERC20(address(tokenB))));

        token0 = DSToken(address(pair.tokens(0)));
        token1 = DSToken(address(pair.tokens(1)));

        userA = new User(pair); userInit(userA);
        userB = new User(pair); userInit(userB);
        userC = new User(pair); userInit(userC);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200); // Sat Feb 25 12:00:00 UTC 1989
    }

    function userInit(User user) public {
        token0.mint(address(user), uint(-1) / 3);
        token1.mint(address(user), uint(-1) / 3);

        user.approve(address(token0), address(pair));
        user.approve(address(token1), address(pair));
    }

    event Print(string msg, uint256 value);
    event Printi(string msg, int256 value);

    // ================================================================
    //                            Deposit
    // ================================================================

    // helper: makes an initial deposit and asserts some properties
    function depositInitial(uint64 amt0, uint64 amt1) internal {
        // skip the whole test if any value is zero
        if (amt0 == 0 || amt1 == 0) return;

        uint userBal0 = token0.balanceOf(address(userA));
        uint userBal1 = token1.balanceOf(address(userA));
        uint fairSupply = max(99000, max(amt0, amt1));

        uint actual = userA.deposit(amt0, amt1, fairSupply);

        // the user has received the correct amount of LP shares
        assertEq(actual, fairSupply);
        assertEq(pair.balanceOf(address(userA)), fairSupply);

        // 1000 LP shares have been minted to the pool
        assertEq(pair.balanceOf(address(pair)), 1000);

        // totalSupply is correct
        assertEq(pair.totalSupply(), add(fairSupply, 1000));

        // the correct amount of tokens have been pulled from the user
        assertEq(userBal0 - amt0, token0.balanceOf(address(userA)));
        assertEq(userBal1 - amt1, token1.balanceOf(address(userA)));

        // the tokens are with the pair now
        assertEq(amt0, token0.balanceOf(address(pair)));
        assertEq(amt1, token1.balanceOf(address(pair)));
    }

    // helper: makes a subsequent deposit and asserts some properties
    function depositSubsequent(uint64 amt0, uint64 amt1) internal {
        // skip the whole test if any value is zero
        if (amt0 == 0 || amt1 == 0) return;

        uint totalSupply = pair.totalSupply();

        // or previous deposit did not complete
        if (totalSupply == 0) return;
        uint pairBal0 = token0.balanceOf(address(pair));
        uint pairBal1 = token1.balanceOf(address(pair));
        uint userBal0 = token0.balanceOf(address(userA));
        uint userBal1 = token1.balanceOf(address(userA));
        uint userLPShares = pair.balanceOf(address(userA));

        uint fairSupply = min(
            mul(totalSupply, amt0) / pairBal0,
            mul(totalSupply, amt1) / pairBal1
        );

        uint sent0 = add(mul(pairBal0, fairSupply), sub(totalSupply, 1)) / totalSupply;
        uint sent1 = add(mul(pairBal1, fairSupply), sub(totalSupply, 1)) / totalSupply;

        fairSupply = min(
            mul(sent0, totalSupply) / pairBal0,
            mul(sent1, totalSupply) / pairBal1
        );

        // if fairSupply ends up being 0, the subsequent deposit will revert.
        // Therefore we finish the test early if this is the case
        if (fairSupply == 0) { return; }

        uint actual = userA.deposit(amt0, amt1, 0);

        // totalSupply is correct
        assertEq(pair.totalSupply(), totalSupply + fairSupply);

        // the user has received fairSupply LP shares
        assertEq(actual, fairSupply);
        assertEq(sub(pair.balanceOf(address(userA)), userLPShares), fairSupply);

        // the user has not sent more than they expected
        assertTrue(userBal1 - token1.balanceOf(address(userA)) <= amt1);
        assertTrue(userBal0 - token0.balanceOf(address(userA)) <= amt0);

        // the tokens are with the pair now
        assertEq(
            token0.balanceOf(address(pair)) - pairBal0,
            userBal0 - token0.balanceOf(address(userA))
        );
        assertEq(
            token1.balanceOf(address(pair)) - pairBal1,
            userBal1 - token1.balanceOf(address(userA))
        );
    }

    /*
       Tests initial and subsequent deposits with fully abstract arguments
       Exercises `deposit` using as large values as is possible without encoutering overflow
    */
    function testDeposit(uint64 fst0, uint64 fst1, uint64 snd0, uint64 snd1) public {
        // --- initial deposit ---

        depositInitial(fst0, fst1);
        (uint vbAdd0, uint vbAdd1, uint vbRem0, uint vbRem1) = getVirtualBalances();
        (uint t_vbAdd0, uint t_vbAdd1, uint t_vbRem0, uint t_vbRem1) = getVirtualTimestamps();

        // the time for virtual balances is 0
        assertEq(t_vbAdd0, 0);
        assertEq(t_vbAdd1, 0);
        assertEq(t_vbRem0, 0);
        assertEq(t_vbRem1, 0);

        // virtual balances and real balances agree
        uint preBal0 = token0.balanceOf(address(pair));
        uint preBal1 = token1.balanceOf(address(pair));

        assertEq(preBal0, vbAdd0);
        assertEq(preBal0, vbRem0);
        assertEq(preBal1, vbAdd1);
        assertEq(preBal1, vbRem1);

        depositSubsequent(snd0, snd1);

        // end the test early if the second deposit did not succeed
        if (token0.balanceOf(address(pair)) == preBal0) return;
        // the time for virtual balances has been reset
        (t_vbAdd0, t_vbAdd1, t_vbRem0, t_vbRem1) = getVirtualTimestamps();
        assertEq(t_vbAdd0, block.timestamp);
        assertEq(t_vbAdd1, block.timestamp);
        assertEq(t_vbRem0, block.timestamp);
        assertEq(t_vbRem1, block.timestamp);

        // virtual balances and real balances agree
        (vbAdd0, vbAdd1, vbRem0, vbRem1) = getVirtualBalances();
        assertEq(token0.balanceOf(address(pair)), vbAdd0);
        assertEq(token0.balanceOf(address(pair)), vbRem0);
        assertEq(token1.balanceOf(address(pair)), vbAdd1);
        assertEq(token1.balanceOf(address(pair)), vbRem1);
    }

    function testDepositAgain(uint64 fst0, uint64 fst1, uint64 snd0, uint64 snd1, uint64 thd0) public {
      testDeposit(fst0,fst1,snd0,snd1);
      // quit if thd0 is 0 or no deposit succeeded
      if (thd0 == 0 || token0.balanceOf(address(pair)) == 0) return;
      uint pre0bal = token0.balanceOf(address(userC));
      uint pre1bal = token1.balanceOf(address(userC));
      // try to do an optimal deposit
      // assume pool is balanced now. So price of token1 is the ratio:
      uint thd1 = token1.balanceOf(address(pair)) * thd0 / token0.balanceOf(address(pair));
      if (thd1 == 0) return;

      userC.deposit(thd0, thd1,0);

      uint post0bal = token0.balanceOf(address(userC));
      uint post1bal = token1.balanceOf(address(userC));
      // as always, drawn money is less than max amount
      assertTrue(sub(pre0bal, post0bal) <= thd0);
      assertTrue(sub(pre1bal, post1bal) <= thd1);
    }

    // some concrete values so we can get a gas read
    function testDepositSpecific() public {
      userA.deposit(123,123,0);
    }

    // some concrete values so we can get a gas read
    function testSwapSpecific() public {
      userA.deposit(123,123,0);
      userB.swap(token0, token1, 10);
    }

    /*
       Tests the virtual balance scaling in deposit
       Sequences some swaps and deposits, jumps through time
    */
    function testDepositVirtualBalanceScaling(uint seed) public {
        randomSeed = seed;
        // initial deposit
        depositInitial(uint64(newRand()), uint64(newRand()));

        // subsequent deposit
        (uint vbAdd0Pre, uint vbAdd1Pre, uint vbRem0Pre, uint vbRem1Pre) = getVirtualBalances();
        depositSubsequent(uint64(newRand()), uint64(newRand()));
        assertVirtualBalanceScaling(vbAdd0Pre, vbAdd1Pre, vbRem0Pre, vbRem1Pre);

        // make a swap
        uint swapAmt = max(30, uint56(newRand()));
        if (toBool(newRand())) { userA.swap(token0, token1, swapAmt); }
        else                   { userA.swap(token1, token0, swapAmt); }

        // jump forward some amount < 5mins
        uint8 jump = uint8(newRand());
        hevm.warp(block.timestamp + jump);

        // make a deposit
        (vbAdd0Pre, vbAdd1Pre, vbRem0Pre, vbRem1Pre) = getVirtualBalances();
        userA.deposit(uint56(newRand()), uint64(newRand()), 0);
        assertVirtualBalanceScaling(vbAdd0Pre, vbAdd1Pre, vbRem0Pre, vbRem1Pre);
    }

    /*
       asserts that the virtual balances have scaled as expected given the
       prestate of the virtual balances.

       The expression here can be derived from the relationship in the
       whitepaper using the following facts:

       1. The new real and virtual balances lie on a hyperbola
       2. The old and new virtual balances lie on the same line through the origin

       TODO: these assertions are off by up to 1%, not sure why. Perhaps
             due to division within `current` and `scale`?
    */
    function square(uint x) internal pure returns (uint) { return mul(x, x); }

    function assertVirtualBalanceScaling(
        uint vbAdd0Pre, uint vbAdd1Pre, uint vbRem0Pre, uint vbRem1Pre
    ) internal {
        uint realBal0 = token0.balanceOf(address(pair));
        uint realBal1 = token1.balanceOf(address(pair));

        {
            uint vbAdd0 = mul(realBal0, mul(realBal1, vbAdd0Pre));
            (uint vbAdd0Post,,,) = getVirtualBalances();
            assertAlmostEq(mul(square(vbAdd0Post), vbRem1Pre), vbAdd0, 1 ether);
        }
        {
            uint vbAdd1 = mul(realBal0, mul(realBal1, vbAdd1Pre));
            (,uint vbAdd1Post,,) = getVirtualBalances();
            assertAlmostEq(mul(square(vbAdd1Post), vbRem0Pre), vbAdd1, 1 ether);
        }
        {
            uint vbRem0 = mul(realBal0, mul(realBal1, vbRem0Pre));
            (,,uint vbRem0Post,) = getVirtualBalances();
            assertAlmostEq(mul(square(vbRem0Post), vbAdd1Pre), vbRem0, 1 ether);
        }
        {
            uint vbRem1 = mul(realBal0, mul(realBal1, vbRem1Pre));
            (,,, uint vbRem1Post) = getVirtualBalances();
            assertAlmostEq(mul(square(vbRem1Post), vbAdd0Pre), vbRem1, 1 ether);
        }
    }

    // ================================================================
    //                           Withdraw
    // ================================================================

    /*
        Tests withdraw with fully abstract arguments.

        testWithdraw0: initial deposits will suffer some
        impairment on withdrawal due to base liquidity which
        is retained at the exchange.
    */
    function testWithdraw0(uint64 amt0, uint64 amt1) public {
      // skip the whole test if any value is zero
        if (amt0 == 0 || amt1 == 0) return;
        uint userBal0 = token0.balanceOf(address(userA));
        uint userBal1 = token1.balanceOf(address(userA));

        uint liquidity = userA.deposit(amt0, amt1, 0);

        // deposited amounts are at the exchange
        assertEq(amt0, token0.balanceOf(address(pair)));
        assertEq(amt1, token1.balanceOf(address(pair)));

        // return amounts should be proportional to supplied liquidity
        uint rtn0 = mul(amt0, liquidity) / pair.totalSupply();
        uint rtn1 = mul(amt1, liquidity) / pair.totalSupply();

        userA.withdraw(liquidity, rtn0, rtn1);

        // tokens are returned to user with slight impairment
        // which is not greater than base liquidity
        assertEq(token0.balanceOf(address(userA)), userBal0 - amt0 + rtn0);
        assertEq(token1.balanceOf(address(userA)), userBal1 - amt1 + rtn1);
        assertTrue(amt0 - rtn0 <= 1000);
        assertTrue(amt1 - rtn1 <= 1000);

        // LP shares base supply remains at the exchange
        assertEq(1000, pair.balanceOf(address(pair)));

        // some tokens remain at the exchange
        assertEq(token0.balanceOf(address(pair)), amt0 - rtn0);
        // remaining tokens are not greater than base liquidity
        assertTrue(token0.balanceOf(address(pair)) <= 1000);
        assertTrue(token1.balanceOf(address(pair)) <= 1000);
    }

    /*
        testWidthdraw1: subsequent deposits can suffer
        impairment on withdrawals.
    */
    function testWithdraw1(uint64 amt0, uint64 amt1, uint64 amt3, uint64 amt4) public {
        // skip the whole test if any value is zero
        if (amt0 == 0 || amt1 == 0  || amt3 == 0 || amt4 == 0) return;

        userA.deposit(amt0, amt1, 0);

        // user balances before deposit
        uint userBal0 = token0.balanceOf(address(userB));
        uint userBal1 = token1.balanceOf(address(userB));

        // perform deposit and immediate withdrawal
        uint liquidity = userB.deposit(amt3, amt4, 0);
        userB.withdraw(liquidity, 0, 0);

        // funds withdrawn are not always equal to funds deposited,
        // but always smaller than or equal to the initial deposit.
        assertTrue(token0.balanceOf(address(userB)) <= userBal0);
        assertTrue(token1.balanceOf(address(userB)) <= userBal1);


        // TODO: if rounding fix in `deposit` has been applied, the error is never larger than 1 wei
        assertTrue(userBal0 - 1 <= token0.balanceOf(address(userB)));
        assertTrue(userBal0 - 1 <= token1.balanceOf(address(userB)));
    }

    /*
        testWidthdraw2: staged withdrawals can accumulate
        some negligable rounding error in favour of the pool.
    */
    function testWithdraw2(uint64 amt0, uint64 amt1) public {
        // skip the whole test if any value is zero
        if (amt0 == 0 || amt1 == 0) return;

        userA.deposit(amt0, amt1, 0); // initializing deposit

        // user balances before deposit
        uint userBal0 = token0.balanceOf(address(userB));
        uint userBal1 = token1.balanceOf(address(userB));

        // deposit and withdraw in stages
        uint liquidity = userB.deposit(amt0, amt1, 0);
        if (liquidity < 200000) return;
        userB.withdraw(liquidity-200000, 0, 0);
        userB.withdraw(50000, 0, 0);
        userB.withdraw(50000, 0, 0);
        userB.withdraw(50000, 0, 0);
        userB.withdraw(50000, 0, 0);

        // rounding errors equate to ~1wei for each withdrawal
        // in favour of the pool
        assertTrue(token0.balanceOf(address(userB)) < userBal0);
        assertTrue(token1.balanceOf(address(userB)) < userBal1);
        assertTrue(userBal0 - token0.balanceOf(address(userB)) <= 4);
        assertTrue(userBal1 - token1.balanceOf(address(userB)) <= 4);
    }

    // ================================================================
    //                             Swap
    // ================================================================

    function price(uint x, uint y) internal pure returns(uint) {
        return (x > y) ? x / y : y / x;
    }


      // The equity of user in the pool expressed in token0.
      // price is a wad
      function equity_at_price(address user, uint priceOfToken1) internal returns (uint256) {
        if (pair.totalSupply() == 0) return 0;
        uint lpshares = pair.balanceOf(user);
        uint token0_amount = mul(lpshares, token0.balanceOf(address(pair))) / pair.totalSupply();
        uint token1_amount = mul(lpshares, token1.balanceOf(address(pair))) / pair.totalSupply();
        emit Print("token0_value: ", token0_amount);
        emit Print("token1_value: ", wmul(token1_amount, priceOfToken1));
        return token0_amount + wmul(token1_amount, priceOfToken1);
      }


    /*
      Fuzz target
     */
    function testSwapReferal(
        uint64 fst0, uint64 fst1, uint64 snd0, uint64 snd1, uint64 swapAmount
    ) public {
      swapRefer(fst0, fst1, snd0, snd1, swapAmount, address(userC));
    }

    /*
      Demonstrates an example where the referal address
      can yield more profit than LPs.

      The numbers are quite extreme
      (swapAmount exceeds the pairs balances multiplied).
      We found this case worth further analysis but did not
      get a chance to investigate the consequences of it further
      during the scope of our engagement.
     */

    function testReferalGainsOddity() public {
      factory.setFee(factory.MAX_FEE());
      //      factory.setFee(factory.max
      uint A_0bal_pre = token0.balanceOf(address(userA));
      uint A_1bal_pre = token1.balanceOf(address(userA));
      uint B_0bal_pre = token0.balanceOf(address(userB));
      uint B_1bal_pre = token1.balanceOf(address(userB));
      uint C_0bal_pre = token0.balanceOf(address(userC));
      uint C_1bal_pre = token1.balanceOf(address(userC));
      
      userA.deposit(1000, 1000,0);

      userB.swapReferall(token0, token1, 1e9, address(userC));

      uint token0_bal = token0.balanceOf(address(pair));
      uint token1_bal = token1.balanceOf(address(pair));
      emit Print("balances (token0):", token0_bal);
      emit Print("balances (token1):", token1_bal);
      // withdraw everything
      userC.withdraw(pair.balanceOf(address(userC)),0,0);
      userA.withdraw(pair.balanceOf(address(userA)),0,0);
      
      {
      int A_0diff = int(token0.balanceOf(address(userA)) - A_0bal_pre);
      int C_0diff = int(token0.balanceOf(address(userC)) - C_0bal_pre);
      int A_1diff = int(token1.balanceOf(address(userA)) - A_1bal_pre);
      int C_1diff = int(token1.balanceOf(address(userC)) - C_1bal_pre);
      int B_0diff = int(token0.balanceOf(address(userB)) - B_0bal_pre);
      int B_1diff = int(token1.balanceOf(address(userB)) - B_1bal_pre);
      emit Printi("user A gain (token0):",   A_0diff);
      emit Printi("user A gain (token1):",   A_1diff);
      emit Printi("user C gain (token0):",   C_0diff);
      emit Printi("user C gain (token1):",   C_1diff);
      emit Printi("user B gain (token0):",   B_0diff);
      emit Printi("user B gain (token1):",   B_1diff);
      emit Printi("user B+C gain (token0):", C_0diff + B_0diff);
      emit Printi("user B+C gain (token1):", C_1diff + B_1diff);
      assertTrue(A_0diff + A_1diff > C_0diff + C_1diff);
      }
    }

    
    /*
      Helper function which performs two deposits and a swap with `user` as the referal address.
      Terminates early when no reward given to the referal address.
    */
    function swapRefer(
        uint64 fst0, uint64 fst1, uint64 snd0, uint64 snd1, uint64 swapAmount, address user
    ) public {
      // make userA the only LP
      depositInitial(fst0, fst1);
      depositSubsequent(snd0, snd1);

      // quit test if no deposit succeeded
      if (pair.totalSupply() == 0) return;

      // assume pool is balanced now. So price of token1 is the ratio:
      uint price_of_token1 = token0.balanceOf(address(pair)) * WAD / token1.balanceOf(address(pair));

      // calculate A's pool equity, expresed in token0.
      uint preequity = equity_at_price(address(userA), price_of_token1);

      uint swapReturn0;
      uint token1Price_pre;
      uint token1Price_post;
      uint midequity;
      {
      (, uint vbAdd1_pre, uint vbRem0_pre,) = getVirtualBalances();

      // get quote for token1 -> token0 swap
      token1Price_pre = pair.getReturn(IERC20(address(token1)), IERC20(address(token0)), 1000);

      // get quote for a random token0 -> token1 swap
      uint token0swapPrice = pair.getReturn(IERC20(address(token0)), IERC20(address(token1)), swapAmount);

      // ensure that the swap will at least give 1 wei of token1
      if (token0swapPrice == 0) return;
      // and that the swapamount is not absurdly high
      if (swapAmount >= token0.balanceOf(address(pair))) return;
      // sell a random amount of token0, with userC as referal address
      swapReturn0 = userB.swapReferall(token0, token1, swapAmount, user);

      (, uint vbAdd1_post, uint vbRem0_post,) = getVirtualBalances();

      // virtual balances for trades in the opposite direction remains the same
      assertEq(vbAdd1_pre, vbAdd1_post);
      assertEq(vbRem0_pre, vbRem0_post);

      // therefore, the sell price for token1 remains the same:
      // get quote for token1 -> token0 swap
      token1Price_post = pair.getReturn(IERC20(address(token1)), IERC20(address(token0)), 1000);
      assertEq(token1Price_pre, token1Price_post);

      midequity = equity_at_price(address(userA), price_of_token1);
      
      // LP equity has increased due to slippage
      assertTrue(preequity <= midequity);
      emit Print("A equity before trade: ", preequity);
      emit Print("A equity after trade : ", midequity);
    }
      // after 5 minutes without trades, the sell price of token1 should be higher
      hevm.warp(block.timestamp + 5 minutes);
      uint coolreturn = pair.getReturn(IERC20(address(token1)), IERC20(address(token0)), 1000);

      emit Print("token1Price_post: ", token1Price_post);
      emit Print("coolreturn :      ", coolreturn);

      assertTrue(token1Price_post <= coolreturn);

      // whatever the equity of the pool has increased by,
      // user will have gained approx 5% of it
      uint referal_profit = equity_at_price(user, price_of_token1);
      emit Print("referal address equity:  ", referal_profit);
      emit Print("A equity gain:           ", midequity - preequity);
      emit Print("A lp tokens:           ", pair.balanceOf(address(userA)));
      emit Print("referal address tokens:", pair.balanceOf(user));

      // the referal address always yields less than lps profit
      assertTrue(referal_profit <= (midequity - preequity));
    }

    function testSwap0(uint64 rand0, uint64 rand1) public {
        if (rand0 < 300 || rand1 < 300) return;
        uint initPrice = 300;
        uint qty0 = rand0 / 10;
        uint qty1 = rand1 / 10;

        // initial deposit
        userA.deposit(rand0, rand0 * initPrice, 0);

        // swap: sell price < 300
        uint return0 = userB.swap(token0, token1, qty0);
        assertTrue(price(return0, qty0) < initPrice);

        // swap: buy price == 300
        uint return1 = userC.swap(token1, token0, qty0);
        assertEq(price(return1, qty0), initPrice);

        // deposit
        uint liqA = userA.deposit(rand1, rand1 * initPrice, 0);

        // swap: buy price == 300
        uint return2 = userC.swap(token1, token0, qty1);
        assertEq(price(return2, qty1), initPrice);

        // withdraw
        userA.withdraw(liqA, 0, 0);

        hevm.warp(604411920); // + 10mins

        // swap: buy price < 300
        uint return3 = userC.swap(token1, token0, qty1);
        assertTrue(price(return3, qty1) < initPrice);

        // real balances up to 10% greater than virtual balances?
        (uint vb0,) = pair.virtualBalancesForRemoval(IERC20(address(token0)));
        (uint vb1,) = pair.virtualBalancesForRemoval(IERC20(address(token1)));

        assertTrue(token0.balanceOf(address(pair)) > vb0);
        assertTrue(token1.balanceOf(address(pair)) > vb1);
        assertAlmostEq(token0.balanceOf(address(pair)), vb0, 10 ether);
        assertAlmostEq(token1.balanceOf(address(pair)), vb1, 10 ether);
    }

    /*
       Deposits and then swaps

       After each swap checks that:
       - K is preserved for the src -> dst curve
       - K is preserved for the real balances
       - The real balances have been updated in accordance with the buy and sell amounts
       - The returned output amount matches the change in real token balances
       - the fee is taken
    */

    // avoid stack to deep...
    uint vbAddSrcPre; uint vbAddDstPre; uint vbRemSrcPre; uint vbRemDstPre;
    uint vbAddSrcEnd; uint vbAddDstEnd; uint vbRemSrcEnd; uint vbRemDstEnd;
    uint pairBalSrcPre; uint pairBalDstPre;
    uint pairBalSrcEnd; uint pairBalDstEnd;

    function testSwapVirtual(uint seed) public {
        randomSeed = seed;

        // add liquidity and ensure timestamps have all been set
        userA.deposit(uint88(newRand()), uint88(newRand()), 0);
        userA.deposit(uint88(newRand()), uint88(newRand()), 0);

        // enable the fee
        factory.setFee(factory.MAX_FEE());

        // bring the pair into an unbalanced state
        userB.swap(token1, token0, uint88(newRand()));
        userB.swap(token0, token1, uint88(newRand()));

        // --- randomly choose the direction (true = 0->1; false = 1->0) ---

        bool direction = toBool(newRand());

        (DSToken src, DSToken dst) = getTokens(direction);
        (vbAddSrcPre, vbAddDstPre, vbRemSrcPre, vbRemDstPre) = getVirtualBalances(direction);
        pairBalSrcPre = src.balanceOf(address(pair));
        pairBalDstPre = dst.balanceOf(address(pair));

        // --- swap some tokens ---

        uint swapAmt = max(25, uint64(newRand()));
        uint ret = userB.swap(src, dst, swapAmt);

        (vbAddSrcEnd, vbAddDstEnd, vbRemSrcEnd, vbRemDstEnd) = getVirtualBalances(direction);
        pairBalSrcEnd = src.balanceOf(address(pair));
        pairBalDstEnd = dst.balanceOf(address(pair));

        // output amount is correct && src -> dst virtual curve has moved accordingly
        uint taxed = sub(swapAmt, mul(swapAmt, pair.fee()) / pair.FEE_DENOMINATOR());
        assertEq(ret, mul(taxed, vbRemDstPre) / add(vbAddSrcPre, taxed));
        assertEq(vbRemDstEnd, sub(vbRemDstPre, ret));
        assertEq(vbAddSrcEnd, add(vbAddSrcPre, swapAmt));

        // k does not decrease for the src -> dst virtual curve
        assertTrue(mul(vbRemDstPre, vbAddSrcPre) <= mul(vbRemDstEnd, vbAddSrcEnd));

        // k does not decrease for the real balances
        assertTrue(mul(pairBalSrcPre, pairBalDstPre) <= mul(pairBalSrcEnd, pairBalDstEnd));

        // k can decrease for dst -> src but not by much
        // TODO: Is this bad?
        assertAlmostEq(
            mul(vbRemSrcPre, vbAddDstPre),
            mul(vbRemSrcEnd, vbAddDstEnd),
            0.00005 ether
        );

        // real balances have shifted by the same amount as the src -> dst virtualBalances
        assertEq(sub(vbAddSrcEnd, vbAddSrcPre), sub(pairBalSrcEnd, pairBalSrcPre));
        assertEq(sub(vbRemDstPre, vbRemDstEnd), sub(pairBalDstPre, pairBalDstEnd));
    }

    // ================================================================
    //                              ETH
    // ================================================================

    /*
       Performs some basic safety checks for deposit / swap / withdraw with ETH

       - user does not send more the amounts array in deposit
       - swap always increases K over the real balances
       - user receives an amount of tokens in proportion to their allocation of LP shares when withdrawing
    */
    function testETH(uint seed) public {
        randomSeed = seed;

        // --- create ETH <-> token pair ---

        DSToken token = new DSToken("TST");
        pair = Mooniswap(factory.deploy(IERC20(address(0)), IERC20(address(token))));
        assertEq(address(token), address(pair.tokens(1))); // double check token ordering...

        userA = new User(pair);
        userB = new User(pair);

        token.mint(address(userA), type(uint).max / 2);
        token.mint(address(userB), type(uint).max / 3);

        userA.approve(address(token), address(pair));
        userB.approve(address(token), address(pair));

        address(userA).transfer(1000000000 ether);
        address(userB).transfer(1000000000 ether);

        // --- deposit ETH & tokens from a few users ---

        uint amt0 = uint64(newRand());
        uint amt1 = uint64(newRand());
        uint sharesA = userA.deposit(amt0, amt1, 0);

        factory.setFee(factory.MAX_FEE());

        assertTrue(address(pair).balance <= amt0);
        assertTrue(token.balanceOf(address(pair)) <= amt1);
        assertEq(pair.balanceOf(address(userA)), sharesA);

        amt0 = uint64(newRand());
        amt1 = uint64(newRand());

        uint pairBalEth = address(pair).balance;
        uint pairBalTok = token.balanceOf(address(pair));

        uint sharesB = userB.deposit(amt0, amt1, 0);

        assertTrue(address(pair).balance - pairBalEth <= amt0);
        assertTrue(token.balanceOf(address(pair)) - pairBalTok <= amt1);
        assertEq(pair.balanceOf(address(userB)), sharesB);

        // TODO: assert that the depositer receives a good amount of LP shares

        // --- do 32 swaps (also jump in time) ---

        for (uint i = 0; i < 32; i++) {
            bool direction = toBool(newRand());
            address src = direction ? address(0) : address(token);
            address dst = direction ? address(token) : address(0);

            pairBalEth = address(pair).balance;
            pairBalTok = token.balanceOf(address(pair));

            uint amt = uint56(newRand());
            userA.swap(DSToken(src), DSToken(dst), amt);

            // K over the real balances always increases after a swap
            uint k_old = mul(pairBalTok, pairBalEth);
            uint k_new = mul(address(pair).balance, token.balanceOf(address(pair)));
            assertTrue(k_old < k_new);
        }

        // --- withdraw all funds ---

        pairBalEth = address(pair).balance;
        pairBalTok = token.balanceOf(address(pair));

        uint preBalEth = address(userA).balance;
        uint preBalTok = token.balanceOf(address(userA));

        uint totalSupply = pair.totalSupply();

        assertEq(pair.balanceOf(address(userA)), sharesA);
        userA.withdraw(sharesA, 0, 0);

        uint deltaEth = address(userA).balance - preBalEth;
        uint deltaTok = token.balanceOf(address(userA)) - preBalTok;

        // assert amount received is in proportion to real balances & lp shares
        assertEq(deltaEth, mul(pairBalEth, sharesA) / totalSupply);
        assertEq(deltaTok, mul(pairBalTok, sharesA) / totalSupply);
    }

    // ================================================================
    //                            Helpers
    // ================================================================

    // sha256 based stateful prng
    uint randomSeed;
    function newRand() internal returns (uint) {
        uint oldSeed = randomSeed;
        randomSeed = uint(sha256(abi.encode(oldSeed)));
        return randomSeed;
    }

    // `x` and `y` are within `errorMargin` percent of each other
    // `x` and `y` should be integers
    // `errorMargin` should be a WAD
    function assertAlmostEq(uint x, uint y, uint errorMargin) internal {
        if (x >= y) {
            if (mul(wdiv(x, y) - WAD, 100) >= errorMargin) {
                emit log_named_uint("    Expected", y);
                emit log_named_uint("      Actual", x);
                emit log_named_uint("Error Margin", errorMargin);
                fail();
            }
        }
        else {
            if (mul(wdiv(y, x) - WAD, 100) >= errorMargin) {
                emit log_named_uint("    Expected", y);
                emit log_named_uint("      Actual", x);
                emit log_named_uint("Error Margin", errorMargin);
                fail();
            }
        }
    }

    // right shifts a uint256 255 places to get a single bit and
    // converts it to a bool
    function toBool(uint256 x) internal pure returns (bool) {
        return (x >> 255) == 1 ? true : false;
    }

    // direction == true -> src = token0 && dst = token1
    function getTokens(bool direction)
        internal view
        returns (DSToken src, DSToken dst)
    {
        src = direction ? token0 : token1;
        dst = direction ? token1 : token0;
    }

    // direction == true -> src = token0 && dst = token1
    function getVirtualBalances(bool direction)
        internal view
        returns (uint vbAddSrc, uint vbAddDst, uint vbRemSrc, uint vbRemDst)
    {
        (uint vbAdd0, uint vbAdd1, uint vbRem0, uint vbRem1) = getVirtualBalances();
        if (direction) {
            vbAddSrc = vbAdd0; vbAddDst = vbAdd1; vbRemSrc = vbRem0; vbRemDst = vbRem1;
        } else {
            vbAddSrc = vbAdd1; vbAddDst = vbAdd0; vbRemSrc = vbRem1; vbRemDst = vbRem0;
        }
    }

    // direction == true -> src = token0 && dst = token1
    function getVirtualTimestamps(bool direction)
        internal view
        returns (uint t_vbAddSrc, uint t_vbAddDst, uint t_vbRemSrc, uint t_vbRemDst)
    {
        (uint t_vbAdd0, uint t_vbAdd1, uint t_vbRem0, uint t_vbRem1) = getVirtualTimestamps();
        if (direction) {
            t_vbAddSrc = t_vbAdd0; t_vbAddDst = t_vbAdd1; t_vbRemSrc = t_vbRem0; t_vbRemDst = t_vbRem1;
        } else {
            t_vbAddSrc = t_vbAdd1; t_vbAddDst = t_vbAdd0; t_vbRemSrc = t_vbRem1; t_vbRemDst = t_vbRem0;
        }
    }

    function getVirtualBalances()
        internal view
        returns (uint vbAdd0, uint vbAdd1, uint vbRem0, uint vbRem1)
    {
        vbAdd0 = pair.getBalanceForAddition(IERC20(address(token0)));
        vbAdd1 = pair.getBalanceForAddition(IERC20(address(token1)));
        vbRem0 = pair.getBalanceForRemoval(IERC20(address(token0)));
        vbRem1 = pair.getBalanceForRemoval(IERC20(address(token1)));
    }

    function getVirtualTimestamps()
        internal view
        returns (uint t_vbAdd0, uint t_vbAdd1, uint t_vbRem0, uint t_vbRem1)
    {
        (, t_vbAdd0) = pair.virtualBalancesForAddition(IERC20(address(token0)));
        (, t_vbAdd1) = pair.virtualBalancesForAddition(IERC20(address(token1)));
        (, t_vbRem0) = pair.virtualBalancesForRemoval(IERC20(address(token0)));
        (, t_vbRem1) = pair.virtualBalancesForRemoval(IERC20(address(token1)));
    }
}
