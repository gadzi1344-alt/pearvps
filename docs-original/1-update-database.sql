-- PEAR: безопасное расширение существующей базы. Это НЕ schema.sql.
-- Запустите этот файл в SQL Editor существующего Supabase-проекта один раз.
-- Он не удаляет имеющиеся профили, посты или файлы.

alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists banner_path text;
do $$ begin
 if not exists (select 1 from pg_constraint where conname='pear_avatar_owner_path' and conrelid='public.profiles'::regclass) then
  alter table public.profiles add constraint pear_avatar_owner_path check (avatar_path is null or (length(avatar_path)<=300 and split_part(avatar_path,'/',1)=id::text));
 end if;
 if not exists (select 1 from pg_constraint where conname='pear_banner_owner_path' and conrelid='public.profiles'::regclass) then
  alter table public.profiles add constraint pear_banner_owner_path check (banner_path is null or (length(banner_path)<=300 and split_part(banner_path,'/',1)=id::text));
 end if;
end $$;

create table if not exists public.pear_admins (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);
create table if not exists public.pear_verified_profiles (
 profile_id uuid primary key references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);
alter table public.pear_admins enable row level security;
alter table public.pear_verified_profiles enable row level security;
revoke all on public.pear_admins from public, anon, authenticated;
revoke all on public.pear_verified_profiles from public, anon, authenticated;
grant select on public.pear_admins, public.pear_verified_profiles to authenticated;
drop policy if exists "pear_admins_select_self" on public.pear_admins;
create policy "pear_admins_select_self" on public.pear_admins for select to authenticated using (user_id=(select auth.uid()));
drop policy if exists "pear_verified_read" on public.pear_verified_profiles;
create policy "pear_verified_read" on public.pear_verified_profiles for select to authenticated using (true);

-- Only the logged-in admin can assign or revoke badges; never trust the UI or mutable username.
create or replace function public.pear_set_verified(p_profile_id uuid,p_verified boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null or not exists (select 1 from public.pear_admins where user_id=auth.uid()) then
  raise exception 'Admin access required' using errcode='42501';
 end if;
 if p_profile_id is null or p_verified is null then
  raise exception 'Profile and status are required';
 end if;
 if p_verified then
  insert into public.pear_verified_profiles(profile_id) values (p_profile_id) on conflict(profile_id) do nothing;
 else
  delete from public.pear_verified_profiles where profile_id=p_profile_id;
 end if;
end $$;
revoke all on function public.pear_set_verified(uuid,boolean) from public, anon, authenticated;
grant execute on function public.pear_set_verified(uuid,boolean) to authenticated;

-- Avatar and banner files: public URLs, max 5 MiB, only images.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('profile-media','profile-media',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do nothing;
drop policy if exists "pear_profile_media_insert_self" on storage.objects;
create policy "pear_profile_media_insert_self" on storage.objects for insert to authenticated
 with check (bucket_id='profile-media' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "pear_profile_media_delete_self" on storage.objects;
create policy "pear_profile_media_delete_self" on storage.objects for delete to authenticated
 using (bucket_id='profile-media' and (storage.foldername(name))[1]=(select auth.uid())::text);

-- If Realtime is present, enable updates of verification status; polling is a fallback.
do $$ begin
 if exists (select 1 from pg_publication where pubname='supabase_realtime') and
    not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pear_verified_profiles') then
  alter publication supabase_realtime add table public.pear_verified_profiles;
 end if;
end $$;
