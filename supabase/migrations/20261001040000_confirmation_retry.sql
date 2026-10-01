-- A lost HTTP response must not make a completed confirmation look invalid.
-- The capability grants consent once; retries only report the existing consent.
create or replace function public.confirm_contact(p_token_hash bytea)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.contact_confirmation_tokens%rowtype;
  v_status text;
begin
  -- Keep the token -> contact lock order used by recipient withdrawal. A retry
  -- racing withdrawal cannot change a disabled contact back to confirmed.
  select * into v_token
  from public.contact_confirmation_tokens
  where token_hash = p_token_hash and expires_at > now()
  for update;
  if not found then return false; end if;

  select status into v_status from public.trusted_contacts
  where id = v_token.trusted_contact_id
  for update;
  if not found then return false; end if;

  if v_token.consumed_at is not null then
    return v_status = 'confirmed';
  end if;
  if v_status <> 'pending' then return false; end if;

  update public.contact_confirmation_tokens set consumed_at = now()
  where id = v_token.id;
  update public.trusted_contacts set status = 'confirmed', confirmed_at = now()
  where id = v_token.trusted_contact_id and status = 'pending';
  return found;
end;
$$;
-- CREATE OR REPLACE preserves the existing anon/authenticated grants. No new
-- role receives access, and replacement/deletion still removes old tokens.
