// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CoinFactory} from "src/CoinFactory.sol";

/// Answers every call with 32 zero bytes: stands in for the position manager, permit2, the fee hook and JIG so that
/// CoinFactory.launch() runs its real coin creation and its real _excluded() list.
contract Yes {
    fallback() external payable { assembly { mstore(0, 0) return(0, 32) } }
}

contract SCollection {
    address public creator;
    uint256 public maxSupply = 100;
    constructor(address c) { creator = c; }
}

/// Round 8 High 1 fix: _excluded() calls IAirdropPot(airdropRecipient).pot() on every launch and in every
/// coinInitCodeHash()/predictCoin(). The constructor only probes pot() when the recipient has code, so an EOA
/// recipient (a plain wallet, which launch() line 168 explicitly supports) is accepted and then every launch and
/// every prediction reverts: the factory is dead on arrival and the hook, bound once by setFactory, with it.
contract EoaAirdropRecipientTest is Test {
    address creator = makeAddr("creator");

    function test_eoa_airdrop_recipient_is_refused_or_launches_work() public {
        Yes posm = new Yes(); Yes permit2 = new Yes(); Yes hook = new Yes(); Yes jig = new Yes();
        address wallet = makeAddr("airdropWallet"); // an EOA airdrop recipient
        CoinFactory f;
        try new CoinFactory(address(posm), address(permit2), address(hook), address(jig), makeAddr("platform"), wallet, 0) returns (CoinFactory f_) {
            f = f_;
        } catch {
            return; // the constructor refused the EOA recipient: consistent, nothing more to check
        }
        // the constructor accepted it, so the factory must be usable with it
        SCollection col = new SCollection(creator);
        bytes32 salt = bytes32(bytes20(address(col)));
        (bool ok,) = address(f).staticcall(abi.encodeCall(f.predictCoin, (address(col), "Coin", "C", salt)));
        assertTrue(ok, "predictCoin() reverts for an EOA airdrop recipient: _excluded() calls pot() on an account without code");
        address predicted = f.predictCoin(address(col), "Coin", "C", salt);
        bool coinIs0 = predicted < address(jig);
        CoinFactory.LaunchParams memory p = CoinFactory.LaunchParams({
            collection: address(col), name: "Coin", symbol: "C", feePips: 10_000, flywheel: address(0), creatorShareBps: type(uint16).max,
            creatorBps: 0, devBuyJig: 0, devBuyMinCoin: 0, maxFeeWei: 0, salt: salt,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0), tickLower: coinIs0 ? int24(0) : int24(-200), tickUpper: coinIs0 ? int24(200) : int24(0)
        });
        vm.prank(creator);
        (, address coinAddr) = f.launch(p);
        assertEq(coinAddr, predicted);
    }
}
