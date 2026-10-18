// START_TICK for DeployJIG from today's ETH price (go day). JIG/ETH pool, token0 = ETH, price = JIG per ETH = 1.0001^tick;
// 1B JIG, so FDV in USD = 1e9 x ETH_USD / 1.0001^tick. The tick is a multiple of 200 (the pool's spacing); a higher tick
// is a lower FDV. Default target $3,900 FDV (Jj accepted the low start, 17 Oct).
//   node scripts/jig-start-tick.mjs [targetFdvUsd] [ethUsd]
import { ethPrice } from '../lib/builds.mjs';
const target = Number(process.argv[2] ?? 3900);
const eth = Number(process.argv[3] ?? (await ethPrice()));
const raw = Math.log((1e9 * eth) / target) / Math.log(1.0001);
const tick = Math.round(raw / 200) * 200;
const fdv = (1e9 * eth) / 1.0001 ** tick;
console.log(JSON.stringify({ ethUsd: eth, targetFdvUsd: target, START_TICK: tick, fdvAtTickUsd: Math.round(fdv), jigUsd: fdv / 1e9 }));
