/**
 * SHAAR Guard · a fronteira de cada micro aplicação
 * ------------------------------------------------------------------
 * Uma aplicação do ecossistema não decide quem entra. Ela verifica um bilhete
 * assinado pelo SHAAR e obedece ao que ele diz. Este ficheiro é essa verificação.
 *
 *   import { registerApplication } from "./shaar-guard.js";
 *   const eu = await registerApplication({ app: "TIKKUN" });
 *
 * O que faz:
 *   · lê o bilhete do fragmento da URL (#bilhete=...) e guarda-o na aba
 *   · verifica a assinatura RS256 com a chave pública do SHAAR
 *   · confere destinatário (aud), emissor (iss), validade (exp/nbf)
 *   · sem bilhete válido, manda a pessoa ao SHAAR
 *
 * O que NÃO faz, de propósito:
 *   · não confia em nada que venha do próprio navegador
 *   · não decide permissão: quem decide é o SHAAR, ao emitir ou recusar
 *   · não substitui a autorização do servidor. Esta é a porta; lá dentro,
 *     cada pedido continua a passar pelas regras da base. Esconder o ecrã
 *     nunca foi defesa e continua a não ser.
 *
 * MODO DE OBSERVAÇÃO
 * Em `modo: "observar"` a biblioteca verifica tudo e devolve o veredicto, mas
 * deixa passar. Serve para pôr a fronteira em produção e ver quem seria
 * barrado ANTES de barrar de facto. É como se recomenda estrear em cada
 * aplicação; passar a "exigir" é mudar uma palavra.
 */

const PADRAO = {
  shaar: "https://shaar.xptoinc.com.br",
  api: "https://api.xptoinc.com.br",
  modo: "exigir",            // "exigir" | "observar"
  margemSegundos: 60,        // tolerância de relógio entre máquinas
  renovarAntesDe: 120,       // pede bilhete novo quando faltam 2 min
};

const CHAVE_SESSAO = (app) => `shaar.bilhete.${app}`;

// A carga do bilhete verificado mais recente. É daqui que podeFazer() responde:
// já passou pela verificação de assinatura, emissor, destinatário e validade.
let CARGA = null;

const b64u = (s) => {
  const p = s.replace(/-/g, "+").replace(/_/g, "/");
  return atob(p + "=".repeat((4 - (p.length % 4)) % 4));
};
const bytes = (s) => Uint8Array.from(b64u(s), (c) => c.charCodeAt(0));
const carga = (t) => JSON.parse(new TextDecoder().decode(bytes(t.split(".")[1])));

// o que o ultimo fragmento trazia, e o erro do ultimo setSession
let ULTIMA_CHEGADA = "sem-fragmento";
let ULTIMO_ERRO = "";

// Trava de ciclo. Sem isto, uma falha persistente faz a pessoa saltar entre a
// aplicacao e o SHAAR indefinidamente — que e pior do que uma mensagem de
// erro, porque nao ha onde ler o que aconteceu.
const CHAVE_VOLTAS = (app) => `shaar.voltas.${app}`;
const MAX_VOLTAS = 2;
function contarVolta(app) {
  try {
    const n = Number(sessionStorage.getItem(CHAVE_VOLTAS(app)) || 0) + 1;
    sessionStorage.setItem(CHAVE_VOLTAS(app), String(n));
    return n;
  } catch (e) { return 1; }
}
function zerarVoltas(app) {
  try { sessionStorage.removeItem(CHAVE_VOLTAS(app)); } catch (e) {}
}

function pararComRecado(app, motivo) {
  const html = `<div style="font:16px/1.6 system-ui,sans-serif;max-width:34rem;margin:12vh auto;padding:0 1.5rem;color:#1B2434">
    <div style="width:44px;height:44px;border-radius:10px;background:#101828;display:grid;place-items:center;margin-bottom:1.5rem">
      <span style="color:#60CFE2;font-weight:800;letter-spacing:.2em;font-size:11px">XPTO</span></div>
    <h1 style="font-size:1.5rem;margin:0 0 .75rem">Não foi possível abrir o ${app}</h1>
    <p style="margin:0 0 1rem;color:#41546E">A sua entrada foi autorizada, mas a sessão não se estabeleceu
    nesta aplicação. Interrompi aqui em vez de a mandar de volta outra vez.</p>
    <p style="margin:0 0 1.5rem;font:13px/1.5 ui-monospace,monospace;color:#6B7B90;background:#F4F6FA;
      border:1px solid #D8E0EA;border-radius:8px;padding:.75rem 1rem">${motivo}</p>
    <a href="https://shaar.xptoinc.com.br" style="display:inline-block;background:#101828;color:#fff;
      text-decoration:none;padding:.7rem 1.4rem;border-radius:8px;font-weight:600">Voltar ao SHAAR</a>
  </div>`;
  try { document.body.innerHTML = html; } catch (e) { /* documento ainda a carregar */ }
  console.error(`[shaar-guard] ${app}: parei o ciclo — ${motivo}`);
}

let jwksCache = null;
async function chaves(api) {
  if (jwksCache) return jwksCache;
  const r = await fetch(`${api}/functions/v1/shaar-jwks`, { cache: "no-cache" });
  if (!r.ok) throw new Error("shaar-guard: JWKS indisponível");
  const { keys } = await r.json();
  jwksCache = new Map();
  for (const jwk of keys) {
    jwksCache.set(
      jwk.kid,
      await crypto.subtle.importKey(
        "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"],
      ),
    );
  }
  return jwksCache;
}

/**
 * Verifica um bilhete. Devolve { ok, motivo, dados }.
 * Nunca lança: quem chama decide o que fazer com um veredicto negativo.
 */
export async function verificarBilhete(bilhete, { app, api, margemSegundos } = {}) {
  const cfg = { ...PADRAO, api, margemSegundos };
  try {
    if (!bilhete || bilhete.split(".").length !== 3) return { ok: false, motivo: "malformado" };

    const [cab, pay, ass] = bilhete.split(".");
    const cabecalho = JSON.parse(new TextDecoder().decode(bytes(cab)));

    // alg vem do próprio bilhete: aceitar o que ele pedir seria deixar alguém
    // escolher "none" ou trocar para HS256 e assinar com a chave pública
    if (cabecalho.alg !== "RS256") return { ok: false, motivo: "algoritmo_recusado" };

    const mapa = await chaves(cfg.api);
    const chave = mapa.get(cabecalho.kid);
    if (!chave) return { ok: false, motivo: "kid_desconhecido" };

    const valida = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", chave, bytes(ass),
      new TextEncoder().encode(`${cab}.${pay}`),
    );
    if (!valida) return { ok: false, motivo: "assinatura_invalida" };

    const d = JSON.parse(new TextDecoder().decode(bytes(pay)));
    const agora = Math.floor(Date.now() / 1000);
    const m = cfg.margemSegundos;

    if (d.iss !== `${cfg.api}/shaar`)      return { ok: false, motivo: "emissor_errado", dados: d };
    if (app && d.aud !== app)              return { ok: false, motivo: "destinatario_errado", dados: d };
    if (typeof d.exp !== "number" || d.exp + m < agora) return { ok: false, motivo: "expirado", dados: d };
    if (typeof d.nbf === "number" && d.nbf - m > agora) return { ok: false, motivo: "ainda_nao_vale", dados: d };

    return { ok: true, dados: d };
  } catch (e) {
    return { ok: false, motivo: "erro_verificacao", detalhe: String(e && e.message) };
  }
}

function guardar(app, bilhete) {
  try { sessionStorage.setItem(CHAVE_SESSAO(app), bilhete); } catch (e) { /* aba privada */ }
}
function lerGuardado(app) {
  try { return sessionStorage.getItem(CHAVE_SESSAO(app)); } catch (e) { return null; }
}
export function esquecerBilhete(app) {
  try { sessionStorage.removeItem(CHAVE_SESSAO(app)); } catch (e) { /* nada a fazer */ }
}

/**
 * Colhe do fragmento o bilhete e a sessão, e limpa a barra de endereço.
 *
 * O bilhete AUTORIZA. A sessão é o que dispensa novo login: cada aplicação
 * vive num subdomínio próprio, com armazenamento próprio, e sem a sessão
 * pediria credenciais outra vez — o que não é SSO, é uma catraca antes de
 * uma porta trancada.
 */
function colher() {
  const frag = (location.hash || "").replace(/^#/, "");
  if (!frag) return null;
  const p = new URLSearchParams(frag);
  const b = p.get("bilhete");
  if (!b) return null;
  const at = p.get("at");
  const rt = p.get("rt");
  // marca do que chegou de facto: b/a/r com 1 ou 0. Vai no motivo quando algo
  // falha, para o diagnostico nao depender de adivinhacao.
  ULTIMA_CHEGADA = `b${b ? 1 : 0}a${at ? 1 : 0}r${rt ? 1 : 0}`;
  for (const k of ["bilhete", "at", "rt"]) p.delete(k);
  const resto = p.toString();
  // fragmento e não query: não vai em logs de servidor nem no cabeçalho Referer.
  // Apagamos assim que consumimos, para não ficar no histórico do navegador.
  history.replaceState(null, "", location.pathname + location.search + (resto ? `#${resto}` : ""));
  return { bilhete: b, sessao: at ? { access_token: at, refresh_token: rt || "" } : null };
}

function irAoShaar(cfg, app, motivo) {
  if (contarVolta(app) > MAX_VOLTAS) {
    pararComRecado(app, `${motivo} · chegou ${ULTIMA_CHEGADA}${ULTIMO_ERRO ? " · " + ULTIMO_ERRO : ""}`);
    return;
  }
  const destino = new URL(cfg.shaar);
  destino.searchParams.set("app", app);
  destino.searchParams.set("de", location.href);
  if (motivo) destino.searchParams.set("motivo", motivo);
  destino.searchParams.set("viu", ULTIMA_CHEGADA);
  if (ULTIMO_ERRO) destino.searchParams.set("erro", ULTIMO_ERRO);
  location.replace(destino.toString());
}

/**
 * Regista a aplicação na fronteira do SHAAR.
 * Devolve a identidade do bilhete, ou null em modo de observação sem bilhete.
 */
export async function registerApplication(opcoes = {}) {
  const cfg = { ...PADRAO, ...opcoes };
  if (!cfg.app) throw new Error("shaar-guard: falta o código da aplicação");

  const colhido = colher();
  const doFragmento = colhido && colhido.bilhete;
  const bilhete = doFragmento || lerGuardado(cfg.app);

  const v = bilhete
    ? await verificarBilhete(bilhete, cfg)
    : { ok: false, motivo: "sem_bilhete" };

  if (v.ok && doFragmento) guardar(cfg.app, doFragmento);
  if (!v.ok) esquecerBilhete(cfg.app);

  if (cfg.modo === "observar") {
    // não barra ninguém; regista o que teria acontecido
    const rotulo = v.ok ? "entraria" : `seria barrado (${v.motivo})`;
    console.info(`[shaar-guard] ${cfg.app}: ${rotulo}`);
    if (typeof cfg.aoObservar === "function") cfg.aoObservar(v);
    if (v.ok) CARGA = v.dados;
    return v.ok ? { ...v.dados, sessao: colhido && colhido.sessao } : null;
  }

  if (!v.ok) { irAoShaar(cfg, cfg.app, v.motivo); return null; }

  // renovar antes de expirar, sem interromper quem está a trabalhar
  const faltam = v.dados.exp - Math.floor(Date.now() / 1000);
  if (faltam > 0) {
    setTimeout(() => {
      esquecerBilhete(cfg.app);
      irAoShaar(cfg, cfg.app, "renovacao");
    }, Math.max(faltam - cfg.renovarAntesDe, 5) * 1000);
  }

  // a sessão vem só na chegada; em recargas seguintes a aplicação já tem a sua
  CARGA = v.dados;
  return { ...v.dados, sessao: colhido && colhido.sessao };
}

/**
 * Pergunta ao gateway se a chave pública desta aplicação ainda é aceite.
 *
 * Setembro de 2026: três aplicações ficaram em ciclo entre o SHAAR e a sua
 * própria porta. Nenhuma tinha defeito na fronteira — tinham sido publicadas
 * com uma chave anon que já não existia (uma anterior à rotação do segredo,
 * outra com o literal "teste"). O gateway respondia 401 em `text/plain`, o
 * supabase-js tentava lê-lo como JSON e devolvia AuthUnknownError, e a pessoa
 * ficava a saltar entre dois sítios sem uma palavra sobre o que se passava.
 *
 * Voltar ao SHAAR não conserta uma chave morta: só repete a viagem. Por isso,
 * antes de mandar alguém de volta, perguntamos. Se a chave for recusada,
 * paramos e dizemos o nome do defeito — que é trabalho de quem publica, não
 * de quem está a tentar entrar.
 */
async function chaveAceite(supabase, cfg) {
  try {
    const base = supabase && (supabase.supabaseUrl || (supabase.rest && supabase.rest.url));
    const chave = supabase && supabase.supabaseKey;
    if (!chave) return true;          // sem forma de saber: não acusamos ninguém
    const r = await fetch(`${String(base || cfg.api).replace(/\/rest\/v1\/?$/, "")}/auth/v1/settings`, {
      headers: { apikey: chave },
    });
    return r.status !== 401 && r.status !== 403;
  } catch (e) {
    return true;                       // rede em baixo não é chave errada
  }
}

/**
 * Adopta a sessão no cliente Supabase da aplicação e CONFIRMA que colou.
 *
 * Se não colar, manda de volta ao SHAAR em vez de deixar a aplicação mostrar
 * o seu próprio ecrã de login — que é o defeito que se quer eliminar: quem
 * já entrou no SHAAR nunca deve ver uma segunda caixa de senha.
 */
export async function adoptarSessao(supabase, eu, opcoes = {}) {
  const cfg = { ...PADRAO, ...opcoes };
  try {
    const ses = eu && eu.sessao;

    // Camada 1 — o par completo. Caminho normal.
    if (ses && ses.access_token) {
      const r = await supabase.auth.setSession({
        access_token: ses.access_token,
        refresh_token: ses.refresh_token || "",
      });
      if (r && r.error) ULTIMO_ERRO = String(r.error.name || r.error.message).slice(0, 40);
    } else {
      ULTIMO_ERRO = "sem_sessao_no_fragmento";
    }

    let { data } = await supabase.auth.getSession();

    // Camada 2 — o access token pode ter vencido no caminho (vive 15 minutos).
    // O refresh token e a credencial duravel: com ele a aplicacao emite o seu
    // proprio par, sem depender da frescura do que recebeu.
    if (!(data && data.session) && ses && ses.refresh_token) {
      const r2 = await supabase.auth.refreshSession({ refresh_token: ses.refresh_token });
      if (r2 && r2.error) ULTIMO_ERRO += `/${String(r2.error.name || r2.error.message).slice(0, 30)}`;
      ({ data } = await supabase.auth.getSession());
      if (data && data.session) console.info(`[shaar-guard] ${cfg.app}: sessão obtida pelo refresh`);
    }

    if (data && data.session) { zerarVoltas(cfg.app); return true; }

    console.warn(`[shaar-guard] ${cfg.app}: a sessão não colou`);
    if (cfg.modo !== "observar") {
      esquecerBilhete(cfg.app);
      if (!(await chaveAceite(supabase, cfg))) {
        pararComRecado(
          cfg.app,
          "a chave pública desta aplicação foi recusada pelo servidor — " +
            "o pacote publicado precisa de ser reconstruído com a chave em vigor"
        );
        return false;
      }
      irAoShaar(cfg, cfg.app, "sessao_nao_colou");
    }
    return false;
  } catch (e) {
    ULTIMO_ERRO = String((e && e.name) || e).slice(0, 40);
    console.warn(`[shaar-guard] ${cfg.app}: erro ao adoptar a sessão:`, e);
    if (cfg.modo !== "observar") {
      esquecerBilhete(cfg.app);
      irAoShaar(cfg, cfg.app, "sessao_erro");
    }
    return false;
  }
}

/**
 * As quatro regras de escopo, iguais às do servidor.
 *
 *   {}                              sem limite
 *   {"departamento":["FIN","OPS"]}  contexto.departamento tem de estar na lista
 *   {"valor_max":50000}             contexto.valor <= 50000
 *   {"nivel_min":3}                 contexto.nivel  >= 3
 *
 * Dimensão declarada e AUSENTE do contexto devolve falso — nunca "sim por
 * omissão". Um esquecimento de programação vira um botão que não aparece, e
 * não um buraco silencioso.
 *
 * A versão que conta é a do servidor, em db/20-permissoes.sql. Se as duas
 * divergirem, é a de lá que manda, e o conjunto de testes apanha a diferença.
 */
function dentroDoEscopo(escopo, ctx) {
  if (!escopo || typeof escopo !== "object") return true;
  const c = ctx && typeof ctx === "object" ? ctx : {};
  return Object.keys(escopo).every((k) => {
    const v = escopo[k];
    if (Array.isArray(v)) return k in c && v.includes(c[k]);
    if (k.endsWith("_max") || k.endsWith("_min")) {
      const d = k.slice(0, -4);
      if (!(d in c)) return false;
      const n = Number(c[d]), lim = Number(v);
      if (!Number.isFinite(n) || !Number.isFinite(lim)) return false;
      return k.endsWith("_max") ? n <= lim : n >= lim;
    }
    return k in c && c[k] === v;
  });
}

/**
 * Esta pessoa pode, nesta aplicação, fazer isto — neste contexto?
 *
 * Responde pelo bilhete que o SHAAR assinou e que esta biblioteca já
 * verificou. Zero chamadas de rede: as permissões viajaram no bilhete.
 *
 * ISTO DECIDE O QUE APARECE, NÃO O QUE ACONTECE. Quem alterar a lista no
 * navegador consegue ver o botão, e ao carregar nele leva um "não" da base de
 * dados, que é onde a regra vive. Esconder um botão nunca foi autorização e
 * continua a não ser — serve para a experiência ser decente, e mais nada.
 */
export function podeFazer(codigo, contexto) {
  if (!CARGA || !CARGA.perms || typeof CARGA.perms !== "object") return false;
  if (!Object.prototype.hasOwnProperty.call(CARGA.perms, codigo)) return false;
  return dentroDoEscopo(CARGA.perms[codigo], contexto);
}

/** Todas as permissões desta pessoa nesta aplicação, com os seus limites. */
export function minhasPermissoes() {
  return CARGA && CARGA.perms ? { ...CARGA.perms } : {};
}

/**
 * A versão das permissões que veio no bilhete.
 *
 * Serve para a aplicação saber que o que tem na mão ficou velho sem perguntar
 * a cada clique: compara-se com GET /permissoes/versao quando a aba volta a
 * ganhar foco — um momento em que ninguém está à espera — e pede-se bilhete
 * novo se divergirem. Enquanto isso, quem perdeu uma permissão continua a ver
 * o botão e leva um "não" da base ao carregar. Feio, mas seguro.
 */
export function versaoPermissoes() {
  return CARGA && typeof CARGA.pv === "number" ? CARGA.pv : 0;
}

export default {
  registerApplication, adoptarSessao, verificarBilhete, esquecerBilhete,
  podeFazer, minhasPermissoes, versaoPermissoes,
};
