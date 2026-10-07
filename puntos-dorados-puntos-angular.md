# 💰 Puntos Dorados — Pantallas de puntos (Angular)

Dos pantallas nuevas, conectadas a la API de [puntos-dorados-puntos-api.md](puntos-dorados-puntos-api.md):

| Dónde | Pestaña | Qué hace |
|---|---|---|
| `PuntosDoradosAdminComponent` | **Puntos** (nueva) | Asignar puntos a una persona **sin reconocimiento**, con confirmación. Ver su saldo y todos los movimientos, y reversar una asignación hecha por error. |
| `PuntosDoradosUserComponent` | **Mis puntos** (nueva, al lado de "Mis reconocimientos") | Saldo, puntos por vencer e historial: asignaciones directas y reconocimientos con puntos. |

**El feed no cambia:** una asignación de puntos no es un reconocimiento y nunca aparece ahí.

Sigue el patrón con el que quedó implementado reconocimientos ([puntos-dorados-cambios-frontend.md](puntos-dorados-cambios-frontend.md)):

| Capa | Cómo |
|---|---|
| **Servicio** | `AuthService` + `await this.authHeaders()` en cada método (`async`, devuelven `Promise<Observable<GoldenResult<T>>>`) y `catchError` con `HttpErrorHandlerService`. |
| **Facade** | Cada método pasa por `runRecognitionRequest` y devuelve `Promise<GoldenResult<T>>`. Nunca lanza. |
| **Componentes** | Revisan `result.hasError`; los errores van a un signal junto al formulario, sin cerrarlo. Las listas usan `PagedList`. |

---

## 1. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Los dos componentes ya son muy grandes** (el de administración pasa de 1.000 líneas). | Cada pestaña nueva es un **componente hijo** (`app-golden-points-admin` y `app-my-points`) con su propio estado. Los componentes padres solo agregan la pestaña y lo pintan. |
| 2 | **Carga.** | El hijo se crea cuando se abre su pestaña y carga sus datos en ese momento, solo en el navegador. Al volver a la pestaña se recarga: con dinero conviene ver siempre el saldo actual. |
| 3 | **Asignar es como transferir dinero.** | Dos pasos: **Revisar** muestra "¿Asignar 200 puntos a Laura? Saldo 150 → 350" y **Confirmar** asigna. |
| 4 | **Doble clic o red lenta.** | Cada solicitud lleva un `requestId`. Se reutiliza si se reintenta **con los mismos datos**, y cambia apenas cambia cualquier campo. La API no abona dos veces el mismo `requestId`. |
| 5 | **Errores del administrador.** | No se editan: se **reversan**, con motivo, desde la tabla de movimientos. Solo aparece "Reversar" cuando la API dice `canReverse`. |
| 6 | **Fechas sin hora** (`expiresAt`, `nextExpirationDate`). | Se convierten a fecha local (`new Date(año, mes, día)`), **no** como UTC. Si no, en Colombia un "7 de abril" se vería como "6 de abril". |
| 7 | **Signos.** | `+200` en verde, `−100` en rojo, y "Reversado" en los movimientos corregidos. |

---

## 2. Archivos

```text
src/app/features/puntos-dorados/
├── domain/puntos-dorados.ts                         ✏️ tipos de puntos
├── infraestructure/
│   ├── golden-api.ts                                nuevo — helpers comunes de la API (movidos desde golden-recognitions.mapper.ts)
│   ├── golden-recognitions.mapper.ts                ✏️ importa los helpers de golden-api.ts
│   ├── golden-points.mapper.ts                      nuevo
│   └── golden-points.service.ts                     nuevo
├── application/
│   ├── golden-request-id.ts                         nuevo — GUID para la idempotencia
│   ├── golden-validators.ts                         nuevo — largo de texto sin contar espacios
│   └── puntos-dorados.fecade.ts                     ✏️ + 6 métodos con runRecognitionRequest
└── presentation/
    ├── admin/points-admin/                          nuevo ⭐ pestaña "Puntos"
    │   ├── points-admin.component.ts
    │   ├── points-admin.component.html
    │   └── points-admin.component.scss
    ├── admin/puntos-dorados-admin.component.*       ✏️ pestaña nueva
    ├── user/my-points/                              nuevo ⭐ pestaña "Mis puntos"
    │   ├── my-points.component.ts
    │   ├── my-points.component.html
    │   └── my-points.component.scss
    └── user/puntos-dorados-user.component.*         ✏️ pestaña nueva
```

---

## 3. Paso 1 — Dominio (`domain/puntos-dorados.ts`) ✏️

`GoldenPointsTransaction` y `GoldenPointsBucket` ya existen. Solo se agregan campos **opcionales**, así que nada de lo que ya los usa se rompe.

```ts
// ── En GoldenPointsTransaction, agrega (opcionales) ──────────────────
//   source?: GoldenPointsSource;
//   sourceLabel?: string;            // "Asignación de puntos", "Reconocimiento · Servicio"…
//   balanceAfter?: number;           // saldo después del movimiento
//   recognitionId?: number | null;
//   expiresAt?: Date | null;         // solo abonos
//   remainingPoints?: number | null; // solo abonos
//   isReversed?: boolean;
//   canReverse?: boolean;            // solo administración
//   userName?: string | null;        // solo administración
//   createdBy?: string | null;       // solo administración

export type GoldenPointsSource = 'Asignacion' | 'Reconocimiento' | 'Redencion' | 'Vencimiento';

/** Encabezado de "Mis puntos" y saldo de una persona en administración. */
export interface GoldenPointsSummary {
  userEmail: string;
  userName: string;
  balance: number;
  totalEarned: number;
  totalSpent: number;
  totalExpired: number;
  expiringSoonPoints: number;
  expiringSoonDays: number;
  nextExpirationDate: Date | null;
  upcomingExpirations: GoldenPointsBucket[];
}

export interface GoldenPointsQuery {
  page: number;
  pageSize: number;
  type?: GoldenPointsTransactionType | null;
  source?: GoldenPointsSource | null;
  /** Solo administración. */
  email?: string | null;
}

export interface AssignGoldenPoints {
  userEmail: string;
  points: number;
  concept: string;
  /** yyyy-MM-dd. null = vence en 6 meses (lo decide la API). */
  expiresDate: string | null;
  requestId: string;
}

/** Valores que también valida la API. */
export const GOLDEN_POINTS_LIMITS = {
  maxPointsPerAssignment: 100_000,
  conceptMin: 5,
  conceptMax: 300,
  reasonMin: 5,
  reasonMax: 200,
  defaultExpirationMonths: 6,
  maxExpirationMonths: 24,
} as const;
```

---

## 4. Paso 2 — Infraestructura

### `infraestructure/golden-api.ts` (nuevo)

Lo genérico de la API ya no es solo de reconocimientos. **Mueve** a este archivo, sin cambios, `GoldenResultDto`, `GoldenPagedResultDto`, `toResult`, `toPage`, `parseUtc` y `toErrorMessage` desde donde estén hoy (en la guía estaban en `golden-recognitions.mapper.ts`), y agrega `parseDateOnly` y `toIsoDate`:

```ts
/** "2027-04-07" → 7 de abril a las 00:00 en hora local. Las fechas sin hora NO se tratan como UTC. */
export function parseDateOnly(value: string): Date {
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  return new Date(year, month - 1, day);
}

/** Date → "yyyy-MM-dd" en hora local (para <input type="date">). */
export function toIsoDate(date: Date): string {
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day}`;
}
```

En los archivos de reconocimientos (mapper, servicio y facade), cambia esos imports a `'./golden-api'` o `'../infraestructure/golden-api'`. Si prefieres no mover nada todavía, importa esos helpers desde donde están y crea `golden-api.ts` solo con `parseDateOnly` y `toIsoDate`.

### `infraestructure/golden-points.mapper.ts`

```ts
import {
  GoldenPointsBucket,
  GoldenPointsSource,
  GoldenPointsSummary,
  GoldenPointsTransaction,
  GoldenPointsTransactionType,
} from '../domain/puntos-dorados';
import { parseDateOnly, parseUtc } from './golden-api';

export interface GoldenPointsTransactionDto {
  id: number;
  userEmail: string;
  userName: string | null;
  type: string;
  source: string;
  sourceLabel: string;
  concept: string;
  points: number;
  balanceAfter: number;
  recognitionId: number | null;
  expiresAt: string | null;
  remainingPoints: number | null;
  isReversed: boolean;
  canReverse: boolean;
  createdAt: string;
  createdBy: string | null;
}

export interface GoldenPointsBucketDto {
  id: number;
  userEmail: string;
  source: string;
  originalPoints: number;
  remainingPoints: number;
  assignedAt: string;
  expiresAt: string;
}

export interface GoldenPointsSummaryDto {
  userEmail: string;
  userName: string;
  balance: number;
  totalEarned: number;
  totalSpent: number;
  totalExpired: number;
  expiringSoonPoints: number;
  expiringSoonDays: number;
  nextExpirationDate: string | null;
  upcomingExpirations: GoldenPointsBucketDto[];
}

const TYPES: readonly GoldenPointsTransactionType[] = ['Credito', 'Debito', 'Ajuste', 'Vencimiento'];
const SOURCES: readonly GoldenPointsSource[] = ['Asignacion', 'Reconocimiento', 'Redencion', 'Vencimiento'];

function toType(value: string): GoldenPointsTransactionType {
  return (TYPES as readonly string[]).includes(value) ? (value as GoldenPointsTransactionType) : 'Ajuste';
}

function toSource(value: string): GoldenPointsSource {
  return (SOURCES as readonly string[]).includes(value) ? (value as GoldenPointsSource) : 'Asignacion';
}

export function toPointsTransaction(dto: GoldenPointsTransactionDto): GoldenPointsTransaction {
  return {
    id: dto.id,
    userEmail: dto.userEmail,
    type: toType(dto.type),
    points: dto.points,
    concept: dto.concept,
    createdAt: parseUtc(dto.createdAt),
    source: toSource(dto.source),
    sourceLabel: dto.sourceLabel,
    balanceAfter: dto.balanceAfter,
    recognitionId: dto.recognitionId,
    expiresAt: dto.expiresAt ? parseDateOnly(dto.expiresAt) : null,
    remainingPoints: dto.remainingPoints,
    isReversed: dto.isReversed,
    canReverse: dto.canReverse,
    userName: dto.userName,
    createdBy: dto.createdBy,
  };
}

export function toPointsBucket(dto: GoldenPointsBucketDto): GoldenPointsBucket {
  return {
    id: dto.id,
    userEmail: dto.userEmail,
    source: dto.source,
    originalPoints: dto.originalPoints,
    remainingPoints: dto.remainingPoints,
    assignedAt: parseUtc(dto.assignedAt),
    expiresAt: parseDateOnly(dto.expiresAt),
  };
}

export function toPointsSummary(dto: GoldenPointsSummaryDto): GoldenPointsSummary {
  return {
    ...dto,
    nextExpirationDate: dto.nextExpirationDate ? parseDateOnly(dto.nextExpirationDate) : null,
    upcomingExpirations: (dto.upcomingExpirations ?? []).map(toPointsBucket),
  };
}
```

### `infraestructure/golden-points.service.ts`

Mismo patrón que `golden-recognitions.service.ts`: token en cada llamada y errores HTTP al `HttpErrorHandlerService`.

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Observable, catchError, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';          // ⬅ mismos imports que golden-recognitions.service.ts
import { AuthService } from '@core/services/auth-msal.service';             // ⬅ ruta real del AuthService
import { HttpErrorHandlerService } from '@core/services/http-error-handler.service'; // ⬅ ruta real
import {
  AssignGoldenPoints,
  GoldenPagedResult,
  GoldenPointsQuery,
  GoldenPointsSummary,
  GoldenPointsTransaction,
  GoldenResult,
} from '../domain/puntos-dorados';
import { GoldenPagedResultDto, GoldenResultDto, toPage, toResult } from './golden-api';
import {
  GoldenPointsSummaryDto,
  GoldenPointsTransactionDto,
  toPointsSummary,
  toPointsTransaction,
} from './golden-points.mapper';

@Injectable({ providedIn: 'root' })
export class GoldenPointsService {
  private readonly http = inject(HttpClient);
  private readonly authService = inject(AuthService);
  private readonly httpErrorHandler = inject(HttpErrorHandlerService);
  private readonly baseUrl = `${environment.api.baseUrl}/api/GoldenPoints`;

  // ── Colaborador (el usuario sale del token) ────────────────────────

  async getMySummary(): Promise<Observable<GoldenResult<GoldenPointsSummary>>> {
    const headers = await this.authHeaders();

    return this.http
      .get<GoldenResultDto<GoldenPointsSummaryDto>>(`${this.baseUrl}/me/summary`, { headers })
      .pipe(
        map(dto => toResult(dto, toPointsSummary)),
        catchError(error => this.handleError(error)),
      );
  }

  async getMyTransactions(query: GoldenPointsQuery): Promise<Observable<GoldenResult<GoldenPagedResult<GoldenPointsTransaction>>>> {
    const headers = await this.authHeaders();

    return this.http
      .get<GoldenResultDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>>(`${this.baseUrl}/me/transactions`, {
        headers,
        params: this.params(query),
      })
      .pipe(
        map(dto => toResult(dto, page => toPage(page, toPointsTransaction))),
        catchError(error => this.handleError(error)),
      );
  }

  // ── Administración ─────────────────────────────────────────────────

  async getUserSummary(email: string): Promise<Observable<GoldenResult<GoldenPointsSummary>>> {
    const headers = await this.authHeaders();

    return this.http
      .get<GoldenResultDto<GoldenPointsSummaryDto>>(`${this.baseUrl}/summary`, {
        headers,
        params: new HttpParams().set('email', email),
      })
      .pipe(
        map(dto => toResult(dto, toPointsSummary)),
        catchError(error => this.handleError(error)),
      );
  }

  async getTransactions(query: GoldenPointsQuery): Promise<Observable<GoldenResult<GoldenPagedResult<GoldenPointsTransaction>>>> {
    const headers = await this.authHeaders();

    return this.http
      .get<GoldenResultDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>>(`${this.baseUrl}/transactions`, {
        headers,
        params: this.params(query),
      })
      .pipe(
        map(dto => toResult(dto, page => toPage(page, toPointsTransaction))),
        catchError(error => this.handleError(error)),
      );
  }

  async assign(request: AssignGoldenPoints): Promise<Observable<GoldenResult<GoldenPointsTransaction>>> {
    const headers = await this.authHeaders();

    return this.http
      .post<GoldenResultDto<GoldenPointsTransactionDto>>(`${this.baseUrl}/assignments`, request, { headers })
      .pipe(
        map(dto => toResult(dto, toPointsTransaction)),
        catchError(error => this.handleError(error)),
      );
  }

  async reverse(transactionId: number, reason: string): Promise<Observable<GoldenResult<GoldenPointsTransaction>>> {
    const headers = await this.authHeaders();

    return this.http
      .post<GoldenResultDto<GoldenPointsTransactionDto>>(`${this.baseUrl}/transactions/${transactionId}/reverse`, { reason }, { headers })
      .pipe(
        map(dto => toResult(dto, toPointsTransaction)),
        catchError(error => this.handleError(error)),
      );
  }

  // ── Privados ───────────────────────────────────────────────────────

  /**
   * ⬇ Copia el MISMO cuerpo de authHeaders() de golden-recognitions.service.ts
   * (pide el token con AuthService en cada llamada y arma Authorization: Bearer …).
   */
  private async authHeaders(): Promise<HttpHeaders> {
    // …
  }

  /**
   * ⬇ El MISMO llamado a HttpErrorHandlerService que usa golden-recognitions.service.ts.
   * Debe relanzar el error (throwError) para que el facade lo convierta en { hasError: true }.
   */
  private handleError(error: unknown): Observable<never> {
    // …
  }

  private params(query: GoldenPointsQuery): HttpParams {
    let params = new HttpParams().set('page', query.page).set('pageSize', query.pageSize);

    if (query.type) {
      params = params.set('type', query.type);
    }

    if (query.source) {
      params = params.set('source', query.source);
    }

    if (query.email) {
      params = params.set('email', query.email);
    }

    return params;
  }
}
```

> **Rutas de `AuthService` y `HttpErrorHandlerService`:** las de arriba son de ejemplo. Copia los `import` exactos de `golden-recognitions.service.ts`.
>
> **`authHeaders()` repetido:** ya está en dos servicios (reconocimientos y puntos), y la redención será el tercero. Cuando eso pase, conviene moverlo a un servicio compartido (por ejemplo `GoldenApiAuthService` con `headers()`) e inyectarlo en los tres.

---

## 5. Paso 3 — Aplicación

### `application/golden-request-id.ts`

```ts
/**
 * GUID para que la API no procese dos veces la misma solicitud.
 * crypto.randomUUID solo existe en HTTPS o localhost; si la app se abre por http en la intranet,
 * se arma con crypto.getRandomValues, que funciona en cualquier contexto.
 */
export function newRequestId(): string {
  const cryptoApi = globalThis.crypto;

  if (typeof cryptoApi?.randomUUID === 'function') {
    return cryptoApi.randomUUID();
  }

  const bytes = cryptoApi.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // versión 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variante

  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
```

### `application/golden-validators.ts`

`Validators.minLength` cuenta los espacios y la API no. Este validador cuenta como la API.

```ts
import { AbstractControl, ValidationErrors, ValidatorFn } from '@angular/forms';

/** Largo del texto sin espacios al inicio ni al final. */
export function trimmedLength(min: number, max: number): ValidatorFn {
  return (control: AbstractControl): ValidationErrors | null => {
    const length = String(control.value ?? '').trim().length;
    return length >= min && length <= max ? null : { trimmedLength: { min, max, actual: length } };
  };
}
```

> Sirve también para el motivo del reconocimiento (`trimmedLength(15, 1000)` en lugar de `Validators.minLength(15)`).

### `application/puntos-dorados.fecade.ts` ✏️ — métodos nuevos

Pasan por el mismo wrapper que reconocimientos (`runRecognitionRequest`): ningún error sale del facade.

```ts
import { GoldenPointsService } from '../infraestructure/golden-points.service';
import {
  AssignGoldenPoints,
  GoldenPointsQuery,
  GoldenPointsSummary,
  GoldenPointsTransaction,
} from '../domain/puntos-dorados';

// Dentro de la clase:
private readonly points = inject(GoldenPointsService);

// ── Puntos (API) ─────────────────────────────────────────────────────

getMyPointsSummary(): Promise<GoldenResult<GoldenPointsSummary>> {
  return this.runRecognitionRequest(() => this.points.getMySummary(), 'No se pudo cargar tu saldo de puntos.');
}

getMyPointsHistory(query: GoldenPointsQuery): Promise<GoldenResult<GoldenPagedResult<GoldenPointsTransaction>>> {
  return this.runRecognitionRequest(() => this.points.getMyTransactions(query), 'No se pudo cargar tu historial de puntos.');
}

getUserPointsSummary(email: string): Promise<GoldenResult<GoldenPointsSummary>> {
  return this.runRecognitionRequest(() => this.points.getUserSummary(email), 'No se pudo consultar el saldo de la persona.');
}

getPointsHistory(query: GoldenPointsQuery): Promise<GoldenResult<GoldenPagedResult<GoldenPointsTransaction>>> {
  return this.runRecognitionRequest(() => this.points.getTransactions(query), 'No se pudieron cargar los movimientos de puntos.');
}

assignPoints(request: AssignGoldenPoints): Promise<GoldenResult<GoldenPointsTransaction>> {
  return this.runRecognitionRequest(
    () => this.points.assign(request),
    'No se pudo asignar los puntos. Intenta de nuevo: no se abonarán dos veces.',
  );
}

reversePointsAssignment(transactionId: number, reason: string): Promise<GoldenResult<GoldenPointsTransaction>> {
  return this.runRecognitionRequest(() => this.points.reverse(transactionId, reason), 'No se pudo reversar la asignación.');
}
```

> **Firma del wrapper.** Aquí se le pasa una función (`() => this.points.getMySummary()`), que es la forma segura: si `authHeaders()` falla al pedir el token, el error ocurre **dentro** del `try` del wrapper. Si en tu código `runRecognitionRequest` recibe la promesa directamente (`this.runRecognitionRequest(this.points.getMySummary(), …)`), usa esa forma en los seis métodos.
>
> **Nombre.** Con puntos, el wrapper deja de ser solo de reconocimientos. Renombrarlo a `runApiRequest` es opcional y no cambia nada más.
>
> **Sin signals nuevos en el facade.** El estado de puntos vive en los componentes (`PagedList` y el resumen). Así no hay dos copias del mismo dato.

---

## 6. Paso 4 — Administración: pestaña "Puntos"

### Diseño

```text
┌ Asignar puntos ─────────────────────────────┐ ┌ Saldo de la persona ────────────┐
│ Persona            [Laura Salazar        ▾] │ │ Laura Salazar                    │
│ Puntos             [ 200 ]                  │ │ 150 puntos disponibles           │
│ Concepto           [Bono por cierre…      ] │ │ Ganados 150 · Por vencer 0       │
│ Vencen el          [          ] (vacío =    │ │ Próximo vencimiento: 1 abr 2027  │
│                     7 de abril de 2027)     │ └─────────────────────────────────┘
│                        [Limpiar] [Revisar]  │  ✔ Se asignaron 200 puntos a Laura.
└─────────────────────────────────────────────┘    Saldo nuevo: 350.
  ┌ ¿Asignar 200 puntos a Laura Salazar? ─────┐
  │ Saldo 150 → 350 · Vencen el 7 abr 2027    │
  │                 [Volver] [Confirmar]      │
  └───────────────────────────────────────────┘
┌ Movimientos ──── ( Todos | Asignaciones | Reconocimientos )  ☐ Solo esta persona ┐
│ FECHA        PERSONA          ORIGEN            CONCEPTO        PUNTOS  SALDO  POR │
│ 07/10/2026   Laura Salazar    Asignación        Bono por…       +200    350  admin│ [Reversar]
│ 01/10/2026   Laura Salazar    Reconocimiento ·… Reconocimiento… +150    150  …    │
│                              ‹ Cargar más ›                                       │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### `presentation/admin/points-admin/points-admin.component.ts`

```ts
import { ChangeDetectionStrategy, Component, PLATFORM_ID, computed, inject, input, signal } from '@angular/core';
import { DatePipe, DecimalPipe, isPlatformBrowser } from '@angular/common';
import { NonNullableFormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { takeUntilDestroyed, toObservable, toSignal } from '@angular/core/rxjs-interop';
import { distinctUntilChanged, from, map, of, switchMap } from 'rxjs';
import { PuntosDoradosFacade } from '../../../application/puntos-dorados.fecade';
import { PagedList } from '../../../application/paged-list';
import { newRequestId } from '../../../application/golden-request-id';
import { trimmedLength } from '../../../application/golden-validators';
import { toIsoDate } from '../../../infraestructure/golden-api';
import {
  GOLDEN_POINTS_LIMITS,
  GoldenPerson,
  GoldenPointsSource,
  GoldenPointsSummary,
  GoldenPointsTransaction,
} from '../../../domain/puntos-dorados';

@Component({
  selector: 'app-golden-points-admin',
  standalone: true,
  imports: [ReactiveFormsModule, DatePipe, DecimalPipe],
  templateUrl: './points-admin.component.html',
  styleUrl: './points-admin.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class GoldenPointsAdminComponent {
  private readonly facade = inject(PuntosDoradosFacade);
  private readonly fb = inject(NonNullableFormBuilder);
  private readonly isBrowser = isPlatformBrowser(inject(PLATFORM_ID));

  /** Las personas que ya carga el componente de administración. */
  readonly people = input<readonly GoldenPerson[]>([]);

  readonly limits = GOLDEN_POINTS_LIMITS;

  readonly form = this.fb.group({
    userEmail: ['', Validators.required],
    points: this.fb.control<number | null>(null, [
      Validators.required,
      Validators.min(1),
      Validators.max(GOLDEN_POINTS_LIMITS.maxPointsPerAssignment),
    ]),
    concept: ['', trimmedLength(GOLDEN_POINTS_LIMITS.conceptMin, GOLDEN_POINTS_LIMITS.conceptMax)],
    expiresDate: [''],
  });

  // ── Fechas del selector de vencimiento ─────────────────────────────
  private readonly today = new Date();
  readonly minExpiration = toIsoDate(new Date(this.today.getFullYear(), this.today.getMonth(), this.today.getDate() + 1));
  readonly maxExpiration = toIsoDate(new Date(this.today.getFullYear(), this.today.getMonth() + GOLDEN_POINTS_LIMITS.maxExpirationMonths, this.today.getDate()));
  readonly defaultExpiration = new Date(this.today.getFullYear(), this.today.getMonth() + GOLDEN_POINTS_LIMITS.defaultExpirationMonths, this.today.getDate());

  // ── Asignación ─────────────────────────────────────────────────────
  readonly step = signal<'form' | 'confirm'>('form');
  readonly saving = signal(false);
  readonly formErrors = signal<string[]>([]);
  readonly lastAssignment = signal<GoldenPointsTransaction | null>(null);

  /** Un requestId por solicitud: se conserva al reintentar con los mismos datos y cambia si cambia cualquier campo. */
  private requestId = newRequestId();

  private readonly formValue = toSignal(this.form.valueChanges, { initialValue: this.form.getRawValue() });
  readonly selectedEmail = computed(() => this.formValue().userEmail ?? '');
  readonly selectedPerson = computed(() => this.people().find(person => person.email === this.selectedEmail()) ?? null);

  // ── Saldo de la persona elegida ────────────────────────────────────
  readonly summary = signal<GoldenPointsSummary | null>(null);
  readonly summaryLoading = signal(false);
  readonly summaryError = signal<string | null>(null);

  /** Lo que se muestra en la confirmación: saldo actual → saldo nuevo. */
  readonly projectedBalance = computed(() => (this.summary()?.balance ?? 0) + Number(this.formValue().points ?? 0));

  // ── Movimientos ────────────────────────────────────────────────────
  readonly sourceFilters: readonly { value: GoldenPointsSource | null; label: string }[] = [
    { value: null, label: 'Todos' },
    { value: 'Asignacion', label: 'Asignaciones' },
    { value: 'Reconocimiento', label: 'Reconocimientos' },
  ];

  readonly sourceFilter = signal<GoldenPointsSource | null>(null);
  readonly onlySelectedPerson = signal(false);

  readonly history = new PagedList<GoldenPointsTransaction>(
    (page, pageSize) =>
      this.facade.getPointsHistory({
        page,
        pageSize,
        source: this.sourceFilter(),
        email: this.onlySelectedPerson() ? this.selectedEmail() || null : null,
      }),
    item => item.id,
    15,
  );

  // ── Reverso ────────────────────────────────────────────────────────
  readonly reversingId = signal<number | null>(null);
  readonly reverseReason = signal('');
  readonly reverseErrors = signal<string[]>([]);
  readonly reverseSaving = signal(false);

  constructor() {
    // Cualquier cambio en el formulario es otra solicitud: requestId nuevo y vuelve al paso de edición.
    this.form.valueChanges.pipe(takeUntilDestroyed()).subscribe(() => {
      this.requestId = newRequestId();
      this.step.set('form');
    });

    // Al elegir una persona, se consulta su saldo.
    toObservable(this.selectedEmail)
      .pipe(
        distinctUntilChanged(),
        switchMap(email => {
          this.summary.set(null);
          this.summaryError.set(null);
          if (!email || !this.isBrowser) {
            return of(null);
          }

          this.summaryLoading.set(true);
          return from(this.facade.getUserPointsSummary(email));
        }),
        takeUntilDestroyed(),
      )
      .subscribe(result => {
        this.summaryLoading.set(false);
        if (!result) {
          return;
        }

        if (result.hasError) {
          this.summaryError.set(result.errors.join(' '));
          return;
        }

        this.summary.set(result.response);
      });

    if (this.isBrowser) {
      void this.history.reload();
    }
  }

  hasError(controlName: keyof typeof this.form.controls): boolean {
    const control = this.form.controls[controlName];
    return control.invalid && (control.touched || control.dirty);
  }

  review(): void {
    this.form.markAllAsTouched();
    if (this.form.invalid) {
      return;
    }

    this.formErrors.set([]);
    this.lastAssignment.set(null);
    this.step.set('confirm');
  }

  backToForm(): void {
    this.step.set('form');
  }

  async confirmAssign(): Promise<void> {
    if (this.saving()) {
      return;
    }

    const { userEmail, points, concept, expiresDate } = this.form.getRawValue();
    this.saving.set(true);

    try {
      const result = await this.facade.assignPoints({
        userEmail,
        points: Number(points),
        concept: concept.trim(),
        expiresDate: expiresDate || null,
        requestId: this.requestId, // si se reintenta sin cambiar nada, es el mismo: la API no abona dos veces
      });

      if (result.hasError) {
        this.formErrors.set(result.errors);
        this.step.set('form');
        return;
      }

      this.lastAssignment.set(result.response);

      // Se conserva la persona para ver su saldo actualizado; se limpia lo demás (y eso genera un requestId nuevo).
      this.form.reset({ userEmail, points: null, concept: '', expiresDate: '' });
      this.form.markAsUntouched();

      await Promise.all([this.refreshSummary(), this.history.reload()]);
    } finally {
      this.saving.set(false);
    }
  }

  clear(): void {
    this.form.reset({ userEmail: '', points: null, concept: '', expiresDate: '' });
    this.formErrors.set([]);
    this.lastAssignment.set(null);
  }

  setSourceFilter(value: GoldenPointsSource | null): void {
    if (this.sourceFilter() === value) {
      return;
    }

    this.sourceFilter.set(value);
    void this.history.reload();
  }

  toggleOnlySelectedPerson(checked: boolean): void {
    this.onlySelectedPerson.set(checked);
    void this.history.reload();
  }

  startReverse(item: GoldenPointsTransaction): void {
    this.reversingId.set(item.id);
    this.reverseReason.set('');
    this.reverseErrors.set([]);
  }

  cancelReverse(): void {
    this.reversingId.set(null);
  }

  async confirmReverse(item: GoldenPointsTransaction): Promise<void> {
    const reason = this.reverseReason().trim();
    if (reason.length < GOLDEN_POINTS_LIMITS.reasonMin || reason.length > GOLDEN_POINTS_LIMITS.reasonMax) {
      this.reverseErrors.set([`Escribe el motivo (entre ${GOLDEN_POINTS_LIMITS.reasonMin} y ${GOLDEN_POINTS_LIMITS.reasonMax} caracteres).`]);
      return;
    }

    if (this.reverseSaving()) {
      return;
    }

    this.reverseSaving.set(true);

    try {
      const result = await this.facade.reversePointsAssignment(item.id, reason);
      if (result.hasError) {
        this.reverseErrors.set(result.errors);
        return;
      }

      this.reversingId.set(null);
      const tasks = [this.history.reload()];
      if (item.userEmail === this.selectedEmail()) {
        tasks.push(this.refreshSummary());
      }

      await Promise.all(tasks);
    } finally {
      this.reverseSaving.set(false);
    }
  }

  private async refreshSummary(): Promise<void> {
    const email = this.selectedEmail();
    if (!email) {
      return;
    }

    const result = await this.facade.getUserPointsSummary(email);
    if (!result.hasError) {
      this.summary.set(result.response);
    }
  }
}
```

### `points-admin.component.html`

```html
<div class="pa">
  <div class="pa-grid">
    <!-- ── Asignar ──────────────────────────────────────────────────── -->
    <section class="pa-card" aria-labelledby="pa-assign-title">
      <h2 id="pa-assign-title" class="pa-card__title">
        <i class="fa-solid fa-coins" aria-hidden="true"></i> Asignar puntos
      </h2>
      <p class="pa-card__hint">Puntos sin reconocimiento. No aparecen en el feed; la persona los ve en "Mis puntos".</p>

      <form [formGroup]="form" (ngSubmit)="review()" novalidate>
        <fieldset [disabled]="step() === 'confirm' || saving()">
          <div class="mb-3">
            <label class="form-label" for="pa-person">Persona</label>
            <select id="pa-person" class="form-select" formControlName="userEmail" [class.is-invalid]="hasError('userEmail')">
              <option value="">Selecciona una persona</option>
              @for (person of people(); track person.email) {
                <option [value]="person.email">{{ person.name }} — {{ person.email }}</option>
              }
            </select>
            @if (hasError('userEmail')) {
              <div class="invalid-feedback">Selecciona a la persona.</div>
            }
          </div>

          <div class="row g-3 mb-3">
            <div class="col-12 col-sm-5">
              <label class="form-label" for="pa-points">Puntos</label>
              <input
                id="pa-points"
                type="number"
                inputmode="numeric"
                min="1"
                [max]="limits.maxPointsPerAssignment"
                step="1"
                class="form-control"
                formControlName="points"
                [class.is-invalid]="hasError('points')" />
              @if (hasError('points')) {
                <div class="invalid-feedback">Entre 1 y {{ limits.maxPointsPerAssignment | number }}.</div>
              }
            </div>

            <div class="col-12 col-sm-7">
              <label class="form-label" for="pa-expires">Vencen el <span class="text-body-secondary">(opcional)</span></label>
              <input
                id="pa-expires"
                type="date"
                class="form-control"
                formControlName="expiresDate"
                [min]="minExpiration"
                [max]="maxExpiration" />
              <div class="form-text">Si lo dejas vacío, vencen el {{ defaultExpiration | date: "d 'de' MMMM 'de' y" }}.</div>
            </div>
          </div>

          <div class="mb-3">
            <label class="form-label" for="pa-concept">Concepto</label>
            <textarea
              id="pa-concept"
              rows="2"
              class="form-control"
              formControlName="concept"
              [maxLength]="limits.conceptMax"
              placeholder="Ej.: Bono por cierre del proyecto de temporada"
              [class.is-invalid]="hasError('concept')"></textarea>
            <div class="form-text">La persona lo ve en su historial.</div>
            @if (hasError('concept')) {
              <div class="invalid-feedback">Entre {{ limits.conceptMin }} y {{ limits.conceptMax }} caracteres.</div>
            }
          </div>
        </fieldset>

        @if (formErrors().length) {
          <div class="alert alert-danger py-2 small" role="alert">
            @for (error of formErrors(); track error) {
              <div>{{ error }}</div>
            }
          </div>
        }

        @if (step() === 'form') {
          <div class="pa-actions">
            <button type="button" class="btn btn-light" (click)="clear()">Limpiar</button>
            <button type="submit" class="btn btn-dark">Revisar</button>
          </div>
        } @else {
          <!-- Confirmación: como una transferencia -->
          <div class="pa-confirm" role="alertdialog" aria-labelledby="pa-confirm-title">
            <p id="pa-confirm-title" class="pa-confirm__title">
              ¿Asignar <strong>{{ form.controls.points.value | number }} puntos</strong> a
              <strong>{{ selectedPerson()?.name ?? selectedEmail() }}</strong>?
            </p>
            <p class="pa-confirm__detail">
              @if (summary(); as current) {
                Saldo {{ current.balance | number }} → <strong>{{ projectedBalance() | number }}</strong> ·
              }
              Vencen el {{ (form.controls.expiresDate.value || null) ? (form.controls.expiresDate.value | date: 'd MMM y') : (defaultExpiration | date: 'd MMM y') }}
            </p>
            <div class="pa-actions">
              <button type="button" class="btn btn-light" [disabled]="saving()" (click)="backToForm()">Volver</button>
              <button type="button" class="btn btn-warning fw-semibold" [disabled]="saving()" (click)="confirmAssign()">
                @if (saving()) {
                  <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Asignando…
                } @else {
                  Confirmar asignación
                }
              </button>
            </div>
          </div>
        }
      </form>
    </section>

    <!-- ── Saldo de la persona ──────────────────────────────────────── -->
    <aside class="pa-card pa-balance" aria-live="polite">
      @if (lastAssignment(); as done) {
        <div class="alert alert-success py-2 small" role="status">
          <i class="fa-solid fa-circle-check me-1" aria-hidden="true"></i>
          Se asignaron <strong>{{ done.points | number }} puntos</strong> a {{ done.userName ?? done.userEmail }}.
          Saldo nuevo: <strong>{{ done.balanceAfter | number }}</strong>.
        </div>
      }

      @if (!selectedEmail()) {
        <p class="pa-balance__empty">Elige una persona para ver su saldo.</p>
      } @else if (summaryLoading()) {
        <div class="pa-skeleton" aria-hidden="true"><span></span><span></span></div>
      } @else if (summaryError()) {
        <div class="alert alert-danger py-2 small" role="alert">{{ summaryError() }}</div>
      } @else if (summary(); as current) {
        <p class="pa-balance__name">{{ current.userName }}</p>
        <p class="pa-balance__value">{{ current.balance | number }} <span>puntos disponibles</span></p>
        <dl class="pa-balance__stats">
          <div><dt>Ganados</dt><dd>{{ current.totalEarned | number }}</dd></div>
          <div><dt>Usados</dt><dd>{{ current.totalSpent | number }}</dd></div>
          <div><dt>Por vencer ({{ current.expiringSoonDays }} días)</dt><dd>{{ current.expiringSoonPoints | number }}</dd></div>
        </dl>
        @if (current.nextExpirationDate) {
          <p class="pa-balance__next">Próximo vencimiento: {{ current.nextExpirationDate | date: 'd MMM y' }}</p>
        }
      }
    </aside>
  </div>

  <!-- ── Movimientos ────────────────────────────────────────────────── -->
  <section class="pa-card mt-3" aria-labelledby="pa-history-title">
    <div class="pa-history__head">
      <h2 id="pa-history-title" class="pa-card__title">Movimientos</h2>
      <div class="pa-chips" role="group" aria-label="Filtrar por origen">
        @for (filter of sourceFilters; track filter.label) {
          <button
            type="button"
            class="pa-chip"
            [class.is-active]="sourceFilter() === filter.value"
            [attr.aria-pressed]="sourceFilter() === filter.value"
            (click)="setSourceFilter(filter.value)">
            {{ filter.label }}
          </button>
        }
      </div>
      <label class="form-check mb-0">
        <input
          type="checkbox"
          class="form-check-input"
          [checked]="onlySelectedPerson()"
          [disabled]="!selectedEmail()"
          (change)="toggleOnlySelectedPerson($any($event.target).checked)" />
        <span class="form-check-label">Solo la persona elegida</span>
      </label>
    </div>

    <div class="pa-table-wrap" [class.is-loading]="history.loading() && history.loaded()">
      <table class="pa-table">
        <caption class="visually-hidden">Movimientos de puntos</caption>
        <thead>
          <tr>
            <th scope="col">Fecha</th>
            <th scope="col">Persona</th>
            <th scope="col">Origen</th>
            <th scope="col">Concepto</th>
            <th scope="col" class="text-end">Puntos</th>
            <th scope="col" class="text-end">Saldo</th>
            <th scope="col">Por</th>
            <th scope="col"><span class="visually-hidden">Acciones</span></th>
          </tr>
        </thead>
        <tbody>
          @for (item of history.items(); track item.id) {
            <tr [class.is-reversed]="item.isReversed">
              <td data-label="Fecha" class="text-nowrap">{{ item.createdAt | date: 'dd/MM/yyyy HH:mm' }}</td>
              <td data-label="Persona">
                <strong class="d-block">{{ item.userName }}</strong>
                <small class="text-body-secondary">{{ item.userEmail }}</small>
              </td>
              <td data-label="Origen">
                {{ item.sourceLabel }}
                @if (item.isReversed) {
                  <span class="pa-badge">Reversado</span>
                }
              </td>
              <td data-label="Concepto" class="pa-table__concept">{{ item.concept }}</td>
              <td data-label="Puntos" class="text-end">
                <strong class="pa-amount" [attr.data-sign]="item.points > 0 ? 'plus' : 'minus'">
                  {{ item.points > 0 ? '+' : '' }}{{ item.points | number }}
                </strong>
              </td>
              <td data-label="Saldo" class="text-end">{{ item.balanceAfter | number }}</td>
              <td data-label="Por"><small>{{ item.createdBy }}</small></td>
              <td data-label="Acciones" class="text-end">
                @if (item.canReverse && reversingId() !== item.id) {
                  <button type="button" class="btn btn-link btn-sm text-danger p-0" (click)="startReverse(item)">Reversar</button>
                }
              </td>
            </tr>

            @if (reversingId() === item.id) {
              <tr class="pa-reverse-row">
                <td colspan="8">
                  <div class="pa-reverse">
                    <label class="form-label small mb-1" [for]="'pa-reason-' + item.id">
                      Motivo del reverso de <strong>{{ item.points | number }} puntos</strong> a {{ item.userName }}
                    </label>
                    <div class="d-flex flex-wrap gap-2">
                      <input
                        class="form-control form-control-sm"
                        [id]="'pa-reason-' + item.id"
                        [value]="reverseReason()"
                        [maxLength]="limits.reasonMax"
                        placeholder="Ej.: Se asignó a la persona equivocada"
                        (input)="reverseReason.set($any($event.target).value)" />
                      <button type="button" class="btn btn-light btn-sm" [disabled]="reverseSaving()" (click)="cancelReverse()">Cancelar</button>
                      <button type="button" class="btn btn-danger btn-sm" [disabled]="reverseSaving()" (click)="confirmReverse(item)">
                        {{ reverseSaving() ? 'Reversando…' : 'Confirmar reverso' }}
                      </button>
                    </div>
                    @for (error of reverseErrors(); track error) {
                      <div class="text-danger small mt-1">{{ error }}</div>
                    }
                  </div>
                </td>
              </tr>
            }
          }
        </tbody>
      </table>

      @if (history.isFirstLoad()) {
        <div class="pa-skeleton" aria-hidden="true"><span></span><span></span><span></span></div>
      }

      @if (history.isEmpty()) {
        <p class="pa-empty">No hay movimientos con estos filtros.</p>
      }
    </div>

    @if (history.error()) {
      <div class="alert alert-danger d-flex justify-content-between align-items-center mt-2" role="alert">
        {{ history.error() }}
        <button type="button" class="btn btn-sm btn-outline-danger" (click)="history.reload()">Reintentar</button>
      </div>
    }

    @if (history.hasMore()) {
      <button type="button" class="pa-load-more" [disabled]="history.loading()" (click)="history.loadMore()">
        {{ history.loading() ? 'Cargando…' : 'Cargar más' }}
      </button>
    }
  </section>
</div>
```

### `points-admin.component.scss`

```scss
:host {
  display: block;
}

.pa-grid {
  display: grid;
  grid-template-columns: minmax(0, 3fr) minmax(0, 2fr);
  gap: 1rem;

  @media (max-width: 991.98px) {
    grid-template-columns: 1fr;
  }
}

.pa-card {
  padding: 1.5rem;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 1rem;
  background: var(--bs-body-bg);
  box-shadow: 0 4px 16px rgb(0 0 0 / 0.05);
}

.pa-card__title {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0 0.25rem;
  font-size: 1.25rem;
  font-weight: 700;

  i {
    color: var(--bs-warning);
  }
}

.pa-card__hint {
  margin-bottom: 1.25rem;
  color: var(--bs-secondary-color);
  font-size: 0.875rem;
}

fieldset {
  min-width: 0;
  margin: 0;
  padding: 0;
  border: 0;
}

.pa-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
}

.pa-confirm {
  padding: 1rem;
  border: 1px solid color-mix(in srgb, var(--bs-warning) 55%, transparent);
  border-radius: 0.75rem;
  background: color-mix(in srgb, var(--bs-warning) 10%, var(--bs-body-bg));
  animation: pa-rise 0.2s ease-out both;
}

.pa-confirm__title {
  margin-bottom: 0.25rem;
}

.pa-confirm__detail {
  margin-bottom: 0.75rem;
  color: var(--bs-secondary-color);
  font-size: 0.875rem;
}

// ── Saldo ─────────────────────────────────────────────────────────────
.pa-balance__empty {
  margin: 2rem 0;
  color: var(--bs-secondary-color);
  text-align: center;
}

.pa-balance__name {
  margin: 0;
  font-weight: 600;
}

.pa-balance__value {
  margin: 0.25rem 0 1rem;
  font-size: 2.25rem;
  font-weight: 800;
  line-height: 1.1;

  span {
    color: var(--bs-secondary-color);
    font-size: 0.9rem;
    font-weight: 500;
  }
}

.pa-balance__stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.5rem;
  margin: 0;

  div {
    padding: 0.5rem;
    border-radius: 0.5rem;
    background: var(--bs-tertiary-bg);
  }

  dt {
    color: var(--bs-secondary-color);
    font-size: 0.7rem;
    font-weight: 600;
  }

  dd {
    margin: 0;
    font-weight: 700;
  }
}

.pa-balance__next {
  margin: 0.75rem 0 0;
  color: var(--bs-secondary-color);
  font-size: 0.8rem;
}

// ── Movimientos ───────────────────────────────────────────────────────
.pa-history__head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.pa-chips {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 0.25rem;
}

.pa-chip {
  padding: 0.3rem 0.85rem;
  border: 1px solid transparent;
  border-radius: 999px;
  background: transparent;
  color: var(--bs-secondary-color);
  font-size: 0.8rem;
  font-weight: 600;

  &.is-active {
    border-color: color-mix(in srgb, var(--bs-warning) 55%, transparent);
    background: color-mix(in srgb, var(--bs-warning) 18%, transparent);
    color: var(--bs-emphasis-color);
  }
}

.pa-table-wrap {
  overflow-x: auto;
  overflow-y: hidden;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 0.75rem;
  transition: opacity 0.2s ease;

  &.is-loading {
    opacity: 0.55;
  }
}

.pa-table {
  width: 100%;
  font-size: 0.875rem;

  th {
    padding: 0.7rem 0.9rem;
    background: var(--bs-warning);
    color: var(--bs-emphasis-color);
    font-size: 0.72rem;
    font-weight: 700;
    letter-spacing: 0.05em;
    text-transform: uppercase;
  }

  td {
    padding: 0.6rem 0.9rem;
    border-top: 1px solid var(--bs-border-color-translucent);
    vertical-align: middle;
  }

  tr.is-reversed td {
    color: var(--bs-secondary-color);

    .pa-amount {
      text-decoration: line-through;
    }
  }
}

.pa-table__concept {
  max-width: 18rem;
}

.pa-amount {
  &[data-sign='plus'] { color: var(--bs-success); }
  &[data-sign='minus'] { color: var(--bs-danger); }
}

.pa-badge {
  margin-left: 0.35rem;
  padding: 0.05rem 0.5rem;
  border-radius: 999px;
  background: var(--bs-tertiary-bg);
  font-size: 0.7rem;
  font-weight: 600;
}

.pa-reverse-row td {
  background: color-mix(in srgb, var(--bs-danger) 6%, var(--bs-body-bg));

  input {
    flex: 1 1 18rem;
  }
}

.pa-load-more {
  display: block;
  margin: 1rem auto 0;
  padding: 0.5rem 1.5rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 999px;
  background: var(--bs-body-bg);
  font-weight: 600;
}

.pa-empty {
  padding: 1.5rem;
  color: var(--bs-secondary-color);
  text-align: center;
}

.pa-skeleton {
  display: grid;
  gap: 0.5rem;
  padding: 0.75rem;

  span {
    height: 2.5rem;
    border-radius: 0.5rem;
    background: var(--bs-tertiary-bg);
    animation: pa-pulse 1.2s ease-in-out infinite alternate;
  }
}

@keyframes pa-rise {
  from {
    opacity: 0;
    transform: translateY(4px);
  }
}

@keyframes pa-pulse {
  to { opacity: 0.5; }
}

@media (max-width: 767.98px) {
  .pa-table thead { display: none; }

  .pa-table tr {
    display: block;
    padding: 0.5rem 0.9rem;
    border-top: 1px solid var(--bs-border-color-translucent);
  }

  .pa-table td {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.2rem 0;
    border: 0;
    text-align: right;

    &::before {
      content: attr(data-label);
      color: var(--bs-secondary-color);
      font-size: 0.75rem;
      font-weight: 600;
      text-align: left;
    }
  }

  .pa-reverse-row td::before {
    content: none;
  }
}

@media (prefers-reduced-motion: reduce) {
  .pa-confirm,
  .pa-skeleton span {
    animation: none;
  }
}
```

### `puntos-dorados-admin.component.*` ✏️

```ts
// .ts
import { GoldenPointsAdminComponent } from './points-admin/points-admin.component';

type AdminTab = 'aprobaciones' | 'categorias' | 'catalogo' | 'puntos' | 'dashboard';

// En imports del @Component: agrega GoldenPointsAdminComponent.
```

```html
<!-- Botón de la pestaña, junto a "Catálogo" (copia la clase de los demás botones) -->
<button type="button" [class.active]="activeTab() === 'puntos'" (click)="setActiveTab('puntos')">Puntos</button>

<!-- Contenido de la pestaña -->
@if (activeTab() === 'puntos') {
  <app-golden-points-admin [people]="people()" />
}
```

> `people()` ya lo carga `loadModuleData()` del componente de administración. Debe traer **usuarios reales** de `dbo.users`: si son datos de prueba, la API responde "La persona seleccionada no existe".

---

## 7. Paso 5 — Colaborador: pestaña "Mis puntos"

### Diseño

```text
┌ MIS PUNTOS ──────────────────────────────────────────────────────────┐
│ 350 puntos disponibles                                                │
│ [Ganados 350] [Usados 0] [Por vencer 30 días: 0] [Vencidos 0]         │
│ Tus próximos puntos vencen el 1 de abril de 2027.                     │
└──────────────────────────────────────────────────────────────────────┘
┌ Próximos vencimientos ─────────────┐ ┌ Historial ─ (Todos|Abonos|Usos|Ajustes|Vencidos) ┐
│ Reconocimiento · Servicio  150 pts │ │ 🏅 Reconocimiento · Servicio            +150     │
│   vence 01/04/2027                 │ │    Reconocimiento aprobado: Servicio  Saldo 150  │
│ Asignación de puntos       200 pts │ │    01/10/2026 · vence 01/04/2027                 │
│   vence 07/04/2027                 │ │ 🪙 Asignación de puntos                 +200     │
└────────────────────────────────────┘ │    Bono por cierre del proyecto       Saldo 350  │
                                        └──────────────────────────────────────────────────┘
```

### `presentation/user/my-points/my-points.component.ts`

```ts
import { ChangeDetectionStrategy, Component, PLATFORM_ID, inject, signal } from '@angular/core';
import { DatePipe, DecimalPipe, isPlatformBrowser } from '@angular/common';
import { PuntosDoradosFacade } from '../../../application/puntos-dorados.fecade';
import { PagedList } from '../../../application/paged-list';
import {
  GoldenPointsSummary,
  GoldenPointsTransaction,
  GoldenPointsTransactionType,
} from '../../../domain/puntos-dorados';

@Component({
  selector: 'app-my-points',
  standalone: true,
  imports: [DatePipe, DecimalPipe],
  templateUrl: './my-points.component.html',
  styleUrl: './my-points.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class MyPointsComponent {
  private readonly facade = inject(PuntosDoradosFacade);

  readonly summary = signal<GoldenPointsSummary | null>(null);
  readonly summaryError = signal<string | null>(null);

  readonly typeFilters: readonly { value: GoldenPointsTransactionType | null; label: string }[] = [
    { value: null, label: 'Todos' },
    { value: 'Credito', label: 'Abonos' },
    { value: 'Debito', label: 'Usos' },
    { value: 'Ajuste', label: 'Ajustes' },
    { value: 'Vencimiento', label: 'Vencidos' },
  ];

  readonly typeFilter = signal<GoldenPointsTransactionType | null>(null);

  readonly history = new PagedList<GoldenPointsTransaction>(
    (page, pageSize) => this.facade.getMyPointsHistory({ page, pageSize, type: this.typeFilter() }),
    item => item.id,
  );

  constructor() {
    // Solo en el navegador: en SSR no hay token y la API respondería 401.
    if (isPlatformBrowser(inject(PLATFORM_ID))) {
      void this.loadSummary();
      void this.history.reload();
    }
  }

  async loadSummary(): Promise<void> {
    this.summaryError.set(null);
    const result = await this.facade.getMyPointsSummary();

    if (result.hasError) {
      this.summaryError.set(result.errors.join(' '));
      return;
    }

    this.summary.set(result.response);
  }

  setTypeFilter(value: GoldenPointsTransactionType | null): void {
    if (this.typeFilter() === value) {
      return;
    }

    this.typeFilter.set(value);
    void this.history.reload();
  }

  icon(item: GoldenPointsTransaction): string {
    switch (item.source) {
      case 'Reconocimiento':
        return 'fa-solid fa-medal';
      case 'Redencion':
        return 'fa-solid fa-gift';
      case 'Vencimiento':
        return 'fa-regular fa-clock';
      default:
        return item.type === 'Ajuste' ? 'fa-solid fa-rotate-left' : 'fa-solid fa-coins';
    }
  }
}
```

### `my-points.component.html`

```html
<div class="mp">
  <!-- ── Saldo ──────────────────────────────────────────────────────── -->
  <header class="mp-hero" aria-live="polite">
    <p class="mp-hero__eyebrow">Mis puntos</p>

    @if (summary(); as s) {
      <p class="mp-hero__balance">
        <span class="mp-hero__value">{{ s.balance | number }}</span> puntos disponibles
      </p>

      <dl class="mp-stats">
        <div class="mp-stat"><dt>Ganados</dt><dd>{{ s.totalEarned | number }}</dd></div>
        <div class="mp-stat"><dt>Usados</dt><dd>{{ s.totalSpent | number }}</dd></div>
        <div class="mp-stat" [class.is-warning]="s.expiringSoonPoints > 0">
          <dt>Por vencer ({{ s.expiringSoonDays }} días)</dt>
          <dd>{{ s.expiringSoonPoints | number }}</dd>
        </div>
        <div class="mp-stat"><dt>Vencidos</dt><dd>{{ s.totalExpired | number }}</dd></div>
      </dl>

      @if (s.nextExpirationDate) {
        <p class="mp-hero__next">
          <i class="fa-regular fa-clock" aria-hidden="true"></i>
          Tus próximos puntos vencen el {{ s.nextExpirationDate | date: "d 'de' MMMM 'de' y" }}.
        </p>
      }
    } @else if (summaryError()) {
      <div class="alert alert-danger d-flex justify-content-between align-items-center mb-0" role="alert">
        {{ summaryError() }}
        <button type="button" class="btn btn-sm btn-outline-danger" (click)="loadSummary()">Reintentar</button>
      </div>
    } @else {
      <div class="mp-skeleton" aria-hidden="true"><span></span><span></span></div>
    }
  </header>

  <div class="mp-grid">
    <!-- ── Próximos vencimientos ────────────────────────────────────── -->
    @if (summary()?.upcomingExpirations?.length) {
      <section class="mp-card" aria-labelledby="mp-expiring-title">
        <h3 id="mp-expiring-title" class="mp-card__title">Próximos vencimientos</h3>
        <ul class="mp-expiring">
          @for (bucket of summary()!.upcomingExpirations; track bucket.id) {
            <li>
              <span>{{ bucket.source }}</span>
              <strong>{{ bucket.remainingPoints | number }} pts</strong>
              <small>vence el {{ bucket.expiresAt | date: 'dd/MM/yyyy' }}</small>
            </li>
          }
        </ul>
      </section>
    }

    <!-- ── Historial ────────────────────────────────────────────────── -->
    <section class="mp-card mp-history" aria-labelledby="mp-history-title">
      <div class="mp-history__head">
        <h3 id="mp-history-title" class="mp-card__title">Historial</h3>
        <div class="mp-chips" role="group" aria-label="Filtrar por tipo de movimiento">
          @for (filter of typeFilters; track filter.label) {
            <button
              type="button"
              class="mp-chip"
              [class.is-active]="typeFilter() === filter.value"
              [attr.aria-pressed]="typeFilter() === filter.value"
              (click)="setTypeFilter(filter.value)">
              {{ filter.label }}
            </button>
          }
        </div>
      </div>

      <div class="mp-list" [class.is-loading]="history.loading() && history.loaded()">
        @for (item of history.items(); track item.id) {
          <article class="mp-item" [class.is-reversed]="item.isReversed">
            <span class="mp-item__icon" [attr.data-sign]="item.points > 0 ? 'plus' : 'minus'">
              <i [class]="icon(item)" aria-hidden="true"></i>
            </span>

            <div class="mp-item__body">
              <strong>{{ item.sourceLabel }}</strong>
              <p>{{ item.concept }}</p>
              <small>
                {{ item.createdAt | date: 'dd/MM/yyyy, h:mm a' }}
                @if (item.points > 0 && item.expiresAt) {
                  · vence el {{ item.expiresAt | date: 'dd/MM/yyyy' }}
                }
                @if (item.isReversed) {
                  · <span class="mp-badge">Reversado</span>
                }
              </small>
            </div>

            <div class="mp-item__amount">
              <strong [attr.data-sign]="item.points > 0 ? 'plus' : 'minus'">
                {{ item.points > 0 ? '+' : '' }}{{ item.points | number }}
              </strong>
              <small>Saldo {{ item.balanceAfter | number }}</small>
            </div>
          </article>
        }

        @if (history.isFirstLoad()) {
          <div class="mp-skeleton" aria-hidden="true"><span></span><span></span><span></span></div>
        }

        @if (history.isEmpty()) {
          <p class="mp-empty">
            @if (typeFilter()) {
              No tienes movimientos de este tipo.
            } @else {
              Aún no tienes puntos. Cuando te reconozcan con puntos o te asignen puntos, aparecerán aquí.
            }
          </p>
        }
      </div>

      @if (history.error()) {
        <div class="alert alert-danger d-flex justify-content-between align-items-center mt-2" role="alert">
          {{ history.error() }}
          <button type="button" class="btn btn-sm btn-outline-danger" (click)="history.reload()">Reintentar</button>
        </div>
      }

      @if (history.hasMore()) {
        <button type="button" class="mp-load-more" [disabled]="history.loading()" (click)="history.loadMore()">
          {{ history.loading() ? 'Cargando…' : 'Cargar más' }}
        </button>
      }
    </section>
  </div>
</div>
```

### `my-points.component.scss`

```scss
:host {
  display: block;
}

// ── Saldo ─────────────────────────────────────────────────────────────
.mp-hero {
  padding: 1.5rem;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 1rem;
  background:
    radial-gradient(90% 140% at 0% 0%, color-mix(in srgb, var(--bs-warning) 16%, transparent), transparent 55%),
    var(--bs-body-bg);
  box-shadow: 0 4px 16px rgb(0 0 0 / 0.05);
}

.mp-hero__eyebrow {
  margin: 0 0 0.25rem;
  color: var(--bs-warning);
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.mp-hero__balance {
  margin: 0 0 1rem;
  color: var(--bs-secondary-color);
  font-weight: 500;
}

.mp-hero__value {
  margin-right: 0.35rem;
  color: var(--bs-emphasis-color);
  font-size: 2.75rem;
  font-weight: 800;
  line-height: 1;
}

.mp-stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
  gap: 0.75rem;
  margin: 0;
}

.mp-stat {
  padding: 0.75rem 1rem;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 0.75rem;
  background: var(--bs-body-bg);

  dt {
    color: var(--bs-secondary-color);
    font-size: 0.72rem;
    font-weight: 600;
  }

  dd {
    margin: 0;
    font-size: 1.35rem;
    font-weight: 800;
  }

  &.is-warning {
    border-color: color-mix(in srgb, var(--bs-warning) 60%, transparent);
  }
}

.mp-hero__next {
  margin: 1rem 0 0;
  color: var(--bs-secondary-color);
  font-size: 0.875rem;
}

// ── Tarjetas ──────────────────────────────────────────────────────────
.mp-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 2fr);
  gap: 1rem;
  margin-top: 1rem;

  @media (max-width: 991.98px) {
    grid-template-columns: 1fr;
  }
}

.mp-history:only-child {
  grid-column: 1 / -1;
}

.mp-card {
  padding: 1.25rem;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 1rem;
  background: var(--bs-body-bg);
}

.mp-card__title {
  margin: 0;
  font-size: 1.05rem;
  font-weight: 700;
}

.mp-expiring {
  display: grid;
  gap: 0.5rem;
  margin: 0.75rem 0 0;
  padding: 0;
  list-style: none;

  li {
    display: grid;
    grid-template-columns: 1fr auto;
    padding: 0.6rem 0.75rem;
    border-radius: 0.5rem;
    background: var(--bs-tertiary-bg);
  }

  small {
    grid-column: 1 / -1;
    color: var(--bs-secondary-color);
  }
}

.mp-history__head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 0.75rem;
}

.mp-chips {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 0.25rem;
}

.mp-chip {
  padding: 0.3rem 0.85rem;
  border: 1px solid transparent;
  border-radius: 999px;
  background: transparent;
  color: var(--bs-secondary-color);
  font-size: 0.8rem;
  font-weight: 600;

  &.is-active {
    border-color: color-mix(in srgb, var(--bs-warning) 55%, transparent);
    background: color-mix(in srgb, var(--bs-warning) 18%, transparent);
    color: var(--bs-emphasis-color);
  }
}

// ── Historial ─────────────────────────────────────────────────────────
.mp-list {
  transition: opacity 0.2s ease;

  &.is-loading {
    opacity: 0.55;
  }
}

.mp-item {
  display: grid;
  grid-template-columns: auto 1fr auto;
  align-items: start;
  gap: 0.75rem;
  padding: 0.85rem 0;
  border-top: 1px solid var(--bs-border-color-translucent);

  &:first-child {
    border-top: 0;
  }

  &.is-reversed {
    opacity: 0.6;

    .mp-item__amount strong {
      text-decoration: line-through;
    }
  }
}

.mp-item__icon {
  --tone: var(--bs-success);

  display: inline-grid;
  place-items: center;
  width: 2.25rem;
  height: 2.25rem;
  border-radius: 0.6rem;
  background: color-mix(in srgb, var(--tone) 14%, transparent);
  color: var(--tone);

  &[data-sign='minus'] { --tone: var(--bs-danger); }
}

.mp-item__body {
  min-width: 0;

  p {
    margin: 0.1rem 0;
    color: var(--bs-body-color);
    font-size: 0.875rem;
    overflow-wrap: anywhere;
  }

  small {
    color: var(--bs-secondary-color);
  }
}

.mp-item__amount {
  display: grid;
  justify-items: end;

  strong {
    font-size: 1.1rem;

    &[data-sign='plus'] { color: var(--bs-success); }
    &[data-sign='minus'] { color: var(--bs-danger); }
  }

  small {
    color: var(--bs-secondary-color);
    white-space: nowrap;
  }
}

.mp-badge {
  padding: 0.05rem 0.5rem;
  border-radius: 999px;
  background: var(--bs-tertiary-bg);
  font-weight: 600;
}

.mp-load-more {
  display: block;
  margin: 1rem auto 0;
  padding: 0.5rem 1.5rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 999px;
  background: var(--bs-body-bg);
  font-weight: 600;
}

.mp-empty {
  padding: 1.5rem 0.5rem;
  color: var(--bs-secondary-color);
  text-align: center;
}

.mp-skeleton {
  display: grid;
  gap: 0.5rem;

  span {
    height: 3rem;
    border-radius: 0.5rem;
    background: var(--bs-tertiary-bg);
    animation: mp-pulse 1.2s ease-in-out infinite alternate;
  }
}

@keyframes mp-pulse {
  to { opacity: 0.5; }
}

@media (prefers-reduced-motion: reduce) {
  .mp-skeleton span {
    animation: none;
  }
}
```

### `puntos-dorados-user.component.*` ✏️

```ts
// .ts
import { MyPointsComponent } from './my-points/my-points.component';

type UserTab = 'feed' | 'reconocer' | 'mis-reconocimientos' | 'mis-puntos' | 'redimir';

// En imports del @Component: agrega MyPointsComponent.

// En loadTabData(tab): "Mis puntos" no necesita caso, porque app-my-points carga sus datos al crearse.
// Si el switch tiene un default que avisa de pestañas sin manejar, agrega:
//   case 'mis-puntos':
//     break;
```

```html
<!-- Botón, después de "Mis reconocimientos" (copia la clase de los demás botones) -->
<button type="button" [class.active]="activeTab() === 'mis-puntos'" (click)="setActiveTab('mis-puntos')">Mis puntos</button>

<!-- Contenido -->
@if (activeTab() === 'mis-puntos') {
  <app-my-points />
}
```

### 7.3 Datos de prueba que reemplaza

`loadModuleData()` ya no carga los datos financieros al inicio. Con "Mis puntos" conectado a la API, quedan tres cosas por resolver:

1. **`refreshUserFinancialData()`.** Si todavía existe (por ejemplo, llamado desde `bootstrapUserContext()`), quita de ahí `getTransactions(email)`, `getPointsBuckets(email)` y `getExpiringPoints(email)`: "Mis puntos" usa la API. `getRedemptions(email)` se queda hasta que exista la redención.
2. **Saldo en "Redimir".** Si esa pestaña muestra el saldo calculado con `transactions()`, cárgalo desde la API en el caso `'redimir'` de `loadTabData`:

   ```ts
   readonly pointsBalance = signal<number | null>(null);

   private async loadPointsBalance(): Promise<void> {
     const result = await this.facade.getMyPointsSummary();
     if (!result.hasError) {
       this.pointsBalance.set(result.response.balance);
     }
   }

   // En loadTabData:
   //   case 'redimir':
   //     void this.loadPointsBalance();
   //     … (lo que ya carga: catálogo disponible)
   //     break;
   ```

3. **"Vencimiento de puntos" en "Mis reconocimientos"** (`getRecognitionExpirationDate`) busca un lote con `source === 'Reconocimiento #id'`. Ese formato no existe en la API. Hoy ningún reconocimiento abona puntos, así que no muestra nada. Cuando se haga la aprobación (parte 2), la API devolverá la fecha de vencimiento dentro del reconocimiento recibido y este método desaparece.

> **Errores repetidos.** Si `HttpErrorHandlerService` muestra una alerta para los errores HTTP, los formularios de esta guía también muestran `result.errors`. Revisa la observación 1 de [puntos-dorados-cambios-frontend.md](puntos-dorados-cambios-frontend.md) para que el usuario no vea el mismo error dos veces.

---

## 8. Pruebas

**Administración**
- Elige a una persona y aparece su saldo.
- Asigna 200: el paso **Revisar** muestra "Saldo 150 → 350"; **Confirmar** asigna. El mensaje de éxito trae el saldo nuevo, el formulario se limpia (la persona sigue elegida) y el movimiento aparece primero en la tabla.
- **Doble clic en "Confirmar asignación":** el botón se deshabilita y la tabla muestra **un** movimiento.
- **Red caída al confirmar:** sale el error. Al volver a confirmar sin cambiar nada se envía el mismo `requestId`; si la primera sí llegó, la API devuelve el mismo movimiento y no abona dos veces.
- **Cambiar los puntos después de un error:** se genera un `requestId` nuevo (otra solicitud).
- **Elegirse a sí mismo:** la API responde "No puedes asignarte puntos a ti mismo".
- **Vencimiento vacío:** el texto de ayuda dice la fecha por defecto y el movimiento la muestra.
- **Reversar:** pide motivo (5 o más caracteres). Después la fila original sale como "Reversado" y aparece un `Ajuste −200`. "Reversar" ya no aparece en esa fila.
- **Filtros:** "Asignaciones" muestra solo manuales; "Solo la persona elegida" filtra por la persona del formulario.

**Colaborador**
- "Mis puntos" muestra el saldo y el historial, lo más reciente primero.
- Los abonos dicen cuándo vencen; los reversados salen tachados.
- El filtro "Ajustes" muestra los reversos.
- Una asignación **no** aparece en el feed.
- Con otra cuenta: nunca se ven los movimientos de otra persona.
- La fecha de vencimiento coincide con la que eligió el administrador (sin correrse un día).

---

## ✅ Checklist

- [ ] API de [puntos-dorados-puntos-api.md](puntos-dorados-puntos-api.md) desplegada.
- [ ] Helpers comunes movidos a `infraestructure/golden-api.ts`; reconocimientos importando desde ahí.
- [ ] Tipos de puntos en el dominio (campos nuevos de `GoldenPointsTransaction` opcionales).
- [ ] `golden-points.service.ts` con `authHeaders()` y `catchError` copiados de `golden-recognitions.service.ts`.
- [ ] `golden-points.mapper.ts`, `golden-request-id.ts` y `golden-validators.ts`.
- [ ] Seis métodos nuevos en el facade con `runRecognitionRequest`.
- [ ] `GoldenPointsAdminComponent` en la pestaña "Puntos"; `people()` con usuarios reales.
- [ ] `MyPointsComponent` en la pestaña "Mis puntos".
- [ ] `refreshUserFinancialData()` sin las tres llamadas de prueba; saldo de "Redimir" cargado en `loadTabData('redimir')` si lo usa.
- [ ] Fechas sin hora con `parseDateOnly` (no `parseUtc`).
- [ ] Probado el doble clic y el reintento después de un error de red.
