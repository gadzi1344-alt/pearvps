-- Pear: статистика активности. Запустите один раз в SQL Editor после резервной копии.
-- Не запускайте schema.sql повторно и не удаляйте существующие данные.
create table if not exists public.pear_presence (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 last_seen timestamptz not null default now()
);
alter table public.pear_presence enable row level security;
revoke all on table public.pear_presence from public, anon, authenticated;

create or replace function public.pear_heartbeat()
returns void language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid()) then
  raise exception 'Authentication required' using errcode='42501';
 end if;
 insert into public.pear_presence(user_id,last_seen) values(auth.uid(),now())
 on conflict(user_id) do update set last_seen=excluded.last_seen
 where public.pear_presence.last_seen < now() - interval '30 seconds';
end $$;
revoke all on function public.pear_heartbeat() from public, anon, authenticated;
grant execute on function public.pear_heartbeat() to authenticated;

create or replace function public.pear_admin_stats()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.pear_admins where user_id=auth.uid()) then
  raise exception 'Admin access required' using errcode='42501';
 end if;
 return jsonb_build_object(
  'online', (select count(*) from public.pear_presence where last_seen >= now() - interval '5 minutes'),
  'users', (select count(*) from public.profiles),
  'posts', (select count(*) from public.posts),
  'new_users_24h', (select count(*) from public.profiles where created_at >= now() - interval '24 hours'),
  'verified', (select count(*) from public.pear_verified_profiles)
 );
end $$;
revoke all on function public.pear_admin_stats() from public, anon, authenticated;
grant execute on function public.pear_admin_stats() to authenticated;

-- A still-unexpired JWT of a deleted user must not create new storage files.
drop policy if exists "post media owner upload" on storage.objects;
create policy "post media owner upload" on storage.objects for insert to authenticated
 with check (bucket_id='post-media' and (storage.foldername(name))[1]=(select auth.uid())::text
 and exists (select 1 from public.profiles p where p.id=(select auth.uid())));
drop policy if exists "pear_profile_media_insert_self" on storage.objects;
create policy "pear_profile_media_insert_self" on storage.objects for insert to authenticated
 with check (bucket_id='profile-media' and (storage.foldername(name))[1]=(select auth.uid())::text
 and exists (select 1 from public.profiles p where p.id=(select auth.uid())));
