# Dropy coordinated benchmark: closed, idle and active

- Date: 2026-09-29 18:19 IST; Dropy 069ccec (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; displays: 2560 x 1664 Retina
- Sources: Electron fixture 43.2.0 windows, 520×380 pt, static.html and animation.html side by side; overlay medium, fit
- 30s per phase, sampled once per second after 3 s; desktop session: owner=benchmark-phases; input idle 1892.1s at start
- Heaviest processes before: BackgroundShortcutRunner 63%; WindowServer 40%; bun 23%; WARP 18%; Helper 12%; Electron 8%; (Renderer) 8%; tccd 6%; 
- Heaviest processes after: WindowServer 47%; WARP 17%; Helper 17%; (Renderer) 9%; bun 8%; Terminal 6%; (Renderer) 3%; Flow 2%; 

| Phase | Dropy CPU mean / p95 | Dropy footprint | Dropy wakeups (idle / interrupt) | WindowServer CPU | GPU util mean / p95 | Capture rate | Presented / not | Frame age p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| none | — | — | — | 44.9% | 22.8% / 25.0% | — | — | — |
| closed | 0.0% / 0.0% | 12.3MB | 0.0/s / 0.1/s | 45.2% | 23.8% / 25.0% |  ( unchanged) |  /  | — |
| idle | 4.1% / 6.2% | 30.8MB | 0.0/s / 1.8/s | 45.2% | 24.4% / 28.0% | 27.0/s (932 unchanged) | 42 / 40 | frameAge=[n=42 p50=34.0 p95=68.3 p99=70.5 max=70.5] |
| active | 11.0% / 12.0% | 30.9MB | 0.0/s / 1.2/s | 47.5% | 27.0% / 28.0% | 57.4/s (48 unchanged) | 2017 / 3 | frameAge=[n=2017 p50=25.1 p95=34.0 p99=36.6 max=49.7] |

## Raw samples

### none

```
windowserver: cpuMean=44.9% cpuP95=46.6% memMax=42.4MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=22.8% utilP95=25.0% samples=30

```

### closed

```
dropy: cpuMean=0.0% cpuP95=0.0% memMax=12.3MB idleWakeups=0.0/s interruptWakeups=0.1/s samples=30
windowserver: cpuMean=45.2% cpuP95=46.5% memMax=41.8MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=23.8% utilP95=25.0% samples=30
no capture metrics
```

### idle

```
dropy: cpuMean=4.1% cpuP95=6.2% memMax=30.8MB idleWakeups=0.0/s interruptWakeups=1.8/s samples=30
windowserver: cpuMean=45.2% cpuP95=47.5% memMax=48.4MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=24.4% utilP95=28.0% samples=30
Dropy reveal: firstFrame=375.6ms open=1 warm=no
Dropy capture metrics: window=1846 duration=36.0s start=165.5ms firstFrame=164.4ms output=1040x760/BGRA status=[complete=974] completeRate=27.0/s unchanged=932 rateChanges=21idle/20full mailboxDrops=0 presented=42 notPresented=40 captureToCallback=[n=974 p50=0.8 p95=1.4 p99=2.3 max=11.6] callbackToPresent=[n=42 p50=31.2 p95=67.2 p99=69.5 max=69.5] frameAge=[n=42 p50=34.0 p95=68.3 p99=70.5 max=70.5] clockOffset=0.000ms stop=closed
```

### active

```
dropy: cpuMean=11.0% cpuP95=12.0% memMax=30.9MB idleWakeups=0.0/s interruptWakeups=1.2/s samples=30
windowserver: cpuMean=47.5% cpuP95=48.9% memMax=47.7MB idleWakeups=-/s interruptWakeups=-/s samples=30
gpu: utilMean=27.0% utilP95=28.0% samples=30
Dropy reveal: firstFrame=220.6ms open=1 warm=no
Dropy capture metrics: window=1851 duration=36.0s start=90.0ms firstFrame=81.8ms output=1040x760/BGRA status=[complete=2069] completeRate=57.4/s unchanged=48 rateChanges=0idle/0full mailboxDrops=1 presented=2017 notPresented=3 captureToCallback=[n=2069 p50=0.8 p95=1.2 p99=1.7 max=8.3] callbackToPresent=[n=2017 p50=24.2 p95=33.2 p99=35.8 max=48.8] frameAge=[n=2017 p50=25.1 p95=34.0 p99=36.6 max=49.7] clockOffset=0.000ms stop=closed
```
