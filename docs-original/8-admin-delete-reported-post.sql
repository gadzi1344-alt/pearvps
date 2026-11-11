-- Pear: удаление поста администратором после рассмотрения жалобы.
-- Перед этим выполните 7-post-reports-pins.sql. Запускать целиком в SQL Editor.
begin;
create table if not exists public.pear_moderation_media_cleanup (
 id uuid primary key default gen_random_uuid(),
 post_id uuid not null unique,
 media_path text not null,
 created_at timestamptz not null default now()
);
alter table public.pear_moderation_media_cleanup enable row level security;
revoke all on public.pear_moderation_media_cleanup from public, anon, authenticated;
grant select on public.pear_moderation_media_cleanup to authenticated;
drop policy if exists pear_cleanup_read_admin on public.pear_moderation_media_cleanup;
create policy pear_cleanup_read_admin on public.pear_moderation_media_cleanup for select to authenticated
 using (exists(select 1 from public.pear_admins a where a.user_id=(select auth.uid())));

-- Удалять можно только те файлы удалённых постов, которые отмечены на очистку,
-- и только если они не используются в другом оставшемся посте.
-- Storage API требует также SELECT для удаления объекта.
drop policy if exists pear_admin_read_cleanup_media on storage.objects;
create policy pear_admin_read_cleanup_media on storage.objects for select to authenticated using (
 bucket_id='post-media'
 and exists(select 1 from public.pear_admins a where a.user_id=(select auth.uid()))
 and exists(select 1 from public.pear_moderation_media_cleanup c where c.media_path=name)
);
drop policy if exists pear_admin_delete_reported_media on storage.objects;
create policy pear_admin_delete_reported_media on storage.objects for delete to authenticated using (
 bucket_id='post-media'
 and exists(select 1 from public.pear_admins a where a.user_id=(select auth.uid()))
 and exists(select 1 from public.pear_moderation_media_cleanup c where c.media_path=name)
 and not exists(select 1 from public.posts p where p.media_path=name)
);

create or replace function public.pear_admin_delete_reported_post(p_report_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target public.posts%rowtype; cleanup_id uuid;
begin
 if auth.uid() is null or not exists(select 1 from public.pear_admins where user_id=auth.uid()) then
  raise exception 'Admin access required' using errcode='42501';
 end if;
 -- Locks post and report so two requests cannot both remove the same publication.
 select p.* into target from public.pear_post_reports r join public.posts p on p.id=r.post_id
 where r.id=p_report_id and r.status='resolved' for update of p,r;
 if not found then raise exception 'A resolved report and existing post are required'; end if;
 if target.media_path is not null then
  insert into public.pear_moderation_media_cleanup(post_id,media_path) values(target.id,target.media_path)
  on conflict(post_id) do update set media_path=excluded.media_path returning id into cleanup_id;
 end if;
 delete from public.posts where id=target.id;
 return jsonb_build_object('post_id',target.id,'cleanup_id',cleanup_id,'media_path',target.media_path);
end $$;
revoke all on function public.pear_admin_delete_reported_post(uuid) from public,anon,authenticated;
grant execute on function public.pear_admin_delete_reported_post(uuid) to authenticated;

-- Снимает задачу только после удаления файла или когда тот нужен другому посту.
create or replace function public.pear_admin_finish_media_cleanup(p_cleanup_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare target_path text;
begin
 if auth.uid() is null or not exists(select 1 from public.pear_admins where user_id=auth.uid()) then
  raise exception 'Admin access required' using errcode='42501'; end if;
 select media_path into target_path from public.pear_moderation_media_cleanup where id=p_cleanup_id for update;
 if not found then return; end if;
 if exists(select 1 from storage.objects where bucket_id='post-media' and name=target_path)
    and not exists(select 1 from public.posts where media_path=target_path) then
  raise exception 'Media still exists';
 end if;
 delete from public.pear_moderation_media_cleanup where id=p_cleanup_id;
end $$;
revoke all on function public.pear_admin_finish_media_cleanup(uuid) from public,anon,authenticated;
grant execute on function public.pear_admin_finish_media_cleanup(uuid) to authenticated;
commit;
