# 📊 Puntos Dorados — Dashboard de métricas (API .NET 8 + SQL Server)

Un endpoint que trae **todo** lo que muestra la pestaña **Dashboard** de administración, con los filtros del modal "Filtrar métricas":

```text
GET /api/GoldenDashboard?from=2026-05-01&to=2026-10-07
                        &userEmails=laura.salazar@empresa.com&userEmails=david.perez@empresa.com
                        &statuses=Aprobada&statuses=Pendiente
                        &categoryIds=1&categoryIds=3
```

| En la pantalla | En la respuesta |
|---|---|
| Tarjetas: Reconocimientos, Aprobaciones, Puntos asignados, Redenciones, con su `+12%` | `kpis` (valor, valor del período anterior y % de cambio) |
| Reconocimientos creados — tendencia | `recognitionsByMonth` |
| Distribución por estado (dona) | `statusDistribution` |
| Reconocimientos por categoría | `recognitionsByCategory` |
| Puntos asignados por mes | `pointsByMonth` (separado en reconocimientos y asignaciones manuales) |

| Filtro del modal | Parámetro | Vacío = |
|---|---|---|
| Rango de fechas (Desde / Hasta) | `from`, `to` (`yyyy-MM-dd`) | Mes actual hasta hoy |
| Colaboradores | `userEmails` (se repite) | Todos |
| Estado de reconocimientos | `statuses`: `Pendiente`, `Aprobada`, `Rechazada` (se repite) | Todos |
| Categorías de reconocimiento | `categoryIds` (se repite) | Todas |

- **Datos en tiempo real:** cada llamada consulta la base de datos, sin caché.
- **Fuera de alcance:** el botón "Exportar consolidado XLSX". Cuando se haga, reutiliza el mismo filtro (`GoldenDashboardQueryDto`) y las mismas consultas.
- **Permisos:** comentados, igual que en [aprobaciones](puntos-dorados-aprobaciones-api.md) (sección 9 de esa guía).
- **Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md).

---

## 1. 🧐 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Un solo endpoint.** | Una petición al abrir la pestaña y otra al aplicar filtros. Las tarjetas y las gráficas salen de la misma consulta, así que siempre cuadran entre sí. |
| 2 | **Período por defecto.** | Mes actual hasta hoy, en hora de Colombia. |
| 3 | **El `+12%`.** | Compara con el **período anterior equivalente**. Mes calendario (completo o hasta hoy): el mismo tramo del mes anterior (1–7 oct contra 1–7 sep). Rango libre: los mismos días justo antes (15 días contra los 15 anteriores). Si el período anterior es 0, `changePercent` llega `null`: el frontend muestra "Nuevo" o no muestra el porcentaje, en vez de "+∞%". |
| 4 | **Fechas.** | El filtro está en días de Colombia. Las columnas se guardan en UTC: "7 de octubre" va de 05:00 UTC del 7 a 05:00 UTC del 8. Los meses de las gráficas también se cuentan en hora de Colombia. |
| 5 | **Colaboradores.** | Por correo, porque es lo que tiene la lista del frontend. En las métricas de reconocimientos, la persona **participa** si lo recibió o lo creó. En puntos y redenciones, cuenta la persona dueña de los puntos. |
| 6 | **Colaboradores que no existen.** | Si se eligieron correos y ninguno está en `dbo.users`, el resultado es **vacío**, no "todos". Lo contrario mostraría las métricas de toda la empresa como si fueran de esas personas. |
| 7 | **Tendencia.** | Muestra **al menos 6 meses** terminando en el mes de "Hasta". Si el rango es más largo, muestra el rango completo. Los meses sin datos llegan en 0, para que la línea no salte meses. |
| 8 | **Categorías.** | Sin filtro: todas las activas, aunque estén en 0, más las inactivas que tengan datos en el período. Con filtro: solo las elegidas. Ordenadas de mayor a menor. |
| 9 | **Puntos asignados.** | Neto del libro de puntos: créditos y ajustes de asignaciones manuales y de reconocimientos. Un reverso o un ajuste a la baja resta. Es la misma regla de "Ganados" en "Mis puntos". |
| 10 | **Redenciones.** | Movimientos de débito con origen "Redención" en el libro. Mientras la redención no exista, llega 0 sin errores. |
| 11 | **Límites.** | Rango máximo de 24 meses. Máximo 200 colaboradores o categorías elegidos, para que la URL no se pase del límite. |

### Qué filtro aplica a qué

| Filtro | Reconocimientos (tarjeta, tendencia, estado, categoría) | Aprobaciones | Puntos asignados | Redenciones |
|---|---|---|---|---|
| **Fechas** | Fecha de creación | Fecha de aprobación | Fecha del movimiento | Fecha del movimiento |
| **Colaboradores** | Recibió o creó | Recibió o creó | Recibió los puntos | Redimió |
| **Estado** | Sí | Sí: si "Aprobada" no está elegida, da 0 | No aplica | No aplica |
| **Categoría** | Sí | Sí | Solo puntos de reconocimientos de esas categorías (sin asignaciones manuales) | No aplica (las redenciones son de productos) |

> **Aprobaciones del período** cuenta los aprobados **en** el período, por fecha de aprobación: uno creado en septiembre y aprobado en octubre cuenta en octubre.
>
> **Nombre de la tarjeta.** Con un rango de fechas elegido, "Reconocimientos del mes" deja de ser del mes. Sugerencia: "Reconocimientos del período", o mostrar las fechas de `period` debajo del título.

---

## 2. 📁 Archivos

```text
DOCCB.Application/
├── Contracts/Persistence/IGoldenDashboardQueryRepository.cs   nuevo ⭐ agregados en SQL
└── Features/GoldenPoints/Application/
    ├── Constants/GoldenDashboardConstants.cs                  nuevo
    ├── Dtos/GoldenDashboardDtos.cs                            nuevo
    ├── Helpers/
    │   ├── GoldenClock.cs                                     ✏️ + UtcOffsetHours, StartOfDayUtc
    │   └── GoldenDashboardValidator.cs                        nuevo — filtro, período anterior, meses
    ├── Interfaces/IGoldenDashboardService.cs                  nuevo
    └── Services/GoldenDashboardService.cs                     nuevo

DOCCB.Infraestructure/
├── Persistence/Scripts SQL/GoldenDashboardIndexes.sql         nuevo
├── Repositories/GoldenDashboardQueryRepository.cs             nuevo
└── InfrastructureServiceRegistration.cs                       ✏️ + 1 línea

WebApp/
├── Common/ApiResponseConstants.cs                             ✏️ + 1 mensaje
└── Controllers/GoldenDashboardController.cs                   nuevo
```

**¿Repositorio propio?** Sí, de solo lectura. Todo son conteos y sumas agrupadas (por estado, categoría y mes), hechos en SQL: no se trae ningún reconocimiento ni movimiento a memoria. Es el caso de la sección 5 de [ARQUITECTURA Y EJEMPLO](.claude/ARQUITECTURA%20Y%20EJEMPLO.MD).

**¿Por qué no el genérico, como en aprobaciones?** Hay dos formas de hacerlo con el genérico, y las dos son las que la arquitectura descarta:

| Con el genérico | Problema |
|---|---|
| Traer los reconocimientos y movimientos del período con `GetListAsync` y contar en C# | Con un rango de 24 meses son miles de filas por cada vez que se abre la pestaña. |
| `GroupBy`, `CountAsync` y `SumAsync` sobre `Query()` o dentro de un `selector`, en el servicio | Son 12 consultas con `GroupBy`, y el mismo filtro (colaborador, estado, categoría) repetido en cada una. Es la "señal práctica" de la sección 5: ese LINQ va en un repositorio. |

En el repositorio, el filtro se escribe una sola vez (`Recognitions(scope)` y `AssignedPoints(scope)`) y cada consulta lo reutiliza. Las dos lecturas simples (correos → ids y lista de categorías) van en el mismo repositorio para que el servicio tenga una sola dependencia y no necesite también el helper.

---

## 3. Paso 1 — 🗄️ Índices

Con pocos datos no se nota. Cuando haya miles de reconocimientos y movimientos, estos índices evitan recorrer las tablas completas en cada filtro.

### `Persistence/Scripts SQL/GoldenDashboardIndexes.sql`

```sql
/* =====================================================================
   Puntos Dorados — índices del dashboard
   Base de datos: DB · Esquema: dbo
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

/* Reconocimientos creados en un rango (tarjeta, tendencia, estado, categoría). */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'ix_golden_recognition_created' AND object_id = OBJECT_ID(N'dbo.golden_recognition'))
    CREATE INDEX ix_golden_recognition_created
        ON dbo.golden_recognition (created_date)
        INCLUDE (status, category_id, nominee_user_id, nominator_user_id);
GO

/* Aprobaciones en un rango. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'ix_golden_recognition_reviewed' AND object_id = OBJECT_ID(N'dbo.golden_recognition'))
    CREATE INDEX ix_golden_recognition_reviewed
        ON dbo.golden_recognition (reviewed_date)
        INCLUDE (status, category_id, nominee_user_id, nominator_user_id);
GO

/* Puntos asignados y redenciones en un rango, de todas las personas. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'ix_golden_points_transaction_created' AND object_id = OBJECT_ID(N'dbo.golden_points_transaction'))
    CREATE INDEX ix_golden_points_transaction_created
        ON dbo.golden_points_transaction (created_date)
        INCLUDE (type, source, points, user_id, recognition_id);
GO
```

---

## 4. Paso 2 — Hora de Colombia: `Helpers/GoldenClock.cs` ✏️

Reemplaza la clase. `Today()` queda igual y se agregan el desfase como constante (para usarlo dentro de las consultas) y el inicio del día en UTC.

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenClock
    {
        /// <summary>Colombia: UTC-5, sin horario de verano.</summary>
        public const int UtcOffsetHours = -5;

        /// <summary>"Hoy" en Colombia.</summary>
        public static DateOnly Today() => DateOnly.FromDateTime(DateTime.UtcNow.AddHours(UtcOffsetHours));

        /// <summary>00:00 de ese día en Colombia, expresado en UTC (las columnas se guardan en UTC).</summary>
        public static DateTime StartOfDayUtc(DateOnly day) => day.ToDateTime(TimeOnly.MinValue).AddHours(-UtcOffsetHours);
    }
}
```

---

## 5. Paso 3 — Constantes, DTOs y filtro

### `Constants/GoldenDashboardConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenDashboardConstants
    {
        public const int MaxRangeMonths = 24;
        public const int MinTrendMonths = 6;
        public const int MaxSelectedItems = 200;

        public const string DateRangeInvalid = "La fecha \"Desde\" no puede ser posterior a \"Hasta\".";
        public const string DateRangeTooLong = "El rango de fechas puede ser de máximo 24 meses.";
        public const string StatusInvalid = "El estado debe ser Pendiente, Aprobada o Rechazada.";
        public const string TooManyItems = "Puedes elegir máximo 200 colaboradores y 200 categorías.";
    }
}
```

### `Dtos/GoldenDashboardDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>
    /// ?from=2026-05-01&amp;to=2026-10-07&amp;userEmails=a@empresa.com&amp;statuses=Aprobada&amp;categoryIds=1
    /// Las listas se envían repitiendo el parámetro.
    /// </summary>
    public class GoldenDashboardQueryDto
    {
        /// <summary>Vacío = primer día del mes de "To".</summary>
        public DateOnly? From { get; set; }
        /// <summary>Vacío = hoy (Colombia).</summary>
        public DateOnly? To { get; set; }
        public List<string> UserEmails { get; set; } = [];
        /// <summary>Pendiente | Aprobada | Rechazada</summary>
        public List<string> Statuses { get; set; } = [];
        public List<int> CategoryIds { get; set; } = [];
    }

    public class GoldenDashboardDto
    {
        public GoldenDashboardPeriodDto Period { get; set; } = new();
        public GoldenDashboardKpisDto Kpis { get; set; } = new();
        /// <summary>Tendencia: un punto por mes, también los meses en 0.</summary>
        public List<GoldenDashboardMonthCountDto> RecognitionsByMonth { get; set; } = [];
        /// <summary>Siempre los tres estados, en orden: Pendiente, Aprobada, Rechazada.</summary>
        public List<GoldenDashboardStatusCountDto> StatusDistribution { get; set; } = [];
        public List<GoldenDashboardCategoryCountDto> RecognitionsByCategory { get; set; } = [];
        /// <summary>Mismos meses que RecognitionsByMonth.</summary>
        public List<GoldenDashboardMonthPointsDto> PointsByMonth { get; set; } = [];
    }

    /// <summary>Las fechas que se usaron de verdad (con los valores por defecto ya aplicados).</summary>
    public class GoldenDashboardPeriodDto
    {
        public DateOnly From { get; set; }
        public DateOnly To { get; set; }
        public DateOnly PreviousFrom { get; set; }
        public DateOnly PreviousTo { get; set; }
    }

    public class GoldenDashboardKpisDto
    {
        public GoldenDashboardKpiDto Recognitions { get; set; } = new();
        public GoldenDashboardKpiDto Approvals { get; set; } = new();
        public GoldenDashboardKpiDto PointsAssigned { get; set; } = new();
        public GoldenDashboardKpiDto Redemptions { get; set; } = new();
    }

    public class GoldenDashboardKpiDto
    {
        public int Value { get; set; }
        public int Previous { get; set; }
        /// <summary>% de cambio contra el período anterior, redondeado. null si el anterior fue 0.</summary>
        public int? ChangePercent { get; set; }
    }

    public class GoldenDashboardMonthCountDto
    {
        /// <summary>Primer día del mes: "2026-05-01".</summary>
        public DateOnly Month { get; set; }
        public int Count { get; set; }
    }

    public class GoldenDashboardStatusCountDto
    {
        /// <summary>Pendiente | Aprobada | Rechazada</summary>
        public string Status { get; set; } = string.Empty;
        public int Count { get; set; }
    }

    public class GoldenDashboardCategoryCountDto
    {
        public int CategoryId { get; set; }
        public string Name { get; set; } = string.Empty;
        public string Icon { get; set; } = string.Empty;
        public string Color { get; set; } = string.Empty;
        public int Count { get; set; }
    }

    public class GoldenDashboardMonthPointsDto
    {
        public DateOnly Month { get; set; }
        public int RecognitionPoints { get; set; }
        public int ManualPoints { get; set; }
        public int Total { get; set; }
    }
}
```

### `Helpers/GoldenDashboardValidator.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    /// <summary>El filtro ya validado. null en una lista = sin filtro.</summary>
    public sealed record GoldenDashboardFilter(
        DateOnly From,
        DateOnly To,
        IReadOnlyList<string> UserEmails,
        IReadOnlyCollection<GoldenRecognitionStatus>? Statuses,
        IReadOnlyCollection<int>? CategoryIds);

    public static class GoldenDashboardValidator
    {
        public static GoldenDashboardFilter Normalize(GoldenDashboardQueryDto query, DateOnly today, List<string> errors)
        {
            var to = query.To ?? today;
            var from = query.From ?? new DateOnly(to.Year, to.Month, 1);

            if (from > to)
            {
                errors.Add(GoldenDashboardConstants.DateRangeInvalid);
            }
            else if (from < to.AddMonths(-GoldenDashboardConstants.MaxRangeMonths))
            {
                errors.Add(GoldenDashboardConstants.DateRangeTooLong);
            }

            var emails = (query.UserEmails ?? [])
                .Select(email => email?.Trim().ToLowerInvariant())
                .Where(email => !string.IsNullOrEmpty(email))
                .Select(email => email!)
                .Distinct()
                .ToList();

            var categoryIds = (query.CategoryIds ?? []).Where(id => id > 0).Distinct().ToList();

            if (emails.Count > GoldenDashboardConstants.MaxSelectedItems || categoryIds.Count > GoldenDashboardConstants.MaxSelectedItems)
            {
                errors.Add(GoldenDashboardConstants.TooManyItems);
            }

            var statuses = new List<GoldenRecognitionStatus>();
            foreach (var value in query.Statuses ?? [])
            {
                // Mismo parser de la guía de aprobaciones: "Pendiente", "Aprobada", "Rechazada".
                if (!GoldenRecognitionApprovalValidator.TryParseStatus(value, out var status))
                {
                    errors.Add(GoldenDashboardConstants.StatusInvalid);
                    break;
                }

                if (status is { } parsed && !statuses.Contains(parsed))
                {
                    statuses.Add(parsed);
                }
            }

            return new GoldenDashboardFilter(
                from,
                to,
                emails,
                statuses.Count > 0 ? statuses : null,
                categoryIds.Count > 0 ? categoryIds : null);
        }

        /// <summary>
        /// Mes calendario (completo o hasta hoy): el mismo tramo del mes anterior (1–7 oct → 1–7 sep).
        /// Rango libre: los mismos días justo antes.
        /// </summary>
        public static (DateOnly From, DateOnly To) PreviousPeriod(DateOnly from, DateOnly to)
        {
            if (from.Day == 1 && from.Year == to.Year && from.Month == to.Month)
            {
                // AddMonths ajusta el fin de mes: 31 oct → 30 sep.
                return (from.AddMonths(-1), to.AddMonths(-1));
            }

            var days = to.DayNumber - from.DayNumber + 1;
            return (from.AddDays(-days), from.AddDays(-1));
        }

        /// <summary>Inicio de la tendencia: al menos 6 meses terminando en el mes de "To", o el rango completo si es más largo.</summary>
        public static DateOnly TrendStart(DateOnly from, DateOnly to)
        {
            var sixMonthsStart = new DateOnly(to.Year, to.Month, 1).AddMonths(-(GoldenDashboardConstants.MinTrendMonths - 1));
            return from < sixMonthsStart ? from : sixMonthsStart;
        }

        /// <summary>Primer día de cada mes entre dos fechas (incluidas).</summary>
        public static List<DateOnly> Months(DateOnly from, DateOnly to)
        {
            var months = new List<DateOnly>();

            for (var month = new DateOnly(from.Year, from.Month, 1); month <= to; month = month.AddMonths(1))
            {
                months.Add(month);
            }

            return months;
        }
    }
}
```

> `TryParseStatus` es el de `GoldenRecognitionApprovalValidator` ([guía de aprobaciones](puntos-dorados-aprobaciones-api.md), Paso 3). Si haces el dashboard antes que las aprobaciones, copia ese método aquí.

---

## 6. Paso 4 — Lecturas: `IGoldenDashboardQueryRepository`

### `Contracts/Persistence/IGoldenDashboardQueryRepository.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Contracts.Persistence
{
    /// <summary>Filtros que no son fechas. null = sin filtro; una lista vacía = nadie.</summary>
    public sealed record GoldenDashboardScope(
        IReadOnlyCollection<int>? UserIds,
        IReadOnlyCollection<GoldenRecognitionStatus>? Statuses,
        IReadOnlyCollection<int>? CategoryIds);

    public sealed record GoldenStatusCount(GoldenRecognitionStatus Status, int Count);

    public sealed record GoldenMonthCount(int Year, int Month, int Count);

    public sealed record GoldenMonthPoints(int Year, int Month, GoldenPointsSource Source, int Points);

    public sealed record GoldenCategoryCount(int CategoryId, int Count);

    public sealed record GoldenDashboardCategory(int Id, string Name, string Icon, string Color, bool Active);

    /// <summary>
    /// Solo lectura y solo agregados: nada se trae a memoria fila por fila.
    /// Los rangos son [fromUtc, toUtc): incluye el inicio, excluye el final.
    /// </summary>
    public interface IGoldenDashboardQueryRepository
    {
        Task<IReadOnlyList<int>> GetUserIdsByEmailsAsync(IReadOnlyCollection<string> emails);

        /// <summary>Reconocimientos creados en el rango, por estado.</summary>
        Task<IReadOnlyList<GoldenStatusCount>> CountCreatedByStatusAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

        /// <summary>Reconocimientos aprobados en el rango (por fecha de aprobación).</summary>
        Task<int> CountApprovalsAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

        /// <summary>Puntos asignados en el rango: neto de créditos y ajustes manuales y de reconocimientos.</summary>
        Task<int> SumPointsAssignedAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

        /// <summary>Redenciones en el rango (débitos con origen Redención).</summary>
        Task<int> CountRedemptionsAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

        /// <summary>Reconocimientos creados por mes (hora de Colombia).</summary>
        Task<IReadOnlyList<GoldenMonthCount>> CountCreatedByMonthAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

        /// <summary>Puntos asignados por mes (hora de Colombia) y origen.</summary>
        Task<IReadOnlyList<GoldenMonthPoints>> SumPointsByMonthAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

        /// <summary>Reconocimientos creados en el rango, por categoría.</summary>
        Task<IReadOnlyList<GoldenCategoryCount>> CountCreatedByCategoryAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

        Task<IReadOnlyList<GoldenDashboardCategory>> GetRecognitionCategoriesAsync();
    }
}
```

### `Repositories/GoldenDashboardQueryRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using DOCCB.Infraestructure.Common;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Infraestructure.Repositories
{
    /// <summary>Tabla principal: golden_recognition. También lee golden_points_transaction y las categorías.</summary>
    public class GoldenDashboardQueryRepository(DOCCbDbContext context)
        : GenericRepositoryBase<DOCCbDbContext, GoldenRecognition>(context), IGoldenDashboardQueryRepository
    {
        public async Task<IReadOnlyList<int>> GetUserIdsByEmailsAsync(IReadOnlyCollection<string> emails)
        {
            var list = emails.ToList();

            return await _context.Set<User>()
                .AsNoTracking()
                .Where(u => list.Contains(u.CorportativeEmail))
                .Select(u => u.Id)
                .ToListAsync();
        }

        public async Task<IReadOnlyList<GoldenStatusCount>> CountCreatedByStatusAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
            await Recognitions(scope)
                .Where(r => r.CreatedDate >= fromUtc && r.CreatedDate < toUtc)
                .GroupBy(r => r.Status)
                .Select(g => new GoldenStatusCount(g.Key, g.Count()))
                .ToListAsync();

        public Task<int> CountApprovalsAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
            Recognitions(scope)
                .Where(r => r.Status == GoldenRecognitionStatus.Approved && r.ReviewedDate >= fromUtc && r.ReviewedDate < toUtc)
                .CountAsync();

        public async Task<int> SumPointsAssignedAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
            await AssignedPoints(scope, fromUtc, toUtc).SumAsync(t => (int?)t.Points) ?? 0;

        public Task<int> CountRedemptionsAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc)
        {
            var query = _context.Set<GoldenPointsTransaction>()
                .AsNoTracking()
                .Where(t => t.Type == GoldenPointsTransactionType.Debit
                    && t.Source == GoldenPointsSource.Redemption
                    && t.CreatedDate >= fromUtc
                    && t.CreatedDate < toUtc);

            if (scope.UserIds is { } userIds)
            {
                query = query.Where(t => userIds.Contains(t.UserId));
            }

            return query.CountAsync();
        }

        public async Task<IReadOnlyList<GoldenMonthCount>> CountCreatedByMonthAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
            await Recognitions(scope)
                .Where(r => r.CreatedDate >= fromUtc && r.CreatedDate < toUtc)
                .Select(r => r.CreatedDate.AddHours(GoldenClock.UtcOffsetHours)) // mes en hora de Colombia
                .GroupBy(local => new { local.Year, local.Month })
                .Select(g => new GoldenMonthCount(g.Key.Year, g.Key.Month, g.Count()))
                .ToListAsync();

        public async Task<IReadOnlyList<GoldenMonthPoints>> SumPointsByMonthAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
            await AssignedPoints(scope, fromUtc, toUtc)
                .Select(t => new { Local = t.CreatedDate.AddHours(GoldenClock.UtcOffsetHours), t.Source, t.Points })
                .GroupBy(x => new { x.Local.Year, x.Local.Month, x.Source })
                .Select(g => new GoldenMonthPoints(g.Key.Year, g.Key.Month, g.Key.Source, g.Sum(x => x.Points)))
                .ToListAsync();

        public async Task<IReadOnlyList<GoldenCategoryCount>> CountCreatedByCategoryAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
            await Recognitions(scope)
                .Where(r => r.CreatedDate >= fromUtc && r.CreatedDate < toUtc)
                .GroupBy(r => r.CategoryId)
                .Select(g => new GoldenCategoryCount(g.Key, g.Count()))
                .ToListAsync();

        public async Task<IReadOnlyList<GoldenDashboardCategory>> GetRecognitionCategoriesAsync() =>
            await _context.Set<GoldenRecognitionCategory>()
                .AsNoTracking()
                .Select(c => new GoldenDashboardCategory(c.Id, c.Name, c.Icon, c.Color, c.Active))
                .ToListAsync();

        // ── Bases con los filtros ──────────────────────────────────────

        /// <summary>Reconocimientos con los filtros de colaborador, estado y categoría (sin fechas).</summary>
        private IQueryable<GoldenRecognition> Recognitions(GoldenDashboardScope scope)
        {
            var query = _dbSet.AsNoTracking();

            if (scope.UserIds is { } userIds)
            {
                // La persona participa si lo recibió o lo creó.
                query = query.Where(r => userIds.Contains(r.NomineeUserId) || userIds.Contains(r.NominatorUserId));
            }

            if (scope.Statuses is { } statuses)
            {
                var pending = statuses.Contains(GoldenRecognitionStatus.Pending);
                var approved = statuses.Contains(GoldenRecognitionStatus.Approved);
                var rejected = statuses.Contains(GoldenRecognitionStatus.Rejected);

                // Comparaciones con OR en lugar de Contains: la columna tiene conversión enum ⇄ texto ('APPROVED').
                query = query.Where(r =>
                    (pending && r.Status == GoldenRecognitionStatus.Pending) ||
                    (approved && r.Status == GoldenRecognitionStatus.Approved) ||
                    (rejected && r.Status == GoldenRecognitionStatus.Rejected));
            }

            if (scope.CategoryIds is { } categoryIds)
            {
                query = query.Where(r => categoryIds.Contains(r.CategoryId));
            }

            return query;
        }

        /// <summary>Créditos y ajustes de asignaciones manuales y de reconocimientos, en el rango.</summary>
        private IQueryable<GoldenPointsTransaction> AssignedPoints(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc)
        {
            var query = _context.Set<GoldenPointsTransaction>()
                .AsNoTracking()
                .Where(t => (t.Type == GoldenPointsTransactionType.Credit || t.Type == GoldenPointsTransactionType.Adjustment)
                    && (t.Source == GoldenPointsSource.Manual || t.Source == GoldenPointsSource.Recognition)
                    && t.CreatedDate >= fromUtc
                    && t.CreatedDate < toUtc);

            if (scope.UserIds is { } userIds)
            {
                query = query.Where(t => userIds.Contains(t.UserId));
            }

            if (scope.CategoryIds is { } categoryIds)
            {
                // Las asignaciones manuales no tienen categoría: con este filtro quedan fuera.
                query = query.Where(t => t.Recognition != null && categoryIds.Contains(t.Recognition.CategoryId));
            }

            return query;
        }
    }
}
```

> **`Contains` con listas de enteros** (`userIds`, `categoryIds`): EF Core 8 lo traduce con `OPENJSON`, que requiere el nivel de compatibilidad 130 o mayor en SQL Server. Ya se usa así en las reacciones de reconocimientos; si allá funciona, aquí también.

### Registro — `InfrastructureServiceRegistration.cs` ✏️

Bajo `//Repositorios de consulta`:

```csharp
services.AddScoped<IGoldenDashboardQueryRepository, GoldenDashboardQueryRepository>();
```

---

## 7. Paso 5 — Servicio

### `Interfaces/IGoldenDashboardService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;     // ResponseDto<T>
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenDashboardService
    {
        Task<ResponseDto<GoldenDashboardDto>> GetAsync(GoldenDashboardQueryDto query, string currentUserEmail);
    }
}
```

### `Services/GoldenDashboardService.cs`

Solo lecturas: usa el repositorio de consulta sin helper, como las demás lecturas con agregados. Las consultas van **una tras otra**, porque comparten el `DbContext` de la petición y EF no permite dos consultas a la vez sobre el mismo.

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenDashboardService(IGoldenDashboardQueryRepository queryRepository) : IGoldenDashboardService
    {
        private readonly IGoldenDashboardQueryRepository _queryRepository = queryRepository;

        private static readonly GoldenRecognitionStatus[] StatusOrder =
        [
            GoldenRecognitionStatus.Pending,
            GoldenRecognitionStatus.Approved,
            GoldenRecognitionStatus.Rejected,
        ];

        public async Task<ResponseDto<GoldenDashboardDto>> GetAsync(GoldenDashboardQueryDto query, string currentUserEmail)
        {
            var errors = new List<string>();
            var filter = GoldenDashboardValidator.Normalize(query, GoldenClock.Today(), errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenDashboardDto>(errors);
            }

            // Permisos (pendiente): el mismo CanReviewAsync de la guía de aprobaciones, sección 9.
            // if (!await CanReviewAsync(currentUserEmail))
            // {
            //     throw new UnauthorizedAccessException();
            // }

            // Colaboradores: si se eligieron y ninguno existe, la lista queda vacía y el resultado es vacío (no "todos").
            IReadOnlyCollection<int>? userIds = filter.UserEmails.Count > 0
                ? await _queryRepository.GetUserIdsByEmailsAsync(filter.UserEmails)
                : null;

            var scope = new GoldenDashboardScope(userIds, filter.Statuses, filter.CategoryIds);

            // ── Períodos ────────────────────────────────────────────────
            var (previousFrom, previousTo) = GoldenDashboardValidator.PreviousPeriod(filter.From, filter.To);
            var trendFrom = GoldenDashboardValidator.TrendStart(filter.From, filter.To);

            var fromUtc = GoldenClock.StartOfDayUtc(filter.From);
            var toUtc = GoldenClock.StartOfDayUtc(filter.To.AddDays(1));          // "Hasta" incluido
            var previousFromUtc = GoldenClock.StartOfDayUtc(previousFrom);
            var previousToUtc = GoldenClock.StartOfDayUtc(previousTo.AddDays(1));
            var trendFromUtc = GoldenClock.StartOfDayUtc(trendFrom);

            // ── Tarjetas ────────────────────────────────────────────────
            var statusCounts = await _queryRepository.CountCreatedByStatusAsync(scope, fromUtc, toUtc);
            var previousCreated = (await _queryRepository.CountCreatedByStatusAsync(scope, previousFromUtc, previousToUtc)).Sum(x => x.Count);

            var approvals = await _queryRepository.CountApprovalsAsync(scope, fromUtc, toUtc);
            var previousApprovals = await _queryRepository.CountApprovalsAsync(scope, previousFromUtc, previousToUtc);

            var points = await _queryRepository.SumPointsAssignedAsync(scope, fromUtc, toUtc);
            var previousPoints = await _queryRepository.SumPointsAssignedAsync(scope, previousFromUtc, previousToUtc);

            var redemptions = await _queryRepository.CountRedemptionsAsync(scope, fromUtc, toUtc);
            var previousRedemptions = await _queryRepository.CountRedemptionsAsync(scope, previousFromUtc, previousToUtc);

            // ── Gráficas ────────────────────────────────────────────────
            var createdByMonth = await _queryRepository.CountCreatedByMonthAsync(scope, trendFromUtc, toUtc);
            var pointsByMonth = await _queryRepository.SumPointsByMonthAsync(scope, trendFromUtc, toUtc);
            var byCategory = await _queryRepository.CountCreatedByCategoryAsync(scope, fromUtc, toUtc);
            var categories = await _queryRepository.GetRecognitionCategoriesAsync();

            var months = GoldenDashboardValidator.Months(trendFrom, filter.To);

            var dashboard = new GoldenDashboardDto
            {
                Period = new GoldenDashboardPeriodDto
                {
                    From = filter.From,
                    To = filter.To,
                    PreviousFrom = previousFrom,
                    PreviousTo = previousTo,
                },
                Kpis = new GoldenDashboardKpisDto
                {
                    Recognitions = Kpi(statusCounts.Sum(x => x.Count), previousCreated),
                    Approvals = Kpi(approvals, previousApprovals),
                    PointsAssigned = Kpi(points, previousPoints),
                    Redemptions = Kpi(redemptions, previousRedemptions),
                },
                RecognitionsByMonth = months.Select(month => new GoldenDashboardMonthCountDto
                {
                    Month = month,
                    Count = createdByMonth.FirstOrDefault(x => x.Year == month.Year && x.Month == month.Month)?.Count ?? 0,
                }).ToList(),
                StatusDistribution = StatusOrder.Select(status => new GoldenDashboardStatusCountDto
                {
                    Status = GoldenRecognitionCodes.ToStatusCode(status),
                    Count = statusCounts.FirstOrDefault(x => x.Status == status)?.Count ?? 0,
                }).ToList(),
                RecognitionsByCategory = ByCategory(categories, byCategory, filter.CategoryIds),
                PointsByMonth = months.Select(month =>
                {
                    var inMonth = pointsByMonth.Where(x => x.Year == month.Year && x.Month == month.Month).ToList();
                    var recognition = inMonth.Where(x => x.Source == GoldenPointsSource.Recognition).Sum(x => x.Points);
                    var manual = inMonth.Where(x => x.Source == GoldenPointsSource.Manual).Sum(x => x.Points);

                    return new GoldenDashboardMonthPointsDto
                    {
                        Month = month,
                        RecognitionPoints = recognition,
                        ManualPoints = manual,
                        Total = recognition + manual,
                    };
                }).ToList(),
            };

            return ResponseDtoHelper.CreateSuccessResponseDto(dashboard);
        }

        // ── Privados ────────────────────────────────────────────────────

        private static GoldenDashboardKpiDto Kpi(int value, int previous) => new()
        {
            Value = value,
            Previous = previous,
            // Sin base de comparación no hay porcentaje: el frontend muestra "Nuevo" o nada.
            ChangePercent = previous == 0
                ? null
                : (int)Math.Round((value - previous) * 100m / previous, MidpointRounding.AwayFromZero),
        };

        /// <summary>
        /// Sin filtro: las activas (aunque estén en 0) y las inactivas con datos. Con filtro: solo las elegidas.
        /// De mayor a menor; los empates, por nombre.
        /// </summary>
        private static List<GoldenDashboardCategoryCountDto> ByCategory(
            IReadOnlyList<GoldenDashboardCategory> categories,
            IReadOnlyList<GoldenCategoryCount> counts,
            IReadOnlyCollection<int>? selected)
        {
            var countById = counts.ToDictionary(x => x.CategoryId, x => x.Count);

            return categories
                .Where(c => selected is null ? c.Active || countById.ContainsKey(c.Id) : selected.Contains(c.Id))
                .Select(c => new GoldenDashboardCategoryCountDto
                {
                    CategoryId = c.Id,
                    Name = c.Name,
                    Icon = c.Icon,
                    Color = c.Color,
                    Count = countById.GetValueOrDefault(c.Id),
                })
                .OrderByDescending(c => c.Count)
                .ThenBy(c => c.Name)
                .ToList();
        }
    }
}
```

> **Cuántas consultas son.** Doce consultas pequeñas, todas agregadas y con índice. Para un dashboard que se abre de vez en cuando está bien. Si algún día se vuelve lento, el primer paso es cachear la respuesta un minuto por combinación de filtros; no hace falta antes.

### Registro — `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IGoldenDashboardService, GoldenDashboardService>();
```

---

## 8. Paso 6 — Controlador

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenDashboardErrorMessage = "No se pudieron cargar las métricas de Puntos Dorados.";
```

### `Controllers/GoldenDashboardController.cs`

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: métricas del dashboard de administración.</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    // Permisos: pendiente (guía de aprobaciones, sección 9). La validación va en el servicio.
    public class GoldenDashboardController(IGoldenDashboardService service) : ControllerBase
    {
        private readonly IGoldenDashboardService _service = service;

        /// <summary>
        /// Tarjetas y gráficas. GET ?from=2026-05-01&amp;to=2026-10-07&amp;userEmails=…&amp;statuses=Aprobada&amp;categoryIds=1
        /// </summary>
        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Get([FromQuery] GoldenDashboardQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetAsync(query, authenticatedUserInfo.Email);
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
    }
}
```

> **Fecha mal escrita** (`from=07/10/2026`): el model binding no la puede leer y ASP.NET responde 400 antes de llegar a la acción. El frontend debe enviar `yyyy-MM-dd`, que es lo que da `<input type="date">`.

---

## 9. Contrato (para el frontend)

**Petición.** Las listas se envían repitiendo el parámetro. En Angular, con `HttpParams.append`:

```ts
let params = new HttpParams();
if (filters.from) params = params.set('from', filters.from);          // 'yyyy-MM-dd'
if (filters.to) params = params.set('to', filters.to);
filters.userEmails.forEach(email => (params = params.append('userEmails', email)));
filters.statuses.forEach(status => (params = params.append('statuses', status)));   // 'Pendiente' | 'Aprobada' | 'Rechazada'
filters.categoryIds.forEach(id => (params = params.append('categoryIds', id)));
```

**Respuesta** (`response`):

```json
{
  "period": { "from": "2026-10-01", "to": "2026-10-07", "previousFrom": "2026-09-01", "previousTo": "2026-09-07" },
  "kpis": {
    "recognitions":   { "value": 6,   "previous": 5,   "changePercent": 20 },
    "approvals":      { "value": 4,   "previous": 3,   "changePercent": 33 },
    "pointsAssigned": { "value": 450, "previous": 390, "changePercent": 15 },
    "redemptions":    { "value": 0,   "previous": 0,   "changePercent": null }
  },
  "recognitionsByMonth": [
    { "month": "2026-05-01", "count": 3 },
    { "month": "2026-06-01", "count": 1 },
    { "month": "2026-07-01", "count": 3 },
    { "month": "2026-08-01", "count": 4 },
    { "month": "2026-09-01", "count": 5 },
    { "month": "2026-10-01", "count": 6 }
  ],
  "statusDistribution": [
    { "status": "Pendiente", "count": 1 },
    { "status": "Aprobada", "count": 4 },
    { "status": "Rechazada", "count": 1 }
  ],
  "recognitionsByCategory": [
    { "categoryId": 1, "name": "Servicio", "icon": "fa-solid fa-handshake", "color": "#2563EB", "count": 3 },
    { "categoryId": 2, "name": "Cumplimiento", "icon": "fa-solid fa-circle-check", "color": "#16A34A", "count": 2 },
    { "categoryId": 3, "name": "Reconocimiento", "icon": "fa-solid fa-medal", "color": "#EA580C", "count": 1 },
    { "categoryId": 4, "name": "La Sacaste del Estadio", "icon": "fa-solid fa-futbol", "color": "#CA8A04", "count": 0 }
  ],
  "pointsByMonth": [
    { "month": "2026-05-01", "recognitionPoints": 120, "manualPoints": 0,   "total": 120 },
    { "month": "2026-06-01", "recognitionPoints": 150, "manualPoints": 0,   "total": 150 },
    { "month": "2026-07-01", "recognitionPoints": 0,   "manualPoints": 0,   "total": 0 },
    { "month": "2026-08-01", "recognitionPoints": 0,   "manualPoints": 0,   "total": 0 },
    { "month": "2026-09-01", "recognitionPoints": 300, "manualPoints": 90,  "total": 390 },
    { "month": "2026-10-01", "recognitionPoints": 350, "manualPoints": 100, "total": 450 }
  ]
}
```

> En este ejemplo el período es del 1 al 7 de octubre, así que octubre en las gráficas es igual a las tarjetas: 6 reconocimientos (suma de la dona y de las categorías) y 450 puntos.

| Pieza de la pantalla | Cómo usar la respuesta |
|---|---|
| Badge `+12%` | `changePercent`: verde si es mayor que 0, rojo si es menor, sin badge (o "Nuevo") si es `null`. |
| Eje de los meses | `month` es una fecha sin hora: `parseDateOnly` (no `parseUtc`) y formato `MMM-yy`. |
| Dona | Usa `statusDistribution` tal cual: siempre trae los tres estados, en el mismo orden. |
| Barras de categoría | `color` es el color de la categoría, si quieres usarlo en lugar del dorado fijo. |
| Puntos por mes | `total` para una barra; `recognitionPoints` + `manualPoints` para barras apiladas. |
| Período usado | `period` dice qué fechas se aplicaron (con los valores por defecto) y contra qué se comparó. |
| Opciones del modal | Colaboradores: la lista de personas que ya carga el componente. Estados: fijos. Categorías: el endpoint de categorías de reconocimiento que ya existe. No hace falta otro endpoint. |

---

## 10. Pruebas

**Sin filtros**
- `period` = del 1 del mes a hoy; `previousFrom`/`previousTo` = el mismo tramo del mes anterior.
- `recognitionsByMonth` y `pointsByMonth` traen 6 meses, los vacíos en 0.
- `statusDistribution` trae los tres estados aunque alguno esté en 0, y su suma es igual a `kpis.recognitions.value`.

**Fechas**
- `from=2026-05-01&to=2026-10-07` → la tendencia empieza en mayo.
- `from=2025-01-01&to=2026-10-07` → la tendencia empieza en enero de 2025 (rango completo).
- **Borde del día:** un reconocimiento creado el 7 de octubre a las 11 p. m. en Colombia (8 de octubre 04:00 UTC) cuenta el **7**, y en el mes de octubre.
- `from` después de `to` → `hasError`. Un rango de 25 meses → `hasError`.

**Comparación**
- Período anterior en 0 → `changePercent: null`.
- 36 contra 32 → `13` (12,5 se redondea alejándose de cero).
- Menos que el anterior → número negativo.

**Filtros**
- **Un colaborador** → solo los reconocimientos que recibió o creó, sus puntos y sus redenciones.
- **Un correo que no existe** → todo en 0 (no las métricas de toda la empresa).
- `statuses=Pendiente` → aprobaciones en 0 y la dona con solo pendientes; los puntos no cambian.
- `categoryIds=1` → los puntos excluyen las asignaciones manuales; redenciones sin cambio.
- `statuses=Otro` → `hasError`.

**Coherencia con otras pantallas**
- `pointsAssigned` de un colaborador en un rango = la suma de sus créditos y ajustes en "Mis puntos" para esas fechas.
- Aprobar un reconocimiento (guía de aprobaciones) sube `approvals` del día y, si tiene puntos, `pointsAssigned`.

---

## ✅ Checklist

- [ ] `GoldenDashboardIndexes.sql` ejecutado.
- [ ] `GoldenClock` con `UtcOffsetHours` y `StartOfDayUtc` (`Today()` sin cambios).
- [ ] `TryParseStatus` disponible (guía de aprobaciones o copiado).
- [ ] `IGoldenDashboardQueryRepository` bajo `//Repositorios de consulta`; `IGoldenDashboardService` en `ApplicationServiceRegistration.cs`.
- [ ] Controlador con `try/catch` completo.
- [ ] Permisos comentados, igual que aprobaciones. **No publicar sin activarlos.**
- [ ] Probado el borde del día (11 p. m. en Colombia).
- [ ] Probado el correo inexistente (resultado vacío, no "todos").
