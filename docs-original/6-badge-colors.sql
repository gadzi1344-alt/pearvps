-- Pear: existing verified profiles remain blue. Run once in Supabase SQL Editor.
BEGIN;
ALTER TABLE public.pear_verified_profiles
  ADD COLUMN IF NOT EXISTS badge_type text NOT NULL DEFAULT 'blue';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.pear_verified_profiles'::regclass AND conname='pear_verified_badge_type_check') THEN
    ALTER TABLE public.pear_verified_profiles ADD CONSTRAINT pear_verified_badge_type_check CHECK (badge_type IN ('blue','green'));
  END IF;
END $$;

-- Changes are checked by the server, not just the admin interface.
CREATE OR REPLACE FUNCTION public.pear_set_verification(p_profile_id uuid, p_type text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.pear_admins WHERE user_id=auth.uid()) THEN
    RAISE EXCEPTION 'Admin access required' USING errcode='42501';
  END IF;
  IF p_profile_id IS NULL OR p_type IS NULL OR p_type NOT IN ('blue','green','none') THEN
    RAISE EXCEPTION 'Invalid profile or badge type' USING errcode='22023';
  END IF;
  IF p_type='none' THEN
    DELETE FROM public.pear_verified_profiles WHERE profile_id=p_profile_id;
  ELSE
    INSERT INTO public.pear_verified_profiles(profile_id,badge_type) VALUES (p_profile_id,p_type)
    ON CONFLICT(profile_id) DO UPDATE SET badge_type=EXCLUDED.badge_type;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.pear_set_verification(uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pear_set_verification(uuid,text) TO authenticated;
COMMIT;
