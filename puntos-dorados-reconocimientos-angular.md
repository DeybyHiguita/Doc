# 🔌 Puntos Dorados — Conectar reconocimientos (Angular)

Cómo conectar las pestañas **Feed**, **Reconocer** y **Mis reconocimientos** de `PuntosDoradosUserComponent` con la API de [puntos-dorados-reconocimientos-api.md](puntos-dorados-reconocimientos-api.md).

Sigue lo que ya tiene el proyecto: un solo facade (`puntos-dorados.fecade.ts`) cuyos métodos devuelven `{ hasError, response }`, estado en signals dentro del componente y carga de cada pestaña la primera vez que se abre.

---

## 1. Qué cambia y por qué

| Hoy | Problema | Con la API |
|---|---|---|
| `getNominations()` trae **todos** los reconocimientos y el componente filtra el feed y "Mis reconocimientos". | Con cientos de reconocimientos se descarga todo. Además, el navegador recibe los de todos, incluidos pendientes, privados y los puntos de otros. | Tres listas paginadas desde el servidor: `feed`, `sent` y `received`. Cada una trae solo lo que esa persona puede ver. |
| `refreshFeedReactions()` llama `getReactions(id)` **una vez por tarjeta**. | 20 tarjetas son 20 peticiones. | Cada tarjeta del feed ya trae sus conteos y "mis reacciones". Reaccionar devuelve el conteo actualizado: **cero peticiones extra**. |
| Las reacciones envían `userEmail` desde el navegador. | Cualquiera podría reaccionar en nombre de otra persona. | El usuario sale del token en la API. El frontend no envía correos. |
| Una sola reacción por persona (`selectedReactionByRecognition`). | No coincide con la API. | Cada tipo (Like, Aplauso, Inspirador, Orgullo) se activa y se quita por separado. |
| La tarjeta muestra el área bajo el nombre ("Operaciones"). | `User` no tiene área en EF: la API la envía vacía por ahora. | Ocultar la línea cuando venga vacía: `@if (item.nominee.area) { … }`. |
| `currentUser` usa `people()[0]` cuando no encuentra el correo. | Es un resto de los datos de prueba: si el usuario de MSAL no está en `people`, la pantalla actúa como **otra persona** (puntos, redenciones). | Se quita esa alternativa (sección 6.6). |
| La pestaña "Reconocer" solo tiene el botón. | No se ven los reconocimientos enviados. | Lista "Reconocimientos que has enviado", con su estado. |

**El panel de administración no cambia.** `PuntosDoradosAdminComponent` sigue usando `getNominations()` para aprobaciones y dashboard hasta la parte 2 (aprobaciones). Por eso no se borra `getNominations()` del facade.

---

## 2. Ajuste en la API (ya está en la guía del backend)

El formulario elige a la persona por **correo** (`nomineeEmail`) y la API pedía su **id**. Se ajustó la API para aceptar `nomineeEmail`, que busca en `users.corporative_email`. Así el formulario no cambia.

Los cambios están en [puntos-dorados-reconocimientos-api.md](puntos-dorados-reconocimientos-api.md):
- **`CreateGoldenRecognitionDto`:** nuevo campo `NomineeEmail`.
- **`GoldenRecognitionValidator`:** acepta el id o el correo.
- **`CreateAsync`:** busca a la persona por id o por correo, y valida "no reconocerse a sí mismo" con el id encontrado.

> ⚠️ **La lista de personas debe ser real.** El selector "Colaborador reconocido" usa `facade.getPeople()`. Si eso todavía devuelve datos de prueba, la API responde "La persona seleccionada no existe" porque ese correo no está en `dbo.users`. Confirma que `getPeople()` consulta usuarios reales.

---

## 3. Archivos

```text
src/app/features/puntos-dorados/
├── domain/puntos-dorados.ts                       ✏️ tipos de la API (resultado, página, feed, reacciones)
├── infraestructure/                               (la carpeta donde está el servicio de productos)
│   ├── golden-recognitions.service.ts             nuevo — HttpClient
│   └── golden-recognitions.mapper.ts              nuevo — DTO → dominio, fechas UTC
├── application/
│   ├── paged-list.ts                              nuevo ⭐ estado de una lista paginada con "Cargar más"
│   └── puntos-dorados.fecade.ts                   ✏️ + 7 métodos
└── presentation/
    ├── user/puntos-dorados-user.component.ts      ✏️
    ├── user/puntos-dorados-user.component.html    ✏️
    ├── user/puntos-dorados-user.component.scss    ✏️
    └── shared/postular-nomination-modal/          ✏️ errores y estado "Enviando…"
```

---

## 4. Paso 1 — Dominio (`domain/puntos-dorados.ts`) ✏️

Agrega al final del archivo. `GoldenNomination` solo suma dos campos **opcionales**, así que el panel de administración no se rompe.

```ts
// ── En GoldenNomination, agrega (opcionales) ─────────────────────────
//   categoryIcon?: string;
//   categoryColor?: string;

/** Respuesta de la API: { response, hasError, errors }. */
export type GoldenResult<T> =
  | { hasError: false; response: T; errors: string[] }
  | { hasError: true; response: null; errors: string[] };

export interface GoldenPagedResult<T> {
  items: T[];
  page: number;
  pageSize: number;
  totalCount: number;
  totalPages: number;
}

export const GOLDEN_REACTION_TYPES: readonly GoldenReactionType[] = ['Like', 'Aplauso', 'Inspirador', 'Orgullo'];

/** Conteo de reacciones de un reconocimiento y las que dio el usuario actual. */
export interface GoldenReactionSummary {
  recognitionId: number;
  counts: Record<GoldenReactionType, number>;
  myReactions: GoldenReactionType[];
  total: number;
}

/** Tarjeta del feed: un reconocimiento aprobado y público. No tiene puntos. */
export interface GoldenFeedItem extends Omit<GoldenNomination, 'pointsAssigned' | 'comments'> {
  categoryIcon: string;
  categoryColor: string;
  approvedAt: Date | null;
  reactions: GoldenReactionSummary;
}

/** Formulario "Crear reconocimiento". */
export interface CreateGoldenRecognition {
  nomineeEmail: string;
  categoryId: number;
  reason: string;
  visibility?: GoldenRecognitionVisibility;
}
```

> Si el facade ya tiene un tipo para `{ response, hasError, errors }` (por ejemplo `ResponseDto<T>`), usa ese en lugar de `GoldenResult<T>`. Lo importante es que, cuando `hasError` es `false`, TypeScript sepa que `response` no es `null`.

---

## 5. Paso 2 — Infraestructura

### `infraestructure/golden-recognitions.mapper.ts`

```ts
import { HttpErrorResponse } from '@angular/common/http';
import {
  GOLDEN_REACTION_TYPES,
  GoldenFeedItem,
  GoldenNomination,
  GoldenNominationStatus,
  GoldenPagedResult,
  GoldenPerson,
  GoldenReactionSummary,
  GoldenReactionType,
  GoldenRecognitionVisibility,
  GoldenResult,
} from '../domain/puntos-dorados';

// ── Lo que envía la API ──────────────────────────────────────────────
interface GoldenPersonDto {
  id: number;
  name: string;
  email: string;
  area: string;
}

export interface GoldenRecognitionDto {
  id: number;
  nominee: GoldenPersonDto;
  nominatedBy: GoldenPersonDto;
  reason: string;
  categoryId: number;
  categoryName: string;
  categoryIcon: string;
  categoryColor: string;
  status: string;
  visibility: string;
  pointsAssigned: number | null;
  createdAt: string;
  reviewedAt: string | null;
}

export interface GoldenReactionSummaryDto {
  recognitionId: number;
  counts: Record<string, number>;
  myReactions: string[];
  total: number;
}

export interface GoldenFeedItemDto {
  id: number;
  nominee: GoldenPersonDto;
  nominatedBy: GoldenPersonDto;
  reason: string;
  categoryId: number;
  categoryName: string;
  categoryIcon: string;
  categoryColor: string;
  createdAt: string;
  approvedAt: string | null;
  reactions: GoldenReactionSummaryDto;
}

export interface GoldenPagedResultDto<T> {
  items: T[];
  page: number;
  pageSize: number;
  totalCount: number;
  totalPages: number;
}

/** La API responde con errors posiblemente null y response null cuando hay error. */
export interface GoldenResultDto<T> {
  hasError: boolean;
  response: T | null;
  errors?: string[] | null;
}

// ── Conversión ───────────────────────────────────────────────────────

/** Aplica fn a la respuesta solo si no hubo error. */
export function toResult<A, B>(dto: GoldenResultDto<A>, fn: (value: A) => B): GoldenResult<B> {
  if (dto.hasError || dto.response === null) {
    return { hasError: true, response: null, errors: dto.errors?.length ? dto.errors : ['No se pudo completar la operación.'] };
  }

  return { hasError: false, response: fn(dto.response), errors: [] };
}

export function toPage<A, B>(dto: GoldenPagedResultDto<A>, fn: (item: A) => B): GoldenPagedResult<B> {
  return { ...dto, items: dto.items.map(fn) };
}

/** Las fechas llegan en UTC sin la Z final: sin esto el navegador las toma como hora local (5 h de diferencia). */
export function parseUtc(value: string): Date {
  return new Date(/[zZ]|[+-]\d{2}:\d{2}$/.test(value) ? value : `${value}Z`);
}

function toPerson(dto: GoldenPersonDto): GoldenPerson {
  return { id: String(dto.id), name: dto.name, email: dto.email, area: dto.area, role: '' };
}

function toStatus(value: string): GoldenNominationStatus {
  return value === 'Aprobada' || value === 'Rechazada' ? value : 'Pendiente';
}

function toVisibility(value: string): GoldenRecognitionVisibility {
  return value === 'Privada' ? 'Privada' : 'Publica';
}

function isReactionType(value: string): value is GoldenReactionType {
  return (GOLDEN_REACTION_TYPES as readonly string[]).includes(value);
}

export function toNomination(dto: GoldenRecognitionDto): GoldenNomination {
  return {
    id: dto.id,
    nominee: toPerson(dto.nominee),
    nominatedBy: toPerson(dto.nominatedBy),
    reason: dto.reason,
    categoryId: dto.categoryId,
    categoryName: dto.categoryName,
    categoryIcon: dto.categoryIcon,
    categoryColor: dto.categoryColor,
    status: toStatus(dto.status),
    visibility: toVisibility(dto.visibility),
    comments: [], // los comentarios de aprobación llegan con la parte 2
    pointsAssigned: dto.pointsAssigned ?? undefined,
    createdAt: parseUtc(dto.createdAt),
    reviewedAt: dto.reviewedAt ? parseUtc(dto.reviewedAt) : undefined,
  };
}

export function toReactionSummary(dto: GoldenReactionSummaryDto): GoldenReactionSummary {
  const counts = Object.fromEntries(GOLDEN_REACTION_TYPES.map(type => [type, dto.counts?.[type] ?? 0])) as Record<GoldenReactionType, number>;

  return {
    recognitionId: dto.recognitionId,
    counts,
    myReactions: (dto.myReactions ?? []).filter(isReactionType),
    total: dto.total,
  };
}

export function toFeedItem(dto: GoldenFeedItemDto): GoldenFeedItem {
  return {
    id: dto.id,
    nominee: toPerson(dto.nominee),
    nominatedBy: toPerson(dto.nominatedBy),
    reason: dto.reason,
    categoryId: dto.categoryId,
    categoryName: dto.categoryName,
    categoryIcon: dto.categoryIcon,
    categoryColor: dto.categoryColor,
    status: 'Aprobada', // el feed solo trae aprobados: así la plantilla actual sigue funcionando
    visibility: 'Publica',
    createdAt: parseUtc(dto.createdAt),
    approvedAt: dto.approvedAt ? parseUtc(dto.approvedAt) : null,
    reactions: toReactionSummary(dto.reactions),
  };
}

/** Mensaje para el usuario cuando la petición falla antes de llegar al servicio (red, sesión, 500). */
export function toErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof HttpErrorResponse) {
    if (error.status === 0) {
      return 'No hay conexión con el servidor. Revisa tu red e intenta de nuevo.';
    }

    if (error.status === 401) {
      return 'Tu sesión expiró. Vuelve a iniciar sesión.';
    }

    const body = error.error as { message?: string; errors?: string[] } | null;
    if (body?.errors?.length) {
      return body.errors.join(' ');
    }

    if (body?.message) {
      return body.message;
    }
  }

  return fallback;
}
```

### `infraestructure/golden-recognitions.service.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment'; // ⬅ el mismo import que usa el servicio de productos
import {
  CreateGoldenRecognition,
  GoldenFeedItem,
  GoldenNomination,
  GoldenPagedResult,
  GoldenReactionSummary,
  GoldenReactionType,
  GoldenResult,
} from '../domain/puntos-dorados';
import {
  GoldenFeedItemDto,
  GoldenPagedResultDto,
  GoldenReactionSummaryDto,
  GoldenRecognitionDto,
  GoldenResultDto,
  toFeedItem,
  toNomination,
  toPage,
  toReactionSummary,
  toResult,
} from './golden-recognitions.mapper';

@Injectable({ providedIn: 'root' })
export class GoldenRecognitionsService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/api/GoldenRecognitions`;

  getFeed(page: number, pageSize: number, categoryId?: number | null): Observable<GoldenResult<GoldenPagedResult<GoldenFeedItem>>> {
    let params = this.pageParams(page, pageSize);
    if (categoryId) {
      params = params.set('categoryId', categoryId);
    }

    return this.http
      .get<GoldenResultDto<GoldenPagedResultDto<GoldenFeedItemDto>>>(`${this.baseUrl}/feed`, { params })
      .pipe(map(dto => toResult(dto, pageDto => toPage(pageDto, toFeedItem))));
  }

  /** Los que creó el usuario (todos los estados, sin puntos). */
  getSent(page: number, pageSize: number): Observable<GoldenResult<GoldenPagedResult<GoldenNomination>>> {
    return this.http
      .get<GoldenResultDto<GoldenPagedResultDto<GoldenRecognitionDto>>>(`${this.baseUrl}/sent`, { params: this.pageParams(page, pageSize) })
      .pipe(map(dto => toResult(dto, pageDto => toPage(pageDto, toNomination))));
  }

  /** Los aprobados que recibió el usuario (con puntos). */
  getReceived(page: number, pageSize: number): Observable<GoldenResult<GoldenPagedResult<GoldenNomination>>> {
    return this.http
      .get<GoldenResultDto<GoldenPagedResultDto<GoldenRecognitionDto>>>(`${this.baseUrl}/received`, { params: this.pageParams(page, pageSize) })
      .pipe(map(dto => toResult(dto, pageDto => toPage(pageDto, toNomination))));
  }

  create(draft: CreateGoldenRecognition): Observable<GoldenResult<GoldenNomination>> {
    return this.http
      .post<GoldenResultDto<GoldenRecognitionDto>>(this.baseUrl, draft)
      .pipe(map(dto => toResult(dto, toNomination)));
  }

  getReactions(recognitionId: number): Observable<GoldenResult<GoldenReactionSummary>> {
    return this.http
      .get<GoldenResultDto<GoldenReactionSummaryDto>>(`${this.baseUrl}/${recognitionId}/reactions`)
      .pipe(map(dto => toResult(dto, toReactionSummary)));
  }

  /** Idempotente: repetirlo no cambia nada. */
  addReaction(recognitionId: number, type: GoldenReactionType): Observable<GoldenResult<GoldenReactionSummary>> {
    return this.http
      .put<GoldenResultDto<GoldenReactionSummaryDto>>(this.reactionUrl(recognitionId, type), {})
      .pipe(map(dto => toResult(dto, toReactionSummary)));
  }

  /** Idempotente: si no había reaccionado, no cambia nada. */
  removeReaction(recognitionId: number, type: GoldenReactionType): Observable<GoldenResult<GoldenReactionSummary>> {
    return this.http
      .delete<GoldenResultDto<GoldenReactionSummaryDto>>(this.reactionUrl(recognitionId, type))
      .pipe(map(dto => toResult(dto, toReactionSummary)));
  }

  private pageParams(page: number, pageSize: number): HttpParams {
    return new HttpParams().set('page', page).set('pageSize', pageSize);
  }

  private reactionUrl(recognitionId: number, type: GoldenReactionType): string {
    return `${this.baseUrl}/${recognitionId}/reactions/${encodeURIComponent(type)}`;
  }
}
```

---

## 6. Paso 3 — Aplicación

### `application/paged-list.ts` ⭐

El estado de una lista paginada con "Cargar más". Se usa tres veces: feed, enviados y recibidos.

```ts
import { Signal, computed, signal } from '@angular/core';
import { GoldenPagedResult, GoldenResult } from '../domain/puntos-dorados';

export type PageLoader<T> = (page: number, pageSize: number) => Promise<GoldenResult<GoldenPagedResult<T>>>;

/**
 * Lista paginada en el servidor: carga la primera página, agrega las siguientes con "Cargar más"
 * y descarta respuestas que llegan tarde (si se recarga mientras se pedía otra página).
 */
export class PagedList<T> {
  private readonly _items = signal<readonly T[]>([]);
  private readonly _page = signal(0);
  private readonly _totalPages = signal(0);
  private readonly _totalCount = signal(0);
  private readonly _loading = signal(false);
  private readonly _loaded = signal(false);
  private readonly _error = signal<string | null>(null);
  private requestId = 0;

  readonly items: Signal<readonly T[]> = this._items.asReadonly();
  readonly totalCount = this._totalCount.asReadonly();
  readonly loading = this._loading.asReadonly();
  readonly loaded = this._loaded.asReadonly();
  readonly error = this._error.asReadonly();
  readonly hasMore = computed(() => this._page() < this._totalPages());
  readonly isEmpty = computed(() => this._loaded() && this._items().length === 0);
  /** Primera carga: para mostrar esqueletos en lugar de la lista vacía. */
  readonly isFirstLoad = computed(() => this._loading() && !this._loaded());

  constructor(
    private readonly loader: PageLoader<T>,
    private readonly idOf: (item: T) => number,
    private readonly pageSize = 10,
  ) {}

  /** Carga la primera página solo si nunca se cargó. */
  ensureLoaded(): Promise<void> {
    if (this._loaded() || this._loading()) {
      return Promise.resolve();
    }

    return this.reload();
  }

  /** Vuelve a la primera página (después de crear un reconocimiento, por ejemplo). */
  reload(): Promise<void> {
    return this.fetch(1, true);
  }

  loadMore(): Promise<void> {
    if (this._loading() || !this.hasMore()) {
      return Promise.resolve();
    }

    return this.fetch(this._page() + 1, false);
  }

  /** Cambia un elemento sin recargar (por ejemplo, sus reacciones). */
  patch(id: number, change: (item: T) => T): void {
    this._items.update(items => items.map(item => (this.idOf(item) === id ? change(item) : item)));
  }

  private async fetch(page: number, replace: boolean): Promise<void> {
    const request = ++this.requestId;
    this._loading.set(true);
    this._error.set(null);

    try {
      const result = await this.loader(page, this.pageSize);

      // Llegó otra petición después de esta: esta respuesta ya no vale.
      if (request !== this.requestId) {
        return;
      }

      if (result.hasError) {
        this._error.set(result.errors.join(' '));
        return;
      }

      const incoming = result.response.items;

      if (replace) {
        this._items.set(incoming);
      } else {
        // Si se aprobaron reconocimientos mientras se paginaba, la página siguiente puede repetir alguno.
        const seen = new Set(this._items().map(this.idOf));
        this._items.update(items => [...items, ...incoming.filter(item => !seen.has(this.idOf(item)))]);
      }

      this._page.set(result.response.page);
      this._totalPages.set(result.response.totalPages);
      this._totalCount.set(result.response.totalCount);
      this._loaded.set(true);
    } finally {
      if (request === this.requestId) {
        this._loading.set(false);
      }
    }
  }
}
```

### `application/puntos-dorados.fecade.ts` ✏️ — métodos nuevos

```ts
import { Observable, firstValueFrom } from 'rxjs';
import { GoldenRecognitionsService } from '../infraestructure/golden-recognitions.service';
import { toErrorMessage } from '../infraestructure/golden-recognitions.mapper';
import {
  CreateGoldenRecognition,
  GoldenFeedItem,
  GoldenNomination,
  GoldenPagedResult,
  GoldenReactionSummary,
  GoldenReactionType,
  GoldenResult,
} from '../domain/puntos-dorados';

// Dentro de la clase PuntosDoradosFacade:
private readonly recognitions = inject(GoldenRecognitionsService);

// ── Reconocimientos (API) ────────────────────────────────────────────

getRecognitionFeed(page: number, pageSize: number, categoryId?: number | null): Promise<GoldenResult<GoldenPagedResult<GoldenFeedItem>>> {
  return this.toPromise(this.recognitions.getFeed(page, pageSize, categoryId), 'No se pudo cargar el feed de reconocimientos.');
}

getSentRecognitions(page: number, pageSize: number): Promise<GoldenResult<GoldenPagedResult<GoldenNomination>>> {
  return this.toPromise(this.recognitions.getSent(page, pageSize), 'No se pudieron cargar los reconocimientos que enviaste.');
}

getReceivedRecognitions(page: number, pageSize: number): Promise<GoldenResult<GoldenPagedResult<GoldenNomination>>> {
  return this.toPromise(this.recognitions.getReceived(page, pageSize), 'No se pudieron cargar tus reconocimientos.');
}

createRecognition(draft: CreateGoldenRecognition): Promise<GoldenResult<GoldenNomination>> {
  return this.toPromise(this.recognitions.create(draft), 'No se pudo enviar el reconocimiento. Intenta de nuevo.');
}

getRecognitionReactions(recognitionId: number): Promise<GoldenResult<GoldenReactionSummary>> {
  return this.toPromise(this.recognitions.getReactions(recognitionId), 'No se pudieron cargar las reacciones.');
}

addRecognitionReaction(recognitionId: number, type: GoldenReactionType): Promise<GoldenResult<GoldenReactionSummary>> {
  return this.toPromise(this.recognitions.addReaction(recognitionId, type), 'No se pudo guardar tu reacción.');
}

removeRecognitionReaction(recognitionId: number, type: GoldenReactionType): Promise<GoldenResult<GoldenReactionSummary>> {
  return this.toPromise(this.recognitions.removeReaction(recognitionId, type), 'No se pudo quitar tu reacción.');
}

/** Errores de red, sesión o 500 se devuelven como { hasError: true } en lugar de lanzar: el componente solo revisa hasError. */
private async toPromise<T>(request: Observable<GoldenResult<T>>, fallback: string): Promise<GoldenResult<T>> {
  try {
    return await firstValueFrom(request);
  } catch (error) {
    return { hasError: true, response: null, errors: [toErrorMessage(error, fallback)] };
  }
}
```

> **Métodos que quedan sin uso:** `getReactions(recognitionId)`, `reactToRecognition(...)` y `removeReaction(recognitionId, email)` ya no los usa el colaborador. Antes de borrarlos, busca si otro archivo los usa (`grep -rn "reactToRecognition\|removeReaction(" src/app`). `getNominations()` **se queda**: lo usa el administrador.
>
> Si el facade ya tiene un helper que convierte errores HTTP en `{ hasError: true }`, usa ese en lugar de `toPromise`.

---

## 7. Paso 4 — `puntos-dorados-user.component.ts` ✏️

### 7.1 Imports

```ts
import { GoldenFeedItem, GoldenNomination, GoldenReactionType } from '../../domain/puntos-dorados';
import { PagedList } from '../../application/paged-list';
```

Quita `type FeedReaction = …` (ahora es `GoldenReactionType`) y, si queda sin uso, `GoldenRecognitionReaction` del import del dominio.

### 7.2 Quitar

| Qué | Por qué |
|---|---|
| `nominations = signal<GoldenNomination[]>([])` | El colaborador ya no descarga todos los reconocimientos. |
| `likesByRecognition`, `myLikeByRecognition`, `selectedReactionByRecognition` | Las reacciones vienen dentro de cada tarjeta del feed. |
| `myNominations = computed(…)` y `publicFeedNominations = computed(…)` (los actuales) | Se reemplazan por las listas de la API (7.3). |
| `toggleLike`, `setReaction`, `refreshFeedReactions`, `refreshRecognitionReactions`, `refreshNominations` | Se reemplazan por `toggleReaction` y `reload()`. |

### 7.3 Agregar (después de `private readonly platformId = …`)

```ts
// ── Reconocimientos: listas paginadas en el servidor, lo más reciente primero ──
readonly feed = new PagedList<GoldenFeedItem>(
  (page, pageSize) => this.facade.getRecognitionFeed(page, pageSize),
  item => item.id,
);

readonly sentRecognitions = new PagedList<GoldenNomination>(
  (page, pageSize) => this.facade.getSentRecognitions(page, pageSize),
  item => item.id,
);

readonly receivedRecognitions = new PagedList<GoldenNomination>(
  (page, pageSize) => this.facade.getReceivedRecognitions(page, pageSize),
  item => item.id,
);

/** Mismos nombres que usaba la plantilla: así los @for actuales siguen funcionando. */
readonly publicFeedNominations = this.feed.items;
readonly myNominations = this.receivedRecognitions.items;

readonly reactionOptions: readonly { type: GoldenReactionType; icon: string; label: string }[] = [
  { type: 'Like', icon: 'fa-solid fa-thumbs-up', label: 'Me gusta' },
  { type: 'Aplauso', icon: 'fa-solid fa-hands-clapping', label: 'Aplauso' },
  { type: 'Inspirador', icon: 'fa-solid fa-lightbulb', label: 'Inspirador' },
  { type: 'Orgullo', icon: 'fa-solid fa-medal', label: 'Orgullo' },
];

/** Reacciones en camino ("id:tipo"): evita el doble clic. */
private readonly pendingReactions = signal<ReadonlySet<string>>(new Set());

readonly submittingNomination = signal(false);
readonly nominationErrors = signal<string[]>([]);

/** Personas que se pueden reconocer: todas menos uno mismo. */
readonly nomineeOptions = computed(() => {
  const me = this.userEmail().toLowerCase();
  return this.people().filter(person => person.email.toLowerCase() !== me);
});
```

> `feed`, `sentRecognitions` y `receivedRecognitions` usan `this.facade`, así que deben declararse **después** de `private readonly facade = inject(PuntosDoradosFacade)`.

### 7.4 Cargar cada lista al abrir su pestaña

En `setActiveTab`, junto a los `if` de "reconocer" y "redimir":

```ts
this.ensureRecognitionTab(tab);
```

En `loadRecognizeTabData()` no hace falta nada: `ensureRecognitionTab('reconocer')` carga los enviados.

En `loadModuleData()`:

```ts
private async loadModuleData(): Promise<void> {
  const peopleResult = await this.facade.getPeople(); // getNominations() ya no

  if (!peopleResult.hasError) {
    this.people.set(peopleResult.response);
    // ⬇ Quitar el bloque que tomaba userEmail/userName/userRole de people[0] (ver 7.6).
  }

  this.ensureRecognitionTab(this.activeTab()); // el feed, si es la pestaña inicial

  await this.refreshUserFinancialData();

  // … lo que ya tenías para 'reconocer' y 'redimir' …
}
```

Método nuevo:

```ts
/** Carga la lista de la pestaña la primera vez. Solo en el navegador: en SSR no hay token y la API respondería 401. */
private ensureRecognitionTab(tab: UserTab): void {
  if (!isPlatformBrowser(this.platformId)) {
    return;
  }

  if (tab === 'feed') {
    void this.feed.ensureLoaded();
  }

  if (tab === 'reconocer') {
    void this.sentRecognitions.ensureLoaded();
  }

  if (tab === 'mis-reconocimientos') {
    void this.receivedRecognitions.ensureLoaded();
  }
}
```

### 7.5 Reacciones y crear reconocimiento

```ts
hasReacted(item: GoldenFeedItem, type: GoldenReactionType): boolean {
  return item.reactions.myReactions.includes(type);
}

reactionCount(item: GoldenFeedItem, type: GoldenReactionType): number {
  return item.reactions.counts[type] ?? 0;
}

isReactionPending(recognitionId: number, type: GoldenReactionType): boolean {
  return this.pendingReactions().has(`${recognitionId}:${type}`);
}

/** Activa o quita una reacción. La API devuelve el conteo actualizado: no hace falta volver a consultar. */
async toggleReaction(item: GoldenFeedItem, type: GoldenReactionType): Promise<void> {
  const key = `${item.id}:${type}`;
  if (this.pendingReactions().has(key)) {
    return;
  }

  this.pendingReactions.update(current => new Set(current).add(key));

  try {
    const result = this.hasReacted(item, type)
      ? await this.facade.removeRecognitionReaction(item.id, type)
      : await this.facade.addRecognitionReaction(item.id, type);

    if (!result.hasError) {
      this.feed.patch(item.id, current => ({ ...current, reactions: result.response }));
    }
  } finally {
    this.pendingReactions.update(current => {
      const next = new Set(current);
      next.delete(key);
      return next;
    });
  }
}

async submitNomination(): Promise<void> {
  this.nominationForm.markAllAsTouched();
  if (this.nominationForm.invalid || this.submittingNomination()) {
    return;
  }

  const { nomineeEmail, categoryId, reason } = this.nominationForm.getRawValue();
  this.submittingNomination.set(true);
  this.nominationErrors.set([]);

  try {
    const result = await this.facade.createRecognition({
      nomineeEmail,
      categoryId: Number(categoryId),
      reason: reason.trim(),
    });

    if (result.hasError) {
      // Se quedan en el modal: el usuario corrige sin perder lo que escribió.
      this.nominationErrors.set(result.errors);
      return;
    }

    this.closePostularModal();
    await this.sentRecognitions.reload(); // el nuevo aparece primero, como Pendiente
  } finally {
    this.submittingNomination.set(false);
  }
}
```

En `closePostularModal()`, agrega `this.nominationErrors.set([]);`.

> **Mínimo de 15 caracteres.** `Validators.minLength(15)` cuenta los espacios y la API cuenta sin ellos. Si alguien escribe "Buen trabajo   " (12 letras y espacios), el formulario lo deja pasar y la API responde el error, que se muestra en el modal. Para avisar antes, cambia el validador por uno que haga `trim()`.

### 7.6 Corrección recomendada: `currentUser`

```ts
// Antes: si el correo no estaba en people, tomaba people()[0] (resto de los datos de prueba).
currentUser = computed(() => {
  const email = this.userEmail().toLowerCase();
  return this.people().find(person => person.email.toLowerCase() === email) ?? null;
});
```

Quita también, en `loadModuleData`, el bloque que ponía `userEmail`, `userName` y `userRole` desde `people[0]`. El usuario real lo carga `bootstrapUserContext()` desde MSAL. Sin este cambio, mientras MSAL no responde (o si el usuario no está en `people`), `refreshUserFinancialData()` consulta puntos y redenciones **de otra persona**.

---

## 8. Paso 5 — Plantilla y estilos

### 8.1 Feed (`@case` o `@if` de la pestaña `feed`)

El `@for (item of publicFeedNominations(); …)` y la tarjeta se quedan como están. Cambia:

| Antes | Después |
|---|---|
| Fecha `item.createdAt` | `item.approvedAt ?? item.createdAt` (el feed ordena por fecha de aprobación) |
| Botón "Me gusta" con `likesByRecognition()[item.id]`, `myLikeByRecognition()[item.id]`, `toggleLike(item.id)` | Bloque de reacciones de abajo |
| Iconos con `selectedReactionByRecognition()[item.id] === '…'` y `setReaction(item.id, '…')` | Bloque de reacciones de abajo |

```html
<div class="pd-reactions" role="group" [attr.aria-label]="'Reacciones al reconocimiento de ' + item.nominee.name">
  @for (option of reactionOptions; track option.type) {
    <button
      type="button"
      class="pd-reaction"
      [class.pd-reaction--main]="option.type === 'Like'"
      [class.is-active]="hasReacted(item, option.type)"
      [disabled]="isReactionPending(item.id, option.type)"
      [attr.aria-pressed]="hasReacted(item, option.type)"
      [attr.aria-label]="option.label + ': ' + reactionCount(item, option.type)"
      [title]="option.label"
      (click)="toggleReaction(item, option.type)">
      <i [class]="option.icon" aria-hidden="true"></i>
      @if (option.type === 'Like') {
        <span>Me gusta</span>
      }
      @if (reactionCount(item, option.type) > 0) {
        <span class="pd-reaction__count">{{ reactionCount(item, option.type) }}</span>
      }
    </button>
  }
</div>
```

Después del `@for` del feed:

```html
@if (feed.isFirstLoad()) {
  <div class="pd-list-skeleton" aria-hidden="true"><span></span><span></span></div>
}

@if (feed.error()) {
  <div class="alert alert-danger d-flex justify-content-between align-items-center" role="alert">
    {{ feed.error() }}
    <button type="button" class="btn btn-sm btn-outline-danger" (click)="feed.reload()">Reintentar</button>
  </div>
}

@if (feed.isEmpty()) {
  <p class="pd-empty">Aún no hay reconocimientos publicados.</p>
}

@if (feed.hasMore()) {
  <button type="button" class="pd-load-more" [disabled]="feed.loading()" (click)="feed.loadMore()">
    {{ feed.loading() ? 'Cargando…' : 'Cargar más' }}
  </button>
}
```

### 8.2 Mis reconocimientos

El `@for (item of myNominations(); …)` sigue igual. Agrega el mismo bloque de carga, error, vacío y "Cargar más" con `receivedRecognitions` en lugar de `feed`. El texto para la lista vacía es "Aún no has recibido reconocimientos aprobados."

Los **comentarios de aprobación** llegan vacíos hasta la parte 2. Envuelve esa sección con `@if (item.comments?.length) { … }` para que no salga una caja vacía.

### 8.3 Reconocer — "Reconocimientos que has enviado"

Debajo de la tarjeta con el botón "Abrir reconocimiento":

```html
<section class="pd-sent" aria-labelledby="pd-sent-title">
  <h3 id="pd-sent-title" class="pd-sent__title">
    Reconocimientos que has enviado
    @if (sentRecognitions.totalCount()) {
      <span class="pd-sent__count">{{ sentRecognitions.totalCount() }}</span>
    }
  </h3>

  @for (item of sentRecognitions.items(); track item.id) {
    <article class="pd-sent__item">
      <header class="pd-sent__head">
        <strong>{{ item.nominee.name }}</strong>
        <span class="pd-status" [attr.data-status]="item.status">{{ item.status }}</span>
      </header>
      <p class="pd-sent__reason">{{ item.reason }}</p>
      <footer class="pd-sent__meta">
        <span>
          <i [class]="item.categoryIcon || 'fa-solid fa-medal'" [style.color]="item.categoryColor" aria-hidden="true"></i>
          {{ item.categoryName }}
        </span>
        <time [attr.datetime]="item.createdAt.toISOString()">{{ item.createdAt | date: 'dd/MM/yyyy' }}</time>
      </footer>
    </article>
  }

  @if (sentRecognitions.isFirstLoad()) {
    <div class="pd-list-skeleton" aria-hidden="true"><span></span><span></span></div>
  }

  @if (sentRecognitions.error()) {
    <div class="alert alert-danger" role="alert">{{ sentRecognitions.error() }}</div>
  }

  @if (sentRecognitions.isEmpty()) {
    <p class="pd-empty">Todavía no has reconocido a nadie. ¡Empieza con el botón de arriba!</p>
  }

  @if (sentRecognitions.hasMore()) {
    <button type="button" class="pd-load-more" [disabled]="sentRecognitions.loading()" (click)="sentRecognitions.loadMore()">
      {{ sentRecognitions.loading() ? 'Cargando…' : 'Cargar más' }}
    </button>
  }
</section>
```

### 8.4 Modal "Crear reconocimiento"

Donde se usa `<app-postular-nomination-modal>`:

| Antes | Después |
|---|---|
| `[people]="people()"` (o como se llame) | `[people]="nomineeOptions()"`: uno mismo no aparece en la lista |
| — | `[errors]="nominationErrors()"` |
| — | `[submitting]="submittingNomination()"` |

En `postular-nomination.modal.ts`:

```ts
readonly errors = input<readonly string[]>([]);
readonly submitting = input(false);
```

En su HTML, encima de los botones:

```html
@if (errors().length) {
  <div class="alert alert-danger py-2 small" role="alert">
    @for (error of errors(); track error) {
      <div>{{ error }}</div>
    }
  </div>
}
```

Y en el botón de enviar: `[disabled]="submitting()"` y el texto `{{ submitting() ? 'Enviando…' : 'Enviar reconocimiento' }}`.

> Si el modal usa `@Input()` en lugar de `input()`, declara los dos como `@Input() errors: readonly string[] = [];` y `@Input() submitting = false;`, y en el HTML quítales los paréntesis.

### 8.5 Estilos (`puntos-dorados-user.component.scss`)

Con los colores que ya usa la pantalla (dorado y tarjetas blancas). Cambia los `var(--bs-…)` por tus variables si las tienes.

```scss
// ── Reacciones ───────────────────────────────────────────────────────
.pd-reactions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  margin-top: 1rem;
}

.pd-reaction {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.35rem;
  min-width: 2.5rem;
  height: 2.5rem;
  padding: 0 0.75rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 999px;
  background: var(--bs-body-bg);
  color: var(--bs-secondary-color);
  font-weight: 600;
  transition: background-color 0.2s ease, border-color 0.2s ease, color 0.2s ease, transform 0.15s ease;

  &:hover:not(:disabled) {
    transform: translateY(-1px);
  }

  &:disabled {
    opacity: 0.6;
  }

  &.is-active {
    border-color: var(--bs-warning);
    background: color-mix(in srgb, var(--bs-warning) 18%, transparent);
    color: var(--bs-emphasis-color);

    i {
      animation: pd-pop 0.3s ease;
    }
  }

  &--main {
    padding: 0 1rem;
  }
}

.pd-reaction__count {
  font-size: 0.8rem;
}

@keyframes pd-pop {
  50% { transform: scale(1.3); }
}

// ── Enviados ─────────────────────────────────────────────────────────
.pd-sent {
  margin-top: 1.5rem;
}

.pd-sent__title {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 1.1rem;
  font-weight: 700;
}

.pd-sent__count {
  padding: 0 0.5rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--bs-warning) 18%, transparent);
  font-size: 0.8rem;
}

.pd-sent__item {
  margin-top: 0.75rem;
  padding: 1rem 1.25rem;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 1rem;
  background: var(--bs-body-bg);
}

.pd-sent__head,
.pd-sent__meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
}

.pd-sent__reason {
  margin: 0.5rem 0;
  color: var(--bs-secondary-color);
}

.pd-sent__meta {
  color: var(--bs-secondary-color);
  font-size: 0.8rem;
}

.pd-status {
  --tone: var(--bs-warning);

  padding: 0.15rem 0.65rem;
  border: 1px solid color-mix(in srgb, var(--tone) 55%, transparent);
  border-radius: 999px;
  color: color-mix(in srgb, var(--tone) 80%, var(--bs-body-color));
  font-size: 0.75rem;
  font-weight: 600;

  &[data-status='Aprobada'] { --tone: var(--bs-success); }
  &[data-status='Rechazada'] { --tone: var(--bs-danger); }
}

// ── Carga, vacío y "Cargar más" ──────────────────────────────────────
.pd-load-more {
  display: block;
  margin: 1rem auto 0;
  padding: 0.5rem 1.5rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 999px;
  background: var(--bs-body-bg);
  font-weight: 600;
}

.pd-empty {
  padding: 2rem 1rem;
  color: var(--bs-secondary-color);
  text-align: center;
}

.pd-list-skeleton {
  display: grid;
  gap: 0.75rem;
  margin-top: 0.75rem;

  span {
    height: 6rem;
    border-radius: 1rem;
    background: var(--bs-tertiary-bg);
    animation: pd-pulse 1.2s ease-in-out infinite alternate;
  }
}

@keyframes pd-pulse {
  to { opacity: 0.5; }
}

@media (prefers-reduced-motion: reduce) {
  .pd-reaction,
  .pd-reaction.is-active i,
  .pd-list-skeleton span {
    animation: none;
    transition: none;
  }
}
```

---

## 9. Pruebas

**Para tener datos en el feed** mientras no exista la aprobación, aprueba a mano con el SQL de la guía del backend (sección 4).

- **Feed:** abre la pantalla. La pestaña de red muestra **una** petición a `/feed`, no una por tarjeta.
- **Reaccionar:** clic en "Aplauso". Se activa, el conteo sube y no hay otra petición. Otro clic lo quita.
- **Doble clic rápido:** el botón se deshabilita mientras responde y el conteo queda bien.
- **Dos reacciones:** "Me gusta" y "Orgullo" en la misma tarjeta quedan activas a la vez.
- **Recargar (F5):** las reacciones siguen marcadas.
- **Crear:** abre el modal. Tú no apareces en la lista de personas. Envía y el modal se cierra. En "Reconocer" aparece el nuevo, primero, como **Pendiente**.
- **Crear repetido:** vuelve a reconocer a la misma persona en la misma categoría. El modal muestra el error de pendiente duplicado y no pierde lo escrito.
- **Mis reconocimientos:** solo aprobados recibidos, con puntos, el más reciente primero.
- **Cargar más:** con más de 10 reconocimientos aparece el botón; desaparece en la última página.
- **Hora:** la fecha coincide con la hora de Colombia.
- **Administrador:** el panel sigue funcionando igual (usa `getNominations()`).

---

## ✅ Checklist

- [ ] Ajuste de `nomineeEmail` aplicado en la API.
- [ ] `getPeople()` devuelve usuarios reales de `dbo.users`.
- [ ] Tipos nuevos en `domain/puntos-dorados.ts`; `categoryIcon` y `categoryColor` opcionales en `GoldenNomination`.
- [ ] `golden-recognitions.service.ts` y `golden-recognitions.mapper.ts` en la carpeta de infraestructura de la feature.
- [ ] `PagedList` en `application/`.
- [ ] Siete métodos nuevos en el facade; `getNominations()` se queda para el administrador.
- [ ] En el componente: listas `feed`, `sentRecognitions` y `receivedRecognitions`; quitados `nominations`, los tres mapas de reacciones y los métodos viejos.
- [ ] `currentUser` sin la alternativa `people()[0]`.
- [ ] Plantilla: bloque de reacciones, "Cargar más" en las tres listas, lista de enviados en "Reconocer" y comentarios con `@if`.
- [ ] Modal con `errors`, `submitting` y `nomineeOptions()`.
- [ ] Probado con dos usuarios distintos (uno reconoce y reacciona, el otro ve "Mis reconocimientos").
