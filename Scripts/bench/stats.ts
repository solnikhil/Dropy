// Small statistics shared by Dropy's Bun tooling. Percentiles use nearest rank, like
// CaptureMetrics in DropyCore, so numbers line up with the app's own logs.

export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const ordered = [...values].sort((a, b) => a - b);
  return ordered[Math.min(ordered.length - 1, Math.max(0, Math.ceil(p * ordered.length) - 1))];
}

export interface Summary {
  n: number;
  p50: number | null;
  p95: number | null;
  max: number | null;
  mean: number | null;
}

export function summarize(values: number[]): Summary {
  const mean = values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
  return {
    n: values.length,
    p50: percentile(values, 0.5),
    p95: percentile(values, 0.95),
    max: values.length ? Math.max(...values) : null,
    mean: mean === null ? null : Math.round(mean * 100) / 100,
  };
}

export const fmt = (value: number | null | undefined, digits = 1) =>
  value === null || value === undefined ? "—" : value.toFixed(digits);
