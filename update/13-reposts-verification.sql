-- Репосты и заявки. Только для совместимой существующей схемы Pear.
-- Сначала резервная копия и проверка на тестовой базе.
begin;
do $$ begin
 if to_regclass('public.pear_notifications') is null or to_regclass('public.pear_admins') is null or to_regclass('public.pear_verified_profiles') is null or to_regclass('public.posts') is null then raise exception 'Не найдены необходимые таблицы Pear'; end if;
 if not exists(select 1 from pg_constraint where conrelid='public.pear_notifications'::regclass and conname='pear_notifications_kind_check' and contype='c') then raise exception 'Неожиданное ограничение типов уведомлений: проверьте схему вручную'; end if;
end $$;
alter table public.pear_notifications drop constraint pear_notifications_kind_check;
alter table public.pear_notifications add constraint pear_notifications_kind_check check(kind in ('like','follow','comment','reply','repost'));
create table public.pear_reposts (
 user_id uuid not null references public.profiles(id) on delete cascade,
 post_id uuid not null references public.posts(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(user_id,post_id)
);
create index pear_reposts_post_idx on public.pear_reposts(post_id);
create index pear_reposts_user_time_idx on public.pear_reposts(user_id,created_at desc);
alter table public.pear_reposts enable row level security;
revoke all on public.pear_reposts from public,anon,authenticated;
grant select,insert,delete on public.pear_reposts to authenticated;
create policy pear_reposts_read on public.pear_reposts for select to authenticated using (true);
create policy pear_reposts_insert_self on public.pear_reposts for insert to authenticated with check (user_id=(select auth.uid()));
create policy pear_reposts_delete_self on public.pear_reposts for delete to authenticated using (user_id=(select auth.uid()));
create function public.pear_notify_repost() returns trigger language plpgsql security definer set search_path='' as $$
declare owner_id uuid;
begin
 if tg_op='DELETE' then delete from public.pear_notifications where kind='repost' and actor_id=old.user_id and post_id=old.post_id; return old; end if;
 select author_id into owner_id from public.posts where id=new.post_id;
 if owner_id is not null and owner_id<>new.user_id then insert into public.pear_notifications(recipient_id,actor_id,kind,post_id) values(owner_id,new.user_id,'repost',new.post_id); end if;
 return new;
end $$;
revoke all on function public.pear_notify_repost() from public,anon,authenticated;
create trigger pear_repost_notification after insert or delete on public.pear_reposts for each row execute function public.pear_notify_repost();
create table public.pear_verification_requests (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 identity_description text not null check(char_length(trim(identity_description)) between 10 and 1000),
 links text not null check(char_length(trim(links)) between 8 and 2000),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(), reviewed_at timestamptz,
 reviewer_id uuid references public.profiles(id) on delete set null
);
create unique index pear_verification_one_pending on public.pear_verification_requests(user_id) where status='pending';
alter table public.pear_verification_requests enable row level security;
revoke all on public.pear_verification_requests from public,anon,authenticated;
grant select on public.pear_verification_requests to authenticated;
create policy pear_verification_read_own_or_admin on public.pear_verification_requests for select to authenticated using (user_id=(select auth.uid()) or exists(select 1 from public.pear_admins where user_id=(select auth.uid())));
create function public.pear_request_verification(p_identity text,p_links text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if exists(select 1 from public.pear_verified_profiles where profile_id=auth.uid()) then raise exception 'Profile already verified'; end if;
 if p_identity is null or p_links is null or char_length(trim(p_identity)) not between 10 and 1000 or char_length(trim(p_links)) not between 8 and 2000 then raise exception 'Invalid application'; end if;
 insert into public.pear_verification_requests(user_id,identity_description,links) values(auth.uid(),trim(p_identity),trim(p_links)) returning id into result;
 return result;
end $$;
revoke all on function public.pear_request_verification(text,text) from public,anon,authenticated;
grant execute on function public.pear_request_verification(text,text) to authenticated;
create function public.pear_review_verification(p_request_id uuid,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
declare applicant uuid;
begin
 if auth.uid() is null or not exists(select 1 from public.pear_admins where user_id=auth.uid()) then raise exception 'Admin access required' using errcode='42501'; end if;
 if p_approve is null then raise exception 'Decision required'; end if;
 update public.pear_verification_requests set status=case when p_approve then 'approved' else 'rejected' end,reviewed_at=now(),reviewer_id=auth.uid() where id=p_request_id and status='pending' returning user_id into applicant;
 if applicant is null then raise exception 'Application not found or already reviewed'; end if;
 if p_approve then insert into public.pear_verified_profiles(profile_id,badge_type) values(applicant,'blue') on conflict(profile_id) do nothing; end if;
end $$;
revoke all on function public.pear_review_verification(uuid,boolean) from public,anon,authenticated;
grant execute on function public.pear_review_verification(uuid,boolean) to authenticated;
commit;
