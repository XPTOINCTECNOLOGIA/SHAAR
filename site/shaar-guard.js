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

const b64u = (s) => {
  const p = s.replace(/-/g, "+").replace(/_/g, "/");
  return atob(p + "=".repeat((4 - (p.length % 4)) % 4));
};
const bytes = (s) => Uint8Array.from(b64u(s), (c) => c.charCodeAt(0));
const carga = (t) => JSON.parse(new TextDecoder().decode(bytes(t.split(".")[1])));

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
  for (const k of ["bilhete", "at", "rt"]) p.delete(k);
  const resto = p.toString();
  // fragmento e não query: não vai em logs de servidor nem no cabeçalho Referer.
  // Apagamos assim que consumimos, para não ficar no histórico do navegador.
  history.replaceState(null, "", location.pathname + location.search + (resto ? `#${resto}` : ""));
  return { bilhete: b, sessao: at ? { access_token: at, refresh_token: rt || "" } : null };
}

function irAoShaar(cfg, app, motivo) {
  const destino = new URL(cfg.shaar);
  destino.searchParams.set("app", app);
  destino.searchParams.set("de", location.href);
  if (motivo) destino.searchParams.set("motivo", motivo);
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
  return { ...v.dados, sessao: colhido && colhido.sessao };
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
    if (eu && eu.sessao && eu.sessao.access_token) {
      await supabase.auth.setSession({
        access_token: eu.sessao.access_token,
        refresh_token: eu.sessao.refresh_token || "",
      });
    }
    const { data } = await supabase.auth.getSession();
    if (data && data.session) return true;

    console.warn(`[shaar-guard] ${cfg.app}: a sessão não colou`);
    if (cfg.modo !== "observar") {
      esquecerBilhete(cfg.app);
      irAoShaar(cfg, cfg.app, "sessao_nao_colou");
    }
    return false;
  } catch (e) {
    console.warn(`[shaar-guard] ${cfg.app}: erro ao adoptar a sessão:`, e);
    if (cfg.modo !== "observar") {
      esquecerBilhete(cfg.app);
      irAoShaar(cfg, cfg.app, "sessao_erro");
    }
    return false;
  }
}

export default { registerApplication, adoptarSessao, verificarBilhete, esquecerBilhete };
