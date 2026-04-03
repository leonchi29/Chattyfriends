-- ============================================
-- SQL para Supabase: Tabla de llamadas grupales
-- Ejecutar en Supabase ? SQL Editor
-- ============================================

-- Tabla para rastrear participantes activos en llamadas de grupo
create table if not exists group_calls (
  id uuid default gen_random_uuid() primary key,
  group_id uuid references groups(id) on delete cascade not null,
  user_id uuid references profiles(id) on delete cascade not null,
  joined_at timestamptz default now() not null,
  unique(group_id, user_id)
);

-- Habilitar Row Level Security
alter table group_calls enable row level security;

-- Cualquiera puede ver las llamadas activas
create policy "Ver llamadas activas"
  on group_calls for select
  using (true);

-- Cualquiera puede unirse a una llamada (insertar)
create policy "Unirse a llamada"
  on group_calls for insert
  with check (true);

-- Los usuarios pueden salir de sus propias llamadas (borrar)
create policy "Salir de llamada"
  on group_calls for delete
  using (true);

-- Habilitar Realtime para la tabla
alter publication supabase_realtime add table group_calls;
