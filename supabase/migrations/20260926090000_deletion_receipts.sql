-- A receipt capability survives deletion of the anonymous auth identity. It
-- contains no account data and lets a client settle a lost DELETE response.
create table public.deletion_receipts (
  receipt_hash bytea primary key check (octet_length(receipt_hash) = 32),
  deletion_id uuid not null default gen_random_uuid(),
  deleted_at timestamptz not null default now()
);
alter table public.deletion_receipts enable row level security;
revoke all on public.deletion_receipts from public, anon, authenticated;

create function public.delete_my_account(p_user_id uuid, p_receipt_hash bytea)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_deletion_id uuid;
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  if octet_length(p_receipt_hash) <> 32 then
    raise exception using errcode = '22023', message = 'INVALID_RECEIPT';
  end if;
  insert into public.deletion_receipts(receipt_hash) values (p_receipt_hash)
    returning deletion_id into v_deletion_id;
  delete from auth.users where id = p_user_id;
  return v_deletion_id;
end $$;
revoke all on function public.delete_my_account(uuid, bytea) from public;
grant execute on function public.delete_my_account(uuid, bytea) to authenticated;

create function public.find_deletion_receipt(p_receipt_hash bytea)
returns uuid language sql stable security definer set search_path = '' as $$
  select deletion_id from public.deletion_receipts where receipt_hash = p_receipt_hash;
$$;
revoke all on function public.find_deletion_receipt(bytea) from public;
grant execute on function public.find_deletion_receipt(bytea) to service_role;
