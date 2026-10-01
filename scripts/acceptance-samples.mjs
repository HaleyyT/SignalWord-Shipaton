import { appendFileSync, closeSync, openSync } from 'node:fs';
import { performance } from 'node:perf_hooks';

/** Record every completed request before evaluating a burst's acceptance result.
 * Only allowlisted scalars leave the request callback. URLs, response bodies,
 * thrown error text and credentials must never enter retained load evidence.
 */
export async function recordConcurrentSamples({ count, output, request }) {
  if (!Number.isInteger(count) || count < 1 || count > 20) {
    throw new Error('ACCEPTANCE_BURST_SIZE_INVALID');
  }
  // Exclusive creation protects earlier cold/failed samples from accidental overwrite.
  const fd = openSync(output, 'wx', 0o600);
  try {
    const samples = await Promise.all(Array.from({ length: count }, async (_, sequence) => {
      const started = performance.now();
      let status = 0;
      let valid = false;
      let transportError = false;
      let phases;
      try {
        const result = await request(sequence);
        status = Number.isInteger(result?.status) && result.status >= 100 && result.status <= 599
          ? result.status : 0;
        valid = status >= 200 && status < 300 && result?.valid === true;
        if (result?.phases && typeof result.phases === 'object' && !Array.isArray(result.phases)) {
          const allowed = ['authSessionMs', 'preparationMs', 'databaseMs', 'appMs'];
          const retained = Object.fromEntries(allowed.flatMap(key => {
            const value = result.phases[key];
            return Number.isFinite(value) && value >= 0 ? [[key, Math.round(value)]] : [];
          }));
          if (Object.keys(retained).length > 0) phases = retained;
        }
      } catch {
        // Network errors may embed private URLs. Retain the category, not the message.
        transportError = true;
      }
      const durationMs = Math.round(performance.now() - started);
      const sample = {
        sequence, status, durationMs, valid, transportError,
        ...(phases ? { phases: {
          ...phases,
          ...(Number.isFinite(phases.appMs) ? { clientEdgeMs: Math.max(0, durationMs - phases.appMs) } : {}),
        } } : {}),
      };
      appendFileSync(fd, JSON.stringify(sample) + '\n');
      return sample;
    }));
    const durations = samples.map(s => s.durationMs).sort((a, b) => a - b);
    return {
      count: samples.length,
      successful: samples.filter(s => s.valid).length,
      p95Ms: durations[Math.ceil(samples.length * 0.95) - 1],
      samples,
    };
  } finally {
    closeSync(fd);
  }
}
