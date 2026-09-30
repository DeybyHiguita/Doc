# 🎓 Cursos por grupos y formulario de finalización — API (.NET 8) y SQL Server

Esta guía **cambia cómo se asignan los cursos** y agrega el **formulario de finalización**.

**Antes** (guía [cursos-api-sqlserver.md](cursos-api-sqlserver.md)): cada curso tenía grupos armados a mano, persona por persona.
**Ahora:** a un curso se le asignan uno o varios **grupos de usuarios** (de [grupos-usuarios-api-sqlserver.md](grupos-usuarios-api-sqlserver.md)), cada uno con su **fecha límite**. Al guardar, cada integrante queda asignado en estado **Pendiente**.

Cada asignación tiene su **formulario de finalización**, que diligencia la propia persona:

| Campo | Origen | ¿Lo edita el usuario? |
|---|---|---|
| Nombre del curso | Ya guardado en `dbo.course` | No |
| Persona asignada | La relación generada desde el grupo | No |
| Gerencia | Directorio activo, consultada al abrir el formulario | No (bloqueado) |
| Estado | `PENDING` al asignar → `COMPLETED` al enviar | Sí, al enviar |
| Satisfacción (0 a 5) | Anónima | Sí |
| Utilidad del curso (0 a 5) | Anónima | Sí |
| Fecha de registro | La pone el servidor | No se le pide |

- **Stack:** .NET 8 · ASP.NET Core · EF Core 8 · SQL Server
- **Pantallas:** [cursos-grupos-finalizacion-angular.md](cursos-grupos-finalizacion-angular.md)

---

## 1. 🧐 Revisión crítica

| # | Tema | Decisión |
|---|---|---|
| 1 | **Anonimato de las calificaciones.** Si la calificación guarda al usuario, a la asignación o la hora exacta, deja de ser anónima. | Tabla aparte `course_rating` **sin** llave al usuario ni a la asignación, solo al curso. Id aleatorio (`NEWID`) para que el orden de inserción no delate a nadie, y fecha **sin hora**. Los promedios solo se muestran con **3 respuestas o más**. |
| 2 | **Límite honesto del anonimato.** Si en un día solo una persona finalizó un curso, quien tenga acceso a la base de datos puede cruzar la fecha de la calificación con la de su finalización. | Es anonimato frente a la aplicación y los reportes, no frente a un administrador de base de datos. Si se necesita más, guardar la calificación con la semana o el mes en lugar del día (sección 4). |
| 3 | **Registrar quién calificó sin guardar qué calificó.** | La finalización (con usuario) y la calificación (sin usuario) se guardan en la **misma transacción**. La calificación solo se acepta si el estado pasa de `PENDING` a `COMPLETED` en ese momento: así nadie califica dos veces y nadie califica sin haber finalizado. |
| 4 | **Doble clic en "Finalizar".** Dos peticiones simultáneas podrían crear dos calificaciones. | El cambio de estado es un `UPDATE … WHERE status = 'PENDING'`: la segunda petición no encuentra la fila pendiente y responde `409`. |
| 5 | **¿Qué significa 0?** Si el formulario empieza en 0, quien no toque las estrellas registra "pésimo" sin quererlo. | El 0 es válido, pero **se tiene que elegir**. El backend exige las dos calificaciones y rechaza valores fuera de 0 a 5. |
| 6 | **La gerencia bloqueada en pantalla no es segura.** El navegador podría enviar otra. | El usuario no la envía. El backend la vuelve a consultar al recibir el formulario y la guarda en la **finalización**, no en la calificación. |
| 7 | **¿Se puede volver a Pendiente?** | No desde el formulario. Una vez finalizado, la calificación ya quedó guardada sin dueño y no se podría corregir. |
| 8 | **¿Quién es el usuario que abre el formulario?** El correo del token (`preferred_username`) suele ser el UPN, que puede no coincidir con el correo guardado. | Se identifica por el **object id** de Entra ID (`oid`) y, como respaldo, por los correos del token. Así funciona también para personas "solo directorio". |
| 9 | **El grupo cambia después de asignarlo.** | La relación se genera al asignar (foto). Un botón **"Actualizar desde el grupo"** agrega a los nuevos integrantes y quita a los pendientes que salieron; los que ya finalizaron se conservan. |
| 10 | **Una persona en dos grupos del mismo curso.** | Queda asignada por el primero y se informa cuántas personas pasaron por eso. La base de datos lo garantiza con un índice único `(course_id, email)`. |
| 11 | **Quitar un grupo que ya tiene finalizados.** | Retiro lógico: se borran los pendientes y se conserva el historial de quienes finalizaron. |
| 12 | **"Vencido".** | No se guarda: se calcula (`PENDING` y fecha límite pasada, en hora de Colombia). |
| 13 | **Personas "solo directorio".** En la guía de cursos anterior no podían recibir cursos porque se asignaba contra `dbo.users`. | Ahora la persona asignada se identifica igual que en los grupos: correo + `user_id` (si está en el maestro) + `entra_object_id`. Pueden recibir cursos y diligenciar su formulario. |
| 14 | **Registros en logs.** Un middleware que guarde el cuerpo de las peticiones rompería el anonimato. | Excluye `POST /api/my-courses/{id}/complete` del registro de cuerpos y nunca escribas en un log el usuario junto a sus calificaciones. |

---

## 2. 🔄 Flujo completo

```text
 ADMINISTRADOR                                         COLABORADOR
 ─────────────                                         ───────────
 Crea / edita el curso
   └─ asigna grupos, cada uno con fecha límite
          │
          ▼
 Se genera course_assignment_user
 (una fila por integrante, estado PENDING) ──────────► "Mis cursos": aparece como Pendiente
                                                        │
                                                        ▼
                                             Abre el formulario de finalización
                                               · curso, fecha límite, su nombre
                                               · gerencia ◄── directorio activo (bloqueada)
                                               · ★★★★☆ satisfacción  (anónima)
                                               · ★★★★★ utilidad      (anónima)
                                                        │ Enviar
                                                        ▼
                                             Una transacción:
                                               1. UPDATE … SET status = COMPLETED,
                                                  completed_date, management_name
                                                  WHERE id = @id AND status = PENDING
                                               2. INSERT course_rating (sin usuario)
          │                                             │
          ▼                                             ▼
 Seguimiento: avance por grupo,                "Mis cursos": Finalizado
 personas con estado y gerencia,
 promedios anónimos (≥ 3 respuestas)
```

---

## 3. 📁 Archivos

```text
DOCCB.Domain/
├── Enum/CourseCompletionStatus.cs                    nuevo
└── Entities/
    ├── CourseAssignment.cs                           ✏️ ahora apunta a un grupo
    ├── CourseAssignmentUser.cs                       ✏️ ahora lleva estado, gerencia y fecha
    └── CourseRating.cs                               nuevo — sin usuario

DOCCB.Application/
├── Contracts/Persistence/
│   ├── ICourseRepository.cs                          ✏️ grupos y correos del curso
│   └── ICourseCompletionRepository.cs                nuevo
├── Features/Courses/Application/
│   ├── Constants/
│   │   ├── CourseConstants.cs                        ✏️ mensajes nuevos
│   │   ├── CourseIndexNames.cs                       ✏️ índices nuevos
│   │   └── CompletionConstants.cs                    nuevo
│   ├── DTOs/
│   │   ├── CourseDetailDtos.cs / SaveCourseRequestDto.cs   ✏️
│   │   ├── CurrentUserIdentity.cs                    nuevo
│   │   ├── CompletionDtos.cs                         nuevo
│   │   └── CourseProgressDtos.cs                     nuevo
│   ├── Helpers/CourseValidationHelper.cs             ✏️ valida grupos en vez de usuarios
│   ├── Interfaces/
│   │   ├── ICourseService.cs                         ✏️ + actualizar desde el grupo
│   │   ├── ICourseCompletionService.cs               nuevo
│   │   └── IManagementDirectory.cs                   nuevo — gerencia del directorio activo
│   └── Services/
│       ├── CourseService.cs                          ✏️ genera la relación desde los grupos
│       ├── CourseCompletionService.cs                ⭐ formulario, mis cursos y seguimiento
│       └── ManagementDirectory.cs                    nuevo — adapta tu método existente

DOCCB.Infraestructure/
├── Common/GenericRepositoryBase.cs                   (existente) base de CourseCompletionRepository
├── Configurations/
│   ├── CourseAssignmentConfiguration.cs              ✏️
│   ├── CourseAssignmentUserConfiguration.cs          ✏️
│   └── CourseRatingConfiguration.cs                  nuevo
├── Persistence/
│   ├── Models/DOCCbDbContext.cs                      ✏️ + CourseRatingConfiguration
│   └── Scripts SQL/Cursos-v2.sql                     ⭐ tablas nuevas y reemplazo de las anteriores
└── Repositories/
    ├── CourseRepository.cs                           ✏️
    └── CourseCompletionRepository.cs                 nuevo — hereda de GenericRepositoryBase

WebApp/
├── Common/Helper/ControllerExtensions.cs             ✏️ + identidad del usuario
└── Controllers/
    ├── CoursesController.cs                          ✏️ + sincronizar y seguimiento
    └── MyCoursesController.cs                        nuevo — /api/my-courses
```

---

## 4. Paso 1 — 🗄️ Base de datos

### Modelo

```text
dbo.course ──< dbo.course_assignment >── dbo.user_group ──< dbo.user_group_member
   │              id, due_date                                     │ (foto al asignar)
   │                   │                                           ▼
   │                   └──────────────< dbo.course_assignment_user
   │                                     email, user_id?, entra_object_id?
   │                                     status  PENDING | COMPLETED
   │                                     completed_date, management_name
   │
   └──────────────────────────────────< dbo.course_rating        ← SIN usuario ni asignación
                                          satisfaction 0-5, usefulness 0-5, created_date (DATE)
```

### `Persistence/Scripts SQL/Cursos-v2.sql`

Reemplaza las tablas `course_assignment` y `course_assignment_user` de la guía anterior. **Si ya tienen datos, el script se detiene** sin tocar nada.

```sql
/* =====================================================================
   Cursos v2 — asignación por grupos, finalización y calificaciones
   Base de datos: DB · Esquema: dbo
   Requiere: dbo.course (Cursos.sql) y dbo.user_group (UserGroups.sql)
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   0. Tablas del modelo anterior (asignación persona por persona)
      Se reemplazan solo si están vacías.
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_assignment', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.course_assignment', N'group_id') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.course_assignment)
    BEGIN
        RAISERROR (N'dbo.course_assignment tiene datos del modelo anterior. Respáldalos o migra antes de continuar.', 16, 1);
        SET NOEXEC ON; -- no ejecuta nada más de este script
    END
    ELSE
    BEGIN
        DROP TABLE IF EXISTS dbo.course_assignment_user;
        DROP TABLE dbo.course_assignment;
    END
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   1. dbo.course_assignment — un grupo asignado a un curso, con su fecha límite
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_assignment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_assignment
    (
        id           INT            IDENTITY(1, 1) NOT NULL,
        course_id    INT            NOT NULL,
        group_id     INT            NOT NULL,
        due_date     DATE           NOT NULL,
        removed      BIT            NOT NULL CONSTRAINT df_course_assignment_removed DEFAULT (0),
        created_date DATETIME2(0)   NOT NULL CONSTRAINT df_course_assignment_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)  NOT NULL,
        updated_date DATETIME2(0)   NULL,
        updated_by   NVARCHAR(150)  NULL,

        CONSTRAINT pk_course_assignment PRIMARY KEY CLUSTERED (id),
        -- (id, course_id) permite que la tabla de personas garantice que la asignación es de ese curso.
        CONSTRAINT uq_course_assignment_id_course_id UNIQUE (id, course_id),
        CONSTRAINT fk_course_assignment_course FOREIGN KEY (course_id) REFERENCES dbo.course (id),
        CONSTRAINT fk_course_assignment_group FOREIGN KEY (group_id) REFERENCES dbo.user_group (id)
    );

    -- Un grupo se asigna una sola vez al mismo curso (entre asignaciones activas).
    CREATE UNIQUE INDEX ux_course_assignment_course_group
        ON dbo.course_assignment (course_id, group_id)
        WHERE removed = 0;

    CREATE INDEX ix_course_assignment_course_id
        ON dbo.course_assignment (course_id)
        INCLUDE (due_date)
        WHERE removed = 0;
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   2. dbo.course_assignment_user — la relación generada: cada persona con su estado
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_assignment_user', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_assignment_user
    (
        id              INT              IDENTITY(1, 1) NOT NULL,
        assignment_id   INT              NOT NULL,
        course_id       INT              NOT NULL,
        email           NVARCHAR(256)    NOT NULL,
        display_name    NVARCHAR(256)    NOT NULL,
        user_id         INT              NULL,
        entra_object_id UNIQUEIDENTIFIER NULL,
        status          VARCHAR(20)      NOT NULL CONSTRAINT df_course_assignment_user_status DEFAULT ('PENDING'),
        completed_date  DATETIME2(0)     NULL,
        management_name NVARCHAR(200)    NULL,
        created_date    DATETIME2(0)     NOT NULL CONSTRAINT df_course_assignment_user_created_date DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT pk_course_assignment_user PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_course_assignment_user_assignment
            FOREIGN KEY (assignment_id, course_id)
            REFERENCES dbo.course_assignment (id, course_id)
            ON DELETE CASCADE,
        CONSTRAINT fk_course_assignment_user_user
            FOREIGN KEY (user_id) REFERENCES dbo.users (id),
        CONSTRAINT ck_course_assignment_user_identity CHECK (user_id IS NOT NULL OR entra_object_id IS NOT NULL),
        CONSTRAINT ck_course_assignment_user_status CHECK (status IN ('PENDING', 'COMPLETED')),
        -- Finalizado siempre tiene fecha; pendiente nunca.
        CONSTRAINT ck_course_assignment_user_completed CHECK (
            (status = 'PENDING' AND completed_date IS NULL) OR
            (status = 'COMPLETED' AND completed_date IS NOT NULL))
    );

    -- Una persona, una asignación por curso: si está en dos grupos, queda en el primero.
    CREATE UNIQUE INDEX ux_course_assignment_user_course_email
        ON dbo.course_assignment_user (course_id, email);

    -- Seguimiento por grupo y estado.
    CREATE INDEX ix_course_assignment_user_assignment
        ON dbo.course_assignment_user (assignment_id, status);

    -- "Mis cursos".
    CREATE INDEX ix_course_assignment_user_email
        ON dbo.course_assignment_user (email)
        INCLUDE (status);

    CREATE INDEX ix_course_assignment_user_entra_object_id
        ON dbo.course_assignment_user (entra_object_id)
        WHERE entra_object_id IS NOT NULL;
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   3. dbo.course_rating — calificaciones ANÓNIMAS del curso
      Sin llave al usuario ni a la asignación. Id aleatorio. Fecha sin hora.
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_rating', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_rating
    (
        id           UNIQUEIDENTIFIER NOT NULL CONSTRAINT df_course_rating_id DEFAULT (NEWID()),
        course_id    INT              NOT NULL,
        satisfaction TINYINT          NOT NULL,
        usefulness   TINYINT          NOT NULL,
        created_date DATE             NOT NULL,

        CONSTRAINT pk_course_rating PRIMARY KEY NONCLUSTERED (id),
        CONSTRAINT fk_course_rating_course FOREIGN KEY (course_id) REFERENCES dbo.course (id),
        CONSTRAINT ck_course_rating_satisfaction CHECK (satisfaction BETWEEN 0 AND 5),
        CONSTRAINT ck_course_rating_usefulness CHECK (usefulness BETWEEN 0 AND 5)
    );

    CREATE CLUSTERED INDEX cx_course_rating_course
        ON dbo.course_rating (course_id, created_date);
END;
GO

SET NOEXEC OFF;
GO
```

> **Anonimato más fuerte (opcional).** Si en la revisión de seguridad piden que ni un administrador de base de datos pueda cruzar fechas, cambia `created_date` por el **primer día del mes** (`DATEFROMPARTS(YEAR(x), MONTH(x), 1)`) al guardar. El requisito de "guardar la fecha del registro" se sigue cumpliendo, con menos detalle.

### Consultas de verificación

```sql
DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'SA Pacific Standard Time' AS DATE);

-- Avance por curso y grupo
SELECT  c.name AS course,
        g.name AS user_group,
        a.due_date,
        total     = COUNT(u.id),
        completed = SUM(CASE WHEN u.status = 'COMPLETED' THEN 1 ELSE 0 END),
        overdue   = SUM(CASE WHEN u.status = 'PENDING' AND a.due_date < @today THEN 1 ELSE 0 END)
FROM    dbo.course_assignment a
JOIN    dbo.course c ON c.id = a.course_id AND c.removed = 0
JOIN    dbo.user_group g ON g.id = a.group_id
LEFT JOIN dbo.course_assignment_user u ON u.assignment_id = a.id
WHERE   a.removed = 0
GROUP BY c.name, g.name, a.due_date
ORDER BY c.name, a.due_date;

-- Calificaciones por curso (el reporte solo las muestra con 3 respuestas o más)
SELECT  c.name,
        responses    = COUNT(*),
        satisfaction = AVG(CAST(r.satisfaction AS DECIMAL(3, 2))),
        usefulness   = AVG(CAST(r.usefulness AS DECIMAL(3, 2)))
FROM    dbo.course_rating r
JOIN    dbo.course c ON c.id = r.course_id
GROUP BY c.name;

-- Control de integridad: finalizados por curso = calificaciones por curso
SELECT  c.name,
        completed = (SELECT COUNT(*) FROM dbo.course_assignment_user u WHERE u.course_id = c.id AND u.status = 'COMPLETED'),
        ratings   = (SELECT COUNT(*) FROM dbo.course_rating r WHERE r.course_id = c.id)
FROM    dbo.course c
WHERE   c.removed = 0;
```

La última consulta debe dar siempre el mismo número en las dos columnas: cada finalización genera exactamente una calificación.

---

## 5. Paso 2 — Dominio

### `DOCCB.Domain/Enum/CourseCompletionStatus.cs`

```csharp
namespace DOCCB.Domain.Enum;

public enum CourseCompletionStatus
{
    /// <summary>Estado normal al asignar el curso.</summary>
    Pending = 1,

    /// <summary>La persona diligenció el formulario de finalización.</summary>
    Completed = 2
}
```

### `DOCCB.Domain/Entities/CourseAssignment.cs` ✏️

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>Un grupo de usuarios asignado a un curso, con su fecha límite.</summary>
public class CourseAssignment : BaseEntity
{
    public int CourseId { get; set; }
    public int GroupId { get; set; }
    public DateOnly DueDate { get; set; }
    public bool Removed { get; set; }

    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? UpdatedDate { get; set; }
    public string? UpdatedBy { get; set; }

    public Course Course { get; set; } = null!;
    public UserGroup Group { get; set; } = null!;
    public ICollection<CourseAssignmentUser> Users { get; set; } = new List<CourseAssignmentUser>();
}
```

### `DOCCB.Domain/Entities/CourseAssignmentUser.cs` ✏️

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities;

/// <summary>Una persona asignada a un curso por un grupo, con el estado de su formulario.</summary>
public class CourseAssignmentUser : BaseEntity
{
    public int AssignmentId { get; set; }
    public int CourseId { get; set; }

    public string Email { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public int? UserId { get; set; }
    public Guid? EntraObjectId { get; set; }

    public CourseCompletionStatus Status { get; set; } = CourseCompletionStatus.Pending;
    public DateTime? CompletedDate { get; set; }

    /// <summary>Gerencia del directorio activo al momento de finalizar.</summary>
    public string? ManagementName { get; set; }

    public DateTime CreatedDate { get; set; }

    public CourseAssignment Assignment { get; set; } = null!;
    public User? User { get; set; }
}
```

### `DOCCB.Domain/Entities/CourseRating.cs`

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>
/// Calificación ANÓNIMA de un curso. A propósito no tiene navegación ni llave
/// hacia el usuario ni hacia la asignación: no agregues ninguna.
/// </summary>
public class CourseRating
{
    public Guid Id { get; set; }
    public int CourseId { get; set; }
    public byte Satisfaction { get; set; }
    public byte Usefulness { get; set; }

    /// <summary>Solo la fecha: con la hora se podría cruzar con la finalización.</summary>
    public DateOnly CreatedDate { get; set; }
}
```

---

## 6. Paso 3 — Configuración de EF Core

### `Constants/CourseIndexNames.cs` ✏️

```csharp
namespace DOCCB.Application.Features.Courses.Application.Constants;

public static class CourseIndexNames
{
    public const string NameModality = "ux_course_name_modality";
    public const string ExternalId = "ux_course_external_id";
    public const string CourseGroup = "ux_course_assignment_course_group";
    public const string CourseUser = "ux_course_assignment_user_course_email";

    public static readonly string[] All = [NameModality, ExternalId, CourseGroup, CourseUser];
}
```

### `Configurations/CourseAssignmentConfiguration.cs` ✏️

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;
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
        builder.HasAlternateKey(a => new { a.Id, a.CourseId }).HasName("uq_course_assignment_id_course_id");

        builder.Property(a => a.Id).HasColumnName("id");
        builder.Property(a => a.CourseId).HasColumnName("course_id");
        builder.Property(a => a.GroupId).HasColumnName("group_id");
        builder.Property(a => a.DueDate).HasColumnName("due_date").HasColumnType("date");
        builder.Property(a => a.Removed).HasColumnName("removed");
        builder.Property(a => a.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(a => a.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
        builder.Property(a => a.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
        builder.Property(a => a.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

        builder.HasIndex(a => new { a.CourseId, a.GroupId })
            .IsUnique()
            .HasFilter("[removed] = 0")
            .HasDatabaseName(CourseIndexNames.CourseGroup);

        builder.HasOne(a => a.Group)
            .WithMany()
            .HasForeignKey(a => a.GroupId)
            .HasConstraintName("fk_course_assignment_group")
            .OnDelete(DeleteBehavior.Restrict);
    }
}
```

### `Configurations/CourseAssignmentUserConfiguration.cs` ✏️

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class CourseAssignmentUserConfiguration : IEntityTypeConfiguration<CourseAssignmentUser>
{
    public void Configure(EntityTypeBuilder<CourseAssignmentUser> builder)
    {
        builder.ToTable("course_assignment_user", "dbo", table =>
        {
            table.HasCheckConstraint("ck_course_assignment_user_identity", "user_id IS NOT NULL OR entra_object_id IS NOT NULL");
            table.HasCheckConstraint("ck_course_assignment_user_status", "status IN ('PENDING', 'COMPLETED')");
            table.HasCheckConstraint("ck_course_assignment_user_completed",
                "(status = 'PENDING' AND completed_date IS NULL) OR (status = 'COMPLETED' AND completed_date IS NOT NULL)");
        });

        builder.HasKey(u => u.Id).HasName("pk_course_assignment_user");

        builder.Property(u => u.Id).HasColumnName("id");
        builder.Property(u => u.AssignmentId).HasColumnName("assignment_id");
        builder.Property(u => u.CourseId).HasColumnName("course_id");
        builder.Property(u => u.Email).HasColumnName("email").HasMaxLength(256).IsRequired();
        builder.Property(u => u.DisplayName).HasColumnName("display_name").HasMaxLength(256).IsRequired();
        builder.Property(u => u.UserId).HasColumnName("user_id");
        builder.Property(u => u.EntraObjectId).HasColumnName("entra_object_id");
        builder.Property(u => u.CompletedDate).HasColumnName("completed_date").HasColumnType("datetime2(0)");
        builder.Property(u => u.ManagementName).HasColumnName("management_name").HasMaxLength(200);
        builder.Property(u => u.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");

        builder.Property(u => u.Status)
            .HasColumnName("status")
            .HasMaxLength(20)
            .IsUnicode(false)
            .HasConversion(
                status => status.ToString().ToUpperInvariant(),
                code => Enum.Parse<CourseCompletionStatus>(code, true));

        // Tiene que estar en el modelo: EF lo usa para ordenar DELETE antes que INSERT
        // cuando una persona pasa de un grupo a otro en el mismo guardado.
        builder.HasIndex(u => new { u.CourseId, u.Email }).IsUnique().HasDatabaseName(CourseIndexNames.CourseUser);
        builder.HasIndex(u => new { u.AssignmentId, u.Status }).HasDatabaseName("ix_course_assignment_user_assignment");
        builder.HasIndex(u => u.Email).HasDatabaseName("ix_course_assignment_user_email");
        builder.HasIndex(u => u.EntraObjectId)
            .HasFilter("[entra_object_id] IS NOT NULL")
            .HasDatabaseName("ix_course_assignment_user_entra_object_id");

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

### `Configurations/CourseRatingConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class CourseRatingConfiguration : IEntityTypeConfiguration<CourseRating>
{
    public void Configure(EntityTypeBuilder<CourseRating> builder)
    {
        builder.ToTable("course_rating", "dbo", table =>
        {
            table.HasCheckConstraint("ck_course_rating_satisfaction", "satisfaction BETWEEN 0 AND 5");
            table.HasCheckConstraint("ck_course_rating_usefulness", "usefulness BETWEEN 0 AND 5");
        });

        builder.HasKey(r => r.Id).HasName("pk_course_rating").IsClustered(false);

        builder.Property(r => r.Id).HasColumnName("id").ValueGeneratedNever();
        builder.Property(r => r.CourseId).HasColumnName("course_id");
        builder.Property(r => r.Satisfaction).HasColumnName("satisfaction");
        builder.Property(r => r.Usefulness).HasColumnName("usefulness");
        builder.Property(r => r.CreatedDate).HasColumnName("created_date").HasColumnType("date");

        builder.HasIndex(r => new { r.CourseId, r.CreatedDate }).IsClustered().HasDatabaseName("cx_course_rating_course");

        // Solo hacia el curso. Sin navegación: nadie debería "llegar" a una calificación desde otra entidad.
        builder.HasOne<Course>()
            .WithMany()
            .HasForeignKey(r => r.CourseId)
            .HasConstraintName("fk_course_rating_course")
            .OnDelete(DeleteBehavior.Restrict);
    }
}
```

### Registro en `DOCCbDbContext.cs`

```csharp
modelBuilder.ApplyConfiguration(new CourseRatingConfiguration()); // nueva
// CourseAssignmentConfiguration y CourseAssignmentUserConfiguration ya estaban registradas.
```

---

## 7. Paso 4 — Cambios en la asignación de cursos

### DTOs ✏️

En `SaveCourseRequestDto.cs`, la asignación ahora es un **grupo** con su fecha:

```csharp
public class SaveCourseAssignmentDto
{
    /// <summary>null = asignación nueva.</summary>
    public int? AssignmentId { get; set; }
    public int GroupId { get; set; }
    public DateOnly DueDate { get; set; }
}

/// <summary>Resultado de crear o actualizar: el frontend avisa si hubo personas en dos grupos.</summary>
public class SaveCourseResultDto
{
    public int CourseId { get; set; }
    /// <summary>Personas que estaban en más de un grupo: quedaron asignadas por el primero.</summary>
    public int OverlappingUsers { get; set; }
}

public class SyncAssignmentResultDto
{
    public int Added { get; set; }
    public int RemovedPending { get; set; }
    /// <summary>Nuevos en el grupo que ya estaban en el curso por otro grupo.</summary>
    public int SkippedInOtherGroups { get; set; }
}
```

En `CourseDetailDtos.cs`, el detalle de cada asignación:

```csharp
public class CourseAssignmentDto
{
    public int AssignmentId { get; set; }
    public int GroupId { get; set; }
    public string GroupName { get; set; } = string.Empty;
    /// <summary>El grupo se eliminó después de asignarlo: sus personas siguen asignadas.</summary>
    public bool GroupRemoved { get; set; }
    public DateOnly DueDate { get; set; }
    public int TotalUsers { get; set; }
    public int CompletedUsers { get; set; }
}
```

`CourseUserDto` ya no se usa en el detalle del curso. `CourseListItemDto` y `CoursePageDto` no cambian.

### `Constants/CourseConstants.cs` ✏️ — mensajes nuevos

```csharp
public const string GroupRequired = "Elige el grupo.";
public const string GroupRepeated = "Ese grupo ya está asignado a este curso.";
public const string GroupChangeNotAllowed = "Para cambiar el grupo, quita la asignación y agrega el grupo nuevo.";
public const string GroupNotFound = "El grupo no existe o fue eliminado.";
public const string AssignmentNotFound = "La asignación no existe en este curso.";
```

### `Helpers/CourseValidationHelper.cs` ✏️

`AssignmentDraft` cambia y el bloque de asignaciones de `Normalize` valida grupos en lugar de usuarios:

```csharp
public sealed record AssignmentDraft(int? AssignmentId, int GroupId, DateOnly DueDate);

// Dentro de Normalize, reemplaza el ciclo de asignaciones por:
var assignments = new List<AssignmentDraft>();
var seenGroups = new HashSet<int>();
var seenAssignments = new HashSet<int>();

for (var i = 0; i < groups.Count; i++)
{
    var group = groups[i];
    var label = $"Asignación {i + 1}";

    if (group.GroupId <= 0)
        errors.Add($"{label}: {CourseConstants.GroupRequired}");
    else if (!seenGroups.Add(group.GroupId))
        errors.Add($"{label}: {CourseConstants.GroupRepeated}");

    if (group.AssignmentId is { } assignmentId && !seenAssignments.Add(assignmentId))
        errors.Add($"{label}: la asignación {assignmentId} viene repetida.");

    if (group.DueDate == default)
        errors.Add($"{label}: elige la fecha límite.");

    assignments.Add(new AssignmentDraft(group.AssignmentId, group.GroupId, group.DueDate));
}
```

### `Contracts/Persistence/ICourseRepository.cs` ✏️

Se agregan dos métodos y se quita `GetExistingUserIdsAsync`:

```csharp
/// <summary>Integrantes de un grupo al momento de asignarlo.</summary>
public sealed record GroupMemberSnapshot(string Email, string DisplayName, int? UserId, Guid? EntraObjectId);

public sealed record GroupSnapshot(int GroupId, string Name, IReadOnlyList<GroupMemberSnapshot> Members);

// En ICourseRepository:

/// <summary>Grupos activos con sus integrantes. Los que no existan no vienen en el diccionario.</summary>
Task<IReadOnlyDictionary<int, GroupSnapshot>> GetGroupSnapshotsAsync(IReadOnlyCollection<int> groupIds, CancellationToken ct);

/// <summary>Correos que ya tienen fila en el curso (incluye finalizados de grupos retirados).</summary>
Task<HashSet<string>> GetCourseEmailsAsync(int courseId, CancellationToken ct);

/// <summary>¿El curso tuvo alguna asignación, activa o retirada? Decide entre borrado lógico y físico.</summary>
Task<bool> HasAssignmentHistoryAsync(int courseId, CancellationToken ct);
```

### `Repositories/CourseRepository.cs` ✏️

**Listado:** los conteos y la próxima fecha solo miran asignaciones activas. La tarjeta del curso muestra grupos, personas y cuántas finalizaron, así que se agregan dos conteos (`AssignedGroupsCount` y `CompletedUsersCount`) al DTO del listado y a la fila intermedia del repositorio, junto a `AssignedUsersCount`.

```csharp
AssignedGroupsCount = c.Assignments.Count(a => !a.Removed),
AssignedUsersCount = c.Assignments.Where(a => !a.Removed).SelectMany(a => a.Users).Count(),
CompletedUsersCount = c.Assignments.Where(a => !a.Removed).SelectMany(a => a.Users)
                          .Count(u => u.Status == CourseCompletionStatus.Completed),
NextDueDate = c.Assignments.Where(a => !a.Removed && a.DueDate >= today).Min(a => (DateOnly?)a.DueDate)
              ?? c.Assignments.Where(a => !a.Removed && a.DueDate < today).Max(a => (DateOnly?)a.DueDate),
```

**Detalle:** cada asignación con su grupo y su avance.

```csharp
Assignments = c.Assignments
    .Where(a => !a.Removed)
    .OrderBy(a => a.DueDate)
    .Select(a => new CourseAssignmentDto
    {
        AssignmentId = a.Id,
        GroupId = a.GroupId,
        GroupName = a.Group.Name,
        GroupRemoved = a.Group.Removed,
        DueDate = a.DueDate,
        TotalUsers = a.Users.Count(),
        CompletedUsers = a.Users.Count(u => u.Status == CourseCompletionStatus.Completed),
    })
    .ToList(),
```

**Carga para editar:** solo asignaciones activas, con sus personas.

```csharp
public Task<Course?> GetForUpdateAsync(int courseId, bool includeAssignments, CancellationToken ct)
{
    IQueryable<Course> query = db.Set<Course>().Where(c => c.Id == courseId && !c.Removed);

    if (includeAssignments)
    {
        query = query
            .Include(c => c.Assignments.Where(a => !a.Removed))
            .ThenInclude(a => a.Users);
    }

    return query.AsSplitQuery().FirstOrDefaultAsync(ct);
}
```

**Métodos nuevos:**

```csharp
public async Task<IReadOnlyDictionary<int, GroupSnapshot>> GetGroupSnapshotsAsync(
    IReadOnlyCollection<int> groupIds, CancellationToken ct)
{
    if (groupIds.Count == 0) return new Dictionary<int, GroupSnapshot>();

    var groups = await db.Set<UserGroup>()
        .AsNoTracking()
        .Where(g => groupIds.Contains(g.Id) && !g.Removed)
        .Select(g => new
        {
            g.Id,
            g.Name,
            Members = g.Members
                .OrderBy(m => m.DisplayName)
                .Select(m => new GroupMemberSnapshot(m.Email, m.DisplayName, m.UserId, m.EntraObjectId))
                .ToList(),
        })
        .AsSplitQuery()
        .ToListAsync(ct);

    return groups.ToDictionary(g => g.Id, g => new GroupSnapshot(g.Id, g.Name, g.Members));
}

public async Task<HashSet<string>> GetCourseEmailsAsync(int courseId, CancellationToken ct)
{
    var emails = await db.Set<CourseAssignmentUser>()
        .AsNoTracking()
        .Where(u => u.CourseId == courseId)
        .Select(u => u.Email)
        .ToListAsync(ct);

    return emails.ToHashSet(StringComparer.OrdinalIgnoreCase);
}

public Task<bool> HasAssignmentHistoryAsync(int courseId, CancellationToken ct) =>
    db.Set<CourseAssignment>().AnyAsync(a => a.CourseId == courseId, ct);
```

### `Services/CourseService.cs` ✏️

Se reemplazan `CreateAsync`, `UpdateAsync`, `DeleteAsync` y `SyncAssignments`, y se agrega `SyncAssignmentAsync`. `FindMissingUsersAsync` y `NewAssignment` de la versión anterior se borran.

```csharp
public async Task<CourseResult<SaveCourseResultDto>> CreateAsync(
    SaveCourseRequestDto dto, string currentUser, CancellationToken ct = default)
{
    if (!CourseModalityCodes.TryParse(dto.Modality, out var modality))
        return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.InvalidModality);

    var (draft, errors) = CourseValidationHelper.Normalize(dto);
    if (draft is null) return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, errors);

    if (draft.Assignments.Any(a => a.AssignmentId is not null))
        return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, "Un curso nuevo no puede traer asignaciones existentes.");

    if (draft.Assignments.Any(a => a.DueDate < Today()))
        return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.PastDueDate);

    var conflict = await CheckUniquenessAsync(draft.Name, modality, draft.ExternalId, excludeCourseId: null, ct);
    if (conflict is not null) return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Conflict, conflict);

    var groups = await _repository.GetGroupSnapshotsAsync(draft.Assignments.Select(a => a.GroupId).ToList(), ct);
    var missingGroups = draft.Assignments.Where(a => !groups.ContainsKey(a.GroupId)).ToList();
    if (missingGroups.Count > 0)
        return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.GroupNotFound);

    var now = Now();
    var course = new Course
    {
        Name = draft.Name,
        Modality = modality,
        ExternalId = draft.ExternalId,
        CreatedDate = now,
        CreatedBy = currentUser,
    };

    var usedEmails = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var overlapping = 0;

    // El orden de la lista define quién gana si una persona está en dos grupos: el primero.
    foreach (var assignmentDraft in draft.Assignments)
    {
        var (assignment, skipped) = NewAssignment(assignmentDraft, groups[assignmentDraft.GroupId], usedEmails, now, currentUser);
        course.Assignments.Add(assignment);
        overlapping += skipped;
    }

    _repository.Add(course);

    var saveConflict = await TrySaveAsync(ct);
    return saveConflict is null
        ? CourseResult<SaveCourseResultDto>.Ok(new SaveCourseResultDto { CourseId = course.Id, OverlappingUsers = overlapping })
        : CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Conflict, saveConflict);
}

public async Task<CourseResult<SaveCourseResultDto>> UpdateAsync(
    int id, SaveCourseRequestDto dto, string currentUser, CancellationToken ct = default)
{
    var (draft, errors) = CourseValidationHelper.Normalize(dto);
    if (draft is null) return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, errors);

    var course = await _repository.GetForUpdateAsync(id, includeAssignments: true, ct);
    if (course is null) return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound);

    var conflict = await CheckUniquenessAsync(draft.Name, course.Modality, draft.ExternalId, id, ct);
    if (conflict is not null) return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Conflict, conflict);

    // ── Validaciones que necesitan lo guardado ──────────────────────
    var existing = course.Assignments.ToDictionary(a => a.Id);
    var today = Today();

    foreach (var assignmentDraft in draft.Assignments)
    {
        if (assignmentDraft.AssignmentId is { } assignmentId)
        {
            if (!existing.TryGetValue(assignmentId, out var current))
                return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.AssignmentNotFound);

            if (current.GroupId != assignmentDraft.GroupId)
                return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.GroupChangeNotAllowed);

            // Una fecha que no cambia se respeta aunque ya haya vencido.
            if (assignmentDraft.DueDate != current.DueDate && assignmentDraft.DueDate < today)
                return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.PastDueDate);
        }
        else if (assignmentDraft.DueDate < today)
        {
            return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.PastDueDate);
        }
    }

    var newDrafts = draft.Assignments.Where(a => a.AssignmentId is null).ToList();
    var groups = await _repository.GetGroupSnapshotsAsync(newDrafts.Select(a => a.GroupId).ToList(), ct);
    if (newDrafts.Any(a => !groups.ContainsKey(a.GroupId)))
        return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.GroupNotFound);

    // ── Cambios ─────────────────────────────────────────────────────
    var now = Now();
    course.Name = draft.Name;
    course.ExternalId = draft.ExternalId;
    course.UpdatedDate = now;
    course.UpdatedBy = currentUser;

    var usedEmails = await _repository.GetCourseEmailsAsync(id, ct);
    var keepIds = draft.Assignments.Where(a => a.AssignmentId is not null).Select(a => a.AssignmentId!.Value).ToHashSet();

    // 1. Asignaciones que ya no vienen
    foreach (var removed in course.Assignments.Where(a => !keepIds.Contains(a.Id)).ToList())
    {
        RetireAssignment(course, removed, usedEmails, now, currentUser);
    }

    // 2. Asignaciones que siguen: solo cambia la fecha
    foreach (var assignmentDraft in draft.Assignments.Where(a => a.AssignmentId is not null))
    {
        var assignment = existing[assignmentDraft.AssignmentId!.Value];
        if (assignment.DueDate == assignmentDraft.DueDate) continue;

        assignment.DueDate = assignmentDraft.DueDate;
        assignment.UpdatedDate = now;
        assignment.UpdatedBy = currentUser;
    }

    // 3. Grupos nuevos
    var overlapping = 0;
    foreach (var assignmentDraft in newDrafts)
    {
        var (assignment, skipped) = NewAssignment(assignmentDraft, groups[assignmentDraft.GroupId], usedEmails, now, currentUser);
        course.Assignments.Add(assignment);
        overlapping += skipped;
    }

    var saveConflict = await TrySaveAsync(ct);
    return saveConflict is null
        ? CourseResult<SaveCourseResultDto>.Ok(new SaveCourseResultDto { CourseId = id, OverlappingUsers = overlapping })
        : CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Conflict, saveConflict);
}

/// <summary>"Actualizar desde el grupo": agrega a los nuevos y quita a los pendientes que salieron.</summary>
public async Task<CourseResult<SyncAssignmentResultDto>> SyncAssignmentAsync(
    int courseId, int assignmentId, string currentUser, CancellationToken ct = default)
{
    var course = await _repository.GetForUpdateAsync(courseId, includeAssignments: true, ct);
    var assignment = course?.Assignments.FirstOrDefault(a => a.Id == assignmentId);
    if (course is null || assignment is null)
        return CourseResult<SyncAssignmentResultDto>.Fail(CourseResultStatus.NotFound, CourseConstants.AssignmentNotFound);

    var groups = await _repository.GetGroupSnapshotsAsync([assignment.GroupId], ct);
    if (!groups.TryGetValue(assignment.GroupId, out var group))
        return CourseResult<SyncAssignmentResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.GroupNotFound);

    var groupEmails = group.Members.Select(m => m.Email).ToHashSet(StringComparer.OrdinalIgnoreCase);
    var usedEmails = await _repository.GetCourseEmailsAsync(courseId, ct);
    var now = Now();

    // Pendientes que ya no están en el grupo. Los finalizados se conservan siempre.
    var removedPending = 0;
    foreach (var user in assignment.Users.Where(u => u.Status == CourseCompletionStatus.Pending && !groupEmails.Contains(u.Email)).ToList())
    {
        assignment.Users.Remove(user);
        _repository.Remove(user);
        usedEmails.Remove(user.Email);
        removedPending++;
    }

    var added = 0;
    var skipped = 0;
    foreach (var member in group.Members)
    {
        if (assignment.Users.Any(u => string.Equals(u.Email, member.Email, StringComparison.OrdinalIgnoreCase))) continue;
        if (!usedEmails.Add(member.Email))
        {
            skipped++; // ya está en el curso por otro grupo
            continue;
        }

        assignment.Users.Add(NewAssignmentUser(member, now));
        added++;
    }

    assignment.UpdatedDate = now;
    assignment.UpdatedBy = currentUser;
    await _repository.SaveChangesAsync(ct);

    return CourseResult<SyncAssignmentResultDto>.Ok(new SyncAssignmentResultDto
    {
        Added = added,
        RemovedPending = removedPending,
        SkippedInOtherGroups = skipped,
    });
}

public async Task<CourseResult<bool>> DeleteAsync(int id, string currentUser, CancellationToken ct = default)
{
    var course = await _repository.GetForUpdateAsync(id, includeAssignments: false, ct);
    if (course is null) return CourseResult<bool>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound);

    if (await _repository.HasAssignmentHistoryAsync(id, ct))
    {
        // Tuvo asignaciones: se conserva el historial y el curso deja de listarse.
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

// ── Privados nuevos ─────────────────────────────────────────────────

private static (CourseAssignment Assignment, int Skipped) NewAssignment(
    AssignmentDraft draft, GroupSnapshot group, HashSet<string> usedEmails, DateTime now, string currentUser)
{
    var assignment = new CourseAssignment
    {
        GroupId = draft.GroupId,
        DueDate = draft.DueDate,
        CreatedDate = now,
        CreatedBy = currentUser,
    };

    var skipped = 0;
    foreach (var member in group.Members)
    {
        // Una persona, una asignación por curso: si ya la trajo otro grupo, se queda en el primero.
        if (!usedEmails.Add(member.Email))
        {
            skipped++;
            continue;
        }

        assignment.Users.Add(NewAssignmentUser(member, now));
    }

    return (assignment, skipped);
}

private static CourseAssignmentUser NewAssignmentUser(GroupMemberSnapshot member, DateTime now) => new()
{
    Email = member.Email,
    DisplayName = member.DisplayName,
    UserId = member.UserId,
    EntraObjectId = member.EntraObjectId,
    Status = CourseCompletionStatus.Pending, // estado normal al asignar
    CreatedDate = now,
    // AssignmentId y CourseId los completa EF desde la navegación al guardar.
};

/// <summary>Con finalizados: retiro lógico y se borran los pendientes. Sin finalizados: se borra.</summary>
private void RetireAssignment(Course course, CourseAssignment assignment, HashSet<string> usedEmails, DateTime now, string currentUser)
{
    var hasCompleted = assignment.Users.Any(u => u.Status == CourseCompletionStatus.Completed);

    foreach (var user in assignment.Users.Where(u => u.Status == CourseCompletionStatus.Pending).ToList())
    {
        assignment.Users.Remove(user);
        _repository.Remove(user);
        usedEmails.Remove(user.Email); // queda libre para que otro grupo del mismo guardado la asigne
    }

    if (hasCompleted)
    {
        assignment.Removed = true;
        assignment.UpdatedDate = now;
        assignment.UpdatedBy = currentUser;
        return;
    }

    course.Assignments.Remove(assignment);
    _repository.Remove(assignment);
}
```

> `TrySaveAsync` ya traduce los índices únicos a mensajes. Agrega el caso del índice nuevo en su `switch`:
> `CourseIndexNames.CourseGroup => CourseConstants.GroupRepeated,`

En `ICourseService` cambian los tipos de `CreateAsync` y `UpdateAsync` a `CourseResult<SaveCourseResultDto>` y se agrega `SyncAssignmentAsync`.

---

## 8. Paso 5 — ⭐ El formulario de finalización

### `DTOs/CurrentUserIdentity.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

/// <summary>
/// Quién es el usuario autenticado. El correo del token suele ser el UPN, que puede no
/// coincidir con el correo guardado; por eso también se usa el object id de Entra ID.
/// </summary>
public sealed record CurrentUserIdentity(Guid? ObjectId, IReadOnlyList<string> Emails)
{
    public bool Owns(string email, Guid? entraObjectId) =>
        (ObjectId is { } oid && entraObjectId == oid)
        || Emails.Contains(email, StringComparer.OrdinalIgnoreCase);
}
```

### `Constants/CompletionConstants.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.Constants;

public static class CompletionConstants
{
    public const int MinRating = 0;
    public const int MaxRating = 5;

    /// <summary>Menos respuestas que esto y los promedios no se muestran: protege el anonimato.</summary>
    public const int MinimumResponsesForSummary = 3;

    public const string FormNotFound = "No encontramos este curso entre tus asignaciones.";
    public const string AlreadyCompleted = "Ya marcaste este curso como finalizado.";
    public const string RatingsRequired = "Califica la satisfacción y la utilidad del curso (de 0 a 5).";

    public static class Status
    {
        public const string Pending = "PENDING";
        public const string Completed = "COMPLETED";
        public const string Overdue = "OVERDUE";
    }
}
```

### `DTOs/CompletionDtos.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

/// <summary>Una fila de "Mis cursos".</summary>
public class MyCourseDto
{
    public int AssignmentUserId { get; set; }
    public int CourseId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public string Modality { get; set; } = string.Empty;
    public string? ExternalId { get; set; }
    public DateOnly DueDate { get; set; }
    public string Status { get; set; } = string.Empty;   // PENDING | COMPLETED
    public DateTime? CompletedDate { get; set; }
    public bool IsOverdue { get; set; }
}

/// <summary>Lo que muestra el formulario. Todo de solo lectura para el usuario.</summary>
public class CompletionFormDto
{
    public int AssignmentUserId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public string Modality { get; set; } = string.Empty;
    public DateOnly DueDate { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime? CompletedDate { get; set; }
    public bool IsOverdue { get; set; }
    public string UserDisplayName { get; set; } = string.Empty;
    public string UserEmail { get; set; } = string.Empty;

    /// <summary>Gerencia del directorio activo. null si no se pudo consultar.</summary>
    public string? Management { get; set; }
}

/// <summary>El usuario solo envía las dos calificaciones. Ni la gerencia ni la fecha.</summary>
public class CompleteCourseRequestDto
{
    public int? Satisfaction { get; set; }
    public int? Usefulness { get; set; }
}

public class CompletionResultDto
{
    public DateTime CompletedDate { get; set; }
}
```

### `Interfaces/IManagementDirectory.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Interfaces;

/// <summary>Gerencia a la que pertenece el usuario según el directorio activo.</summary>
public interface IManagementDirectory
{
    /// <summary>null si no se pudo obtener. No lanza por fallas del directorio.</summary>
    Task<string?> GetManagementAsync(CurrentUserIdentity user, CancellationToken ct);
}
```

### `Services/ManagementDirectory.cs` — conecta tu método existente

Ya tienes un método que trae la gerencia desde el directorio activo. Esta clase solo lo adapta al contrato, para que el formulario no dependa de cómo se consulta.

```csharp
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Interfaces;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.Courses.Application.Services;

public class ManagementDirectory(
    /* ⬇ el servicio donde vive tu método actual */ IUserManagementService userManagement,
    ILogger<ManagementDirectory> logger) : IManagementDirectory
{
    public async Task<string?> GetManagementAsync(CurrentUserIdentity user, CancellationToken ct)
    {
        try
        {
            foreach (var email in user.Emails)
            {
                // ⬇ Reemplaza por la llamada real a tu método que trae la gerencia.
                var management = await userManagement.GetManagementByEmailAsync(email);
                if (!string.IsNullOrWhiteSpace(management)) return management.Trim();
            }

            return null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Si el directorio no responde, el formulario se muestra igual con la gerencia "No disponible".
            logger.LogWarning(ex, "No se pudo consultar la gerencia en el directorio activo.");
            return null;
        }
    }
}
```

> Si tu método recibe el object id en vez del correo, usa `user.ObjectId`.

### `Contracts/Persistence/ICourseCompletionRepository.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Contracts.Persistence;

/// <summary>Una asignación de persona con los datos del curso, sin seguimiento.</summary>
public sealed record AssignmentUserRow(
    int Id,
    int CourseId,
    string CourseName,
    CourseModality Modality,
    DateOnly DueDate,
    string Email,
    string DisplayName,
    Guid? EntraObjectId,
    CourseCompletionStatus Status,
    DateTime? CompletedDate,
    bool AssignmentRemoved,
    bool CourseRemoved);

public interface ICourseCompletionRepository
{
    Task<IReadOnlyList<AssignmentUserRow>> GetMyAssignmentsAsync(CurrentUserIdentity user, CancellationToken ct);
    Task<AssignmentUserRow?> GetAssignmentUserAsync(int assignmentUserId, CancellationToken ct);

    /// <summary>
    /// En una transacción: pasa la fila a COMPLETED solo si sigue PENDING, y guarda la calificación.
    /// false = ya estaba finalizada (otra petición llegó primero).
    /// </summary>
    Task<bool> TryCompleteAsync(int assignmentUserId, DateTime completedDate, string? management, CourseRating rating, CancellationToken ct);

    Task<CourseProgressDto?> GetProgressAsync(int courseId, DateOnly today, CancellationToken ct);
    Task<RatingSummaryDto> GetRatingSummaryAsync(int courseId, int minimumResponses, CancellationToken ct);
    Task<AssignedUsersPageDto> GetAssignmentUsersAsync(int courseId, int assignmentId, AssignedUsersQuery query, DateOnly today, CancellationToken ct);
}
```

### `Repositories/CourseCompletionRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using DOCCB.Infraestructure.Common;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using System.Linq.Expressions;

namespace DOCCB.Infraestructure.Repositories;

/// <summary>
/// Hereda de GenericRepositoryBase como el resto de repositorios: _dbSet es course_assignment_user
/// y _context da acceso a course, course_assignment y course_rating.
/// </summary>
public class CourseCompletionRepository(DOCCbDbContext context)
    : GenericRepositoryBase<DOCCbDbContext, CourseAssignmentUser>(context), ICourseCompletionRepository
{
    /// <summary>Una sola proyección para "Mis cursos" y para el formulario.</summary>
    private static readonly Expression<Func<CourseAssignmentUser, AssignmentUserRow>> ToRow =
        u => new AssignmentUserRow(
                u.Id,
                u.CourseId,
                u.Assignment.Course.Name,
                u.Assignment.Course.Modality,
                u.Assignment.DueDate,
                u.Email,
                u.DisplayName,
                u.EntraObjectId,
                u.Status,
                u.CompletedDate,
                u.Assignment.Removed,
                u.Assignment.Course.Removed);

    public Task<IReadOnlyList<AssignmentUserRow>> GetMyAssignmentsAsync(CurrentUserIdentity user, CancellationToken ct) =>
        Guard<IReadOnlyList<AssignmentUserRow>>(async () =>
        {
            var emails = user.Emails.ToList();
            var oid = user.ObjectId;

            return await _dbSet
                .AsNoTracking()
                .Where(u => emails.Contains(u.Email) || (oid != null && u.EntraObjectId == oid))
                .Where(u => !u.Assignment.Course.Removed)
                // Si retiraron el grupo, el pendiente desaparece; lo finalizado se sigue viendo.
                .Where(u => !u.Assignment.Removed || u.Status == CourseCompletionStatus.Completed)
                .Select(ToRow)
                .ToListAsync(ct);
        });

    public Task<AssignmentUserRow?> GetAssignmentUserAsync(int assignmentUserId, CancellationToken ct) =>
        Guard(() => _dbSet
            .AsNoTracking()
            .Where(u => u.Id == assignmentUserId)
            .Select(ToRow)
            .FirstOrDefaultAsync(ct));

    public Task<bool> TryCompleteAsync(
        int assignmentUserId, DateTime completedDate, string? management, CourseRating rating, CancellationToken ct) =>
        Guard(() => CompleteInTransactionAsync(assignmentUserId, completedDate, management, rating, ct));

    private Task<bool> CompleteInTransactionAsync(
        int assignmentUserId, DateTime completedDate, string? management, CourseRating rating, CancellationToken ct)
    {
        // Si el DbContext usa EnableRetryOnFailure, las transacciones deben ir dentro de la estrategia.
        var strategy = _context.Database.CreateExecutionStrategy();

        return strategy.ExecuteAsync(async () =>
        {
            await using var transaction = await _context.Database.BeginTransactionAsync(ct);

            // UPDATE condicional: la segunda petición de un doble clic no encuentra la fila PENDING.
            var affected = await _dbSet
                .Where(u => u.Id == assignmentUserId && u.Status == CourseCompletionStatus.Pending)
                .ExecuteUpdateAsync(set => set
                    .SetProperty(u => u.Status, CourseCompletionStatus.Completed)
                    .SetProperty(u => u.CompletedDate, completedDate)
                    .SetProperty(u => u.ManagementName, management), ct);

            if (affected == 0)
            {
                await transaction.RollbackAsync(ct);
                return false;
            }

            // La calificación va en la misma transacción, pero sin ninguna referencia a la persona.
            _context.Set<CourseRating>().Add(rating);
            await _context.SaveChangesAsync(ct);
            await transaction.CommitAsync(ct);
            return true;
        });
    }

    public Task<CourseProgressDto?> GetProgressAsync(int courseId, DateOnly today, CancellationToken ct) =>
        Guard(() => _context.Set<Course>()
            .AsNoTracking()
            .Where(c => c.Id == courseId && !c.Removed)
            .Select(c => new CourseProgressDto
            {
                CourseId = c.Id,
                CourseName = c.Name,
                Assignments = c.Assignments
                    .Where(a => !a.Removed)
                    .OrderBy(a => a.DueDate)
                    .Select(a => new AssignmentProgressDto
                    {
                        AssignmentId = a.Id,
                        GroupName = a.Group.Name,
                        DueDate = a.DueDate,
                        Total = a.Users.Count(),
                        Completed = a.Users.Count(u => u.Status == CourseCompletionStatus.Completed),
                        Overdue = a.DueDate < today ? a.Users.Count(u => u.Status == CourseCompletionStatus.Pending) : 0,
                    })
                    .ToList(),
            })
            .FirstOrDefaultAsync(ct));

    public Task<RatingSummaryDto> GetRatingSummaryAsync(int courseId, int minimumResponses, CancellationToken ct) =>
        Guard(() => BuildRatingSummaryAsync(courseId, minimumResponses, ct));

    private async Task<RatingSummaryDto> BuildRatingSummaryAsync(int courseId, int minimumResponses, CancellationToken ct)
    {
        var ratings = _context.Set<CourseRating>().AsNoTracking().Where(r => r.CourseId == courseId);
        var responses = await ratings.CountAsync(ct);

        // Con pocas respuestas un promedio puede delatar a alguien: solo se devuelve el conteo.
        if (responses < minimumResponses)
        {
            return new RatingSummaryDto { Responses = responses, Visible = false, MinimumResponses = minimumResponses };
        }

        var satisfaction = await ratings.GroupBy(r => r.Satisfaction).Select(g => new { Score = g.Key, Count = g.Count() }).ToListAsync(ct);
        var usefulness = await ratings.GroupBy(r => r.Usefulness).Select(g => new { Score = g.Key, Count = g.Count() }).ToListAsync(ct);

        int[] Distribution(IEnumerable<(byte Score, int Count)> groups)
        {
            var buckets = new int[CompletionConstants.MaxRating + 1];
            foreach (var (score, count) in groups) buckets[score] = count;
            return buckets;
        }

        var satisfactionBuckets = Distribution(satisfaction.Select(x => (x.Score, x.Count)));
        var usefulnessBuckets = Distribution(usefulness.Select(x => (x.Score, x.Count)));

        return new RatingSummaryDto
        {
            Responses = responses,
            Visible = true,
            MinimumResponses = minimumResponses,
            SatisfactionAverage = Math.Round(satisfactionBuckets.Select((count, score) => count * score).Sum() / (double)responses, 1),
            UsefulnessAverage = Math.Round(usefulnessBuckets.Select((count, score) => count * score).Sum() / (double)responses, 1),
            SatisfactionDistribution = satisfactionBuckets,
            UsefulnessDistribution = usefulnessBuckets,
        };
    }

    public Task<AssignedUsersPageDto> GetAssignmentUsersAsync(
        int courseId, int assignmentId, AssignedUsersQuery query, DateOnly today, CancellationToken ct) =>
        Guard(() => BuildAssignmentUsersAsync(courseId, assignmentId, query, today, ct));

    private async Task<AssignedUsersPageDto> BuildAssignmentUsersAsync(
        int courseId, int assignmentId, AssignedUsersQuery query, DateOnly today, CancellationToken ct)
    {
        var users = _dbSet
            .AsNoTracking()
            .Where(u => u.CourseId == courseId && u.AssignmentId == assignmentId);

        if (query.Search is { Length: > 0 } term)
        {
            users = users.Where(u => u.DisplayName.Contains(term) || u.Email.Contains(term));
        }

        users = query.Status switch
        {
            CompletionConstants.Status.Completed => users.Where(u => u.Status == CourseCompletionStatus.Completed),
            CompletionConstants.Status.Pending => users.Where(u => u.Status == CourseCompletionStatus.Pending),
            CompletionConstants.Status.Overdue => users.Where(u => u.Status == CourseCompletionStatus.Pending && u.Assignment.DueDate < today),
            _ => users,
        };

        var total = await users.CountAsync(ct);

        var items = await users
            .OrderBy(u => u.DisplayName)
            .ThenBy(u => u.Id)
            .Skip((query.Page - 1) * query.PageSize)
            .Take(query.PageSize)
            .Select(u => new
            {
                u.DisplayName,
                u.Email,
                InDoccb = u.UserId != null,
                u.Status,
                u.CompletedDate,
                u.ManagementName,
                u.Assignment.DueDate,
            })
            .ToListAsync(ct);

        return new AssignedUsersPageDto
        {
            TotalCount = total,
            Items = items.Select(u => new AssignedUserProgressDto
            {
                DisplayName = u.DisplayName,
                Email = u.Email,
                InDoccb = u.InDoccb,
                Status = u.Status == CourseCompletionStatus.Completed ? CompletionConstants.Status.Completed : CompletionConstants.Status.Pending,
                IsOverdue = u.Status == CourseCompletionStatus.Pending && u.DueDate < today,
                CompletedDate = u.CompletedDate,
                Management = u.ManagementName,
            }).ToList(),
        };
    }

    /// <summary>
    /// Misma convención que GenericRepositoryBase: los errores de base de datos suben tal cual
    /// y cualquier otro se envuelve con el nombre de la entidad. La cancelación nunca se envuelve.
    /// </summary>
    private static async Task<TResult> Guard<TResult>(Func<Task<TResult>> action)
    {
        try
        {
            return await action();
        }
        catch (Exception ex) when (ex is not (OperationCanceledException or DbUpdateException or SqlException or TimeoutException))
        {
            throw new InvalidOperationException($"Error en el repositorio para la entidad {nameof(CourseAssignmentUser)}.", ex);
        }
    }
}
```

> **Por qué `Guard`:** `GenericRepositoryBase` deja subir `DbUpdateException`, `SqlException` y `TimeoutException`, y envuelve cualquier otra excepción en `InvalidOperationException`. `Guard` aplica esa convención a los métodos propios de este repositorio y además deja pasar `OperationCanceledException`, que la base hoy envuelve (ver [referencia-estilos-y-capas-doccb.md](referencia-estilos-y-capas-doccb.md)). Si agregas ese `catch` a la base, puedes mover `Guard` allí como método `protected` y reutilizarlo en `CourseRepository` y `UserGroupRepository`.

### `Services/CourseCompletionService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Application.Features.Courses.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Courses.Application.Services;

public class CourseCompletionService(
    ICourseCompletionRepository repository,
    IManagementDirectory managementDirectory,
    TimeProvider timeProvider) : ICourseCompletionService
{
    // ── Mis cursos ──────────────────────────────────────────────────

    public async Task<ServiceResult<List<MyCourseDto>>> GetMyCoursesAsync(CurrentUserIdentity user, CancellationToken ct = default)
    {
        var today = BusinessDate.Today(timeProvider);
        var rows = await repository.GetMyAssignmentsAsync(user, ct);

        var courses = rows
            .Select(row => new MyCourseDto
            {
                AssignmentUserId = row.Id,
                CourseId = row.CourseId,
                CourseName = row.CourseName,
                Modality = CourseModalityCodes.ToCode(row.Modality),
                DueDate = row.DueDate,
                Status = ToCode(row.Status),
                CompletedDate = row.CompletedDate,
                IsOverdue = IsOverdue(row, today),
            })
            // Primero los pendientes, del más urgente al menos urgente; luego los finalizados, del más reciente.
            .OrderBy(c => c.Status == CompletionConstants.Status.Completed)
            .ThenBy(c => c.Status == CompletionConstants.Status.Completed ? DateOnly.MaxValue : c.DueDate)
            .ThenByDescending(c => c.CompletedDate)
            .ToList();

        return ServiceResult<List<MyCourseDto>>.Ok(courses);
    }

    // ── Formulario ──────────────────────────────────────────────────

    public async Task<ServiceResult<CompletionFormDto>> GetFormAsync(
        int assignmentUserId, CurrentUserIdentity user, CancellationToken ct = default)
    {
        var row = await FindOwnedAsync(assignmentUserId, user, ct);
        if (row is null) return ServiceResult<CompletionFormDto>.Fail(ServiceResultStatus.NotFound, CompletionConstants.FormNotFound);

        // La gerencia se consulta cada vez que se abre el formulario, como pide el requisito.
        var management = row.Status == CourseCompletionStatus.Pending
            ? await managementDirectory.GetManagementAsync(user, ct)
            : null;

        return ServiceResult<CompletionFormDto>.Ok(new CompletionFormDto
        {
            AssignmentUserId = row.Id,
            CourseName = row.CourseName,
            Modality = CourseModalityCodes.ToCode(row.Modality),
            DueDate = row.DueDate,
            Status = ToCode(row.Status),
            CompletedDate = row.CompletedDate,
            IsOverdue = IsOverdue(row, BusinessDate.Today(timeProvider)),
            UserDisplayName = row.DisplayName,
            UserEmail = row.Email,
            Management = management,
        });
    }

    public async Task<ServiceResult<CompletionResultDto>> CompleteAsync(
        int assignmentUserId, CompleteCourseRequestDto dto, CurrentUserIdentity user, CancellationToken ct = default)
    {
        if (!IsValidRating(dto.Satisfaction) || !IsValidRating(dto.Usefulness))
            return ServiceResult<CompletionResultDto>.Fail(ServiceResultStatus.Invalid, CompletionConstants.RatingsRequired);

        var row = await FindOwnedAsync(assignmentUserId, user, ct);
        if (row is null) return ServiceResult<CompletionResultDto>.Fail(ServiceResultStatus.NotFound, CompletionConstants.FormNotFound);

        if (row.Status == CourseCompletionStatus.Completed || row.AssignmentRemoved)
            return ServiceResult<CompletionResultDto>.Fail(ServiceResultStatus.Conflict, CompletionConstants.AlreadyCompleted);

        // La gerencia NO viene del navegador: se vuelve a consultar aquí.
        var management = await managementDirectory.GetManagementAsync(user, ct);
        var completedDate = timeProvider.GetUtcNow().UtcDateTime;

        var rating = new CourseRating
        {
            Id = Guid.NewGuid(),
            CourseId = row.CourseId,
            Satisfaction = (byte)dto.Satisfaction!.Value,
            Usefulness = (byte)dto.Usefulness!.Value,
            CreatedDate = BusinessDate.Today(timeProvider), // requisito: fecha del registro, sin pedírsela al usuario
        };

        var completed = await repository.TryCompleteAsync(assignmentUserId, completedDate, management, rating, ct);

        return completed
            ? ServiceResult<CompletionResultDto>.Ok(new CompletionResultDto { CompletedDate = completedDate })
            : ServiceResult<CompletionResultDto>.Fail(ServiceResultStatus.Conflict, CompletionConstants.AlreadyCompleted);
    }

    // ── Seguimiento (administración) ────────────────────────────────

    public async Task<ServiceResult<CourseProgressDto>> GetProgressAsync(int courseId, CancellationToken ct = default)
    {
        var progress = await repository.GetProgressAsync(courseId, BusinessDate.Today(timeProvider), ct);
        if (progress is null) return ServiceResult<CourseProgressDto>.Fail(ServiceResultStatus.NotFound, CourseConstants.CourseNotFound);

        progress.Ratings = await repository.GetRatingSummaryAsync(courseId, CompletionConstants.MinimumResponsesForSummary, ct);
        return ServiceResult<CourseProgressDto>.Ok(progress);
    }

    public async Task<ServiceResult<AssignedUsersPageDto>> GetAssignmentUsersAsync(
        int courseId, int assignmentId, AssignedUsersQueryDto dto, CancellationToken ct = default)
    {
        var search = dto.Search?.Trim();
        var query = new AssignedUsersQuery(
            string.IsNullOrEmpty(search) ? null : search[..Math.Min(search.Length, 100)],
            dto.Status?.Trim().ToUpperInvariant(),
            Math.Max(1, dto.Page),
            Math.Clamp(dto.PageSize, 1, 100));

        var page = await repository.GetAssignmentUsersAsync(courseId, assignmentId, query, BusinessDate.Today(timeProvider), ct);
        return ServiceResult<AssignedUsersPageDto>.Ok(page);
    }

    // ── Privados ────────────────────────────────────────────────────

    /// <summary>
    /// Si la fila no existe o es de otra persona, responde lo mismo: "no encontrado".
    /// Así nadie puede averiguar ids de asignaciones ajenas probando números.
    /// </summary>
    private async Task<AssignmentUserRow?> FindOwnedAsync(int id, CurrentUserIdentity user, CancellationToken ct)
    {
        var row = await repository.GetAssignmentUserAsync(id, ct);

        if (row is null || row.CourseRemoved || !user.Owns(row.Email, row.EntraObjectId)) return null;
        if (row.AssignmentRemoved && row.Status == CourseCompletionStatus.Pending) return null;

        return row;
    }

    private static bool IsValidRating(int? value) =>
        value is >= CompletionConstants.MinRating and <= CompletionConstants.MaxRating;

    private static bool IsOverdue(AssignmentUserRow row, DateOnly today) =>
        row.Status == CourseCompletionStatus.Pending && row.DueDate < today;

    private static string ToCode(CourseCompletionStatus status) =>
        status == CourseCompletionStatus.Completed ? CompletionConstants.Status.Completed : CompletionConstants.Status.Pending;
}
```

> Este servicio **no escribe logs** con el usuario y sus calificaciones. Mantenlo así.

### `Interfaces/ICourseCompletionService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Interfaces;

public interface ICourseCompletionService
{
    Task<ServiceResult<List<MyCourseDto>>> GetMyCoursesAsync(CurrentUserIdentity user, CancellationToken ct = default);
    Task<ServiceResult<CompletionFormDto>> GetFormAsync(int assignmentUserId, CurrentUserIdentity user, CancellationToken ct = default);
    Task<ServiceResult<CompletionResultDto>> CompleteAsync(int assignmentUserId, CompleteCourseRequestDto dto, CurrentUserIdentity user, CancellationToken ct = default);

    Task<ServiceResult<CourseProgressDto>> GetProgressAsync(int courseId, CancellationToken ct = default);
    Task<ServiceResult<AssignedUsersPageDto>> GetAssignmentUsersAsync(int courseId, int assignmentId, AssignedUsersQueryDto dto, CancellationToken ct = default);
}
```

---

## 9. Paso 6 — Seguimiento (DTOs)

### `DTOs/CourseProgressDtos.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

public class CourseProgressDto
{
    public int CourseId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public List<AssignmentProgressDto> Assignments { get; set; } = [];
    public RatingSummaryDto Ratings { get; set; } = new();
}

public class AssignmentProgressDto
{
    public int AssignmentId { get; set; }
    public string GroupName { get; set; } = string.Empty;
    public DateOnly DueDate { get; set; }
    public int Total { get; set; }
    public int Completed { get; set; }
    /// <summary>Pendientes con la fecha límite ya pasada.</summary>
    public int Overdue { get; set; }
}

/// <summary>Resumen anónimo. Si Visible es false, solo se informa cuántas respuestas hay.</summary>
public class RatingSummaryDto
{
    public int Responses { get; set; }
    public bool Visible { get; set; }
    public int MinimumResponses { get; set; }
    public double? SatisfactionAverage { get; set; }
    public double? UsefulnessAverage { get; set; }
    /// <summary>Índice = calificación (0 a 5); valor = cuántas respuestas.</summary>
    public int[]? SatisfactionDistribution { get; set; }
    public int[]? UsefulnessDistribution { get; set; }
}

public class AssignedUsersQueryDto
{
    public string? Search { get; set; }
    /// <summary>PENDING | COMPLETED | OVERDUE | vacío = todos</summary>
    public string? Status { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 20;
}

public sealed record AssignedUsersQuery(string? Search, string? Status, int Page, int PageSize);

public class AssignedUserProgressDto
{
    public string DisplayName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public bool InDoccb { get; set; }
    public string Status { get; set; } = string.Empty;
    public bool IsOverdue { get; set; }
    public DateTime? CompletedDate { get; set; }
    public string? Management { get; set; }
}

public class AssignedUsersPageDto
{
    public List<AssignedUserProgressDto> Items { get; set; } = [];
    public int TotalCount { get; set; }
}
```

---

## 10. Paso 7 — Controladores

### `WebApp/Common/Helper/ControllerExtensions.cs` ✏️ — identidad del usuario

```csharp
/// <summary>Object id de Entra ID + todos los correos que trae el token, normalizados.</summary>
public static CurrentUserIdentity CurrentIdentity(this ClaimsPrincipal user)
{
    var oidClaim = user.FindFirstValue("oid")
        ?? user.FindFirstValue("http://schemas.microsoft.com/identity/claims/objectidentifier");

    var emails = new[] { "preferred_username", ClaimTypes.Email, "email", ClaimTypes.Upn, "upn" }
        .Select(user.FindFirstValue)
        .Where(value => !string.IsNullOrWhiteSpace(value) && value.Contains('@'))
        .Select(value => value!.Trim().ToLowerInvariant())
        .Distinct()
        .ToList();

    return new CurrentUserIdentity(Guid.TryParse(oidClaim, out var oid) ? oid : null, emails);
}
```

### `WebApp/Controllers/MyCoursesController.cs`

Para **cualquier** usuario autenticado: cada uno solo ve y diligencia lo suyo.

```csharp
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using WebApp.Common.Helper;

namespace WebApp.Controllers;

[ApiController]
[Route("api/my-courses")]
[Authorize]
public class MyCoursesController(ICourseCompletionService service) : ControllerBase
{
    private readonly ICourseCompletionService _service = service;

    [HttpGet]
    public async Task<IActionResult> GetMyCourses(CancellationToken ct) =>
        this.ToActionResult(await _service.GetMyCoursesAsync(User.CurrentIdentity(), ct));

    [HttpGet("{id:int}/completion-form")]
    public async Task<IActionResult> GetForm(int id, CancellationToken ct) =>
        this.ToActionResult(await _service.GetFormAsync(id, User.CurrentIdentity(), ct));

    /// <summary>⚠️ No registres el cuerpo de esta petición en logs: contiene calificaciones anónimas.</summary>
    [HttpPost("{id:int}/complete")]
    public async Task<IActionResult> Complete(int id, [FromBody] CompleteCourseRequestDto dto, CancellationToken ct) =>
        this.ToActionResult(await _service.CompleteAsync(id, dto, User.CurrentIdentity(), ct));
}
```

### `WebApp/Controllers/CoursesController.cs` ✏️ — acciones nuevas

Inyecta también `ICourseCompletionService`.

```csharp
[HttpPost("{id:int}/assignments/{assignmentId:int}/sync")]
public async Task<IActionResult> SyncAssignment(int id, int assignmentId, CancellationToken ct) =>
    ToActionResult(await _courseService.SyncAssignmentAsync(id, assignmentId, CurrentUser, ct));

[HttpGet("{id:int}/progress")]
public async Task<IActionResult> GetProgress(int id, CancellationToken ct) =>
    this.ToActionResult(await _completionService.GetProgressAsync(id, ct));

[HttpGet("{id:int}/assignments/{assignmentId:int}/users")]
public async Task<IActionResult> GetAssignmentUsers(
    int id, int assignmentId, [FromQuery] AssignedUsersQueryDto query, CancellationToken ct) =>
    this.ToActionResult(await _completionService.GetAssignmentUsersAsync(id, assignmentId, query, ct));
```

Estas acciones quedan bajo el permiso de administración de cursos que ya tiene el controlador.

---

## 11. Paso 8 — Registro de dependencias

`ApplicationServiceRegistration.cs`:

```csharp
services.AddScoped<ICourseCompletionService, CourseCompletionService>();
services.AddScoped<IManagementDirectory, ManagementDirectory>();
```

`InfrastructureServiceRegistration.cs`:

```csharp
services.AddScoped<ICourseCompletionRepository, CourseCompletionRepository>();
```

---

## 12. Contrato resultante

| Método | Ruta | Quién | Respuesta |
|---|---|---|---|
| `POST` | `/api/courses` | Admin | `201` `{ courseId, overlappingUsers }` |
| `PUT` | `/api/courses/{id}` | Admin | `200` `{ courseId, overlappingUsers }` |
| `GET` | `/api/courses/{id}` | Admin | Detalle; cada asignación con `groupId`, `groupName`, `dueDate`, `totalUsers`, `completedUsers` |
| `POST` | `/api/courses/{id}/assignments/{assignmentId}/sync` | Admin | `{ added, removedPending, skippedInOtherGroups }` |
| `GET` | `/api/courses/{id}/progress` | Admin | Avance por grupo + resumen anónimo de calificaciones |
| `GET` | `/api/courses/{id}/assignments/{assignmentId}/users?search=&status=&page=` | Admin | Personas con estado, gerencia y fecha de finalización |
| `GET` | `/api/my-courses` | Cualquier usuario | Sus cursos, pendientes primero |
| `GET` | `/api/my-courses/{id}/completion-form` | El dueño | Datos del formulario, con la gerencia consultada en ese momento |
| `POST` | `/api/my-courses/{id}/complete` | El dueño | `{ satisfaction, usefulness }` → `200` `{ completedDate }` · `409` si ya finalizó · `404` si no es suyo |

Cuerpo de `POST /api/courses` y `PUT /api/courses/{id}`:

```json
{
  "name": "Excel avanzado",
  "modality": "VIRTUAL",
  "externalId": "LMS-2231",
  "assignments": [
    { "assignmentId": null, "groupId": 12, "dueDate": "2026-10-30" },
    { "assignmentId": 41,   "groupId": 7,  "dueDate": "2026-12-15" }
  ]
}
```

---

## 13. Pruebas

### Del servicio de cursos

- Crear con dos grupos que comparten 3 personas → `overlappingUsers = 3` y esas personas quedan en el primer grupo.
- Editar cambiando el `groupId` de una asignación existente → `400` con `GroupChangeNotAllowed`.
- Quitar un grupo sin finalizados → se borra con sus personas.
- Quitar un grupo con finalizados → queda con `removed = 1`, sin pendientes, y los finalizados siguen.
- Quitar el grupo A y agregar el grupo B que comparte personas con A, en el mismo guardado → las compartidas quedan en B sin error de índice único.
- Actualizar desde el grupo después de agregar 2 personas al grupo y quitar 1 pendiente → `added = 2`, `removedPending = 1`.

### Del formulario

- Abrir el formulario de otra persona → `404`, igual que un id que no existe.
- Enviar sin una de las calificaciones → `400`.
- Enviar con `6` o `-1` → `400`.
- Enviar con `0` en las dos → se acepta (el 0 es válido si se elige).
- Enviar dos veces seguidas → la primera `200`, la segunda `409`, y hay **una** sola fila en `course_rating`.
- Si el directorio falla, el formulario se abre con `management = null` y el envío se guarda igual.
- Un usuario cuyo `preferred_username` es el UPN y cuyo correo guardado es otro → lo encuentra por `oid`.
- Después de enviar: `course_assignment_user` en `COMPLETED` con fecha y gerencia; `course_rating` con el curso, las dos calificaciones y la fecha **sin hora**.

### Del seguimiento

- Con 2 respuestas → `visible = false`, sin promedios.
- Con 3 respuestas (5, 4, 0) → promedio 3,0 y distribución `[1, 0, 0, 0, 1, 1]`.
- Filtro `OVERDUE` → solo pendientes de grupos con fecha vencida.

### De base de datos

- La consulta de integridad de la sección 4 da el mismo número de finalizados y de calificaciones.
- Intentar `UPDATE … SET status = 'COMPLETED'` sin `completed_date` → lo rechaza `ck_course_assignment_user_completed`.

---

## 14. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| "Mis cursos" sale vacío para algunas personas | El correo del token (UPN) no coincide con el guardado y la fila no tiene `entra_object_id` | Las personas que llegan del maestro no traen `entra_object_id`: asegúrate de que el token traiga también el claim de correo, o completa ese id al asignar. |
| `The configured execution strategy does not support user-initiated transactions` | `EnableRetryOnFailure` activo y la transacción fuera de la estrategia | `TryCompleteAsync` ya usa `CreateExecutionStrategy`; no lo quites. |
| Error `2601` en `ux_course_assignment_user_course_email` al guardar | El índice no está en la configuración de EF, que entonces no ordena el DELETE antes del INSERT | Déjalo en `CourseAssignmentUserConfiguration`. |
| La gerencia siempre sale vacía | `ManagementDirectory` aún no llama a tu método real | Reemplaza la línea marcada con ⬇. |
| Los promedios no aparecen | Hay menos de 3 respuestas | Es a propósito: protege el anonimato. |
| Las calificaciones aparecen en los logs | Un middleware registra el cuerpo de las peticiones | Exclúyelo para `POST /api/my-courses/{id}/complete`. |
| En los logs aparece `Error en el repositorio para la entidad …` cuando alguien cierra la página | La cancelación de la petición (`OperationCanceledException`) termina envuelta en `InvalidOperationException` | `Guard` la deja pasar. Haz lo mismo en `GenericRepositoryBase` con `catch (OperationCanceledException) { throw; }`. |
| El script se detiene con "tiene datos del modelo anterior" | Ya había asignaciones persona por persona | Respáldalas, decide si se convierten en grupos y vuelve a ejecutar. |

---

## ✅ Checklist

- [ ] `UserGroups.sql` ejecutado antes que `Cursos-v2.sql`.
- [ ] `Cursos-v2.sql` ejecutado; consulta de integridad en cero diferencias.
- [ ] Entidades, enum y configuraciones actualizados; `CourseRatingConfiguration` registrada.
- [ ] `CourseIndexNames` con los índices nuevos y `TrySaveAsync` con el caso `CourseGroup`.
- [ ] `CourseCompletionRepository` hereda de `GenericRepositoryBase` y está registrado en `InfrastructureServiceRegistration.cs`.
- [ ] `AssignedGroupsCount` y `CompletedUsersCount` agregados al listado de cursos.
- [ ] `ManagementDirectory` conectado al método real que trae la gerencia.
- [ ] Token con claim `oid` y con el correo; probado con un UPN distinto al correo.
- [ ] `course_rating` sin llaves a usuario ni a asignación; fecha sin hora.
- [ ] Endpoint de finalización excluido de cualquier registro de cuerpos de petición.
- [ ] Promedios ocultos con menos de 3 respuestas.
- [ ] `MyCoursesController` con `[Authorize]`; acciones de seguimiento con el permiso de administración de cursos.
- [ ] Pruebas de doble envío, de propiedad (`404`) y de rangos de calificación.
