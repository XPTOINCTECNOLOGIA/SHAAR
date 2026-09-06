/**
 * SHAAR Guard · versão de servidor
 * ------------------------------------------------------------------
 * A biblioteca de navegador não serve para TETELESTAI e BNEI YISRAEL: são
 * Container Apps, com servidor próprio. Nelas a verificação tem de acontecer
 * ANTES de servir qualquer rota — verificar no navegador uma aplicação que
 * tem servidor seria pedir ao cliente que se autorize a si mesmo.
 *
 *   import { guardaShaar } from "./shaar-guard-servidor.mjs";
 *   app.use(guardaShaar({ app: "TETELESTAI", modo: "observar" }));
 *
 * Mesma chave pública, mesmas regras, mesmo modo de observação. O que muda é
 * onde corre e o que faz com o veredicto: em vez de redireccionar o
 * navegador, devolve 403 — que é o que o briefing pede para quem tem token
 * válido mas não tem direito àquela aplicação.
 *
 * Sem dependências: usa o `crypto` do Node e `fetch`, ambos nativos desde o
 * Node 18. Uma fronteira de segurança com árvore de dependências é uma
 * superfície de ataque a mais.
 */

import { createPublicKey, createVerify } from "node:crypto";

const PADRAO = {
  api: "https://api.xptoinc.com.br",
  shaar: "https://shaar.xptoinc.com.br",
  modo: "exigir",              // "exigir" | "observar"
  margemSegundos: 60,
  cacheChavesSegundos: 3600,
  /** rotas que passam sem bilhete. O health check é a única excepção que o
   *  briefing admite; o resto da lista deve ficar vazio. */
  livres: [/^\/health$/, /^\/healthz$/],
};

const b64u = (s) => Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");

let cache = { em: 0, chaves: null };
async function chaves(cfg) {
  const agora = Date.now() / 1000;
  if (cache.chaves && agora - cache.em < cfg.cacheChavesSegundos) return cache.chaves;
  const r = await fetch(`${cfg.api}/functions/v1/shaar-jwks`);
  if (!r.ok) throw new Error("JWKS indisponível");
  const { keys } = await r.json();
  const mapa = new Map();
  for (const jwk of keys) mapa.set(jwk.kid, createPublicKey({ key: jwk, format: "jwk" }));
  cache = { em: agora, chaves: mapa };
  return mapa;
}

/** Verifica um bilhete. Devolve { ok, motivo, dados }. Nunca lança. */
export async function verificarBilhete(bilhete, opcoes = {}) {
  const cfg = { ...PADRAO, ...opcoes };
  try {
    const partes = String(bilhete || "").split(".");
    if (partes.length !== 3) return { ok: false, motivo: "malformado" };
    const [cab, pay, ass] = partes;

    const cabecalho = JSON.parse(b64u(cab).toString());
    // o alg vem do bilhete: aceitá-lo como veio deixaria escolher "none"
    if (cabecalho.alg !== "RS256") return { ok: false, motivo: "algoritmo_recusado" };

    const chave = (await chaves(cfg)).get(cabecalho.kid);
    if (!chave) return { ok: false, motivo: "kid_desconhecido" };

    const v = createVerify("RSA-SHA256");
    v.update(`${cab}.${pay}`);
    v.end();
    if (!v.verify(chave, b64u(ass))) return { ok: false, motivo: "assinatura_invalida" };

    const d = JSON.parse(b64u(pay).toString());
    const agora = Math.floor(Date.now() / 1000);
    const m = cfg.margemSegundos;

    if (d.iss !== `${cfg.api}/shaar`)   return { ok: false, motivo: "emissor_errado", dados: d };
    if (cfg.app && d.aud !== cfg.app)   return { ok: false, motivo: "destinatario_errado", dados: d };
    if (typeof d.exp !== "number" || d.exp + m < agora) return { ok: false, motivo: "expirado", dados: d };
    if (typeof d.nbf === "number" && d.nbf - m > agora) return { ok: false, motivo: "ainda_nao_vale", dados: d };

    return { ok: true, dados: d };
  } catch (e) {
    return { ok: false, motivo: "erro_verificacao", detalhe: String(e && e.message) };
  }
}

/**
 * Middleware Express/Connect.
 * O bilhete chega no cabeçalho `x-shaar-bilhete` ou num cookie de mesmo nome.
 */
export function guardaShaar(opcoes = {}) {
  const cfg = { ...PADRAO, ...opcoes };
  if (!cfg.app) throw new Error("shaar-guard: falta o código da aplicação");

  return async function (req, res, next) {
    const caminho = (req.path || req.url || "").split("?")[0];
    if (cfg.livres.some((re) => re.test(caminho))) return next();

    const doCabecalho = req.headers["x-shaar-bilhete"];
    const doCookie = (req.headers.cookie || "")
      .split(";").map((c) => c.trim())
      .find((c) => c.startsWith("shaar_bilhete="));
    const bilhete = doCabecalho || (doCookie ? decodeURIComponent(doCookie.slice(14)) : null);

    const v = bilhete
      ? await verificarBilhete(bilhete, cfg)
      : { ok: false, motivo: "sem_bilhete" };

    if (v.ok) { req.shaar = v.dados; return next(); }

    if (cfg.modo === "observar") {
      // não barra: regista o que teria acontecido, para se ver quem seria
      // barrado antes de barrar de facto
      console.warn(`[shaar-guard] ${cfg.app} ${caminho}: seria barrado (${v.motivo})`);
      req.shaar = null;
      return next();
    }

    // 403 mesmo com token válido do ecossistema: é o caso do briefing
    res.statusCode = 403;
    res.setHeader("content-type", "application/json; charset=utf-8");
    res.setHeader("cache-control", "no-store");
    res.end(JSON.stringify({
      erro: "sem_acesso",
      motivo: v.motivo,
      entrar: `${cfg.shaar}?app=${encodeURIComponent(cfg.app)}`,
    }));
  };
}

export default { guardaShaar, verificarBilhete };
