# 🏆 Puntos Dorados — Reconocimientos, parte 1 (API .NET 8 + SQL Server)

Base de datos y API para las pestañas del colaborador en `/puntos-dorados-user`:

| Pestaña / historia | Endpoint |
|---|---|
| **Reconocer** — crear reconocimiento | `POST /api/GoldenRecognitions` |
| Ver los reconocimientos que **yo creé** | `GET /api/GoldenRecognitions/sent?page=&pageSize=` |
| **Mis reconocimientos** — los aprobados que **recibí** | `GET /api/GoldenRecognitions/received?page=&pageSize=` |
| **Feed** — reconocimientos públicos aprobados de todos | `GET /api/GoldenRecognitions/feed?page=&pageSize=&categoryId=` |
| **Reaccionar** (Like, Aplauso, Inspirador, Orgullo) | `PUT` / `DELETE /api/GoldenRecognitions/{id}/reactions/{tipo}` |
| Conteo rápido de reacciones | `GET /api/GoldenRecognitions/{id}/reactions` (y viene en cada ítem del feed) |

- **Todo paginado** y **lo más reciente primero**.
- **Los puntos son opcionales** y **nunca salen en el feed**: solo los ve quien los recibió, en "Mis reconocimientos".
- **Solo backend.** El JSON coincide con tus tipos `GoldenNomination`, `GoldenRecognitionVisibility` y `GoldenReactionType` de `puntos-dorados.ts`.
- **Parte 2 (después):** aprobaciones (aprobar, rechazar, asignar puntos, comentarios), vencimiento de puntos y notificaciones (sección 11).
- **Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md).

---

## 1. 🧭 ¿Repositorio propio? Sí, pero solo para leer

| Condición ([ARQUITECTURA Y EJEMPLO](.claude/ARQUITECTURA%20Y%20EJEMPLO.MD), sección 5) | ¿Se cumple? |
|---|---|
| Agregados en SQL | **Sí.** Conteo de reacciones por tipo para cada reconocimiento de la página (`GroupBy`). Contarlas en memoria traería todas las reacciones. |
| Proyecciones de varias tablas | **Sí.** Cada tarjeta necesita reconocimiento + quien recibe + quien reconoce (`dbo.users`) + categoría (nombre, icono, color). |
| Paginación con total y orden por fecha | **Sí.** El genérico no tiene una consulta con proyección, total y orden propio a la vez. |

**Decisión:**

| Operación | Cómo |
|---|---|
| Crear reconocimiento, agregar y quitar reacciones | Repositorio genérico con `ITransactionExecutorHelper` (patrón estándar) |
| Feed, enviados, recibidos y conteos | `IGoldenRecognitionQueryRepository` (**solo lectura**), heredando `GenericRepositoryBase` |

El servicio devuelve `ResponseDto<T>` en todos los casos y el controlador es el de Request: para el frontend todo se ve igual.

---

## 2. 🧐 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Ciclo de vida.** El backlog separa Postulación → Aprobaciones → Feed. | Un reconocimiento nace **Pendiente**. El feed y "Mis reconocimientos" muestran solo **Aprobados**. Aprobar es la parte 2; mientras tanto, para probar, se aprueba con el SQL de la sección 4. |
| 2 | **Puntos.** Opcionales, y el formulario del colaborador no los pide. | `points_assigned` puede ser `NULL`. **El colaborador no asigna puntos** (se presta a abusos entre compañeros): los asigna Compensación y Beneficios al aprobar (parte 2). |
| 3 | **Puntos en el feed.** | El DTO del feed **no tiene** campo de puntos: no basta con que llegue en `null`. Tampoco salen en "enviados" (los puntos de un compañero son suyos). Solo los ve quien los recibió. |
| 4 | **Visibilidad.** `Publica` / `Privada`. | Por defecto `Publica`. Un reconocimiento privado aprobado sale en "Mis reconocimientos" de quien lo recibió, pero no en el feed. |
| 5 | **Orden.** "Ver primero los últimos". | "Enviados" y "recibidos": por fecha de creación, del más nuevo al más viejo. **Feed: por fecha de aprobación**: uno creado hace tres semanas y aprobado hoy sale arriba, no enterrado. El `id` desempata. |
| 6 | **Paginación.** | `page` (desde 1) y `pageSize` (por defecto 10, máximo 50). Valores fuera de rango se ajustan, no dan error. La respuesta trae `totalCount` y `totalPages`. |
| 7 | **Reacciones.** La tarjeta tiene "Me gusta" y tres iconos más. | Cada persona puede dar **cada tipo una vez** por reconocimiento (como Slack): Like y Aplauso a la vez, pero no dos Like. Índice único `(recognition_id, user_id, reaction_type)`. |
| 8 | **Doble clic al reaccionar.** | Agregar es `PUT` y quitar es `DELETE`, los dos **idempotentes**: repetirlos no cambia nada ni da error. Si dos clics chocan en el índice único, se responde éxito con el conteo actual. |
| 9 | **¿Dónde se reacciona?** | Solo en reconocimientos del feed (aprobados y públicos). |
| 10 | **Conteo rápido.** | Cada ítem del feed trae `reactions: { counts, myReactions, total }`, calculado con un solo `GroupBy` por página sobre un índice. Si algún día el feed es muy grande, se pueden guardar contadores en la tabla. |
| 11 | **Reconocerse a sí mismo.** | No se permite (servicio + `CHECK` en la base de datos). |
| 12 | **Spam.** Reconocer a la misma persona, en la misma categoría, varias veces seguidas. | No se permite otro reconocimiento **pendiente** igual (mismo autor, misma persona, misma categoría). Cuando se aprueba o rechaza el primero, se puede volver a reconocer. |
| 13 | **Motivo.** El formulario pide mínimo 15 caracteres. | 15 a 1.000 caracteres, validado en el servicio y en la base de datos. Angular escapa el texto al mostrarlo; si se usa en un correo (parte 2), pasarlo por `WebUtility.HtmlEncode`. |
| 14 | **Personas.** | Quien reconoce y quien recibe deben existir en `dbo.users`. Si el usuario del token no está, se responde el mismo mensaje que usa Request ("…ingresar tu información en el módulo 'Mis Datos'"). |

---

## 3. 📁 Archivos

```text
DOCCB.Domain/
├── Enum/
│   ├── GoldenRecognitionStatus.cs
│   ├── GoldenRecognitionVisibility.cs
│   └── GoldenReactionType.cs
└── Entities/
    ├── GoldenRecognition.cs
    └── GoldenRecognitionReaction.cs

DOCCB.Application/
├── Contracts/Persistence/IGoldenRecognitionQueryRepository.cs   ⭐ lecturas (feed, enviados, recibidos, conteos)
└── Features/GoldenPoints/Application/
    ├── Constants/
    │   ├── GoldenRecognitionConstants.cs         límites y mensajes
    │   └── GoldenRecognitionCodes.cs             enum ⇄ "Aprobada", "Publica", "Aplauso"…
    ├── Dtos/GoldenRecognitionDtos.cs
    ├── Helpers/
    │   ├── GoldenRecognitionValidator.cs
    │   └── GoldenRecognitionMapper.cs            ⭐ aquí se decide qué ve cada quien (puntos)
    ├── Interfaces/IGoldenRecognitionService.cs
    └── Services/GoldenRecognitionService.cs

DOCCB.Infraestructure/
├── Configurations/
│   ├── GoldenRecognitionConfiguration.cs
│   └── GoldenRecognitionReactionConfiguration.cs
├── Persistence/
│   ├── Models/DOCCbDbContext.cs                  ✏️ + 2 DbSet
│   └── Scripts SQL/GoldenPointsRecognitions.sql
├── Repositories/GoldenRecognitionQueryRepository.cs
└── InfrastructureServiceRegistration.cs          ✏️ + 1 línea

WebApp/
├── Common/ApiResponseConstants.cs                ✏️ + 1 mensaje
└── Controllers/GoldenRecognitionsController.cs
```

---

## 4. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/GoldenPointsRecognitions.sql`

```sql
/* =====================================================================
   Puntos Dorados — reconocimientos y reacciones
   Base de datos: DB · Esquema: dbo
   Requiere: dbo.users, dbo.golden_recognition_category
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

-- Obligatorios para los índices filtrados.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_recognition
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_recognition', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_recognition
    (
        id                INT            IDENTITY(1, 1) NOT NULL,
        nominee_user_id   INT            NOT NULL,      -- quien recibe el reconocimiento
        nominator_user_id INT            NOT NULL,      -- quien lo crea
        category_id       INT            NOT NULL,
        reason            NVARCHAR(1000) NOT NULL,
        status            VARCHAR(20)    NOT NULL CONSTRAINT df_golden_recognition_status DEFAULT ('PENDING'),
        visibility        VARCHAR(20)    NOT NULL CONSTRAINT df_golden_recognition_visibility DEFAULT ('PUBLIC'),
        points_assigned   INT            NULL,          -- opcional; lo asigna la aprobación (parte 2)
        reviewed_date     DATETIME2(0)   NULL,          -- fecha de aprobación o rechazo (parte 2)
        reviewed_by       NVARCHAR(150)  NULL,
        created_date      DATETIME2(0)   NOT NULL CONSTRAINT df_golden_recognition_created_date DEFAULT (SYSUTCDATETIME()),
        created_by        NVARCHAR(150)  NOT NULL,
        updated_date      DATETIME2(0)   NULL,
        updated_by        NVARCHAR(150)  NULL,

        CONSTRAINT pk_golden_recognition PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_golden_recognition_nominee FOREIGN KEY (nominee_user_id) REFERENCES dbo.users (id),
        CONSTRAINT fk_golden_recognition_nominator FOREIGN KEY (nominator_user_id) REFERENCES dbo.users (id),
        CONSTRAINT fk_golden_recognition_category FOREIGN KEY (category_id) REFERENCES dbo.golden_recognition_category (id),
        CONSTRAINT ck_golden_recognition_not_self CHECK (nominee_user_id <> nominator_user_id),
        CONSTRAINT ck_golden_recognition_reason CHECK (LEN(LTRIM(RTRIM(reason))) >= 15),
        CONSTRAINT ck_golden_recognition_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
        CONSTRAINT ck_golden_recognition_visibility CHECK (visibility IN ('PUBLIC', 'PRIVATE')),
        CONSTRAINT ck_golden_recognition_points CHECK (points_assigned IS NULL OR points_assigned > 0)
    );

    -- "Mis reconocimientos" (recibidos aprobados, más nuevos primero)
    CREATE INDEX ix_golden_recognition_nominee
        ON dbo.golden_recognition (nominee_user_id, status, created_date DESC);

    -- "Enviados" (más nuevos primero) y la regla de "un pendiente igual"
    CREATE INDEX ix_golden_recognition_nominator
        ON dbo.golden_recognition (nominator_user_id, created_date DESC)
        INCLUDE (nominee_user_id, category_id, status);

    -- Feed: solo aprobados y públicos, aprobados más recientes primero
    CREATE INDEX ix_golden_recognition_feed
        ON dbo.golden_recognition (reviewed_date DESC, id DESC)
        INCLUDE (category_id)
        WHERE status = 'APPROVED' AND visibility = 'PUBLIC';
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_recognition_reaction — una fila por persona, reconocimiento y tipo
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_recognition_reaction', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_recognition_reaction
    (
        id             INT          IDENTITY(1, 1) NOT NULL,
        recognition_id INT          NOT NULL,
        user_id        INT          NOT NULL,
        reaction_type  VARCHAR(20)  NOT NULL,
        created_date   DATETIME2(0) NOT NULL CONSTRAINT df_golden_recognition_reaction_created_date DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT pk_golden_recognition_reaction PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_golden_recognition_reaction_recognition
            FOREIGN KEY (recognition_id) REFERENCES dbo.golden_recognition (id) ON DELETE CASCADE,
        CONSTRAINT fk_golden_recognition_reaction_user FOREIGN KEY (user_id) REFERENCES dbo.users (id),
        CONSTRAINT ck_golden_recognition_reaction_type CHECK (reaction_type IN ('LIKE', 'APPLAUSE', 'INSPIRING', 'PROUD'))
    );

    -- Cada tipo una vez por persona: el doble clic choca aquí.
    CREATE UNIQUE INDEX ux_golden_recognition_reaction
        ON dbo.golden_recognition_reaction (recognition_id, user_id, reaction_type);

    -- Conteo rápido por reconocimiento y tipo.
    CREATE INDEX ix_golden_recognition_reaction_counts
        ON dbo.golden_recognition_reaction (recognition_id, reaction_type);
END;
GO
```

> Los códigos en la base de datos van en inglés (`APPROVED`, `PUBLIC`, `APPLAUSE`) como el resto del esquema. La API los traduce a los textos de tu frontend (`Aprobada`, `Publica`, `Aplauso`).

### Para probar el feed mientras no existe la aprobación

```sql
-- Aprobar a mano un reconocimiento (lo hará la parte 2)
UPDATE dbo.golden_recognition
SET    status = 'APPROVED',
       reviewed_date = SYSUTCDATETIME(),
       reviewed_by = N'prueba@empresa.com',
       points_assigned = 150
WHERE  id = 1;

-- Conteo de reacciones de un reconocimiento
SELECT reaction_type, COUNT(*) AS total
FROM   dbo.golden_recognition_reaction
WHERE  recognition_id = 1
GROUP BY reaction_type;
```

---

## 5. Paso 2 — Dominio y configuración EF

### `Enum/GoldenRecognitionStatus.cs`, `GoldenRecognitionVisibility.cs`, `GoldenReactionType.cs`

```csharp
namespace DOCCB.Domain.Enum
{
    public enum GoldenRecognitionStatus
    {
        Pending = 1,
        Approved = 2,
        Rejected = 3,
    }

    public enum GoldenRecognitionVisibility
    {
        Public = 1,
        Private = 2,
    }

    public enum GoldenReactionType
    {
        Like = 1,
        Applause = 2,
        Inspiring = 3,
        Proud = 4,
    }
}
```

> Uno por archivo, con el nombre del enum.

### `Entities/GoldenRecognition.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities
{
    /// <summary>Reconocimiento de un colaborador a otro. Nace pendiente; la aprobación lo publica.</summary>
    public class GoldenRecognition
    {
        public int Id { get; set; }
        public int NomineeUserId { get; set; }
        public int NominatorUserId { get; set; }
        public int CategoryId { get; set; }
        public string Reason { get; set; } = string.Empty;
        public GoldenRecognitionStatus Status { get; set; } = GoldenRecognitionStatus.Pending;
        public GoldenRecognitionVisibility Visibility { get; set; } = GoldenRecognitionVisibility.Public;

        /// <summary>Opcional. Lo asigna la aprobación; nunca el colaborador.</summary>
        public int? PointsAssigned { get; set; }

        public DateTime? ReviewedDate { get; set; }
        public string? ReviewedBy { get; set; }

        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;
        public DateTime? UpdatedDate { get; set; }
        public string? UpdatedBy { get; set; }

        public User Nominee { get; set; } = null!;
        public User Nominator { get; set; } = null!;
        public GoldenRecognitionCategory Category { get; set; } = null!;
        public ICollection<GoldenRecognitionReaction> Reactions { get; set; } = new List<GoldenRecognitionReaction>();
    }
}
```

### `Entities/GoldenRecognitionReaction.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities
{
    public class GoldenRecognitionReaction
    {
        public int Id { get; set; }
        public int RecognitionId { get; set; }
        public int UserId { get; set; }
        public GoldenReactionType ReactionType { get; set; }
        public DateTime CreatedDate { get; set; }

        public GoldenRecognition Recognition { get; set; } = null!;
    }
}
```

### `Configurations/GoldenRecognitionConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenRecognitionConfiguration : IEntityTypeConfiguration<GoldenRecognition>
    {
        public void Configure(EntityTypeBuilder<GoldenRecognition> builder)
        {
            builder.ToTable("golden_recognition", "dbo");

            builder.HasKey(r => r.Id).HasName("pk_golden_recognition");

            builder.Property(r => r.Id).HasColumnName("id");
            builder.Property(r => r.NomineeUserId).HasColumnName("nominee_user_id");
            builder.Property(r => r.NominatorUserId).HasColumnName("nominator_user_id");
            builder.Property(r => r.CategoryId).HasColumnName("category_id");
            builder.Property(r => r.Reason).HasColumnName("reason").HasMaxLength(1000).IsRequired();
            builder.Property(r => r.PointsAssigned).HasColumnName("points_assigned");
            builder.Property(r => r.ReviewedDate).HasColumnName("reviewed_date").HasColumnType("datetime2(0)");
            builder.Property(r => r.ReviewedBy).HasColumnName("reviewed_by").HasMaxLength(150);
            builder.Property(r => r.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(r => r.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
            builder.Property(r => r.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
            builder.Property(r => r.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

            // Enum ⇄ código en mayúsculas ('APPROVED', 'PUBLIC'), como exigen los CHECK del script.
            builder.Property(r => r.Status)
                .HasColumnName("status")
                .HasMaxLength(20)
                .IsUnicode(false)
                .HasConversion(
                    status => status.ToString().ToUpperInvariant(),
                    code => Enum.Parse<GoldenRecognitionStatus>(code, true));

            builder.Property(r => r.Visibility)
                .HasColumnName("visibility")
                .HasMaxLength(20)
                .IsUnicode(false)
                .HasConversion(
                    visibility => visibility.ToString().ToUpperInvariant(),
                    code => Enum.Parse<GoldenRecognitionVisibility>(code, true));

            builder.HasOne(r => r.Nominee)
                .WithMany()
                .HasForeignKey(r => r.NomineeUserId)
                .HasConstraintName("fk_golden_recognition_nominee")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasOne(r => r.Nominator)
                .WithMany()
                .HasForeignKey(r => r.NominatorUserId)
                .HasConstraintName("fk_golden_recognition_nominator")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasOne(r => r.Category)
                .WithMany()
                .HasForeignKey(r => r.CategoryId)
                .HasConstraintName("fk_golden_recognition_category")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasMany(r => r.Reactions)
                .WithOne(x => x.Recognition)
                .HasForeignKey(x => x.RecognitionId)
                .HasConstraintName("fk_golden_recognition_reaction_recognition")
                .OnDelete(DeleteBehavior.Cascade);
        }
    }
}
```

### `Configurations/GoldenRecognitionReactionConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenRecognitionReactionConfiguration : IEntityTypeConfiguration<GoldenRecognitionReaction>
    {
        public void Configure(EntityTypeBuilder<GoldenRecognitionReaction> builder)
        {
            builder.ToTable("golden_recognition_reaction", "dbo");

            builder.HasKey(x => x.Id).HasName("pk_golden_recognition_reaction");

            builder.Property(x => x.Id).HasColumnName("id");
            builder.Property(x => x.RecognitionId).HasColumnName("recognition_id");
            builder.Property(x => x.UserId).HasColumnName("user_id");
            builder.Property(x => x.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");

            builder.Property(x => x.ReactionType)
                .HasColumnName("reaction_type")
                .HasMaxLength(20)
                .IsUnicode(false)
                .HasConversion(
                    type => type.ToString().ToUpperInvariant(),
                    code => Enum.Parse<GoldenReactionType>(code, true));

            builder.HasIndex(x => new { x.RecognitionId, x.UserId, x.ReactionType })
                .IsUnique()
                .HasDatabaseName("ux_golden_recognition_reaction");

            builder.HasOne<User>()
                .WithMany()
                .HasForeignKey(x => x.UserId)
                .HasConstraintName("fk_golden_recognition_reaction_user")
                .OnDelete(DeleteBehavior.Restrict);
        }
    }
}
```

### `Persistence/Models/DOCCbDbContext.cs` ✏️

```csharp
public DbSet<GoldenRecognition> GoldenRecognitions { get; set; }
public DbSet<GoldenRecognitionReaction> GoldenRecognitionReactions { get; set; }
```

---

## 6. Paso 3 — Constantes, códigos y DTOs

### `Constants/GoldenRecognitionConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenRecognitionConstants
    {
        public const int ReasonMinLength = 15;
        public const int ReasonMaxLength = 1000;
        public const int DefaultPageSize = 10;
        public const int MaxPageSize = 50;

        public const string UserNotRegistered = "Para realizar cualquier acción primero debes ingresar tu información en el módulo 'Mis Datos'";
        public const string NomineeRequired = "Selecciona a la persona que quieres reconocer.";
        public const string NomineeNotFound = "La persona seleccionada no existe.";
        public const string CannotRecognizeYourself = "No puedes reconocerte a ti mismo.";
        public const string CategoryRequired = "Selecciona una categoría de reconocimiento.";
        public const string CategoryNotFound = "La categoría de reconocimiento no existe.";
        public const string CategoryInactive = "La categoría está inactiva. Elige otra.";
        public const string ReasonTooShort = "Cuéntanos el motivo con al menos 15 caracteres.";
        public const string ReasonTooLong = "El motivo admite hasta 1.000 caracteres.";
        public const string VisibilityInvalid = "La visibilidad debe ser \"Publica\" o \"Privada\".";
        public const string DuplicatePending = "Ya tienes un reconocimiento pendiente para esta persona en esta categoría. Espera a que se revise.";
        public const string RecognitionNotInFeed = "El reconocimiento no existe o no está publicado en el feed.";
        public const string ReactionInvalid = "La reacción debe ser Like, Aplauso, Inspirador u Orgullo.";
        public const string UnexpectedError = "No se pudo completar la operación. Intenta de nuevo.";
    }
}
```

### `Constants/GoldenRecognitionCodes.cs`

Traduce los enums a los textos de `puntos-dorados.ts` y al revés.

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenRecognitionCodes
    {
        // GoldenNominationStatus = 'Pendiente' | 'Aprobada' | 'Rechazada'
        public static string ToStatusCode(GoldenRecognitionStatus status) => status switch
        {
            GoldenRecognitionStatus.Approved => "Aprobada",
            GoldenRecognitionStatus.Rejected => "Rechazada",
            _ => "Pendiente",
        };

        // GoldenRecognitionVisibility = 'Publica' | 'Privada'
        public static string ToVisibilityCode(GoldenRecognitionVisibility visibility) =>
            visibility == GoldenRecognitionVisibility.Private ? "Privada" : "Publica";

        /// <summary>Vacío = pública. Acepta "Publica"/"Pública" y "Privada", sin distinguir mayúsculas.</summary>
        public static bool TryParseVisibility(string? value, out GoldenRecognitionVisibility visibility)
        {
            var text = value?.Trim().ToLowerInvariant();
            visibility = GoldenRecognitionVisibility.Public;

            if (string.IsNullOrEmpty(text) || text is "publica" or "pública")
            {
                return true;
            }

            if (text == "privada")
            {
                visibility = GoldenRecognitionVisibility.Private;
                return true;
            }

            return false;
        }

        // GoldenReactionType = 'Like' | 'Aplauso' | 'Inspirador' | 'Orgullo'
        private static readonly IReadOnlyDictionary<GoldenReactionType, string> ReactionCodes = new Dictionary<GoldenReactionType, string>
        {
            [GoldenReactionType.Like] = "Like",
            [GoldenReactionType.Applause] = "Aplauso",
            [GoldenReactionType.Inspiring] = "Inspirador",
            [GoldenReactionType.Proud] = "Orgullo",
        };

        public static IEnumerable<GoldenReactionType> AllReactionTypes => ReactionCodes.Keys;

        public static string ToReactionCode(GoldenReactionType type) => ReactionCodes[type];

        public static bool TryParseReaction(string? value, out GoldenReactionType type)
        {
            foreach (var pair in ReactionCodes)
            {
                if (string.Equals(pair.Value, value?.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    type = pair.Key;
                    return true;
                }
            }

            type = default;
            return false;
        }
    }
}
```

### `Dtos/GoldenRecognitionDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>GoldenPerson del frontend.</summary>
    public class GoldenPersonDto
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string Email { get; set; } = string.Empty;
        public string Area { get; set; } = string.Empty;
    }

    /// <summary>Formulario "Crear reconocimiento". Sin puntos: los asigna la aprobación.</summary>
    public class CreateGoldenRecognitionDto
    {
        /// <summary>Id en dbo.users. Opcional si llega NomineeEmail.</summary>
        public int NomineeUserId { get; set; }
        /// <summary>Correo corporativo de la persona: es lo que envía el formulario del frontend.</summary>
        public string? NomineeEmail { get; set; }
        public int CategoryId { get; set; }
        public string? Reason { get; set; }
        /// <summary>"Publica" (por defecto) o "Privada".</summary>
        public string? Visibility { get; set; }
    }

    /// <summary>Enviados y recibidos (GoldenNomination del frontend).</summary>
    public class GoldenRecognitionDto
    {
        public int Id { get; set; }
        public GoldenPersonDto Nominee { get; set; } = new();
        public GoldenPersonDto NominatedBy { get; set; } = new();
        public string Reason { get; set; } = string.Empty;
        public int CategoryId { get; set; }
        public string CategoryName { get; set; } = string.Empty;
        public string CategoryIcon { get; set; } = string.Empty;
        public string CategoryColor { get; set; } = string.Empty;
        /// <summary>"Pendiente" | "Aprobada" | "Rechazada"</summary>
        public string Status { get; set; } = string.Empty;
        /// <summary>"Publica" | "Privada"</summary>
        public string Visibility { get; set; } = string.Empty;
        /// <summary>Solo en "recibidos". En "enviados" siempre null.</summary>
        public int? PointsAssigned { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime? ReviewedAt { get; set; }
    }

    /// <summary>Tarjeta del feed. A propósito NO tiene puntos.</summary>
    public class GoldenRecognitionFeedItemDto
    {
        public int Id { get; set; }
        public GoldenPersonDto Nominee { get; set; } = new();
        public GoldenPersonDto NominatedBy { get; set; } = new();
        public string Reason { get; set; } = string.Empty;
        public int CategoryId { get; set; }
        public string CategoryName { get; set; } = string.Empty;
        public string CategoryIcon { get; set; } = string.Empty;
        public string CategoryColor { get; set; } = string.Empty;
        public DateTime CreatedAt { get; set; }
        public DateTime? ApprovedAt { get; set; }
        public GoldenReactionSummaryDto Reactions { get; set; } = new();
    }

    /// <summary>Conteo de reacciones de un reconocimiento.</summary>
    public class GoldenReactionSummaryDto
    {
        public int RecognitionId { get; set; }
        /// <summary>Siempre los cuatro tipos: { "Like": 3, "Aplauso": 1, "Inspirador": 0, "Orgullo": 0 }.</summary>
        public Dictionary<string, int> Counts { get; set; } = [];
        /// <summary>Las que dio el usuario actual, para pintar los botones activos.</summary>
        public List<string> MyReactions { get; set; } = [];
        public int Total { get; set; }
    }

    /// <summary>?page=&pageSize=&categoryId=</summary>
    public class GoldenRecognitionPageQueryDto
    {
        public int Page { get; set; } = 1;
        public int PageSize { get; set; } = 10;
        /// <summary>Solo en el feed.</summary>
        public int? CategoryId { get; set; }
    }

    public class GoldenPagedResultDto<T>
    {
        public List<T> Items { get; set; } = [];
        public int Page { get; set; }
        public int PageSize { get; set; }
        public int TotalCount { get; set; }
        public int TotalPages => PageSize == 0 ? 0 : (int)Math.Ceiling(TotalCount / (double)PageSize);
    }
}
```

> **Área de la persona.** La entidad `User` no tiene área y `UsersArea` no está mapeada en EF, así que por ahora `Area` llega vacía (la proyección de la sección 7 pone `string.Empty`). Cuando se mapee `UsersArea`, se cambia solo esa línea.

---

## 7. Paso 4 — Lecturas: `IGoldenRecognitionQueryRepository`

### `Contracts/Persistence/IGoldenRecognitionQueryRepository.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Contracts.Persistence
{
    /// <summary>Un reconocimiento con sus personas y su categoría, tal como sale de la base de datos.</summary>
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

    public sealed record GoldenRecognitionPage(IReadOnlyList<GoldenRecognitionRow> Rows, int TotalCount);

    public sealed record GoldenReactionCount(int RecognitionId, GoldenReactionType ReactionType, int Count);

    public sealed record GoldenUserReaction(int RecognitionId, GoldenReactionType ReactionType);

    /// <summary>Solo lectura. Las escrituras van por el repositorio genérico.</summary>
    public interface IGoldenRecognitionQueryRepository
    {
        Task<int?> GetUserIdByEmailAsync(string email);

        /// <summary>Aprobados y públicos; aprobados más recientes primero.</summary>
        Task<GoldenRecognitionPage> GetFeedPageAsync(int? categoryId, int page, int pageSize);

        /// <summary>Creados por el usuario, todos los estados; más nuevos primero.</summary>
        Task<GoldenRecognitionPage> GetSentPageAsync(int nominatorUserId, int page, int pageSize);

        /// <summary>Recibidos y aprobados (públicos y privados); más nuevos primero.</summary>
        Task<GoldenRecognitionPage> GetReceivedPageAsync(int nomineeUserId, int page, int pageSize);

        Task<GoldenRecognitionRow?> GetRowAsync(int recognitionId);

        Task<IReadOnlyList<GoldenReactionCount>> GetReactionCountsAsync(IReadOnlyCollection<int> recognitionIds);

        Task<IReadOnlyList<GoldenUserReaction>> GetUserReactionsAsync(IReadOnlyCollection<int> recognitionIds, int userId);
    }
}
```

### `Repositories/GoldenRecognitionQueryRepository.cs`

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
    /// <summary>Tabla principal: golden_recognition. Solo lecturas sin seguimiento.</summary>
    public class GoldenRecognitionQueryRepository(DOCCbDbContext context)
        : GenericRepositoryBase<DOCCbDbContext, GoldenRecognition>(context), IGoldenRecognitionQueryRepository
    {
        /// <summary>Una sola proyección para feed, enviados y recibidos: trae solo las columnas necesarias.</summary>
        private static readonly Expression<Func<GoldenRecognition, GoldenRecognitionRow>> ToRow = r => new GoldenRecognitionRow(
            r.Id,
            r.NomineeUserId,
            r.Nominee.DisplayName,               // ⬅ propiedades reales de User
            r.Nominee.CorportativeEmail,
            // User no tiene área y UsersArea no está mapeada en EF: por ahora va vacía.
            string.Empty,
            r.NominatorUserId,
            r.Nominator.DisplayName,
            r.Nominator.CorportativeEmail,
            string.Empty,
            r.Reason,
            r.CategoryId,
            r.Category.Name,
            r.Category.Icon,
            r.Category.Color,
            r.Status,
            r.Visibility,
            r.PointsAssigned,
            r.CreatedDate,
            r.ReviewedDate);

        public Task<int?> GetUserIdByEmailAsync(string email) =>
            _context.Set<User>()
                .AsNoTracking()
                .Where(u => u.CorportativeEmail == email)
                .Select(u => (int?)u.Id)
                .FirstOrDefaultAsync();

        public Task<GoldenRecognitionPage> GetFeedPageAsync(int? categoryId, int page, int pageSize)
        {
            var query = _dbSet
                .AsNoTracking()
                .Where(r => r.Status == GoldenRecognitionStatus.Approved && r.Visibility == GoldenRecognitionVisibility.Public);

            if (categoryId is { } id)
            {
                query = query.Where(r => r.CategoryId == id);
            }

            // Usa ix_golden_recognition_feed. Lo recién aprobado arriba.
            return PageAsync(query.OrderByDescending(r => r.ReviewedDate).ThenByDescending(r => r.Id), page, pageSize);
        }

        public Task<GoldenRecognitionPage> GetSentPageAsync(int nominatorUserId, int page, int pageSize) =>
            PageAsync(
                _dbSet.AsNoTracking()
                    .Where(r => r.NominatorUserId == nominatorUserId)
                    .OrderByDescending(r => r.CreatedDate)
                    .ThenByDescending(r => r.Id),
                page,
                pageSize);

        public Task<GoldenRecognitionPage> GetReceivedPageAsync(int nomineeUserId, int page, int pageSize) =>
            PageAsync(
                _dbSet.AsNoTracking()
                    .Where(r => r.NomineeUserId == nomineeUserId && r.Status == GoldenRecognitionStatus.Approved)
                    .OrderByDescending(r => r.CreatedDate)
                    .ThenByDescending(r => r.Id),
                page,
                pageSize);

        public Task<GoldenRecognitionRow?> GetRowAsync(int recognitionId) =>
            _dbSet.AsNoTracking()
                .Where(r => r.Id == recognitionId)
                .Select(ToRow)
                .FirstOrDefaultAsync();

        public async Task<IReadOnlyList<GoldenReactionCount>> GetReactionCountsAsync(IReadOnlyCollection<int> recognitionIds)
        {
            if (recognitionIds.Count == 0)
            {
                return [];
            }

            var ids = recognitionIds.ToList();

            // Un solo GROUP BY para toda la página (usa ix_golden_recognition_reaction_counts).
            return await _context.Set<GoldenRecognitionReaction>()
                .AsNoTracking()
                .Where(x => ids.Contains(x.RecognitionId))
                .GroupBy(x => new { x.RecognitionId, x.ReactionType })
                .Select(g => new GoldenReactionCount(g.Key.RecognitionId, g.Key.ReactionType, g.Count()))
                .ToListAsync();
        }

        public async Task<IReadOnlyList<GoldenUserReaction>> GetUserReactionsAsync(IReadOnlyCollection<int> recognitionIds, int userId)
        {
            if (recognitionIds.Count == 0)
            {
                return [];
            }

            var ids = recognitionIds.ToList();

            return await _context.Set<GoldenRecognitionReaction>()
                .AsNoTracking()
                .Where(x => x.UserId == userId && ids.Contains(x.RecognitionId))
                .Select(x => new GoldenUserReaction(x.RecognitionId, x.ReactionType))
                .ToListAsync();
        }

        private static async Task<GoldenRecognitionPage> PageAsync(IOrderedQueryable<GoldenRecognition> query, int page, int pageSize)
        {
            var total = await query.CountAsync();

            var rows = await query
                .Skip((page - 1) * pageSize)
                .Take(pageSize)
                .Select(ToRow)
                .ToListAsync();

            return new GoldenRecognitionPage(rows, total);
        }
    }
}
```

### Registro — `InfrastructureServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IGoldenRecognitionQueryRepository, GoldenRecognitionQueryRepository>();
```

---

## 8. Paso 5 — Reglas, mapeo y servicio

### `Helpers/GoldenRecognitionValidator.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public sealed record GoldenRecognitionDraft(int NomineeUserId, string? NomineeEmail, int CategoryId, string Reason, GoldenRecognitionVisibility Visibility);

    public static class GoldenRecognitionValidator
    {
        public static GoldenRecognitionDraft Normalize(CreateGoldenRecognitionDto dto, List<string> errors)
        {
            var nomineeEmail = dto.NomineeEmail?.Trim().ToLowerInvariant();
            if (dto.NomineeUserId <= 0 && string.IsNullOrEmpty(nomineeEmail))
            {
                errors.Add(GoldenRecognitionConstants.NomineeRequired);
            }

            if (dto.CategoryId <= 0)
            {
                errors.Add(GoldenRecognitionConstants.CategoryRequired);
            }

            var reason = dto.Reason?.Trim() ?? string.Empty;
            if (reason.Length < GoldenRecognitionConstants.ReasonMinLength)
            {
                errors.Add(GoldenRecognitionConstants.ReasonTooShort);
            }
            else if (reason.Length > GoldenRecognitionConstants.ReasonMaxLength)
            {
                errors.Add(GoldenRecognitionConstants.ReasonTooLong);
            }

            if (!GoldenRecognitionCodes.TryParseVisibility(dto.Visibility, out var visibility))
            {
                errors.Add(GoldenRecognitionConstants.VisibilityInvalid);
            }

            return new GoldenRecognitionDraft(dto.NomineeUserId, nomineeEmail, dto.CategoryId, reason, visibility);
        }

        /// <summary>Página desde 1; tamaño entre 1 y 50. Fuera de rango se ajusta, no da error.</summary>
        public static (int Page, int PageSize) Paging(GoldenRecognitionPageQueryDto query) =>
            (Math.Max(1, query.Page), Math.Clamp(query.PageSize, 1, GoldenRecognitionConstants.MaxPageSize));
    }
}
```

### `Helpers/GoldenRecognitionMapper.cs` ⭐

Aquí se decide qué ve cada quien. Los puntos solo salen en "recibidos".

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenRecognitionMapper
    {
        /// <param name="includePoints">true solo para quien recibió el reconocimiento.</param>
        public static GoldenRecognitionDto ToDto(GoldenRecognitionRow row, bool includePoints) => new()
        {
            Id = row.Id,
            Nominee = Nominee(row),
            NominatedBy = Nominator(row),
            Reason = row.Reason,
            CategoryId = row.CategoryId,
            CategoryName = row.CategoryName,
            CategoryIcon = row.CategoryIcon,
            CategoryColor = row.CategoryColor,
            Status = GoldenRecognitionCodes.ToStatusCode(row.Status),
            Visibility = GoldenRecognitionCodes.ToVisibilityCode(row.Visibility),
            PointsAssigned = includePoints ? row.PointsAssigned : null,
            CreatedAt = row.CreatedDate,
            ReviewedAt = row.ReviewedDate,
        };

        /// <summary>Tarjeta del feed: sin puntos.</summary>
        public static GoldenRecognitionFeedItemDto ToFeedItem(GoldenRecognitionRow row, GoldenReactionSummaryDto reactions) => new()
        {
            Id = row.Id,
            Nominee = Nominee(row),
            NominatedBy = Nominator(row),
            Reason = row.Reason,
            CategoryId = row.CategoryId,
            CategoryName = row.CategoryName,
            CategoryIcon = row.CategoryIcon,
            CategoryColor = row.CategoryColor,
            CreatedAt = row.CreatedDate,
            ApprovedAt = row.ReviewedDate,
            Reactions = reactions,
        };

        /// <summary>Siempre trae los cuatro tipos, aunque estén en 0.</summary>
        public static GoldenReactionSummaryDto ToReactionSummary(
            int recognitionId,
            IEnumerable<GoldenReactionCount> counts,
            IEnumerable<GoldenReactionType> myReactions)
        {
            var byType = counts
                .Where(c => c.RecognitionId == recognitionId)
                .ToDictionary(c => c.ReactionType, c => c.Count);

            var countsByCode = GoldenRecognitionCodes.AllReactionTypes.ToDictionary(
                type => GoldenRecognitionCodes.ToReactionCode(type),
                type => byType.GetValueOrDefault(type));

            return new GoldenReactionSummaryDto
            {
                RecognitionId = recognitionId,
                Counts = countsByCode,
                MyReactions = myReactions.Select(GoldenRecognitionCodes.ToReactionCode).ToList(),
                Total = countsByCode.Values.Sum(),
            };
        }

        private static GoldenPersonDto Nominee(GoldenRecognitionRow row) => new()
        {
            Id = row.NomineeId,
            Name = row.NomineeName,
            Email = row.NomineeEmail,
            Area = row.NomineeArea,
        };

        private static GoldenPersonDto Nominator(GoldenRecognitionRow row) => new()
        {
            Id = row.NominatorId,
            Name = row.NominatorName,
            Email = row.NominatorEmail,
            Area = row.NominatorArea,
        };
    }
}
```

### `Interfaces/IGoldenRecognitionService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;     // ResponseDto<T>
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenRecognitionService
    {
        Task<ResponseDto<GoldenRecognitionDto>> CreateAsync(CreateGoldenRecognitionDto dto, string currentUserEmail);
        Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>> GetSentAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail);
        Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>> GetReceivedAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail);
        Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionFeedItemDto>>> GetFeedAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail);
        Task<ResponseDto<GoldenReactionSummaryDto>> GetReactionsAsync(int recognitionId, string currentUserEmail);
        Task<ResponseDto<GoldenReactionSummaryDto>> AddReactionAsync(int recognitionId, string reactionType, string currentUserEmail);
        Task<ResponseDto<GoldenReactionSummaryDto>> RemoveReactionAsync(int recognitionId, string reactionType, string currentUserEmail);
    }
}
```

### `Services/GoldenRecognitionService.cs`

- **Lecturas:** con el repositorio de consultas, sin helper (por los agregados).
- **Escrituras:** con el helper y el repositorio genérico.

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
    public class GoldenRecognitionService(
        ITransactionExecutorHelper transactionHelper,
        IGoldenRecognitionQueryRepository queryRepository) : IGoldenRecognitionService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly IGoldenRecognitionQueryRepository _queryRepository = queryRepository;

        // ── Crear ───────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenRecognitionDto>> CreateAsync(CreateGoldenRecognitionDto dto, string currentUserEmail)
        {
            var errors = new List<string>();
            var draft = GoldenRecognitionValidator.Normalize(dto, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(errors);
            }

            GoldenRecognition? created = null;

            var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionDto>>(
                async unitOfWork =>
                {
                    var nominator = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                    if (nominator is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.UserNotRegistered);
                    }

                    // Por id o por correo (el formulario envía el correo).
                    var nominee = draft.NomineeUserId > 0
                        ? await unitOfWork.Repository<User>().GetByIdAsync(draft.NomineeUserId)
                        : await FindUserByEmailAsync(unitOfWork, draft.NomineeEmail!);

                    if (nominee is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.NomineeNotFound);
                    }

                    if (nominee.Id == nominator.Id)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.CannotRecognizeYourself);
                    }

                    var category = await unitOfWork.Repository<GoldenRecognitionCategory>().GetByIdAsync(draft.CategoryId);
                    if (category is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.CategoryNotFound);
                    }

                    if (!category.Active)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.CategoryInactive);
                    }

                    var recognitions = unitOfWork.Repository<GoldenRecognition>();

                    // Anti-spam: no otro pendiente igual (mismo autor, misma persona, misma categoría).
                    var duplicatePending = await recognitions.AnyAsync(r =>
                        r.NominatorUserId == nominator.Id &&
                        r.NomineeUserId == nominee.Id &&
                        r.CategoryId == draft.CategoryId &&
                        r.Status == GoldenRecognitionStatus.Pending);

                    if (duplicatePending)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.DuplicatePending);
                    }

                    created = new GoldenRecognition
                    {
                        NomineeUserId = nominee.Id,
                        NominatorUserId = nominator.Id,
                        CategoryId = draft.CategoryId,
                        Reason = draft.Reason,
                        Status = GoldenRecognitionStatus.Pending,
                        Visibility = draft.Visibility,
                        PointsAssigned = null, // los asigna la aprobación (parte 2)
                        CreatedDate = DateTime.UtcNow,
                        CreatedBy = currentUserEmail,
                    };

                    await recognitions.AddAsync(created);
                    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenRecognitionDto()); // provisional: aún no hay Id
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.UnexpectedError);

            if (created is null || response.HasError)
            {
                return response;
            }

            // El helper ya guardó: se lee con nombres y categoría, y se responde con el Id real.
            var row = await _queryRepository.GetRowAsync(created.Id);
            return row is null
                ? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.UnexpectedError)
                : ResponseDtoHelper.CreateSuccessResponseDto(GoldenRecognitionMapper.ToDto(row, includePoints: false));
        }

        // ── Lecturas paginadas ──────────────────────────────────────────

        public async Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>> GetSentAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail)
        {
            var userId = await _queryRepository.GetUserIdByEmailAsync(currentUserEmail);
            if (userId is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>(GoldenRecognitionConstants.UserNotRegistered);
            }

            var (page, pageSize) = GoldenRecognitionValidator.Paging(query);
            var result = await _queryRepository.GetSentPageAsync(userId.Value, page, pageSize);

            // Quien reconoce ve el estado, pero no los puntos de su compañero.
            return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(
                result.Rows.Select(row => GoldenRecognitionMapper.ToDto(row, includePoints: false)),
                page, pageSize, result.TotalCount));
        }

        public async Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>> GetReceivedAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail)
        {
            var userId = await _queryRepository.GetUserIdByEmailAsync(currentUserEmail);
            if (userId is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionDto>>(GoldenRecognitionConstants.UserNotRegistered);
            }

            var (page, pageSize) = GoldenRecognitionValidator.Paging(query);
            var result = await _queryRepository.GetReceivedPageAsync(userId.Value, page, pageSize);

            // Son suyos: aquí sí ve los puntos.
            return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(
                result.Rows.Select(row => GoldenRecognitionMapper.ToDto(row, includePoints: true)),
                page, pageSize, result.TotalCount));
        }

        public async Task<ResponseDto<GoldenPagedResultDto<GoldenRecognitionFeedItemDto>>> GetFeedAsync(GoldenRecognitionPageQueryDto query, string currentUserEmail)
        {
            var userId = await _queryRepository.GetUserIdByEmailAsync(currentUserEmail);
            if (userId is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenRecognitionFeedItemDto>>(GoldenRecognitionConstants.UserNotRegistered);
            }

            var (page, pageSize) = GoldenRecognitionValidator.Paging(query);
            var result = await _queryRepository.GetFeedPageAsync(query.CategoryId, page, pageSize);

            var ids = result.Rows.Select(row => row.Id).ToList();
            var summaries = await BuildReactionSummariesAsync(ids, userId.Value);

            return ResponseDtoHelper.CreateSuccessResponseDto(ToPage(
                result.Rows.Select(row => GoldenRecognitionMapper.ToFeedItem(row, summaries[row.Id])),
                page, pageSize, result.TotalCount));
        }

        // ── Reacciones ──────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenReactionSummaryDto>> GetReactionsAsync(int recognitionId, string currentUserEmail)
        {
            var userId = await _queryRepository.GetUserIdByEmailAsync(currentUserEmail);
            if (userId is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.UserNotRegistered);
            }

            var row = await _queryRepository.GetRowAsync(recognitionId);
            if (row is null || !IsInFeed(row.Status, row.Visibility))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.RecognitionNotInFeed);
            }

            var summaries = await BuildReactionSummariesAsync([recognitionId], userId.Value);
            return ResponseDtoHelper.CreateSuccessResponseDto(summaries[recognitionId]);
        }

        /// <summary>Idempotente: si ya había reaccionado con ese tipo, no cambia nada.</summary>
        public async Task<ResponseDto<GoldenReactionSummaryDto>> AddReactionAsync(int recognitionId, string reactionType, string currentUserEmail)
        {
            if (!GoldenRecognitionCodes.TryParseReaction(reactionType, out var type))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.ReactionInvalid);
            }

            int? userId = null;

            try
            {
                var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenReactionSummaryDto>>(
                    async unitOfWork =>
                    {
                        var user = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                        if (user is null)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.UserNotRegistered);
                        }

                        userId = user.Id;

                        var recognition = await unitOfWork.Repository<GoldenRecognition>().GetByIdAsync(recognitionId);
                        if (recognition is null || !IsInFeed(recognition.Status, recognition.Visibility))
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.RecognitionNotInFeed);
                        }

                        var reactions = unitOfWork.Repository<GoldenRecognitionReaction>();
                        var alreadyThere = await reactions.AnyAsync(x =>
                            x.RecognitionId == recognitionId && x.UserId == user.Id && x.ReactionType == type);

                        if (!alreadyThere)
                        {
                            await reactions.AddAsync(new GoldenRecognitionReaction
                            {
                                RecognitionId = recognitionId,
                                UserId = user.Id,
                                ReactionType = type,
                                CreatedDate = DateTime.UtcNow,
                            });
                        }

                        return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenReactionSummaryDto()); // se arma después de guardar
                    }
                ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.UnexpectedError);

                if (response.HasError)
                {
                    return response;
                }
            }
            catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException && userId is not null)
            {
                // Doble clic: otra petición insertó la misma reacción y chocó con el índice único.
                // Si la reacción existe, el resultado es el que el usuario quería; si no, el error era otro.
                var mine = await _queryRepository.GetUserReactionsAsync([recognitionId], userId.Value);
                if (!mine.Any(x => x.ReactionType == type))
                {
                    throw;
                }
            }

            var summaries = await BuildReactionSummariesAsync([recognitionId], userId!.Value);
            return ResponseDtoHelper.CreateSuccessResponseDto(summaries[recognitionId]);
        }

        /// <summary>Idempotente: si no había reaccionado con ese tipo, no cambia nada.</summary>
        public async Task<ResponseDto<GoldenReactionSummaryDto>> RemoveReactionAsync(int recognitionId, string reactionType, string currentUserEmail)
        {
            if (!GoldenRecognitionCodes.TryParseReaction(reactionType, out var type))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.ReactionInvalid);
            }

            int? userId = null;

            var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenReactionSummaryDto>>(
                async unitOfWork =>
                {
                    var user = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                    if (user is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.UserNotRegistered);
                    }

                    userId = user.Id;

                    var reactions = unitOfWork.Repository<GoldenRecognitionReaction>();
                    var existing = await reactions.GetListAsync(x =>
                        x.RecognitionId == recognitionId && x.UserId == user.Id && x.ReactionType == type);

                    // Delete por entidad, no DeleteRangeAsync (ese guarda por su cuenta).
                    foreach (var reaction in existing)
                    {
                        reactions.Delete(reaction);
                    }

                    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenReactionSummaryDto());
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenReactionSummaryDto>(GoldenRecognitionConstants.UnexpectedError);

            if (response.HasError || userId is null)
            {
                return response;
            }

            var summaries = await BuildReactionSummariesAsync([recognitionId], userId.Value);
            return ResponseDtoHelper.CreateSuccessResponseDto(summaries[recognitionId]);
        }

        // ── Privados ────────────────────────────────────────────────────

        private static bool IsInFeed(GoldenRecognitionStatus status, GoldenRecognitionVisibility visibility) =>
            status == GoldenRecognitionStatus.Approved && visibility == GoldenRecognitionVisibility.Public;

        /// <summary>Usuario de dbo.users por el correo del token. Mismo criterio que Request.</summary>
        private static async Task<User?> FindUserByEmailAsync(IUnitOfWork unitOfWork, string email) =>
            (await unitOfWork.Repository<User>().GetListAsync(u => u.CorportativeEmail == email)).FirstOrDefault();

        /// <summary>Conteos y "mis reacciones" de varios reconocimientos con dos consultas en total.</summary>
        private async Task<Dictionary<int, GoldenReactionSummaryDto>> BuildReactionSummariesAsync(IReadOnlyCollection<int> recognitionIds, int userId)
        {
            var counts = await _queryRepository.GetReactionCountsAsync(recognitionIds);
            var mine = await _queryRepository.GetUserReactionsAsync(recognitionIds, userId);

            return recognitionIds.Distinct().ToDictionary(
                id => id,
                id => GoldenRecognitionMapper.ToReactionSummary(
                    id,
                    counts,
                    mine.Where(x => x.RecognitionId == id).Select(x => x.ReactionType)));
        }

        private static GoldenPagedResultDto<T> ToPage<T>(IEnumerable<T> items, int page, int pageSize, int totalCount) => new()
        {
            Items = items.ToList(),
            Page = page,
            PageSize = pageSize,
            TotalCount = totalCount,
        };
    }
}
```

**Notas del servicio**

- **Usuario activo.** `FindUserByEmailAsync` busca por `corporative_email`. Si en tu proyecto `RequestService.GetActiveUserAsync` filtra además por usuario activo, usa el mismo filtro aquí y en `GetUserIdByEmailAsync`.
- **`IUnitOfWork`** se usa como tipo del parámetro en `FindUserByEmailAsync`; está en `DOCCB.Application.Contracts.Persistence`.
- **Lecturas sin helper.** El repositorio de consultas usa el `DbContext` de la petición. Lee lo que ya está guardado: después de un `ExecuteWithTransactionAsync`, el cambio ya tiene commit.

---

## 9. Paso 6 — Controlador

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenRecognitionsErrorMessage = "No se pudo completar la operación con los reconocimientos.";
```

### `Controllers/GoldenRecognitionsController.cs`

El patrón de `RequestController`: **cada acción con su `try/catch` completo**. No se usa un método privado que lo comparta (la primera versión tenía `HandleAsync` y se reemplazó; ver [convenciones](.claude/convenciones-backend-doccb.md), regla 18).

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: reconocimientos del colaborador (crear, enviados, recibidos, feed, reacciones).</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class GoldenRecognitionsController(IGoldenRecognitionService service) : ControllerBase
    {
        private readonly IGoldenRecognitionService _service = service;

        /// <summary>Crear reconocimiento (pestaña "Reconocer"). Nace Pendiente.</summary>
        [HttpPost]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Create([FromBody] CreateGoldenRecognitionDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.CreateAsync(dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
            }
        }

        /// <summary>Los que creé, todos los estados. GET sent?page=1&amp;pageSize=10</summary>
        [HttpGet("sent")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetSent([FromQuery] GoldenRecognitionPageQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetSentAsync(query, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
            }
        }

        /// <summary>"Mis reconocimientos": los aprobados que recibí. GET received?page=1&amp;pageSize=10</summary>
        [HttpGet("received")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetReceived([FromQuery] GoldenRecognitionPageQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetReceivedAsync(query, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
            }
        }

        /// <summary>Feed público. GET feed?page=1&amp;pageSize=10&amp;categoryId=</summary>
        [HttpGet("feed")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetFeed([FromQuery] GoldenRecognitionPageQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetFeedAsync(query, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
            }
        }

        /// <summary>Conteo de reacciones de un reconocimiento del feed.</summary>
        [HttpGet("{id:int}/reactions")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetReactions(int id)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetReactionsAsync(id, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
            }
        }

        /// <summary>Agregar reacción (idempotente). PUT {id}/reactions/Aplauso</summary>
        [HttpPut("{id:int}/reactions/{reactionType}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> AddReaction(int id, string reactionType)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.AddReactionAsync(id, reactionType, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
            }
        }

        /// <summary>Quitar reacción (idempotente). DELETE {id}/reactions/Aplauso</summary>
        [HttpDelete("{id:int}/reactions/{reactionType}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> RemoveReaction(int id, string reactionType)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.RemoveReactionAsync(id, reactionType, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
            }
        }
    }
}
```

### Registro — `ApplicationServiceRegistration.cs`

```csharp
services.AddScoped<IGoldenRecognitionService, GoldenRecognitionService>();
```

### El selector "Colaborador reconocido"

El formulario necesita buscar personas. Usa el buscador de usuarios que ya existe (`IUserSearchRepository.SearchAsync`, expuesto en `GET /api/users/search?term=`). Si ese endpoint no está en tu proyecto, es una acción más en `UserController` con el mismo patrón. Lo que se envía en `nomineeUserId` es el `id` de `dbo.users`.

---

## 10. Contrato (para el frontend)

Todas las respuestas: `{ response, hasError, errors }`. Errores de negocio con HTTP 200 y `hasError: true`; `401` sin usuario.

| Método | Ruta | Cuerpo / query | `response` |
|---|---|---|---|
| `POST` | `/api/GoldenRecognitions` | `{ nomineeEmail, categoryId, reason, visibility? }` (o `nomineeUserId` en lugar del correo) | El reconocimiento creado, `status: "Pendiente"` |
| `GET` | `/api/GoldenRecognitions/sent` | `?page=1&pageSize=10` | Página de `GoldenRecognitionDto` (sin puntos) |
| `GET` | `/api/GoldenRecognitions/received` | `?page=1&pageSize=10` | Página de `GoldenRecognitionDto` (con puntos), solo aprobados |
| `GET` | `/api/GoldenRecognitions/feed` | `?page=1&pageSize=10&categoryId=` | Página de `GoldenRecognitionFeedItemDto` (sin puntos, con reacciones) |
| `GET` | `/api/GoldenRecognitions/{id}/reactions` | — | `GoldenReactionSummaryDto` |
| `PUT` | `/api/GoldenRecognitions/{id}/reactions/{tipo}` | tipo: `Like`, `Aplauso`, `Inspirador`, `Orgullo` | `GoldenReactionSummaryDto` actualizado |
| `DELETE` | `/api/GoldenRecognitions/{id}/reactions/{tipo}` | igual | `GoldenReactionSummaryDto` actualizado |

Crear:

```json
POST /api/GoldenRecognitions
{
  "nomineeEmail": "laura.salazar@empresa.com",
  "categoryId": 2,
  "reason": "Lideró la estrategia comercial de temporada con impacto destacado.",
  "visibility": "Publica"
}
```

Página del feed:

```json
{
  "response": {
    "items": [
      {
        "id": 7,
        "nominee": { "id": 42, "name": "Laura Salazar", "email": "laura.salazar@empresa.com", "area": "Comercial" },
        "nominatedBy": { "id": 15, "name": "David Pérez", "email": "david.perez@empresa.com", "area": "Comercial" },
        "reason": "Lideró la estrategia comercial de temporada con impacto destacado.",
        "categoryId": 2,
        "categoryName": "Cumplimiento",
        "categoryIcon": "fa-solid fa-circle-check",
        "categoryColor": "#16A34A",
        "createdAt": "2026-05-18T14:02:11",
        "approvedAt": "2026-05-20T09:30:00",
        "reactions": {
          "recognitionId": 7,
          "counts": { "Like": 1, "Aplauso": 0, "Inspirador": 0, "Orgullo": 0 },
          "myReactions": ["Like"],
          "total": 1
        }
      }
    ],
    "page": 1,
    "pageSize": 10,
    "totalCount": 1,
    "totalPages": 1
  },
  "hasError": false,
  "errors": []
}
```

Un ítem de "Mis reconocimientos" (`received`):

```json
{
  "id": 3,
  "nominee": { "id": 20, "name": "Daniela Torres", "email": "daniela.torres@empresa.com", "area": "Operaciones" },
  "nominatedBy": { "id": 9, "name": "Natalia Gómez", "email": "natalia.gomez@empresa.com", "area": "Operaciones" },
  "reason": "Coordinó de forma sobresaliente el despliegue de una mejora crítica para la operación.",
  "categoryId": 3,
  "categoryName": "Reconocimiento",
  "categoryIcon": "fa-solid fa-medal",
  "categoryColor": "#EA580C",
  "status": "Aprobada",
  "visibility": "Publica",
  "pointsAssigned": 150,
  "createdAt": "2026-06-02T10:15:00",
  "reviewedAt": "2026-06-03T08:00:00"
}
```

**Fechas en UTC.** `createdAt`, `approvedAt` y `reviewedAt` vienen en UTC y sin la `Z` final. En el mapper del frontend hay que agregarla antes de mostrarlas; si no, el navegador las toma como hora local (5 horas de diferencia).

**Ajustes al modelo del frontend** (`puntos-dorados.ts`), cuando se haga la pantalla:

- `GoldenPerson.id` pasa a `number`.
- `GoldenNomination` suma `categoryIcon` y `categoryColor`.
- Nuevo tipo para la tarjeta del feed, con `reactions` y sin puntos.
- Las fechas llegan como texto ISO: convertirlas a `Date` en el mapper.

---

## 11. Parte 2 (siguiente)

| Pieza | Qué falta |
|---|---|
| **Aprobaciones** | Aprobar o rechazar, asignar `points_assigned`, `reviewed_date` / `reviewed_by`, y los comentarios de aprobación (tabla `golden_recognition_comment`). |
| **Puntos y vencimiento** | Al aprobar con puntos, crear el "bucket" de puntos con su fecha de vencimiento (`GoldenPointsBucket`). Eso alimenta "Vencimiento de puntos" en "Mis reconocimientos". |
| **Notificaciones** | Avisar a Compensación y Beneficios de un reconocimiento nuevo, y a la persona cuando se aprueba (con el log de correos). |
| **Detalle por id** | `GET /api/GoldenRecognitions/{id}` para abrir un reconocimiento desde una notificación. |

---

## 12. Pruebas

**Crear**
- Motivo con 14 caracteres → `hasError`; con 15 → se crea **Pendiente** y la respuesta trae el `id` real.
- Reconocerse a sí mismo → `hasError`.
- Categoría inactiva → `hasError`.
- Dos veces seguidas a la misma persona en la misma categoría → la segunda `hasError` (pendiente duplicado); en otra categoría → se crea.
- Usuario del token que no está en `dbo.users` → el mensaje de "Mis Datos".

**Listas**
- `sent` → mis reconocimientos en todos los estados, el más nuevo primero, **sin** `pointsAssigned`.
- `received` → solo **aprobados** que recibí, con puntos; un pendiente que recibí no aparece.
- `feed` → solo aprobados **y** públicos; un aprobado privado no aparece; el JSON no tiene ningún campo de puntos.
- Aprobar con el SQL de prueba uno creado antes que otros → en el feed sale primero (orden por aprobación).
- `page=2&pageSize=5` con 12 aprobados → 5 ítems, `totalCount: 12`, `totalPages: 3`.
- `pageSize=500` → se ajusta a 50.

**Reacciones**
- `PUT …/reactions/Aplauso` dos veces → `counts.Aplauso` = 1 y `myReactions` lo incluye.
- `PUT Like` + `PUT Orgullo` → `total: 2`, `myReactions: ["Like", "Orgullo"]`.
- `DELETE …/reactions/Like` sin haber reaccionado → éxito, sin cambios.
- Tipo `Corazon` → `hasError`.
- Reaccionar a un reconocimiento pendiente o privado → `hasError`.
- Dos `PUT` simultáneos del mismo tipo (doble clic) → los dos responden éxito y queda **una** fila.

---

## ✅ Checklist

- [ ] `GoldenPointsRecognitions.sql` ejecutado (después de las categorías).
- [ ] Enums en `DOCCB.Domain/Enum`, entidades sin `BaseEntity`, configuraciones con conversión a códigos en mayúsculas.
- [ ] Dos `DbSet` en `DOCCbDbContext`.
- [ ] Proyección con `DisplayName` y `CorportativeEmail` (no admite nulos) y `Area` vacía (`User` no tiene área).
- [ ] Controlador con `try/catch` completo en cada acción.
- [ ] `IGoldenRecognitionQueryRepository` registrado en `InfrastructureServiceRegistration.cs`; `IGoldenRecognitionService` en `ApplicationServiceRegistration.cs`.
- [ ] El feed nunca devuelve puntos; "enviados" tampoco.
- [ ] Reacciones idempotentes y prueba de doble clic hecha.
- [ ] Selector de personas conectado al buscador de usuarios existente.
- [ ] Fechas tratadas como UTC en el frontend.
