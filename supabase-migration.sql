create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  role text not null default 'client' check (role in ('owner', 'client')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    lower(coalesce(new.email, '')),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    case when lower(coalesce(new.email, '')) = 'njfilmes1@gmail.com' then 'owner' else 'client' end
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'owner'
  );
$$;

create table if not exists public.hub_snapshots (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  device_id text,
  updated_at timestamptz not null default now()
);

create table if not exists public.portfolio_projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  category text not null check (category in ('Vídeos', 'Fotografias', 'Drone')),
  image_url text not null default '',
  description text not null default '',
  location text not null default 'Bahia',
  year text not null default '',
  type text not null default 'Projeto autoral',
  featured boolean not null default false,
  video_url text,
  views_count integer not null default 0 check (views_count >= 0),
  likes_count integer not null default 0 check (likes_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  client_name text not null,
  client_email text not null,
  title text not null,
  status text not null default 'Orçamento' check (status in ('Orçamento', 'Aprovado', 'Em produção', 'Em edição', 'Entregue', 'Arquivado')),
  budget numeric(12,2) not null default 0,
  paid numeric(12,2) not null default 0,
  due_date date,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_files (
  id uuid primary key default gen_random_uuid(),
  client_project_id uuid not null references public.client_projects(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  file_name text not null,
  storage_path text not null unique,
  mime_type text not null default 'application/octet-stream',
  file_size bigint not null default 0,
  created_at timestamptz not null default now()
);

alter table public.portfolio_projects add column if not exists video_url text;
alter table public.portfolio_projects add column if not exists views_count integer not null default 0;
alter table public.portfolio_projects add column if not exists likes_count integer not null default 0;

alter table public.profiles enable row level security;
alter table public.hub_snapshots enable row level security;
alter table public.portfolio_projects enable row level security;
alter table public.client_projects enable row level security;
alter table public.client_files enable row level security;

grant usage on schema public to anon, authenticated;
grant select on public.portfolio_projects to anon, authenticated;
grant select on public.profiles, public.client_projects, public.client_files to authenticated;
grant all on public.hub_snapshots, public.portfolio_projects, public.client_projects, public.client_files to authenticated;

drop policy if exists profiles_select_self_or_owner on public.profiles;
create policy profiles_select_self_or_owner on public.profiles
for select using (id = auth.uid() or public.is_owner());

-- Não existe política de atualização para profiles: o cliente não pode alterar o próprio role.
-- A promoção para owner ocorre exclusivamente no trigger, com o e-mail definido acima.

drop policy if exists hub_snapshots_owner_all on public.hub_snapshots;
create policy hub_snapshots_owner_all on public.hub_snapshots
for all using (public.is_owner() and owner_id = auth.uid())
with check (public.is_owner() and owner_id = auth.uid());

drop policy if exists portfolio_public_read on public.portfolio_projects;
create policy portfolio_public_read on public.portfolio_projects
for select using (true);

drop policy if exists portfolio_owner_insert on public.portfolio_projects;
create policy portfolio_owner_insert on public.portfolio_projects
for insert with check (public.is_owner() and owner_id = auth.uid());

drop policy if exists portfolio_owner_update on public.portfolio_projects;
create policy portfolio_owner_update on public.portfolio_projects
for update using (public.is_owner() and owner_id = auth.uid())
with check (public.is_owner() and owner_id = auth.uid());

drop policy if exists portfolio_owner_delete on public.portfolio_projects;
create policy portfolio_owner_delete on public.portfolio_projects
for delete using (public.is_owner() and owner_id = auth.uid());

drop policy if exists client_projects_owner_all on public.client_projects;
create policy client_projects_owner_all on public.client_projects
for all using (public.is_owner() and owner_id = auth.uid())
with check (public.is_owner() and owner_id = auth.uid());

drop policy if exists client_projects_client_read on public.client_projects;
create policy client_projects_client_read on public.client_projects
for select using (lower(client_email) = lower(coalesce(auth.jwt() ->> 'email', '')));

drop policy if exists client_files_owner_all on public.client_files;
create policy client_files_owner_all on public.client_files
for all using (public.is_owner() and owner_id = auth.uid())
with check (public.is_owner() and owner_id = auth.uid());

drop policy if exists client_files_client_read on public.client_files;
create policy client_files_client_read on public.client_files
for select using (
  exists (
    select 1 from public.client_projects p
    where p.id = client_project_id
      and lower(p.client_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
);

insert into storage.buckets (id, name, public)
values ('portfolio-assets', 'portfolio-assets', true)
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public)
values ('client-deliveries', 'client-deliveries', false)
on conflict (id) do update set public = false;

drop policy if exists portfolio_assets_public_read on storage.objects;
create policy portfolio_assets_public_read on storage.objects
for select using (bucket_id = 'portfolio-assets');

drop policy if exists portfolio_assets_owner_insert on storage.objects;
create policy portfolio_assets_owner_insert on storage.objects
for insert with check (bucket_id = 'portfolio-assets' and public.is_owner());

drop policy if exists portfolio_assets_owner_update on storage.objects;
create policy portfolio_assets_owner_update on storage.objects
for update using (bucket_id = 'portfolio-assets' and public.is_owner())
with check (bucket_id = 'portfolio-assets' and public.is_owner());

drop policy if exists portfolio_assets_owner_delete on storage.objects;
create policy portfolio_assets_owner_delete on storage.objects
for delete using (bucket_id = 'portfolio-assets' and public.is_owner());

drop policy if exists client_deliveries_owner_insert on storage.objects;
create policy client_deliveries_owner_insert on storage.objects
for insert with check (bucket_id = 'client-deliveries' and public.is_owner());

drop policy if exists client_deliveries_owner_select on storage.objects;
create policy client_deliveries_owner_select on storage.objects
for select using (bucket_id = 'client-deliveries' and public.is_owner());

drop policy if exists client_deliveries_owner_update on storage.objects;
create policy client_deliveries_owner_update on storage.objects
for update using (bucket_id = 'client-deliveries' and public.is_owner())
with check (bucket_id = 'client-deliveries' and public.is_owner());

drop policy if exists client_deliveries_owner_delete on storage.objects;
create policy client_deliveries_owner_delete on storage.objects
for delete using (bucket_id = 'client-deliveries' and public.is_owner());

drop policy if exists client_deliveries_client_select on storage.objects;
create policy client_deliveries_client_select on storage.objects
for select using (
  bucket_id = 'client-deliveries'
  and name ~ '^[0-9a-fA-F-]{36}/'
  and exists (
    select 1 from public.client_projects p
    where p.id = split_part(name, '/', 1)::uuid
      and lower(p.client_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
);


-- Configuração editável da capa: leitura pública, alterações apenas pelo proprietário.
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
grant select on public.site_settings to anon, authenticated;
grant all on public.site_settings to authenticated;

drop policy if exists site_settings_public_read on public.site_settings;
create policy site_settings_public_read on public.site_settings
for select using (true);

drop policy if exists site_settings_owner_insert on public.site_settings;
create policy site_settings_owner_insert on public.site_settings
for insert with check (public.is_owner() and owner_id = auth.uid());

drop policy if exists site_settings_owner_update on public.site_settings;
create policy site_settings_owner_update on public.site_settings
for update using (public.is_owner() and owner_id = auth.uid())
with check (public.is_owner() and owner_id = auth.uid());

drop policy if exists site_settings_owner_delete on public.site_settings;
create policy site_settings_owner_delete on public.site_settings
for delete using (public.is_owner() and owner_id = auth.uid());

-- Contadores públicos simples. Não são métricas antifraude; a interface limita uma ação por navegador.
create or replace function public.increment_portfolio_view(project_id uuid)
returns integer
language sql
security definer
set search_path = public
as $$
  update public.portfolio_projects
  set views_count = views_count + 1, updated_at = now()
  where id = project_id
  returning views_count;
$$;

create or replace function public.increment_portfolio_like(project_id uuid)
returns integer
language sql
security definer
set search_path = public
as $$
  update public.portfolio_projects
  set likes_count = likes_count + 1, updated_at = now()
  where id = project_id
  returning likes_count;
$$;

revoke all on function public.increment_portfolio_view(uuid) from public;
grant execute on function public.increment_portfolio_view(uuid) to anon, authenticated;
revoke all on function public.increment_portfolio_like(uuid) from public;
grant execute on function public.increment_portfolio_like(uuid) to anon, authenticated;
