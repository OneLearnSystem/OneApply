-- OneCollege + OneUniversity. Additive upgrade for the existing OneLearn platform.
-- Run the entire file once. It is safe to run again. Existing apps are untouched.
BEGIN;
DO $$BEGIN IF to_regclass('public.ol_schools') IS NULL THEN RAISE EXCEPTION 'Install the OneLearn platform first. Use your existing OneLearn project.';END IF;END$$;
CREATE TABLE IF NOT EXISTS public.he_settings(school_id uuid REFERENCES public.ol_schools(id),app text CHECK(app IN ('college','university')),data jsonb NOT NULL DEFAULT '{}',revision int NOT NULL DEFAULT 0,PRIMARY KEY(school_id,app));
CREATE TABLE IF NOT EXISTS public.he_students(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),school_id uuid NOT NULL REFERENCES public.ol_schools(id),app text NOT NULL CHECK(app IN ('college','university')),first text NOT NULL,last text NOT NULL,year int NOT NULL CHECK(year BETWEEN 1 AND 10),email text NOT NULL DEFAULT '',programme_id uuid,notes text NOT NULL DEFAULT '',archived boolean NOT NULL DEFAULT false,login_code text UNIQUE NOT NULL DEFAULT upper(replace(gen_random_uuid()::text,'-','')),access_code text UNIQUE NOT NULL DEFAULT ('HE-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),revision int NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS he_student_email ON public.he_students(school_id,app,lower(email)) WHERE email<>'' AND NOT archived;
CREATE TABLE IF NOT EXISTS public.he_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),school_id uuid NOT NULL REFERENCES public.ol_schools(id),app text NOT NULL CHECK(app IN ('college','university')),kind text NOT NULL CHECK(kind IN ('programme','module','room','session','assessment','submission','result','enrolment','attendance','notice','resource','appointment','project','request','decision')),data jsonb NOT NULL,revision int NOT NULL DEFAULT 0,created_by uuid,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS he_items_scope ON public.he_items(school_id,app,kind);
CREATE UNIQUE INDEX IF NOT EXISTS he_enrolment_unique ON public.he_items(school_id,app,(data->>'student'),(data->>'module')) WHERE kind='enrolment';
CREATE UNIQUE INDEX IF NOT EXISTS he_attendance_unique ON public.he_items(school_id,app,(data->>'student'),(data->>'session')) WHERE kind='attendance';
CREATE UNIQUE INDEX IF NOT EXISTS he_submission_unique ON public.he_items(school_id,app,(data->>'student'),(data->>'assessment')) WHERE kind='submission';
CREATE UNIQUE INDEX IF NOT EXISTS he_result_unique ON public.he_items(school_id,app,(data->>'student'),(data->>'assessment'),(data->>'attempt')) WHERE kind='result';
CREATE TABLE IF NOT EXISTS public.he_roles(school_id uuid REFERENCES public.ol_schools(id),app text CHECK(app IN ('college','university')),user_id uuid REFERENCES auth.users(id),role text NOT NULL CHECK(role IN ('lecturer','programme_leader','registry','support','timetable_manager','viewer')),PRIMARY KEY(school_id,app,user_id));
CREATE TABLE IF NOT EXISTS public.he_files(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),school_id uuid NOT NULL REFERENCES public.ol_schools(id),app text NOT NULL,item_id uuid NOT NULL REFERENCES public.he_items(id),name text NOT NULL,content text NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.he_audit(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,school_id uuid NOT NULL REFERENCES public.ol_schools(id),app text NOT NULL,actor uuid,student_id uuid,action text NOT NULL,at timestamptz NOT NULL DEFAULT now());
DO $$DECLARE t text;BEGIN FOREACH t IN ARRAY ARRAY['he_settings','he_students','he_items','he_roles','he_files','he_audit'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);END LOOP;END$$;
CREATE OR REPLACE FUNCTION public.he_role(sid uuid,ap text) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE WHEN public.ol_role(sid)='admin' THEN 'admin' WHEN public.ol_role(sid) IS NOT NULL THEN coalesce((SELECT role FROM public.he_roles WHERE school_id=sid AND app=ap AND user_id=auth.uid()),'lecturer') END
$$;
CREATE OR REPLACE FUNCTION public.he_ref(sid uuid,ap text,ident text,k text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE d jsonb;BEGIN SELECT data INTO d FROM public.he_items WHERE school_id=sid AND app=ap AND id=ident::uuid AND kind=k AND coalesce(data->>'archived','false')<>'true';IF d IS NULL THEN RAISE EXCEPTION 'The selected % is unavailable in this institution.',k;END IF;RETURN d;END$$;
CREATE OR REPLACE FUNCTION public.he_enrolled(sid uuid,ap text,st text,mo text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
SELECT EXISTS(SELECT 1 FROM public.he_items WHERE school_id=sid AND app=ap AND kind='enrolment' AND data->>'student'=st AND data->>'module'=mo)
$$;
CREATE OR REPLACE FUNCTION public.he_teaches(sid uuid,ap text,mo text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
SELECT EXISTS(SELECT 1 FROM public.he_items WHERE school_id=sid AND app=ap AND kind='module' AND id=mo::uuid AND data->>'teacher'=auth.uid()::text)
$$;
CREATE OR REPLACE FUNCTION public.he_closed(sid uuid,ap text,dy date) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE w jsonb;ns text;BEGIN
 IF EXISTS(SELECT 1 FROM public.he_settings WHERE school_id=sid AND app=ap AND data->>'status' IN ('closed','closing')) THEN RETURN true;END IF;
 IF ap='college' THEN ns:='school_'||replace(sid::text,'-','');IF to_regclass(format('%I.oe_workspace',ns)) IS NOT NULL THEN
 EXECUTE format('SELECT data FROM %I.oe_workspace WHERE id=1',ns) INTO w;
 IF w#>>'{school,status}' IN ('closed','closing') OR EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(w->'closures','[]'))c WHERE dy BETWEEN (c->>'start')::date AND (c->>'end')::date AND c->>'status'<>'open') THEN RETURN true;END IF;END IF;END IF;
 RETURN false;END$$;
CREATE OR REPLACE FUNCTION public.he_read(sid uuid,ap text,ro text,st uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE it jsonb; students jsonb; mine text[]; visible uuid[]; settings jsonb;
BEGIN
 SELECT coalesce(data,'{}') INTO settings FROM public.he_settings WHERE school_id=sid AND app=ap;
 SELECT coalesce(array_agg(data->>'module'),'{}') INTO mine FROM public.he_items WHERE school_id=sid AND app=ap AND kind='enrolment' AND data->>'student'=st::text;
 SELECT coalesce(jsonb_agg(to_jsonb(p)-'school_id'-'app'-CASE WHEN ro IN ('admin','registry') THEN '__none' ELSE 'login_code' END-CASE WHEN ro='student' THEN 'notes' ELSE '__none' END ORDER BY p.last,p.first),'[]') INTO students FROM public.he_students p WHERE school_id=sid AND app=ap AND
 (ro IN ('admin','registry','programme_leader','support','timetable_manager') OR (ro='student' AND id=st) OR EXISTS(SELECT 1 FROM public.he_items e WHERE e.school_id=sid AND e.app=ap AND e.kind='enrolment' AND e.data->>'student'=p.id::text AND public.he_teaches(sid,ap,e.data->>'module')));
 SELECT coalesce(array_agg(i.id),'{}') INTO visible FROM public.he_items i WHERE i.school_id=sid AND i.app=ap AND
 CASE WHEN ro='student' THEN
 CASE i.kind
 WHEN 'programme' THEN true WHEN 'room' THEN true WHEN 'module' THEN true
 WHEN 'session' THEN i.data->>'module'=ANY(mine)
 WHEN 'assessment' THEN i.data->>'module'=ANY(mine) AND i.data->>'published'='true'
 WHEN 'resource' THEN i.data->>'module'=ANY(mine) AND i.data->>'published'='true'
 WHEN 'notice' THEN i.data->>'published'='true' AND (nullif(i.data->>'year','') IS NULL OR i.data->>'year'=(SELECT year::text FROM public.he_students WHERE id=st)) AND (nullif(i.data->>'module','') IS NULL OR i.data->>'module'=ANY(mine))
 WHEN 'result' THEN i.data->>'student'=st::text AND i.data->>'released'='true'
 ELSE i.data->>'student'=st::text END
 ELSE CASE WHEN i.kind IN ('programme','room','module','session','notice') THEN true
 WHEN i.kind IN ('request','appointment','project') THEN ro IN ('admin','registry','support','programme_leader') OR i.data->>'staff'=auth.uid()::text
 WHEN i.kind='decision' THEN ro IN ('admin','registry','programme_leader')
 ELSE ro IN ('admin','registry','programme_leader') OR (ap='college' AND i.kind='attendance' AND i.data->>'daily'='true' AND ro='lecturer') OR public.he_teaches(sid,ap,coalesce(i.data->>'module',
 (SELECT data->>'module' FROM public.he_items WHERE school_id=sid AND app=ap AND id=nullif(i.data->>'assessment','')::uuid),
 (SELECT data->>'module' FROM public.he_items WHERE school_id=sid AND app=ap AND id=nullif(i.data->>'session','')::uuid)))
 END END;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'data',CASE WHEN ro='student' THEN data-'privateNote' ELSE data END,'revision',revision,'created_at',created_at) ORDER BY created_at),'[]') INTO it FROM public.he_items WHERE id=ANY(visible);
 RETURN jsonb_build_object('role',ro,'userId',auth.uid(),'studentId',st,'settings',coalesce(settings,'{}'),'settingsRevision',coalesce((SELECT revision FROM public.he_settings WHERE school_id=sid AND app=ap),0),
 'institution',(SELECT name FROM public.ol_schools WHERE id=sid),'students',students,'items',it,
 'staff',coalesce((SELECT jsonb_agg(jsonb_build_object('id',u.id,'email',CASE WHEN ro='student' THEN '' ELSE u.email END,'name',coalesce(nullif(settings#>>ARRAY['staffNames',u.id::text],''),split_part(u.email,'@',1)),'role',CASE WHEN m.role='admin' THEN 'admin' ELSE coalesce(r.role,'lecturer') END)) FROM public.ol_members m JOIN auth.users u ON u.id=m.user_id LEFT JOIN public.he_roles r ON r.user_id=u.id AND r.school_id=sid AND r.app=ap WHERE m.school_id=sid AND u.email_confirmed_at IS NOT NULL),'[]'),
 'files',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'item',item_id,'name',name)) FROM public.he_files WHERE school_id=sid AND app=ap AND item_id=ANY(visible)),'[]'),
 'audit',CASE WHEN ro='admin' THEN coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM (SELECT action,at FROM public.he_audit WHERE school_id=sid AND app=ap ORDER BY at DESC LIMIT 50)a),'[]') ELSE '[]'::jsonb END);
END$$;
CREATE OR REPLACE FUNCTION public.he_api(p_slug text,p_app text,p_action text DEFAULT 'read',p_data jsonb DEFAULT '{}',p_code text DEFAULT '',p_student boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_column
<<he_ctx>>
DECLARE sid uuid; ro text; st uuid; em text; conf jsonb; rev int; ident uuid; kind text; d jsonb; old public.he_items; person public.he_students; x jsonb; y jsonb; ar jsonb; it public.he_items; md jsonb; rm jsonb; pr jsonb; target uuid; yr int; rows int:=0; skipped int:=0; mo text; ids text[]; req text; dt date; startt time; endt time; nam text; n int; total numeric; snapshot jsonb; result jsonb; uid uuid:=auth.uid();
BEGIN
 IF p_app IS NULL OR p_app NOT IN ('college','university') OR p_action IS NULL OR jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR octet_length(p_data::text)>1800000 THEN RAISE EXCEPTION 'Invalid request.';END IF;
 SELECT id INTO sid FROM public.ol_schools WHERE slug=p_slug AND active;IF sid IS NULL THEN RAISE EXCEPTION 'Institution not found. Check the institution address.';END IF;
 SELECT lower(email) INTO em FROM auth.users WHERE id=uid AND email_confirmed_at IS NOT NULL;
 ro:=CASE WHEN NOT p_student THEN public.he_role(sid,p_app) END;
 SELECT data,revision INTO conf,rev FROM public.he_settings WHERE school_id=sid AND app=p_app;
 conf:=coalesce(conf,jsonb_build_object('name',(SELECT name FROM public.ol_schools WHERE id=sid),'choicesOpen',true,'status','open','years',CASE WHEN p_app='college' THEN 3 ELSE 6 END,'allowCodes',p_app='college'));
 IF ro IS NULL THEN
  IF em IS NOT NULL THEN SELECT id INTO st FROM public.he_students WHERE school_id=sid AND app=p_app AND lower(email)=em AND NOT archived;END IF;
  IF st IS NULL AND (p_app='college' OR conf->>'allowCodes'='true') AND upper(regexp_replace(p_code,'[-[:space:]]','','g')) ~ '^[A-F0-9]{32}$' THEN
   SELECT id INTO st FROM public.he_students WHERE school_id=sid AND app=p_app AND login_code=upper(regexp_replace(p_code,'[-[:space:]]','','g')) AND NOT archived;
  END IF;
  IF st IS NULL THEN RAISE EXCEPTION 'No access. Use an approved staff account or your linked student account/code.';END IF;
  ro:='student';
 END IF;
 IF p_action='read' THEN RETURN public.he_read(sid,p_app,ro,st)||jsonb_build_object('settings',conf);END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(sid::text||p_app,66));
 INSERT INTO public.he_settings(school_id,app,data) VALUES(sid,p_app,conf) ON CONFLICT DO NOTHING;
 IF p_action='file_get' THEN
  snapshot:=public.he_read(sid,p_app,ro,st);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot->'files') f WHERE f->>'id'=p_data->>'id') THEN RAISE EXCEPTION 'File unavailable.';END IF;
  RETURN (SELECT jsonb_build_object('name',name,'content',content) FROM public.he_files WHERE id=(p_data->>'id')::uuid AND school_id=sid AND app=p_app);
 END IF;
 IF p_action='settings' THEN
  IF ro<>'admin' THEN RAISE EXCEPTION 'Administrator access required.';END IF;
  IF coalesce((p_data->>'revision')::int,-1)<>coalesce(rev,0) THEN RAISE EXCEPTION 'Settings changed. Refresh and try again.';END IF;
  d:=p_data->'settings';
  IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR coalesce(length(trim(d->>'name')),0) NOT BETWEEN 1 AND 160 OR coalesce(d->>'status','') NOT IN ('open','closed','closing') OR coalesce((d->>'years')::int,0) NOT BETWEEN 1 AND 10 OR (p_app='college' AND (d->>'years')::int<>3) OR jsonb_typeof(d->'choicesOpen') IS DISTINCT FROM 'boolean' OR jsonb_typeof(d->'allowCodes') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Check the institution settings. College has exactly Years 1–3.';END IF;
  IF EXISTS(SELECT 1 FROM public.he_students WHERE school_id=sid AND app=p_app AND NOT archived AND year>(d->>'years')::int) THEN RAISE EXCEPTION 'Active students exist in a higher year.';END IF;
  INSERT INTO public.he_settings VALUES(sid,p_app,d,1) ON CONFLICT(school_id,app) DO UPDATE SET data=excluded.data,revision=public.he_settings.revision+1;
 ELSIF p_action='role' THEN
  IF ro<>'admin' OR coalesce(p_data->>'role','') NOT IN ('lecturer','programme_leader','registry','support','timetable_manager','viewer') THEN RAISE EXCEPTION 'Administrator and a valid staff role required.';END IF;
  target:=(p_data->>'user')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.ol_members WHERE school_id=sid AND user_id=target AND role<>'admin') THEN RAISE EXCEPTION 'Choose an existing non-admin institution member. Invite staff through OneLearn first.';END IF;
  INSERT INTO public.he_roles VALUES(sid,p_app,target,p_data->>'role') ON CONFLICT(school_id,app,user_id) DO UPDATE SET role=excluded.role;
 ELSIF p_action IN ('import','student','rotate') THEN
  IF ro NOT IN ('admin','registry') THEN RAISE EXCEPTION 'Registry or administrator access required.';END IF;
  IF p_action='rotate' THEN
   UPDATE public.he_students SET login_code=upper(replace(gen_random_uuid()::text,'-','')),access_code='HE-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),revision=revision+1 WHERE id=(p_data->>'id')::uuid AND school_id=sid AND app=p_app;
   IF NOT FOUND THEN RAISE EXCEPTION 'Student not found.';END IF;
  ELSE
   ar:=CASE WHEN p_action='import' THEN p_data->'students' ELSE jsonb_build_array(p_data) END;
   IF jsonb_typeof(ar) IS DISTINCT FROM 'array' OR jsonb_array_length(ar) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Import 1–500 students.';END IF;
   FOR x IN SELECT value FROM jsonb_array_elements(ar) LOOP
    yr:=(x->>'year')::int;
    IF coalesce(length(trim(x->>'first')),0) NOT BETWEEN 1 AND 80 OR coalesce(length(trim(x->>'last')),0) NOT BETWEEN 1 AND 100 OR yr IS NULL OR yr NOT BETWEEN 1 AND (conf->>'years')::int OR length(coalesce(x->>'notes',''))>3000 OR (coalesce(x->>'email','')<>'' AND x->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') THEN RAISE EXCEPTION 'Check every name, year and email.';END IF;
    target:=nullif(x->>'programme_id','')::uuid;
    IF target IS NOT NULL THEN pr:=public.he_ref(sid,p_app,target::text,'programme');IF yr>(pr->>'years')::int THEN RAISE EXCEPTION 'Year exceeds programme length.';END IF;END IF;
    IF p_action='import' OR nullif(x->>'id','') IS NULL THEN
     IF EXISTS(SELECT 1 FROM public.he_students WHERE school_id=sid AND app=p_app AND NOT archived AND year=yr AND lower(first)=lower(trim(x->>'first')) AND lower(last)=lower(trim(x->>'last'))) THEN skipped:=skipped+1;CONTINUE;END IF;
     INSERT INTO public.he_students(school_id,app,first,last,year,email,programme_id,notes) VALUES(sid,p_app,trim(x->>'first'),trim(x->>'last'),yr,lower(trim(coalesce(x->>'email',''))),target,coalesce(x->>'notes','')) RETURNING id INTO ident;rows:=rows+1;
     IF jsonb_array_length(coalesce(p_data->'modules','[]'))>0 THEN PERFORM public.he_api(p_slug,p_app,'choices',jsonb_build_object('student',ident,'modules',p_data->'modules'));END IF;
    ELSE
     SELECT * INTO person FROM public.he_students WHERE id=(x->>'id')::uuid AND school_id=sid AND app=p_app FOR UPDATE;
     IF person.id IS NULL OR person.revision<>coalesce((x->>'revision')::int,-1) THEN RAISE EXCEPTION 'Student changed. Refresh and try again.';END IF;
     IF (yr<>person.year OR target IS DISTINCT FROM person.programme_id) AND EXISTS(SELECT 1 FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='enrolment' AND data->>'student'=person.id::text) THEN RAISE EXCEPTION 'Remove existing class/module memberships before changing year or programme.';END IF;
     UPDATE public.he_students SET first=trim(x->>'first'),last=trim(x->>'last'),year=yr,email=lower(trim(coalesce(x->>'email',''))),programme_id=target,notes=coalesce(x->>'notes',''),archived=coalesce((x->>'archived')::boolean,false),revision=revision+1 WHERE id=person.id;
     IF x->>'archived'='true' THEN DELETE FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='enrolment' AND data->>'student'=person.id::text;END IF;
    END IF;
   END LOOP;
  END IF;
 ELSIF p_action='choices' THEN
  target:=CASE WHEN ro='student' THEN st ELSE (p_data->>'student')::uuid END;
  IF ro NOT IN ('student','admin','registry','programme_leader') THEN RAISE EXCEPTION 'Class allocation access required.';END IF;
  IF ro='student' AND conf->>'choicesOpen'<>'true' THEN RAISE EXCEPTION 'Choices are closed. Contact staff.';END IF;
  SELECT * INTO person FROM public.he_students WHERE id=target AND school_id=sid AND app=p_app AND NOT archived;
  IF person.id IS NULL THEN RAISE EXCEPTION 'Active student not found.';END IF;
  IF jsonb_typeof(p_data->'modules') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'modules')>30 THEN RAISE EXCEPTION 'Choose up to 30 modules.';END IF;
  SELECT coalesce(array_agg(value),'{}') INTO ids FROM jsonb_array_elements_text(p_data->'modules');
  IF cardinality(ids)<>(SELECT count(DISTINCT v) FROM unnest(ids)v) THEN RAISE EXCEPTION 'Duplicate module selection.';END IF;
  IF p_app='college' AND cardinality(ids)>0 THEN
   IF cardinality(ids)<>5 OR (SELECT count(*) FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='module' AND id::text=ANY(ids) AND data->>'group'='core')<>2 THEN RAISE EXCEPTION 'Choose exactly three options and two core subjects.';END IF;
   IF (SELECT count(DISTINCT data->>'subject') FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='module' AND id::text=ANY(ids))<>5 THEN RAISE EXCEPTION 'Choose five different subjects.';END IF;
  END IF;
  IF ro='student' AND cardinality(ids)=0 THEN RAISE EXCEPTION 'Choose your modules.';END IF;
  total:=0;
  FOR n IN 1..cardinality(ids) LOOP
   mo:=ids[n];
   md:=public.he_ref(sid,p_app,mo,'module');
   IF (md->>'year')::int<>person.year OR (p_app='university' AND nullif(md->>'programme','')::uuid IS DISTINCT FROM person.programme_id) THEN RAISE EXCEPTION 'Choose modules for this student’s year and programme.';END IF;
   IF (SELECT count(*) FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='enrolment' AND data->>'module'=mo AND data->>'student'<>target::text)>=(md->>'capacity')::int THEN
    IF p_app<>'college' THEN RAISE EXCEPTION 'A selected module is full.';END IF;
    SELECT a.id::text INTO mo FROM public.he_items a WHERE a.school_id=sid AND a.app=p_app AND a.kind='module' AND a.data->>'subject'=md->>'subject' AND a.data->>'year'=md->>'year' AND (SELECT count(*) FROM public.he_items e WHERE e.school_id=sid AND e.app=p_app AND e.kind='enrolment' AND e.data->>'module'=a.id::text)<(a.data->>'capacity')::int LIMIT 1;
    IF mo IS NULL THEN INSERT INTO public.he_items(school_id,app,kind,data,created_by) VALUES(sid,p_app,'module',md||jsonb_build_object('title',md->>'subject'||' · Additional group','teacher',null),uid) RETURNING id::text INTO mo;END IF;
    ids[n]:=mo;
   END IF;
   total:=total+coalesce((md->>'credits')::numeric,0);
   FOR req IN SELECT jsonb_array_elements_text(coalesce(md->'prerequisites','[]')) LOOP
    IF NOT EXISTS(SELECT 1 FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='decision' AND data->>'student'=target::text AND data->>'module'=req AND data->>'outcome'='Passed') THEN RAISE EXCEPTION 'A prerequisite module has not yet been approved as passed.';END IF;
   END LOOP;
  END LOOP;
  IF p_app='university' AND cardinality(ids)>0 THEN
   pr:=public.he_ref(sid,p_app,person.programme_id::text,'programme');
   IF total>(pr->>'annualCredits')::numeric THEN RAISE EXCEPTION 'Selected credits exceed the programme’s yearly limit.';END IF;
   IF EXISTS(SELECT 1 FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='module' AND data->>'programme'=person.programme_id::text AND (data->>'year')::int=person.year AND data->>'compulsory'='true' AND coalesce(data->>'archived','false')<>'true' AND NOT(id::text=ANY(ids))) THEN RAISE EXCEPTION 'Include every compulsory module.';END IF;
  END IF;
  IF EXISTS(SELECT 1 FROM public.he_items a JOIN public.he_items b ON b.school_id=a.school_id AND b.app=a.app AND b.kind='session' AND a.id<b.id WHERE a.school_id=sid AND a.app=p_app AND a.kind='session' AND a.data->>'module'=ANY(ids) AND b.data->>'module'=ANY(ids) AND a.data->>'date'=b.data->>'date' AND coalesce(a.data->>'cancelled','false')<>'true' AND coalesce(b.data->>'cancelled','false')<>'true' AND (a.data->>'start')::time<(b.data->>'end')::time AND (a.data->>'end')::time>(b.data->>'start')::time) THEN RAISE EXCEPTION 'Selected modules have a timetable clash.';END IF;
  DELETE FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='enrolment' AND data->>'student'=target::text;
  FOREACH mo IN ARRAY ids LOOP INSERT INTO public.he_items(school_id,app,kind,data,created_by) VALUES(sid,p_app,'enrolment',jsonb_build_object('student',target,'module',mo),uid);END LOOP;
 ELSIF p_action='sessions' THEN
  IF ro NOT IN ('admin','programme_leader','timetable_manager') OR jsonb_typeof(p_data->'sessions') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'sessions') NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Provide 1–200 sessions using a timetable role.';END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_data->'sessions') LOOP PERFORM public.he_api(p_slug,p_app,'save',jsonb_build_object('kind','session','data',x));END LOOP;
 ELSIF p_action='daily_register' THEN
  IF p_app<>'college' OR ro NOT IN ('admin','registry','programme_leader','lecturer') THEN RAISE EXCEPTION 'College register access required.';END IF;
  dt:=(p_data->>'date')::date;
  IF dt IS NULL OR dt>(now() AT TIME ZONE 'Europe/London')::date OR extract(isodow FROM dt)>5 OR coalesce(p_data->>'slot','') NOT IN ('AM','PM') OR public.he_closed(sid,p_app,dt) THEN RAISE EXCEPTION 'Choose a past/current weekday and an open institution.';END IF;
  IF jsonb_typeof(p_data->'marks') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'marks') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Choose at least one mark.';END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_data->'marks') LOOP
   IF NOT EXISTS(SELECT 1 FROM public.he_students WHERE school_id=sid AND app=p_app AND id=(x->>'student')::uuid AND NOT archived) OR coalesce(x->>'mark','') NOT IN ('Present','Absent','Late','Ill','Authorised') OR length(coalesce(x->>'note',''))>1000 THEN RAISE EXCEPTION 'Invalid student or mark.';END IF;
   req:=dt::text||'-'||(p_data->>'slot');
   SELECT * INTO old FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='attendance' AND data->>'student'=x->>'student' AND data->>'session'=req;
   IF coalesce(old.revision,-1)<>coalesce((x->>'revision')::int,-1) THEN RAISE EXCEPTION 'Register changed. Refresh before saving.';END IF;
   d:=jsonb_build_object('student',x->>'student','session',req,'date',dt,'mark',x->>'mark','note',coalesce(x->>'note',''),'daily',true);
   IF old.id IS NULL THEN INSERT INTO public.he_items(school_id,app,kind,data,created_by) VALUES(sid,p_app,'attendance',d,uid);ELSE UPDATE public.he_items SET data=d,revision=revision+1,updated_at=now() WHERE id=old.id;END IF;
  END LOOP;
 ELSIF p_action='register' THEN
  IF ro NOT IN ('admin','registry','programme_leader','lecturer') THEN RAISE EXCEPTION 'Register access required.';END IF;
  md:=public.he_ref(sid,p_app,p_data->>'session','session');
  IF ro='lecturer' AND md->>'teacher' IS DISTINCT FROM uid::text AND NOT public.he_teaches(sid,p_app,md->>'module') THEN RAISE EXCEPTION 'This is not your teaching session.';END IF;
  IF public.he_closed(sid,p_app,(md->>'date')::date) OR md->>'cancelled'='true' OR (md->>'date')::date>(now() AT TIME ZONE 'Europe/London')::date THEN RAISE EXCEPTION 'Attendance is unavailable for closed institutions, cancelled sessions or future dates.';END IF;
  IF jsonb_typeof(p_data->'marks') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'marks') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Choose at least one attendance mark.';END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_data->'marks') LOOP
   IF NOT public.he_enrolled(sid,p_app,x->>'student',md->>'module') OR coalesce(x->>'mark','') NOT IN ('Present','Absent','Late','Ill','Authorised') OR length(coalesce(x->>'note',''))>1000 THEN RAISE EXCEPTION 'Invalid student or attendance mark.';END IF;
   SELECT * INTO old FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='attendance' AND data->>'student'=x->>'student' AND data->>'session'=p_data->>'session';
   IF coalesce(old.revision,-1)<>coalesce((x->>'revision')::int,-1) THEN RAISE EXCEPTION 'Register changed. Refresh before saving.';END IF;
   d:=jsonb_build_object('student',x->>'student','session',p_data->>'session','module',md->>'module','date',md->>'date','mark',x->>'mark','note',coalesce(x->>'note',''));
   IF old.id IS NULL THEN INSERT INTO public.he_items(school_id,app,kind,data,created_by) VALUES(sid,p_app,'attendance',d,uid);ELSE UPDATE public.he_items SET data=d,revision=revision+1,updated_at=now() WHERE id=old.id;END IF;
  END LOOP;
 ELSIF p_action='save' THEN
  kind:=p_data->>'kind';d:=p_data->'data';ident:=nullif(p_data->>'id','')::uuid;
  IF kind IS NULL OR kind NOT IN ('programme','module','room','session','assessment','submission','result','notice','resource','appointment','project','request','decision') OR jsonb_typeof(d) IS DISTINCT FROM 'object' OR coalesce(length(trim(d->>'title')),0) NOT BETWEEN 1 AND 180 OR octet_length(d::text)>30000 THEN RAISE EXCEPTION 'Choose a valid record type and title.';END IF;
  IF ident IS NOT NULL THEN SELECT * INTO old FROM public.he_items WHERE id=ident AND school_id=sid AND app=p_app AND public.he_items.kind=he_ctx.kind FOR UPDATE;
   IF old.id IS NULL OR old.revision<>coalesce((p_data->>'revision')::int,-1) THEN RAISE EXCEPTION 'Record changed. Refresh and try again.';END IF;
  ELSE old:=NULL;END IF;
  IF ro='lecturer' AND old.id IS NOT NULL AND kind IN ('appointment','project','request') AND coalesce(old.data->>'staff','')<>uid::text THEN RAISE EXCEPTION 'This record is assigned to another staff member.';END IF;
  IF ro='student' THEN
   IF kind NOT IN ('submission','request') OR (old.id IS NOT NULL AND old.data->>'student'<>st::text) THEN RAISE EXCEPTION 'Student editing is restricted to your own submissions and requests.';END IF;
   d:=jsonb_build_object('title',d->>'title','body',coalesce(d->>'body',''),'assessment',d->>'assessment','type',d->>'type','requestedDate',d->>'requestedDate','student',st,'status','Pending','staff',null);
   IF old.id IS NOT NULL AND old.data->>'status'<>'Pending' THEN RAISE EXCEPTION 'This request has already been processed.';END IF;
  ELSE
   IF (kind IN ('programme','module','room','decision') AND ro NOT IN ('admin','registry','programme_leader')) OR (kind='session' AND ro NOT IN ('admin','programme_leader','timetable_manager')) OR (kind IN ('assessment','resource','result') AND ro NOT IN ('admin','programme_leader','lecturer')) OR (kind IN ('appointment','project','request') AND ro NOT IN ('admin','registry','programme_leader','support','lecturer')) OR (kind='notice' AND ro NOT IN ('admin','registry','programme_leader','lecturer')) OR kind='submission' THEN RAISE EXCEPTION 'Your role cannot edit this type of record.';END IF;
  END IF;
  IF nullif(d->>'student','') IS NOT NULL THEN
   SELECT * INTO person FROM public.he_students WHERE id=(d->>'student')::uuid AND school_id=sid AND app=p_app AND NOT archived;
   IF person.id IS NULL THEN RAISE EXCEPTION 'Active student not found.';END IF;
   IF ro='lecturer' AND kind IN ('appointment','project','request') AND NOT EXISTS(SELECT 1 FROM public.he_items e WHERE e.school_id=sid AND e.app=p_app AND e.kind='enrolment' AND e.data->>'student'=person.id::text AND public.he_teaches(sid,p_app,e.data->>'module')) THEN RAISE EXCEPTION 'Choose a student enrolled on one of your modules.';END IF;
  END IF;
  IF kind IN ('programme') THEN
   IF coalesce((d->>'years')::int,0) NOT BETWEEN 1 AND 10 OR coalesce((d->>'annualCredits')::int,0) NOT BETWEEN 1 AND 240 THEN RAISE EXCEPTION 'Set programme length and annual credit limit.';END IF;
  ELSIF kind='room' THEN
   IF coalesce((d->>'capacity')::int,0) NOT BETWEEN 1 AND 2000 OR coalesce(length(d->>'building'),0)=0 THEN RAISE EXCEPTION 'Enter a building and room capacity.';END IF;
  ELSIF kind='module' THEN
   IF coalesce((d->>'year')::int,0) NOT BETWEEN 1 AND (conf->>'years')::int OR coalesce((d->>'capacity')::int,0) NOT BETWEEN 1 AND 2000 OR coalesce((d->>'credits')::int,-1) NOT BETWEEN 0 AND 240 THEN RAISE EXCEPTION 'Check year, capacity and credits.';END IF;
   IF p_app='university' THEN pr:=public.he_ref(sid,p_app,d->>'programme','programme');IF (d->>'year')::int>(pr->>'years')::int THEN RAISE EXCEPTION 'Module year exceeds programme length.';END IF;
   ELSE IF coalesce(d->>'group','') NOT IN ('core','option') OR coalesce(length(d->>'subject'),0)=0 THEN RAISE EXCEPTION 'Choose core/option and a subject.';END IF;END IF;
   IF ident IS NOT NULL AND (SELECT count(*) FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='enrolment' AND data->>'module'=ident::text)>(d->>'capacity')::int THEN RAISE EXCEPTION 'Capacity is below current enrolment.';END IF;
   IF ident IS NOT NULL AND (d->>'year' IS DISTINCT FROM old.data->>'year' OR d->>'programme' IS DISTINCT FROM old.data->>'programme' OR d->>'group' IS DISTINCT FROM old.data->>'group' OR d->>'subject' IS DISTINCT FROM old.data->>'subject') AND EXISTS(SELECT 1 FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='enrolment' AND data->>'module'=ident::text) THEN RAISE EXCEPTION 'Remove memberships before changing the module’s year, programme or subject group.';END IF;
   IF jsonb_typeof(coalesce(d->'prerequisites','[]'))<>'array' THEN RAISE EXCEPTION 'Invalid prerequisites.';END IF;
   FOR req IN SELECT jsonb_array_elements_text(coalesce(d->'prerequisites','[]')) LOOP PERFORM public.he_ref(sid,p_app,req,'module');IF req=ident::text THEN RAISE EXCEPTION 'A module cannot require itself.';END IF;END LOOP;
  ELSIF kind='session' THEN
   md:=public.he_ref(sid,p_app,d->>'module','module');rm:=public.he_ref(sid,p_app,d->>'room','room');
   dt:=(d->>'date')::date;startt:=(d->>'start')::time;endt:=(d->>'end')::time;
   IF dt IS NULL OR startt IS NULL OR endt IS NULL OR endt<=startt OR nullif(d->>'teacher','') IS NULL OR coalesce(d->>'type','') NOT IN ('Lecture','Seminar','Lab','Workshop','Tutorial','Exam','AM registration','PM registration') THEN RAISE EXCEPTION 'Check date, time, lecturer and session type.';END IF;
   IF (rm->>'capacity')::int<(md->>'capacity')::int THEN RAISE EXCEPTION 'Room is too small for the module/class capacity.';END IF;
   IF coalesce(d->>'cancelled','false')<>'true' AND EXISTS(SELECT 1 FROM public.he_items a WHERE school_id=sid AND app=p_app AND kind='session' AND a.id IS DISTINCT FROM ident AND a.data->>'date'=d->>'date' AND coalesce(a.data->>'cancelled','false')<>'true' AND (a.data->>'start')::time<endt AND (a.data->>'end')::time>startt AND
    (a.data->>'room'=d->>'room' OR a.data->>'teacher'=d->>'teacher' OR a.data->>'module'=d->>'module' OR EXISTS(SELECT 1 FROM public.he_items e JOIN public.he_items f ON e.data->>'student'=f.data->>'student' AND f.school_id=sid AND f.app=p_app AND f.kind='enrolment' WHERE e.school_id=sid AND e.app=p_app AND e.kind='enrolment' AND e.data->>'module'=d->>'module' AND f.data->>'module'=a.data->>'module'))) THEN RAISE EXCEPTION 'Timetable clash: room, lecturer or enrolled students are already in a session.';END IF;
  ELSIF kind IN ('assessment','resource') THEN
   md:=public.he_ref(sid,p_app,d->>'module','module');
   IF ro='lecturer' AND NOT public.he_teaches(sid,p_app,d->>'module') THEN RAISE EXCEPTION 'Only the module lecturer may edit this record.';END IF;
   IF kind='assessment' THEN
    IF nullif(d->>'due','') IS NULL OR coalesce((d->>'weight')::numeric,0) NOT BETWEEN 0.1 AND 100 OR coalesce((d->>'passMark')::numeric,-1) NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'Check the deadline, weighting and pass mark.';END IF;
    PERFORM (d->>'due')::timestamptz;
    IF (SELECT coalesce(sum((data->>'weight')::numeric),0) FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='assessment' AND data->>'module'=d->>'module' AND id IS DISTINCT FROM ident)+(d->>'weight')::numeric>100 THEN RAISE EXCEPTION 'Assessment weights exceed 100%% for this module.';END IF;
   END IF;
  ELSIF kind='submission' THEN
   IF ro<>'student' OR ident IS NOT NULL THEN RAISE EXCEPTION 'A submitted attempt is final. Contact staff for reassessment.';END IF;
   md:=public.he_ref(sid,p_app,d->>'assessment','assessment');
   IF md->>'published'<>'true' OR NOT public.he_enrolled(sid,p_app,st::text,md->>'module') THEN RAISE EXCEPTION 'Assessment is not available to you.';END IF;
   SELECT max((data->>'approvedDate')::date) INTO dt FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='request' AND data->>'student'=st::text AND data->>'assessment'=d->>'assessment' AND data->>'status'='Approved' AND data->>'type'='Extension';
   d:=d||jsonb_build_object('module',md->>'module','submittedAt',now(),'status','Submitted','late',now()>greatest((md->>'due')::timestamptz,coalesce((dt+1)::timestamp AT TIME ZONE 'Europe/London'-interval '1 second',(md->>'due')::timestamptz)));
  ELSIF kind='result' THEN
   md:=public.he_ref(sid,p_app,d->>'assessment','assessment');
   IF NOT public.he_enrolled(sid,p_app,d->>'student',md->>'module') OR coalesce((d->>'mark')::numeric,-1) NOT BETWEEN 0 AND 100 OR coalesce((d->>'attempt')::int,0) NOT BETWEEN 1 AND 10 THEN RAISE EXCEPTION 'Check student enrolment, mark and attempt.';END IF;
   IF ro='lecturer' AND (NOT public.he_teaches(sid,p_app,md->>'module') OR d->>'released'='true' OR old.data->>'released'='true') THEN RAISE EXCEPTION 'Lecturers enter draft marks. Programme leaders approve and release results.';END IF;
   d:=d||jsonb_build_object('module',md->>'module');
  ELSIF kind IN ('appointment','project','request','decision') THEN
   IF person.id IS NULL THEN RAISE EXCEPTION 'Choose a student.';END IF;
   IF ro='lecturer' AND coalesce(d->>'staff','')<>uid::text THEN RAISE EXCEPTION 'Only assigned staff may manage this record.';END IF;
   IF kind='request' THEN
    IF coalesce(d->>'type','') NOT IN ('Extension','Study adjustment','Support','Absence','Study break','Transfer') OR coalesce(d->>'status','') NOT IN ('Pending','Approved','Declined','Closed') THEN RAISE EXCEPTION 'Choose a request type and status.';END IF;
    IF nullif(d->>'assessment','') IS NOT NULL THEN md:=public.he_ref(sid,p_app,d->>'assessment','assessment');IF NOT public.he_enrolled(sid,p_app,person.id::text,md->>'module') THEN RAISE EXCEPTION 'Assessment does not belong to this student.';END IF;END IF;
    IF d->>'type'='Extension' AND d->>'status'='Approved' THEN IF nullif(d->>'assessment','') IS NULL OR nullif(d->>'approvedDate','') IS NULL THEN RAISE EXCEPTION 'An approved extension needs an assessment and date.';END IF;PERFORM (d->>'approvedDate')::date;END IF;
   ELSIF kind='decision' THEN
    IF coalesce(d->>'outcome','') NOT IN ('Passed','Resit','Repeat','Progress','Award','Withdrawn') THEN RAISE EXCEPTION 'Choose a progression outcome.';END IF;
    IF nullif(d->>'module','') IS NOT NULL THEN PERFORM public.he_ref(sid,p_app,d->>'module','module');END IF;
   END IF;
  ELSIF kind='notice' THEN
   IF nullif(d->>'module','') IS NOT NULL THEN PERFORM public.he_ref(sid,p_app,d->>'module','module');END IF;
   IF nullif(d->>'year','') IS NOT NULL AND (d->>'year')::int NOT BETWEEN 1 AND (conf->>'years')::int THEN RAISE EXCEPTION 'Invalid year audience.';END IF;
  END IF;
  IF nullif(d->>'teacher','') IS NOT NULL OR nullif(d->>'staff','') IS NOT NULL THEN
   IF NOT EXISTS(SELECT 1 FROM public.ol_members m JOIN auth.users u ON u.id=m.user_id WHERE m.school_id=sid AND u.email_confirmed_at IS NOT NULL AND u.id=coalesce(nullif(d->>'teacher',''),nullif(d->>'staff',''))::uuid) THEN RAISE EXCEPTION 'Choose a verified member of institution staff.';END IF;
  END IF;
  IF old.id IS NOT NULL AND kind IN ('result','appointment','project','request') AND d->>'student' IS DISTINCT FROM old.data->>'student' THEN RAISE EXCEPTION 'A saved record cannot be reassigned to another student.';END IF;
  IF old.id IS NOT NULL AND kind IN ('assessment','resource','session') AND d->>'module' IS DISTINCT FROM old.data->>'module' THEN RAISE EXCEPTION 'Create a new record to change its module.';END IF;
  IF ident IS NULL THEN INSERT INTO public.he_items(school_id,app,kind,data,created_by) VALUES(sid,p_app,kind,d,uid) RETURNING id INTO ident;ELSE UPDATE public.he_items SET data=d,revision=revision+1,updated_at=now() WHERE id=ident;END IF;
  IF p_data->'file' IS NOT NULL AND p_data->'file'<>'null'::jsonb THEN
   x:=p_data->'file';
   IF kind NOT IN ('resource','submission') OR coalesce(length(x->>'name'),0) NOT BETWEEN 1 AND 160 OR coalesce(length(x->>'content'),0) NOT BETWEEN 1 AND 1400000 OR x->>'content' !~ '^[A-Za-z0-9+/]+={0,2}$' OR lower(x->>'name') !~ '\.(pdf|docx|pptx|xlsx|csv|txt|png|jpg|jpeg|zip)$' THEN RAISE EXCEPTION 'Attach a supported file up to 1 MB.';END IF;
   INSERT INTO public.he_files(school_id,app,item_id,name,content) VALUES(sid,p_app,ident,x->>'name',x->>'content');
  END IF;
 ELSIF p_action='seed_college' THEN
  IF p_app<>'college' OR ro<>'admin' THEN RAISE EXCEPTION 'College administrator access required.';END IF;
  IF EXISTS(SELECT 1 FROM public.he_items WHERE school_id=sid AND app=p_app AND kind='module') THEN RAISE EXCEPTION 'Starter classes already exist or classes have been created. Use course management.';END IF;
  FOR n IN 1..6 LOOP INSERT INTO public.he_items(school_id,app,kind,data,created_by) VALUES(sid,p_app,'room',jsonb_build_object('title','A0'||n,'building','A Block','capacity',30),uid);END LOOP;
  FOR x IN SELECT value FROM jsonb_array_elements(p_data->'subjects') LOOP
   IF coalesce(x->>'group','') NOT IN ('core','option') OR coalesce(length(x->>'name'),0) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid starter subject.';END IF;
   FOR yr IN 1..3 LOOP INSERT INTO public.he_items(school_id,app,kind,data,created_by) VALUES(sid,p_app,'module',jsonb_build_object('title',x->>'name'||' · Group A','subject',x->>'name','group',x->>'group','year',yr,'capacity',24,'credits',0,'qualification','A level','teacher',null,'prerequisites','[]'::jsonb),uid);END LOOP;
  END LOOP;
 ELSE RAISE EXCEPTION 'Unknown operation.';END IF;
 INSERT INTO public.he_audit(school_id,app,actor,student_id,action) VALUES(sid,p_app,uid,st,p_action||coalesce(': '||kind,''));
 RETURN public.he_read(sid,p_app,ro,st)||jsonb_build_object('message',CASE WHEN p_action='import' THEN rows||' imported; '||skipped||' matching names skipped.' ELSE 'Saved successfully.' END,'savedId',ident);
END$$;
REVOKE ALL ON FUNCTION public.he_role(uuid,text),public.he_ref(uuid,text,text,text),public.he_enrolled(uuid,text,text,text),public.he_teaches(uuid,text,text),public.he_read(uuid,text,text,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.he_closed(uuid,text,date) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.he_api(text,text,text,jsonb,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.he_api(text,text,text,jsonb,text,boolean) TO anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
