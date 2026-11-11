-- Pear: жалобы и один закреплённый пост на пользователя.
-- Выполните целиком в SQL Editor СУЩЕСТВУЮЩЕГО проекта Supabase.
-- Требуются исходная схема Pear и 1-update-database.sql. Имеющиеся данные не удаляются.
begin;

create table if not exists public.pear_pinned_posts (
 author_id uuid primary key references public.profiles(id) on delete cascade,
 post_id uuid not null unique references public.posts(id) on delete cascade,
 pinned_at timestamptz not null default now()
);
alter table public.pear_pinned_posts enable row level security;
revoke all on public.pear_pinned_posts from public, anon, authenticated;
grant select on public.pear_pinned_posts to authenticated;
drop policy if exists pear_pins_read on public.pear_pinned_posts;
create policy pear_pins_read on public.pear_pinned_posts for select to authenticated using (true);

create or replace function public.pear_set_pinned_post(p_post_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_post_id is null then
  delete from public.pear_pinned_posts where author_id=uid;
 else
  if not exists(select 1 from public.posts where id=p_post_id and author_id=uid) then
   raise exception 'Only your own post can be pinned' using errcode='42501';
  end if;
  insert into public.pear_pinned_posts(author_id,post_id,pinned_at) values(uid,p_post_id,now())
  on conflict(author_id) do update set post_id=excluded.post_id,pinned_at=now();
 end if;
end $$;
revoke all on function public.pear_set_pinned_post(uuid) from public, anon, authenticated;
grant execute on function public.pear_set_pinned_post(uuid) to authenticated;

create table if not exists public.pear_post_reports (
 id uuid primary key default gen_random_uuid(),
 post_id uuid not null references public.posts(id) on delete cascade,
 reporter_id uuid not null references public.profiles(id) on delete cascade,
 reason text not null check (reason in ('Спам','Оскорбления или травля','Неприемлемый контент','Мошенничество','Другое')),
 details text not null default '' check (char_length(details)<=500),
 status text not null default 'open' check(status in ('open','resolved')),
 created_at timestamptz not null default now(),
 unique(post_id,reporter_id)
);
create index if not exists pear_post_reports_created_idx on public.pear_post_reports(created_at desc);
alter table public.pear_post_reports enable row level security;
revoke all on public.pear_post_reports from public, anon, authenticated;
grant select on public.pear_post_reports to authenticated;
drop policy if exists pear_reports_read_admin on public.pear_post_reports;
create policy pear_reports_read_admin on public.pear_post_reports for select to authenticated
 using (exists(select 1 from public.pear_admins a where a.user_id=(select auth.uid())));

create or replace function public.pear_report_post(p_post_id uuid,p_reason text,p_details text default '')
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if not exists(select 1 from public.posts where id=p_post_id and author_id<>uid) then
  raise exception 'Post unavailable or your own post' using errcode='42501';
 end if;
 if p_reason is null or p_reason not in ('Спам','Оскорбления или травля','Неприемлемый контент','Мошенничество','Другое') or char_length(coalesce(p_details,''))>500 then
  raise exception 'Invalid report';
 end if;
 insert into public.pear_post_reports(post_id,reporter_id,reason,details)
 values(p_post_id,uid,p_reason,trim(coalesce(p_details,'')));
end $$;
revoke all on function public.pear_report_post(uuid,text,text) from public, anon, authenticated;
grant execute on function public.pear_report_post(uuid,text,text) to authenticated;

create or replace function public.pear_resolve_post_report(p_report_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.pear_admins where user_id=auth.uid()) then
  raise exception 'Admin access required' using errcode='42501';
 end if;
 update public.pear_post_reports set status='resolved' where id=p_report_id;
 if not found then raise exception 'Report not found'; end if;
end $$;
revoke all on function public.pear_resolve_post_report(uuid) from public, anon, authenticated;
grant execute on function public.pear_resolve_post_report(uuid) to authenticated;
commit;
