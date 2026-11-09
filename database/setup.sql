BEGIN;
CREATE SCHEMA IF NOT EXISTS badminton_private;
REVOKE ALL ON SCHEMA badminton_private FROM PUBLIC;
CREATE TABLE IF NOT EXISTS badminton_private.teams(id integer PRIMARY KEY,players text[] NOT NULL);
CREATE TABLE IF NOT EXISTS badminton_private.pairs(id integer PRIMARY KEY,a integer NOT NULL,b integer NOT NULL,UNIQUE(a,b));
CREATE TABLE IF NOT EXISTS badminton_private.results(match_id integer NOT NULL REFERENCES badminton_private.pairs(id),revision integer NOT NULL,payload jsonb NOT NULL,PRIMARY KEY(match_id,revision));
CREATE OR REPLACE FUNCTION badminton_private.check_role() RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE r text;
BEGIN
 r:=COALESCE(NULLIF(current_setting('request.jwt.claims',true),'')::jsonb->>'role','');
 IF r NOT IN ('anon','authenticated','service_role') THEN RAISE EXCEPTION 'Request identity required' USING ERRCODE='42501';END IF;
END $$;
CREATE OR REPLACE FUNCTION badminton_private.game_error(g jsonb) RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE a integer;b integer;hi integer;lo integer;
BEGIN
 IF jsonb_typeof(g) IS DISTINCT FROM 'array' THEN RETURN '双方分数未填完整';END IF;
 IF jsonb_array_length(g)<>2 THEN RETURN '双方分数未填完整';END IF;
 IF jsonb_typeof(g->0) IS DISTINCT FROM 'number' OR jsonb_typeof(g->1) IS DISTINCT FROM 'number' THEN RETURN '分数必须是整数';END IF;
 IF (g->>0)!~'^[0-9]{1,2}$' OR (g->>1)!~'^[0-9]{1,2}$' THEN RETURN '每局分数须为 0–15 的整数';END IF;
 a:=(g->>0)::integer;b:=(g->>1)::integer;
 IF a>15 OR b>15 THEN RETURN '每局分数须为 0–15 的整数';END IF;
 hi:=greatest(a,b);lo:=least(a,b);
 IF hi=11 AND lo<=9 OR hi BETWEEN 12 AND 14 AND hi-lo=2 OR hi=15 AND lo IN(13,14) THEN RETURN '';END IF;
 RETURN '每局 11 分；10 平后须领先 2 分，15 分封顶（15:14 有效）';
END $$;
CREATE OR REPLACE FUNCTION public.badminton_list() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE items jsonb;
BEGIN
 PERFORM badminton_private.check_role();
 SELECT COALESCE(jsonb_agg(x.payload),'[]'::jsonb) INTO items FROM (SELECT DISTINCT ON(match_id) payload FROM badminton_private.results ORDER BY match_id,revision DESC) x;
 RETURN jsonb_build_object('status',200,'results',items);
END $$;
CREATE OR REPLACE FUNCTION public.badminton_history(p_match_id integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE items jsonb;
BEGIN
 PERFORM badminton_private.check_role();
 IF NOT EXISTS(SELECT 1 FROM badminton_private.pairs WHERE id=p_match_id) THEN RETURN jsonb_build_object('status',400,'error','比赛不存在');END IF;
 SELECT COALESCE(jsonb_agg(payload ORDER BY revision DESC),'[]'::jsonb) INTO items FROM badminton_private.results WHERE match_id=p_match_id;
 RETURN jsonb_build_object('status',200,'history',items);
END $$;
CREATE OR REPLACE FUNCTION public.badminton_submit(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE mid integer;rev integer;latest integer;pair_record badminton_private.pairs%ROWTYPE;
 games jsonb;g jsonb;aw integer:=0;bw integer:=0;i integer;n integer;err text;k text;result jsonb;reporter text;
BEGIN
 PERFORM badminton_private.check_role();
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR octet_length(p::text)>8192 THEN RETURN jsonb_build_object('status',400,'error','提交数据无效或过长');END IF;
 IF jsonb_typeof(p->'matchId') IS DISTINCT FROM 'number' OR (p->>'matchId')!~'^[0-9]{1,2}$' THEN RETURN jsonb_build_object('status',400,'error','比赛不存在');END IF;
 IF jsonb_typeof(p->'revision') IS DISTINCT FROM 'number' OR (p->>'revision')!~'^[0-9]{1,3}$' THEN RETURN jsonb_build_object('status',400,'error','版本无效，请刷新');END IF;
 mid:=(p->>'matchId')::integer;rev:=(p->>'revision')::integer;
 IF rev>=300 THEN RETURN jsonb_build_object('status',400,'error','该场修改次数过多，请联系组织者');END IF;
 SELECT * INTO pair_record FROM badminton_private.pairs WHERE id=mid FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('status',400,'error','比赛不存在');END IF;
 games:=p->'games';
 IF jsonb_typeof(games) IS DISTINCT FROM 'array' THEN RETURN jsonb_build_object('status',400,'error','请填写完整的 2 局或 3 局比分');END IF;
 n:=jsonb_array_length(games);
 IF n NOT IN(2,3) THEN RETURN jsonb_build_object('status',400,'error','请填写完整的 2 局或 3 局比分');END IF;
 FOR i IN 0..n-1 LOOP
  IF aw=2 OR bw=2 THEN RETURN jsonb_build_object('status',400,'error','已连赢两局，无需填写第三局');END IF;
  g:=games->i;err:=badminton_private.game_error(g);
  IF err<>'' THEN RETURN jsonb_build_object('status',400,'error',format('第 %s 局：%s',i+1,err));END IF;
  IF (g->>0)::integer>(g->>1)::integer THEN aw:=aw+1;ELSE bw:=bw+1;END IF;
 END LOOP;
 IF aw<>2 AND bw<>2 THEN RETURN jsonb_build_object('status',400,'error','三局两胜：目前尚未产生获胜方');END IF;
 reporter:=p->>'reporter';
 IF jsonb_typeof(p->'reporter') IS DISTINCT FROM 'string' OR reporter='待补充' OR NOT EXISTS(SELECT 1 FROM badminton_private.teams t WHERE t.id IN(pair_record.a,pair_record.b) AND reporter=ANY(t.players)) THEN RETURN jsonb_build_object('status',400,'error','请选择本场参赛选手作为填报人');END IF;
 FOREACH k IN ARRAY ARRAY['note','court','reason','playedAt'] LOOP
  IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' OR length(p->>k)>(CASE WHEN k='note' THEN 300 ELSE 100 END) THEN RETURN jsonb_build_object('status',400,'error','填写内容无效或过长');END IF;
 END LOOP;
 IF rev>0 AND length(btrim(p->>'reason'))=0 THEN RETURN jsonb_build_object('status',400,'error','修改比分请填写更正原因');END IF;
 IF p->>'playedAt'<>'' AND (p->>'playedAt')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' THEN RETURN jsonb_build_object('status',400,'error','比赛时间格式无效');END IF;
 SELECT COALESCE(max(revision),0) INTO latest FROM badminton_private.results WHERE match_id=mid;
 IF latest<>rev THEN RETURN jsonb_build_object('status',409,'error','这场比分已被其他人更新，请关闭窗口、刷新后再核对填写');END IF;
 result:=jsonb_build_object('id',gen_random_uuid()::text,'matchId',mid,'revision',rev+1,'games',games,'reporter',reporter,'note',p->>'note','court',p->>'court','playedAt',p->>'playedAt','reason',p->>'reason','createdAt',to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
 INSERT INTO badminton_private.results(match_id,revision,payload) VALUES(mid,rev+1,result);
 RETURN jsonb_build_object('status',200,'result',result);
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA badminton_private FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA badminton_private FROM PUBLIC;
REVOKE ALL ON FUNCTION public.badminton_list(),public.badminton_history(integer),public.badminton_submit(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.badminton_list(),public.badminton_history(integer),public.badminton_submit(jsonb) TO anon,authenticated;
INSERT INTO badminton_private.teams (id,players) VALUES
(1,ARRAY['朱雨乐','肖云凯']),
(2,ARRAY['宋远见','王永盛']),
(3,ARRAY['蔡志祥','李俊豪']),
(4,ARRAY['孔子涵','郑昌盛']),
(5,ARRAY['吴鹏旭','李雨航']),
(6,ARRAY['张俊涵','杨锦南']),
(7,ARRAY['廖浩轩','牟彬洁']),
(8,ARRAY['李凯南','廉培宇']),
(9,ARRAY['江玉涛','李铮昂']),
(10,ARRAY['张江杭','刘仕杰']),
(11,ARRAY['安羿驰','毕强']),
(12,ARRAY['寇北辰','许欣悦']),
(13,ARRAY['刘家润','谢镇谦'])
ON CONFLICT (id) DO NOTHING;
INSERT INTO badminton_private.pairs (id,a,b) VALUES
(1, 1, 2),
(2, 1, 3),
(3, 1, 4),
(4, 1, 5),
(5, 1, 6),
(6, 1, 7),
(7, 1, 8),
(8, 1, 9),
(9, 1, 10),
(10, 1, 11),
(11, 1, 12),
(12, 1, 13),
(13, 2, 3),
(14, 2, 4),
(15, 2, 5),
(16, 2, 6),
(17, 2, 7),
(18, 2, 8),
(19, 2, 9),
(20, 2, 10),
(21, 2, 11),
(22, 2, 12),
(23, 2, 13),
(24, 3, 4),
(25, 3, 5),
(26, 3, 6),
(27, 3, 7),
(28, 3, 8),
(29, 3, 9),
(30, 3, 10),
(31, 3, 11),
(32, 3, 12),
(33, 3, 13),
(34, 4, 5),
(35, 4, 6),
(36, 4, 7),
(37, 4, 8),
(38, 4, 9),
(39, 4, 10),
(40, 4, 11),
(41, 4, 12),
(42, 4, 13),
(43, 5, 6),
(44, 5, 7),
(45, 5, 8),
(46, 5, 9),
(47, 5, 10),
(48, 5, 11),
(49, 5, 12),
(50, 5, 13),
(51, 6, 7),
(52, 6, 8),
(53, 6, 9),
(54, 6, 10),
(55, 6, 11),
(56, 6, 12),
(57, 6, 13),
(58, 7, 8),
(59, 7, 9),
(60, 7, 10),
(61, 7, 11),
(62, 7, 12),
(63, 7, 13),
(64, 8, 9),
(65, 8, 10),
(66, 8, 11),
(67, 8, 12),
(68, 8, 13),
(69, 9, 10),
(70, 9, 11),
(71, 9, 12),
(72, 9, 13),
(73, 10, 11),
(74, 10, 12),
(75, 10, 13),
(76, 11, 12),
(77, 11, 13),
(78, 12, 13)
ON CONFLICT (id) DO NOTHING;

COMMIT;
