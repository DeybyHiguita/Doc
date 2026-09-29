# 📋 Listado de cursos con filtros en la URL (Angular 20 + Bootstrap 5)

Guía paso a paso para construir la pantalla **Módulo de Cursos**: la tabla de cursos creados, con filtros, orden, paginación y botones de acción para **editar** y **eliminar**.

Replica el diseño de **Módulo de Certificados** (`/certificates`): encabezado con título y subtítulo, tarjeta "Listado de…" con botón principal, fila de filtros, tabla con encabezado de color, estados en píldoras, acciones con botones de ícono y paginación "Página 1 de N".

Los filtros viajan en la URL en **un solo parámetro codificado**, para que la URL se pueda compartir sin que el usuario vea ni edite los filtros a mano:

```text
/cursos?f=eyJ2IjoxLCJzIjoiZXhjZWwiLCJtIjoiViIsInAiOjJ9.1x9k2qd
```

- **Stack:** Angular 20 · standalone · signals · OnPush · Bootstrap 5.3 · Font Awesome · SweetAlert2 · SSR · MSAL
- **Depende de:** [crud-cursos-angular.md](crud-cursos-angular.md). De esa guía se reutilizan el dominio, los servicios, la facade, el panel de edición (`app-course-editor`), el buscador de usuarios y los tokens de color.

---

## 1. 🧐 Revisión crítica del requerimiento

| # | Hueco o riesgo | Decisión |
|---|---|---|
| 1 | **"Parámetros no legibles".** Codificar en Base64 **no es cifrar**: cualquiera lo decodifica en segundos. Cifrar en el navegador tampoco sirve, porque la clave queda en el bundle. | El parámetro se **ofusca** (Base64URL + suma de verificación): no se lee a simple vista y no se puede editar a mano sin invalidarlo. **Nunca** se pone ahí algo sensible, y el backend sigue validando permisos en cada consulta. Si algún día hace falta ocultar de verdad, ver la sección 9. |
| 2 | **Enlaces editados o cortados.** Un enlace copiado a medias o modificado a mano puede traer valores absurdos (`page: -5`, modalidad inventada). | La suma de verificación rechaza tokens alterados. Además, cada campo se valida contra una lista blanca. Si algo falla, se usan los valores por defecto y la URL se limpia **sin** crear entrada en el historial. |
| 3 | **Tokens de otra pantalla.** Si certificados usa el mismo mecanismo, un token de allá podría interpretarse aquí. | La suma de verificación incluye un **ámbito** (`courses`). Un token de otra pantalla no pasa la verificación. |
| 4 | **Cambios de formato futuros.** Si mañana cambian las claves, los enlaces viejos rompen la página. | El token lleva versión (`v: 1`). Una versión desconocida se descarta sin errores. |
| 5 | **URL larga.** JSON con nombres de campo completos genera URLs enormes. | Claves de una letra y **solo** los valores que difieren del predeterminado. Sin filtros, no hay parámetro. |
| 6 | **Botón atrás.** Si cada tecla del buscador crea una entrada en el historial, "atrás" se vuelve inútil. | El buscador pasa por un rebote de 350 ms antes de tocar la URL. Filtros y páginas sí crean entrada: "atrás" deshace el último filtro. |
| 7 | **Bucle URL ⇄ estado.** Escribir la URL al cambiar el estado, y el estado al cambiar la URL, puede entrar en ciclo. | Se compara el token canónico en ambos sentidos: si es igual, no se hace nada. |
| 8 | **¿Editar en otra página o en panel?** Certificados usa `/certificates/new`. | Crear y editar abren el panel lateral de la guía anterior. La tabla y los filtros quedan detrás, y al guardar la lista se refresca en el mismo lugar. Si prefieres una ruta aparte (`/cursos/:id/editar`), mira la sección 10. |
| 9 | **Filtro por texto del servidor.** Si se filtra la página cargada en el navegador, los cursos de la página 3 nunca aparecen. | Búsqueda, filtros, orden y paginación se aplican **en el servidor**. |
| 10 | **Tabla en móvil.** Seis columnas no caben en 360 px. | Por debajo de `md`, cada fila se convierte en una tarjeta con etiquetas. |

---

## 2. 🎨 Diseño

### Escritorio

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Módulo de Cursos                                                             │
│ Crea, asigna y gestiona los cursos de manera fácil y rápida                  │
│                                                                              │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Listado de Cursos                    [🔗 Copiar enlace] [📅+ Nuevo Curso] │ │
│ │ ──────────────────────────────────────────────────────────────────────── │ │
│ │ Buscar                     Modalidad               ID externo            │ │
│ │ [🔍 Nombre o ID externo ]   [Todas            ▾]    [Todos           ▾]   │ │
│ │                                                          ✕ Limpiar filtros│ │
│ │ ┌──────────────────────────────────────────────────────────────────────┐ │ │
│ │ │ NOMBRE ⇅      MODALIDAD    ID EXTERNO   ASIGNADOS  FECHA LÍMITE ⇅ ACC. │ │ │ ← color de acento
│ │ ├──────────────────────────────────────────────────────────────────────┤ │ │
│ │ │ Excel avanz.  (Virtual)    LMS-2231        32      30/10/2026   [✎][🗑]│ │ │
│ │ │                                                    En 31 días         │ │ │
│ │ │ Primeros aux. (Presencial) No aplica       12      15/12/2026   [✎][🗑]│ │ │
│ │ │ Liderazgo     (Virtual)    (Pendiente)      0      —            [✎][🗑]│ │ │
│ │ └──────────────────────────────────────────────────────────────────────┘ │ │
│ │                                                                          │ │
│ │                        (‹)  Página 1 de 2  (›)                           │ │
│ │                           24 cursos en total                             │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Móvil (< 768 px)

```text
┌────────────────────────────┐
│ Excel avanzado para an…    │
│ Modalidad       (Virtual)  │
│ ID externo       LMS-2231  │
│ Asignados              32  │
│ Fecha límite   30/10/2026  │
│                  [✎] [🗑]  │
└────────────────────────────┘
```

### Equivalencias con Certificados

| Certificados | Cursos |
|---|---|
| Módulo de Certificados / subtítulo | Módulo de Cursos / subtítulo |
| Listado de Certificados + **Nuevo Certificado** | Listado de Cursos + **Nuevo Curso** (+ **Copiar enlace**) |
| Filtros: Tipo de solicitud, Fecha inicio, Fecha fin | Filtros: Buscar, Modalidad, ID externo |
| Columnas: Tipo, Motivo, Fecha, Observaciones, Estado, Acciones | Columnas: Nombre, Modalidad, ID externo, Asignados, Fecha límite, Acciones |
| Píldora Aprobada / Pendiente | Píldora Virtual / Presencial y píldora **Pendiente** del ID |
| Acciones ver, descargar, editar, eliminar | Acciones **editar** y **eliminar** |
| Página 1 de 1 con flechas redondas | Igual |

### Movimiento

| Elemento | Qué hace |
|---|---|
| Filas | Entran en cascada (máximo 10 escalones de 35 ms). |
| Fila en hover | Fondo con tinte del acento y una barra lateral que aparece a la izquierda. |
| Botones de acción | Suben 2 px en hover y se encogen al presionar. Eliminar se tiñe de rojo. |
| Encabezados ordenables | La flecha rota al invertir el orden. |
| Recarga con datos | La tabla se atenúa en lugar de desaparecer. |
| Copiar enlace | El ícono cambia a ✓ por 2 s. |

Todo se apaga con `prefers-reduced-motion`.

### Accesibilidad

- `<table>` real con `<caption>` oculto, `scope="col"` y `aria-sort` en las columnas ordenables. El orden se cambia con un `<button>` dentro del encabezado.
- Los botones de acción tienen `aria-label` con el nombre del curso ("Editar Excel avanzado"), no solo el ícono.
- La zona de resultados tiene `aria-live="polite"` y `aria-busy`.
- En móvil, cada celda muestra su etiqueta con `data-label`, así la tabla sigue teniendo sentido sin encabezado visible.

---

## 3. 📁 Archivos

```text
src/app/shared/utils/
└── url-state.ts                                ⭐ codifica / decodifica estado en un token (reutilizable)

src/app/features/courses/
├── domain/
│   └── course.model.ts                          ✏️ se agrega el orden a CourseQuery
├── infraestructure/
│   └── courses.service.ts                       ✏️ envía sort y direction
├── application/
│   ├── courses.facade.ts                        ✏️ consulta por defecto exportada + toggleSort
│   ├── course-query.url.ts                      ⭐ CourseQuery ⇄ token, con validación
│   └── course-query-url.sync.ts                 ⭐ sincroniza la consulta con la URL
└── presentation/
    ├── _courses-tokens.scss                     tokens de color como mixin (compartidos)
    ├── courses-table/                           ⭐ la tabla (presentacional)
    │   ├── courses-table.component.ts
    │   ├── courses-table.component.html
    │   └── courses-table.component.scss
    └── courses-list-page/                       ⭐ la página
        ├── courses-list-page.component.ts
        ├── courses-list-page.component.html
        └── courses-list-page.component.scss
```

Esta página reemplaza a `courses-page` (la de tarjetas) como pantalla de `/cursos`. `course-editor`, `user-picker`, `course-feedback` y todo `domain`, `infraestructure` y `application` de la guía anterior se usan tal cual, salvo los cambios marcados con ✏️. Si nunca construiste la página de tarjetas, sáltate `courses-page` y `course-card`.

> Si la página de Certificados ya tiene estilos compartidos para la tabla, la paginación o los botones de acción (por ejemplo en `@shared-styles`), úsalos en lugar de los de esta guía. El objetivo es que las dos pantallas se vean idénticas, y eso se logra mejor con las mismas clases. Lo mismo aplica a `shared/components/pagination`, `skeleton-loader` y `confirmation-dialog-component`: ver la tabla de reutilización en la guía de CRUD (sección 3).

---

## 4. Paso 1 — Tokens de color compartidos

En la guía anterior los tokens vivían en el `:host` de `courses-page`. Ahora dos páginas los necesitan, así que pasan a un mixin.

### `presentation/_courses-tokens.scss`

```scss
@mixin courses-tokens {
  // ══ Tokens de color — reemplaza por tus variables ══════════════════
  --cu-accent: var(--bs-primary);          // encabezado de la tabla, botón principal, acciones
  --cu-on-accent: #fff;                    // texto sobre el acento (encabezado de la tabla)
  --cu-action-fg: color-mix(in srgb, var(--cu-accent) 25%, #111); // ícono sobre botón de acción
  --cu-virtual: var(--bs-info);            // píldora Virtual
  --cu-onsite: var(--bs-success);          // píldora Presencial
  --cu-warning: var(--bs-warning);         // ID pendiente, vence pronto
  --cu-danger: var(--bs-danger);           // eliminar, vencido
  --cu-surface: var(--bs-body-bg);
  --cu-surface-alt: var(--bs-tertiary-bg);
  --cu-border: var(--bs-border-color-translucent);
  --cu-text: var(--bs-body-color);
  --cu-muted: var(--bs-secondary-color);

  // ══ Forma y movimiento ════════════════════════════════════════════
  --cu-radius: 1rem;
  --cu-radius-sm: 0.625rem;
  --cu-shadow: 0 1px 2px rgb(0 0 0 / 0.04), 0 4px 16px rgb(0 0 0 / 0.06);
  --cu-shadow-lift: 0 2px 4px rgb(0 0 0 / 0.05), 0 18px 36px -8px rgb(0 0 0 / 0.16);
  --cu-ease-spring: cubic-bezier(0.2, 0.9, 0.3, 1.15);
  --cu-ease-out: cubic-bezier(0.2, 0.8, 0.2, 1);
  --cu-z-drawer: 1060;
}
```

Para que se vea como Certificados, `--cu-accent` debe apuntar a la **misma** variable del amarillo de la marca que usa esa pantalla (encabezado de tabla, botón "Nuevo Certificado" y opción activa del menú).

Si ya tenías la página de tarjetas, reemplaza su bloque de tokens por:

```scss
@use '../courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}
```

---

## 5. Paso 2 — El token de URL (reutilizable)

### `shared/utils/url-state.ts`

No conoce cursos: recibe un objeto plano y un ámbito. Certificados puede usar el mismo archivo con `scope: 'certificates'`.

```ts
/**
 * Estado de pantalla en un solo parámetro de URL.
 *
 *   token = base64url(JSON) + "." + checksum(ámbito + payload)
 *
 * ⚠️ Esto OFUSCA, no cifra. Cualquiera puede decodificar el JSON.
 *    Sirve para que la URL no se lea a simple vista y no se edite a mano.
 *    Nunca pongas aquí datos sensibles; el backend valida permisos siempre.
 */

const VERSION = 1;
const MAX_TOKEN_LENGTH = 1500;

export type UrlStatePayload = Record<string, string | number | boolean>;

/** null si no hay nada que guardar: así la URL queda limpia. */
export function encodeUrlState(scope: string, state: UrlStatePayload): string | null {
  const entries = Object.entries(state).filter(([, value]) => value !== '' && value !== undefined && value !== null);
  if (!entries.length) return null;

  const json = JSON.stringify({ v: VERSION, ...Object.fromEntries(entries) });
  const payload = toBase64Url(new TextEncoder().encode(json));
  return `${payload}.${checksum(scope, payload)}`;
}

/** null si el token falta, está alterado, es de otro ámbito o de otra versión. */
export function decodeUrlState(scope: string, token: string | null | undefined): Record<string, unknown> | null {
  if (!token || token.length > MAX_TOKEN_LENGTH) return null;

  const parts = token.split('.');
  if (parts.length !== 2) return null;

  const [payload, sum] = parts;
  if (!payload || sum !== checksum(scope, payload)) return null;

  try {
    const json = new TextDecoder().decode(fromBase64Url(payload));
    const data: unknown = JSON.parse(json);

    if (!data || typeof data !== 'object' || Array.isArray(data)) return null;

    const { v, ...rest } = data as Record<string, unknown>;
    return v === VERSION ? rest : null;
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

/**
 * FNV-1a de 32 bits en base 36.
 * No es criptográfico: solo detecta tokens alterados, cortados o de otra pantalla.
 */
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

`btoa`, `atob`, `TextEncoder` y `TextDecoder` existen en el navegador y en Node 18+, así que el archivo funciona con SSR.

---

## 6. Paso 3 — Cambios en el dominio y la infraestructura

### `domain/course.model.ts` ✏️

Agrega los tipos de orden y dos campos a `CourseQuery`:

```ts
export type CourseSortField = 'name' | 'dueDate';
export type SortDirection = 'asc' | 'desc';

export interface CourseQuery {
  readonly search: string;
  readonly modality: CourseModality | null;
  readonly pendingExternalId: boolean;
  readonly sort: CourseSortField;
  readonly direction: SortDirection;
  readonly page: number;
  readonly pageSize: number;
}
```

### `domain/course-due.ts`

Ya existe desde la guía de CRUD (sección 6). La tabla usa la misma función `describeDue` que la tarjeta: no la dupliques.

### `infraestructure/courses.service.ts` ✏️

En `list()`, envía el orden junto con la paginación:

```ts
let params = new HttpParams()
  .set('page', query.page)
  .set('pageSize', query.pageSize)
  .set('sort', query.sort)
  .set('direction', query.direction);
```

### Contrato del backend ✏️

`GET /api/courses` recibe dos parámetros más:

| Parámetro | Valores | Por defecto |
|---|---|---|
| `sort` | `name` · `dueDate` | `name` |
| `direction` | `asc` · `desc` | `asc` |

El backend los traduce con un `switch` a una expresión de orden conocida. **Nunca** los concatena en SQL ni los usa para armar un `OrderBy` dinámico por nombre de propiedad. Con `dueDate`, los cursos sin fecha van al final en ambas direcciones, y el desempate es por `Id` para que la paginación no repita filas.

---

## 7. Paso 4 — Cambios en la facade

### `application/courses.facade.ts` ✏️

**1.** Reemplaza la constante privada `DEFAULT_QUERY` por una exportada, con el orden:

```ts
export const DEFAULT_COURSE_QUERY: CourseQuery = {
  search: '',
  modality: null,
  pendingExternalId: false,
  sort: 'name',
  direction: 'asc',
  page: 1,
  pageSize: COURSES_PAGE_SIZE,
};
```

Y actualiza la señal privada:

```ts
private readonly _query = signal<CourseQuery>(DEFAULT_COURSE_QUERY);
```

**2.** `clearFilters` limpia los filtros pero **conserva el orden** que eligió el usuario:

```ts
clearFilters(): void {
  const { sort, direction, pageSize } = this.query();
  this._query.set({ ...DEFAULT_COURSE_QUERY, sort, direction, pageSize });
}
```

**3.** Agrega `toggleSort`:

```ts
/** Clic en la misma columna invierte el orden; en otra, empieza ascendente. */
toggleSort(field: CourseSortField): void {
  this._query.update((q) => ({
    ...q,
    sort: field,
    direction: q.sort === field && q.direction === 'asc' ? 'desc' : 'asc',
    page: 1,
  }));
}
```

**4.** Agrega `setQuery`, para que la sincronización con la URL reemplace la consulta sin escribir la señal desde afuera:

```ts
/** Reemplaza la consulta completa. Lo usa la sincronización con la URL. */
setQuery(query: CourseQuery): void {
  this._query.set(query);
}
```

Recuerda importar `CourseSortField` desde `../domain/course.model`.

---

## 8. Paso 5 — ⭐ La consulta en la URL

### `application/course-query.url.ts`

Traduce `CourseQuery` a claves cortas y valida todo lo que llega de la URL. Un valor que no pasa la validación se reemplaza por el predeterminado, sin romper los demás.

```ts
import { UrlStatePayload, decodeUrlState, encodeUrlState } from '@shared/utils/url-state';
import { CourseModality } from '../domain/course-modality.enum';
import { CourseQuery, CourseSortField, SortDirection } from '../domain/course.model';
import { DEFAULT_COURSE_QUERY } from './courses.facade';

export const COURSE_QUERY_PARAM = 'f';
const SCOPE = 'courses';
const MAX_SEARCH = 100;
const MAX_PAGE = 10_000;

// Claves y valores cortos: la URL queda compacta y no se lee a simple vista.
//   s = búsqueda   m = modalidad   x = solo ID pendiente
//   o = orden      d = dirección   p = página
const MODALITY_TO_CODE: Record<CourseModality, string> = {
  [CourseModality.Virtual]: 'V',
  [CourseModality.Onsite]: 'P',
};
const SORT_TO_CODE: Record<CourseSortField, string> = { name: 'n', dueDate: 'd' };
const DIRECTION_TO_CODE: Record<SortDirection, string> = { asc: 'a', desc: 'z' };

const CODE_TO_MODALITY = invert(MODALITY_TO_CODE);
const CODE_TO_SORT = invert(SORT_TO_CODE);
const CODE_TO_DIRECTION = invert(DIRECTION_TO_CODE);

/** Solo guarda lo que difiere del predeterminado. Sin cambios → null (sin parámetro). */
export function toCourseQueryToken(query: CourseQuery): string | null {
  const d = DEFAULT_COURSE_QUERY;
  const state: UrlStatePayload = {};

  if (query.search) state['s'] = query.search;
  if (query.modality) state['m'] = MODALITY_TO_CODE[query.modality];
  if (query.pendingExternalId) state['x'] = 1;
  if (query.sort !== d.sort) state['o'] = SORT_TO_CODE[query.sort];
  if (query.direction !== d.direction) state['d'] = DIRECTION_TO_CODE[query.direction];
  if (query.page > 1) state['p'] = query.page;

  return encodeUrlState(SCOPE, state);
}

/** Nunca lanza: un token inválido devuelve la consulta predeterminada. */
export function fromCourseQueryToken(token: string | null, pageSize = DEFAULT_COURSE_QUERY.pageSize): CourseQuery {
  const d = DEFAULT_COURSE_QUERY;
  const raw = decodeUrlState(SCOPE, token) ?? {};

  return {
    search: typeof raw['s'] === 'string' ? raw['s'].trim().slice(0, MAX_SEARCH) : d.search,
    modality: pick(CODE_TO_MODALITY, raw['m']) ?? d.modality,
    pendingExternalId: raw['x'] === 1,
    sort: pick(CODE_TO_SORT, raw['o']) ?? d.sort,
    direction: pick(CODE_TO_DIRECTION, raw['d']) ?? d.direction,
    page: isPage(raw['p']) ? raw['p'] : d.page,
    pageSize,
  };
}

function isPage(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= 1 && (value as number) <= MAX_PAGE;
}

function pick<T>(map: Record<string, T>, code: unknown): T | null {
  return typeof code === 'string' && Object.hasOwn(map, code) ? map[code] : null;
}

function invert<K extends string>(map: Record<K, string>): Record<string, K> {
  return Object.fromEntries(Object.entries(map).map(([key, code]) => [code, key])) as Record<string, K>;
}
```

> Si una página del enlace ya no existe (el catálogo se redujo), la facade lo corrige al recibir el total: `goToPage` limita al máximo disponible. Ver el ajuste en la sección 11.

### `application/course-query-url.sync.ts`

Se llama en el constructor de la página. Mantiene la consulta de la facade y el parámetro `f` de la URL iguales en los dos sentidos.

```ts
import { inject } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { distinctUntilChanged, map } from 'rxjs';
import { CoursesFacade } from './courses.facade';
import { COURSE_QUERY_PARAM, fromCourseQueryToken, toCourseQueryToken } from './course-query.url';

/**
 * URL → estado: carga inicial, enlace compartido, botones atrás / adelante.
 * Estado → URL: cada filtro, orden o página que cambia el usuario.
 *
 * Debe llamarse en un contexto de inyección (constructor de la página).
 */
export function syncCourseQueryWithUrl(facade: CoursesFacade): void {
  const route = inject(ActivatedRoute);
  const router = inject(Router);

  const writeToken = (token: string | null, replaceUrl: boolean) =>
    router.navigate([], {
      relativeTo: route,
      queryParams: { [COURSE_QUERY_PARAM]: token }, // null elimina el parámetro
      queryParamsHandling: 'merge',
      replaceUrl,
    });

  // ── URL → estado ──────────────────────────────────────────────────
  // queryParamMap emite de inmediato: la primera petición ya sale con los filtros del enlace.
  route.queryParamMap
    .pipe(
      map((params) => params.get(COURSE_QUERY_PARAM)),
      distinctUntilChanged(),
      takeUntilDestroyed(),
    )
    .subscribe((token) => {
      const next = fromCourseQueryToken(token, facade.query().pageSize);
      const canonical = toCourseQueryToken(next);

      if (canonical !== toCourseQueryToken(facade.query())) {
        facade.setQuery(next);
      }

      // Token alterado, viejo o con valores por defecto: se reescribe sin ensuciar el historial.
      if (token !== canonical) {
        void writeToken(canonical, true);
      }
    });

  // ── Estado → URL ──────────────────────────────────────────────────
  toObservable(facade.query)
    .pipe(map(toCourseQueryToken), distinctUntilChanged(), takeUntilDestroyed())
    .subscribe((token) => {
      if (token !== route.snapshot.queryParamMap.get(COURSE_QUERY_PARAM)) {
        void writeToken(token, false); // crea entrada: "atrás" deshace el último filtro
      }
    });
}
```

Por qué no hay bucle: cuando la URL cambia la consulta, la consulta produce el mismo token que ya está en la URL, y la segunda suscripción no navega. Cuando la consulta cambia la URL, la URL produce una consulta con el mismo token que la actual, y la primera no hace `set`.

---

## 9. 🔒 Si algún día hace falta ocultar de verdad

El token de esta guía es suficiente para filtros de catálogo. Si un filtro llegara a contener algo que no debe verse (una cédula, un nombre de empleado), la única forma real de ocultarlo es que **el servidor lo guarde** y la URL lleve solo un identificador:

| Paso | Qué pasa |
|---|---|
| 1 | El front envía la consulta: `POST /api/shared-views { scope: "courses", state: {...} }` |
| 2 | El backend la guarda asociada al usuario y responde `{ id: "k7Qm2x" }` |
| 3 | La URL queda `/cursos?v=k7Qm2x` |
| 4 | Quien abre el enlace hace `GET /api/shared-views/k7Qm2x`; el backend valida que tenga permiso y devuelve el estado |

Cuesta una tabla y dos endpoints, y los enlaces dejan de funcionar si se borra el registro. Por eso no es la opción por defecto.

---

## 10. Paso 6 — La tabla

Presentacional: recibe los cursos y el orden, emite eventos. No inyecta la facade.

### `presentation/courses-table/courses-table.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import { COURSE_MODALITY_CONFIG } from '../../domain/course-modality.config';
import { describeDue } from '../../domain/course-due';
import { CourseSortField, CourseSummary, SortDirection } from '../../domain/course.model';

@Component({
  selector: 'app-courses-table',
  templateUrl: './courses-table.component.html',
  styleUrl: './courses-table.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CoursesTableComponent {
  readonly courses = input.required<readonly CourseSummary[]>();
  readonly sort = input.required<CourseSortField>();
  readonly direction = input.required<SortDirection>();
  /** true mientras llega una recarga: la tabla se atenúa. */
  readonly refreshing = input(false);

  readonly edit = output<CourseSummary>();
  readonly remove = output<CourseSummary>();
  readonly sortChange = output<CourseSortField>();

  /** Todo lo que la fila necesita, calculado una vez por cambio de datos. */
  readonly rows = computed(() =>
    this.courses().map((course) => {
      const config = COURSE_MODALITY_CONFIG[course.modality];
      return {
        course,
        config,
        pendingId: !course.externalId && config.externalIdExpected,
        due: describeDue(course.nextDueDate),
      };
    }),
  );

  ariaSort(field: CourseSortField): 'ascending' | 'descending' | 'none' {
    if (this.sort() !== field) return 'none';
    return this.direction() === 'asc' ? 'ascending' : 'descending';
  }

  sortIcon(field: CourseSortField): string {
    if (this.sort() !== field) return 'fa-sort';
    return this.direction() === 'asc' ? 'fa-sort-up' : 'fa-sort-down';
  }
}
```

### `courses-table.component.html`

```html
<div class="table-wrap" [class.is-refreshing]="refreshing()">
  <table class="courses-table">
    <caption class="visually-hidden">Cursos creados</caption>

    <thead>
      <tr>
        <th scope="col" class="col-name" [attr.aria-sort]="ariaSort('name')">
          <button type="button" class="th-sort" [class.is-active]="sort() === 'name'" (click)="sortChange.emit('name')">
            Nombre <i class="fa-solid {{ sortIcon('name') }}" aria-hidden="true"></i>
          </button>
        </th>
        <th scope="col">Modalidad</th>
        <th scope="col">ID externo</th>
        <th scope="col" class="text-center">Asignados</th>
        <th scope="col" [attr.aria-sort]="ariaSort('dueDate')">
          <button
            type="button"
            class="th-sort"
            [class.is-active]="sort() === 'dueDate'"
            (click)="sortChange.emit('dueDate')">
            Fecha límite <i class="fa-solid {{ sortIcon('dueDate') }}" aria-hidden="true"></i>
          </button>
        </th>
        <th scope="col" class="text-center">Acciones</th>
      </tr>
    </thead>

    <tbody>
      @for (row of rows(); track row.course.id; let i = $index) {
        <tr [style.--i]="i">
          <td data-label="Nombre" class="col-name">
            <span class="course-name" [title]="row.course.name">{{ row.course.name }}</span>
          </td>

          <td data-label="Modalidad">
            <span class="status-pill" [attr.data-tone]="row.config.tone">
              <i class="fa-solid {{ row.config.icon }}" aria-hidden="true"></i>
              {{ row.config.label }}
            </span>
          </td>

          <td data-label="ID externo">
            @if (row.course.externalId; as externalId) {
              <code class="external-id">{{ externalId }}</code>
            } @else if (row.pendingId) {
              <span class="status-pill" data-tone="warning">
                <i class="fa-solid fa-hourglass-half" aria-hidden="true"></i> Pendiente
              </span>
            } @else {
              <span class="text-muted-soft">No aplica</span>
            }
          </td>

          <td data-label="Asignados" class="text-center">
            <span class="count">{{ row.course.assignedCount }}</span>
          </td>

          <td data-label="Fecha límite">
            @if (row.due; as due) {
              <span class="due" [attr.data-state]="due.state">
                {{ due.date }}
                <small>{{ due.relative }}</small>
              </span>
            } @else {
              <span class="text-muted-soft">—</span>
            }
          </td>

          <td data-label="Acciones">
            <div class="row-actions">
              <button
                type="button"
                class="action-btn"
                title="Editar"
                [attr.aria-label]="'Editar ' + row.course.name"
                (click)="edit.emit(row.course)">
                <i class="fa-solid fa-pen-to-square" aria-hidden="true"></i>
              </button>
              <button
                type="button"
                class="action-btn action-btn--danger"
                title="Eliminar"
                [attr.aria-label]="'Eliminar ' + row.course.name"
                (click)="remove.emit(row.course)">
                <i class="fa-solid fa-trash" aria-hidden="true"></i>
              </button>
            </div>
          </td>
        </tr>
      }
    </tbody>
  </table>
</div>
```

### `courses-table.component.scss`

```scss
:host {
  display: block;
}

.table-wrap {
  overflow-x: auto;
  border-radius: var(--cu-radius-sm);
  transition: opacity 0.2s ease;

  &.is-refreshing {
    opacity: 0.5;
    pointer-events: none;
  }
}

.courses-table {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  color: var(--cu-text);
  font-size: 0.9rem;
}

// ── Encabezado de color, como en Certificados ──────────────────────
thead th {
  padding: 0.95rem 1rem;
  background: var(--cu-accent);
  color: var(--cu-on-accent);
  font-size: 0.8rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-align: start;
  text-transform: uppercase;
  white-space: nowrap;

  &:first-child {
    border-top-left-radius: var(--cu-radius-sm);
  }

  &:last-child {
    border-top-right-radius: var(--cu-radius-sm);
  }

  &.text-center {
    text-align: center;
  }
}

.th-sort {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0;
  border: 0;
  background: none;
  color: inherit;
  font: inherit;
  letter-spacing: inherit;
  text-transform: inherit;

  i {
    font-size: 0.75rem;
    opacity: 0.55;
    transition: opacity 0.2s ease, transform 0.25s var(--cu-ease-spring);
  }

  &:hover i,
  &.is-active i {
    opacity: 1;
  }

  &.is-active i {
    transform: scale(1.15);
  }

  &:focus-visible {
    border-radius: 0.25rem;
    outline: 2px solid var(--cu-on-accent);
    outline-offset: 3px;
  }
}

// ── Filas ──────────────────────────────────────────────────────────
tbody tr {
  position: relative;
  animation: cu-row-in 0.35s var(--cu-ease-out) both;
  animation-delay: calc(min(var(--i, 0), 10) * 35ms);
  transition: background-color 0.2s ease;

  &:nth-child(even) {
    background: color-mix(in srgb, var(--cu-surface-alt) 45%, transparent);
  }

  &:hover {
    background: color-mix(in srgb, var(--cu-accent) 8%, transparent);

    td:first-child {
      box-shadow: inset 3px 0 0 var(--cu-accent);
    }
  }
}

tbody td {
  padding: 0.9rem 1rem;
  border-bottom: 1px solid var(--cu-border);
  vertical-align: middle;
  transition: box-shadow 0.2s ease;
}

tbody tr:last-child td {
  border-bottom: 0;
}

.col-name {
  min-width: 14rem;
  max-width: 22rem;
}

.course-name {
  display: -webkit-box;
  overflow: hidden;
  font-weight: 600;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
}

// ── Píldoras (mismo estilo que Aprobada / Pendiente) ───────────────
.status-pill {
  --tone: var(--cu-virtual);

  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  padding: 0.3rem 0.75rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 16%, transparent);
  color: color-mix(in srgb, var(--tone) 70%, var(--cu-text));
  font-size: 0.8rem;
  font-weight: 600;
  white-space: nowrap;

  &[data-tone='onsite'] {
    --tone: var(--cu-onsite);
  }

  &[data-tone='warning'] {
    --tone: var(--cu-warning);
  }

  i {
    font-size: 0.75rem;
  }
}

.external-id {
  padding: 0.2rem 0.5rem;
  border-radius: 0.375rem;
  background: var(--cu-surface-alt);
  color: var(--cu-text);
  font-size: 0.8rem;
}

.count {
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.due {
  display: inline-flex;
  flex-direction: column;
  font-variant-numeric: tabular-nums;
  line-height: 1.25;
  white-space: nowrap;

  small {
    color: var(--cu-muted);
    font-size: 0.75rem;
  }

  &[data-state='soon'] small {
    color: color-mix(in srgb, var(--cu-warning) 65%, var(--cu-text));
    font-weight: 600;
  }

  &[data-state='overdue'] small {
    color: var(--cu-danger);
    font-weight: 600;
  }
}

.text-muted-soft {
  color: var(--cu-muted);
}

// ── Botones de acción (cuadrados redondeados del color de acento) ──
.row-actions {
  display: flex;
  justify-content: center;
  gap: 0.5rem;
}

.action-btn {
  display: inline-grid;
  place-items: center;
  width: 2.25rem;
  height: 2.25rem;
  padding: 0;
  border: 0;
  border-radius: 0.6rem;
  background: var(--cu-accent);
  color: var(--cu-action-fg);
  box-shadow: 0 4px 10px -4px color-mix(in srgb, var(--cu-accent) 70%, transparent);
  transition:
    transform 0.18s var(--cu-ease-out),
    box-shadow 0.18s ease,
    background-color 0.18s ease,
    color 0.18s ease;

  &:hover {
    box-shadow: 0 8px 16px -6px color-mix(in srgb, var(--cu-accent) 80%, transparent);
    transform: translateY(-2px);
  }

  &:active {
    transform: scale(0.92);
  }

  &:focus-visible {
    outline: 2px solid var(--cu-text);
    outline-offset: 2px;
  }

  &--danger:hover {
    background: var(--cu-danger);
    color: #fff;
    box-shadow: 0 8px 16px -6px color-mix(in srgb, var(--cu-danger) 70%, transparent);
  }
}

// ── Móvil: cada fila es una tarjeta ────────────────────────────────
@media (max-width: 767.98px) {
  .courses-table thead {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip: rect(0 0 0 0);
  }

  .courses-table,
  .courses-table tbody,
  .courses-table tr,
  .courses-table td {
    display: block;
    width: 100%;
  }

  tbody tr {
    margin-bottom: 0.75rem;
    padding: 0.75rem 1rem;
    border: 1px solid var(--cu-border);
    border-left: 3px solid var(--cu-accent);
    border-radius: var(--cu-radius-sm);
    background: var(--cu-surface);

    &:nth-child(even) {
      background: var(--cu-surface);
    }

    &:hover td:first-child {
      box-shadow: none;
    }
  }

  tbody td {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.4rem 0;
    border: 0;
    text-align: end;

    &::before {
      content: attr(data-label);
      color: var(--cu-muted);
      font-size: 0.75rem;
      font-weight: 600;
      text-align: start;
      text-transform: uppercase;
    }

    &.text-center {
      text-align: end;
    }
  }

  // El nombre va arriba, grande y sin etiqueta.
  td.col-name {
    max-width: none;
    padding-bottom: 0.6rem;
    text-align: start;

    &::before {
      display: none;
    }
  }

  .row-actions {
    justify-content: flex-end;
  }

  .due {
    align-items: flex-end;
  }
}

@keyframes cu-row-in {
  from {
    opacity: 0;
    transform: translateY(6px);
  }
}

@media (prefers-reduced-motion: reduce) {
  tbody tr {
    animation: cu-fade 0.15s ease both;
  }

  .action-btn,
  .th-sort i {
    transition: none;
  }

  .action-btn:hover {
    transform: none;
  }
}

@keyframes cu-fade {
  from {
    opacity: 0;
  }
}
```

---

## 11. Paso 7 — La página

### Ajuste en la facade: página fuera de rango

Un enlace viejo puede apuntar a la página 5 cuando ya solo hay 2. En el `subscribe` del constructor de `CoursesFacade`, justo después de guardar el resultado, agrega:

```ts
// Enlace a una página que ya no existe: salta a la última disponible.
const lastPage = Math.max(1, Math.ceil(result.page.total / this.query().pageSize));
if (this.query().page > lastPage) {
  this._query.update((q) => ({ ...q, page: lastPage }));
}
```

### `presentation/courses-list-page/courses-list-page.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  PLATFORM_ID,
  computed,
  effect,
  inject,
  signal,
  untracked,
} from '@angular/core';
import { DOCUMENT, isPlatformBrowser } from '@angular/common';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { debounceTime, distinctUntilChanged, map, skip } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { CourseModality, COURSE_MODALITIES } from '../../domain/course-modality.enum';
import { COURSE_MODALITY_CONFIG } from '../../domain/course-modality.config';
import { CourseSummary } from '../../domain/course.model';
import { CoursesFacade } from '../../application/courses.facade';
import { COURSES_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/courses.providers';
import { syncCourseQueryWithUrl } from '../../application/course-query-url.sync';
import { CoursesTableComponent } from '../courses-table/courses-table.component';
import { CourseEditorComponent } from '../course-editor/course-editor.component';
import { confirmDanger, notifyError, notifySuccess } from '../course-feedback';

type ResultsView = 'skeleton' | 'error' | 'empty' | 'table';

@Component({
  selector: 'app-courses-list-page',
  imports: [CoursesTableComponent, CourseEditorComponent],
  providers: [...COURSES_INFRASTRUCTURE_PROVIDERS, CoursesFacade],
  templateUrl: './courses-list-page.component.html',
  styleUrl: './courses-list-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CoursesListPageComponent {
  protected readonly facade = inject(CoursesFacade);
  private readonly document = inject(DOCUMENT);
  private readonly isBrowser = isPlatformBrowser(inject(PLATFORM_ID));

  readonly modalities = COURSE_MODALITIES;
  readonly config = COURSE_MODALITY_CONFIG;
  readonly skeletonRows = Array.from({ length: 5 }, (_, i) => i);

  readonly q = this.facade.query;

  /** Valor inmediato del buscador; la consulta real (y la URL) va con rebote. */
  readonly searchDraft = signal('');
  readonly linkCopied = signal(false);

  readonly view = computed<ResultsView>(() => {
    const status = this.facade.status();
    const hasItems = this.facade.courses().length > 0;
    if (status === 'error') return 'error';
    if (!hasItems) return status === 'loading' ? 'skeleton' : 'empty';
    return 'table';
  });

  constructor() {
    // 1. Primero la URL: así la primera petición ya sale con los filtros del enlace.
    syncCourseQueryWithUrl(this.facade);
    this.searchDraft.set(this.q().search);

    // 2. Atrás / adelante cambian la búsqueda: el input la refleja.
    //    Se compara sin espacios para no borrar el espacio que el usuario está escribiendo.
    effect(() => {
      const search = this.q().search;
      untracked(() => {
        if (this.searchDraft().trim() !== search) this.searchDraft.set(search);
      });
    });

    // 3. Lo que el usuario escribe llega a la consulta con rebote.
    toObservable(this.searchDraft)
      .pipe(
        skip(1),
        debounceTime(350),
        map((value) => value.trim()),
        distinctUntilChanged(),
        takeUntilDestroyed(),
      )
      .subscribe((search) => {
        if (search !== this.q().search) this.facade.patchQuery({ search });
      });
  }

  // ── Filtros ───────────────────────────────────────────────────────
  onModalityChange(value: string): void {
    const modality = this.modalities.find((m) => m === value) ?? null;
    this.facade.patchQuery({ modality });
  }

  onExternalIdChange(value: string): void {
    this.facade.patchQuery({ pendingExternalId: value === 'pending' });
  }

  clearFilters(): void {
    this.searchDraft.set('');
    this.facade.clearFilters();
  }

  // ── Acciones ──────────────────────────────────────────────────────
  edit(course: CourseSummary): void {
    this.facade.openEdit(course.id);
  }

  async remove(course: CourseSummary): Promise<void> {
    const count = course.assignedCount;
    const confirmed = await confirmDanger(
      `¿Eliminar "${course.name}"?`,
      count
        ? `Tiene ${count} ${count === 1 ? 'usuario asignado' : 'usuarios asignados'}. Se conserva el historial, pero el curso deja de aparecer en el listado.`
        : 'Esta acción no se puede deshacer.',
      'Eliminar',
    );
    if (!confirmed) return;

    try {
      await this.facade.remove(course);
      notifySuccess('Curso eliminado');
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudo eliminar el curso.'));
    }
  }

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
}
```

### `courses-list-page.component.html`

```html
<section class="courses-page">
  <header class="page-header">
    <h1 class="page-title">Módulo de Cursos</h1>
    <p class="page-subtitle">Crea, asigna y gestiona los cursos de manera fácil y rápida</p>
  </header>

  <div class="list-card">
    <!-- ── Título + acciones principales ────────────────────────────── -->
    <div class="list-card__head">
      <h2 class="list-card__title">Listado de Cursos</h2>

      <div class="d-flex flex-wrap gap-2">
        <button
          type="button"
          class="btn btn-link list-card__share"
          [class.is-copied]="linkCopied()"
          (click)="copyLink()">
          <i class="fa-solid {{ linkCopied() ? 'fa-check' : 'fa-link' }}" aria-hidden="true"></i>
          {{ linkCopied() ? 'Enlace copiado' : 'Copiar enlace' }}
        </button>
        <button type="button" class="btn btn-accent" (click)="facade.openCreate()">
          <i class="fa-solid fa-calendar-plus me-2" aria-hidden="true"></i> Nuevo Curso
        </button>
      </div>
    </div>

    <!-- ── Filtros ──────────────────────────────────────────────────── -->
    <div class="list-card__filters">
      <div class="row g-3">
        <div class="col-12 col-md-4">
          <label for="course-search" class="form-label">Buscar</label>
          <div class="search-field">
            <i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>
            <input
              id="course-search"
              type="search"
              class="form-control"
              placeholder="Nombre o ID externo"
              autocomplete="off"
              [value]="searchDraft()"
              (input)="searchDraft.set($any($event.target).value)" />
          </div>
        </div>

        <div class="col-12 col-sm-6 col-md-4">
          <label for="course-modality" class="form-label">Modalidad</label>
          <select id="course-modality" class="form-select" (change)="onModalityChange($any($event.target).value)">
            <option value="" [selected]="!q().modality">Todas</option>
            @for (modality of modalities; track modality) {
              <option [value]="modality" [selected]="q().modality === modality">{{ config[modality].label }}</option>
            }
          </select>
        </div>

        <div class="col-12 col-sm-6 col-md-4">
          <label for="course-external-id" class="form-label">ID externo</label>
          <select
            id="course-external-id"
            class="form-select"
            (change)="onExternalIdChange($any($event.target).value)">
            <option value="" [selected]="!q().pendingExternalId">Todos</option>
            <option value="pending" [selected]="q().pendingExternalId">Solo pendientes</option>
          </select>
        </div>
      </div>

      @if (facade.hasFilters()) {
        <div class="text-end mt-2">
          <button type="button" class="btn btn-link btn-sm list-card__clear" (click)="clearFilters()">
            <i class="fa-solid fa-filter-circle-xmark me-1" aria-hidden="true"></i> Limpiar filtros
          </button>
        </div>
      }
    </div>

    <!-- ── Resultados ───────────────────────────────────────────────── -->
    <div class="list-card__results" aria-live="polite" [attr.aria-busy]="facade.status() === 'loading'">
      @switch (view()) {
        @case ('skeleton') {
          <div class="table-skeleton" aria-hidden="true">
            <div class="table-skeleton__head"></div>
            @for (i of skeletonRows; track i) {
              <div class="table-skeleton__row" [style.--i]="i">
                <span></span><span></span><span></span><span></span>
              </div>
            }
          </div>
          <span class="visually-hidden" role="status">Cargando cursos…</span>
        }

        @case ('error') {
          <div class="state-box" data-tone="danger">
            <i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>
            <p class="fw-semibold mb-1">No se pudieron cargar los cursos</p>
            <p class="text-body-secondary small">{{ facade.error() }}</p>
            <button type="button" class="btn btn-outline-secondary btn-sm" (click)="facade.reload()">
              <i class="fa-solid fa-rotate-right me-1" aria-hidden="true"></i> Reintentar
            </button>
          </div>
        }

        @case ('empty') {
          <div class="state-box">
            <i class="fa-solid fa-folder-open" aria-hidden="true"></i>
            @if (facade.hasFilters()) {
              <p class="fw-semibold mb-1">Sin resultados</p>
              <p class="text-body-secondary small">Ningún curso coincide con los filtros.</p>
              <button type="button" class="btn btn-outline-secondary btn-sm" (click)="clearFilters()">
                Limpiar filtros
              </button>
            } @else {
              <p class="fw-semibold mb-1">Aún no hay cursos</p>
              <p class="text-body-secondary small">Crea el primero con el botón <strong>Nuevo Curso</strong>.</p>
            }
          </div>
        }

        @default {
          <app-courses-table
            [courses]="facade.courses()"
            [sort]="q().sort"
            [direction]="q().direction"
            [refreshing]="facade.status() === 'loading'"
            (sortChange)="facade.toggleSort($event)"
            (edit)="edit($event)"
            (remove)="remove($event)" />
        }
      }
    </div>

    <!-- ── Paginación ───────────────────────────────────────────────── -->
    @if (view() === 'table') {
      <nav class="pager" aria-label="Paginación de cursos">
        <button
          type="button"
          class="pager__btn"
          aria-label="Página anterior"
          [disabled]="q().page <= 1"
          (click)="facade.goToPage(q().page - 1)">
          <i class="fa-solid fa-chevron-left" aria-hidden="true"></i>
        </button>

        <span class="pager__status">
          Página {{ q().page }} de {{ facade.totalPages() }}
          <small>{{ facade.total() }} {{ facade.total() === 1 ? 'curso' : 'cursos' }} en total</small>
        </span>

        <button
          type="button"
          class="pager__btn"
          aria-label="Página siguiente"
          [disabled]="q().page >= facade.totalPages()"
          (click)="facade.goToPage(q().page + 1)">
          <i class="fa-solid fa-chevron-right" aria-hidden="true"></i>
        </button>
      </nav>
    }
  </div>

  <app-course-editor />
</section>
```

### `courses-list-page.component.scss`

```scss
@use '../courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}

.courses-page {
  padding: 1.5rem 1.5rem 2rem;

  @media (max-width: 575.98px) {
    padding: 1rem 0.75rem 1.5rem;
  }
}

// ── Encabezado (igual a Módulo de Certificados) ────────────────────
.page-header {
  margin-bottom: 2rem;
  animation: cu-fade-up 0.4s var(--cu-ease-out) both;
}

.page-title {
  margin: 0 0 0.25rem;
  font-size: 1.6rem;
  font-weight: 700;
}

.page-subtitle {
  margin: 0;
  color: var(--cu-muted);
}

// ── Tarjeta del listado (vidrio, como Certificados) ────────────────
.list-card {
  padding: 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow);
  animation: cu-fade-up 0.45s var(--cu-ease-out) 0.05s both;

  @media (max-width: 575.98px) {
    padding: 1rem;
  }
}

@supports (backdrop-filter: blur(1px)) {
  .list-card {
    background: color-mix(in srgb, var(--cu-surface) 78%, transparent);
    backdrop-filter: blur(14px) saturate(150%);
  }
}

.list-card__head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  padding-bottom: 1.25rem;
  border-bottom: 1px solid var(--cu-border);
}

.list-card__title {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 700;
}

.list-card__share {
  color: var(--cu-muted);
  text-decoration: none;
  transition: color 0.2s ease;

  &:hover {
    color: var(--cu-text);
  }

  &.is-copied {
    color: var(--bs-success);
  }

  i {
    margin-right: 0.35rem;
    transition: transform 0.3s var(--cu-ease-spring);
  }

  &.is-copied i {
    transform: scale(1.25);
  }
}

// Botón principal con el color de acento (como "Nuevo Certificado").
.btn-accent {
  --bs-btn-bg: var(--cu-accent);
  --bs-btn-border-color: var(--cu-accent);
  --bs-btn-color: var(--cu-action-fg);
  --bs-btn-hover-bg: color-mix(in srgb, var(--cu-accent) 88%, #000);
  --bs-btn-hover-border-color: color-mix(in srgb, var(--cu-accent) 88%, #000);
  --bs-btn-hover-color: var(--cu-action-fg);
  --bs-btn-active-bg: color-mix(in srgb, var(--cu-accent) 80%, #000);
  --bs-btn-active-border-color: color-mix(in srgb, var(--cu-accent) 80%, #000);
  --bs-btn-active-color: var(--cu-action-fg);
  --bs-btn-focus-shadow-rgb: 0, 0, 0;

  padding: 0.6rem 1.25rem;
  border-radius: 0.6rem;
  font-weight: 600;
  box-shadow: 0 8px 18px -8px color-mix(in srgb, var(--cu-accent) 75%, transparent);
  transition:
    transform 0.2s var(--cu-ease-out),
    box-shadow 0.2s ease,
    background-color 0.2s ease;

  &:hover {
    box-shadow: 0 12px 24px -8px color-mix(in srgb, var(--cu-accent) 85%, transparent);
    transform: translateY(-2px);
  }

  &:active {
    transform: scale(0.98);
  }
}

// ── Filtros ────────────────────────────────────────────────────────
.list-card__filters {
  padding: 1.25rem 0 1rem;

  .form-label {
    margin-bottom: 0.35rem;
    color: var(--cu-muted);
    font-size: 0.9rem;
  }

  .form-control,
  .form-select {
    min-height: 2.75rem;
    border-radius: 0.6rem;
    background-color: color-mix(in srgb, var(--cu-surface) 85%, transparent);
    transition: border-color 0.15s ease, box-shadow 0.15s ease;

    &:focus {
      border-color: color-mix(in srgb, var(--cu-accent) 70%, var(--cu-border));
      box-shadow: 0 0 0 0.25rem color-mix(in srgb, var(--cu-accent) 22%, transparent);
    }
  }
}

.search-field {
  position: relative;

  i {
    position: absolute;
    top: 50%;
    left: 0.9rem;
    color: var(--cu-muted);
    transform: translateY(-50%);
    transition: color 0.2s ease;
    pointer-events: none;
  }

  .form-control {
    padding-left: 2.5rem;
  }

  &:focus-within i {
    color: var(--cu-accent);
  }
}

.list-card__clear {
  color: var(--cu-muted);
  text-decoration: none;
  animation: cu-fade-up 0.2s ease both;

  &:hover {
    color: var(--cu-danger);
  }
}

// ── Esqueleto de tabla ─────────────────────────────────────────────
.table-skeleton {
  overflow: hidden;
  border-radius: var(--cu-radius-sm);
}

.table-skeleton__head {
  height: 3rem;
  background: color-mix(in srgb, var(--cu-accent) 55%, transparent);
}

.table-skeleton__row {
  display: grid;
  grid-template-columns: 3fr 1.5fr 1.5fr 1fr;
  gap: 1.5rem;
  padding: 1.15rem 1rem;
  border-bottom: 1px solid var(--cu-border);
  animation: cu-fade-up 0.3s ease both;
  animation-delay: calc(var(--i, 0) * 60ms);

  span {
    height: 0.9rem;
    border-radius: 0.4rem;
    background: linear-gradient(
      90deg,
      var(--cu-surface-alt) 0%,
      color-mix(in srgb, var(--cu-surface-alt) 40%, var(--cu-surface)) 50%,
      var(--cu-surface-alt) 100%
    );
    background-size: 200% 100%;
    animation: cu-skeleton 1.2s ease-in-out infinite;
  }
}

// ── Estados vacío y error ──────────────────────────────────────────
.state-box {
  --tone: var(--cu-accent);

  padding: 2.5rem 1rem;
  text-align: center;
  animation: cu-fade-up 0.3s ease both;

  &[data-tone='danger'] {
    --tone: var(--cu-danger);
  }

  > i {
    display: inline-grid;
    place-items: center;
    width: 3.5rem;
    height: 3.5rem;
    margin-bottom: 0.75rem;
    border-radius: 1rem;
    background: color-mix(in srgb, var(--tone) 14%, transparent);
    color: var(--tone);
    font-size: 1.4rem;
  }
}

// ── Paginación (flechas redondas, como Certificados) ───────────────
.pager {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 1.25rem;
  margin-top: 1.5rem;
}

.pager__btn {
  display: inline-grid;
  place-items: center;
  width: 2.5rem;
  height: 2.5rem;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: color-mix(in srgb, var(--cu-accent) 14%, var(--cu-surface));
  color: var(--cu-text);
  transition:
    background-color 0.2s ease,
    transform 0.2s var(--cu-ease-out),
    color 0.2s ease;

  &:hover:not(:disabled) {
    background: var(--cu-accent);
    color: var(--cu-action-fg);
    transform: scale(1.08);
  }

  &:active:not(:disabled) {
    transform: scale(0.94);
  }

  &:disabled {
    opacity: 0.45;
  }

  &:focus-visible {
    outline: 2px solid var(--cu-accent);
    outline-offset: 2px;
  }
}

.pager__status {
  display: flex;
  flex-direction: column;
  align-items: center;
  font-weight: 600;
  font-variant-numeric: tabular-nums;

  small {
    color: var(--cu-muted);
    font-size: 0.75rem;
    font-weight: 400;
  }
}

// ── Animaciones ────────────────────────────────────────────────────
@keyframes cu-fade-up {
  from {
    opacity: 0;
    transform: translateY(8px);
  }
}

@keyframes cu-skeleton {
  from {
    background-position: 200% 0;
  }
  to {
    background-position: -200% 0;
  }
}

@media (prefers-reduced-motion: reduce) {
  .page-header,
  .list-card,
  .table-skeleton__row,
  .state-box,
  .list-card__clear {
    animation: none;
  }

  .table-skeleton__row span {
    animation: none;
  }

  .btn-accent:hover,
  .pager__btn:hover:not(:disabled) {
    transform: none;
  }
}
```

### Ruta en `src/app/app.routes.ts`

Reemplaza el `loadComponent` de la ruta `cursos`:

```ts
{
  path: 'cursos',
  canActivate: [permissionGuard],
  data: { permissionPath: 'courses' },
  loadComponent: () =>
    import('@features/courses/presentation/courses-list-page/courses-list-page.component')
      .then(m => m.CoursesListPageComponent),
}
```

La ruta **no** debe tener `runGuardsAndResolvers: 'always'`: cada cambio de filtro navega, y volver a correr el guard en cada tecla es innecesario.

### Si prefieres editar en otra página (como `/certificates/new`)

1. Crea las rutas `cursos/nuevo` y `cursos/:id/editar` con una página que envuelva el formulario del editor.
2. En la tabla, `edit` navega en lugar de abrir el panel, **llevándose el token** para volver a la misma vista:

```ts
edit(course: CourseSummary): void {
  void this.router.navigate(['/cursos', course.id, 'editar'], { queryParamsHandling: 'preserve' });
}
```

3. En la página de edición, "Volver a cursos" y "Guardar" navegan a `/cursos` con `queryParamsHandling: 'preserve'`. Así el usuario vuelve a los mismos filtros y la misma página.

---

## 12. Pruebas

### Unitarias

```ts
describe('url-state', () => {
  it('ida y vuelta con tildes y ñ', () => {
    const token = encodeUrlState('courses', { s: 'Educación en compañía' })!;
    expect(decodeUrlState('courses', token)).toEqual({ s: 'Educación en compañía' });
  });

  it('el token no deja leer el valor a simple vista', () => {
    const token = encodeUrlState('courses', { s: 'excel' })!;
    expect(token).not.toContain('excel');
  });

  it('sin valores no genera token', () => {
    expect(encodeUrlState('courses', { s: '' })).toBeNull();
  });

  it('rechaza un token alterado', () => {
    const token = encodeUrlState('courses', { p: 2 })!;
    const tampered = token.replace(/^./, (c) => (c === 'a' ? 'b' : 'a'));
    expect(decodeUrlState('courses', tampered)).toBeNull();
  });

  it('rechaza un token de otra pantalla', () => {
    const token = encodeUrlState('certificates', { p: 2 })!;
    expect(decodeUrlState('courses', token)).toBeNull();
  });

  it('rechaza basura sin lanzar', () => {
    expect(decodeUrlState('courses', '%%%.123')).toBeNull();
    expect(decodeUrlState('courses', 'x'.repeat(5000))).toBeNull();
  });
});

describe('course-query.url', () => {
  it('la consulta por defecto no genera parámetro', () => {
    expect(toCourseQueryToken(DEFAULT_COURSE_QUERY)).toBeNull();
  });

  it('ida y vuelta de todos los campos', () => {
    const query: CourseQuery = {
      ...DEFAULT_COURSE_QUERY,
      search: 'excel',
      modality: CourseModality.Onsite,
      pendingExternalId: true,
      sort: 'dueDate',
      direction: 'desc',
      page: 3,
    };
    expect(fromCourseQueryToken(toCourseQueryToken(query))).toEqual(query);
  });

  it('descarta valores inválidos y conserva los válidos', () => {
    const token = encodeUrlState('courses', { s: 'excel', m: 'X', p: -4, o: 'drop table' })!;
    const query = fromCourseQueryToken(token);

    expect(query.search).toBe('excel');
    expect(query.modality).toBeNull();
    expect(query.page).toBe(1);
    expect(query.sort).toBe('name');
  });

  it('un token inválido devuelve la consulta por defecto', () => {
    expect(fromCourseQueryToken('no-es-un-token')).toEqual(DEFAULT_COURSE_QUERY);
  });
});

describe('CoursesFacade.toggleSort', () => {
  it('invierte el orden en la misma columna y vuelve a la página 1', () => {
    facade.goToPage(2);
    facade.toggleSort('name');
    expect(facade.query().direction).toBe('desc');
    expect(facade.query().page).toBe(1);
  });

  it('empieza ascendente en otra columna', () => {
    facade.toggleSort('name');
    facade.toggleSort('dueDate');
    expect(facade.query()).toEqual(jasmine.objectContaining({ sort: 'dueDate', direction: 'asc' }));
  });
});

describe('describeDue', () => {
  const today = new Date(2026, 8, 29);

  it('marca como vencida una fecha pasada', () => {
    expect(describeDue('2026-09-27', today)?.state).toBe('overdue');
  });

  it('marca "pronto" dentro de 7 días', () => {
    expect(describeDue('2026-10-03', today)).toEqual(jasmine.objectContaining({ state: 'soon', relative: 'En 4 días' }));
  });
});
```

### Revisión con la URL

- Sin filtros: la URL es `/cursos`, sin `?f=`.
- Aplica modalidad, búsqueda y página 2; copia el enlace; ábrelo en una ventana de incógnito: aparece exactamente la misma vista.
- La barra de direcciones no muestra "excel", "VIRTUAL" ni "page".
- Cambia un carácter del token a mano y recarga: aparece la vista por defecto y la URL se limpia sola.
- Pega un token generado en otra pantalla: se ignora.
- Escribe en el buscador: la URL cambia una sola vez, al dejar de escribir.
- Cambia dos filtros y presiona **atrás** dos veces: deshace uno por uno.
- Abre un enlace a la página 5 cuando solo hay 2: queda en la página 2.
- Con el panel de edición abierto, guardar refresca la tabla y la URL sigue igual.
- Con SSR: la página renderiza con los filtros del enlace desde el servidor, sin parpadeo.

### Revisión visual contra Certificados

Pon las dos pantallas lado a lado:

- Mismo tamaño y peso del título y del subtítulo.
- Misma tarjeta de vidrio, mismo radio y misma sombra.
- Mismo alto de los campos de filtro y mismo color de las etiquetas.
- Encabezado de la tabla con el mismo amarillo y el texto en mayúsculas.
- Botones de acción del mismo tamaño, forma y color que ver / editar / eliminar.
- Paginación con las mismas flechas redondas.

Si algo no coincide, busca la clase que usa Certificados y úsala aquí en lugar de la de esta guía.

---

## 13. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| La primera petición sale sin filtros y luego se repite con ellos | `syncCourseQueryWithUrl` se llamó después de algo que ya leyó la consulta | Llámalo **primero** en el constructor de la página. |
| El historial se llena con cada tecla | El buscador escribe la consulta sin rebote | El input actualiza `searchDraft`; solo el `debounceTime(350)` llama a `patchQuery`. |
| El espacio desaparece mientras se escribe | El `effect` sobrescribe el input con la búsqueda recortada | Compara `searchDraft().trim()` con la búsqueda antes de hacer `set`. |
| `InvalidCharacterError` en `btoa` | Se pasó un texto con tildes directo a `btoa` | Usa `TextEncoder` antes, como en `url-state.ts`. |
| El token deja de funcionar al cambiar un campo | Se cambió una clave corta sin subir la versión | Sube `VERSION` y, si hace falta, lee la versión anterior en `decodeUrlState`. |
| Los selects no muestran el filtro del enlace | `[value]` en el `<select>` se aplica antes de que existan las opciones | Usa `[selected]` en cada `<option>`, como en la plantilla. |
| El encabezado de la tabla no toma el amarillo | `--cu-accent` apunta a `--bs-primary` y el primario de la app no es el amarillo | Apunta `--cu-accent` a la variable del amarillo que usa Certificados. |
| Copiar enlace falla | `navigator.clipboard` requiere HTTPS o `localhost` | En producción ya es HTTPS; en otro entorno se muestra el aviso para copiar a mano. |

---

## ✅ Checklist

- [ ] Tokens movidos a `_courses-tokens.scss` y `--cu-accent` apuntando al amarillo de Certificados.
- [ ] `CourseQuery` con `sort` y `direction`; `DEFAULT_COURSE_QUERY` exportada.
- [ ] `CoursesService.list` envía `sort` y `direction`.
- [ ] Backend: `sort` y `direction` con lista blanca, nulos al final y desempate por `Id`.
- [ ] Facade: `toggleSort`, `setQuery`, `clearFilters` conserva el orden y corrección de página fuera de rango.
- [ ] `url-state.ts` en `@shared/utils` y `course-query.url.ts` con validación campo por campo.
- [ ] `syncCourseQueryWithUrl` llamado primero en el constructor de la página.
- [ ] Ruta `cursos` apunta a `CoursesListPageComponent`.
- [ ] Probado: enlace compartido en incógnito, token alterado, botón atrás, página fuera de rango.
- [ ] Revisado lado a lado con Módulo de Certificados.
- [ ] Nada sensible dentro del token.
- [ ] Pruebas unitarias de `url-state`, `course-query.url`, `toggleSort` y `describeDue` en verde.
