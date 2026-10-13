# 🎁 Puntos Dorados — Redimir en su propio componente y filtros con `select` (Angular)

Tres cambios en el módulo del colaborador (`PuntosDoradosUserComponent`):

| Qué | Resultado |
|---|---|
| **Redimir** | Pasa a su propio componente, `app-golden-redeem`, con una pantalla nueva: saldo real, "tu próxima meta", tarjetas con barra de progreso, filtros y confirmación del canje. |
| **Feed** | Filtros por **categoría**, **persona reconocida** y **período**. |
| **Todos los filtros son `<select>`** | Feed, Mis puntos (tipo y, nuevo, origen) y Redimir. Las guías pendientes de administración (Aprobaciones y Puntos) y el Catálogo también, en la sección 9. |

**Usa** las clases que ya tiene la pantalla de Redimir (`.redeem-filters-panel`, `.filter-field`, `.field-label`, `.field-input`, `.filter-actions`, `.btn-clear-filters`), que vienen de `puntos-dorados-shared.scss`. Así todos los filtros se ven igual.

**Requiere:**
- **Guía de puntos** ([puntos-dorados-puntos-angular.md](puntos-dorados-puntos-angular.md)): `getMyPointsSummary()` en el facade, `golden-api.ts` (`parseDateOnly`, `toIsoDate`) y `golden-request-id.ts` (`newRequestId`).
- **El catálogo disponible** (`facade.getAvailableProducts()`), que ya consulta la API de productos.
- **Para el feed:** un ajuste chico en la API de reconocimientos (sección 3).
- ⚠️ **Para canjear:** la API de redención **todavía no existe**. El frontend queda listo con su contrato (sección 10). Hasta que exista, "Confirmar canje" muestra un error.

---

## 1. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Redimir en su componente.** | Como "Mis puntos": `app-golden-redeem` tiene su estado, carga sus datos al abrirse y el componente del colaborador solo lo pinta. Se van de ese componente ocho signals, diez métodos y los datos de prueba de saldo y transacciones. |
| 2 | **Saldo real.** | Sale de `getMyPointsSummary()` (API de puntos). El de hoy (`facade.calculateBalance`) es de prueba. |
| 3 | **Filtros.** | Un `<select>` por filtro, con su etiqueta, y "Limpiar" solo cuando hay alguno activo. Las opciones se marcan con `[selected]` en cada `<option>`, no con `[value]` en el `<select>`: si las opciones llegan después (de la API), `[value]` no las marca. |
| 4 | **Puntos mínimos y máximos.** | Se cambian los dos campos numéricos por **rangos** en un select ("Hasta 100 pts", "101 a 300"…), en una constante que se ajusta al catálogo real. |
| 5 | **Lo que motiva a redimir.** | Cada premio muestra cuánto le falta a la persona (barra de progreso y "Te faltan 120 pts"). Arriba, "Te alcanza para N premios", "Tu próxima meta" (el más barato que aún no alcanza) y el aviso de los puntos por vencer. |
| 6 | **Orden "Recomendados".** | Primero lo que alcanza, del más valioso al menos (aprovecha el saldo); después lo que no alcanza, del que menos falta al que más. |
| 7 | **Canjear es gastar puntos.** | Un modal confirma con "Saldo actual 350 → Después del canje 50". Lleva un `requestId`: un doble clic o un reintento no canjea dos veces. Al terminar, se recargan el saldo y el catálogo (el stock cambió). |
| 8 | **Puntos por vencer.** | Si hay, el modal avisa que se usan **primero** los que vencen antes. Así lo hará la API (consume los lotes del más próximo a vencer). |
| 9 | **Historial.** | Sale de Redimir: ya está completo y con datos reales en "Mis puntos". En su lugar hay un enlace "Ver mi historial de puntos" que cambia de pestaña. |
| 10 | **Filtros del feed en la API.** | El feed es paginado en el servidor. Filtrar en el navegador solo filtraría la página cargada: los filtros se envían a la API. |
| 11 | **Período del feed.** | Por **fecha de aprobación** (la misma con la que se ordena el feed): "Este mes", "Últimos 3 meses" (este y los dos anteriores), "Este año". |

---

## 2. Archivos

```text
Backend (ajuste del feed)
├── Dtos/GoldenRecognitionDtos.cs                               ✏️ GoldenRecognitionPageQueryDto + 2 campos
├── Contracts/Persistence/IGoldenRecognitionQueryRepository.cs  ✏️ GetFeedPageAsync con 2 filtros más
├── Repositories/GoldenRecognitionQueryRepository.cs            ✏️
└── Services/GoldenRecognitionService.cs                        ✏️ GetFeedAsync

src/app/features/puntos-dorados/
├── domain/puntos-dorados.ts                                    ✏️ filtros, rangos, canje
├── infraestructure/
│   ├── golden-recognitions.mapper.ts                           ✏️ + pointsExpiresAt
│   ├── golden-recognitions.service.ts                          ✏️ getFeed con filtros
│   ├── golden-redemptions.mapper.ts                            nuevo
│   └── golden-redemptions.service.ts                           nuevo
├── application/puntos-dorados.fecade.ts                        ✏️ getRecognitionFeed con filtros, redeemProduct real
└── presentation/user/
    ├── redeem/                                                 nuevo ⭐ pestaña "Redimir"
    │   ├── redeem.component.ts
    │   ├── redeem.component.html
    │   └── redeem.component.scss
    ├── my-points/my-points.component.*                         ✏️ filtros con select (tipo y origen)
    └── puntos-dorados-user.component.*                         ✏️ filtros del feed, app-golden-redeem, limpieza
```

---

## 3. Paso 1 — Ajuste en la API del feed (backend)

El feed acepta hoy `categoryId`. Se agregan `nomineeEmail` (persona reconocida) y `from` (aprobados desde esa fecha).

### `Dtos/GoldenRecognitionDtos.cs` ✏️ — en `GoldenRecognitionPageQueryDto`

```csharp
/// <summary>Solo en el feed: reconocimientos que recibió esta persona.</summary>
public string? NomineeEmail { get; set; }

/// <summary>Solo en el feed: aprobados desde esta fecha (yyyy-MM-dd, día de Colombia).</summary>
public DateOnly? From { get; set; }
```

### `IGoldenRecognitionQueryRepository.cs` ✏️ — cambia la firma

```csharp
/// <summary>Aprobados y públicos; aprobados más recientes primero. Filtros opcionales.</summary>
Task<GoldenRecognitionPage> GetFeedPageAsync(int? categoryId, int? nomineeUserId, DateTime? approvedFromUtc, int page, int pageSize);
```

### `GoldenRecognitionQueryRepository.cs` ✏️

```csharp
public Task<GoldenRecognitionPage> GetFeedPageAsync(int? categoryId, int? nomineeUserId, DateTime? approvedFromUtc, int page, int pageSize)
{
    var query = _dbSet
        .AsNoTracking()
        .Where(r => r.Status == GoldenRecognitionStatus.Approved && r.Visibility == GoldenRecognitionVisibility.Public);

    if (categoryId is { } id)
    {
        query = query.Where(r => r.CategoryId == id);
    }

    if (nomineeUserId is { } nominee)
    {
        query = query.Where(r => r.NomineeUserId == nominee);
    }

    if (approvedFromUtc is { } fromUtc)
    {
        query = query.Where(r => r.ReviewedDate >= fromUtc);
    }

    // Usa ix_golden_recognition_feed. Lo recién aprobado arriba.
    return PageAsync(query.OrderByDescending(r => r.ReviewedDate).ThenByDescending(r => r.Id), page, pageSize);
}
```

### `GoldenRecognitionService.GetFeedAsync` ✏️

Reemplaza la línea de `GetFeedPageAsync` por:

```csharp
var (page, pageSize) = GoldenRecognitionValidator.Paging(query);

// Persona: por correo, como el resto del frontend. Si no existe, página vacía (no "todos").
int? nomineeUserId = null;
var nomineeEmail = query.NomineeEmail?.Trim().ToLowerInvariant();
if (!string.IsNullOrEmpty(nomineeEmail))
{
    nomineeUserId = await _queryRepository.GetUserIdByEmailAsync(nomineeEmail);
    if (nomineeUserId is null)
    {
        return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(Enumerable.Empty<GoldenRecognitionFeedItemDto>(), page, pageSize, 0));
    }
}

// Período: desde las 00:00 de ese día en Colombia, en UTC (reviewed_date se guarda en UTC).
DateTime? approvedFromUtc = query.From is { } from ? GoldenClock.StartOfDayUtc(from) : null;

var result = await _queryRepository.GetFeedPageAsync(query.CategoryId, nomineeUserId, approvedFromUtc, page, pageSize);
```

> `GoldenClock.StartOfDayUtc` está en la [guía del dashboard](puntos-dorados-dashboard-api.md) (Paso 2). Si todavía no la tienes: `from.ToDateTime(TimeOnly.MinValue).AddHours(5)`.
>
> El controlador no cambia: `[FromQuery] GoldenRecognitionPageQueryDto` ya recibe los dos campos nuevos.

---

## 4. Paso 2 — Dominio (`domain/puntos-dorados.ts`) ✏️

```ts
// ── En GoldenNomination, agrega (opcional) ───────────────────────────
//   pointsExpiresAt?: Date | null;   // solo en "Mis reconocimientos"

// ── Feed ─────────────────────────────────────────────────────────────
export type GoldenFeedPeriod = 'all' | 'month' | 'quarter' | 'year';

/** Lo que el usuario eligió en los filtros del feed. */
export interface GoldenFeedFilters {
  categoryId: number | null;
  nomineeEmail: string | null;
  period: GoldenFeedPeriod;
}

/** Lo que se envía a la API. */
export interface GoldenFeedQuery {
  categoryId?: number | null;
  nomineeEmail?: string | null;
  /** yyyy-MM-dd */
  from?: string | null;
}

// ── Catálogo ─────────────────────────────────────────────────────────
/** Rangos del filtro de puntos (en lugar de mínimo y máximo escritos a mano). Ajusta los cortes a tu catálogo. */
export const GOLDEN_POINT_RANGES: readonly { value: string; label: string; min: number | null; max: number | null }[] = [
  { value: '', label: 'Todos los puntos', min: null, max: null },
  { value: '0-100', label: 'Hasta 100 pts', min: 0, max: 100 },
  { value: '101-300', label: '101 a 300 pts', min: 101, max: 300 },
  { value: '301-600', label: '301 a 600 pts', min: 301, max: 600 },
  { value: '601-', label: 'Más de 600 pts', min: 601, max: null },
];

// ── Canje ────────────────────────────────────────────────────────────
export interface RedeemGoldenProduct {
  productId: number;
  /** GUID: un doble clic o un reintento no canjea dos veces. */
  requestId: string;
}

export interface GoldenRedemptionReceipt {
  redemptionId: number;
  productId: number;
  productName: string;
  points: number;
  balanceAfter: number;
  createdAt: Date;
}
```

---

## 5. Paso 3 — Infraestructura y facade

### `infraestructure/golden-recognitions.service.ts` ✏️ — `getFeed`

Cambia la firma y los parámetros; lo demás del método (`authHeaders`, `map`, `catchError`) queda igual:

```ts
async getFeed(page: number, pageSize: number, query: GoldenFeedQuery = {}): Promise<Observable<GoldenResult<GoldenPagedResult<GoldenFeedItem>>>> {
  const headers = await this.authHeaders();
  let params = new HttpParams().set('page', page).set('pageSize', pageSize);

  if (query.categoryId) {
    params = params.set('categoryId', query.categoryId);
  }

  if (query.nomineeEmail) {
    params = params.set('nomineeEmail', query.nomineeEmail);
  }

  if (query.from) {
    params = params.set('from', query.from);
  }

  return this.http
    .get<GoldenResultDto<GoldenPagedResultDto<GoldenFeedItemDto>>>(`${this.baseUrl}/feed`, { headers, params })
    .pipe(
      map(dto => toResult(dto, pageDto => toPage(pageDto, toFeedItem))),
      catchError(error => /* el mismo manejo de errores que ya tiene */ this.handleError(error)),
    );
}
```

### `infraestructure/golden-recognitions.mapper.ts` ✏️ — vencimiento en "Mis reconocimientos"

Si ya hiciste el Paso 7 de la [API de aprobaciones](puntos-dorados-aprobaciones-api.md), `received` trae `pointsExpiresAt`. Agrégalo:

```ts
// En GoldenRecognitionDto:
//   pointsExpiresAt?: string | null;

// En toNomination, al final del objeto:
//   pointsExpiresAt: dto.pointsExpiresAt ? parseDateOnly(dto.pointsExpiresAt) : null,
```

Es una fecha **sin hora**: `parseDateOnly`, no `parseUtc`; si no, se corre un día.

### `infraestructure/golden-redemptions.mapper.ts` (nuevo)

```ts
import { GoldenRedemptionReceipt } from '../domain/puntos-dorados';
import { parseUtc } from './golden-api';

export interface GoldenRedemptionReceiptDto {
  redemptionId: number;
  productId: number;
  productName: string;
  points: number;
  balanceAfter: number;
  createdAt: string;
}

export function toRedemptionReceipt(dto: GoldenRedemptionReceiptDto): GoldenRedemptionReceipt {
  return { ...dto, createdAt: parseUtc(dto.createdAt) };
}
```

### `infraestructure/golden-redemptions.service.ts` (nuevo)

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { Observable, catchError, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';          // ⬅ mismos imports que golden-recognitions.service.ts
import { AuthService } from '@core/services/auth-msal.service';             // ⬅ ruta real
import { HttpErrorHandlerService } from '@core/services/http-error-handler.service'; // ⬅ ruta real
import { GoldenRedemptionReceipt, GoldenResult, RedeemGoldenProduct } from '../domain/puntos-dorados';
import { GoldenResultDto, toResult } from './golden-api';
import { GoldenRedemptionReceiptDto, toRedemptionReceipt } from './golden-redemptions.mapper';

@Injectable({ providedIn: 'root' })
export class GoldenRedemptionsService {
  private readonly http = inject(HttpClient);
  private readonly authService = inject(AuthService);
  private readonly httpErrorHandler = inject(HttpErrorHandlerService);
  private readonly baseUrl = `${environment.api.baseUrl}/api/GoldenRedemptions`;

  async redeem(request: RedeemGoldenProduct): Promise<Observable<GoldenResult<GoldenRedemptionReceipt>>> {
    const headers = await this.authHeaders();

    return this.http
      .post<GoldenResultDto<GoldenRedemptionReceiptDto>>(this.baseUrl, request, { headers })
      .pipe(
        map(dto => toResult(dto, toRedemptionReceipt)),
        catchError(error => this.handleError(error)),
      );
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

### `application/puntos-dorados.fecade.ts` ✏️

```ts
private readonly redemptions = inject(GoldenRedemptionsService);

/** Antes: (page, pageSize, categoryId?). Ahora recibe todos los filtros del feed. */
getRecognitionFeed(page: number, pageSize: number, query: GoldenFeedQuery = {}): Promise<GoldenResult<GoldenPagedResult<GoldenFeedItem>>> {
  return this.runRecognitionRequest(() => this.recognitions.getFeed(page, pageSize, query), 'No se pudo cargar el feed de reconocimientos.');
}

/** Reemplaza el redeemProduct(email, productId) de prueba. El usuario sale del token en la API. */
redeemProduct(request: RedeemGoldenProduct): Promise<GoldenResult<GoldenRedemptionReceipt>> {
  return this.runRecognitionRequest(() => this.redemptions.redeem(request), 'No se pudo completar el canje. Intenta de nuevo: no se descontará dos veces.');
}
```

---

## 6. Paso 4 — `presentation/user/redeem/` ⭐ (nuevo)

### Diseño

```text
┌ SALDO DISPONIBLE ─────────────────────┐  🎁 Te alcanza para 4 premios
│ 350 puntos                            │  ⏰ 50 pts vencen el 7 de abril: úsalos primero
└───────────────────────────────────────┘  Ver mi historial de puntos →
┌ [img] TU PRÓXIMA META  Kit de bienestar ───────────────────────────┐
│       ███████████████░░░░  Te faltan 50 pts (88 %)                  │
└─────────────────────────────────────────────────────────────────────┘
[Categoría ▾] [Puntos ▾] [Mostrar ▾] [Ordenar ▾]  [Limpiar]     6 de 9 premios
┌ img ─────────── Bienestar ┐ ┌ img ──── ¡Últimas 2! ┐ ┌ img ───────────────┐
│ Día libre adicional       │ │ Audífonos            │ │ Kit de bienestar   │
│ 300 pts                   │ │ 200 pts              │ │ 400 pts            │
│ ████████████ ✓ Te alcanza │ │ ███████ ✓ Te alcanza │ │ █████████░ Faltan 50│
│ [ Redimir ]               │ │ [ Redimir ]          │ │ [Aún no te alcanza]│
└───────────────────────────┘ └──────────────────────┘ └────────────────────┘

   ┌ Confirmar canje ────────────────────────┐
   │ [img] Día libre adicional                │
   │ Costo                          300 pts   │
   │ Saldo actual                   350 pts   │
   │ Saldo después del canje         50 pts   │
   │ ⏰ Se usan primero los que vencen antes.  │
   │               [Cancelar] [Confirmar canje]│
   └──────────────────────────────────────────┘
```

### `redeem.component.ts`

```ts
import { ChangeDetectionStrategy, Component, PLATFORM_ID, computed, inject, output, signal } from '@angular/core';
import { DatePipe, DecimalPipe, isPlatformBrowser } from '@angular/common';
import { PuntosDoradosFacade } from '../../../application/puntos-dorados.fecade';
import { newRequestId } from '../../../application/golden-request-id';
import {
  GOLDEN_POINT_RANGES,
  GoldenPointsSummary,
  GoldenProduct,
  GoldenRedemptionReceipt,
} from '../../../domain/puntos-dorados';

type RedeemView = 'all' | 'affordable' | 'almost';
type RedeemSort = 'recommended' | 'asc' | 'desc' | 'name';

/** Un producto con lo que le falta a la persona para redimirlo. */
interface RedeemCard {
  product: GoldenProduct;
  cost: number;
  affordable: boolean;
  /** Puntos que faltan; 0 si alcanza. */
  missing: number;
  /** Saldo / costo, de 0 a 100. */
  progress: number;
  lowStock: boolean;
}

@Component({
  selector: 'app-golden-redeem',
  standalone: true,
  imports: [DatePipe, DecimalPipe],
  templateUrl: './redeem.component.html',
  styleUrl: './redeem.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class GoldenRedeemComponent {
  private readonly facade = inject(PuntosDoradosFacade);

  /** El padre cambia a la pestaña "Mis puntos". */
  readonly openHistory = output<void>();

  readonly pointRanges = GOLDEN_POINT_RANGES;

  readonly viewOptions: readonly { value: RedeemView; label: string }[] = [
    { value: 'all', label: 'Todos los premios' },
    { value: 'affordable', label: 'Me alcanza' },
    { value: 'almost', label: 'Casi me alcanza' },
  ];

  readonly sortOptions: readonly { value: RedeemSort; label: string }[] = [
    { value: 'recommended', label: 'Recomendados' },
    { value: 'asc', label: 'Menos puntos primero' },
    { value: 'desc', label: 'Más puntos primero' },
    { value: 'name', label: 'Nombre (A–Z)' },
  ];

  // ── Datos ──────────────────────────────────────────────────────────
  readonly summary = signal<GoldenPointsSummary | null>(null);
  readonly products = signal<GoldenProduct[]>([]);
  readonly loading = signal(false);
  readonly loaded = signal(false);
  readonly errors = signal<string[]>([]);

  readonly balance = computed(() => this.summary()?.balance ?? 0);

  readonly cards = computed<RedeemCard[]>(() => {
    const balance = this.balance();
    return this.products().filter(isRedeemable).map(product => toCard(product, balance));
  });

  readonly affordableCount = computed(() => this.cards().filter(card => card.affordable).length);

  /** El premio que menos falta para alcanzar: la próxima meta. */
  readonly nextGoal = computed(
    () => [...this.cards()].filter(card => !card.affordable).sort((a, b) => a.missing - b.missing)[0] ?? null,
  );

  readonly categories = computed(() =>
    [...new Set(this.cards().map(card => card.product.category))].sort((a, b) => a.localeCompare(b, 'es')),
  );

  // ── Filtros (todos <select>) ───────────────────────────────────────
  readonly categoryFilter = signal('');
  readonly rangeFilter = signal('');
  readonly viewFilter = signal<RedeemView>('all');
  readonly sortOrder = signal<RedeemSort>('recommended');

  readonly hasFilters = computed(() => !!this.categoryFilter() || !!this.rangeFilter() || this.viewFilter() !== 'all');

  readonly visibleCards = computed(() => {
    const category = this.categoryFilter();
    const range = this.pointRanges.find(option => option.value === this.rangeFilter());
    const view = this.viewFilter();

    const filtered = this.cards().filter(card => {
      if (category && card.product.category !== category) {
        return false;
      }

      if (range?.min != null && card.cost < range.min) {
        return false;
      }

      if (range?.max != null && card.cost > range.max) {
        return false;
      }

      if (view === 'affordable' && !card.affordable) {
        return false;
      }

      // "Casi": no alcanza, pero ya tiene el 75 % o más.
      if (view === 'almost' && (card.affordable || card.progress < 75)) {
        return false;
      }

      return true;
    });

    return sortCards(filtered, this.sortOrder());
  });

  // ── Canje ──────────────────────────────────────────────────────────
  readonly selected = signal<RedeemCard | null>(null);
  readonly redeeming = signal(false);
  readonly redeemErrors = signal<string[]>([]);
  readonly receipt = signal<GoldenRedemptionReceipt | null>(null);

  /** Uno por canje: se conserva si se reintenta el mismo y cambia al abrir otro. */
  private requestId = '';

  constructor() {
    // Solo en el navegador: en SSR no hay token y la API respondería 401.
    if (isPlatformBrowser(inject(PLATFORM_ID))) {
      void this.load();
    }
  }

  /** Saldo y catálogo a la vez. */
  async load(): Promise<void> {
    this.loading.set(true);
    this.errors.set([]);

    try {
      const [summary, products] = await Promise.all([this.facade.getMyPointsSummary(), this.facade.getAvailableProducts()]);
      const errors: string[] = [];

      if (summary.hasError) {
        errors.push(...summary.errors);
      } else {
        this.summary.set(summary.response);
      }

      if (products.hasError) {
        errors.push(...products.errors);
      } else {
        this.products.set(products.response);
      }

      this.errors.set(errors);
      this.loaded.set(true);
    } finally {
      this.loading.set(false);
    }
  }

  // ── Filtros ────────────────────────────────────────────────────────

  setCategory(value: string): void {
    this.categoryFilter.set(value);
  }

  setRange(value: string): void {
    this.rangeFilter.set(this.pointRanges.some(option => option.value === value) ? value : '');
  }

  setView(value: string): void {
    this.viewFilter.set(this.viewOptions.find(option => option.value === value)?.value ?? 'all');
  }

  setSort(value: string): void {
    this.sortOrder.set(this.sortOptions.find(option => option.value === value)?.value ?? 'recommended');
  }

  clearFilters(): void {
    this.categoryFilter.set('');
    this.rangeFilter.set('');
    this.viewFilter.set('all');
  }

  // ── Canje ──────────────────────────────────────────────────────────

  openRedeem(card: RedeemCard): void {
    if (!card.affordable) {
      return;
    }

    this.selected.set(card);
    this.receipt.set(null);
    this.redeemErrors.set([]);
    this.requestId = newRequestId();
  }

  closeRedeem(): void {
    if (this.redeeming()) {
      return;
    }

    this.selected.set(null);
    this.receipt.set(null);
  }

  async confirmRedeem(): Promise<void> {
    const card = this.selected();
    if (!card || this.redeeming() || this.receipt()) {
      return;
    }

    this.redeeming.set(true);
    this.redeemErrors.set([]);

    try {
      // Si la red falla y se vuelve a confirmar, va el mismo requestId: la API no canjea dos veces.
      const result = await this.facade.redeemProduct({ productId: card.product.id, requestId: this.requestId });

      if (result.hasError) {
        this.redeemErrors.set(result.errors);
        return;
      }

      this.receipt.set(result.response);
      // Saldo nuevo y stock nuevo, sin cerrar el modal (muestra el comprobante).
      void this.load();
    } finally {
      this.redeeming.set(false);
    }
  }

  /** Imagen rota: se muestra el ícono de regalo en su lugar. */
  hideImage(event: Event): void {
    (event.target as HTMLImageElement).style.display = 'none';
  }
}

/** Se puede canjear con puntos: activo, con costo y con stock (null = sin control de stock). */
function isRedeemable(product: GoldenProduct): boolean {
  return product.status && (product.pointsCost ?? 0) > 0 && product.stock !== 0;
}

function toCard(product: GoldenProduct, balance: number): RedeemCard {
  const cost = product.pointsCost ?? 0;
  const missing = Math.max(0, cost - balance);

  return {
    product,
    cost,
    affordable: missing === 0,
    missing,
    progress: Math.min(100, Math.floor((balance / cost) * 100)),
    lowStock: product.stock != null && product.stock > 0 && product.stock < 5,
  };
}

function sortCards(cards: RedeemCard[], order: RedeemSort): RedeemCard[] {
  const sorted = [...cards];

  switch (order) {
    case 'asc':
      return sorted.sort((a, b) => a.cost - b.cost);
    case 'desc':
      return sorted.sort((a, b) => b.cost - a.cost);
    case 'name':
      return sorted.sort((a, b) => a.product.name.localeCompare(b.product.name, 'es'));
    default:
      // Recomendados: lo que alcanza primero (lo más valioso arriba); después lo que menos falta.
      return sorted.sort((a, b) => {
        if (a.affordable !== b.affordable) {
          return a.affordable ? -1 : 1;
        }

        return a.affordable ? b.cost - a.cost : a.missing - b.missing;
      });
  }
}
```

> **`GoldenProduct`.** Se usan `id`, `name`, `description`, `category`, `pointsCost`, `stock`, `imageUrl` y `status`, como en la pantalla actual. En la API, `stock` puede ser `null` (sin control de stock: siempre disponible) y `pointsCost` también (no se canjea con puntos). Por eso el `?? 0` y el `!== 0`.

### `redeem.component.html`

```html
<section class="panel rd" aria-labelledby="rd-title">
  <div class="panel-title">
    <h2 id="rd-title">Redimir puntos</h2>
    <p>Elige un premio y canjéalo con tus puntos disponibles.</p>
  </div>

  <!-- ── Saldo ──────────────────────────────────────────────────────── -->
  <div class="rd-hero">
    <div class="rd-hero__balance" aria-live="polite">
      <span class="rd-eyebrow">Saldo disponible</span>
      @if (summary(); as current) {
        <p class="rd-hero__value">{{ current.balance | number }} <span>puntos</span></p>
      } @else if (loading()) {
        <span class="rd-skeleton rd-skeleton--value" aria-hidden="true"></span>
      } @else {
        <p class="rd-hero__value">— <span>puntos</span></p>
      }
    </div>

    <ul class="rd-hero__facts">
      <li>
        <i class="fa-solid fa-gift" aria-hidden="true"></i>
        Te alcanza para <strong>{{ affordableCount() }}</strong> {{ affordableCount() === 1 ? 'premio' : 'premios' }}
      </li>
      @if (summary(); as current) {
        @if (current.expiringSoonPoints > 0 && current.nextExpirationDate) {
          <li class="is-warning">
            <i class="fa-regular fa-clock" aria-hidden="true"></i>
            <strong>{{ current.expiringSoonPoints | number }} pts</strong> vencen el
            {{ current.nextExpirationDate | date: "d 'de' MMMM" }}: úsalos primero
          </li>
        }
      }
      <li>
        <button type="button" class="rd-link" (click)="openHistory.emit()">Ver mi historial de puntos →</button>
      </li>
    </ul>
  </div>

  <!-- ── Próxima meta ───────────────────────────────────────────────── -->
  @if (nextGoal(); as goal) {
    <div class="rd-goal">
      <div class="rd-goal__media">
        @if (goal.product.imageUrl) {
          <img [src]="goal.product.imageUrl" [alt]="goal.product.name" (error)="hideImage($event)" />
        }
        <i class="fa-solid fa-gift" aria-hidden="true"></i>
      </div>
      <div class="rd-goal__body">
        <span class="rd-eyebrow">Tu próxima meta</span>
        <strong>{{ goal.product.name }}</strong>
        <div class="rd-progress" role="progressbar" [attr.aria-valuenow]="goal.progress" aria-valuemin="0" aria-valuemax="100"
          [attr.aria-label]="'Progreso hacia ' + goal.product.name">
          <span [style.width.%]="goal.progress"></span>
        </div>
        <small>Te faltan <strong>{{ goal.missing | number }} pts</strong> ({{ goal.progress }} %)</small>
      </div>
    </div>
  }

  <!-- ── Filtros ────────────────────────────────────────────────────── -->
  <div class="redeem-filters-panel">
    <div class="filter-field">
      <label class="field-label" for="rd-category">Categoría</label>
      <select id="rd-category" class="field-input" (change)="setCategory($any($event.target).value)">
        <option value="" [selected]="!categoryFilter()">Todas las categorías</option>
        @for (category of categories(); track category) {
          <option [value]="category" [selected]="categoryFilter() === category">{{ category }}</option>
        }
      </select>
    </div>

    <div class="filter-field">
      <label class="field-label" for="rd-range">Puntos</label>
      <select id="rd-range" class="field-input" (change)="setRange($any($event.target).value)">
        @for (range of pointRanges; track range.value) {
          <option [value]="range.value" [selected]="rangeFilter() === range.value">{{ range.label }}</option>
        }
      </select>
    </div>

    <div class="filter-field">
      <label class="field-label" for="rd-view">Mostrar</label>
      <select id="rd-view" class="field-input" (change)="setView($any($event.target).value)">
        @for (option of viewOptions; track option.value) {
          <option [value]="option.value" [selected]="viewFilter() === option.value">{{ option.label }}</option>
        }
      </select>
    </div>

    <div class="filter-field">
      <label class="field-label" for="rd-sort">Ordenar</label>
      <select id="rd-sort" class="field-input" (change)="setSort($any($event.target).value)">
        @for (option of sortOptions; track option.value) {
          <option [value]="option.value" [selected]="sortOrder() === option.value">{{ option.label }}</option>
        }
      </select>
    </div>

    @if (hasFilters()) {
      <div class="filter-actions">
        <button type="button" class="btn-clear-filters" (click)="clearFilters()">Limpiar</button>
      </div>
    }
  </div>

  @if (loaded() && cards().length) {
    <p class="rd-count" aria-live="polite">{{ visibleCards().length }} de {{ cards().length }} premios</p>
  }

  @if (errors().length) {
    <div class="alert alert-danger d-flex justify-content-between align-items-center gap-3" role="alert">
      {{ errors().join(' ') }}
      <button type="button" class="btn btn-sm btn-outline-danger" (click)="load()">Reintentar</button>
    </div>
  }

  <!-- ── Catálogo ───────────────────────────────────────────────────── -->
  <div class="rd-grid" [class.is-loading]="loading() && loaded()">
    @for (card of visibleCards(); track card.product.id) {
      <article class="rd-card" [class.is-affordable]="card.affordable">
        <div class="rd-card__media">
          @if (card.product.imageUrl) {
            <img [src]="card.product.imageUrl" [alt]="card.product.name" loading="lazy" (error)="hideImage($event)" />
          }
          <i class="fa-solid fa-gift" aria-hidden="true"></i>
          <span class="rd-card__category">{{ card.product.category }}</span>
          @if (card.lowStock) {
            <span class="rd-card__stock">¡{{ card.product.stock === 1 ? 'Última unidad' : 'Últimas ' + card.product.stock }}!</span>
          }
        </div>

        <div class="rd-card__body">
          <h3 class="rd-card__name">{{ card.product.name }}</h3>
          <p class="rd-card__description">{{ card.product.description }}</p>

          <p class="rd-card__cost"><strong>{{ card.cost | number }}</strong> pts</p>

          <div class="rd-progress" role="progressbar" [attr.aria-valuenow]="card.progress" aria-valuemin="0" aria-valuemax="100"
            [attr.aria-label]="'Tu saldo cubre el ' + card.progress + ' % de ' + card.product.name">
            <span [style.width.%]="card.progress"></span>
          </div>

          <small class="rd-card__hint" [class.is-ok]="card.affordable">
            @if (card.affordable) {
              <i class="fa-solid fa-circle-check" aria-hidden="true"></i> Te alcanza
            } @else {
              Te faltan {{ card.missing | number }} pts
            }
          </small>

          <button type="button" class="btn-primary rd-card__cta" [disabled]="!card.affordable" (click)="openRedeem(card)">
            {{ card.affordable ? 'Redimir' : 'Aún no te alcanza' }}
          </button>
        </div>
      </article>
    }

    @if (loading() && !loaded()) {
      @for (placeholder of [1, 2, 3]; track placeholder) {
        <div class="rd-card rd-card--skeleton" aria-hidden="true"><span></span><span></span><span></span></div>
      }
    }
  </div>

  @if (loaded() && !loading() && cards().length === 0 && !errors().length) {
    <div class="empty-state">
      <p>Por ahora no hay premios disponibles. ¡Vuelve pronto!</p>
    </div>
  } @else if (loaded() && cards().length > 0 && visibleCards().length === 0) {
    <div class="empty-state">
      <p>Ningún premio coincide con estos filtros.</p>
      <button type="button" class="btn-clear-filters" (click)="clearFilters()">Limpiar filtros</button>
    </div>
  }
</section>

<!-- ── Confirmar canje ────────────────────────────────────────────── -->
@if (selected(); as card) {
  <div class="rd-backdrop" (click)="closeRedeem()"></div>

  <section class="rd-modal" role="dialog" aria-modal="true" aria-labelledby="rd-modal-title" (keydown.escape)="closeRedeem()">
    @if (receipt(); as done) {
      <div class="rd-success">
        <span class="rd-success__icon"><i class="fa-solid fa-gift" aria-hidden="true"></i></span>
        <h2 id="rd-modal-title">¡Canje registrado!</h2>
        <p>Redimiste <strong>{{ done.productName }}</strong> por {{ done.points | number }} pts.</p>
        <p class="rd-success__balance">Tu nuevo saldo: <strong>{{ done.balanceAfter | number }} pts</strong></p>
        <button type="button" class="btn-primary" (click)="closeRedeem()">Listo</button>
      </div>
    } @else {
      <header class="rd-modal__head">
        <div class="rd-modal__media">
          @if (card.product.imageUrl) {
            <img [src]="card.product.imageUrl" [alt]="card.product.name" (error)="hideImage($event)" />
          }
          <i class="fa-solid fa-gift" aria-hidden="true"></i>
        </div>
        <div>
          <span class="rd-eyebrow">Confirmar canje</span>
          <h2 id="rd-modal-title" class="rd-modal__title">{{ card.product.name }}</h2>
        </div>
      </header>

      <dl class="rd-summary">
        <div><dt>Costo</dt><dd>{{ card.cost | number }} pts</dd></div>
        <div><dt>Saldo actual</dt><dd>{{ balance() | number }} pts</dd></div>
        <div class="is-total"><dt>Saldo después del canje</dt><dd>{{ balance() - card.cost | number }} pts</dd></div>
      </dl>

      @if (summary(); as current) {
        @if (current.expiringSoonPoints > 0) {
          <p class="rd-note">
            <i class="fa-regular fa-clock" aria-hidden="true"></i>
            Se usan primero los puntos que vencen antes ({{ current.expiringSoonPoints | number }} pts vencen pronto).
          </p>
        }
      }

      @for (error of redeemErrors(); track error) {
        <p class="rd-error" role="alert">{{ error }}</p>
      }

      <footer class="rd-modal__foot">
        <button type="button" class="btn-clear-filters" [disabled]="redeeming()" (click)="closeRedeem()">Cancelar</button>
        <button type="button" class="btn-primary" [disabled]="redeeming()" (click)="confirmRedeem()">
          {{ redeeming() ? 'Canjeando…' : 'Confirmar canje' }}
        </button>
      </footer>
    }
  </section>
}
```

### `redeem.component.scss`

```scss
@use '../../shared/puntos-dorados-shared.scss' as *;

:host {
  display: block;
}

.rd-eyebrow {
  display: block;
  color: var(--bs-warning);
  font-size: 0.7rem;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

// ── Saldo ─────────────────────────────────────────────────────────────
.rd-hero {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr);
  align-items: center;
  gap: 1.5rem;
  margin-bottom: 1rem;
  padding: 1.5rem 1.75rem;
  border: 1px solid color-mix(in srgb, var(--bs-warning) 35%, transparent);
  border-radius: 1.25rem;
  background:
    radial-gradient(120% 160% at 0% 0%, color-mix(in srgb, var(--bs-warning) 22%, transparent), transparent 60%),
    var(--bs-body-bg);

  @media (max-width: 767.98px) {
    grid-template-columns: 1fr;
  }
}

.rd-hero__value {
  margin: 0.25rem 0 0;
  font-size: 3rem;
  font-weight: 800;
  line-height: 1;

  span {
    color: var(--bs-secondary-color);
    font-size: 1rem;
    font-weight: 500;
  }
}

.rd-hero__facts {
  display: grid;
  gap: 0.5rem;
  margin: 0;
  padding: 0;
  list-style: none;

  li {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  i {
    width: 1.25rem;
    color: var(--bs-warning);
  }

  .is-warning {
    color: color-mix(in srgb, var(--bs-orange, #f59e0b) 80%, var(--bs-body-color));

    i {
      color: inherit;
    }
  }
}

.rd-link {
  padding: 0;
  border: 0;
  background: none;
  color: var(--bs-emphasis-color);
  font-weight: 600;
  text-decoration: underline;
  text-underline-offset: 3px;
}

// ── Próxima meta ──────────────────────────────────────────────────────
.rd-goal {
  display: flex;
  align-items: center;
  gap: 1rem;
  margin-bottom: 1.25rem;
  padding: 1rem 1.25rem;
  border: 1px dashed color-mix(in srgb, var(--bs-warning) 60%, transparent);
  border-radius: 1rem;
  background: color-mix(in srgb, var(--bs-warning) 6%, var(--bs-body-bg));
}

.rd-goal__media,
.rd-modal__media {
  position: relative;
  flex-shrink: 0;
  display: grid;
  place-items: center;
  width: 4rem;
  height: 4rem;
  overflow: hidden;
  border-radius: 0.75rem;
  background: var(--bs-tertiary-bg);
  color: var(--bs-warning);
  font-size: 1.5rem;

  img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.rd-goal__body {
  display: grid;
  flex: 1;
  gap: 0.3rem;
  min-width: 0;
}

// ── Barra de progreso ─────────────────────────────────────────────────
.rd-progress {
  height: 0.5rem;
  overflow: hidden;
  border-radius: 999px;
  background: var(--bs-tertiary-bg);

  span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: linear-gradient(90deg, var(--bs-warning), color-mix(in srgb, var(--bs-warning) 70%, var(--bs-orange, #f59e0b)));
    transition: width 0.4s ease;
  }
}

.rd-count {
  margin: 0.75rem 0;
  color: var(--bs-secondary-color);
  font-size: 0.85rem;
}

// ── Catálogo ──────────────────────────────────────────────────────────
.rd-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr));
  gap: 1rem;
  transition: opacity 0.2s ease;

  &.is-loading {
    opacity: 0.55;
  }
}

.rd-card {
  display: flex;
  flex-direction: column;
  overflow: hidden;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 1rem;
  background: var(--bs-body-bg);
  box-shadow: 0 4px 16px rgb(0 0 0 / 0.05);
  transition: transform 0.2s ease, box-shadow 0.2s ease, border-color 0.2s ease;

  &:hover {
    transform: translateY(-3px);
    box-shadow: 0 12px 28px rgb(0 0 0 / 0.1);
  }

  &.is-affordable {
    border-color: color-mix(in srgb, var(--bs-warning) 55%, transparent);
  }
}

.rd-card__media {
  position: relative;
  display: grid;
  place-items: center;
  aspect-ratio: 4 / 3;
  background: var(--bs-tertiary-bg);
  color: color-mix(in srgb, var(--bs-warning) 70%, transparent);
  font-size: 2.5rem;

  img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.rd-card__category,
.rd-card__stock {
  position: absolute;
  top: 0.75rem;
  padding: 0.2rem 0.6rem;
  border-radius: 999px;
  font-size: 0.72rem;
  font-weight: 700;
}

.rd-card__category {
  left: 0.75rem;
  background: rgb(255 255 255 / 0.9);
  color: var(--bs-dark);
}

.rd-card__stock {
  right: 0.75rem;
  background: var(--bs-danger);
  color: var(--bs-white);
}

.rd-card__body {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: 0.5rem;
  padding: 1rem 1.1rem 1.1rem;
}

.rd-card__name {
  margin: 0;
  font-size: 1.05rem;
  font-weight: 700;
}

.rd-card__description {
  display: -webkit-box;
  margin: 0;
  overflow: hidden;
  color: var(--bs-secondary-color);
  font-size: 0.85rem;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
}

.rd-card__cost {
  margin: auto 0 0;
  font-size: 0.9rem;

  strong {
    font-size: 1.5rem;
    font-weight: 800;
  }
}

.rd-card__hint {
  color: var(--bs-secondary-color);
  font-weight: 600;

  &.is-ok {
    color: var(--bs-success);
  }
}

.rd-card__cta {
  width: 100%;
  margin-top: 0.25rem;
}

.rd-card--skeleton {
  gap: 0.75rem;
  padding: 1rem;

  span {
    height: 1.25rem;
    border-radius: 0.5rem;
    background: var(--bs-tertiary-bg);
    animation: rd-pulse 1.2s ease-in-out infinite alternate;

    &:first-child {
      height: 9rem;
    }
  }
}

.rd-skeleton {
  display: block;
  border-radius: 0.5rem;
  background: var(--bs-tertiary-bg);
  animation: rd-pulse 1.2s ease-in-out infinite alternate;

  &--value {
    width: 10rem;
    height: 3rem;
    margin-top: 0.25rem;
  }
}

// ── Modal ─────────────────────────────────────────────────────────────
.rd-backdrop {
  position: fixed;
  inset: 0;
  z-index: 1050;
  background: rgb(0 0 0 / 0.4);
}

.rd-modal {
  position: fixed;
  top: 50%;
  left: 50%;
  z-index: 1055;
  display: grid;
  gap: 1rem;
  width: min(28rem, calc(100vw - 2rem));
  max-height: calc(100vh - 2rem);
  overflow-y: auto;
  padding: 1.5rem;
  border-radius: 1.25rem;
  background: var(--bs-body-bg);
  box-shadow: 0 24px 48px rgb(0 0 0 / 0.2);
  transform: translate(-50%, -50%);
  animation: rd-rise 0.2s ease-out both;
}

.rd-modal__head {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.rd-modal__title {
  margin: 0;
  font-size: 1.2rem;
  font-weight: 700;
}

.rd-summary {
  display: grid;
  gap: 0.5rem;
  margin: 0;
  padding: 1rem;
  border-radius: 0.9rem;
  background: var(--bs-tertiary-bg);

  div {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
  }

  dt {
    color: var(--bs-secondary-color);
    font-weight: 500;
  }

  dd {
    margin: 0;
    font-weight: 700;
  }

  .is-total {
    padding-top: 0.5rem;
    border-top: 1px dashed var(--bs-border-color);

    dd {
      color: var(--bs-emphasis-color);
      font-size: 1.15rem;
    }
  }
}

.rd-note {
  margin: 0;
  color: var(--bs-secondary-color);
  font-size: 0.85rem;
}

.rd-error {
  margin: 0;
  color: var(--bs-danger);
  font-size: 0.875rem;
}

.rd-modal__foot {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75rem;
}

.rd-success {
  display: grid;
  justify-items: center;
  gap: 0.5rem;
  text-align: center;

  h2 {
    margin: 0.5rem 0 0;
    font-size: 1.35rem;
    font-weight: 800;
  }

  p {
    margin: 0;
  }

  .btn-primary {
    margin-top: 0.75rem;
    min-width: 8rem;
  }
}

.rd-success__icon {
  display: grid;
  place-items: center;
  width: 4.5rem;
  height: 4.5rem;
  border-radius: 50%;
  background: var(--bs-warning);
  color: var(--bs-white);
  font-size: 1.9rem;
  animation: rd-pop 0.45s ease-out both;
}

.rd-success__balance {
  color: var(--bs-secondary-color);
}

@keyframes rd-rise {
  from {
    opacity: 0;
    transform: translate(-50%, calc(-50% + 8px));
  }
}

@keyframes rd-pop {
  0% { transform: scale(0.4); opacity: 0; }
  70% { transform: scale(1.12); opacity: 1; }
  100% { transform: scale(1); }
}

@keyframes rd-pulse {
  to { opacity: 0.5; }
}

@media (prefers-reduced-motion: reduce) {
  .rd-card,
  .rd-progress span,
  .rd-modal,
  .rd-success__icon,
  .rd-skeleton,
  .rd-card--skeleton span {
    animation: none;
    transition: none;
  }
}
```

> **`@use` de los estilos compartidos.** Trae `.panel`, `.panel-title`, `.redeem-filters-panel`, `.filter-field`, `.field-label`, `.field-input`, `.btn-primary`, `.btn-clear-filters` y `.empty-state`, que hoy usa la pestaña desde el componente del colaborador. Si alguno vive en los estilos globales, no hace falta nada más.

---

## 7. Paso 5 — `puntos-dorados-user.component` ✏️

### `.ts` — imports

```ts
import { GoldenRedeemComponent } from './redeem/redeem.component';
import { toIsoDate } from '../../infraestructure/golden-api';
import { GoldenFeedFilters, GoldenFeedPeriod, GoldenFeedQuery } from '../../domain/puntos-dorados';

// En imports del @Component: agrega GoldenRedeemComponent.
// Del import del dominio, quita lo que deja de usarse: GoldenPointsBucket, GoldenPointsTransaction, GoldenProduct, GoldenRedemption.
```

Y fuera de la clase, al final del archivo:

```ts
const DEFAULT_FEED_FILTERS: GoldenFeedFilters = { categoryId: null, nomineeEmail: null, period: 'all' };

/** Del filtro elegido a lo que se envía a la API. */
function toFeedQuery(filters: GoldenFeedFilters): GoldenFeedQuery {
  return {
    categoryId: filters.categoryId,
    nomineeEmail: filters.nomineeEmail,
    from: periodStart(filters.period),
  };
}

/** Primer día del período, en fecha local: "Últimos 3 meses" = este mes y los dos anteriores. */
function periodStart(period: GoldenFeedPeriod, today = new Date()): string | null {
  switch (period) {
    case 'month':
      return toIsoDate(new Date(today.getFullYear(), today.getMonth(), 1));
    case 'quarter':
      return toIsoDate(new Date(today.getFullYear(), today.getMonth() - 2, 1));
    case 'year':
      return toIsoDate(new Date(today.getFullYear(), 0, 1));
    default:
      return null;
  }
}
```

### `.ts` — feed con filtros

Cambia el `feed` y agrega el estado de los filtros:

```ts
readonly feedFilters = signal<GoldenFeedFilters>(DEFAULT_FEED_FILTERS);

readonly feed = new PagedList<GoldenFeedItem>(
  (page, pageSize) => this.facade.getRecognitionFeed(page, pageSize, toFeedQuery(this.feedFilters())),
  item => item.id,
);

readonly feedPeriods: readonly { value: GoldenFeedPeriod; label: string }[] = [
  { value: 'all', label: 'Siempre' },
  { value: 'month', label: 'Este mes' },
  { value: 'quarter', label: 'Últimos 3 meses' },
  { value: 'year', label: 'Este año' },
];

readonly hasFeedFilters = computed(() => {
  const filters = this.feedFilters();
  return filters.categoryId !== null || filters.nomineeEmail !== null || filters.period !== 'all';
});

/** Personas para el filtro, en orden alfabético. */
readonly feedPeople = computed(() => [...this.people()].sort((a, b) => a.name.localeCompare(b.name, 'es')));
```

> `feedFilters` va **antes** de `feed`, porque el `feed` lo lee.

Métodos:

```ts
setFeedCategory(value: string): void {
  const id = Number(value);
  this.updateFeedFilters({ categoryId: Number.isInteger(id) && id > 0 ? id : null });
}

setFeedPerson(value: string): void {
  this.updateFeedFilters({ nomineeEmail: value || null });
}

setFeedPeriod(value: string): void {
  this.updateFeedFilters({ period: this.feedPeriods.find(option => option.value === value)?.value ?? 'all' });
}

clearFeedFilters(): void {
  this.feedFilters.set(DEFAULT_FEED_FILTERS);
  void this.feed.reload();
}

/** Cada cambio de filtro vuelve a la primera página del feed. */
private updateFeedFilters(change: Partial<GoldenFeedFilters>): void {
  this.feedFilters.update(current => ({ ...current, ...change }));
  void this.feed.reload();
}
```

### `.ts` — categorías también para el feed

El filtro del feed necesita las categorías. Hoy solo se cargan al abrir "Reconocer". Renombra la bandera y el método, y úsalos en las dos pestañas:

```ts
/** Evita repetir la llamada a categorías: se cargan una vez (feed o reconocer). */
private categoriesLoaded = false;

private loadTabData(tab: UserTab): void {
  if (!isPlatformBrowser(this.platformId)) {
    return;
  }

  if (tab === 'feed') {
    void this.feed.ensureLoaded();
    this.ensureCategories();
  }

  if (tab === 'reconocer') {
    void this.sentRecognitions.ensureLoaded();
    this.ensureCategories();
  }

  if (tab === 'mis-reconocimientos') {
    void this.receivedRecognitions.ensureLoaded();
  }

  // 'mis-puntos' y 'redimir': sus componentes cargan sus datos al crearse.
}

private ensureCategories(): void {
  if (this.categoriesLoaded) {
    return;
  }

  this.categoriesLoaded = true;
  void this.loadCategories();
}

/** Categorías de reconocimiento: filtro del feed y selector del modal de "Reconocer". */
private async loadCategories(): Promise<void> {
  const response = await this.facade.getCategories();
  if (!response.hasError) {
    this.categories.set(response.response);
  }
}
```

> El filtro del feed muestra **todas** las categorías (`categories()`), también las inactivas: el feed puede tener reconocimientos aprobados antes de que se inactivaran. El modal de "Reconocer" sigue usando `activeCategories()`.

### `.ts` — lo que se va (lo tiene `app-golden-redeem`)

| Borrar | Por qué |
|---|---|
| `products`, `transactions`, `redemptions`, `pointsBuckets`, `expiringPoints` | Datos de Redimir; los de puntos eran de prueba. |
| `redeemCategoryFilter`, `redeemMinPointsFilter`, `redeemMaxPointsFilter`, `redeemSortOrder`, `redeemTabLoaded` | Filtros de Redimir. |
| `pointsBalance`, `redeemFilterCategories`, `filteredRedeemProducts` | Ahora en `app-golden-redeem`, con el saldo real. |
| `redeemSelectedProduct`, `setRedeemCategoryFilter`, `setRedeemMinPoints`, `setRedeemMaxPoints`, `clearRedeemFilters`, `setRedeemSortOrder`, `trackByProductId`, `trackByTransactionId` | Ídem. |
| `loadRedeemTabData`, `refreshProducts`, `refreshUserFinancialData` | Ídem. Quita también sus llamadas: `this.refreshUserFinancialData()` en `bootstrapUserContext` y `await this.refreshUserFinancialData()` en `loadModuleData`. |
| `recognizeTabLoaded`, `loadRecognizeTabData` | Los reemplazan `categoriesLoaded`, `ensureCategories` y `loadCategories`. |
| `getRecognitionExpirationDate` | Buscaba en lotes de prueba con un formato que la API no usa. Ahora la fecha viene en cada reconocimiento recibido (`item.pointsExpiresAt`). |

Después, en el facade: `grep -rn "<método>" src/app` para `calculateBalance`, `getTransactions`, `getRedemptions`, `getPointsBuckets` y `getExpiringPoints`. Si ya nadie los usa, bórralos con sus datos de prueba.

### `.html` — filtros del feed

Justo después del `panel-title` del feed:

```html
<div class="redeem-filters-panel">
  <div class="filter-field">
    <label class="field-label" for="feed-category">Categoría</label>
    <select id="feed-category" class="field-input" (change)="setFeedCategory($any($event.target).value)">
      <option value="" [selected]="feedFilters().categoryId === null">Todas las categorías</option>
      @for (category of categories(); track category.id) {
        <option [value]="category.id" [selected]="feedFilters().categoryId === category.id">{{ category.name }}</option>
      }
    </select>
  </div>

  <div class="filter-field">
    <label class="field-label" for="feed-person">Persona reconocida</label>
    <select id="feed-person" class="field-input" (change)="setFeedPerson($any($event.target).value)">
      <option value="" [selected]="feedFilters().nomineeEmail === null">Todas las personas</option>
      @for (person of feedPeople(); track person.email) {
        <option [value]="person.email" [selected]="feedFilters().nomineeEmail === person.email">{{ person.name }}</option>
      }
    </select>
  </div>

  <div class="filter-field">
    <label class="field-label" for="feed-period">Período</label>
    <select id="feed-period" class="field-input" (change)="setFeedPeriod($any($event.target).value)">
      @for (option of feedPeriods; track option.value) {
        <option [value]="option.value" [selected]="feedFilters().period === option.value">{{ option.label }}</option>
      }
    </select>
  </div>

  @if (hasFeedFilters()) {
    <div class="filter-actions">
      <button type="button" class="btn-clear-filters" (click)="clearFeedFilters()">Limpiar</button>
    </div>
  }
</div>
```

Y el mensaje de vacío distingue si hay filtros:

```html
@if (feed.isEmpty()) {
  <div class="empty-state">
    @if (hasFeedFilters()) {
      <p>Ningún reconocimiento coincide con estos filtros.</p>
      <button type="button" class="btn-clear-filters" (click)="clearFeedFilters()">Limpiar filtros</button>
    } @else {
      <p>Aún no hay reconocimientos públicos aprobados para mostrar.</p>
    }
  </div>
}
```

### `.html` — "Mis reconocimientos"

1. **Hay una `s` suelta** después de cerrar `nominee-info`: `</div>s`. Se ve como una letra en cada tarjeta. Quítala.
2. **El vencimiento de los puntos** ahora viene en el reconocimiento:

```html
<div class="recognition-highlight-item">
  <small>Vencimiento de puntos</small>
  <strong>
    @if (item.pointsExpiresAt; as expirationDate) {
      {{ expirationDate | date: 'dd/MM/yyyy' }}
    } @else {
      {{ item.pointsAssigned ? 'No definido' : 'Sin puntos' }}
    }
  </strong>
</div>
```

### `.html` — pestaña Redimir

Reemplaza **toda** la sección `@if (activeTab() === 'redimir') { … }` por:

```html
@if (activeTab() === 'redimir') {
  <app-golden-redeem (openHistory)="setActiveTab('mis-puntos')" />
}
```

---

## 8. Paso 6 — "Mis puntos" con `select` ✏️

Los botones de tipo (Todos, Abonos, Usos…) pasan a un `select`. Se agrega otro para el **origen** (Asignación, Reconocimiento, Redención, Vencimiento), que la API ya acepta (`source`).

### `my-points.component.ts`

```ts
// Junto a typeFilters:
readonly sourceFilters: readonly { value: GoldenPointsSource | null; label: string }[] = [
  { value: null, label: 'Todos los orígenes' },
  { value: 'Asignacion', label: 'Asignaciones' },
  { value: 'Reconocimiento', label: 'Reconocimientos' },
  { value: 'Redencion', label: 'Redenciones' },
  { value: 'Vencimiento', label: 'Vencimientos' },
];

readonly sourceFilter = signal<GoldenPointsSource | null>(null);

readonly hasFilters = computed(() => this.typeFilter() !== null || this.sourceFilter() !== null);

// El history ahora envía los dos filtros:
readonly history = new PagedList<GoldenPointsTransaction>(
  (page, pageSize) => this.facade.getMyPointsHistory({ page, pageSize, type: this.typeFilter(), source: this.sourceFilter() }),
  item => item.id,
);
```

Cambia la primera opción de `typeFilters` a `{ value: null, label: 'Todos los movimientos' }`, y agrega:

```ts
/** Desde el select: '' = todos. */
setTypeFilterValue(value: string): void {
  this.setTypeFilter(this.typeFilters.find(option => option.value === value)?.value ?? null);
}

setSourceFilterValue(value: string): void {
  const source = this.sourceFilters.find(option => option.value === value)?.value ?? null;
  if (this.sourceFilter() === source) {
    return;
  }

  this.sourceFilter.set(source);
  void this.history.reload();
}

clearFilters(): void {
  this.typeFilter.set(null);
  this.sourceFilter.set(null);
  void this.history.reload();
}
```

Imports: `computed` de `@angular/core` y `GoldenPointsSource` del dominio.

### `my-points.component.html`

Reemplaza el bloque `<div class="mp-chips" …> … </div>` del encabezado del historial por:

```html
<div class="redeem-filters-panel mp-filters">
  <div class="filter-field">
    <label class="field-label" for="mp-type">Tipo de movimiento</label>
    <select id="mp-type" class="field-input" (change)="setTypeFilterValue($any($event.target).value)">
      @for (filter of typeFilters; track filter.label) {
        <option [value]="filter.value ?? ''" [selected]="typeFilter() === filter.value">{{ filter.label }}</option>
      }
    </select>
  </div>

  <div class="filter-field">
    <label class="field-label" for="mp-source">Origen</label>
    <select id="mp-source" class="field-input" (change)="setSourceFilterValue($any($event.target).value)">
      @for (filter of sourceFilters; track filter.label) {
        <option [value]="filter.value ?? ''" [selected]="sourceFilter() === filter.value">{{ filter.label }}</option>
      }
    </select>
  </div>

  @if (hasFilters()) {
    <div class="filter-actions">
      <button type="button" class="btn-clear-filters" (click)="clearFilters()">Limpiar</button>
    </div>
  }
</div>
```

Y en el mensaje de vacío, cambia `@if (typeFilter())` por `@if (hasFilters())` y el texto por "No tienes movimientos con estos filtros.".

### `my-points.component.scss`

- **Arriba del archivo:** `@use '../../shared/puntos-dorados-shared.scss' as *;`, para tener `.redeem-filters-panel`, `.field-input`, etc.
- **Borra** `.mp-chips` y `.mp-chip`.
- **Agrega:**

```scss
.mp-filters {
  flex: 1 1 100%;
  margin: 0;
}
```

> El encabezado del historial (`.mp-history__head`) ya es `flex-wrap`: el título queda arriba y los filtros ocupan la fila de abajo.

---

## 9. Paso 7 — Los demás filtros: administración

Para que **todos** los filtros sean `select`.

### Aprobaciones ([puntos-dorados-aprobaciones-dashboard-angular.md](puntos-dorados-aprobaciones-dashboard-angular.md), Paso 5)

En el `.html`, cambia el bloque `approval-filters` (los botones `tab-btn`) por:

```html
<div class="filter-field approval-filters">
  <label class="field-label" for="approval-status">Estado</label>
  <select id="approval-status" class="field-input" (change)="setApprovalStatusFilterValue($any($event.target).value)">
    @for (filter of approvalStatusFilters; track filter.label) {
      <option [value]="filter.value ?? ''" [selected]="approvalStatusFilter() === filter.value">{{ filter.label }}</option>
    }
  </select>
</div>
```

En el `.ts`:

```ts
/** Desde el select: '' = todos. */
setApprovalStatusFilterValue(value: string): void {
  this.setApprovalStatusFilter(this.approvalStatusFilters.find(option => option.value === value)?.value ?? null);
}
```

En el `.scss`, `.approval-filters` deja de ser `display: flex`: basta con `min-width: 14rem;`.

### Pestaña "Puntos" de administración ([puntos-dorados-puntos-angular.md](puntos-dorados-puntos-angular.md), Paso 4), cuando la implementes

En `points-admin.component.html`, cambia los botones `.pa-chips` y el checkbox "Solo la persona elegida" por:

```html
<div class="pa-filters">
  <select class="form-select form-select-sm" aria-label="Filtrar por origen" (change)="setSourceFilterValue($any($event.target).value)">
    @for (filter of sourceFilters; track filter.label) {
      <option [value]="filter.value ?? ''" [selected]="sourceFilter() === filter.value">{{ filter.label }}</option>
    }
  </select>

  <select class="form-select form-select-sm" aria-label="Personas" (change)="setOnlySelectedPerson($any($event.target).value === 'selected')">
    <option value="all" [selected]="!onlySelectedPerson()">Todas las personas</option>
    <option value="selected" [selected]="onlySelectedPerson()" [disabled]="!selectedEmail()">Solo la persona elegida</option>
  </select>
</div>
```

En el `.ts`, en lugar de `setSourceFilter`/`toggleOnlySelectedPerson` desde la plantilla:

```ts
setSourceFilterValue(value: string): void {
  this.setSourceFilter(this.sourceFilters.find(option => option.value === value)?.value ?? null);
}

setOnlySelectedPerson(only: boolean): void {
  this.toggleOnlySelectedPerson(only);
}
```

En el `.scss`, cambia `.pa-chips`/`.pa-chip` por:

```scss
.pa-filters {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;

  .form-select {
    width: auto;
    min-width: 12rem;
  }
}
```

### Catálogo de administración (código actual)

Los campos "Puntos min" y "Puntos max" pasan al mismo select de rangos que Redimir. En `puntos-dorados-admin.component.ts`:

```ts
import { GOLDEN_POINT_RANGES } from '../../domain/puntos-dorados';

readonly pointRanges = GOLDEN_POINT_RANGES;
catalogRangeFilter = signal(''); // reemplaza catalogMinPointsFilter y catalogMaxPointsFilter

setCatalogRange(value: string): void {
  this.catalogRangeFilter.set(this.pointRanges.some(option => option.value === value) ? value : '');
}
```

En `filteredCatalogProducts`, cambia las dos condiciones de `min`/`max` por:

```ts
const range = this.pointRanges.find(option => option.value === this.catalogRangeFilter());
// …
if (range?.min != null && product.pointsCost < range.min) {
  return false;
}
if (range?.max != null && product.pointsCost > range.max) {
  return false;
}
```

En `clearCatalogFilters`, `this.catalogRangeFilter.set('');` en lugar de los dos `set(null)`. Borra `setCatalogMinPoints` y `setCatalogMaxPoints`.

En el `.html`, cambia los dos `<input type="number">` por:

```html
<select class="field-input" (change)="setCatalogRange($any($event.target).value)">
  @for (range of pointRanges; track range.value) {
    <option [value]="range.value" [selected]="catalogRangeFilter() === range.value">{{ range.label }}</option>
  }
</select>
```

Y los dos selects que ya existen en Catálogo (`catalogCategoryFilter`, `catalogSortOrder`) usan `[value]` en el `<select>`. Para el de categoría, que tiene opciones que llegan de la API, cámbialo a `[selected]` en cada `<option>`, como los demás.

---

## 10. Contrato de la API de redención (pendiente)

El frontend queda listo con este contrato. Mientras no exista, "Confirmar canje" muestra "No se pudo completar el canje…" y no cambia nada.

```text
POST /api/GoldenRedemptions
{ "productId": 7, "requestId": "3f0b…" }
```

```json
{
  "response": {
    "redemptionId": 41,
    "productId": 7,
    "productName": "Día libre adicional",
    "points": 300,
    "balanceAfter": 50,
    "createdAt": "2026-10-13T15:20:00"
  },
  "hasError": false,
  "errors": []
}
```

Lo que tendrá que hacer la API (como dejó diseñado la sección 10 de la [guía de puntos](puntos-dorados-puntos-api.md)), **en una sola transacción**:

- **Validar:** el producto disponible, el saldo suficiente y `max_redemptions_per_user`.
- **Descontar los puntos:** `GoldenPointsLedger.DebitAsync`, del lote que vence primero.
- **Descontar el stock:** `DecreaseStockAsync`.
- **Guardar la redención.**
- **No canjear dos veces:** el mismo `requestId` devuelve la misma redención.

**Errores:** saldo insuficiente, sin stock, límite por persona y producto no disponible responden con HTTP 200 y `hasError`, no con 400, para que el mensaje salga en el modal.

---

## 11. Pruebas

**Redimir**
- Al abrir: el saldo es el mismo de "Mis puntos" (ya no el de prueba).
- **"Te alcanza para N premios":** cuenta solo los que cuestan menos o igual que el saldo.
- **"Tu próxima meta":** es el premio que menos puntos falta para alcanzar. No aparece si todo alcanza o si no hay premios.
- **Puntos por vencer:** si hay, el aviso dice cuántos y cuándo.
- **Filtros:**
  - Cada select filtra al instante, el contador "N de M premios" cambia y "Limpiar" aparece solo con filtros activos.
  - "Casi me alcanza" muestra los que no alcanzan pero tienen 75 % o más de barra.
  - "Recomendados" ordena primero los que alcanzan, del más caro al más barato.
- **"Aún no te alcanza":** el botón está deshabilitado y la tarjeta dice cuánto falta.
- **Imagen rota:** se ve el ícono de regalo, no el ícono de imagen rota del navegador.
- **Canje:**
  - **Redimir:** el modal muestra "Saldo actual 350 → Saldo después del canje 50".
  - **Esc o clic afuera:** cierra el modal, salvo mientras está canjeando.
  - **Con la API de redención:** "Confirmar canje" muestra "¡Canje registrado!" con el saldo nuevo; detrás, el saldo y el stock se actualizan.
  - **Sin la API todavía:** el error sale en el modal y el saldo no cambia.
  - **Doble clic en "Confirmar canje":** una sola petición.
- **"Ver mi historial de puntos":** abre la pestaña "Mis puntos".

**Feed**
- **Categoría "Servicio":** solo reconocimientos de esa categoría. Con "Cargar más", las páginas siguientes también vienen filtradas.
- **Una persona:** solo los que esa persona recibió.
- **"Este mes":** solo los aprobados desde el 1 del mes.
- **"Limpiar":** vuelve a todo.
- **Filtros sin resultados:** "Ningún reconocimiento coincide con estos filtros."
- **Categoría inactiva:** aparece en el filtro si tiene reconocimientos.

**Mis puntos**
- **Tipo "Usos" + Origen "Redenciones":** solo los canjes.
- **"Limpiar":** vuelve a todo.

**Mis reconocimientos**
- **Uno aprobado con puntos:** muestra la fecha de vencimiento real.
- **Uno sin puntos:** dice "Sin puntos".
- **La `s` suelta:** ya no aparece.

---

## ✅ Checklist

- [ ] API del feed con `nomineeEmail` y `from`.
- [ ] Dominio: `GoldenFeedFilters`, `GoldenFeedQuery`, `GOLDEN_POINT_RANGES`, `RedeemGoldenProduct`, `GoldenRedemptionReceipt` y `pointsExpiresAt` en `GoldenNomination`.
- [ ] `getFeed` y `getRecognitionFeed` con filtros; `golden-redemptions.*` y `redeemProduct` real en el facade.
- [ ] `app-golden-redeem` creado, con el `@use` de los estilos compartidos.
- [ ] Componente del colaborador: filtros del feed, categorías cargadas para el feed, `<app-golden-redeem>` y todo lo de Redimir borrado.
- [ ] "Mis reconocimientos": `pointsExpiresAt` y sin la `s` suelta.
- [ ] "Mis puntos": selects de tipo y origen.
- [ ] Administración: select de estado en Aprobaciones y rangos en Catálogo (y en "Puntos" cuando se implemente).
- [ ] Métodos de prueba del facade borrados si ya nadie los usa.
- [ ] API de redención: pendiente (sección 10).
