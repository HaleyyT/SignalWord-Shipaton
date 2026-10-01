-- Bound confirmation-email abuse by both SignalWord identity and encrypted
-- destination fingerprint. Only accepted setup attempts consume capacity;
-- blocked statements cannot erase or reset prior successful counts.

create or replace function public.enforce_contact_verification_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_destination_fingerprint text;
  v_user_hash bytea;
  v_destination_hash bytea;
  v_window_start timestamptz := pg_catalog.date_trunc('hour', statement_timestamp());
begin
  select contact.user_id, contact.destination_fingerprint
    into v_user_id, v_destination_fingerprint
    from public.trusted_contacts contact
    where contact.id = new.trusted_contact_id;

  if v_user_id is null or v_destination_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'INVALID_RATE_LIMIT_SUBJECT';
  end if;

  v_user_hash := extensions.digest(
    pg_catalog.convert_to('contact_setup:' || v_user_id::text, 'UTF8'), 'sha256'
  );
  v_destination_hash := pg_catalog.decode(v_destination_fingerprint, 'hex');

  -- Every writer takes locks in this order to avoid deadlocks.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'user:' || pg_catalog.encode(v_user_hash, 'hex') || ':' || v_window_start::text, 41
  ));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'destination:' || pg_catalog.encode(v_destination_hash, 'hex') || ':' || v_window_start::text, 42
  ));

  if coalesce((select bucket.request_count from public.rate_limit_buckets bucket
      where bucket.scope = 'user' and bucket.subject_hash = v_user_hash
        and bucket.window_started_at = v_window_start), 0) >= 5
    or coalesce((select bucket.request_count from public.rate_limit_buckets bucket
      where bucket.scope = 'destination' and bucket.subject_hash = v_destination_hash
        and bucket.window_started_at = v_window_start), 0) >= 3 then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  insert into public.rate_limit_buckets (
    scope, subject_hash, window_started_at, request_count, expires_at
  ) values ('user', v_user_hash, v_window_start, 1, v_window_start + interval '1 hour')
  on conflict (scope, subject_hash, window_started_at) do update
    set request_count = public.rate_limit_buckets.request_count + 1,
        updated_at = statement_timestamp();

  insert into public.rate_limit_buckets (
    scope, subject_hash, window_started_at, request_count, expires_at
  ) values ('destination', v_destination_hash, v_window_start, 1, v_window_start + interval '1 hour')
  on conflict (scope, subject_hash, window_started_at) do update
    set request_count = public.rate_limit_buckets.request_count + 1,
        updated_at = statement_timestamp();

  return new;
end;
$$;

revoke all on function public.enforce_contact_verification_rate_limit() from public;

create trigger enforce_contact_verification_rate_limit
before insert on public.contact_verification_deliveries
for each row execute function public.enforce_contact_verification_rate_limit();
