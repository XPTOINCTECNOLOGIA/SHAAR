-- SHAAR · o board tem cargo próprio: CONSELHEIRO
--
-- Marcus Freire Silva ficara sem cargo por eu supor que "BOARD" era so um
-- perfil, como acontece com o CEO. Nao e: conselheiro e um cargo da estrutura.
--
-- O posto continua vindo do perfil (nivel 90 -> posto 2), porque shaar_posto
-- resolve os tres primeiros pelo perfil antes de olhar o cargo. Gravar o
-- nivel no cargo mesmo assim deixa o dado auto-explicativo: se um dia alguem
-- tiver o cargo sem o perfil BOARD, a ordenacao continua correta.

insert into public.positions (name, description, active, nivel_organizacional, is_executive, codigo)
select 'CONSELHEIRO', 'Conselheiro do Board', true, 2, true, 'CONSELHEIRO'
 where not exists (select 1 from public.positions where upper(btrim(name)) = 'CONSELHEIRO');

update public.users u
   set position_id = (select id from public.positions where upper(btrim(name)) = 'CONSELHEIRO' limit 1),
       updated_at  = now()
 where lower(u.email) = 'marcus.silva@xptoinc.com.br';

comment on column public.positions.nivel_organizacional is
  'Ordem hierarquica do cargo, 2 a 13. O posto 1 (SUPERADMIN) e o 3 (CEO) vem '
  'do perfil, porque quem os ocupa nao tem cargo registado.';
