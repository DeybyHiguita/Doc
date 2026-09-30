# 🔗 Filtros en la URL (Angular 20) — guía reutilizable

Guía para que **cualquier listado** guarde sus filtros, orden y página en la URL. Así un enlace copiado abre exactamente la misma vista, F5 no pierde nada, y los botones **atrás** y **adelante** deshacen y rehacen filtros.

```text
/cursos?f=eyJ2IjoxLCJzIjoiZXhjZWwiLCJtIjoiViIsInAiOjJ9.1x9k2qd
```

Los filtros viajan en **un solo parámetro codificado**: no se leen a simple vista y no se pueden editar a mano sin invalidarlos.

La guía deja **cuatro piezas compartidas** en `shared` y muestra cómo aplicarlas a tres pantallas:

| Pantalla | Filtros |
|---|---|
| Listado de cursos | búsqueda, modalidad, ID pendiente, orden, dirección, página |
| Grupos de usuarios | búsqueda, página |
| Certificados (ejemplo) | tipo de solicitud, fecha inicio, fecha fin, estados (selección múltiple), página |

- **Stack:** Angular 20 · signals · Router · RxJS · SSR
- **Reemplaza a:** la sección 8 de [listado-cursos-angular.md](listado-cursos-angular.md). Los enlaces generados con esa versión **siguen funcionando** con esta.

---

## 1. 🧐 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **"Parámetros no legibles."** Base64 no es cifrado; cifrar en el navegador tampoco sirve, porque la clave queda en el bundle. | El token se **ofusca** (Base64URL + suma de verificación). No se lee a simple vista ni se edita a mano, pero **nunca** lleva datos sensibles. El backend valida permisos en cada consulta. |
| 2 | **Enlaces alterados o cortados.** | La suma de verificación rechaza el token completo. Además, cada campo se valida contra una lista blanca: un valor inválido cae a su predeterminado sin afectar a los demás. La URL se corrige sola **sin** crear entrada en el historial. |
| 3 | **Un token de otra pantalla.** | Cada pantalla tiene su **ámbito** (`courses`, `user-groups`…) y la suma de verificación lo incluye. Un token de Certificados no se acepta en Cursos. |
| 4 | **Cambiar el formato más adelante.** | El token lleva **versión**. Si cambias claves o códigos, subes la versión y los enlaces viejos se descartan sin errores. |
| 5 | **URLs largas.** | Claves de una letra, códigos cortos y **solo** los valores distintos al predeterminado. Sin filtros, no hay parámetro. |
| 6 | **Historial.** Si cada tecla del buscador crea una entrada, "atrás" no sirve. | El buscador tiene un rebote de 350 ms antes de tocar la URL. Cada cambio de filtro, orden o página sí crea entrada. |
| 7 | **Bucle URL ⇄ estado.** | Se compara el **token canónico** en ambos sentidos: si es igual, no se hace nada. |
| 8 | **Cada pantalla reescribiendo lo mismo.** | Una pantalla solo **declara** sus campos (`defineUrlQuery`) y llama a una función (`syncQueryWithUrl`). Toda la lógica vive en `shared`. |
| 9 | **Perder los filtros al ir a editar y volver.** | Los enlaces de ida y vuelta conservan el parámetro con `queryParamsHandling: 'preserve'`. |
| 10 | **Primera carga con filtros.** Si la URL se aplica tarde, sale una petición sin filtros y luego otra con ellos. | La sincronización se llama en el **constructor** de la página: la primera petición ya lleva los filtros del enlace, incluso con SSR. |

---

## 2. 🔄 Cómo funciona

```text
                         ┌────────────────────────────┐
   enlace / F5 / atrás   │  URL  ?f=<payload>.<suma>  │
 ───────────────────────►│                            │
                         └──────┬──────────────▲──────┘
                                │              │
             queryParamMap      │              │  router.navigate
             (URL → estado)     │              │  (estado → URL)
                                ▼              │
                    ┌──────────────────────────┴──────┐
                    │ codec.fromToken   codec.toToken │  ← defineUrlQuery (por pantalla)
                    │  · verifica suma y ámbito       │
                    │  · valida campo por campo       │
                    │  · aplica reglas entre campos   │
                    └──────────┬───────────▲──────────┘
                               │           │
                     setQuery  │           │  query (signal de solo lectura)
                               ▼           │
                    ┌──────────────────────┴──────────┐
                    │            Facade               │ ──► API (una sola petición)
                    └─────────────────────────────────┘
```

- **URL → estado:** se decodifica el token, se valida y se reemplaza la consulta de la facade. Si el token venía alterado o con valores por defecto, la URL se reescribe con el token canónico usando `replaceUrl`.
- **Estado → URL:** cada cambio de la consulta produce su token. Si es distinto al de la URL, se navega a la misma ruta con el nuevo parámetro.

---

## 3. 📁 Archivos

```text
src/app/shared/
├── utils/
│   └── url-state.ts                        token: base64url + versión + suma de verificación
└── url-query/
    ├── url-query-fields.ts                 ⭐ cómo se guarda cada tipo de campo
    ├── url-query.ts                        ⭐ defineUrlQuery: el esquema de cada pantalla
    ├── sync-query-with-url.ts              ⭐ sincroniza facade ⇄ URL
    └── search-draft.ts                     buscador con rebote que respeta atrás / adelante

src/app/features/<feature>/application/
└── <feature>-query.url.ts                  el esquema de esa pantalla (≈ 15 líneas)
```

---

## 4. Paso 1 — `shared/utils/url-state.ts`

Si ya lo creaste con la guía del listado de cursos, reemplázalo por esta versión: solo agrega el parámetro `version` y los tokens existentes siguen siendo válidos.

```ts
/**
 * Estado de pantalla en un solo parámetro de URL.
 *
 *   token = base64url(JSON) + "." + suma(ámbito + payload)
 *
 * ⚠️ Esto OFUSCA, no cifra. Cualquiera puede decodificar el JSON.
 *    Sirve para que la URL no se lea a simple vista y no se edite a mano.
 *    Nunca pongas aquí datos sensibles; el backend valida permisos siempre.
 */

const DEFAULT_VERSION = 1;
const MAX_TOKEN_LENGTH = 1500;

export type UrlStatePayload = Record<string, string | number | boolean>;

/** null si no hay nada que guardar: así la URL queda limpia. */
export function encodeUrlState(scope: string, state: UrlStatePayload, version = DEFAULT_VERSION): string | null {
  const entries = Object.entries(state).filter(([, value]) => value !== '' && value !== undefined && value !== null);
  if (!entries.length) return null;

  const json = JSON.stringify({ v: version, ...Object.fromEntries(entries) });
  const payload = toBase64Url(new TextEncoder().encode(json));
  return `${payload}.${checksum(scope, payload)}`;
}

/** null si el token falta, está alterado, es de otro ámbito o de otra versión. */
export function decodeUrlState(
  scope: string,
  token: string | null | undefined,
  version = DEFAULT_VERSION,
): Record<string, unknown> | null {
  if (!token || token.length > MAX_TOKEN_LENGTH) return null;

  const parts = token.split('.');
  if (parts.length !== 2) return null;

  const [payload, sum] = parts;
  if (!payload || sum !== checksum(scope, payload)) return null;

  try {
    const data: unknown = JSON.parse(new TextDecoder().decode(fromBase64Url(payload)));
    if (!data || typeof data !== 'object' || Array.isArray(data)) return null;

    const { v, ...rest } = data as Record<string, unknown>;
    return v === version ? rest : null;
  } catch {
    return null;
  }
}

// ── Base64URL con soporte de tildes y ñ ─────────────────────────────

function toBase64Url(bytes: Uint8Array): string {
  let binary = '';
  bytes.forEach((byte) => (binary += String.fromCharCode(byte)));
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(value: string): Uint8Array {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

/** FNV-1a de 32 bits en base 36. No es criptográfico: detecta tokens alterados, cortados o de otra pantalla. */
function checksum(scope: string, value: string): string {
  const input = `${scope}:${value}`;
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36);
}
```

`btoa`, `atob`, `TextEncoder` y `TextDecoder` existen en el navegador y en Node 18+, así que funciona con SSR.

---

## 5. Paso 2 — `shared/url-query/url-query-fields.ts`

Cada tipo de filtro tiene su **codec**: cómo se escribe en el token y cómo se valida al leerlo. Una pantalla combina los que necesita.

```ts
/** Cómo se guarda un campo de la consulta dentro del token. */
export interface FieldCodec<V> {
  /** Clave corta dentro del token: una o dos letras. */
  readonly key: string;
  /** undefined = no se guarda. */
  encode(value: V): string | number | boolean | undefined;
  /** undefined = ausente o inválido: se usa el valor predeterminado. */
  decode(raw: unknown): V | undefined;
}

type Codes<V extends string> = Readonly<Record<V, string>>;

export const urlFields = {
  /** Texto libre (búsqueda). Se recorta y se limita de largo. */
  text(key: string, { max = 100 }: { max?: number } = {}): FieldCodec<string> {
    return {
      key,
      encode: (value) => value.trim() || undefined,
      decode: (raw) => (typeof raw === 'string' ? raw.trim().slice(0, max) : undefined),
    };
  },

  /** Casilla sí/no. Solo viaja cuando está activa. */
  flag(key: string): FieldCodec<boolean> {
    return {
      key,
      encode: (value) => (value ? 1 : undefined),
      decode: (raw) => (raw === 1 ? true : undefined),
    };
  },

  /** Entero dentro de un rango (página). Fuera del rango, se descarta. */
  int(key: string, { min = 1, max = 10_000 }: { min?: number; max?: number } = {}): FieldCodec<number> {
    return {
      key,
      encode: (value) => value,
      decode: (raw) =>
        typeof raw === 'number' && Number.isInteger(raw) && raw >= min && raw <= max ? raw : undefined,
    };
  },

  /** Una opción de una lista cerrada. En el token viaja su código corto, nunca el valor. */
  choice<V extends string>(key: string, codes: Codes<V>): FieldCodec<V> {
    const byCode = invert(codes);
    return {
      key,
      encode: (value) => codes[value],
      decode: (raw) => (typeof raw === 'string' ? byCode.get(raw) : undefined),
    };
  },

  /** Varias opciones de una lista cerrada (ej. estados). Se ordenan para que el token sea único. */
  choiceList<V extends string>(key: string, codes: Codes<V>): FieldCodec<readonly V[]> {
    const all = Object.keys(codes) as V[];
    return {
      key,
      encode: (values) => (values.length ? values.map((value) => codes[value]).sort().join(',') : undefined),
      decode: (raw) => {
        if (typeof raw !== 'string') return undefined;
        const wanted = new Set(raw.split(','));
        return all.filter((value) => wanted.has(codes[value])); // en el orden de la lista, sin desconocidos
      },
    };
  },

  /** Fecha sin hora (yyyy-MM-dd). Viaja compacta: 20260930. Rechaza fechas imposibles como el 30 de febrero. */
  isoDate(key: string): FieldCodec<string | null> {
    return {
      key,
      encode: (value) => (value ? Number(value.replaceAll('-', '')) : undefined),
      decode: (raw) => {
        if (typeof raw !== 'number' || !Number.isInteger(raw)) return undefined;
        const digits = String(raw);
        if (digits.length !== 8) return undefined;
        const iso = `${digits.slice(0, 4)}-${digits.slice(4, 6)}-${digits.slice(6)}`;
        return isValidIsoDate(iso) ? iso : undefined;
      },
    };
  },

  /** Permite "sin valor" (null) en cualquier codec. Ej.: modalidad = null significa "Todas". */
  nullable<V>(codec: FieldCodec<V>): FieldCodec<V | null> {
    return {
      key: codec.key,
      encode: (value) => (value === null ? undefined : codec.encode(value)),
      decode: (raw) => codec.decode(raw),
    };
  },
};

function invert<V extends string>(codes: Codes<V>): ReadonlyMap<string, V> {
  return new Map(Object.entries(codes).map(([value, code]) => [code as string, value as V]));
}

function isValidIsoDate(iso: string): boolean {
  const date = new Date(`${iso}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(iso);
}
```

---

## 6. Paso 3 — `shared/url-query/url-query.ts`

Cada pantalla **declara** su esquema con `defineUrlQuery`. Lo que no está en `fields` (por ejemplo `pageSize`) no viaja en la URL y se conserva tal cual.

```ts
import { UrlStatePayload, decodeUrlState, encodeUrlState } from '@shared/utils/url-state';
import { FieldCodec } from './url-query-fields';

export type UrlQueryFields<T> = { readonly [K in keyof T]?: FieldCodec<T[K]> };

export interface UrlQueryDefinition<T> {
  /** Identifica la pantalla: un token de otra pantalla no se acepta aquí. */
  readonly scope: string;
  /** Súbela si cambias claves o códigos: los enlaces viejos se descartan sin romper nada. */
  readonly version?: number;
  /** Consulta por defecto. Lo que sea igual a esto no viaja en la URL. */
  readonly defaults: T;
  readonly fields: UrlQueryFields<T>;
  /** Reglas entre campos, ej. "fecha inicio ≤ fecha fin". Se aplica al leer y al escribir. */
  readonly normalize?: (query: T) => T;
}

export interface UrlQueryCodec<T> {
  readonly defaults: T;
  /** null = no hay nada distinto al predeterminado: la URL queda sin parámetro. */
  toToken(query: T): string | null;
  /** Nunca lanza. Los campos que no viajan en la URL se toman de `base`. */
  fromToken(token: string | null, base?: T): T;
}

/** "v" la usa url-state para la versión. */
const RESERVED_KEYS = new Set(['v']);

export function defineUrlQuery<T extends object>(definition: UrlQueryDefinition<T>): UrlQueryCodec<T> {
  const { scope, defaults, version = 1, normalize = (query: T) => query } = definition;

  const fields = (Object.entries(definition.fields) as [string, FieldCodec<unknown> | undefined][]).filter(
    (entry): entry is [string, FieldCodec<unknown>] => entry[1] !== undefined,
  );

  assertValidKeys(scope, fields.map(([, codec]) => codec.key));

  const defaultsRecord = defaults as unknown as Record<string, unknown>;

  const toToken = (query: T): string | null => {
    const normalized = normalize(query) as unknown as Record<string, unknown>;
    const payload: UrlStatePayload = {};

    for (const [name, codec] of fields) {
      if (isSame(normalized[name], defaultsRecord[name])) continue; // lo predeterminado no viaja
      const encoded = codec.encode(normalized[name]);
      if (encoded !== undefined) payload[codec.key] = encoded;
    }

    return encodeUrlState(scope, payload, version);
  };

  const fromToken = (token: string | null, base: T = defaults): T => {
    const raw = decodeUrlState(scope, token, version) ?? {};
    const result: Record<string, unknown> = { ...(base as unknown as Record<string, unknown>) };

    for (const [name, codec] of fields) {
      const decoded = codec.decode(raw[codec.key]);
      result[name] = decoded === undefined ? defaultsRecord[name] : decoded;
    }

    return normalize(result as unknown as T);
  };

  return { defaults, toToken, fromToken };
}

/** Error de programación, no de usuario: aparece al cargar el módulo, no en producción. */
function assertValidKeys(scope: string, keys: readonly string[]): void {
  const seen = new Set<string>();
  for (const key of keys) {
    if (!key || RESERVED_KEYS.has(key) || seen.has(key)) {
      throw new Error(`[url-query:${scope}] La clave "${key}" está vacía, reservada o repetida.`);
    }
    seen.add(key);
  }
}

function isSame(a: unknown, b: unknown): boolean {
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((value, i) => Object.is(value, b[i]));
  }
  return Object.is(a, b);
}
```

---

## 7. Paso 4 — `shared/url-query/sync-query-with-url.ts`

Mantiene la consulta de la facade y la URL iguales en los dos sentidos.

```ts
import { Signal, inject } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { distinctUntilChanged, map } from 'rxjs';
import { UrlQueryCodec } from './url-query';

/** Lo que la facade debe exponer para poder sincronizarse. */
export interface UrlQuerySource<T> {
  /** Consulta actual, de solo lectura. */
  readonly query: Signal<T>;
  /** Reemplaza la consulta completa. La facade decide qué recargar. */
  setQuery(query: T): void;
}

export interface SyncQueryOptions {
  /** Nombre del parámetro. Por defecto "f". */
  readonly param?: string;
}

/**
 * URL → estado: carga inicial, enlace compartido, botones atrás / adelante.
 * Estado → URL: cada filtro, orden o página que cambia el usuario.
 *
 * Llamar en el CONSTRUCTOR de la página (contexto de inyección): así la primera
 * petición ya sale con los filtros del enlace.
 */
export function syncQueryWithUrl<T extends object>(
  source: UrlQuerySource<T>,
  codec: UrlQueryCodec<T>,
  options: SyncQueryOptions = {},
): void {
  const param = options.param ?? 'f';
  const route = inject(ActivatedRoute);
  const router = inject(Router);

  const writeToken = (token: string | null, replaceUrl: boolean) =>
    router.navigate([], {
      relativeTo: route,
      queryParams: { [param]: token }, // null elimina el parámetro
      queryParamsHandling: 'merge',
      replaceUrl,
    });

  // ── URL → estado ──────────────────────────────────────────────────
  // queryParamMap emite de inmediato: el estado queda listo antes de la primera petición.
  route.queryParamMap
    .pipe(
      map((params) => params.get(param)),
      distinctUntilChanged(),
      takeUntilDestroyed(),
    )
    .subscribe((token) => {
      const next = codec.fromToken(token, source.query());
      const canonical = codec.toToken(next);

      if (canonical !== codec.toToken(source.query())) {
        source.setQuery(next);
      }

      // Token alterado, viejo o con valores por defecto: se corrige sin ensuciar el historial.
      if (token !== canonical) {
        void writeToken(canonical, true);
      }
    });

  // ── Estado → URL ──────────────────────────────────────────────────
  toObservable(source.query)
    .pipe(
      map((query) => codec.toToken(query)),
      distinctUntilChanged(),
      takeUntilDestroyed(),
    )
    .subscribe((token) => {
      if (token !== route.snapshot.queryParamMap.get(param)) {
        void writeToken(token, false); // crea entrada: "atrás" deshace el último filtro
      }
    });
}
```

**Por qué no hay bucle:** cuando la URL cambia la consulta, la consulta produce el mismo token que ya está en la URL, así que la segunda suscripción no navega. Cuando la consulta cambia la URL, la URL produce una consulta con el mismo token que la actual, así que la primera no hace `setQuery`.

---

## 8. Paso 5 — `shared/url-query/search-draft.ts`

El buscador necesita dos valores: lo que el usuario **está escribiendo** (inmediato) y lo que **se consulta** (con rebote). Esta función los mantiene coordinados, incluso cuando "atrás" cambia la búsqueda.

```ts
import { WritableSignal, effect, signal, untracked } from '@angular/core';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { debounceTime, distinctUntilChanged, map, skip } from 'rxjs';

/**
 * @param read  lee la búsqueda de la consulta (una signal)
 * @param write aplica una búsqueda nueva a la consulta (la facade vuelve a la página 1)
 * @returns la signal para enlazar al input
 *
 * Llamar en un contexto de inyección (constructor de la página).
 */
export function createSearchDraft(
  read: () => string,
  write: (search: string) => void,
  debounceMs = 350,
): WritableSignal<string> {
  const draft = signal(untracked(read));

  // Consulta → input: enlace compartido, atrás / adelante, "Limpiar filtros".
  // Se compara sin espacios para no borrar el espacio que el usuario está escribiendo.
  effect(() => {
    const current = read();
    untracked(() => {
      if (draft().trim() !== current) draft.set(current);
    });
  });

  // Input → consulta, con rebote: el historial no se llena con cada tecla.
  toObservable(draft)
    .pipe(
      skip(1),
      debounceTime(debounceMs),
      map((value) => value.trim()),
      distinctUntilChanged(),
      takeUntilDestroyed(),
    )
    .subscribe((search) => {
      if (search !== untracked(read)) write(search);
    });

  return draft;
}
```

---

## 9. Paso 6 — Lo que la facade debe cumplir

Para sincronizarse, la facade de cada listado necesita tres cosas:

```ts
// 1. La consulta en solo lectura
private readonly _query = signal<MyQuery>(DEFAULT_MY_QUERY);
readonly query = this._query.asReadonly();

// 2. Reemplazo completo, usado por la sincronización
setQuery(query: MyQuery): void {
  this._query.set(query);
}

// 3. Corrección de página fuera de rango, justo después de recibir el total
const lastPage = Math.max(1, Math.ceil(total / this._query().pageSize));
if (this._query().page > lastPage) {
  this._query.update((q) => ({ ...q, page: lastPage }));
}
```

Y una regla que ya cumplen las facades de estas guías: **cualquier filtro nuevo vuelve a la página 1**. Si no, un enlace puede quedar en la página 4 de un resultado que ahora tiene 1.

---

## 10. ✅ Aplicarlo a una pantalla: los 5 pasos

| # | Qué | Dónde |
|---|---|---|
| 1 | La facade cumple la sección 9 (`query` de solo lectura, `setQuery`, corrección de página). | `application/<feature>.facade.ts` |
| 2 | Declarar el esquema con `defineUrlQuery`: ámbito, valores por defecto y un codec por filtro. | `application/<feature>-query.url.ts` |
| 3 | En el constructor de la página: `syncQueryWithUrl(this.facade, ESQUEMA)`. | `presentation/<feature>-page/…component.ts` |
| 4 | Buscador con `createSearchDraft` en lugar de un `signal` suelto. | Misma página |
| 5 | Enlaces a editar / detalle y de vuelta con `queryParamsHandling: 'preserve'` (sección 14). | Tabla y página de edición |

---

## 11. Aplicación — Listado de cursos

### `features/courses/application/course-query.url.ts`

Reemplaza a la versión de la guía del listado. **Usa las mismas claves y códigos**, así que los enlaces que ya se compartieron siguen abriendo la misma vista.

```ts
import { defineUrlQuery } from '@shared/url-query/url-query';
import { urlFields } from '@shared/url-query/url-query-fields';
import { CourseModality } from '../domain/course-modality.enum';
import { CourseQuery, CourseSortField, SortDirection } from '../domain/course.model';
import { DEFAULT_COURSE_QUERY } from './courses.facade';

export const COURSE_QUERY_URL = defineUrlQuery<CourseQuery>({
  scope: 'courses',
  defaults: DEFAULT_COURSE_QUERY,
  fields: {
    search: urlFields.text('s'),
    modality: urlFields.nullable(
      urlFields.choice<CourseModality>('m', { [CourseModality.Virtual]: 'V', [CourseModality.Onsite]: 'P' }),
    ),
    pendingExternalId: urlFields.flag('x'),
    sort: urlFields.choice<CourseSortField>('o', { name: 'n', dueDate: 'd' }),
    direction: urlFields.choice<SortDirection>('d', { asc: 'a', desc: 'z' }),
    page: urlFields.int('p'),
  },
});
```

Borra `course-query-url.sync.ts`: lo reemplaza `syncQueryWithUrl`.

### En `courses-list-page.component.ts`

```ts
import { syncQueryWithUrl } from '@shared/url-query/sync-query-with-url';
import { createSearchDraft } from '@shared/url-query/search-draft';
import { COURSE_QUERY_URL } from '../../application/course-query.url';

export class CoursesListPageComponent {
  protected readonly facade = inject(CoursesFacade);

  // Reemplaza el signal searchDraft, el effect y la suscripción con rebote de la versión anterior.
  readonly searchDraft = createSearchDraft(
    () => this.facade.query().search,
    (search) => this.facade.patchQuery({ search }),
  );

  constructor() {
    syncQueryWithUrl(this.facade, COURSE_QUERY_URL);
  }

  clearFilters(): void {
    this.facade.clearFilters(); // el buscador se limpia solo: lo sigue la consulta
  }

  // … el resto de la página no cambia
}
```

La plantilla sigue igual: `[value]="searchDraft()"` y `(input)="searchDraft.set($any($event.target).value)"`.

---

## 12. Aplicación — Grupos de usuarios

### Ajuste en `user-groups-list.facade.ts`

```ts
setQuery(query: UserGroupQuery): void {
  this._query.set(query);
}
```

Y en el `subscribe` del constructor, después de `this._total.set(result.page.total)`:

```ts
const lastPage = Math.max(1, Math.ceil(result.page.total / this._query().pageSize));
if (this._query().page > lastPage) this._query.update((q) => ({ ...q, page: lastPage }));
```

### `features/user-groups/application/user-group-query.url.ts`

```ts
import { defineUrlQuery } from '@shared/url-query/url-query';
import { urlFields } from '@shared/url-query/url-query-fields';
import { UserGroupQuery } from '../domain/user-group.model';

export const USER_GROUP_QUERY_URL = defineUrlQuery<UserGroupQuery>({
  scope: 'user-groups',
  defaults: { search: '', page: 1, pageSize: 10 },
  fields: {
    search: urlFields.text('s'),
    page: urlFields.int('p'),
  },
});
```

### En `user-groups-list-page.component.ts`

```ts
export class UserGroupsListPageComponent {
  protected readonly facade = inject(UserGroupsListFacade);

  readonly searchDraft = createSearchDraft(
    () => this.facade.query().search,
    (search) => this.facade.search(search),
  );

  constructor() {
    syncQueryWithUrl(this.facade, USER_GROUP_QUERY_URL);
    // Se elimina la suscripción con rebote que había aquí: la hace createSearchDraft.
  }
}
```

Y los enlaces de la tabla y del botón "Nuevo grupo" conservan el filtro (sección 14).

---

## 13. Ejemplo — Certificados: fechas y selección múltiple

Adáptalo a los tipos reales del módulo de certificados. Muestra dos codecs que las otras pantallas no usan y una regla entre campos.

```ts
import { defineUrlQuery } from '@shared/url-query/url-query';
import { urlFields } from '@shared/url-query/url-query-fields';

// ⬇ Reemplaza por los tipos reales del módulo
type CertificateType = 'LABOR' | 'SEVERANCE' | 'INCOME_WITHHOLDING';
type RequestStatus = 'PENDING' | 'APPROVED' | 'REJECTED';

export interface CertificateQuery {
  readonly requestType: CertificateType | null;
  /** yyyy-MM-dd */
  readonly from: string | null;
  /** yyyy-MM-dd */
  readonly to: string | null;
  readonly statuses: readonly RequestStatus[];
  readonly page: number;
  readonly pageSize: number;
}

export const DEFAULT_CERTIFICATE_QUERY: CertificateQuery = {
  requestType: null,
  from: null,
  to: null,
  statuses: [],
  page: 1,
  pageSize: 10,
};

export const CERTIFICATE_QUERY_URL = defineUrlQuery<CertificateQuery>({
  scope: 'certificates',
  defaults: DEFAULT_CERTIFICATE_QUERY,
  fields: {
    requestType: urlFields.nullable(
      urlFields.choice<CertificateType>('t', { LABOR: 'L', SEVERANCE: 'C', INCOME_WITHHOLDING: 'R' }),
    ),
    from: urlFields.isoDate('a'),
    to: urlFields.isoDate('b'),
    statuses: urlFields.choiceList<RequestStatus>('e', { PENDING: 'p', APPROVED: 'a', REJECTED: 'r' }),
    page: urlFields.int('p'),
  },
  // Si un enlace trae el rango invertido, se voltea en lugar de devolver cero resultados.
  normalize: (query) =>
    query.from && query.to && query.from > query.to ? { ...query, from: query.to, to: query.from } : query,
});
```

> Las fechas de los filtros viajan como `yyyy-MM-dd` de punta a punta (`input type="date"`), sin pasar por `Date`: así no se corren un día por la zona horaria.

---

## 14. Ir a editar y volver sin perder los filtros

El usuario filtró, fue a la página 3 y abrió un registro para editarlo. Al volver, debe estar exactamente donde estaba.

**Ida** — en la tabla del listado:

```html
<a [routerLink]="['/grupos', group.id, 'editar']" queryParamsHandling="preserve">…</a>
<a routerLink="/grupos/nuevo" queryParamsHandling="preserve" class="btn btn-accent">Nuevo grupo</a>
```

**Vuelta** — en la página de edición:

```html
<a routerLink="/grupos" queryParamsHandling="preserve">← Grupos de usuarios</a>
<a routerLink="/grupos" queryParamsHandling="preserve" class="btn btn-outline-secondary">Cancelar</a>
```

```ts
// Después de guardar
await this.router.navigate(['/grupos'], { queryParamsHandling: 'preserve' });
```

La página de edición **no** lee el parámetro `f`: solo lo lleva de vuelta.

Las entradas del **menú** lateral, en cambio, no conservan nada: llevan al listado limpio, que es lo que se espera al entrar desde el menú.

### Botón "Copiar enlace"

```ts
private readonly document = inject(DOCUMENT);
private readonly isBrowser = isPlatformBrowser(inject(PLATFORM_ID));
readonly linkCopied = signal(false);

async copyLink(): Promise<void> {
  if (!this.isBrowser) return;

  try {
    await navigator.clipboard.writeText(this.document.location.href);
    this.linkCopied.set(true);
    setTimeout(() => this.linkCopied.set(false), 2000);
  } catch {
    notifyError('No se pudo copiar el enlace. Cópialo desde la barra de direcciones.');
  }
}
```

`navigator.clipboard` exige HTTPS o `localhost`.

---

## 15. Cambiar el formato sin romper enlaces

| Cambio | ¿Hay que subir la versión? |
|---|---|
| Agregar un filtro nuevo con una clave nueva | **No.** Los enlaces viejos no lo traen y toma su valor por defecto. |
| Agregar una opción nueva a un `choice` | **No.** |
| Quitar un filtro | **No.** La clave vieja se ignora. |
| Cambiar la clave de un filtro (`s` → `q`) | **Sí.** |
| Cambiar el código de una opción (`V` → `VI`) | **Sí.** |
| Cambiar el significado de un valor | **Sí.** |

Al subir la versión (`version: 2` en `defineUrlQuery`), los enlaces viejos abren la vista por defecto y la URL se limpia sola. Si hace falta que sigan funcionando, lee la versión anterior con su propio esquema y convierte el resultado.

---

## 16. 🔒 Seguridad

- **Ofuscar no es cifrar.** Cualquiera con conocimientos técnicos decodifica el token en segundos. Sirve para que la URL no se lea a simple vista y no se edite a mano, nada más.
- **Nunca** pongas en el token cédulas, nombres de empleados, salarios ni ningún dato que no debería ver quien reciba el enlace.
- **El backend valida permisos en cada consulta.** Un enlace compartido a alguien sin permiso debe devolver `403`, no los datos.
- Si algún día un filtro necesita contener algo sensible, la única forma real de ocultarlo es guardarlo en el servidor y que la URL lleve solo un identificador. Está descrito en la sección 9 de [listado-cursos-angular.md](listado-cursos-angular.md).

---

## 17. Pruebas

### Unitarias

```ts
describe('urlFields', () => {
  it('text recorta y limita el largo', () => {
    expect(urlFields.text('s', { max: 5 }).decode('  excel avanzado ')).toBe('excel');
  });

  it('int descarta valores fuera del rango', () => {
    expect(urlFields.int('p').decode(-4)).toBeUndefined();
    expect(urlFields.int('p').decode(2.5)).toBeUndefined();
  });

  it('isoDate rechaza el 30 de febrero', () => {
    expect(urlFields.isoDate('a').decode(20260230)).toBeUndefined();
    expect(urlFields.isoDate('a').decode(20260930)).toBe('2026-09-30');
  });

  it('choiceList ignora códigos desconocidos y conserva el orden de la lista', () => {
    const field = urlFields.choiceList<'A' | 'B' | 'C'>('e', { A: 'a', B: 'b', C: 'c' });
    expect(field.decode('c,x,a')).toEqual(['A', 'C']);
  });
});

describe('defineUrlQuery', () => {
  const Q = defineUrlQuery({
    scope: 'test',
    defaults: { search: '', page: 1, pageSize: 10 },
    fields: { search: urlFields.text('s'), page: urlFields.int('p') },
  });

  it('la consulta por defecto no genera parámetro', () => {
    expect(Q.toToken(Q.defaults)).toBeNull();
  });

  it('ida y vuelta, con tildes y ñ', () => {
    const query = { search: 'Educación en compañía', page: 3, pageSize: 10 };
    expect(Q.fromToken(Q.toToken(query))).toEqual(query);
  });

  it('el token no deja leer el valor a simple vista', () => {
    expect(Q.toToken({ search: 'excel', page: 1, pageSize: 10 })).not.toContain('excel');
  });

  it('conserva lo que no viaja en la URL', () => {
    const token = Q.toToken({ search: 'x', page: 1, pageSize: 10 });
    expect(Q.fromToken(token, { search: '', page: 1, pageSize: 50 }).pageSize).toBe(50);
  });

  it('un token alterado devuelve la consulta por defecto', () => {
    const token = Q.toToken({ search: 'x', page: 2, pageSize: 10 })!;
    const tampered = token.replace(/^./, (c) => (c === 'a' ? 'b' : 'a'));
    expect(Q.fromToken(tampered)).toEqual(Q.defaults);
  });

  it('rechaza un token de otra pantalla', () => {
    const other = defineUrlQuery({ scope: 'otra', defaults: Q.defaults, fields: { page: urlFields.int('p') } });
    expect(Q.fromToken(other.toToken({ search: '', page: 4, pageSize: 10 })).page).toBe(1);
  });

  it('falla al definir una clave repetida', () => {
    expect(() =>
      defineUrlQuery({ scope: 'x', defaults: { a: '', b: '' }, fields: { a: urlFields.text('s'), b: urlFields.text('s') } }),
    ).toThrowError(/repetida/);
  });
});

describe('CERTIFICATE_QUERY_URL', () => {
  it('voltea un rango de fechas invertido', () => {
    const query = { ...DEFAULT_CERTIFICATE_QUERY, from: '2026-12-31', to: '2026-01-01' };
    const result = CERTIFICATE_QUERY_URL.fromToken(CERTIFICATE_QUERY_URL.toToken(query));
    expect([result.from, result.to]).toEqual(['2026-01-01', '2026-12-31']);
  });
});
```

### De la sincronización

```ts
@Component({ template: '' })
class TestPageComponent {
  private readonly _query = signal({ search: '', page: 1, pageSize: 10 });
  readonly source = { query: this._query.asReadonly(), setQuery: (q: typeof Q.defaults) => this._query.set(q) };

  constructor() {
    syncQueryWithUrl(this.source, Q);
  }
}

it('aplica los filtros del enlace al abrir la página', async () => {
  TestBed.configureTestingModule({ providers: [provideRouter([{ path: 'lista', component: TestPageComponent }])] });
  const harness = await RouterTestingHarness.create();
  const token = Q.toToken({ search: 'norte', page: 2, pageSize: 10 });

  const page = await harness.navigateByUrl(`/lista?f=${token}`, TestPageComponent);

  expect(page.source.query()).toEqual({ search: 'norte', page: 2, pageSize: 10 });
});

it('limpia un token alterado sin crear entrada en el historial', async () => {
  TestBed.configureTestingModule({ providers: [provideRouter([{ path: 'lista', component: TestPageComponent }])] });
  const harness = await RouterTestingHarness.create();

  await harness.navigateByUrl('/lista?f=basura.123', TestPageComponent);
  await harness.fixture.whenStable();

  expect(TestBed.inject(Router).url).toBe('/lista');
});
```

### Revisión manual (hazla en cada pantalla)

- Sin filtros: la URL no tiene `?f=`.
- Aplica varios filtros y ve a la página 2; copia el enlace y ábrelo en una ventana de incógnito: aparece exactamente la misma vista.
- La barra de direcciones no muestra los valores de los filtros.
- Cambia un carácter del token y recarga: aparece la vista por defecto y la URL se limpia sola.
- Pega el token de otra pantalla: se ignora.
- Escribe en el buscador: la URL cambia **una** vez, al dejar de escribir.
- Cambia dos filtros y presiona **atrás** dos veces: se deshacen uno por uno, y el buscador muestra el valor correcto.
- Abre un enlace a la página 5 cuando solo hay 2: queda en la página 2.
- Filtra, ve a la página 3, abre un registro para editar y vuelve (con el botón, con "Cancelar" y después de guardar): sigues en la página 3 con los mismos filtros.
- En DevTools → Network, al abrir un enlace con filtros sale **una sola** petición, y ya con los filtros.
- Con SSR: la página llega del servidor ya filtrada, sin parpadeo.

---

## 18. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| Al abrir un enlace salen dos peticiones: una sin filtros y otra con ellos | `syncQueryWithUrl` se llamó en `ngOnInit` o en `afterNextRender` | Llámala en el **constructor** de la página. |
| El historial se llena con cada tecla | El input escribe directo en la consulta | Usa `createSearchDraft`: solo el rebote toca la consulta. |
| Mientras escribes, desaparece el espacio final | El effect sobrescribe el input con la búsqueda recortada | `createSearchDraft` compara con `trim()`; no lo quites. |
| "Atrás" no actualiza el buscador | El input tiene un `signal` propio que nadie sincroniza | Usa la signal que devuelve `createSearchDraft`. |
| La URL cambia sola en bucle | La facade transforma la consulta en `setQuery` (ej. recorta la búsqueda) y el token ya no coincide | Pon esas reglas en `normalize` del esquema, no en la facade. |
| `InvalidCharacterError` en `btoa` | Texto con tildes pasado directo a `btoa` | `url-state.ts` usa `TextEncoder` antes; no lo cambies. |
| Los selects no muestran el filtro del enlace | `[value]` en el `<select>` se aplica antes de que existan las opciones | Usa `[selected]` en cada `<option>`. |
| Al volver de editar se pierden los filtros | Falta `queryParamsHandling="preserve"` en algún enlace | Revísalo en la ida, en "Volver", en "Cancelar" y en la navegación después de guardar. |
| Los guards se ejecutan en cada filtro | La ruta tiene `runGuardsAndResolvers: 'always'` | Quítalo: cada filtro navega y no necesita volver a validar permisos. |
| Un input de la página recibe el token | La app usa `withComponentInputBinding()` y la página tiene un `input()` llamado `f` | No nombres `f` a ningún input de una página con filtros en la URL. |
| `[url-query:…] La clave "v" está vacía, reservada o repetida` | Se usó `v` o una clave repetida en `fields` | `v` está reservada para la versión; usa otra letra. |

---

## ✅ Checklist por pantalla

- [ ] La facade expone `query` de solo lectura, `setQuery` y corrige la página fuera de rango.
- [ ] Cualquier filtro nuevo vuelve a la página 1.
- [ ] Esquema declarado con `defineUrlQuery`: ámbito propio, valores por defecto y un codec por filtro.
- [ ] Reglas entre campos en `normalize`, no en la facade.
- [ ] `syncQueryWithUrl` llamado en el constructor de la página.
- [ ] Buscador con `createSearchDraft`.
- [ ] Enlaces a editar y de vuelta con `queryParamsHandling: 'preserve'`.
- [ ] La ruta no tiene `runGuardsAndResolvers: 'always'`.
- [ ] Nada sensible dentro del token.
- [ ] Revisión manual de la sección 17 completa.
