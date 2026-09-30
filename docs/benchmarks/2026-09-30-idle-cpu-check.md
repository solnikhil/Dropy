# Dropy coordinated benchmark: closed, idle and active

- Date: 2026-09-30 02:17 IST; Dropy 91a62ea (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; displays: 2560 x 1664 Retina
- Sources: Electron fixture 43.2.0 windows, 520×380 pt, static.html and animation.html side by side; overlay medium, fit
- 30s per phase, sampled once per second after 3 s; desktop session: owner=benchmark-phases; input idle 20.0s at start; power ac
- Heaviest processes before: WindowServer 44%; WARP 18%; Helper 12%; (Renderer) 8%; Electron 8%; sysmond 6%; (Renderer) 5%; syspolicyd 5%; 
- Heaviest processes after: WindowServer 51%; WARP 22%; Helper 19%; (Renderer) 13%; dasd 5%; (Renderer) 4%; Flow 3%; notifyd 2%; 

| Phase | Dropy CPU mean / p95 | Dropy footprint | Dropy wakeups (idle / interrupt) | WindowServer CPU | GPU util mean / p95 | Capture rate | Presented / not | Frame age p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| none | — | — | — | 45.4% | 13.0% / 15.0% | — | — | — |
| closed | 0.0% / 0.0% | 12.4MB | 0.0/s / 0.2/s | 48.0% | 12.4% / 15.0% | — | — | — |
| idle | 2.3% / 2.9% | 27.0MB | 0.0/s / 0.7/s | 48.5% | 12.3% / 15.0% | 10.8/s (389 unchanged) | 3 / 0 | frameAge=[n=3 p50=49.9 p95=100.2 p99=100.2 max=100.2] |
| active | 11.3% / 12.1% | 30.4MB | 0.1/s / 1.4/s | 47.6% | 19.6% / 21.0% | 57.8/s (14 unchanged) | 2069 / 0 | frameAge=[n=2069 p50=25.1 p95=33.8 p99=34.6 max=36.4] |

## Raw samples

### none

```
windowserver: cpuMean=45.4% cpuP95=52.1% memMax=45.0MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=13.0% utilP95=15.0% samples=30

```

### closed

```
dropy: cpuMean=0.0% cpuP95=0.0% memMax=12.4MB idleWakeups=0.0/s interruptWakeups=0.2/s samples=30
windowserver: cpuMean=48.0% cpuP95=52.1% memMax=44.5MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=12.4% utilP95=15.0% samples=30
no capture metrics
```

### idle

```
dropy: cpuMean=2.3% cpuP95=2.9% memMax=27.0MB idleWakeups=0.0/s interruptWakeups=0.7/s samples=30
windowserver: cpuMean=48.5% cpuP95=51.3% memMax=49.6MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=12.3% utilP95=15.0% samples=30
Dropy reveal: firstFrame=359.9ms open=1 warm=no
Dropy capture metrics: window=5060 duration=36.3s start=189.3ms firstFrame=183.6ms output=1040x760/BGRA status=[complete=392] completeRate=10.8/s unchanged=389 rateChanges=1idle/0full mailboxDrops=0 presented=3 notPresented=0 drawableMisses=3 captureToCallback=[n=392 p50=1.3 p95=1.8 p99=3.0 max=10.6] callbackToPresent=[n=3 p50=39.3 p95=99.0 p99=99.0 max=99.0] frameAge=[n=3 p50=49.9 p95=100.2 p99=100.2 max=100.2] clockOffset=0.000ms stop=closed
```

### active

```
dropy: cpuMean=11.3% cpuP95=12.1% memMax=30.4MB idleWakeups=0.1/s interruptWakeups=1.4/s samples=30
windowserver: cpuMean=47.6% cpuP95=49.4% memMax=46.9MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=19.6% utilP95=21.0% samples=30
Dropy reveal: firstFrame=256.2ms open=1 warm=no
Dropy capture metrics: window=5065 duration=36.1s start=136.6ms firstFrame=128.1ms output=1040x760/BGRA status=[complete=2085] completeRate=57.8/s unchanged=14 rateChanges=0idle/0full mailboxDrops=1 presented=2069 notPresented=0 drawableMisses=0 captureToCallback=[n=2085 p50=0.9 p95=1.2 p99=1.5 max=2.2] callbackToPresent=[n=2069 p50=24.2 p95=32.8 p99=33.7 max=35.0] frameAge=[n=2069 p50=25.1 p95=33.8 p99=34.6 max=36.4] clockOffset=0.000ms stop=closed
```
