-- NJFILMES — migração complementar idempotente para projetos já existentes.
-- Preferencialmente execute supabase-migration.sql completo. Este arquivo corrige uma instalação anterior.

alter table if exists public.portfolio_projects add column if not exists video_url text;
alter table if exists public.portfolio_projects add column if not exists views_count integer not null default 0;
alter table if exists public.portfolio_projects add column if not exists likes_count integer not null default 0;

-- Impede que qualquer utilizador altere o próprio role para owner.
drop policy if exists profiles_update_self on public.profiles;

create table if not exists public.site_settings (
  id text primary key default 'main',
  owner_id uuid not null references auth.users(id) on delete cascade,
  hero_image_url text not null default '',
  hero_kicker text not null default 'Vídeo · Fotografia · Drone · Bahia',
  hero_title text not null default 'Vamos tirar',
  hero_emphasis text not null default 'sua ideia do papel?',
  hero_description text not null default 'Filmes, fotografias e imagens aéreas para histórias que pedem presença — da primeira ideia ao último frame.',
  hero_position text not null default '58% 50%',
  updated_at timestamptz not null default now()
);

alter table public.site_settings enable row level security;

grant usage on schema public to anon, authenticated;
grant select on public.portfolio_projects, public.site_settings to anon, authenticated;
grant select on public.profiles, public.client_projects, public.client_files to authenticated;
grant all on public.hub_snapshots, public.portfolio_projects, public.client_projects, public.client_files, public.site_settings to authenticated;
drop policy if exists site_settings_public_read on public.site_settings;
create policy site_settings_public_read on public.site_settings for select using (true);
drop policy if exists site_settings_owner_insert on public.site_settings;
create policy site_settings_owner_insert on public.site_settings for insert with check (public.is_owner() and owner_id = auth.uid());
drop policy if exists site_settings_owner_update on public.site_settings;
create policy site_settings_owner_update on public.site_settings for update using (public.is_owner() and owner_id = auth.uid()) with check (public.is_owner() and owner_id = auth.uid());
drop policy if exists site_settings_owner_delete on public.site_settings;
create policy site_settings_owner_delete on public.site_settings for delete using (public.is_owner() and owner_id = auth.uid());

create or replace function public.increment_portfolio_view(project_id uuid)
returns integer language sql security definer set search_path = public
as $$ update public.portfolio_projects set views_count = views_count + 1, updated_at = now() where id = project_id returning views_count; $$;
create or replace function public.increment_portfolio_like(project_id uuid)
returns integer language sql security definer set search_path = public
as $$ update public.portfolio_projects set likes_count = likes_count + 1, updated_at = now() where id = project_id returning likes_count; $$;
revoke all on function public.increment_portfolio_view(uuid) from public;
grant execute on function public.increment_portfolio_view(uuid) to anon, authenticated;
revoke all on function public.increment_portfolio_like(uuid) from public;
grant execute on function public.increment_portfolio_like(uuid) to anon, authenticated;

-- Para instalações antigas, confirme que handle_new_user e is_owner continuam no arquivo principal.
-- Exemplo de carga inicial da capa:
-- insert into public.site_settings (owner_id, hero_image_url) values ('OWNER_UUID', './assets/IMG_6223.webp') on conflict (id) do nothing;
