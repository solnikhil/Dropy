# Dropy capture benchmark

- Date: 2026-09-26 01:11 IST
- Dropy: 18ad4dd
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0
- Phase length: 20s each, sampled once per second after a 3s warm-up

## static (TextEdit)

```
without Dropy
windowserver: cpuMean=44.8% cpuP95=48.4% memMax=42.2MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=11.8% utilP95=14.0% samples=20

with Dropy
dropy: cpuMean=11.2% cpuP95=12.6% memMax=33.6MB idleWakeups=0.0/s interruptWakeups=10.6/s samples=20
windowserver: cpuMean=45.3% cpuP95=46.7% memMax=47.2MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=44.6% utilP95=46.0% samples=20
Dropy reveal: firstFrame=440.3ms open=1 warm=no
Dropy capture metrics: window=3688 duration=24.9s start=244.3ms firstFrame=223.5ms output=1176x705/BGRA status=[complete=1434,idle=1] completeRate=57.5/s mailboxDrops=4 presented=1427 notPresented=2 captureToCallback=[n=1434 p50=0.8 p95=1.7 p99=3.3 max=16.4] callbackToPresent=[n=1427 p50=41.2 p95=51.1 p99=52.0 max=54.4] frameAge=[n=1427 p50=42.1 p95=51.9 p99=52.7 max=56.0] clockOffset=0.000ms stop=closed
```

## scroll (Safari)

```
without Dropy
windowserver: cpuMean=44.3% cpuP95=46.7% memMax=37.3MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=18.0% utilP95=19.0% samples=20

with Dropy
dropy: cpuMean=11.7% cpuP95=13.4% memMax=33.4MB idleWakeups=0.0/s interruptWakeups=10.9/s samples=20
windowserver: cpuMean=45.6% cpuP95=48.5% memMax=50.0MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=47.5% utilP95=49.0% samples=20
Dropy reveal: firstFrame=558.9ms open=1 warm=no
Dropy capture metrics: window=3704 duration=24.8s start=303.7ms firstFrame=297.0ms output=1176x705/BGRA status=[complete=1431] completeRate=57.7/s mailboxDrops=7 presented=1421 notPresented=2 captureToCallback=[n=1431 p50=0.7 p95=1.6 p99=3.2 max=20.0] callbackToPresent=[n=1421 p50=39.1 p95=51.1 p99=51.9 max=54.1] frameAge=[n=1421 p50=40.2 p95=51.9 p99=53.0 max=55.6] clockOffset=-0.000ms stop=closed
```

## animation (Safari)

```
without Dropy
windowserver: cpuMean=42.9% cpuP95=45.5% memMax=36.8MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=31.7% utilP95=34.0% samples=20

with Dropy
dropy: cpuMean=12.0% cpuP95=12.9% memMax=33.6MB idleWakeups=0.0/s interruptWakeups=10.4/s samples=20
windowserver: cpuMean=43.9% cpuP95=46.5% memMax=46.6MB idleWakeups=-/s interruptWakeups=-/s samples=20
gpu: utilMean=57.8% utilP95=59.0% samples=20
Dropy reveal: firstFrame=673.2ms open=1 warm=no
Dropy capture metrics: window=3721 duration=24.8s start=299.5ms firstFrame=302.1ms output=1176x705/BGRA status=[complete=1436] completeRate=57.8/s mailboxDrops=9 presented=1422 notPresented=4 captureToCallback=[n=1436 p50=0.7 p95=2.2 p99=4.9 max=67.0] callbackToPresent=[n=1422 p50=28.5 p95=35.5 p99=39.7 max=51.8] frameAge=[n=1422 p50=29.8 p95=36.4 p99=41.1 max=54.2] clockOffset=0.000ms stop=closed
```

