-- ЗАМЕНИТЕ 00000000-0000-0000-0000-000000000000 на UUID ВАШЕГО аккаунта durov.
-- UUID нужно взять в Supabase Authentication -> Users и убедиться по email,
-- что это именно ваш аккаунт. Это идентификатор, не пароль.
-- Не отправляйте никому секретные ключи или пароли.
-- Скрипт останавливается, если UUID не заменён, не является профилем durov или durov не найден.
do $$
declare admin_id uuid := '00000000-0000-0000-0000-000000000000';
begin
 if admin_id='00000000-0000-0000-0000-000000000000'::uuid then
  raise exception 'Сначала замените пример UUID на UUID вашего аккаунта durov';
 end if;
 if not exists (select 1 from public.profiles where id=admin_id and username='durov') then
  raise exception 'Не найден профиль durov с указанным UUID — проверьте UUID и ник';
 end if;
 insert into public.pear_admins(user_id) values(admin_id) on conflict(user_id) do nothing;
 insert into public.pear_verified_profiles(profile_id) values(admin_id) on conflict(profile_id) do nothing;
end $$;
