# Dropy idle input-to-visible latency trace

- Date: 2026-09-30 02:07 IST; revision: 91a62ea (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; source: Electron 43.2.0 fixture window A, static text page; overlay wide, fit
- 10s quiet, then 20 HID clicks on the preview's Press button, 3s apart; desktop session: owner=latency-trace; input idle 104.8s at start; power ac

Clicks routed: 20; distinct input marks traced: 20; clicks with a response frame: 20.

### Response frames (idle input to visible update) (20 frames, 0 not presented, 43 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 0.8 | 1.1 | 1.5 |
| compare | 0.1 | 0.1 | 0.2 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.0 | 0.0 | 0.0 |
| draw | 30.6 | 57.0 | 60.2 |
| compose | 30.3 | 49.0 | 49.4 |
| age | 60.9 | 106.9 | 110.0 |
| inputToDisplay | 74.5 | 92.6 | 98.0 |
| inputToPresent | 135.8 | 188.4 | 204.9 |

### Follow-up frames after an input (37 frames, 0 not presented, 16 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 1.3 | 1.9 | 2.0 |
| compare | 0.4 | 1.8 | 1.8 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.1 | 0.4 | 0.5 |
| draw | 0.4 | 53.0 | 53.8 |
| compose | 28.6 | 36.5 | 42.2 |
| age | 33.1 | 84.3 | 84.7 |
| inputToDisplay | 1041.9 | 2252.0 | 2469.3 |
| inputToPresent | 1062.2 | 2334.7 | 2553.6 |

### Frames with no input (quiet period) (3 frames, 1 not presented, 5 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 1.1 | 12.6 | 12.6 |
| compare | 0.2 | 0.3 | 0.3 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.0 | 0.1 | 0.1 |
| draw | 34.3 | 55.0 | 55.0 |
| compose | 18.1 | 30.6 | 30.6 |
| age | 66.4 | 73.7 | 73.7 |

### Per click

| # | inputToDisplay | inputToPresent | capture | main | draw | compose | draws | misses |
|---|---|---|---|---|---|---|---|---|
| 1 | 87.7 | 141.8 | 0.5 | 0.0 | 22.4 | 31.1 | 3 | 2 |
| 2 | 78.4 | 135.1 | 0.7 | 0.0 | 24.8 | 31.1 | 3 | 2 |
| 3 | 45.3 | 100.5 | 0.8 | 0.0 | 23.7 | 30.6 | 3 | 2 |
| 4 | 64.2 | 127.1 | 0.7 | 0.0 | 38.3 | 23.8 | 3 | 2 |
| 5 | 98.0 | 204.9 | 0.9 | 0.0 | 57.0 | 48.9 | 4 | 3 |
| 6 | 76.1 | 137.0 | 0.7 | 0.0 | 29.2 | 31.0 | 3 | 2 |
| 7 | 38.1 | 95.6 | 0.8 | 0.0 | 25.5 | 31.1 | 3 | 2 |
| 8 | 60.2 | 113.3 | 0.5 | 0.0 | 23.1 | 29.5 | 3 | 2 |
| 9 | 92.6 | 151.4 | 1.0 | 0.0 | 29.0 | 28.7 | 3 | 2 |
| 10 | 65.1 | 134.6 | 1.1 | 0.0 | 44.0 | 24.3 | 3 | 2 |
| 11 | 78.4 | 188.4 | 0.8 | 0.0 | 60.2 | 49.0 | 4 | 3 |
| 12 | 38.6 | 97.5 | 0.6 | 0.0 | 26.9 | 31.3 | 3 | 2 |
| 13 | 65.7 | 169.0 | 1.1 | 0.0 | 52.7 | 49.4 | 4 | 3 |
| 14 | 89.5 | 153.6 | 0.7 | 0.0 | 33.0 | 30.2 | 3 | 2 |
| 15 | 74.5 | 148.3 | 1.1 | 0.0 | 44.5 | 28.1 | 3 | 2 |
| 16 | 88.8 | 151.4 | 0.8 | 0.0 | 31.4 | 30.3 | 3 | 2 |
| 17 | 51.6 | 114.4 | 0.7 | 0.0 | 30.6 | 31.3 | 3 | 2 |
| 18 | 66.6 | 135.8 | 1.0 | 0.0 | 44.1 | 23.9 | 3 | 2 |
| 19 | 77.1 | 135.3 | 1.5 | 0.0 | 30.6 | 25.9 | 3 | 2 |
| 20 | 91.2 | 152.0 | 0.8 | 0.0 | 29.6 | 30.3 | 3 | 2 |

## Capture metrics

```
Dropy reveal: firstFrame=422.3ms open=1 warm=no
Dropy capture metrics: window=4926 duration=90.3s start=207.8ms firstFrame=199.9ms output=1040x760/BGRA status=[complete=1169] completeRate=12.9/s unchanged=1109 rateChanges=10idle/9full mailboxDrops=0 presented=59 notPresented=1 drawableMisses=64 captureToCallback=[n=1169 p50=1.3 p95=2.0 p99=2.8 max=12.6] callbackToPresent=[n=59 p50=52.7 p95=102.1 p99=109.2 max=109.2] frameAge=[n=59 p50=53.1 p95=103.2 p99=110.0 max=110.0] clockOffset=0.000ms stop=closed
  20 Dropy input: kind=pointerClick condition=visible route=accessibility
```
