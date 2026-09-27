# Dropy capture benchmark

The Dropy CPU percentages below are invalid: this run's sampler incorrectly rescaled `proc_pid_rusage` nanoseconds by the Mac's 125/3 mach timebase. Other measurements remain as recorded. Rerun before using Dropy CPU as a baseline.

- Date: 2026-09-26 01:08 IST
- Dropy: 18ad4dd
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0
- Phase length: 20s each, sampled once per second after a 3s warm-up

## static (TextEdit)

```
without Dropy
windowserver: cpuMean=43.4% cpuP95=45.8% memMax=39.8MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=11.4% utilP95=14.0% samples=20

with Dropy
dropy: cpuMean=9.7% cpuP95=10.8% memMax=33.3MB idleWakeups=0.0/s interruptWakeups=9.6/s samples=20
windowserver: cpuMean=45.4% cpuP95=46.7% memMax=51.1MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=44.1% utilP95=46.0% samples=20
Dropy reveal: firstFrame=467.5ms open=1 warm=no
Dropy capture metrics: window=3636 duration=25.5s start=256.6ms firstFrame=227.0ms output=1176x705/BGRA status=[complete=1466] completeRate=57.6/s mailboxDrops=38 presented=1426 notPresented=1 captureToCallback=[n=1466 p50=0.7 p95=1.3 p99=2.6 max=11.1] callbackToPresent=[n=1426 p50=26.3 p95=35.1 p99=40.1 max=51.4] frameAge=[n=1426 p50=26.9 p95=36.0 p99=41.0 max=52.0] clockOffset=0.000ms stop=closed
```

## scroll (Safari)

```
without Dropy
windowserver: cpuMean=44.1% cpuP95=45.7% memMax=38.5MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=17.9% utilP95=19.0% samples=20

with Dropy
dropy: cpuMean=10.0% cpuP95=11.0% memMax=33.5MB idleWakeups=0.0/s interruptWakeups=9.8/s samples=20
windowserver: cpuMean=43.9% cpuP95=46.6% memMax=49.8MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=47.1% utilP95=49.0% samples=20
Dropy reveal: firstFrame=504.7ms open=1 warm=no
Dropy capture metrics: window=3652 duration=24.9s start=290.7ms firstFrame=263.9ms output=1176x705/BGRA status=[complete=1440] completeRate=57.7/s mailboxDrops=4 presented=1432 notPresented=2 captureToCallback=[n=1440 p50=0.7 p95=1.3 p99=2.8 max=16.2] callbackToPresent=[n=1432 p50=27.8 p95=34.7 p99=36.7 max=40.9] frameAge=[n=1432 p50=28.4 p95=35.4 p99=37.3 max=41.5] clockOffset=-0.000ms stop=closed
```

## animation (Safari)

```
without Dropy
windowserver: cpuMean=44.9% cpuP95=45.8% memMax=37.9MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=33.1% utilP95=35.0% samples=20

with Dropy
dropy: cpuMean=9.1% cpuP95=10.8% memMax=37.4MB idleWakeups=0.0/s interruptWakeups=23.6/s samples=20
windowserver: cpuMean=44.9% cpuP95=48.9% memMax=58.9MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=54.9% utilP95=64.0% samples=20
Dropy reveal: firstFrame=775.4ms open=1 warm=no
Dropy capture metrics: window=3668 duration=24.5s start=439.6ms firstFrame=415.3ms output=1176x705/BGRA status=[complete=1370] completeRate=56.0/s mailboxDrops=8 presented=664 notPresented=697 captureToCallback=[n=1370 p50=0.7 p95=2.7 p99=7.5 max=24.2] callbackToPresent=[n=664 p50=47.2 p95=58.6 p99=65.0 max=65.7] frameAge=[n=664 p50=48.0 p95=59.1 p99=65.5 max=66.1] clockOffset=0.000ms stop=closed
```
