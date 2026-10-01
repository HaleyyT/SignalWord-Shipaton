-- Delivery material comes exclusively from the authenticated Edge API.
-- Wrappers establish its verified subject for nested ownership checks.
do $migration$
declare f record; definition text; args text; gateway text;
begin
 for f in select p.oid,p.proname,p.proargnames,p.pronargs,p.proretset from pg_proc p
 join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('create_or_reuse_alert','create_routed_alert','change_check_in') loop
  gateway := 'gateway_' || f.proname;
  select string_agg(quote_ident(name),', ' order by ord) into args
   from unnest(f.proargnames[1:f.pronargs]) with ordinality a(name,ord);
  definition := format('create function public.%I(%s) returns %s language plpgsql security definer set search_path = '''' as $body$ begin
    perform set_config(''request.jwt.claim.sub'', p_user_id::text, true);
    perform set_config(''request.jwt.claims'', jsonb_build_object(''sub'',p_user_id,''role'',''authenticated'')::text, true);
    %s public.%I(%s);
  end $body$',gateway,pg_get_function_arguments(f.oid),pg_get_function_result(f.oid),
  case when f.proretset then 'return query select * from' else 'return' end,f.proname,args);
  execute definition;
  execute format('revoke all on function public.%I(%s) from public,anon,authenticated',gateway,pg_get_function_identity_arguments(f.oid));
  execute format('grant execute on function public.%I(%s) to service_role',gateway,pg_get_function_identity_arguments(f.oid));
 end loop;
 -- Include all legacy overloads so direct access cannot bypass the API.
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('create_or_reuse_alert','create_or_reuse_alert_legacy','create_routed_alert','change_check_in') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.oid::regprocedure);
 end loop;
end $migration$;
