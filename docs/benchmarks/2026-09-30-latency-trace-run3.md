# Dropy idle input-to-visible latency trace

- Date: 2026-09-30 02:13 IST; revision: 91a62ea (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; source: Electron 43.2.0 fixture window A, static text page; overlay wide, fit
- 10s quiet, then 20 HID clicks on the preview's Press button, 3s apart; desktop session: owner=latency-trace; input idle 101.7s at start; power ac

Clicks routed: 20; distinct input marks traced: 20; clicks with a response frame: 20.

### Response frames (idle input to visible update) (20 frames, 0 not presented, 39 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 0.8 | 1.1 | 1.1 |
| compare | 0.1 | 0.1 | 0.4 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.0 | 0.1 | 1.2 |
| draw | 30.5 | 45.0 | 62.5 |
| compose | 30.0 | 35.6 | 49.0 |
| age | 60.6 | 81.5 | 112.5 |
| inputToDisplay | 63.7 | 88.1 | 101.3 |
| inputToPresent | 124.6 | 152.9 | 183.4 |

### Follow-up frames after an input (32 frames, 0 not presented, 12 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 1.3 | 1.9 | 22.2 |
| compare | 0.3 | 1.8 | 2.2 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.1 | 0.6 | 0.6 |
| draw | 0.4 | 42.7 | 50.2 |
| compose | 26.7 | 32.8 | 37.5 |
| age | 30.5 | 70.9 | 81.3 |
| inputToDisplay | 1051.2 | 2247.4 | 2267.2 |
| inputToPresent | 1080.7 | 2318.4 | 2336.2 |

### Frames with no input (quiet period) (3 frames, 0 not presented, 4 drawable misses)

| Stage | p50 | p95 | max |
|---|---|---|---|
| capture | 2.0 | 10.8 | 10.8 |
| compare | 0.3 | 0.4 | 0.4 |
| forward | 0.0 | 0.0 | 0.0 |
| main | 0.0 | 0.1 | 0.1 |
| draw | 22.6 | 52.3 | 52.3 |
| compose | 29.3 | 32.2 | 32.2 |
| age | 55.3 | 81.2 | 81.2 |

### Per click

| # | inputToDisplay | inputToPresent | capture | main | draw | compose | draws | misses | draw log (ms after delivery) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 56.4 | 75.3 | 0.7 | 0.1 | 0.2 | 17.5 | 1 | 0 | +0.2:shown |
| 2 | 44.5 | 97.4 | 0.8 | 0.0 | 20.7 | 31.4 | 3 | 2 | +0.2:miss,+15.0:miss,+20.7:shown |
| 3 | 63.7 | 128.4 | 1.1 | 0.0 | 33.4 | 30.2 | 3 | 2 | +0.1:miss,+16.2:miss,+33.4:shown |
| 4 | 74.5 | 138.3 | 0.7 | 0.0 | 33.1 | 29.9 | 3 | 2 | +0.1:miss,+16.0:miss,+33.1:shown |
| 5 | 51.7 | 112.3 | 0.6 | 0.0 | 29.7 | 30.1 | 3 | 2 | +0.1:miss,+12.6:miss,+29.7:shown |
| 6 | 88.1 | 151.7 | 0.8 | 0.0 | 32.8 | 29.9 | 3 | 2 | +0.1:miss,+15.7:miss,+32.8:shown |
| 7 | 59.7 | 124.6 | 1.1 | 0.0 | 33.3 | 30.5 | 3 | 2 | +0.1:miss,+16.1:miss,+33.3:shown |
| 8 | 85.6 | 148.9 | 0.7 | 0.0 | 32.5 | 30.0 | 3 | 2 | +0.1:miss,+15.3:miss,+32.5:shown |
| 9 | 46.8 | 102.8 | 0.7 | 0.0 | 24.1 | 31.2 | 3 | 2 | +0.2:miss,+14.8:miss,+24.1:shown |
| 10 | 52.7 | 120.5 | 0.5 | 1.2 | 37.3 | 28.7 | 3 | 2 | +0.1:miss,+20.2:miss,+37.3:shown |
| 11 | 78.4 | 134.6 | 1.1 | 0.0 | 30.2 | 24.8 | 3 | 2 | +0.1:miss,+13.0:miss,+30.2:shown |
| 12 | 101.3 | 152.9 | 0.8 | 0.0 | 21.2 | 29.5 | 3 | 2 | +0.2:miss,+4.0:miss,+21.2:shown |
| 13 | 68.1 | 131.9 | 1.1 | 0.0 | 35.2 | 27.4 | 3 | 2 | +0.2:miss,+18.0:miss,+35.2:shown |
| 14 | 78.1 | 134.8 | 1.0 | 0.0 | 26.2 | 29.4 | 3 | 2 | +0.2:miss,+9.0:miss,+26.2:shown |
| 15 | 71.0 | 183.4 | 0.9 | 0.0 | 62.5 | 49.0 | 4 | 3 | +0.1:miss,+14.3:miss,+31.4:miss,+62.5:shown |
| 16 | 84.8 | 147.3 | 0.8 | 0.0 | 31.7 | 30.0 | 3 | 2 | +0.1:miss,+14.6:miss,+31.7:shown |
| 17 | 48.1 | 102.0 | 0.9 | 0.0 | 22.0 | 30.9 | 3 | 2 | +0.2:miss,+12.4:miss,+22.0:shown |
| 18 | 64.2 | 123.6 | 0.8 | 0.0 | 30.5 | 28.1 | 3 | 2 | +0.1:miss,+13.3:miss,+30.5:shown |
| 19 | 18.5 | 100.0 | 0.9 | 0.0 | 45.0 | 35.6 | 3 | 2 | +0.2:miss,+17.0:miss,+45.0:shown |
| 20 | 41.1 | 96.7 | 0.7 | 0.0 | 24.0 | 30.8 | 3 | 2 | +0.2:miss,+7.8:miss,+24.0:shown |

## Capture metrics

```
Dropy reveal: firstFrame=373.6ms open=1 warm=no
Dropy capture metrics: window=5020 duration=89.7s start=217.3ms firstFrame=210.1ms output=1040x760/BGRA status=[complete=1104] completeRate=12.3/s unchanged=1049 rateChanges=7idle/6full mailboxDrops=0 presented=55 notPresented=0 drawableMisses=55 captureToCallback=[n=1104 p50=1.3 p95=2.0 p99=2.8 max=22.2] callbackToPresent=[n=55 p50=38.1 p95=79.5 p99=111.6 max=111.6] frameAge=[n=55 p50=50.3 p95=81.3 p99=112.5 max=112.5] clockOffset=0.000ms stop=closed
  20 Dropy input: kind=pointerClick condition=visible route=accessibility
```
