# ✅ Puntos Dorados — Aprobación de reconocimientos (API .NET 8 + SQL Server)

API para la pestaña **Aprobaciones** de `PuntosDoradosAdminComponent`. Cada tarjeta muestra un reconocimiento con su estado y el campo "Puntos a asignar"; los botones cambian según el estado.

| Paso | Quién | Endpoint |
|---|---|---|
| 1. Crear el reconocimiento (nace **Pendiente**) | Cualquier colaborador | `POST /api/GoldenRecognitions` (ya existe) |
| 2. Listar para aprobar | Administración | `GET /api/GoldenRecognitionApprovals?status=&page=&pageSize=` |
| 3. **Aprobar**, con puntos o sin ellos | Administración | `PATCH /api/GoldenRecognitionApprovals/{id}/approve` |
| 4. **Rechazar** | Administración | `PATCH /api/GoldenRecognitionApprovals/{id}/reject` |
| 5. **Guardar ajuste** de puntos de uno aprobado | Administración | `PUT /api/GoldenRecognitionApprovals/{id}/points` |
| 6. Ver el aprobado en el **feed** y en **"Mis reconocimientos"** | Todos / quien lo recibió | Sin cambios: `feed` y `received` ya muestran solo los aprobados |

**Qué ve cada quien en un reconocimiento aprobado:**

| Dónde | ¿Sale? | ¿Muestra los puntos? |
|---|---|---|
| **Feed** | Sí, si es público | **Nunca.** El DTO del feed no tiene campo de puntos. |
| **"Mis reconocimientos"** de quien lo recibió | Sí, público o privado | Sí, y la fecha en que vencen (Paso 7). Son suyos. |
| **"Enviados"** de quien lo creó | Sí, con su estado | No. |
| **Aprobaciones** (administración) | Sí | Sí. |

- **Permisos:** la validación de quién puede aprobar queda **comentada** (sección 9), como pediste. Mientras esté así, cualquier usuario autenticado puede usar estos endpoints: no la publiques en producción sin activarla.
- **Fuera de alcance:** la carga masiva por XLSX de la misma pantalla, las notificaciones por correo y el frontend.
- **Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md). Usa el libro de puntos de [puntos-dorados-puntos-api.md](puntos-dorados-puntos-api.md).

---

## 1. 🧐 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Estados.** | `Pendiente` → `Aprobada` o `Rechazada`. **Rechazada es final** ("Estado final: solicitud rechazada"). Una aprobada no vuelve a pendiente ni se rechaza: solo se le ajustan los puntos. |
| 2 | **Puntos opcionales.** | Vacío o `0` = sin puntos (`points_assigned` queda `NULL`). Si se dan: de 1 a 100.000, el mismo límite de la asignación manual. |
| 3 | **Puntos como dinero.** | Aprobar con puntos los abona con `GoldenPointsLedger.CreditAsync` **en la misma transacción** que aprueba: quedan las dos cosas o ninguna. Vencen a los 6 meses (`DefaultExpirationMonths`). |
| 4 | **"Guardar ajuste".** | No se edita ningún movimiento. Se registra un **ajuste por la diferencia**: de 100 a 150 es `+50`; de 150 a 100 es `−50`. Así el historial de "Mis puntos" explica cada cambio. |
| 5 | **Bajar puntos ya usados.** | Solo se puede quitar lo que la persona **todavía tiene** de ese reconocimiento. Si ya gastó o se le vencieron 60, no se puede dejar en menos de 60. |
| 6 | **Dos administradores a la vez.** Uno aprueba con puntos y otro rechaza el mismo reconocimiento. | `row_version` en `golden_recognition`. El segundo choca al guardar, se reintenta, ve que ya fue revisado y responde "ya fue aprobado". Sin esto, el reconocimiento podría quedar rechazado **con los puntos abonados**. |
| 7 | **Doble clic en "Aprobar".** | Mismo caso del punto 6. Además, el índice `ux_golden_points_transaction_recognition_credit` impide un segundo abono. |
| 8 | **Comentario.** | Opcional, hasta 500 caracteres, al aprobar o rechazar (`review_comment`). Lo ve administración; no sale en el feed. La pantalla actual no lo pide: el frontend puede no enviarlo. |
| 9 | **Orden de la lista.** | Primero los **pendientes, el más antiguo arriba** (es una fila de espera: nada se queda olvidado). Después los revisados, el de revisión más reciente arriba. |
| 10 | **Reverso desde la pestaña "Puntos".** | Ahí solo se reversan asignaciones manuales. Los puntos de un reconocimiento se corrigen aquí, con "Guardar ajuste". |
| 11 | **El feed y "Mis reconocimientos".** | No cambian: ya filtran por `Aprobada` y el feed ordena por fecha de aprobación. Aprobar hoy uno creado hace tres semanas lo pone arriba del feed. |

---

## 2. 📁 Archivos

```text
DOCCB.Domain/
└── Entities/GoldenRecognition.cs                         ✏️ + ReviewComment, RowVersion

DOCCB.Application/
├── Contracts/Persistence/
│   └── IGoldenRecognitionQueryRepository.cs              ✏️ + vencimiento de puntos (Paso 7)
└── Features/GoldenPoints/Application/
    ├── Constants/
    │   ├── GoldenRecognitionApprovalConstants.cs         nuevo
    │   └── GoldenPointsConstants.cs                      ✏️ + 1 mensaje
    ├── Dtos/
    │   ├── GoldenRecognitionApprovalDtos.cs              nuevo
    │   └── GoldenRecognitionDtos.cs                      ✏️ + PointsExpiresAt (Paso 7)
    ├── Helpers/
    │   ├── GoldenRecognitionApprovalValidator.cs         nuevo
    │   ├── GoldenRecognitionApprovalMapper.cs            nuevo
    │   └── GoldenPointsLedger.cs                         ✏️ + SetRecognitionPointsAsync
    ├── Interfaces/IGoldenRecognitionApprovalService.cs   nuevo
    └── Services/
        ├── GoldenRecognitionApprovalService.cs           nuevo ⭐
        └── GoldenRecognitionService.cs                   ✏️ GetReceivedAsync (Paso 7)

DOCCB.Infraestructure/
├── Configurations/GoldenRecognitionConfiguration.cs      ✏️ + 2 propiedades
├── Persistence/Scripts SQL/GoldenRecognitionApprovals.sql nuevo
└── Repositories/GoldenRecognitionQueryRepository.cs      ✏️ (Paso 7)

WebApp/
├── Common/ApiResponseConstants.cs                        ✏️ + 1 mensaje
└── Controllers/GoldenRecognitionApprovalsController.cs   nuevo
```

> **Por qué un servicio y un controlador nuevos** en lugar de agregar acciones a `GoldenRecognitionsController`: lo de administración queda separado de lo del colaborador. Cuando se activen los permisos, se protege un solo controlador sin tocar el otro.
>
> **Sin repositorio propio.** Todo va con `ITransactionExecutorHelper` y `unitOfWork.Repository<T>()` (sección 7). Los únicos archivos de `Repositories/` que se tocan son los del Paso 7, que ya existen.

---

## 3. Paso 1 — 🗄️ Base de datos

### Antes del script: revisa los datos

El script agrega una regla de coherencia (`CHECK`). Si hay filas aprobadas a mano con SQL que no la cumplen, el script falla. Esta consulta debe devolver **cero filas**:

```sql
SELECT id, status, reviewed_date, reviewed_by, points_assigned
FROM   dbo.golden_recognition
WHERE  (status = 'PENDING'  AND (reviewed_date IS NOT NULL OR reviewed_by IS NOT NULL OR points_assigned IS NOT NULL))
   OR  (status IN ('APPROVED', 'REJECTED') AND (reviewed_date IS NULL OR reviewed_by IS NULL))
   OR  (status = 'REJECTED' AND points_assigned IS NOT NULL);
```

Si devuelve filas, corrígelas a mano (son datos de prueba) antes de seguir.

### `Persistence/Scripts SQL/GoldenRecognitionApprovals.sql`

```sql
/* =====================================================================
   Puntos Dorados — aprobación de reconocimientos
   Base de datos: DB · Esquema: dbo
   Requiere: GoldenPointsRecognitions.sql y GoldenPointsLedger.sql
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Concurrencia: dos revisiones del mismo reconocimiento al mismo tiempo no se pisan. */
IF COL_LENGTH(N'dbo.golden_recognition', N'row_version') IS NULL
    ALTER TABLE dbo.golden_recognition ADD row_version ROWVERSION NOT NULL;
GO

/* Comentario opcional de quien aprueba o rechaza. */
IF COL_LENGTH(N'dbo.golden_recognition', N'review_comment') IS NULL
    ALTER TABLE dbo.golden_recognition ADD review_comment NVARCHAR(500) NULL;
GO

/* Coherencia del estado: un pendiente no tiene revisión ni puntos; uno revisado tiene fecha y revisor;
   uno rechazado no tiene puntos. */
IF OBJECT_ID(N'dbo.ck_golden_recognition_review', N'C') IS NULL
    ALTER TABLE dbo.golden_recognition WITH CHECK
        ADD CONSTRAINT ck_golden_recognition_review CHECK (
            (status = 'PENDING'  AND reviewed_date IS NULL AND reviewed_by IS NULL AND points_assigned IS NULL) OR
            (status = 'APPROVED' AND reviewed_date IS NOT NULL AND reviewed_by IS NOT NULL) OR
            (status = 'REJECTED' AND reviewed_date IS NOT NULL AND reviewed_by IS NOT NULL AND points_assigned IS NULL));
GO

/* Lista de aprobación: pendientes, el más antiguo primero. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'ix_golden_recognition_review' AND object_id = OBJECT_ID(N'dbo.golden_recognition'))
    CREATE INDEX ix_golden_recognition_review
        ON dbo.golden_recognition (status, created_date)
        INCLUDE (reviewed_date);
GO
```

### Consulta de control (debe devolver **cero filas**)

Súmala a las tres de la guía de puntos. Los puntos de cada reconocimiento aprobado deben ser lo que el libro dice que abonó:

```sql
-- 4. points_assigned = suma de los movimientos del reconocimiento (abono + ajustes)
SELECT r.id, r.points_assigned, ledger = COALESCE(SUM(t.points), 0)
FROM   dbo.golden_recognition r
LEFT JOIN dbo.golden_points_transaction t ON t.recognition_id = r.id
WHERE  r.status = 'APPROVED'
GROUP BY r.id, r.points_assigned
HAVING COALESCE(r.points_assigned, 0) <> COALESCE(SUM(t.points), 0);
```

> **Datos de prueba.** El SQL de prueba de la guía de reconocimientos aprobaba con `points_assigned = 150` **sin** abonar nada en el libro, así que esta consulta los va a mostrar. Para corregir uno, usa "Guardar ajuste" con el **mismo** valor: el libro tiene 0, así que abona los 150 y queda cuadrado.

---

## 4. Paso 2 — Entidad y configuración ✏️

### `Entities/GoldenRecognition.cs` — agrega

```csharp
/// <summary>Comentario opcional de quien aprobó o rechazó.</summary>
public string? ReviewComment { get; set; }

/// <summary>Concurrencia: dos revisiones al mismo tiempo no se pisan.</summary>
public byte[] RowVersion { get; set; } = [];
```

### `Configurations/GoldenRecognitionConfiguration.cs` — agrega

```csharp
builder.Property(r => r.ReviewComment).HasColumnName("review_comment").HasMaxLength(500);

// EF agrega "WHERE row_version = @original" al UPDATE: si otro guardó antes, falla y el servicio reintenta.
builder.Property(r => r.RowVersion).HasColumnName("row_version").IsRowVersion();
```

> `CreateAsync` de `GoldenRecognitionService` no cambia: la base de datos genera `row_version` al insertar.

---

## 5. Paso 3 — Constantes, DTOs y validación

### `Constants/GoldenRecognitionApprovalConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenRecognitionApprovalConstants
    {
        public const int CommentMaxLength = 500;

        public const string RecognitionNotFound = "El reconocimiento no existe.";
        public const string AlreadyApproved = "Este reconocimiento ya fue aprobado. Recarga la lista.";
        public const string AlreadyRejected = "Este reconocimiento ya fue rechazado. Recarga la lista.";
        public const string OnlyApprovedCanBeAdjusted = "Solo se pueden ajustar los puntos de un reconocimiento aprobado.";
        public const string PointsRequired = "Escribe los puntos que debe tener el reconocimiento (0 para quitarlos).";
        public const string PointsInvalid = "Los puntos deben ser un número entre 0 y 100.000.";
        public const string CommentTooLong = "El comentario admite hasta 500 caracteres.";
        public const string StatusInvalid = "El estado debe ser Pendiente, Aprobada o Rechazada.";
        public const string ConcurrentReview = "Otra persona modificó este reconocimiento al mismo tiempo. Recarga la lista e intenta de nuevo.";

        // Permisos: se usa cuando se active la validación (sección 9).
        public const string CannotReviewOwnRecognition = "No puedes revisar un reconocimiento que recibiste o que creaste.";
    }
}
```

### `Constants/GoldenPointsConstants.cs` ✏️ — agrega

```csharp
public const string RecognitionPointsAlreadyUsed = "La persona ya usó o se le vencieron {0} de estos puntos: no puedes dejar menos de {0}.";
```

### `Dtos/GoldenRecognitionApprovalDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>?status=Pendiente&amp;page=1&amp;pageSize=12</summary>
    public class GoldenRecognitionApprovalQueryDto
    {
        /// <summary>Pendiente | Aprobada | Rechazada. Vacío = todos.</summary>
        public string? Status { get; set; }
        public int Page { get; set; } = 1;
        public int PageSize { get; set; } = 10;
    }

    /// <summary>Botón "Aprobar". Points vacío o 0 = sin puntos.</summary>
    public class ApproveGoldenRecognitionDto
    {
        public int? Points { get; set; }
        public string? Comment { get; set; }
    }

    /// <summary>Botón "Rechazar".</summary>
    public class RejectGoldenRecognitionDto
    {
        public string? Comment { get; set; }
    }

    /// <summary>Botón "Guardar ajuste": el total de puntos que debe quedar (0 = sin puntos). Obligatorio.</summary>
    public class AdjustGoldenRecognitionPointsDto
    {
        public int? Points { get; set; }
    }

    /// <summary>Tarjeta de Aprobaciones: el GoldenRecognitionDto con los datos de la revisión.</summary>
    public class GoldenRecognitionApprovalDto : GoldenRecognitionDto
    {
        public string? ReviewedBy { get; set; }
        public string? ReviewComment { get; set; }
        /// <summary>Pendiente: se muestran "Rechazar" y "Aprobar".</summary>
        public bool CanReview { get; set; }
        /// <summary>Aprobada: se muestra "Guardar ajuste".</summary>
        public bool CanAdjustPoints { get; set; }
    }
}
```

> `AdjustGoldenRecognitionPointsDto.Points` es `int?` a propósito: si llega una petición sin cuerpo, `int` valdría 0 y **quitaría todos los puntos**. Con `int?` se responde "Escribe los puntos…".

### `Helpers/GoldenRecognitionApprovalValidator.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenRecognitionApprovalValidator
    {
        /// <summary>Vacío o 0 = sin puntos. Máximo el de una asignación manual.</summary>
        public static int NormalizePoints(int? value, List<string> errors)
        {
            var points = value ?? 0;
            if (points < 0 || points > GoldenPointsConstants.MaxPointsPerAssignment)
            {
                errors.Add(GoldenRecognitionApprovalConstants.PointsInvalid);
            }

            return points;
        }

        /// <summary>Vacío = sin comentario.</summary>
        public static string? NormalizeComment(string? value, List<string> errors)
        {
            var comment = value?.Trim();
            if (string.IsNullOrEmpty(comment))
            {
                return null;
            }

            if (comment.Length > GoldenRecognitionApprovalConstants.CommentMaxLength)
            {
                errors.Add(GoldenRecognitionApprovalConstants.CommentTooLong);
            }

            return comment;
        }

        /// <summary>Vacío = todos (true con null). Sin distinguir mayúsculas. false = valor desconocido.</summary>
        public static bool TryParseStatus(string? value, out GoldenRecognitionStatus? status)
        {
            status = null;
            var text = value?.Trim().ToLowerInvariant();

            if (string.IsNullOrEmpty(text))
            {
                return true;
            }

            status = text switch
            {
                "pendiente" => GoldenRecognitionStatus.Pending,
                "aprobada" => GoldenRecognitionStatus.Approved,
                "rechazada" => GoldenRecognitionStatus.Rejected,
                _ => null,
            };

            return status is not null;
        }

        /// <summary>Página desde 1; tamaño entre 1 y 50. Fuera de rango se ajusta.</summary>
        public static (int Page, int PageSize) Paging(GoldenRecognitionApprovalQueryDto query) =>
            (Math.Max(1, query.Page), Math.Clamp(query.PageSize, 1, GoldenRecognitionConstants.MaxPageSize));
    }
}
```

---

## 6. Paso 4 — Libro de puntos: ajustar un reconocimiento ✏️

En `Helpers/GoldenPointsLedger.cs` agrega el record (junto a `GoldenPointsCredit`) y el método (junto a `ReverseAsync`). Va en el libro porque **nadie más debe cambiar** `golden_points_account` ni `golden_points_bucket`.

```csharp
/// <summary>"Guardar ajuste" de un reconocimiento aprobado: cuántos puntos debe haber dado en total.</summary>
public sealed record GoldenRecognitionPointsChange(
    int UserId,
    int RecognitionId,
    int TargetPoints,
    string CategoryName,
    string CreatedBy);
```

```csharp
/// <summary>
/// Deja en TargetPoints lo que un reconocimiento le dio a la persona, con un movimiento por la diferencia.
/// Sube: abona la diferencia. Baja: la quita de lo que queda de esos mismos puntos; lo usado o vencido no se quita.
/// Devuelve null si salió bien, o el motivo por el que no se pudo (sin haber cambiado nada).
/// </summary>
public static async Task<string?> SetRecognitionPointsAsync(IUnitOfWork unitOfWork, GoldenRecognitionPointsChange change)
{
    var transactions = unitOfWork.Repository<GoldenPointsTransaction>();

    // Lo que el reconocimiento ha dado: su abono y sus ajustes. Los gastos y vencimientos no llevan recognition_id.
    var movements = await transactions.GetListAsync(t => t.RecognitionId == change.RecognitionId);
    var granted = movements.Sum(t => t.Points);
    var delta = change.TargetPoints - granted;

    if (delta == 0)
    {
        return null;
    }

    var today = GoldenClock.Today();
    var defaultExpires = today.AddMonths(GoldenPointsConstants.DefaultExpirationMonths);
    var credit = movements.FirstOrDefault(t => t.Type == GoldenPointsTransactionType.Credit);

    // Se aprobó sin puntos: el primero es un abono normal (un reconocimiento tiene un solo abono).
    if (delta > 0 && credit is null)
    {
        await CreditAsync(unitOfWork, new GoldenPointsCredit(
            change.UserId,
            delta,
            GoldenPointsSource.Recognition,
            $"Reconocimiento aprobado: {change.CategoryName}",
            defaultExpires,
            change.CreatedBy,
            RecognitionId: change.RecognitionId));

        return null;
    }

    var account = await unitOfWork.Repository<GoldenPointsAccount>().GetByIdAsync(change.UserId);
    if (account is null)
    {
        return GoldenPointsConstants.UnexpectedError;
    }

    var buckets = unitOfWork.Repository<GoldenPointsBucket>();
    var now = DateTime.UtcNow;

    var adjustment = new GoldenPointsTransaction
    {
        UserId = change.UserId,
        Type = GoldenPointsTransactionType.Adjustment,
        Source = GoldenPointsSource.Recognition,
        Points = delta,
        Concept = $"Ajuste del reconocimiento {change.CategoryName}: {granted} → {change.TargetPoints} puntos",
        RecognitionId = change.RecognitionId,
        CreatedDate = now,
        CreatedBy = change.CreatedBy,
    };

    if (delta > 0)
    {
        // Los puntos de más vencen con el abono original, si todavía no ha vencido.
        var creditBucket = await buckets.GetAsync(b => b.TransactionId == credit!.Id);
        var expires = creditBucket is not null && creditBucket.ExpiresDate > today ? creditBucket.ExpiresDate : defaultExpires;

        adjustment.Bucket = new GoldenPointsBucket
        {
            UserId = change.UserId,
            OriginalPoints = delta,
            RemainingPoints = delta,
            ExpiresDate = expires,
            CreatedDate = now,
        };
    }
    else
    {
        // Menos puntos: se quitan de lo que queda de este reconocimiento, primero lo que vence antes.
        var toRemove = -delta;
        var movementIds = movements.Select(t => t.Id).ToList();

        // Con seguimiento y ordenados en SQL, en una sola consulta. includes: null elige la sobrecarga.
        var available = await buckets.GetListAsync(
            b => movementIds.Contains(b.TransactionId) && b.RemainingPoints > 0,
            orderBy: q => q.OrderBy(b => b.ExpiresDate).ThenBy(b => b.Id),
            includes: null,
            disableTracking: false);

        var used = granted - available.Sum(b => b.RemainingPoints);
        if (change.TargetPoints < used || account.Balance < toRemove)
        {
            return string.Format(GoldenPointsConstants.RecognitionPointsAlreadyUsed, used);
        }

        foreach (var bucket in available)
        {
            if (toRemove == 0)
            {
                break;
            }

            var take = Math.Min(bucket.RemainingPoints, toRemove);
            bucket.RemainingPoints -= take;
            toRemove -= take;
        }
    }

    // row_version de la cuenta: si otro movimiento la cambió al mismo tiempo, el guardado falla y se reintenta.
    account.Balance += delta;
    account.UpdatedDate = now;
    adjustment.BalanceAfter = account.Balance;

    await transactions.AddAsync(adjustment);
    return null;
}
```

**Cómo queda en "Mis puntos"** (100 al aprobar, luego 150 y luego 120):

| Tipo | Origen | Concepto | Puntos |
|---|---|---|---|
| Crédito | Reconocimiento · Servicio | Reconocimiento aprobado: Servicio | +100 |
| Ajuste | Reconocimiento · Servicio | Ajuste del reconocimiento Servicio: 100 → 150 puntos | +50 |
| Ajuste | Reconocimiento · Servicio | Ajuste del reconocimiento Servicio: 150 → 120 puntos | −30 |

- **Saldo y totales:** "Ganados" ya suma créditos y ajustes, así que muestra 120.
- **Reverso desde "Puntos":** estos movimientos no muestran "Reversar", porque solo se reversan asignaciones manuales.

---

## 7. Lecturas: repositorio genérico, sin repositorio propio

Revisado con la regla de [ARQUITECTURA Y EJEMPLO](.claude/ARQUITECTURA%20Y%20EJEMPLO.MD) (sección 5): el genérico alcanza. No hay que contar ni sumar en memoria, ni encadenar LINQ sobre `Query()` en el servicio.

| Lo que necesita la pestaña | Con el repositorio genérico |
|---|---|
| Filtrar por estado | `GetPagedListAsync(r => status == null \|\| r.Status == status, …)` |
| Pendientes primero, el más antiguo arriba | `orderBy` con un orden calculado: el genérico lo recibe tal cual |
| Página con total | `GetPagedListAsync` → `PaginatedResponseDto<T>` (`TotalRecords`) |
| Personas y categoría de cada tarjeta | `includes: WithCard`: `Include` de `Nominee`, `Nominator` y `Category` |
| Responder la tarjeta después de aprobar, rechazar o ajustar | La misma entidad que se modificó, leída con `GetAsync(…, includes: WithCard, disableTracking: false)` dentro de la lambda. No hace falta una segunda consulta. |

- **Costo:** `Include` trae todas las columnas de `dbo.users` de las personas de la página. Con 10 a 50 tarjetas no se nota. Si algún día pesa, el cambio es a una proyección (`GetListAsync<TResult>` con `selector`), no a un repositorio propio.
- **Respuesta:** sigue siendo `GoldenPagedResultDto<T>` (`items`, `totalCount`), el que espera el frontend en Puntos Dorados. Se arma con los números de `PaginatedResponseDto<T>`.

---

## 8. Paso 5 — Mapeo y servicio

### `Helpers/GoldenRecognitionApprovalMapper.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenRecognitionApprovalMapper
    {
        /// <summary>
        /// Administración: sí ve los puntos.
        /// La entidad debe venir con Nominee, Nominator y Category (el servicio los incluye con WithCard).
        /// </summary>
        public static GoldenRecognitionApprovalDto ToDto(GoldenRecognition recognition) => new()
        {
            Id = recognition.Id,
            Nominee = Person(recognition.Nominee),
            NominatedBy = Person(recognition.Nominator),
            Reason = recognition.Reason,
            CategoryId = recognition.CategoryId,
            CategoryName = recognition.Category.Name,
            CategoryIcon = recognition.Category.Icon,
            CategoryColor = recognition.Category.Color,
            Status = GoldenRecognitionCodes.ToStatusCode(recognition.Status),
            Visibility = GoldenRecognitionCodes.ToVisibilityCode(recognition.Visibility),
            PointsAssigned = recognition.PointsAssigned,
            CreatedAt = recognition.CreatedDate,
            ReviewedAt = recognition.ReviewedDate,
            ReviewedBy = recognition.ReviewedBy,
            ReviewComment = recognition.ReviewComment,
            CanReview = recognition.Status == GoldenRecognitionStatus.Pending,
            CanAdjustPoints = recognition.Status == GoldenRecognitionStatus.Approved,
        };

        /// <summary>User no tiene área (UsersArea no está mapeada en EF): va vacía.</summary>
        private static GoldenPersonDto Person(User user) => new()
        {
            Id = user.Id,
            Name = user.DisplayName,
            Email = user.CorportativeEmail,
            Area = string.Empty,
        };
    }
}
```

### `Interfaces/IGoldenRecognitionApprovalService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;     // ResponseDto<T>
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenRecognitionApprovalService
    {
        Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionApprovalDto>>> GetAsync(GoldenRecognitionApprovalQueryDto query, string currentUserEmail);
        Task<ResponseDto<GoldenRecognitionApprovalDto>> ApproveAsync(int recognitionId, ApproveGoldenRecognitionDto dto, string currentUserEmail);
        Task<ResponseDto<GoldenRecognitionApprovalDto>> RejectAsync(int recognitionId, RejectGoldenRecognitionDto dto, string currentUserEmail);
        Task<ResponseDto<GoldenRecognitionApprovalDto>> AdjustPointsAsync(int recognitionId, AdjustGoldenRecognitionPointsDto dto, string currentUserEmail);
    }
}
```

### `Services/GoldenRecognitionApprovalService.cs` ⭐

Todo con el helper y el repositorio genérico (patrón de Request):

- **Lista:** `ExecuteQueryAsync` + `GetPagedListAsync`.
- **Aprobar, rechazar y ajustar:** `ExecuteWithTransactionAsync` con el ciclo de reintentos (regla 21 de las convenciones). La entidad se lee con seguimiento y con las personas y la categoría. Se modifica en la lambda y, cuando el helper guarda, se responde con ella (como el patrón del `Id` después de insertar).

> ⚠️ **Los errores se devuelven antes de modificar nada.** `ExecuteWithTransactionAsync` guarda al terminar la lambda aunque esta devuelva un `ResponseDto` con error. Si una entidad con seguimiento ya se modificó, ese cambio se guardaría. Por eso cada método valida todo primero y modifica al final.

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;        // Include, DbUpdateException
using Microsoft.EntityFrameworkCore.Query;  // IIncludableQueryable

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenRecognitionApprovalService(ITransactionExecutorHelper transactionHelper) : IGoldenRecognitionApprovalService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        // ── Lista ───────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionApprovalDto>>> GetAsync(GoldenRecognitionApprovalQueryDto query, string currentUserEmail)
        {
            if (!GoldenRecognitionApprovalValidator.TryParseStatus(query.Status, out var status))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionApprovalDto>>(GoldenRecognitionApprovalConstants.StatusInvalid);
            }

            // Permisos (pendiente, sección 9): solo quien puede aprobar ve esta lista.
            // if (!await CanReviewAsync(currentUserEmail))
            // {
            //     throw new UnauthorizedAccessException();
            // }

            // Página y tamaño ya validados: GetPagedListAsync no los revisa.
            var (page, pageSize) = GoldenRecognitionApprovalValidator.Paging(query);

            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenPagedResultDto<GoldenRecognitionApprovalDto>>>(
                async unitOfWork =>
                {
                    var result = await unitOfWork.Repository<GoldenRecognition>().GetPagedListAsync(
                        r => status == null || r.Status == status,
                        orderBy: q => q
                            // 1. Pendientes antes que revisados.
                            .OrderBy(r => r.Status == GoldenRecognitionStatus.Pending ? 0 : 1)
                            // 2. Entre pendientes, el más antiguo primero (en los revisados esta clave es NULL y no cuenta).
                            .ThenBy(r => r.Status == GoldenRecognitionStatus.Pending ? (DateTime?)r.CreatedDate : null)
                            // 3. Entre revisados, la revisión más reciente primero.
                            .ThenByDescending(r => r.ReviewedDate)
                            .ThenByDescending(r => r.Id),
                        includes: WithCard,
                        pageNumber: page,
                        pageSize: pageSize);

                    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPagedResultDto<GoldenRecognitionApprovalDto>
                    {
                        Items = result.Data.Select(GoldenRecognitionApprovalMapper.ToDto).ToList(),
                        Page = result.PageNumber,
                        PageSize = result.PageSize,
                        TotalCount = result.TotalRecords,
                    });
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionApprovalDto>>(GoldenRecognitionConstants.UnexpectedError);
        }

        // ── Aprobar ─────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenRecognitionApprovalDto>> ApproveAsync(int recognitionId, ApproveGoldenRecognitionDto dto, string currentUserEmail)
        {
            var errors = new List<string>();
            var points = GoldenRecognitionApprovalValidator.NormalizePoints(dto.Points, errors);
            var comment = GoldenRecognitionApprovalValidator.NormalizeComment(dto.Comment, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(errors);
            }

            for (var attempt = 1; attempt <= GoldenPointsConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenRecognition? reviewed = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionApprovalDto>>(
                        async unitOfWork =>
                        {
                            var recognition = await LoadForReviewAsync(unitOfWork, recognitionId);

                            var stateError = PendingStateError(recognition);
                            if (stateError is not null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(stateError);
                            }

                            // Permisos (pendiente, sección 9):
                            // var permissionError = await ValidateReviewerAsync(unitOfWork, recognition!, currentUserEmail);
                            // if (permissionError is not null)
                            // {
                            //     return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(permissionError);
                            // }

                            var now = DateTime.UtcNow;
                            recognition!.Status = GoldenRecognitionStatus.Approved;
                            recognition.PointsAssigned = points > 0 ? points : null;
                            recognition.ReviewedDate = now;
                            recognition.ReviewedBy = currentUserEmail;
                            recognition.ReviewComment = comment;
                            recognition.UpdatedDate = now;
                            recognition.UpdatedBy = currentUserEmail;

                            if (points > 0)
                            {
                                // Misma transacción: se aprueba y se abona, o ninguna de las dos.
                                await GoldenPointsLedger.CreditAsync(unitOfWork, new GoldenPointsCredit(
                                    recognition.NomineeUserId,
                                    points,
                                    GoldenPointsSource.Recognition,
                                    $"Reconocimiento aprobado: {recognition.Category.Name}",
                                    GoldenClock.Today().AddMonths(GoldenPointsConstants.DefaultExpirationMonths),
                                    currentUserEmail,
                                    RecognitionId: recognition.Id));
                            }

                            reviewed = recognition;
                            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenRecognitionApprovalDto()); // se arma después de guardar
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionConstants.UnexpectedError);

                    if (response.HasError || reviewed is null)
                    {
                        return response;
                    }

                    // El helper ya guardó: se responde con la misma entidad, ya actualizada.
                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenRecognitionApprovalMapper.ToDto(reviewed));
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Otra revisión del mismo reconocimiento (row_version) u otro movimiento en la cuenta de la persona.
                    // El siguiente intento lee el estado nuevo: si ya fue revisado, responde "ya fue aprobado/rechazado".
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionApprovalConstants.ConcurrentReview);
        }

        // ── Rechazar ────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenRecognitionApprovalDto>> RejectAsync(int recognitionId, RejectGoldenRecognitionDto dto, string currentUserEmail)
        {
            var errors = new List<string>();
            var comment = GoldenRecognitionApprovalValidator.NormalizeComment(dto.Comment, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(errors);
            }

            for (var attempt = 1; attempt <= GoldenPointsConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenRecognition? reviewed = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionApprovalDto>>(
                        async unitOfWork =>
                        {
                            var recognition = await LoadForReviewAsync(unitOfWork, recognitionId);

                            var stateError = PendingStateError(recognition);
                            if (stateError is not null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(stateError);
                            }

                            // Permisos (pendiente, sección 9):
                            // var permissionError = await ValidateReviewerAsync(unitOfWork, recognition!, currentUserEmail);
                            // if (permissionError is not null)
                            // {
                            //     return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(permissionError);
                            // }

                            var now = DateTime.UtcNow;
                            recognition!.Status = GoldenRecognitionStatus.Rejected;
                            recognition.PointsAssigned = null;
                            recognition.ReviewedDate = now;
                            recognition.ReviewedBy = currentUserEmail;
                            recognition.ReviewComment = comment;
                            recognition.UpdatedDate = now;
                            recognition.UpdatedBy = currentUserEmail;

                            reviewed = recognition;
                            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenRecognitionApprovalDto());
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionConstants.UnexpectedError);

                    if (response.HasError || reviewed is null)
                    {
                        return response;
                    }

                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenRecognitionApprovalMapper.ToDto(reviewed));
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Otra revisión del mismo reconocimiento al mismo tiempo: el siguiente intento ve el estado nuevo.
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionApprovalConstants.ConcurrentReview);
        }

        // ── Guardar ajuste ──────────────────────────────────────────────

        public async Task<ResponseDto<GoldenRecognitionApprovalDto>> AdjustPointsAsync(int recognitionId, AdjustGoldenRecognitionPointsDto dto, string currentUserEmail)
        {
            if (dto.Points is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionApprovalConstants.PointsRequired);
            }

            var errors = new List<string>();
            var points = GoldenRecognitionApprovalValidator.NormalizePoints(dto.Points, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(errors);
            }

            for (var attempt = 1; attempt <= GoldenPointsConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenRecognition? adjusted = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionApprovalDto>>(
                        async unitOfWork =>
                        {
                            var recognition = await LoadForReviewAsync(unitOfWork, recognitionId);
                            if (recognition is null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionApprovalConstants.RecognitionNotFound);
                            }

                            if (recognition.Status != GoldenRecognitionStatus.Approved)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionApprovalConstants.OnlyApprovedCanBeAdjusted);
                            }

                            // Permisos (pendiente, sección 9):
                            // var permissionError = await ValidateReviewerAsync(unitOfWork, recognition, currentUserEmail);
                            // if (permissionError is not null)
                            // {
                            //     return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(permissionError);
                            // }

                            // El libro decide la diferencia a partir de lo que ya abonó (no de points_assigned).
                            var ledgerError = await GoldenPointsLedger.SetRecognitionPointsAsync(unitOfWork, new GoldenRecognitionPointsChange(
                                recognition.NomineeUserId,
                                recognition.Id,
                                points,
                                recognition.Category.Name,
                                currentUserEmail));

                            if (ledgerError is not null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(ledgerError);
                            }

                            var now = DateTime.UtcNow;
                            recognition.PointsAssigned = points > 0 ? points : null;
                            recognition.UpdatedDate = now;
                            recognition.UpdatedBy = currentUserEmail;

                            adjusted = recognition;
                            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenRecognitionApprovalDto());
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionConstants.UnexpectedError);

                    if (response.HasError || adjusted is null)
                    {
                        return response;
                    }

                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenRecognitionApprovalMapper.ToDto(adjusted));
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Otro ajuste o movimiento al mismo tiempo: el siguiente intento recalcula la diferencia.
                    // Un doble clic con el mismo valor termina sin cambios (diferencia 0).
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionApprovalDto>(GoldenRecognitionApprovalConstants.ConcurrentReview);
        }

        // ── Privados ────────────────────────────────────────────────────

        /// <summary>Lo que necesita la tarjeta: las dos personas y la categoría.</summary>
        private static IIncludableQueryable<GoldenRecognition, object> WithCard(IQueryable<GoldenRecognition> query) =>
            query.Include(r => r.Nominee).Include(r => r.Nominator).Include(r => r.Category);

        /// <summary>
        /// Con seguimiento, porque se modifica en la lambda (y EF compara su row_version al guardar),
        /// y con lo que necesita la tarjeta, para responder sin otra consulta.
        /// </summary>
        private static Task<GoldenRecognition?> LoadForReviewAsync(IUnitOfWork unitOfWork, int recognitionId) =>
            unitOfWork.Repository<GoldenRecognition>().GetAsync(r => r.Id == recognitionId, includes: WithCard, disableTracking: false);

        /// <summary>Solo un pendiente se aprueba o se rechaza.</summary>
        private static string? PendingStateError(GoldenRecognition? recognition) => recognition?.Status switch
        {
            null => GoldenRecognitionApprovalConstants.RecognitionNotFound,
            GoldenRecognitionStatus.Approved => GoldenRecognitionApprovalConstants.AlreadyApproved,
            GoldenRecognitionStatus.Rejected => GoldenRecognitionApprovalConstants.AlreadyRejected,
            _ => null,
        };

        // Permisos: ValidateReviewerAsync y CanReviewAsync van aquí cuando se activen (sección 9).
    }
}
```

> **`currentUserEmail` en la lista:** por ahora no se usa. Lo usará la validación de permisos.
>
> **La entidad después de guardar.** `reviewed` (o `adjusted`) se usa cuando la unidad de trabajo ya se liberó. Funciona porque las personas y la categoría ya vinieron con `Include` y el mapper no lee ninguna otra navegación.

### Registro — `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IGoldenRecognitionApprovalService, GoldenRecognitionApprovalService>();
```

---

## 9. 🔒 Permisos (comentados hasta definir la regla)

Quedan escritos para que solo haya que descomentarlos. Cuando definas la regla, pégalos en la sección `Privados` del servicio y descomenta las llamadas de cada método.

```csharp
// ── Permisos (pendiente) ─────────────────────────────────────────────
// Se activa cuando se defina quién aprueba. Hasta entonces, cualquier usuario autenticado puede usar estos endpoints.
//
// Requiere inyectar IPermissionService (módulo RolesAndPermissions) en el constructor:
//   private readonly IPermissionService _permissionService = permissionService;
//
// /// <summary>Lista: solo quien tiene el permiso de aprobar.</summary>
// private async Task<bool> CanReviewAsync(string reviewerEmail)
// {
//     return await _permissionService.<método real>(reviewerEmail, "<permiso de aprobación de Puntos Dorados>");
// }
//
// /// <summary>Aprobar, rechazar y ajustar: permiso + no revisar lo propio.</summary>
// private async Task<string?> ValidateReviewerAsync(IUnitOfWork unitOfWork, GoldenRecognition recognition, string reviewerEmail)
// {
//     var reviewer = await unitOfWork.Repository<User>().GetAsync(u => u.CorportativeEmail == reviewerEmail);
//     if (reviewer is null)
//     {
//         return GoldenRecognitionConstants.UserNotRegistered;
//     }
//
//     // 1. Permiso de aprobador (por ejemplo, Compensación y Beneficios). Sin permiso → 401 en el controlador.
//     if (!await CanReviewAsync(reviewerEmail))
//     {
//         throw new UnauthorizedAccessException();
//     }
//
//     // 2. Nadie aprueba, rechaza ni ajusta un reconocimiento que recibió o que creó.
//     if (recognition.NomineeUserId == reviewer.Id || recognition.NominatorUserId == reviewer.Id)
//     {
//         return GoldenRecognitionApprovalConstants.CannotReviewOwnRecognition;
//     }
//
//     return null;
// }
```

**Lo que hay que decidir antes de activarlos:**

| # | Pregunta | Sugerencia |
|---|---|---|
| 1 | ¿Qué rol o permiso aprueba? | Uno propio ("Aprobar Puntos Dorados") en `RolesAndPermissions`, no "es administrador": así se puede dar a Compensación y Beneficios sin darles todo. |
| 2 | ¿Puede aprobar alguien que **recibió** el reconocimiento? | No: sería asignarse puntos a sí mismo. Es la misma regla de la asignación manual ("No puedes asignarte puntos a ti mismo"). |
| 3 | ¿Puede aprobar quien lo **creó**? | No: el control es que lo revise otra persona. |
| 4 | ¿Sin permiso: 401 o error de negocio? | 401, con el `catch (UnauthorizedAccessException)` que ya tiene el controlador. |

> El 1 y el 4 son permisos. El 2 y el 3 son reglas de control, y te recomiendo activarlas apenas puedas, aunque el permiso tarde más: sin ellas, un administrador puede aprobarse a sí mismo un reconocimiento con puntos.

---

## 10. Paso 6 — Controlador

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenRecognitionApprovalsErrorMessage = "No se pudo completar la operación con las aprobaciones de reconocimientos.";
```

### `Controllers/GoldenRecognitionApprovalsController.cs`

**Cada acción con su `try/catch` completo** (regla 18).

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: aprobación de reconocimientos (administración).</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    // Permisos: pendiente (sección 9). La validación va en el servicio.
    public class GoldenRecognitionApprovalsController(IGoldenRecognitionApprovalService service) : ControllerBase
    {
        private readonly IGoldenRecognitionApprovalService _service = service;

        /// <summary>Lista para aprobar. GET ?status=Pendiente&amp;page=1&amp;pageSize=12</summary>
        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Get([FromQuery] GoldenRecognitionApprovalQueryDto query)
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
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage });
            }
        }

        /// <summary>Aprobar, con puntos o sin ellos. PATCH {id}/approve { "points": 150, "comment": null }</summary>
        [HttpPatch("{id:int}/approve")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Approve(int id, [FromBody] ApproveGoldenRecognitionDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.ApproveAsync(id, dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage });
            }
        }

        /// <summary>Rechazar (estado final). PATCH {id}/reject { "comment": null }</summary>
        [HttpPatch("{id:int}/reject")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Reject(int id, [FromBody] RejectGoldenRecognitionDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.RejectAsync(id, dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage });
            }
        }

        /// <summary>"Guardar ajuste": total de puntos que debe quedar. PUT {id}/points { "points": 120 }</summary>
        [HttpPut("{id:int}/points")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> AdjustPoints(int id, [FromBody] AdjustGoldenRecognitionPointsDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.AdjustPointsAsync(id, dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionApprovalsErrorMessage });
            }
        }
    }
}
```

---

## 11. Paso 7 — "Mis reconocimientos": cuándo vencen los puntos ✏️

"Mis reconocimientos" ya muestra los aprobados con sus puntos. Falta la fecha de vencimiento, que hoy el frontend busca en datos de prueba (`getRecognitionExpirationDate`). Con este paso la trae la API en cada reconocimiento recibido. Es opcional: lo demás funciona sin él.

### `Dtos/GoldenRecognitionDtos.cs` — en `GoldenRecognitionDto` agrega

```csharp
/// <summary>Solo en "recibidos" y con puntos: cuándo vencen.</summary>
public DateOnly? PointsExpiresAt { get; set; }
```

### `IGoldenRecognitionQueryRepository.cs` — agrega

```csharp
/// <summary>Fecha de vencimiento del abono de cada reconocimiento (solo los que tienen puntos).</summary>
Task<IReadOnlyDictionary<int, DateOnly>> GetPointsExpirationsAsync(IReadOnlyCollection<int> recognitionIds);
```

### `GoldenRecognitionQueryRepository.cs` — agrega

```csharp
public async Task<IReadOnlyDictionary<int, DateOnly>> GetPointsExpirationsAsync(IReadOnlyCollection<int> recognitionIds)
{
    if (recognitionIds.Count == 0)
    {
        return new Dictionary<int, DateOnly>();
    }

    var ids = recognitionIds.ToList();

    // Un reconocimiento tiene un solo abono (índice único), así que hay una fecha por reconocimiento.
    // Se proyecta antes de armar el diccionario: así la navegación Transaction se resuelve en SQL.
    return await _context.Set<GoldenPointsBucket>()
        .AsNoTracking()
        .Where(b => b.Transaction.Type == GoldenPointsTransactionType.Credit
            && b.Transaction.RecognitionId != null
            && ids.Contains(b.Transaction.RecognitionId.Value))
        .Select(b => new { RecognitionId = b.Transaction.RecognitionId!.Value, b.ExpiresDate })
        .ToDictionaryAsync(x => x.RecognitionId, x => x.ExpiresDate);
}
```

### `GoldenRecognitionService.GetReceivedAsync` — reemplaza el `return`

```csharp
var expirations = await _queryRepository.GetPointsExpirationsAsync(result.Rows.Select(row => row.Id).ToList());

// Son suyos: aquí sí ve los puntos y cuándo vencen.
return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(
    result.Rows.Select(row =>
    {
        var dto = GoldenRecognitionMapper.ToDto(row, includePoints: true);
        dto.PointsExpiresAt = expirations.TryGetValue(row.Id, out var expiresAt) ? expiresAt : null;
        return dto;
    }),
    page, pageSize, result.TotalCount));
```

> `GetSentAsync` y el feed no cambian: no muestran puntos, así que tampoco su vencimiento.

---

## 12. Contrato (para el frontend)

Todas las respuestas: `{ response, hasError, errors }`. Errores de negocio con HTTP 200 y `hasError: true`; `401` sin usuario.

| Método | Ruta | Cuerpo / query | `response` |
|---|---|---|---|
| `GET` | `/api/GoldenRecognitionApprovals` | `?status=Pendiente&page=1&pageSize=12` (`status` vacío = todos) | Página de `GoldenRecognitionApprovalDto` |
| `PATCH` | `/api/GoldenRecognitionApprovals/{id}/approve` | `{ "points": 150, "comment": null }` (`points` vacío o 0 = sin puntos) | El reconocimiento, `status: "Aprobada"` |
| `PATCH` | `/api/GoldenRecognitionApprovals/{id}/reject` | `{ "comment": null }` | El reconocimiento, `status: "Rechazada"` |
| `PUT` | `/api/GoldenRecognitionApprovals/{id}/points` | `{ "points": 120 }` (obligatorio; 0 = quitar) | El reconocimiento con los puntos nuevos |

Un ítem de la lista:

```json
{
  "id": 12,
  "nominee": { "id": 31, "name": "Juan Camilo Ruiz", "email": "juan.ruiz@empresa.com", "area": "" },
  "nominatedBy": { "id": 20, "name": "Daniela Torres", "email": "daniela.torres@empresa.com", "area": "" },
  "reason": "Apoyó una contingencia crítica de operación fuera de su horario.",
  "categoryId": 1,
  "categoryName": "Servicio",
  "categoryIcon": "fa-solid fa-handshake",
  "categoryColor": "#2563EB",
  "status": "Pendiente",
  "visibility": "Publica",
  "pointsAssigned": null,
  "pointsExpiresAt": null,
  "createdAt": "2026-05-25T14:10:00",
  "reviewedAt": null,
  "reviewedBy": null,
  "reviewComment": null,
  "canReview": true,
  "canAdjustPoints": false
}
```

**Cómo se pinta cada tarjeta:**

| Estado | `canReview` | `canAdjustPoints` | Botones | "Puntos a asignar" |
|---|---|---|---|---|
| Pendiente | `true` | `false` | Rechazar · Aprobar | Vacío; lo que se escriba va en `approve` |
| Aprobada | `false` | `true` | Guardar ajuste | `pointsAssigned` (vacío = sin puntos); lo que se escriba va en `points` |
| Rechazada | `false` | `false` | "Estado final: solicitud rechazada." | No se muestra |

- **Área:** llega vacía (`User` no tiene área). La tarjeta debe ocultar "TI ·" cuando esté vacía.
- **Fechas:** en UTC y sin la `Z`, igual que en reconocimientos (`parseUtc` en el mapper). `pointsExpiresAt` es solo fecha (`parseDateOnly`).
- **Después de aprobar, rechazar o ajustar:** la respuesta trae la tarjeta actualizada; reemplázala en la lista sin recargar todo.
- **Si responde "ya fue aprobado/rechazado":** otra persona lo revisó primero. Recarga la lista.

---

## 13. Pruebas

**Lista**
- `status=Pendiente` → solo pendientes, el **más antiguo** primero.
- Sin `status` → pendientes primero; después aprobados y rechazados, la revisión más reciente primero.
- `status=Otro` → `hasError`.

**Aprobar**
- **Sin puntos** → `Aprobada` y `pointsAssigned: null`. Sale en el feed (si es público) y en "Mis reconocimientos" de quien lo recibió. "Mis puntos" no cambia.
- **Con 150** → sale en el feed **sin** ningún campo de puntos. En "Mis reconocimientos" sale con 150 y `pointsExpiresAt` = hoy + 6 meses. En "Mis puntos" aparece `+150 · Reconocimiento aprobado: <categoría>` y el saldo sube 150.
- **Privado aprobado** → no sale en el feed; sí en "Mis reconocimientos".
- **Aprobar de nuevo** → "Este reconocimiento ya fue aprobado".
- **Puntos -1 o 100.001** → `hasError`.
- **Feed:** uno creado hace semanas y aprobado hoy sale **arriba** (orden por aprobación).
- **Dos pestañas:** en una se aprueba con puntos y en la otra se rechaza el mismo, casi al mismo tiempo. Gana el primero; el segundo responde "ya fue…". En la base de datos, el estado y los puntos coinciden con el que ganó.

**Rechazar**
- **Pendiente** → `Rechazada`. No sale en el feed ni en "Mis reconocimientos". Quien lo creó lo ve "Rechazada" en sus enviados.
- **Rechazar uno aprobado** → "ya fue aprobado".

**Guardar ajuste**
- **150 → 200** → un `Ajuste +50` con la misma fecha de vencimiento del abono; saldo +50.
- **200 → 120** → `Ajuste −80`; saldo −80.
- **Aprobado sin puntos → 100** → un `Crédito +100` normal.
- **→ 0** → `pointsAssigned: null`; sigue aprobado y en el feed.
- **Mismo valor** → sin movimientos nuevos.
- **Sin cuerpo o sin `points`** → "Escribe los puntos…" (no quita nada).
- **Pendiente o rechazado** → "Solo se pueden ajustar los puntos de un reconocimiento aprobado".
- **Si la persona ya usó parte** (cuando exista la redención; o simulando un vencimiento) → no deja bajar de lo usado.

**Control**
- Las tres consultas de la guía de puntos y la del Paso 1 devuelven **cero filas** después de todas las pruebas.

---

## ✅ Checklist

- [ ] Revisados los datos y ejecutado `GoldenRecognitionApprovals.sql`.
- [ ] `GoldenRecognition` con `ReviewComment` y `RowVersion` (`IsRowVersion`).
- [ ] `SetRecognitionPointsAsync` en `GoldenPointsLedger` y el mensaje nuevo en `GoldenPointsConstants`.
- [ ] Lista y respuestas con el repositorio genérico (sin repositorio propio); `IGoldenRecognitionApprovalService` en `ApplicationServiceRegistration.cs`.
- [ ] Controlador con `try/catch` completo en cada acción.
- [ ] Permisos comentados (sección 9), con fecha para definir la regla. **No publicar en producción sin activarlos.**
- [ ] (Opcional) `pointsExpiresAt` en "Mis reconocimientos".
- [ ] El feed sigue sin campo de puntos.
- [ ] Probados los dos administradores a la vez y el doble clic.
- [ ] Consulta de control 4 en cero filas (datos de prueba corregidos con "Guardar ajuste").
