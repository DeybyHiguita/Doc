# 🔔 Cursos — Configuración de alertas por correo — API (.NET 8) y SQL Server

**Lo que se construye:** un módulo para configurar qué correos envía el sistema sobre los cursos, a quién y cuándo.

- **Configuración general:** aplica a todos los cursos.
- **Configuración propia de un curso:** si existe, **reemplaza** a la general para ese curso.

| # | Alerta | Para | Cuándo | Copia (cada alerta tiene la suya) |
|---|---|---|---|---|
| 1 | **Bienvenida** (ya existe) | La persona | Al asignarle el curso | Su líder, su gerencia, su dirección y otros correos |
| 2 | **Recordatorio normal** | La persona | N días antes de la fecha límite (por defecto 7) | Igual, con su propia selección |
| 3 | **Alerta urgente** | La persona | M días antes (por defecto 2), más cerca que la normal | Igual (por defecto, su líder) |
| 4 | **Reporte de resultados** | Líderes, gerencia, dirección u otros correos | En los momentos que se elijan respecto a la fecha límite (por ejemplo, 3 días antes, el día y 3 días después) | — |

- **Los días y los momentos son números libres:** cualquier valor de 0 a 365 días, sin una lista cerrada de opciones.
- **Las copias van siempre en CC del correo de la persona:** se marcan por alerta y no hay un interruptor aparte.

**Requiere:**
- **La cola de correos** de [cursos-cola-correos-api.md](cursos-cola-correos-api.md) ya implementada (tabla `course_email_queue`, `CourseEmailWorker`, composers, `cc` en el correo). Esta guía **no envía correos**: decide qué toca y lo pone en esa cola.
- **La integración con el DataLake** (`IDataLakeEmployeeClient`, hoy en la rama `.claude/DataLake`) para el líder y la gerencia. Si todavía no está en la rama de cursos, ver la nota del Paso 5.

**El frontend** está en [cursos-alertas-angular.md](cursos-alertas-angular.md). **Base:** el código de la rama de cursos (`.claude/Cursos API`). Convenciones: [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md).

---

## 1. Cómo se decide cada envío

```text
Fecha límite de la asignación (por grupo)                                      ▼ due
──────┬──────────────────────────────┬───────────────────────────┬───────────────┬─────────────▶
   Asignación                 due − 7 días                  due − 2 días        due      due + 3
   ① Bienvenida            ② Recordatorio normal        ③ Alerta urgente            ④ Reporte
   (en cola al asignar)     (solo si no ha finalizado)   (con copia)                 (a los interesados)
```

```text
CourseAlertsWorker (cada hora, de 7:00 a 18:00)          CourseEmailWorker (siempre)
  CourseAlertJobService: ¿qué toca hoy?                    toma de la cola, arma con el composer,
  → filas en course_email_queue con dedupe_key  ─────►     envía (25/min), reintenta, registra
```

| Regla | Detalle |
|---|---|
| **Solo pendientes.** | Los recordatorios van a quien **no** ha diligenciado el formulario de finalización. Se revisa al encolar y otra vez al enviar. |
| **Una vez por persona.** | Cada alerta lleva una `dedupe_key` única en la cola (por ejemplo, `COURSE_DUE_URGENT:5821:2026-11-15`). Encolarla otra vez no hace nada. |
| **La urgente manda.** | Dentro de la ventana urgente ya no se encola la normal. |
| **Sin recordatorio redundante.** | Si a la persona la asignaron cuando ya estaba en la ventana del recordatorio normal, no se le envía: la bienvenida ya trae la fecha. |
| **Nada después de la fecha límite.** | Los recordatorios se detienen ese día. |
| **Copias por alerta.** | Cada alerta tiene sus casillas "su líder", "su gerencia", "su dirección" y su lista de correos. Van en **CC** del correo de la persona y se resuelven al enviar. |
| **Reporte a los líderes.** | Cada líder recibe **solo su equipo** dentro del grupo (las personas cuyo líder es él). Los "otros correos" reciben el grupo completo. |
| **Reportes con margen.** | Cada momento de cada asignación sale una vez a cada destinatario. Si el servidor estuvo apagado ese día, se encola hasta 2 días después. |
| **Configuración que aplica.** | Si el curso tiene una propia, se usa **completa**; si no, la general. No se mezclan campos. |
| **Si se cambia la fecha límite.** | La llave incluye la fecha: con la fecha nueva, la persona vuelve a recibir sus alertas a tiempo. |

---

## 2. Decisiones

### Lo que ya existe y se reutiliza

| Necesidad | Se usa |
|---|---|
| Enviar, reintentar, registrar y mostrar el avance | La cola de [cursos-cola-correos-api.md](cursos-cola-correos-api.md): `course_email_queue`, `CourseEmailWorker`, `ICourseEmailComposer` y la pantalla "Envío de correos". |
| No repetir una alerta | `course_email_queue.dedupe_key` (índice único). **No hay tabla de control propia.** |
| El líder, la gerencia y la dirección de cada persona | **El DataLake** (`IDataLakeEmployeeClient`): empleados con `ManagerEmployeeCode`, `ManagementName` y `DirectionName`, más el catálogo de líderes con su correo. Si el DataLake no responde, el líder sale de Graph (`GetManagerAsync`). |
| Buscar personas para las copias (frontend) | `GET /api/users/search` (`UserController`), el mismo buscador de usuarios que ya existe. |
| Plantilla del recordatorio (normal y urgente) | `TemplateCourseReminderUser.html`. Sin cambios. |
| Plantilla del reporte | `TemplateCoursePendingReport.html`, con dos ajustes pequeños (Paso 6). |
| Datos de la persona al enviar | `ICourseCompletionRepository.GetAssignmentUserAsync` (el mismo que usa la bienvenida). |
| Cifras y calificaciones del reporte | `ICourseCompletionService.GetProgressAsync` y `GetAssignmentUsersAsync`. |
| "Hoy" en Colombia | `BusinessDate.Today(TimeProvider)`. |
| Consultas del proceso | El repositorio genérico con `selector`: no hace falta un repositorio propio. |

### Lo que ofrece hoy el DataLake (revisado en `.claude/DataLake`)

| Dato | ¿Está? | Cómo |
|---|---|---|
| **Líder** de una persona | ✅ | Empleado → `ManagerEmployeeCode` → catálogo `leaders` (`EmployeeCode`, `CorporateEmail`). |
| **Gerencia** de una persona (nombre) | ✅ | `ClickEmployeeDto.ManagementName`. |
| **Dirección** de una persona (nombre) | ✅ | `ClickEmployeeDto.DirectionName`. |
| **Correo del gerente** o **del director** | ❌ | Los catálogos `managements` y `directions` solo traen `Code` y `Name`, sin responsable. |

**En consecuencia:**
- **"Su líder"** funciona desde ya.
- **"Su gerencia" y "su dirección"** se guardan y se muestran como "Pronto". El proceso deja un aviso en el log y no copia. Cuando el DataLake agregue el responsable a esos catálogos (por ejemplo, `HeadEmployeeCode`), se completa solo `CourseAlertCopyResolver`.
- **De regalo, la gerencia de cada persona:** el formulario de finalización y las listas del reporte dejan de mostrar "No disponible" o "—" (Paso 5).

### Lo nuevo

| # | Tema | Decisión |
|---|---|---|
| 1 | **Estilo del módulo.** | Patrón Request (`ResponseDto`, `ITransactionExecutorHelper`, repositorio genérico, controlador con `try/catch` por acción y `Ok(...)`). |
| 2 | **General y por curso en la misma tabla.** | `course_alert_settings.course_id NULL` = general. `UNIQUE (course_id)`: SQL Server admite **un solo** `NULL`. |
| 3 | **Copias por alerta.** | Cada alerta (bienvenida, recordatorio, urgente) tiene sus columnas: `*_copy_leader`, `*_copy_management`, `*_copy_direction` y `*_copy_emails`. El reporte tiene `report_to_*` y `report_emails`. |
| 4 | **Listas** (correos, momentos). | Columnas JSON (colecciones primitivas de EF Core 8). |
| 5 | **Números libres.** | Días antes: de 0 a 365. Momentos del reporte: de 365 días antes a 365 después, hasta 20. Correos por lista: hasta 50. |
| 6 | **El DataLake, en memoria.** | `DataLakeOrganizationDirectory` trae todos los empleados una vez (páginas de 200) y los guarda **60 minutos** en `IMemoryCache`. Si falla, no lo reintenta durante 5 minutos y sigue sin él. |
| 7 | **Encolar y enviar, separados.** | `CourseAlertJobService` solo decide y encola. El envío lo hace la cola. |
| 8 | **Cuándo corre.** | `CourseAlertsWorker` cada hora entre las 7:00 y las 18:00 de Colombia. Encolar es idempotente. |
| 9 | **El reporte.** | Un correo por destinatario. Las cifras se calculan **al enviar**. A un líder, solo su equipo. |
| 10 | **Bienvenida.** | Su composer lee la configuración: si está apagada, `SKIPPED`; si tiene copias marcadas, van en CC. |

---

## 3. Archivos

```text
DOCCB.Domain/Entities/
└── CourseAlertSettings.cs                                       nuevo

DOCCB.Application/
├── Features/CourseAlerts/Application/
│   ├── Constants/CourseAlertConstants.cs
│   ├── Dtos/CourseAlertDtos.cs
│   ├── Dtos/CourseAlertCandidates.cs                            filas que lee el proceso
│   ├── Helpers/CourseAlertSettingsRules.cs                      validación, mapeo y destinatarios por alerta
│   ├── Helpers/CourseAlertSchedule.cs                           ⭐ qué toca hoy y sus llaves
│   ├── Helpers/CourseAlertProjections.cs                        proyección de una asignación
│   ├── Interfaces/ICourseAlertSettingsService.cs
│   ├── Interfaces/ICourseAlertCopyResolver.cs
│   ├── Interfaces/IOrganizationDirectory.cs                     líder, gerencia y dirección de una persona
│   ├── Interfaces/ICourseAlertJobService.cs
│   ├── Services/CourseAlertSettingsService.cs
│   ├── Services/CourseAlertCopyResolver.cs
│   ├── Services/DataLakeOrganizationDirectory.cs                el DataLake, en caché
│   ├── Services/CourseAlertJobService.cs                        ⭐ decide y encola
│   ├── Composers/CourseReminderEmailComposer.cs                 normal y urgente
│   └── Composers/CourseReportEmailComposer.cs                   reporte de resultados
├── Features/Courses/Application/
│   ├── Helpers/BusinessDate.cs                                  ✏️ + FromUtc
│   └── Services/ManagementDirectory.cs                          ✏️ la gerencia sale del DataLake
├── Features/CourseEmails/Application/
│   ├── Composers/CourseAssignedEmailComposer.cs                 ✏️ respeta la configuración
│   └── Helpers/CourseEmailQueueFactory.cs                       ✏️ + ForPersonId, ForRecipient
├── Contracts/Persistence/ICourseEmailQueueRepository.cs         ✏️ + GetExistingKeysAsync, EnqueueAsync
├── Features/Directory/Application/Interfaces/IGraphDirectoryService.cs  ✏️ + GetManagerAsync
├── Features/Directory/Application/Services/GraphDirectoryService.cs     ✏️
├── Features/EmailAlertLog/Application/Constants/EmailAlertTypes.cs      ✏️ + 2 tipos
├── EmailsTemplate/TemplateCourseReminderUser.html               ya existe, sin cambios
├── EmailsTemplate/TemplateCoursePendingReport.html              ✏️ sin {AREA}, + {CALIFICACIONES}
└── ApplicationServiceRegistration.cs                            ✏️

DOCCB.Infraestructure/
├── Configurations/CourseAlertSettingsConfiguration.cs           nuevo
├── Repositories/CourseEmailQueueRepository.cs                   ✏️
├── Persistence/Models/DOCCbDbContext.cs                         ✏️ DbSet
└── Persistence/Scripts SQL/CourseAlerts.sql                     nuevo

WebApp/
├── Controllers/CourseAlertsController.cs                        nuevo
├── BackgroundServices/CourseAlertsWorker.cs                     nuevo
├── Common/ResponseConstants/ApiResponseConstants.cs             ✏️
├── appsettings.json                                             ✏️ CourseAlerts
└── Program.cs                                                   ✏️ AddHostedService
```

---

## 4. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/CourseAlerts.sql`

```sql
/* =====================================================================
   Cursos · configuración de alertas por correo
   Base de datos: DB · Esquema: dbo

   REQUIERE:
   - dbo.course
   - dbo.course_email_queue (guía de la cola de correos)

   CREA:
   - dbo.course_alert_settings (la general y una por curso)
   - La configuración general con los valores por defecto

   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.course_alert_settings', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_alert_settings
    (
        id                         INT           IDENTITY(1, 1) NOT NULL,
        course_id                  INT           NULL,     -- NULL = configuración general

        -- ① Bienvenida y sus copias
        welcome_enabled            BIT           NOT NULL CONSTRAINT df_cas_welcome_enabled DEFAULT (1),
        welcome_copy_leader        BIT           NOT NULL CONSTRAINT df_cas_welcome_leader DEFAULT (0),
        welcome_copy_management    BIT           NOT NULL CONSTRAINT df_cas_welcome_management DEFAULT (0),
        welcome_copy_direction     BIT           NOT NULL CONSTRAINT df_cas_welcome_direction DEFAULT (0),
        welcome_copy_emails        NVARCHAR(MAX) NOT NULL CONSTRAINT df_cas_welcome_emails DEFAULT (N'[]'),

        -- ② Recordatorio normal y sus copias
        reminder_enabled           BIT           NOT NULL CONSTRAINT df_cas_reminder_enabled DEFAULT (1),
        reminder_days_before       INT           NOT NULL CONSTRAINT df_cas_reminder_days DEFAULT (7),
        reminder_copy_leader       BIT           NOT NULL CONSTRAINT df_cas_reminder_leader DEFAULT (0),
        reminder_copy_management   BIT           NOT NULL CONSTRAINT df_cas_reminder_management DEFAULT (0),
        reminder_copy_direction    BIT           NOT NULL CONSTRAINT df_cas_reminder_direction DEFAULT (0),
        reminder_copy_emails       NVARCHAR(MAX) NOT NULL CONSTRAINT df_cas_reminder_emails DEFAULT (N'[]'),

        -- ③ Alerta urgente y sus copias
        urgent_enabled             BIT           NOT NULL CONSTRAINT df_cas_urgent_enabled DEFAULT (1),
        urgent_days_before         INT           NOT NULL CONSTRAINT df_cas_urgent_days DEFAULT (2),
        urgent_copy_leader         BIT           NOT NULL CONSTRAINT df_cas_urgent_leader DEFAULT (1),
        urgent_copy_management     BIT           NOT NULL CONSTRAINT df_cas_urgent_management DEFAULT (0),
        urgent_copy_direction      BIT           NOT NULL CONSTRAINT df_cas_urgent_direction DEFAULT (0),
        urgent_copy_emails         NVARCHAR(MAX) NOT NULL CONSTRAINT df_cas_urgent_emails DEFAULT (N'[]'),

        -- ④ Reporte de resultados y a quién va
        report_enabled             BIT           NOT NULL CONSTRAINT df_cas_report_enabled DEFAULT (0),
        report_day_offsets         NVARCHAR(MAX) NOT NULL CONSTRAINT df_cas_report_offsets DEFAULT (N'[]'), -- JSON [-3,0,3]
        report_to_leader           BIT           NOT NULL CONSTRAINT df_cas_report_leader DEFAULT (0),
        report_to_management       BIT           NOT NULL CONSTRAINT df_cas_report_management DEFAULT (0),
        report_to_direction        BIT           NOT NULL CONSTRAINT df_cas_report_direction DEFAULT (0),
        report_emails              NVARCHAR(MAX) NOT NULL CONSTRAINT df_cas_report_emails DEFAULT (N'[]'),

        created_date               DATETIME2(0)  NOT NULL CONSTRAINT df_cas_created_date DEFAULT (SYSUTCDATETIME()),
        created_by                 NVARCHAR(150) NOT NULL,
        updated_date               DATETIME2(0)  NULL,
        updated_by                 NVARCHAR(150) NULL,

        CONSTRAINT pk_course_alert_settings PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_course_alert_settings_course FOREIGN KEY (course_id) REFERENCES dbo.course (id) ON DELETE CASCADE,
        -- UNIQUE en SQL Server admite un solo NULL: una general y, como máximo, una por curso.
        CONSTRAINT uq_course_alert_settings_course UNIQUE (course_id),
        CONSTRAINT ck_cas_reminder_days CHECK (reminder_days_before BETWEEN 0 AND 365),
        CONSTRAINT ck_cas_urgent_days CHECK (urgent_days_before BETWEEN 0 AND 365),
        CONSTRAINT ck_cas_json CHECK (
            ISJSON(welcome_copy_emails) = 1 AND ISJSON(reminder_copy_emails) = 1 AND ISJSON(urgent_copy_emails) = 1
            AND ISJSON(report_day_offsets) = 1 AND ISJSON(report_emails) = 1)
    );
END;
GO

-- La configuración general con los valores por defecto.
IF NOT EXISTS (SELECT 1 FROM dbo.course_alert_settings WHERE course_id IS NULL)
    INSERT INTO dbo.course_alert_settings (course_id, created_by) VALUES (NULL, N'sistema');
GO
```

> Los cursos se eliminan con `removed = 1`, así que el `ON DELETE CASCADE` solo actúa si alguien borra la fila del curso a mano.

---

## 5. Paso 2 — Dominio y EF Core

### `DOCCB.Domain/Entities/CourseAlertSettings.cs`

```csharp
namespace DOCCB.Domain.Entities
{
    /// <summary>Configuración de alertas de cursos. CourseId null = la general; con valor = la propia de ese curso.</summary>
    public class CourseAlertSettings
    {
        public int Id { get; set; }
        public int? CourseId { get; set; }

        // ① Bienvenida
        public bool WelcomeEnabled { get; set; } = true;
        public bool WelcomeCopyLeader { get; set; }
        public bool WelcomeCopyManagement { get; set; }
        public bool WelcomeCopyDirection { get; set; }
        public List<string> WelcomeCopyEmails { get; set; } = [];

        // ② Recordatorio normal
        public bool ReminderEnabled { get; set; } = true;
        public int ReminderDaysBefore { get; set; } = 7;
        public bool ReminderCopyLeader { get; set; }
        public bool ReminderCopyManagement { get; set; }
        public bool ReminderCopyDirection { get; set; }
        public List<string> ReminderCopyEmails { get; set; } = [];

        // ③ Urgente
        public bool UrgentEnabled { get; set; } = true;
        public int UrgentDaysBefore { get; set; } = 2;
        public bool UrgentCopyLeader { get; set; } = true;
        public bool UrgentCopyManagement { get; set; }
        public bool UrgentCopyDirection { get; set; }
        public List<string> UrgentCopyEmails { get; set; } = [];

        // ④ Reporte de resultados
        public bool ReportEnabled { get; set; }
        /// <summary>Días respecto a la fecha límite: -3 = tres días antes, 0 = el día, 3 = tres días después.</summary>
        public List<int> ReportDayOffsets { get; set; } = [];
        public bool ReportToLeader { get; set; }
        public bool ReportToManagement { get; set; }
        public bool ReportToDirection { get; set; }
        public List<string> ReportEmails { get; set; } = [];

        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;
        public DateTime? UpdatedDate { get; set; }
        public string? UpdatedBy { get; set; }

        public Course? Course { get; set; }
    }
}
```

### `Configurations/CourseAlertSettingsConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class CourseAlertSettingsConfiguration : IEntityTypeConfiguration<CourseAlertSettings>
    {
        public void Configure(EntityTypeBuilder<CourseAlertSettings> builder)
        {
            builder.ToTable("course_alert_settings", "dbo");
            builder.HasKey(s => s.Id).HasName("pk_course_alert_settings");

            builder.Property(s => s.Id).HasColumnName("id");
            builder.Property(s => s.CourseId).HasColumnName("course_id");

            builder.Property(s => s.WelcomeEnabled).HasColumnName("welcome_enabled");
            builder.Property(s => s.WelcomeCopyLeader).HasColumnName("welcome_copy_leader");
            builder.Property(s => s.WelcomeCopyManagement).HasColumnName("welcome_copy_management");
            builder.Property(s => s.WelcomeCopyDirection).HasColumnName("welcome_copy_direction");
            builder.Property(s => s.WelcomeCopyEmails).HasColumnName("welcome_copy_emails");

            builder.Property(s => s.ReminderEnabled).HasColumnName("reminder_enabled");
            builder.Property(s => s.ReminderDaysBefore).HasColumnName("reminder_days_before");
            builder.Property(s => s.ReminderCopyLeader).HasColumnName("reminder_copy_leader");
            builder.Property(s => s.ReminderCopyManagement).HasColumnName("reminder_copy_management");
            builder.Property(s => s.ReminderCopyDirection).HasColumnName("reminder_copy_direction");
            builder.Property(s => s.ReminderCopyEmails).HasColumnName("reminder_copy_emails");

            builder.Property(s => s.UrgentEnabled).HasColumnName("urgent_enabled");
            builder.Property(s => s.UrgentDaysBefore).HasColumnName("urgent_days_before");
            builder.Property(s => s.UrgentCopyLeader).HasColumnName("urgent_copy_leader");
            builder.Property(s => s.UrgentCopyManagement).HasColumnName("urgent_copy_management");
            builder.Property(s => s.UrgentCopyDirection).HasColumnName("urgent_copy_direction");
            builder.Property(s => s.UrgentCopyEmails).HasColumnName("urgent_copy_emails");

            builder.Property(s => s.ReportEnabled).HasColumnName("report_enabled");
            builder.Property(s => s.ReportDayOffsets).HasColumnName("report_day_offsets");
            builder.Property(s => s.ReportToLeader).HasColumnName("report_to_leader");
            builder.Property(s => s.ReportToManagement).HasColumnName("report_to_management");
            builder.Property(s => s.ReportToDirection).HasColumnName("report_to_direction");
            builder.Property(s => s.ReportEmails).HasColumnName("report_emails");

            builder.Property(s => s.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(s => s.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
            builder.Property(s => s.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
            builder.Property(s => s.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

            builder.HasOne(s => s.Course)
                .WithMany()
                .HasForeignKey(s => s.CourseId)
                .HasConstraintName("fk_course_alert_settings_course")
                .OnDelete(DeleteBehavior.Cascade);
        }
    }
}
```

> Las `List<string>` y `List<int>` se guardan como JSON en `nvarchar(max)` (EF Core 8), sin configuración extra.

### `DOCCbDbContext.cs` ✏️

```csharp
public DbSet<CourseAlertSettings> CourseAlertSettings { get; set; }
```

---

## 6. Paso 3 — Constantes, DTOs y reglas

### `Features/EmailAlertLog/Application/Constants/EmailAlertTypes.cs` ✏️

Agrega los dos tipos y súmalos a `All`, que alimenta el filtro de "Registro de correos":

```csharp
public const string CourseAssigned = "COURSE_ASSIGNED";
public const string CourseDueReminder = "COURSE_DUE_REMINDER";
public const string CourseDueUrgent = "COURSE_DUE_URGENT";
public const string CourseOverdue = "COURSE_OVERDUE";
public const string CourseResultsReport = "COURSE_RESULTS_REPORT";

/// <summary>Para el filtro de "Registro de correos": siempre visibles aunque aún no haya envíos.</summary>
public static readonly string[] All = [CourseAssigned, CourseDueReminder, CourseDueUrgent, CourseOverdue, CourseResultsReport];
```

### `Features/Courses/Application/Helpers/BusinessDate.cs` ✏️ — agrega

```csharp
/// <summary>Fecha de Colombia de un instante guardado en UTC (por ejemplo, la fecha de finalización).</summary>
public static DateOnly FromUtc(DateTime utc) =>
    DateOnly.FromDateTime(TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), Zone));
```

### `Constants/CourseAlertConstants.cs`

```csharp
namespace DOCCB.Application.Features.CourseAlerts.Application.Constants
{
    public static class CourseAlertConstants
    {
        /// <summary>Días antes de la fecha límite: de 0 (el mismo día) a 365.</summary>
        public const int MaxDaysBefore = 365;
        public const int MaxEmails = 50;
        public const int MaxReportMoments = 20;
        /// <summary>Los momentos del reporte van de 365 días antes a 365 días después de la fecha límite.</summary>
        public const int MaxReportOffset = 365;
        /// <summary>Si el servidor estuvo apagado el día exacto, el reporte se encola hasta 2 días después.</summary>
        public const int ReportGraceDays = 2;
        public const int PreviewMaxItems = 200;
        /// <summary>El máximo por página que deja ICourseCompletionService.GetAssignmentUsersAsync.</summary>
        public const int PeoplePageSize = 100;
        /// <summary>Quién encoló, cuando lo hace el proceso programado.</summary>
        public const string SystemUser = "sistema";

        /// <summary>Por qué recibe el reporte (course_email_queue.recipient_role).</summary>
        public const string RoleLeader = "LEADER";
        public const string RoleEmail = "EMAIL";

        // Plantillas que ya están en EmailsTemplate.
        public const string ReminderTemplate = "TemplateCourseReminderUser.html";
        public const string ReportTemplate = "TemplateCoursePendingReport.html";

        public const string ReminderSubject = "Recordatorio: tienes un curso pendiente";
        public const string UrgentSubject = "Urgente: tu curso está por vencer";
        public const string UrgentMessage = "Esta es una alerta prioritaria: el plazo para terminar el curso está por vencer.";
        public const string NoGroupName = "Grupo sin nombre";
        /// <summary>Saludo del reporte cuando el correo no está en users ("Hola equipo,").</summary>
        public const string ReportFallbackName = "equipo";

        // Motivos para no enviar (quedan en course_email_queue.last_error, estado SKIPPED).
        public const string WelcomeDisabled = "La bienvenida está apagada para este curso.";
        public const string AlertDisabled = "Esta alerta está apagada para este curso.";
        public const string AlreadyCompleted = "La persona ya diligenció el formulario de finalización.";
        public const string DueDatePassed = "La fecha límite ya pasó.";
        public const string AssignmentRemoved = "La asignación ya no existe.";
        public const string LeaderWithoutTeam = "Ninguna persona del grupo tiene a este líder.";
        public const string ProgressUnavailable = "No se pudo leer el avance del curso.";

        public const string CourseNotFound = "El curso no existe.";
        public const string DaysInvalid = "Los días de anticipación deben estar entre 0 y 365.";
        public const string UrgentMustBeCloser = "La alerta urgente debe enviarse más cerca de la fecha límite que el recordatorio normal.";
        public const string TooManyEmails = "Puedes agregar hasta 50 correos en cada lista.";
        public const string InvalidEmails = "Estos correos no son válidos: {0}.";
        public const string ReportWithoutMoments = "Agrega al menos un momento para enviar el reporte de resultados.";
        public const string ReportWithoutRecipients = "Elige quién recibe el reporte: líderes, gerencia, dirección u otros correos.";
        public const string ReportMomentsInvalid = "Los momentos del reporte van de 365 días antes a 365 días después de la fecha límite (máximo 20).";
        public const string ConcurrentChange = "Otra persona guardó esta configuración al mismo tiempo. Recarga la página e intenta de nuevo.";
        public const string UnexpectedError = "No se pudo completar la operación. Intenta de nuevo.";
    }
}
```

### `Dtos/CourseAlertDtos.cs`

La pantalla trabaja con un bloque por alerta. La tabla es plana; `CourseAlertSettingsRules` traduce entre los dos.

```csharp
namespace DOCCB.Application.Features.CourseAlerts.Application.Dtos
{
    /// <summary>A quién se copia una alerta (o a quién va el reporte).</summary>
    public class CourseAlertRecipientsDto
    {
        /// <summary>El líder de cada persona.</summary>
        public bool Leader { get; set; }
        /// <summary>La gerencia de cada persona. Pendiente: el DataLake aún no trae el correo del gerente.</summary>
        public bool Management { get; set; }
        /// <summary>La dirección de cada persona. Pendiente: el DataLake aún no trae el correo del director.</summary>
        public bool Direction { get; set; }
        public List<string> Emails { get; set; } = [];
    }

    public class CourseAlertWelcomeDto
    {
        public bool Enabled { get; set; }
        public CourseAlertRecipientsDto Copy { get; set; } = new();
    }

    public class CourseAlertReminderDto
    {
        public bool Enabled { get; set; }
        /// <summary>Días antes de la fecha límite (0 = el mismo día).</summary>
        public int DaysBefore { get; set; }
        public CourseAlertRecipientsDto Copy { get; set; } = new();
    }

    public class CourseAlertReportDto
    {
        public bool Enabled { get; set; }
        /// <summary>-3 = tres días antes, 0 = el día, 3 = tres días después.</summary>
        public List<int> DayOffsets { get; set; } = [];
        public CourseAlertRecipientsDto To { get; set; } = new();
    }

    /// <summary>Lo que se edita en pantalla (general o de un curso). UpdatedDate/UpdatedBy solo van en la respuesta.</summary>
    public class CourseAlertSettingsDto
    {
        public CourseAlertWelcomeDto Welcome { get; set; } = new();
        public CourseAlertReminderDto Reminder { get; set; } = new();
        public CourseAlertReminderDto Urgent { get; set; } = new();
        public CourseAlertReportDto Report { get; set; } = new();

        public DateTime? UpdatedDate { get; set; }
        public string? UpdatedBy { get; set; }
    }

    public class CourseAlertCourseSettingsDto
    {
        public int CourseId { get; set; }
        public string CourseName { get; set; } = string.Empty;
        /// <summary>true = el curso no tiene configuración propia: Settings trae la general, que es la que aplica.</summary>
        public bool UsesGeneral { get; set; }
        public CourseAlertSettingsDto Settings { get; set; } = new();
    }

    /// <summary>
    /// Lo que se encoló en una ejecución (o lo que se encolaría, con DryRun = true).
    /// Cuenta correos nuevos: lo que ya estaba en la cola no se repite ni se cuenta.
    /// </summary>
    public class CourseAlertRunResultDto
    {
        public DateOnly Date { get; set; }
        public bool DryRun { get; set; }
        public int Reminders { get; set; }
        public int Urgent { get; set; }
        public int Reports { get; set; }
        /// <summary>Solo en la vista previa (máximo 200).</summary>
        public List<CourseAlertPreviewItemDto> Items { get; set; } = [];
    }

    public class CourseAlertPreviewItemDto
    {
        public string AlertType { get; set; } = string.Empty;
        public string CourseName { get; set; } = string.Empty;
        public string GroupName { get; set; } = string.Empty;
        public DateOnly DueDate { get; set; }
        public string To { get; set; } = string.Empty;
        /// <summary>La política de copia ("Líder", "Gerencia", correos fijos). El líder real se resuelve al enviar.</summary>
        public List<string> Copies { get; set; } = [];
    }
}
```

### `Dtos/CourseAlertCandidates.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.CourseAlerts.Application.Dtos
{
    /// <summary>Una persona pendiente con fecha límite próxima.</summary>
    public sealed record CourseAlertCandidate(
        int AssignmentUserId,
        int AssignmentId,
        int CourseId,
        string CourseName,
        string GroupName,
        DateOnly DueDate,
        DateTime AssignedDate,
        string Email);

    /// <summary>Una asignación (grupo + fecha) con su curso.</summary>
    public sealed record CourseAlertAssignment(
        int AssignmentId,
        int CourseId,
        string CourseName,
        CourseModality Modality,
        string GroupName,
        DateOnly DueDate);
}
```

### `Helpers/CourseAlertProjections.cs`

La usan el proceso (reportes que tocan) y el composer del reporte.

```csharp
using System.Linq.Expressions;
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.CourseAlerts.Application.Helpers
{
    public static class CourseAlertProjections
    {
        public static readonly Expression<Func<CourseAssignment, CourseAlertAssignment>> Assignment = a =>
            new CourseAlertAssignment(
                a.Id,
                a.CourseId,
                a.Course.Name,
                a.Course.Modality,
                a.UserGroup != null ? a.UserGroup.Name : CourseAlertConstants.NoGroupName,
                a.DueDate);
    }
}
```

### `Helpers/CourseAlertSettingsRules.cs`

```csharp
using System.Net.Mail;
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.CourseAlerts.Application.Helpers
{
    /// <summary>A quién se copia una alerta (o a quién va el reporte), ya leído de la configuración.</summary>
    public sealed record CourseAlertRecipients(bool Leader, bool Management, bool Direction, IReadOnlyList<string> Emails)
    {
        public static readonly CourseAlertRecipients None = new(false, false, false, []);

        public bool IsEmpty => !Leader && !Management && !Direction && Emails.Count == 0;
    }

    public static class CourseAlertSettingsRules
    {
        /// <summary>Los mismos valores por defecto del script. Se usan si la general no existe en la base.</summary>
        public static CourseAlertSettings Defaults() => new() { CreatedBy = CourseAlertConstants.SystemUser };

        /// <summary>Limpia y valida lo que llega de la pantalla. Devuelve la versión normalizada.</summary>
        public static CourseAlertSettingsDto Normalize(CourseAlertSettingsDto dto, List<string> errors)
        {
            var welcome = dto.Welcome ?? new();
            var reminder = dto.Reminder ?? new();
            var urgent = dto.Urgent ?? new();
            var report = dto.Report ?? new();

            if (reminder.DaysBefore is < 0 or > CourseAlertConstants.MaxDaysBefore
                || urgent.DaysBefore is < 0 or > CourseAlertConstants.MaxDaysBefore)
            {
                errors.Add(CourseAlertConstants.DaysInvalid);
            }

            if (reminder.Enabled && urgent.Enabled && urgent.DaysBefore >= reminder.DaysBefore)
            {
                errors.Add(CourseAlertConstants.UrgentMustBeCloser);
            }

            var offsets = (report.DayOffsets ?? []).Distinct().Order().ToList();
            if (offsets.Count > CourseAlertConstants.MaxReportMoments
                || offsets.Any(offset => Math.Abs(offset) > CourseAlertConstants.MaxReportOffset))
            {
                errors.Add(CourseAlertConstants.ReportMomentsInvalid);
            }

            if (report.Enabled && offsets.Count == 0)
            {
                errors.Add(CourseAlertConstants.ReportWithoutMoments);
            }

            var reportTo = NormalizeRecipients(report.To, errors);
            if (report.Enabled && !reportTo.Leader && !reportTo.Management && !reportTo.Direction && reportTo.Emails.Count == 0)
            {
                errors.Add(CourseAlertConstants.ReportWithoutRecipients);
            }

            return new CourseAlertSettingsDto
            {
                Welcome = new() { Enabled = welcome.Enabled, Copy = NormalizeRecipients(welcome.Copy, errors) },
                Reminder = new() { Enabled = reminder.Enabled, DaysBefore = reminder.DaysBefore, Copy = NormalizeRecipients(reminder.Copy, errors) },
                Urgent = new() { Enabled = urgent.Enabled, DaysBefore = urgent.DaysBefore, Copy = NormalizeRecipients(urgent.Copy, errors) },
                Report = new() { Enabled = report.Enabled, DayOffsets = offsets, To = reportTo },
            };
        }

        public static void Apply(CourseAlertSettingsDto draft, CourseAlertSettings entity)
        {
            entity.WelcomeEnabled = draft.Welcome.Enabled;
            entity.WelcomeCopyLeader = draft.Welcome.Copy.Leader;
            entity.WelcomeCopyManagement = draft.Welcome.Copy.Management;
            entity.WelcomeCopyDirection = draft.Welcome.Copy.Direction;
            entity.WelcomeCopyEmails = draft.Welcome.Copy.Emails;

            entity.ReminderEnabled = draft.Reminder.Enabled;
            entity.ReminderDaysBefore = draft.Reminder.DaysBefore;
            entity.ReminderCopyLeader = draft.Reminder.Copy.Leader;
            entity.ReminderCopyManagement = draft.Reminder.Copy.Management;
            entity.ReminderCopyDirection = draft.Reminder.Copy.Direction;
            entity.ReminderCopyEmails = draft.Reminder.Copy.Emails;

            entity.UrgentEnabled = draft.Urgent.Enabled;
            entity.UrgentDaysBefore = draft.Urgent.DaysBefore;
            entity.UrgentCopyLeader = draft.Urgent.Copy.Leader;
            entity.UrgentCopyManagement = draft.Urgent.Copy.Management;
            entity.UrgentCopyDirection = draft.Urgent.Copy.Direction;
            entity.UrgentCopyEmails = draft.Urgent.Copy.Emails;

            entity.ReportEnabled = draft.Report.Enabled;
            entity.ReportDayOffsets = draft.Report.DayOffsets;
            entity.ReportToLeader = draft.Report.To.Leader;
            entity.ReportToManagement = draft.Report.To.Management;
            entity.ReportToDirection = draft.Report.To.Direction;
            entity.ReportEmails = draft.Report.To.Emails;
        }

        public static CourseAlertSettingsDto ToDto(CourseAlertSettings s) => new()
        {
            Welcome = new()
            {
                Enabled = s.WelcomeEnabled,
                Copy = ToDto(CopyOf(s, EmailAlertTypes.CourseAssigned)),
            },
            Reminder = new()
            {
                Enabled = s.ReminderEnabled,
                DaysBefore = s.ReminderDaysBefore,
                Copy = ToDto(CopyOf(s, EmailAlertTypes.CourseDueReminder)),
            },
            Urgent = new()
            {
                Enabled = s.UrgentEnabled,
                DaysBefore = s.UrgentDaysBefore,
                Copy = ToDto(CopyOf(s, EmailAlertTypes.CourseDueUrgent)),
            },
            Report = new()
            {
                Enabled = s.ReportEnabled,
                DayOffsets = [.. s.ReportDayOffsets],
                To = ToDto(ReportTo(s)),
            },
            UpdatedDate = s.UpdatedDate ?? s.CreatedDate,
            UpdatedBy = s.UpdatedBy ?? s.CreatedBy,
        };

        /// <summary>A quién se copia esta alerta. None si el tipo no lleva copia.</summary>
        public static CourseAlertRecipients CopyOf(CourseAlertSettings s, string alertType) => alertType switch
        {
            EmailAlertTypes.CourseAssigned => new(s.WelcomeCopyLeader, s.WelcomeCopyManagement, s.WelcomeCopyDirection, s.WelcomeCopyEmails),
            EmailAlertTypes.CourseDueReminder => new(s.ReminderCopyLeader, s.ReminderCopyManagement, s.ReminderCopyDirection, s.ReminderCopyEmails),
            EmailAlertTypes.CourseDueUrgent => new(s.UrgentCopyLeader, s.UrgentCopyManagement, s.UrgentCopyDirection, s.UrgentCopyEmails),
            _ => CourseAlertRecipients.None,
        };

        /// <summary>A quién va el reporte de resultados.</summary>
        public static CourseAlertRecipients ReportTo(CourseAlertSettings s) =>
            new(s.ReportToLeader, s.ReportToManagement, s.ReportToDirection, s.ReportEmails);

        /// <summary>Para la vista previa: a quién se copiaría, sin consultar el DataLake ni Graph.</summary>
        public static List<string> DescribeCopies(CourseAlertRecipients copy)
        {
            var copies = new List<string>();
            if (copy.Leader)
            {
                copies.Add("Líder");
            }

            if (copy.Management)
            {
                copies.Add("Gerencia");
            }

            if (copy.Direction)
            {
                copies.Add("Dirección");
            }

            copies.AddRange(copy.Emails);
            return copies;
        }

        private static CourseAlertRecipientsDto ToDto(CourseAlertRecipients r) => new()
        {
            Leader = r.Leader,
            Management = r.Management,
            Direction = r.Direction,
            Emails = [.. r.Emails],
        };

        private static CourseAlertRecipientsDto NormalizeRecipients(CourseAlertRecipientsDto? dto, List<string> errors) => new()
        {
            Leader = dto?.Leader ?? false,
            Management = dto?.Management ?? false,
            Direction = dto?.Direction ?? false,
            Emails = NormalizeEmails(dto?.Emails, errors),
        };

        /// <summary>Minúsculas, sin repetidos ni vacíos. Los inválidos se reportan (no se descartan en silencio).</summary>
        private static List<string> NormalizeEmails(IEnumerable<string>? emails, List<string> errors)
        {
            var all = (emails ?? [])
                .Select(email => email?.Trim().ToLowerInvariant() ?? string.Empty)
                .Where(email => email.Length > 0)
                .Distinct()
                .ToList();

            var invalid = all.Where(email => email.Length > 320 || !MailAddress.TryCreate(email, out _)).ToList();
            if (invalid.Count > 0)
            {
                errors.Add(string.Format(CourseAlertConstants.InvalidEmails, string.Join(", ", invalid)));
            }

            if (all.Count > CourseAlertConstants.MaxEmails)
            {
                errors.Add(CourseAlertConstants.TooManyEmails);
            }

            return all.Except(invalid).ToList();
        }
    }
}
```

### `Helpers/CourseAlertSchedule.cs` ⭐

Las reglas de la sección 1 y las llaves de la cola, en un solo lugar y sin base de datos (fácil de probar).

```csharp
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.CourseAlerts.Application.Helpers
{
    public static class CourseAlertSchedule
    {
        /// <summary>
        /// Qué recordatorio le toca hoy a esta persona pendiente: CourseDueUrgent, CourseDueReminder o null.
        /// Si ya se encoló, su llave lo detiene en la cola.
        /// </summary>
        public static string? ReminderFor(CourseAlertSettings settings, CourseAlertCandidate person, DateOnly today)
        {
            var daysLeft = person.DueDate.DayNumber - today.DayNumber;
            if (daysLeft < 0)
            {
                return null; // ya venció: no es un recordatorio
            }

            // La urgente manda: dentro de su ventana ya no se encola la normal.
            if (settings.UrgentEnabled && daysLeft <= settings.UrgentDaysBefore)
            {
                return EmailAlertTypes.CourseDueUrgent;
            }

            if (!settings.ReminderEnabled || daysLeft > settings.ReminderDaysBefore)
            {
                return null;
            }

            // Si la asignaron ya dentro de la ventana, la bienvenida trae la fecha: no se repite.
            var windowStart = person.DueDate.AddDays(-settings.ReminderDaysBefore);
            return DateOnly.FromDateTime(person.AssignedDate) < windowStart ? EmailAlertTypes.CourseDueReminder : null;
        }

        /// <summary>
        /// El momento del reporte que toca hoy: el más reciente cuya fecha (fecha límite + días) cayó
        /// entre hoy menos el margen y hoy. null si ninguno.
        /// </summary>
        public static int? ReportOffsetFor(DateOnly dueDate, IEnumerable<int> offsets, DateOnly today, int graceDays)
        {
            int? current = null;
            foreach (var offset in offsets)
            {
                var late = today.DayNumber - dueDate.AddDays(offset).DayNumber;
                if (late >= 0 && late <= graceDays && (current is null || offset > current))
                {
                    current = offset;
                }
            }

            return current;
        }

        /// <summary>Una por persona, tipo y fecha límite: con otra fecha, la alerta vuelve a tocar.</summary>
        public static string ReminderKey(string alertType, int assignmentUserId, DateOnly dueDate) =>
            $"{alertType}:{assignmentUserId}:{dueDate:yyyy-MM-dd}";

        /// <summary>
        /// Una por asignación, fecha límite, momento, rol y destinatario. El rol separa el reporte del equipo
        /// (líder) del reporte completo (otros correos) aunque sea el mismo correo.
        /// </summary>
        public static string ReportKey(int assignmentId, DateOnly dueDate, int offset, string role, string email) =>
            $"{EmailAlertTypes.CourseResultsReport}:{assignmentId}:{dueDate:yyyy-MM-dd}:{offset}:{role}:{email.ToLowerInvariant()}";
    }
}
```

---

## 7. Paso 4 — La configuración: servicio

### `Interfaces/ICourseAlertSettingsService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.CourseAlerts.Application.Interfaces
{
    /// <summary>La general y la de cada curso. Para los composers y el proceso: todas a la vez.</summary>
    public sealed record CourseAlertSettingsSet(CourseAlertSettings General, IReadOnlyDictionary<int, CourseAlertSettings> ByCourse)
    {
        /// <summary>La propia del curso si existe; si no, la general.</summary>
        public CourseAlertSettings For(int courseId) => ByCourse.GetValueOrDefault(courseId) ?? General;
    }

    public interface ICourseAlertSettingsService
    {
        Task<ResponseDto<CourseAlertSettingsDto>> GetGeneralAsync();
        Task<ResponseDto<CourseAlertSettingsDto>> SaveGeneralAsync(CourseAlertSettingsDto dto, string userEmail);

        Task<ResponseDto<CourseAlertCourseSettingsDto>> GetForCourseAsync(int courseId);
        Task<ResponseDto<CourseAlertCourseSettingsDto>> SaveForCourseAsync(int courseId, CourseAlertSettingsDto dto, string userEmail);
        /// <summary>Borra la configuración propia: el curso vuelve a la general.</summary>
        Task<ResponseDto<CourseAlertCourseSettingsDto>> ResetCourseAsync(int courseId);

        /// <summary>Uso interno (composers y proceso).</summary>
        Task<CourseAlertSettingsSet> LoadAllAsync();
    }
}
```

### `Services/CourseAlertSettingsService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Application.Features.CourseAlerts.Application.Helpers;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Application.Features.CourseAlerts.Application.Services
{
    public class CourseAlertSettingsService(ITransactionExecutorHelper transactionHelper) : ICourseAlertSettingsService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        // ── General ─────────────────────────────────────────────────────

        public async Task<ResponseDto<CourseAlertSettingsDto>> GetGeneralAsync()
        {
            var set = await LoadAllAsync();
            return ResponseDtoHelper.CreateSuccessResponseDto(CourseAlertSettingsRules.ToDto(set.General));
        }

        public async Task<ResponseDto<CourseAlertSettingsDto>> SaveGeneralAsync(CourseAlertSettingsDto dto, string userEmail)
        {
            var (saved, errors) = await SaveAsync(courseId: null, dto, userEmail);
            return saved is null
                ? ResponseDtoHelper.CreateErrorResponseDto<CourseAlertSettingsDto>(errors)
                : ResponseDtoHelper.CreateSuccessResponseDto(CourseAlertSettingsRules.ToDto(saved));
        }

        // ── Por curso ───────────────────────────────────────────────────

        public async Task<ResponseDto<CourseAlertCourseSettingsDto>> GetForCourseAsync(int courseId)
        {
            var result = await _transactionHelper.ExecuteQueryAsync<CourseAlertCourseSettingsDto>(async unitOfWork =>
            {
                var courseName = await GetCourseNameAsync(unitOfWork, courseId);
                if (courseName is null)
                {
                    return null;
                }

                // La propia del curso y la general, en una consulta.
                var rows = await unitOfWork.Repository<CourseAlertSettings>()
                    .GetListAsync(s => s.CourseId == courseId || s.CourseId == null);

                var own = rows.FirstOrDefault(s => s.CourseId == courseId);
                var general = rows.FirstOrDefault(s => s.CourseId == null) ?? CourseAlertSettingsRules.Defaults();

                return new CourseAlertCourseSettingsDto
                {
                    CourseId = courseId,
                    CourseName = courseName,
                    UsesGeneral = own is null,
                    Settings = CourseAlertSettingsRules.ToDto(own ?? general),
                };
            });

            return result is null
                ? ResponseDtoHelper.CreateErrorResponseDto<CourseAlertCourseSettingsDto>(CourseAlertConstants.CourseNotFound)
                : ResponseDtoHelper.CreateSuccessResponseDto(result);
        }

        public async Task<ResponseDto<CourseAlertCourseSettingsDto>> SaveForCourseAsync(int courseId, CourseAlertSettingsDto dto, string userEmail)
        {
            var courseName = await _transactionHelper.ExecuteQueryAsync<string>(unitOfWork => GetCourseNameAsync(unitOfWork, courseId));
            if (courseName is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<CourseAlertCourseSettingsDto>(CourseAlertConstants.CourseNotFound);
            }

            var (saved, errors) = await SaveAsync(courseId, dto, userEmail);
            return saved is null
                ? ResponseDtoHelper.CreateErrorResponseDto<CourseAlertCourseSettingsDto>(errors)
                : ResponseDtoHelper.CreateSuccessResponseDto(new CourseAlertCourseSettingsDto
                {
                    CourseId = courseId,
                    CourseName = courseName,
                    UsesGeneral = false,
                    Settings = CourseAlertSettingsRules.ToDto(saved),
                });
        }

        public async Task<ResponseDto<CourseAlertCourseSettingsDto>> ResetCourseAsync(int courseId)
        {
            await _transactionHelper.ExecuteWithTransactionAsync<bool>(async unitOfWork =>
            {
                var repository = unitOfWork.Repository<CourseAlertSettings>();
                var own = await repository.GetAsync(s => s.CourseId == courseId, disableTracking: false);
                if (own is not null)
                {
                    repository.Delete(own);
                }

                return true;
            });

            return await GetForCourseAsync(courseId);
        }

        // ── Uso interno ─────────────────────────────────────────────────

        public async Task<CourseAlertSettingsSet> LoadAllAsync()
        {
            // Una fila general y una por curso con configuración propia: es una tabla pequeña.
            var all = await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<CourseAlertSettings>>(async unitOfWork =>
                await unitOfWork.Repository<CourseAlertSettings>().GetListAsync(s => true)) ?? [];

            var general = all.FirstOrDefault(s => s.CourseId == null) ?? CourseAlertSettingsRules.Defaults();
            var byCourse = all.Where(s => s.CourseId != null).ToDictionary(s => s.CourseId!.Value);

            return new CourseAlertSettingsSet(general, byCourse);
        }

        // ── Privados ────────────────────────────────────────────────────

        /// <summary>Crea o actualiza la general (courseId null) o la de un curso. Primero valida, después modifica.</summary>
        private async Task<(CourseAlertSettings? Saved, List<string> Errors)> SaveAsync(int? courseId, CourseAlertSettingsDto dto, string userEmail)
        {
            var errors = new List<string>();
            var draft = CourseAlertSettingsRules.Normalize(dto, errors);
            if (errors.Count > 0)
            {
                return (null, errors);
            }

            try
            {
                var saved = await _transactionHelper.ExecuteWithTransactionAsync<CourseAlertSettings>(async unitOfWork =>
                {
                    var repository = unitOfWork.Repository<CourseAlertSettings>();
                    var settings = await repository.GetAsync(s => s.CourseId == courseId, disableTracking: false);
                    var now = DateTime.UtcNow;

                    if (settings is null)
                    {
                        settings = new CourseAlertSettings { CourseId = courseId, CreatedDate = now, CreatedBy = userEmail };
                        await repository.AddAsync(settings);
                    }
                    else
                    {
                        settings.UpdatedDate = now;
                        settings.UpdatedBy = userEmail;
                    }

                    CourseAlertSettingsRules.Apply(draft, settings);
                    return settings;
                });

                return saved is null ? (null, [CourseAlertConstants.UnexpectedError]) : (saved, []);
            }
            catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
            {
                // Dos personas crearon a la vez la configuración del mismo curso (uq_course_alert_settings_course).
                return (null, [CourseAlertConstants.ConcurrentChange]);
            }
        }

        private static async Task<string?> GetCourseNameAsync(IUnitOfWork unitOfWork, int courseId) =>
            (await unitOfWork.Repository<Course>().GetListAsync(
                c => c.Id == courseId && !c.Removed,
                selector: q => q.Select(c => c.Name).Take(1)))
            .FirstOrDefault();
    }
}
```

> **`s.CourseId == courseId` con `courseId` en `null`:** EF Core lo traduce a `course_id IS NULL`, así que el mismo `SaveAsync` sirve para la general.

---

## 8. Paso 5 — Líder, gerencia y dirección: el DataLake

El parámetro `cc` de `SendTemplatedEmailAsync` ya está (guía de la cola, Paso 6).

### `Interfaces/IOrganizationDirectory.cs`

```csharp
namespace DOCCB.Application.Features.CourseAlerts.Application.Interfaces
{
    /// <summary>Una persona en el maestro de empleados: su líder, su gerencia y su dirección.</summary>
    public sealed record OrganizationPerson(
        string Email,
        string FullName,
        string? LeaderEmail,
        string? ManagementName,
        string? DirectionName);

    public interface IOrganizationDirectory
    {
        /// <summary>
        /// Las personas que encuentre, por correo corporativo (sin distinguir mayúsculas).
        /// Vacío si el DataLake está apagado o no responde. Nunca lanza.
        /// </summary>
        Task<IReadOnlyDictionary<string, OrganizationPerson>> FindByEmailsAsync(IReadOnlyCollection<string> emails, CancellationToken ct);
    }
}
```

### `Services/DataLakeOrganizationDirectory.cs`

El DataLake no filtra empleados por correo. Por eso se trae el maestro completo una vez (páginas de 200, el máximo que acepta) y se guarda en memoria.

```csharp
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.Application.Features.DataLake.Application.DTOs;
using DOCCB.Application.Features.DataLake.Application.Interfaces;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.CourseAlerts.Application.Services
{
    /// <summary>
    /// El maestro de empleados del DataLake, en memoria 60 minutos para toda la aplicación.
    /// Si el DataLake falla, se sigue sin él y no se vuelve a intentar durante 5 minutos.
    /// </summary>
    public class DataLakeOrganizationDirectory(
        IDataLakeEmployeeClient dataLake,
        IMemoryCache cache,
        IConfiguration configuration,
        ILogger<DataLakeOrganizationDirectory> logger) : IOrganizationDirectory
    {
        private const string CacheKey = "course-alerts:organization";
        private const int PageSize = 200;
        private static readonly TimeSpan Fresh = TimeSpan.FromMinutes(60);
        private static readonly TimeSpan RetryAfterError = TimeSpan.FromMinutes(5);
        private static readonly IReadOnlyDictionary<string, OrganizationPerson> Empty = new Dictionary<string, OrganizationPerson>();

        /// <summary>Una sola carga a la vez: el proceso y varios correos pueden pedirla al mismo tiempo.</summary>
        private static readonly SemaphoreSlim LoadLock = new(1, 1);

        private readonly IDataLakeEmployeeClient _dataLake = dataLake;
        private readonly IMemoryCache _cache = cache;
        private readonly IConfiguration _configuration = configuration;
        private readonly ILogger<DataLakeOrganizationDirectory> _logger = logger;

        public async Task<IReadOnlyDictionary<string, OrganizationPerson>> FindByEmailsAsync(IReadOnlyCollection<string> emails, CancellationToken ct)
        {
            var everyone = await GetEveryoneAsync(ct);
            var found = new Dictionary<string, OrganizationPerson>(StringComparer.OrdinalIgnoreCase);

            foreach (var email in emails)
            {
                if (everyone.TryGetValue(email.Trim(), out var person))
                {
                    found[email] = person;
                }
            }

            return found;
        }

        private async Task<IReadOnlyDictionary<string, OrganizationPerson>> GetEveryoneAsync(CancellationToken ct)
        {
            if (_cache.TryGetValue(CacheKey, out IReadOnlyDictionary<string, OrganizationPerson>? cached) && cached is not null)
            {
                return cached;
            }

            if (!bool.TryParse(_configuration["DataLakeApi:Enabled"], out var enabled) || !enabled)
            {
                return Empty;
            }

            await LoadLock.WaitAsync(ct);
            try
            {
                // Otro hilo pudo cargarlo mientras se esperaba el turno.
                if (_cache.TryGetValue(CacheKey, out cached) && cached is not null)
                {
                    return cached;
                }

                var everyone = await LoadAsync(ct);
                _cache.Set(CacheKey, everyone, Fresh);
                _logger.LogInformation("Maestro de empleados del DataLake en memoria: {Count} personas.", everyone.Count);
                return everyone;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogWarning(ex, "No se pudo leer el maestro de empleados del DataLake. Se sigue sin líder, gerencia ni dirección.");
                _cache.Set(CacheKey, Empty, RetryAfterError);
                return Empty;
            }
            finally
            {
                LoadLock.Release();
            }
        }

        private async Task<IReadOnlyDictionary<string, OrganizationPerson>> LoadAsync(CancellationToken ct)
        {
            var employees = new List<ClickEmployeeDto>();
            for (var page = 1; ; page++)
            {
                var result = await _dataLake.GetEmployeesAsync(new DataLakeEmployeeQueryDto(PageNumber: page, PageSize: PageSize), ct);
                employees.AddRange(result.Items);

                if (result.Items.Count < PageSize || employees.Count >= result.TotalCount)
                {
                    break;
                }
            }

            // Correo de cada líder por su código de empleado: el catálogo de líderes y, si falta, el propio maestro.
            var emailByCode = (await _dataLake.GetLeadersAsync(ct))
                .Where(leader => !string.IsNullOrWhiteSpace(leader.CorporateEmail))
                .GroupBy(leader => leader.EmployeeCode)
                .ToDictionary(g => g.Key, g => g.First().CorporateEmail.Trim().ToLowerInvariant());

            foreach (var employee in employees.Where(e => !string.IsNullOrWhiteSpace(e.CorporateEmail)))
            {
                emailByCode.TryAdd(employee.EmployeeCode, employee.CorporateEmail!.Trim().ToLowerInvariant());
            }

            return employees
                .Where(e => !string.IsNullOrWhiteSpace(e.CorporateEmail))
                .GroupBy(e => e.CorporateEmail!.Trim(), StringComparer.OrdinalIgnoreCase)
                .ToDictionary(
                    g => g.Key,
                    g =>
                    {
                        var e = g.First();
                        var leaderEmail = e.ManagerEmployeeCode is { } code && emailByCode.TryGetValue(code, out var leader) ? leader : null;
                        return new OrganizationPerson(g.Key.ToLowerInvariant(), e.FullName, leaderEmail, e.ManagementName, e.DirectionName);
                    },
                    StringComparer.OrdinalIgnoreCase);
        }
    }
}
```

> **Si la integración del DataLake todavía no está en la rama de cursos**, `IDataLakeEmployeeClient` no existe y esta clase no compila. Mientras tanto, registra una versión vacía (ver "Registro"): el líder sale de Graph y lo demás sigue igual.
>
> **Con `DataLakeApi:Enabled` en `false`** (por ejemplo, en desarrollo), esta clase devuelve vacío sin llamar al DataLake.

### `IGraphDirectoryService` ✏️ — el líder según Entra ID (respaldo)

```csharp
/// <summary>Líder (manager) de la persona en Entra ID. null si no tiene.</summary>
Task<DirectoryUser?> GetManagerAsync(string email, CancellationToken ct);
```

### `GraphDirectoryService` ✏️

Con los mismos `graph`, `UserFields`, `ToDirectoryUser` y `GuardAsync` de la clase:

```csharp
public Task<DirectoryUser?> GetManagerAsync(string email, CancellationToken ct) => GuardAsync(async () =>
{
    try
    {
        var manager = await graph.Users[email].Manager.GetAsync(
            request => request.QueryParameters.Select = UserFields, ct);

        return manager is User user ? ToDirectoryUser(user) : null;
    }
    catch (ODataError ex) when (ex.ResponseStatusCode == 404)
    {
        return null; // sin líder asignado en el directorio (o la persona no existe)
    }
});
```

### `Interfaces/ICourseAlertCopyResolver.cs`

```csharp
using DOCCB.Application.Features.CourseAlerts.Application.Helpers;

namespace DOCCB.Application.Features.CourseAlerts.Application.Interfaces
{
    public interface ICourseAlertCopyResolver
    {
        /// <summary>Las copias de una alerta para esta persona (líder, gerencia, dirección y correos), sin ella misma. Nunca lanza.</summary>
        Task<IReadOnlyList<string>> ResolveAsync(CourseAlertRecipients copy, string userEmail, CancellationToken ct);
    }
}
```

### `Services/CourseAlertCopyResolver.cs`

```csharp
using DOCCB.Application.Features.CourseAlerts.Application.Helpers;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.Application.Features.Directory.Application.Exceptions;
using DOCCB.Application.Features.Directory.Application.Interfaces;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.CourseAlerts.Application.Services
{
    /// <summary>Scoped: lo usan los composers, que corren en el scope de cada correo.</summary>
    public class CourseAlertCopyResolver(
        IOrganizationDirectory organization,
        IGraphDirectoryService directory,
        ILogger<CourseAlertCopyResolver> logger) : ICourseAlertCopyResolver
    {
        private readonly IOrganizationDirectory _organization = organization;
        private readonly IGraphDirectoryService _directory = directory;
        private readonly ILogger<CourseAlertCopyResolver> _logger = logger;

        public async Task<IReadOnlyList<string>> ResolveAsync(CourseAlertRecipients copy, string userEmail, CancellationToken ct)
        {
            var copies = new List<string>(copy.Emails);

            if (copy.Leader && await GetLeaderAsync(userEmail, ct) is { } leader)
            {
                copies.Add(leader);
            }

            if (copy.Management || copy.Direction)
            {
                // PENDIENTE: el DataLake da el NOMBRE de la gerencia y la dirección de la persona, pero no el correo
                // de su responsable. Cuando el catálogo lo traiga, se agrega aquí (como el líder).
                _logger.LogWarning("Copia a gerencia o dirección activa, pero el DataLake aún no trae el correo del responsable: no se envía.");
            }

            return copies
                .Select(email => email.Trim().ToLowerInvariant())
                .Where(email => email.Length > 0 && !email.Equals(userEmail, StringComparison.OrdinalIgnoreCase))
                .Distinct()
                .ToList();
        }

        /// <summary>El líder según el DataLake y, si no aparece, según Entra ID.</summary>
        private async Task<string?> GetLeaderAsync(string userEmail, CancellationToken ct)
        {
            var people = await _organization.FindByEmailsAsync([userEmail], ct);
            if (people.Values.FirstOrDefault()?.LeaderEmail is { } fromDataLake)
            {
                return fromDataLake;
            }

            try
            {
                return (await _directory.GetManagerAsync(userEmail, ct))?.Email;
            }
            catch (DirectoryUnavailableException ex)
            {
                // El correo a la persona igual sale; solo sin la copia al líder.
                _logger.LogWarning(ex, "No se pudo consultar el líder de {User}.", userEmail);
                return null;
            }
        }
    }
}
```

### `Features/Courses/Application/Services/ManagementDirectory.cs` ✏️ — la gerencia del formulario

`IManagementDirectory` era un TODO que devolvía `null`: el formulario de finalización mostraba "No disponible" y la gerencia de `course_assignment_completion` quedaba vacía. Con el DataLake ya se puede llenar:

```csharp
public class ManagementDirectory(
    IOrganizationDirectory organization,
    ILogger<ManagementDirectory> logger) : IManagementDirectory
{
    public async Task<string?> GetManagementAsync(CurrentUserIdentity user, CancellationToken ct)
    {
        try
        {
            var people = await organization.FindByEmailsAsync(user.Emails.ToList(), ct);
            return people.Values.Select(p => p.ManagementName?.Trim()).FirstOrDefault(name => !string.IsNullOrEmpty(name));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Si el directorio no responde, el formulario se muestra igual con la gerencia "No disponible".
            logger.LogWarning(ex, "No se pudo consultar la gerencia en el DataLake.");
            return null;
        }
    }
}
```

> Ya no usa `IUserManagementService`: quita esa dependencia y el `using` de la clase.

---

## 9. Paso 6 — Las plantillas

Las dos ya están en `EmailsTemplate` y nada las usa todavía.

### `TemplateCourseReminderUser.html` — sin cambios

Sirve para el recordatorio normal y para la urgente. El composer envía:

| Token | Normal | Urgente |
|---|---|---|
| `NOMBRE`, `CURSO`, `MODALIDAD`, `FECHA_LIMITE` | Los de la persona y el curso | Igual |
| `PLAZO_TEXTO` | "Faltan 7 días" | "Faltan 2 días", "Falta 1 día" o "Vence hoy" |
| `ALERTA_COLOR` / `ALERTA_FONDO` | `#B45309` / `#FFF8E1` | `#DC2626` / `#FEE2E2` |
| `MENSAJE` | Vacío | "Esta es una alerta prioritaria…" |
| `CURSO_URL` | El portal (como la bienvenida) | Igual |
| `CTA_URL` | `{portal}/mis-cursos?finalizar={assignmentUserId}` | Igual |

### `TemplateCoursePendingReport.html` ✏️ — cuatro ajustes

La plantilla saluda "como parte del área {AREA}", pero la configuración guarda solo correos. Además, el reporte lleva las calificaciones.

**1. En el comentario de tokens**, cambia la línea de `AREA` por:

```text
      CALIFICACIONES      Resumen de calificaciones (anónimas), ya en texto.
```

**2. El párrafo después de "Hola {NOMBRE},"**: reemplaza

```html
Como parte del área <strong>{AREA}</strong>, te compartimos el estado de un curso
que aún tiene personas pendientes por finalizar.
```

por

```html
Te compartimos el avance de este curso: quiénes ya lo terminaron y quiénes faltan.
```

**3. Después del texto `{PORCENTAJE}% del grupo finalizó el curso.`** (cierra su `</div>`), agrega:

```html
<!-- Calificaciones (anónimas) -->
<div style="margin-top:16px; padding:12px 14px; border-radius:8px; background-color:#FFF8E1; color:#333333;">
    <strong>Calificaciones (anónimas):</strong> {CALIFICACIONES}
</div>
```

**4. En el mensaje final**, cambia "Recibes este correo porque tu área está registrada como interesada en este curso." por:

```html
Recibes este correo porque estás en la lista de interesados en los resultados de este curso.
```

---

## 10. Paso 7 — ⭐ El proceso: decide y encola

### `Helpers/CourseEmailQueueFactory.cs` ✏️ — agrega

```csharp
/// <summary>Un correo programado para una persona: el proceso ya conoce el Id y la llave.</summary>
public static CourseEmailQueueItem ForPersonId(string alertType, int assignmentUserId, string dedupeKey, DateTime now, string createdBy) => new()
{
    AlertType = alertType,
    AssignmentUserId = assignmentUserId,
    DedupeKey = dedupeKey,
    Status = CourseEmailQueueStatus.Pending,
    NextAttemptDate = now,
    CreatedDate = now,
    CreatedBy = createdBy,
};

/// <summary>Un correo de una asignación a un destinatario fijo (el reporte). role: por qué lo recibe (LEADER, EMAIL).</summary>
public static CourseEmailQueueItem ForRecipient(
    string alertType, int assignmentId, string recipientEmail, string role, string dedupeKey, DateTime now, string createdBy) => new()
{
    AlertType = alertType,
    AssignmentId = assignmentId,
    RecipientEmail = recipientEmail,
    RecipientRole = role,
    DedupeKey = dedupeKey,
    Status = CourseEmailQueueStatus.Pending,
    NextAttemptDate = now,
    CreatedDate = now,
    CreatedBy = createdBy,
};
```

### `ICourseEmailQueueRepository` ✏️ — agrega

```csharp
// ── Alertas programadas ─────────────────────────────────────────
/// <summary>Cuáles de estas llaves ya están en la cola (en cualquier estado).</summary>
Task<IReadOnlySet<string>> GetExistingKeysAsync(IReadOnlyCollection<string> keys, CancellationToken ct);

/// <summary>Encola los que no estén. Devuelve cuántos entraron.</summary>
Task<int> EnqueueAsync(IReadOnlyCollection<CourseEmailQueueItem> items, CancellationToken ct);
```

### `CourseEmailQueueRepository` ✏️ — agrega

```csharp
public async Task<IReadOnlySet<string>> GetExistingKeysAsync(IReadOnlyCollection<string> keys, CancellationToken ct)
{
    if (keys.Count == 0)
    {
        return new HashSet<string>();
    }

    var existing = await _dbSet
        .AsNoTracking()
        .Where(i => i.DedupeKey != null && keys.Contains(i.DedupeKey))
        .Select(i => i.DedupeKey!)
        .ToListAsync(ct);

    return existing.ToHashSet(StringComparer.OrdinalIgnoreCase);
}

public async Task<int> EnqueueAsync(IReadOnlyCollection<CourseEmailQueueItem> items, CancellationToken ct)
{
    if (items.Count == 0)
    {
        return 0;
    }

    _dbSet.AddRange(items);
    try
    {
        await _context.SaveChangesAsync(ct);
        return items.Count;
    }
    catch (DbUpdateException)
    {
        // Otra ejecución encoló alguno al mismo tiempo (ux_ceq_dedupe_key): se guardan uno por uno.
        _context.ChangeTracker.Clear();
    }

    var inserted = 0;
    foreach (var item in items)
    {
        item.Id = 0;
        _dbSet.Add(item);
        try
        {
            await _context.SaveChangesAsync(ct);
            inserted++;
        }
        catch (DbUpdateException)
        {
            // Ya estaba en la cola.
        }
        finally
        {
            _context.ChangeTracker.Clear();
        }
    }

    return inserted;
}
```

### `Interfaces/ICourseAlertJobService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;

namespace DOCCB.Application.Features.CourseAlerts.Application.Interfaces
{
    public interface ICourseAlertJobService
    {
        /// <summary>
        /// Encola los recordatorios, urgentes y reportes que tocan hoy. dryRun = solo dice qué se encolaría.
        /// requestedBy queda en created_by ("sistema" cuando lo hace el proceso programado).
        /// </summary>
        Task<ResponseDto<CourseAlertRunResultDto>> RunAsync(bool dryRun, string requestedBy, CancellationToken ct = default);
    }
}
```

### `Services/CourseAlertJobService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Application.Features.CourseAlerts.Application.Helpers;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.Application.Features.CourseEmails.Application.Helpers;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.CourseAlerts.Application.Services
{
    public class CourseAlertJobService(
        ITransactionExecutorHelper transactionHelper,
        ICourseAlertSettingsService settingsService,
        IOrganizationDirectory organization,
        ICourseEmailQueueRepository queue,
        ICourseEmailQueueSignal queueSignal,
        TimeProvider timeProvider,
        ILogger<CourseAlertJobService> logger) : ICourseAlertJobService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly ICourseAlertSettingsService _settingsService = settingsService;
        private readonly IOrganizationDirectory _organization = organization;
        private readonly ICourseEmailQueueRepository _queue = queue;
        private readonly ICourseEmailQueueSignal _queueSignal = queueSignal;
        private readonly TimeProvider _timeProvider = timeProvider;
        private readonly ILogger<CourseAlertJobService> _logger = logger;

        public async Task<ResponseDto<CourseAlertRunResultDto>> RunAsync(bool dryRun, string requestedBy, CancellationToken ct = default)
        {
            var today = BusinessDate.Today(_timeProvider);
            var now = _timeProvider.GetUtcNow().UtcDateTime;
            var settings = await _settingsService.LoadAllAsync();
            var all = settings.ByCourse.Values.Append(settings.General).ToList();
            var planned = new List<PlannedAlert>();

            // ── ② y ③ Recordatorios a las personas pendientes ───────────
            var maxDays = all.Max(s => Math.Max(
                s.ReminderEnabled ? s.ReminderDaysBefore : 0,
                s.UrgentEnabled ? s.UrgentDaysBefore : 0));

            foreach (var person in await GetPendingPeopleAsync(today, today.AddDays(maxDays)))
            {
                var personSettings = settings.For(person.CourseId);
                var alertType = CourseAlertSchedule.ReminderFor(personSettings, person, today);
                if (alertType is null)
                {
                    continue;
                }

                var key = CourseAlertSchedule.ReminderKey(alertType, person.AssignmentUserId, person.DueDate);
                planned.Add(new PlannedAlert(
                    CourseEmailQueueFactory.ForPersonId(alertType, person.AssignmentUserId, key, now, requestedBy),
                    new CourseAlertPreviewItemDto
                    {
                        AlertType = alertType,
                        CourseName = person.CourseName,
                        GroupName = person.GroupName,
                        DueDate = person.DueDate,
                        To = person.Email,
                        Copies = CourseAlertSettingsRules.DescribeCopies(CourseAlertSettingsRules.CopyOf(personSettings, alertType)),
                    }));
            }

            // ── ④ Reportes de resultados ────────────────────────────────
            var offsets = all.Where(s => s.ReportEnabled).SelectMany(s => s.ReportDayOffsets).ToList();
            if (offsets.Count > 0)
            {
                // Toca si (due + offset) está entre hoy - margen y hoy ⇒ due entre estos límites.
                var dueFrom = today.AddDays(-CourseAlertConstants.ReportGraceDays - offsets.Max());
                var dueTo = today.AddDays(-offsets.Min());

                foreach (var assignment in await GetAssignmentsDueBetweenAsync(dueFrom, dueTo))
                {
                    var assignmentSettings = settings.For(assignment.CourseId);
                    var to = CourseAlertSettingsRules.ReportTo(assignmentSettings);
                    if (!assignmentSettings.ReportEnabled || to.IsEmpty)
                    {
                        continue;
                    }

                    var offset = CourseAlertSchedule.ReportOffsetFor(
                        assignment.DueDate, assignmentSettings.ReportDayOffsets, today, CourseAlertConstants.ReportGraceDays);
                    if (offset is null)
                    {
                        continue;
                    }

                    foreach (var (role, email) in await GetReportRecipientsAsync(assignment, to, ct))
                    {
                        var key = CourseAlertSchedule.ReportKey(assignment.AssignmentId, assignment.DueDate, offset.Value, role, email);
                        planned.Add(new PlannedAlert(
                            CourseEmailQueueFactory.ForRecipient(
                                EmailAlertTypes.CourseResultsReport, assignment.AssignmentId, email, role, key, now, requestedBy),
                            new CourseAlertPreviewItemDto
                            {
                                AlertType = EmailAlertTypes.CourseResultsReport,
                                CourseName = assignment.CourseName,
                                GroupName = assignment.GroupName,
                                DueDate = assignment.DueDate,
                                To = role == CourseAlertConstants.RoleLeader ? $"{email} (líder: su equipo)" : email,
                            }));
                    }
                }
            }

            // Lo que ya está en la cola (de esta u otra ejecución, enviado o no) no se repite.
            var existing = await _queue.GetExistingKeysAsync(planned.Select(p => p.Item.DedupeKey!).ToList(), ct);
            var fresh = planned.Where(p => !existing.Contains(p.Item.DedupeKey!)).ToList();

            var result = new CourseAlertRunResultDto
            {
                Date = today,
                DryRun = dryRun,
                Reminders = fresh.Count(p => p.Item.AlertType == EmailAlertTypes.CourseDueReminder),
                Urgent = fresh.Count(p => p.Item.AlertType == EmailAlertTypes.CourseDueUrgent),
                Reports = fresh.Count(p => p.Item.AlertType == EmailAlertTypes.CourseResultsReport),
                Items = dryRun ? fresh.Take(CourseAlertConstants.PreviewMaxItems).Select(p => p.Preview).ToList() : [],
            };

            if (!dryRun && fresh.Count > 0)
            {
                var queued = await _queue.EnqueueAsync(fresh.Select(p => p.Item).ToList(), ct);
                _queueSignal.Notify();

                _logger.LogInformation(
                    "Alertas de cursos {Date}: {Queued} correos en cola ({Reminders} recordatorios, {Urgent} urgentes, {Reports} reportes).",
                    today, queued, result.Reminders, result.Urgent, result.Reports);
            }

            return ResponseDtoHelper.CreateSuccessResponseDto(result);
        }

        // ── Destinatarios del reporte ───────────────────────────────────

        /// <summary>
        /// Los "otros correos" reciben el grupo completo. Cada líder (según el DataLake) recibe su equipo.
        /// Gerencia y dirección: pendientes hasta que el DataLake traiga el correo del responsable.
        /// </summary>
        private async Task<List<(string Role, string Email)>> GetReportRecipientsAsync(
            CourseAlertAssignment assignment, CourseAlertRecipients to, CancellationToken ct)
        {
            var recipients = to.Emails.Select(email => (CourseAlertConstants.RoleEmail, email)).ToList();

            if (to.Leader)
            {
                var members = await GetMemberEmailsAsync(assignment.AssignmentId);
                var people = await _organization.FindByEmailsAsync(members, ct);
                if (people.Count == 0 && members.Count > 0)
                {
                    _logger.LogWarning(
                        "Reporte a líderes de la asignación {AssignmentId}: el DataLake no respondió o no encontró a nadie; no se encolan.",
                        assignment.AssignmentId);
                }

                recipients.AddRange(people.Values
                    .Select(person => person.LeaderEmail)
                    .Where(leader => !string.IsNullOrWhiteSpace(leader))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .Select(leader => (CourseAlertConstants.RoleLeader, leader!)));
            }

            if (to.Management || to.Direction)
            {
                _logger.LogWarning("Reporte a gerencia o dirección activo, pero el DataLake aún no trae el correo del responsable: no se encola.");
            }

            return recipients;
        }

        // ── Consultas (repositorio genérico con selector) ───────────────

        /// <summary>Personas sin formulario, de cursos activos, con fecha límite entre dueFrom y dueTo.</summary>
        private async Task<IReadOnlyList<CourseAlertCandidate>> GetPendingPeopleAsync(DateOnly dueFrom, DateOnly dueTo) =>
            await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<CourseAlertCandidate>>(async unitOfWork =>
                await unitOfWork.Repository<CourseAssignmentUser>().GetListAsync(
                    u => u.Completion == null
                        && !u.Assignment.Course.Removed
                        && u.Assignment.DueDate >= dueFrom
                        && u.Assignment.DueDate <= dueTo
                        && u.User.IsActive
                        && u.User.CorportativeEmail != "",
                    selector: q => q.Select(u => new CourseAlertCandidate(
                        u.Id,
                        u.AssignmentId,
                        u.Assignment.CourseId,
                        u.Assignment.Course.Name,
                        u.Assignment.UserGroup != null ? u.Assignment.UserGroup.Name : CourseAlertConstants.NoGroupName,
                        u.Assignment.DueDate,
                        u.CreatedDate,
                        u.User.CorportativeEmail)))) ?? [];

        /// <summary>Asignaciones con personas, de cursos activos, con fecha límite entre dueFrom y dueTo.</summary>
        private async Task<IReadOnlyList<CourseAlertAssignment>> GetAssignmentsDueBetweenAsync(DateOnly dueFrom, DateOnly dueTo) =>
            await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<CourseAlertAssignment>>(async unitOfWork =>
                await unitOfWork.Repository<CourseAssignment>().GetListAsync(
                    a => !a.Course.Removed && a.DueDate >= dueFrom && a.DueDate <= dueTo && a.Users.Any(),
                    selector: q => q.Select(CourseAlertProjections.Assignment))) ?? [];

        /// <summary>Correos de las personas de una asignación (para saber a qué líderes va el reporte).</summary>
        private async Task<IReadOnlyList<string>> GetMemberEmailsAsync(int assignmentId) =>
            await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<string>>(async unitOfWork =>
                await unitOfWork.Repository<CourseAssignmentUser>().GetListAsync(
                    u => u.AssignmentId == assignmentId && u.User.CorportativeEmail != "",
                    selector: q => q.Select(u => u.User.CorportativeEmail))) ?? [];

        /// <summary>El correo para la cola y su fila de la vista previa.</summary>
        private sealed record PlannedAlert(CourseEmailQueueItem Item, CourseAlertPreviewItemDto Preview);
    }
}
```

> **Rápido:**
> - No envía nada ni consulta Graph. El DataLake se lee una vez por hora (está en memoria).
> - Con miles de personas, son unas pocas consultas, una búsqueda de llaves y un `INSERT`.

### `WebApp/BackgroundServices/CourseAlertsWorker.cs`

Va junto a `CourseEmailWorker` (guía de la cola).

```csharp
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.Application.Features.Courses.Application.Constants;

namespace DOCCB.WebApp.BackgroundServices
{
    /// <summary>
    /// Alertas de cursos: cada "IntervalMinutes" (60 por defecto) entre "WindowStart" y "WindowEnd" de Colombia
    /// (7:00 a 18:00). Encolar es idempotente: repetir no duplica, y si la API se reinicia a media mañana, la
    /// primera vuelta pone al día lo de hoy. De noche no encola nada.
    /// Se desactiva con "CourseAlerts:JobEnabled": false.
    /// </summary>
    public class CourseAlertsWorker(
        IServiceScopeFactory scopeFactory,
        IConfiguration configuration,
        TimeProvider timeProvider,
        ILogger<CourseAlertsWorker> logger) : BackgroundService
    {
        private static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById(CourseConstants.BusinessTimeZoneId);

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            if (!configuration.GetValue("CourseAlerts:JobEnabled", true))
            {
                logger.LogInformation("Alertas de cursos desactivadas por configuración.");
                return;
            }

            var windowStart = ReadTime("CourseAlerts:WindowStart", new TimeSpan(7, 0, 0));
            var windowEnd = ReadTime("CourseAlerts:WindowEnd", new TimeSpan(18, 0, 0));
            var interval = TimeSpan.FromMinutes(Math.Max(15, configuration.GetValue("CourseAlerts:IntervalMinutes", 60)));

            while (!stoppingToken.IsCancellationRequested)
            {
                var now = TimeZoneInfo.ConvertTime(timeProvider.GetUtcNow(), Zone);
                TimeSpan wait;

                if (now.TimeOfDay >= windowStart && now.TimeOfDay < windowEnd)
                {
                    await RunOnceAsync(stoppingToken);
                    wait = interval;
                }
                else
                {
                    // Hasta el próximo inicio de la ventana (hoy o mañana).
                    var next = new DateTimeOffset(now.Date + windowStart, now.Offset);
                    wait = (next > now ? next : next.AddDays(1)) - now;
                }

                try
                {
                    await Task.Delay(wait, stoppingToken);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }

        private async Task RunOnceAsync(CancellationToken ct)
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var job = scope.ServiceProvider.GetRequiredService<ICourseAlertJobService>();
                await job.RunAsync(dryRun: false, CourseAlertConstants.SystemUser, ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Un fallo (por ejemplo, la base de datos caída) no tumba la aplicación: se intenta en la siguiente vuelta.
                logger.LogError(ex, "Error encolando las alertas de cursos.");
            }
        }

        private TimeSpan ReadTime(string key, TimeSpan fallback) =>
            TimeSpan.TryParse(configuration[key], out var value) ? value : fallback;
    }
}
```

---

## 11. Paso 8 — Los composers

Los registra la cola: `CourseEmailDispatcher` busca el composer por `AlertTypes` y le pide el correo justo antes de enviarlo.

### `Composers/CourseReminderEmailComposer.cs` — recordatorio normal y urgente

```csharp
using System.Globalization;
using System.Net;
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Helpers;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Configuration;

namespace DOCCB.Application.Features.CourseAlerts.Application.Composers
{
    public class CourseReminderEmailComposer(
        ICourseCompletionRepository assignments,
        ICourseAlertSettingsService settingsService,
        ICourseAlertCopyResolver copyResolver,
        IConfiguration configuration,
        TimeProvider timeProvider) : ICourseEmailComposer
    {
        private static readonly CultureInfo Spanish = new("es-ES");

        private readonly ICourseCompletionRepository _assignments = assignments;
        private readonly ICourseAlertSettingsService _settingsService = settingsService;
        private readonly ICourseAlertCopyResolver _copyResolver = copyResolver;
        private readonly IConfiguration _configuration = configuration;
        private readonly TimeProvider _timeProvider = timeProvider;

        public IReadOnlyCollection<string> AlertTypes { get; } = [EmailAlertTypes.CourseDueReminder, EmailAlertTypes.CourseDueUrgent];

        public async Task<CourseEmailComposition> ComposeAsync(CourseEmailQueueItem item, CancellationToken ct)
        {
            var person = item.AssignmentUserId is int id ? await _assignments.GetAssignmentUserAsync(id, ct) : null;
            if (person is null)
            {
                return CourseEmailComposition.Skip(CourseEmailConstants.PersonNotInCourse);
            }

            if (person.CourseRemoved)
            {
                return CourseEmailComposition.Skip(CourseEmailConstants.CourseRemoved);
            }

            // Pudo diligenciar el formulario entre que se encoló y ahora.
            if (person.IsCompleted)
            {
                return CourseEmailComposition.Skip(CourseAlertConstants.AlreadyCompleted);
            }

            if (string.IsNullOrWhiteSpace(person.Email))
            {
                return CourseEmailComposition.Skip(CourseEmailConstants.NoEmail);
            }

            var daysLeft = person.DueDate.DayNumber - BusinessDate.Today(_timeProvider).DayNumber;
            if (daysLeft < 0)
            {
                return CourseEmailComposition.Skip(CourseAlertConstants.DueDatePassed);
            }

            var urgent = item.AlertType == EmailAlertTypes.CourseDueUrgent;
            var settings = (await _settingsService.LoadAllAsync()).For(person.CourseId);
            if (!(urgent ? settings.UrgentEnabled : settings.ReminderEnabled))
            {
                return CourseEmailComposition.Skip(CourseAlertConstants.AlertDisabled);
            }

            var copies = await _copyResolver.ResolveAsync(CourseAlertSettingsRules.CopyOf(settings, item.AlertType), person.Email, ct);

            var portalUrl = _configuration["Frontend:FrontendApp"]?.TrimEnd('/') ?? string.Empty;
            var tokens = new Dictionary<string, string>
            {
                ["NOMBRE"] = WebUtility.HtmlEncode(person.DisplayName),
                ["CURSO"] = WebUtility.HtmlEncode(person.CourseName),
                ["MODALIDAD"] = person.Modality.ToString(),
                ["FECHA_LIMITE"] = person.DueDate.ToDateTime(TimeOnly.MinValue).ToString("d 'de' MMMM 'de' yyyy", Spanish),
                ["PLAZO_TEXTO"] = DaysLeftText(daysLeft),
                // Los colores que documenta la plantilla: ámbar si faltan días, rojo para la urgente.
                ["ALERTA_COLOR"] = urgent ? "#DC2626" : "#B45309",
                ["ALERTA_FONDO"] = urgent ? "#FEE2E2" : "#FFF8E1",
                ["MENSAJE"] = urgent ? CourseAlertConstants.UrgentMessage : string.Empty,
                ["CURSO_URL"] = portalUrl,
                ["CTA_URL"] = $"{portalUrl}/mis-cursos?finalizar={person.Id}",
            };

            var subject = urgent ? CourseAlertConstants.UrgentSubject : CourseAlertConstants.ReminderSubject;
            return CourseEmailComposition.Send(
                new ComposedEmail(person.Email, copies, subject, CourseAlertConstants.ReminderTemplate, tokens, person.AssignmentId));
        }

        /// <summary>Para PLAZO_TEXTO ("Faltan 3 días para completar tu curso").</summary>
        private static string DaysLeftText(int days) => days switch
        {
            0 => "Vence hoy",
            1 => "Falta 1 día",
            _ => $"Faltan {days} días",
        };
    }
}
```

### `Composers/CourseReportEmailComposer.cs` — reporte de resultados

Las cifras se leen **al enviar**. A un líder (`recipient_role = LEADER`) le llega solo su equipo dentro del grupo.

```csharp
using System.Globalization;
using System.Net;
using System.Text;
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Application.Features.CourseAlerts.Application.Helpers;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Application.Features.Courses.Application.Interfaces;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Configuration;

namespace DOCCB.Application.Features.CourseAlerts.Application.Composers
{
    public class CourseReportEmailComposer(
        ITransactionExecutorHelper transactionHelper,
        ICourseCompletionService completionService,
        IOrganizationDirectory organization,
        IUserSearchRepository users,
        IConfiguration configuration,
        TimeProvider timeProvider) : ICourseEmailComposer
    {
        private static readonly CultureInfo Spanish = new("es-ES");

        /// <summary>Estilo de las celdas, el mismo del formato que documenta TemplateCoursePendingReport.html.</summary>
        private const string CellStyle = "padding:10px 12px; border-top:1px solid #EEEEEE; font-size:13px;";

        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly ICourseCompletionService _completionService = completionService;
        private readonly IOrganizationDirectory _organization = organization;
        private readonly IUserSearchRepository _users = users;
        private readonly IConfiguration _configuration = configuration;
        private readonly TimeProvider _timeProvider = timeProvider;

        /// <summary>Una persona del grupo, lista para las tablas del correo.</summary>
        private sealed record ReportPerson(string DisplayName, string Email, string? Management, bool Completed, bool IsOverdue, DateTime? CompletedDate);

        public IReadOnlyCollection<string> AlertTypes { get; } = [EmailAlertTypes.CourseResultsReport];

        public async Task<CourseEmailComposition> ComposeAsync(CourseEmailQueueItem item, CancellationToken ct)
        {
            var assignment = item.AssignmentId is int id ? await GetAssignmentAsync(id) : null;
            if (assignment is null)
            {
                return CourseEmailComposition.Skip(CourseAlertConstants.AssignmentRemoved);
            }

            if (string.IsNullOrWhiteSpace(item.RecipientEmail))
            {
                return CourseEmailComposition.Skip(CourseEmailConstants.NoEmail);
            }

            // Calificaciones: el mismo cálculo de la página de resultados (con el anonimato).
            // Si no se pueden leer, se lanza: la cola lo reintenta más tarde.
            var progressResult = await _completionService.GetProgressAsync(assignment.CourseId, ct);
            var progress = progressResult.Status == CourseResultStatus.Ok ? progressResult.Response.Response : null;
            var group = progress?.Assignments.FirstOrDefault(a => a.AssignmentId == assignment.AssignmentId);
            var assigned = group is null ? null : await GetPeopleAsync(assignment, ct);
            if (progress is null || group is null || assigned is null)
            {
                throw new InvalidOperationException(CourseAlertConstants.ProgressUnavailable);
            }

            // Líder y gerencia de cada persona (el DataLake está en memoria: no es una llamada por persona).
            var organization = await _organization.FindByEmailsAsync(assigned.Select(p => p.Email).ToList(), ct);
            var people = assigned
                .Select(p => new ReportPerson(
                    p.DisplayName,
                    p.Email,
                    p.Management ?? organization.GetValueOrDefault(p.Email)?.ManagementName,
                    p.Status == CompletionConstants.Status.Completed,
                    p.IsOverdue,
                    p.CompletedDate))
                .ToList();

            var recipient = item.RecipientEmail;
            var forLeader = item.RecipientRole == CourseAlertConstants.RoleLeader;
            if (forLeader)
            {
                people = people
                    .Where(p => string.Equals(organization.GetValueOrDefault(p.Email)?.LeaderEmail, recipient, StringComparison.OrdinalIgnoreCase))
                    .ToList();

                if (people.Count == 0)
                {
                    return CourseEmailComposition.Skip(CourseAlertConstants.LeaderWithoutTeam);
                }
            }

            var total = people.Count;
            var completed = people.Count(p => p.Completed);
            var percent = total == 0 ? 0 : (int)Math.Round(completed * 100.0 / total);
            var name = (await _users.FindByEmailsAsync([recipient], ct)).FirstOrDefault()?.DisplayName;
            var daysLeft = assignment.DueDate.DayNumber - BusinessDate.Today(_timeProvider).DayNumber;
            var portalUrl = _configuration["Frontend:FrontendApp"]?.TrimEnd('/') ?? string.Empty;
            var groupName = forLeader ? $"{assignment.GroupName} · tu equipo" : assignment.GroupName;

            var tokens = new Dictionary<string, string>
            {
                ["NOMBRE"] = WebUtility.HtmlEncode(name ?? CourseAlertConstants.ReportFallbackName),
                ["CURSO"] = WebUtility.HtmlEncode(assignment.CourseName),
                ["MODALIDAD"] = assignment.Modality.ToString(),
                ["GRUPO"] = WebUtility.HtmlEncode(groupName),
                ["FECHA_LIMITE"] = assignment.DueDate.ToDateTime(TimeOnly.MinValue).ToString("d 'de' MMMM 'de' yyyy", Spanish),
                ["ESTADO_PLAZO"] = DueStateText(daysLeft),
                ["ESTADO_COLOR"] = daysLeft > 0 ? "#B45309" : "#DC2626",
                ["TOTAL_ASIGNADOS"] = total.ToString(Spanish),
                ["TOTAL_FINALIZADOS"] = completed.ToString(Spanish),
                ["TOTAL_PENDIENTES"] = (total - completed).ToString(Spanish),
                ["PORCENTAJE"] = percent.ToString(Spanish),
                ["FILAS_PENDIENTES"] = Rows(
                    people.Where(p => !p.Completed).ToList(),
                    p => p.IsOverdue ? ("Vencido", "#DC2626") : ("Pendiente", "#B45309")),
                ["FILAS_FINALIZADOS"] = Rows(
                    people.Where(p => p.Completed).ToList(),
                    p => (p.CompletedDate is { } date ? BusinessDate.FromUtc(date).ToString("d MMM yyyy", Spanish) : "—", "#047857")),
                // Las calificaciones son del grupo completo: por equipo romperían el anonimato.
                ["CALIFICACIONES"] = RatingsText(group.Ratings, progress.Ratings),
                ["CTA_URL"] = $"{portalUrl}/cursos/{assignment.CourseId}/resultados?grupo={assignment.AssignmentId}",
            };

            var subject = forLeader
                ? $"Avance de tu equipo en el curso {assignment.CourseName}"
                : $"Avance del curso {assignment.CourseName} · {assignment.GroupName}";

            return CourseEmailComposition.Send(
                new ComposedEmail(recipient, [], subject, CourseAlertConstants.ReportTemplate, tokens, assignment.AssignmentId));
        }

        // ── Datos ───────────────────────────────────────────────────────

        private async Task<CourseAlertAssignment?> GetAssignmentAsync(int assignmentId) =>
            (await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<CourseAlertAssignment>>(async unitOfWork =>
                await unitOfWork.Repository<CourseAssignment>().GetListAsync(
                    a => a.Id == assignmentId && !a.Course.Removed,
                    selector: q => q.Select(CourseAlertProjections.Assignment).Take(1))))
            ?.FirstOrDefault();

        /// <summary>Todas las personas de la asignación, con el servicio de la página de resultados (páginas de 100).</summary>
        private async Task<List<AssignedUserProgressDto>?> GetPeopleAsync(CourseAlertAssignment assignment, CancellationToken ct)
        {
            var people = new List<AssignedUserProgressDto>();

            for (var page = 1; ; page++)
            {
                var response = await _completionService.GetAssignmentUsersAsync(
                    assignment.CourseId,
                    assignment.AssignmentId,
                    new AssignedUsersQueryDto { Page = page, PageSize = CourseAlertConstants.PeoplePageSize },
                    ct);

                if (response.Status != CourseResultStatus.Ok || response.Response.Response is not { } current)
                {
                    return null;
                }

                people.AddRange(current.Items);
                if (current.Items.Count < CourseAlertConstants.PeoplePageSize || people.Count >= current.TotalCount)
                {
                    return people;
                }
            }
        }

        // ── Textos ──────────────────────────────────────────────────────

        /// <summary>Las filas con el formato que documenta la plantilla. Lista vacía: una fila "Nadie en esta lista.".</summary>
        private static string Rows(IReadOnlyList<ReportPerson> people, Func<ReportPerson, (string Text, string Color)> third)
        {
            if (people.Count == 0)
            {
                return $"<tr><td colspan=\"3\" style=\"{CellStyle} color:#666666;\">Nadie en esta lista.</td></tr>";
            }

            var rows = new StringBuilder();
            foreach (var person in people)
            {
                var (text, color) = third(person);
                rows.Append("<tr>")
                    .Append($"<td style=\"{CellStyle} color:#111111;\"><strong>{Html(person.DisplayName)}</strong><br><span style=\"color:#666666;\">{Html(person.Email)}</span></td>")
                    .Append($"<td style=\"{CellStyle} color:#333333;\">{Html(person.Management ?? "—")}</td>")
                    .Append($"<td style=\"{CellStyle} font-weight:bold; color:{color};\">{Html(text)}</td>")
                    .Append("</tr>");
            }

            return rows.ToString();
        }

        /// <summary>Para ESTADO_PLAZO.</summary>
        private static string DueStateText(int daysLeft) => daysLeft switch
        {
            > 1 => $"Vence en {daysLeft} días",
            1 => "Vence mañana",
            0 => "Vence hoy",
            -1 => "Venció ayer",
            _ => $"Venció hace {-daysLeft} días",
        };

        /// <summary>Respeta el anonimato: sin respuestas suficientes no hay promedios.</summary>
        private static string RatingsText(RatingSummaryDto? groupRatings, RatingSummaryDto courseRatings)
        {
            var ratings = groupRatings ?? courseRatings;
            var scope = groupRatings is null ? "del curso (todos los grupos)" : "del grupo";

            return ratings.Visible
                ? $"{scope}: calidad {Average(ratings.SatisfactionAverage)} / 5 · utilidad {Average(ratings.UsefulnessAverage)} / 5 · " +
                  $"conocimiento {Average(ratings.KnowledgeBeforeAverage)} → {Average(ratings.KnowledgeAfterAverage)} / 10 ({ratings.Responses} respuestas)."
                : $"aún no hay respuestas suficientes para mostrarlas sin romper el anonimato ({ratings.Responses} de {ratings.MinimumResponses}).";
        }

        private static string Average(double? value) => value?.ToString("0.0", Spanish) ?? "—";

        /// <summary>La plantilla reemplaza texto tal cual: sin esto, un "&" o "<" en un nombre rompe el HTML.</summary>
        private static string Html(string? value) => WebUtility.HtmlEncode(value ?? string.Empty);
    }
}
```

> **La gerencia en las listas:** la de quien ya finalizó sale del formulario (`ManagementName`). La de quien está pendiente sale del DataLake. Si tampoco está ahí, aparece "—".
>
> **Las calificaciones** usan los campos del formulario de 5 preguntas ([cursos-formulario-finalizacion-api.md](cursos-formulario-finalizacion-api.md)). Si esa guía aún no está aplicada, quita del texto la parte de "conocimiento".

### `Composers/CourseAssignedEmailComposer.cs` ✏️ — la bienvenida respeta la configuración

**1. Dependencias nuevas:**

```csharp
public class CourseAssignedEmailComposer(
    ICourseCompletionRepository assignments,
    ICourseAlertSettingsService alertSettings,
    ICourseAlertCopyResolver copyResolver,
    IConfiguration configuration) : ICourseEmailComposer
{
    // … lo de hoy …
    private readonly ICourseAlertSettingsService _alertSettings = alertSettings;
    private readonly ICourseAlertCopyResolver _copyResolver = copyResolver;
```

```csharp
using DOCCB.Application.Features.CourseAlerts.Application.Constants;
using DOCCB.Application.Features.CourseAlerts.Application.Helpers;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
```

**2. En `ComposeAsync`**, después de la validación del correo:

```csharp
// La propia del curso si existe; si no, la general.
var settings = (await _alertSettings.LoadAllAsync()).For(person.CourseId);
if (!settings.WelcomeEnabled)
{
    return CourseEmailComposition.Skip(CourseAlertConstants.WelcomeDisabled);
}

var copies = await _copyResolver.ResolveAsync(
    CourseAlertSettingsRules.CopyOf(settings, EmailAlertTypes.CourseAssigned), person.Email, ct);
```

**3. Al final**, pasa `copies` en lugar de la lista vacía:

```csharp
return CourseEmailComposition.Send(new ComposedEmail(person.Email, copies, Subject, TemplateFileName, tokens, person.AssignmentId));
```

---

## 12. Paso 9 — Controlador, registro y configuración

### `Common/ResponseConstants/ApiResponseConstants.cs` ✏️

```csharp
public const string GetCourseAlertsErrorMessage = "No se pudo cargar la configuración de alertas.";
public const string SaveCourseAlertsErrorMessage = "No se pudo guardar la configuración de alertas.";
public const string RunCourseAlertsErrorMessage = "No se pudieron procesar las alertas de cursos.";
```

### `Controllers/CourseAlertsController.cs`

```csharp
using DOCCB.Application.Features.CourseAlerts.Application.Dtos;
using DOCCB.Application.Features.CourseAlerts.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Configuración de alertas de cursos (administración).</summary>
    [ApiController]
    [Route("api/course-alerts")]
    [Authorize]
    public class CourseAlertsController(
        ICourseAlertSettingsService settingsService,
        ICourseAlertJobService jobService) : ControllerBase
    {
        private readonly ICourseAlertSettingsService _settingsService = settingsService;
        private readonly ICourseAlertJobService _jobService = jobService;

        [HttpGet("general")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetGeneral()
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _settingsService.GetGeneralAsync());
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GetCourseAlertsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GetCourseAlertsErrorMessage });
            }
        }

        [HttpPut("general")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> SaveGeneral([FromBody] CourseAlertSettingsDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _settingsService.SaveGeneralAsync(dto, authenticatedUserInfo.Email));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.SaveCourseAlertsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.SaveCourseAlertsErrorMessage });
            }
        }

        [HttpGet("courses/{courseId:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetForCourse(int courseId)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _settingsService.GetForCourseAsync(courseId));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GetCourseAlertsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GetCourseAlertsErrorMessage });
            }
        }

        [HttpPut("courses/{courseId:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> SaveForCourse(int courseId, [FromBody] CourseAlertSettingsDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _settingsService.SaveForCourseAsync(courseId, dto, authenticatedUserInfo.Email));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.SaveCourseAlertsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.SaveCourseAlertsErrorMessage });
            }
        }

        /// <summary>Quita la configuración propia: el curso vuelve a la general.</summary>
        [HttpDelete("courses/{courseId:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> ResetCourse(int courseId)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _settingsService.ResetCourseAsync(courseId));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.SaveCourseAlertsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.SaveCourseAlertsErrorMessage });
            }
        }

        /// <summary>Qué se encolaría ahora, sin encolar nada.</summary>
        [HttpGet("preview")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Preview(CancellationToken ct)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _jobService.RunAsync(dryRun: true, authenticatedUserInfo.Email, ct));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.RunCourseAlertsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.RunCourseAlertsErrorMessage });
            }
        }

        /// <summary>Encola ya lo que toca hoy. El envío sigue en segundo plano; lo que ya está en cola no se repite.</summary>
        [HttpPost("run")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Run(CancellationToken ct)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _jobService.RunAsync(dryRun: false, authenticatedUserInfo.Email, ct));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.RunCourseAlertsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.RunCourseAlertsErrorMessage });
            }
        }
    }
}
```

> Solo `[Authorize]`, como `CoursesController`: el acceso a la administración de cursos lo controla el frontend.

### Registro

`ApplicationServiceRegistration.cs`, junto a los de la cola:

```csharp
services.AddMemoryCache(); // si ya está registrado, no pasa nada
services.AddScoped<IOrganizationDirectory, DataLakeOrganizationDirectory>();
services.AddScoped<ICourseAlertSettingsService, CourseAlertSettingsService>();
services.AddScoped<ICourseAlertCopyResolver, CourseAlertCopyResolver>();
services.AddScoped<ICourseAlertJobService, CourseAlertJobService>();
// Más composers para el mismo IEnumerable<ICourseEmailComposer> del dispatcher.
services.AddScoped<ICourseEmailComposer, CourseReminderEmailComposer>();
services.AddScoped<ICourseEmailComposer, CourseReportEmailComposer>();
```

> **Antes de integrar el DataLake en la rama de cursos:** registra en su lugar una versión vacía. El líder sale de Graph, el reporte a líderes no se encola y la gerencia sigue "No disponible":
>
> ```csharp
> /// <summary>Temporal: mientras la integración del DataLake no esté en esta rama.</summary>
> public class UnavailableOrganizationDirectory : IOrganizationDirectory
> {
>     public Task<IReadOnlyDictionary<string, OrganizationPerson>> FindByEmailsAsync(IReadOnlyCollection<string> emails, CancellationToken ct) =>
>         Task.FromResult<IReadOnlyDictionary<string, OrganizationPerson>>(new Dictionary<string, OrganizationPerson>());
> }
> ```
>
> ```csharp
> services.AddScoped<IOrganizationDirectory, UnavailableOrganizationDirectory>();
> ```
>
> Al integrar el DataLake, se cambia esa línea por la de `DataLakeOrganizationDirectory` y se borra la clase temporal.

`Program.cs`, junto a `CourseEmailWorker`:

```csharp
builder.Services.AddHostedService<CourseAlertsWorker>();
```

### `appsettings.json` ✏️

```json
"CourseAlerts": {
  "JobEnabled": true,
  "WindowStart": "07:00",
  "WindowEnd": "18:00",
  "IntervalMinutes": 60
}
```

> **El DataLake** usa su propia sección `DataLakeApi` (con `Enabled`), que ya trae la integración. Sus secretos van en User Secrets o en la configuración del servidor, no en `appsettings.json`.
>
> **En desarrollo:** `"JobEnabled": false` en `appsettings.Development.json`, para que tu máquina no encole sola. Usa la vista previa y "Ejecutar ahora".
>
> **Varias instancias:** las llaves impiden duplicados aunque dos instancias encolen a la vez, así que `JobEnabled` puede quedar activo en todas.

---

## 13. Contrato

Base `/api/course-alerts`. Respuestas `{ response, hasError, errors }`. Errores de validación: HTTP 200 + `hasError`.

| Método | Ruta | Respuesta |
|---|---|---|
| `GET` | `/general` | `CourseAlertSettingsDto` |
| `PUT` | `/general` | La guardada |
| `GET` | `/courses/{courseId}` | `{ courseId, courseName, usesGeneral, settings }`. Si `usesGeneral`, `settings` es la general. |
| `PUT` | `/courses/{courseId}` | La propia del curso (`usesGeneral: false`) |
| `DELETE` | `/courses/{courseId}` | Vuelve a la general (`usesGeneral: true`) |
| `GET` | `/preview` | `{ date, dryRun: true, reminders, urgent, reports, items[] }`: lo que se encolaría ahora |
| `POST` | `/run` | Lo mismo, encolando (`items` vacío). El avance se ve en `/api/course-emails`. |

```json
{
  "welcome":  { "enabled": true,
                "copy": { "leader": false, "management": false, "direction": false, "emails": [] } },
  "reminder": { "enabled": true, "daysBefore": 7,
                "copy": { "leader": false, "management": false, "direction": false, "emails": ["formacion@empresa.co"] } },
  "urgent":   { "enabled": true, "daysBefore": 2,
                "copy": { "leader": true, "management": false, "direction": false, "emails": [] } },
  "report":   { "enabled": true, "dayOffsets": [-3, 0, 3],
                "to": { "leader": true, "management": false, "direction": false, "emails": ["gestion.humana@empresa.co"] } }
}
```

`reports` cuenta correos: un reporte a 3 líderes y 1 correo suma 4.

**Buscar personas para las copias:** el frontend usa `GET /api/users/search?q=…&top=10`, que ya existe.

---

## 14. Pruebas

**Configuración**
- **`GET /general` recién instalado:** 7 y 2 días, la urgente con copia al líder y sin reporte.
- **Números libres:**
  - Recordatorio en 45 y urgente en 10 se guardan.
  - Urgente en 400 → "Los días de anticipación deben estar entre 0 y 365.".
  - Un momento de reporte en `-120` se guarda.
  - 21 momentos → el mensaje del máximo de 20.
- **Errores que no se guardan** (`hasError`):
  - Urgente 7 y normal 3 → "La alerta urgente debe enviarse más cerca…".
  - Reporte activo sin momentos, o sin líder, gerencia, dirección ni correos.
  - Un correo inválido → "Estos correos no son válidos: …".
- **Configuración propia de un curso:**
  - `PUT /courses/12` la crea. `GET /courses/12` responde `usesGeneral: false`.
  - `DELETE` vuelve a la general.

**Copias por alerta**
- **Recordatorio con un correo fijo y urgente con líder:** el recordatorio lleva solo ese correo en CC y la urgente solo el líder.
- **Líder:**
  - Con el DataLake activo, el líder sale de él.
  - Con `DataLakeApi:Enabled: false`, sale de Graph.
  - Sin ninguno de los dos, el correo sale igual, sin la copia.
- **Gerencia o dirección marcadas:** el correo sale sin esa copia y el log dice que falta el correo del responsable.

**El DataLake**
- **La primera consulta lo carga** (log: "Maestro de empleados del DataLake en memoria: N personas."). Las siguientes, durante una hora, no lo llaman.
- **Si el DataLake no responde:**
  - Un aviso en el log.
  - No vuelve a intentar durante 5 minutos.
  - Las alertas salen igual (con el líder de Graph).
- **Formulario de finalización:** la gerencia ya no sale "No disponible" para quien está en el maestro.

**Encolar** (con `JobEnabled: false`, usando la vista previa y "Ejecutar ahora")
- **Fechas límite de prueba:** una asignación a 7 días, otra a 2 y otra a 0.
  - `GET /preview` muestra el normal, el urgente y el urgente, cada uno con sus copias ("Líder", correos).
  - `POST /run` responde enseguida con los conteos.
  - Otro `POST /run` encola **0**.
- **Formulario diligenciado después de encolar y antes de enviar:** el correo queda `SKIPPED`.
- **Asignada dentro de la ventana:** si a la persona la asignaron hace 2 días y vence en 5 (normal = 7), no recibe el normal. Sí recibe el urgente al llegar a 2.
- **Cambio de fecha límite:** la persona vuelve a recibir sus alertas con la fecha nueva.
- **Reporte:**
  - Con "Líderes" y un correo, una asignación de 30 personas de 3 líderes que vence hoy: se encolan 4.
  - Cada líder recibe "Avance de tu equipo…" con **solo sus personas** y los totales de su equipo. El correo fijo recibe el grupo completo.
  - Las calificaciones son siempre las del grupo y solo si hay respuestas suficientes.
  - **Un correo que es líder y también está en "otros correos":** recibe los dos (el de su equipo y el completo).
  - **Servidor apagado:** si un momento cayó ayer, se encola hoy (margen de 2 días).
- **El proceso programado:**
  - Con `JobEnabled: true`, encola a las 7:00 y vuelve cada hora (en la segunda vuelta, 0 nuevos).
  - A las 22:00 no encola nada.
- **Bienvenida:**
  - Con `welcome.enabled: false` en un curso, al asignarle un grupo los correos quedan `SKIPPED`.
  - Con `welcome.copy.leader: true`, sale con el líder en CC.

---

## ✅ Checklist

- [ ] Guía de la cola implementada (`course_email_queue` con `recipient_role`, `CourseEmailWorker`, `cc`).
- [ ] `CourseAlerts.sql` (la tabla con copias por alerta y la general por defecto).
- [ ] `CourseAlertSettings`, su configuración y el `DbSet`.
- [ ] `EmailAlertTypes`: `CourseDueUrgent` y `CourseResultsReport`, también en `All`.
- [ ] `BusinessDate.FromUtc`.
- [ ] Constantes, DTOs, candidatos, proyecciones, reglas y calendario:
  - `CourseAlertConstants` y los DTOs anidados.
  - `CourseAlertCandidates` y `CourseAlertProjections`.
  - `CourseAlertSettingsRules` con `CourseAlertRecipients`.
  - `CourseAlertSchedule`.
- [ ] `CourseAlertSettingsService`.
- [ ] El DataLake:
  - `IOrganizationDirectory` + `DataLakeOrganizationDirectory` (o la versión vacía mientras se integra).
  - `ManagementDirectory`.
- [ ] `GetManagerAsync` en `IGraphDirectoryService` / `GraphDirectoryService`.
- [ ] `CourseAlertCopyResolver`.
- [ ] Los cuatro ajustes de `TemplateCoursePendingReport.html`.
- [ ] Cola:
  - `ForPersonId` y `ForRecipient` en `CourseEmailQueueFactory`.
  - `GetExistingKeysAsync` y `EnqueueAsync` en el repositorio.
- [ ] `CourseAlertJobService` y `CourseAlertsWorker`.
- [ ] Composers:
  - El recordatorio.
  - El reporte, con el equipo de cada líder.
  - La bienvenida con sus copias.
- [ ] `ApiResponseConstants`, `CourseAlertsController`, registros (`AddMemoryCache`), `appsettings` y `AddHostedService`.
