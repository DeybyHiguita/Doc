# 🗄️ Cursos — API (.NET 8) y base de datos (SQL Server)

Guía paso a paso para construir el backend del módulo de **Cursos** en DOCCB, siguiendo la arquitectura de `DOCCB Backend`. Es el backend que consumen [crud-cursos-angular.md](crud-cursos-angular.md) y [listado-cursos-angular.md](listado-cursos-angular.md).

- **Stack:** .NET 8 · ASP.NET Core · Entity Framework Core 8 · SQL Server
- **Base de datos:** `DB` · esquema `dbo` · tablas y atributos en inglés y `snake_case` (`dbo.table_name`, `column_name`)
- **Proyectos:** `WebApp` · `DOCCB.Application` · `DOCCB.Domain` · `DOCCB.Infraestructure`

> ⚠️ **Actualizado por [cursos-grupos-finalizacion-api-sqlserver.md](cursos-grupos-finalizacion-api-sqlserver.md).** Ahora un curso se asigna a **grupos de usuarios** (cada uno con su fecha límite) y cada persona tiene estado y formulario de finalización. De esta guía siguen vigentes `dbo.course`, la entidad `Course`, el ID externo, el listado y `BusinessDate`. `dbo.course_assignment` (ahora con `user_group_id`) y `dbo.course_assignment_user` se conservan con los ajustes de índices de la guía nueva; sus DTOs y la parte de asignaciones de `CourseService` y `CourseRepository` se reemplazan por los de esa guía.

---

## 1. 🧐 Decisiones de diseño

| # | Tema | Decisión |
|---|---|---|
| 1 | **Convención de nombres.** La base de datos usa inglés y `snake_case` (`dbo.course`, `due_date`); las entidades C# usan inglés y PascalCase, como el resto de DOCCB. | La configuración de EF Core traduce cada propiedad a su columna con `ToTable` y `HasColumnName`. El código no cambia de estilo y la base de datos respeta su convención. |
| 2 | **De dónde salen los usuarios.** La guía de Angular proponía Microsoft Graph, pero DOCCB ya tiene su tabla de usuarios (`dbo.users`) con carga masiva. | Se asigna contra `dbo.users` con una llave foránea real: sin permisos de Graph y sin copias de nombres que se desactualizan. Si hay empleados que no están en esa tabla, vuelve a Graph (sección 12). |
| 3 | **"Hoy" depende del servidor.** Si el servidor corre en UTC, entre las 7 p. m. y la medianoche de Colombia ya es "mañana" y una fecha de hoy se rechaza como pasada. | "Hoy" se calcula siempre en la zona `America/Bogota`. |
| 4 | **Duplicados por carrera.** Validar en el servicio no basta: dos personas pueden guardar el mismo nombre al mismo tiempo. | Índices únicos filtrados en la base de datos. El servicio valida primero para dar un buen mensaje, y si aun así el índice rechaza, responde `409` con el mismo mensaje. |
| 5 | **Eliminar un curso con usuarios** borra el historial de quién debía tomarlo. | Si tiene grupos asignados, borrado lógico (`removed = 1`, igual que `Removed` en `Request`). Si no tiene, borrado físico. |
| 6 | **El repositorio genérico no alcanza.** `IGenericRepository<T>` no expresa listados paginados con subconsultas ni cargas con `ThenInclude`. | Repositorio propio `ICourseRepository` en `Contracts/Persistence`, implementado en `Infraestructure`. Mismo patrón que el resto: interfaz en Application, implementación en Infraestructura, sin saltarse capas. |
| 7 | **Modalidad.** Un entero en la base de datos no se entiende al consultarla a mano. | Se guarda como texto (`VIRTUAL`, `PRESENCIAL`) con `CHECK`. En C# es un `enum`. |
| 8 | **Integridad grupo ↔ curso.** Un usuario podría quedar ligado a un grupo de otro curso por un error de código. | La tabla de usuarios lleva `course_id` y una llave foránea compuesta `(assignment_id, course_id)`: la base de datos no permite esa inconsistencia. |
| 9 | **Fuente del esquema.** DOCCB versiona scripts en `Persistence/Scripts SQL`. | El script SQL crea las tablas; la configuración de EF solo las describe. Si el equipo usa migraciones, genera la migración y compárala con el script antes de aplicarla. |

---

## 2. 📁 Archivos

```text
DOCCB.Domain/
├── Entities/
│   ├── Course.cs
│   ├── CourseAssignment.cs
│   └── CourseAssignmentUser.cs
└── Enum/
    └── CourseModality.cs

DOCCB.Application/
├── Contracts/Persistence/
│   ├── ICourseRepository.cs                      ⭐ contrato de datos de cursos
│   ├── IUserSearchRepository.cs                  búsqueda de usuarios
│   └── DuplicateKeyException.cs
├── Features/Courses/Application/
│   ├── Constants/
│   │   ├── CourseConstants.cs                    límites y mensajes
│   │   └── CourseIndexNames.cs                   nombres de los índices únicos
│   ├── DTOs/
│   │   ├── CourseQueryDto.cs                     filtros del listado (query string)
│   │   ├── CourseListDtos.cs                     listado + indicadores
│   │   ├── CourseDetailDtos.cs                   detalle con grupos y usuarios
│   │   ├── SaveCourseRequestDto.cs               crear / actualizar
│   │   └── CourseResult.cs                       resultado + tipo de error (404, 409, 400)
│   ├── Helpers/
│   │   ├── CourseModalityCodes.cs                enum ⇄ "VIRTUAL" / "PRESENCIAL"
│   │   ├── BusinessDate.cs                       "hoy" en hora de Colombia
│   │   └── CourseValidationHelper.cs             ⭐ reglas de formato
│   ├── Interfaces/ICourseService.cs
│   └── Services/CourseService.cs                 ⭐ reglas de negocio
└── Features/Users/Application/
    ├── DTOs/UserSearchResultDto.cs
    └── (IUserService + UserService: método SearchAsync)

DOCCB.Infraestructure/
├── Configurations/
│   ├── CourseConfiguration.cs
│   ├── CourseAssignmentConfiguration.cs
│   └── CourseAssignmentUserConfiguration.cs
├── Persistence/
│   ├── Models/DOCCbDbContext.cs                  (+3 ApplyConfiguration)
│   └── Scripts SQL/Cursos.sql                    ⭐ creación de tablas
└── Repositories/
    ├── CourseRepository.cs
    └── UserSearchRepository.cs

WebApp/Controllers/
├── CoursesController.cs                          ⭐ /api/courses
└── UserController.cs                             (+ GET /api/users/search)
```

---

## 3. Paso 1 — 🗄️ Base de datos

### Modelo

```text
dbo.users (existente)
     ▲
     │ user_id
     │
dbo.course ──< dbo.course_assignment ──< dbo.course_assignment_user
  id             id                        assignment_id ┐ FK compuesta a
  name           course_id ────────────────course_id     ┘ (id, course_id)
  modality       due_date                  user_id
  external_id
  removed
```

| Tabla | Qué guarda |
|---|---|
| `dbo.course` | El curso: nombre, modalidad, ID del sistema externo y auditoría. |
| `dbo.course_assignment` | Un **grupo** de asignación del curso, con su fecha límite. Un curso puede tener varios. |
| `dbo.course_assignment_user` | Qué usuarios están en cada grupo. Un usuario solo puede estar en un grupo por curso. |

### `Persistence/Scripts SQL/Cursos.sql`

```sql
/* =====================================================================
   Módulo de Cursos
   Base de datos: DB · Esquema: dbo
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

-- Obligatorios para crear y usar índices filtrados.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.course
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course
    (
        id           INT            IDENTITY(1, 1) NOT NULL,
        name         NVARCHAR(150)  NOT NULL,
        modality     VARCHAR(20)    NOT NULL,
        external_id  VARCHAR(50)    NULL,
        removed      BIT            NOT NULL CONSTRAINT df_course_removed DEFAULT (0),
        created_date DATETIME2(0)   NOT NULL CONSTRAINT df_course_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)  NOT NULL,
        updated_date DATETIME2(0)   NULL,
        updated_by   NVARCHAR(150)  NULL,

        CONSTRAINT pk_course PRIMARY KEY CLUSTERED (id),
        CONSTRAINT ck_course_name CHECK (LEN(LTRIM(name)) > 0),
        CONSTRAINT ck_course_modality CHECK (modality IN ('VIRTUAL', 'PRESENCIAL')),
        CONSTRAINT ck_course_external_id CHECK (external_id IS NULL OR (LEN(external_id) > 0 AND CHARINDEX(' ', external_id) = 0))
    );

    -- El mismo nombre puede existir en las dos modalidades, pero no dos veces en la misma.
    -- Solo cuenta entre cursos no eliminados: un nombre borrado se puede volver a usar.
    CREATE UNIQUE INDEX ux_course_name_modality
        ON dbo.course (name, modality)
        WHERE removed = 0;

    -- Un ID del sistema externo pertenece a un solo curso.
    CREATE UNIQUE INDEX ux_course_external_id
        ON dbo.course (external_id)
        WHERE external_id IS NOT NULL;
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.course_assignment — grupos con fecha límite
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_assignment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_assignment
    (
        id           INT            IDENTITY(1, 1) NOT NULL,
        course_id    INT            NOT NULL,
        due_date     DATE           NOT NULL,
        created_date DATETIME2(0)   NOT NULL CONSTRAINT df_course_assignment_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)  NOT NULL,

        CONSTRAINT pk_course_assignment PRIMARY KEY CLUSTERED (id),
        -- (id, course_id) permite que la tabla de usuarios garantice que el grupo es de ese curso.
        CONSTRAINT uq_course_assignment_id_course_id UNIQUE (id, course_id),
        CONSTRAINT fk_course_assignment_course FOREIGN KEY (course_id) REFERENCES dbo.course (id)
    );

    CREATE INDEX ix_course_assignment_course_id
        ON dbo.course_assignment (course_id)
        INCLUDE (due_date);
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.course_assignment_user — usuarios de cada grupo
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_assignment_user', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_assignment_user
    (
        assignment_id INT            NOT NULL,
        course_id     INT            NOT NULL,
        user_id       INT            NOT NULL,
        created_date  DATETIME2(0)   NOT NULL CONSTRAINT df_course_assignment_user_created_date DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT pk_course_assignment_user PRIMARY KEY CLUSTERED (assignment_id, user_id),
        CONSTRAINT fk_course_assignment_user_assignment
            FOREIGN KEY (assignment_id, course_id)
            REFERENCES dbo.course_assignment (id, course_id)
            ON DELETE CASCADE,
        CONSTRAINT fk_course_assignment_user_user
            FOREIGN KEY (user_id)
            REFERENCES dbo.users (id)
    );

    -- Un usuario solo puede estar en un grupo por curso.
    CREATE UNIQUE INDEX ux_course_assignment_user_course_user
        ON dbo.course_assignment_user (course_id, user_id);

    -- "¿En qué cursos está este usuario?"
    CREATE INDEX ix_course_assignment_user_user_id
        ON dbo.course_assignment_user (user_id);
END;
GO
```

> ⚠️ Confirma el nombre real de la tabla de usuarios y de su llave (`dbo.users`, `id`) antes de ejecutar. Si la base de datos no se llama `DB`, cambia el `USE`.

### Consultas de verificación

Útiles para revisar los datos a mano o para agregarlas a `Consultas Comunes.sql`:

```sql
DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'SA Pacific Standard Time' AS DATE);

-- Cursos activos con usuarios asignados y próxima fecha límite
SELECT  c.id,
        c.name,
        c.modality,
        c.external_id,
        assigned_users = (SELECT COUNT(*) FROM dbo.course_assignment_user u WHERE u.course_id = c.id),
        next_due_date  = COALESCE(
                               (SELECT MIN(a.due_date) FROM dbo.course_assignment a WHERE a.course_id = c.id AND a.due_date >= @today),
                               (SELECT MAX(a.due_date) FROM dbo.course_assignment a WHERE a.course_id = c.id AND a.due_date < @today))
FROM    dbo.course c
WHERE   c.removed = 0
ORDER BY c.name;

-- Cursos virtuales sin ID externo (los "pendientes")
SELECT id, name FROM dbo.course
WHERE  removed = 0 AND modality = 'VIRTUAL' AND external_id IS NULL;
```

---

## 4. Paso 2 — Dominio

### `DOCCB.Domain/Enum/CourseModality.cs`

```csharp
namespace DOCCB.Domain.Enum;

public enum CourseModality
{
    Virtual = 1,
    Presencial = 2
}
```

### `DOCCB.Domain/Entities/Course.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities;

public class Course : BaseEntity
{
    public string Name { get; set; } = string.Empty;
    public CourseModality Modality { get; set; }
    public string? ExternalId { get; set; }
    public bool Removed { get; set; }

    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? UpdatedDate { get; set; }
    public string? UpdatedBy { get; set; }

    public ICollection<CourseAssignment> Assignments { get; set; } = new List<CourseAssignment>();
}
```

### `DOCCB.Domain/Entities/CourseAssignment.cs`

```csharp
namespace DOCCB.Domain.Entities;

public class CourseAssignment : BaseEntity
{
    public int CourseId { get; set; }
    public DateOnly DueDate { get; set; }
    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;

    public Course Course { get; set; } = null!;
    public ICollection<CourseAssignmentUser> Users { get; set; } = new List<CourseAssignmentUser>();
}
```

### `DOCCB.Domain/Entities/CourseAssignmentUser.cs`

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>Llave compuesta (AssignmentId, UserId): no hereda de BaseEntity.</summary>
public class CourseAssignmentUser
{
    public int AssignmentId { get; set; }
    public int CourseId { get; set; }
    public int UserId { get; set; }
    public DateTime CreatedDate { get; set; }

    public CourseAssignment Assignment { get; set; } = null!;
    public User User { get; set; } = null!;
}
```

> Si `BaseEntity` o `TrazabilityEntity` ya declaran `Removed`, `CreatedDate`, `CreatedBy`, `UpdatedDate` o `UpdatedBy`, hereda de esa clase y borra aquí las propiedades repetidas. La configuración del paso 3 las mapea igual, porque se refiere a ellas por nombre.

---

## 5. Paso 3 — Configuración de EF Core

Aquí se traduce PascalCase a `snake_case`. Los nombres de índices y llaves son **los mismos del script**: así un error de la base de datos se puede reconocer por su nombre.

### `Features/Courses/Application/Constants/CourseIndexNames.cs`

Va en Application porque el servicio los usa para traducir un duplicado a un mensaje; la configuración de Infraestructura los reutiliza.

```csharp
namespace DOCCB.Application.Features.Courses.Application.Constants;

public static class CourseIndexNames
{
    public const string NameModality = "ux_course_name_modality";
    public const string ExternalId = "ux_course_external_id";
    public const string CourseUser = "ux_course_assignment_user_course_user";

    public static readonly string[] All = [NameModality, ExternalId, CourseUser];
}
```

### `DOCCB.Infraestructure/Configurations/CourseConfiguration.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class CourseConfiguration : IEntityTypeConfiguration<Course>
{
    public void Configure(EntityTypeBuilder<Course> builder)
    {
        builder.ToTable("course", "dbo", table =>
        {
            table.HasCheckConstraint("ck_course_name", "LEN(LTRIM(name)) > 0");
            table.HasCheckConstraint("ck_course_modality", "modality IN ('VIRTUAL', 'PRESENCIAL')");
            table.HasCheckConstraint("ck_course_external_id",
                "external_id IS NULL OR (LEN(external_id) > 0 AND CHARINDEX(' ', external_id) = 0)");
        });

        builder.HasKey(c => c.Id).HasName("pk_course");

        builder.Property(c => c.Id).HasColumnName("id");
        builder.Property(c => c.Name).HasColumnName("name").HasMaxLength(150).IsRequired();

        // En la BD se guarda "VIRTUAL" / "PRESENCIAL"; en C# es un enum.
        builder.Property(c => c.Modality)
            .HasColumnName("modality")
            .HasMaxLength(20)
            .IsUnicode(false)
            .HasConversion(
                modality => modality.ToString().ToUpperInvariant(),
                code => Enum.Parse<CourseModality>(code, true));

        builder.Property(c => c.ExternalId).HasColumnName("external_id").HasMaxLength(50).IsUnicode(false);
        builder.Property(c => c.Removed).HasColumnName("removed");
        builder.Property(c => c.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(c => c.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
        builder.Property(c => c.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
        builder.Property(c => c.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

        builder.HasIndex(c => new { c.Name, c.Modality })
            .IsUnique()
            .HasFilter("[removed] = 0")
            .HasDatabaseName(CourseIndexNames.NameModality);

        builder.HasIndex(c => c.ExternalId)
            .IsUnique()
            .HasFilter("[external_id] IS NOT NULL")
            .HasDatabaseName(CourseIndexNames.ExternalId);

        builder.HasMany(c => c.Assignments)
            .WithOne(a => a.Course)
            .HasForeignKey(a => a.CourseId)
            .HasConstraintName("fk_course_assignment_course")
            .OnDelete(DeleteBehavior.Restrict);
    }
}
```

### `DOCCB.Infraestructure/Configurations/CourseAssignmentConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class CourseAssignmentConfiguration : IEntityTypeConfiguration<CourseAssignment>
{
    public void Configure(EntityTypeBuilder<CourseAssignment> builder)
    {
        builder.ToTable("course_assignment", "dbo");

        builder.HasKey(a => a.Id).HasName("pk_course_assignment");

        // Llave alterna (id, course_id): destino de la FK compuesta de los usuarios.
        builder.HasAlternateKey(a => new { a.Id, a.CourseId }).HasName("uq_course_assignment_id_course_id");

        builder.Property(a => a.Id).HasColumnName("id");
        builder.Property(a => a.CourseId).HasColumnName("course_id");
        builder.Property(a => a.DueDate).HasColumnName("due_date").HasColumnType("date");
        builder.Property(a => a.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(a => a.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();

        builder.HasIndex(a => a.CourseId).HasDatabaseName("ix_course_assignment_course_id");
    }
}
```

### `DOCCB.Infraestructure/Configurations/CourseAssignmentUserConfiguration.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class CourseAssignmentUserConfiguration : IEntityTypeConfiguration<CourseAssignmentUser>
{
    public void Configure(EntityTypeBuilder<CourseAssignmentUser> builder)
    {
        builder.ToTable("course_assignment_user", "dbo");

        builder.HasKey(u => new { u.AssignmentId, u.UserId }).HasName("pk_course_assignment_user");

        builder.Property(u => u.AssignmentId).HasColumnName("assignment_id");
        builder.Property(u => u.CourseId).HasColumnName("course_id");
        builder.Property(u => u.UserId).HasColumnName("user_id");
        builder.Property(u => u.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");

        // Regla "un usuario, un grupo por curso". Tiene que estar en el modelo, no solo en el script:
        // con él, EF ejecuta el DELETE antes del INSERT cuando alguien se mueve de un grupo a otro.
        builder.HasIndex(u => new { u.CourseId, u.UserId })
            .IsUnique()
            .HasDatabaseName(CourseIndexNames.CourseUser);

        builder.HasIndex(u => u.UserId).HasDatabaseName("ix_course_assignment_user_user_id");

        builder.HasOne(u => u.Assignment)
            .WithMany(a => a.Users)
            .HasForeignKey(u => new { u.AssignmentId, u.CourseId })
            .HasPrincipalKey(a => new { a.Id, a.CourseId })
            .HasConstraintName("fk_course_assignment_user_assignment")
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasOne(u => u.User)
            .WithMany()
            .HasForeignKey(u => u.UserId)
            .HasConstraintName("fk_course_assignment_user_user")
            .OnDelete(DeleteBehavior.Restrict);
    }
}
```

### Registro en `DOCCbDbContext.cs`

```csharp
modelBuilder.ApplyConfiguration(new CourseConfiguration());
modelBuilder.ApplyConfiguration(new CourseAssignmentConfiguration());
modelBuilder.ApplyConfiguration(new CourseAssignmentUserConfiguration());
```

---

## 6. Paso 4 — DTOs

Los nombres coinciden con lo que espera el frontend: ASP.NET Core los serializa en camelCase (`courseId`, `assignedUsersCount`…) y `DateOnly` viaja como `"2026-10-30"`.

### `DTOs/CourseQueryDto.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Courses.Application.DTOs;

/// <summary>Filtros tal como llegan en la query string.</summary>
public class CourseQueryDto
{
    public string? Search { get; set; }
    public string? Modality { get; set; }
    public bool PendingExternalId { get; set; }
    public string? Sort { get; set; }
    public string? Direction { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = CourseConstants.DefaultPageSize;
}

public enum CourseSortField { Name, DueDate }

public enum SortDirection { Asc, Desc }

/// <summary>Filtros ya validados y normalizados: es lo que recibe el repositorio.</summary>
public sealed record CourseListQuery(
    string? Search,
    CourseModality? Modality,
    bool PendingExternalId,
    CourseSortField Sort,
    SortDirection Direction,
    int Page,
    int PageSize);
```

### `DTOs/CourseListDtos.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

public class CourseListItemDto
{
    public int CourseId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Modality { get; set; } = string.Empty;
    public string? ExternalId { get; set; }
    public int AssignedUsersCount { get; set; }
    public DateOnly? NextDueDate { get; set; }
}

public class CourseStatsDto
{
    public int Total { get; set; }
    public int Virtual { get; set; }
    public int Onsite { get; set; }
    public int PendingExternalId { get; set; }
}

public class CoursePageDto
{
    public List<CourseListItemDto> Items { get; set; } = [];
    public int TotalCount { get; set; }
    public CourseStatsDto Stats { get; set; } = new();
}
```

### `DTOs/CourseDetailDtos.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

public class CourseUserDto
{
    /// <summary>Id de dbo.users como texto: el frontend lo trata como identificador opaco.</summary>
    public string UserId { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? JobTitle { get; set; }
}

public class CourseAssignmentDto
{
    public int AssignmentId { get; set; }
    public DateOnly DueDate { get; set; }
    public List<CourseUserDto> Users { get; set; } = [];
}

public class CourseDetailDto
{
    public int CourseId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Modality { get; set; } = string.Empty;
    public string? ExternalId { get; set; }
    public List<CourseAssignmentDto> Assignments { get; set; } = [];
}
```

### `DTOs/SaveCourseRequestDto.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

/// <summary>POST envía la modalidad; PUT la ignora (no se cambia al editar).</summary>
public class SaveCourseRequestDto
{
    public string? Name { get; set; }
    public string? Modality { get; set; }
    public string? ExternalId { get; set; }
    public List<SaveCourseAssignmentDto> Assignments { get; set; } = [];
}

public class SaveCourseAssignmentDto
{
    /// <summary>null = grupo nuevo.</summary>
    public int? AssignmentId { get; set; }
    public DateOnly DueDate { get; set; }
    public List<string> UserIds { get; set; } = [];
}

public class SetExternalIdRequestDto
{
    public string? ExternalId { get; set; }
}
```

### `DTOs/CourseResult.cs`

`ResponseDto<T>` dice si hubo error, pero no **cuál**: el controlador necesita saberlo para responder `404`, `409` o `400`, que es lo que el frontend usa para elegir el mensaje.

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;

namespace DOCCB.Application.Features.Courses.Application.DTOs;

public enum CourseResultStatus
{
    Ok,
    Invalid,
    NotFound,
    Conflict
}

public sealed class CourseResult<T>
{
    public CourseResultStatus Status { get; }
    public ResponseDto<T> Response { get; }

    private CourseResult(CourseResultStatus status, ResponseDto<T> response)
    {
        Status = status;
        Response = response;
    }

    public static CourseResult<T> Ok(T value) =>
        new(CourseResultStatus.Ok, ResponseDtoHelper.CreateSuccessResponseDto(value));

    public static CourseResult<T> Fail(CourseResultStatus status, IEnumerable<string> errors) =>
        new(status, ResponseDtoHelper.CreateErrorResponseDto<T>(errors.ToList()));

    public static CourseResult<T> Fail(CourseResultStatus status, string error) =>
        Fail(status, [error]);
}
```

> Ajusta las llamadas a `ResponseDtoHelper` a sus firmas reales. Si `ResponseDto` ya trae un código de estado, úsalo en lugar de `CourseResultStatus`.

---

## 7. Paso 5 — Constantes y helpers

### `Constants/CourseConstants.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.Constants;

public static class CourseConstants
{
    public const int NameMaxLength = 150;
    public const int ExternalIdMaxLength = 50;
    public const int SearchMaxLength = 100;
    public const int DefaultPageSize = 12;
    public const int MaxPageSize = 50;

    /// <summary>Zona del negocio: define qué día es "hoy" al validar fechas límite.</summary>
    public const string BusinessTimeZoneId = "America/Bogota";

    public const string CourseNotFound = "El curso no existe o fue eliminado.";
    public const string InvalidModality = "La modalidad debe ser VIRTUAL o PRESENCIAL.";
    public const string DuplicateName = "Ya existe un curso con ese nombre en esa modalidad.";
    public const string DuplicateExternalId = "Ese ID externo ya está asignado a otro curso.";
    public const string DuplicatedUser = "Un usuario no puede estar en dos grupos del mismo curso.";
    public const string PastDueDate = "La fecha límite no puede ser una fecha pasada.";
    public const string ExternalIdRequired = "Escribe el ID externo.";
}
```

### `Helpers/CourseModalityCodes.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Courses.Application.Helpers;

/// <summary>Traduce el enum al texto que viaja en la API ("VIRTUAL", "PRESENCIAL") y viceversa.</summary>
public static class CourseModalityCodes
{
    public static string ToCode(CourseModality modality) => modality.ToString().ToUpperInvariant();

    public static bool TryParse(string? code, out CourseModality modality)
    {
        modality = default;
        return !string.IsNullOrWhiteSpace(code)
            && !int.TryParse(code, out _)          // "1" no es una modalidad válida
            && Enum.TryParse(code.Trim(), ignoreCase: true, out modality)
            && Enum.IsDefined(modality);
    }
}
```

### `Helpers/BusinessDate.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;

namespace DOCCB.Application.Features.Courses.Application.Helpers;

/// <summary>
/// "Hoy" en hora de Colombia, sin importar la zona del servidor.
/// En un servidor en UTC, después de las 7 p. m. de Colombia ya sería "mañana".
/// </summary>
public static class BusinessDate
{
    private static readonly TimeZoneInfo Zone =
        TimeZoneInfo.FindSystemTimeZoneById(CourseConstants.BusinessTimeZoneId);

    public static DateOnly Today(TimeProvider time) =>
        DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(time.GetUtcNow(), Zone).DateTime);
}
```

> .NET 8 acepta `America/Bogota` también en Windows. Si el servidor no tiene ICU y falla, usa el identificador de Windows: `SA Pacific Standard Time`.

### `Helpers/CourseValidationHelper.cs` — ⭐ reglas de formato

Solo reglas que no necesitan la base de datos: así se prueban sin montar nada.

```csharp
using System.Text.RegularExpressions;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Helpers;

public sealed record AssignmentDraft(int? AssignmentId, DateOnly DueDate, IReadOnlyList<int> UserIds);

public sealed record CourseDraft(string Name, string? ExternalId, IReadOnlyList<AssignmentDraft> Assignments);

public static partial class CourseValidationHelper
{
    [GeneratedRegex(@"\s")]
    private static partial Regex Whitespace();

    /// <summary>Vacío se normaliza a null. Devuelve los errores encontrados.</summary>
    public static List<string> ValidateExternalId(string? raw, out string? normalized)
    {
        var errors = new List<string>();
        normalized = string.IsNullOrWhiteSpace(raw) ? null : raw.Trim();

        if (normalized is null) return errors;

        if (normalized.Length > CourseConstants.ExternalIdMaxLength)
            errors.Add($"El ID externo no puede tener más de {CourseConstants.ExternalIdMaxLength} caracteres.");

        if (Whitespace().IsMatch(normalized))
            errors.Add("El ID externo no puede tener espacios.");

        return errors;
    }

    /// <summary>Valida el formato y entrega el borrador normalizado, o la lista de errores.</summary>
    public static (CourseDraft? Draft, List<string> Errors) Normalize(SaveCourseRequestDto dto)
    {
        var errors = new List<string>();

        var name = dto.Name?.Trim() ?? string.Empty;
        if (name.Length == 0)
            errors.Add("Escribe el nombre del curso.");
        else if (name.Length > CourseConstants.NameMaxLength)
            errors.Add($"El nombre no puede tener más de {CourseConstants.NameMaxLength} caracteres.");

        errors.AddRange(ValidateExternalId(dto.ExternalId, out var externalId));

        var groups = dto.Assignments ?? [];
        var assignments = new List<AssignmentDraft>();
        var seenUsers = new HashSet<int>();
        var seenGroups = new HashSet<int>();
        var hasDuplicatedUsers = false;

        for (var i = 0; i < groups.Count; i++)
        {
            var group = groups[i];
            var label = $"Grupo {i + 1}";

            if (group.AssignmentId is { } assignmentId && !seenGroups.Add(assignmentId))
                errors.Add($"{label}: el grupo {assignmentId} viene repetido.");

            if (group.DueDate == default)
                errors.Add($"{label}: elige la fecha límite.");

            var userIds = new List<int>();
            foreach (var raw in (group.UserIds ?? []).Distinct())
            {
                if (!int.TryParse(raw, out var userId) || userId <= 0)
                {
                    errors.Add($"{label}: el usuario \"{raw}\" no es válido.");
                    continue;
                }

                if (!seenUsers.Add(userId)) hasDuplicatedUsers = true;
                userIds.Add(userId);
            }

            if (userIds.Count == 0)
                errors.Add($"{label}: agrega al menos un usuario.");

            assignments.Add(new AssignmentDraft(group.AssignmentId, group.DueDate, userIds));
        }

        if (hasDuplicatedUsers)
            errors.Add(CourseConstants.DuplicatedUser);

        return errors.Count > 0
            ? (null, errors)
            : (new CourseDraft(name, externalId, assignments), errors);
    }
}
```

---

## 8. Paso 6 — Contratos de persistencia

### `Contracts/Persistence/ICourseRepository.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Contracts.Persistence;

public interface ICourseRepository
{
    // ── Lecturas (sin seguimiento) ──────────────────────────────────
    Task<CoursePageDto> GetPageAsync(CourseListQuery query, DateOnly today, CancellationToken ct);
    Task<CourseDetailDto?> GetDetailAsync(int courseId, CancellationToken ct);
    Task<bool> NameExistsAsync(string name, CourseModality modality, int? excludeCourseId, CancellationToken ct);
    Task<bool> ExternalIdExistsAsync(string externalId, int? excludeCourseId, CancellationToken ct);
    Task<IReadOnlySet<int>> GetExistingUserIdsAsync(IReadOnlyCollection<int> userIds, CancellationToken ct);

    // ── Escrituras ──────────────────────────────────────────────────
    /// <summary>Curso con seguimiento para modificarlo. includeAssignments trae grupos y usuarios.</summary>
    Task<Course?> GetForUpdateAsync(int courseId, bool includeAssignments, CancellationToken ct);
    void Add(Course course);
    void Remove<TEntity>(TEntity entity) where TEntity : class;

    /// <summary>Un solo SaveChanges = una sola transacción. Lanza DuplicateKeyException si un índice único rechaza.</summary>
    Task SaveChangesAsync(CancellationToken ct);
}
```

### `Contracts/Persistence/DuplicateKeyException.cs`

```csharp
namespace DOCCB.Application.Contracts.Persistence;

/// <summary>Un índice único rechazó el cambio. IndexName permite saber cuál regla se violó.</summary>
public sealed class DuplicateKeyException(string indexName, Exception inner)
    : Exception($"Registro duplicado ({indexName}).", inner)
{
    public string IndexName { get; } = indexName;
}
```

### `Contracts/Persistence/IUserSearchRepository.cs`

```csharp
using DOCCB.Application.Features.Users.Application.DTOs;

namespace DOCCB.Application.Contracts.Persistence;

public interface IUserSearchRepository
{
    Task<List<UserSearchResultDto>> SearchAsync(string term, int top, CancellationToken ct);
}
```

### `Features/Users/Application/DTOs/UserSearchResultDto.cs`

```csharp
namespace DOCCB.Application.Features.Users.Application.DTOs;

/// <summary>Mismos campos que CourseUserDto: el buscador del frontend usa uno solo.</summary>
public class UserSearchResultDto
{
    public string UserId { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? JobTitle { get; set; }
}
```

---

## 9. Paso 7 — Repositorios (Infraestructura)

### `Repositories/CourseRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Infraestructure.Repositories;

public class CourseRepository(DOCCbDbContext db) : ICourseRepository
{
    public async Task<CoursePageDto> GetPageAsync(CourseListQuery query, DateOnly today, CancellationToken ct)
    {
        IQueryable<Course> courses = db.Set<Course>().AsNoTracking().Where(c => !c.Removed);

        if (query.Search is { Length: > 0 } term)
        {
            courses = courses.Where(c => c.Name.Contains(term) || (c.ExternalId != null && c.ExternalId.Contains(term)));
        }

        // Los indicadores se calculan solo con la búsqueda, sin modalidad ni "pendientes":
        // si no, al filtrar por Virtual el indicador de Presenciales caería a cero.
        var stats = await courses
            .GroupBy(_ => 1)
            .Select(g => new CourseStatsDto
            {
                Total = g.Count(),
                Virtual = g.Count(c => c.Modality == CourseModality.Virtual),
                Onsite = g.Count(c => c.Modality == CourseModality.Presencial),
                PendingExternalId = g.Count(c => c.Modality == CourseModality.Virtual && c.ExternalId == null),
            })
            .FirstOrDefaultAsync(ct) ?? new CourseStatsDto();

        if (query.Modality is { } modality)
        {
            courses = courses.Where(c => c.Modality == modality);
        }

        if (query.PendingExternalId)
        {
            courses = courses.Where(c => c.Modality == CourseModality.Virtual && c.ExternalId == null);
        }

        var totalCount = await courses.CountAsync(ct);

        var rows = courses.Select(c => new CourseRow
        {
            Id = c.Id,
            Name = c.Name,
            Modality = c.Modality,
            ExternalId = c.ExternalId,
            AssignedUsersCount = c.Assignments.SelectMany(a => a.Users).Count(),
            // Próxima fecha vigente; si todas vencieron, la más reciente.
            NextDueDate = c.Assignments.Where(a => a.DueDate >= today).Min(a => (DateOnly?)a.DueDate)
                          ?? c.Assignments.Where(a => a.DueDate < today).Max(a => (DateOnly?)a.DueDate),
        });

        var page = await Sort(rows, query)
            .Skip((query.Page - 1) * query.PageSize)
            .Take(query.PageSize)
            .ToListAsync(ct);

        return new CoursePageDto
        {
            Items = page.Select(r => new CourseListItemDto
            {
                CourseId = r.Id,
                Name = r.Name,
                Modality = CourseModalityCodes.ToCode(r.Modality),
                ExternalId = r.ExternalId,
                AssignedUsersCount = r.AssignedUsersCount,
                NextDueDate = r.NextDueDate,
            }).ToList(),
            TotalCount = totalCount,
            Stats = stats,
        };
    }

    /// <summary>
    /// Lista blanca de órdenes: nunca se ordena por un nombre de columna que llegue del cliente.
    /// Los cursos sin fecha van al final y el Id desempata, para que la paginación no repita filas.
    /// </summary>
    private static IQueryable<CourseRow> Sort(IQueryable<CourseRow> rows, CourseListQuery query) =>
        (query.Sort, query.Direction) switch
        {
            (CourseSortField.DueDate, SortDirection.Asc) =>
                rows.OrderBy(r => r.NextDueDate == null).ThenBy(r => r.NextDueDate).ThenBy(r => r.Id),
            (CourseSortField.DueDate, SortDirection.Desc) =>
                rows.OrderBy(r => r.NextDueDate == null).ThenByDescending(r => r.NextDueDate).ThenBy(r => r.Id),
            (_, SortDirection.Desc) =>
                rows.OrderByDescending(r => r.Name).ThenBy(r => r.Id),
            _ =>
                rows.OrderBy(r => r.Name).ThenBy(r => r.Id),
        };

    public async Task<CourseDetailDto?> GetDetailAsync(int courseId, CancellationToken ct)
    {
        var row = await db.Set<Course>()
            .AsNoTracking()
            .Where(c => c.Id == courseId && !c.Removed)
            .Select(c => new
            {
                c.Id,
                c.Name,
                c.Modality,
                c.ExternalId,
                Assignments = c.Assignments
                    .OrderBy(a => a.DueDate)
                    .Select(a => new
                    {
                        a.Id,
                        a.DueDate,
                        Users = a.Users
                            .OrderBy(u => u.User.DisplayName)
                            .Select(u => new { u.UserId, u.User.DisplayName, Email = u.User.CorportativeEmail })
                            .ToList(),
                    })
                    .ToList(),
            })
            .AsSplitQuery()
            .FirstOrDefaultAsync(ct);

        if (row is null) return null;

        return new CourseDetailDto
        {
            CourseId = row.Id,
            Name = row.Name,
            Modality = CourseModalityCodes.ToCode(row.Modality),
            ExternalId = row.ExternalId,
            Assignments = row.Assignments.Select(a => new CourseAssignmentDto
            {
                AssignmentId = a.Id,
                DueDate = a.DueDate,
                Users = a.Users.Select(u => new CourseUserDto
                {
                    UserId = u.UserId.ToString(),
                    DisplayName = u.DisplayName,
                    Email = u.Email,
                }).ToList(),
            }).ToList(),
        };
    }

    public Task<bool> NameExistsAsync(string name, CourseModality modality, int? excludeCourseId, CancellationToken ct) =>
        db.Set<Course>().AnyAsync(c =>
            !c.Removed &&
            c.Name == name &&
            c.Modality == modality &&
            (excludeCourseId == null || c.Id != excludeCourseId), ct);

    public Task<bool> ExternalIdExistsAsync(string externalId, int? excludeCourseId, CancellationToken ct) =>
        db.Set<Course>().AnyAsync(c =>
            c.ExternalId == externalId &&
            (excludeCourseId == null || c.Id != excludeCourseId), ct);

    public async Task<IReadOnlySet<int>> GetExistingUserIdsAsync(IReadOnlyCollection<int> userIds, CancellationToken ct)
    {
        var ids = await db.Set<User>()
            .AsNoTracking()
            .Where(u => userIds.Contains(u.Id)) // agrega aquí el filtro de "usuario activo" de tu entidad
            .Select(u => u.Id)
            .ToListAsync(ct);

        return ids.ToHashSet();
    }

    public Task<Course?> GetForUpdateAsync(int courseId, bool includeAssignments, CancellationToken ct)
    {
        IQueryable<Course> query = db.Set<Course>().Where(c => c.Id == courseId && !c.Removed);

        if (includeAssignments)
        {
            query = query.Include(c => c.Assignments).ThenInclude(a => a.Users);
        }

        return query.FirstOrDefaultAsync(ct);
    }

    public void Add(Course course) => db.Set<Course>().Add(course);

    public void Remove<TEntity>(TEntity entity) where TEntity : class => db.Remove(entity);

    public async Task SaveChangesAsync(CancellationToken ct)
    {
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (ex.InnerException is SqlException { Number: 2601 or 2627 } sql)
        {
            // 2601 = índice único · 2627 = restricción UNIQUE / PK
            var index = CourseIndexNames.All.FirstOrDefault(sql.Message.Contains) ?? "desconocido";
            throw new DuplicateKeyException(index, ex);
        }
    }

    /// <summary>Proyección intermedia: permite ordenar por la próxima fecha dentro de SQL.</summary>
    private sealed class CourseRow
    {
        public int Id { get; init; }
        public string Name { get; init; } = string.Empty;
        public CourseModality Modality { get; init; }
        public string? ExternalId { get; init; }
        public int AssignedUsersCount { get; init; }
        public DateOnly? NextDueDate { get; init; }
    }
}
```

> `DisplayName` y `CorportativeEmail` son los nombres que usa la entidad `User` en el código actual. Si el cargo existe en `User`, mapéalo a `JobTitle` en `GetDetailAsync` y en `UserSearchRepository`.

### `Repositories/UserSearchRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Users.Application.DTOs;
using DOCCB.Domain.Entities;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Infraestructure.Repositories;

public class UserSearchRepository(DOCCbDbContext db) : IUserSearchRepository
{
    public Task<List<UserSearchResultDto>> SearchAsync(string term, int top, CancellationToken ct) =>
        db.Set<User>()
            .AsNoTracking()
            .Where(u => u.DisplayName.Contains(term) || u.CorportativeEmail.Contains(term)) // + filtro de activos
            .OrderBy(u => u.DisplayName)
            .Take(top)
            .Select(u => new UserSearchResultDto
            {
                UserId = u.Id.ToString(),
                DisplayName = u.DisplayName,
                Email = u.CorportativeEmail,
            })
            .ToListAsync(ct);
}
```

---

## 10. Paso 8 — ⭐ El servicio

### `Interfaces/ICourseService.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Interfaces;

public interface ICourseService
{
    Task<CourseResult<CoursePageDto>> GetPageAsync(CourseQueryDto query, CancellationToken ct = default);
    Task<CourseResult<CourseDetailDto>> GetByIdAsync(int id, CancellationToken ct = default);
    Task<CourseResult<int>> CreateAsync(SaveCourseRequestDto dto, string currentUser, CancellationToken ct = default);
    Task<CourseResult<bool>> UpdateAsync(int id, SaveCourseRequestDto dto, string currentUser, CancellationToken ct = default);
    Task<CourseResult<bool>> SetExternalIdAsync(int id, SetExternalIdRequestDto dto, string currentUser, CancellationToken ct = default);
    Task<CourseResult<bool>> DeleteAsync(int id, string currentUser, CancellationToken ct = default);
}
```

### `Services/CourseService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Application.Features.Courses.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Courses.Application.Services;

public class CourseService(ICourseRepository repository, TimeProvider timeProvider) : ICourseService
{
    private readonly ICourseRepository _repository = repository;
    private readonly TimeProvider _timeProvider = timeProvider;

    // ── Consultas ───────────────────────────────────────────────────

    public async Task<CourseResult<CoursePageDto>> GetPageAsync(CourseQueryDto dto, CancellationToken ct = default)
    {
        CourseModality? modality = null;
        if (!string.IsNullOrWhiteSpace(dto.Modality))
        {
            if (!CourseModalityCodes.TryParse(dto.Modality, out var parsed))
                return CourseResult<CoursePageDto>.Fail(CourseResultStatus.Invalid, CourseConstants.InvalidModality);

            modality = parsed;
        }

        var query = new CourseListQuery(
            Search: Truncate(dto.Search?.Trim(), CourseConstants.SearchMaxLength),
            Modality: modality,
            PendingExternalId: dto.PendingExternalId,
            // Orden y dirección desconocidos caen al valor por defecto: no son un error del usuario.
            Sort: string.Equals(dto.Sort, "dueDate", StringComparison.OrdinalIgnoreCase)
                ? CourseSortField.DueDate
                : CourseSortField.Name,
            Direction: string.Equals(dto.Direction, "desc", StringComparison.OrdinalIgnoreCase)
                ? SortDirection.Desc
                : SortDirection.Asc,
            Page: Math.Max(1, dto.Page),
            PageSize: Math.Clamp(dto.PageSize, 1, CourseConstants.MaxPageSize));

        var page = await _repository.GetPageAsync(query, Today(), ct);
        return CourseResult<CoursePageDto>.Ok(page);
    }

    public async Task<CourseResult<CourseDetailDto>> GetByIdAsync(int id, CancellationToken ct = default)
    {
        var detail = await _repository.GetDetailAsync(id, ct);

        return detail is null
            ? CourseResult<CourseDetailDto>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound)
            : CourseResult<CourseDetailDto>.Ok(detail);
    }

    // ── Comandos ────────────────────────────────────────────────────

    public async Task<CourseResult<int>> CreateAsync(SaveCourseRequestDto dto, string currentUser, CancellationToken ct = default)
    {
        if (!CourseModalityCodes.TryParse(dto.Modality, out var modality))
            return CourseResult<int>.Fail(CourseResultStatus.Invalid, CourseConstants.InvalidModality);

        var (draft, errors) = CourseValidationHelper.Normalize(dto);
        if (draft is null)
            return CourseResult<int>.Fail(CourseResultStatus.Invalid, errors);

        if (draft.Assignments.Any(a => a.AssignmentId is not null))
            return CourseResult<int>.Fail(CourseResultStatus.Invalid, "Un curso nuevo no puede traer grupos existentes.");

        var today = Today();
        if (draft.Assignments.Any(a => a.DueDate < today))
            return CourseResult<int>.Fail(CourseResultStatus.Invalid, CourseConstants.PastDueDate);

        var conflict = await CheckUniquenessAsync(draft.Name, modality, draft.ExternalId, excludeCourseId: null, ct);
        if (conflict is not null)
            return CourseResult<int>.Fail(CourseResultStatus.Conflict, conflict);

        var missing = await FindMissingUsersAsync(draft.Assignments.SelectMany(a => a.UserIds), ct);
        if (missing is not null)
            return CourseResult<int>.Fail(CourseResultStatus.Invalid, missing);

        var now = Now();
        var course = new Course
        {
            Name = draft.Name,
            Modality = modality,
            ExternalId = draft.ExternalId,
            CreatedDate = now,
            CreatedBy = currentUser,
        };

        foreach (var group in draft.Assignments)
        {
            course.Assignments.Add(NewAssignment(group, now, currentUser));
        }

        _repository.Add(course);

        var saveConflict = await TrySaveAsync(ct);
        return saveConflict is null
            ? CourseResult<int>.Ok(course.Id)
            : CourseResult<int>.Fail(CourseResultStatus.Conflict, saveConflict);
    }

    public async Task<CourseResult<bool>> UpdateAsync(int id, SaveCourseRequestDto dto, string currentUser, CancellationToken ct = default)
    {
        var (draft, errors) = CourseValidationHelper.Normalize(dto);
        if (draft is null)
            return CourseResult<bool>.Fail(CourseResultStatus.Invalid, errors);

        var course = await _repository.GetForUpdateAsync(id, includeAssignments: true, ct);
        if (course is null)
            return CourseResult<bool>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound);

        // La modalidad no cambia al editar: se valida el nombre contra la que ya tiene.
        var conflict = await CheckUniquenessAsync(draft.Name, course.Modality, draft.ExternalId, id, ct);
        if (conflict is not null)
            return CourseResult<bool>.Fail(CourseResultStatus.Conflict, conflict);

        var existing = course.Assignments.ToDictionary(a => a.Id);
        var today = Today();

        foreach (var group in draft.Assignments)
        {
            if (group.AssignmentId is { } assignmentId)
            {
                if (!existing.TryGetValue(assignmentId, out var current))
                    return CourseResult<bool>.Fail(CourseResultStatus.Invalid, $"El grupo {assignmentId} no pertenece a este curso.");

                // Una fecha que llega igual a la guardada se respeta aunque ya haya vencido.
                if (group.DueDate != current.DueDate && group.DueDate < today)
                    return CourseResult<bool>.Fail(CourseResultStatus.Invalid, CourseConstants.PastDueDate);
            }
            else if (group.DueDate < today)
            {
                return CourseResult<bool>.Fail(CourseResultStatus.Invalid, CourseConstants.PastDueDate);
            }
        }

        // Solo se verifica que existan los usuarios NUEVOS: uno ya asignado que se inactivó no bloquea la edición.
        var currentUserIds = course.Assignments.SelectMany(a => a.Users).Select(u => u.UserId).ToHashSet();
        var missing = await FindMissingUsersAsync(
            draft.Assignments.SelectMany(a => a.UserIds).Where(userId => !currentUserIds.Contains(userId)), ct);
        if (missing is not null)
            return CourseResult<bool>.Fail(CourseResultStatus.Invalid, missing);

        var now = Now();
        course.Name = draft.Name;
        course.ExternalId = draft.ExternalId;
        course.UpdatedDate = now;
        course.UpdatedBy = currentUser;

        SyncAssignments(course, draft.Assignments, now, currentUser);

        var saveConflict = await TrySaveAsync(ct);
        return saveConflict is null
            ? CourseResult<bool>.Ok(true)
            : CourseResult<bool>.Fail(CourseResultStatus.Conflict, saveConflict);
    }

    public async Task<CourseResult<bool>> SetExternalIdAsync(int id, SetExternalIdRequestDto dto, string currentUser, CancellationToken ct = default)
    {
        var errors = CourseValidationHelper.ValidateExternalId(dto.ExternalId, out var externalId);
        if (externalId is null)
            errors.Add(CourseConstants.ExternalIdRequired);
        if (errors.Count > 0)
            return CourseResult<bool>.Fail(CourseResultStatus.Invalid, errors);

        var course = await _repository.GetForUpdateAsync(id, includeAssignments: false, ct);
        if (course is null)
            return CourseResult<bool>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound);

        if (await _repository.ExternalIdExistsAsync(externalId!, id, ct))
            return CourseResult<bool>.Fail(CourseResultStatus.Conflict, CourseConstants.DuplicateExternalId);

        course.ExternalId = externalId;
        course.UpdatedDate = Now();
        course.UpdatedBy = currentUser;

        var saveConflict = await TrySaveAsync(ct);
        return saveConflict is null
            ? CourseResult<bool>.Ok(true)
            : CourseResult<bool>.Fail(CourseResultStatus.Conflict, saveConflict);
    }

    public async Task<CourseResult<bool>> DeleteAsync(int id, string currentUser, CancellationToken ct = default)
    {
        var course = await _repository.GetForUpdateAsync(id, includeAssignments: true, ct);
        if (course is null)
            return CourseResult<bool>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound);

        if (course.Assignments.Count > 0)
        {
            // Tiene historial de asignaciones: se conserva y el curso deja de listarse.
            course.Removed = true;
            course.UpdatedDate = Now();
            course.UpdatedBy = currentUser;
        }
        else
        {
            _repository.Remove(course);
        }

        await _repository.SaveChangesAsync(ct);
        return CourseResult<bool>.Ok(true);
    }

    // ── Privados ────────────────────────────────────────────────────

    /// <summary>Grupos: los que no llegan se borran, los existentes se actualizan y los nuevos se crean.</summary>
    private void SyncAssignments(Course course, IReadOnlyList<AssignmentDraft> groups, DateTime now, string currentUser)
    {
        var keepIds = groups.Where(g => g.AssignmentId is not null).Select(g => g.AssignmentId!.Value).ToHashSet();

        foreach (var removed in course.Assignments.Where(a => !keepIds.Contains(a.Id)).ToList())
        {
            course.Assignments.Remove(removed);
            _repository.Remove(removed); // sus usuarios se borran en cascada
        }

        foreach (var group in groups.Where(g => g.AssignmentId is not null))
        {
            var assignment = course.Assignments.First(a => a.Id == group.AssignmentId);
            assignment.DueDate = group.DueDate;

            var wanted = group.UserIds.ToHashSet();

            foreach (var user in assignment.Users.Where(u => !wanted.Contains(u.UserId)).ToList())
            {
                assignment.Users.Remove(user);
                _repository.Remove(user);
            }

            var current = assignment.Users.Select(u => u.UserId).ToHashSet();
            foreach (var userId in wanted.Where(userId => !current.Contains(userId)))
            {
                assignment.Users.Add(new CourseAssignmentUser { UserId = userId, CreatedDate = now });
            }
        }

        foreach (var group in groups.Where(g => g.AssignmentId is null))
        {
            course.Assignments.Add(NewAssignment(group, now, currentUser));
        }
    }

    private static CourseAssignment NewAssignment(AssignmentDraft group, DateTime now, string currentUser)
    {
        var assignment = new CourseAssignment { DueDate = group.DueDate, CreatedDate = now, CreatedBy = currentUser };

        foreach (var userId in group.UserIds)
        {
            // EF completa AssignmentId y CourseId desde la navegación al guardar.
            assignment.Users.Add(new CourseAssignmentUser { UserId = userId, CreatedDate = now });
        }

        return assignment;
    }

    private async Task<string?> CheckUniquenessAsync(
        string name, CourseModality modality, string? externalId, int? excludeCourseId, CancellationToken ct)
    {
        if (await _repository.NameExistsAsync(name, modality, excludeCourseId, ct))
            return CourseConstants.DuplicateName;

        if (externalId is not null && await _repository.ExternalIdExistsAsync(externalId, excludeCourseId, ct))
            return CourseConstants.DuplicateExternalId;

        return null;
    }

    private async Task<string?> FindMissingUsersAsync(IEnumerable<int> userIds, CancellationToken ct)
    {
        var requested = userIds.ToHashSet();
        if (requested.Count == 0) return null;

        var existing = await _repository.GetExistingUserIdsAsync(requested, ct);
        var missing = requested.Where(id => !existing.Contains(id)).ToList();

        return missing.Count == 0
            ? null
            : $"Estos usuarios no existen o están inactivos: {string.Join(", ", missing)}.";
    }

    /// <summary>Si un índice único rechaza (dos personas guardando a la vez), devuelve el mensaje de la regla.</summary>
    private async Task<string?> TrySaveAsync(CancellationToken ct)
    {
        try
        {
            await _repository.SaveChangesAsync(ct);
            return null;
        }
        catch (DuplicateKeyException ex)
        {
            return ex.IndexName switch
            {
                CourseIndexNames.NameModality => CourseConstants.DuplicateName,
                CourseIndexNames.ExternalId => CourseConstants.DuplicateExternalId,
                CourseIndexNames.CourseUser => CourseConstants.DuplicatedUser,
                _ => "Ya existe un registro con esos datos.",
            };
        }
    }

    private DateOnly Today() => BusinessDate.Today(_timeProvider);

    private DateTime Now() => _timeProvider.GetUtcNow().UtcDateTime;

    private static string? Truncate(string? value, int max) =>
        string.IsNullOrEmpty(value) ? null : value.Length <= max ? value : value[..max];
}
```

### Búsqueda de usuarios en `IUserService` / `UserService`

Agrega el método a la interfaz existente:

```csharp
Task<ResponseDto<List<UserSearchResultDto>>> SearchAsync(string? term, int top, CancellationToken ct = default);
```

Y su implementación (inyecta `IUserSearchRepository` en el constructor de `UserService`):

```csharp
private const int SearchMinLength = 2;
private const int SearchMaxResults = 25;

public async Task<ResponseDto<List<UserSearchResultDto>>> SearchAsync(string? term, int top, CancellationToken ct = default)
{
    var clean = term?.Trim() ?? string.Empty;
    if (clean.Length < SearchMinLength)
        return ResponseDtoHelper.CreateSuccessResponseDto(new List<UserSearchResultDto>());

    var results = await _userSearchRepository.SearchAsync(clean, Math.Clamp(top, 1, SearchMaxResults), ct);
    return ResponseDtoHelper.CreateSuccessResponseDto(results);
}
```

---

## 11. Paso 9 — Controladores

### `WebApp/Controllers/CoursesController.cs`

```csharp
using System.Security.Claims;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace WebApp.Controllers;

[ApiController]
[Route("api/courses")]
[Authorize] // + el atributo de permiso que usa DOCCB para restringir por rol
public class CoursesController(ICourseService courseService) : ControllerBase
{
    private readonly ICourseService _courseService = courseService;

    [HttpGet]
    public async Task<IActionResult> GetPage([FromQuery] CourseQueryDto query, CancellationToken ct) =>
        ToActionResult(await _courseService.GetPageAsync(query, ct));

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id, CancellationToken ct) =>
        ToActionResult(await _courseService.GetByIdAsync(id, ct));

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] SaveCourseRequestDto dto, CancellationToken ct)
    {
        var result = await _courseService.CreateAsync(dto, CurrentUser, ct);

        return result.Status == CourseResultStatus.Ok
            ? CreatedAtAction(nameof(GetById), new { id = result.Response.Response }, result.Response)
            : ToActionResult(result);
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] SaveCourseRequestDto dto, CancellationToken ct) =>
        ToActionResult(await _courseService.UpdateAsync(id, dto, CurrentUser, ct));

    [HttpPatch("{id:int}/external-id")]
    public async Task<IActionResult> SetExternalId(int id, [FromBody] SetExternalIdRequestDto dto, CancellationToken ct) =>
        ToActionResult(await _courseService.SetExternalIdAsync(id, dto, CurrentUser, ct));

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, CancellationToken ct) =>
        ToActionResult(await _courseService.DeleteAsync(id, CurrentUser, ct));

    /// <summary>Correo del usuario autenticado, para la auditoría. Usa MicrosoftUserAuthenticatorHelper si ya lo expone.</summary>
    private string CurrentUser =>
        User.FindFirstValue("preferred_username")
        ?? User.FindFirstValue(ClaimTypes.Email)
        ?? User.Identity?.Name
        ?? "desconocido";

    private IActionResult ToActionResult<T>(CourseResult<T> result) => result.Status switch
    {
        CourseResultStatus.Ok => Ok(result.Response),
        CourseResultStatus.NotFound => NotFound(result.Response),
        CourseResultStatus.Conflict => Conflict(result.Response),
        _ => BadRequest(result.Response),
    };
}
```

### `WebApp/Controllers/UserController.cs` — búsqueda

El frontend llama a `/api/users/search` (plural). Si `UserController` usa `api/[controller]`, su ruta es `/api/User`: por eso la acción declara una ruta absoluta.

```csharp
[HttpGet("/api/users/search")]
public async Task<IActionResult> Search([FromQuery] string? q, [FromQuery] int top = 10, CancellationToken ct = default) =>
    Ok(await _userService.SearchAsync(q, top, ct));
```

### Contrato resultante

| Método | Ruta | Éxito | Errores |
|---|---|---|---|
| `GET` | `/api/courses?search=&modality=&pendingExternalId=&sort=&direction=&page=&pageSize=` | `200` `{ items, totalCount, stats }` | `400` modalidad inválida |
| `GET` | `/api/courses/{id}` | `200` detalle con grupos | `404` |
| `POST` | `/api/courses` | `201` con el `courseId` | `400` validación · `409` nombre o ID externo repetido |
| `PUT` | `/api/courses/{id}` | `200` | `400` · `404` · `409` |
| `PATCH` | `/api/courses/{id}/external-id` | `200` | `400` · `404` · `409` |
| `DELETE` | `/api/courses/{id}` | `200` (lógico o físico) | `404` |
| `GET` | `/api/users/search?q=ana&top=10` | `200` `[{ userId, displayName, email, jobTitle }]` | — |

Todas las respuestas usan el envelope `ResponseDto`, así que el frontend lee `errors` también en los `4xx`.

---

## 12. Paso 10 — Registro de dependencias

`ApplicationServiceRegistration.cs`:

```csharp
services.AddScoped<ICourseService, CourseService>();
services.TryAddSingleton(TimeProvider.System);
```

`InfrastructureServiceRegistration.cs`:

```csharp
services.AddScoped<ICourseRepository, CourseRepository>();
services.AddScoped<IUserSearchRepository, UserSearchRepository>();
```

> `TryAddSingleton` requiere `using Microsoft.Extensions.DependencyInjection.Extensions;`.

### Si algún día hace falta Microsoft Graph

Si hay personas que deben recibir cursos y no están en `dbo.users`, cambia solo `UserSearchRepository` por una implementación con Graph (la consulta está en la guía de Angular, sección 7). La tabla `course_assignment_user` tendría que guardar el `object id` de Entra ID en lugar de `user_id`, así que decídelo **antes** de ejecutar el script.

---

## 13. Pruebas

### Unitarias de validación

```csharp
public class CourseValidationHelperTests
{
    private static SaveCourseRequestDto Valid() => new()
    {
        Name = "Excel avanzado",
        Modality = "VIRTUAL",
        Assignments = [new() { DueDate = new DateOnly(2099, 1, 1), UserIds = ["1", "2"] }],
    };

    [Fact]
    public void Rechaza_un_nombre_con_solo_espacios()
    {
        var dto = Valid();
        dto.Name = "   ";

        var (draft, errors) = CourseValidationHelper.Normalize(dto);

        Assert.Null(draft);
        Assert.Contains("Escribe el nombre del curso.", errors);
    }

    [Fact]
    public void Convierte_un_id_externo_vacio_en_null()
    {
        var dto = Valid();
        dto.ExternalId = "   ";

        var (draft, _) = CourseValidationHelper.Normalize(dto);

        Assert.Null(draft!.ExternalId);
    }

    [Fact]
    public void Rechaza_un_id_externo_con_espacios()
    {
        var errors = CourseValidationHelper.ValidateExternalId("LMS 22", out _);

        Assert.Contains("El ID externo no puede tener espacios.", errors);
    }

    [Fact]
    public void Rechaza_un_usuario_en_dos_grupos()
    {
        var dto = Valid();
        dto.Assignments.Add(new() { DueDate = new DateOnly(2099, 2, 1), UserIds = ["2"] });

        var (_, errors) = CourseValidationHelper.Normalize(dto);

        Assert.Contains(CourseConstants.DuplicatedUser, errors);
    }

    [Fact]
    public void Rechaza_un_grupo_sin_usuarios()
    {
        var dto = Valid();
        dto.Assignments[0].UserIds = [];

        var (_, errors) = CourseValidationHelper.Normalize(dto);

        Assert.Contains("Grupo 1: agrega al menos un usuario.", errors);
    }
}
```

### Del servicio (con un doble de `ICourseRepository`)

- Crear con una fecha de ayer → `400` con `PastDueDate`.
- Editar un grupo vencido sin cambiar su fecha → se guarda.
- Editar un grupo vencido cambiando su fecha a otra pasada → `400`.
- `NameExistsAsync` devuelve `true` → `409` con `DuplicateName`.
- `SaveChangesAsync` lanza `DuplicateKeyException("ux_course_external_id")` → `409` con `DuplicateExternalId`.
- Eliminar un curso con grupos → queda con `Removed = true` y no se llama a `Remove`.
- Con un `TimeProvider` falso a las 11 p. m. de Colombia (04:00 UTC del día siguiente), una fecha de "hoy" en Colombia se acepta.

### Contra SQL Server

- Ejecuta el script dos veces: la segunda no debe fallar ni duplicar nada.
- Inserta dos cursos con el mismo nombre y modalidad → error `2601` en `ux_course_name_modality`.
- Mismo nombre en modalidades distintas → se permite.
- Elimina lógicamente un curso y crea otro con su nombre → se permite.
- Intenta insertar en `course_assignment_user` un `course_id` distinto al del grupo → la FK compuesta lo rechaza.
- Mueve un usuario del grupo 1 al grupo 2 del mismo curso con un `PUT` → se guarda sin violar el índice único.

---

## 14. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| `Invalid object name 'dbo.Course'` | Falta `ToTable("course", "dbo")` o la configuración no se registró | Revisa las tres líneas de `ApplyConfiguration` en `DOCCbDbContext`. |
| `Invalid column name 'Name'` | Una propiedad sin `HasColumnName` | Cada propiedad debe mapear su columna en `snake_case`. |
| `INSERT failed because the following SET options have incorrect settings: 'QUOTED_IDENTIFIER'` | Inserción manual en una sesión con `QUOTED_IDENTIFIER OFF` sobre una tabla con índices filtrados | Ejecuta los scripts con `SET QUOTED_IDENTIFIER ON`. EF Core ya lo usa. |
| Mover a alguien de grupo da error `2601` | El índice único `(course_id, user_id)` no está en la configuración de EF | Déjalo en `CourseAssignmentUserConfiguration`: EF lo necesita para ordenar el DELETE antes del INSERT. |
| Fechas de hoy rechazadas en la noche | "Hoy" calculado con la hora del servidor en UTC | Usa `BusinessDate.Today`, nunca `DateTime.Today`. |
| `TimeZoneNotFoundException` | Servidor Windows sin ICU | Cambia `BusinessTimeZoneId` a `SA Pacific Standard Time`. |
| La modalidad llega como `1` en el JSON | Se serializó el enum en lugar del código | Usa `CourseModalityCodes.ToCode` en los DTOs, como el repositorio. |
| `409` sin mensaje claro | El nombre del índice en el script no coincide con `CourseIndexNames` | Deben ser idénticos en el script, en la configuración y en las constantes. |

---

## ✅ Checklist

- [ ] Confirmados el nombre de la base de datos y la tabla/llave de usuarios (`dbo.users`, `id`).
- [ ] Decidido: usuarios de `dbo.users` (esta guía) o de Entra ID vía Graph (antes de ejecutar el script).
- [ ] `Cursos.sql` en `Persistence/Scripts SQL` y ejecutado en cada ambiente.
- [ ] Entidades, enum y configuraciones creadas; configuraciones registradas en `DOCCbDbContext`.
- [ ] Nombres de índices iguales en el script, en la configuración y en `CourseIndexNames`.
- [ ] Propiedades de auditoría alineadas con `BaseEntity` / `TrazabilityEntity`.
- [ ] Filtro de "usuario activo" agregado en `GetExistingUserIdsAsync` y `UserSearchRepository`.
- [ ] `ICourseService`, `ICourseRepository`, `IUserSearchRepository` y `TimeProvider` registrados.
- [ ] `CoursesController` protegido con el permiso de administración de cursos.
- [ ] `GET /api/users/search` responde en la ruta en plural.
- [ ] Endpoints documentados en Swagger.
- [ ] Pruebas unitarias de validación y del servicio en verde; pruebas contra SQL Server hechas.
- [ ] Probado de punta a punta con las pantallas de Angular.
