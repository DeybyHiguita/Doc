# 🧹 Puntos Dorados — Repositorios: qué sobra y cómo quitarlo

**Contexto:** los primeros módulos de Puntos Dorados se hicieron antes de conocer bien el `UnitOfWork` y el `IGenericRepository` del proyecto. Por eso se crearon repositorios de consulta para cosas que el genérico ya resuelve, y quedó código que nadie usa.

Esta guía revisa el código real de `.claude/Puntos dorados api`. Para cada repositorio dice qué se queda, qué sobra y cómo quitarlo **sin cambiar las respuestas de la API**: el frontend no se toca.

**Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md) (sección "Unit of Work y repositorio genérico") y [ARQUITECTURA Y EJEMPLO.MD](.claude/ARQUITECTURA%20Y%20EJEMPLO.MD), sección 5.

---

## 1. La regla

**Por defecto, el repositorio genérico** (`ITransactionExecutorHelper` + `unitOfWork.Repository<T>()`). Un repositorio propio solo cuando:

| Se queda en un repositorio propio | Ejemplo en Puntos Dorados |
|---|---|
| **Agregados sobre muchas filas:** sumas, conteos o `GroupBy` de todo un período o de todo un historial. | Dashboard (KPIs y gráficas), resumen de "Mis puntos" (ganado, usado, vencido). |
| **Una consulta que comparte la base de filtros con esos agregados**, para que siempre coincidan. | La tabla "Reconocimientos del período" usa el mismo `Recognitions(scope)` que los KPIs. |
| **La misma consulta en varios servicios.** | `IUserSearchRepository` (lo comparten el buscador de grupos y el de personas). |

**La prueba práctica:** ¿con el genérico tendría que traer muchas filas a memoria para contar o sumar, o encadenar LINQ sobre `Query()` en el servicio? Si la respuesta es no, va con el genérico.

### Lo que el genérico ya resuelve (y antes no sabíamos)

| Necesidad | Método genérico |
|---|---|
| Página con filtro, orden calculado, total y personas o categoría | `GetPagedListAsync(filtro, orderBy, includes: …, pageNumber, pageSize)`. Es lo que ya usa Aprobaciones. |
| Una fila por id con sus relaciones | `GetAsync(filtro, includes: …)` |
| Proyectar solo unas columnas, `Take`, `Distinct` | `GetListAsync(filtro, selector: q => q.Select(…))` |
| Contar por grupo **los ids de una página** (máximo 50) | `GetListAsync(filtro, selector: q => q.GroupBy(…).Select(…))`. Se ejecuta en SQL, sin `Query()`. |
| ¿Existe? | `AnyAsync(filtro)` |

> **`GroupBy` acotado vs. `GroupBy` de un período.** La sección 5 de ARQUITECTURA manda los `GroupBy` a un repositorio porque "no hay método genérico para eso". Pero el `selector` de `GetListAsync<TResult>` recibe el `IQueryable` ya filtrado y acepta cualquier LINQ que se traduzca a SQL.
> - **Contar las reacciones de los 10 reconocimientos de una página:** cabe en un `selector`.
> - **Contar todos los reconocimientos de 24 meses por mes y por categoría:** es un repositorio.
>
> Las convenciones quedan actualizadas con esta distinción.

---

## 2. Inventario y veredicto

### `GoldenRecognitionQueryRepository` → **se elimina completo**

| Método | Lo usa | Veredicto | Reemplazo |
|---|---|---|---|
| `GetUserIdByEmailAsync` | 5 lecturas del servicio | ❌ Búsqueda simple, y está **repetida** en los 3 repositorios | `GetListAsync(selector: Select(u => u.Id))` |
| `GetFeedPageAsync(categoryId, page, pageSize)` | **Nadie** | ❌ **Código muerto**: lo reemplazó la sobrecarga con más filtros | — |
| `GetFeedPageAsync(categoryId, nomineeUserId, from, …)` | `GetFeedAsync` | ❌ Página + filtros + orden | `GetPagedListAsync` + `WithCard` |
| `GetSentPageAsync` | `GetSentAsync` | ❌ Página + filtro | `GetPagedListAsync` + `WithCard` |
| `GetReceivedPageAsync` | `GetReceivedAsync` | ❌ Página + filtro | `GetPagedListAsync` + `WithCard` |
| `GetReviewPageAsync` | `GetForReviewAsync` (endpoint viejo) | ❌ **Código muerto** (sección 3) | — |
| `GetRowAsync` | Después de crear y de editar | ❌ Una fila con relaciones | `GetAsync` + `WithCard` |
| `GetPointsExpirationsAsync` | "Mis reconocimientos" | ❌ Proyección simple | `GetListAsync` + `selector` |
| `GetReactionCountsAsync` | Feed y reacciones | ❌ `GroupBy` acotado a los ids de una página | `GetListAsync` + `selector` con `GroupBy` |
| `GetUserReactionsAsync` | Feed y reacciones | ❌ Proyección simple | `GetListAsync` + `selector` |

**Además, mezcla los dos estilos:** el servicio escribe con el helper (un `DbContext` por llamada), pero lee con un repositorio que recibe el `DbContext` de la petición. Al pasar todo al helper queda un solo estilo, igual que en Aprobaciones.

### `GoldenPointsQueryRepository` → **se queda, pero solo con el resumen**

| Método | Veredicto | Reemplazo |
|---|---|---|
| `GetSummaryAsync` | ✅ **Se queda**: 5 sumas en SQL sobre todo el historial de la persona | — |
| `GetUpcomingExpirationsAsync` | ✅ **Se queda**: se lee siempre junto con el resumen | — |
| `GetUserAsync` | ❌ Búsqueda repetida | `GetListAsync` + `selector` |
| `GetTransactionsPageAsync` | ❌ Página + filtros + 4 relaciones | `GetPagedListAsync` + `includes` |
| `GetTransactionAsync` | ❌ Una fila con relaciones | `GetAsync` + `includes` |
| `GetUserIdsWithDuePointsAsync` | ❌ `Select` + `Distinct` | `GetListAsync` + `selector` |

### `GoldenDashboardQueryRepository` → **se queda**

| Método | Veredicto |
|---|---|
| Los 9 agregados (`CountCreatedByStatusAsync`, `SumPointsByMonthAsync`, `CountRecognizedUsersAsync`…) | ✅ `GroupBy`, `Sum` y `Count` sobre todo el período |
| `GetRecognitionsPageAsync` | ✅ Usa la misma base de filtros que los KPIs (`Recognitions(scope)`), y así la tabla y las tarjetas siempre coinciden |
| `GetUserIdsByEmailsAsync` | ❌ Búsqueda repetida → genérico |
| `GetRecognitionCategoriesAsync` | ❌ Lista simple → genérico |

### `UserSearchRepository` → **se queda**

Ya existía y lo comparte el buscador de grupos. `GoldenPeopleService` lo reutiliza bien.

### Resultado

| | Antes | Después |
|---|---|---|
| Repositorios de consulta de Puntos Dorados | 3 | 2 |
| Métodos en esos repositorios | 28 | 12 |
| Búsquedas de usuario por correo | En 3 repositorios distintos, además del servicio | Solo en el servicio que la necesita, con el genérico |

---

## 3. Otras cosas que sobran

| # | Qué | Dónde | Por qué sobra |
|---|---|---|---|
| 1 | **El admin viejo de reconocimientos:** `GET review`, `POST {id}/approve`, `POST {id}/reject` | `GoldenRecognitionsController`, `IGoldenRecognitionService` y `GoldenRecognitionService` (`GetForReviewAsync`, `ApproveAsync`, `RejectAsync`, `ReviewAsync`, `ToDtosWithExpirationAsync`) | El frontend aprueba con `GoldenRecognitionApprovals`. Además, este `ApproveAsync` **abona puntos con su propia regla**: si alguien lo llama, queda una aprobación distinta de la oficial (sin comentario, sin `row_version`). Es un riesgo, no solo código de más. |
| 2 | Lo que solo usaba ese admin viejo | `GoldenRecognitionCodes.TryParseStatusFilter` y las constantes `StatusFilterInvalid`, `AlreadyReviewed` y `PointsInvalid` de `GoldenRecognitionConstants` | Quedan sin uso. |
| 3 | `GoldenProductAvailability.Today()` | `GoldenProductAvailability` y 6 usos en `GoldenProductService` | Hace lo mismo que `GoldenClock.Today()`. Debe haber una sola definición de "hoy en Colombia". |
| 4 | `WithCard` privado | `GoldenRecognitionApprovalService` | Ahora lo necesitan dos servicios: pasa a un helper compartido. |
| 5 | `using System; using System.Text; …` de plantilla | Varios archivos de Puntos Dorados | La convención dice "sin usings de plantilla". Opcional: Visual Studio los quita con *Quitar y ordenar usings*. |

---

## 4. Antes de empezar: guarda las respuestas actuales

Nada de esto debe cambiar lo que responde la API. Antes de tocar código, guarda en Swagger o Postman (con el mismo usuario) la respuesta de:

- `GET /api/GoldenRecognitions/feed?page=1&pageSize=10`, la misma con `categoryId`, y con `nomineeEmail` y `from`.
- `GET /api/GoldenRecognitions/sent` y `/received`.
- `GET /api/GoldenRecognitions/{id}/reactions` (uno del feed).
- `GET /api/GoldenPoints/me/summary` y `/me/transactions`.
- `GET /api/GoldenPoints/transactions?email=…` y `/summary?email=…` (admin).
- `GET /api/GoldenDashboard` con un colaborador y una categoría en los filtros.

Al final (sección 12) se comparan.

---

## 5. Paso 1 — Borrar el admin viejo de reconocimientos

1. **`WebApp/Controllers/GoldenRecognitionsController.cs`:** borra las acciones `GetForReview` (`[HttpGet("review")]`), `Approve` (`[HttpPost("{id:int}/approve")]`) y `Reject` (`[HttpPost("{id:int}/reject")]`), con sus comentarios "⬇ Permiso de administración".
2. **`IGoldenRecognitionService.cs`:** borra `GetForReviewAsync`, `ApproveAsync` y `RejectAsync`.
3. **`GoldenRecognitionService.cs`:** borra:
   - toda la sección "── Administración ──" (`GetForReviewAsync`, `ApproveAsync`, `RejectAsync`);
   - el método privado `ReviewAsync`, con su ciclo de reintentos;
   - `ToDtosWithExpirationAsync`.
4. **Compila** y busca lo que quedó sin uso:

   ```bash
   grep -rn "TryParseStatusFilter\|StatusFilterInvalid\|AlreadyReviewed\|GoldenRecognitionConstants.PointsInvalid" --include='*.cs' .
   ```

   Si solo aparecen sus definiciones, bórralas de `GoldenRecognitionCodes` y `GoldenRecognitionConstants`.

> `ApproveGoldenRecognitionDto` **se queda**: lo usa `GoldenRecognitionApprovalsController`.

---

## 6. Paso 2 — Piezas compartidas

### `Features/GoldenPoints/Application/Helpers/GoldenRecognitionQueries.cs` (nuevo)

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Query;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenRecognitionQueries
    {
        /// <summary>Lo que necesita una tarjeta de reconocimiento: las dos personas y la categoría.</summary>
        public static IIncludableQueryable<GoldenRecognition, object> WithCard(IQueryable<GoldenRecognition> query) =>
            query.Include(r => r.Nominee).Include(r => r.Nominator).Include(r => r.Category);
    }
}
```

### `GoldenRecognitionApprovalService.cs` ✏️

- Borra el método privado `WithCard`.
- Cambia `includes: WithCard` por `includes: GoldenRecognitionQueries.WithCard` (en la lista, `GetPagedListAsync`, y en `LoadForReviewAsync`).

### `Features/GoldenPoints/Application/Dtos/GoldenRecognitionRows.cs` (nuevo)

Los registros salen del archivo del repositorio, que se va a borrar. Solo se mueven dos: `GoldenRecognitionPage` y `GoldenUserReaction` ya no hacen falta.

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>Un reconocimiento con sus personas y su categoría, listo para mapear a los DTO.</summary>
    public sealed record GoldenRecognitionRow(
        int Id,
        int NomineeId, string NomineeName, string NomineeEmail, string NomineeArea,
        int NominatorId, string NominatorName, string NominatorEmail, string NominatorArea,
        string Reason,
        int CategoryId, string CategoryName, string CategoryIcon, string CategoryColor,
        GoldenRecognitionStatus Status,
        GoldenRecognitionVisibility Visibility,
        int? PointsAssigned,
        DateTime CreatedDate,
        DateTime? ReviewedDate);

    public sealed record GoldenReactionCount(int RecognitionId, GoldenReactionType ReactionType, int Count);
}
```

### `Helpers/GoldenRecognitionMapper.cs` ✏️

- **Usings:** quita `using DOCCB.Application.Contracts.Persistence;` y agrega `using DOCCB.Domain.Entities;`.
- **Método nuevo**, junto a `ToDto` (lo que antes hacía la proyección `ToRow` del repositorio):

```csharp
/// <summary>Entidad cargada con WithCard → fila. Antes lo hacía la proyección del repositorio.</summary>
public static GoldenRecognitionRow ToRow(GoldenRecognition r) => new(
    r.Id,
    r.NomineeUserId, r.Nominee.DisplayName, r.Nominee.CorportativeEmail,
    // User no tiene área y UsersArea no está mapeada en EF: por ahora va vacía.
    string.Empty,
    r.NominatorUserId, r.Nominator.DisplayName, r.Nominator.CorportativeEmail, string.Empty,
    r.Reason,
    r.CategoryId, r.Category.Name, r.Category.Icon, r.Category.Color,
    r.Status,
    r.Visibility,
    r.PointsAssigned,
    r.CreatedDate,
    r.ReviewedDate);
```

`ToDto`, `ToFeedItem` y `ToReactionSummary` no cambian.

---

## 7. Paso 3 — `GoldenRecognitionService` con el genérico

### Constructor y usings

```csharp
using System.Linq.Expressions;
// … los demás quedan

public class GoldenRecognitionService(ITransactionExecutorHelper transactionHelper) : IGoldenRecognitionService
{
    private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
```

(Sale `IGoldenRecognitionQueryRepository` y el campo `_queryRepository`.)

### Privados nuevos — reemplazan `BuildReactionSummariesAsync`

Van al final de la clase, junto a `FindUserByEmailAsync` (que se queda para las escrituras). Borra `BuildReactionSummariesAsync`.

```csharp
// ── Lecturas con el repositorio genérico ───────────────────────────

/// <summary>Id del usuario por el correo, sin traer la fila completa.</summary>
private static async Task<int?> FindUserIdAsync(IUnitOfWork unitOfWork, string email) =>
    (await unitOfWork.Repository<User>().GetListAsync(
        u => u.CorportativeEmail == email,
        selector: q => q.Select(u => (int?)u.Id).Take(1)))
    .FirstOrDefault();

/// <summary>Una página con personas y categoría (igual que Aprobaciones). El total sale en la misma llamada.</summary>
private static async Task<(List<GoldenRecognitionRow> Rows, int TotalCount)> LoadPageAsync(
    IUnitOfWork unitOfWork,
    Expression<Func<GoldenRecognition, bool>> filter,
    Func<IQueryable<GoldenRecognition>, IOrderedQueryable<GoldenRecognition>> orderBy,
    int page,
    int pageSize)
{
    // Página y tamaño ya validados con GoldenRecognitionValidator.Paging: GetPagedListAsync no los revisa.
    var result = await unitOfWork.Repository<GoldenRecognition>().GetPagedListAsync(
        filter,
        orderBy,
        includes: GoldenRecognitionQueries.WithCard,
        pageNumber: page,
        pageSize: pageSize);

    return (result.Data.Select(GoldenRecognitionMapper.ToRow).ToList(), result.TotalRecords);
}

/// <summary>Una fila por id, después de guardar (para responder con nombres y categoría).</summary>
private Task<GoldenRecognitionRow?> LoadRowAsync(int recognitionId) =>
    _transactionHelper.ExecuteQueryAsync<GoldenRecognitionRow>(async unitOfWork =>
    {
        var recognition = await unitOfWork.Repository<GoldenRecognition>().GetAsync(
            r => r.Id == recognitionId,
            includes: GoldenRecognitionQueries.WithCard);

        return recognition is null ? null : GoldenRecognitionMapper.ToRow(recognition);
    });

/// <summary>Vencimiento del lote que abonó cada reconocimiento: una consulta para toda la página.</summary>
private static async Task<Dictionary<int, DateOnly>> LoadPointsExpirationsAsync(IUnitOfWork unitOfWork, IReadOnlyCollection<int> recognitionIds)
{
    if (recognitionIds.Count == 0)
    {
        return new Dictionary<int, DateOnly>();
    }

    var ids = recognitionIds.ToList();

    // Un reconocimiento abona una sola vez (ux_golden_points_transaction_recognition_credit).
    var rows = await unitOfWork.Repository<GoldenPointsBucket>().GetListAsync(
        b => b.Transaction.RecognitionId != null
             && ids.Contains(b.Transaction.RecognitionId.Value)
             && b.Transaction.Type == GoldenPointsTransactionType.Credit,
        selector: q => q.Select(b => new { RecognitionId = b.Transaction.RecognitionId!.Value, b.ExpiresDate }));

    return rows.ToDictionary(r => r.RecognitionId, r => r.ExpiresDate);
}

/// <summary>Conteos y "mis reacciones" de los reconocimientos de una página: dos consultas en total.</summary>
private static async Task<Dictionary<int, GoldenReactionSummaryDto>> LoadReactionSummariesAsync(
    IUnitOfWork unitOfWork, IReadOnlyCollection<int> recognitionIds, int userId)
{
    var ids = recognitionIds.Distinct().ToList();
    if (ids.Count == 0)
    {
        return new Dictionary<int, GoldenReactionSummaryDto>();
    }

    var reactions = unitOfWork.Repository<GoldenRecognitionReaction>();

    // GROUP BY en SQL, acotado a los ids de la página (usa ix_golden_recognition_reaction_counts).
    var counts = await reactions.GetListAsync(
        x => ids.Contains(x.RecognitionId),
        selector: q => q
            .GroupBy(x => new { x.RecognitionId, x.ReactionType })
            .Select(g => new GoldenReactionCount(g.Key.RecognitionId, g.Key.ReactionType, g.Count())));

    var mine = await reactions.GetListAsync(
        x => x.UserId == userId && ids.Contains(x.RecognitionId),
        selector: q => q.Select(x => new { x.RecognitionId, x.ReactionType }));

    return ids.ToDictionary(
        id => id,
        id => GoldenRecognitionMapper.ToReactionSummary(
            id,
            counts,
            mine.Where(x => x.RecognitionId == id).Select(x => x.ReactionType)));
}

/// <summary>Lo mismo en su propia lectura (después de agregar o quitar una reacción).</summary>
private async Task<Dictionary<int, GoldenReactionSummaryDto>> ReactionSummariesAsync(IReadOnlyCollection<int> recognitionIds, int userId) =>
    await _transactionHelper.ExecuteQueryAsync<Dictionary<int, GoldenReactionSummaryDto>>(async unitOfWork =>
        await LoadReactionSummariesAsync(unitOfWork, recognitionIds, userId))
    ?? new Dictionary<int, GoldenReactionSummaryDto>();
```

> **¿Por qué `includes:` con nombre?** `GetPagedListAsync` y `GetAsync` tienen sobrecargas con `includeList` y con `includes`. Sin el nombre, la llamada es ambigua (CS0121).
>
> **Tipos anónimos en el `selector`:** C# deduce `TResult` del `Select`. No hace falta crear un registro para cada proyección interna.

### `CreateAsync` y `UpdateAsync` ✏️

En los dos, la lectura después de guardar cambia de:

```csharp
var row = await _queryRepository.GetRowAsync(created.Id);    // CreateAsync
var row = await _queryRepository.GetRowAsync(recognitionId); // UpdateAsync
```

a:

```csharp
var row = await LoadRowAsync(created.Id);    // CreateAsync
var row = await LoadRowAsync(recognitionId); // UpdateAsync
```

### `GetSentAsync` ✏️

```csharp
public async Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>> GetSentAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail)
{
    var (page, pageSize) = GoldenRecognitionValidator.Paging(query);

    return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>>(async unitOfWork =>
    {
        var userId = await FindUserIdAsync(unitOfWork, currentUserEmail);
        if (userId is null)
        {
            return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>(GoldenRecognitionConstants.UserNotRegistered);
        }

        var nominatorId = userId.Value;
        var (rows, total) = await LoadPageAsync(
            unitOfWork,
            r => r.NominatorUserId == nominatorId,
            q => q.OrderByDescending(r => r.CreatedDate).ThenByDescending(r => r.Id),
            page,
            pageSize);

        // Quien reconoce ve el estado, pero no los puntos de su compañero.
        return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(
            rows.Select(row => GoldenRecognitionMapper.ToDto(row, includePoints: false)),
            page, pageSize, total));
    }) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>(GoldenRecognitionConstants.UnexpectedError);
}
```

### `GetReceivedAsync` ✏️

```csharp
public async Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>> GetReceivedAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail)
{
    var (page, pageSize) = GoldenRecognitionValidator.Paging(query);

    return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>>(async unitOfWork =>
    {
        var userId = await FindUserIdAsync(unitOfWork, currentUserEmail);
        if (userId is null)
        {
            return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>(GoldenRecognitionConstants.UserNotRegistered);
        }

        var nomineeId = userId.Value;
        var (rows, total) = await LoadPageAsync(
            unitOfWork,
            r => r.NomineeUserId == nomineeId && r.Status == GoldenRecognitionStatus.Approved,
            q => q.OrderByDescending(r => r.CreatedDate).ThenByDescending(r => r.Id),
            page,
            pageSize);

        var expirations = await LoadPointsExpirationsAsync(unitOfWork, rows.Select(row => row.Id).ToList());

        // Son suyos: aquí sí ve los puntos y cuándo vencen.
        return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(
            rows.Select(row =>
            {
                var dto = GoldenRecognitionMapper.ToDto(row, includePoints: true);
                dto.PointsExpiresAt = expirations.TryGetValue(row.Id, out var expiresAt) ? expiresAt : null;
                return dto;
            }),
            page, pageSize, total));
    }) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>(GoldenRecognitionConstants.UnexpectedError);
}
```

### `GetFeedAsync` ✏️

```csharp
public async Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionFeedItemDto>>> GetFeedAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail)
{
    var (page, pageSize) = GoldenRecognitionValidator.Paging(query);
    var nomineeEmail = query.NomineeEmail?.Trim().ToLowerInvariant();
    var categoryId = query.CategoryId;

    // Período: desde las 00:00 de ese día en Colombia, en UTC (reviewed_date se guarda en UTC).
    DateTime? approvedFromUtc = query.From is { } from ? GoldenClock.StartOfDayUtc(from) : null;

    return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenPagedResultDto<GoldenRecognitionFeedItemDto>>>(async unitOfWork =>
    {
        var userId = await FindUserIdAsync(unitOfWork, currentUserEmail);
        if (userId is null)
        {
            return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionFeedItemDto>>(GoldenRecognitionConstants.UserNotRegistered);
        }

        int? nomineeUserId = null;
        if (!string.IsNullOrEmpty(nomineeEmail))
        {
            nomineeUserId = await FindUserIdAsync(unitOfWork, nomineeEmail);
            if (nomineeUserId is null)
            {
                // Persona que no existe: página vacía, no "todos".
                return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(Enumerable.Empty<GoldenRecognitionFeedItemDto>(), page, pageSize, 0));
            }
        }

        // Un filtro en null no llega al SQL: EF Core arma la consulta según si el parámetro viene o no.
        var (rows, total) = await LoadPageAsync(
            unitOfWork,
            r => r.Status == GoldenRecognitionStatus.Approved
                 && r.Visibility == GoldenRecognitionVisibility.Public
                 && (categoryId == null || r.CategoryId == categoryId)
                 && (nomineeUserId == null || r.NomineeUserId == nomineeUserId)
                 && (approvedFromUtc == null || r.ReviewedDate >= approvedFromUtc),
            // Usa ix_golden_recognition_feed. Lo recién aprobado arriba.
            q => q.OrderByDescending(r => r.ReviewedDate).ThenByDescending(r => r.Id),
            page,
            pageSize);

        var summaries = await LoadReactionSummariesAsync(unitOfWork, rows.Select(row => row.Id).ToList(), userId.Value);

        return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(
            rows.Select(row => GoldenRecognitionMapper.ToFeedItem(row, summaries[row.Id])),
            page, pageSize, total));
    }) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionFeedItemDto>>(GoldenRecognitionConstants.UnexpectedError);
}
```

### `GetReactionsAsync` ✏️

```csharp
public async Task<ResponseDto<GoldenReactionSummaryDto>> GetReactionsAsync(int recognitionId, string currentUserEmail) =>
    await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenReactionSummaryDto>>(async unitOfWork =>
    {
        var userId = await FindUserIdAsync(unitOfWork, currentUserEmail);
        if (userId is null)
        {
            return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.UserNotRegistered);
        }

        // Solo se reacciona a lo que está en el feed: aprobado y público.
        var inFeed = await unitOfWork.Repository<GoldenRecognition>().AnyAsync(r =>
            r.Id == recognitionId
            && r.Status == GoldenRecognitionStatus.Approved
            && r.Visibility == GoldenRecognitionVisibility.Public);

        if (!inFeed)
        {
            return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.RecognitionNotInFeed);
        }

        var summaries = await LoadReactionSummariesAsync(unitOfWork, [recognitionId], userId.Value);
        return ResponseDtoHelper.CreateSuccessResponseDto(summaries[recognitionId]);
    }) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.UnexpectedError);
```

### `AddReactionAsync` y `RemoveReactionAsync` ✏️

En los dos, la última lectura cambia de nombre:

```csharp
var summaries = await ReactionSummariesAsync([recognitionId], userId!.Value);
```

En el `catch` de `AddReactionAsync` (el doble clic), cambia la consulta del repositorio:

```csharp
catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException && userId is not null)
{
    // Doble clic: otra petición insertó la misma reacción y chocó con el índice único.
    // Si la reacción existe, el resultado es el que el usuario quería; si no, el error era otro.
    var reactorId = userId.Value;
    var exists = await _transactionHelper.ExecuteQueryAsync<bool>(async unitOfWork =>
        await unitOfWork.Repository<GoldenRecognitionReaction>().AnyAsync(x =>
            x.RecognitionId == recognitionId && x.UserId == reactorId && x.ReactionType == type));

    if (!exists)
    {
        throw;
    }
}
```

---

## 8. Paso 4 — Borrar `GoldenRecognitionQueryRepository`

1. **Borra los archivos:**
   - `Application/Contracts/Persistence/IGoldenRecognitionQueryRepository.cs`
   - `Infraestructure/Repositories/GoldenRecognitionQueryRepository.cs`
2. **En `InfrastructureServiceRegistration.cs`, borra la línea:**

   ```csharp
   services.AddScoped<IGoldenRecognitionQueryRepository, GoldenRecognitionQueryRepository>();
   ```

3. **Compila.** Si algo todavía usa `GoldenRecognitionRow` o `GoldenReactionCount` con `using DOCCB.Application.Contracts.Persistence;`, agrega `using DOCCB.Application.Features.GoldenPoints.Application.Dtos;`.

---

## 9. Paso 5 — `GoldenPointsQueryRepository`: solo el resumen

### `IGoldenPointsQueryRepository.cs` ✏️

- **Registros:** se quedan `GoldenPointsUserRow`, `GoldenPointsTransactionRow`, `GoldenPointsSummaryRow` y `GoldenPointsBucketRow`. Borra `GoldenPointsTransactionPage`.
- **Interfaz:** queda así:

```csharp
/// <summary>
/// Solo los agregados de "Mis puntos": sumas sobre todo el historial de la persona y sus próximos vencimientos.
/// Lo demás va por el repositorio genérico. Los movimientos se registran con GoldenPointsLedger.
/// </summary>
public interface IGoldenPointsQueryRepository
{
    Task<GoldenPointsSummaryRow> GetSummaryAsync(int userId, DateOnly today, DateOnly expiringUntil);

    Task<IReadOnlyList<GoldenPointsBucketRow>> GetUpcomingExpirationsAsync(int userId, DateOnly today, int take);
}
```

### `GoldenPointsQueryRepository.cs` ✏️

Borra la expresión `ToRow` y los métodos `GetUserAsync`, `GetTransactionsPageAsync`, `GetTransactionAsync` y `GetUserIdsWithDuePointsAsync`. Cambia el resumen de la clase:

```csharp
/// <summary>Agregados de "Mis puntos" sobre golden_points_transaction y golden_points_bucket. Solo lecturas sin seguimiento.</summary>
```

### `Helpers/GoldenPointsMapper.cs` ✏️ — agrega

```csharp
/// <summary>Movimiento cargado con sus relaciones → fila. Antes lo hacía la proyección del repositorio.</summary>
public static GoldenPointsTransactionRow ToRow(GoldenPointsTransaction t) => new(
    t.Id,
    t.UserId,
    t.User.DisplayName,
    t.User.CorportativeEmail,
    t.Type,
    t.Source,
    t.Points,
    t.BalanceAfter,
    t.Concept,
    t.RecognitionId,
    t.Recognition?.Category.Name,
    t.ReversesTransactionId,
    t.ReversedBy != null,
    t.Bucket?.RemainingPoints,
    t.Bucket?.ExpiresDate,
    t.CreatedDate,
    t.CreatedBy);
```

(Agrega `using DOCCB.Domain.Entities;` si el mapper no lo tiene.)

### `GoldenPointsService.cs` ✏️

**Usings:**

```csharp
using DOCCB.Application.Common.DTOs;          // PaginatedResponseDto
using Microsoft.EntityFrameworkCore;          // Include, ThenInclude
using Microsoft.EntityFrameworkCore.Query;    // IIncludableQueryable
```

**Privados nuevos** (en la sección "── Privados ──"):

```csharp
/// <summary>Persona por correo: id, nombre y correo, sin traer la fila completa.</summary>
private Task<GoldenPointsUserRow?> FindUserAsync(string email) =>
    _transactionHelper.ExecuteQueryAsync<GoldenPointsUserRow>(async unitOfWork =>
        (await unitOfWork.Repository<User>().GetListAsync(
            u => u.CorportativeEmail == email,
            selector: q => q.Select(u => new GoldenPointsUserRow(u.Id, u.DisplayName, u.CorportativeEmail)).Take(1)))
        .FirstOrDefault());

/// <summary>Lo que muestra un movimiento: persona, categoría del reconocimiento, si fue reversado y su lote.</summary>
private static IIncludableQueryable<GoldenPointsTransaction, object> WithDetails(IQueryable<GoldenPointsTransaction> query) =>
    query
        .Include(t => t.Recognition).ThenInclude(r => r!.Category)
        .Include(t => t.ReversedBy)
        .Include(t => t.Bucket)
        .Include(t => t.User);
```

**Las búsquedas de usuario:** en `GetMyTransactionsAsync`, `GetTransactionsAsync` y `BuildSummaryAsync`, cambia

```csharp
var user = await _queryRepository.GetUserAsync(…);
```

por

```csharp
var user = await FindUserAsync(…);
```

**`PageAsync`:** la consulta cambia de

```csharp
var result = await _queryRepository.GetTransactionsPageAsync(userId, type, source, page, pageSize);
```

a

```csharp
// Los enums tienen conversión enum ⇄ texto en la columna: se compara contra un valor no nulo.
var typeValue = type.GetValueOrDefault();
var sourceValue = source.GetValueOrDefault();

var result = await _transactionHelper.ExecuteQueryAsync<PaginatedResponseDto<GoldenPointsTransaction>>(async unitOfWork =>
    await unitOfWork.Repository<GoldenPointsTransaction>().GetPagedListAsync(
        t => (userId == null || t.UserId == userId)
             && (type == null || t.Type == typeValue)
             && (source == null || t.Source == sourceValue),
        q => q.OrderByDescending(t => t.CreatedDate).ThenByDescending(t => t.Id),
        includes: WithDetails,
        pageNumber: page,
        pageSize: pageSize));
```

y la respuesta:

```csharp
return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPagedResultDto<GoldenPointsTransactionDto>
{
    Items = result?.Data
        .Select(GoldenPointsMapper.ToRow)
        .Select(row => GoldenPointsMapper.ToDto(row, forAdmin))
        .ToList() ?? [],
    Page = page,
    PageSize = pageSize,
    TotalCount = result?.TotalRecords ?? 0,
});
```

**`ReadTransactionAsync`:**

```csharp
private async Task<ResponseDto<GoldenPointsTransactionDto>> ReadTransactionAsync(int transactionId)
{
    var transaction = await _transactionHelper.ExecuteQueryAsync<GoldenPointsTransaction>(async unitOfWork =>
        await unitOfWork.Repository<GoldenPointsTransaction>().GetAsync(t => t.Id == transactionId, includes: WithDetails));

    return transaction is null
        ? ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.UnexpectedError)
        : ResponseDtoHelper.CreateSuccessResponseDto(GoldenPointsMapper.ToDto(GoldenPointsMapper.ToRow(transaction), forAdmin: true));
}
```

**`ExpireDuePointsAsync`** (el proceso diario):

```csharp
var userIds = await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<int>>(async unitOfWork =>
    await unitOfWork.Repository<GoldenPointsBucket>().GetListAsync(
        b => b.RemainingPoints > 0 && b.ExpiresDate < today,
        selector: q => q.Select(b => b.UserId).Distinct())) ?? [];
```

`BuildSummaryAsync` sigue llamando a `_queryRepository.GetSummaryAsync` y `_queryRepository.GetUpcomingExpirationsAsync`: el repositorio se queda para eso.

---

## 10. Paso 6 — Dashboard: las dos búsquedas simples

### `GoldenDashboardService.cs` ✏️ — constructor

```csharp
public class GoldenDashboardService(
    ITransactionExecutorHelper transactionHelper,
    IGoldenDashboardQueryRepository queryRepository) : IGoldenDashboardService
{
    private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
    private readonly IGoldenDashboardQueryRepository _queryRepository = queryRepository;
```

(`using DOCCB.Application.Features.Common.Application.Interfaces;` y `using DOCCB.Domain.Entities;` si no están.)

### Categorías

```csharp
var categories = await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<GoldenDashboardCategory>>(async unitOfWork =>
    await unitOfWork.Repository<GoldenRecognitionCategory>().GetListAsync(
        selector: q => q.Select(c => new GoldenDashboardCategory(c.Id, c.Name, c.Icon, c.Color, c.Active)))) ?? [];
```

### `ScopeAsync`

```csharp
private async Task<GoldenDashboardScope> ScopeAsync(GoldenDashboardFilter filter)
{
    IReadOnlyCollection<int>? userIds = null;

    if (filter.UserEmails.Count > 0)
    {
        var emails = filter.UserEmails.ToList();
        userIds = await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<int>>(async unitOfWork =>
            await unitOfWork.Repository<User>().GetListAsync(
                u => emails.Contains(u.CorportativeEmail),
                selector: q => q.Select(u => u.Id))) ?? [];
    }

    return new GoldenDashboardScope(userIds, filter.Statuses, filter.CategoryIds);
}
```

> Si se eligieron colaboradores y ninguno existe, `userIds` queda vacío: el resultado es vacío, no "todos" (igual que antes).

### `IGoldenDashboardQueryRepository` y `GoldenDashboardQueryRepository` ✏️

Borra `GetUserIdsByEmailsAsync` y `GetRecognitionCategoriesAsync`. El registro `GoldenDashboardCategory` se queda: lo usa el servicio.

---

## 11. Paso 7 — Una sola definición de "hoy"

1. En `GoldenProductService.cs`, cambia las 6 apariciones de `GoldenProductAvailability.Today()` por `GoldenClock.Today()`. Están en el mismo namespace (`Helpers`).
2. En `GoldenProductAvailability.cs`, borra `Today()`.

---

## 12. Verificación

**Nada quedó apuntando a lo borrado** (desde la carpeta de la solución):

```bash
grep -rn "IGoldenRecognitionQueryRepository\|GetUserIdByEmailAsync\|GetReviewPageAsync\|GetTransactionsPageAsync\|GetUserIdsByEmailsAsync\|GoldenProductAvailability.Today" --include='*.cs' .
```

No debe devolver nada.

**Compila sin advertencias nuevas.**

**Mismas respuestas.** Repite las llamadas de la sección 4 con el mismo usuario y compara:

| Endpoint | Qué revisar |
|---|---|
| Feed (sin filtros y con cada filtro) | Mismos `items` en el mismo orden, mismo `totalCount`, mismas reacciones y "mis reacciones". |
| Feed con un `nomineeEmail` que no existe | Página vacía (no todos). |
| `sent` | Sin `pointsAssigned`. |
| `received` | Con `pointsAssigned` y `pointsExpiresAt`. |
| Reacciones | Agregar dos veces la misma (doble clic) responde igual y no duplica. |
| Crear y editar un reconocimiento | La respuesta trae nombres, categoría e `id` real. |
| `me/summary` y `summary?email=` | Mismos números. |
| `me/transactions` y `transactions` con `type`, `source` y `email` | Mismas filas. `isReversed`, `remainingPoints`, `expiresAt` y la categoría del reconocimiento iguales. |
| Reversar una asignación | La respuesta trae el movimiento con sus datos. |
| Dashboard con colaborador y categoría | Mismos KPIs y gráficas. Con un colaborador inexistente, todo en 0. |
| Proceso diario de vencimiento | Se ejecuta igual (revisa el log del `GoldenPointsExpirationWorker`). |
| Catálogo | "Vencido" se calcula igual (`GoldenClock`). |

**Los endpoints viejos ya no existen:** `GET /api/GoldenRecognitions/review` responde 404 o 405. Aprobar y rechazar desde la pantalla de Aprobaciones sigue funcionando.

---

## ✅ Checklist

- [ ] Respuestas guardadas antes de empezar (sección 4).
- [ ] Paso 1: admin viejo de reconocimientos borrado (controlador, interfaz, servicio, constantes y códigos sin uso).
- [ ] Paso 2: `GoldenRecognitionQueries.WithCard` compartido, `GoldenRecognitionRows.cs` y `GoldenRecognitionMapper.ToRow`.
- [ ] Paso 3: `GoldenRecognitionService` solo con el helper (sin `_queryRepository`).
- [ ] Paso 4: `GoldenRecognitionQueryRepository` borrado, con su registro.
- [ ] Paso 5: `GoldenPointsQueryRepository` solo con `GetSummaryAsync` y `GetUpcomingExpirationsAsync`; el servicio usa el genérico para lo demás.
- [ ] Paso 6: dashboard sin búsquedas simples en el repositorio.
- [ ] Paso 7: `GoldenClock.Today()` como única definición.
- [ ] Verificación: `grep` vacío, compila y las respuestas coinciden.
