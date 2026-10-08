# 🖥️ Puntos Dorados — Aprobaciones y Dashboard (Angular)

Conecta dos pestañas de `PuntosDoradosAdminComponent` con su API:

| Pestaña | API |
|---|---|
| **Aprobaciones** | [puntos-dorados-aprobaciones-api.md](puntos-dorados-aprobaciones-api.md) |
| **Dashboard** | [puntos-dorados-dashboard-api.md](puntos-dorados-dashboard-api.md) |

**Se cambia el componente en su lugar.** La plantilla y los estilos ya existen (`.approval-card`, `.kpi-card`, los cuatro `<canvas>`, `app-dashboard-filters`). La guía cambia de dónde salen los datos y toca la plantilla solo donde hace falta.

Sigue el patrón con el que quedó implementado reconocimientos ([puntos-dorados-cambios-frontend.md](puntos-dorados-cambios-frontend.md)):

| Capa | Cómo |
|---|---|
| **Servicio** | `AuthService` + `await this.authHeaders()` en cada método (`async`, devuelven `Promise<Observable<GoldenResult<T>>>`) y `catchError` con `HttpErrorHandlerService`. |
| **Facade** | Cada método pasa por `runRecognitionRequest` y devuelve `Promise<GoldenResult<T>>`. Nunca lanza. |
| **Componente** | Estado en signals; revisa `result.hasError`; los errores se muestran donde se produjeron. La lista de aprobaciones usa `PagedList`. Cada pestaña carga sus datos al abrirse. |

**Antes de empezar:**
- **Las dos APIs desplegadas.**
- **`infraestructure/golden-api.ts`** con los helpers comunes y `parseDateOnly`. Es el Paso 2 de [puntos-dorados-puntos-angular.md](puntos-dorados-puntos-angular.md). Si todavía no hiciste esa guía, haz solo ese archivo.

---

## 1. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **¿Componentes hijos o el mismo componente?** | **El mismo.** Los estilos de las tarjetas, los KPI y las gráficas viven en el SCSS de `PuntosDoradosAdminComponent`; un hijo no los recibiría (encapsulación de estilos) y la pantalla se vería distinta. Los métodos que la plantilla ya llama (`approveNomination`, `rejectNomination`, `updateApprovedPoints`, `getApprovalPoints`, `dashboardKpis`, `applyDashboardFilters`…) se conservan con el mismo nombre; cambia lo que hacen. |
| 2 | **Aprobar es mover puntos.** | Dos clics: **✅ Aprobar** muestra "¿Aprobar y asignar 150 puntos a Juan?" dentro de la tarjeta y **Confirmar** llama a la API. Igual para rechazar (es definitivo) y "Guardar ajuste" ("¿Dejar en 120 los puntos…?"). |
| 3 | **Después de aprobar.** | La API devuelve la tarjeta actualizada y se reemplaza en la lista (`PagedList.patch`), sin recargar. |
| 4 | **Errores de una tarjeta.** | Debajo de esa tarjeta. "Ya fue aprobado" significa que otra persona lo revisó primero: **↻ Recargar** trae el estado real. |
| 5 | **Lista de aprobaciones.** | Paginada (12 por página, "Cargar más") y con filtro por estado. La API ya pone los pendientes primero, el más antiguo arriba. |
| 6 | **Filtros del dashboard.** | `app-dashboard-filters` (el de mental-health) **no cambia** y `FilterState` tampoco. `toApiDashboardFilters` lo traduce a la API: los correos pasan tal cual, los estados también, y las categorías, que el modal maneja por **nombre**, se convierten a **id** con `categories()`. Las opciones de categoría salen de `categories()`, no de los reconocimientos. |
| 7 | **KPI.** | Se conserva la forma `{ label, value, trend }` que pinta la plantilla. `trend` es `+12%`, `↓ 8%` (la plantilla ya lo pinta rojo por la flecha), `Nuevo` si antes era 0, o vacío si no cambió ("sin variación"). |
| 8 | **Gráficas.** | Los mismos `@ViewChild`, `charts`, `renderDashboardCharts` y estilos (`DASHBOARD_COLORS`, `LEGEND_DEFAULTS`…). Cambia de dónde salen los números: la configuración pasa a `golden-dashboard-charts.ts` y el `effect` que ya existe redibuja cuando cambia `dashboardData()`. Al salir de la pestaña, las gráficas se destruyen. |
| 9 | **Carga por pestaña.** | Aprobaciones: la primera vez que se abre (`ensureLoaded`). Dashboard: **cada vez** que se abre y al aplicar filtros, porque son métricas "en tiempo real". |
| 10 | **Respuestas que llegan tarde.** | Si se aplican filtros dos veces seguidas, solo cuenta la última respuesta. |
| 11 | **Carga masiva y exportar.** | Siguen sin API: `processBulkApprovals` y `exportConsolidatedData` del facade son de prueba. Se deshabilitan los dos botones hasta tener su endpoint; la lectura del Excel y el armado del XLSX se quedan (sección 9). **Exportar** ya tiene su guía: [puntos-dorados-exportar-consolidado.md](puntos-dorados-exportar-consolidado.md); si la implementas junto con esta, no lo deshabilites. |
| 12 | **Puntos por defecto.** | Antes el input arrancaba en **100** (`getApprovalPoints` devolvía `?? 100`): aprobar sin mirar daba 100 puntos. Ahora un pendiente arranca vacío (sin puntos). |

---

## 2. Archivos

```text
src/app/features/puntos-dorados/
├── domain/puntos-dorados.ts                           ✏️ tipos de aprobaciones y dashboard
├── infraestructure/
│   ├── golden-approvals.mapper.ts                     nuevo
│   ├── golden-approvals.service.ts                    nuevo
│   ├── golden-dashboard.mapper.ts                     nuevo
│   └── golden-dashboard.service.ts                    nuevo
├── application/puntos-dorados.fecade.ts               ✏️ + 5 métodos con runRecognitionRequest
└── presentation/admin/
    ├── golden-dashboard-charts.ts                     nuevo — las 4 gráficas, con los estilos que hoy están en el componente
    ├── puntos-dorados-admin.component.ts              ✏️ aprobaciones y dashboard con la API
    ├── puntos-dorados-admin.component.html            ✏️ cambios puntuales
    └── puntos-dorados-admin.component.scss            ✏️ + confirmación, errores y "Cargar más"
```

---

## 3. Paso 1 — Dominio (`domain/puntos-dorados.ts`) ✏️

Agrega al final del archivo:

```ts
// ── Aprobaciones ─────────────────────────────────────────────────────

/** Tarjeta de la pestaña Aprobaciones: el reconocimiento con los datos de su revisión. */
export interface GoldenApprovalItem extends GoldenNomination {
  reviewedBy: string | null;
  reviewComment: string | null;
  /** Pendiente: se muestran "Rechazar" y "Aprobar". */
  canReview: boolean;
  /** Aprobada: se muestra "Guardar ajuste". */
  canAdjustPoints: boolean;
}

export interface GoldenApprovalQuery {
  page: number;
  pageSize: number;
  /** null = todos. */
  status?: GoldenNominationStatus | null;
}

export interface ApproveGoldenRecognition {
  /** null o 0 = sin puntos. */
  points: number | null;
  comment?: string | null;
}

/** Mismo límite que la API. */
export const GOLDEN_APPROVAL_MAX_POINTS = 100_000;

// ── Dashboard ────────────────────────────────────────────────────────

/** Parámetros de GET /api/GoldenDashboard (no es el modelo del modal: ver toApiDashboardFilters). */
export interface GoldenDashboardFilters {
  /** yyyy-MM-dd. null = desde el 1 del mes. */
  from: string | null;
  /** yyyy-MM-dd. null = hoy. */
  to: string | null;
  userEmails: string[];
  statuses: GoldenNominationStatus[];
  categoryIds: number[];
}

/** Valor de un indicador en la API. (GoldenDashboardKpi ya existe: es la tarjeta { label, value, trend }.) */
export interface GoldenDashboardKpiValue {
  value: number;
  previous: number;
  /** % contra el período anterior. null = el anterior fue 0. */
  changePercent: number | null;
}

export interface GoldenDashboard {
  period: { from: Date; to: Date; previousFrom: Date; previousTo: Date };
  kpis: {
    recognitions: GoldenDashboardKpiValue;
    approvals: GoldenDashboardKpiValue;
    pointsAssigned: GoldenDashboardKpiValue;
    redemptions: GoldenDashboardKpiValue;
  };
  recognitionsByMonth: { month: Date; count: number }[];
  statusDistribution: { status: GoldenNominationStatus; count: number }[];
  recognitionsByCategory: { categoryId: number; name: string; icon: string; color: string; count: number }[];
  pointsByMonth: { month: Date; recognitionPoints: number; manualPoints: number; total: number }[];
}
```

---

## 4. Paso 2 — Infraestructura

### `infraestructure/golden-approvals.mapper.ts`

La tarjeta es el mismo reconocimiento de siempre más cuatro campos: se reutiliza `toNomination`.

```ts
import { GoldenApprovalItem } from '../domain/puntos-dorados';
import { GoldenRecognitionDto, toNomination } from './golden-recognitions.mapper';

export interface GoldenApprovalDto extends GoldenRecognitionDto {
  reviewedBy: string | null;
  reviewComment: string | null;
  canReview: boolean;
  canAdjustPoints: boolean;
}

export function toApprovalItem(dto: GoldenApprovalDto): GoldenApprovalItem {
  return {
    ...toNomination(dto),
    reviewedBy: dto.reviewedBy,
    reviewComment: dto.reviewComment,
    canReview: dto.canReview,
    canAdjustPoints: dto.canAdjustPoints,
  };
}
```

### `infraestructure/golden-approvals.service.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Observable, catchError, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';          // ⬅ mismos imports que golden-recognitions.service.ts
import { AuthService } from '@core/services/auth-msal.service';             // ⬅ ruta real del AuthService
import { HttpErrorHandlerService } from '@core/services/http-error-handler.service'; // ⬅ ruta real
import {
  ApproveGoldenRecognition,
  GoldenApprovalItem,
  GoldenApprovalQuery,
  GoldenPagedResult,
  GoldenResult,
} from '../domain/puntos-dorados';
import { GoldenPagedResultDto, GoldenResultDto, toPage, toResult } from './golden-api';
import { GoldenApprovalDto, toApprovalItem } from './golden-approvals.mapper';

@Injectable({ providedIn: 'root' })
export class GoldenApprovalsService {
  private readonly http = inject(HttpClient);
  private readonly authService = inject(AuthService);
  private readonly httpErrorHandler = inject(HttpErrorHandlerService);
  private readonly baseUrl = `${environment.api.baseUrl}/api/GoldenRecognitionApprovals`;

  async getApprovals(query: GoldenApprovalQuery): Promise<Observable<GoldenResult<GoldenPagedResult<GoldenApprovalItem>>>> {
    const headers = await this.authHeaders();
    let params = new HttpParams().set('page', query.page).set('pageSize', query.pageSize);

    if (query.status) {
      params = params.set('status', query.status);
    }

    return this.http
      .get<GoldenResultDto<GoldenPagedResultDto<GoldenApprovalDto>>>(this.baseUrl, { headers, params })
      .pipe(
        map(dto => toResult(dto, page => toPage(page, toApprovalItem))),
        catchError(error => this.handleError(error)),
      );
  }

  async approve(recognitionId: number, request: ApproveGoldenRecognition): Promise<Observable<GoldenResult<GoldenApprovalItem>>> {
    const headers = await this.authHeaders();

    return this.http
      .patch<GoldenResultDto<GoldenApprovalDto>>(`${this.baseUrl}/${recognitionId}/approve`, request, { headers })
      .pipe(
        map(dto => toResult(dto, toApprovalItem)),
        catchError(error => this.handleError(error)),
      );
  }

  async reject(recognitionId: number, comment: string | null): Promise<Observable<GoldenResult<GoldenApprovalItem>>> {
    const headers = await this.authHeaders();

    return this.http
      .patch<GoldenResultDto<GoldenApprovalDto>>(`${this.baseUrl}/${recognitionId}/reject`, { comment }, { headers })
      .pipe(
        map(dto => toResult(dto, toApprovalItem)),
        catchError(error => this.handleError(error)),
      );
  }

  /** "Guardar ajuste": el total de puntos que debe quedar (0 = quitar). */
  async adjustPoints(recognitionId: number, points: number): Promise<Observable<GoldenResult<GoldenApprovalItem>>> {
    const headers = await this.authHeaders();

    return this.http
      .put<GoldenResultDto<GoldenApprovalDto>>(`${this.baseUrl}/${recognitionId}/points`, { points }, { headers })
      .pipe(
        map(dto => toResult(dto, toApprovalItem)),
        catchError(error => this.handleError(error)),
      );
  }

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
}
```

### `infraestructure/golden-dashboard.mapper.ts`

```ts
import { GoldenDashboard, GoldenDashboardKpiValue, GoldenNominationStatus } from '../domain/puntos-dorados';
import { parseDateOnly } from './golden-api';

interface GoldenDashboardKpiDto {
  value: number;
  previous: number;
  changePercent: number | null;
}

export interface GoldenDashboardDto {
  period: { from: string; to: string; previousFrom: string; previousTo: string };
  kpis: {
    recognitions: GoldenDashboardKpiDto;
    approvals: GoldenDashboardKpiDto;
    pointsAssigned: GoldenDashboardKpiDto;
    redemptions: GoldenDashboardKpiDto;
  };
  recognitionsByMonth: { month: string; count: number }[];
  statusDistribution: { status: string; count: number }[];
  recognitionsByCategory: { categoryId: number; name: string; icon: string; color: string; count: number }[];
  pointsByMonth: { month: string; recognitionPoints: number; manualPoints: number; total: number }[];
}

function toStatus(value: string): GoldenNominationStatus {
  return value === 'Aprobada' || value === 'Rechazada' ? value : 'Pendiente';
}

function toKpi(dto: GoldenDashboardKpiDto): GoldenDashboardKpiValue {
  return { value: dto.value, previous: dto.previous, changePercent: dto.changePercent ?? null };
}

/** Los meses y el período son fechas sin hora: parseDateOnly, no parseUtc (si no, se corren un día). */
export function toDashboard(dto: GoldenDashboardDto): GoldenDashboard {
  return {
    period: {
      from: parseDateOnly(dto.period.from),
      to: parseDateOnly(dto.period.to),
      previousFrom: parseDateOnly(dto.period.previousFrom),
      previousTo: parseDateOnly(dto.period.previousTo),
    },
    kpis: {
      recognitions: toKpi(dto.kpis.recognitions),
      approvals: toKpi(dto.kpis.approvals),
      pointsAssigned: toKpi(dto.kpis.pointsAssigned),
      redemptions: toKpi(dto.kpis.redemptions),
    },
    recognitionsByMonth: (dto.recognitionsByMonth ?? []).map(point => ({ month: parseDateOnly(point.month), count: point.count })),
    statusDistribution: (dto.statusDistribution ?? []).map(item => ({ status: toStatus(item.status), count: item.count })),
    recognitionsByCategory: dto.recognitionsByCategory ?? [],
    pointsByMonth: (dto.pointsByMonth ?? []).map(point => ({ ...point, month: parseDateOnly(point.month) })),
  };
}
```

### `infraestructure/golden-dashboard.service.ts`

Las listas del filtro se envían **repitiendo** el parámetro (`statuses=Aprobada&statuses=Pendiente`), que es lo que espera la API.

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Observable, catchError, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';          // ⬅ mismos imports que golden-recognitions.service.ts
import { AuthService } from '@core/services/auth-msal.service';             // ⬅ ruta real
import { HttpErrorHandlerService } from '@core/services/http-error-handler.service'; // ⬅ ruta real
import { GoldenDashboard, GoldenDashboardFilters, GoldenResult } from '../domain/puntos-dorados';
import { GoldenResultDto, toResult } from './golden-api';
import { GoldenDashboardDto, toDashboard } from './golden-dashboard.mapper';

@Injectable({ providedIn: 'root' })
export class GoldenDashboardService {
  private readonly http = inject(HttpClient);
  private readonly authService = inject(AuthService);
  private readonly httpErrorHandler = inject(HttpErrorHandlerService);
  private readonly baseUrl = `${environment.api.baseUrl}/api/GoldenDashboard`;

  async getDashboard(filters: GoldenDashboardFilters): Promise<Observable<GoldenResult<GoldenDashboard>>> {
    const headers = await this.authHeaders();

    return this.http
      .get<GoldenResultDto<GoldenDashboardDto>>(this.baseUrl, { headers, params: this.params(filters) })
      .pipe(
        map(dto => toResult(dto, toDashboard)),
        catchError(error => this.handleError(error)),
      );
  }

  private params(filters: GoldenDashboardFilters): HttpParams {
    let params = new HttpParams();

    if (filters.from) {
      params = params.set('from', filters.from);
    }

    if (filters.to) {
      params = params.set('to', filters.to);
    }

    for (const email of filters.userEmails) {
      params = params.append('userEmails', email);
    }

    for (const status of filters.statuses) {
      params = params.append('statuses', status);
    }

    for (const categoryId of filters.categoryIds) {
      params = params.append('categoryIds', categoryId);
    }

    return params;
  }

  /** ⬇ Mismo cuerpo que en golden-recognitions.service.ts. */
  private async authHeaders(): Promise<HttpHeaders> {
    // …
  }

  /** ⬇ Mismo llamado a HttpErrorHandlerService; debe relanzar el error. */
  private handleError(error: unknown): Observable<never> {
    // …
  }
}
```

> **Rutas de `AuthService` y `HttpErrorHandlerService`:** las de arriba son de ejemplo. Copia los `import` exactos de `golden-recognitions.service.ts`.
>
> **`authHeaders()` repetido:** con estos dos servicios ya son tres o cuatro copias del mismo método. Si quieres quitar la repetición, el siguiente paso natural es un servicio compartido (por ejemplo `GoldenApiAuthService` con `headers()` y `handleError()`) que se inyecta en todos.

---

## 5. Paso 3 — `application/puntos-dorados.fecade.ts` ✏️

```ts
import { GoldenApprovalsService } from '../infraestructure/golden-approvals.service';
import { GoldenDashboardService } from '../infraestructure/golden-dashboard.service';
import {
  ApproveGoldenRecognition,
  GoldenApprovalItem,
  GoldenApprovalQuery,
  GoldenDashboard,
  GoldenDashboardFilters,
} from '../domain/puntos-dorados';

// Dentro de la clase:
private readonly approvals = inject(GoldenApprovalsService);
private readonly dashboardApi = inject(GoldenDashboardService);

// ── Aprobaciones (API) ───────────────────────────────────────────────

getRecognitionApprovals(query: GoldenApprovalQuery): Promise<GoldenResult<GoldenPagedResult<GoldenApprovalItem>>> {
  return this.runRecognitionRequest(() => this.approvals.getApprovals(query), 'No se pudieron cargar los reconocimientos por aprobar.');
}

approveRecognition(recognitionId: number, request: ApproveGoldenRecognition): Promise<GoldenResult<GoldenApprovalItem>> {
  return this.runRecognitionRequest(() => this.approvals.approve(recognitionId, request), 'No se pudo aprobar el reconocimiento. Intenta de nuevo.');
}

rejectRecognition(recognitionId: number, comment: string | null): Promise<GoldenResult<GoldenApprovalItem>> {
  return this.runRecognitionRequest(() => this.approvals.reject(recognitionId, comment), 'No se pudo rechazar el reconocimiento. Intenta de nuevo.');
}

adjustRecognitionPoints(recognitionId: number, points: number): Promise<GoldenResult<GoldenApprovalItem>> {
  return this.runRecognitionRequest(() => this.approvals.adjustPoints(recognitionId, points), 'No se pudo guardar el ajuste de puntos.');
}

// ── Dashboard (API) ──────────────────────────────────────────────────

getDashboard(filters: GoldenDashboardFilters): Promise<GoldenResult<GoldenDashboard>> {
  return this.runRecognitionRequest(() => this.dashboardApi.getDashboard(filters), 'No se pudieron cargar las métricas.');
}
```

> Mismo wrapper que reconocimientos y puntos. Si en tu código `runRecognitionRequest` recibe la promesa directamente en lugar de una función, usa esa forma en los cinco métodos.

---

## 6. Paso 4 — `presentation/admin/golden-dashboard-charts.ts`

La configuración de las cuatro gráficas, fuera del componente. **Se mueven aquí, sin cambios, los estilos que hoy están arriba de `puntos-dorados-admin.component.ts`** (`CHART_FONT`, `DASHBOARD_COLORS`, `TOOLTIP_DEFAULTS`, `LEGEND_DEFAULTS`), así las gráficas se ven igual que ahora. Solo cambia de dónde salen los números.

```ts
import type { ChartConfiguration } from 'chart.js';
import { GoldenDashboard, GoldenNominationStatus } from '../../domain/puntos-dorados';

// ── Estilos (movidos sin cambios desde puntos-dorados-admin.component.ts) ──
const CHART_FONT = { family: "'Montserrat', sans-serif", weight: 600 as const };
const DASHBOARD_COLORS = {
  yellow: '#f5c518',
  yellowSoft: '#f9d54a',
  yellowDark: '#e0b700',
  black: '#111827',
  green: '#10b981',
  amber: '#f59e0b',
  red: '#ef4444',
  gray: '#6b7280',
  graySoft: '#d1d5db',
} as const;

const TOOLTIP_DEFAULTS = {
  backgroundColor: 'rgba(0, 0, 0, 0.8)',
  titleFont: CHART_FONT,
  bodyFont: { family: "'Montserrat', sans-serif" },
};

const LEGEND_DEFAULTS = {
  display: true,
  position: 'bottom' as const,
  labels: { font: CHART_FONT, padding: 12, usePointStyle: true },
};

const STATUS_COLORS: Record<GoldenNominationStatus, string> = {
  Pendiente: DASHBOARD_COLORS.amber,
  Aprobada: DASHBOARD_COLORS.green,
  Rechazada: DASHBOARD_COLORS.red,
};

const CATEGORY_PALETTE = [
  DASHBOARD_COLORS.yellow,
  DASHBOARD_COLORS.yellowSoft,
  DASHBOARD_COLORS.yellowDark,
  DASHBOARD_COLORS.gray,
  DASHBOARD_COLORS.graySoft,
];

const MONTH = new Intl.DateTimeFormat('es-CO', { month: 'short' });

/** "may.-26", el mismo formato que usaba getLastMonthsLabels. */
function monthLabel(date: Date): string {
  return `${MONTH.format(date)}-${String(date.getFullYear()).slice(-2)}`;
}

/** "Reconocimientos creados": un punto por mes, también los meses en 0. */
export function trendChartConfig(data: GoldenDashboard): ChartConfiguration<'line'> {
  const months = data.recognitionsByMonth;

  return {
    type: 'line',
    data: {
      labels: months.map(item => monthLabel(item.month)),
      datasets: [
        {
          label: 'Reconocimientos creados',
          data: months.map(item => item.count),
          borderColor: DASHBOARD_COLORS.black,
          backgroundColor: 'rgba(245, 197, 24, 0.18)',
          borderWidth: 3,
          fill: true,
          tension: 0.4,
          pointBackgroundColor: DASHBOARD_COLORS.yellow,
          pointBorderColor: '#fff',
          pointBorderWidth: 2,
          pointRadius: 5,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: LEGEND_DEFAULTS, tooltip: TOOLTIP_DEFAULTS },
      scales: { y: { beginAtZero: true, ticks: { stepSize: 1 } } },
    },
  };
}

/** "Distribución por estado": la API siempre trae los tres estados, en orden. */
export function statusChartConfig(data: GoldenDashboard): ChartConfiguration<'doughnut'> {
  const items = data.statusDistribution;

  return {
    type: 'doughnut',
    data: {
      labels: items.map(item => item.status),
      datasets: [
        {
          label: 'Estado',
          data: items.map(item => item.count),
          backgroundColor: items.map(item => STATUS_COLORS[item.status]),
          borderColor: '#fff',
          borderWidth: 2,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: LEGEND_DEFAULTS, tooltip: TOOLTIP_DEFAULTS },
    },
  };
}

/** "Reconocimientos por categoría": barras horizontales, de mayor a menor (así llegan de la API). */
export function categoryChartConfig(data: GoldenDashboard): ChartConfiguration<'bar'> {
  const items = data.recognitionsByCategory;

  return {
    type: 'bar',
    data: {
      labels: items.map(item => item.name),
      datasets: [
        {
          label: 'Reconocimientos por categoría',
          data: items.map(item => item.count),
          // La paleta dorada de siempre. Para usar el color de cada categoría: items.map(item => item.color).
          backgroundColor: items.map((_, index) => CATEGORY_PALETTE[index % CATEGORY_PALETTE.length]),
          borderRadius: 8,
        },
      ],
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: LEGEND_DEFAULTS, tooltip: TOOLTIP_DEFAULTS },
      scales: { x: { beginAtZero: true, ticks: { stepSize: 1 } } },
    },
  };
}

/** "Puntos asignados": barras apiladas por mes, de reconocimientos (negro) y asignaciones directas (dorado). */
export function pointsChartConfig(data: GoldenDashboard): ChartConfiguration<'bar'> {
  const months = data.pointsByMonth;

  return {
    type: 'bar',
    data: {
      labels: months.map(item => monthLabel(item.month)),
      datasets: [
        {
          label: 'Reconocimientos',
          data: months.map(item => item.recognitionPoints),
          backgroundColor: DASHBOARD_COLORS.black,
          borderRadius: 8,
          stack: 'points',
        },
        {
          label: 'Asignaciones',
          data: months.map(item => item.manualPoints),
          backgroundColor: DASHBOARD_COLORS.yellow,
          borderRadius: 8,
          stack: 'points',
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: LEGEND_DEFAULTS, tooltip: TOOLTIP_DEFAULTS },
      scales: { x: { stacked: true }, y: { stacked: true, beginAtZero: true } },
    },
  };
}
```

> **Lo que se va con los datos de prueba:** la tendencia de hoy inventaba valores cuando un mes daba 0 (`count || monthIndex + 1`). Con la API, un mes sin reconocimientos se ve en 0.
>
> `Chart.register(...)` se queda en el componente: registra los mismos controladores que usan estas configuraciones (línea, barra, dona, `Filler`, `Legend`, `Tooltip`).

---

## 7. Paso 5 — Aprobaciones en `puntos-dorados-admin.component` ✏️

### `.ts` — imports

```ts
import { PagedList } from '../../application/paged-list';
import {
  GOLDEN_APPROVAL_MAX_POINTS,
  GoldenApprovalItem,
  GoldenNominationStatus,
  GoldenResult,
  // … los que ya importa (GoldenBulkApprovalRow, GoldenDashboardKpi, GoldenNomination…)
} from '../../domain/puntos-dorados';
```

Y fuera de la clase, junto a `type AdminTab`:

```ts
type ApprovalAction = 'approve' | 'reject' | 'adjust';

/** La confirmación abierta en una tarjeta. */
interface ApprovalConfirm {
  id: number;
  action: ApprovalAction;
  points: number | null;
}
```

### `.ts` — estado

**Reemplaza** estas dos declaraciones:

```ts
nominations = signal<GoldenNomination[]>([]);
approvalPointsMap = signal<{ [key: number]: number }>({});
```

por:

```ts
// ── Aprobaciones (API) ───────────────────────────────────────────────
readonly approvalMaxPoints = GOLDEN_APPROVAL_MAX_POINTS;

readonly approvalStatusFilters: readonly { value: GoldenNominationStatus | null; label: string }[] = [
  { value: null, label: 'Todos' },
  { value: 'Pendiente', label: 'Pendientes' },
  { value: 'Aprobada', label: 'Aprobadas' },
  { value: 'Rechazada', label: 'Rechazadas' },
];

/** null = todos. La API pone los pendientes primero, el más antiguo arriba. */
readonly approvalStatusFilter = signal<GoldenNominationStatus | null>(null);

readonly approvals = new PagedList<GoldenApprovalItem>(
  (page, pageSize) => this.facade.getRecognitionApprovals({ page, pageSize, status: this.approvalStatusFilter() }),
  item => item.id,
  12,
);

/** Las tarjetas de la API. La plantilla y pendingNominations siguen usando nominations(). */
readonly nominations = this.approvals.items;

/** Lo escrito en "Puntos a asignar" de cada tarjeta (texto del input). */
private readonly approvalPointsDraft = signal<Record<number, string>>({});
readonly approvalConfirm = signal<ApprovalConfirm | null>(null);
readonly approvalComment = signal('');
readonly approvalSavingId = signal<number | null>(null);
readonly approvalErrors = signal<Record<number, string[]>>({});
```

> `approvals` va **después** de `facade` (ya está arriba de todo) y **antes** de `nominations`, porque `nominations` lo usa.

### `.ts` — métodos

**Reemplaza** `approveNomination`, `rejectNomination`, `updateApprovedPoints`, `updateApprovalPoints` y `getApprovalPoints` por estos (mismos nombres y parámetros que usa la plantilla), y **borra** `refreshNominations` y `syncApprovalPointsFromNominations`:

```ts
setApprovalStatusFilter(value: GoldenNominationStatus | null): void {
  if (this.approvalStatusFilter() === value) {
    return;
  }

  this.approvalStatusFilter.set(value);
  this.approvalConfirm.set(null);
  void this.approvals.reload();
}

reloadApprovals(): void {
  this.approvalConfirm.set(null);
  this.approvalErrors.set({});
  void this.approvals.reload();
}

/** Lo que muestra el input: lo escrito, o los puntos actuales. Vacío = sin puntos (antes eran 100 por defecto). */
getApprovalPoints(nominationId: number): string {
  const draft = this.approvalPointsDraft()[nominationId];
  if (draft !== undefined) {
    return draft;
  }

  const item = this.approvals.items().find(nomination => nomination.id === nominationId);
  return item?.pointsAssigned != null ? String(item.pointsAssigned) : '';
}

updateApprovalPoints(nominationId: number, value: string): void {
  this.approvalPointsDraft.update(drafts => ({ ...drafts, [nominationId]: value }));
  this.clearApprovalErrors(nominationId);

  // Cambiar los puntos invalida una confirmación abierta (mostraba otro número).
  if (this.approvalConfirm()?.id === nominationId) {
    this.approvalConfirm.set(null);
  }
}

/** Los botones de la tarjeta ahora piden confirmación; confirmApproval es el que llama a la API. */
approveNomination(nominationId: number): void {
  this.askApproval(nominationId, 'approve');
}

rejectNomination(nominationId: number): void {
  this.askApproval(nominationId, 'reject');
}

updateApprovedPoints(nominationId: number): void {
  this.askApproval(nominationId, 'adjust');
}

cancelApproval(): void {
  this.approvalConfirm.set(null);
}

approvalConfirmText(item: GoldenApprovalItem): string {
  const confirm = this.approvalConfirm();
  if (!confirm) {
    return '';
  }

  const name = item.nominee.name;
  const format = (points: number) => points.toLocaleString('es-CO');

  switch (confirm.action) {
    case 'approve':
      return confirm.points
        ? `¿Aprobar y asignar ${format(confirm.points)} puntos a ${name}?`
        : `¿Aprobar sin puntos el reconocimiento a ${name}?`;
    case 'reject':
      return `¿Rechazar el reconocimiento a ${name}? Es definitivo.`;
    case 'adjust':
      return `¿Dejar en ${format(confirm.points ?? 0)} los puntos de este reconocimiento (hoy ${format(item.pointsAssigned ?? 0)})? La diferencia queda como ajuste en el historial de ${name}.`;
  }
}

async confirmApproval(item: GoldenApprovalItem): Promise<void> {
  const confirm = this.approvalConfirm();
  if (!confirm || confirm.id !== item.id || this.approvalSavingId() !== null) {
    return;
  }

  this.approvalSavingId.set(item.id);
  this.clearApprovalErrors(item.id);

  try {
    const comment = this.approvalComment().trim() || null;
    let result: GoldenResult<GoldenApprovalItem>;

    if (confirm.action === 'approve') {
      result = await this.facade.approveRecognition(item.id, { points: confirm.points, comment });
    } else if (confirm.action === 'reject') {
      result = await this.facade.rejectRecognition(item.id, comment);
    } else {
      result = await this.facade.adjustRecognitionPoints(item.id, confirm.points ?? 0);
    }

    this.approvalConfirm.set(null);

    if (result.hasError) {
      this.setApprovalErrors(item.id, result.errors);
      return;
    }

    // La API devuelve la tarjeta actualizada: se reemplaza sin recargar la lista.
    // (En una constante: dentro de la función, TypeScript ya no sabe que response no es null.)
    const updated = result.response;
    this.approvals.patch(item.id, () => updated);
    this.approvalPointsDraft.update(({ [item.id]: _removed, ...rest }) => rest);
  } finally {
    this.approvalSavingId.set(null);
  }
}

/** Primer clic: valida los puntos y abre la confirmación dentro de la tarjeta. */
private askApproval(nominationId: number, action: ApprovalAction): void {
  this.clearApprovalErrors(nominationId);
  let points: number | null = null;

  if (action !== 'reject') {
    const parsed = this.parseApprovalPoints(this.getApprovalPoints(nominationId));
    if (parsed === undefined) {
      this.setApprovalErrors(nominationId, [`Los puntos deben ser un número entero entre 0 y ${this.approvalMaxPoints.toLocaleString('es-CO')}.`]);
      return;
    }

    points = parsed;
  }

  this.approvalComment.set('');
  this.approvalConfirm.set({ id: nominationId, action, points });
}

/** null = vacío (sin puntos). undefined = no es un entero entre 0 y el máximo. */
private parseApprovalPoints(text: string): number | null | undefined {
  const value = text.trim();
  if (value === '') {
    return null;
  }

  if (!/^\d+$/.test(value)) {
    return undefined;
  }

  const points = Number(value);
  return points <= this.approvalMaxPoints ? points : undefined;
}

private setApprovalErrors(id: number, errors: string[]): void {
  this.approvalErrors.update(all => ({ ...all, [id]: errors }));
}

private clearApprovalErrors(id: number): void {
  this.approvalErrors.update(({ [id]: _removed, ...rest }) => rest);
}
```

> **Antes, el input arrancaba en 100.** `getApprovalPoints` devolvía `?? 100`, así que aprobar sin tocar el campo daba 100 puntos. Ahora un pendiente arranca **vacío** (sin puntos) y la confirmación dice cuántos se van a asignar.

### `.html` — pestaña Aprobaciones

El título y todo el bloque de **Carga masiva** se quedan igual. Reemplaza desde `@if (nominations().length === 0) {` hasta el cierre de su `@else { … }` por:

```html
<div class="approval-toolbar">
  <div class="approval-filters" role="group" aria-label="Filtrar por estado">
    @for (filter of approvalStatusFilters; track filter.label) {
      <button
        type="button"
        class="tab-btn"
        [class.active]="approvalStatusFilter() === filter.value"
        [attr.aria-pressed]="approvalStatusFilter() === filter.value"
        (click)="setApprovalStatusFilter(filter.value)">
        {{ filter.label }}
      </button>
    }
  </div>

  <div class="approval-toolbar-end">
    @if (approvals.loaded()) {
      <small>{{ approvals.totalCount() }} reconocimientos</small>
    }
    <button type="button" class="btn-secondary" [disabled]="approvals.loading()" (click)="reloadApprovals()">↻ Recargar</button>
  </div>
</div>

@if (approvals.error()) {
  <div class="bulk-summary" role="alert">
    <strong>{{ approvals.error() }}</strong>
    <button type="button" class="btn-secondary" (click)="reloadApprovals()">Reintentar</button>
  </div>
}

@if (approvals.isFirstLoad()) {
  <div class="empty-state">
    <p>Cargando reconocimientos…</p>
  </div>
} @else if (approvals.isEmpty()) {
  <div class="empty-state">
    <p>{{ approvalStatusFilter() === 'Pendiente' ? 'No hay reconocimientos pendientes.' : 'No hay reconocimientos para gestionar.' }}</p>
  </div>
} @else {
  <div class="cards-list" [class.is-loading]="approvals.loading()">
    @for (item of nominations(); track trackByNominationId($index, item)) {
      <article class="approval-card" [attr.aria-busy]="approvalSavingId() === item.id">
        <div class="approval-card-header">
          <div>
            <strong style="font-size: 1.1rem;">{{ item.nominee.name }}</strong>
            <small class="card-meta">
              <!-- La API envía el área vacía (User no tiene área): sin esto queda " · Reconocido por" -->
              @if (item.nominee.area) {
                {{ item.nominee.area }} ·
              }
              Reconocido por: {{ item.nominatedBy.name }}
            </small>
          </div>
          <span class="status" [class.approved]="item.status === 'Aprobada'" [class.rejected]="item.status === 'Rechazada'">
            {{ item.status }}
          </span>
        </div>

        <p class="approval-reason">{{ item.reason }}</p>

        <div class="approval-meta">
          <small>📅 Creado: {{ item.createdAt | date: 'dd/MM/yyyy' }}</small>
          @if (item.reviewedAt) {
            <small>
              {{ item.status === 'Rechazada' ? '❌ Rechazado' : '✅ Aprobado' }} el {{ item.reviewedAt | date: 'dd/MM/yyyy' }}
              @if (item.reviewedBy) {
                por {{ item.reviewedBy }}
              }
            </small>
          }
        </div>

        @if (item.canReview || item.canAdjustPoints) {
          <div class="approval-decision-row">
            <div class="approval-points-section">
              <label class="field-label" for="points-{{ item.id }}">Puntos a asignar</label>
              <input
                [id]="'points-' + item.id"
                type="number"
                class="field-input"
                min="0"
                [max]="approvalMaxPoints"
                step="1"
                placeholder="Sin puntos"
                [value]="getApprovalPoints(item.id)"
                [disabled]="approvalSavingId() === item.id"
                (input)="updateApprovalPoints(item.id, $any($event.target).value)"
                aria-label="Asignar puntos" />
            </div>

            @if (approvalConfirm()?.id !== item.id) {
              <div class="approval-actions">
                @if (item.canReview) {
                  <button type="button" class="btn-secondary" (click)="rejectNomination(item.id)">❌ Rechazar</button>
                  <button type="button" class="btn-primary" (click)="approveNomination(item.id)">✅ Aprobar</button>
                } @else {
                  <button type="button" class="btn-primary" (click)="updateApprovedPoints(item.id)">Guardar ajuste</button>
                }
              </div>
            }
          </div>
        } @else {
          <div class="approval-status-summary rejected">
            <small>Estado final: solicitud rechazada.</small>
          </div>
        }

        @if (approvalConfirm()?.id === item.id) {
          <div class="approval-confirm" role="alertdialog" [attr.aria-label]="approvalConfirmText(item)">
            <p>{{ approvalConfirmText(item) }}</p>

            @if (approvalConfirm()?.action !== 'adjust') {
              <input
                class="field-input"
                maxlength="500"
                placeholder="Comentario (opcional)"
                [value]="approvalComment()"
                (input)="approvalComment.set($any($event.target).value)" />
            }

            <div class="approval-actions">
              <button type="button" class="btn-secondary" [disabled]="approvalSavingId() === item.id" (click)="cancelApproval()">Volver</button>
              <button type="button" class="btn-primary" [disabled]="approvalSavingId() === item.id" (click)="confirmApproval(item)">
                {{ approvalSavingId() === item.id ? 'Guardando…' : 'Confirmar' }}
              </button>
            </div>
          </div>
        }

        @if (item.reviewComment) {
          <p class="approval-comment">💬 {{ item.reviewComment }}</p>
        }

        @for (error of approvalErrors()[item.id] ?? []; track error) {
          <p class="approval-error" role="alert">{{ error }}</p>
        }
      </article>
    }
  </div>

  @if (approvals.hasMore()) {
    <button type="button" class="btn-secondary approval-load-more" [disabled]="approvals.loading()" (click)="approvals.loadMore()">
      {{ approvals.loading() ? 'Cargando…' : 'Cargar más' }}
    </button>
  }
}
```

**Qué cambió frente a la plantilla actual:**
- **Filtro por estado y Recargar:** en la barra de arriba.
- **Estados de la lista:** "Cargando", "vacío" y error; "Cargar más" abajo.
- **Área:** solo se muestra si viene (hoy llega vacía).
- **Revisión:** "Aprobado el … por …" en las tarjetas revisadas.
- **Botones:** dependen de `canReview` / `canAdjustPoints`, que manda la API, en lugar de comparar el estado.
- **Confirmación, comentario y errores:** dentro de la tarjeta.

### `.scss` — agrega al final

```scss
// ── Aprobaciones (API) ────────────────────────────────────────────────
.approval-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  margin: 1.25rem 0 1rem;
}

.approval-filters {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.approval-toolbar-end {
  display: flex;
  align-items: center;
  gap: 0.75rem;

  small {
    color: var(--bs-secondary-color, #6b7280);
  }
}

.cards-list.is-loading {
  opacity: 0.55;
  transition: opacity 0.2s ease;
}

.approval-card[aria-busy='true'] {
  opacity: 0.7;
}

.approval-confirm {
  display: grid;
  gap: 0.6rem;
  margin-top: 0.75rem;
  padding: 0.85rem;
  border: 1px solid color-mix(in srgb, var(--bs-warning, #e9c046) 55%, transparent);
  border-radius: 0.75rem;
  background: color-mix(in srgb, var(--bs-warning, #e9c046) 10%, transparent);

  p {
    margin: 0;
    font-weight: 600;
  }
}

.approval-comment {
  margin: 0.5rem 0 0;
  color: var(--bs-secondary-color, #6b7280);
  font-size: 0.85rem;
  font-style: italic;
}

.approval-error {
  margin: 0.5rem 0 0;
  color: var(--bs-danger, #dc3545);
  font-size: 0.85rem;
}

.approval-load-more {
  display: block;
  margin: 1.25rem auto 0;
}
```

> Los colores usan las variables de Bootstrap con un valor de respaldo. Si el SCSS del componente ya tiene sus propias variables (por ejemplo, para el dorado), usa esas.

---

## 8. Paso 6 — Dashboard en `puntos-dorados-admin.component` ✏️

### `.ts` — imports y arriba del archivo

1. **Borra** `CHART_FONT`, `DASHBOARD_COLORS`, `TOOLTIP_DEFAULTS` y `LEGEND_DEFAULTS`: ya están en `golden-dashboard-charts.ts`.
2. **Quita** `type ChartConfiguration` del import de `chart.js`. Se quedan `Chart` y lo que se registra con `Chart.register(...)`.
3. **Agrega:**

```ts
import { GoldenDashboard, GoldenDashboardFilters, GoldenDashboardKpiValue } from '../../domain/puntos-dorados';
import { toIsoDate } from '../../infraestructure/golden-api';
import { categoryChartConfig, pointsChartConfig, statusChartConfig, trendChartConfig } from './golden-dashboard-charts';
```

4. Al final del archivo, fuera de la clase:

```ts
/** Lo que pinta .kpi-trend: verde si subió; rojo si bajó (la plantilla lo detecta por la "↓"); "Nuevo" si antes era 0. */
function kpiTrend(kpi: GoldenDashboardKpiValue): string | undefined {
  if (kpi.changePercent === null) {
    return kpi.value > 0 ? 'Nuevo' : undefined;
  }

  if (kpi.changePercent > 0) {
    return `+${kpi.changePercent}%`;
  }

  if (kpi.changePercent < 0) {
    return `↓ ${Math.abs(kpi.changePercent)}%`;
  }

  return undefined; // 0 %: la plantilla muestra "sin variación"
}

/** El modal puede dar texto "yyyy-MM-dd" (input date) o Date: la API recibe "yyyy-MM-dd". */
function toApiDate(value: string | Date | null | undefined): string | null {
  if (!value) {
    return null;
  }

  return value instanceof Date ? toIsoDate(value) : value.slice(0, 10);
}

function isNominationStatus(value: string): value is GoldenNominationStatus {
  return value === 'Pendiente' || value === 'Aprobada' || value === 'Rechazada';
}
```

### `.ts` — estado

**Reemplaza** `dashboardKpis = signal<GoldenDashboardKpi[]>([]);` y `dashboardRecognitionCategoryOptions`, y **borra** `filteredDashboardNominations`:

```ts
// ── Dashboard (API) ──────────────────────────────────────────────────
readonly dashboardData = signal<GoldenDashboard | null>(null);
readonly dashboardLoading = signal(false);
readonly dashboardError = signal<string | null>(null);
private dashboardRequestId = 0;

/** Las mismas tarjetas de siempre ({ label, value, trend }), con datos de la API. */
readonly dashboardKpis = computed<GoldenDashboardKpi[]>(() => {
  const data = this.dashboardData();
  if (!data) {
    return [];
  }

  const filters = this.dashboardFilters();
  const hasRange = !!(filters.fromDate || filters.toDate);

  return [
    { label: hasRange ? 'Reconocimientos del período' : 'Reconocimientos del mes', kpi: data.kpis.recognitions },
    { label: 'Aprobaciones', kpi: data.kpis.approvals },
    { label: 'Puntos asignados', kpi: data.kpis.pointsAssigned },
    { label: 'Redenciones', kpi: data.kpis.redemptions },
  ].map(({ label, kpi }) => ({ label, value: kpi.value.toLocaleString('es-CO'), trend: kpiTrend(kpi) }));
});

/** Opciones del modal: las categorías reales (antes salían de los reconocimientos de prueba). */
dashboardRecognitionCategoryOptions = computed(() =>
  this.categories()
    .map(category => category.name)
    .sort((a, b) => a.localeCompare(b, 'es')),
);
```

> **Tipo `GoldenDashboardKpi`.** Si en tu dominio `value` es `number`, deja `value: kpi.value` y en la plantilla usa `{{ kpi.value | number }}`. Si `trend` no admite `undefined`, ajusta `kpiTrend` al tipo que tenga. Si el tipo tiene otros campos obligatorios, complétalos.

### `.ts` — en el constructor

Cambia el `effect` de las gráficas: ahora depende de `dashboardData()` (no de `nominations()` ni `dashboardKpis()`), y destruye las gráficas al salir de la pestaña. Agrega también la carga de la pestaña inicial:

```ts
constructor() {
  this.bootstrapUserContext();
  this.loadModuleData();
  this.loadAdminTabData(this.activeTab());

  // Redibuja las gráficas cuando llegan datos nuevos o se abre la pestaña.
  effect(() => {
    const activeTab = this.activeTab();
    this.dashboardData();

    if (!isPlatformBrowser(this.platformId)) {
      return;
    }

    if (activeTab !== 'dashboard') {
      // Los <canvas> ya no existen: no dejar gráficas colgando de ellos.
      this.destroyCharts();
      return;
    }

    // setTimeout: espera a que Angular pinte los <canvas> de la pestaña.
    setTimeout(() => this.renderDashboardCharts(), 0);
  });
}
```

### `.ts` — métodos

**Reemplaza** `applyDashboardFilters`, `clearDashboardFilters` y `renderDashboardCharts`, **borra** `buildRecognitionsTrendChart`, `buildStatusChart`, `buildCategoriesChart`, `buildPointsChart` y `getLastMonthsLabels`, y **agrega** `loadDashboard` y `toApiDashboardFilters`:

```ts
/** Consulta la API con los filtros actuales. Si se aplican filtros dos veces seguidas, solo cuenta la última respuesta. */
async loadDashboard(): Promise<void> {
  const request = ++this.dashboardRequestId;
  this.dashboardLoading.set(true);
  this.dashboardError.set(null);

  try {
    const result = await this.facade.getDashboard(this.toApiDashboardFilters(this.dashboardFilters()));

    if (request !== this.dashboardRequestId) {
      return;
    }

    if (result.hasError) {
      this.dashboardError.set(result.errors.join(' '));
      return;
    }

    // El effect del constructor redibuja las gráficas.
    this.dashboardData.set(result.response);
  } finally {
    if (request === this.dashboardRequestId) {
      this.dashboardLoading.set(false);
    }
  }
}

applyDashboardFilters(filters: FilterState): void {
  this.dashboardFilters.set({
    fromDate: filters.fromDate || null,
    toDate: filters.toDate || null,
    users: filters.users || [],
    jobTitles: filters.jobTitles || [],
    recognitionStatuses: filters.recognitionStatuses || [],
    recognitionCategories: filters.recognitionCategories || [],
  });
  this.showDashboardFilters.set(false);

  if (isPlatformBrowser(this.platformId)) {
    void this.loadDashboard();
  }
}

clearDashboardFilters(): void {
  this.dashboardFilters.set({
    fromDate: null,
    toDate: null,
    users: [],
    jobTitles: [],
    recognitionStatuses: [],
    recognitionCategories: [],
  });

  if (isPlatformBrowser(this.platformId)) {
    void this.loadDashboard();
  }
}

/** Traduce el FilterState del modal a los parámetros de la API. */
private toApiDashboardFilters(filters: FilterState): GoldenDashboardFilters {
  // El modal trabaja con nombres de categoría; la API, con ids.
  const categoryIds = (filters.recognitionCategories ?? [])
    .map(name => this.categories().find(category => category.name === name)?.id)
    .filter((id): id is number => typeof id === 'number');

  return {
    from: toApiDate(filters.fromDate),
    to: toApiDate(filters.toDate),
    userEmails: filters.users ?? [],                                   // el modal ya entrega correos
    statuses: (filters.recognitionStatuses ?? []).filter(isNominationStatus),
    categoryIds,
    // jobTitles no se envía: la API no filtra por cargo y el modal los oculta (showJobTitles = false).
  };
}

private renderDashboardCharts(): void {
  this.destroyCharts();

  const data = this.dashboardData();
  if (!data) {
    return;
  }

  if (this.recognitionsTrendCanvasRef?.nativeElement) {
    this.charts.push(new Chart(this.recognitionsTrendCanvasRef.nativeElement, trendChartConfig(data)));
  }
  if (this.statusCanvasRef?.nativeElement) {
    this.charts.push(new Chart(this.statusCanvasRef.nativeElement, statusChartConfig(data)));
  }
  if (this.categoriesCanvasRef?.nativeElement) {
    this.charts.push(new Chart(this.categoriesCanvasRef.nativeElement, categoryChartConfig(data)));
  }
  if (this.pointsCanvasRef?.nativeElement) {
    this.charts.push(new Chart(this.pointsCanvasRef.nativeElement, pointsChartConfig(data)));
  }
}
```

**Cómo se traduce cada filtro** (`FilterState` → API):

| `FilterState` | API | Cómo |
|---|---|---|
| `fromDate`, `toDate` | `from`, `to` | `yyyy-MM-dd`. `toApiDate` acepta texto o `Date`. |
| `users` | `userEmails` | Tal cual: `dashboardFilterUsers()` ya arma las opciones con el correo de cada persona. |
| `recognitionStatuses` | `statuses` | Tal cual (`Pendiente`, `Aprobada`, `Rechazada`); se descarta cualquier otro texto. |
| `recognitionCategories` | `categoryIds` | Son **nombres**: se busca el id en `categories()`. |
| `jobTitles` | — | No se envía. |

> ⚠️ **`categories()` debe venir de la API de categorías.** Los ids que se envían salen de ahí. Si `facade.getCategories()` todavía devuelve datos de prueba, esos ids no existen en `golden_recognition_category` y el filtro por categoría da todo en 0.

### `.html` — pestaña Dashboard

Lo demás se queda igual (KPI, `canvas`, botón de filtros y `app-dashboard-filters`). Hay que hacer tres cambios.

**1. El resumen de filtros activos.** `filteredDashboardNominations()` ya no existe. Cambia esa línea por:

```html
<span>Reconocimientos: {{ dashboardData()?.kpis?.recognitions?.value ?? 0 }}</span>
```

**2. Error y carga.** Justo antes de `<!-- KPIs -->`:

```html
@if (dashboardError()) {
  <div class="bulk-summary" role="alert">
    <strong>{{ dashboardError() }}</strong>
    <button type="button" class="btn-secondary" (click)="loadDashboard()">Reintentar</button>
  </div>
}
```

Y en los dos contenedores, para que se note mientras recarga:

```html
<div class="kpi-grid" [class.is-loading]="dashboardLoading()">
…
<div class="dashboard-grid top-gap" [class.is-loading]="dashboardLoading()">
```

**3. El subtítulo de "Puntos asignados".** Ahora es por mes y por origen:

```html
<p class="card-subtitle">Por mes: reconocimientos y asignaciones</p>
```

En el `.scss`:

```scss
.kpi-grid.is-loading,
.dashboard-grid.is-loading {
  opacity: 0.55;
  transition: opacity 0.2s ease;
}
```

---

## 9. Paso 7 — Carga por pestaña, carga inicial, carga masiva y exportar

### `setActiveTab` y `loadAdminTabData`

Cambia `setActiveTab`: en lugar de dibujar las gráficas (ahora lo hace el `effect`), carga los datos de la pestaña.

```ts
setActiveTab(tab: AdminTab): void {
  if (this.activeTab() === tab) {
    return;
  }

  this.activeTab.set(tab);

  if (!isPlatformBrowser(this.platformId)) {
    return;
  }

  this.loadAdminTabData(tab);

  requestAnimationFrame(() => {
    const contentWrapper = document.querySelector('.content-wrapper');
    if (contentWrapper instanceof HTMLElement) {
      contentWrapper.scrollTo({ top: 0, behavior: 'smooth' });
    }
  });
}

/** Carga los datos de la pestaña visible, solo en el navegador. */
private loadAdminTabData(tab: AdminTab): void {
  if (!isPlatformBrowser(this.platformId)) {
    return;
  }

  switch (tab) {
    case 'aprobaciones':
      void this.approvals.ensureLoaded();
      break;
    case 'dashboard':
      // Cada vez que se abre: son métricas "en tiempo real".
      void this.loadDashboard();
      break;
  }
}
```

### `loadModuleData`

Quita `getNominations()` y `getDashboardKpis()`: ahora cada pestaña carga lo suyo al abrirse.

```ts
private async loadModuleData(): Promise<void> {
  const [peopleResult, productsResult, categoriesResult, productCategoriesResult] = await Promise.all([
    this.facade.getPeople(),
    this.facade.getProducts(),
    this.facade.getCategories(),
    this.facade.getProductCategories(),
  ]);

  if (!peopleResult.hasError) {
    this.people.set(peopleResult.response);
    if (!this.userEmail() && peopleResult.response.length > 0) {
      this.userEmail.set(peopleResult.response[0].email);
      this.userName.set(peopleResult.response[0].name);
      this.userRole.set(peopleResult.response[0].role);
    }
  }

  if (!productsResult.hasError) {
    this.products.set(productsResult.response);
  }

  if (!categoriesResult.hasError) {
    this.categories.set(categoriesResult.response);
  }

  if (!productCategoriesResult.hasError) {
    this.productCategories.set(productCategoriesResult.response);
  }
}
```

> **Resto de los datos de prueba.** Si `userEmail` todavía está vacío, se usa la primera persona de `people` (nombre y correo en el encabezado). Es el mismo resto que tenía `currentUser` en el componente del colaborador. Aquí no afecta las aprobaciones, porque la API toma el usuario del token. Conviene quitarlo cuando `bootstrapUserContext` cargue siempre al usuario real.

### Carga masiva y exportar

> **Exportar** se conecta con [puntos-dorados-exportar-consolidado.md](puntos-dorados-exportar-consolidado.md). Si la implementas junto con esta guía, deshabilita solo "Procesar".

Hoy las dos usan métodos de prueba del facade (`processBulkApprovals` y `exportConsolidatedData`): la carga masiva diría "Aprobadas: N" sin aprobar nada real, y el consolidado sale con datos falsos. Hasta tener su API, deshabilita los botones:

```html
<!-- Carga masiva -->
<button type="button" class="btn-bulk-process" [disabled]="true" title="Próximamente">⚡ Procesar</button>

<!-- Dashboard -->
<button type="button" class="btn-primary" [disabled]="true" title="Próximamente">Exportar consolidado XLSX</button>
```

**Lo que sí se queda:**
- **La lectura del archivo** (`onBulkFileSelected`, `parseBulkApprovalXlsx`): servirá tal cual cuando exista el endpoint.
- **El armado del XLSX** en `exportConsolidatedXlsx`, con la librería `xlsx`. Cuando se haga la API del consolidado, basta con que devuelva las filas (con los mismos filtros del dashboard) y reemplazar `facade.exportConsolidatedData()`.

### Qué borrar

| Del componente | Por qué |
|---|---|
| `nominations = signal<GoldenNomination[]>([])`, `approvalPointsMap`, `refreshNominations`, `syncApprovalPointsFromNominations` | Los reemplaza el Paso 5. |
| `dashboardKpis = signal(...)`, `filteredDashboardNominations` | Los reemplazan `dashboardData` y el `computed` del Paso 6. |
| `buildRecognitionsTrendChart`, `buildStatusChart`, `buildCategoriesChart`, `buildPointsChart`, `getLastMonthsLabels` | Los reemplaza `golden-dashboard-charts.ts`. |
| `CHART_FONT`, `DASHBOARD_COLORS`, `TOOLTIP_DEFAULTS`, `LEGEND_DEFAULTS`, `type ChartConfiguration` | Se movieron a `golden-dashboard-charts.ts`. |
| La llamada a `renderDashboardCharts()` dentro de `setActiveTab` y los `setTimeout` de `applyDashboardFilters` / `clearDashboardFilters` | Las dibuja el `effect` cuando llegan los datos. Con las dos cosas, cada gráfica se dibujaría dos veces. |

**Se quedan:** los cuatro `@ViewChild` de los canvas, `charts`, `destroyCharts`, `ngOnDestroy`, `Chart.register(...)`, `dashboardFilters`, `dashboardFilterUsers`, `dashboardStatusOptions`, `dashboardStatusFilterLabel`, `dashboardCategoryFilterLabel`, `hasActiveDashboardFilters`, `pendingNominations` y `trackByNominationId`.

**En el facade**, con `grep -rn "<método>" src/app` antes de borrar cada uno:
- **Ya no los usa la administración:** `getNominations`, `approveNomination`, `rejectNomination`, `updateRecognitionPoints` y `getDashboardKpis`. Si nadie más los usa, se borran con sus datos de prueba.
- **Se quedan por ahora:** `processBulkApprovals` y `exportConsolidatedData`, hasta tener sus APIs.

> **Errores repetidos.** Si `HttpErrorHandlerService` muestra una alerta para los errores HTTP, las tarjetas y el dashboard también muestran `result.errors`. Revisa la observación 1 de [puntos-dorados-cambios-frontend.md](puntos-dorados-cambios-frontend.md).

---

## 10. Pruebas

**Aprobaciones**
- Al abrir la pestaña: los pendientes arriba, el más antiguo primero; después los revisados.
- Un pendiente arranca con "Puntos a asignar" **vacío** (antes, 100).
- "Pendientes" filtra; "Todos" vuelve a la lista completa.
- Una persona sin área: la tarjeta dice "Reconocido por: …" sin el " · " suelto.
- **✅ Aprobar con 150:**
  - Abre "¿Aprobar y asignar 150 puntos a …?" en la tarjeta. **Confirmar** la cambia a "Aprobada" sin recargar, con "✅ Aprobado el … por …" y "Guardar ajuste".
  - En la pestaña "Mis puntos" de esa persona aparece `+150`.
  - En el feed el reconocimiento sale **sin** puntos.
- **Aprobar con el campo vacío:** "¿Aprobar sin puntos…?".
- **❌ Rechazar con comentario:** "Estado final: solicitud rechazada." y el comentario debajo.
- **Guardar ajuste de 150 a 120:** la confirmación muestra los dos números; en "Mis puntos" aparece `Ajuste −30`.
- **Puntos `-5`, `1.5` o `200000`:** error en la tarjeta, sin llamar a la API.
- **Cambiar los puntos con la confirmación abierta:** la confirmación se cierra.
- **Dos pestañas del navegador:** aprobar en una y rechazar en la otra. La segunda muestra "ya fue aprobado…"; **↻ Recargar** trae el estado real.
- **Doble clic en "Confirmar":** una sola petición.
- **"Cargar más":** con más de 12 reconocimientos aparece y agrega los siguientes.

**Dashboard**
- **Al abrir:** cuatro KPI con su variación (verde, roja con "↓", "Nuevo" o "sin variación") y las cuatro gráficas con los mismos estilos de antes, pero con datos reales.
- **Ir a Catálogo y volver varias veces:** las gráficas se dibujan una sola vez y no aparece "Canvas is already in use" en la consola.
- **Filtro de fechas:** la tarjeta dice "Reconocimientos del período" y la tendencia cubre el rango.
- **Un colaborador:** las cifras bajan a las suyas.
- **Una categoría:** solo esa barra, y "Puntos asignados" sin las asignaciones manuales.
- **Opciones de categoría del modal:** son las de la pestaña Categorías, no las de los reconocimientos de prueba.
- **Aplicar dos filtros seguidos rápido:** se queda el resultado del último.
- **Un mes sin reconocimientos:** se ve en 0 (antes la gráfica inventaba un valor).
- **Aprobar un reconocimiento y volver al Dashboard:** "Aprobaciones" ya lo cuenta.
- **"Procesar" y "Exportar consolidado XLSX":** deshabilitados.

---

## ✅ Checklist

- [ ] APIs de aprobaciones y dashboard desplegadas.
- [ ] `golden-api.ts` con `parseDateOnly` y `toIsoDate` (Paso 2 de la guía de puntos).
- [ ] Tipos nuevos en el dominio (`GoldenDashboardKpiValue`, sin chocar con el `GoldenDashboardKpi` que ya existe).
- [ ] `golden-approvals.service.ts` y `golden-dashboard.service.ts` con `authHeaders()` y `catchError` copiados de `golden-recognitions.service.ts`.
- [ ] Cinco métodos nuevos en el facade con `runRecognitionRequest`.
- [ ] `golden-dashboard-charts.ts` con los estilos movidos desde el componente.
- [ ] Aprobaciones: `nominations` sale de `PagedList`; los métodos conservan su nombre; plantilla y SCSS actualizados.
- [ ] Dashboard: `dashboardKpis` como `computed`, `effect` que depende de `dashboardData`, `toApiDashboardFilters` con categorías por id.
- [ ] `categories()` viene de la API de categorías.
- [ ] `loadAdminTabData` en `setActiveTab` y en el constructor; `getNominations()` y `getDashboardKpis()` fuera de `loadModuleData`.
- [ ] "Procesar" y "Exportar consolidado XLSX" deshabilitados hasta tener API.
- [ ] Probado aprobar con dos pestañas abiertas, el doble clic y entrar y salir del dashboard varias veces.
