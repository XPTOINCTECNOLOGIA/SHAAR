/**
 * SHAAR Guard · declarações de tipo
 *
 * Vive ao lado de shaar-guard.js e viaja com ele. Sem isto, cada aplicação em
 * TypeScript teria de silenciar o import ou inventar os seus próprios tipos —
 * e nove aplicações inventando tipos para a mesma coisa é como as definições
 * divergem.
 */

/** O que o bilhete afirma. Tudo vem da base do SHAAR, nunca do navegador. */
export interface Identidade {
  /** emissor: sempre o SHAAR */
  iss: string;
  /** destinatário: o código da aplicação a que este bilhete serve */
  aud: string;
  /** id da pessoa em public.users, como texto */
  sub: string;
  email: string;
  nome: string | null;
  perfil: string | null;
  nivel: number;
  cargo: string | null;
  iat: number;
  nbf: number;
  exp: number;
  /** identificador único deste bilhete */
  jti: string;
  /**
   * Sessão do ecossistema, entregue pelo SHAAR só na chegada. É o que dispensa
   * novo login: a aplicação deve passá-la ao seu cliente Supabase com
   * `supabase.auth.setSession(sessao)` ANTES de renderizar.
   */
  sessao?: { access_token: string; refresh_token: string } | null;
}

export type MotivoRecusa =
  | "sem_bilhete"
  | "malformado"
  | "algoritmo_recusado"
  | "kid_desconhecido"
  | "assinatura_invalida"
  | "emissor_errado"
  | "destinatario_errado"
  | "expirado"
  | "ainda_nao_vale"
  | "erro_verificacao";

export interface Veredicto {
  ok: boolean;
  motivo?: MotivoRecusa;
  detalhe?: string;
  /** presente mesmo em algumas recusas, para o registo saber de quem se trata */
  dados?: Identidade;
}

export interface Opcoes {
  /** código da aplicação, tal como está em shaar_apps.code */
  app: string;
  /**
   * "exigir"   — sem bilhete válido, manda a pessoa ao SHAAR
   * "observar" — verifica e regista, mas deixa passar. Para estrear em
   *              produção sem risco de trancar alguém fora.
   */
  modo?: "exigir" | "observar";
  shaar?: string;
  api?: string;
  /** tolerância de relógio entre máquinas, em segundos */
  margemSegundos?: number;
  /** quantos segundos antes de expirar se vai buscar bilhete novo */
  renovarAntesDe?: number;
  /** chamado em modo de observação, com o veredicto */
  aoObservar?: (veredicto: Veredicto) => void;
}

/**
 * Regista a aplicação na fronteira do SHAAR.
 * Devolve a identidade do bilhete, ou null quando não há bilhete válido
 * (em modo "exigir" a navegação já terá sido redireccionada).
 */
export function registerApplication(opcoes: Opcoes): Promise<Identidade | null>;

/** Verifica um bilhete isolado. Nunca lança. */
export function verificarBilhete(
  bilhete: string,
  opcoes?: Partial<Opcoes>,
): Promise<Veredicto>;

/** Apaga o bilhete guardado nesta aba. */
export function esquecerBilhete(app: string): void;

declare const _default: {
  registerApplication: typeof registerApplication;
  verificarBilhete: typeof verificarBilhete;
  esquecerBilhete: typeof esquecerBilhete;
};
export default _default;
