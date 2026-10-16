# 💰 Puntos Dorados — Asignación de puntos y "Mis puntos" (API .NET 8 + SQL Server)

Los puntos se manejan **como dinero**:
- **Nunca se edita un saldo a mano.** Cada entrada o salida de puntos es un **movimiento** que queda guardado para siempre.
- **El saldo es el resultado de los movimientos.** Por eso siempre se puede explicar de dónde salió cada punto.

| Pantalla | Quién | Qué hace |
|---|---|---|
| **Puntos** (administración) | Compensación y Beneficios | Asignar puntos a una persona **sin reconocimiento**, consultar movimientos y reversar una asignación hecha por error. |
| **Mis puntos** (colaborador) | Cada persona | Saldo, puntos por vencer e historial: asignaciones directas y reconocimientos con puntos. |

**El feed no cambia.** Una asignación de puntos no es un reconocimiento: se guarda en el libro de puntos, no en `golden_recognition`, así que nunca sale en el feed.

**Fuera de alcance (siguiente parte):** gastar puntos (redención), procesar los vencimientos y la carga masiva por Excel. La sección 10 deja el diseño listo para ellas.

- **Stack:** .NET 8 · EF Core 8 · SQL Server
- **Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md) (patrón de Request, `try/catch` completo en cada acción, `User` sin área).

---

## 1. 🏦 El modelo: cuenta, libro de movimientos y lotes

```text
dbo.users ──1:1── dbo.golden_points_account          saldo actual (con row_version)
    │
    └──1:N── dbo.golden_points_transaction           LIBRO: un movimiento por fila, nunca se edita
                 │  CREDIT  +200  "Asignación de puntos"      saldo después: 200
                 │  CREDIT  +150  "Reconocimiento · Servicio"  saldo después: 350
                 │  ADJUSTMENT −200 "Reverso de la #1"         saldo después: 150
                 │  DEBIT   −100  "Redención: Kit" (luego)     saldo después: 50
                 │
                 └──1:1── dbo.golden_points_bucket   LOTE: cada abono, con su fecha de vencimiento
                              original 150 · quedan 150 · vence 2027-04-07
```

| Tabla | Para qué | Regla |
|---|---|---|
| `golden_points_account` | Saldo actual de cada persona, para consultarlo rápido y para bloquear cambios simultáneos. | `balance >= 0`. `row_version`: dos abonos a la vez no se pisan. |
| `golden_points_transaction` | El historial (libro). | **Solo se insertan filas**: un trigger bloquea `UPDATE` y `DELETE`. Cada fila guarda el saldo que quedó (`balance_after`). |
| `golden_points_bucket` | Cuántos puntos quedan de cada abono y cuándo vencen. | Los gastos y los vencimientos (siguiente parte) los consumen del más próximo a vencer. |

**Invariante:** saldo de la cuenta = suma de los movimientos = suma de lo que queda en los lotes. La sección 4 trae las consultas para verificarlo.

---

## 2. 🧭 ¿Repositorio propio?

| Operación | Cómo | Por qué |
|---|---|---|
| Asignar y reversar | Repositorio genérico + `ITransactionExecutorHelper`, con la regla en `GoldenPointsLedger` | Son inserciones y cambios simples sobre tres tablas, en una transacción. |
| Historial, resumen y próximos vencimientos | `IGoldenPointsQueryRepository` (solo lectura) | Sumas en SQL (total ganado, puntos por vencer), paginación con total y proyección con persona, reconocimiento y lote. Son los casos de la sección 5 de [ARQUITECTURA Y EJEMPLO](.claude/ARQUITECTURA%20Y%20EJEMPLO.MD). |

`GoldenPointsLedger` **no guarda nada**: trabaja con el `IUnitOfWork` de quien lo llama. Así la aprobación de un reconocimiento (parte 2) abona los puntos **en la misma transacción** en que lo aprueba: se guardan las dos cosas o ninguna.

---

## 3. 🧐 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Nada se borra ni se edita.** | Un error se corrige con un movimiento inverso (**reverso**), que queda en el historial. Un trigger en la base de datos impide `UPDATE` y `DELETE` en el libro. |
| 2 | **Doble clic en "Asignar".** Con dinero, eso es abonar dos veces. | Cada envío del formulario lleva un `requestId` (GUID que genera el frontend). Índice único en la base de datos: la segunda petición encuentra la primera y responde lo mismo, **sin abonar otra vez**. |
| 3 | **Dos abonos a la misma persona al mismo tiempo.** | `row_version` en la cuenta: el segundo choca y se reintenta (hasta 3 veces) leyendo el saldo nuevo. `balance_after` siempre queda bien. |
| 4 | **Reversar.** | Solo asignaciones **manuales** cuyos puntos **no se han usado** (el lote está completo), y una sola vez (índice único). Pide un motivo. |
| 5 | **Asignarse puntos a uno mismo.** | No se permite: otra persona del equipo debe hacerlo. Es un control básico cuando se maneja algo como dinero. |
| 6 | **Vencimiento.** La pantalla "Mis reconocimientos" ya muestra "Vencimiento de puntos" (unos 6 meses). | Cada abono vence por defecto **6 meses** después (`DefaultExpirationMonths`). El administrador puede elegir otra fecha, hasta 24 meses. ⚠️ Revisa si 6 meses es la regla del negocio. |
| 7 | **¿Quién descuenta los puntos vencidos?** | Un proceso diario (siguiente parte, sección 10). Mientras no exista, nada se descuenta solo. Los primeros puntos vencen 6 meses después de la primera asignación, así que hay margen para construirlo. |
| 8 | **Reconocimiento con puntos.** | Al **aprobarlo** (parte 2) se abona con `GoldenPointsLedger.CreditAsync`, origen "Reconocimiento". Índice único: un reconocimiento abona **una sola vez**. |
| 9 | **Puntos en el feed.** | Nunca. El feed lee reconocimientos, no movimientos. |
| 10 | **Concepto.** | Obligatorio (5 a 300 caracteres): es lo que la persona ve en su historial ("Bono por cierre de proyecto"). |
| 11 | **Límites.** | 1 a 100.000 puntos por asignación. Evita un cero de más por error de tipeo. |

---

## 4. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/GoldenPointsLedger.sql`

```sql
/* =====================================================================
   Puntos Dorados — cuenta, libro de movimientos y lotes de puntos
   Base de datos: DB · Esquema: dbo
   Requiere: dbo.users, dbo.golden_recognition (GoldenPointsRecognitions.sql)
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_points_account — saldo actual, una fila por persona
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_points_account', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_points_account
    (
        user_id      INT           NOT NULL,
        balance      INT           NOT NULL CONSTRAINT df_golden_points_account_balance DEFAULT (0),
        row_version  ROWVERSION    NOT NULL,
        created_date DATETIME2(0)  NOT NULL CONSTRAINT df_golden_points_account_created_date DEFAULT (SYSUTCDATETIME()),
        updated_date DATETIME2(0)  NULL,

        CONSTRAINT pk_golden_points_account PRIMARY KEY CLUSTERED (user_id),
        CONSTRAINT fk_golden_points_account_user FOREIGN KEY (user_id) REFERENCES dbo.users (id),
        -- Como una cuenta bancaria sin sobregiro.
        CONSTRAINT ck_golden_points_account_balance CHECK (balance >= 0)
    );
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_points_transaction — LIBRO: solo inserciones
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_points_transaction', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_points_transaction
    (
        id                      INT              IDENTITY(1, 1) NOT NULL,
        user_id                 INT              NOT NULL,
        type                    VARCHAR(20)      NOT NULL,   -- CREDIT | DEBIT | ADJUSTMENT | EXPIRATION
        source                  VARCHAR(20)      NOT NULL,   -- MANUAL | RECOGNITION | REDEMPTION | EXPIRATION
        points                  INT              NOT NULL,   -- con signo: + entra, − sale
        balance_after           INT              NOT NULL,   -- saldo de la cuenta después de este movimiento
        concept                 NVARCHAR(300)    NOT NULL,
        recognition_id          INT              NULL,       -- si viene de un reconocimiento
        reverses_transaction_id INT              NULL,       -- si es el reverso de otra asignación
        request_id              UNIQUEIDENTIFIER NULL,       -- idempotencia del formulario
        created_date            DATETIME2(0)     NOT NULL CONSTRAINT df_golden_points_transaction_created_date DEFAULT (SYSUTCDATETIME()),
        created_by              NVARCHAR(150)    NOT NULL,

        CONSTRAINT pk_golden_points_transaction PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_golden_points_transaction_user FOREIGN KEY (user_id) REFERENCES dbo.users (id),
        CONSTRAINT fk_golden_points_transaction_recognition FOREIGN KEY (recognition_id) REFERENCES dbo.golden_recognition (id),
        CONSTRAINT fk_golden_points_transaction_reverses
            FOREIGN KEY (reverses_transaction_id) REFERENCES dbo.golden_points_transaction (id),
        CONSTRAINT ck_golden_points_transaction_type CHECK (type IN ('CREDIT', 'DEBIT', 'ADJUSTMENT', 'EXPIRATION')),
        CONSTRAINT ck_golden_points_transaction_source CHECK (source IN ('MANUAL', 'RECOGNITION', 'REDEMPTION', 'EXPIRATION')),
        -- El signo debe corresponder al tipo.
        CONSTRAINT ck_golden_points_transaction_sign CHECK (
            (type = 'CREDIT' AND points > 0) OR
            (type IN ('DEBIT', 'EXPIRATION') AND points < 0) OR
            (type = 'ADJUSTMENT' AND points <> 0)),
        CONSTRAINT ck_golden_points_transaction_balance CHECK (balance_after >= 0),
        CONSTRAINT ck_golden_points_transaction_concept CHECK (LEN(LTRIM(RTRIM(concept))) > 0)
    );

    -- Historial de una persona, lo más reciente primero.
    CREATE INDEX ix_golden_points_transaction_user
        ON dbo.golden_points_transaction (user_id, created_date DESC, id DESC)
        INCLUDE (type, source, points, balance_after);

    -- Doble clic: un requestId solo se procesa una vez.
    CREATE UNIQUE INDEX ux_golden_points_transaction_request
        ON dbo.golden_points_transaction (request_id)
        WHERE request_id IS NOT NULL;

    -- Una asignación se reversa una sola vez.
    CREATE UNIQUE INDEX ux_golden_points_transaction_reverses
        ON dbo.golden_points_transaction (reverses_transaction_id)
        WHERE reverses_transaction_id IS NOT NULL;

    -- Un reconocimiento abona puntos una sola vez.
    CREATE UNIQUE INDEX ux_golden_points_transaction_recognition_credit
        ON dbo.golden_points_transaction (recognition_id)
        WHERE recognition_id IS NOT NULL AND type = 'CREDIT';
END;
GO

/* El libro no se edita ni se borra: los errores se corrigen con un movimiento inverso. */
IF OBJECT_ID(N'dbo.tr_golden_points_transaction_immutable', N'TR') IS NULL
    EXEC (N'
    CREATE TRIGGER dbo.tr_golden_points_transaction_immutable
    ON dbo.golden_points_transaction
    INSTEAD OF UPDATE, DELETE
    AS
    BEGIN
        RAISERROR (N''Los movimientos de puntos no se modifican ni se eliminan. Registra un movimiento inverso.'', 16, 1);
        ROLLBACK TRANSACTION;
    END');
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_points_bucket — LOTE: lo que queda de cada abono y cuándo vence
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_points_bucket', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_points_bucket
    (
        id               INT          IDENTITY(1, 1) NOT NULL,
        user_id          INT          NOT NULL,
        transaction_id   INT          NOT NULL,
        original_points  INT          NOT NULL,
        remaining_points INT          NOT NULL,
        expires_date     DATE         NOT NULL,
        created_date     DATETIME2(0) NOT NULL CONSTRAINT df_golden_points_bucket_created_date DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT pk_golden_points_bucket PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_golden_points_bucket_user FOREIGN KEY (user_id) REFERENCES dbo.users (id),
        CONSTRAINT fk_golden_points_bucket_transaction FOREIGN KEY (transaction_id) REFERENCES dbo.golden_points_transaction (id),
        CONSTRAINT uq_golden_points_bucket_transaction UNIQUE (transaction_id),
        CONSTRAINT ck_golden_points_bucket_points CHECK (original_points > 0 AND remaining_points BETWEEN 0 AND original_points)
    );

    -- "Puntos por vencer" y, más adelante, gastar primero lo que vence antes.
    CREATE INDEX ix_golden_points_bucket_user_expires
        ON dbo.golden_points_bucket (user_id, expires_date)
        INCLUDE (remaining_points)
        WHERE remaining_points > 0;
END;
GO
```

### Consultas de control (deben devolver **cero filas**)

```sql
-- 1. Saldo de la cuenta = suma de sus movimientos
SELECT a.user_id, a.balance, ledger = COALESCE(SUM(t.points), 0)
FROM   dbo.golden_points_account a
LEFT JOIN dbo.golden_points_transaction t ON t.user_id = a.user_id
GROUP BY a.user_id, a.balance
HAVING a.balance <> COALESCE(SUM(t.points), 0);

-- 2. Saldo de la cuenta = lo que queda en sus lotes
SELECT a.user_id, a.balance, buckets = COALESCE(SUM(b.remaining_points), 0)
FROM   dbo.golden_points_account a
LEFT JOIN dbo.golden_points_bucket b ON b.user_id = a.user_id
GROUP BY a.user_id, a.balance
HAVING a.balance <> COALESCE(SUM(b.remaining_points), 0);

-- 3. Cada "saldo después" coincide con el acumulado
SELECT id, user_id, balance_after, running
FROM (
    SELECT id, user_id, balance_after,
           running = SUM(points) OVER (PARTITION BY user_id ORDER BY id ROWS UNBOUNDED PRECEDING)
    FROM dbo.golden_points_transaction
) x
WHERE balance_after <> running;
```

> Programa estas tres consultas como alerta (por ejemplo, un job semanal). Si alguna devuelve filas, alguien tocó las tablas por fuera de la API.

---

## 5. Paso 2 — Dominio y configuración EF

### `Enum/GoldenPointsTransactionType.cs` y `Enum/GoldenPointsSource.cs`

```csharp
namespace DOCCB.Domain.Enum
{
    public enum GoldenPointsTransactionType
    {
        Credit = 1,       // entra: asignación o reconocimiento
        Debit = 2,        // sale: redención
        Adjustment = 3,   // corrección (reverso de una asignación)
        Expiration = 4,   // sale: puntos vencidos
    }

    public enum GoldenPointsSource
    {
        Manual = 1,
        Recognition = 2,
        Redemption = 3,
        Expiration = 4,
    }
}
```

> Uno por archivo, con el nombre del enum.

### `Entities/GoldenPointsAccount.cs`

```csharp
namespace DOCCB.Domain.Entities
{
    /// <summary>Saldo actual de puntos de una persona. Lo cambia solo GoldenPointsLedger.</summary>
    public class GoldenPointsAccount
    {
        public int UserId { get; set; }
        public int Balance { get; set; }
        public byte[] RowVersion { get; set; } = [];
        public DateTime CreatedDate { get; set; }
        public DateTime? UpdatedDate { get; set; }
    }
}
```

### `Entities/GoldenPointsTransaction.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities
{
    /// <summary>Un movimiento del libro de puntos. Nunca se modifica.</summary>
    public class GoldenPointsTransaction
    {
        public int Id { get; set; }
        public int UserId { get; set; }
        public GoldenPointsTransactionType Type { get; set; }
        public GoldenPointsSource Source { get; set; }

        /// <summary>Con signo: positivo entra, negativo sale.</summary>
        public int Points { get; set; }

        /// <summary>Saldo de la cuenta después de este movimiento.</summary>
        public int BalanceAfter { get; set; }

        public string Concept { get; set; } = string.Empty;
        public int? RecognitionId { get; set; }
        public int? ReversesTransactionId { get; set; }
        public Guid? RequestId { get; set; }
        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;

        public User User { get; set; } = null!;
        public GoldenRecognition? Recognition { get; set; }
        public GoldenPointsTransaction? ReversesTransaction { get; set; }
        public GoldenPointsTransaction? ReversedBy { get; set; }
        public GoldenPointsBucket? Bucket { get; set; }
    }
}
```

### `Entities/GoldenPointsBucket.cs`

```csharp
namespace DOCCB.Domain.Entities
{
    /// <summary>Lo que queda de un abono y cuándo vence.</summary>
    public class GoldenPointsBucket
    {
        public int Id { get; set; }
        public int UserId { get; set; }
        public int TransactionId { get; set; }
        public int OriginalPoints { get; set; }
        public int RemainingPoints { get; set; }
        public DateOnly ExpiresDate { get; set; }
        public DateTime CreatedDate { get; set; }

        public GoldenPointsTransaction Transaction { get; set; } = null!;
    }
}
```

### `Configurations/GoldenPointsAccountConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenPointsAccountConfiguration : IEntityTypeConfiguration<GoldenPointsAccount>
    {
        public void Configure(EntityTypeBuilder<GoldenPointsAccount> builder)
        {
            builder.ToTable("golden_points_account", "dbo");

            builder.HasKey(a => a.UserId).HasName("pk_golden_points_account");

            builder.Property(a => a.UserId).HasColumnName("user_id").ValueGeneratedNever();
            builder.Property(a => a.Balance).HasColumnName("balance");
            builder.Property(a => a.RowVersion).HasColumnName("row_version").IsRowVersion();
            builder.Property(a => a.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(a => a.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");

            builder.HasOne<User>()
                .WithOne()
                .HasForeignKey<GoldenPointsAccount>(a => a.UserId)
                .HasConstraintName("fk_golden_points_account_user")
                .OnDelete(DeleteBehavior.Restrict);
        }
    }
}
```

### `Configurations/GoldenPointsTransactionConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenPointsTransactionConfiguration : IEntityTypeConfiguration<GoldenPointsTransaction>
    {
        public void Configure(EntityTypeBuilder<GoldenPointsTransaction> builder)
        {
            // HasTrigger: EF Core 7+ no puede usar OUTPUT en tablas con triggers si no se le avisa.
            builder.ToTable("golden_points_transaction", "dbo", table =>
                table.HasTrigger("tr_golden_points_transaction_immutable"));

            builder.HasKey(t => t.Id).HasName("pk_golden_points_transaction");

            builder.Property(t => t.Id).HasColumnName("id");
            builder.Property(t => t.UserId).HasColumnName("user_id");
            builder.Property(t => t.Points).HasColumnName("points");
            builder.Property(t => t.BalanceAfter).HasColumnName("balance_after");
            builder.Property(t => t.Concept).HasColumnName("concept").HasMaxLength(300).IsRequired();
            builder.Property(t => t.RecognitionId).HasColumnName("recognition_id");
            builder.Property(t => t.ReversesTransactionId).HasColumnName("reverses_transaction_id");
            builder.Property(t => t.RequestId).HasColumnName("request_id");
            builder.Property(t => t.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(t => t.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();

            builder.Property(t => t.Type)
                .HasColumnName("type")
                .HasMaxLength(20)
                .IsUnicode(false)
                .HasConversion(
                    type => type.ToString().ToUpperInvariant(),
                    code => Enum.Parse<GoldenPointsTransactionType>(code, true));

            builder.Property(t => t.Source)
                .HasColumnName("source")
                .HasMaxLength(20)
                .IsUnicode(false)
                .HasConversion(
                    source => source.ToString().ToUpperInvariant(),
                    code => Enum.Parse<GoldenPointsSource>(code, true));

            builder.HasIndex(t => t.RequestId)
                .IsUnique()
                .HasFilter("[request_id] IS NOT NULL")
                .HasDatabaseName("ux_golden_points_transaction_request");

            builder.HasOne(t => t.User)
                .WithMany()
                .HasForeignKey(t => t.UserId)
                .HasConstraintName("fk_golden_points_transaction_user")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasOne(t => t.Recognition)
                .WithMany()
                .HasForeignKey(t => t.RecognitionId)
                .HasConstraintName("fk_golden_points_transaction_recognition")
                .OnDelete(DeleteBehavior.Restrict);

            // Un reverso apunta a la asignación que corrige; esa asignación sabe si ya fue reversada.
            builder.HasOne(t => t.ReversesTransaction)
                .WithOne(t => t.ReversedBy)
                .HasForeignKey<GoldenPointsTransaction>(t => t.ReversesTransactionId)
                .HasConstraintName("fk_golden_points_transaction_reverses")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasOne(t => t.Bucket)
                .WithOne(b => b.Transaction)
                .HasForeignKey<GoldenPointsBucket>(b => b.TransactionId)
                .HasConstraintName("fk_golden_points_bucket_transaction")
                .OnDelete(DeleteBehavior.Restrict);
        }
    }
}
```

> Los códigos `CREDIT`, `ADJUSTMENT`… salen de `ToString().ToUpperInvariant()` del enum: `Credit` → `CREDIT`. No cambies el nombre de un valor del enum sin cambiar también el `CHECK` del script.

### `Configurations/GoldenPointsBucketConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenPointsBucketConfiguration : IEntityTypeConfiguration<GoldenPointsBucket>
    {
        public void Configure(EntityTypeBuilder<GoldenPointsBucket> builder)
        {
            builder.ToTable("golden_points_bucket", "dbo");

            builder.HasKey(b => b.Id).HasName("pk_golden_points_bucket");

            builder.Property(b => b.Id).HasColumnName("id");
            builder.Property(b => b.UserId).HasColumnName("user_id");
            builder.Property(b => b.TransactionId).HasColumnName("transaction_id");
            builder.Property(b => b.OriginalPoints).HasColumnName("original_points");
            builder.Property(b => b.RemainingPoints).HasColumnName("remaining_points");
            builder.Property(b => b.ExpiresDate).HasColumnName("expires_date").HasColumnType("date");
            builder.Property(b => b.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");

            builder.HasOne<User>()
                .WithMany()
                .HasForeignKey(b => b.UserId)
                .HasConstraintName("fk_golden_points_bucket_user")
                .OnDelete(DeleteBehavior.Restrict);

            // La relación con la transacción está en GoldenPointsTransactionConfiguration.
        }
    }
}
```

### `Persistence/Models/DOCCbDbContext.cs` ✏️

```csharp
public DbSet<GoldenPointsAccount> GoldenPointsAccounts { get; set; }
public DbSet<GoldenPointsTransaction> GoldenPointsTransactions { get; set; }
public DbSet<GoldenPointsBucket> GoldenPointsBuckets { get; set; }
```

---

## 6. Paso 3 — Constantes, códigos, DTOs y reglas

### `Constants/GoldenPointsConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenPointsConstants
    {
        public const int MaxPointsPerAssignment = 100_000;
        public const int ConceptMinLength = 5;
        public const int ConceptMaxLength = 300;
        public const int ReasonMinLength = 5;
        public const int ReasonMaxLength = 200;
        public const int DefaultExpirationMonths = 6;   // ⚠️ confirmar con el negocio
        public const int MaxExpirationMonths = 24;
        public const int ExpiringSoonDays = 30;
        public const int UpcomingExpirationsTake = 5;
        public const int DefaultPageSize = 10;
        public const int MaxPageSize = 50;
        public const int SaveAttempts = 3;

        public const string UserNotRegistered = "Para realizar cualquier acción primero debes ingresar tu información en el módulo 'Mis Datos'";
        public const string UserEmailRequired = "Selecciona a la persona.";
        public const string UserNotFound = "La persona seleccionada no existe.";
        public const string CannotAssignToYourself = "No puedes asignarte puntos a ti mismo. Pídele a otra persona del equipo que lo haga.";
        public const string PointsInvalid = "Los puntos deben ser un número entre 1 y 100.000.";
        public const string ConceptInvalid = "Escribe el concepto de la asignación (entre 5 y 300 caracteres).";
        public const string ExpirationInvalid = "La fecha de vencimiento debe ser posterior a hoy y máximo 24 meses después.";
        public const string RequestIdRequired = "Falta el identificador de la solicitud. Recarga la página e intenta de nuevo.";
        public const string ReasonInvalid = "Escribe el motivo del reverso (entre 5 y 200 caracteres).";
        public const string TransactionNotFound = "El movimiento no existe.";
        public const string OnlyManualCanBeReversed = "Solo se pueden reversar asignaciones manuales de puntos.";
        public const string AlreadyReversed = "Esta asignación ya fue reversada.";
        public const string AlreadyUsed = "Los puntos de esta asignación ya se usaron o vencieron: no se puede reversar.";
        public const string InvalidTypeFilter = "El tipo debe ser Credito, Debito, Ajuste o Vencimiento.";
        public const string InvalidSourceFilter = "El origen debe ser Asignacion, Reconocimiento, Redencion o Vencimiento.";
        public const string ConcurrentChange = "Hubo otro movimiento de puntos al mismo tiempo. Intenta de nuevo.";
        public const string UnexpectedError = "No se pudo completar la operación. Intenta de nuevo.";
    }
}
```

### `Constants/GoldenPointsCodes.cs`

Traduce los enums a los textos del frontend (`GoldenPointsTransactionType = 'Credito' | 'Debito' | 'Ajuste' | 'Vencimiento'`) y al revés.

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenPointsCodes
    {
        private static readonly IReadOnlyDictionary<GoldenPointsTransactionType, string> TypeCodes = new Dictionary<GoldenPointsTransactionType, string>
        {
            [GoldenPointsTransactionType.Credit] = "Credito",
            [GoldenPointsTransactionType.Debit] = "Debito",
            [GoldenPointsTransactionType.Adjustment] = "Ajuste",
            [GoldenPointsTransactionType.Expiration] = "Vencimiento",
        };

        private static readonly IReadOnlyDictionary<GoldenPointsSource, string> SourceCodes = new Dictionary<GoldenPointsSource, string>
        {
            [GoldenPointsSource.Manual] = "Asignacion",
            [GoldenPointsSource.Recognition] = "Reconocimiento",
            [GoldenPointsSource.Redemption] = "Redencion",
            [GoldenPointsSource.Expiration] = "Vencimiento",
        };

        public static string ToTypeCode(GoldenPointsTransactionType type) => TypeCodes[type];

        public static string ToSourceCode(GoldenPointsSource source) => SourceCodes[source];

        /// <summary>Vacío = sin filtro (true con null). Sin distinguir mayúsculas. false = valor desconocido.</summary>
        public static bool TryParseType(string? value, out GoldenPointsTransactionType? type) => TryParse(TypeCodes, value, out type);

        public static bool TryParseSource(string? value, out GoldenPointsSource? source) => TryParse(SourceCodes, value, out source);

        private static bool TryParse<TEnum>(IReadOnlyDictionary<TEnum, string> codes, string? value, out TEnum? result)
            where TEnum : struct, Enum
        {
            result = null;

            if (string.IsNullOrWhiteSpace(value))
            {
                return true;
            }

            foreach (var pair in codes)
            {
                if (string.Equals(pair.Value, value.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    result = pair.Key;
                    return true;
                }
            }

            return false;
        }
    }
}
```

### `Dtos/GoldenPointsDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>Formulario "Asignar puntos" (administración).</summary>
    public class AssignGoldenPointsDto
    {
        public string? UserEmail { get; set; }
        public int Points { get; set; }
        public string? Concept { get; set; }
        /// <summary>Opcional. Por defecto, hoy + 6 meses.</summary>
        public DateOnly? ExpiresDate { get; set; }
        /// <summary>GUID que genera el frontend al abrir el formulario: evita abonar dos veces.</summary>
        public Guid RequestId { get; set; }
    }

    public class ReverseGoldenPointsDto
    {
        public string? Reason { get; set; }
    }

    /// <summary>?page=&pageSize=&type=&source=&email= (email solo en administración).</summary>
    public class GoldenPointsTransactionQueryDto
    {
        public int Page { get; set; } = 1;
        public int PageSize { get; set; } = 10;
        /// <summary>Credito | Debito | Ajuste | Vencimiento</summary>
        public string? Type { get; set; }
        /// <summary>Asignacion | Reconocimiento | Redencion | Vencimiento</summary>
        public string? Source { get; set; }
        public string? Email { get; set; }
    }

    /// <summary>Un movimiento del historial (GoldenPointsTransaction del frontend, con campos extra).</summary>
    public class GoldenPointsTransactionDto
    {
        public int Id { get; set; }
        public string UserEmail { get; set; } = string.Empty;
        /// <summary>Solo en administración.</summary>
        public string? UserName { get; set; }
        /// <summary>Credito | Debito | Ajuste | Vencimiento</summary>
        public string Type { get; set; } = string.Empty;
        /// <summary>Asignacion | Reconocimiento | Redencion | Vencimiento</summary>
        public string Source { get; set; } = string.Empty;
        /// <summary>Texto listo para mostrar: "Asignación de puntos", "Reconocimiento · Servicio"…</summary>
        public string SourceLabel { get; set; } = string.Empty;
        public string Concept { get; set; } = string.Empty;
        /// <summary>Con signo: +200, −100.</summary>
        public int Points { get; set; }
        public int BalanceAfter { get; set; }
        public int? RecognitionId { get; set; }
        /// <summary>Solo en abonos: cuándo vencen y cuántos quedan.</summary>
        public DateOnly? ExpiresAt { get; set; }
        public int? RemainingPoints { get; set; }
        public bool IsReversed { get; set; }
        /// <summary>Solo en administración: se puede reversar ahora.</summary>
        public bool CanReverse { get; set; }
        public DateTime CreatedAt { get; set; }
        /// <summary>Solo en administración: quién hizo el movimiento.</summary>
        public string? CreatedBy { get; set; }
    }

    /// <summary>Un lote con saldo (GoldenPointsBucket del frontend).</summary>
    public class GoldenPointsBucketDto
    {
        public int Id { get; set; }
        public string UserEmail { get; set; } = string.Empty;
        public string Source { get; set; } = string.Empty;
        public int OriginalPoints { get; set; }
        public int RemainingPoints { get; set; }
        public DateTime AssignedAt { get; set; }
        public DateOnly ExpiresAt { get; set; }
    }

    /// <summary>Encabezado de "Mis puntos" (y del administrador al elegir una persona).</summary>
    public class GoldenPointsSummaryDto
    {
        public string UserEmail { get; set; } = string.Empty;
        public string UserName { get; set; } = string.Empty;
        public int Balance { get; set; }
        public int TotalEarned { get; set; }
        public int TotalSpent { get; set; }
        public int TotalExpired { get; set; }
        public int ExpiringSoonPoints { get; set; }
        public int ExpiringSoonDays { get; set; }
        public DateOnly? NextExpirationDate { get; set; }
        public List<GoldenPointsBucketDto> UpcomingExpirations { get; set; } = [];
    }
}
```

> La paginación usa `GoldenPagedResultDto<T>` de [la guía de reconocimientos](puntos-dorados-reconocimientos-api.md): está en la misma feature.

### `Helpers/GoldenClock.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenClock
    {
        /// <summary>"Hoy" en Colombia (UTC-5, sin horario de verano).</summary>
        public static DateOnly Today() => DateOnly.FromDateTime(DateTime.UtcNow.AddHours(-5));
    }
}
```

> `GoldenProductAvailability.Today()` (guía de productos) hace lo mismo: puedes cambiarlo por `GoldenClock.Today()` para que haya una sola definición.

### `Helpers/GoldenPointsValidator.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public sealed record GoldenPointsAssignmentDraft(string UserEmail, int Points, string Concept, DateOnly ExpiresDate, Guid RequestId);

    public static class GoldenPointsValidator
    {
        public static GoldenPointsAssignmentDraft NormalizeAssignment(AssignGoldenPointsDto dto, DateOnly today, List<string> errors)
        {
            var email = dto.UserEmail?.Trim().ToLowerInvariant() ?? string.Empty;
            if (email.Length == 0)
            {
                errors.Add(GoldenPointsConstants.UserEmailRequired);
            }

            if (dto.Points < 1 || dto.Points > GoldenPointsConstants.MaxPointsPerAssignment)
            {
                errors.Add(GoldenPointsConstants.PointsInvalid);
            }

            var concept = dto.Concept?.Trim() ?? string.Empty;
            if (concept.Length < GoldenPointsConstants.ConceptMinLength || concept.Length > GoldenPointsConstants.ConceptMaxLength)
            {
                errors.Add(GoldenPointsConstants.ConceptInvalid);
            }

            var expires = dto.ExpiresDate ?? today.AddMonths(GoldenPointsConstants.DefaultExpirationMonths);
            if (expires <= today || expires > today.AddMonths(GoldenPointsConstants.MaxExpirationMonths))
            {
                errors.Add(GoldenPointsConstants.ExpirationInvalid);
            }

            if (dto.RequestId == Guid.Empty)
            {
                errors.Add(GoldenPointsConstants.RequestIdRequired);
            }

            return new GoldenPointsAssignmentDraft(email, dto.Points, concept, expires, dto.RequestId);
        }

        public static string NormalizeReason(string? value, List<string> errors)
        {
            var reason = value?.Trim() ?? string.Empty;
            if (reason.Length < GoldenPointsConstants.ReasonMinLength || reason.Length > GoldenPointsConstants.ReasonMaxLength)
            {
                errors.Add(GoldenPointsConstants.ReasonInvalid);
            }

            return reason;
        }

        /// <summary>Página desde 1; tamaño entre 1 y 50. Fuera de rango se ajusta.</summary>
        public static (int Page, int PageSize) Paging(GoldenPointsTransactionQueryDto query) =>
            (Math.Max(1, query.Page), Math.Clamp(query.PageSize, 1, GoldenPointsConstants.MaxPageSize));
    }
}
```

### `Helpers/GoldenPointsLedger.cs` ⭐ — la única forma de mover puntos

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    /// <summary>Un abono de puntos.</summary>
    public sealed record GoldenPointsCredit(
        int UserId,
        int Points,
        GoldenPointsSource Source,
        string Concept,
        DateOnly ExpiresDate,
        string CreatedBy,
        int? RecognitionId = null,
        Guid? RequestId = null);

    /// <summary>
    /// Mueve puntos dentro de la transacción de quien llama (asignación manual, aprobación de un reconocimiento,
    /// carga masiva). No guarda: el ITransactionExecutorHelper guarda al final de la lambda, junto con lo demás.
    /// Nadie más debe cambiar golden_points_account ni golden_points_bucket.
    /// </summary>
    public static class GoldenPointsLedger
    {
        public static async Task<GoldenPointsTransaction> CreditAsync(IUnitOfWork unitOfWork, GoldenPointsCredit credit)
        {
            if (credit.Points <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(credit), "Un abono debe tener puntos positivos.");
            }

            var now = DateTime.UtcNow;
            var account = await GetOrCreateAccountAsync(unitOfWork, credit.UserId, now);

            // row_version: si otro movimiento cambió esta cuenta al mismo tiempo, el guardado falla y se reintenta.
            account.Balance += credit.Points;
            account.UpdatedDate = now;

            var transaction = new GoldenPointsTransaction
            {
                UserId = credit.UserId,
                Type = GoldenPointsTransactionType.Credit,
                Source = credit.Source,
                Points = credit.Points,
                BalanceAfter = account.Balance,
                Concept = credit.Concept,
                RecognitionId = credit.RecognitionId,
                RequestId = credit.RequestId,
                CreatedDate = now,
                CreatedBy = credit.CreatedBy,
                // El lote se inserta junto con el movimiento, en el mismo guardado.
                Bucket = new GoldenPointsBucket
                {
                    UserId = credit.UserId,
                    OriginalPoints = credit.Points,
                    RemainingPoints = credit.Points,
                    ExpiresDate = credit.ExpiresDate,
                    CreatedDate = now,
                },
            };

            await unitOfWork.Repository<GoldenPointsTransaction>().AddAsync(transaction);
            return transaction;
        }

        /// <summary>
        /// Reversa una asignación manual cuyos puntos no se han usado.
        /// Devuelve el movimiento de reverso, o el motivo por el que no se pudo.
        /// </summary>
        public static async Task<(GoldenPointsTransaction? Reversal, string? Error)> ReverseAsync(
            IUnitOfWork unitOfWork, int transactionId, string reason, string createdBy)
        {
            var transactions = unitOfWork.Repository<GoldenPointsTransaction>();

            var original = await transactions.GetByIdAsync(transactionId);
            if (original is null)
            {
                return (null, GoldenPointsConstants.TransactionNotFound);
            }

            if (original.Type != GoldenPointsTransactionType.Credit || original.Source != GoldenPointsSource.Manual)
            {
                return (null, GoldenPointsConstants.OnlyManualCanBeReversed);
            }

            if (await transactions.AnyAsync(t => t.ReversesTransactionId == transactionId))
            {
                return (null, GoldenPointsConstants.AlreadyReversed);
            }

            // GetListAsync no hace seguimiento: se obtiene el id y se lee con GetByIdAsync para poder modificarlo.
            var buckets = unitOfWork.Repository<GoldenPointsBucket>();
            var bucketId = (await buckets.GetListAsync(b => b.TransactionId == transactionId)).Select(b => b.Id).FirstOrDefault();
            var bucket = bucketId == 0 ? null : await buckets.GetByIdAsync(bucketId);

            if (bucket is null || bucket.RemainingPoints != original.Points)
            {
                return (null, GoldenPointsConstants.AlreadyUsed);
            }

            var account = await unitOfWork.Repository<GoldenPointsAccount>().GetByIdAsync(original.UserId);
            if (account is null || account.Balance < original.Points)
            {
                return (null, GoldenPointsConstants.AlreadyUsed);
            }

            var now = DateTime.UtcNow;
            bucket.RemainingPoints = 0;
            account.Balance -= original.Points;
            account.UpdatedDate = now;

            var reversal = new GoldenPointsTransaction
            {
                UserId = original.UserId,
                Type = GoldenPointsTransactionType.Adjustment,
                Source = GoldenPointsSource.Manual,
                Points = -original.Points,
                BalanceAfter = account.Balance,
                Concept = $"Reverso de la asignación #{original.Id}: {reason}",
                ReversesTransactionId = original.Id,
                CreatedDate = now,
                CreatedBy = createdBy,
            };

            await transactions.AddAsync(reversal);
            return (reversal, null);
        }

        private static async Task<GoldenPointsAccount> GetOrCreateAccountAsync(IUnitOfWork unitOfWork, int userId, DateTime now)
        {
            var accounts = unitOfWork.Repository<GoldenPointsAccount>();

            // FindAsync también encuentra una cuenta agregada antes en esta misma transacción (carga masiva).
            var account = await accounts.GetByIdAsync(userId);
            if (account is not null)
            {
                return account;
            }

            account = new GoldenPointsAccount { UserId = userId, Balance = 0, CreatedDate = now };
            await accounts.AddAsync(account);
            return account;
        }
    }
}
```

---

## 7. Paso 4 — Lecturas: `IGoldenPointsQueryRepository`

### `Contracts/Persistence/IGoldenPointsQueryRepository.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Contracts.Persistence
{
    public sealed record GoldenPointsUserRow(int Id, string Name, string Email);

    public sealed record GoldenPointsTransactionRow(
        int Id,
        int UserId,
        string UserName,
        string UserEmail,
        GoldenPointsTransactionType Type,
        GoldenPointsSource Source,
        int Points,
        int BalanceAfter,
        string Concept,
        int? RecognitionId,
        string? RecognitionCategory,
        int? ReversesTransactionId,
        bool IsReversed,
        int? RemainingPoints,
        DateOnly? ExpiresDate,
        DateTime CreatedDate,
        string CreatedBy);

    public sealed record GoldenPointsTransactionPage(IReadOnlyList<GoldenPointsTransactionRow> Rows, int TotalCount);

    public sealed record GoldenPointsSummaryRow(
        int Balance,
        int TotalEarned,
        int TotalSpent,
        int TotalExpired,
        int ExpiringSoonPoints,
        DateOnly? NextExpirationDate);

    public sealed record GoldenPointsBucketRow(
        int Id,
        string UserEmail,
        GoldenPointsSource Source,
        string? RecognitionCategory,
        int OriginalPoints,
        int RemainingPoints,
        DateTime AssignedDate,
        DateOnly ExpiresDate);

    /// <summary>Solo lectura. Los movimientos se registran con GoldenPointsLedger.</summary>
    public interface IGoldenPointsQueryRepository
    {
        Task<GoldenPointsUserRow?> GetUserAsync(string email);

        /// <summary>userId null = todas las personas (administración). Lo más reciente primero.</summary>
        Task<GoldenPointsTransactionPage> GetTransactionsPageAsync(
            int? userId, GoldenPointsTransactionType? type, GoldenPointsSource? source, int page, int pageSize);

        Task<GoldenPointsTransactionRow?> GetTransactionAsync(int transactionId);

        Task<GoldenPointsSummaryRow> GetSummaryAsync(int userId, DateOnly today, DateOnly expiringUntil);

        Task<IReadOnlyList<GoldenPointsBucketRow>> GetUpcomingExpirationsAsync(int userId, DateOnly today, int take);
    }
}
```

### `Repositories/GoldenPointsQueryRepository.cs`

```csharp
using System.Linq.Expressions;
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using DOCCB.Infraestructure.Common;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Infraestructure.Repositories
{
    /// <summary>Tabla principal: golden_points_transaction. Solo lecturas sin seguimiento.</summary>
    public class GoldenPointsQueryRepository(DOCCbDbContext context)
        : GenericRepositoryBase<DOCCbDbContext, GoldenPointsTransaction>(context), IGoldenPointsQueryRepository
    {
        private static readonly Expression<Func<GoldenPointsTransaction, GoldenPointsTransactionRow>> ToRow = t => new GoldenPointsTransactionRow(
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
            t.Recognition != null ? t.Recognition.Category.Name : null,
            t.ReversesTransactionId,
            t.ReversedBy != null,
            t.Bucket != null ? (int?)t.Bucket.RemainingPoints : null,
            t.Bucket != null ? (DateOnly?)t.Bucket.ExpiresDate : null,
            t.CreatedDate,
            t.CreatedBy);

        public Task<GoldenPointsUserRow?> GetUserAsync(string email) =>
            _context.Set<User>()
                .AsNoTracking()
                .Where(u => u.CorportativeEmail == email)
                .Select(u => new GoldenPointsUserRow(u.Id, u.DisplayName, u.CorportativeEmail))
                .FirstOrDefaultAsync();

        public async Task<GoldenPointsTransactionPage> GetTransactionsPageAsync(
            int? userId, GoldenPointsTransactionType? type, GoldenPointsSource? source, int page, int pageSize)
        {
            var query = _dbSet.AsNoTracking();

            if (userId is { } id)
            {
                query = query.Where(t => t.UserId == id);
            }

            if (type is { } typeFilter)
            {
                query = query.Where(t => t.Type == typeFilter);
            }

            if (source is { } sourceFilter)
            {
                query = query.Where(t => t.Source == sourceFilter);
            }

            var total = await query.CountAsync();

            var rows = await query
                .OrderByDescending(t => t.CreatedDate)
                .ThenByDescending(t => t.Id)
                .Skip((page - 1) * pageSize)
                .Take(pageSize)
                .Select(ToRow)
                .ToListAsync();

            return new GoldenPointsTransactionPage(rows, total);
        }

        public Task<GoldenPointsTransactionRow?> GetTransactionAsync(int transactionId) =>
            _dbSet.AsNoTracking()
                .Where(t => t.Id == transactionId)
                .Select(ToRow)
                .FirstOrDefaultAsync();

        public async Task<GoldenPointsSummaryRow> GetSummaryAsync(int userId, DateOnly today, DateOnly expiringUntil)
        {
            var balance = await _context.Set<GoldenPointsAccount>()
                .AsNoTracking()
                .Where(a => a.UserId == userId)
                .Select(a => (int?)a.Balance)
                .FirstOrDefaultAsync() ?? 0;

            var movements = _dbSet.AsNoTracking().Where(t => t.UserId == userId);

            // Ganado = abonos menos reversos (los ajustes son negativos).
            var earned = await movements
                .Where(t => t.Type == GoldenPointsTransactionType.Credit || t.Type == GoldenPointsTransactionType.Adjustment)
                .SumAsync(t => (int?)t.Points) ?? 0;

            var spent = await movements
                .Where(t => t.Type == GoldenPointsTransactionType.Debit)
                .SumAsync(t => (int?)-t.Points) ?? 0;

            var expired = await movements
                .Where(t => t.Type == GoldenPointsTransactionType.Expiration)
                .SumAsync(t => (int?)-t.Points) ?? 0;

            var activeBuckets = _context.Set<GoldenPointsBucket>()
                .AsNoTracking()
                .Where(b => b.UserId == userId && b.RemainingPoints > 0 && b.ExpiresDate >= today);

            var expiringSoon = await activeBuckets
                .Where(b => b.ExpiresDate <= expiringUntil)
                .SumAsync(b => (int?)b.RemainingPoints) ?? 0;

            var nextExpiration = await activeBuckets.MinAsync(b => (DateOnly?)b.ExpiresDate);

            return new GoldenPointsSummaryRow(balance, earned, spent, expired, expiringSoon, nextExpiration);
        }

        public async Task<IReadOnlyList<GoldenPointsBucketRow>> GetUpcomingExpirationsAsync(int userId, DateOnly today, int take) =>
            await _context.Set<GoldenPointsBucket>()
                .AsNoTracking()
                .Where(b => b.UserId == userId && b.RemainingPoints > 0 && b.ExpiresDate >= today)
                .OrderBy(b => b.ExpiresDate)
                .ThenBy(b => b.Id)
                .Take(take)
                .Select(b => new GoldenPointsBucketRow(
                    b.Id,
                    b.Transaction.User.CorportativeEmail,
                    b.Transaction.Source,
                    b.Transaction.Recognition != null ? b.Transaction.Recognition.Category.Name : null,
                    b.OriginalPoints,
                    b.RemainingPoints,
                    b.CreatedDate,
                    b.ExpiresDate))
                .ToListAsync();
    }
}
```

### Registro — `InfrastructureServiceRegistration.cs` ✏️

Bajo `//Repositorios de consulta`:

```csharp
services.AddScoped<IGoldenPointsQueryRepository, GoldenPointsQueryRepository>();
```

---

## 8. Paso 5 — Mapeo y servicio

### `Helpers/GoldenPointsMapper.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenPointsMapper
    {
        /// <param name="forAdmin">true agrega nombre, quién lo hizo y si se puede reversar.</param>
        public static GoldenPointsTransactionDto ToDto(GoldenPointsTransactionRow row, bool forAdmin) => new()
        {
            Id = row.Id,
            UserEmail = row.UserEmail,
            UserName = forAdmin ? row.UserName : null,
            Type = GoldenPointsCodes.ToTypeCode(row.Type),
            Source = GoldenPointsCodes.ToSourceCode(row.Source),
            SourceLabel = SourceLabel(row.Source, row.RecognitionCategory, row.ReversesTransactionId is not null),
            Concept = row.Concept,
            Points = row.Points,
            BalanceAfter = row.BalanceAfter,
            RecognitionId = row.RecognitionId,
            ExpiresAt = row.ExpiresDate,
            RemainingPoints = row.RemainingPoints,
            IsReversed = row.IsReversed,
            CanReverse = forAdmin
                && row.Type == GoldenPointsTransactionType.Credit
                && row.Source == GoldenPointsSource.Manual
                && !row.IsReversed
                && row.RemainingPoints == row.Points,
            CreatedAt = row.CreatedDate,
            CreatedBy = forAdmin ? row.CreatedBy : null,
        };

        public static GoldenPointsSummaryDto ToSummary(
            GoldenPointsUserRow user, GoldenPointsSummaryRow summary, IEnumerable<GoldenPointsBucketRow> upcoming) => new()
        {
            UserEmail = user.Email,
            UserName = user.Name,
            Balance = summary.Balance,
            TotalEarned = summary.TotalEarned,
            TotalSpent = summary.TotalSpent,
            TotalExpired = summary.TotalExpired,
            ExpiringSoonPoints = summary.ExpiringSoonPoints,
            ExpiringSoonDays = GoldenPointsConstants.ExpiringSoonDays,
            NextExpirationDate = summary.NextExpirationDate,
            UpcomingExpirations = upcoming.Select(bucket => new GoldenPointsBucketDto
            {
                Id = bucket.Id,
                UserEmail = bucket.UserEmail,
                Source = SourceLabel(bucket.Source, bucket.RecognitionCategory, isReversal: false),
                OriginalPoints = bucket.OriginalPoints,
                RemainingPoints = bucket.RemainingPoints,
                AssignedAt = bucket.AssignedDate,
                ExpiresAt = bucket.ExpiresDate,
            }).ToList(),
        };

        private static string SourceLabel(GoldenPointsSource source, string? recognitionCategory, bool isReversal)
        {
            if (isReversal)
            {
                return "Reverso de asignación";
            }

            return source switch
            {
                GoldenPointsSource.Manual => "Asignación de puntos",
                GoldenPointsSource.Recognition => recognitionCategory is null ? "Reconocimiento" : $"Reconocimiento · {recognitionCategory}",
                GoldenPointsSource.Redemption => "Redención",
                GoldenPointsSource.Expiration => "Vencimiento",
                _ => "Movimiento",
            };
        }
    }
}
```

### `Interfaces/IGoldenPointsService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;     // ResponseDto<T>
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenPointsService
    {
        // Colaborador (el usuario sale del token)
        Task<ResponseDto<GoldenPointsSummaryDto>> GetMySummaryAsync(string currentUserEmail);
        Task<ResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>> GetMyTransactionsAsync(GoldenPointsTransactionQueryDto query, string currentUserEmail);

        // Administración
        Task<ResponseDto<GoldenPointsSummaryDto>> GetUserSummaryAsync(string? userEmail);
        Task<ResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>> GetTransactionsAsync(GoldenPointsTransactionQueryDto query);
        Task<ResponseDto<GoldenPointsTransactionDto>> AssignAsync(AssignGoldenPointsDto dto, string currentUserEmail);
        Task<ResponseDto<GoldenPointsTransactionDto>> ReverseAsync(int transactionId, ReverseGoldenPointsDto dto, string currentUserEmail);
    }
}
```

### `Services/GoldenPointsService.cs`

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
using Microsoft.EntityFrameworkCore; // DbUpdateException

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenPointsService(
        ITransactionExecutorHelper transactionHelper,
        IGoldenPointsQueryRepository queryRepository) : IGoldenPointsService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly IGoldenPointsQueryRepository _queryRepository = queryRepository;

        // ── Colaborador ─────────────────────────────────────────────────

        public Task<ResponseDto<GoldenPointsSummaryDto>> GetMySummaryAsync(string currentUserEmail) =>
            BuildSummaryAsync(currentUserEmail, GoldenPointsConstants.UserNotRegistered);

        public async Task<ResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>> GetMyTransactionsAsync(
            GoldenPointsTransactionQueryDto query, string currentUserEmail)
        {
            var user = await _queryRepository.GetUserAsync(currentUserEmail);
            if (user is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>(GoldenPointsConstants.UserNotRegistered);
            }

            // query.Email se ignora: cada persona solo ve lo suyo.
            return await PageAsync(user.Id, query, forAdmin: false);
        }

        // ── Administración ──────────────────────────────────────────────

        public Task<ResponseDto<GoldenPointsSummaryDto>> GetUserSummaryAsync(string? userEmail)
        {
            var email = userEmail?.Trim().ToLowerInvariant();
            if (string.IsNullOrEmpty(email))
            {
                return Task.FromResult(ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsSummaryDto>(GoldenPointsConstants.UserEmailRequired));
            }

            return BuildSummaryAsync(email, GoldenPointsConstants.UserNotFound);
        }

        public async Task<ResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>> GetTransactionsAsync(GoldenPointsTransactionQueryDto query)
        {
            int? userId = null;
            var email = query.Email?.Trim().ToLowerInvariant();

            if (!string.IsNullOrEmpty(email))
            {
                var user = await _queryRepository.GetUserAsync(email);
                if (user is null)
                {
                    return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>(GoldenPointsConstants.UserNotFound);
                }

                userId = user.Id;
            }

            return await PageAsync(userId, query, forAdmin: true);
        }

        public async Task<ResponseDto<GoldenPointsTransactionDto>> AssignAsync(AssignGoldenPointsDto dto, string currentUserEmail)
        {
            var errors = new List<string>();
            var draft = GoldenPointsValidator.NormalizeAssignment(dto, GoldenClock.Today(), errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(errors);
            }

            for (var attempt = 1; attempt <= GoldenPointsConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenPointsTransaction? created = null;
                    var alreadyProcessedId = 0;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenPointsTransactionDto>>(
                        async unitOfWork =>
                        {
                            // Idempotencia: si este envío ya se procesó (doble clic, reintento de red), no se abona otra vez.
                            alreadyProcessedId = (await unitOfWork.Repository<GoldenPointsTransaction>()
                                .GetListAsync(t => t.RequestId == draft.RequestId))
                                .Select(t => t.Id)
                                .FirstOrDefault();

                            if (alreadyProcessedId > 0)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPointsTransactionDto());
                            }

                            var user = (await unitOfWork.Repository<User>().GetListAsync(u => u.CorportativeEmail == draft.UserEmail)).FirstOrDefault();
                            if (user is null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.UserNotFound);
                            }

                            if (string.Equals(user.CorportativeEmail, currentUserEmail, StringComparison.OrdinalIgnoreCase))
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.CannotAssignToYourself);
                            }

                            created = await GoldenPointsLedger.CreditAsync(unitOfWork, new GoldenPointsCredit(
                                user.Id,
                                draft.Points,
                                GoldenPointsSource.Manual,
                                draft.Concept,
                                draft.ExpiresDate,
                                currentUserEmail,
                                RequestId: draft.RequestId));

                            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPointsTransactionDto()); // provisional: aún no hay Id
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.UnexpectedError);

                    if (response.HasError)
                    {
                        return response;
                    }

                    // El helper ya guardó: se lee con nombres, lote y saldo final.
                    var id = alreadyProcessedId > 0 ? alreadyProcessedId : created?.Id ?? 0;
                    return await ReadTransactionAsync(id);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Otro movimiento cambió la cuenta al mismo tiempo (row_version) o el mismo requestId llegó dos veces
                    // (índice único). El siguiente intento lee el saldo nuevo o encuentra la solicitud ya guardada.
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.ConcurrentChange);
        }

        public async Task<ResponseDto<GoldenPointsTransactionDto>> ReverseAsync(int transactionId, ReverseGoldenPointsDto dto, string currentUserEmail)
        {
            var errors = new List<string>();
            var reason = GoldenPointsValidator.NormalizeReason(dto.Reason, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(errors);
            }

            for (var attempt = 1; attempt <= GoldenPointsConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenPointsTransaction? reversal = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenPointsTransactionDto>>(
                        async unitOfWork =>
                        {
                            var (created, error) = await GoldenPointsLedger.ReverseAsync(unitOfWork, transactionId, reason, currentUserEmail);
                            if (error is not null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(error);
                            }

                            reversal = created;
                            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPointsTransactionDto());
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.UnexpectedError);

                    if (response.HasError)
                    {
                        return response;
                    }

                    return await ReadTransactionAsync(reversal?.Id ?? 0);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Cambio simultáneo en la cuenta, o dos reversos a la vez (índice único): el siguiente intento
                    // lee el estado nuevo y responde "ya fue reversada" si corresponde.
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.ConcurrentChange);
        }

        // ── Privados ────────────────────────────────────────────────────

        private async Task<ResponseDto<GoldenPointsSummaryDto>> BuildSummaryAsync(string email, string notFoundMessage)
        {
            var user = await _queryRepository.GetUserAsync(email);
            if (user is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsSummaryDto>(notFoundMessage);
            }

            var today = GoldenClock.Today();
            var summary = await _queryRepository.GetSummaryAsync(user.Id, today, today.AddDays(GoldenPointsConstants.ExpiringSoonDays));
            var upcoming = await _queryRepository.GetUpcomingExpirationsAsync(user.Id, today, GoldenPointsConstants.UpcomingExpirationsTake);

            return ResponseDtoHelper.CreateSuccessResponseDto(GoldenPointsMapper.ToSummary(user, summary, upcoming));
        }

        private async Task<ResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>> PageAsync(
            int? userId, GoldenPointsTransactionQueryDto query, bool forAdmin)
        {
            if (!GoldenPointsCodes.TryParseType(query.Type, out var type))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>(GoldenPointsConstants.InvalidTypeFilter);
            }

            if (!GoldenPointsCodes.TryParseSource(query.Source, out var source))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenPointsTransactionDto>>(GoldenPointsConstants.InvalidSourceFilter);
            }

            var (page, pageSize) = GoldenPointsValidator.Paging(query);
            var result = await _queryRepository.GetTransactionsPageAsync(userId, type, source, page, pageSize);

            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPagedResultDto<GoldenPointsTransactionDto>
            {
                Items = result.Rows.Select(row => GoldenPointsMapper.ToDto(row, forAdmin)).ToList(),
                Page = page,
                PageSize = pageSize,
                TotalCount = result.TotalCount,
            });
        }

        private async Task<ResponseDto<GoldenPointsTransactionDto>> ReadTransactionAsync(int transactionId)
        {
            var row = await _queryRepository.GetTransactionAsync(transactionId);
            return row is null
                ? ResponseDtoHelper.CreateErrorResponseDto<GoldenPointsTransactionDto>(GoldenPointsConstants.UnexpectedError)
                : ResponseDtoHelper.CreateSuccessResponseDto(GoldenPointsMapper.ToDto(row, forAdmin: true));
        }
    }
}
```

**Notas del servicio**

- **El `Id` después de guardar.** Dentro de la lambda el movimiento todavía no tiene `Id`: la respuesta real se arma afuera, leyendo con el repositorio de consultas (convención del proyecto).
- **Reintentos.** Cada llamada a `ExecuteWithTransactionAsync` abre su propio `DbContext`, así que cada intento vuelve a leer el saldo y el `requestId`. El reintento por `DbUpdateException` también cubre el caso raro de dos primeros abonos a una cuenta que aún no existe (choque de llave primaria).
- **`UserNotRegistered`.** Si `RequestService` filtra además por usuario activo, aplica el mismo filtro en `GetUserAsync`.

---

## 9. Paso 6 — Controlador

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenPointsErrorMessage = "No se pudo completar la operación con los puntos.";
```

### `Controllers/GoldenPointsController.cs`

Cada acción con su `try/catch` completo (regla 18 de las convenciones).

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: saldo, historial y asignación de puntos.</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class GoldenPointsController(IGoldenPointsService service) : ControllerBase
    {
        private readonly IGoldenPointsService _service = service;

        /// <summary>"Mis puntos": saldo, totales y próximos vencimientos del usuario autenticado.</summary>
        [HttpGet("me/summary")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetMySummary()
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetMySummaryAsync(authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenPointsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenPointsErrorMessage });
            }
        }

        /// <summary>"Mis puntos": historial del usuario autenticado. GET me/transactions?page=1&amp;pageSize=10&amp;type=&amp;source=</summary>
        [HttpGet("me/transactions")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetMyTransactions([FromQuery] GoldenPointsTransactionQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetMyTransactionsAsync(query, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenPointsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenPointsErrorMessage });
            }
        }

        /// <summary>Administración: saldo de una persona. GET summary?email=</summary>
        // ⬇ Permiso de administración de Puntos Dorados
        [HttpGet("summary")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetUserSummary([FromQuery] string? email)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetUserSummaryAsync(email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenPointsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenPointsErrorMessage });
            }
        }

        /// <summary>Administración: movimientos de todos o de una persona. GET transactions?email=&amp;type=&amp;source=&amp;page=</summary>
        // ⬇ Permiso de administración de Puntos Dorados
        [HttpGet("transactions")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetTransactions([FromQuery] GoldenPointsTransactionQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetTransactionsAsync(query);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenPointsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenPointsErrorMessage });
            }
        }

        /// <summary>Administración: asignar puntos sin reconocimiento.</summary>
        // ⬇ Permiso de administración de Puntos Dorados
        [HttpPost("assignments")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Assign([FromBody] AssignGoldenPointsDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.AssignAsync(dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenPointsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenPointsErrorMessage });
            }
        }

        /// <summary>Administración: reversar una asignación manual no usada.</summary>
        // ⬇ Permiso de administración de Puntos Dorados
        [HttpPost("transactions/{id:int}/reverse")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Reverse(int id, [FromBody] ReverseGoldenPointsDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.ReverseAsync(id, dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenPointsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenPointsErrorMessage });
            }
        }
    }
}
```

> **Permiso de administración.** `summary`, `transactions`, `assignments` y `reverse` son de Compensación y Beneficios: agrega en esas cuatro acciones el atributo o la política que usan tus otros controladores de administración. `me/summary` y `me/transactions` son para cualquier usuario autenticado.

### Registro — `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IGoldenPointsService, GoldenPointsService>();
```

---

## 10. Lo que sigue (y cómo encaja)

### Aprobación de un reconocimiento con puntos (parte 2 de reconocimientos)

Dentro del **mismo** `ExecuteWithTransactionAsync` que aprueba:

```csharp
recognition.Status = GoldenRecognitionStatus.Approved;
recognition.PointsAssigned = points;          // queda como dato del reconocimiento
recognition.ReviewedDate = DateTime.UtcNow;
recognition.ReviewedBy = reviewerEmail;

if (points is > 0)
{
    // El saldo SIEMPRE sale del libro, no de points_assigned.
    await GoldenPointsLedger.CreditAsync(unitOfWork, new GoldenPointsCredit(
        recognition.NomineeUserId,
        points.Value,
        GoldenPointsSource.Recognition,
        $"Reconocimiento aprobado: {category.Name}",
        GoldenClock.Today().AddMonths(GoldenPointsConstants.DefaultExpirationMonths),
        reviewerEmail,
        RecognitionId: recognition.Id));
}
```

- **Abona una sola vez:** si alguien aprueba dos veces, el índice `ux_golden_points_transaction_recognition_credit` lo impide.
- **"Vencimiento de puntos" en "Mis reconocimientos":** la consulta de recibidos puede leer `ExpiresDate` del lote cuyo movimiento tiene ese `recognition_id`.

### Redención (gastar puntos)

`GoldenPointsLedger.DebitAsync(unitOfWork, userId, points, concept, redemptionId, createdBy)`, en la misma transacción que crea la redención y descuenta el stock del producto:

1. Lee la cuenta con seguimiento; si `Balance < points`, responde "saldo insuficiente".
2. Consume los lotes con saldo y no vencidos, **del que vence primero** (`ORDER BY expires_date, id`), restando `remaining_points`.
3. `account.Balance -= points` y un movimiento `DEBIT` con `-points`, origen `REDEMPTION`.
4. `row_version` protege de dos redenciones simultáneas: la segunda falla, reintenta y ve el saldo nuevo.

### Vencimiento de puntos

Un `BackgroundService` (o un job de SQL Agent que llame a un endpoint interno) una vez al día:

- Por cada lote con `remaining_points > 0` y `expires_date < hoy`, en una transacción por persona: un movimiento `EXPIRATION` con `-remaining`, `remaining_points = 0` y `account.Balance -= remaining`.
- Avisos opcionales "tus puntos vencen en 30 días" con el log de correos.

### Carga masiva (Excel por cédula)

Cada fila es un `CreditAsync` con origen `MANUAL`, todas en una transacción o por lotes. `GetOrCreateAccountAsync` ya contempla varias filas de la misma persona en la misma transacción.

---

## 11. Contrato (para el frontend)

Base `/api/GoldenPoints`. Todas las respuestas: `{ response, hasError, errors }`. Errores de negocio con HTTP 200 y `hasError: true`; `401` sin usuario.

| Método | Ruta | Quién | Cuerpo / query | `response` |
|---|---|---|---|---|
| `GET` | `/me/summary` | Colaborador | — | `GoldenPointsSummaryDto` |
| `GET` | `/me/transactions` | Colaborador | `?page=1&pageSize=10&type=&source=` | Página de `GoldenPointsTransactionDto` |
| `GET` | `/summary` | Admin | `?email=persona@empresa.com` | `GoldenPointsSummaryDto` de esa persona |
| `GET` | `/transactions` | Admin | `?email=&type=&source=Asignacion&page=` | Página con `userName`, `createdBy`, `canReverse` |
| `POST` | `/assignments` | Admin | `{ userEmail, points, concept, expiresDate?, requestId }` | El movimiento creado (con `balanceAfter`) |
| `POST` | `/transactions/{id}/reverse` | Admin | `{ reason }` | El movimiento de reverso |

Asignar:

```json
POST /api/GoldenPoints/assignments
{
  "userEmail": "laura.salazar@empresa.com",
  "points": 200,
  "concept": "Bono por cierre del proyecto de temporada",
  "expiresDate": null,
  "requestId": "6f1d0a52-6a1e-4c1e-9a54-0d5c7b2e9f11"
}
```

```json
{
  "response": {
    "id": 18,
    "userEmail": "laura.salazar@empresa.com",
    "userName": "Laura Salazar",
    "type": "Credito",
    "source": "Asignacion",
    "sourceLabel": "Asignación de puntos",
    "concept": "Bono por cierre del proyecto de temporada",
    "points": 200,
    "balanceAfter": 350,
    "recognitionId": null,
    "expiresAt": "2027-04-07",
    "remainingPoints": 200,
    "isReversed": false,
    "canReverse": true,
    "createdAt": "2026-10-07T15:20:00",
    "createdBy": "admin@empresa.com"
  },
  "hasError": false,
  "errors": []
}
```

Resumen de "Mis puntos":

```json
{
  "response": {
    "userEmail": "laura.salazar@empresa.com",
    "userName": "Laura Salazar",
    "balance": 350,
    "totalEarned": 350,
    "totalSpent": 0,
    "totalExpired": 0,
    "expiringSoonPoints": 0,
    "expiringSoonDays": 30,
    "nextExpirationDate": "2027-04-07",
    "upcomingExpirations": [
      { "id": 9, "userEmail": "laura.salazar@empresa.com", "source": "Reconocimiento · Servicio", "originalPoints": 150, "remainingPoints": 150, "assignedAt": "2026-10-01T13:00:00", "expiresAt": "2027-04-01" },
      { "id": 12, "userEmail": "laura.salazar@empresa.com", "source": "Asignación de puntos", "originalPoints": 200, "remainingPoints": 200, "assignedAt": "2026-10-07T15:20:00", "expiresAt": "2027-04-07" }
    ]
  },
  "hasError": false,
  "errors": []
}
```

**Encaja con tu modelo actual** (`puntos-dorados.ts`):

| Frontend | API |
|---|---|
| `GoldenPointsTransaction` (`id, userEmail, type, points, concept, createdAt`) | Cada ítem de `/me/transactions` (con campos extra: `sourceLabel`, `balanceAfter`, `expiresAt`…) |
| `GoldenPointsBucket` (`id, userEmail, source, originalPoints, remainingPoints, assignedAt, expiresAt`) | `summary.upcomingExpirations` |
| `getTransactions(email)` | `GET /me/transactions` (sin correo: sale del token) |
| `getPointsBuckets(email)` / `getExpiringPoints(email)` | `GET /me/summary` → `upcomingExpirations` |

**Reglas para las pantallas:**

- **Admin "Asignar puntos":** genera `requestId = crypto.randomUUID()` al abrir el formulario y **reutilízalo** si el usuario vuelve a intentar con los mismos datos. Genera uno nuevo después de un éxito.
- **Fechas:** `createdAt` y `assignedAt` llegan en UTC sin `Z` (agregarla en el mapper). `expiresAt` y `nextExpirationDate` son fechas sin hora (`yyyy-MM-dd`): no convertirlas a UTC.
- **Puntos con signo:** mostrar `+200` en verde y `−100` en rojo. Un movimiento con `isReversed: true` se muestra tachado o con la etiqueta "Reversado".

---

## 12. Pruebas

**Asignar**
- Asignar 200 a una persona sin cuenta → se crea la cuenta; `balanceAfter: 200`; lote con 200 que vence en 6 meses.
- Asignar otros 150 → `balanceAfter: 350`.
- Mismo `requestId` dos veces seguidas → la segunda responde **el mismo movimiento** y el saldo sigue en 350.
- Dos pestañas asignando a la misma persona al mismo tiempo (requestIds distintos) → los dos quedan, con `balanceAfter` consecutivos (350 → 550 → 750, sin repetir).
- Asignarse a sí mismo → `hasError`.
- `points: 0`, `150000`, concepto de 3 letras o `expiresDate` de ayer → `hasError`.
- Persona que no está en `dbo.users` → `hasError`.

**Reversar**
- Reversar una asignación → `Ajuste −200`, saldo baja 200, el original queda con `isReversed: true` y `canReverse: false`.
- Reversar otra vez → "ya fue reversada".
- Reversar un movimiento que no es manual (de reconocimiento, cuando exista) → `hasError`.

**Mis puntos**
- `/me/summary` con 350 → `balance: 350`, próximos vencimientos ordenados por fecha.
- `/me/transactions` → lo más reciente primero, sin `createdBy` ni `userName`.
- Una persona nunca ve los movimientos de otra.
- El feed **no** muestra asignaciones de puntos.

**Base de datos**
- `UPDATE dbo.golden_points_transaction SET points = 1 WHERE id = 1` → lo rechaza el trigger.
- Las tres consultas de control de la sección 4 → cero filas.

---

## ✅ Checklist

- [ ] `GoldenPointsLedger.sql` ejecutado (después de los reconocimientos).
- [ ] Entidades sin `BaseEntity`; `RowVersion` con `IsRowVersion()`; `HasTrigger` en la configuración del libro.
- [ ] Tres `DbSet` en `DOCCbDbContext`.
- [ ] `IGoldenPointsQueryRepository` registrado bajo `//Repositorios de consulta`; `IGoldenPointsService` en `ApplicationServiceRegistration.cs`.
- [ ] Ningún otro código cambia `golden_points_account` ni `golden_points_bucket`: todo pasa por `GoldenPointsLedger`.
- [ ] Controlador con `try/catch` completo en cada acción y permiso de administración en las cuatro acciones de administración.
- [ ] Confirmado con el negocio: vencimiento de 6 meses y máximo de 100.000 puntos por asignación.
- [ ] Consultas de control programadas como alerta.
- [ ] Probado el doble envío (`requestId`) y la asignación simultánea.
