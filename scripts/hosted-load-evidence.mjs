import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const SHA256 = /^[a-f0-9]{64}$/;
const LABEL = /^[a-z0-9][a-z0-9-]{2,63}$/;

function validateSamples(rows, expectedCount) {
  if (!Array.isArray(rows)) throw new Error('COMPLETE_SAMPLE_SET_REQUIRED');
  if (rows.length !== expectedCount || new Set(rows.map(row => row.sequence)).size !== expectedCount) {
    throw new Error('COMPLETE_SAMPLE_SET_REQUIRED');
  }
  for (const row of rows) {
    if (!Number.isSafeInteger(row.sequence) || row.sequence < 0 || row.sequence >= expectedCount ||
      !Number.isSafeInteger(row.status) || row.status < 100 || row.status > 599 || !Number.isSafeInteger(row.durationMs) ||
      row.durationMs < 0 || typeof row.valid !== 'boolean' || typeof row.transportError !== 'boolean') {
      throw new Error('VALID_SAMPLE_REQUIRED');
    }
  }
  return rows;
}

function samples(path, expectedCount) {
  return validateSamples(readFileSync(path, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)), expectedCount);
}

function providerCount(provider, key) {
  const value = provider?.[key];
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`PROVIDER_COUNT_REQUIRED:${key}`);
  return value;
}

function p95(values) {
  const ordered = [...values].sort((left, right) => left - right);
  return ordered[Math.ceil(ordered.length * 0.95) - 1];
}

/** Build the redacted H16 judgment only after correlated provider evidence is captured. */
export function evaluateHostedLoadEvidence({ metadata, first, duplicate, reads, provider }) {
  if (metadata.environment !== 'development' || !/^[a-f0-9]{40}$/.test(metadata.sourceCommit ?? '') || metadata.declaredBeforeRun !== true) {
    throw new Error('DECLARED_DEVELOPMENT_RUN_REQUIRED');
  }
  first = validateSamples(first, 10);
  duplicate = validateSamples(duplicate, 10);
  reads = validateSamples(reads, 20);
  const deliveries = provider?.deliveries;
  if (!Array.isArray(deliveries) || deliveries.length < 10 || provider.capturedBeforeCleanup !== true) {
    throw new Error('PRE_CLEANUP_PROVIDER_EVIDENCE_REQUIRED');
  }
  for (const delivery of deliveries) {
    if (!LABEL.test(delivery.senderLabel ?? '') || !LABEL.test(delivery.deliveryLabel ?? '') ||
      !SHA256.test(delivery.providerMessageDigest ?? '') || !Number.isSafeInteger(delivery.attemptCount) ||
      !Number.isSafeInteger(delivery.providerAcceptedMs) || delivery.providerAcceptedMs < 0 ||
      !Number.isSafeInteger(delivery.signedCallbackCount) || delivery.signedCallbackCount < 0) {
      throw new Error('VALID_PROVIDER_DELIVERY_REQUIRED');
    }
  }
  const counts = {
    incidentCount: providerCount(provider, 'incidentCount'),
    uniqueIncidentCount: providerCount(provider, 'uniqueIncidentCount'),
    deliveryCountBeforeDuplicates: providerCount(provider, 'deliveryCountBeforeDuplicates'),
    deliveryCountAfterDuplicates: providerCount(provider, 'deliveryCountAfterDuplicates'),
    queuedCount: providerCount(provider, 'queuedCount'),
    unknownOutcomeCount: providerCount(provider, 'unknownOutcomeCount'),
  };
  const senderCount = new Set(deliveries.map(delivery => delivery.senderLabel)).size;
  const uniqueProviderMessages = new Set(deliveries.map(delivery => delivery.providerMessageDigest)).size;
  const providerP95Ms = p95(deliveries.map(delivery => delivery.providerAcceptedMs));
  const firstP95Ms = p95(first.map(row => row.durationMs));
  const duplicateP95Ms = p95(duplicate.map(row => row.durationMs));
  const readP95Ms = p95(reads.map(row => row.durationMs));
  const assertions = {
    tenSuccessfulFirstSubmissions: first.length === 10 && first.every(row => row.status === 201 && row.valid && !row.transportError),
    tenSuccessfulIdempotentDuplicates: duplicate.length === 10 && duplicate.every(row => row.status === 200 && row.valid && !row.transportError),
    twentySuccessfulReads: reads.length === 20 && reads.every(row => row.status === 200 && row.valid && !row.transportError),
    submissionP95WithinBudget: firstP95Ms <= 2000,
    duplicateP95WithinBudget: duplicateP95Ms <= 2000,
    readP95WithinBudget: readP95Ms <= 5000,
    tenUniqueIncidents: counts.incidentCount === 10 && counts.uniqueIncidentCount === 10,
    providerDeliveryRowsComplete: counts.deliveryCountBeforeDuplicates > 0 && counts.deliveryCountBeforeDuplicates === deliveries.length,
    duplicatesCreatedNoDeliveries: counts.deliveryCountBeforeDuplicates === counts.deliveryCountAfterDuplicates,
    tenDistinctProviderSenders: senderCount === 10,
    oneAttemptPerDelivery: deliveries.every(delivery => delivery.attemptCount === 1),
    uniqueProviderMessagePerDelivery: uniqueProviderMessages === deliveries.length,
    signedCallbacksPresent: deliveries.every(delivery => delivery.signedCallbackCount >= 1),
    providerAcceptanceWithinBudget: providerP95Ms <= 5000,
    noQueuedOrUnknownWork: counts.queuedCount === 0 && counts.unknownOutcomeCount === 0,
  };
  return {
    environment: 'development',
    sourceCommit: metadata.sourceCommit,
    recordedAt: metadata.recordedAt,
    sampleCounts: { first: first.length, duplicate: duplicate.length, reads: reads.length, deliveries: deliveries.length },
    latencyMs: { firstP95: firstP95Ms, duplicateP95: duplicateP95Ms, readP95: readP95Ms, providerAcceptanceP95: providerP95Ms },
    assertions,
    passed: Object.values(assertions).every(Boolean),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [metadataPath, firstPath, duplicatePath, readsPath, providerPath, output] = process.argv.slice(2);
  if (!output) throw new Error('METADATA_SAMPLES_PROVIDER_AND_NEW_OUTPUT_REQUIRED');
  const result = evaluateHostedLoadEvidence({
    metadata: JSON.parse(readFileSync(metadataPath, 'utf8')),
    first: samples(firstPath, 10),
    duplicate: samples(duplicatePath, 10),
    reads: samples(readsPath, 20),
    provider: JSON.parse(readFileSync(providerPath, 'utf8')),
  });
  writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ passed: result.passed, output }));
  if (!result.passed) process.exitCode = 1;
}
