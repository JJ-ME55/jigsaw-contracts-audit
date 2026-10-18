// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreatorCoin} from "src/CreatorCoin.sol";
import {CoinFactory} from "src/CoinFactory.sol";
import {AirdropClaim} from "src/AirdropClaim.sol";
import {PotVault} from "src/PotVault.sol";

contract SJig is ERC20 {
    constructor() ERC20("J", "J") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

/// Answers every call with 32 zero bytes: stands in for the position manager, permit2 and the fee hook so that
/// CoinFactory.launch() runs its real coin creation, real _excluded() list and the real AirdropClaim.notify().
contract Yes {
    fallback() external payable { assembly { mstore(0, 0) return(0, 32) } }
}

contract SCollection {
    address public creator;
    uint256 public maxSupply = 10_000;
    uint256 public totalSupply = 1_000;
    constructor(address c) { creator = c; }
    function ownerOf(uint256 id) external view returns (address) { require(id != 0 && id <= totalSupply, "unminted"); return address(uint160(0xBEEF0000 + id)); }
}

/// The pot (PotVault) receives every swept airdrop remainder but is not in CoinFactory._excluded(): its coin balance
/// counts in the eligible supply and "earns" JIG that no code path can ever claim.
contract PotStrandedTest is Test {
    SJig jig; CoinFactory factory; CreatorCoin coin; AirdropClaim airdrop; PotVault pot; SCollection col;
    address platform = makeAddr("platform");
    address creator = makeAddr("creator");
    address notifier = makeAddr("forwarder");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        jig = new SJig();
        pot = new PotVault(makeAddr("potSafe"));
        airdrop = new AirdropClaim(address(this), address(pot));
        Yes posm = new Yes(); Yes permit2 = new Yes(); Yes hook = new Yes();
        factory = new CoinFactory(address(posm), address(permit2), address(hook), address(jig), platform, address(airdrop), 0);
        airdrop.setFactory(address(factory));
        airdrop.renounceOwnership();
        col = new SCollection(creator);

        bytes32 salt = bytes32(bytes20(address(col)));
        address predicted = factory.predictCoin(address(col), "Coin", "C", salt);
        bool coinIs0 = predicted < address(jig);
        CoinFactory.LaunchParams memory p = CoinFactory.LaunchParams({
            collection: address(col), name: "Coin", symbol: "C", feePips: 10_000, flywheel: notifier, creatorShareBps: type(uint16).max,
            creatorBps: 500, devBuyJig: 0, devBuyMinCoin: 0, maxFeeWei: 0, salt: salt,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0), tickLower: coinIs0 ? int24(0) : int24(-200), tickUpper: coinIs0 ? int24(200) : int24(0)
        });
        vm.prank(creator);
        (, address coinAddr) = factory.launch(p);
        coin = CreatorCoin(coinAddr);
        assertEq(coin.balanceOf(address(airdrop)), 50_000_000e18, "the 5% is parked");
        jig.mint(notifier, 1_000_000e18);
        vm.prank(notifier); jig.approve(address(coin), type(uint256).max);
    }

    function test_pot_balance_earns_rewards_nobody_can_claim() public {
        // 1,000 of 10,000 minted; the keeper pushes every minted id, the window closes, the rest is swept to the pot
        uint256[] memory ids = new uint256[](1_000);
        for (uint256 i; i < 1_000; i++) ids[i] = i + 1;
        airdrop.claimFor(address(coin), ids);
        vm.warp(block.timestamp + 31 days);
        uint256 swept = airdrop.sweep(address(coin));
        assertEq(coin.balanceOf(address(pot)), swept);
        assertEq(swept, 45_000_000e18, "90% of the airdrop went to the pot");

        vm.prank(creator); coin.transfer(alice, 5_000_000e18); // real holders: creator 45M + alice 5M + the 1,000 pushed owners 5M
        assertEq(coin.balanceOf(alice), 5_000_000e18);

        vm.prank(notifier); coin.notifyReward(1_000e18);
        vm.warp(block.timestamp + 1 days);

        // the pot is a protocol address with no way to call claim(): it must hold no share of holder rewards
        assertEq(coin.earned(address(pot)), 0, "pot earns holder rewards it can never claim");
        assertTrue(coin.excluded(address(pot)), "pot must be excluded from the eligible supply");
    }
}
