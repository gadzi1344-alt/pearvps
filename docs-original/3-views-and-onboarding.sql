-- Для уже работающей Pear с профилями и галочками.
-- НЕ повторяйте старые schema.sql и 1-update-database.sql.
-- Перед изменением рекомендуется резервная копия.
-- Существующие аккаунты сохраняют свои ники и пропускают экран регистрации.
alter table public.profiles add column if not exists username_confirmed boolean not null default true;
alter table public.profiles alter column username_confirmed set default false;

-- Один учтённый просмотр на одного вошедшего пользователя и публикацию.
-- Собственные публикации автора не учитываются.
create table if not exists public.pear_post_views (
 post_id uuid not null references public.posts(id) on delete cascade,
 viewer_id uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(post_id,viewer_id)
);
alter table public.pear_post_views enable row level security;
revoke all on public.pear_post_views from public, anon, authenticated;

-- The authenticated caller can record only their own view; no viewer list is exposed.
create or replace function public.pear_record_post_view(p_post_id uuid)
returns bigint language plpgsql security definer set search_path = '' as $$
declare owner_id uuid; total bigint;
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 select p.author_id into owner_id from public.posts p where p.id=p_post_id;
 if not found then raise exception 'Post not found'; end if;
 if owner_id <> auth.uid() then
  insert into public.pear_post_views(post_id,viewer_id) values(p_post_id,auth.uid()) on conflict(post_id,viewer_id) do nothing;
 end if;
 select count(*) into total from public.pear_post_views v where v.post_id=p_post_id;
 return total;
end $$;
revoke all on function public.pear_record_post_view(uuid) from public, anon, authenticated;
grant execute on function public.pear_record_post_view(uuid) to authenticated;

-- Only aggregates, for at most 100 post IDs at a time. No viewer identities are returned.
create or replace function public.pear_post_view_counts(p_post_ids uuid[])
returns table(post_id uuid,total bigint) language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if coalesce(array_length(p_post_ids,1),0)>100 then raise exception 'Too many posts'; end if;
 return query select v.post_id,count(*)::bigint from public.pear_post_views v where v.post_id=any(p_post_ids) group by v.post_id;
end $$;
revoke all on function public.pear_post_view_counts(uuid[]) from public, anon, authenticated;
grant execute on function public.pear_post_view_counts(uuid[]) to authenticated;
