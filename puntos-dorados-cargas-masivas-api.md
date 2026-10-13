# 📥 Puntos Dorados — API de cargas masivas: reconocimientos y puntos

API para dos cargas desde Excel en administración:

| Pestaña | Sección | Endpoint |
|---|---|---|
| **Reconocimientos masivos** (ya existe en el frontend) | Crear reconocimientos | `POST /api/GoldenBulkLoads/recognitions?dryRun=true\|false` |
| **Puntos masivos** (nueva, sección 9) | Asignar puntos | `POST /api/GoldenBulkLoads/points?dryRun=true\|false` |

El frontend ya está hecho (`golden-bulk-excel.ts`, `GoldenBulkLoadsService`, `app-golden-bulk-load`). Esta guía construye la API con **los mismos nombres** que envía y espera.

- **Navegador:** lee el Excel y envía las filas en JSON.
- **API, primero:** revisa sin guardar (`dryRun=true`).
- **API, al procesar:** aplica todo en una transacción (`dryRun=false`).

> **"Aprobar pendientes"** (la otra sección de la misma pestaña) usa `POST approvals` y `GET pending-recognitions`. Están en [puntos-dorados-editar-masivos-dashboard.md](puntos-dorados-editar-masivos-dashboard.md), sección 2.6. Van en **este mismo servicio y controlador**:
> - **Métodos:** `ProcessApprovalsAsync` y `GetPendingForTemplateAsync`, con sus tipos privados `BulkDecision`, `ApprovalDraft` y `ParseDecision`.
> - **Constantes:** `RecognitionIdRequired`, `DuplicateRecognitionRow`, `RecognitionNotFound`, `RecognitionNotPending`, `DecisionInvalid`, `ApprovalPointsInvalid` y `CommentTooLong` (sección 2.5 de esa guía).
> - **DTO:** `GoldenBulkApprovalRowDto` y `GoldenBulkPendingRowDto`.
> - **Lo que ya está:** `RowError`, `Summary`, `AlreadyProcessed`, `FindLoadAsync`, `AddLoadAsync` y `WithLoadId` existen aquí con el mismo nombre.

**Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md):
- `ResponseDto` y errores de negocio con HTTP 200.
- `try/catch` completo en cada acción.
- Repositorio genérico.
- Validar todo antes de modificar.
- Reintentos (regla 21).

---

## 1. Lo que envía y espera el frontend

### Petición (las dos cargas)

```json
POST /api/GoldenBulkLoads/recognitions?dryRun=true
{
  "requestId": "3f0b8c2e-…",
  "fileName": "plantilla-reconocimientos-2026-10-14.xlsx",
  "rows": [
    { "rowNumber": 2, "identification": "1020304050", "email": null, "category": "Servicio", "reason": "Apoyó una contingencia crítica fuera de su horario." }
  ]
}
```

```json
POST /api/GoldenBulkLoads/points?dryRun=true
{
  "requestId": "9a1d…",
  "fileName": "plantilla-puntos-2026-10-14.xlsx",
  "rows": [
    { "rowNumber": 2, "identification": null, "email": "laura.salazar@empresa.com", "points": 200, "concept": "Bono por cierre del proyecto", "expiresDate": null }
  ]
}
```

- `rowNumber`: la fila del Excel (la 1 son los encabezados), para los mensajes de error.
- `identification` / `email`: cédula o correo; al menos uno.
- `expiresDate`: `yyyy-MM-dd` o `null` (vence a los 12 meses).

### Respuesta (`response`)

```json
{
  "dryRun": true,
  "alreadyProcessed": false,
  "loadId": null,
  "totalRows": 3,
  "validRows": 2,
  "processedRows": 0,
  "skippedRows": 0,
  "totalPoints": 350,
  "errors": [
    { "rowNumber": 4, "message": "No existe una persona registrada con esa cédula o correo." }
  ]
}
```

| Caso | `hasError` | Qué trae |
|---|---|---|
| Revisión sin errores | `false` | `validRows` = filas; "Procesar" se habilita. |
| Revisión con errores de filas | `false` | `errors` con su `rowNumber`; "Procesar" queda deshabilitado. |
| Procesado | `false` | `processedRows` y `loadId`. |
| El mismo `requestId` otra vez | `false` | `alreadyProcessed: true` y el `loadId` de la carga que ya existía. |
| Error del archivo completo (sin filas, más de 1.000, sin `requestId`) | `true` | `errors` del `ResponseDto`. |

---

## 2. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Revisar antes de aplicar.** | La misma acción con `dryRun=true` valida todo contra la base de datos **sin guardar**. El componente revisa al elegir el archivo y solo deja procesar si no hay errores. |
| 2 | **Todo o nada.** | Al procesar se vuelve a validar todo. Si una fila falla (algo cambió entre la revisión y el clic), **no se aplica ninguna**: nunca queda una carga a medias. |
| 3 | **Doble clic o reintento.** | `golden_bulk_load.request_id` tiene índice único. Si el mismo envío llega dos veces, la segunda responde `alreadyProcessed` y no abona otra vez. |
| 4 | **Trazabilidad.** | Cada carga queda registrada (tipo, archivo, filas, quién y cuándo). Los movimientos de puntos y los reconocimientos que crea guardan `bulk_load_id`. |
| 5 | **Personas.** | Por cédula o por correo, resueltas con **una sola consulta** para todo el archivo. Si vienen las dos y son de personas distintas, la fila da error, porque es la señal típica de una equivocación. A la cédula se le quitan puntos y espacios. |
| 6 | **Reconocimientos masivos.** | Quedan **Pendientes**, como dice la pantalla. La plantilla no tiene puntos ni estado: los puntos se asignan al aprobar. Quien reconoce es quien sube el archivo, y por eso no puede reconocerse a sí mismo. Se valida que la categoría esté activa, el motivo tenga de 15 a 1.000 caracteres y no exista otro pendiente igual (en la base de datos ni repetido en el archivo). |
| 7 | **Puntos masivos.** | Son las mismas reglas de la asignación manual: 1 a 100.000 puntos, concepto de 5 a 300 caracteres, vencimiento opcional (máximo 24 meses, por defecto 12) y no asignarse a sí mismo. Cada fila es un abono del libro (`GoldenPointsLedger.CreditAsync`) con origen "Asignación". |
| 8 | **Límite.** | 1.000 filas por archivo. El componente ya lo revisa antes de llamar a la API; la API lo vuelve a validar. |
| 9 | **¿Repositorio propio?** | No. Son filtros con `Contains` (personas, categorías) y altas: el repositorio genérico alcanza. |
| 10 | **Permisos.** | Comentados, igual que el resto de administración. |

> ⚠️ **Al activar los permisos.** La regla recomendada "nadie aprueba un reconocimiento que creó" hace que quien suba la carga de reconocimientos **no pueda aprobarlos** después: tendrá que hacerlo otra persona. Si se quiere que la misma persona los apruebe, esa regla no debe aplicarse a los reconocimientos con `bulk_load_id`.

---

## 3. Paso 1 — Base de datos: `Persistence/Scripts SQL/GoldenBulkLoads.sql`

```sql
/* =====================================================================
   Puntos Dorados — cargas masivas
   Base de datos: DB · Esquema: dbo
   Requiere: GoldenPointsRecognitions.sql y GoldenPointsLedger.sql
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.golden_bulk_load', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_bulk_load
    (
        id           INT              IDENTITY(1, 1) NOT NULL,
        load_type    VARCHAR(20)      NOT NULL,      -- POINTS | RECOGNITIONS | APPROVALS
        request_id   UNIQUEIDENTIFIER NOT NULL,      -- un envío = una carga (doble clic)
        file_name    NVARCHAR(260)    NULL,
        total_rows   INT              NOT NULL,
        created_date DATETIME2(0)     NOT NULL CONSTRAINT df_golden_bulk_load_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)    NOT NULL,

        CONSTRAINT pk_golden_bulk_load PRIMARY KEY CLUSTERED (id),
        CONSTRAINT ck_golden_bulk_load_type CHECK (load_type IN ('POINTS', 'RECOGNITIONS', 'APPROVALS')),
        CONSTRAINT ck_golden_bulk_load_rows CHECK (total_rows > 0)
    );

    CREATE UNIQUE INDEX ux_golden_bulk_load_request ON dbo.golden_bulk_load (request_id);
END;
GO

/* Qué movimientos y qué reconocimientos entraron con cada carga. */
IF COL_LENGTH(N'dbo.golden_points_transaction', N'bulk_load_id') IS NULL
    ALTER TABLE dbo.golden_points_transaction
        ADD bulk_load_id INT NULL
            CONSTRAINT fk_golden_points_transaction_bulk_load REFERENCES dbo.golden_bulk_load (id);
GO

IF COL_LENGTH(N'dbo.golden_recognition', N'bulk_load_id') IS NULL
    ALTER TABLE dbo.golden_recognition
        ADD bulk_load_id INT NULL
            CONSTRAINT fk_golden_recognition_bulk_load REFERENCES dbo.golden_bulk_load (id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'ix_golden_points_transaction_bulk_load' AND object_id = OBJECT_ID(N'dbo.golden_points_transaction'))
    CREATE INDEX ix_golden_points_transaction_bulk_load
        ON dbo.golden_points_transaction (bulk_load_id)
        WHERE bulk_load_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'ix_golden_recognition_bulk_load' AND object_id = OBJECT_ID(N'dbo.golden_recognition'))
    CREATE INDEX ix_golden_recognition_bulk_load
        ON dbo.golden_recognition (bulk_load_id)
        WHERE bulk_load_id IS NOT NULL;
GO
```

> El trigger del libro (`tr_golden_points_transaction_immutable`) bloquea `UPDATE` y `DELETE` de filas. Agregar una columna con `ALTER TABLE` no lo dispara.

**Ver qué entró con una carga:**

```sql
SELECT * FROM dbo.golden_bulk_load ORDER BY id DESC;
SELECT * FROM dbo.golden_points_transaction WHERE bulk_load_id = 12;
SELECT * FROM dbo.golden_recognition       WHERE bulk_load_id = 13;
```

---

## 4. Paso 2 — Dominio y EF

### `DOCCB.Domain/Enum/GoldenBulkLoadType.cs`

```csharp
namespace DOCCB.Domain.Enum
{
    public enum GoldenBulkLoadType
    {
        Points = 1,
        Recognitions = 2,
        Approvals = 3,
    }
}
```

### `DOCCB.Domain/Entities/GoldenBulkLoad.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities
{
    /// <summary>Un archivo procesado en una carga masiva.</summary>
    public class GoldenBulkLoad
    {
        public int Id { get; set; }
        public GoldenBulkLoadType LoadType { get; set; }
        public Guid RequestId { get; set; }
        public string? FileName { get; set; }
        public int TotalRows { get; set; }
        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;
    }
}
```

### `GoldenPointsTransaction.cs` y `GoldenRecognition.cs` ✏️ — agrega en las dos

```csharp
/// <summary>La carga masiva que lo creó (null si se creó uno por uno).</summary>
public int? BulkLoadId { get; set; }
public GoldenBulkLoad? BulkLoad { get; set; }
```

### `DOCCB.Infraestructure/Configurations/GoldenBulkLoadConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenBulkLoadConfiguration : IEntityTypeConfiguration<GoldenBulkLoad>
    {
        public void Configure(EntityTypeBuilder<GoldenBulkLoad> builder)
        {
            builder.ToTable("golden_bulk_load", "dbo");

            builder.HasKey(x => x.Id).HasName("pk_golden_bulk_load");

            builder.Property(x => x.Id).HasColumnName("id");
            builder.Property(x => x.RequestId).HasColumnName("request_id");
            builder.Property(x => x.FileName).HasColumnName("file_name").HasMaxLength(260);
            builder.Property(x => x.TotalRows).HasColumnName("total_rows");
            builder.Property(x => x.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(x => x.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();

            // Enum ⇄ código en mayúsculas ('POINTS'), como exige el CHECK del script.
            builder.Property(x => x.LoadType)
                .HasColumnName("load_type")
                .HasMaxLength(20)
                .IsUnicode(false)
                .HasConversion(
                    type => type.ToString().ToUpperInvariant(),
                    code => Enum.Parse<GoldenBulkLoadType>(code, true));

            builder.HasIndex(x => x.RequestId).IsUnique().HasDatabaseName("ux_golden_bulk_load_request");
        }
    }
}
```

### `GoldenPointsTransactionConfiguration.cs` ✏️ — agrega

```csharp
builder.Property(t => t.BulkLoadId).HasColumnName("bulk_load_id");

builder.HasOne(t => t.BulkLoad)
    .WithMany()
    .HasForeignKey(t => t.BulkLoadId)
    .HasConstraintName("fk_golden_points_transaction_bulk_load")
    .OnDelete(DeleteBehavior.Restrict);
```

### `GoldenRecognitionConfiguration.cs` ✏️ — agrega

```csharp
builder.Property(r => r.BulkLoadId).HasColumnName("bulk_load_id");

builder.HasOne(r => r.BulkLoad)
    .WithMany()
    .HasForeignKey(r => r.BulkLoadId)
    .HasConstraintName("fk_golden_recognition_bulk_load")
    .OnDelete(DeleteBehavior.Restrict);
```

### `Persistence/Models/DOCCbDbContext.cs` ✏️

```csharp
public DbSet<GoldenBulkLoad> GoldenBulkLoads { get; set; }
```

### `Helpers/GoldenPointsLedger.cs` ✏️ — el abono puede venir de una carga

En el record `GoldenPointsCredit`, agrega el parámetro opcional al final:

```csharp
public sealed record GoldenPointsCredit(
    int UserId,
    int Points,
    GoldenPointsSource Source,
    string Concept,
    DateOnly ExpiresDate,
    string CreatedBy,
    int? RecognitionId = null,
    Guid? RequestId = null,
    GoldenBulkLoad? BulkLoad = null); // nuevo: la carga masiva que lo originó
```

Y en `CreditAsync`, dentro de `new GoldenPointsTransaction { … }`:

```csharp
// Se enlaza por la entidad: dentro de la lambda la carga todavía tiene Id = 0 y EF pone bulk_load_id al guardar.
BulkLoad = credit.BulkLoad,
```

---

## 5. Paso 3 — Constantes y DTOs

### `Constants/GoldenBulkLoadConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenBulkLoadConstants
    {
        public const int MaxRows = 1_000;
        public const int SaveAttempts = 3;
        public const int FileNameMaxLength = 260;

        // Archivo
        public const string RequestIdRequired = "Falta el identificador de la carga. Vuelve a seleccionar el archivo.";
        public const string NoRows = "El archivo no tiene filas para procesar.";
        public const string TooManyRows = "El archivo admite hasta 1.000 filas. Divídelo en varios.";

        // Personas
        public const string IdentifierRequired = "Escribe la cédula o el correo de la persona.";
        public const string UserNotFound = "No existe una persona registrada con esa cédula o correo.";
        public const string IdentifierMismatch = "La cédula y el correo no son de la misma persona.";
        public const string CannotTargetYourself = "No puedes asignarte puntos ni reconocerte a ti mismo.";

        // Puntos
        public const string PointsInvalid = "Los puntos deben ser un número entero entre 1 y 100.000.";
        public const string ConceptInvalid = "El concepto debe tener entre 5 y 300 caracteres.";
        public const string ExpirationInvalid = "El vencimiento debe ser posterior a hoy y máximo 24 meses después.";

        // Reconocimientos
        public const string CategoryRequired = "Escribe la categoría.";
        public const string CategoryNotFound = "La categoría no existe o está inactiva.";
        public const string ReasonInvalid = "El motivo debe tener entre 15 y 1.000 caracteres.";
        public const string DuplicatePending = "Ya hay un reconocimiento pendiente igual (misma persona y categoría).";
    }
}
```

### `Dtos/GoldenBulkLoadDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>Un archivo ya leído en el navegador.</summary>
    public class GoldenBulkRequestDto<TRow>
    {
        /// <summary>GUID por archivo: el mismo envío dos veces no se procesa dos veces.</summary>
        public Guid RequestId { get; set; }
        public string? FileName { get; set; }
        public List<TRow> Rows { get; set; } = [];
    }

    /// <summary>Una fila de la plantilla de puntos.</summary>
    public class GoldenBulkPointsRowDto
    {
        /// <summary>Fila en el Excel (la 1 son los encabezados).</summary>
        public int RowNumber { get; set; }
        public string? Identification { get; set; }
        public string? Email { get; set; }
        public int Points { get; set; }
        public string? Concept { get; set; }
        /// <summary>Vacío = vence a los 12 meses.</summary>
        public DateOnly? ExpiresDate { get; set; }
    }

    /// <summary>Una fila de la plantilla de reconocimientos (quedan pendientes).</summary>
    public class GoldenBulkRecognitionRowDto
    {
        public int RowNumber { get; set; }
        public string? Identification { get; set; }
        public string? Email { get; set; }
        /// <summary>Nombre de una categoría activa.</summary>
        public string? Category { get; set; }
        public string? Reason { get; set; }
    }

    public class GoldenBulkRowErrorDto
    {
        public int RowNumber { get; set; }
        public string Message { get; set; } = string.Empty;
    }

    public class GoldenBulkResultDto
    {
        /// <summary>true = solo se revisó; no se guardó nada.</summary>
        public bool DryRun { get; set; }
        /// <summary>Este requestId ya se había procesado: no se volvió a aplicar.</summary>
        public bool AlreadyProcessed { get; set; }
        /// <summary>Id de golden_bulk_load cuando se procesó.</summary>
        public int? LoadId { get; set; }
        public int TotalRows { get; set; }
        /// <summary>Filas sin errores.</summary>
        public int ValidRows { get; set; }
        /// <summary>Filas aplicadas (0 si hubo errores o fue revisión).</summary>
        public int ProcessedRows { get; set; }
        /// <summary>Filas que no se tocan (solo en "Aprobar pendientes").</summary>
        public int SkippedRows { get; set; }
        public int TotalPoints { get; set; }
        public List<GoldenBulkRowErrorDto> Errors { get; set; } = [];
    }
}
```

> `DateOnly?` en el JSON: el frontend envía `"2027-04-07"` o `null`, y .NET 8 lo convierte solo.

---

## 6. Paso 4 — Personas por cédula o correo: `Helpers/GoldenBulkUserDirectory.cs`

Aparte del servicio porque lo usan las tres cargas (también "Aprobar pendientes" si en el futuro lleva cédula).

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    /// <summary>Cómo se identifica a una persona en una fila: cédula (solo letras y números) y/o correo (minúsculas).</summary>
    public sealed record GoldenBulkUserKey(string? Document, string? Email)
    {
        public bool IsEmpty => Document is null && Email is null;

        public static GoldenBulkUserKey From(string? document, string? email)
        {
            var cleanDocument = new string((document ?? string.Empty).Where(char.IsLetterOrDigit).ToArray());
            var cleanEmail = email?.Trim().ToLowerInvariant();

            return new GoldenBulkUserKey(
                cleanDocument.Length > 0 ? cleanDocument : null,
                string.IsNullOrEmpty(cleanEmail) ? null : cleanEmail);
        }
    }

    /// <summary>Las personas de todas las filas, leídas con una sola consulta.</summary>
    public sealed class GoldenBulkUserDirectory
    {
        private readonly Dictionary<string, User> _byDocument;
        private readonly Dictionary<string, User> _byEmail;

        private GoldenBulkUserDirectory(IReadOnlyList<User> users)
        {
            _byDocument = users
                .Where(u => !string.IsNullOrEmpty(u.DocumentNumber)) // ⬅ propiedad real de la cédula en User
                .GroupBy(u => u.DocumentNumber!)
                .ToDictionary(g => g.Key, g => g.First());

            _byEmail = users
                .GroupBy(u => u.CorportativeEmail.ToLowerInvariant())
                .ToDictionary(g => g.Key, g => g.First());
        }

        public static async Task<GoldenBulkUserDirectory> LoadAsync(IUnitOfWork unitOfWork, IEnumerable<GoldenBulkUserKey> keys)
        {
            var list = keys.ToList();
            var documents = list.Where(k => k.Document is not null).Select(k => k.Document!).Distinct().ToList();
            var emails = list.Where(k => k.Email is not null).Select(k => k.Email!).Distinct().ToList();

            if (documents.Count == 0 && emails.Count == 0)
            {
                return new GoldenBulkUserDirectory([]);
            }

            // Una sola consulta con IN para toda la carga. Sin seguimiento: solo se leen.
            var users = await unitOfWork.Repository<User>().GetListAsync(u =>
                documents.Contains(u.DocumentNumber!) || emails.Contains(u.CorportativeEmail)); // ⬅ misma propiedad

            return new GoldenBulkUserDirectory(users);
        }

        /// <summary>La cédula manda. Si también viene el correo, deben ser de la misma persona.</summary>
        public (User? User, string? Error) Find(GoldenBulkUserKey key)
        {
            User? byDocument = null;
            if (key.Document is not null && !_byDocument.TryGetValue(key.Document, out byDocument))
            {
                return (null, GoldenBulkLoadConstants.UserNotFound);
            }

            User? byEmail = null;
            if (key.Email is not null && !_byEmail.TryGetValue(key.Email, out byEmail))
            {
                return (null, GoldenBulkLoadConstants.UserNotFound);
            }

            if (byDocument is not null && byEmail is not null && byDocument.Id != byEmail.Id)
            {
                return (null, GoldenBulkLoadConstants.IdentifierMismatch);
            }

            return (byDocument ?? byEmail, null);
        }
    }
}
```

> ⚠️ **La cédula en `User`.** El código usa `u.DocumentNumber` en dos lugares (marcados con ⬅). Cámbialo por la propiedad real de `DOCCB.Domain/Entities/User.cs`.
> - **Si la propiedad no existe** (la cédula está en otra tabla): por ahora las plantillas funcionan con la columna **correo**. Deja `_byDocument` vacío y quita `documents.Contains(...)` de la consulta.
> - **Si la cédula se guarda con puntos o espacios:** la búsqueda no la encuentra, porque aquí se compara solo con números y letras.

---

## 7. Paso 5 — Servicio

### `Interfaces/IGoldenBulkLoadService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenBulkLoadService
    {
        Task<ResponseDto<GoldenBulkResultDto>> ProcessRecognitionsAsync(GoldenBulkRequestDto<GoldenBulkRecognitionRowDto> request, bool dryRun, string currentUserEmail);
        Task<ResponseDto<GoldenBulkResultDto>> ProcessPointsAsync(GoldenBulkRequestDto<GoldenBulkPointsRowDto> request, bool dryRun, string currentUserEmail);
    }
}
```

### `Services/GoldenBulkLoadService.cs`

Los dos métodos siguen los mismos pasos:
1. **Formato de cada fila**, sin base de datos.
2. **En la transacción:** ¿ya se procesó este `requestId`?
3. **Personas** (y categorías) de todas las filas, en pocas consultas.
4. **Si hay errores o es revisión:** se responde **sin modificar nada**.
5. **Si todo está bien:** se registra la carga y se aplican las filas.

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
    public class GoldenBulkLoadService(ITransactionExecutorHelper transactionHelper) : IGoldenBulkLoadService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        // ── Reconocimientos (quedan pendientes) ─────────────────────────

        public async Task<ResponseDto<GoldenBulkResultDto>> ProcessRecognitionsAsync(
            GoldenBulkRequestDto<GoldenBulkRecognitionRowDto> request, bool dryRun, string currentUserEmail)
        {
            var requestError = ValidateRequest(request.RequestId, request.Rows.Count);
            if (requestError is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(requestError);
            }

            // 1. Formato de cada fila.
            var formatErrors = new List<GoldenBulkRowErrorDto>();
            var drafts = new List<RecognitionDraft>();

            foreach (var row in request.Rows)
            {
                var messages = new List<string>();

                var key = GoldenBulkUserKey.From(row.Identification, row.Email);
                if (key.IsEmpty)
                {
                    messages.Add(GoldenBulkLoadConstants.IdentifierRequired);
                }

                var category = row.Category?.Trim() ?? string.Empty;
                if (category.Length == 0)
                {
                    messages.Add(GoldenBulkLoadConstants.CategoryRequired);
                }

                var reason = row.Reason?.Trim() ?? string.Empty;
                if (reason.Length < GoldenRecognitionConstants.ReasonMinLength || reason.Length > GoldenRecognitionConstants.ReasonMaxLength)
                {
                    messages.Add(GoldenBulkLoadConstants.ReasonInvalid);
                }

                if (messages.Count > 0)
                {
                    formatErrors.Add(RowError(row.RowNumber, messages));
                }
                else
                {
                    drafts.Add(new RecognitionDraft(row.RowNumber, key, category, reason));
                }
            }

            for (var attempt = 1; attempt <= GoldenBulkLoadConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenBulkLoad? load = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenBulkResultDto>>(
                        async unitOfWork =>
                        {
                            // 2. Doble envío.
                            var previous = await FindLoadAsync(unitOfWork, request.RequestId);
                            if (previous is not null)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(AlreadyProcessed(previous));
                            }

                            var admin = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                            if (admin is null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UserNotRegistered);
                            }

                            // Permisos (pendiente, guía de aprobaciones, sección 9):
                            // if (!await CanReviewAsync(currentUserEmail))
                            // {
                            //     throw new UnauthorizedAccessException();
                            // }

                            // 3. Personas, categorías activas y pendientes que ya tiene quien sube el archivo.
                            var directory = await GoldenBulkUserDirectory.LoadAsync(unitOfWork, drafts.Select(draft => draft.Key));

                            var names = drafts.Select(draft => draft.CategoryName).Distinct().ToList();
                            var categories = (await unitOfWork.Repository<GoldenRecognitionCategory>()
                                    .GetListAsync(c => c.Active && names.Contains(c.Name)))
                                .GroupBy(c => c.Name, StringComparer.OrdinalIgnoreCase)
                                .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

                            var existingPending = (await unitOfWork.Repository<GoldenRecognition>()
                                    .GetListAsync(r => r.NominatorUserId == admin.Id && r.Status == GoldenRecognitionStatus.Pending))
                                .Select(r => (r.NomineeUserId, r.CategoryId))
                                .ToHashSet();

                            var errors = new List<GoldenBulkRowErrorDto>(formatErrors);
                            var ready = new List<(RecognitionDraft Draft, User Nominee, GoldenRecognitionCategory Category)>();
                            var pendingInFile = new HashSet<(int NomineeUserId, int CategoryId)>();

                            foreach (var draft in drafts)
                            {
                                var (nominee, error) = directory.Find(draft.Key);
                                if (nominee is null)
                                {
                                    errors.Add(RowError(draft.RowNumber, error!));
                                    continue;
                                }

                                if (nominee.Id == admin.Id)
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.CannotTargetYourself));
                                    continue;
                                }

                                if (!categories.TryGetValue(draft.CategoryName, out var category))
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.CategoryNotFound));
                                    continue;
                                }

                                // Anti-spam: ni otro pendiente igual en la base de datos ni repetido en el archivo.
                                var pair = (nominee.Id, category.Id);
                                if (existingPending.Contains(pair) || !pendingInFile.Add(pair))
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.DuplicatePending));
                                    continue;
                                }

                                ready.Add((draft, nominee, category));
                            }

                            var result = Summary(request.Rows.Count, ready.Count, errors, totalPoints: 0, dryRun);

                            // 4. Revisión, o algo falló: no se cambia nada (todo o nada).
                            if (dryRun || errors.Count > 0)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(result);
                            }

                            // 5. Se registra la carga y se crean los reconocimientos.
                            load = await AddLoadAsync(unitOfWork, GoldenBulkLoadType.Recognitions, request, currentUserEmail);
                            var now = DateTime.UtcNow;

                            foreach (var (draft, nominee, category) in ready)
                            {
                                await unitOfWork.Repository<GoldenRecognition>().AddAsync(new GoldenRecognition
                                {
                                    NomineeUserId = nominee.Id,
                                    NominatorUserId = admin.Id,
                                    CategoryId = category.Id,
                                    Reason = draft.Reason,
                                    Status = GoldenRecognitionStatus.Pending,
                                    Visibility = GoldenRecognitionVisibility.Public,
                                    PointsAssigned = null, // los asigna la aprobación
                                    CreatedDate = now,
                                    CreatedBy = currentUserEmail,
                                    BulkLoad = load,
                                });
                            }

                            result.ProcessedRows = ready.Count;
                            return ResponseDtoHelper.CreateSuccessResponseDto(result);
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UnexpectedError);

                    return WithLoadId(response, load);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // El mismo requestId llegó en otra petición (índice único): el siguiente intento responde "ya se procesó".
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UnexpectedError);
        }

        // ── Puntos ──────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenBulkResultDto>> ProcessPointsAsync(
            GoldenBulkRequestDto<GoldenBulkPointsRowDto> request, bool dryRun, string currentUserEmail)
        {
            var requestError = ValidateRequest(request.RequestId, request.Rows.Count);
            if (requestError is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(requestError);
            }

            // 1. Formato de cada fila (las mismas reglas de la asignación manual).
            var today = GoldenClock.Today();
            var formatErrors = new List<GoldenBulkRowErrorDto>();
            var drafts = new List<PointsDraft>();

            foreach (var row in request.Rows)
            {
                var messages = new List<string>();

                var key = GoldenBulkUserKey.From(row.Identification, row.Email);
                if (key.IsEmpty)
                {
                    messages.Add(GoldenBulkLoadConstants.IdentifierRequired);
                }

                if (row.Points < 1 || row.Points > GoldenPointsConstants.MaxPointsPerAssignment)
                {
                    messages.Add(GoldenBulkLoadConstants.PointsInvalid);
                }

                var concept = row.Concept?.Trim() ?? string.Empty;
                if (concept.Length < GoldenPointsConstants.ConceptMinLength || concept.Length > GoldenPointsConstants.ConceptMaxLength)
                {
                    messages.Add(GoldenBulkLoadConstants.ConceptInvalid);
                }

                var expires = row.ExpiresDate ?? today.AddMonths(GoldenPointsConstants.DefaultExpirationMonths);
                if (expires <= today || expires > today.AddMonths(GoldenPointsConstants.MaxExpirationMonths))
                {
                    messages.Add(GoldenBulkLoadConstants.ExpirationInvalid);
                }

                if (messages.Count > 0)
                {
                    formatErrors.Add(RowError(row.RowNumber, messages));
                }
                else
                {
                    drafts.Add(new PointsDraft(row.RowNumber, key, row.Points, concept, expires));
                }
            }

            for (var attempt = 1; attempt <= GoldenBulkLoadConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenBulkLoad? load = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenBulkResultDto>>(
                        async unitOfWork =>
                        {
                            // 2. Doble envío.
                            var previous = await FindLoadAsync(unitOfWork, request.RequestId);
                            if (previous is not null)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(AlreadyProcessed(previous));
                            }

                            var admin = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                            if (admin is null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UserNotRegistered);
                            }

                            // Permisos (pendiente): if (!await CanReviewAsync(currentUserEmail)) throw new UnauthorizedAccessException();

                            // 3. Personas de todas las filas.
                            var directory = await GoldenBulkUserDirectory.LoadAsync(unitOfWork, drafts.Select(draft => draft.Key));
                            var errors = new List<GoldenBulkRowErrorDto>(formatErrors);
                            var ready = new List<(PointsDraft Draft, User User)>();

                            foreach (var draft in drafts)
                            {
                                var (user, error) = directory.Find(draft.Key);
                                if (user is null)
                                {
                                    errors.Add(RowError(draft.RowNumber, error!));
                                }
                                else if (user.Id == admin.Id)
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.CannotTargetYourself));
                                }
                                else
                                {
                                    ready.Add((draft, user));
                                }
                            }

                            var result = Summary(request.Rows.Count, ready.Count, errors, ready.Sum(item => item.Draft.Points), dryRun);

                            // 4. Revisión, o algo falló: no se cambia nada.
                            if (dryRun || errors.Count > 0)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(result);
                            }

                            // 5. Se registra la carga y cada fila es un abono del libro.
                            // Varias filas de la misma persona: GetOrCreateAccountAsync encuentra la cuenta ya agregada (FindAsync).
                            load = await AddLoadAsync(unitOfWork, GoldenBulkLoadType.Points, request, currentUserEmail);

                            foreach (var (draft, user) in ready)
                            {
                                await GoldenPointsLedger.CreditAsync(unitOfWork, new GoldenPointsCredit(
                                    user.Id,
                                    draft.Points,
                                    GoldenPointsSource.Manual,
                                    draft.Concept,
                                    draft.ExpiresDate,
                                    currentUserEmail,
                                    BulkLoad: load));
                            }

                            result.ProcessedRows = ready.Count;
                            return ResponseDtoHelper.CreateSuccessResponseDto(result);
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UnexpectedError);

                    return WithLoadId(response, load);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Saldo cambiado por otro movimiento (row_version de la cuenta) o el mismo requestId en otra petición.
                    // El siguiente intento lee de nuevo; si fue el requestId, responde "ya se procesó".
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenPointsConstants.ConcurrentChange);
        }

        // ── Privados ────────────────────────────────────────────────────

        private sealed record RecognitionDraft(int RowNumber, GoldenBulkUserKey Key, string CategoryName, string Reason);

        private sealed record PointsDraft(int RowNumber, GoldenBulkUserKey Key, int Points, string Concept, DateOnly ExpiresDate);

        private static string? ValidateRequest(Guid requestId, int rowCount)
        {
            if (requestId == Guid.Empty)
            {
                return GoldenBulkLoadConstants.RequestIdRequired;
            }

            if (rowCount == 0)
            {
                return GoldenBulkLoadConstants.NoRows;
            }

            return rowCount > GoldenBulkLoadConstants.MaxRows ? GoldenBulkLoadConstants.TooManyRows : null;
        }

        private static GoldenBulkRowErrorDto RowError(int rowNumber, string message) => new() { RowNumber = rowNumber, Message = message };

        private static GoldenBulkRowErrorDto RowError(int rowNumber, IEnumerable<string> messages) => RowError(rowNumber, string.Join(" ", messages));

        private static GoldenBulkResultDto Summary(int totalRows, int validRows, List<GoldenBulkRowErrorDto> errors, int totalPoints, bool dryRun) => new()
        {
            DryRun = dryRun,
            TotalRows = totalRows,
            ValidRows = validRows,
            TotalPoints = totalPoints,
            Errors = errors.OrderBy(error => error.RowNumber).ToList(),
        };

        /// <summary>El mismo requestId ya se aplicó: se informa la carga existente y no se vuelve a aplicar.</summary>
        private static GoldenBulkResultDto AlreadyProcessed(GoldenBulkLoad load) => new()
        {
            AlreadyProcessed = true,
            LoadId = load.Id,
            TotalRows = load.TotalRows,
        };

        private static Task<GoldenBulkLoad?> FindLoadAsync(IUnitOfWork unitOfWork, Guid requestId) =>
            unitOfWork.Repository<GoldenBulkLoad>().GetAsync(load => load.RequestId == requestId);

        private static async Task<GoldenBulkLoad> AddLoadAsync<TRow>(
            IUnitOfWork unitOfWork, GoldenBulkLoadType type, GoldenBulkRequestDto<TRow> request, string createdBy)
        {
            var fileName = request.FileName?.Trim();

            var load = new GoldenBulkLoad
            {
                LoadType = type,
                RequestId = request.RequestId,
                FileName = string.IsNullOrEmpty(fileName)
                    ? null
                    : fileName[..Math.Min(fileName.Length, GoldenBulkLoadConstants.FileNameMaxLength)],
                TotalRows = request.Rows.Count,
                CreatedDate = DateTime.UtcNow,
                CreatedBy = createdBy,
            };

            await unitOfWork.Repository<GoldenBulkLoad>().AddAsync(load);
            return load;
        }

        /// <summary>El Id de la carga existe recién después de guardar: se pone en la respuesta al salir del helper.</summary>
        private static ResponseDto<GoldenBulkResultDto> WithLoadId(ResponseDto<GoldenBulkResultDto> response, GoldenBulkLoad? load)
        {
            if (!response.HasError && load is not null && response.Response is not null)
            {
                response.Response.LoadId = load.Id;
            }

            return response;
        }

        private static Task<User?> FindUserByEmailAsync(IUnitOfWork unitOfWork, string email) =>
            unitOfWork.Repository<User>().GetAsync(u => u.CorportativeEmail == email);
    }
}
```

**Notas**
- **Validar antes de modificar.** Cada lambda devuelve los errores **antes** de agregar nada, porque el helper guarda aunque la lambda devuelva un `ResponseDto` con error.
- **El `loadId`.** Dentro de la lambda la carga tiene `Id = 0`: los movimientos y los reconocimientos se enlazan por la entidad (`BulkLoad = load`) y el `Id` real se pone en la respuesta al salir del helper (`WithLoadId`).
- **Rendimiento.** Para 1.000 filas son pocas consultas: la carga, personas (una con `IN`), categorías (una) y pendientes (una). Después vienen los `INSERT` de un solo `SaveChanges`.
- **`ResponseDto.Response`.** Si en tu `ResponseDto<T>` la propiedad se llama distinto, ajústala en `WithLoadId`.

### Registro — `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IGoldenBulkLoadService, GoldenBulkLoadService>();
```

---

## 8. Paso 6 — Controlador: `Controllers/GoldenBulkLoadsController.cs`

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenBulkLoadsErrorMessage = "No se pudo procesar la carga masiva.";
```

### El controlador

Cada acción con su `try/catch` completo (regla 18).

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: cargas masivas desde Excel (el navegador lee el archivo y envía las filas).</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    // Permisos: pendiente (guía de aprobaciones, sección 9). La validación va en el servicio.
    public class GoldenBulkLoadsController(IGoldenBulkLoadService service) : ControllerBase
    {
        private readonly IGoldenBulkLoadService _service = service;

        /// <summary>Crear reconocimientos (quedan pendientes). POST recognitions?dryRun=true revisa sin guardar.</summary>
        [HttpPost("recognitions")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Recognitions([FromBody] GoldenBulkRequestDto<GoldenBulkRecognitionRowDto> request, [FromQuery] bool dryRun = false)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.ProcessRecognitionsAsync(request, dryRun, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage });
            }
        }

        /// <summary>Asignar puntos. POST points?dryRun=true revisa sin guardar.</summary>
        [HttpPost("points")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Points([FromBody] GoldenBulkRequestDto<GoldenBulkPointsRowDto> request, [FromQuery] bool dryRun = false)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.ProcessPointsAsync(request, dryRun, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage });
            }
        }
    }
}
```

> **Tamaño del cuerpo.** 1.000 filas con motivos de hasta 1.000 caracteres son unos 1,2 MB de JSON, por debajo del límite por defecto de Kestrel (30 MB). No hay que configurar nada.

---

## 9. Paso 7 — Frontend: pestaña "Puntos masivos"

El frontend de puntos ya está listo:
- `golden-bulk-excel.ts` tiene la plantilla `points` (cédula, correo, puntos, concepto, vence).
- `GoldenBulkLoadsService.process('points', …)` llama a `POST points`.

Solo falta la pestaña, igual que "Reconocimientos masivos".

### `puntos-dorados-admin.component.ts` ✏️

```ts
type AdminTab = 'aprobaciones' | 'categorias' | 'catalogo' | 'puntos' | 'dashboard' | 'masivos' | 'puntos-masivos';
```

### `puntos-dorados-admin.component.html` ✏️

El botón, después de "Reconocimientos masivos":

```html
<button type="button" class="tab-btn" [class.active]="activeTab() === 'puntos-masivos'"
  (click)="setActiveTab('puntos-masivos')">Puntos masivos</button>
```

Y la pestaña, después del bloque `@if (activeTab() === 'masivos') { … }`:

```html
@if (activeTab() === 'puntos-masivos') {
<section class="panel">
  <div class="panel-title">
    <h2>Puntos masivos</h2>
    <p>Asigna puntos a muchas personas a la vez con un archivo XLSX: bonos, campañas o premios de un evento.</p>
  </div>

  <div class="bulk-sections">
    <article class="bulk-section">
      <div class="bulk-section-head">
        <h3><i class="fa-solid fa-coins" aria-hidden="true"></i> Asignar puntos</h3>
        <p>Sube un archivo con cédula/correo, puntos, concepto y, si quieres, la fecha de vencimiento (vacío = 12 meses).
          Los puntos se abonan de inmediato y la persona los ve en "Mis puntos".</p>
      </div>
      <app-golden-bulk-load [kinds]="['points']" />
    </article>
  </div>
</section>
}
```

- **No hace falta un caso en `loadAdminTabData`:** `app-golden-bulk-load` no carga nada al abrirse.
- **Movimientos:** cada fila aparece como una asignación más en la pestaña **Puntos** (Movimientos), con su concepto. Desde ahí se puede reversar una fila hecha por error, como cualquier asignación manual.

---

## 10. Pruebas

**Reconocimientos masivos**
- **Plantilla:** "Descargar plantilla" baja un Excel con `cedula`, `correo`, `categoria`, `motivo` y la hoja Instrucciones.
- **Archivo correcto de 3 filas:**
  - La revisión dice "Correctas: 3" y habilita "Procesar".
  - Al procesar: "Carga #N, filas aplicadas: 3". Los tres aparecen como **Pendientes** en Aprobaciones, creados por quien subió el archivo.
- **Errores por fila** (cada uno con su número; no se aplica ninguna fila):
  - Una categoría inactiva o mal escrita.
  - Un motivo de 10 caracteres.
  - Una cédula que no existe.
  - Una fila sin cédula ni correo.
- **Cédula y correo de dos personas distintas:** "La cédula y el correo no son de la misma persona".
- **La misma persona y categoría dos veces en el archivo:** la segunda fila da "Ya hay un reconocimiento pendiente igual".
- **El mismo archivo otra vez, sin aprobar los anteriores:** todas las filas dan pendiente duplicado.
- **Quien sube el archivo aparece como reconocido:** "No puedes asignarte puntos ni reconocerte a ti mismo".

**Puntos masivos**
- **Archivo correcto (200 + 150 + 100, dos filas de la misma persona):**
  - Se procesa: "Puntos: 450".
  - En la pestaña Puntos aparecen 3 movimientos y el saldo de esa persona sube 350.
- **Vencimiento:**
  - `vence` vacío: vence a los 12 meses.
  - Una fecha de 30 meses: "El vencimiento debe ser posterior a hoy y máximo 24 meses después".
  - Una fecha en una celda con formato de fecha de Excel se lee bien.
- **Puntos `0`, `-5` o `150000`; concepto de 3 letras:** error en esa fila.

**Las dos cargas**
- **Doble clic en "Procesar"** (o reenviar la misma petición desde Postman con el mismo `requestId`): la segunda responde `alreadyProcessed: true` con el mismo `loadId` y no duplica nada.
- **Lo que se procesó:**
  - En la base de datos: `golden_bulk_load` tiene la carga, y los movimientos y reconocimientos tienen su `bulk_load_id`.
  - **Consultas de control:** las de la [guía de puntos](.claude/guias/puntos-dorados-puntos-api.md) devuelven cero filas.
- **1.001 filas:** el componente avisa antes de llamar a la API. Si se llama directo, responde `hasError` "admite hasta 1.000 filas".

---

## ✅ Checklist

- [ ] `GoldenBulkLoads.sql` ejecutado.
- [ ] `GoldenBulkLoad`, `GoldenBulkLoadType`, su configuración y el `DbSet`; `BulkLoadId` y `BulkLoad` en `GoldenPointsTransaction` y `GoldenRecognition` (entidad y configuración).
- [ ] `GoldenPointsCredit` con `BulkLoad`, que se usa en `CreditAsync`.
- [ ] **La propiedad real de la cédula en `User`** en `GoldenBulkUserDirectory` (las dos marcas ⬅).
- [ ] `GoldenBulkLoadConstants`, `GoldenBulkLoadDtos`, `IGoldenBulkLoadService` y `GoldenBulkLoadService`; registro en `ApplicationServiceRegistration.cs`.
- [ ] `GoldenBulkLoadsController` con `recognitions` y `points` (cada una con su `try/catch`).
- [ ] Pestaña "Puntos masivos" en administración.
- [ ] Para "Aprobar pendientes": `approvals` y `pending-recognitions`, con sus constantes, DTO y tipos privados, de la [otra guía](puntos-dorados-editar-masivos-dashboard.md) (secciones 2.5 y 2.6), en este mismo servicio.
- [ ] Probados el doble clic y una carga con errores (no aplica nada).
