-- Pear: модераторы. Для существующей базы Pear после обновлений 1, 6, 7 и 8.
-- Перед запуском сделайте резервную копию и проверьте скрипт на тестовом проекте.
-- Изменяет политики и функции модерации, но не удаляет существующие данные.
BEGIN;
DO $$ BEGIN
 IF to_regclass('public.profiles') IS NULL OR to_regclass('public.posts') IS NULL
 OR to_regclass('public.pear_admins') IS NULL OR to_regclass('public.pear_post_reports') IS NULL
 OR to_regclass('public.pear_moderation_media_cleanup') IS NULL OR to_regclass('storage.objects') IS NULL
 OR to_regprocedure('public.pear_resolve_post_report(uuid)') IS NULL
 OR to_regprocedure('public.pear_admin_delete_reported_post(uuid)') IS NULL
 OR to_regprocedure('public.pear_admin_finish_media_cleanup(uuid)') IS NULL THEN
  RAISE EXCEPTION 'В базе нет необходимых таблиц или функций Pear (обновления 1, 7 и 8). Операция отменена.';
 END IF;
END $$;

-- Если таблица уже есть, транзакция останавливается: сначала проверить её назначение.
CREATE TABLE public.pear_moderators (
 user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pear_moderators ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pear_moderators FROM PUBLIC, anon, authenticated;
-- Список ролей виден зарегистрированным пользователям, чтобы показывать значки.
GRANT SELECT ON public.pear_moderators TO authenticated;
CREATE POLICY pear_moderators_read ON public.pear_moderators FOR SELECT TO authenticated USING (true);

-- Проверка использует только доверенные серверные таблицы, не метаданные пользователя.
CREATE FUNCTION public.pear_can_moderate() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT auth.uid() IS NOT NULL AND (
  EXISTS (SELECT 1 FROM public.pear_admins WHERE user_id=auth.uid()) OR
  EXISTS (SELECT 1 FROM public.pear_moderators WHERE user_id=auth.uid())
 );
$$;
REVOKE ALL ON FUNCTION public.pear_can_moderate() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pear_can_moderate() TO authenticated;

-- Назначает или снимает роль только действующий администратор.
CREATE FUNCTION public.pear_admin_set_moderator(p_user_id uuid,p_enabled boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.pear_admins WHERE user_id=auth.uid()) THEN
  RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501';
 END IF;
 IF p_user_id IS NULL OR p_enabled IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=p_user_id) THEN
  RAISE EXCEPTION 'Profile or role state invalid' USING ERRCODE='22023';
 END IF;
 IF p_enabled THEN
  INSERT INTO public.pear_moderators(user_id) VALUES(p_user_id) ON CONFLICT(user_id) DO NOTHING;
 ELSE
  DELETE FROM public.pear_moderators WHERE user_id=p_user_id;
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.pear_admin_set_moderator(uuid,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pear_admin_set_moderator(uuid,boolean) TO authenticated;

-- Проверка файла выполняется с правами владельца функции, чтобы скрытые RLS посты
-- не выглядели отсутствующими. Путь разрешён только из очереди и не используется.
CREATE FUNCTION public.pear_can_remove_moderation_media(p_path text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT public.pear_can_moderate()
 AND EXISTS (SELECT 1 FROM public.pear_moderation_media_cleanup WHERE media_path=p_path)
 AND NOT EXISTS (SELECT 1 FROM public.posts WHERE media_path=p_path);
$$;
REVOKE ALL ON FUNCTION public.pear_can_remove_moderation_media(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pear_can_remove_moderation_media(text) TO authenticated;

-- Дополнительные политики не удаляют имеющиеся политики администратора.
CREATE POLICY pear_reports_read_moderator ON public.pear_post_reports FOR SELECT TO authenticated USING (public.pear_can_moderate());
CREATE POLICY pear_cleanup_read_moderator ON public.pear_moderation_media_cleanup FOR SELECT TO authenticated USING (public.pear_can_moderate());
CREATE POLICY pear_moderator_read_cleanup_media ON storage.objects FOR SELECT TO authenticated USING (
 bucket_id='post-media' AND public.pear_can_moderate()
 AND EXISTS (SELECT 1 FROM public.pear_moderation_media_cleanup c WHERE c.media_path=name)
);
CREATE POLICY pear_moderator_delete_reported_media ON storage.objects FOR DELETE TO authenticated USING (
 bucket_id='post-media' AND public.pear_can_remove_moderation_media(name)
);

CREATE OR REPLACE FUNCTION public.pear_resolve_post_report(p_report_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT public.pear_can_moderate() THEN RAISE EXCEPTION 'Moderator access required' USING ERRCODE='42501'; END IF;
 UPDATE public.pear_post_reports SET status='resolved' WHERE id=p_report_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report not found'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.pear_resolve_post_report(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pear_resolve_post_report(uuid) TO authenticated;

-- Удаление только по рассмотренной жалобе; сохранена очередь очистки файлов.
CREATE OR REPLACE FUNCTION public.pear_admin_delete_reported_post(p_report_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE target public.posts%ROWTYPE; cleanup_id uuid;
BEGIN
 IF NOT public.pear_can_moderate() THEN RAISE EXCEPTION 'Moderator access required' USING ERRCODE='42501'; END IF;
 SELECT p.* INTO target FROM public.pear_post_reports r JOIN public.posts p ON p.id=r.post_id
 WHERE r.id=p_report_id AND r.status='resolved' FOR UPDATE OF p,r;
 IF NOT FOUND THEN RAISE EXCEPTION 'A resolved report and existing post are required'; END IF;
 IF target.media_path IS NOT NULL THEN
  INSERT INTO public.pear_moderation_media_cleanup(post_id,media_path) VALUES(target.id,target.media_path)
  ON CONFLICT(post_id) DO UPDATE SET media_path=excluded.media_path RETURNING id INTO cleanup_id;
 END IF;
 DELETE FROM public.posts WHERE id=target.id;
 RETURN jsonb_build_object('post_id',target.id,'cleanup_id',cleanup_id,'media_path',target.media_path);
END $$;
REVOKE ALL ON FUNCTION public.pear_admin_delete_reported_post(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pear_admin_delete_reported_post(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.pear_admin_finish_media_cleanup(p_cleanup_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE target_path text;
BEGIN
 IF NOT public.pear_can_moderate() THEN RAISE EXCEPTION 'Moderator access required' USING ERRCODE='42501'; END IF;
 SELECT media_path INTO target_path FROM public.pear_moderation_media_cleanup WHERE id=p_cleanup_id FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='post-media' AND name=target_path)
    AND NOT EXISTS(SELECT 1 FROM public.posts WHERE media_path=target_path) THEN
  RAISE EXCEPTION 'Media still exists';
 END IF;
 DELETE FROM public.pear_moderation_media_cleanup WHERE id=p_cleanup_id;
END $$;
REVOKE ALL ON FUNCTION public.pear_admin_finish_media_cleanup(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pear_admin_finish_media_cleanup(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
