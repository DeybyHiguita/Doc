# 🎓 Cursos por grupos y formulario de finalización — API (.NET 8) y SQL Server

Esta guía conecta los **grupos de usuarios** con los **cursos** y agrega el **formulario de finalización**. Está hecha sobre el esquema real de la base de datos ([referencia-estilos-y-capas-doccb.md](referencia-estilos-y-capas-doccb.md), sección 3).

**Cómo funciona:**

- A un curso se le asignan **grupos**. Cada asignación es un grupo + una **fecha de finalización**.
- El **mismo grupo** puede asignarse **varias veces** al mismo curso, con fechas distintas (por ejemplo, el grupo 1 diez veces, una por cohorte).
- Al guardar una asignación, cada integrante del grupo queda relacionado con ella en `course_assignment_user`, en estado **Pendiente**.
- **Cada persona, en cada asignación**, diligencia su propio formulario de finalización. Si la persona está en el grupo 1 asignado dos veces, tiene dos formularios.
- En el listado de cursos, el administrador ve los grupos asignados a cada curso (grupo + fecha) y, en cada uno, sus integrantes con el estado del formulario.

**El formulario de finalización:**

| Campo | Origen | ¿Lo edita el usuario? |
|---|---|---|
| Nombre del curso | `dbo.course` | No |
| Grupo y fecha de finalización | La asignación | No |
| Persona | `dbo.course_assignment_user` → `dbo.users` | No |
| Gerencia | Directorio activo, consultada al abrir el formulario | No (bloqueado) |
| Estado | **Pendiente** al asignar → **Finalizado** al enviar | Sí, al enviar |
| Satisfacción (0 a 5) | Anónima | Sí |
| Utilidad del curso (0 a 5) | Anónima | Sí |
| Fecha de registro | La pone el servidor | No se le pide |

- **Stack:** .NET 8 · ASP.NET Core · EF Core 8 · SQL Server
- **Pantallas:** [cursos-grupos-finalizacion-angular.md](cursos-grupos-finalizacion-angular.md)

---

## 1. 🧐 Revisión crítica

| # | Tema | Decisión |
|---|---|---|
| 1 | **Un grupo repetido en el mismo curso.** Es válido (cohortes con fechas distintas), pero el mismo grupo con la **misma fecha** dos veces es un error de captura. | Índice único `(course_id, user_group_id, due_date)`. |
| 2 | **Una persona en varias asignaciones del mismo curso.** Pasa si el grupo se repite o si está en dos grupos. | Cada asignación es un formulario distinto. Se quita el índice de la primera guía que impedía repetir a una persona en el mismo curso, y queda único `(assignment_id, user_id)`: una persona una sola vez **por asignación**. |
| 3 | **Personas "solo directorio".** `course_assignment_user` se relaciona con `dbo.users` por `user_id`. Quien no está en el maestro no tiene `user_id`. | No se asignan. Al guardar, la API responde cuántas personas quedaron fuera (`skippedWithoutUser`), y la pantalla lo avisa antes de guardar. Tampoco podrían entrar a DOCCB a diligenciar el formulario. |
| 4 | **¿Dónde se guarda el estado?** Una columna `status` puede quedar "Finalizado" sin fecha ni formulario. | El estado se **deriva**: sin fila en `course_assignment_completion` = **Pendiente**; con fila = **Finalizado**. El estado por defecto al asignar es Pendiente sin escribir nada, y no hay estados inconsistentes. |
| 5 | **Anonimato de las calificaciones.** Si la calificación guarda al usuario o la hora exacta, deja de ser anónima. | Tabla aparte `course_rating` **sin** usuario ni `course_assignment_user`. Tiene el curso y la asignación (grupo + fecha) para poder ver resultados por cohorte, un id aleatorio (`NEWID`) y la fecha **sin hora**. |
| 6 | **Promedios que delatan.** Con menos de 3 respuestas, o restando el total del curso menos una asignación visible, se puede deducir qué calificó alguien. | Promedios solo con **3 respuestas o más**. Los resultados **por asignación** solo se muestran si **todas** las asignaciones con respuestas llegan a 3; si no, solo el total del curso. |
| 7 | **Registrar quién finalizó sin guardar qué calificó.** | La finalización (con persona) y la calificación (sin persona) se guardan en el **mismo `SaveChanges`**, que es una sola transacción: se guardan las dos o ninguna. |
| 8 | **Doble clic en "Finalizar".** | Índice único en `course_assignment_completion (assignment_user_id)`. La segunda petición choca con el índice, no guarda nada (ni calificación) y responde `409`. |
| 9 | **¿Qué significa 0?** | El 0 es válido, pero **se tiene que elegir**. La API exige las dos calificaciones y rechaza valores fuera de 0 a 5. |
| 10 | **La gerencia bloqueada en pantalla no es segura.** | El navegador no la envía. La API la vuelve a consultar al recibir el formulario y la guarda en la finalización. |
| 11 | **¿Quién abre el formulario?** | La API busca al usuario del token en `dbo.users` por `corporative_email` y solo muestra filas con **su** `user_id`. Un id ajeno responde `404`, igual que uno que no existe. |
| 12 | **El grupo cambia después de asignarlo.** | La relación es una foto al asignar. **"Actualizar desde el grupo"** agrega a los nuevos integrantes y quita a los **pendientes** que salieron. Quien ya finalizó se conserva. |
| 13 | **Quitar una asignación que ya tiene formularios.** Borrarla borraría el historial. | No se permite (`409`, con cuántas personas finalizaron). Se puede cambiar su fecha. La base de datos también lo protege: la llave de la finalización no es en cascada. |
| 14 | **Cambiar el grupo de una asignación guardada.** | No se permite: sus personas y formularios son de ese grupo. Se agrega otra asignación. |
| 15 | **"Vencido".** | No se guarda: se calcula (pendiente y fecha pasada, en hora de Colombia). |
| 16 | **Logs.** Un middleware que guarde el cuerpo de las peticiones rompería el anonimato. | Excluye `POST /api/my-courses/{id}/complete` del registro de cuerpos. |

---

## 2. 🔄 Flujo

```text
 ADMINISTRADOR                                          COLABORADOR
 ─────────────                                          ───────────
 Crea / edita el curso
   └─ asigna grupos: (grupo 1, 30 oct) (grupo 1, 15 dic) (grupo 2, 30 oct)
          │
          ▼
 course_assignment: una fila por grupo + fecha
 course_assignment_user: una fila por integrante  ──────► "Mis cursos": cada asignación
 con user_id, en cada asignación (Pendiente)              aparece como Pendiente
                                                          │
                                                          ▼
                                               Formulario de finalización
                                                 · curso, grupo, fecha, su nombre
                                                 · gerencia ◄── directorio activo (bloqueada)
                                                 · ★ satisfacción  (anónima)
                                                 · ★ utilidad      (anónima)
                                                          │ Enviar
                                                          ▼
                                               Un solo SaveChanges:
                                                 1. INSERT course_assignment_completion
                                                    (assignment_user_id, gerencia, fecha)
                                                 2. INSERT course_rating (sin persona)
          │                                               │
          ▼                                               ▼
 Listado → "Grupos asignados":                   "Mis cursos": Finalizado
 cada grupo + fecha, sus integrantes con
 estado y gerencia, promedios anónimos (≥ 3)
```

---

## 3. 📁 Archivos

```text
DOCCB.Domain/Entities/
├── CourseAssignment.cs                               ✏️ user_group_id y auditoría
├── CourseAssignmentUser.cs                           ✏️ + navegación a la finalización
├── CourseAssignmentCompletion.cs                     nuevo — el formulario diligenciado
└── CourseRating.cs                                   nuevo — calificación anónima

DOCCB.Application/
├── Contracts/Persistence/
│   ├── ICourseRepository.cs                          ✏️ foto de grupos
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
│   ├── Helpers/
│   │   ├── CourseValidationHelper.cs                 ✏️ valida grupo + fecha
│   │   └── RatingSummaryBuilder.cs                   nuevo — promedios con la regla de anonimato
│   ├── Interfaces/
│   │   ├── ICourseService.cs                         ✏️
│   │   ├── ICourseCompletionService.cs               nuevo
│   │   └── IManagementDirectory.cs                   nuevo
│   └── Services/
│       ├── CourseService.cs                          ✏️ genera la relación desde los grupos
│       ├── CourseCompletionService.cs                ⭐ mis cursos, formulario, grupos asignados
│       └── ManagementDirectory.cs                    nuevo — adapta tu método de gerencia

DOCCB.Infraestructure/
├── Common/GenericRepositoryBase.cs                   (existente) base de CourseCompletionRepository
├── Configurations/
│   ├── CourseAssignmentConfiguration.cs              ✏️
│   ├── CourseAssignmentUserConfiguration.cs          ✏️
│   ├── CourseAssignmentCompletionConfiguration.cs    nuevo
│   └── CourseRatingConfiguration.cs                  nuevo
├── Persistence/
│   ├── Models/DOCCbDbContext.cs                      ✏️ + 2 configuraciones
│   └── Scripts SQL/CursosFinalizacion.sql            ⭐ ajusta tus tablas y crea las nuevas
└── Repositories/
    ├── CourseRepository.cs                           ✏️
    └── CourseCompletionRepository.cs                 nuevo — hereda de GenericRepositoryBase

Presentation/WebApp/
├── Common/Helper/ControllerExtensions.cs             ✏️ + identidad del usuario
└── Controllers/
    ├── CoursesController.cs                          ✏️ + grupos asignados e integrantes
    └── MyCoursesController.cs                        nuevo — /api/my-courses
```

---

## 4. Paso 1 — 🗄️ Base de datos

### Modelo

```text
dbo.user_group ──< dbo.user_group_member (user_id NULL = solo directorio)
      │
      │ user_group_id
      ▼
dbo.course ──< dbo.course_assignment ──< dbo.course_assignment_user >── dbo.users
                 id, user_group_id,         id, assignment_id, user_id
                 due_date                          │
                    │                              │ 1 : 0..1
                    │                              ▼
                    │                   dbo.course_assignment_completion   ← el formulario
                    │                     assignment_user_id (único)
                    │                     management_name, created_date
                    │
                    └──────────────────< dbo.course_rating                 ← SIN persona
                                          course_id, assignment_id
                                          satisfaction 0-5, usefulness 0-5
                                          created_date (DATE)
```

| Tabla | Estado | Qué guarda |
|---|---|---|
| `dbo.course` | Sin cambios | `id`, `name`, `modality`, `external_id`, `removed`, `created_date`, `created_by`, `updated_date`, `updated_by` |
| `dbo.course_assignment` | ✏️ índices | `id`, `course_id`, `user_group_id`, `due_date`, `created_date`, `created_by`, `updated_date`, `updated_by` |
| `dbo.course_assignment_user` | ✏️ índices | `id`, `assignment_id`, `user_id`, `created_date` |
| `dbo.course_assignment_completion` | **nueva** | `id`, `assignment_user_id`, `management_name`, `created_date` |
| `dbo.course_rating` | **nueva** | `id`, `course_id`, `assignment_id`, `satisfaction`, `usefulness`, `created_date` |
| `dbo.user_group`, `user_group_manager`, `user_group_member` | Sin cambios | Ver [grupos-usuarios-api-sqlserver.md](grupos-usuarios-api-sqlserver.md) |

### Antes de ejecutar: confirma tus columnas

```sql
SELECT  TABLE_NAME, COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM    INFORMATION_SCHEMA.COLUMNS
WHERE   TABLE_SCHEMA = 'dbo'
  AND   TABLE_NAME IN ('course_assignment', 'course_assignment_user')
ORDER BY TABLE_NAME, ORDINAL_POSITION;

-- Índices actuales de course_assignment_user
SELECT  i.name, i.is_unique, i.is_primary_key,
        columns = STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal)
FROM    sys.indexes i
JOIN    sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
JOIN    sys.columns c        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE   i.object_id = OBJECT_ID(N'dbo.course_assignment_user')
GROUP BY i.name, i.is_unique, i.is_primary_key;
```

> **Si `course_assignment_user` todavía tiene `course_id`** (venía en la primera guía), mapéalo también en la entidad y en la configuración (sección 6) y llénalo al crear cada fila. Si no lo tiene, no hace falta: el curso se obtiene por la asignación.

### `Persistence/Scripts SQL/CursosFinalizacion.sql`

El script **no recrea** tus tablas: ajusta sus índices y crea las dos nuevas. Se puede ejecutar varias veces.

```sql
/* =====================================================================
   Cursos por grupos · formulario de finalización · calificaciones
   Base de datos: DB · Esquema: dbo
   Requiere: dbo.course, dbo.course_assignment, dbo.course_assignment_user,
             dbo.user_group, dbo.users
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   0. Verificaciones: si falta algo, el script se detiene sin cambiar nada.
   ───────────────────────────────────────────────────────────────────── */
IF COL_LENGTH(N'dbo.course_assignment', N'user_group_id') IS NULL
BEGIN
    RAISERROR (N'dbo.course_assignment no tiene la columna user_group_id.', 16, 1);
    SET NOEXEC ON;
END;

IF COL_LENGTH(N'dbo.course_assignment_user', N'id') IS NULL
BEGIN
    RAISERROR (N'dbo.course_assignment_user no tiene la columna id.', 16, 1);
    SET NOEXEC ON;
END;

-- El mismo grupo con la misma fecha dos veces en un curso impide crear el índice del paso 1.
IF EXISTS (
    SELECT 1 FROM dbo.course_assignment
    GROUP BY course_id, user_group_id, due_date
    HAVING COUNT(*) > 1)
BEGIN
    RAISERROR (N'Hay asignaciones repetidas (curso, grupo, fecha). Revísalas con la consulta de la guía.', 16, 1);
    SET NOEXEC ON;
END;

-- Una persona repetida en la misma asignación impide crear el índice del paso 2.
IF EXISTS (
    SELECT 1 FROM dbo.course_assignment_user
    GROUP BY assignment_id, user_id
    HAVING COUNT(*) > 1)
BEGIN
    RAISERROR (N'Hay personas repetidas en una misma asignación. Revísalas con la consulta de la guía.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   1. dbo.course_assignment
   ───────────────────────────────────────────────────────────────────── */
-- Llave al grupo.
IF OBJECT_ID(N'dbo.fk_course_assignment_user_group', N'F') IS NULL
    ALTER TABLE dbo.course_assignment
        ADD CONSTRAINT fk_course_assignment_user_group
        FOREIGN KEY (user_group_id) REFERENCES dbo.user_group (id);

-- El mismo grupo puede repetirse en un curso, pero no con la misma fecha.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.course_assignment') AND name = N'ux_course_assignment_course_group_due')
    CREATE UNIQUE INDEX ux_course_assignment_course_group_due
        ON dbo.course_assignment (course_id, user_group_id, due_date);

-- (id, course_id): permite que course_rating garantice que la asignación es de ese curso.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.course_assignment') AND name = N'uq_course_assignment_id_course_id')
    ALTER TABLE dbo.course_assignment
        ADD CONSTRAINT uq_course_assignment_id_course_id UNIQUE (id, course_id);
GO

/* ─────────────────────────────────────────────────────────────────────
   2. dbo.course_assignment_user
   ───────────────────────────────────────────────────────────────────── */
-- La primera guía permitía una persona una sola vez por curso. Ahora puede estar
-- en varias asignaciones del mismo curso (una por formulario).
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.course_assignment_user') AND name = N'ux_course_assignment_user_course_user')
    DROP INDEX ux_course_assignment_user_course_user ON dbo.course_assignment_user;

-- Una persona una sola vez por asignación.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.course_assignment_user') AND name = N'ux_course_assignment_user_assignment_user')
    CREATE UNIQUE INDEX ux_course_assignment_user_assignment_user
        ON dbo.course_assignment_user (assignment_id, user_id);

-- "Mis cursos": todas las asignaciones de una persona.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.course_assignment_user') AND name = N'ix_course_assignment_user_user_id')
    CREATE INDEX ix_course_assignment_user_user_id
        ON dbo.course_assignment_user (user_id)
        INCLUDE (assignment_id);

-- La finalización apunta a id: tiene que ser único. Si ya es la llave primaria, no se crea nada.
IF NOT EXISTS (
    SELECT 1
    FROM   sys.indexes i
    WHERE  i.object_id = OBJECT_ID(N'dbo.course_assignment_user')
      AND  i.is_unique = 1
      AND  (SELECT COUNT(*) FROM sys.index_columns ic
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0) = 1
      AND  EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                     AND ic.key_ordinal = 1 AND c.name = N'id'))
    CREATE UNIQUE INDEX ux_course_assignment_user_id ON dbo.course_assignment_user (id);
GO

/* ─────────────────────────────────────────────────────────────────────
   3. dbo.course_assignment_completion — el formulario diligenciado
      Una fila por persona y asignación. Sin fila = Pendiente.
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_assignment_completion', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_assignment_completion
    (
        id                 INT            IDENTITY(1, 1) NOT NULL,
        assignment_user_id INT            NOT NULL,
        management_name    NVARCHAR(200)  NULL,          -- gerencia del directorio activo al finalizar
        created_date       DATETIME2(0)   NOT NULL
            CONSTRAINT df_course_assignment_completion_created_date DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT pk_course_assignment_completion PRIMARY KEY CLUSTERED (id),
        -- Sin cascada: no se puede borrar a una persona (ni su asignación) si ya diligenció el formulario.
        CONSTRAINT fk_course_assignment_completion_assignment_user
            FOREIGN KEY (assignment_user_id) REFERENCES dbo.course_assignment_user (id)
    );

    -- Un formulario por persona y asignación: el doble envío choca aquí.
    CREATE UNIQUE INDEX ux_course_assignment_completion_assignment_user
        ON dbo.course_assignment_completion (assignment_user_id)
        INCLUDE (created_date);
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   4. dbo.course_rating — calificaciones ANÓNIMAS
      Sin persona ni course_assignment_user. Id aleatorio. Fecha sin hora.
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.course_rating', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_rating
    (
        id            UNIQUEIDENTIFIER NOT NULL CONSTRAINT df_course_rating_id DEFAULT (NEWID()),
        course_id     INT              NOT NULL,
        assignment_id INT              NOT NULL,
        satisfaction  TINYINT          NOT NULL,
        usefulness    TINYINT          NOT NULL,
        created_date  DATE             NOT NULL,

        CONSTRAINT pk_course_rating PRIMARY KEY NONCLUSTERED (id),
        CONSTRAINT fk_course_rating_assignment
            FOREIGN KEY (assignment_id, course_id) REFERENCES dbo.course_assignment (id, course_id),
        CONSTRAINT ck_course_rating_satisfaction CHECK (satisfaction BETWEEN 0 AND 5),
        CONSTRAINT ck_course_rating_usefulness CHECK (usefulness BETWEEN 0 AND 5)
    );

    CREATE CLUSTERED INDEX cx_course_rating_course
        ON dbo.course_rating (course_id, assignment_id, created_date);
END;
GO

SET NOEXEC OFF;
GO
```

Si el paso 0 se detiene por repetidos, estas consultas los muestran:

```sql
SELECT course_id, user_group_id, due_date, COUNT(*) AS total
FROM   dbo.course_assignment
GROUP BY course_id, user_group_id, due_date
HAVING COUNT(*) > 1;

SELECT assignment_id, user_id, COUNT(*) AS total
FROM   dbo.course_assignment_user
GROUP BY assignment_id, user_id
HAVING COUNT(*) > 1;
```

> **Anonimato más fuerte (opcional).** Si piden que ni un administrador de base de datos pueda cruzar fechas, guarda en `course_rating.created_date` el **primer día del mes**. El requisito de "guardar la fecha del registro" se sigue cumpliendo, con menos detalle.

### Consultas de verificación

```sql
DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'SA Pacific Standard Time' AS DATE);

-- Grupos asignados a cada curso, con su avance
SELECT  c.name AS course,
        g.name AS user_group,
        a.due_date,
        total     = COUNT(au.id),
        completed = COUNT(f.id),
        overdue   = CASE WHEN a.due_date < @today THEN COUNT(au.id) - COUNT(f.id) ELSE 0 END
FROM    dbo.course_assignment a
JOIN    dbo.course c ON c.id = a.course_id AND c.removed = 0
JOIN    dbo.user_group g ON g.id = a.user_group_id
LEFT JOIN dbo.course_assignment_user au ON au.assignment_id = a.id
LEFT JOIN dbo.course_assignment_completion f ON f.assignment_user_id = au.id
GROUP BY c.name, g.name, a.id, a.due_date
ORDER BY c.name, a.due_date;

-- Integrantes de una asignación con su estado
DECLARE @assignmentId INT = 1;
SELECT  u.corporative_email,
        status = CASE WHEN f.id IS NULL THEN 'PENDIENTE' ELSE 'FINALIZADO' END,
        f.management_name,
        f.created_date AS completed_date
FROM    dbo.course_assignment_user au
JOIN    dbo.users u ON u.id = au.user_id
LEFT JOIN dbo.course_assignment_completion f ON f.assignment_user_id = au.id
WHERE   au.assignment_id = @assignmentId;

-- Integridad: en cada asignación, formularios = calificaciones
SELECT  a.id,
        completions = (SELECT COUNT(*) FROM dbo.course_assignment_user au
                       JOIN dbo.course_assignment_completion f ON f.assignment_user_id = au.id
                       WHERE au.assignment_id = a.id),
        ratings     = (SELECT COUNT(*) FROM dbo.course_rating r WHERE r.assignment_id = a.id)
FROM    dbo.course_assignment a;
```

La última consulta debe dar el mismo número en las dos columnas: cada formulario genera exactamente una calificación.

---

## 5. Paso 2 — Dominio

### `Entities/CourseAssignment.cs` ✏️

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>Un grupo asignado a un curso con una fecha de finalización. El mismo grupo puede repetirse con otra fecha.</summary>
public class CourseAssignment : BaseEntity
{
    public int CourseId { get; set; }
    public int UserGroupId { get; set; }
    public DateOnly DueDate { get; set; }

    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? UpdatedDate { get; set; }
    public string? UpdatedBy { get; set; }

    public Course Course { get; set; } = null!;
    public UserGroup UserGroup { get; set; } = null!;
    public ICollection<CourseAssignmentUser> Users { get; set; } = new List<CourseAssignmentUser>();
}
```

### `Entities/CourseAssignmentUser.cs` ✏️

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>Una persona en una asignación. Sin Completion = Pendiente.</summary>
public class CourseAssignmentUser : BaseEntity
{
    public int AssignmentId { get; set; }
    public int UserId { get; set; }
    public DateTime CreatedDate { get; set; }

    public CourseAssignment Assignment { get; set; } = null!;
    public User User { get; set; } = null!;

    /// <summary>El formulario diligenciado. null mientras esté pendiente.</summary>
    public CourseAssignmentCompletion? Completion { get; set; }
}
```

### `Entities/CourseAssignmentCompletion.cs`

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>Formulario de finalización de una persona en una asignación. Sin calificaciones: esas son anónimas.</summary>
public class CourseAssignmentCompletion : BaseEntity
{
    public int AssignmentUserId { get; set; }

    /// <summary>Gerencia del directorio activo al momento de finalizar.</summary>
    public string? ManagementName { get; set; }

    /// <summary>Fecha del registro: es la fecha de finalización. La pone el servidor.</summary>
    public DateTime CreatedDate { get; set; }

    public CourseAssignmentUser AssignmentUser { get; set; } = null!;
}
```

### `Entities/CourseRating.cs`

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>
/// Calificación ANÓNIMA. A propósito no tiene llave ni navegación hacia la persona
/// ni hacia course_assignment_user: no agregues ninguna.
/// </summary>
public class CourseRating
{
    public Guid Id { get; set; }
    public int CourseId { get; set; }
    public int AssignmentId { get; set; }
    public byte Satisfaction { get; set; }
    public byte Usefulness { get; set; }

    /// <summary>Solo la fecha: con la hora se podría cruzar con la finalización.</summary>
    public DateOnly CreatedDate { get; set; }
}
```

> `BaseEntity` es la base que ya usan tus entidades (aporta `Id`). `CourseRating` no la usa porque su id es un `Guid`.

---

## 6. Paso 3 — Configuración de EF Core

### `Constants/CourseIndexNames.cs` ✏️

```csharp
namespace DOCCB.Application.Features.Courses.Application.Constants;

public static class CourseIndexNames
{
    public const string NameModality = "ux_course_name_modality";
    public const string ExternalId = "ux_course_external_id";
    public const string AssignmentGroupDue = "ux_course_assignment_course_group_due";
    public const string AssignmentUser = "ux_course_assignment_user_assignment_user";
    public const string Completion = "ux_course_assignment_completion_assignment_user";

    public static readonly string[] All = [NameModality, ExternalId, AssignmentGroupDue, AssignmentUser, Completion];
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
        builder.Property(a => a.UserGroupId).HasColumnName("user_group_id");
        builder.Property(a => a.DueDate).HasColumnName("due_date").HasColumnType("date");
        builder.Property(a => a.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(a => a.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
        builder.Property(a => a.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
        builder.Property(a => a.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

        builder.HasIndex(a => new { a.CourseId, a.UserGroupId, a.DueDate })
            .IsUnique()
            .HasDatabaseName(CourseIndexNames.AssignmentGroupDue);

        builder.HasOne(a => a.UserGroup)
            .WithMany()
            .HasForeignKey(a => a.UserGroupId)
            .HasConstraintName("fk_course_assignment_user_group")
            .OnDelete(DeleteBehavior.Restrict);

        // La relación con Course (Course.Assignments) ya está en CourseConfiguration.
    }
}
```

### `Configurations/CourseAssignmentUserConfiguration.cs` ✏️

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

        builder.HasKey(u => u.Id);

        builder.Property(u => u.Id).HasColumnName("id");
        builder.Property(u => u.AssignmentId).HasColumnName("assignment_id");
        builder.Property(u => u.UserId).HasColumnName("user_id");
        builder.Property(u => u.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");

        builder.HasIndex(u => new { u.AssignmentId, u.UserId })
            .IsUnique()
            .HasDatabaseName(CourseIndexNames.AssignmentUser);
        builder.HasIndex(u => u.UserId).HasDatabaseName("ix_course_assignment_user_user_id");

        builder.HasOne(u => u.Assignment)
            .WithMany(a => a.Users)
            .HasForeignKey(u => u.AssignmentId)
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasOne(u => u.User)
            .WithMany()
            .HasForeignKey(u => u.UserId)
            .OnDelete(DeleteBehavior.Restrict);
    }
}
```

> `HasKey(u => u.Id)` sin `HasName`: EF no crea la tabla (el script manda), así que no importa cómo se llame tu llave primaria. Si en tu tabla la llave es `(assignment_id, user_id)` y `id` es solo una identidad, igual funciona: el script crea el índice único sobre `id`.

### `Configurations/CourseAssignmentCompletionConfiguration.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class CourseAssignmentCompletionConfiguration : IEntityTypeConfiguration<CourseAssignmentCompletion>
{
    public void Configure(EntityTypeBuilder<CourseAssignmentCompletion> builder)
    {
        builder.ToTable("course_assignment_completion", "dbo");

        builder.HasKey(c => c.Id).HasName("pk_course_assignment_completion");

        builder.Property(c => c.Id).HasColumnName("id");
        builder.Property(c => c.AssignmentUserId).HasColumnName("assignment_user_id");
        builder.Property(c => c.ManagementName).HasColumnName("management_name").HasMaxLength(200);
        builder.Property(c => c.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");

        builder.HasIndex(c => c.AssignmentUserId)
            .IsUnique()
            .HasDatabaseName(CourseIndexNames.Completion);

        // 1 : 0..1 y sin cascada: el historial de formularios no se borra por accidente.
        builder.HasOne(c => c.AssignmentUser)
            .WithOne(u => u.Completion)
            .HasForeignKey<CourseAssignmentCompletion>(c => c.AssignmentUserId)
            .HasConstraintName("fk_course_assignment_completion_assignment_user")
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
        builder.Property(r => r.AssignmentId).HasColumnName("assignment_id");
        builder.Property(r => r.Satisfaction).HasColumnName("satisfaction");
        builder.Property(r => r.Usefulness).HasColumnName("usefulness");
        builder.Property(r => r.CreatedDate).HasColumnName("created_date").HasColumnType("date");

        builder.HasIndex(r => new { r.CourseId, r.AssignmentId, r.CreatedDate })
            .IsClustered()
            .HasDatabaseName("cx_course_rating_course");

        // Solo hacia la asignación (grupo + fecha). Sin navegación y nunca hacia la persona.
        builder.HasOne<CourseAssignment>()
            .WithMany()
            .HasForeignKey(r => new { r.AssignmentId, r.CourseId })
            .HasPrincipalKey(a => new { a.Id, a.CourseId })
            .HasConstraintName("fk_course_rating_assignment")
            .OnDelete(DeleteBehavior.Restrict);
    }
}
```

### Registro en `Persistence/Models/DOCCbDbContext.cs`

```csharp
modelBuilder.ApplyConfiguration(new CourseAssignmentCompletionConfiguration()); // nueva
modelBuilder.ApplyConfiguration(new CourseRatingConfiguration());               // nueva
// CourseAssignmentConfiguration y CourseAssignmentUserConfiguration ya estaban registradas.
```

---

## 7. Paso 4 — Asignar grupos al curso

### DTOs ✏️

`SaveCourseRequestDto.cs`: cada asignación es un **grupo con su fecha**.

```csharp
public class SaveCourseAssignmentDto
{
    /// <summary>null = asignación nueva.</summary>
    public int? AssignmentId { get; set; }
    public int GroupId { get; set; }
    public DateOnly DueDate { get; set; }
}

public class SaveCourseResultDto
{
    public int CourseId { get; set; }

    /// <summary>Integrantes de los grupos nuevos que no están en dbo.users: no se asignaron.</summary>
    public int SkippedWithoutUser { get; set; }
}

public class SyncAssignmentResultDto
{
    public int Added { get; set; }
    public int RemovedPending { get; set; }
    public int SkippedWithoutUser { get; set; }
}
```

`CourseDetailDtos.cs`: cada asignación del detalle.

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

`CourseListItemDto` suma dos conteos para la tarjeta del curso:

```csharp
public int AssignedGroupsCount { get; set; }   // asignaciones (grupo + fecha)
public int AssignedUsersCount { get; set; }    // ya existía: personas en todas las asignaciones
public int CompletedUsersCount { get; set; }   // formularios diligenciados
```

### `Constants/CourseConstants.cs` ✏️ — mensajes nuevos

```csharp
public const string GroupRequired = "Elige el grupo.";
public const string GroupDueRepeated = "Ese grupo ya está asignado con esa fecha de finalización.";
public const string GroupChangeNotAllowed = "Una asignación guardada no cambia de grupo. Agrega una asignación nueva.";
public const string GroupNotFound = "El grupo no existe o fue eliminado.";
public const string AssignmentNotFound = "La asignación no existe en este curso.";

public static string AssignmentHasCompletions(string groupName, DateOnly dueDate, int completed) =>
    $"No se puede quitar {groupName} ({dueDate:dd/MM/yyyy}): {completed} " +
    (completed == 1 ? "persona ya diligenció" : "personas ya diligenciaron") +
    " el formulario. Puedes cambiar su fecha.";
```

### `Helpers/CourseValidationHelper.cs` ✏️

```csharp
public sealed record AssignmentDraft(int? AssignmentId, int GroupId, DateOnly DueDate);

// Dentro de Normalize, el ciclo de asignaciones:
var assignments = new List<AssignmentDraft>();
var seenGroupDue = new HashSet<(int GroupId, DateOnly DueDate)>();
var seenAssignments = new HashSet<int>();

for (var i = 0; i < groups.Count; i++)
{
    var group = groups[i];
    var label = $"Asignación {i + 1}";

    if (group.GroupId <= 0)
        errors.Add($"{label}: {CourseConstants.GroupRequired}");

    if (group.DueDate == default)
        errors.Add($"{label}: elige la fecha de finalización.");
    // El mismo grupo puede repetirse, pero no con la misma fecha.
    else if (group.GroupId > 0 && !seenGroupDue.Add((group.GroupId, group.DueDate)))
        errors.Add($"{label}: {CourseConstants.GroupDueRepeated}");

    if (group.AssignmentId is { } assignmentId && !seenAssignments.Add(assignmentId))
        errors.Add($"{label}: la asignación {assignmentId} viene repetida.");

    assignments.Add(new AssignmentDraft(group.AssignmentId, group.GroupId, group.DueDate));
}
```

### `Contracts/Persistence/ICourseRepository.cs` ✏️

```csharp
/// <summary>Integrantes de un grupo al asignarlo: los que tienen usuario y cuántos no.</summary>
public sealed record GroupSnapshot(int GroupId, string Name, IReadOnlyList<int> UserIds, int WithoutUserCount);

// En ICourseRepository:

/// <summary>Grupos activos. Los que no existan no vienen en el diccionario.</summary>
Task<IReadOnlyDictionary<int, GroupSnapshot>> GetGroupSnapshotsAsync(IReadOnlyCollection<int> groupIds, CancellationToken ct);

/// <summary>¿El curso tuvo alguna asignación? Decide entre borrado lógico y físico.</summary>
Task<bool> HasAssignmentHistoryAsync(int courseId, CancellationToken ct);
```

Se quita `GetExistingUserIdsAsync` de la primera guía: las personas ahora salen del grupo.

### `Repositories/CourseRepository.cs` ✏️

**Listado:**

```csharp
AssignedGroupsCount = c.Assignments.Count(),
AssignedUsersCount = c.Assignments.SelectMany(a => a.Users).Count(),
CompletedUsersCount = c.Assignments.SelectMany(a => a.Users).Count(u => u.Completion != null),
NextDueDate = c.Assignments.Where(a => a.DueDate >= today).Min(a => (DateOnly?)a.DueDate)
              ?? c.Assignments.Where(a => a.DueDate < today).Max(a => (DateOnly?)a.DueDate),
```

**Detalle:**

```csharp
Assignments = c.Assignments
    .OrderBy(a => a.DueDate)
    .ThenBy(a => a.Id)
    .Select(a => new CourseAssignmentDto
    {
        AssignmentId = a.Id,
        GroupId = a.UserGroupId,
        GroupName = a.UserGroup.Name,
        GroupRemoved = a.UserGroup.Removed,
        DueDate = a.DueDate,
        TotalUsers = a.Users.Count(),
        CompletedUsers = a.Users.Count(u => u.Completion != null),
    })
    .ToList(),
```

**Carga para editar:** las asignaciones con sus personas y, de cada una, si ya finalizó.

```csharp
public Task<Course?> GetForUpdateAsync(int courseId, bool includeAssignments, CancellationToken ct)
{
    IQueryable<Course> query = db.Set<Course>().Where(c => c.Id == courseId && !c.Removed);

    if (includeAssignments)
    {
        query = query
            .Include(c => c.Assignments).ThenInclude(a => a.UserGroup)
            .Include(c => c.Assignments).ThenInclude(a => a.Users).ThenInclude(u => u.Completion);
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

    var ids = groupIds.Distinct().ToList();

    var groups = await db.Set<UserGroup>()
        .AsNoTracking()
        .Where(g => ids.Contains(g.Id) && !g.Removed)
        .Select(g => new
        {
            g.Id,
            g.Name,
            UserIds = g.Members.Where(m => m.UserId != null).Select(m => m.UserId!.Value).Distinct().ToList(),
            WithoutUser = g.Members.Count(m => m.UserId == null),
        })
        .AsSplitQuery()
        .ToListAsync(ct);

    return groups.ToDictionary(g => g.Id, g => new GroupSnapshot(g.Id, g.Name, g.UserIds, g.WithoutUser));
}

public Task<bool> HasAssignmentHistoryAsync(int courseId, CancellationToken ct) =>
    db.Set<CourseAssignment>().AnyAsync(a => a.CourseId == courseId, ct);
```

> Si tu `CourseRepository` ya hereda de `GenericRepositoryBase`, cambia `db` por `_context`.

### `Services/CourseService.cs` ✏️

Se reemplazan `CreateAsync`, `UpdateAsync` y `DeleteAsync`, y se agrega `SyncAssignmentAsync`.

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
    if (draft.Assignments.Any(a => !groups.ContainsKey(a.GroupId)))
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

    var skipped = 0;
    foreach (var assignmentDraft in draft.Assignments)
    {
        var group = groups[assignmentDraft.GroupId];
        course.Assignments.Add(NewAssignment(assignmentDraft, group, now, currentUser));
        skipped += group.WithoutUserCount;
    }

    _repository.Add(course);

    var saveConflict = await TrySaveAsync(ct);
    return saveConflict is null
        ? CourseResult<SaveCourseResultDto>.Ok(new SaveCourseResultDto { CourseId = course.Id, SkippedWithoutUser = skipped })
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

    // ── Validaciones contra lo guardado ─────────────────────────────
    var existing = course.Assignments.ToDictionary(a => a.Id);
    var today = Today();

    foreach (var assignmentDraft in draft.Assignments)
    {
        if (assignmentDraft.AssignmentId is { } assignmentId)
        {
            if (!existing.TryGetValue(assignmentId, out var current))
                return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.AssignmentNotFound);

            if (current.UserGroupId != assignmentDraft.GroupId)
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

    // Asignaciones que ya no vienen: solo se pueden quitar si nadie diligenció el formulario.
    var keepIds = draft.Assignments.Where(a => a.AssignmentId is not null).Select(a => a.AssignmentId!.Value).ToHashSet();
    var removed = course.Assignments.Where(a => !keepIds.Contains(a.Id)).ToList();

    var blocking = removed
        .Select(a => new { Assignment = a, Completed = a.Users.Count(u => u.Completion is not null) })
        .Where(x => x.Completed > 0)
        .Select(x => CourseConstants.AssignmentHasCompletions(x.Assignment.UserGroup.Name, x.Assignment.DueDate, x.Completed))
        .ToList();

    if (blocking.Count > 0) return CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Conflict, blocking);

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

    // 1. Quitar: sin formularios, así que se borran con sus personas (cascada).
    foreach (var assignment in removed)
    {
        course.Assignments.Remove(assignment);
        _repository.Remove(assignment);
    }

    // 2. Las que siguen: solo cambia la fecha.
    foreach (var assignmentDraft in draft.Assignments.Where(a => a.AssignmentId is not null))
    {
        var assignment = existing[assignmentDraft.AssignmentId!.Value];
        if (assignment.DueDate == assignmentDraft.DueDate) continue;

        assignment.DueDate = assignmentDraft.DueDate;
        assignment.UpdatedDate = now;
        assignment.UpdatedBy = currentUser;
    }

    // 3. Nuevas.
    var skipped = 0;
    foreach (var assignmentDraft in newDrafts)
    {
        var group = groups[assignmentDraft.GroupId];
        course.Assignments.Add(NewAssignment(assignmentDraft, group, now, currentUser));
        skipped += group.WithoutUserCount;
    }

    var saveConflict = await TrySaveAsync(ct);
    return saveConflict is null
        ? CourseResult<SaveCourseResultDto>.Ok(new SaveCourseResultDto { CourseId = id, SkippedWithoutUser = skipped })
        : CourseResult<SaveCourseResultDto>.Fail(CourseResultStatus.Conflict, saveConflict);
}

/// <summary>"Actualizar desde el grupo": agrega a los nuevos y quita a los pendientes que salieron.</summary>
public async Task<CourseResult<SyncAssignmentResultDto>> SyncAssignmentAsync(
    int courseId, int assignmentId, string currentUser, CancellationToken ct = default)
{
    var course = await _repository.GetForUpdateAsync(courseId, includeAssignments: true, ct);
    var assignment = course?.Assignments.FirstOrDefault(a => a.Id == assignmentId);
    if (assignment is null)
        return CourseResult<SyncAssignmentResultDto>.Fail(CourseResultStatus.NotFound, CourseConstants.AssignmentNotFound);

    var groups = await _repository.GetGroupSnapshotsAsync([assignment.UserGroupId], ct);
    if (!groups.TryGetValue(assignment.UserGroupId, out var group))
        return CourseResult<SyncAssignmentResultDto>.Fail(CourseResultStatus.Invalid, CourseConstants.GroupNotFound);

    var groupUserIds = group.UserIds.ToHashSet();
    var now = Now();

    // Pendientes que salieron del grupo. Quien ya diligenció el formulario se conserva siempre.
    var removedPending = 0;
    foreach (var user in assignment.Users.Where(u => u.Completion is null && !groupUserIds.Contains(u.UserId)).ToList())
    {
        assignment.Users.Remove(user);
        _repository.Remove(user);
        removedPending++;
    }

    var current = assignment.Users.Select(u => u.UserId).ToHashSet();
    var added = 0;
    foreach (var userId in group.UserIds)
    {
        if (!current.Add(userId)) continue;
        assignment.Users.Add(NewAssignmentUser(userId, now));
        added++;
    }

    assignment.UpdatedDate = now;
    assignment.UpdatedBy = currentUser;
    await _repository.SaveChangesAsync(ct);

    return CourseResult<SyncAssignmentResultDto>.Ok(new SyncAssignmentResultDto
    {
        Added = added,
        RemovedPending = removedPending,
        SkippedWithoutUser = group.WithoutUserCount,
    });
}

public async Task<CourseResult<bool>> DeleteAsync(int id, string currentUser, CancellationToken ct = default)
{
    var course = await _repository.GetForUpdateAsync(id, includeAssignments: false, ct);
    if (course is null) return CourseResult<bool>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound);

    if (await _repository.HasAssignmentHistoryAsync(id, ct))
    {
        // Tuvo asignaciones: se conserva el historial (y los formularios) y el curso deja de listarse.
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

// ── Privados ────────────────────────────────────────────────────────

private static CourseAssignment NewAssignment(AssignmentDraft draft, GroupSnapshot group, DateTime now, string currentUser)
{
    var assignment = new CourseAssignment
    {
        UserGroupId = draft.GroupId,
        DueDate = draft.DueDate,
        CreatedDate = now,
        CreatedBy = currentUser,
    };

    // Todos los integrantes con usuario, aunque ya estén en otra asignación del mismo curso:
    // cada asignación es un formulario distinto.
    foreach (var userId in group.UserIds)
    {
        assignment.Users.Add(NewAssignmentUser(userId, now));
    }

    return assignment;
}

private static CourseAssignmentUser NewAssignmentUser(int userId, DateTime now) => new()
{
    UserId = userId,
    CreatedDate = now,
    // AssignmentId lo completa EF desde la navegación. Sin Completion = Pendiente.
};
```

`TrySaveAsync` ya traduce los índices únicos a mensajes. Agrega los casos nuevos a su `switch`:

```csharp
CourseIndexNames.AssignmentGroupDue => CourseConstants.GroupDueRepeated,
CourseIndexNames.AssignmentUser => "Una persona quedó dos veces en la misma asignación. Intenta de nuevo.",
```

En `ICourseService`, `CreateAsync` y `UpdateAsync` devuelven `CourseResult<SaveCourseResultDto>`, y se agrega `SyncAssignmentAsync`.

---

## 8. Paso 5 — ⭐ El formulario de finalización

### `DTOs/CurrentUserIdentity.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

/// <summary>
/// Lo que dice el token del usuario autenticado. La API lo convierte en su user_id
/// buscando los correos en dbo.users.corporative_email.
/// </summary>
public sealed record CurrentUserIdentity(Guid? ObjectId, IReadOnlyList<string> Emails);
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
    public const string AlreadyCompleted = "Ya diligenciaste el formulario de este curso.";
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

/// <summary>Una fila de "Mis cursos": una asignación de la persona.</summary>
public class MyCourseDto
{
    public int AssignmentUserId { get; set; }
    public int CourseId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public string Modality { get; set; } = string.Empty;
    /// <summary>El mismo curso puede aparecer varias veces: el grupo y la fecha las distinguen.</summary>
    public string GroupName { get; set; } = string.Empty;
    public DateOnly DueDate { get; set; }
    public string Status { get; set; } = string.Empty;   // PENDING | COMPLETED
    public DateTime? CompletedDate { get; set; }
    public bool IsOverdue { get; set; }
}

/// <summary>Lo que muestra el formulario. Todo es de solo lectura para el usuario.</summary>
public class CompletionFormDto
{
    public int AssignmentUserId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public string Modality { get; set; } = string.Empty;
    public string GroupName { get; set; } = string.Empty;
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

Ya tienes un método que trae la gerencia desde el directorio activo. Esta clase solo lo adapta al contrato.

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

/// <summary>Una persona en una asignación, con lo que necesitan "Mis cursos" y el formulario.</summary>
public sealed record AssignmentUserRow(
    int Id,
    int UserId,
    int AssignmentId,
    int CourseId,
    string CourseName,
    CourseModality Modality,
    string GroupName,
    DateOnly DueDate,
    string DisplayName,
    string Email,
    DateTime? CompletedDate,
    bool CourseRemoved)
{
    public bool IsCompleted => CompletedDate is not null;
}

/// <summary>Conteo de calificaciones por asignación y valor. Nunca filas individuales.</summary>
public sealed record RatingBucket(int AssignmentId, byte Satisfaction, byte Usefulness, int Count);

public interface ICourseCompletionRepository
{
    Task<IReadOnlyList<AssignmentUserRow>> GetMyAssignmentsAsync(int userId, CancellationToken ct);
    Task<AssignmentUserRow?> GetAssignmentUserAsync(int assignmentUserId, CancellationToken ct);

    /// <summary>
    /// Guarda el formulario y la calificación en un solo SaveChanges.
    /// false = ya existía un formulario para esa persona y asignación (doble envío); no se guardó nada.
    /// </summary>
    Task<bool> TryCompleteAsync(CourseAssignmentCompletion completion, CourseRating rating, CancellationToken ct);

    Task<CourseProgressDto?> GetProgressAsync(int courseId, DateOnly today, CancellationToken ct);
    Task<IReadOnlyList<RatingBucket>> GetRatingBucketsAsync(int courseId, CancellationToken ct);
    Task<AssignedUsersPageDto> GetAssignmentUsersAsync(int courseId, int assignmentId, AssignedUsersQuery query, DateOnly today, CancellationToken ct);
}
```

### `Repositories/CourseCompletionRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Domain.Entities;
using DOCCB.Infraestructure.Common;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using System.Linq.Expressions;

namespace DOCCB.Infraestructure.Repositories;

/// <summary>
/// Hereda de GenericRepositoryBase como el resto de repositorios: _dbSet es course_assignment_user
/// y _context da acceso a las demás tablas.
/// </summary>
public class CourseCompletionRepository(DOCCbDbContext context)
    : GenericRepositoryBase<DOCCbDbContext, CourseAssignmentUser>(context), ICourseCompletionRepository
{
    /// <summary>Una sola proyección para "Mis cursos" y para el formulario.</summary>
    private static readonly Expression<Func<CourseAssignmentUser, AssignmentUserRow>> ToRow =
        u => new AssignmentUserRow(
                u.Id,
                u.UserId,
                u.AssignmentId,
                u.Assignment.CourseId,
                u.Assignment.Course.Name,
                u.Assignment.Course.Modality,
                u.Assignment.UserGroup.Name,
                u.Assignment.DueDate,
                u.User.DisplayName,
                u.User.CorportativeEmail ?? string.Empty,
                u.Completion != null ? (DateTime?)u.Completion.CreatedDate : null,
                u.Assignment.Course.Removed);

    public Task<IReadOnlyList<AssignmentUserRow>> GetMyAssignmentsAsync(int userId, CancellationToken ct) =>
        Guard<IReadOnlyList<AssignmentUserRow>>(async () => await _dbSet
            .AsNoTracking()
            .Where(u => u.UserId == userId && !u.Assignment.Course.Removed)
            .Select(ToRow)
            .ToListAsync(ct));

    public Task<AssignmentUserRow?> GetAssignmentUserAsync(int assignmentUserId, CancellationToken ct) =>
        Guard(() => _dbSet
            .AsNoTracking()
            .Where(u => u.Id == assignmentUserId)
            .Select(ToRow)
            .FirstOrDefaultAsync(ct));

    public Task<bool> TryCompleteAsync(CourseAssignmentCompletion completion, CourseRating rating, CancellationToken ct) =>
        Guard(() => SaveCompletionAsync(completion, rating, ct));

    private async Task<bool> SaveCompletionAsync(CourseAssignmentCompletion completion, CourseRating rating, CancellationToken ct)
    {
        _context.Set<CourseAssignmentCompletion>().Add(completion);
        // La calificación no tiene ninguna referencia a la persona ni a su fila de asignación.
        _context.Set<CourseRating>().Add(rating);

        try
        {
            // Un solo SaveChanges = una sola transacción: se guardan las dos o ninguna.
            await _context.SaveChangesAsync(ct);
            return true;
        }
        catch (DbUpdateException ex) when (IsDuplicateCompletion(ex))
        {
            // Doble envío: otra petición ya guardó el formulario. De esta no quedó nada.
            _context.ChangeTracker.Clear();
            return false;
        }
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
                    .OrderBy(a => a.DueDate)
                    .ThenBy(a => a.Id)
                    .Select(a => new AssignmentProgressDto
                    {
                        AssignmentId = a.Id,
                        GroupId = a.UserGroupId,
                        GroupName = a.UserGroup.Name,
                        GroupRemoved = a.UserGroup.Removed,
                        DueDate = a.DueDate,
                        Total = a.Users.Count(),
                        Completed = a.Users.Count(u => u.Completion != null),
                        Overdue = a.DueDate < today ? a.Users.Count(u => u.Completion == null) : 0,
                        // Hoy en el grupo sin usuario en DOCCB: no pueden recibir el curso.
                        WithoutUser = a.UserGroup.Members.Count(m => m.UserId == null),
                    })
                    .ToList(),
            })
            .AsSplitQuery()
            .FirstOrDefaultAsync(ct));

    public Task<IReadOnlyList<RatingBucket>> GetRatingBucketsAsync(int courseId, CancellationToken ct) =>
        Guard<IReadOnlyList<RatingBucket>>(async () => await _context.Set<CourseRating>()
            .AsNoTracking()
            .Where(r => r.CourseId == courseId)
            .GroupBy(r => new { r.AssignmentId, r.Satisfaction, r.Usefulness })
            .Select(g => new RatingBucket(g.Key.AssignmentId, g.Key.Satisfaction, g.Key.Usefulness, g.Count()))
            .ToListAsync(ct));

    public Task<AssignedUsersPageDto> GetAssignmentUsersAsync(
        int courseId, int assignmentId, AssignedUsersQuery query, DateOnly today, CancellationToken ct) =>
        Guard(() => BuildAssignmentUsersAsync(courseId, assignmentId, query, today, ct));

    private async Task<AssignedUsersPageDto> BuildAssignmentUsersAsync(
        int courseId, int assignmentId, AssignedUsersQuery query, DateOnly today, CancellationToken ct)
    {
        var users = _dbSet
            .AsNoTracking()
            .Where(u => u.AssignmentId == assignmentId && u.Assignment.CourseId == courseId);

        if (query.Search is { Length: > 0 } term)
        {
            users = users.Where(u => u.User.DisplayName.Contains(term) || (u.User.CorportativeEmail ?? "").Contains(term));
        }

        users = query.Status switch
        {
            CompletionConstants.Status.Completed => users.Where(u => u.Completion != null),
            CompletionConstants.Status.Pending => users.Where(u => u.Completion == null),
            CompletionConstants.Status.Overdue => users.Where(u => u.Completion == null && u.Assignment.DueDate < today),
            _ => users,
        };

        var total = await users.CountAsync(ct);

        var items = await users
            .OrderBy(u => u.User.DisplayName)
            .ThenBy(u => u.Id)
            .Skip((query.Page - 1) * query.PageSize)
            .Take(query.PageSize)
            .Select(u => new AssignedUserProgressDto
            {
                DisplayName = u.User.DisplayName,
                Email = u.User.CorportativeEmail ?? string.Empty,
                Status = u.Completion != null ? CompletionConstants.Status.Completed : CompletionConstants.Status.Pending,
                IsOverdue = u.Completion == null && u.Assignment.DueDate < today,
                CompletedDate = u.Completion != null ? (DateTime?)u.Completion.CreatedDate : null,
                Management = u.Completion != null ? u.Completion.ManagementName : null,
            })
            .ToListAsync(ct);

        return new AssignedUsersPageDto { TotalCount = total, Items = items };
    }

    private static bool IsDuplicateCompletion(DbUpdateException ex) =>
        ex.InnerException is SqlException { Number: 2601 or 2627 } sql
        && sql.Message.Contains(CourseIndexNames.Completion, StringComparison.OrdinalIgnoreCase);

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

> **Por qué `Guard`:** aplica la convención de `GenericRepositoryBase` a los métodos propios y además deja pasar `OperationCanceledException`, que la base hoy envuelve ([referencia-estilos-y-capas-doccb.md](referencia-estilos-y-capas-doccb.md)). Si agregas ese `catch` a la base, puedes mover `Guard` allí como `protected`.
>
> `DisplayName` y `CorportativeEmail` son los nombres de la entidad `User` en tu código. Si `DisplayName` no existe, arma el nombre con las columnas que tengas.

### `Helpers/RatingSummaryBuilder.cs`

La regla de anonimato vive en la capa de aplicación, no en la consulta.

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Helpers;

public static class RatingSummaryBuilder
{
    public static RatingSummaryDto Build(IEnumerable<RatingBucket> buckets, int minimumResponses)
    {
        var list = buckets.ToList();
        var responses = list.Sum(b => b.Count);

        // Con pocas respuestas un promedio puede delatar a alguien: solo se informa el conteo.
        if (responses < minimumResponses)
        {
            return new RatingSummaryDto { Responses = responses, Visible = false, MinimumResponses = minimumResponses };
        }

        var satisfaction = new int[CompletionConstants.MaxRating + 1];
        var usefulness = new int[CompletionConstants.MaxRating + 1];

        foreach (var bucket in list)
        {
            satisfaction[bucket.Satisfaction] += bucket.Count;
            usefulness[bucket.Usefulness] += bucket.Count;
        }

        return new RatingSummaryDto
        {
            Responses = responses,
            Visible = true,
            MinimumResponses = minimumResponses,
            SatisfactionAverage = Average(satisfaction, responses),
            UsefulnessAverage = Average(usefulness, responses),
            SatisfactionDistribution = satisfaction,
            UsefulnessDistribution = usefulness,
        };
    }

    /// <summary>
    /// Por asignación solo si TODAS las asignaciones con respuestas llegan al mínimo.
    /// Si no, restando el total del curso menos las visibles se deducirían las ocultas.
    /// </summary>
    public static bool CanShowPerAssignment(IEnumerable<RatingBucket> buckets, int minimumResponses) =>
        buckets
            .GroupBy(b => b.AssignmentId)
            .All(g => g.Sum(b => b.Count) >= minimumResponses);

    private static double Average(int[] buckets, int responses) =>
        Math.Round(buckets.Select((count, score) => count * score).Sum() / (double)responses, 1);
}
```

### `Services/CourseCompletionService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Application.Features.Courses.Application.Interfaces;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.Courses.Application.Services;

public class CourseCompletionService(
    ICourseCompletionRepository repository,
    IUserSearchRepository users,
    IManagementDirectory managementDirectory,
    TimeProvider timeProvider) : ICourseCompletionService
{
    // ── Mis cursos ──────────────────────────────────────────────────

    public async Task<ServiceResult<List<MyCourseDto>>> GetMyCoursesAsync(CurrentUserIdentity user, CancellationToken ct = default)
    {
        var userId = await ResolveUserIdAsync(user, ct);
        if (userId is null) return ServiceResult<List<MyCourseDto>>.Ok([]);

        var today = BusinessDate.Today(timeProvider);
        var rows = await repository.GetMyAssignmentsAsync(userId.Value, ct);

        var courses = rows
            .Select(row => new MyCourseDto
            {
                AssignmentUserId = row.Id,
                CourseId = row.CourseId,
                CourseName = row.CourseName,
                Modality = CourseModalityCodes.ToCode(row.Modality),
                GroupName = row.GroupName,
                DueDate = row.DueDate,
                Status = ToCode(row),
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

        // La gerencia se consulta cada vez que se abre el formulario pendiente.
        var management = row.IsCompleted ? null : await managementDirectory.GetManagementAsync(user, ct);

        return ServiceResult<CompletionFormDto>.Ok(new CompletionFormDto
        {
            AssignmentUserId = row.Id,
            CourseName = row.CourseName,
            Modality = CourseModalityCodes.ToCode(row.Modality),
            GroupName = row.GroupName,
            DueDate = row.DueDate,
            Status = ToCode(row),
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

        if (row.IsCompleted)
            return ServiceResult<CompletionResultDto>.Fail(ServiceResultStatus.Conflict, CompletionConstants.AlreadyCompleted);

        // La gerencia NO viene del navegador: se vuelve a consultar aquí.
        var management = await managementDirectory.GetManagementAsync(user, ct);
        var now = timeProvider.GetUtcNow().UtcDateTime;

        var completion = new CourseAssignmentCompletion
        {
            AssignmentUserId = row.Id,
            ManagementName = management,
            CreatedDate = now, // requisito: fecha del registro, sin pedírsela al usuario
        };

        var rating = new CourseRating
        {
            Id = Guid.NewGuid(),
            CourseId = row.CourseId,
            AssignmentId = row.AssignmentId,
            Satisfaction = (byte)dto.Satisfaction!.Value,
            Usefulness = (byte)dto.Usefulness!.Value,
            CreatedDate = BusinessDate.Today(timeProvider), // solo la fecha
        };

        var saved = await repository.TryCompleteAsync(completion, rating, ct);

        return saved
            ? ServiceResult<CompletionResultDto>.Ok(new CompletionResultDto { CompletedDate = now })
            : ServiceResult<CompletionResultDto>.Fail(ServiceResultStatus.Conflict, CompletionConstants.AlreadyCompleted);
    }

    // ── Grupos asignados (administración) ───────────────────────────

    public async Task<ServiceResult<CourseProgressDto>> GetProgressAsync(int courseId, CancellationToken ct = default)
    {
        var progress = await repository.GetProgressAsync(courseId, BusinessDate.Today(timeProvider), ct);
        if (progress is null) return ServiceResult<CourseProgressDto>.Fail(ServiceResultStatus.NotFound, CourseConstants.CourseNotFound);

        var buckets = await repository.GetRatingBucketsAsync(courseId, ct);
        var minimum = CompletionConstants.MinimumResponsesForSummary;

        progress.Ratings = RatingSummaryBuilder.Build(buckets, minimum);

        if (RatingSummaryBuilder.CanShowPerAssignment(buckets, minimum))
        {
            foreach (var assignment in progress.Assignments)
            {
                assignment.Ratings = RatingSummaryBuilder.Build(buckets.Where(b => b.AssignmentId == assignment.AssignmentId), minimum);
            }
        }

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

    /// <summary>user_id del usuario autenticado en dbo.users. null si no está o si sus correos apuntan a dos personas.</summary>
    private async Task<int?> ResolveUserIdAsync(CurrentUserIdentity user, CancellationToken ct)
    {
        if (user.Emails.Count == 0) return null;

        var matches = await users.FindByEmailsAsync(user.Emails.ToList(), ct);
        var ids = matches.Select(m => m.UserId).Distinct().ToList();

        return ids.Count == 1 ? ids[0] : null;
    }

    /// <summary>
    /// Si la fila no existe o es de otra persona, responde lo mismo: "no encontrado".
    /// Así nadie puede averiguar ids ajenos probando números.
    /// </summary>
    private async Task<AssignmentUserRow?> FindOwnedAsync(int assignmentUserId, CurrentUserIdentity user, CancellationToken ct)
    {
        var userId = await ResolveUserIdAsync(user, ct);
        if (userId is null) return null;

        var row = await repository.GetAssignmentUserAsync(assignmentUserId, ct);
        return row is null || row.CourseRemoved || row.UserId != userId ? null : row;
    }

    private static bool IsValidRating(int? value) =>
        value is >= CompletionConstants.MinRating and <= CompletionConstants.MaxRating;

    private static bool IsOverdue(AssignmentUserRow row, DateOnly today) => !row.IsCompleted && row.DueDate < today;

    private static string ToCode(AssignmentUserRow row) =>
        row.IsCompleted ? CompletionConstants.Status.Completed : CompletionConstants.Status.Pending;
}
```

> Este servicio **no escribe logs** con la persona y sus calificaciones. Mantenlo así.
>
> `IUserSearchRepository.FindByEmailsAsync` viene de la guía de grupos y busca en `users.corporative_email`.

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

## 9. Paso 6 — Grupos asignados (DTOs)

### `DTOs/CourseProgressDtos.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs;

/// <summary>Lo que ve el administrador desde el listado: los grupos del curso y su avance.</summary>
public class CourseProgressDto
{
    public int CourseId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public List<AssignmentProgressDto> Assignments { get; set; } = [];
    public RatingSummaryDto Ratings { get; set; } = new();
}

/// <summary>Una asignación: grupo + fecha de finalización.</summary>
public class AssignmentProgressDto
{
    public int AssignmentId { get; set; }
    public int GroupId { get; set; }
    public string GroupName { get; set; } = string.Empty;
    public bool GroupRemoved { get; set; }
    public DateOnly DueDate { get; set; }
    public int Total { get; set; }
    public int Completed { get; set; }
    /// <summary>Pendientes con la fecha ya pasada.</summary>
    public int Overdue { get; set; }
    /// <summary>Integrantes del grupo sin usuario en DOCCB: no recibieron el curso.</summary>
    public int WithoutUser { get; set; }
    /// <summary>null cuando no se pueden mostrar por asignación sin romper el anonimato.</summary>
    public RatingSummaryDto? Ratings { get; set; }
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

/// <summary>Un integrante de la asignación con el estado de su formulario.</summary>
public class AssignedUserProgressDto
{
    public string DisplayName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
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

### `Common/Helper/ControllerExtensions.cs` ✏️ — identidad del usuario

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

### `Controllers/MyCoursesController.cs`

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

    /// <summary>{id} es course_assignment_user.id: una persona en una asignación.</summary>
    [HttpGet("{id:int}/completion-form")]
    public async Task<IActionResult> GetForm(int id, CancellationToken ct) =>
        this.ToActionResult(await _service.GetFormAsync(id, User.CurrentIdentity(), ct));

    /// <summary>⚠️ No registres el cuerpo de esta petición en logs: contiene calificaciones anónimas.</summary>
    [HttpPost("{id:int}/complete")]
    public async Task<IActionResult> Complete(int id, [FromBody] CompleteCourseRequestDto dto, CancellationToken ct) =>
        this.ToActionResult(await _service.CompleteAsync(id, dto, User.CurrentIdentity(), ct));
}
```

### `Controllers/CoursesController.cs` ✏️ — acciones nuevas

Inyecta también `ICourseCompletionService`.

```csharp
/// <summary>Grupos asignados al curso (grupo + fecha), con avance y calificaciones anónimas.</summary>
[HttpGet("{id:int}/assignments")]
public async Task<IActionResult> GetAssignments(int id, CancellationToken ct) =>
    this.ToActionResult(await _completionService.GetProgressAsync(id, ct));

/// <summary>Integrantes de una asignación con el estado de su formulario.</summary>
[HttpGet("{id:int}/assignments/{assignmentId:int}/users")]
public async Task<IActionResult> GetAssignmentUsers(
    int id, int assignmentId, [FromQuery] AssignedUsersQueryDto query, CancellationToken ct) =>
    this.ToActionResult(await _completionService.GetAssignmentUsersAsync(id, assignmentId, query, ct));

[HttpPost("{id:int}/assignments/{assignmentId:int}/sync")]
public async Task<IActionResult> SyncAssignment(int id, int assignmentId, CancellationToken ct) =>
    ToActionResult(await _courseService.SyncAssignmentAsync(id, assignmentId, CurrentUser, ct));
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
// IUserSearchRepository ya está registrado desde las guías anteriores.
```

---

## 12. Contrato resultante

| Método | Ruta | Quién | Respuesta |
|---|---|---|---|
| `POST` | `/api/courses` | Admin | `201` `{ courseId, skippedWithoutUser }` |
| `PUT` | `/api/courses/{id}` | Admin | `200` `{ courseId, skippedWithoutUser }` · `409` si se quita una asignación con formularios |
| `GET` | `/api/courses` | Admin | Cada curso con `assignedGroupsCount`, `assignedUsersCount`, `completedUsersCount` |
| `GET` | `/api/courses/{id}` | Admin | Detalle; cada asignación con `groupId`, `groupName`, `dueDate`, `totalUsers`, `completedUsers` |
| `GET` | `/api/courses/{id}/assignments` | Admin | Grupos asignados (grupo + fecha) con avance, `withoutUser` y calificaciones anónimas |
| `GET` | `/api/courses/{id}/assignments/{assignmentId}/users?search=&status=&page=` | Admin | Integrantes con estado, gerencia y fecha de finalización |
| `POST` | `/api/courses/{id}/assignments/{assignmentId}/sync` | Admin | `{ added, removedPending, skippedWithoutUser }` |
| `GET` | `/api/my-courses` | Cualquier usuario | Sus asignaciones, pendientes primero |
| `GET` | `/api/my-courses/{id}/completion-form` | El dueño | Datos del formulario, con la gerencia consultada en ese momento |
| `POST` | `/api/my-courses/{id}/complete` | El dueño | `{ satisfaction, usefulness }` → `200` `{ completedDate }` · `409` si ya lo diligenció · `404` si no es suyo |

Cuerpo de `POST /api/courses` y `PUT /api/courses/{id}` (el grupo 12 dos veces, con fechas distintas):

```json
{
  "name": "Excel avanzado",
  "modality": "VIRTUAL",
  "externalId": "LMS-2231",
  "assignments": [
    { "assignmentId": 41,   "groupId": 12, "dueDate": "2026-10-30" },
    { "assignmentId": null, "groupId": 12, "dueDate": "2026-12-15" },
    { "assignmentId": null, "groupId": 7,  "dueDate": "2026-10-30" }
  ]
}
```

---

## 13. Pruebas

### Asignación

- Crear con el grupo 1 dos veces (30 oct y 15 dic) → dos asignaciones; cada integrante tiene **dos** filas en `course_assignment_user`.
- Crear con el grupo 1 dos veces con la **misma** fecha → `400` con `GroupDueRepeated`.
- Crear con un grupo que tiene 2 personas "solo directorio" → `skippedWithoutUser = 2` y esas personas no tienen fila.
- Editar cambiando el `groupId` de una asignación guardada → `400` con `GroupChangeNotAllowed`.
- Quitar una asignación sin formularios → se borra con sus personas.
- Quitar una asignación con 3 formularios → `409` con el mensaje de cuántas personas; nada cambia.
- Cambiar la fecha de una asignación con formularios → se acepta.
- Actualizar desde el grupo después de agregar 2 personas y quitar 1 pendiente → `added = 2`, `removedPending = 1`; quien ya finalizó y salió del grupo se conserva.

### Formulario

- La misma persona en dos asignaciones del curso → "Mis cursos" muestra dos filas con grupo y fecha; diligenciar una deja la otra pendiente.
- Abrir el formulario de otra persona → `404`, igual que un id que no existe.
- Usuario del token que no está en `dbo.users` → "Mis cursos" vacío y `404` en el formulario.
- Enviar sin una calificación, con `6` o con `-1` → `400`.
- Enviar con `0` en las dos → se acepta.
- Enviar dos veces seguidas → la primera `200`, la segunda `409`; una sola fila en `course_assignment_completion` y una sola en `course_rating`.
- Si el directorio falla, el formulario se abre con `management = null` y el envío se guarda igual.
- Después de enviar: `course_assignment_completion` con la gerencia y la fecha; `course_rating` con curso, asignación, las dos calificaciones y la fecha **sin hora**.

### Grupos asignados y calificaciones

- Curso con asignaciones A (5 respuestas) y B (1 respuesta) → promedio del curso visible, **ninguna** asignación con promedio.
- Curso con A (3) y B (4) → curso y las dos asignaciones visibles.
- Filtro `OVERDUE` → solo pendientes de asignaciones vencidas.

### Base de datos

- La consulta de integridad de la sección 4 da el mismo número de formularios y calificaciones por asignación.
- `DELETE` de una fila de `course_assignment_user` con formulario → lo rechaza `fk_course_assignment_completion_assignment_user`.

---

## 14. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| El script se detiene en el paso 0 | Falta `user_group_id` o `id`, o hay repetidos | Ejecuta la consulta de columnas o la de repetidos de la sección 4 y corrige antes de volver a ejecutar. |
| Error de FK al crear `fk_course_assignment_user_group` | Hay asignaciones con un `user_group_id` que no existe | `SELECT * FROM dbo.course_assignment a WHERE NOT EXISTS (SELECT 1 FROM dbo.user_group g WHERE g.id = a.user_group_id)`. |
| "Mis cursos" sale vacío | El correo del token no está en `users.corporative_email`, o dos usuarios comparten el correo | Revisa el maestro. La guía de grupos tiene la consulta de correos repetidos. |
| `Cannot insert the value NULL into column 'course_id'` en `course_assignment_user` | Tu tabla conserva `course_id` de la primera guía | Mapéalo en la entidad y asígnalo en `NewAssignmentUser` (sección 4, nota). |
| Error `547` al quitar una asignación | Tiene formularios y el servicio no lo detectó (la carga no incluyó `Completion`) | `GetForUpdateAsync` debe incluir `.ThenInclude(u => u.Completion)`. |
| La gerencia siempre sale vacía | `ManagementDirectory` aún no llama a tu método real | Reemplaza la línea marcada con ⬇. |
| Los promedios no aparecen | Menos de 3 respuestas, o una asignación con menos de 3 (entonces no hay promedios por asignación) | Es a propósito: protege el anonimato. |
| Las calificaciones aparecen en los logs | Un middleware registra el cuerpo de las peticiones | Exclúyelo para `POST /api/my-courses/{id}/complete`. |
| En los logs aparece `Error en el repositorio para la entidad …` cuando alguien cierra la página | La cancelación termina envuelta en `InvalidOperationException` | `Guard` la deja pasar. Haz lo mismo en `GenericRepositoryBase`. |

---

## ✅ Checklist

- [ ] Consulta de columnas revisada; `course_id` en `course_assignment_user` resuelto (mapeado o inexistente).
- [ ] `CursosFinalizacion.sql` ejecutado; consulta de integridad sin diferencias.
- [ ] Índice viejo `ux_course_assignment_user_course_user` eliminado (una persona puede estar en varias asignaciones del curso).
- [ ] Entidades y configuraciones actualizadas; `CourseAssignmentCompletionConfiguration` y `CourseRatingConfiguration` registradas.
- [ ] `CourseIndexNames` y `TrySaveAsync` con los índices nuevos.
- [ ] `CourseCompletionRepository` hereda de `GenericRepositoryBase` y está registrado.
- [ ] `ManagementDirectory` conectado al método real que trae la gerencia.
- [ ] `course_rating` sin llave a la persona ni a `course_assignment_user`; fecha sin hora.
- [ ] Endpoint de finalización excluido de cualquier registro de cuerpos de petición.
- [ ] `MyCoursesController` con `[Authorize]`; acciones de grupos asignados con el permiso de administración de cursos.
- [ ] Pruebas de grupo repetido, doble envío, propiedad (`404`) y anonimato por asignación.
