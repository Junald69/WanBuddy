-- =============================================================================
-- WanBuddy v0.2 / M2  09: 施設マスタのシード(PRD 4.12)
--   マスタデータなので migration に含める(`supabase db push` でも投入される)。冪等。
--   出典: https://www.tptc.co.jp/park/03_01/dogrun(確認日 2026-10-28)。公式文章は転載せず要約。
--   ※正式な施設コードは未決(PRD 7.1)。提案値 'tatsumi-no-mori-dogrun'。
-- =============================================================================
insert into public.facilities
  (code, name, park_name, operator, address, open_time, close_time, timezone,
   fee_note, registration_required, registration_note, official_url, notice_text, is_active)
values (
  'tatsumi-no-mori-dogrun',
  'たつみの森ドッグラン',
  '辰巳の森海浜公園',
  '東京港埠頭株式会社',
  '東京都江東区辰巳2-1-35',
  time '06:00', time '21:00', 'Asia/Tokyo',
  '無料',
  true,
  '毎年度(4月1日から)「たつみの森ドッグラン利用登録」が必須。狂犬病予防注射の接種が前提です。',
  'https://www.tptc.co.jp/park/03_01/dogrun',
  'たつみの森ドッグランのご利用には、毎年度(4月1日から)『たつみの森ドッグラン利用登録』が必要です(狂犬病予防注射の接種が前提です)。利用時間は6時〜21時で、夜間照明はありません。行事等で利用が制限される日があります。詳しくは公式ページをご確認ください。',
  true
)
on conflict (code) do nothing;

insert into public.facility_areas (facility_id, code, name, area_sqm)
select f.id, a.code, a.name, a.sqm
  from public.facilities f
  cross join (values ('free', 'フリー広場', 1240), ('small', '小型犬用広場', 490)) as a(code, name, sqm)
 where f.code = 'tatsumi-no-mori-dogrun'
on conflict (facility_id, code) do nothing;
