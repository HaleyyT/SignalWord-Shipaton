-- Invited/admin-created users may have no profile marker. Create only the
-- authenticated caller's profile on their explicit first profile request.
create or replace function public.signalword_profile(p_user_id uuid, p_display_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or auth.uid() is distinct from p_user_id then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if p_display_name is not null and char_length(btrim(p_display_name)) not between 1 and 80 then
    raise exception 'INVALID_PROFILE';
  end if;
  -- Serialize with deletion preparation before inspecting its durable tombstone.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));
  if exists(select 1 from public.pending_deletions where user_id = p_user_id)
     or exists(select 1 from public.profiles where id = p_user_id and deleted_at is not null) then
    raise exception 'ACCOUNT_DELETION_PENDING';
  end if;
  insert into public.profiles (id, display_name)
    select id, coalesce(btrim(p_display_name), 'SignalWord user')
    from auth.users where id = p_user_id and email_confirmed_at is not null
    on conflict (id) do nothing;
  if not exists(select 1 from public.profiles where id = p_user_id) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if p_display_name is not null then
    update public.profiles set display_name = btrim(p_display_name) where id = p_user_id;
  end if;
  return (select jsonb_build_object('displayName', display_name) from public.profiles where id = p_user_id);
end $$;
revoke all on function public.signalword_profile(uuid,text) from public, anon;
grant execute on function public.signalword_profile(uuid,text) to authenticated;
