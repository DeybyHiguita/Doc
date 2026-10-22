# 📬 Cursos — Envío de correos en segundo plano — API (.NET 8) y SQL Server

**El problema hoy:** al asignar un grupo a un curso, `CourseService` espera a que salga **cada** correo de bienvenida antes de responder.

- **Cada correo es lento:** `MailNotificationService` pide un token nuevo a Entra ID y crea un cliente de Graph nuevo en cada envío.
- **Exchange Online acepta 30 mensajes por minuto por buzón:** un grupo de 300 personas tarda al menos 10 minutos. La petición se vence mucho antes.
- **Si algo falla a mitad, nadie se entera:** parte del grupo queda sin correo y no hay forma de saber quiénes ni de reintentar.

**Lo que se construye:** una **cola de correos** en SQL Server y un **proceso en segundo plano** que la atiende.

1. Al guardar, la asignación y sus correos quedan en la base **en la misma transacción**. La respuesta llega en milisegundos.
2. El proceso envía los correos a un ritmo que Exchange acepta, reintenta los que fallan y deja cada resultado en `email_alert_log`.
3. La pantalla consulta el estado ("120 enviados, 180 en cola, 2 con error") mientras el envío sigue.

Esta guía mueve a la cola el correo de bienvenida. Las alertas programadas ([cursos-alertas-api.md](cursos-alertas-api.md)) usan la misma cola. **El frontend** está en [cursos-cola-correos-angular.md](cursos-cola-correos-angular.md).

**Base:** el código de la rama de cursos (`.claude/Cursos API`). Convenciones: [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md).

---

## 1. Estrategias evaluadas

| Opción | Qué pasa | ¿Sirve? |
|---|---|---|
| **Seguir enviando dentro de la petición** | La pantalla espera minutos. La petición se vence y el envío queda a medias. | ❌ |
| **`Task.Run` sin esperar** | Responde rápido, pero el `DbContext` de la petición ya se cerró, un reinicio pierde lo pendiente y no hay estado que consultar. | ❌ |
| **Cola en memoria (`Channel`) + `BackgroundService`** | Rápida y sin tablas, pero se pierde al reiniciar o al reciclar el app pool, y el estado solo vive en ese servidor. | ❌ |
| **Tabla de cola en SQL Server + `BackgroundService`** | Durable: lo encolado sobrevive a reinicios. El estado se consulta con SQL. Permite reintentos y varias instancias sin enviar dos veces. No agrega infraestructura. | ✅ **Elegida** |
| **Hangfire** | Buena librería (reintentos y panel propio), pero agrega una dependencia y sus propias tablas. El estado por curso y grupo igual hay que construirlo. | Posible, no necesaria |
| **Azure Service Bus / Azure Functions** | Escala mucho, pero es infraestructura y costo nuevos. El cuello de botella es el límite de Exchange, no la cola. | Solo si el volumen crece mucho |

**Por qué la tabla:** es el patrón *outbox*. La asignación y sus correos se guardan en el **mismo `SaveChanges`**, así que no puede quedar una asignación sin sus correos ni correos de una asignación que no se guardó.

---

## 2. Cómo funciona

```text
PETICIÓN "Guardar curso"                          PROCESO EN SEGUNDO PLANO (CourseEmailWorker)
──────────────────────────                        ──────────────────────────────────────────────
CourseService                                     ┌─► toma el siguiente PENDING (reclamo atómico)
  curso + asignación + personas                   │   lo arma con datos de ese momento (composer por tipo)
  + 1 fila PENDING por persona    ─ un solo ─►    │   lo envía por Graph (máximo 25 por minuto)
    en course_email_queue         SaveChanges     │   SENT · reintento · FAILED  (+ email_alert_log)
  avisa al proceso (señal)  ────────────────────► └── sin pendientes: espera un aviso o 30 s
responde de inmediato: { queuedEmails: 300 }

PANTALLA: GET /api/course-emails/courses/{id} cada 5 s mientras haya correos en cola
```

**Estados de cada correo:**

```text
PENDING ──(el proceso lo toma)──► SENDING ──► SENT
   ▲                                  │
   └──── reintento (1, 5, 15 y 60 min) ┤
                                      ├──► FAILED (5 intentos) ──"Reintentar"──► PENDING
                                      └──► SKIPPED (ya no aplica: el curso se eliminó, la persona no tiene correo…)
```

| Regla | Detalle |
|---|---|
| **Se arma al enviar, no al encolar.** | El "composer" lee los datos de ese momento. Si la persona salió del grupo antes de que saliera su correo, su fila se borró con ella (cascada) y no se envía. |
| **Ritmo.** | 25 por minuto por defecto (Exchange acepta 30). Uno a la vez: Graph admite 4 peticiones simultáneas por buzón. |
| **Reintentos.** | 5 intentos: a los 1, 5, 15 y 60 minutos. Además, el cliente de Graph reintenta solo los 429 respetando `Retry-After`. |
| **Si el servidor se cae enviando.** | El correo queda en `SENDING` y vuelve a la cola a los 5 minutos. En el peor caso esa persona recibe el correo dos veces; nunca se queda sin él. |
| **Varias instancias.** | El reclamo es un `UPDATE` condicionado: solo una instancia gana cada correo. |
| **"Registro de correos".** | Una fila por correo con el resultado final (`SENT`, o `FAILED` al agotar los intentos), no una por intento. |
| **Limpieza.** | Las filas procesadas se borran a los 60 días. El historial queda en `email_alert_log`. |

---

## 3. Los límites de Microsoft que definen el diseño

| Límite | Valor | Dónde |
|---|---|---|
| Mensajes por minuto por buzón | **30**. El exceso se encola y se demora; Exchange "no está pensado para envíos masivos". | [Exchange Online limits](https://learn.microsoft.com/en-us/office365/servicedescriptions/exchange-online-service-description/exchange-online-limits) |
| Destinatarios por día por buzón | **10.000** (ventana de 24 horas; cuentan los CC). Es un límite fijo. | Misma página |
| Peticiones simultáneas a un buzón (app + buzón) | **4** | [Graph throttling limits](https://learn.microsoft.com/en-us/graph/throttling-limits) — Outlook service limits |
| Peticiones a un buzón | **10.000 en 10 minutos** | Misma página |
| Carga a un buzón | **150 MB en 5 minutos** (el banner va en cada correo) | Misma página |

**En la práctica:**
- 300 personas ≈ **12 minutos** a 25 por minuto.
- El techo real es **10.000 destinatarios al día** desde el buzón remitente, contando certificados, solicitudes y copias. Lo que pase de ahí falla y queda para "Reintentar" al día siguiente.

---

## 4. Archivos

```text
DOCCB.Domain/Entities/
└── CourseEmailQueueItem.cs                                       nuevo

DOCCB.Application/
├── Contracts/Persistence/ICourseEmailQueueRepository.cs          nuevo
├── Contracts/Persistence/ICourseRepository.cs                    ✏️ + QueueEmails
├── Features/CourseEmails/Application/
│   ├── Constants/CourseEmailQueueStatus.cs
│   ├── Constants/CourseEmailConstants.cs
│   ├── Dtos/CourseEmailDtos.cs
│   ├── Helpers/CourseEmailQueueFactory.cs
│   ├── Interfaces/ICourseEmailComposer.cs                        cómo se arma cada tipo de correo
│   ├── Interfaces/ICourseEmailQueueSignal.cs
│   ├── Interfaces/ICourseEmailDispatcher.cs
│   ├── Interfaces/ICourseEmailStatusService.cs
│   ├── Composers/CourseAssignedEmailComposer.cs                  la bienvenida (lo que hacía CourseNotificationService)
│   ├── Services/CourseEmailQueueSignal.cs
│   ├── Services/CourseEmailDispatcher.cs                         ⭐ procesa un correo de la cola
│   └── Services/CourseEmailStatusService.cs
├── Features/Courses/Application/
│   ├── DTOs/SaveCourseRequestDto.cs                              ✏️ + QueuedEmails en los resultados
│   ├── Services/CourseService.cs                                 ✏️ encola en vez de enviar
│   ├── Services/CourseNotificationService.cs                     🗑️ se borra
│   ├── Interfaces/ICourseNotificationService.cs                  🗑️ se borra
│   └── DTOs/CourseAssignedNotification.cs                        🗑️ se borra
├── Features/MailNotification/Application/Interfaces/IMailNotificationService.cs  ✏️ + cc
├── Features/MailNotification/Application/Services/MailNotificationService.cs     ✏️ GraphServiceClient compartido + cc
└── ApplicationServiceRegistration.cs                             ✏️

DOCCB.Infraestructure/
├── Configurations/CourseEmailQueueItemConfiguration.cs           nuevo
├── Repositories/CourseEmailQueueRepository.cs                    nuevo
├── Repositories/CourseRepository.cs                              ✏️ QueueEmails
├── Persistence/Models/DOCCbDbContext.cs                          ✏️ DbSet
├── Persistence/Scripts SQL/CourseEmailQueue.sql                  nuevo
└── InfrastructureServiceRegistration.cs                          ✏️

WebApp/
├── BackgroundServices/CourseEmailWorker.cs                       nuevo (carpeta nueva: es el primer BackgroundService)
├── Controllers/CourseEmailsController.cs                         nuevo
├── Common/ResponseConstants/ApiResponseConstants.cs              ✏️
├── appsettings.json                                              ✏️ CourseEmails
└── Program.cs                                                    ✏️ AddHostedService
```

---

## 5. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/CourseEmailQueue.sql`

```sql
/* =====================================================================
   Cursos · cola de correos (se envían en segundo plano)
   Base de datos: DB · Esquema: dbo

   REQUIERE:
   - dbo.course_assignment_user

   CREA:
   - dbo.course_email_queue

   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.course_email_queue', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.course_email_queue
    (
        id                  BIGINT         IDENTITY(1, 1) NOT NULL,
        alert_type          VARCHAR(100)   NOT NULL,   -- EmailAlertTypes: COURSE_ASSIGNED, COURSE_DUE_REMINDER…
        assignment_user_id  INT            NULL,       -- correos a una persona (bienvenida, recordatorios)
        assignment_id       INT            NULL,       -- correos de una asignación sin persona (reporte). Sin llave foránea, a propósito.
        recipient_email     NVARCHAR(320)  NULL,       -- destinatario fijo (reporte)
        recipient_role      VARCHAR(20)    NULL,       -- por qué lo recibe (reporte): LEADER = solo su equipo, EMAIL = el grupo completo
        dedupe_key          NVARCHAR(450)  NULL,       -- evita encolar dos veces lo mismo (alertas programadas)

        status              VARCHAR(20)    NOT NULL CONSTRAINT df_ceq_status DEFAULT ('PENDING'),
        attempts            INT            NOT NULL CONSTRAINT df_ceq_attempts DEFAULT (0),
        next_attempt_date   DATETIME2(0)   NOT NULL CONSTRAINT df_ceq_next_attempt DEFAULT (SYSUTCDATETIME()),
        locked_until        DATETIME2(0)   NULL,       -- mientras se envía (SENDING)
        last_error          NVARCHAR(2000) NULL,

        created_date        DATETIME2(0)   NOT NULL CONSTRAINT df_ceq_created_date DEFAULT (SYSUTCDATETIME()),
        created_by          NVARCHAR(150)  NOT NULL,
        processed_date      DATETIME2(0)   NULL,       -- cuándo quedó SENT, FAILED o SKIPPED

        CONSTRAINT pk_course_email_queue PRIMARY KEY CLUSTERED (id),
        -- Si la persona sale de la asignación, su correo pendiente se va con ella.
        CONSTRAINT fk_ceq_assignment_user FOREIGN KEY (assignment_user_id)
            REFERENCES dbo.course_assignment_user (id) ON DELETE CASCADE,
        CONSTRAINT ck_ceq_status CHECK (status IN ('PENDING', 'SENDING', 'SENT', 'FAILED', 'SKIPPED')),
        CONSTRAINT ck_ceq_target CHECK (assignment_user_id IS NOT NULL OR assignment_id IS NOT NULL)
    );

    -- El proceso busca el siguiente por estado y fecha.
    CREATE INDEX ix_ceq_status_next ON dbo.course_email_queue (status, next_attempt_date) INCLUDE (locked_until);
    CREATE INDEX ix_ceq_assignment_user ON dbo.course_email_queue (assignment_user_id);
    CREATE INDEX ix_ceq_assignment ON dbo.course_email_queue (assignment_id) WHERE assignment_id IS NOT NULL;
    -- La bienvenida no lleva llave (se encola una sola vez, al crear la persona en la asignación).
    CREATE UNIQUE INDEX ux_ceq_dedupe_key ON dbo.course_email_queue (dedupe_key) WHERE dedupe_key IS NOT NULL;
END;
GO
```

> **`assignment_id` sin llave foránea:** con llaves a `course_assignment` y a `course_assignment_user`, los dos `ON DELETE CASCADE` darían "multiple cascade paths" en SQL Server. Un reporte de una asignación borrada queda `SKIPPED`.

---

## 6. Paso 2 — Dominio y EF Core

### `DOCCB.Domain/Entities/CourseEmailQueueItem.cs`

```csharp
namespace DOCCB.Domain.Entities
{
    /// <summary>Un correo de cursos por enviar (o ya procesado). Lo atiende CourseEmailWorker.</summary>
    public class CourseEmailQueueItem
    {
        public long Id { get; set; }
        public string AlertType { get; set; } = string.Empty;
        public int? AssignmentUserId { get; set; }
        public int? AssignmentId { get; set; }
        public string? RecipientEmail { get; set; }
        /// <summary>Por qué lo recibe (reporte): LEADER = solo su equipo, EMAIL = el grupo completo.</summary>
        public string? RecipientRole { get; set; }
        public string? DedupeKey { get; set; }

        public string Status { get; set; } = string.Empty;
        public int Attempts { get; set; }
        public DateTime NextAttemptDate { get; set; }
        public DateTime? LockedUntil { get; set; }
        public string? LastError { get; set; }

        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;
        public DateTime? ProcessedDate { get; set; }

        /// <summary>Con la navegación, la fila se puede encolar antes de que la persona tenga Id (mismo SaveChanges).</summary>
        public CourseAssignmentUser? AssignmentUser { get; set; }
    }
}
```

### `Configurations/CourseEmailQueueItemConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class CourseEmailQueueItemConfiguration : IEntityTypeConfiguration<CourseEmailQueueItem>
    {
        public void Configure(EntityTypeBuilder<CourseEmailQueueItem> builder)
        {
            builder.ToTable("course_email_queue", "dbo");
            builder.HasKey(i => i.Id).HasName("pk_course_email_queue");

            builder.Property(i => i.Id).HasColumnName("id");
            builder.Property(i => i.AlertType).HasColumnName("alert_type").HasMaxLength(100).IsUnicode(false).IsRequired();
            builder.Property(i => i.AssignmentUserId).HasColumnName("assignment_user_id");
            builder.Property(i => i.AssignmentId).HasColumnName("assignment_id");
            builder.Property(i => i.RecipientEmail).HasColumnName("recipient_email").HasMaxLength(320);
            builder.Property(i => i.RecipientRole).HasColumnName("recipient_role").HasMaxLength(20).IsUnicode(false);
            builder.Property(i => i.DedupeKey).HasColumnName("dedupe_key").HasMaxLength(450);

            builder.Property(i => i.Status).HasColumnName("status").HasMaxLength(20).IsUnicode(false).IsRequired();
            builder.Property(i => i.Attempts).HasColumnName("attempts");
            builder.Property(i => i.NextAttemptDate).HasColumnName("next_attempt_date").HasColumnType("datetime2(0)");
            builder.Property(i => i.LockedUntil).HasColumnName("locked_until").HasColumnType("datetime2(0)");
            builder.Property(i => i.LastError).HasColumnName("last_error").HasMaxLength(2000);

            builder.Property(i => i.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(i => i.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
            builder.Property(i => i.ProcessedDate).HasColumnName("processed_date").HasColumnType("datetime2(0)");

            builder.HasIndex(i => i.DedupeKey)
                .IsUnique()
                .HasFilter("[dedupe_key] IS NOT NULL")
                .HasDatabaseName("ux_ceq_dedupe_key");

            builder.HasOne(i => i.AssignmentUser)
                .WithMany()
                .HasForeignKey(i => i.AssignmentUserId)
                .HasConstraintName("fk_ceq_assignment_user")
                .OnDelete(DeleteBehavior.Cascade);
        }
    }
}
```

### `DOCCbDbContext.cs` ✏️

```csharp
public DbSet<CourseEmailQueueItem> CourseEmailQueue { get; set; }
```

---

## 7. Paso 3 — Constantes, DTOs y contratos

### `Constants/CourseEmailQueueStatus.cs`

```csharp
namespace DOCCB.Application.Features.CourseEmails.Application.Constants
{
    public static class CourseEmailQueueStatus
    {
        public const string Pending = "PENDING";
        public const string Sending = "SENDING";
        public const string Sent = "SENT";
        public const string Failed = "FAILED";
        public const string Skipped = "SKIPPED";
    }
}
```

### `Constants/CourseEmailConstants.cs`

```csharp
namespace DOCCB.Application.Features.CourseEmails.Application.Constants
{
    public static class CourseEmailConstants
    {
        /// <summary>Intentos antes de dejar el correo en FAILED.</summary>
        public const int MaxAttempts = 5;
        /// <summary>Espera antes de cada reintento, en minutos.</summary>
        public static readonly int[] RetryDelayMinutes = [1, 5, 15, 60];
        /// <summary>Si el proceso se cae enviando, el correo vuelve a la cola después de este tiempo.</summary>
        public const int LockMinutes = 5;
        public const int MaxErrorLength = 2000;
        public const int FailedItemsLimit = 50;
        public const string NoGroupName = "Grupo sin nombre";

        // Valores por defecto de la sección "CourseEmails" de appsettings.
        /// <summary>Exchange Online acepta 30 mensajes por minuto por buzón: se deja margen.</summary>
        public const int DefaultMaxPerMinute = 25;
        public const int DefaultPollSeconds = 30;
        public const int DefaultRetentionDays = 60;

        public const string NoComposer = "No hay cómo armar este tipo de correo.";
        public const string ComposeFailed = "No se pudo preparar el correo.";
        public const string SendFailed = "No se pudo enviar el correo.";
        public const string PersonNotInCourse = "La persona ya no está en el curso.";
        public const string CourseRemoved = "El curso fue eliminado.";
        public const string NoEmail = "La persona no tiene correo corporativo.";
    }
}
```

### `Dtos/CourseEmailDtos.cs`

```csharp
namespace DOCCB.Application.Features.CourseEmails.Application.Dtos
{
    /// <summary>Estado de los correos de un curso. Pending incluye los que se están enviando.</summary>
    public class CourseEmailStatusDto
    {
        public int CourseId { get; set; }
        public int Pending { get; set; }
        public int Sent { get; set; }
        public int Failed { get; set; }
        public int Skipped { get; set; }
        /// <summary>Minutos aproximados para vaciar la cola completa (todos los cursos), al ritmo configurado.</summary>
        public int EstimatedMinutes { get; set; }
        public List<CourseEmailAssignmentStatusDto> Assignments { get; set; } = [];
        /// <summary>Los últimos que fallaron (máximo 50).</summary>
        public List<CourseEmailFailedItemDto> FailedItems { get; set; } = [];
    }

    public class CourseEmailAssignmentStatusDto
    {
        public int AssignmentId { get; set; }
        public string GroupName { get; set; } = string.Empty;
        public DateOnly DueDate { get; set; }
        public List<CourseEmailTypeStatusDto> Types { get; set; } = [];
    }

    public class CourseEmailTypeStatusDto
    {
        public string AlertType { get; set; } = string.Empty;
        public int Pending { get; set; }
        public int Sent { get; set; }
        public int Failed { get; set; }
        public int Skipped { get; set; }
    }

    public class CourseEmailFailedItemDto
    {
        public long Id { get; set; }
        public string AlertType { get; set; } = string.Empty;
        public int AssignmentId { get; set; }
        public string? Name { get; set; }
        public string? Email { get; set; }
        public string? Error { get; set; }
        public int Attempts { get; set; }
        public DateTime? LastAttemptDate { get; set; }
    }

    /// <summary>Para las tarjetas de "Cursos": solo los cursos con correos en cola o con error.</summary>
    public class CourseEmailActivityDto
    {
        public int CourseId { get; set; }
        public int Pending { get; set; }
        public int Failed { get; set; }
    }
}
```

### `Helpers/CourseEmailQueueFactory.cs`

```csharp
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.CourseEmails.Application.Helpers
{
    public static class CourseEmailQueueFactory
    {
        /// <summary>
        /// Un correo para una persona de una asignación. Recibe la entidad, no el Id:
        /// sirve antes de guardar y EF llena assignment_user_id en el mismo SaveChanges.
        /// </summary>
        public static CourseEmailQueueItem ForPerson(string alertType, CourseAssignmentUser assignmentUser, DateTime now, string createdBy) => new()
        {
            AlertType = alertType,
            AssignmentUser = assignmentUser,
            Status = CourseEmailQueueStatus.Pending,
            NextAttemptDate = now,
            CreatedDate = now,
            CreatedBy = createdBy,
        };
    }
}
```

### `Interfaces/ICourseEmailComposer.cs`

Cada tipo de correo sabe armarse. El proceso no conoce las plantillas: le pide el correo al composer del tipo.

```csharp
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.CourseEmails.Application.Interfaces
{
    /// <summary>El correo listo para enviar. AssignmentId va al log ("Registro de correos").</summary>
    public sealed record ComposedEmail(
        string To,
        IReadOnlyList<string> Cc,
        string Subject,
        string TemplateFileName,
        IDictionary<string, string> Tokens,
        int? AssignmentId);

    /// <summary>Se envía (Email) o ya no aplica (SkipReason).</summary>
    public sealed record CourseEmailComposition(ComposedEmail? Email, string? SkipReason)
    {
        public static CourseEmailComposition Send(ComposedEmail email) => new(email, null);
        public static CourseEmailComposition Skip(string reason) => new(null, reason);
    }

    public interface ICourseEmailComposer
    {
        /// <summary>Tipos de correo (EmailAlertTypes) que sabe armar.</summary>
        IReadOnlyCollection<string> AlertTypes { get; }

        /// <summary>Arma el correo con los datos de este momento. Skip si ya no aplica.</summary>
        Task<CourseEmailComposition> ComposeAsync(CourseEmailQueueItem item, CancellationToken ct);
    }
}
```

### `Interfaces/ICourseEmailQueueSignal.cs`

```csharp
namespace DOCCB.Application.Features.CourseEmails.Application.Interfaces
{
    /// <summary>Singleton: despierta al proceso en cuanto hay correos nuevos, sin esperar su siguiente revisión.</summary>
    public interface ICourseEmailQueueSignal
    {
        void Notify();

        /// <summary>Espera un aviso o hasta que pase el tiempo. true si llegó un aviso.</summary>
        Task<bool> WaitAsync(TimeSpan timeout, CancellationToken ct);
    }
}
```

### `Services/CourseEmailQueueSignal.cs`

```csharp
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;

namespace DOCCB.Application.Features.CourseEmails.Application.Services
{
    public sealed class CourseEmailQueueSignal : ICourseEmailQueueSignal
    {
        // Máximo 1: varios avisos seguidos despiertan al proceso una sola vez.
        private readonly SemaphoreSlim _signal = new(0, 1);

        public void Notify()
        {
            try
            {
                _signal.Release();
            }
            catch (SemaphoreFullException)
            {
                // Ya estaba avisado.
            }
        }

        public Task<bool> WaitAsync(TimeSpan timeout, CancellationToken ct) => _signal.WaitAsync(timeout, ct);
    }
}
```

> El aviso solo despierta al proceso de **este** servidor. Si hay otra instancia, la encuentra en su siguiente revisión (30 s).

---

## 8. Paso 4 — La asignación encola en vez de enviar

### `Contracts/Persistence/ICourseRepository.cs` ✏️ — en "Escrituras"

```csharp
/// <summary>Correos que se guardan en el mismo SaveChanges que la asignación: o quedan los dos o ninguno.</summary>
void QueueEmails(IEnumerable<CourseEmailQueueItem> emails);
```

### `Repositories/CourseRepository.cs` ✏️

```csharp
public void QueueEmails(IEnumerable<CourseEmailQueueItem> emails) => db.Set<CourseEmailQueueItem>().AddRange(emails);
```

### `DTOs/SaveCourseRequestDto.cs` ✏️ — en `SaveCourseResultDto` y en `SyncAssignmentResultDto`

```csharp
/// <summary>Correos de bienvenida que quedaron en cola (se envían en segundo plano).</summary>
public int QueuedEmails { get; set; }
```

### `Services/CourseService.cs` ✏️

**1. Dependencia:** `ICourseNotificationService notificationService` se reemplaza por la señal:

```csharp
public class CourseService(
    ICourseRepository repository,
    IUserGroupRepository userGroupRepository,
    ICourseEmailQueueSignal emailQueueSignal,
    TimeProvider timeProvider) : ICourseService
{
    private readonly ICourseRepository _repository = repository;
    private readonly IUserGroupRepository _userGroupRepository = userGroupRepository;
    private readonly ICourseEmailQueueSignal _emailQueueSignal = emailQueueSignal;
    private readonly TimeProvider _timeProvider = timeProvider;
```

Usings nuevos:

```csharp
using DOCCB.Application.Features.CourseEmails.Application.Helpers;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
```

**2. `CreateAsync`:** justo antes de `var saveConflict = await TrySaveAsync(ct);`:

```csharp
var queued = QueueWelcomeEmails(course.Assignments.SelectMany(a => a.Users), now, currentUser);
```

Y después de guardar, en lugar de `await NotifyAssignedAsync(course.Assignments, …);`:

```csharp
NotifyQueue(queued);

return CourseResult<SaveCourseResultDto>.Ok(new SaveCourseResultDto
{
    CourseId = course.Id,
    SkippedWithoutUser = skipped,
    QueuedEmails = queued,
});
```

**3. `UpdateAsync`:** igual, con las asignaciones nuevas. Antes de `TrySaveAsync`:

```csharp
var queued = QueueWelcomeEmails(createdAssignments.SelectMany(a => a.Users), now, currentUser);
```

Después de guardar, en lugar de `await NotifyAssignedAsync(createdAssignments, …);`:

```csharp
NotifyQueue(queued);

return CourseResult<SaveCourseResultDto>.Ok(new SaveCourseResultDto
{
    CourseId = id,
    SkippedWithoutUser = skipped,
    QueuedEmails = queued,
});
```

**4. `SyncAssignmentAsync`:** antes de `await _repository.SaveChangesAsync(ct);`:

```csharp
var queued = QueueWelcomeEmails(newUsers, now, currentUser);
```

Después, en lugar de `await NotifyAssignedAsync(assignment, newUsers, …);`, `NotifyQueue(queued);` y en el resultado `QueuedEmails = queued`.

**5. Borra** los dos `NotifyAssignedAsync` privados y `ModalityLabel` (solo los usaban ellos). **Agrega:**

```csharp
/// <summary>Un correo de bienvenida en cola por persona nueva. Se guarda con la asignación.</summary>
private int QueueWelcomeEmails(IEnumerable<CourseAssignmentUser> users, DateTime now, string currentUser)
{
    var emails = users
        .Select(user => CourseEmailQueueFactory.ForPerson(EmailAlertTypes.CourseAssigned, user, now, currentUser))
        .ToList();

    _repository.QueueEmails(emails);
    return emails.Count;
}

/// <summary>Después de guardar: el proceso en segundo plano empieza ya.</summary>
private void NotifyQueue(int queued)
{
    if (queued > 0) _emailQueueSignal.Notify();
}
```

> Si una validación devuelve error después de `QueueWelcomeEmails`, no se guarda nada: el contexto es de la petición, igual que el curso.

### 🗑️ Se borran

- `Services/CourseNotificationService.cs`
- `Interfaces/ICourseNotificationService.cs`
- `DTOs/CourseAssignedNotification.cs`
- Su registro en `ApplicationServiceRegistration.cs`: `services.AddScoped<ICourseNotificationService, CourseNotificationService>();`

Lo que hacían (tokens, plantilla, enlace `?finalizar=`) pasa al composer de bienvenida (Paso 5).

---

## 9. Paso 5 — La bienvenida: `CourseAssignedEmailComposer`

Reutiliza `ICourseCompletionRepository.GetAssignmentUserAsync`, que ya trae curso, grupo, fecha, nombre y correo de una persona asignada.

### `Composers/CourseAssignedEmailComposer.cs`

```csharp
using System.Globalization;
using System.Net;
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Configuration;

namespace DOCCB.Application.Features.CourseEmails.Application.Composers
{
    /// <summary>"Tienes un curso asignado": un correo por persona cuando queda en una asignación (grupo + fecha).</summary>
    public class CourseAssignedEmailComposer(
        ICourseCompletionRepository assignments,
        IConfiguration configuration) : ICourseEmailComposer
    {
        private const string TemplateFileName = "TemplateCourseAssignedUser.html";
        private const string Subject = "Tienes un curso asignado";
        private static readonly CultureInfo Spanish = new("es-ES");

        private readonly ICourseCompletionRepository _assignments = assignments;
        private readonly IConfiguration _configuration = configuration;

        public IReadOnlyCollection<string> AlertTypes { get; } = [EmailAlertTypes.CourseAssigned];

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

            if (string.IsNullOrWhiteSpace(person.Email))
            {
                return CourseEmailComposition.Skip(CourseEmailConstants.NoEmail);
            }

            var portalUrl = _configuration["Frontend:FrontendApp"]?.TrimEnd('/') ?? string.Empty;
            var tokens = new Dictionary<string, string>
            {
                ["NOMBRE"] = WebUtility.HtmlEncode(person.DisplayName),
                ["CURSO"] = WebUtility.HtmlEncode(person.CourseName),
                ["MODALIDAD"] = person.Modality.ToString(),
                ["GRUPO"] = WebUtility.HtmlEncode(string.IsNullOrWhiteSpace(person.GroupName) ? CourseEmailConstants.NoGroupName : person.GroupName),
                ["FECHA_LIMITE"] = person.DueDate.ToDateTime(TimeOnly.MinValue).ToString("d 'de' MMMM 'de' yyyy", Spanish),
                ["CURSO_URL"] = portalUrl,
                ["CTA_URL"] = $"{portalUrl}/mis-cursos?finalizar={person.Id}",
            };

            return CourseEmailComposition.Send(new ComposedEmail(person.Email, [], Subject, TemplateFileName, tokens, person.AssignmentId));
        }
    }
}
```

> Son los mismos tokens, plantilla, asunto y cultura del `CourseNotificationService` que se borra. `CourseModality.ToString()` da "Virtual" / "Presencial", lo mismo que el `ModalityLabel` de antes.

---

## 10. Paso 6 — El correo: cliente de Graph compartido y `cc`

### `IMailNotificationService` ✏️ — parámetro opcional al final

```csharp
Task<ResponseDto<string>?> SendTemplatedEmailAsync(
    string to,
    string subject,
    string templateFileName,
    IDictionary<string, string> tokens,
    string? portalUrl = null,
    byte[]? pdfAttachment = null,
    string? pdfAttachmentName = null,
    IReadOnlyCollection<string>? cc = null);
```

### `MailNotificationService` ✏️

**1. Usa el `GraphServiceClient` que ya está registrado** (singleton con `ClientSecretCredential`, el mismo de "Por líder"). Ese cliente guarda el token y lo renueva solo. Hoy cada correo pide un token nuevo a Entra ID y crea su propio cliente.

```csharp
public class MailNotificationService(
    IConfiguration configuration,
    GraphServiceClient graph,
    ILogger<MailNotificationService> logger) : IMailNotificationService
{
    private readonly IConfiguration _configuration = configuration;
    private readonly GraphServiceClient _graph = graph;
    private readonly ILogger<MailNotificationService> _logger = logger;
```

En `SendTemplatedEmailAsync`, borra estas dos líneas:

```csharp
var token = await _tokenService.GetTokenAsync();
var graphClient = new GraphServiceClient(new BaseBearerTokenAuthenticationProvider(new TokenProvider(token)));
```

y envía con el compartido:

```csharp
await _graph.Users[sender].SendMail
    .PostAsync(new SendMailPostRequestBody
    {
        Message = message,
        SaveToSentItems = true
    });
```

Quita los `using` que quedan sin uso: `Microsoft.Kiota.Abstractions.Authentication` y los dos de `MSAL`. `ITokenService` sigue registrado porque `RequestSharePointStorageService` lo usa.

> Es la misma app de Entra ID (`AzureAd:TenantId`, `ClientId`, `ClientSecret`), con el mismo permiso `Mail.Send`. El cliente de Graph trae además el reintento automático de los 429 con `Retry-After`.

**2. `cc`:** agrega `IReadOnlyCollection<string>? cc = null` al final de la firma y, en el `new Message { … }`, después de `ToRecipients`:

```csharp
CcRecipients = (cc ?? [])
    .Where(email => !string.IsNullOrWhiteSpace(email) && !email.Equals(to, StringComparison.OrdinalIgnoreCase))
    .Distinct(StringComparer.OrdinalIgnoreCase)
    .Select(email => new Recipient { EmailAddress = new EmailAddress { Address = email } })
    .ToList(),
```

Las llamadas de hoy (certificados, solicitudes) no cambian: los parámetros son opcionales.

---

## 11. Paso 7 — El repositorio de la cola

### `Contracts/Persistence/ICourseEmailQueueRepository.cs`

```csharp
using DOCCB.Application.Features.CourseEmails.Application.Dtos;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Contracts.Persistence
{
    public sealed record CourseEmailCountRow(int AssignmentId, string AlertType, string Status, int Count);

    public sealed record CourseEmailAssignmentRow(int AssignmentId, string? GroupName, DateOnly DueDate);

    /// <summary>La cola de correos: reclamo atómico para el proceso y conteos para la pantalla.</summary>
    public interface ICourseEmailQueueRepository
    {
        // ── Proceso en segundo plano ────────────────────────────────────
        /// <summary>Toma el siguiente correo listo (PENDING o SENDING abandonado). Solo una instancia lo gana.</summary>
        Task<CourseEmailQueueItem?> ClaimNextAsync(DateTime now, DateTime lockedUntil, CancellationToken ct);
        Task MarkSentAsync(long id, DateTime now, CancellationToken ct);
        Task MarkSkippedAsync(long id, string reason, DateTime now, CancellationToken ct);
        Task MarkRetryAsync(long id, DateTime nextAttempt, string error, CancellationToken ct);
        Task MarkFailedAsync(long id, string error, DateTime now, CancellationToken ct);
        Task<int> DeleteProcessedBeforeAsync(DateTime before, CancellationToken ct);

        // ── Estado para la pantalla ─────────────────────────────────────
        Task<IReadOnlyList<CourseEmailAssignmentRow>> GetAssignmentsAsync(int courseId, CancellationToken ct);
        Task<IReadOnlyList<CourseEmailCountRow>> CountByAssignmentAsync(int courseId, CancellationToken ct);
        Task<IReadOnlyList<CourseEmailFailedItemDto>> GetFailedAsync(int courseId, int take, CancellationToken ct);
        Task<IReadOnlyList<CourseEmailActivityDto>> GetActiveCoursesAsync(CancellationToken ct);
        /// <summary>PENDING + SENDING de toda la cola, para estimar cuánto falta.</summary>
        Task<int> CountPendingAsync(CancellationToken ct);
        /// <summary>Los FAILED del curso vuelven a PENDING con los intentos en cero.</summary>
        Task<int> RetryFailedAsync(int courseId, DateTime now, CancellationToken ct);
    }
}
```

### `Repositories/CourseEmailQueueRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Application.Features.CourseEmails.Application.Dtos;
using DOCCB.Domain.Entities;
using DOCCB.Infraestructure.Common;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Infraestructure.Repositories
{
    /// <summary>
    /// Hereda de GenericRepositoryBase como CourseCompletionRepository: _dbSet es course_email_queue
    /// y _context da acceso a course_assignment.
    /// La asignación de cada fila sale de la persona (bienvenida, recordatorios) o de assignment_id (reporte).
    /// </summary>
    public class CourseEmailQueueRepository(DOCCbDbContext context)
        : GenericRepositoryBase<DOCCbDbContext, CourseEmailQueueItem>(context), ICourseEmailQueueRepository
    {
        // ── Proceso en segundo plano ────────────────────────────────────

        public async Task<CourseEmailQueueItem?> ClaimNextAsync(DateTime now, DateTime lockedUntil, CancellationToken ct)
        {
            // Si otra instancia gana el mismo correo, se prueba con el siguiente.
            for (var attempt = 0; attempt < 3; attempt++)
            {
                var candidateId = await Claimable(now)
                    .OrderBy(i => i.NextAttemptDate)
                    .ThenBy(i => i.Id)
                    .Select(i => (long?)i.Id)
                    .FirstOrDefaultAsync(ct);

                if (candidateId is null)
                {
                    return null;
                }

                // El UPDATE vuelve a revisar la condición en la misma sentencia: solo uno lo gana.
                var claimed = await Claimable(now)
                    .Where(i => i.Id == candidateId)
                    .ExecuteUpdateAsync(s => s
                        .SetProperty(i => i.Status, CourseEmailQueueStatus.Sending)
                        .SetProperty(i => i.LockedUntil, lockedUntil)
                        .SetProperty(i => i.Attempts, i => i.Attempts + 1), ct);

                if (claimed == 1)
                {
                    return await _dbSet.AsNoTracking().FirstAsync(i => i.Id == candidateId, ct);
                }
            }

            return null;
        }

        public Task MarkSentAsync(long id, DateTime now, CancellationToken ct) =>
            _dbSet.Where(i => i.Id == id).ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, CourseEmailQueueStatus.Sent)
                .SetProperty(i => i.ProcessedDate, now)
                .SetProperty(i => i.LockedUntil, (DateTime?)null)
                .SetProperty(i => i.LastError, (string?)null), ct);

        public Task MarkSkippedAsync(long id, string reason, DateTime now, CancellationToken ct) =>
            _dbSet.Where(i => i.Id == id).ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, CourseEmailQueueStatus.Skipped)
                .SetProperty(i => i.ProcessedDate, now)
                .SetProperty(i => i.LockedUntil, (DateTime?)null)
                .SetProperty(i => i.LastError, reason), ct);

        public Task MarkRetryAsync(long id, DateTime nextAttempt, string error, CancellationToken ct) =>
            _dbSet.Where(i => i.Id == id).ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, CourseEmailQueueStatus.Pending)
                .SetProperty(i => i.NextAttemptDate, nextAttempt)
                .SetProperty(i => i.LockedUntil, (DateTime?)null)
                .SetProperty(i => i.LastError, error), ct);

        public Task MarkFailedAsync(long id, string error, DateTime now, CancellationToken ct) =>
            _dbSet.Where(i => i.Id == id).ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, CourseEmailQueueStatus.Failed)
                .SetProperty(i => i.ProcessedDate, now)
                .SetProperty(i => i.LockedUntil, (DateTime?)null)
                .SetProperty(i => i.LastError, error), ct);

        public Task<int> DeleteProcessedBeforeAsync(DateTime before, CancellationToken ct) =>
            _dbSet
                .Where(i => (i.Status == CourseEmailQueueStatus.Sent
                        || i.Status == CourseEmailQueueStatus.Skipped
                        || i.Status == CourseEmailQueueStatus.Failed)
                    && i.ProcessedDate < before)
                .ExecuteDeleteAsync(ct);

        // ── Estado para la pantalla ─────────────────────────────────────

        public async Task<IReadOnlyList<CourseEmailAssignmentRow>> GetAssignmentsAsync(int courseId, CancellationToken ct) =>
            await _context.Set<CourseAssignment>()
                .AsNoTracking()
                .Where(a => a.CourseId == courseId)
                .OrderBy(a => a.DueDate)
                .ThenBy(a => a.Id)
                .Select(a => new CourseEmailAssignmentRow(a.Id, a.UserGroup != null ? a.UserGroup.Name : null, a.DueDate))
                .ToListAsync(ct);

        public async Task<IReadOnlyList<CourseEmailCountRow>> CountByAssignmentAsync(int courseId, CancellationToken ct)
        {
            var assignmentIds = AssignmentIdsOf(courseId);

            return await Rows()
                .Where(r => assignmentIds.Contains(r.AssignmentId))
                .GroupBy(r => new { r.AssignmentId, r.AlertType, r.Status })
                .Select(g => new CourseEmailCountRow(g.Key.AssignmentId, g.Key.AlertType, g.Key.Status, g.Count()))
                .ToListAsync(ct);
        }

        public async Task<IReadOnlyList<CourseEmailFailedItemDto>> GetFailedAsync(int courseId, int take, CancellationToken ct)
        {
            var assignmentIds = AssignmentIdsOf(courseId);

            return await _dbSet
                .AsNoTracking()
                .Where(i => i.Status == CourseEmailQueueStatus.Failed
                    && assignmentIds.Contains(i.AssignmentUserId != null ? i.AssignmentUser!.AssignmentId : i.AssignmentId!.Value))
                .OrderByDescending(i => i.ProcessedDate)
                .Take(take)
                .Select(i => new CourseEmailFailedItemDto
                {
                    Id = i.Id,
                    AlertType = i.AlertType,
                    AssignmentId = i.AssignmentUserId != null ? i.AssignmentUser!.AssignmentId : i.AssignmentId!.Value,
                    Name = i.AssignmentUser != null ? i.AssignmentUser.User.DisplayName : null,
                    Email = i.AssignmentUser != null ? i.AssignmentUser.User.CorportativeEmail : i.RecipientEmail,
                    Error = i.LastError,
                    Attempts = i.Attempts,
                    LastAttemptDate = i.ProcessedDate,
                })
                .ToListAsync(ct);
        }

        public async Task<IReadOnlyList<CourseEmailActivityDto>> GetActiveCoursesAsync(CancellationToken ct) =>
            await Rows()
                .Where(r => r.Status == CourseEmailQueueStatus.Pending
                    || r.Status == CourseEmailQueueStatus.Sending
                    || r.Status == CourseEmailQueueStatus.Failed)
                .Join(_context.Set<CourseAssignment>(), r => r.AssignmentId, a => a.Id, (r, a) => new { a.CourseId, r.Status })
                .GroupBy(x => x.CourseId)
                .Select(g => new CourseEmailActivityDto
                {
                    CourseId = g.Key,
                    Pending = g.Count(x => x.Status != CourseEmailQueueStatus.Failed),
                    Failed = g.Count(x => x.Status == CourseEmailQueueStatus.Failed),
                })
                .ToListAsync(ct);

        public Task<int> CountPendingAsync(CancellationToken ct) =>
            _dbSet.CountAsync(i => i.Status == CourseEmailQueueStatus.Pending || i.Status == CourseEmailQueueStatus.Sending, ct);

        public Task<int> RetryFailedAsync(int courseId, DateTime now, CancellationToken ct)
        {
            var assignmentIds = AssignmentIdsOf(courseId);

            return _dbSet
                .Where(i => i.Status == CourseEmailQueueStatus.Failed
                    && assignmentIds.Contains(i.AssignmentUserId != null ? i.AssignmentUser!.AssignmentId : i.AssignmentId!.Value))
                .ExecuteUpdateAsync(s => s
                    .SetProperty(i => i.Status, CourseEmailQueueStatus.Pending)
                    .SetProperty(i => i.Attempts, 0)
                    .SetProperty(i => i.NextAttemptDate, now)
                    .SetProperty(i => i.ProcessedDate, (DateTime?)null)
                    .SetProperty(i => i.LastError, (string?)null), ct);
        }

        // ── Privados ────────────────────────────────────────────────────

        /// <summary>PENDING cuya hora ya llegó, o SENDING cuyo envío quedó abandonado (el proceso se cayó).</summary>
        private IQueryable<CourseEmailQueueItem> Claimable(DateTime now) =>
            _dbSet.Where(i => (i.Status == CourseEmailQueueStatus.Pending && i.NextAttemptDate <= now)
                || (i.Status == CourseEmailQueueStatus.Sending && i.LockedUntil < now));

        /// <summary>Cada fila con su asignación, para agrupar y filtrar por curso.</summary>
        private IQueryable<QueueRow> Rows() =>
            _dbSet.AsNoTracking().Select(i => new QueueRow
            {
                AssignmentId = i.AssignmentUserId != null ? i.AssignmentUser!.AssignmentId : i.AssignmentId!.Value,
                AlertType = i.AlertType,
                Status = i.Status,
            });

        /// <summary>Subconsulta: EF la mete dentro del WHERE (no trae los ids a memoria).</summary>
        private IQueryable<int> AssignmentIdsOf(int courseId) =>
            _context.Set<CourseAssignment>().Where(a => a.CourseId == courseId).Select(a => a.Id);

        private sealed class QueueRow
        {
            public int AssignmentId { get; init; }
            public string AlertType { get; init; } = string.Empty;
            public string Status { get; init; } = string.Empty;
        }
    }
}
```

> **Por qué un repositorio propio:** el reclamo usa `ExecuteUpdateAsync` con una condición que se revisa en la misma sentencia, y los conteos cruzan `course_assignment`. Ver [convenciones](.claude/convenciones-backend-doccb.md), "¿Cuándo sí un repositorio propio?".
>
> **`AssignmentIdsOf` va en una variable antes del `Where`:** así EF la traduce como subconsulta. Llamada dentro del lambda, no se podría traducir.
>
> **`QueueRow` con propiedades `init`** (no un `record` posicional): EF puede seguir filtrando y agrupando sobre propiedades asignadas, no sobre parámetros de constructor.

---

## 12. Paso 8 — ⭐ El proceso: dispatcher y worker

### `Interfaces/ICourseEmailDispatcher.cs`

```csharp
namespace DOCCB.Application.Features.CourseEmails.Application.Interfaces
{
    public enum CourseEmailDispatchResult
    {
        /// <summary>No hay nada listo para enviar.</summary>
        Empty,
        Sent,
        /// <summary>Ya no aplicaba: no se envió nada.</summary>
        Skipped,
        /// <summary>Falló; vuelve a la cola más tarde.</summary>
        Retrying,
        /// <summary>Falló y agotó los intentos.</summary>
        Failed,
    }

    public interface ICourseEmailDispatcher
    {
        /// <summary>Toma el siguiente correo de la cola y lo procesa.</summary>
        Task<CourseEmailDispatchResult> ProcessNextAsync(CancellationToken ct);

        /// <summary>Borra lo procesado hace más de retentionDays. El historial queda en email_alert_log.</summary>
        Task CleanupAsync(int retentionDays, CancellationToken ct);
    }
}
```

### `Services/CourseEmailDispatcher.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using DOCCB.Application.Features.EmailAlertLog.Application.Constants;
using DOCCB.Application.Features.EmailAlertLog.Application.Dtos;
using DOCCB.Application.Features.EmailAlertLog.Application.Interfaces;
using DOCCB.Application.Features.MailNotification.Application.Interfaces;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.CourseEmails.Application.Services
{
    /// <summary>Scoped: el worker crea un scope por correo (DbContext nuevo cada vez).</summary>
    public class CourseEmailDispatcher(
        ICourseEmailQueueRepository queue,
        IEnumerable<ICourseEmailComposer> composers,
        IMailNotificationService mailNotificationService,
        IEmailAlertLogService emailAlertLogService,
        TimeProvider timeProvider,
        ILogger<CourseEmailDispatcher> logger) : ICourseEmailDispatcher
    {
        private readonly ICourseEmailQueueRepository _queue = queue;
        private readonly IEnumerable<ICourseEmailComposer> _composers = composers;
        private readonly IMailNotificationService _mail = mailNotificationService;
        private readonly IEmailAlertLogService _emailAlerts = emailAlertLogService;
        private readonly TimeProvider _timeProvider = timeProvider;
        private readonly ILogger<CourseEmailDispatcher> _logger = logger;

        public async Task<CourseEmailDispatchResult> ProcessNextAsync(CancellationToken ct)
        {
            var now = UtcNow();
            var item = await _queue.ClaimNextAsync(now, now.AddMinutes(CourseEmailConstants.LockMinutes), ct);
            if (item is null)
            {
                return CourseEmailDispatchResult.Empty;
            }

            var composer = _composers.FirstOrDefault(c => c.AlertTypes.Contains(item.AlertType));
            if (composer is null)
            {
                await _queue.MarkSkippedAsync(item.Id, CourseEmailConstants.NoComposer, UtcNow(), ct);
                return CourseEmailDispatchResult.Skipped;
            }

            CourseEmailComposition composition;
            try
            {
                composition = await composer.ComposeAsync(item, ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "No se pudo preparar el correo {Id} ({AlertType}).", item.Id, item.AlertType);
                return await FailAsync(item, email: null, CourseEmailConstants.ComposeFailed, ct);
            }

            if (composition.Email is not { } email)
            {
                await _queue.MarkSkippedAsync(item.Id, composition.SkipReason ?? string.Empty, UtcNow(), ct);
                return CourseEmailDispatchResult.Skipped;
            }

            // SendTemplatedEmailAsync no lanza: devuelve el error en la respuesta.
            var response = await _mail.SendTemplatedEmailAsync(
                email.To, email.Subject, email.TemplateFileName, email.Tokens, cc: email.Cc);

            if (response is { HasError: false })
            {
                await _queue.MarkSentAsync(item.Id, UtcNow(), ct);
                await _emailAlerts.RegisterAsync(ToLog(item, email), EmailAlertStatus.Sent);
                return CourseEmailDispatchResult.Sent;
            }

            return await FailAsync(item, email, response?.Errors.FirstOrDefault() ?? CourseEmailConstants.SendFailed, ct);
        }

        public async Task CleanupAsync(int retentionDays, CancellationToken ct)
        {
            var deleted = await _queue.DeleteProcessedBeforeAsync(UtcNow().AddDays(-retentionDays), ct);
            if (deleted > 0)
            {
                _logger.LogInformation("Cola de correos de cursos: {Deleted} filas procesadas borradas.", deleted);
            }
        }

        // ── Privados ────────────────────────────────────────────────────

        /// <summary>Reintenta más tarde. Al agotar los intentos queda FAILED y en "Registro de correos".</summary>
        private async Task<CourseEmailDispatchResult> FailAsync(
            CourseEmailQueueItem item, ComposedEmail? email, string error, CancellationToken ct)
        {
            error = error.Length <= CourseEmailConstants.MaxErrorLength ? error : error[..CourseEmailConstants.MaxErrorLength];

            // ClaimNextAsync ya sumó este intento.
            if (item.Attempts < CourseEmailConstants.MaxAttempts)
            {
                var delays = CourseEmailConstants.RetryDelayMinutes;
                var minutes = delays[Math.Min(item.Attempts, delays.Length) - 1];
                await _queue.MarkRetryAsync(item.Id, UtcNow().AddMinutes(minutes), error, ct);
                return CourseEmailDispatchResult.Retrying;
            }

            await _queue.MarkFailedAsync(item.Id, error, UtcNow(), ct);
            if (email is not null)
            {
                await _emailAlerts.RegisterAsync(ToLog(item, email), EmailAlertStatus.Failed, error);
            }

            return CourseEmailDispatchResult.Failed;
        }

        private static EmailAlertSend ToLog(CourseEmailQueueItem item, ComposedEmail email) =>
            new(item.AlertType, email.AssignmentId, [email.To, .. email.Cc]);

        private DateTime UtcNow() => _timeProvider.GetUtcNow().UtcDateTime;
    }
}
```

> **Log:** usa `IEmailAlertLogService.RegisterAsync` (ya existe) en vez de `SendAndLogAsync`, para registrar solo el resultado final y no un `FAILED` por cada reintento.

### `WebApp/BackgroundServices/CourseEmailWorker.cs`

Es el primer `BackgroundService` de esta API: crea la carpeta `BackgroundServices`.

```csharp
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;

namespace DOCCB.WebApp.BackgroundServices
{
    /// <summary>
    /// Atiende la cola de correos de cursos mientras la API esté arriba: uno a la vez, al ritmo de
    /// "CourseEmails:MaxPerMinute". Sin pendientes, espera un aviso (ICourseEmailQueueSignal) o "PollSeconds".
    /// Se desactiva con "CourseEmails:WorkerEnabled": false (los correos quedan en PENDING).
    /// </summary>
    public class CourseEmailWorker(
        IServiceScopeFactory scopeFactory,
        ICourseEmailQueueSignal signal,
        IConfiguration configuration,
        ILogger<CourseEmailWorker> logger) : BackgroundService
    {
        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            if (!configuration.GetValue("CourseEmails:WorkerEnabled", true))
            {
                logger.LogInformation("Cola de correos de cursos desactivada por configuración.");
                return;
            }

            // Nunca por encima de 30: es el límite de Exchange Online por buzón.
            var maxPerMinute = Math.Clamp(configuration.GetValue("CourseEmails:MaxPerMinute", CourseEmailConstants.DefaultMaxPerMinute), 1, 30);
            var pause = TimeSpan.FromSeconds(60.0 / maxPerMinute);
            var poll = TimeSpan.FromSeconds(configuration.GetValue("CourseEmails:PollSeconds", CourseEmailConstants.DefaultPollSeconds));
            var retentionDays = configuration.GetValue("CourseEmails:RetentionDays", CourseEmailConstants.DefaultRetentionDays);
            var nextCleanup = DateTime.MinValue;

            while (!stoppingToken.IsCancellationRequested)
            {
                var result = CourseEmailDispatchResult.Empty;

                try
                {
                    // Un scope por correo: DbContext nuevo y nada acumulado en memoria.
                    using var scope = scopeFactory.CreateScope();
                    var dispatcher = scope.ServiceProvider.GetRequiredService<ICourseEmailDispatcher>();

                    if (DateTime.UtcNow >= nextCleanup)
                    {
                        await dispatcher.CleanupAsync(retentionDays, stoppingToken);
                        nextCleanup = DateTime.UtcNow.AddDays(1);
                    }

                    result = await dispatcher.ProcessNextAsync(stoppingToken);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    return;
                }
                catch (Exception ex)
                {
                    // Por ejemplo, la base de datos no responde: se intenta en la siguiente vuelta.
                    logger.LogError(ex, "Error procesando la cola de correos de cursos.");
                }

                try
                {
                    switch (result)
                    {
                        case CourseEmailDispatchResult.Empty:
                            await signal.WaitAsync(poll, stoppingToken); // despierta antes si llega un aviso
                            break;
                        case CourseEmailDispatchResult.Skipped:
                            break; // no se envió nada: sigue con el siguiente
                        default:
                            await Task.Delay(pause, stoppingToken); // el ritmo que acepta Exchange
                            break;
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }
}
```

---

## 13. Paso 9 — El estado para la pantalla

### `Interfaces/ICourseEmailStatusService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.CourseEmails.Application.Dtos;

namespace DOCCB.Application.Features.CourseEmails.Application.Interfaces
{
    public interface ICourseEmailStatusService
    {
        Task<ResponseDto<CourseEmailStatusDto>> GetCourseStatusAsync(int courseId, CancellationToken ct = default);

        /// <summary>Cursos con correos en cola o con error (para las tarjetas).</summary>
        Task<ResponseDto<List<CourseEmailActivityDto>>> GetActiveAsync(CancellationToken ct = default);

        /// <summary>Vuelve a poner en cola los que fallaron. Devuelve cuántos.</summary>
        Task<ResponseDto<int>> RetryFailedAsync(int courseId, CancellationToken ct = default);
    }
}
```

### `Services/CourseEmailStatusService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.CourseEmails.Application.Constants;
using DOCCB.Application.Features.CourseEmails.Application.Dtos;
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using Microsoft.Extensions.Configuration;

namespace DOCCB.Application.Features.CourseEmails.Application.Services
{
    public class CourseEmailStatusService(
        ICourseEmailQueueRepository queue,
        ICourseEmailQueueSignal signal,
        IConfiguration configuration,
        TimeProvider timeProvider) : ICourseEmailStatusService
    {
        private readonly ICourseEmailQueueRepository _queue = queue;
        private readonly ICourseEmailQueueSignal _signal = signal;
        private readonly IConfiguration _configuration = configuration;
        private readonly TimeProvider _timeProvider = timeProvider;

        public async Task<ResponseDto<CourseEmailStatusDto>> GetCourseStatusAsync(int courseId, CancellationToken ct = default)
        {
            var assignments = await _queue.GetAssignmentsAsync(courseId, ct);
            var counts = await _queue.CountByAssignmentAsync(courseId, ct);
            var failed = await _queue.GetFailedAsync(courseId, CourseEmailConstants.FailedItemsLimit, ct);
            var pendingInQueue = await _queue.CountPendingAsync(ct);

            var status = new CourseEmailStatusDto
            {
                CourseId = courseId,
                Pending = Sum(counts, CourseEmailQueueStatus.Pending, CourseEmailQueueStatus.Sending),
                Sent = Sum(counts, CourseEmailQueueStatus.Sent),
                Failed = Sum(counts, CourseEmailQueueStatus.Failed),
                Skipped = Sum(counts, CourseEmailQueueStatus.Skipped),
                EstimatedMinutes = (int)Math.Ceiling(pendingInQueue / (double)MaxPerMinute()),
                FailedItems = [.. failed],
                Assignments = assignments
                    .Select(a => new CourseEmailAssignmentStatusDto
                    {
                        AssignmentId = a.AssignmentId,
                        GroupName = string.IsNullOrWhiteSpace(a.GroupName) ? CourseEmailConstants.NoGroupName : a.GroupName,
                        DueDate = a.DueDate,
                        Types = counts
                            .Where(c => c.AssignmentId == a.AssignmentId)
                            .GroupBy(c => c.AlertType)
                            .Select(g => new CourseEmailTypeStatusDto
                            {
                                AlertType = g.Key,
                                Pending = Sum(g, CourseEmailQueueStatus.Pending, CourseEmailQueueStatus.Sending),
                                Sent = Sum(g, CourseEmailQueueStatus.Sent),
                                Failed = Sum(g, CourseEmailQueueStatus.Failed),
                                Skipped = Sum(g, CourseEmailQueueStatus.Skipped),
                            })
                            .ToList(),
                    })
                    .Where(a => a.Types.Count > 0)
                    .ToList(),
            };

            return ResponseDtoHelper.CreateSuccessResponseDto(status);
        }

        public async Task<ResponseDto<List<CourseEmailActivityDto>>> GetActiveAsync(CancellationToken ct = default) =>
            ResponseDtoHelper.CreateSuccessResponseDto((await _queue.GetActiveCoursesAsync(ct)).ToList());

        public async Task<ResponseDto<int>> RetryFailedAsync(int courseId, CancellationToken ct = default)
        {
            var count = await _queue.RetryFailedAsync(courseId, _timeProvider.GetUtcNow().UtcDateTime, ct);
            if (count > 0)
            {
                _signal.Notify();
            }

            return ResponseDtoHelper.CreateSuccessResponseDto(count);
        }

        // ── Privados ────────────────────────────────────────────────────

        private static int Sum(IEnumerable<CourseEmailCountRow> rows, params string[] statuses) =>
            rows.Where(r => statuses.Contains(r.Status)).Sum(r => r.Count);

        private int MaxPerMinute() =>
            int.TryParse(_configuration["CourseEmails:MaxPerMinute"], out var value) && value > 0
                ? Math.Min(value, 30)
                : CourseEmailConstants.DefaultMaxPerMinute;
    }
}
```

### `Common/ResponseConstants/ApiResponseConstants.cs` ✏️

```csharp
public const string GetCourseEmailsErrorMessage = "No se pudo cargar el estado de los correos.";
public const string RetryCourseEmailsErrorMessage = "No se pudieron reintentar los correos.";
```

### `Controllers/CourseEmailsController.cs`

```csharp
using DOCCB.Application.Features.CourseEmails.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Estado de los correos de cursos que se envían en segundo plano.</summary>
    [ApiController]
    [Route("api/course-emails")]
    [Authorize]
    public class CourseEmailsController(ICourseEmailStatusService statusService) : ControllerBase
    {
        private readonly ICourseEmailStatusService _statusService = statusService;

        /// <summary>Cursos con correos en cola o con error.</summary>
        [HttpGet("active")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetActive(CancellationToken ct)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _statusService.GetActiveAsync(ct));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GetCourseEmailsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GetCourseEmailsErrorMessage });
            }
        }

        [HttpGet("courses/{courseId:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetCourseStatus(int courseId, CancellationToken ct)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _statusService.GetCourseStatusAsync(courseId, ct));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GetCourseEmailsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GetCourseEmailsErrorMessage });
            }
        }

        /// <summary>Los que fallaron vuelven a la cola.</summary>
        [HttpPost("courses/{courseId:int}/retry")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> RetryFailed(int courseId, CancellationToken ct)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(await _statusService.RetryFailedAsync(courseId, ct));
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.RetryCourseEmailsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.RetryCourseEmailsErrorMessage });
            }
        }
    }
}
```

---

## 14. Paso 10 — Registro, configuración y despliegue

### Registro

`ApplicationServiceRegistration.cs` — quita `ICourseNotificationService` y agrega:

```csharp
services.AddSingleton<ICourseEmailQueueSignal, CourseEmailQueueSignal>();
services.AddScoped<ICourseEmailDispatcher, CourseEmailDispatcher>();
services.AddScoped<ICourseEmailStatusService, CourseEmailStatusService>();
// Un composer por tipo de correo. El dispatcher recibe todos (IEnumerable<ICourseEmailComposer>).
services.AddScoped<ICourseEmailComposer, CourseAssignedEmailComposer>();
```

`InfrastructureServiceRegistration.cs`, después de `ICourseCompletionRepository`:

```csharp
services.AddScoped<ICourseEmailQueueRepository, CourseEmailQueueRepository>();
```

`Program.cs`, después de `AddApplicationServices`:

```csharp
builder.Services.AddHostedService<CourseEmailWorker>();
```

### `appsettings.json` ✏️

```json
"CourseEmails": {
  "WorkerEnabled": true,
  "MaxPerMinute": 25,
  "PollSeconds": 30,
  "RetentionDays": 60
}
```

> **En desarrollo:** con `"WorkerEnabled": false` en `appsettings.Development.json`, los correos quedan en `PENDING` y puedes revisar la cola sin enviar nada. Cámbialo a `true` cuando quieras probar el envío.

### Despliegue — que el proceso no se duerma

Un `BackgroundService` vive mientras viva la aplicación. Si el servidor la apaga por inactividad, el envío se detiene hasta la siguiente petición. **No se pierde nada** (la cola está en la base), pero se demora.

| Dónde corre la API | Qué configurar |
|---|---|
| **Azure App Service** | *Configuration › General settings › Always On* = **On**. |
| **IIS** | En el app pool: *Start Mode* = `AlwaysRunning` e *Idle Time-out* = `0`. En el sitio: *Preload Enabled* = `True` (requiere la característica *Application Initialization*). |

> **Varias instancias:** el reclamo atómico evita enviar dos veces, pero el ritmo es por instancia y Exchange cuenta por buzón. Con más de una instancia, deja `WorkerEnabled: true` solo en una, o divide `MaxPerMinute` entre las instancias.

---

## 15. Contrato

Base `/api/course-emails`. Respuestas `{ response, hasError, errors }`.

| Método | Ruta | Respuesta |
|---|---|---|
| `GET` | `/active` | `[{ courseId, pending, failed }]`: solo cursos con correos en cola o con error |
| `GET` | `/courses/{courseId}` | `CourseEmailStatusDto` (abajo) |
| `POST` | `/courses/{courseId}/retry` | Cuántos volvieron a la cola |

```json
{
  "courseId": 12,
  "pending": 178, "sent": 120, "failed": 2, "skipped": 0,
  "estimatedMinutes": 8,
  "assignments": [
    {
      "assignmentId": 45, "groupName": "Operaciones turno A", "dueDate": "2026-11-15",
      "types": [ { "alertType": "COURSE_ASSIGNED", "pending": 178, "sent": 120, "failed": 2, "skipped": 0 } ]
    }
  ],
  "failedItems": [
    { "id": 9812, "alertType": "COURSE_ASSIGNED", "assignmentId": 45, "name": "Ana Pérez", "email": "ana.perez@empresa.co",
      "error": "No se pudo enviar el correo. Intenta de nuevo más tarde.", "attempts": 5, "lastAttemptDate": "2026-10-21T15:42:10" }
  ]
}
```

**Cambios en `/api/courses`:**
- `POST`, `PUT /{id}` y `POST /{id}/assignments/{assignmentId}/sync` agregan `queuedEmails` a su respuesta.
- Responden en cuanto se guarda, sin esperar los correos.

---

## 16. Pruebas

**Asignar**
- **Grupo de 300 personas:**
  - La respuesta llega en uno o dos segundos con `queuedEmails: 300`.
  - En `course_email_queue` quedan 300 filas `PENDING` con `assignment_user_id` lleno.
  - El envío empieza enseguida (la señal) y avanza unos 25 por minuto.
  - `GET /courses/{id}` muestra `pending` bajando y `sent` subiendo.
- **Una validación falla** (por ejemplo, grupo y fecha repetidos): no queda ni la asignación ni sus filas en la cola.
- **"Actualizar desde el grupo" con 3 personas nuevas:** `queuedEmails: 3`.

**El proceso**
- **Reiniciar la API a mitad del envío:** al arrancar sigue con los `PENDING`. Un `SENDING` abandonado vuelve a salir a los 5 minutos.
- **Error de envío** (por ejemplo, renombra la plantilla):
  - Cada correo se reintenta a los 1, 5, 15 y 60 minutos y queda `FAILED`.
  - En "Registro de correos" queda un solo `FAILED` por correo, no uno por intento.
  - Corrige la plantilla y llama `POST /courses/{id}/retry`: salen.
- **La persona sale del grupo antes de que salga su correo:** su fila se borra con ella y no se envía.
- **El curso se elimina con correos en cola:** quedan `SKIPPED` con "El curso fue eliminado.".
- **`WorkerEnabled: false`:** las filas se quedan en `PENDING`. Al ponerlo en `true` y reiniciar, salen.
- **Dos instancias con el proceso activo:** ningún correo sale dos veces.

**Rendimiento**
- **Un correo ya no pide token:** en el log de la API desaparece "Solicitando token de acceso para Microsoft Graph" en cada envío.
- **Ritmo:** con `MaxPerMinute: 25`, entre un envío y el siguiente pasan unos 2,4 segundos.

---

## ✅ Checklist

- [ ] `CourseEmailQueue.sql`.
- [ ] `CourseEmailQueueItem`, su configuración y el `DbSet`.
- [ ] Constantes, DTOs, `CourseEmailQueueFactory` y los contratos (`ICourseEmailComposer`, `ICourseEmailQueueSignal`, `ICourseEmailDispatcher`, `ICourseEmailStatusService`).
- [ ] `ICourseRepository.QueueEmails` + `CourseRepository`.
- [ ] `CourseService`:
  - Encola la bienvenida y avisa a la señal.
  - `QueuedEmails` en los resultados.
  - Sin los `NotifyAssignedAsync`.
- [ ] Borrados: `CourseNotificationService`, su interfaz, `CourseAssignedNotification` y su registro.
- [ ] `CourseAssignedEmailComposer`.
- [ ] `MailNotificationService`: `GraphServiceClient` compartido y `cc`.
- [ ] `ICourseEmailQueueRepository` + `CourseEmailQueueRepository`.
- [ ] `CourseEmailDispatcher` y `CourseEmailWorker`.
- [ ] `CourseEmailStatusService`, `CourseEmailsController` y `ApiResponseConstants`.
- [ ] Registros, `appsettings`, `AddHostedService`.
- [ ] Always On (Azure) o `AlwaysRunning` + Preload (IIS).
