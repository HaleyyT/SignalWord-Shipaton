import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync('supabase/migrations/20260921000000_initial_alerts.sql', 'utf8');
const alertApiMigration = readFileSync('supabase/migrations/20260924010000_alert_api_walking_skeleton.sql', 'utf8');
const contactRateLimitMigration = readFileSync('supabase/migrations/20260924060000_contact_setup_rate_limits.sql', 'utf8');

test('schema protects each private table with row-level security', () => {
  for (const table of [
    'profiles',
    'trusted_contacts',
    'alert_events',
    'location_samples',
    'alert_deliveries',
    'viewer_tokens',
    'contact_confirmation_tokens',
    'rate_limit_buckets',
  ]) {
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
  }
});

test('schema guarantees one canonical alert for an idempotency key', () => {
  assert.match(migration, /constraint alert_events_user_idempotency_key unique \(user_id, idempotency_key\)/i);
  assert.match(migration, /token_hash bytea not null unique check \(octet_length\(token_hash\) = 32\)/i);
  assert.match(migration, /constraint alert_deliveries_provider_idempotency_key unique \(provider_idempotency_key\)/i);
});

test('schema guarantees that an alert contact belongs to the same user', () => {
  assert.match(migration, /foreign key \(trusted_contact_id, user_id\)[\s\S]*references public\.trusted_contacts \(id, user_id\)/i);
});

test('schema permits queued deliveries while deduplicating assigned provider IDs', () => {
  assert.doesNotMatch(migration, /unique nulls not distinct \(provider, provider_message_id\)/i);
  assert.match(migration, /unique index alert_deliveries_provider_message_unique_idx[\s\S]*where provider_message_id is not null/i);
  assert.match(migration, /next_attempt_at timestamptz not null default now\(\)/i);
  assert.match(migration, /max_attempts integer not null default 4/i);
});

test('schema persists only hashed expiring confirmation and rate-limit subjects', () => {
  assert.match(migration, /create table public\.contact_confirmation_tokens/i);
  assert.match(migration, /consumed_at timestamptz/i);
  assert.match(migration, /create table public\.rate_limit_buckets/i);
  assert.match(migration, /subject_hash bytea not null check \(octet_length\(subject_hash\) = 32\)/i);
});

test('contact verification traffic is limited by hashed user and destination subjects', () => {
  assert.match(contactRateLimitMigration, /before insert on public\.contact_verification_deliveries/i);
  assert.match(contactRateLimitMigration, /scope = 'user'/i);
  assert.match(contactRateLimitMigration, /scope = 'destination'/i);
  assert.match(contactRateLimitMigration, />= 5/);
  assert.match(contactRateLimitMigration, />= 3/);
  assert.match(contactRateLimitMigration, /message = 'RATE_LIMITED'/);
  assert.doesNotMatch(contactRateLimitMigration, /destination_ciphertext/);
});

test('schema blocks anonymous direct access to sensitive data', () => {
  for (const table of ['viewer_tokens', 'trusted_contacts', 'alert_events', 'location_samples', 'alert_deliveries', 'profiles']) {
    assert.match(migration, new RegExp(`revoke all on public\\.${table} from anon`, 'i'));
  }
  assert.doesNotMatch(migration, /grant all .* to anon/i);
});

test('schema has bounded retention for locations, tokens, and delivery diagnostics', () => {
  assert.match(migration, /delete from public\.location_samples where expires_at <= now\(\)/i);
  assert.match(migration, /delete from public\.viewer_tokens where expires_at <= now\(\) or revoked_at is not null/i);
  assert.match(migration, /interval '7 days'/i);
  assert.match(migration, /delete from public\.contact_confirmation_tokens/i);
  assert.match(migration, /delete from public\.rate_limit_buckets where expires_at <= now\(\)/i);
  assert.match(migration, /cron\.schedule\([\s\S]*signalword-hourly-retention/i);
});

test('alert creation is transactionally serialized and stores only a viewer-token hash', () => {
  assert.match(alertApiMigration, /pg_advisory_xact_lock/i);
  assert.match(alertApiMigration, /extensions\.digest\(pg_catalog\.convert_to\(p_viewer_token, 'UTF8'\), 'sha256'\)/i);
  assert.match(alertApiMigration, /insert into public\.alert_deliveries[\s\S]*payload_ciphertext[\s\S]*payload_key_version/i);
  assert.doesNotMatch(alertApiMigration, /return query[\s\S]{0,200}p_viewer_token/i);
});

test('cooldown is kind-scoped so a rehearsal cannot suppress a real alert', () => {
  assert.match(alertApiMigration, /where user_id = p_user_id\s+and kind = p_kind\s+and state in/mi);
});

test('delivery uses a leased retryable transactional outbox', () => {
  assert.match(alertApiMigration, /create or replace function public\.claim_alert_deliveries/i);
  assert.match(alertApiMigration, /for update skip locked/i);
  assert.match(alertApiMigration, /create or replace function public\.finish_alert_delivery/i);
  assert.match(alertApiMigration, /when 1 then now\(\) \+ interval '1 minute'/i);
});

test('public projection is token-scoped, expiry-aware, and explicitly allowlisted', () => {
  assert.match(alertApiMigration, /create or replace function public\.get_public_event/i);
  assert.match(alertApiMigration, /token\.revoked_at is null/i);
  assert.match(alertApiMigration, /token\.expires_at > now\(\)/i);
  assert.match(alertApiMigration, /jsonb_strip_nulls\(jsonb_build_object/i);
  assert.doesNotMatch(alertApiMigration, /destination_ciphertext/);
  assert.match(alertApiMigration, /location\.captured_at between now\(\) - interval '30 seconds'/i);
});
