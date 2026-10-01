-- Provision the minimal application-owned profile for SignalWord-created auth
-- identities. The marker avoids changing unrelated/admin-created identities.

create function public.bootstrap_signalword_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(new.raw_user_meta_data ->> 'signalword_client', 'false') = 'true' then
    insert into public.profiles (id, display_name)
    values (new.id, 'SignalWord user')
    on conflict (id) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.bootstrap_signalword_profile() from public;

create trigger bootstrap_signalword_profile_after_auth_insert
after insert on auth.users
for each row execute function public.bootstrap_signalword_profile();
