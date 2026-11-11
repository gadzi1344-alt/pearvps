-- Опционально: для уже созданной базы из первого архива Pear.
-- Не пересоздаёт таблицы и не удаляет данные. Добавляет только существующие таблицы в публикацию Realtime.
-- Если Realtime не включён, приложение всё равно обновляется автоматически опросом.
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise exception 'Публикация supabase_realtime не найдена. Включите Realtime в панели Supabase.';
  end if;
  foreach t in array array['posts','likes','comments','follows','profiles'] loop
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
