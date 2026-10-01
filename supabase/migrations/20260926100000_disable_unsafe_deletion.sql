-- The legacy deletion RPC cannot recover a lost response. Fail it closed.
revoke execute on function public.delete_my_account(uuid) from authenticated;
