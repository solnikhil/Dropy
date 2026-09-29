# Dropy coordinated benchmark: closed, idle and active

- Date: 2026-09-29 18:23 IST; Dropy 069ccec (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; displays: 2560 x 1664 Retina
- Sources: Electron fixture 43.2.0 windows, 520×380 pt, static.html and animation.html side by side; overlay medium, fit
- 30s per phase, sampled once per second after 3 s; desktop session: owner=benchmark-phases; input idle 2134.7s at start
- Heaviest processes before: BackgroundShortcutRunner 67%; WindowServer 38%; WARP 19%; Helper 11%; (Renderer) 7%; Electron 7%; bun 6%; tccd 5%; 
- Heaviest processes after: WindowServer 42%; WARP 19%; Helper 18%; bun 16%; (Renderer) 10%; Terminal 8%; trustd 7%; dataaccessd 6%; 

| Phase | Dropy CPU mean / p95 | Dropy footprint | Dropy wakeups (idle / interrupt) | WindowServer CPU | GPU util mean / p95 | Capture rate | Presented / not | Frame age p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| none | — | — | — | 45.4% | 22.7% / 24.0% | — | — | — |
| closed | 0.0% / 0.0% | 12.5MB | 0.0/s / 0.2/s | 45.0% | 23.4% / 25.0% | — | — | — |
| idle | 4.3% / 6.3% | 30.6MB | 0.0/s / 2.1/s | 44.6% | 24.5% / 28.0% | 27.1/s (936 unchanged) | 42 / 48 | frameAge=[n=42 p50=43.3 p95=100.9 p99=103.7 max=103.7] |
| active | 10.8% / 11.5% | 30.9MB | 0.0/s / 1.5/s | 47.2% | 26.7% / 28.0% | 57.4/s (58 unchanged) | 2014 / 1 | frameAge=[n=2014 p50=41.4 p95=50.3 p99=51.3 max=52.8] |

## Raw samples

### none

```
windowserver: cpuMean=45.4% cpuP95=48.0% memMax=42.9MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=22.7% utilP95=24.0% samples=30

```

### closed

```
dropy: cpuMean=0.0% cpuP95=0.0% memMax=12.5MB idleWakeups=0.0/s interruptWakeups=0.2/s samples=30
windowserver: cpuMean=45.0% cpuP95=47.1% memMax=40.4MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=23.4% utilP95=25.0% samples=30
no capture metrics
```

### idle

```
dropy: cpuMean=4.3% cpuP95=6.3% memMax=30.6MB idleWakeups=0.0/s interruptWakeups=2.1/s samples=30
windowserver: cpuMean=44.6% cpuP95=46.2% memMax=47.0MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=24.5% utilP95=28.0% samples=30
Dropy reveal: firstFrame=305.9ms open=1 warm=no
Dropy capture metrics: window=1952 duration=36.2s start=124.9ms firstFrame=127.4ms output=1040x760/BGRA status=[complete=978] completeRate=27.1/s unchanged=936 rateChanges=21idle/20full mailboxDrops=0 presented=42 notPresented=48 captureToCallback=[n=978 p50=0.8 p95=1.3 p99=2.0 max=11.2] callbackToPresent=[n=42 p50=37.6 p95=99.8 p99=102.6 max=102.6] frameAge=[n=42 p50=43.3 p95=100.9 p99=103.7 max=103.7] clockOffset=0.000ms stop=closed
```

### active

```
dropy: cpuMean=10.8% cpuP95=11.5% memMax=30.9MB idleWakeups=0.0/s interruptWakeups=1.5/s samples=30
windowserver: cpuMean=47.2% cpuP95=49.3% memMax=47.5MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=26.7% utilP95=28.0% samples=30
Dropy reveal: firstFrame=218.4ms open=1 warm=no
Dropy capture metrics: window=1957 duration=36.1s start=88.1ms firstFrame=79.8ms output=1040x760/BGRA status=[complete=2074] completeRate=57.4/s unchanged=58 rateChanges=0idle/0full mailboxDrops=0 presented=2014 notPresented=1 captureToCallback=[n=2074 p50=0.8 p95=1.2 p99=1.6 max=3.1] callbackToPresent=[n=2014 p50=40.6 p95=49.5 p99=50.3 max=52.0] frameAge=[n=2014 p50=41.4 p95=50.3 p99=51.3 max=52.8] clockOffset=0.000ms stop=closed
```
