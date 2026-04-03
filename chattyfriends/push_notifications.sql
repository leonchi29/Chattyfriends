-- Ejecuta esto en Supabase SQL Editor para activar push reales
-- El token configurado para este proyecto es:
-- chatty_push_5f9c3d0e7b8a4c4da1b3f6e9a2c7d5f1
create extension if not exists pg_net;

create table if not exists device_tokens (
  token text primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  username text,
  platform text,
  updated_at timestamptz not null default now()
);

alter table device_tokens enable row level security;

do $$ begin
  create policy "device tokens select" on device_tokens for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "device tokens insert" on device_tokens for insert with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "device tokens update" on device_tokens for update using (true) with check (true);
exception when duplicate_object then null; end $$;

create table if not exists call_notifications (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references profiles(id) on delete cascade,
  receiver_id uuid not null references profiles(id) on delete cascade,
  media_type text not null check (media_type in ('audio','video')),
  created_at timestamptz not null default now()
);

alter table call_notifications enable row level security;

do $$ begin
  create policy "call notifications select" on call_notifications for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "call notifications insert" on call_notifications for insert with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "call notifications delete" on call_notifications for delete using (true);
exception when duplicate_object then null; end $$;

create or replace function http_notify_chatty() returns trigger
language plpgsql
security definer
as $$
declare
  body jsonb;
begin
  body := jsonb_build_object(
    'table', TG_TABLE_NAME,
    'event', TG_OP,
    'record', to_jsonb(new)
  );

  -- Llama a la Supabase Edge Function (no requiere Firebase Blaze)
  perform net.http_post(
    url := 'https://xijruxarvehmlvzbnffn.supabase.co/functions/v1/push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer chatty_push_5f9c3d0e7b8a4c4da1b3f6e9a2c7d5f1'
    ),
    body := body
  );

  return new;
end;
$$;

drop trigger if exists trg_push_messages on messages;
create trigger trg_push_messages
after insert on messages
for each row execute function http_notify_chatty();

drop trigger if exists trg_push_group_messages on group_messages;
create trigger trg_push_group_messages
after insert on group_messages
for each row execute function http_notify_chatty();

drop trigger if exists trg_push_group_calls on group_calls;
create trigger trg_push_group_calls
after insert on group_calls
for each row execute function http_notify_chatty();

drop trigger if exists trg_push_call_notifications on call_notifications;
create trigger trg_push_call_notifications
after insert on call_notifications
for each row execute function http_notify_chatty();
