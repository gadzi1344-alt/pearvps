-- PEAR: ответы на комментарии и персональные уведомления. Выполняйте в существующем проекте.
begin;
alter table public.comments add column if not exists parent_id uuid references public.comments(id) on delete cascade;
create index if not exists pear_comments_parent_idx on public.comments(parent_id);
create or replace function public.pear_validate_comment_reply() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.parent_id is not null and not exists(select 1 from public.comments c where c.id=new.parent_id and c.post_id=new.post_id) then
  raise exception 'Reply must refer to a comment on the same post';
 end if;
 return new;
end $$;
drop trigger if exists pear_comment_parent_validate on public.comments;
create trigger pear_comment_parent_validate before insert or update of parent_id,post_id on public.comments for each row execute function public.pear_validate_comment_reply();

create table if not exists public.pear_notifications (
 id uuid primary key default gen_random_uuid(),
 recipient_id uuid not null references public.profiles(id) on delete cascade,
 actor_id uuid not null references public.profiles(id) on delete cascade,
 kind text not null check(kind in ('like','follow','comment','reply')),
 post_id uuid references public.posts(id) on delete cascade,
 comment_id uuid references public.comments(id) on delete cascade,
 created_at timestamptz not null default now(),
 read_at timestamptz,
 check(recipient_id <> actor_id)
);
create index if not exists pear_notifications_inbox_idx on public.pear_notifications(recipient_id,created_at desc);
create index if not exists pear_notifications_unread_idx on public.pear_notifications(recipient_id) where read_at is null;
alter table public.pear_notifications enable row level security;
revoke all on public.pear_notifications from public,anon,authenticated;
grant select on public.pear_notifications to authenticated;
drop policy if exists pear_notifications_read_self on public.pear_notifications;
create policy pear_notifications_read_self on public.pear_notifications for select to authenticated using(recipient_id=(select auth.uid()));

create or replace function public.pear_notification_from_like() returns trigger language plpgsql security definer set search_path='' as $$
declare owner_id uuid;
begin
 if tg_op='DELETE' then
  delete from public.pear_notifications where kind='like' and actor_id=old.user_id and post_id=old.post_id;
  return old;
 end if;
 select author_id into owner_id from public.posts where id=new.post_id;
 if owner_id is not null and owner_id<>new.user_id then
  insert into public.pear_notifications(recipient_id,actor_id,kind,post_id) values(owner_id,new.user_id,'like',new.post_id);
 end if;return new;
end $$;
drop trigger if exists pear_like_notification on public.likes;
create trigger pear_like_notification after insert or delete on public.likes for each row execute function public.pear_notification_from_like();

create or replace function public.pear_notification_from_follow() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='DELETE' then
  delete from public.pear_notifications where kind='follow' and actor_id=old.follower_id and recipient_id=old.following_id;
  return old;
 end if;
 if new.follower_id<>new.following_id then
  insert into public.pear_notifications(recipient_id,actor_id,kind) values(new.following_id,new.follower_id,'follow');
 end if;return new;
end $$;
drop trigger if exists pear_follow_notification on public.follows;
create trigger pear_follow_notification after insert or delete on public.follows for each row execute function public.pear_notification_from_follow();

create or replace function public.pear_notification_from_comment() returns trigger language plpgsql security definer set search_path='' as $$
declare parent_author uuid;post_author uuid;
begin
 select author_id into post_author from public.posts where id=new.post_id;
 if new.parent_id is not null then
  select author_id into parent_author from public.comments where id=new.parent_id;
  if parent_author is not null and parent_author<>new.author_id then
   insert into public.pear_notifications(recipient_id,actor_id,kind,post_id,comment_id) values(parent_author,new.author_id,'reply',new.post_id,new.id);
  end if;
 end if;
 if post_author is not null and post_author<>new.author_id and post_author is distinct from parent_author then
  insert into public.pear_notifications(recipient_id,actor_id,kind,post_id,comment_id) values(post_author,new.author_id,'comment',new.post_id,new.id);
 end if;return new;
end $$;
drop trigger if exists pear_comment_notification on public.comments;
create trigger pear_comment_notification after insert on public.comments for each row execute function public.pear_notification_from_comment();

create or replace function public.pear_mark_notifications_read(p_id uuid default null) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 update public.pear_notifications set read_at=now() where recipient_id=auth.uid() and read_at is null and (p_id is null or id=p_id);
end $$;
revoke all on function public.pear_mark_notifications_read(uuid) from public,anon,authenticated;
grant execute on function public.pear_mark_notifications_read(uuid) to authenticated;
-- Realtime is optional; polling continues if the publication isn't available.
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pear_notifications') then
  begin
   alter publication supabase_realtime add table public.pear_notifications;
  exception when insufficient_privilege or object_not_in_prerequisite_state then
   raise notice 'Realtime unavailable; notifications will use polling';
  end;
 end if;
end $$;
commit;
