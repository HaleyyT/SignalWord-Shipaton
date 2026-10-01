-- Only the authenticated Edge API may choose encrypted routing and consent tokens.
-- Client callers must not choose a known confirmation hash and confirm themselves.
-- The API verifies the user JWT before passing that verified user's ID here.
create or replace function public.create_or_replace_contact(
  p_user_id uuid,
  p_name text,
  p_channel text,
  p_destination_ciphertext text,
  p_destination_fingerprint text,
  p_destination_key_version integer,
  p_confirmation_token_hash bytea,
  p_confirmation_payload_ciphertext text,
  p_payload_key_version integer,
  p_delivery_provider text
)
returns table (
  contact_id uuid,
  contact_name text,
  contact_channel text,
  contact_status text,
  confirmation_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact public.trusted_contacts%rowtype;
  v_token_id uuid;
  v_expires_at timestamptz := now() + interval '30 minutes';
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  if pg_catalog.char_length(pg_catalog.btrim(p_name)) not between 1 and 80
    or p_channel <> 'email'
    or pg_catalog.char_length(p_destination_ciphertext) < 24
    or pg_catalog.char_length(p_destination_fingerprint) <> 64
    or p_destination_key_version not between 1 and 32767
    or pg_catalog.octet_length(p_confirmation_token_hash) <> 32
    or pg_catalog.char_length(p_confirmation_payload_ciphertext) < 24
    or p_payload_key_version not between 1 and 32767
    or p_delivery_provider not in ('fake', 'resend') then
    raise exception using errcode = '22023', message = 'INVALID_CONTACT_CONFIGURATION';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 1));

  select * into v_contact from public.trusted_contacts where user_id = p_user_id for update;
  if found then
    update public.viewer_tokens token
      set revoked_at = coalesce(token.revoked_at, now())
      from public.alert_events event
      where event.trusted_contact_id = v_contact.id
        and token.alert_event_id = event.id;
    update public.trusted_contacts
      set name = pg_catalog.btrim(p_name), channel = p_channel,
        destination_ciphertext = p_destination_ciphertext,
        destination_fingerprint = p_destination_fingerprint,
        destination_key_version = p_destination_key_version::smallint,
        status = 'pending', confirmed_at = null
      where id = v_contact.id
      returning * into v_contact;
  else
    insert into public.trusted_contacts (
      user_id, name, channel, destination_ciphertext, destination_fingerprint,
      destination_key_version, status
    ) values (
      p_user_id, pg_catalog.btrim(p_name), p_channel,
      p_destination_ciphertext, p_destination_fingerprint,
      p_destination_key_version::smallint, 'pending'
    ) returning * into v_contact;
  end if;

  delete from public.contact_confirmation_tokens where trusted_contact_id = v_contact.id;
  insert into public.contact_confirmation_tokens (trusted_contact_id, token_hash, expires_at)
    values (v_contact.id, p_confirmation_token_hash, v_expires_at)
    returning id into v_token_id;
  insert into public.contact_verification_deliveries (
    trusted_contact_id, provider, provider_idempotency_key,
    payload_ciphertext, payload_key_version
  ) values (
    v_contact.id, p_delivery_provider,
    'contact/' || v_contact.id::text || '/verification/' || v_token_id::text,
    p_confirmation_payload_ciphertext, p_payload_key_version::smallint
  );

  return query select v_contact.id, v_contact.name, v_contact.channel,
    v_contact.status, v_expires_at;
end;
$$;

revoke all on function public.create_or_replace_contact(uuid, text, text, text, text, integer, bytea, text, integer, text) from public, anon, authenticated;
grant execute on function public.create_or_replace_contact(uuid, text, text, text, text, integer, bytea, text, integer, text) to service_role;

