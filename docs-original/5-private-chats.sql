-- Pear: private one-to-one chats. Back up first; run after prior updates.
-- No old tables are dropped and existing posts/accounts are retained.
create table if not exists public.pear_chats (
 id uuid primary key default gen_random_uuid(),
 user_a uuid not null references public.profiles(id) on delete cascade,
 user_b uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now(),
 unique(user_a,user_b), check(user_a < user_b)
);
create table if not exists public.pear_chat_messages (
 id uuid primary key default gen_random_uuid(),
 chat_id uuid not null references public.pear_chats(id) on delete cascade,
 sender_id uuid not null references public.profiles(id) on delete cascade,
 body text not null default '' check(char_length(body) <= 2000),
 image_path text,
 created_at timestamptz not null default now(),
 read_at timestamptz,
 check(char_length(btrim(body)) > 0 or image_path is not null)
);
create index if not exists pear_chat_msgs_order_idx on public.pear_chat_messages(chat_id,created_at desc,id desc);
create index if not exists pear_chat_msgs_unread_idx on public.pear_chat_messages(chat_id,sender_id) where read_at is null;
alter table public.pear_chats enable row level security;
alter table public.pear_chat_messages enable row level security;
revoke all on public.pear_chats, public.pear_chat_messages from public, anon, authenticated;
grant select on public.pear_chats, public.pear_chat_messages to authenticated;
grant insert(chat_id,sender_id,body,image_path) on public.pear_chat_messages to authenticated;

-- Membership is always checked against the authenticated user, never the UI.
create or replace function public.pear_is_chat_member(p_chat uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.pear_chats c where c.id=p_chat and auth.uid() in (c.user_a,c.user_b));
$$;
revoke all on function public.pear_is_chat_member(uuid) from public, anon, authenticated;
grant execute on function public.pear_is_chat_member(uuid) to authenticated;

create or replace function public.pear_is_chat_member_text(p_chat text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if p_chat is null or p_chat !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
 return public.pear_is_chat_member(p_chat::uuid);
end $$;
revoke all on function public.pear_is_chat_member_text(text) from public, anon, authenticated;
grant execute on function public.pear_is_chat_member_text(text) to authenticated;

drop policy if exists "chat members read" on public.pear_chats;
create policy "chat members read" on public.pear_chats for select to authenticated using (auth.uid() in (user_a,user_b));
drop policy if exists "chat messages read" on public.pear_chat_messages;
create policy "chat messages read" on public.pear_chat_messages for select to authenticated using (public.pear_is_chat_member(chat_id));
drop policy if exists "chat messages send" on public.pear_chat_messages;
create policy "chat messages send" on public.pear_chat_messages for insert to authenticated with check (
 sender_id=auth.uid() and public.pear_is_chat_member(chat_id) and read_at is null
 and (image_path is null or (
   (storage.foldername(image_path))[1]=auth.uid()::text and (storage.foldername(image_path))[2]=chat_id::text
   and array_length(storage.foldername(image_path),1)=2
   and exists(select 1 from storage.objects o where o.bucket_id='chat-media' and o.name=image_path)
 ))
);

create or replace function public.pear_start_chat(p_other uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare a uuid; b uuid; result uuid;
begin
 if auth.uid() is null or p_other is null or auth.uid()=p_other or not exists(select 1 from public.profiles where id=p_other) or not exists(select 1 from public.profiles where id=auth.uid()) then raise exception 'Cannot start chat' using errcode='42501'; end if;
 a:=least(auth.uid(),p_other); b:=greatest(auth.uid(),p_other);
 insert into public.pear_chats(user_a,user_b) values(a,b)
 on conflict(user_a,user_b) do update set user_a=excluded.user_a returning id into result;
 return result;
end $$;
revoke all on function public.pear_start_chat(uuid) from public, anon, authenticated;
grant execute on function public.pear_start_chat(uuid) to authenticated;

-- Mark only the messages actually displayed; caller must be the recipient.
create or replace function public.pear_mark_chat_read(p_chat uuid,p_ids uuid[])
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.pear_is_chat_member(p_chat) then raise exception 'Access denied' using errcode='42501'; end if;
 if coalesce(array_length(p_ids,1),0)>200 then raise exception 'Too many message ids'; end if;
 update public.pear_chat_messages m set read_at=now() where m.chat_id=p_chat and m.id=any(p_ids) and m.sender_id<>auth.uid() and m.read_at is null;
end $$;
revoke all on function public.pear_mark_chat_read(uuid,uuid[]) from public, anon, authenticated;
grant execute on function public.pear_mark_chat_read(uuid,uuid[]) to authenticated;

create or replace function public.pear_list_chats()
returns table(chat_id uuid,other_id uuid,display_name text,username text,avatar_path text,last_body text,last_image boolean,last_at timestamptz,unread bigint)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 return query
 select c.id,p.id,p.display_name,p.username,p.avatar_path,l.body,coalesce(l.image_path is not null,false),l.created_at,
   (select count(*) from public.pear_chat_messages m2 where m2.chat_id=c.id and m2.sender_id<>auth.uid() and m2.read_at is null)
 from public.pear_chats c
 join public.profiles p on p.id=case when c.user_a=auth.uid() then c.user_b else c.user_a end
 left join lateral (select m.body,m.image_path,m.created_at from public.pear_chat_messages m where m.chat_id=c.id order by m.created_at desc,m.id desc limit 1) l on true
 where auth.uid() in (c.user_a,c.user_b)
 order by l.created_at desc nulls last,c.created_at desc limit 100;
end $$;
revoke all on function public.pear_list_chats() from public, anon, authenticated;
grant execute on function public.pear_list_chats() to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('chat-media','chat-media',false,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
 on conflict(id) do nothing;
-- Fail rather than silently exposing chat photos through an existing public bucket.
do $$ begin if exists(select 1 from storage.buckets where id='chat-media' and public=true) then raise exception 'chat-media must be a private bucket'; end if; end $$;

drop policy if exists "chat media upload" on storage.objects;
create policy "chat media upload" on storage.objects for insert to authenticated with check (
 bucket_id='chat-media' and (storage.foldername(name))[1]=auth.uid()::text
 and array_length(storage.foldername(name),1)=2
 and public.pear_is_chat_member_text((storage.foldername(name))[2])
 and exists(select 1 from public.profiles p where p.id=auth.uid())
);
drop policy if exists "chat media read" on storage.objects;
create policy "chat media read" on storage.objects for select to authenticated using (
 bucket_id='chat-media' and public.pear_is_chat_member_text((storage.foldername(name))[2])
 and ((storage.foldername(name))[1]=auth.uid()::text or exists(
   select 1 from public.pear_chat_messages m where m.image_path=storage.objects.name and public.pear_is_chat_member(m.chat_id)
 ))
);
drop policy if exists "chat media cleanup" on storage.objects;
create policy "chat media cleanup" on storage.objects for delete to authenticated using (
 bucket_id='chat-media' and (storage.foldername(name))[1]=auth.uid()::text and public.pear_is_chat_member_text((storage.foldername(name))[2])
);
-- Realtime is optional: the client also polls. RLS applies to delivery.
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pear_chat_messages') then
  alter publication supabase_realtime add table public.pear_chat_messages;
 end if;
end $$;
