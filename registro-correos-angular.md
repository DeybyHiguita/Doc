# 📧 Registro de correos (Angular 20 + Bootstrap 5)

Pantalla para consultar el log de correos que envía DOCCB.

- **Filtros en pantalla:** tipo de alerta, nombre del destinatario y correo del destinatario.
- **Filtro por URL:** por ahora **solo el correo**. Otra pantalla puede tener un botón "Ver correos enviados" que abre esta, ya filtrada por el correo de una persona.
- **Cada fila** es un correo recibido por una persona: fecha, tipo, destinatario, estado y, si falló, el error.

---

- **Stack:** Angular 20 · standalone · signals · OnPush · Bootstrap 5.3 · Font Awesome · SSR · MSAL
- **Backend:** [log-envio-correos-api.md](log-envio-correos-api.md), sección 11 (`GET /api/email-alert-logs` y `/types`)
- **Filtros por URL:** [filtros-url-angular.md](filtros-url-angular.md) (`defineUrlQuery`, `syncQueryWithUrl`, `createSearchDraft`). Esta pantalla no agrega nada a `shared`: solo declara su esquema.
- **Estilos:** los de la app ([referencia-estilos-y-capas-doccb.md](referencia-estilos-y-capas-doccb.md)).

---

## 1. 🧐 Revisión crítica

| # | Tema | Decisión |
|---|---|---|
| 1 | **El correo en la URL.** | Viaja dentro del token del sistema de filtros (`?f=…`): ofuscado, con versión y suma de verificación, igual que en Cursos y Grupos. La otra pantalla **no** escribe la URL a mano: usa `emailLogsLink(correo)`, que arma el token con el mismo esquema. |
| 2 | **Agregar más filtros a la URL después.** | El esquema declara solo `email`. Sumar tipo, nombre o página es agregar una línea en `fields`; los enlaces que ya existen siguen funcionando, porque agregar claves no cambia las anteriores. |
| 3 | **Filtros que no están en la URL.** Si alguien filtra por nombre y recarga la página, ese filtro se pierde. | Es lo esperado mientras solo el correo viaje en la URL. La pantalla lo deja claro: el botón "Copiar enlace" no existe todavía. |
| 4 | **Escribir en el buscador.** Una petición por tecla satura la API. | Nombre y correo usan `createSearchDraft` (rebote de 350 ms). El tipo es una lista: se aplica al elegir. |
| 5 | **"Empieza por" en el correo.** | El backend busca correos que **empiezan** por lo escrito: aprovecha el índice y un correo completo (el del enlace) coincide exacto. Escribir `@empresa.com` no busca el dominio; para eso, escribir el nombre. |
| 6 | **Personas que no están en el maestro.** Su nombre no se conoce. | Se muestran con el correo y el texto "Sin usuario en DOCCB". El filtro por nombre no las encuentra. |
| 7 | **Fechas en UTC.** La API devuelve `sent_date` en UTC, a veces sin la `Z` final. El navegador la tomaría como hora local y mostraría 5 horas de diferencia. | El mapper le agrega la `Z` cuando falta. |
| 8 | **Datos personales.** La pantalla muestra correos de personas y mensajes de error. | Ruta con `permissionGuard` y permiso propio (`email-logs`); la API también debe exigirlo. |
| 9 | **Errores largos.** | La fila muestra "Ver error"; el mensaje completo se despliega debajo, sin romper la tabla. |

---

## 2. 🎨 Diseño

```text
┌──────────────────────────────────────────────────────────────────────┐
│ AUDITORÍA                                                             │
│ Registro de correos                                                   │
│ Consulta los correos que envió el sistema y si llegaron a salir.      │
├──────────────────────────────────────────────────────────────────────┤
│ Tipo de alerta        Nombre                   Correo                 │
│ [Todos          ▾]    [🔍 Buscar por nombre]   [@ ana.perez@empresa…] │
│                                                       ✕ Limpiar filtros│
├──────────────────────────────────────────────────────────────────────┤
│ 23 correos                                                            │
│ FECHA            TIPO                 DESTINATARIO              ESTADO│
│ 1 oct 2026 10:09 Curso asignado       Ana Pérez                 ✔ Enviado
│                                       ana.perez@empresa.com           │
│ 30 sep 2026 8:15 Recordatorio de…     ana.perez@empresa.com     ✖ Falló│
│                                       Sin usuario en DOCCB  [Ver error ▾]
│   └ SMTP 550: mailbox unavailable                                      │
│                         ‹  Página 1 de 2  ›                            │
└──────────────────────────────────────────────────────────────────────┘
```

- **Encabezado:** el mismo hero de Cursos, con eyebrow dorado.
- **Filtros:** una tarjeta con tres campos en fila (en móvil, uno debajo de otro). "Limpiar filtros" solo aparece si hay alguno.
- **Tabla:** encabezado dorado con texto oscuro, estado en pastilla (verde enviado, rojo falló).
- **Paginación:** `‹ Página 1 de N ›` centrada, como en Grupos.
- **Carga:** esqueletos la primera vez; después, la tabla se atenúa mientras llega la página nueva.

---

## 3. 📁 Archivos

```text
src/app/features/email-logs/
├── domain/
│   ├── email-log.model.ts                  consulta, fila, etiquetas de tipos
│   └── email-logs.repository.ts            contrato (clase abstracta)
├── infraestructure/
│   ├── email-log.dto.ts
│   ├── email-log.mapper.ts                 fecha UTC, estado
│   ├── email-logs.service.ts               HttpClient
│   └── email-logs.providers.ts
├── application/
│   ├── email-logs.facade.ts                ⭐ estado de la pantalla
│   ├── email-log-query.url.ts              ⭐ qué filtros viajan en la URL
│   └── email-logs.link.ts                  ⭐ enlace para otras pantallas
└── presentation/
    └── email-logs-page/
        ├── email-logs-page.component.ts
        ├── email-logs-page.component.html
        └── email-logs-page.component.scss

src/app/app.routes.ts                       (+ ruta /registro-correos)
```

---

## 4. Paso 1 — Domain

### `domain/email-log.model.ts`

```ts
export type EmailSendStatus = 'SENT' | 'FAILED';

/** Consulta de la pantalla. Vacío = sin filtro. */
export interface EmailLogQuery {
  readonly type: string;
  readonly name: string;
  readonly email: string;
  readonly page: number;
  readonly pageSize: number;
}

export const DEFAULT_EMAIL_LOG_QUERY: EmailLogQuery = {
  type: '',
  name: '',
  email: '',
  page: 1,
  pageSize: 20,
};

/** Un correo recibido por una persona. */
export interface EmailLogItem {
  readonly recipientId: number;
  readonly logId: number;
  readonly alertType: string;
  readonly assignmentId: number | null;
  /** ISO 8601 con zona (UTC). */
  readonly sentDate: string;
  readonly status: EmailSendStatus;
  readonly errorMessage: string | null;
  readonly recipientEmail: string;
  /** null = la persona no está en el maestro de usuarios. */
  readonly recipientName: string | null;
}

export interface EmailLogPage {
  readonly items: readonly EmailLogItem[];
  readonly total: number;
}

/** Nombre legible de cada tipo (constantes EmailAlertTypes del backend). Los nuevos se muestran tal cual. */
const ALERT_TYPE_LABELS: Readonly<Record<string, string>> = {
  COURSE_ASSIGNED: 'Curso asignado',
  COURSE_DUE_REMINDER: 'Recordatorio de curso',
  COURSE_OVERDUE: 'Curso vencido',
  REQUEST_SHARED: 'Solicitud compartida',
};

export function alertTypeLabel(type: string): string {
  return ALERT_TYPE_LABELS[type] ?? type;
}
```

### `domain/email-logs.repository.ts`

```ts
import { Observable } from 'rxjs';
import { EmailLogPage, EmailLogQuery } from './email-log.model';

export abstract class EmailLogsRepository {
  abstract list(query: EmailLogQuery): Observable<EmailLogPage>;
  /** Tipos que existen en el log, para el filtro. */
  abstract getTypes(): Observable<string[]>;
}
```

---

## 5. Paso 2 — Infrastructure

### `infraestructure/email-log.dto.ts`

```ts
export interface EmailLogItemDto {
  recipientId: number;
  logId: number;
  alertType: string;
  assignmentId: number | null;
  sentDate: string;
  sendStatus: string;
  errorMessage: string | null;
  recipientEmail: string;
  recipientName: string | null;
}

export interface EmailLogPageDto {
  items: EmailLogItemDto[];
  totalCount: number;
}
```

### `infraestructure/email-log.mapper.ts`

```ts
import { EmailLogItem, EmailLogPage } from '../domain/email-log.model';
import { EmailLogItemDto, EmailLogPageDto } from './email-log.dto';

/** sent_date se guarda en UTC; si la API no manda la zona, se la agrega para que no se lea como hora local. */
function asUtc(value: string): string {
  return /[zZ]|[+-]\d{2}:\d{2}$/.test(value) ? value : `${value}Z`;
}

export function toEmailLogItem(dto: EmailLogItemDto): EmailLogItem {
  return {
    recipientId: dto.recipientId,
    logId: dto.logId,
    alertType: dto.alertType,
    assignmentId: dto.assignmentId,
    sentDate: asUtc(dto.sentDate),
    status: dto.sendStatus === 'SENT' ? 'SENT' : 'FAILED',
    errorMessage: dto.errorMessage?.trim() || null,
    recipientEmail: dto.recipientEmail,
    recipientName: dto.recipientName?.trim() || null,
  };
}

export function toEmailLogPage(dto: EmailLogPageDto): EmailLogPage {
  return { items: dto.items.map(toEmailLogItem), total: dto.totalCount };
}
```

### `infraestructure/email-logs.service.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, unwrap } from '@shared/utils/api-response';
import { EmailLogsRepository } from '../domain/email-logs.repository';
import { EmailLogPage, EmailLogQuery } from '../domain/email-log.model';
import { EmailLogPageDto } from './email-log.dto';
import { toEmailLogPage } from './email-log.mapper';

@Injectable({ providedIn: 'root' })
export class EmailLogsService implements EmailLogsRepository {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/api/email-alert-logs`;

  list(query: EmailLogQuery): Observable<EmailLogPage> {
    let params = new HttpParams().set('page', query.page).set('pageSize', query.pageSize);
    if (query.type) params = params.set('type', query.type);
    if (query.name) params = params.set('name', query.name);
    if (query.email) params = params.set('email', query.email);

    return this.http
      .get<ApiResponse<EmailLogPageDto>>(this.baseUrl, { params })
      .pipe(map(unwrap), map(toEmailLogPage));
  }

  getTypes(): Observable<string[]> {
    return this.http.get<ApiResponse<string[]>>(`${this.baseUrl}/types`).pipe(map(unwrap));
  }
}
```

### `infraestructure/email-logs.providers.ts`

```ts
import { Provider } from '@angular/core';
import { EmailLogsRepository } from '../domain/email-logs.repository';
import { EmailLogsService } from './email-logs.service';

export const EMAIL_LOGS_INFRASTRUCTURE_PROVIDERS: Provider[] = [
  { provide: EmailLogsRepository, useExisting: EmailLogsService },
];
```

---

## 6. Paso 3 — Application

### `application/email-logs.facade.ts`

Cumple lo que pide la sincronización con la URL ([filtros-url-angular.md](filtros-url-angular.md), sección 9): `query` de solo lectura, `setQuery`, cada filtro vuelve a la página 1 y la página se corrige si queda fuera de rango.

```ts
import { Injectable, computed, inject, signal } from '@angular/core';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { catchError, map, of, switchMap, tap } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { EmailLogsRepository } from '../domain/email-logs.repository';
import { DEFAULT_EMAIL_LOG_QUERY, EmailLogItem, EmailLogQuery } from '../domain/email-log.model';

type LoadResult = { ok: true; items: readonly EmailLogItem[]; total: number } | { ok: false; error: string };

@Injectable()
export class EmailLogsFacade {
  private readonly repository = inject(EmailLogsRepository);

  private readonly _query = signal<EmailLogQuery>(DEFAULT_EMAIL_LOG_QUERY);
  private readonly _status = signal<'loading' | 'ready' | 'error'>('loading');
  private readonly _refreshing = signal(false);
  private readonly _items = signal<readonly EmailLogItem[]>([]);
  private readonly _total = signal(0);
  private readonly _error = signal<string | null>(null);
  private readonly _types = signal<readonly string[]>([]);

  readonly query = this._query.asReadonly();
  readonly status = this._status.asReadonly();
  readonly refreshing = this._refreshing.asReadonly();
  readonly items = this._items.asReadonly();
  readonly total = this._total.asReadonly();
  readonly error = this._error.asReadonly();
  readonly types = this._types.asReadonly();

  readonly totalPages = computed(() => Math.max(1, Math.ceil(this._total() / this._query().pageSize)));
  readonly hasFilters = computed(() => {
    const { type, name, email } = this._query();
    return Boolean(type || name || email);
  });

  constructor() {
    // Una petición por cada consulta distinta; la anterior se cancela si llega otra.
    toObservable(this._query)
      .pipe(
        tap(() => this._refreshing.set(true)),
        switchMap((query) =>
          this.repository.list(query).pipe(
            map((page): LoadResult => ({ ok: true, items: page.items, total: page.total })),
            catchError((e) => of<LoadResult>({ ok: false, error: toErrorMessage(e, 'No se pudo consultar el registro de correos.') })),
          ),
        ),
        takeUntilDestroyed(),
      )
      .subscribe((result) => {
        this._refreshing.set(false);

        if (!result.ok) {
          this._error.set(result.error);
          this._status.set('error');
          return;
        }

        this._items.set(result.items);
        this._total.set(result.total);
        this._status.set('ready');

        // Un enlace o "atrás" pudo dejar una página que ya no existe.
        const lastPage = Math.max(1, Math.ceil(result.total / this._query().pageSize));
        if (this._query().page > lastPage) this._query.update((q) => ({ ...q, page: lastPage }));
      });

    this.repository
      .getTypes()
      .pipe(catchError(() => of<string[]>([])), takeUntilDestroyed())
      .subscribe((types) => this._types.set(types));
  }

  /** Lo usa syncQueryWithUrl. */
  setQuery(query: EmailLogQuery): void {
    this._query.set(query);
  }

  setType(type: string): void {
    this._query.update((q) => ({ ...q, type, page: 1 }));
  }

  setName(name: string): void {
    this._query.update((q) => ({ ...q, name, page: 1 }));
  }

  setEmail(email: string): void {
    this._query.update((q) => ({ ...q, email, page: 1 }));
  }

  goToPage(page: number): void {
    this._query.update((q) => ({ ...q, page: Math.min(Math.max(1, page), this.totalPages()) }));
  }

  clearFilters(): void {
    this._query.update((q) => ({ ...DEFAULT_EMAIL_LOG_QUERY, pageSize: q.pageSize }));
  }

  retry(): void {
    this._query.update((q) => ({ ...q })); // objeto nuevo: vuelve a consultar
  }
}
```

### `application/email-log-query.url.ts` ⭐

Aquí se decide **qué filtros viajan en la URL**. Por ahora, solo el correo.

```ts
import { defineUrlQuery } from '@shared/url-query/url-query';
import { urlFields } from '@shared/url-query/url-query-fields';
import { DEFAULT_EMAIL_LOG_QUERY, EmailLogQuery } from '../domain/email-log.model';

export const EMAIL_LOG_QUERY_URL = defineUrlQuery<EmailLogQuery>({
  scope: 'email-logs',
  defaults: DEFAULT_EMAIL_LOG_QUERY,
  fields: {
    email: urlFields.text('e', { max: 320 }),

    // Para que otro filtro viaje en la URL, agrégalo aquí. Los enlaces existentes siguen sirviendo.
    // type: urlFields.text('t', { max: 100 }),
    // name: urlFields.text('n'),
    // page: urlFields.int('p'),
  },
});
```

Lo que no está en `fields` (tipo, nombre, página) se conserva en la consulta, pero no aparece en la URL.

### `application/email-logs.link.ts` ⭐ — para otras pantallas

La otra pantalla no arma el token a mano: importa esta función.

```ts
import { Params } from '@angular/router';
import { EMAIL_LOG_QUERY_URL } from './email-log-query.url';

export const EMAIL_LOGS_PATH = '/registro-correos';

export interface EmailLogsLink {
  readonly commands: readonly string[];
  readonly queryParams: Params;
}

/** Enlace a "Registro de correos" ya filtrado por un correo. */
export function emailLogsLink(email: string): EmailLogsLink {
  const token = EMAIL_LOG_QUERY_URL.toToken({ ...EMAIL_LOG_QUERY_URL.defaults, email: email.trim() });
  return { commands: [EMAIL_LOGS_PATH], queryParams: token ? { f: token } : {} };
}
```

---

## 7. Paso 4 — La página

### `presentation/email-logs-page/email-logs-page.component.ts`

```ts
import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { createSearchDraft } from '@shared/url-query/search-draft';
import { syncQueryWithUrl } from '@shared/url-query/sync-query-with-url';
import { EmailLogsFacade } from '../../application/email-logs.facade';
import { EMAIL_LOG_QUERY_URL } from '../../application/email-log-query.url';
import { alertTypeLabel } from '../../domain/email-log.model';
import { EMAIL_LOGS_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/email-logs.providers';

@Component({
  selector: 'app-email-logs-page',
  imports: [DatePipe],
  providers: [...EMAIL_LOGS_INFRASTRUCTURE_PROVIDERS, EmailLogsFacade],
  templateUrl: './email-logs-page.component.html',
  styleUrl: './email-logs-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class EmailLogsPageComponent {
  protected readonly facade = inject(EmailLogsFacade);
  protected readonly typeLabel = alertTypeLabel;

  /** Lo que el usuario escribe; la consulta se actualiza con rebote. */
  readonly nameDraft = createSearchDraft(
    () => this.facade.query().name,
    (name) => this.facade.setName(name),
  );

  readonly emailDraft = createSearchDraft(
    () => this.facade.query().email,
    (email) => this.facade.setEmail(email),
  );

  /** Fila con el error desplegado. */
  readonly expandedId = signal<number | null>(null);

  constructor() {
    // En el constructor: la primera petición ya sale con el correo del enlace.
    syncQueryWithUrl(this.facade, EMAIL_LOG_QUERY_URL);
  }

  toggleError(recipientId: number): void {
    this.expandedId.update((current) => (current === recipientId ? null : recipientId));
  }
}
```

### `email-logs-page.component.html`

```html
<section class="el">
  <header class="el-hero mb-3">
    <p class="el-hero__eyebrow">Auditoría</p>
    <h1 class="h3 mb-1">Registro de correos</h1>
    <p class="text-body-secondary mb-0">Consulta los correos que envió el sistema y si llegaron a salir.</p>
  </header>

  <!-- ── Filtros ─────────────────────────────────────────────────── -->
  <section class="el-card el-filters" aria-label="Filtros">
    <div class="row g-3 align-items-end">
      <div class="col-12 col-md-4">
        <label class="form-label small fw-semibold" for="el-type">Tipo de alerta</label>
        <select
          id="el-type"
          class="form-select"
          [value]="facade.query().type"
          (change)="facade.setType($any($event.target).value)">
          <option value="">Todos</option>
          @for (type of facade.types(); track type) {
            <option [value]="type">{{ typeLabel(type) }}</option>
          }
        </select>
      </div>

      <div class="col-12 col-md-4">
        <label class="form-label small fw-semibold" for="el-name">Nombre</label>
        <div class="el-input">
          <i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>
          <input
            id="el-name"
            type="search"
            class="form-control"
            placeholder="Nombre del destinatario"
            autocomplete="off"
            [value]="nameDraft()"
            (input)="nameDraft.set($any($event.target).value)" />
        </div>
      </div>

      <div class="col-12 col-md-4">
        <label class="form-label small fw-semibold" for="el-email">Correo</label>
        <div class="el-input">
          <i class="fa-solid fa-at" aria-hidden="true"></i>
          <input
            id="el-email"
            type="search"
            inputmode="email"
            class="form-control"
            placeholder="Empieza por…"
            autocomplete="off"
            [value]="emailDraft()"
            (input)="emailDraft.set($any($event.target).value)" />
        </div>
      </div>
    </div>

    @if (facade.hasFilters()) {
      <div class="text-end mt-2">
        <button type="button" class="btn btn-link btn-sm p-0" (click)="facade.clearFilters()">
          <i class="fa-solid fa-xmark me-1" aria-hidden="true"></i> Limpiar filtros
        </button>
      </div>
    }
  </section>

  <!-- ── Resultados ─────────────────────────────────────────────── -->
  <section class="el-card mt-3" aria-labelledby="el-results">
    <h2 id="el-results" class="el-count" aria-live="polite">
      @if (facade.status() === 'ready') {
        {{ facade.total() }} {{ facade.total() === 1 ? 'correo' : 'correos' }}
      } @else {
        Correos
      }
    </h2>

    @switch (facade.status()) {
      @case ('loading') {
        <div class="el-skeleton" aria-hidden="true">
          @for (i of [0, 1, 2, 3, 4]; track i) { <span></span> }
        </div>
        <span class="visually-hidden" role="status">Cargando…</span>
      }

      @case ('error') {
        <div class="alert alert-danger d-flex justify-content-between align-items-center mb-0" role="alert">
          {{ facade.error() }}
          <button type="button" class="btn btn-sm btn-outline-danger" (click)="facade.retry()">Reintentar</button>
        </div>
      }

      @default {
        @if (!facade.items().length) {
          <div class="el-empty">
            <i class="fa-regular fa-envelope" aria-hidden="true"></i>
            @if (facade.hasFilters()) {
              <p class="fw-semibold mb-1">Ningún correo coincide con los filtros.</p>
              <button type="button" class="btn btn-link btn-sm" (click)="facade.clearFilters()">Limpiar filtros</button>
            } @else {
              <p class="fw-semibold mb-0">Aún no se han enviado correos.</p>
            }
          </div>
        } @else {
          <div class="el-wrap" [class.is-refreshing]="facade.refreshing()" [attr.aria-busy]="facade.refreshing()">
            <table class="el-table">
              <caption class="visually-hidden">Correos enviados</caption>
              <thead>
                <tr>
                  <th scope="col">Fecha</th>
                  <th scope="col">Tipo</th>
                  <th scope="col">Destinatario</th>
                  <th scope="col" class="text-center">Estado</th>
                </tr>
              </thead>
              <tbody>
                @for (item of facade.items(); track item.recipientId; let i = $index) {
                  <tr [style.--i]="i">
                    <td data-label="Fecha" class="text-nowrap">{{ item.sentDate | date: 'd MMM y, h:mm a' }}</td>
                    <td data-label="Tipo">{{ typeLabel(item.alertType) }}</td>
                    <td data-label="Destinatario">
                      @if (item.recipientName) {
                        <strong class="d-block">{{ item.recipientName }}</strong>
                        <small class="text-body-secondary">{{ item.recipientEmail }}</small>
                      } @else {
                        <strong class="d-block">{{ item.recipientEmail }}</strong>
                        <small class="text-body-secondary">Sin usuario en DOCCB</small>
                      }
                    </td>
                    <td data-label="Estado" class="text-center">
                      @if (item.status === 'SENT') {
                        <span class="el-pill" data-tone="ok"><i class="fa-solid fa-check" aria-hidden="true"></i> Enviado</span>
                      } @else {
                        <span class="el-pill" data-tone="fail"><i class="fa-solid fa-xmark" aria-hidden="true"></i> Falló</span>
                        @if (item.errorMessage) {
                          <button
                            type="button"
                            class="btn btn-link btn-sm d-block mx-auto p-0 mt-1"
                            [attr.aria-expanded]="expandedId() === item.recipientId"
                            [attr.aria-controls]="'el-error-' + item.recipientId"
                            (click)="toggleError(item.recipientId)">
                            {{ expandedId() === item.recipientId ? 'Ocultar error' : 'Ver error' }}
                          </button>
                        }
                      }
                    </td>
                  </tr>
                  @if (expandedId() === item.recipientId) {
                    <tr class="el-error-row" [id]="'el-error-' + item.recipientId">
                      <td colspan="4">
                        <i class="fa-solid fa-circle-exclamation me-1" aria-hidden="true"></i>
                        {{ item.errorMessage }}
                      </td>
                    </tr>
                  }
                }
              </tbody>
            </table>
          </div>

          @if (facade.totalPages() > 1) {
            <nav class="el-pager" aria-label="Paginación">
              <button
                type="button"
                class="el-pager__btn"
                aria-label="Página anterior"
                [disabled]="facade.query().page <= 1"
                (click)="facade.goToPage(facade.query().page - 1)">
                <i class="fa-solid fa-chevron-left" aria-hidden="true"></i>
              </button>
              <span class="small">Página {{ facade.query().page }} de {{ facade.totalPages() }}</span>
              <button
                type="button"
                class="el-pager__btn"
                aria-label="Página siguiente"
                [disabled]="facade.query().page >= facade.totalPages()"
                (click)="facade.goToPage(facade.query().page + 1)">
                <i class="fa-solid fa-chevron-right" aria-hidden="true"></i>
              </button>
            </nav>
          }
        }
      }
    }
  </section>
</section>
```

### `email-logs-page.component.scss`

```scss
:host {
  // ══ Tokens — conéctalos a las variables de la app (ver referencia de estilos) ══
  --el-accent: var(--bs-warning);              // dorado de la app
  --el-on-accent: var(--bs-emphasis-color);    // texto oscuro sobre el dorado
  --el-ok: var(--bs-success);
  --el-fail: var(--bs-danger);
  --el-surface: var(--bs-body-bg);
  --el-surface-alt: var(--bs-tertiary-bg);
  --el-border: var(--bs-border-color-translucent);
  --el-text: var(--bs-body-color);
  --el-muted: var(--bs-secondary-color);
  --el-radius: 1rem;
  --el-radius-sm: 0.625rem;
  --el-shadow: 0 1px 2px rgb(0 0 0 / 0.04), 0 4px 16px rgb(0 0 0 / 0.06);
  --el-ease-out: cubic-bezier(0.2, 0.8, 0.2, 1);

  display: block;
  padding: 1.5rem 0;
}

// ── Encabezado: mismo lenguaje que .courses-hero ─────────────────────
.el-hero {
  padding: 1.5rem;
  border: 1px solid var(--el-border);
  border-radius: var(--el-radius);
  background:
    radial-gradient(90% 140% at 0% 0%, color-mix(in srgb, var(--el-accent) 13%, transparent), transparent 55%),
    var(--el-surface);
  box-shadow: var(--el-shadow);
}

.el-hero__eyebrow {
  margin: 0 0 0.25rem;
  color: var(--el-accent);
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.el-card {
  padding: 1.25rem;
  border: 1px solid var(--el-border);
  border-radius: var(--el-radius);
  background: var(--el-surface);
  box-shadow: var(--el-shadow);
}

// ── Filtros ───────────────────────────────────────────────────────────
.el-input {
  position: relative;

  i {
    position: absolute;
    top: 50%;
    left: 0.85rem;
    color: var(--el-muted);
    transform: translateY(-50%);
    pointer-events: none;
  }

  input {
    padding-left: 2.3rem;
  }
}

.el-count {
  margin: 0 0 0.75rem;
  font-size: 1rem;
  font-weight: 700;
}

// ── Tabla ─────────────────────────────────────────────────────────────
.el-wrap {
  overflow-x: auto;
  overflow-y: hidden; // sin esto aparece un scroll vertical con pocas filas
  border: 1px solid var(--el-border);
  border-radius: var(--el-radius-sm);
  transition: opacity 0.2s ease;

  &.is-refreshing {
    opacity: 0.55;
  }
}

.el-table {
  width: 100%;
  font-size: 0.875rem;

  th {
    padding: 0.7rem 0.9rem;
    background: var(--el-accent);
    color: var(--el-on-accent);
    font-size: 0.72rem;
    font-weight: 700;
    letter-spacing: 0.05em;
    text-align: left;
    text-transform: uppercase;

    &.text-center {
      text-align: center;
    }
  }

  td {
    padding: 0.65rem 0.9rem;
    border-top: 1px solid var(--el-border);
    vertical-align: middle;
  }

  tbody tr:not(.el-error-row) {
    animation: el-rise 0.3s var(--el-ease-out) both;
    animation-delay: calc(min(var(--i, 0), 10) * 30ms);
  }
}

.el-error-row td {
  border-top: 0;
  background: color-mix(in srgb, var(--el-fail) 7%, var(--el-surface));
  color: color-mix(in srgb, var(--el-fail) 75%, var(--el-text));
  font-family: var(--bs-font-monospace);
  font-size: 0.8rem;
  white-space: pre-wrap;
  word-break: break-word;
}

.el-pill {
  --tone: var(--el-muted);

  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.15rem 0.6rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 14%, transparent);
  color: color-mix(in srgb, var(--tone) 75%, var(--el-text));
  font-size: 0.75rem;
  font-weight: 600;

  &[data-tone='ok'] { --tone: var(--el-ok); }
  &[data-tone='fail'] { --tone: var(--el-fail); }
}

// ── Paginación: como la de Grupos ─────────────────────────────────────
.el-pager {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  padding: 0.9rem 0 0;
  color: var(--el-muted);
}

.el-pager__btn {
  padding: 0.25rem 0.5rem;
  border: 0;
  border-radius: 999px;
  background: transparent;
  color: var(--el-text);

  &:hover:not(:disabled) {
    background: color-mix(in srgb, var(--el-accent) 14%, transparent);
  }

  &:disabled {
    color: var(--el-border);
  }
}

// ── Vacío y carga ─────────────────────────────────────────────────────
.el-empty {
  display: grid;
  justify-items: center;
  gap: 0.25rem;
  padding: 2.5rem 1rem;
  text-align: center;

  > i {
    margin-bottom: 0.5rem;
    color: var(--el-muted);
    font-size: 2rem;
  }
}

.el-skeleton {
  display: grid;
  gap: 0.5rem;

  span {
    height: 2.75rem;
    border-radius: 0.5rem;
    background: var(--el-surface-alt);
    animation: el-pulse 1.2s ease-in-out infinite alternate;
  }
}

@keyframes el-rise {
  from {
    opacity: 0;
    transform: translateY(6px);
  }
}

@keyframes el-pulse {
  to { opacity: 0.5; }
}

// ── Móvil: cada fila como tarjeta ─────────────────────────────────────
@media (max-width: 767.98px) {
  .el-table thead { display: none; }

  .el-table tr {
    display: block;
    padding: 0.6rem 0.9rem;
    border-top: 1px solid var(--el-border);
  }

  .el-table td {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.2rem 0;
    border: 0;
    text-align: right;

    &::before {
      content: attr(data-label);
      color: var(--el-muted);
      font-size: 0.75rem;
      font-weight: 600;
      text-align: left;
    }
  }

  .el-error-row td::before { content: none; }
}

@media (prefers-reduced-motion: reduce) {
  .el-table tbody tr,
  .el-skeleton span {
    animation: none;
  }
}
```

---

## 8. Paso 5 — Ruta

En `src/app/app.routes.ts`:

```ts
{
  path: 'registro-correos',
  canActivate: [permissionGuard],
  data: { permissionPath: 'email-logs' },
  loadComponent: () =>
    import('@features/email-logs/presentation/email-logs-page/email-logs-page.component')
      .then(m => m.EmailLogsPageComponent),
},
```

Crea el permiso `email-logs` y agrega la entrada al menú de administración. El menú lleva a la pantalla **sin** filtros.

---

## 9. Paso 6 — Abrirla desde otra pantalla con el correo

Ejemplo: en "Grupos asignados" de un curso, un botón por persona para ver los correos que recibió ([cursos-grupos-finalizacion-angular.md](cursos-grupos-finalizacion-angular.md), `assignment-users`).

```ts
// assignment-users.component.ts
import { RouterLink } from '@angular/router';
import { emailLogsLink } from '@features/email-logs/application/email-logs.link';

@Component({
  imports: [DatePipe, RouterLink],
  // …
})
export class AssignmentUsersComponent {
  protected readonly emailLogsLink = emailLogsLink;
  // …
}
```

```html
<!-- En la fila de cada persona -->
@let logs = emailLogsLink(user.email);
<a
  class="btn btn-link btn-sm p-0"
  [routerLink]="logs.commands"
  [queryParams]="logs.queryParams"
  [attr.aria-label]="'Ver correos enviados a ' + user.displayName"
  title="Ver correos enviados">
  <i class="fa-regular fa-envelope" aria-hidden="true"></i>
</a>
```

Desde código, por ejemplo después de una acción:

```ts
const link = emailLogsLink(email);
await this.router.navigate(link.commands, { queryParams: link.queryParams });
```

- La pantalla abre con el correo escrito en el filtro y la tabla ya filtrada: la primera petición sale con él.
- La URL queda como `/registro-correos?f=…`. Ese enlace se puede copiar y compartir.
- Si el usuario borra el correo del filtro, el parámetro desaparece de la URL.
- `@let` existe desde Angular 18.1. Si la plantilla de origen no lo permite, calcula el enlace en el componente.

---

## 10. Pruebas

### Unitarias

```ts
describe('EMAIL_LOG_QUERY_URL', () => {
  it('solo el correo viaja en la URL', () => {
    const token = EMAIL_LOG_QUERY_URL.toToken({ ...DEFAULT_EMAIL_LOG_QUERY, email: 'ana@empresa.com', name: 'Ana', type: 'COURSE_ASSIGNED', page: 3 });
    const back = EMAIL_LOG_QUERY_URL.fromToken(token);

    expect(back.email).toBe('ana@empresa.com');
    expect(back.name).toBe('');
    expect(back.type).toBe('');
    expect(back.page).toBe(1);
  });

  it('sin correo no hay parámetro', () => {
    expect(EMAIL_LOG_QUERY_URL.toToken({ ...DEFAULT_EMAIL_LOG_QUERY, name: 'Ana' })).toBeNull();
  });

  it('un token de otra pantalla no aplica filtros', () => {
    const courses = COURSE_QUERY_URL.toToken({ ...COURSE_QUERY_URL.defaults, search: 'excel' });
    expect(EMAIL_LOG_QUERY_URL.fromToken(courses)).toEqual(DEFAULT_EMAIL_LOG_QUERY);
  });
});

describe('emailLogsLink', () => {
  it('arma la ruta y el token del correo', () => {
    const link = emailLogsLink('  ana@empresa.com ');
    expect(link.commands).toEqual(['/registro-correos']);
    expect(EMAIL_LOG_QUERY_URL.fromToken(link.queryParams['f']).email).toBe('ana@empresa.com');
  });
});

describe('EmailLogsFacade', () => {
  it('cada filtro vuelve a la página 1', () => {
    facade.goToPage(3);
    facade.setType('COURSE_ASSIGNED');
    expect(facade.query().page).toBe(1);
  });

  it('limpiar filtros conserva el tamaño de página', () => {
    facade.setQuery({ ...DEFAULT_EMAIL_LOG_QUERY, email: 'ana@', pageSize: 50 });
    facade.clearFilters();
    expect(facade.query()).toEqual({ ...DEFAULT_EMAIL_LOG_QUERY, pageSize: 50 });
  });
});

describe('toEmailLogItem', () => {
  it('agrega la Z a una fecha sin zona', () => {
    expect(toEmailLogItem({ ...dto, sentDate: '2026-10-01T15:09:01' }).sentDate).toBe('2026-10-01T15:09:01Z');
  });
});
```

### Revisión manual

- Desde "Grupos asignados", clic en el sobre de una persona: abre la pantalla con su correo en el filtro y solo sus correos. La red muestra **una** petición, ya con `email`.
- F5 en esa pantalla: el filtro de correo sigue. Si además se filtró por nombre, ese filtro se pierde (es lo esperado por ahora).
- "Atrás" vuelve a la pantalla anterior, sin pasar por estados intermedios del buscador.
- Escribir un correo letra por letra: una sola petición después de dejar de escribir.
- Un enlace con el token alterado a mano: la pantalla abre sin filtros y la URL se corrige sola.
- Una fila "Falló": "Ver error" despliega el mensaje; en móvil se ve como tarjeta.
- Una persona sin usuario en DOCCB: se ve su correo y el texto "Sin usuario en DOCCB".
- La hora de envío coincide con la hora de Colombia, no con la UTC.
- Sin el permiso `email-logs`: la ruta no abre y la API responde 403.

---

## ✅ Checklist

- [ ] Backend de la sección 11 de [log-envio-correos-api.md](log-envio-correos-api.md) desplegado y protegido con permiso.
- [ ] `EMAIL_LOG_QUERY_URL` con ámbito `email-logs` y solo `email` en `fields`.
- [ ] `syncQueryWithUrl` en el **constructor** de la página.
- [ ] Nombre y correo con `createSearchDraft`; tipo aplicado al elegir.
- [ ] Otras pantallas usan `emailLogsLink(correo)`; nadie arma el token a mano.
- [ ] Mapper con la fecha en UTC.
- [ ] Tokens `--el-*` conectados a las variables de la app; ningún color escrito a mano.
- [ ] Ruta `/registro-correos` con `permissionGuard` y permiso `email-logs`; entrada en el menú sin filtros.
- [ ] Probado con teclado, móvil y `prefers-reduced-motion`.
