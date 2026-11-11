-- Выполняйте в новом проекте Supabase через SQL Editor, от имени владельца проекта.
create extension if not exists pgcrypto;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text not null unique check (username ~ '^[a-zA-Z0-9_]{3,24}$'),
 display_name text not null check (char_length(display_name) between 1 and 60),
 bio text not null default '' check (char_length(bio) <= 240),
 created_at timestamptz not null default now()
);
create table public.posts (
 id uuid primary key default gen_random_uuid(),
 author_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
 body text not null default '' check (char_length(body) <= 1000),
 media_path text check (media_path is null or (length(media_path) <= 300 and split_part(media_path, '/', 1) = author_id::text)),
 category text not null default 'Общее' check (category in ('Общее','Игры','Технологии','Творчество')),
 created_at timestamptz not null default now(),
 check (char_length(trim(body)) > 0 or media_path is not null)
);
create table public.likes (
 user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
 post_id uuid not null references public.posts(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(user_id,post_id)
);
create table public.comments (
 id uuid primary key default gen_random_uuid(),
 post_id uuid not null references public.posts(id) on delete cascade,
 author_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
 body text not null check (char_length(trim(body)) between 1 and 500),
 created_at timestamptz not null default now()
);
create table public.follows (
 follower_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
 following_id uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(follower_id,following_id), check(follower_id <> following_id)
);
create index posts_created_idx on public.posts(created_at desc);
create index posts_author_idx on public.posts(author_id, created_at desc);
create index comments_post_idx on public.comments(post_id,created_at);
create index likes_post_idx on public.likes(post_id);
create index follows_following_idx on public.follows(following_id);

-- Initial username is 21 chars, unique without requiring personal data from providers.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into public.profiles(id,username,display_name)
 values(new.id, 'u_' || substr(replace(new.id::text,'-',''),1,20), left(coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'),''),nullif(trim(new.raw_user_meta_data->>'name'),''),'Новый пользователь'),60));
 return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.likes enable row level security;
alter table public.comments enable row level security;
alter table public.follows enable row level security;
-- Public feed visible only to signed-in users.
create policy "profiles read" on public.profiles for select to authenticated using (true);
create policy "profiles edit self" on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);
create policy "posts read" on public.posts for select to authenticated using (true);
create policy "posts create self" on public.posts for insert to authenticated with check ((select auth.uid()) = author_id);
create policy "posts delete self" on public.posts for delete to authenticated using ((select auth.uid()) = author_id);
create policy "likes read" on public.likes for select to authenticated using (true);
create policy "likes create self" on public.likes for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "likes delete self" on public.likes for delete to authenticated using ((select auth.uid()) = user_id);
create policy "comments read" on public.comments for select to authenticated using (true);
create policy "comments create self" on public.comments for insert to authenticated with check ((select auth.uid()) = author_id);
create policy "comments delete self" on public.comments for delete to authenticated using ((select auth.uid()) = author_id);
create policy "follows read" on public.follows for select to authenticated using (true);
create policy "follows create self" on public.follows for insert to authenticated with check ((select auth.uid()) = follower_id);
create policy "follows delete self" on public.follows for delete to authenticated using ((select auth.uid()) = follower_id);
grant usage on schema public to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, delete on public.posts, public.likes, public.comments, public.follows to authenticated;

-- Public bucket: anyone who has a file URL can see the image. Do not upload private content.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('post-media','post-media',true,5242880,array['image/jpeg','image/png','image/webp','image/gif']);
create policy "post media owner upload" on storage.objects for insert to authenticated
 with check (bucket_id='post-media' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "post media owner delete" on storage.objects for delete to authenticated
 using (bucket_id='post-media' and (storage.foldername(name))[1]=(select auth.uid())::text);
