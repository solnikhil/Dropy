# Dropy idle input-to-visible latency trace

- Date: 2026-09-30 02:10 IST; revision: 91a62ea (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; source: Electron 43.2.0 fixture window A, static text page; overlay wide, fit
- 10s quiet, then 20 HID clicks on the preview's Press button, 3s apart; desktop session: owner=latency-trace; input idle 35.5s at start; power ac

Clicks routed: 20; distinct input marks traced: 20; clicks with a response frame: 20.

### Response frames (idle input to visible update) (20 frames, 0 not presented, 42 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 0.9 | 1.1 | 1.2 |
| compare | 0.1 | 0.1 | 0.3 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.0 | 0.0 | 0.1 |
| draw | 31.6 | 57.0 | 67.9 |
| compose | 30.6 | 49.0 | 49.3 |
| age | 63.1 | 107.1 | 117.5 |
| inputToDisplay | 65.5 | 108.3 | 109.2 |
| inputToPresent | 133.7 | 183.8 | 197.2 |

### Follow-up frames after an input (32 frames, 0 not presented, 12 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 1.5 | 2.1 | 2.4 |
| compare | 0.3 | 1.8 | 2.2 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.1 | 0.5 | 0.5 |
| draw | 0.4 | 53.8 | 54.8 |
| compose | 28.4 | 47.2 | 49.4 |
| age | 34.6 | 81.8 | 84.0 |
| inputToDisplay | 1045.0 | 2279.1 | 2420.9 |
| inputToPresent | 1070.3 | 2350.6 | 2477.6 |

### Frames with no input (quiet period) (3 frames, 0 not presented, 3 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 1.8 | 6.5 | 6.5 |
| compare | 0.2 | 0.4 | 0.4 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.0 | 5.1 | 5.1 |
| draw | 27.7 | 31.1 | 31.1 |
| compose | 29.1 | 32.6 | 32.6 |
| age | 58.9 | 64.5 | 64.5 |

### Per click

| # | inputToDisplay | inputToPresent | capture | main | draw | compose | draws | misses |
|---|---|---|---|---|---|---|---|---|
| 1 | 49.5 | 73.0 | 0.8 | 0.1 | 0.1 | 22.3 | 1 | 0 |
| 2 | 104.4 | 167.3 | 0.8 | 0.0 | 31.1 | 30.8 | 3 | 2 |
| 3 | 78.9 | 133.7 | 1.0 | 0.0 | 29.7 | 23.9 | 3 | 2 |
| 4 | 20.9 | 78.0 | 0.8 | 0.0 | 25.6 | 30.7 | 3 | 2 |
| 5 | 46.0 | 103.6 | 0.9 | 0.0 | 25.3 | 31.3 | 3 | 2 |
| 6 | 66.2 | 183.8 | 0.5 | 0.0 | 67.9 | 49.0 | 4 | 3 |
| 7 | 108.3 | 171.4 | 0.9 | 0.0 | 31.9 | 30.3 | 3 | 2 |
| 8 | 40.8 | 96.8 | 0.9 | 0.0 | 25.8 | 29.2 | 3 | 2 |
| 9 | 38.9 | 103.7 | 1.0 | 0.0 | 35.4 | 28.3 | 3 | 2 |
| 10 | 65.5 | 172.4 | 0.7 | 0.0 | 56.8 | 49.3 | 4 | 3 |
| 11 | 100.9 | 164.7 | 1.0 | 0.0 | 32.5 | 30.3 | 3 | 2 |
| 12 | 109.2 | 176.2 | 1.2 | 0.0 | 35.3 | 30.5 | 3 | 2 |
| 13 | 76.2 | 129.2 | 1.0 | 0.0 | 31.6 | 20.4 | 3 | 2 |
| 14 | 91.3 | 197.2 | 0.9 | 0.0 | 55.9 | 49.0 | 4 | 3 |
| 15 | 38.9 | 96.0 | 0.9 | 0.0 | 25.4 | 30.8 | 3 | 2 |
| 16 | 67.5 | 130.9 | 1.1 | 0.0 | 31.6 | 30.6 | 3 | 2 |
| 17 | 64.3 | 171.4 | 0.9 | 0.0 | 57.0 | 49.0 | 4 | 3 |
| 18 | 64.8 | 131.1 | 0.9 | 0.0 | 32.6 | 32.7 | 2 | 1 |
| 19 | 87.0 | 144.2 | 0.7 | 0.0 | 27.2 | 29.2 | 3 | 2 |
| 20 | 34.3 | 134.5 | 0.9 | 0.0 | 56.0 | 43.2 | 4 | 3 |

## Capture metrics

```
Dropy reveal: firstFrame=302.2ms open=1 warm=no
Dropy capture metrics: window=4978 duration=89.8s start=178.6ms firstFrame=160.1ms output=1040x760/BGRA status=[complete=1099] completeRate=12.2/s unchanged=1044 rateChanges=7idle/6full mailboxDrops=0 presented=55 notPresented=0 drawableMisses=57 captureToCallback=[n=1099 p50=1.3 p95=2.0 p99=3.1 max=15.8] callbackToPresent=[n=55 p50=51.5 p95=106.2 p99=117.0 max=117.0] frameAge=[n=55 p50=53.1 p95=106.9 p99=117.5 max=117.5] clockOffset=0.000ms stop=closed
  20 Dropy input: kind=pointerClick condition=visible route=accessibility
```
