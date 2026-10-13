# 🔎 Puntos Dorados — "Reconocimientos del período" no muestra datos

**Síntoma:** en el Dashboard de administración, la tabla "Reconocimientos del período" sale vacía, pero la API (`GET /api/GoldenDashboard/recognitions`) sí responde.

**Lo que se revisó:** la cadena del frontend está bien conectada.

```text
GoldenDashboardComponent.loadDashboard()
 └─ recognitionsTable.reload()                    PagedList, 10 por página
     └─ facade.getDashboardRecognitions(filtros, page, pageSize)
         └─ GoldenDashboardService.getRecognitions(…)
             GET /api/GoldenDashboard/recognitions?from&to&userEmails&statuses&categoryIds&page&pageSize
             └─ toResult → toPage → toDashboardRecognition (fechas con parseUtc, estado con toStatus)
 └─ plantilla: @for (row of recognitionsTable.items(); track row.id)
```

El problema está en **lo que responde la API** o en **el rango de fechas** que se consulta.

---

## 1. Cómo saber cuál es (1 minuto)

1. Abre el Dashboard con DevTools → **Network**.
2. Filtra por `recognitions`.
3. Abre la petición `GET …/GoldenDashboard/recognitions` y mira:
   - **Payload / URL:** qué `from` y `to` se enviaron (sin filtros no se envían).
   - **Response:** la forma del JSON.
4. Busca tu caso en la tabla de la sección 2.

---

## 2. Las causas posibles

| Lo que ves en la respuesta | Causa | Qué hacer |
|---|---|---|
| `"items": []` y `"totalCount": 0` | **El período.** Sin filtros, la tabla muestra los reconocimientos **creados este mes** (del 1 al día de hoy). Si se crearon en meses anteriores, la tabla queda vacía aunque las gráficas de tendencia tengan datos (esas muestran 6 meses). La tarjeta "Reconocimientos del mes" también está en 0. | Funciona como se diseñó: filtra un rango de fechas en el modal. Aplica la mejora de la sección 3 para que la tabla diga qué fechas consulta. |
| `"data": [...]`, `"totalRecords"`, `"pageNumber"` (en lugar de `items`, `totalCount`, `page`) | La API devuelve el `PaginatedResponseDto` del proyecto en vez de `GoldenPagedResultDto`. El mapper busca `items`, no lo encuentra y la tabla muestra "No se pudieron cargar los reconocimientos del período". | Corrige la API (sección 4). |
| `"hasError": true` | Error de validación: por ejemplo, "Desde" después de "Hasta", más de 24 meses o un estado desconocido. | El mensaje sale en rojo debajo de la tabla. Revisa los filtros enviados. |
| `"items"` con datos y la tabla vacía | No lo explica el código actual. | Guarda la respuesta completa y la URL de la petición, y revísalas junto con esta guía. |

> **Si probaste en Swagger y ahí sí trae datos,** compara los parámetros. En Swagger seguramente enviaste `from` y `to`; el Dashboard, sin filtros, no los envía, y la API usa el mes actual.

---

## 3. Mejora en el frontend: decir qué período se consulta

Así nadie vuelve a pensar que la tabla falla cuando el mes no tiene reconocimientos.

### `golden-dashboard.component.html` — subtítulo de la tabla

Reemplaza el `<p>` del encabezado de "Reconocimientos del período" por:

```html
<p>
  @if (dashboardData(); as data) {
    Creados del {{ data.period.from | date: 'd MMM' }} al {{ data.period.to | date: 'd MMM y' }}, con los filtros aplicados.
  } @else {
    El estado de cada reconocimiento, con los filtros aplicados.
  }
</p>
```

`dashboardData().period` trae las fechas que usó la API, con los valores por defecto ya aplicados. Coinciden con las de la tabla porque los dos piden los mismos filtros.

### `golden-dashboard.component.html` — mensaje de vacío

Reemplaza el bloque `@if (recognitionsTable.isEmpty())` por:

```html
@if (recognitionsTable.isEmpty()) {
  <p class="dashboard-table-empty">
    @if (hasActiveDashboardFilters()) {
      No hay reconocimientos creados con estos filtros.
    } @else {
      No hay reconocimientos creados este mes. Usa los filtros para ver otras fechas.
    }
  </p>
}
```

---

## 4. Corrección en la API (si responde `data` en lugar de `items`)

Toda la API de Puntos Dorados pagina con `GoldenPagedResultDto<T>` (`Items`, `Page`, `PageSize`, `TotalCount`, `TotalPages`), y el frontend (`toPage`) espera esa forma. En `GoldenDashboardService.GetRecognitionsAsync`, la respuesta debe ser:

```csharp
var (rows, total) = await _queryRepository.GetRecognitionsPageAsync(
    scope,
    GoldenClock.StartOfDayUtc(filter.From),
    GoldenClock.StartOfDayUtc(filter.To.AddDays(1)),
    page,
    pageSize);

return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPagedResultDto<GoldenDashboardRecognitionDto>
{
    Items = rows.Select(row => new GoldenDashboardRecognitionDto
    {
        Id = row.Id,
        NomineeName = row.NomineeName,
        NomineeEmail = row.NomineeEmail,
        NominatorName = row.NominatorName,
        CategoryName = row.CategoryName,
        CategoryIcon = row.CategoryIcon,
        CategoryColor = row.CategoryColor,
        Status = GoldenRecognitionCodes.ToStatusCode(row.Status),
        PointsAssigned = row.PointsAssigned,
        CreatedAt = row.CreatedDate,
        ReviewedAt = row.ReviewedDate,
    }).ToList(),
    Page = page,
    PageSize = pageSize,
    TotalCount = total,
});
```

Y el tipo de retorno del método y de la interfaz: `Task<ResponseDto<GoldenPagedResultDto<GoldenDashboardRecognitionDto>>>`.

> `PaginatedResponseDto<T>` es el del proyecto para features **fuera** de Puntos Dorados. Dentro de Puntos Dorados se mantiene `GoldenPagedResultDto<T>`, porque `PagedList` y `toPage` lo usan en todas las listas.

---

## 5. Pruebas

- **Sin filtros y sin reconocimientos este mes:**
  - El subtítulo dice "Creados del 1 oct al 14 oct 2026…".
  - La tabla dice "No hay reconocimientos creados este mes. Usa los filtros para ver otras fechas.".
  - La tarjeta "Reconocimientos del mes" está en 0.
- **Con un rango que incluya los meses con datos:** la tabla los muestra, del más nuevo al más viejo, y el número del encabezado es igual a la tarjeta "Reconocimientos del período".
- **Cargar uno masivo hoy** (pestaña "Reconocimientos masivos") **y volver al Dashboard:** aparece en la tabla como Pendiente.
- **En Network, la respuesta de `recognitions`:** trae `items`, `page`, `pageSize`, `totalCount` y `totalPages`.
