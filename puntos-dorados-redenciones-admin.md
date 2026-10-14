# 🧾 Puntos Dorados — Redenciones: registrar el canje y pantalla de administración

**Lo que se pide:** cuando un colaborador redime un producto, la solicitud aparece en una pantalla nueva de administración. Ahí se ve en una tabla con filtros y se puede exportar. Todavía no se sabe qué se hará con estas solicitudes, así que por ahora no hay estados ni acciones: solo consultar y exportar.

**Punto de partida:**
- **Frontend:** el componente `app-golden-redeem` ya llama a `POST GoldenRedemptions` al confirmar el canje.
- **Backend:** la redención **todavía no existe**. Solo está su contrato, en la guía [puntos-dorados-redimir-y-filtros-angular.md](.claude/guias/puntos-dorados-redimir-y-filtros-angular.md), sección 10.

Sin redenciones guardadas la pantalla no tendría datos, así que esta guía tiene tres partes:

| Parte | Qué hace |
|---|---|
| **A. Registrar el canje** (`POST /api/GoldenRedemptions`) | Descuenta los puntos, descuenta el stock y guarda la redención, todo en una transacción. Cumple el contrato que ya usa el frontend. |
| **B. Consultar y exportar** (`GET /api/GoldenRedemptions` y `/export`) | La tabla paginada con filtros y las filas para el XLSX. |
| **C. Pestaña "Redenciones"** (Angular) | Un componente nuevo en el admin, con los filtros como `<select>` y el botón "Exportar XLSX". También corrige la URL del servicio de redención. |

**Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md). **Guías relacionadas:**
- Libro de puntos: [puntos-dorados-puntos-api.md](.claude/guias/puntos-dorados-puntos-api.md)
- Productos: [puntos-dorados-productos-api.md](.claude/guias/puntos-dorados-productos-api.md)
- Exportar el consolidado: [puntos-dorados-exportar-consolidado.md](.claude/guias/puntos-dorados-exportar-consolidado.md)

---

## 1. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Una redención, una unidad.** | El modal canjea un producto por vez. `max_redemptions_per_user` cuenta las redenciones de esa persona para ese producto. |
| 2 | **Todo o nada.** | Descontar los puntos (`GoldenPointsLedger.DebitAsync`, nuevo), bajar el stock y guardar la redención van en **una** transacción. Nunca quedan puntos descontados sin redención, ni redención sin descontar. |
| 3 | **Primero validar, después modificar.** | El helper guarda aunque la lambda devuelva un error. Por eso todas las validaciones (producto, disponibilidad, límite por persona, saldo) van **antes** de tocar cualquier entidad. |
| 4 | **Doble clic en "Confirmar canje".** | El `requestId` del frontend es único en `golden_redemption`. La segunda petición encuentra la primera y responde **lo mismo**, sin canjear otra vez. |
| 5 | **Dos canjes al mismo tiempo** (el último del stock, o la misma persona en dos pestañas). | `row_version` de la cuenta de puntos y del producto: el segundo choca y se reintenta (hasta 3 veces) leyendo los datos nuevos. |
| 6 | **Puntos vencidos que el proceso diario aún no descontó.** | No se pueden gastar. El débito solo usa lotes con `expires_date >= hoy`, del que vence primero. |
| 7 | **Lo que se redimió, tal como era.** | La redención guarda el nombre del producto, la categoría y los puntos **de ese día**. Si después se edita el producto, la tabla y la exportación no cambian. |
| 8 | **Sin estados todavía.** | No se sabe qué se hará con las solicitudes, así que no se inventa un flujo ("Entregada", "Cancelada"). La sección 12 dice cómo agregarlo cuando se decida. |
| 9 | **Exportar.** | Igual que el consolidado: la API devuelve las filas en JSON (máximo 20.000) y el navegador arma el XLSX con `xlsx`. Trae una segunda hoja con los filtros usados. |
| 10 | **Filtros.** | Todos con `<select>`: período, persona, categoría y producto. "Personalizado" muestra dos fechas. **El período por defecto es "Todo"**, para no repetir la tabla vacía del dashboard (que por defecto mostraba solo el mes actual). |
| 11 | **Repositorio.** | Genérico (`GetPagedListAsync` y `GetListAsync<TResult>`), porque no hay agregaciones. |
| 12 | **Permisos.** | Las dos consultas de administración quedan con la validación **comentada**, como Aprobaciones. Canjear lo puede hacer cualquier colaborador registrado. |
| 13 | **Errores de negocio.** | HTTP 200 con `hasError`: saldo insuficiente, sin stock, límite alcanzado, producto no disponible. Así el mensaje sale en el modal. |

---

## 2. Archivos

```text
DOCCB.Domain/Entities/
└── GoldenRedemption.cs                                   nuevo

DOCCB.Application/Features/GoldenPoints/Application/
├── Constants/
│   ├── GoldenRedemptionConstants.cs                      nuevo
│   └── GoldenPointsConstants.cs                          ✏️ + InsufficientBalance
├── Dtos/GoldenRedemptionDtos.cs                          nuevo
├── Helpers/GoldenPointsLedger.cs                         ✏️ + DebitAsync
├── Interfaces/IGoldenRedemptionService.cs                nuevo
└── Services/GoldenRedemptionService.cs                   nuevo

DOCCB.Infraestructure/
├── Configurations/GoldenRedemptionConfiguration.cs       nuevo
└── Persistence/
    ├── Models/DOCCbDbContext.cs                          ✏️ + 1 DbSet
    └── Scripts SQL/GoldenPointsRedemptions.sql           nuevo

WebApp/
├── Common/ApiResponseConstants.cs                        ✏️ + 1 mensaje
└── Controllers/GoldenRedemptionsController.cs            nuevo

Frontend (features/puntos-dorados/)
├── domain/puntos-dorados.ts                              ✏️ fila, filtros y períodos
├── infrastructure/mappers/golden-redemptions.mapper.ts   ✏️ + toRedemptionRow
├── infrastructure/services/golden-redemptions.service.ts ✏️ URL corregida + getPage + export
├── application/puntos-dorados.fecade.ts                  ✏️ + 2 métodos
├── application/golden-redemptions-excel.ts               nuevo — arma el XLSX
└── presentation/admin/
    ├── redemptions-admin/redemptions-admin.component.*   nuevo
    └── puntos-dorados-admin.component.{ts,html}          ✏️ pestaña "Redenciones"
```

---

# Backend — Partes A (canjear) y B (consultar y exportar)

## 3. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/GoldenPointsRedemptions.sql`

```sql
/* =====================================================================
   Puntos Dorados — redenciones (canjes del catálogo)
   Base de datos: DB · Esquema: dbo
   Requiere: dbo.users, dbo.golden_product, dbo.golden_product_category,
             dbo.golden_points_transaction (GoldenPointsLedger.sql)
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.golden_redemption', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_redemption
    (
        id                    INT              IDENTITY(1, 1) NOT NULL,
        user_id               INT              NOT NULL,
        product_id            INT              NOT NULL,
        product_category_id   INT              NOT NULL,   -- categoría del producto ese día (para filtrar)
        product_name          NVARCHAR(150)    NOT NULL,   -- nombre del producto ese día
        category_name         NVARCHAR(100)    NOT NULL,   -- nombre de la categoría ese día
        points                INT              NOT NULL,   -- lo que costó ese día
        points_transaction_id INT              NOT NULL,   -- el movimiento DEBIT del libro
        request_id            UNIQUEIDENTIFIER NOT NULL,   -- doble clic: un requestId, una redención
        created_date          DATETIME2(0)     NOT NULL CONSTRAINT df_golden_redemption_created_date DEFAULT (SYSUTCDATETIME()),
        created_by            NVARCHAR(150)    NOT NULL,

        CONSTRAINT pk_golden_redemption PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_golden_redemption_user FOREIGN KEY (user_id) REFERENCES dbo.users (id),
        CONSTRAINT fk_golden_redemption_product FOREIGN KEY (product_id) REFERENCES dbo.golden_product (id),
        CONSTRAINT fk_golden_redemption_category FOREIGN KEY (product_category_id) REFERENCES dbo.golden_product_category (id),
        CONSTRAINT fk_golden_redemption_transaction
            FOREIGN KEY (points_transaction_id) REFERENCES dbo.golden_points_transaction (id),
        CONSTRAINT uq_golden_redemption_transaction UNIQUE (points_transaction_id),
        CONSTRAINT uq_golden_redemption_request UNIQUE (request_id),
        CONSTRAINT ck_golden_redemption_points CHECK (points > 0)
    );

    -- Pantalla de administración: lo más reciente primero, filtrando por período.
    CREATE INDEX ix_golden_redemption_created
        ON dbo.golden_redemption (created_date DESC, id DESC)
        INCLUDE (user_id, product_id, product_category_id, points);

    -- Límite por persona y producto (max_redemptions_per_user).
    CREATE INDEX ix_golden_redemption_user_product
        ON dbo.golden_redemption (user_id, product_id);
END;
GO
```

> **¿Por qué la redención apunta al movimiento, y no al revés?** El libro (`golden_points_transaction`) no se modifica: tiene un trigger que bloquea `UPDATE` y `DELETE`. Así no hay que agregarle una columna, y el `UNIQUE` garantiza que cada movimiento corresponde a una sola redención.

### Consultas de control (deben devolver **cero filas**)

Agrégalas a las del libro de puntos:

```sql
-- 1. Cada redención descontó exactamente sus puntos, a la misma persona
SELECT r.id
FROM   dbo.golden_redemption r
JOIN   dbo.golden_points_transaction t ON t.id = r.points_transaction_id
WHERE  t.points <> -r.points OR t.user_id <> r.user_id OR t.source <> 'REDEMPTION';

-- 2. No hay descuentos por redención sin su redención
SELECT t.id
FROM   dbo.golden_points_transaction t
LEFT JOIN dbo.golden_redemption r ON r.points_transaction_id = t.id
WHERE  t.source = 'REDEMPTION' AND r.id IS NULL;
```

---

## 4. Paso 2 — Dominio y configuración EF

### `Entities/GoldenRedemption.cs`

```csharp
namespace DOCCB.Domain.Entities
{
    /// <summary>
    /// Un canje del catálogo. Guarda el producto como era ese día:
    /// si después se edita, la redención no cambia.
    /// </summary>
    public class GoldenRedemption
    {
        public int Id { get; set; }
        public int UserId { get; set; }
        public int ProductId { get; set; }
        public int ProductCategoryId { get; set; }
        public string ProductName { get; set; } = string.Empty;
        public string CategoryName { get; set; } = string.Empty;
        public int Points { get; set; }
        public int PointsTransactionId { get; set; }
        public Guid RequestId { get; set; }
        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;

        public User User { get; set; } = null!;
        public GoldenProduct Product { get; set; } = null!;
        public GoldenPointsTransaction PointsTransaction { get; set; } = null!;
    }
}
```

### `Configurations/GoldenRedemptionConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenRedemptionConfiguration : IEntityTypeConfiguration<GoldenRedemption>
    {
        public void Configure(EntityTypeBuilder<GoldenRedemption> builder)
        {
            builder.ToTable("golden_redemption", "dbo");

            builder.HasKey(r => r.Id).HasName("pk_golden_redemption");

            builder.Property(r => r.Id).HasColumnName("id");
            builder.Property(r => r.UserId).HasColumnName("user_id");
            builder.Property(r => r.ProductId).HasColumnName("product_id");
            builder.Property(r => r.ProductCategoryId).HasColumnName("product_category_id");
            builder.Property(r => r.ProductName).HasColumnName("product_name").HasMaxLength(150).IsRequired();
            builder.Property(r => r.CategoryName).HasColumnName("category_name").HasMaxLength(100).IsRequired();
            builder.Property(r => r.Points).HasColumnName("points");
            builder.Property(r => r.PointsTransactionId).HasColumnName("points_transaction_id");
            builder.Property(r => r.RequestId).HasColumnName("request_id");
            builder.Property(r => r.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(r => r.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();

            builder.HasIndex(r => r.RequestId)
                .IsUnique()
                .HasDatabaseName("uq_golden_redemption_request");

            builder.HasOne(r => r.User)
                .WithMany()
                .HasForeignKey(r => r.UserId)
                .HasConstraintName("fk_golden_redemption_user")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasOne(r => r.Product)
                .WithMany()
                .HasForeignKey(r => r.ProductId)
                .HasConstraintName("fk_golden_redemption_product")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasOne<GoldenProductCategory>()
                .WithMany()
                .HasForeignKey(r => r.ProductCategoryId)
                .HasConstraintName("fk_golden_redemption_category")
                .OnDelete(DeleteBehavior.Restrict);

            // El movimiento se inserta en el mismo guardado; EF lo inserta primero y llena PointsTransactionId.
            builder.HasOne(r => r.PointsTransaction)
                .WithOne()
                .HasForeignKey<GoldenRedemption>(r => r.PointsTransactionId)
                .HasConstraintName("fk_golden_redemption_transaction")
                .OnDelete(DeleteBehavior.Restrict);
        }
    }
}
```

### `Persistence/Models/DOCCbDbContext.cs` ✏️

```csharp
public DbSet<GoldenRedemption> GoldenRedemptions { get; set; }
```

---

## 5. Paso 3 — El libro: `DebitAsync`

### `Constants/GoldenPointsConstants.cs` ✏️ — agrega

```csharp
public const string InsufficientBalance = "No te alcanzan los puntos: tienes {0} disponibles y este premio cuesta {1}.";
```

### `Helpers/GoldenPointsLedger.cs` ✏️

Junto a `GoldenPointsCredit`, agrega el registro:

```csharp
/// <summary>Un gasto de puntos (hoy, solo redenciones).</summary>
public sealed record GoldenPointsDebit(
    int UserId,
    int Points,
    GoldenPointsSource Source,
    string Concept,
    string CreatedBy);
```

Dentro de `GoldenPointsLedger`, después de `ReverseAsync`, va el método. Es lo que la sección 10 de la guía de puntos dejó diseñado:

```csharp
/// <summary>
/// Descuenta puntos del lote que vence primero. Primero valida y solo después modifica:
/// si devuelve un error, no cambió nada. No guarda (lo hace el helper de quien llama).
/// </summary>
public static async Task<(GoldenPointsTransaction? Debit, string? Error)> DebitAsync(IUnitOfWork unitOfWork, GoldenPointsDebit debit)
{
    if (debit.Points <= 0)
    {
        throw new ArgumentOutOfRangeException(nameof(debit), "Un gasto debe tener puntos positivos.");
    }

    // Con seguimiento: se modifican abajo. row_version de la cuenta frena dos gastos simultáneos.
    var account = await unitOfWork.Repository<GoldenPointsAccount>().GetByIdAsync(debit.UserId);

    // Solo lotes vigentes, del que vence primero. Los vencidos no se gastan aunque el proceso diario aún no los haya descontado.
    var today = GoldenClock.Today();
    var buckets = await unitOfWork.Repository<GoldenPointsBucket>().GetListAsync(
        b => b.UserId == debit.UserId && b.RemainingPoints > 0 && b.ExpiresDate >= today,
        q => q.OrderBy(b => b.ExpiresDate).ThenBy(b => b.Id),
        includes: null,
        disableTracking: false);

    var available = buckets.Sum(b => b.RemainingPoints);
    if (account is null || available < debit.Points || account.Balance < debit.Points)
    {
        return (null, string.Format(GoldenPointsConstants.InsufficientBalance, Math.Min(available, account?.Balance ?? 0), debit.Points));
    }

    // ── Desde aquí solo se modifica ─────────────────────────────────
    var pending = debit.Points;
    foreach (var bucket in buckets)
    {
        if (pending == 0)
        {
            break;
        }

        var taken = Math.Min(bucket.RemainingPoints, pending);
        bucket.RemainingPoints -= taken;
        pending -= taken;
    }

    var now = DateTime.UtcNow;
    account.Balance -= debit.Points;
    account.UpdatedDate = now;

    var transaction = new GoldenPointsTransaction
    {
        UserId = debit.UserId,
        Type = GoldenPointsTransactionType.Debit,
        Source = debit.Source,
        Points = -debit.Points,
        BalanceAfter = account.Balance,
        Concept = debit.Concept,
        CreatedDate = now,
        CreatedBy = debit.CreatedBy,
    };

    await unitOfWork.Repository<GoldenPointsTransaction>().AddAsync(transaction);
    return (transaction, null);
}
```

> **`includes: null` con nombre:** sin él, la llamada es ambigua entre las dos sobrecargas de `GetListAsync` (CS0121). `disableTracking: false` es obligatorio: `GetListAsync` no hace seguimiento por defecto, y sin seguimiento los lotes no se actualizarían.
>
> **El invariante se mantiene:** el saldo de la cuenta, la suma de movimientos y la suma de lotes bajan los mismos puntos. Las tres consultas de control del libro siguen en cero.

---

## 6. Paso 4 — Constantes y DTOs

### `Constants/GoldenRedemptionConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenRedemptionConstants
    {
        public const int DefaultPageSize = 20;
        public const int MaxPageSize = 50;
        public const int MaxExportRows = 20_000;

        public const string ProductRequired = "Elige el premio que quieres redimir.";
        public const string ProductNotFound = "El premio no existe.";
        public const string ProductUnavailable = "Este premio ya no está disponible ({0}). Actualiza el catálogo.";
        public const string LimitReached = "Ya alcanzaste el máximo de canjes de este premio por persona ({0}).";
        public const string RequestIdInUse = "Esta solicitud ya se usó para otro canje. Recarga la página e intenta de nuevo.";
        public const string DateRangeInvalid = "La fecha \"Desde\" no puede ser posterior a \"Hasta\".";
        public const string TooManyExportRows = "Hay más de 20.000 redenciones con estos filtros. Reduce el período o agrega filtros.";
    }
}
```

`RequestIdRequired`, `UserNotRegistered`, `ConcurrentChange`, `UnexpectedError` y `SaveAttempts` se reutilizan de `GoldenPointsConstants`.

### `Dtos/GoldenRedemptionDtos.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;

namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>POST /api/GoldenRedemptions — "Confirmar canje".</summary>
    public class RedeemGoldenProductDto
    {
        public int ProductId { get; set; }
        /// <summary>GUID que genera el frontend al abrir la confirmación: un doble clic no canjea dos veces.</summary>
        public Guid RequestId { get; set; }
    }

    /// <summary>Comprobante del canje (GoldenRedemptionReceiptDto del frontend).</summary>
    public class GoldenRedemptionReceiptDto
    {
        public int RedemptionId { get; set; }
        public int ProductId { get; set; }
        public string ProductName { get; set; } = string.Empty;
        public int Points { get; set; }
        public int BalanceAfter { get; set; }
        public DateTime CreatedAt { get; set; }
    }

    /// <summary>?from=&to=&userEmail=&categoryId=&productId=&page=&pageSize= (administración).</summary>
    public class GoldenRedemptionQueryDto
    {
        /// <summary>Fecha en Colombia, incluida. Vacío = sin límite.</summary>
        public DateOnly? From { get; set; }
        /// <summary>Fecha en Colombia, incluida (hasta las 23:59). Vacío = sin límite.</summary>
        public DateOnly? To { get; set; }
        public string? UserEmail { get; set; }
        public int? CategoryId { get; set; }
        public int? ProductId { get; set; }
        public int Page { get; set; } = 1;
        public int PageSize { get; set; } = GoldenRedemptionConstants.DefaultPageSize;
    }

    /// <summary>Una solicitud de redención: fila de la tabla y de la exportación.</summary>
    public class GoldenRedemptionAdminDto
    {
        public int Id { get; set; }
        public DateTime CreatedAt { get; set; }
        public string UserName { get; set; } = string.Empty;
        public string UserEmail { get; set; } = string.Empty;
        public int ProductId { get; set; }
        public string ProductName { get; set; } = string.Empty;
        public string CategoryName { get; set; } = string.Empty;
        public int Points { get; set; }
    }
}
```

---

## 7. Paso 5 — Servicio

### `Interfaces/IGoldenRedemptionService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenRedemptionService
    {
        /// <summary>Colaborador: canjea un producto con sus puntos.</summary>
        Task<ResponseDto<GoldenRedemptionReceiptDto>> RedeemAsync(RedeemGoldenProductDto dto, string userEmail);

        /// <summary>Administración: una página de solicitudes, lo más reciente primero.</summary>
        Task<ResponseDto<GoldenPagedResultDto<GoldenRedemptionAdminDto>>> GetPageAsync(GoldenRedemptionQueryDto query);

        /// <summary>Administración: todas las filas del filtro (máximo 20.000) para el XLSX.</summary>
        Task<ResponseDto<List<GoldenRedemptionAdminDto>>> ExportAsync(GoldenRedemptionQueryDto query);
    }
}
```

### `Services/GoldenRedemptionService.cs`

```csharp
using System.Linq.Expressions;
using DOCCB.Application.Common.DTOs;
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenRedemptionService(
        ITransactionExecutorHelper transactionHelper,
        ILogger<GoldenRedemptionService> logger) : IGoldenRedemptionService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly ILogger<GoldenRedemptionService> _logger = logger;

        /// <summary>Lo que devuelve la transacción del canje. La redención trae su Id después de guardar.</summary>
        private sealed record RedeemOutcome(GoldenRedemption? Redemption, int BalanceAfter, string? Error)
        {
            public static RedeemOutcome Fail(string error) => new(null, 0, error);
        }

        // ── Canjear ─────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenRedemptionReceiptDto>> RedeemAsync(RedeemGoldenProductDto dto, string userEmail)
        {
            var errors = new List<string>();
            if (dto.ProductId <= 0)
            {
                errors.Add(GoldenRedemptionConstants.ProductRequired);
            }

            if (dto.RequestId == Guid.Empty)
            {
                errors.Add(GoldenPointsConstants.RequestIdRequired);
            }

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRedemptionReceiptDto>(errors);
            }

            for (var attempt = 1; attempt <= GoldenPointsConstants.SaveAttempts; attempt++)
            {
                try
                {
                    var outcome = await _transactionHelper.ExecuteWithTransactionAsync<RedeemOutcome>(
                        unitOfWork => RedeemInTransactionAsync(unitOfWork, dto, userEmail));

                    if (outcome is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRedemptionReceiptDto>(GoldenPointsConstants.UnexpectedError);
                    }

                    if (outcome.Error is not null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRedemptionReceiptDto>(outcome.Error);
                    }

                    // Después de guardar: la redención ya tiene Id.
                    var redemption = outcome.Redemption!;
                    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenRedemptionReceiptDto
                    {
                        RedemptionId = redemption.Id,
                        ProductId = redemption.ProductId,
                        ProductName = redemption.ProductName,
                        Points = redemption.Points,
                        BalanceAfter = outcome.BalanceAfter,
                        CreatedAt = redemption.CreatedDate,
                    });
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Otro movimiento de la misma persona, el último del stock o el mismo requestId dos veces: se vuelve a leer todo.
                    _logger.LogWarning(ex, "Conflicto al redimir el producto {ProductId} ({User}), intento {Attempt}", dto.ProductId, userEmail, attempt);
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenRedemptionReceiptDto>(GoldenPointsConstants.ConcurrentChange);
        }

        /// <summary>Primero todas las validaciones; después los cambios (el helper guarda aunque haya error).</summary>
        private static async Task<RedeemOutcome?> RedeemInTransactionAsync(IUnitOfWork unitOfWork, RedeemGoldenProductDto dto, string userEmail)
        {
            var user = await unitOfWork.Repository<User>().GetAsync(u => u.CorportativeEmail == userEmail);
            if (user is null)
            {
                return RedeemOutcome.Fail(GoldenPointsConstants.UserNotRegistered);
            }

            // 1. Doble clic o reintento: el mismo requestId devuelve la misma redención.
            var redemptions = unitOfWork.Repository<GoldenRedemption>();
            var existing = await redemptions.GetAsync(
                r => r.RequestId == dto.RequestId,
                includes: q => q.Include(r => r.PointsTransaction));

            if (existing is not null)
            {
                return existing.UserId == user.Id && existing.ProductId == dto.ProductId
                    ? new RedeemOutcome(existing, existing.PointsTransaction.BalanceAfter, null)
                    : RedeemOutcome.Fail(GoldenRedemptionConstants.RequestIdInUse);
            }

            // 2. El producto, con seguimiento (stock y row_version), y su categoría.
            var product = await unitOfWork.Repository<GoldenProduct>().GetByIdAsync(dto.ProductId);
            if (product is null)
            {
                return RedeemOutcome.Fail(GoldenRedemptionConstants.ProductNotFound);
            }

            var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(product.CategoryId);

            // Activo, categoría activa, con puntos, con stock (o sin control) y no vencido: la misma regla del catálogo.
            var reasons = GoldenProductAvailability.UnavailableReasons(product, category?.Active ?? false, GoldenClock.Today());
            if (reasons.Count > 0)
            {
                return RedeemOutcome.Fail(string.Format(GoldenRedemptionConstants.ProductUnavailable, string.Join(", ", reasons)));
            }

            // 3. Máximo por persona (0 = sin límite).
            if (product.MaxRedemptionsPerUser > 0)
            {
                var redeemed = await redemptions.Query().CountAsync(r => r.UserId == user.Id && r.ProductId == product.Id);
                if (redeemed >= product.MaxRedemptionsPerUser)
                {
                    return RedeemOutcome.Fail(string.Format(GoldenRedemptionConstants.LimitReached, product.MaxRedemptionsPerUser));
                }
            }

            // 4. Puntos: DebitAsync valida el saldo ANTES de tocar nada; si devuelve error, no cambió nada.
            var points = product.PointsCost!.Value; // la disponibilidad ya descartó "Sin puntos asignados"
            var (debit, debitError) = await GoldenPointsLedger.DebitAsync(unitOfWork, new GoldenPointsDebit(
                user.Id,
                points,
                GoldenPointsSource.Redemption,
                $"Redención: {product.Name}",
                userEmail));

            if (debitError is not null)
            {
                return RedeemOutcome.Fail(debitError);
            }

            // ── Desde aquí solo se modifica ─────────────────────────────

            // 5. Stock. No puede fallar: la disponibilidad ya descartó el stock en 0 y se canjea una unidad.
            //    Si fallara, la excepción deshace la transacción completa (puntos incluidos).
            if (!GoldenProductStock.TryDecrease(product, 1, out var stockError))
            {
                throw new InvalidOperationException(stockError);
            }

            // 6. La redención, con el producto como era hoy.
            var redemption = new GoldenRedemption
            {
                UserId = user.Id,
                ProductId = product.Id,
                ProductCategoryId = product.CategoryId,
                ProductName = product.Name,
                CategoryName = category!.Name,
                Points = points,
                PointsTransaction = debit!,
                RequestId = dto.RequestId,
                CreatedDate = DateTime.UtcNow,
                CreatedBy = userEmail,
            };

            await redemptions.AddAsync(redemption);
            return new RedeemOutcome(redemption, debit!.BalanceAfter, null);
        }

        // ── Administración ──────────────────────────────────────────────

        public async Task<ResponseDto<GoldenPagedResultDto<GoldenRedemptionAdminDto>>> GetPageAsync(GoldenRedemptionQueryDto query)
        {
            var (filter, error) = BuildFilter(query);
            if (error is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRedemptionAdminDto>>(error);
            }

            var page = Math.Max(1, query.Page);
            var pageSize = Math.Clamp(query.PageSize, 1, GoldenRedemptionConstants.MaxPageSize);

            var result = await _transactionHelper.ExecuteQueryAsync<PaginatedResponseDto<GoldenRedemption>>(async unitOfWork =>
                await unitOfWork.Repository<GoldenRedemption>().GetPagedListAsync(
                    filter,
                    q => q.OrderByDescending(r => r.CreatedDate).ThenByDescending(r => r.Id),
                    includes: q => q.Include(r => r.User),
                    pageNumber: page,
                    pageSize: pageSize));

            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPagedResultDto<GoldenRedemptionAdminDto>
            {
                Items = result?.Data.Select(r => new GoldenRedemptionAdminDto
                {
                    Id = r.Id,
                    CreatedAt = r.CreatedDate,
                    UserName = r.User.DisplayName,
                    UserEmail = r.User.CorportativeEmail,
                    ProductId = r.ProductId,
                    ProductName = r.ProductName,
                    CategoryName = r.CategoryName,
                    Points = r.Points,
                }).ToList() ?? [],
                Page = page,
                PageSize = pageSize,
                TotalCount = result?.TotalRecords ?? 0,
            });
        }

        public async Task<ResponseDto<List<GoldenRedemptionAdminDto>>> ExportAsync(GoldenRedemptionQueryDto query)
        {
            var (filter, error) = BuildFilter(query);
            if (error is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<List<GoldenRedemptionAdminDto>>(error);
            }

            // Una fila de más para saber si se pasa del límite, sin contar aparte.
            var rows = await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<GoldenRedemptionAdminDto>>(async unitOfWork =>
                await unitOfWork.Repository<GoldenRedemption>().GetListAsync<GoldenRedemptionAdminDto>(
                    filter,
                    selector: q => q
                        // Con selector, el parámetro orderBy se ignora: el orden va aquí.
                        .OrderByDescending(r => r.CreatedDate)
                        .ThenByDescending(r => r.Id)
                        .Take(GoldenRedemptionConstants.MaxExportRows + 1)
                        .Select(r => new GoldenRedemptionAdminDto
                        {
                            Id = r.Id,
                            CreatedAt = r.CreatedDate,
                            UserName = r.User.DisplayName,
                            UserEmail = r.User.CorportativeEmail,
                            ProductId = r.ProductId,
                            ProductName = r.ProductName,
                            CategoryName = r.CategoryName,
                            Points = r.Points,
                        }))) ?? [];

            if (rows.Count > GoldenRedemptionConstants.MaxExportRows)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<List<GoldenRedemptionAdminDto>>(GoldenRedemptionConstants.TooManyExportRows);
            }

            return ResponseDtoHelper.CreateSuccessResponseDto(rows.ToList());
        }

        /// <summary>Un solo filtro para la tabla y la exportación: así siempre coinciden.</summary>
        private static (Expression<Func<GoldenRedemption, bool>>? Filter, string? Error) BuildFilter(GoldenRedemptionQueryDto query)
        {
            if (query.From is { } from && query.To is { } to && from > to)
            {
                return (null, GoldenRedemptionConstants.DateRangeInvalid);
            }

            // Fechas de Colombia → UTC (created_date se guarda en UTC). "Hasta" incluye todo ese día.
            DateTime? fromUtc = query.From is { } f ? GoldenClock.StartOfDayUtc(f) : null;
            DateTime? toUtc = query.To is { } t ? GoldenClock.StartOfDayUtc(t.AddDays(1)) : null;
            var email = string.IsNullOrWhiteSpace(query.UserEmail) ? null : query.UserEmail.Trim();
            var categoryId = query.CategoryId;
            var productId = query.ProductId;

            return (r =>
                (fromUtc == null || r.CreatedDate >= fromUtc) &&
                (toUtc == null || r.CreatedDate < toUtc) &&
                (email == null || r.User.CorportativeEmail == email) &&
                (categoryId == null || r.ProductCategoryId == categoryId) &&
                (productId == null || r.ProductId == productId), null);
        }
    }
}
```

**Notas del servicio**

- **`CorportativeEmail`** (así se llama en `User`) es el correo con el que se busca a la persona en el resto de Puntos Dorados. `DisplayName` es el nombre que se muestra.
- **¿Por qué funciona el reintento?** Hay tres choques posibles: la cuenta de puntos (`row_version`), el producto (`row_version`) y el índice único de `request_id`. El helper envuelve cualquiera de ellos en `InvalidOperationException` con un `DbUpdateException` adentro (`DbUpdateConcurrencyException` hereda de él). En el reintento todo se vuelve a leer. Por ejemplo, el doble clic que perdió encuentra la redención del primero y responde lo mismo.
- **`Query().CountAsync`:** un solo `Where` con `Count` dentro de una escritura, que es el uso permitido de `Query()`.
- **`GoldenClock.StartOfDayUtc`** es el que agregó la guía del dashboard.
- **El producto no cambia `updated_date` ni `updated_by` al bajar el stock:** esos campos son de la edición del administrador.

### Registro — `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IGoldenRedemptionService, GoldenRedemptionService>();
```

---

## 8. Paso 6 — Controlador

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenRedemptionsErrorMessage = "No se pudo completar la operación con las redenciones.";
```

### `Controllers/GoldenRedemptionsController.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace DOCCB.WebApp.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class GoldenRedemptionsController(IGoldenRedemptionService redemptionService) : ControllerBase
    {
        private readonly IGoldenRedemptionService _redemptionService = redemptionService;

        /// <summary>Colaborador: canjea un producto con sus puntos.</summary>
        [HttpPost]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Redeem([FromBody] RedeemGoldenProductDto request)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _redemptionService.RedeemAsync(request, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRedemptionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRedemptionsErrorMessage });
            }
        }

        /// <summary>Administración: solicitudes de redención, paginadas y con filtros.</summary>
        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetAll([FromQuery] GoldenRedemptionQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                // Permisos (pendiente, igual que Aprobaciones): solo administración del programa.

                var response = await _redemptionService.GetPageAsync(query);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRedemptionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRedemptionsErrorMessage });
            }
        }

        /// <summary>Administración: filas para el XLSX (mismos filtros, máximo 20.000).</summary>
        [HttpGet("export")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Export([FromQuery] GoldenRedemptionQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                // Permisos (pendiente, igual que Aprobaciones): solo administración del programa.

                var response = await _redemptionService.ExportAsync(query);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRedemptionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRedemptionsErrorMessage });
            }
        }
    }
}
```

---

## 9. Contrato

Base `/api/GoldenRedemptions`. Todas las respuestas: `{ response, hasError, errors }`.

| Método | Ruta | Quién | Cuerpo / query | `response` |
|---|---|---|---|---|
| `POST` | `/` | Colaborador | `{ productId, requestId }` | Comprobante (`redemptionId`, `productName`, `points`, `balanceAfter`, `createdAt`) |
| `GET` | `/` | Admin | `?from=2026-10-01&to=2026-10-31&userEmail=&categoryId=&productId=&page=1&pageSize=20` | `{ items, page, pageSize, totalCount, totalPages }` |
| `GET` | `/export` | Admin | Los mismos filtros, sin `page` | Arreglo de filas (máximo 20.000) |

Una fila:

```json
{
  "id": 41,
  "createdAt": "2026-10-13T15:20:00",
  "userName": "Laura Salazar",
  "userEmail": "laura.salazar@empresa.com",
  "productId": 7,
  "productName": "Día libre adicional",
  "categoryName": "Beneficios",
  "points": 300
}
```

`createdAt` llega en UTC sin `Z`, como el resto de la API (el frontend usa `parseUtc`). `from` y `to` son fechas de Colombia, y las dos se incluyen.

---

# Frontend — Parte C: pestaña "Redenciones"

## 10. Paso 7 — Dominio, servicio y facade

### `infrastructure/services/golden-redemptions.service.ts` ✏️ — corrige la URL

Hoy arma `${environment.api.baseUrl}/api/GoldenRedemptions`, pero `baseUrl` **ya incluye `/api`**. El canje llama a `/api/api/GoldenRedemptions` y falla siempre. Cámbialo como en los demás servicios:

```ts
// environment.api.baseUrl ya incluye /api (igual que los demás servicios).
private readonly baseUrl = `${environment.api.baseUrl}/GoldenRedemptions`;
```

En `handleError`, el texto dice "gestionar los reconocimientos". Cámbialo por:

```ts
return this.httpErrorHandler.handleHttpError(error, 'gestionar las redenciones');
```

### `domain/puntos-dorados.ts` ✏️ — agrega

```ts
/** Una solicitud de redención (pantalla de administración y exportación). */
export interface GoldenRedemptionRow {
  id: number;
  createdAt: Date;
  userName: string;
  userEmail: string;
  productId: number;
  productName: string;
  categoryName: string;
  points: number;
}

/** Filtros de la API. Fechas "yyyy-MM-dd" en hora local; null = sin filtro. */
export interface GoldenRedemptionFilters {
  from: string | null;
  to: string | null;
  userEmail: string | null;
  categoryId: number | null;
  productId: number | null;
}

export type GoldenRedemptionPeriod = 'all' | 'this-month' | 'last-month' | 'last-3-months' | 'this-year' | 'custom';

export const GOLDEN_REDEMPTION_PERIODS: readonly { value: GoldenRedemptionPeriod; label: string }[] = [
  { value: 'all', label: 'Todo' },
  { value: 'this-month', label: 'Este mes' },
  { value: 'last-month', label: 'Mes anterior' },
  { value: 'last-3-months', label: 'Últimos 3 meses' },
  { value: 'this-year', label: 'Este año' },
  { value: 'custom', label: 'Personalizado' },
];
```

> La interfaz `GoldenRedemption` que ya existe es la del mock (`GOLDEN_REDEMPTIONS`) y la sigue usando `puntos-dorados-page`. No la toques.

### `infrastructure/mappers/golden-redemptions.mapper.ts` ✏️ — agrega

```ts
import { GoldenRedemptionReceipt, GoldenRedemptionRow } from '../../domain/puntos-dorados';

export interface GoldenRedemptionRowDto {
  id: number;
  createdAt: string;
  userName: string;
  userEmail: string;
  productId: number;
  productName: string;
  categoryName: string;
  points: number;
}

export function toRedemptionRow(dto: GoldenRedemptionRowDto): GoldenRedemptionRow {
  return { ...dto, createdAt: parseUtc(dto.createdAt) };
}
```

(La primera línea reemplaza el `import` actual de `GoldenRedemptionReceipt`.)

### `infrastructure/services/golden-redemptions.service.ts` ✏️ — agrega

Imports nuevos:

```ts
import { HttpClient, HttpErrorResponse, HttpHeaders, HttpParams } from "@angular/common/http";
import { GoldenPagedResult, GoldenRedemptionFilters, GoldenRedemptionRow, RedeemGoldenProduct, GoldenResult, GoldenRedemptionReceipt } from "../../domain/puntos-dorados";
import { GoldenPagedResultDto, GoldenResultDto, toPage, toResult } from "../golden-api";
import { GoldenRedemptionReceiptDto, GoldenRedemptionRowDto, toRedemptionReceipt, toRedemptionRow } from "../mappers/golden-redemptions.mapper";
```

Métodos (después de `redeem`):

```ts
/** Administración: una página de solicitudes, lo más reciente primero. */
async getPage(filters: GoldenRedemptionFilters, page: number, pageSize: number): Promise<Observable<GoldenResult<GoldenPagedResult<GoldenRedemptionRow>>>> {
  const headers = await this.authHeaders();
  const params = this.params(filters).set('page', page).set('pageSize', pageSize);

  return this.http
    .get<GoldenResultDto<GoldenPagedResultDto<GoldenRedemptionRowDto>>>(this.baseUrl, { headers, params })
    .pipe(
      map(dto => toResult(dto, pageDto => toPage(pageDto, toRedemptionRow))),
      catchError(error => this.handleError(error)),
    );
}

/** Administración: todas las filas del filtro (máximo 20.000) para el XLSX. */
async export(filters: GoldenRedemptionFilters): Promise<Observable<GoldenResult<GoldenRedemptionRow[]>>> {
  const headers = await this.authHeaders();

  return this.http
    .get<GoldenResultDto<GoldenRedemptionRowDto[]>>(`${this.baseUrl}/export`, { headers, params: this.params(filters) })
    .pipe(
      map(dto => toResult(dto, rows => rows.map(toRedemptionRow))),
      catchError(error => this.handleError(error)),
    );
}

private params(filters: GoldenRedemptionFilters): HttpParams {
  let params = new HttpParams();

  if (filters.from) {
    params = params.set('from', filters.from);
  }

  if (filters.to) {
    params = params.set('to', filters.to);
  }

  if (filters.userEmail) {
    params = params.set('userEmail', filters.userEmail);
  }

  if (filters.categoryId !== null) {
    params = params.set('categoryId', filters.categoryId);
  }

  if (filters.productId !== null) {
    params = params.set('productId', filters.productId);
  }

  return params;
}
```

### `application/puntos-dorados.fecade.ts` ✏️ — agrega (junto a `redeemProduct`)

```ts
getRedemptionsPage(filters: GoldenRedemptionFilters, page: number, pageSize: number): Promise<GoldenResult<GoldenPagedResult<GoldenRedemptionRow>>> {
  return this.runRecognitionRequest(this.redemptions.getPage(filters, page, pageSize), 'No se pudieron cargar las redenciones.');
}

exportRedemptions(filters: GoldenRedemptionFilters): Promise<GoldenResult<GoldenRedemptionRow[]>> {
  return this.runRecognitionRequest(this.redemptions.export(filters), 'No se pudieron exportar las redenciones.');
}
```

Agrega `GoldenRedemptionFilters` y `GoldenRedemptionRow` al import de `../domain/puntos-dorados`.

### `application/golden-redemptions-excel.ts` (nuevo)

```ts
import * as XLSX from 'xlsx';
import { GoldenRedemptionRow } from '../domain/puntos-dorados';
import { toIsoDate } from '../infrastructure/golden-api';

/**
 * Descarga las redenciones en XLSX.
 * Hoja "Redenciones": una fila por solicitud, con autofiltro.
 * Hoja "Filtros": qué se exportó y cuándo.
 */
export function downloadRedemptionsXlsx(rows: readonly GoldenRedemptionRow[], filters: readonly [string, string][]): void {
  const data = XLSX.utils.json_to_sheet(
    rows.map(row => ({
      'N.° redención': row.id,
      // Fecha real (no texto): en Excel se puede ordenar y filtrar por fecha.
      Fecha: row.createdAt,
      Colaborador: row.userName,
      Correo: row.userEmail,
      Producto: row.productName,
      Categoría: row.categoryName,
      Puntos: row.points,
    })),
    { cellDates: true, dateNF: 'dd/mm/yyyy hh:mm' },
  );
  data['!cols'] = [{ wch: 14 }, { wch: 17 }, { wch: 32 }, { wch: 34 }, { wch: 32 }, { wch: 20 }, { wch: 10 }];
  if (data['!ref']) {
    data['!autofilter'] = { ref: data['!ref'] };
  }

  const totalPoints = rows.reduce((total, row) => total + row.points, 0);
  const summary = XLSX.utils.aoa_to_sheet([
    ['Filtro', 'Valor'],
    ...filters,
    ['Redenciones', rows.length],
    ['Puntos redimidos', totalPoints],
    ['Exportado', new Date().toLocaleString('es-CO')],
  ]);
  summary['!cols'] = [{ wch: 18 }, { wch: 48 }];

  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, data, 'Redenciones');
  XLSX.utils.book_append_sheet(workbook, summary, 'Filtros');
  XLSX.writeFile(workbook, `redenciones-puntos-dorados-${toIsoDate(new Date())}.xlsx`);
}
```

---

## 11. Paso 8 — Componente `app-golden-redemptions-admin`

Va en `presentation/admin/redemptions-admin/`, como `points-admin`. Recibe las personas del admin, que ya las carga para el dashboard. Carga él mismo las categorías y los productos para sus filtros.

### `redemptions-admin.component.ts`

```ts
import { ChangeDetectionStrategy, Component, PLATFORM_ID, computed, inject, input, signal } from '@angular/core';
import { DatePipe, DecimalPipe, isPlatformBrowser } from '@angular/common';
import { PuntosDoradosFacade } from '../../../application/puntos-dorados.fecade';
import { PagedList } from '../../../application/paged-list';
import { downloadRedemptionsXlsx } from '../../../application/golden-redemptions-excel';
import { toIsoDate } from '../../../infrastructure/golden-api';
import {
  GOLDEN_REDEMPTION_PERIODS,
  GoldenPerson,
  GoldenProduct,
  GoldenProductCategory,
  GoldenRedemptionFilters,
  GoldenRedemptionPeriod,
  GoldenRedemptionRow,
} from '../../../domain/puntos-dorados';

@Component({
  selector: 'app-golden-redemptions-admin',
  standalone: true,
  imports: [DatePipe, DecimalPipe],
  templateUrl: './redemptions-admin.component.html',
  styleUrl: './redemptions-admin.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class GoldenRedemptionsAdminComponent {
  private readonly facade = inject(PuntosDoradosFacade);
  private readonly isBrowser = isPlatformBrowser(inject(PLATFORM_ID));

  /** Personas para el filtro: las mismas del modal de filtros del dashboard. */
  readonly people = input<GoldenPerson[]>([]);

  readonly periods = GOLDEN_REDEMPTION_PERIODS;

  // ── Filtros ────────────────────────────────────────────────────────
  readonly period = signal<GoldenRedemptionPeriod>('all');
  readonly customFrom = signal('');
  readonly customTo = signal('');
  readonly userEmail = signal<string | null>(null);
  readonly categoryId = signal<number | null>(null);
  readonly productId = signal<number | null>(null);

  readonly categories = signal<GoldenProductCategory[]>([]);
  readonly products = signal<GoldenProduct[]>([]);

  readonly sortedPeople = computed(() => [...this.people()].sort((a, b) => a.name.localeCompare(b.name, 'es')));

  /** Con una categoría elegida, solo sus productos. */
  readonly productOptions = computed(() => {
    const categoryId = this.categoryId();
    return this.products()
      .filter(product => categoryId === null || product.categoryId === categoryId)
      .sort((a, b) => a.name.localeCompare(b.name, 'es'));
  });

  /** Lo que se envía a la API: la tabla y la exportación usan exactamente lo mismo. */
  readonly filters = computed<GoldenRedemptionFilters>(() => ({
    ...this.periodRange(this.period()),
    userEmail: this.userEmail(),
    categoryId: this.categoryId(),
    productId: this.productId(),
  }));

  readonly hasFilters = computed(
    () => this.period() !== 'all' || this.userEmail() !== null || this.categoryId() !== null || this.productId() !== null,
  );

  readonly rangeError = computed(() => {
    const { from, to } = this.filters();
    return from && to && from > to ? 'La fecha "Desde" no puede ser posterior a "Hasta".' : null;
  });

  // ── Tabla ──────────────────────────────────────────────────────────
  readonly table = new PagedList<GoldenRedemptionRow>(
    (page, pageSize) => this.facade.getRedemptionsPage(this.filters(), page, pageSize),
    row => row.id,
    20,
  );

  // ── Exportar ───────────────────────────────────────────────────────
  readonly exporting = signal(false);
  readonly exportError = signal<string | null>(null);

  constructor() {
    if (this.isBrowser) {
      void this.table.reload();
      void this.loadFilterOptions();
    }
  }

  setPeriod(value: string): void {
    this.period.set(value as GoldenRedemptionPeriod);
    this.reload();
  }

  setCustomFrom(value: string): void {
    this.customFrom.set(value);
    this.reload();
  }

  setCustomTo(value: string): void {
    this.customTo.set(value);
    this.reload();
  }

  setUser(value: string): void {
    this.userEmail.set(value || null);
    this.reload();
  }

  setCategory(value: string): void {
    const categoryId = value ? Number(value) : null;
    this.categoryId.set(categoryId);

    // Si el producto elegido no es de la nueva categoría, se quita.
    const product = this.products().find(item => item.id === this.productId());
    if (categoryId !== null && product && product.categoryId !== categoryId) {
      this.productId.set(null);
    }

    this.reload();
  }

  setProduct(value: string): void {
    this.productId.set(value ? Number(value) : null);
    this.reload();
  }

  clearFilters(): void {
    this.period.set('all');
    this.customFrom.set('');
    this.customTo.set('');
    this.userEmail.set(null);
    this.categoryId.set(null);
    this.productId.set(null);
    this.reload();
  }

  async exportXlsx(): Promise<void> {
    if (this.exporting() || this.rangeError()) {
      return;
    }

    this.exporting.set(true);
    this.exportError.set(null);

    try {
      const result = await this.facade.exportRedemptions(this.filters());
      if (result.hasError) {
        this.exportError.set(result.errors.join(' '));
        return;
      }

      if (result.response.length === 0) {
        this.exportError.set('No hay redenciones para exportar con estos filtros.');
        return;
      }

      downloadRedemptionsXlsx(result.response, this.describeFilters());
    } finally {
      this.exporting.set(false);
    }
  }

  private reload(): void {
    this.exportError.set(null);
    if (this.rangeError()) {
      return;
    }

    void this.table.reload();
  }

  /** Fechas del período en hora local ("yyyy-MM-dd"). "Todo" = sin fechas. */
  private periodRange(period: GoldenRedemptionPeriod): { from: string | null; to: string | null } {
    const today = new Date();
    const year = today.getFullYear();
    const month = today.getMonth();

    switch (period) {
      case 'this-month':
        return { from: toIsoDate(new Date(year, month, 1)), to: toIsoDate(today) };
      case 'last-month':
        // Día 0 del mes actual = último día del mes anterior.
        return { from: toIsoDate(new Date(year, month - 1, 1)), to: toIsoDate(new Date(year, month, 0)) };
      case 'last-3-months':
        return { from: toIsoDate(new Date(year, month - 2, 1)), to: toIsoDate(today) };
      case 'this-year':
        return { from: toIsoDate(new Date(year, 0, 1)), to: toIsoDate(today) };
      case 'custom':
        return { from: this.customFrom() || null, to: this.customTo() || null };
      default:
        return { from: null, to: null };
    }
  }

  /** Hoja "Filtros" del XLSX. */
  private describeFilters(): [string, string][] {
    const { from, to } = this.filters();
    const periodLabel = this.periods.find(option => option.value === this.period())?.label ?? 'Todo';
    const range = from || to ? ` (${from ?? 'inicio'} a ${to ?? 'hoy'})` : '';
    const person = this.people().find(item => item.email === this.userEmail());

    return [
      ['Período', periodLabel + range],
      ['Persona', person ? `${person.name} (${person.email})` : this.userEmail() ?? 'Todas'],
      ['Categoría', this.categories().find(item => item.id === this.categoryId())?.name ?? 'Todas'],
      ['Producto', this.products().find(item => item.id === this.productId())?.name ?? 'Todos'],
    ];
  }

  private async loadFilterOptions(): Promise<void> {
    const [categories, products] = await Promise.all([this.facade.getProductCategories(), this.facade.getProducts()]);

    if (!categories.hasError) {
      this.categories.set(categories.response);
    }

    if (!products.hasError) {
      this.products.set(products.response);
    }
  }
}
```

> **Productos y categorías inactivos** también salen en los filtros: puede haber redenciones de un producto que ya se ocultó. Los inactivos llevan "(inactiva)" o "(inactivo)" en el texto.

### `redemptions-admin.component.html`

```html
<section class="rd-card" aria-labelledby="rd-title">
  <div class="rd-head">
    <div>
      <h2 id="rd-title" class="rd-title">
        <i class="fa-solid fa-gift" aria-hidden="true"></i> Solicitudes de redención
      </h2>
      <p class="rd-hint">
        @if (table.loaded()) {
          {{ table.totalCount() | number }} {{ table.totalCount() === 1 ? 'solicitud' : 'solicitudes' }} con estos filtros.
        }
        Lo más reciente primero.
      </p>
    </div>

    <button type="button" class="btn btn-warning fw-semibold"
      [disabled]="exporting() || !!rangeError() || table.isEmpty()" (click)="exportXlsx()">
      @if (exporting()) {
        <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Exportando…
      } @else {
        <i class="fa-solid fa-file-excel me-1" aria-hidden="true"></i> Exportar XLSX
      }
    </button>
  </div>

  <!-- ── Filtros: todos con select ──────────────────────────────────── -->
  <div class="rd-filters">
    <div>
      <label class="field-label" for="rd-period">Período</label>
      <select id="rd-period" class="field-input" (change)="setPeriod($any($event.target).value)">
        @for (option of periods; track option.value) {
          <option [value]="option.value" [selected]="period() === option.value">{{ option.label }}</option>
        }
      </select>
    </div>

    <div>
      <label class="field-label" for="rd-person">Persona</label>
      <select id="rd-person" class="field-input" (change)="setUser($any($event.target).value)">
        <option value="" [selected]="userEmail() === null">Todas las personas</option>
        @for (person of sortedPeople(); track person.email) {
          <option [value]="person.email" [selected]="userEmail() === person.email">{{ person.name }}</option>
        }
      </select>
    </div>

    <div>
      <label class="field-label" for="rd-category">Categoría</label>
      <select id="rd-category" class="field-input" (change)="setCategory($any($event.target).value)">
        <option value="" [selected]="categoryId() === null">Todas las categorías</option>
        @for (category of categories(); track category.id) {
          <option [value]="category.id" [selected]="categoryId() === category.id">
            {{ category.name }}{{ category.status === 'Inactiva' ? ' (inactiva)' : '' }}
          </option>
        }
      </select>
    </div>

    <div>
      <label class="field-label" for="rd-product">Producto</label>
      <select id="rd-product" class="field-input" (change)="setProduct($any($event.target).value)">
        <option value="" [selected]="productId() === null">Todos los productos</option>
        @for (product of productOptions(); track product.id) {
          <option [value]="product.id" [selected]="productId() === product.id">
            {{ product.name }}{{ product.status ? '' : ' (inactivo)' }}
          </option>
        }
      </select>
    </div>

    @if (period() === 'custom') {
      <div>
        <label class="field-label" for="rd-from">Desde</label>
        <input id="rd-from" type="date" class="field-input" [value]="customFrom()" (change)="setCustomFrom($any($event.target).value)" />
      </div>
      <div>
        <label class="field-label" for="rd-to">Hasta</label>
        <input id="rd-to" type="date" class="field-input" [value]="customTo()" (change)="setCustomTo($any($event.target).value)" />
      </div>
    }
  </div>

  @if (hasFilters()) {
    <button type="button" class="btn btn-link btn-sm px-0 mb-2" (click)="clearFilters()">
      <i class="fa-solid fa-xmark me-1" aria-hidden="true"></i> Limpiar filtros
    </button>
  }

  @if (rangeError()) {
    <div class="alert alert-warning py-2 small" role="alert">{{ rangeError() }}</div>
  }

  @if (exportError()) {
    <div class="alert alert-danger py-2 small" role="alert">{{ exportError() }}</div>
  }

  <!-- ── Tabla ──────────────────────────────────────────────────────── -->
  <div class="rd-table-wrap" [class.is-loading]="table.loading() && table.loaded()">
    <table class="rd-table">
      <caption class="visually-hidden">Solicitudes de redención</caption>
      <thead>
        <tr>
          <th scope="col">N.°</th>
          <th scope="col">Fecha</th>
          <th scope="col">Colaborador</th>
          <th scope="col">Producto</th>
          <th scope="col">Categoría</th>
          <th scope="col" class="text-end">Puntos</th>
        </tr>
      </thead>
      <tbody>
        @for (row of table.items(); track row.id) {
          <tr>
            <td data-label="N.°" class="text-body-secondary">#{{ row.id }}</td>
            <td data-label="Fecha" class="text-nowrap">{{ row.createdAt | date: 'dd/MM/yyyy HH:mm' }}</td>
            <td data-label="Colaborador">
              <strong class="d-block">{{ row.userName }}</strong>
              <small class="text-body-secondary">{{ row.userEmail }}</small>
            </td>
            <td data-label="Producto">{{ row.productName }}</td>
            <td data-label="Categoría"><span class="rd-badge">{{ row.categoryName }}</span></td>
            <td data-label="Puntos" class="text-end"><strong>{{ row.points | number }}</strong></td>
          </tr>
        }
      </tbody>
    </table>

    @if (table.isFirstLoad()) {
      <div class="rd-skeleton" aria-hidden="true"><span></span><span></span><span></span></div>
    }

    @if (table.isEmpty()) {
      <p class="rd-empty">
        @if (hasFilters()) {
          No hay redenciones con estos filtros.
        } @else {
          Todavía nadie ha redimido un producto.
        }
      </p>
    }
  </div>

  @if (table.error()) {
    <div class="alert alert-danger d-flex justify-content-between align-items-center mt-2" role="alert">
      {{ table.error() }}
      <button type="button" class="btn btn-sm btn-outline-danger" (click)="table.reload()">Reintentar</button>
    </div>
  }

  @if (table.hasMore()) {
    <button type="button" class="rd-load-more" [disabled]="table.loading()" (click)="table.loadMore()">
      {{ table.loading() ? 'Cargando…' : 'Cargar más' }}
    </button>
  }
</section>
```

### `redemptions-admin.component.scss`

Usa el mismo aspecto que la tabla de "Movimientos" de la pestaña Puntos:

```scss
@use '../../shared/puntos-dorados-shared.scss' as *;

:host {
  display: block;
}

.rd-card {
  padding: 1.5rem;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 1rem;
  background: var(--bs-body-bg);
  box-shadow: 0 4px 16px rgb(0 0 0 / 0.05);
}

.rd-head {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.rd-title {
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

.rd-hint {
  margin: 0;
  color: var(--bs-secondary-color);
  font-size: 0.875rem;
}

.rd-filters {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(12rem, 1fr));
  gap: 0.75rem;
  margin-bottom: 0.75rem;
}

.rd-table-wrap {
  overflow-x: auto;
  overflow-y: hidden;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 0.75rem;
  transition: opacity 0.2s ease;

  &.is-loading {
    opacity: 0.55;
  }
}

.rd-table {
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
}

.rd-badge {
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--bs-warning) 18%, transparent);
  font-size: 0.75rem;
  font-weight: 600;
  white-space: nowrap;
}

.rd-load-more {
  display: block;
  margin: 1rem auto 0;
  padding: 0.5rem 1.5rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 999px;
  background: var(--bs-body-bg);
  font-weight: 600;
}

.rd-empty {
  padding: 1.5rem;
  color: var(--bs-secondary-color);
  text-align: center;
}

.rd-skeleton {
  display: grid;
  gap: 0.5rem;
  padding: 0.75rem;

  span {
    height: 2.5rem;
    border-radius: 0.5rem;
    background: var(--bs-tertiary-bg);
    animation: rd-pulse 1.2s ease-in-out infinite alternate;
  }
}

@keyframes rd-pulse {
  to { opacity: 0.5; }
}

// En el celular, cada fila es una tarjeta con la etiqueta a la izquierda.
@media (max-width: 767.98px) {
  .rd-table thead { display: none; }

  .rd-table tr {
    display: block;
    padding: 0.5rem 0.9rem;
    border-top: 1px solid var(--bs-border-color-translucent);
  }

  .rd-table td {
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
}

@media (prefers-reduced-motion: reduce) {
  .rd-skeleton span {
    animation: none;
  }
}
```

---

## 12. Paso 9 — La pestaña en el admin

### `puntos-dorados-admin.component.ts` ✏️

```ts
import { GoldenRedemptionsAdminComponent } from "./redemptions-admin/redemptions-admin.component";

type AdminTab = 'aprobaciones' | 'categorias' | 'catalogo' | 'puntos' | 'redenciones' | 'dashboard' | 'masivos';
```

Y en `imports` del `@Component`, agrega `GoldenRedemptionsAdminComponent`.

`loadAdminTabData` no cambia: el componente carga su tabla al crearse, igual que `app-golden-points-admin`.

### `puntos-dorados-admin.component.html` ✏️

Botón, después de "Puntos":

```html
<button type="button" class="tab-btn" [class.active]="activeTab() === 'redenciones'"
  (click)="setActiveTab('redenciones')">Redenciones</button>
```

Contenido, después del bloque de `'puntos'`:

```html
@if (activeTab() === 'redenciones') {
<app-golden-redemptions-admin [people]="people()" />
}
```

> Como está dentro de `@if`, el componente se crea cada vez que se abre la pestaña: la tabla siempre trae las redenciones más recientes.

---

## 13. Pruebas

**Canjear** (desde "Redimir" del colaborador)

- **Canje normal:**
  - "Confirmar canje" muestra "¡Canje registrado!" con el saldo nuevo.
  - En "Mis puntos" aparece un movimiento "Redención: <producto>" con los puntos en negativo.
  - El stock del producto baja en 1.
- **La petición** va a `/api/GoldenRedemptions`, no a `/api/api/…`.
- **Doble clic** o el mismo `requestId` enviado dos veces desde Swagger: una sola redención, un solo descuento, y las dos respuestas iguales.
- **Errores** (el mensaje sale en el modal):
  - **Saldo insuficiente:** "No te alcanzan los puntos: tienes 50 disponibles y este premio cuesta 300."
  - **Stock en 0:** "Este premio ya no está disponible (Sin stock)…". También con el producto inactivo, la categoría inactiva o el producto vencido.
  - **`max_redemptions_per_user = 1` y segundo canje:** "Ya alcanzaste el máximo de canjes de este premio por persona (1)."
- **Puntos vencidos sin procesar:**
  - **Datos de prueba:** un lote con `expires_date` de ayer y `remaining_points > 0`.
  - **Resultado:** esos puntos no alcanzan para canjear; el mensaje muestra solo los disponibles.
- **Lotes:** con dos lotes (100 que vencen antes y 300 después), canjear 150 deja 0 en el primero y 250 en el segundo.
- **Consultas de control:** las del libro y las de la sección 3 devuelven cero filas.
- **Dos canjes del último del stock al mismo tiempo** (dos pestañas, dos personas): uno se registra y el otro recibe "Sin stock". El stock queda en 0, nunca en −1.

**Pantalla "Redenciones"**

- **Al abrir:** muestra todas las redenciones (período "Todo"), de la más nueva a la más vieja, con el total en el encabezado.
- **Filtros:**
  - **"Este mes", una persona, una categoría:** cada uno filtra al instante y el total cambia. "Limpiar filtros" vuelve a todo.
  - **Categoría "Beneficios":** el select de productos muestra solo los de esa categoría. Si había un producto de otra categoría elegido, se quita.
  - **"Personalizado":** aparecen "Desde" y "Hasta". Con "Desde" posterior a "Hasta" sale el aviso y no se consulta.
  - **"Hasta" = hoy:** incluye un canje hecho hoy a las 11 p. m.
- **Producto renombrado después de un canje:** la fila sigue mostrando el nombre de ese día.
- **Exportar:**
  - El XLSX trae las mismas filas que el filtro (todas, no solo la página visible).
  - **Hoja "Filtros":** el período, la persona, la categoría, el producto, el total de puntos y la fecha de exportación.
  - **Columna "Fecha":** es una fecha de Excel (se ordena y filtra) y muestra **la misma hora que la tabla**. Si sale corrida 5 horas, la versión de `xlsx` interpreta las fechas en UTC; en ese caso avísame.
  - **Sin resultados:** el botón está deshabilitado.
  - **Más de 20.000 filas** (o baja `MaxExportRows` a 2 para probar): "Hay más de 20.000 redenciones…".
- **Celular:** cada fila se ve como tarjeta con su etiqueta.

---

## 14. Lo que queda para después

| Tema | Cómo encaja |
|---|---|
| **Estado de la solicitud** ("Solicitada", "Entregada", "Cancelada") | Columna `status VARCHAR(20) NOT NULL DEFAULT 'REQUESTED'` con su `CHECK`, `row_version` y un `PATCH /{id}/status`. Cancelar debería **devolver los puntos** con un movimiento inverso del libro y subir el stock otra vez. Cuando lo decidan, se agrega un filtro "Estado" y una columna en la tabla y en el XLSX. |
| **Aviso por correo** al administrador o al colaborador | Con el log de correos existente, después de guardar (fuera de la transacción). |
| **Cédula o área en la exportación** | La entidad `User` no tiene cédula, y `UsersArea` no está mapeada. Cuando existan, se agregan a `GoldenRedemptionAdminDto` y al selector de `ExportAsync`. |
| **"Mis canjes" del colaborador** | `GET /me` con el mismo DTO, filtrando por su usuario. Reemplazaría el mock `getRedemptions(email)`. |
| **Borrar productos** | La guía de productos dice que un producto **nunca redimido** se podría borrar. Ahora se puede saber: `AnyAsync(r => r.ProductId == id)` sobre `golden_redemption`. |

---

## ✅ Checklist

**Backend**
- [ ] `GoldenPointsRedemptions.sql` ejecutado (tabla, índices y consultas de control).
- [ ] `GoldenRedemption` + configuración + `DbSet`.
- [ ] `GoldenPointsDebit` y `GoldenPointsLedger.DebitAsync`; `InsufficientBalance` en `GoldenPointsConstants`.
- [ ] `GoldenRedemptionConstants`, DTOs, `IGoldenRedemptionService`, `GoldenRedemptionService` y su registro.
- [ ] `GoldenRedemptionsController`: `POST`, `GET` y `GET export`, con `try/catch` completo y los permisos comentados.

**Frontend**
- [ ] URL del servicio de redención corregida (`/GoldenRedemptions`, sin `/api` de más).
- [ ] Dominio, mapper, servicio (`getPage`, `export`) y facade.
- [ ] `golden-redemptions-excel.ts`.
- [ ] `app-golden-redemptions-admin` y la pestaña "Redenciones" en el admin.
