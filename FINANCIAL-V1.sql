-- NEXUS GROUP — FINANCIAL HISTORY / ADMIN NOTE / WALLET LEDGER FIX
-- Safe: does not delete balances or financial records.

-- 1) Make sure wallet request admin notes exist.
alter table public.wallet_requests
  add column if not exists admin_note text;

-- 2) Member-safe ledger reader. It exposes only the signed-in member's own ledger.
drop function if exists public.get_my_wallet_ledger();
create or replace function public.get_my_wallet_ledger()
returns table (
  id bigint,
  amount numeric,
  balance_after numeric,
  entry_type text,
  reason text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    wl.id,
    wl.amount::numeric,
    wl.balance_after::numeric,
    wl.entry_type::text,
    wl.reason::text,
    wl.created_at
  from public.wallet_ledger wl
  where wl.user_id = auth.uid()
  order by wl.created_at desc
  limit 200;
$$;

grant execute on function public.get_my_wallet_ledger() to authenticated;

-- 3) Total profits = manual profits (including welcome bonus) + referral commissions + machine income.
drop function if exists public.get_my_total_profits();
create or replace function public.get_my_total_profits()
returns numeric
language sql
security definer
set search_path = public
as $$
  select
    coalesce((
      select sum(mp.amount)
      from public.nexus_manual_profits mp
      where mp.user_id = auth.uid()
    ),0)
    + coalesce((
      select sum(rc.commission_amount)
      from public.nexus_referral_commissions rc
      where rc.referrer_id = auth.uid()
    ),0)
    + coalesce((
      select sum(coalesce(r.daily_income,0) * coalesce(r.last_paid_day,0))
      from public.nexus_machine_rentals r
      where r.user_id = auth.uid()
    ),0);
$$;

grant execute on function public.get_my_total_profits() to authenticated;

-- 4) Approval/rejection RPC: keep admin_note and record every approved wallet movement in wallet_ledger.
drop function if exists public.admin_process_wallet_request(bigint,boolean,text);
create or replace function public.admin_process_wallet_request(
  p_request_id bigint,
  p_approve boolean,
  p_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  w record;
  new_status text;
  v_balance numeric;
  v_note text := nullif(btrim(coalesce(p_note,'')), '');
  v_balance_after numeric;
begin
  if not public.is_admin() then
    raise exception 'admin_only';
  end if;

  select * into w
  from public.wallet_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'request_not_found';
  end if;

  if w.status <> 'pending' then
    raise exception 'request_already_processed';
  end if;

  if p_approve then
    if w.request_type = 'deposit' then
      insert into public.wallet_balances(user_id,balance)
      values(w.user_id,0)
      on conflict (user_id) do nothing;

      update public.wallet_balances
      set balance = coalesce(balance,0) + w.amount, updated_at = now()
      where user_id = w.user_id
      returning balance into v_balance_after;

      new_status := 'approved';

      insert into public.wallet_ledger(
        user_id, amount, balance_after, entry_type, reason, admin_id, created_at
      ) values (
        w.user_id, w.amount, v_balance_after, 'adjustment', 'إيداع', auth.uid(), now()
      );

    elsif w.request_type = 'withdraw' then
      select coalesce(balance,0) into v_balance
      from public.wallet_balances
      where user_id = w.user_id
      for update;

      if coalesce(v_balance,0) < w.amount then
        raise exception 'insufficient_balance';
      end if;

      update public.wallet_balances
      set balance = coalesce(balance,0) - w.amount, updated_at = now()
      where user_id = w.user_id
      returning balance into v_balance_after;

      new_status := 'approved';

      insert into public.wallet_ledger(
        user_id, amount, balance_after, entry_type, reason, admin_id, created_at
      ) values (
        w.user_id, -w.amount, v_balance_after, 'adjustment', 'سحب', auth.uid(), now()
      );

    else
      raise exception 'invalid_request_type';
    end if;
  else
    new_status := 'rejected';
  end if;

  update public.wallet_requests
  set status = new_status,
      admin_note = v_note
  where id = p_request_id;

  return json_build_object(
    'ok', true,
    'request_id', p_request_id,
    'status', new_status
  );
end;
$$;

grant execute on function public.admin_process_wallet_request(bigint,boolean,text) to authenticated;
