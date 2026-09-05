-- SHAAR · três pessoas que a sincronização trouxe recebem cargo e perfil
--
-- Felipe Aires Coelho Araújo  -> CLO   (C-level)
-- Marcus Freire Silva         -> BOARD (perfil, sem cargo — como o CEO)
-- Mirna Carneiro de Araujo    -> CGO   (C-level)
--
-- Entraram pelo espelho do diretório com perfil SEM PERFIL, que é o perfil de
-- chegada e não concede nada. Agora ganham o lugar real na estrutura.
--
-- O casamento é por e-mail, não por nome: nomes vêm do Entra com grafias
-- irregulares (um deles chega truncado como "... Araújo D").

-- ------------------------------------------------------------------
-- 1. Os dois cargos novos
-- ------------------------------------------------------------------
insert into public.positions (name, description, active, nivel_organizacional, is_executive, codigo)
select v.nome, v.descricao, true, 9, true, v.nome
  from (values
         ('CLO', 'Chief Legal Officer'),
         ('CGO', 'Chief Growth Officer')
       ) as v(nome, descricao)
 where not exists (select 1 from public.positions p where upper(btrim(p.name)) = v.nome);

-- ------------------------------------------------------------------
-- 2. Perfil e cargo de cada um
-- ------------------------------------------------------------------
-- Felipe: C-level, cargo CLO
update public.users u
   set profile_id  = (select id from public.profiles  where name = 'C-LEVEL' limit 1),
       position_id = (select id from public.positions where upper(btrim(name)) = 'CLO' limit 1),
       updated_at  = now()
 where lower(u.email) = 'felipe.dias@xptoinc.com.br';

-- Mirna: C-level, cargo CGO
update public.users u
   set profile_id  = (select id from public.profiles  where name = 'C-LEVEL' limit 1),
       position_id = (select id from public.positions where upper(btrim(name)) = 'CGO' limit 1),
       updated_at  = now()
 where lower(u.email) = 'mirna.araujo@xptoinc.com.br';

-- Marcus: BOARD. Como o CEO, o posto vem do perfil e nao do cargo — nao ha
-- cargo "BOARD" na estrutura, e inventar um so para ordenar seria ruido.
update public.users u
   set profile_id  = (select id from public.profiles where name = 'BOARD' limit 1),
       position_id = null,
       updated_at  = now()
 where lower(u.email) = 'marcus.silva@xptoinc.com.br';
