-- OneApply / OnePath. Additive setup for an existing OneLearn project.
-- Run HIGHER-EDUCATION-UPGRADE.sql first. No demo records are inserted here.
BEGIN;
CREATE TABLE IF NOT EXISTS public.hp_cycles(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), school_id uuid NOT NULL REFERENCES public.ol_schools(id), title text NOT NULL, kind text NOT NULL CHECK(kind IN ('College','University')), opens date NOT NULL, closes date NOT NULL, max_choices int NOT NULL CHECK(max_choices BETWEEN 1 AND 10), intro text NOT NULL DEFAULT '', published boolean NOT NULL DEFAULT false, CHECK(closes>=opens));
CREATE TABLE IF NOT EXISTS public.hp_courses(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),school_id uuid NOT NULL REFERENCES public.ol_schools(id),cycle_id uuid NOT NULL REFERENCES public.hp_cycles(id),title text NOT NULL,qualification text NOT NULL DEFAULT '',duration text NOT NULL DEFAULT '',requirements text NOT NULL DEFAULT '',published boolean NOT NULL DEFAULT true);
CREATE TABLE IF NOT EXISTS public.hp_applications(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),school_id uuid NOT NULL REFERENCES public.ol_schools(id),cycle_id uuid NOT NULL REFERENCES public.hp_cycles(id),user_id uuid NOT NULL REFERENCES auth.users(id),data jsonb NOT NULL DEFAULT '{}',status text NOT NULL DEFAULT 'Draft',decision text NOT NULL DEFAULT '',student_id uuid REFERENCES public.he_students(id),revision int NOT NULL DEFAULT 0,updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(cycle_id,user_id));
CREATE TABLE IF NOT EXISTS public.hp_opportunities(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),school_id uuid NOT NULL REFERENCES public.ol_schools(id),title text NOT NULL,kind text NOT NULL CHECK(kind IN ('Career','Placement','Apprenticeship','Event')),organisation text NOT NULL DEFAULT '',description text NOT NULL DEFAULT '',url text NOT NULL DEFAULT '',deadline date,published boolean NOT NULL DEFAULT true);
CREATE TABLE IF NOT EXISTS public.hp_plans(school_id uuid REFERENCES public.ol_schools(id),user_id uuid REFERENCES auth.users(id),data jsonb NOT NULL DEFAULT '{"saved":[],"goals":[],"placements":[]}',revision int NOT NULL DEFAULT 0,PRIMARY KEY(school_id,user_id));
CREATE TABLE IF NOT EXISTS public.hp_audit(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,school_id uuid NOT NULL REFERENCES public.ol_schools(id),actor uuid NOT NULL,action text NOT NULL,record_id uuid,at timestamptz NOT NULL DEFAULT now());
DO $$DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['hp_cycles','hp_courses','hp_applications','hp_opportunities','hp_plans','hp_audit'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t); END LOOP;END$$;
CREATE OR REPLACE FUNCTION public.hp_api(p_slug text,p_action text DEFAULT 'read',p_data jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sid uuid; uid uuid:=auth.uid(); admin boolean; cy public.hp_cycles; ar public.hp_applications; ident uuid; result jsonb; student uuid; current_rev int; dest text; op text:=p_action;
BEGIN
 SELECT id INTO sid FROM public.ol_schools WHERE slug=p_slug AND active;
 IF sid IS NULL THEN RAISE EXCEPTION 'Institution not found. Check your institution address.';END IF;
 admin:=coalesce(public.ol_role(sid)='admin',false);
 IF p_action<>'read' AND uid IS NULL THEN RAISE EXCEPTION 'Sign in to save your work.';END IF;
 IF octet_length(p_data::text)>150000 THEN RAISE EXCEPTION 'This entry is too large.';END IF;
 IF p_action IN ('cycle','course','opportunity','decision','enrol') AND NOT admin THEN RAISE EXCEPTION 'Institution administrator access required.';END IF;
 IF p_action='cycle' THEN
  ident:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid());
  IF length(trim(p_data->>'title')) NOT BETWEEN 1 AND 150 THEN RAISE EXCEPTION 'Enter a cycle title.';END IF;
  IF EXISTS(SELECT 1 FROM public.hp_cycles WHERE id=ident AND school_id<>sid) THEN RAISE EXCEPTION 'Record unavailable.';END IF;
  INSERT INTO public.hp_cycles(id,school_id,title,kind,opens,closes,max_choices,intro,published) VALUES(ident,sid,trim(p_data->>'title'),p_data->>'kind',(p_data->>'opens')::date,(p_data->>'closes')::date,(p_data->>'max_choices')::int,left(coalesce(p_data->>'intro',''),4000),coalesce((p_data->>'published')::boolean,false)) ON CONFLICT(id) DO UPDATE SET title=excluded.title,kind=excluded.kind,opens=excluded.opens,closes=excluded.closes,max_choices=excluded.max_choices,intro=excluded.intro,published=excluded.published;
 ELSIF p_action='course' THEN
  SELECT * INTO cy FROM public.hp_cycles WHERE id=(p_data->>'cycle_id')::uuid AND school_id=sid;IF cy.id IS NULL THEN RAISE EXCEPTION 'Choose a cycle in this institution.';END IF;
  ident:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid());IF EXISTS(SELECT 1 FROM public.hp_courses WHERE id=ident AND school_id<>sid) THEN RAISE EXCEPTION 'Record unavailable.';END IF;
  IF length(trim(p_data->>'title')) NOT BETWEEN 1 AND 150 THEN RAISE EXCEPTION 'Enter a course title.';END IF;
  INSERT INTO public.hp_courses(id,school_id,cycle_id,title,qualification,duration,requirements,published) VALUES(ident,sid,cy.id,trim(p_data->>'title'),left(coalesce(p_data->>'qualification',''),150),left(coalesce(p_data->>'duration',''),150),left(coalesce(p_data->>'requirements',''),4000),coalesce((p_data->>'published')::boolean,true)) ON CONFLICT(id) DO UPDATE SET title=excluded.title,qualification=excluded.qualification,duration=excluded.duration,requirements=excluded.requirements,published=excluded.published;
 ELSIF p_action='application' THEN
  SELECT * INTO cy FROM public.hp_cycles WHERE id=(p_data->>'cycle_id')::uuid AND school_id=sid AND published;
  IF cy.id IS NULL OR (now() AT TIME ZONE 'Europe/London')::date NOT BETWEEN cy.opens AND cy.closes THEN RAISE EXCEPTION 'This application cycle is not open.';END IF;
  IF jsonb_typeof(p_data#>'{data,choices}') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data#>'{data,choices}') NOT BETWEEN 1 AND cy.max_choices THEN RAISE EXCEPTION 'Check the number of course choices.';END IF;
  IF (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(p_data#>'{data,choices}'))<>jsonb_array_length(p_data#>'{data,choices}') OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(p_data#>'{data,choices}') x WHERE NOT EXISTS(SELECT 1 FROM public.hp_courses c WHERE c.id::text=x.value AND c.cycle_id=cy.id AND c.published)) THEN RAISE EXCEPTION 'Choose available courses from this cycle.';END IF;
  IF length(trim(coalesce(p_data#>>'{data,first}','')))<1 OR length(trim(coalesce(p_data#>>'{data,last}','')))<1 THEN RAISE EXCEPTION 'Enter your first and last names.';END IF;
  dest:=CASE WHEN p_data->>'submit'='true' THEN 'Submitted' ELSE 'Draft' END;
  IF dest='Submitted' AND (length(trim(coalesce(p_data#>>'{data,statement}','')))<30 OR p_data#>>'{data,confirm}' IS DISTINCT FROM 'true') THEN RAISE EXCEPTION 'Add a statement of at least 30 characters and confirm your details.';END IF;
  INSERT INTO public.hp_applications(school_id,cycle_id,user_id) VALUES(sid,cy.id,uid) ON CONFLICT(cycle_id,user_id) DO NOTHING;
  SELECT * INTO ar FROM public.hp_applications WHERE cycle_id=cy.id AND user_id=uid FOR UPDATE;
  IF ar.status<>'Draft' OR ar.revision<>coalesce((p_data->>'revision')::int,0) THEN RAISE EXCEPTION 'This application changed or was already submitted. Refresh before editing.';END IF;
  UPDATE public.hp_applications SET data=jsonb_build_object('first',left(trim(p_data#>>'{data,first}'),100),'last',left(trim(p_data#>>'{data,last}'),100),'email',(SELECT email FROM auth.users WHERE id=uid),'qualifications',left(coalesce(p_data#>>'{data,qualifications}',''),4000),'statement',left(coalesce(p_data#>>'{data,statement}',''),8000),'choices',p_data#>'{data,choices}'),status=dest,revision=revision+1,updated_at=now() WHERE id=ar.id;ident:=ar.id;
 ELSIF p_action IN ('decision','respond','enrol') THEN
  SELECT * INTO ar FROM public.hp_applications WHERE id=(p_data->>'id')::uuid AND school_id=sid FOR UPDATE;
  IF ar.id IS NULL THEN RAISE EXCEPTION 'Application unavailable.';END IF;
  IF ar.revision IS DISTINCT FROM (p_data->>'revision')::int THEN RAISE EXCEPTION 'This record changed. Refresh first.';END IF;
  IF p_action='decision' THEN
   dest:=p_data->>'status';IF ar.status NOT IN ('Submitted','Under review','Interview','Conditional offer','Offer') OR dest NOT IN ('Under review','Interview','Conditional offer','Offer','Unsuccessful') THEN RAISE EXCEPTION 'This decision is not available at this stage.';END IF;
   IF length(trim(coalesce(p_data->>'decision','')))<1 THEN RAISE EXCEPTION 'Add a message for the applicant.';END IF;
   UPDATE public.hp_applications SET status=dest,decision=left(p_data->>'decision',4000),revision=revision+1,updated_at=now() WHERE id=ar.id;
  ELSIF p_action='respond' THEN
   IF ar.user_id<>uid OR ar.status NOT IN ('Conditional offer','Offer') OR p_data->>'status' NOT IN ('Accepted','Declined') THEN RAISE EXCEPTION 'Offer response unavailable.';END IF;
   UPDATE public.hp_applications SET status=p_data->>'status',revision=revision+1,updated_at=now() WHERE id=ar.id;
  ELSE
   SELECT * INTO cy FROM public.hp_cycles WHERE id=ar.cycle_id;
   IF cy.kind<>'College' OR ar.status<>'Accepted' OR ar.student_id IS NOT NULL OR p_data->>'verified' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'Accept a College offer and verify its conditions before enrolment.';END IF;
   IF EXISTS(SELECT 1 FROM public.he_students WHERE school_id=sid AND app='college' AND lower(email)=lower(ar.data->>'email') AND NOT archived) THEN RAISE EXCEPTION 'A student with this email already exists. Review in OneCollege.';END IF;
   INSERT INTO public.he_students(school_id,app,first,last,year,email,notes) VALUES(sid,'college',ar.data->>'first',ar.data->>'last',1,ar.data->>'email','Created from OneApply. Assign programme and classes in OneCollege.') RETURNING id INTO student;
   UPDATE public.hp_applications SET student_id=student,status='Enrolled',revision=revision+1,updated_at=now() WHERE id=ar.id;
  END IF;ident:=ar.id;
 ELSIF p_action='opportunity' THEN
  ident:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid());IF EXISTS(SELECT 1 FROM public.hp_opportunities WHERE id=ident AND school_id<>sid) THEN RAISE EXCEPTION 'Record unavailable.';END IF;
  IF length(trim(p_data->>'title')) NOT BETWEEN 1 AND 150 OR (coalesce(p_data->>'url','')<>'' AND p_data->>'url' !~ '^https://') THEN RAISE EXCEPTION 'Enter a title and a valid HTTPS link, or leave the link blank.';END IF;
  INSERT INTO public.hp_opportunities(id,school_id,title,kind,organisation,description,url,deadline,published) VALUES(ident,sid,trim(p_data->>'title'),p_data->>'kind',left(coalesce(p_data->>'organisation',''),150),left(coalesce(p_data->>'description',''),6000),coalesce(p_data->>'url',''),nullif(p_data->>'deadline','')::date,coalesce((p_data->>'published')::boolean,true)) ON CONFLICT(id) DO UPDATE SET title=excluded.title,kind=excluded.kind,organisation=excluded.organisation,description=excluded.description,url=excluded.url,deadline=excluded.deadline,published=excluded.published;
 ELSIF p_action='plan' THEN
  IF jsonb_typeof(p_data->'data') IS DISTINCT FROM 'object' OR jsonb_typeof(p_data#>'{data,goals}') IS DISTINCT FROM 'array' OR jsonb_typeof(p_data#>'{data,saved}') IS DISTINCT FROM 'array' OR jsonb_typeof(p_data#>'{data,placements}') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid plan.';END IF;
  INSERT INTO public.hp_plans(school_id,user_id) VALUES(sid,uid) ON CONFLICT DO NOTHING;
  SELECT revision INTO current_rev FROM public.hp_plans WHERE school_id=sid AND user_id=uid FOR UPDATE;
  IF current_rev<>coalesce((p_data->>'revision')::int,0) THEN RAISE EXCEPTION 'Your plan changed on another device. Refresh first.';END IF;
  UPDATE public.hp_plans SET data=p_data->'data',revision=revision+1 WHERE school_id=sid AND user_id=uid;
 ELSIF p_action<>'read' THEN RAISE EXCEPTION 'Unknown action.';
 END IF;
 IF p_action<>'read' THEN INSERT INTO public.hp_audit(school_id,actor,action,record_id) VALUES(sid,uid,op,ident);END IF;
 SELECT jsonb_build_object('institution',(SELECT name FROM public.ol_schools WHERE id=sid),'admin',admin,'cycles',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.opens DESC) FROM public.hp_cycles c WHERE school_id=sid AND (published OR admin)),'[]'::jsonb),'courses',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY title) FROM public.hp_courses c WHERE school_id=sid AND (admin OR (published AND EXISTS(SELECT 1 FROM public.hp_cycles y WHERE y.id=c.cycle_id AND y.published)))),'[]'::jsonb),'applications',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY updated_at DESC) FROM public.hp_applications a WHERE school_id=sid AND (admin OR user_id=uid)),'[]'::jsonb),'opportunities',coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY title) FROM public.hp_opportunities o WHERE school_id=sid AND (published OR admin)),'[]'::jsonb),'plan',coalesce((SELECT jsonb_build_object('data',data,'revision',revision) FROM public.hp_plans WHERE school_id=sid AND user_id=uid),'{"data":{"saved":[],"goals":[],"placements":[]},"revision":0}'::jsonb),'audit',CASE WHEN admin THEN coalesce((SELECT jsonb_agg(x) FROM (SELECT action,at FROM public.hp_audit WHERE school_id=sid ORDER BY at DESC LIMIT 50)x),'[]'::jsonb) ELSE '[]'::jsonb END) INTO result;
 RETURN result;
END$$;
REVOKE ALL ON FUNCTION public.hp_api(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hp_api(text,text,jsonb) TO anon,authenticated;
COMMIT;

