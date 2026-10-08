# 📥 Puntos Dorados — Exportar consolidado XLSX (API + Angular)

Conecta el botón **Exportar consolidado XLSX** de la pestaña Dashboard con datos reales.

| Parte | Qué hace |
|---|---|
| **API** | `GET /api/GoldenDashboard/export` devuelve las filas del consolidado (JSON), con **los mismos filtros** del dashboard. |
| **Angular** | `exportConsolidatedXlsx()` sigue armando el Excel con la librería `xlsx`, como hoy. Solo cambia de dónde salen las filas. |

**Requiere:**
- **API:** [puntos-dorados-dashboard-api.md](puntos-dorados-dashboard-api.md), por el filtro, el validador y el repositorio, y [puntos-dorados-aprobaciones-api.md](puntos-dorados-aprobaciones-api.md), por la columna `review_comment`.
- **Angular:** [puntos-dorados-aprobaciones-dashboard-angular.md](puntos-dorados-aprobaciones-dashboard-angular.md), por `golden-dashboard.service.ts` y `toApiDashboardFilters`.

**Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md).

---

## 1. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **¿Quién arma el Excel?** | **El navegador**, como hoy (`xlsx` ya está en el proyecto). La API devuelve filas en JSON: no hace falta una librería de Excel en .NET y el formato del archivo se cambia sin tocar el backend. |
| 2 | **Qué filas.** | Los reconocimientos **creados** en el período, con los filtros de colaborador, estado y categoría. Es exactamente lo que cuenta la tarjeta "Reconocimientos" del dashboard: el número de filas del Excel coincide con esa tarjeta. |
| 3 | **Nombres de los campos.** | Los mismos que ya lee `exportConsolidatedXlsx` (`recognitionId`, `nomineeName`, `nomineeEmail`, `nominatorName`, `category`, `status`, `pointsAssigned`, `visibility`, `createdAt`, `reviewedAt`), más cinco nuevos: correo de quien reconoce, motivo, revisado por, comentario de la revisión. |
| 4 | **Privados y puntos.** | Se incluyen: es un reporte de administración. Que no salgan en el feed es una regla del feed, no del consolidado. |
| 5 | **Orden.** | Del más antiguo al más nuevo (por fecha de creación): se lee como una bitácora. |
| 6 | **Tamaño.** | Máximo **20.000 filas**. Si el filtro trae más, la API responde un error de negocio ("reduce el rango o agrega filtros") en lugar de mandar un JSON gigante al navegador. |
| 7 | **Fechas.** | La API las envía en UTC, como siempre. En el Excel van como texto en hora de Colombia (`dd/MM/yyyy HH:mm`), así se ven igual en cualquier computador. |
| 8 | **Nombre del archivo.** | `puntos-dorados-consolidado-<desde>-a-<hasta>.xlsx`, con el período que se usó de verdad. Hoy usa `new Date().toISOString()`, que después de las 7 p. m. en Colombia ya da la fecha de **mañana** (es UTC). |
| 9 | **Permisos.** | Comentados, igual que el dashboard (sección 9 de la guía de aprobaciones). |

---

# Parte A — API

## 2. Archivos

```text
DOCCB.Application/
├── Contracts/Persistence/IGoldenDashboardQueryRepository.cs     ✏️ + GoldenConsolidatedRow, GetConsolidatedRowsAsync
└── Features/GoldenPoints/Application/
    ├── Constants/GoldenDashboardConstants.cs                    ✏️ + límite y mensaje
    ├── Dtos/GoldenDashboardDtos.cs                              ✏️ + GoldenConsolidatedRowDto
    ├── Interfaces/IGoldenDashboardService.cs                    ✏️ + ExportAsync
    └── Services/GoldenDashboardService.cs                       ✏️ + ExportAsync

DOCCB.Infraestructure/
└── Repositories/GoldenDashboardQueryRepository.cs               ✏️ + GetConsolidatedRowsAsync

WebApp/
└── Controllers/GoldenDashboardController.cs                     ✏️ + acción Export
```

**¿Repositorio nuevo?** No. La consulta usa el mismo filtro privado `Recognitions(scope)` del repositorio del dashboard. Escribirla aparte obligaría a repetir los filtros de colaborador, estado y categoría.

---

## 3. Constantes y DTO

### `Constants/GoldenDashboardConstants.cs` ✏️ — agrega

```csharp
public const int MaxExportRows = 20_000;

public const string TooManyExportRows = "El consolidado tiene más de 20.000 reconocimientos. Reduce el rango de fechas o agrega filtros.";
```

### `Dtos/GoldenDashboardDtos.cs` ✏️ — agrega

```csharp
/// <summary>Una fila del consolidado. Los nombres coinciden con los que ya lee exportConsolidatedXlsx en Angular.</summary>
public class GoldenConsolidatedRowDto
{
    public int RecognitionId { get; set; }
    public string NomineeName { get; set; } = string.Empty;
    public string NomineeEmail { get; set; } = string.Empty;
    public string NominatorName { get; set; } = string.Empty;
    public string NominatorEmail { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string Reason { get; set; } = string.Empty;
    /// <summary>Pendiente | Aprobada | Rechazada</summary>
    public string Status { get; set; } = string.Empty;
    /// <summary>Publica | Privada</summary>
    public string Visibility { get; set; } = string.Empty;
    public int? PointsAssigned { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? ReviewedAt { get; set; }
    public string? ReviewedBy { get; set; }
    public string? ReviewComment { get; set; }
}
```

---

## 4. Repositorio

### `Contracts/Persistence/IGoldenDashboardQueryRepository.cs` ✏️

Agrega el record (junto a los demás) y el método en la interfaz:

```csharp
public sealed record GoldenConsolidatedRow(
    int RecognitionId,
    string NomineeName,
    string NomineeEmail,
    string NominatorName,
    string NominatorEmail,
    string CategoryName,
    string Reason,
    GoldenRecognitionStatus Status,
    GoldenRecognitionVisibility Visibility,
    int? PointsAssigned,
    DateTime CreatedDate,
    DateTime? ReviewedDate,
    string? ReviewedBy,
    string? ReviewComment);
```

```csharp
/// <summary>
/// Reconocimientos creados en el rango, con los mismos filtros del dashboard, del más antiguo al más nuevo.
/// Trae como máximo <paramref name="take"/> filas.
/// </summary>
Task<IReadOnlyList<GoldenConsolidatedRow>> GetConsolidatedRowsAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc, int take);
```

### `Repositories/GoldenDashboardQueryRepository.cs` ✏️ — agrega

```csharp
public async Task<IReadOnlyList<GoldenConsolidatedRow>> GetConsolidatedRowsAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc, int take) =>
    await Recognitions(scope)
        .Where(r => r.CreatedDate >= fromUtc && r.CreatedDate < toUtc)
        .OrderBy(r => r.CreatedDate)
        .ThenBy(r => r.Id)
        .Take(take)
        .Select(r => new GoldenConsolidatedRow(
            r.Id,
            r.Nominee.DisplayName,
            r.Nominee.CorportativeEmail,
            r.Nominator.DisplayName,
            r.Nominator.CorportativeEmail,
            r.Category.Name,
            r.Reason,
            r.Status,
            r.Visibility,
            r.PointsAssigned,
            r.CreatedDate,
            r.ReviewedDate,
            r.ReviewedBy,
            r.ReviewComment))
        .ToListAsync();
```

> Usa el índice `ix_golden_recognition_created` del dashboard para el rango. Las personas y la categoría se leen con un `JOIN` por fila, solo con las columnas del `Select`.

---

## 5. Servicio

### `Interfaces/IGoldenDashboardService.cs` ✏️ — agrega

```csharp
Task<ResponseDto<List<GoldenConsolidatedRowDto>>> ExportAsync(GoldenDashboardQueryDto query, string currentUserEmail);
```

### `Services/GoldenDashboardService.cs` ✏️ — agrega

```csharp
public async Task<ResponseDto<List<GoldenConsolidatedRowDto>>> ExportAsync(GoldenDashboardQueryDto query, string currentUserEmail)
{
    var errors = new List<string>();
    var filter = GoldenDashboardValidator.Normalize(query, GoldenClock.Today(), errors);

    if (errors.Count > 0)
    {
        return ResponseDtoHelper.CreateErrorResponseDto<List<GoldenConsolidatedRowDto>>(errors);
    }

    // Permisos (pendiente): el mismo CanReviewAsync de la guía de aprobaciones, sección 9.
    // if (!await CanReviewAsync(currentUserEmail))
    // {
    //     throw new UnauthorizedAccessException();
    // }

    var scope = await ScopeAsync(filter);

    // Se pide una fila de más: si llega, el consolidado pasa del límite.
    var rows = await _queryRepository.GetConsolidatedRowsAsync(
        scope,
        GoldenClock.StartOfDayUtc(filter.From),
        GoldenClock.StartOfDayUtc(filter.To.AddDays(1)),
        GoldenDashboardConstants.MaxExportRows + 1);

    if (rows.Count > GoldenDashboardConstants.MaxExportRows)
    {
        return ResponseDtoHelper.CreateErrorResponseDto<List<GoldenConsolidatedRowDto>>(GoldenDashboardConstants.TooManyExportRows);
    }

    return ResponseDtoHelper.CreateSuccessResponseDto(rows.Select(row => new GoldenConsolidatedRowDto
    {
        RecognitionId = row.RecognitionId,
        NomineeName = row.NomineeName,
        NomineeEmail = row.NomineeEmail,
        NominatorName = row.NominatorName,
        NominatorEmail = row.NominatorEmail,
        Category = row.CategoryName,
        Reason = row.Reason,
        Status = GoldenRecognitionCodes.ToStatusCode(row.Status),
        Visibility = GoldenRecognitionCodes.ToVisibilityCode(row.Visibility),
        PointsAssigned = row.PointsAssigned,
        CreatedAt = row.CreatedDate,
        ReviewedAt = row.ReviewedDate,
        ReviewedBy = row.ReviewedBy,
        ReviewComment = row.ReviewComment,
    }).ToList());
}

/// <summary>
/// Filtros que no son fechas. Si se eligieron correos y ninguno existe, la lista queda vacía
/// y el resultado es vacío (no "todos").
/// </summary>
private async Task<GoldenDashboardScope> ScopeAsync(GoldenDashboardFilter filter)
{
    IReadOnlyCollection<int>? userIds = filter.UserEmails.Count > 0
        ? await _queryRepository.GetUserIdsByEmailsAsync(filter.UserEmails)
        : null;

    return new GoldenDashboardScope(userIds, filter.Statuses, filter.CategoryIds);
}
```

> `GetAsync` arma el mismo `scope` con cuatro líneas. Puedes cambiarlas por `var scope = await ScopeAsync(filter);` para que haya una sola versión. Es opcional.

---

## 6. Controlador — `GoldenDashboardController.cs` ✏️

Agrega la acción. Tiene su propio `try/catch` completo (regla 18):

```csharp
/// <summary>
/// Filas del consolidado, con los mismos filtros del dashboard.
/// GET export?from=2026-05-01&amp;to=2026-10-07&amp;userEmails=…&amp;statuses=Aprobada&amp;categoryIds=1
/// </summary>
[HttpGet("export")]
[ProducesResponseType(StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
[ProducesResponseType(StatusCodes.Status401Unauthorized)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
public async Task<IActionResult> Export([FromQuery] GoldenDashboardQueryDto query)
{
    try
    {
        var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
        if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
        {
            return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
        }

        var response = await _service.ExportAsync(query, authenticatedUserInfo.Email);
        return Ok(response);
    }
    catch (ArgumentException ex)
    {
        return BadRequest(new { message = ApiResponseConstants.GoldenDashboardErrorMessage, error = ex.Message });
    }
    catch (UnauthorizedAccessException)
    {
        return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
    }
    catch (Exception)
    {
        return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenDashboardErrorMessage });
    }
}
```

### Contrato

```text
GET /api/GoldenDashboard/export?from=2026-10-01&to=2026-10-07&statuses=Aprobada
```

```json
{
  "response": [
    {
      "recognitionId": 12,
      "nomineeName": "Juan Camilo Ruiz",
      "nomineeEmail": "juan.ruiz@empresa.com",
      "nominatorName": "Daniela Torres",
      "nominatorEmail": "daniela.torres@empresa.com",
      "category": "Servicio",
      "reason": "Apoyó una contingencia crítica de operación fuera de su horario.",
      "status": "Aprobada",
      "visibility": "Publica",
      "pointsAssigned": 150,
      "createdAt": "2026-10-02T14:10:00",
      "reviewedAt": "2026-10-03T09:30:00",
      "reviewedBy": "admin@empresa.com",
      "reviewComment": null
    }
  ],
  "hasError": false,
  "errors": []
}
```

Fechas en UTC sin la `Z`, como el resto de la API. Errores de negocio con HTTP 200 y `hasError` (filtros inválidos o más de 20.000 filas).

---

# Parte B — Angular

## 7. Dominio y mapper

### `domain/puntos-dorados.ts` ✏️ — agrega

```ts
/** Una fila del consolidado (Exportar XLSX). */
export interface GoldenConsolidatedRow {
  recognitionId: number;
  nomineeName: string;
  nomineeEmail: string;
  nominatorName: string;
  nominatorEmail: string;
  category: string;
  reason: string;
  status: GoldenNominationStatus;
  visibility: GoldenRecognitionVisibility;
  pointsAssigned: number | null;
  createdAt: Date;
  reviewedAt: Date | null;
  reviewedBy: string | null;
  reviewComment: string | null;
}
```

> Si `exportConsolidatedData()` ya devuelve un tipo con estos nombres (el de los datos de prueba), agrégale los campos nuevos y úsalo en lugar de crear otro.

### `infraestructure/golden-dashboard.mapper.ts` ✏️ — agrega

```ts
// Agrega a los imports que ya tiene el archivo:
import { GoldenConsolidatedRow } from '../domain/puntos-dorados';
import { parseUtc } from './golden-api';

export interface GoldenConsolidatedRowDto {
  recognitionId: number;
  nomineeName: string;
  nomineeEmail: string;
  nominatorName: string;
  nominatorEmail: string;
  category: string;
  reason: string;
  status: string;
  visibility: string;
  pointsAssigned: number | null;
  createdAt: string;
  reviewedAt: string | null;
  reviewedBy: string | null;
  reviewComment: string | null;
}

export function toConsolidatedRow(dto: GoldenConsolidatedRowDto): GoldenConsolidatedRow {
  return {
    ...dto,
    status: toStatus(dto.status), // el mismo toStatus del archivo
    visibility: dto.visibility === 'Privada' ? 'Privada' : 'Publica',
    createdAt: parseUtc(dto.createdAt),
    reviewedAt: dto.reviewedAt ? parseUtc(dto.reviewedAt) : null,
  };
}
```

---

## 8. Servicio y facade

### `infraestructure/golden-dashboard.service.ts` ✏️ — agrega

Mismos filtros y mismo `params(filters)` que `getDashboard`:

```ts
async exportConsolidated(filters: GoldenDashboardFilters): Promise<Observable<GoldenResult<GoldenConsolidatedRow[]>>> {
  const headers = await this.authHeaders();

  return this.http
    .get<GoldenResultDto<GoldenConsolidatedRowDto[]>>(`${this.baseUrl}/export`, { headers, params: this.params(filters) })
    .pipe(
      map(dto => toResult(dto, rows => rows.map(toConsolidatedRow))),
      catchError(error => this.handleError(error)),
    );
}
```

Imports nuevos: `GoldenConsolidatedRow` del dominio y `GoldenConsolidatedRowDto`, `toConsolidatedRow` del mapper.

### `application/puntos-dorados.fecade.ts` ✏️

**Reemplaza** el `exportConsolidatedData()` de prueba (y sus datos) por:

```ts
exportConsolidatedData(filters: GoldenDashboardFilters): Promise<GoldenResult<GoldenConsolidatedRow[]>> {
  return this.runRecognitionRequest(() => this.dashboardApi.exportConsolidated(filters), 'No se pudo generar el consolidado.');
}
```

---

## 9. Componente — `puntos-dorados-admin.component` ✏️

### `.ts`

Estado (junto al del dashboard):

```ts
readonly exporting = signal(false);
readonly exportError = signal<string | null>(null);
```

**Reemplaza** `exportConsolidatedXlsx()`. El armado del Excel es el mismo; cambian de dónde salen las filas, las columnas nuevas, las fechas y el nombre del archivo:

```ts
async exportConsolidatedXlsx(): Promise<void> {
  if (this.exporting()) {
    return;
  }

  this.exporting.set(true);
  this.exportError.set(null);

  try {
    const filters = this.toApiDashboardFilters(this.dashboardFilters());
    const response = await this.facade.exportConsolidatedData(filters);

    if (response.hasError) {
      this.exportError.set(response.errors.join(' '));
      return;
    }

    if (response.response.length === 0) {
      this.exportError.set('No hay reconocimientos con estos filtros.');
      return;
    }

    // Encabezados legibles. Si prefieres los de antes (reconocimientoId, colaboradorReconocido…), cambia solo las claves.
    const exportRows = response.response.map(item => ({
      'Id': item.recognitionId,
      'Colaborador reconocido': item.nomineeName,
      'Correo reconocido': item.nomineeEmail,
      'Reconocido por': item.nominatorName,
      'Correo de quien reconoce': item.nominatorEmail,
      'Categoría': item.category,
      'Motivo': item.reason,
      'Estado': item.status,
      'Puntos': item.pointsAssigned ?? '',
      'Visibilidad': item.visibility === 'Privada' ? 'Privada' : 'Pública',
      'Fecha de creación': formatExportDate(item.createdAt),
      'Fecha de revisión': item.reviewedAt ? formatExportDate(item.reviewedAt) : '',
      'Revisado por': item.reviewedBy ?? '',
      'Comentario de la revisión': item.reviewComment ?? '',
    }));

    const worksheet = XLSX.utils.json_to_sheet(exportRows);
    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, worksheet, 'Consolidado');

    // El período que se usó de verdad (con los valores por defecto ya aplicados), en fecha de Colombia.
    const period = this.dashboardData()?.period;
    const from = period ? toIsoDate(period.from) : filters.from ?? toIsoDate(new Date());
    const to = period ? toIsoDate(period.to) : filters.to ?? toIsoDate(new Date());
    XLSX.writeFile(workbook, `puntos-dorados-consolidado-${from}-a-${to}.xlsx`);
  } finally {
    this.exporting.set(false);
  }
}
```

Y fuera de la clase, junto a `kpiTrend`:

```ts
/** dd/MM/yyyy HH:mm en la hora del navegador (Colombia). Como texto: se ve igual en cualquier Excel. */
function formatExportDate(date: Date): string {
  const pad = (value: number) => String(value).padStart(2, '0');
  return `${pad(date.getDate())}/${pad(date.getMonth() + 1)}/${date.getFullYear()} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
```

> **El período del nombre** sale de `dashboardData().period`, la última respuesta del dashboard. Como los filtros se aplican y el dashboard se recarga antes de exportar, coinciden. Si el dashboard todavía no cargó, usa los filtros o la fecha de hoy.

### `.html` — botón de exportar

Si lo deshabilitaste con la guía de aprobaciones y dashboard, vuelve a habilitarlo así:

```html
<div class="actions">
  <button type="button" class="btn-primary" [disabled]="exporting()" (click)="exportConsolidatedXlsx()">
    {{ exporting() ? 'Exportando…' : 'Exportar consolidado XLSX' }}
  </button>
  @if (exportError()) {
    <span class="error">{{ exportError() }}</span>
  }
</div>
```

---

## 10. Pruebas

**API**
- `GET export` sin filtros → los reconocimientos creados este mes, del más antiguo al más nuevo.
- **Mismos filtros que el dashboard:** el número de filas es igual a `kpis.recognitions.value`.
- **Incluye los privados y los pendientes;** los rechazados traen `pointsAssigned: null`.
- `from` después de `to` → `hasError`. Un rango de 25 meses → `hasError`.
- **Más de 20.000 filas** (o baja temporalmente `MaxExportRows` a 2 para probarlo) → "El consolidado tiene más de 20.000…".
- **Un correo que no existe** en `userEmails` → lista vacía.

**Angular**
- **Sin filtros:** descarga `puntos-dorados-consolidado-2026-10-01-a-2026-10-08.xlsx` con las 14 columnas.
- **Con un filtro de fechas y una categoría:** el Excel trae solo esas filas y el nombre usa ese rango.
- **Las fechas:** se ven en hora de Colombia. Uno creado a las 9 p. m. dice 21:00, no 02:00 del día siguiente.
- **Exportar a las 8 p. m.:** el nombre del archivo no salta a la fecha de mañana.
- **Sin resultados:** "No hay reconocimientos con estos filtros." y no se descarga nada.
- **Doble clic en Exportar:** una sola descarga; el botón dice "Exportando…".

---

## ✅ Checklist

- [ ] `MaxExportRows` y `TooManyExportRows` en `GoldenDashboardConstants`.
- [ ] `GoldenConsolidatedRowDto`, `GoldenConsolidatedRow` y `GetConsolidatedRowsAsync` (con `Recognitions(scope)`).
- [ ] `ExportAsync` y `ScopeAsync` en el servicio; acción `Export` con `try/catch` completo.
- [ ] Permisos comentados, igual que el dashboard.
- [ ] Angular: `GoldenConsolidatedRow`, `toConsolidatedRow`, `exportConsolidated` y el facade sin datos de prueba.
- [ ] `exportConsolidatedXlsx` con los filtros del dashboard, fechas locales y nombre de archivo por período.
- [ ] Botón de exportar habilitado, con "Exportando…" y el error.
- [ ] Probado: el número de filas coincide con la tarjeta "Reconocimientos" del dashboard.
