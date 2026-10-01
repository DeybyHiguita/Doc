# 📧 Log de envío de correos — API (.NET 8) y SQL Server

Guía para guardar un registro de cada correo que envía DOCCB: qué alerta era, a quién se envió, cuándo y si salió bien.

- **Registrar envíos:** interno. `IEmailAlertLogService` no tiene controlador: lo usan otros servicios (cursos, solicitudes, recordatorios…) cada vez que envían un correo.
- **Consultar envíos:** un endpoint de **solo lectura** para la pantalla "Registro de correos" ([registro-correos-angular.md](registro-correos-angular.md)). Ver la sección 11.
- **Tablas:** `dbo.email_alert_log` y `dbo.email_alert_recipient` (ya creadas).
- **Estilo:** el de Request: `ITransactionExecutorHelper` + `unitOfWork.Repository<T>()`. Ver la sección 1.
- **Stack:** .NET 8 · EF Core 8 · SQL Server

---

## 1. 🧭 ¿Repositorio propio o repositorio genérico?

La regla del proyecto ([ARQUITECTURA Y EJEMPLO](.claude/ARQUITECTURA%20Y%20EJEMPLO.MD), sección 5): **por defecto, repositorio genérico**. Un repositorio específico solo si se cumple alguna de las condiciones de esta tabla.

| Condición para un repositorio específico | ¿Se cumple aquí? |
|---|---|
| Proyecciones con cálculos o agregados en SQL | No. Se inserta un registro y sus destinatarios. |
| `GroupBy`, subconsultas, `AsSplitQuery`, orden calculado | No. |
| Traducir errores de SQL a reglas de negocio | No. Un fallo al guardar el log no se traduce: se registra en el logger y no detiene a nadie. |
| La misma consulta compleja en varios servicios | No. Todos llaman a **un servicio**, no a una consulta. |
| Consulta sensible a privacidad o rendimiento | No. |
| Grafo de entidades a modificar juntas | Un log con su lista de destinatarios, que `AddAsync` guarda junto en un solo `SaveChanges` gracias a la navegación. |

**Decisión: sin repositorio.** El servicio usa `unitOfWork.Repository<EmailAlertLog>()`.

La reutilización entre features la da el **servicio** (`IEmailAlertLogService`), no un repositorio. Por eso no hay archivos en `Contracts/Persistence` ni en `Repositories`.

### Lo que sí hay en Infraestructura

| Qué | Dónde |
|---|---|
| Dos configuraciones EF | `Configurations/EmailAlertLogConfiguration.cs`, `Configurations/EmailAlertRecipientConfiguration.cs` |
| Registro | Nada: `ApplyConfigurationsFromAssembly` carga las configuraciones solo |

---

## 2. 🧐 Revisión crítica

| # | Tema | Decisión |
|---|---|---|
| 1 | **El log nunca debe romper el proceso que envía el correo.** Si el correo salió y falla el `INSERT` del log, el usuario no debe ver un error. | El servicio atrapa cualquier error al guardar el log, lo escribe en `ILogger` y sigue. |
| 2 | **Un correo enviado no se puede "deshacer".** Si el log se guardara dentro de la transacción del proceso que llama y esa transacción fallara, se perdería el registro de un correo que sí salió. | `ITransactionExecutorHelper` crea su **propio `DbContext` y su propia transacción** en cada llamada. El log queda guardado aunque el proceso que llamó haga rollback. |
| 3 | **Enviar dentro de una transacción de negocio.** Si se envía el correo y luego la transacción del negocio falla, la persona recibe un correo por algo que no quedó guardado. | Se envía **después** de guardar el negocio (ejemplo en la sección 8). |
| 4 | **`error_message` es `NVARCHAR(MAX)`.** Guardar la excepción completa (con la traza) llena la tabla y puede exponer datos. | Solo `ex.Message`, recortado a 2.000 caracteres. La traza completa va al `ILogger`. |
| 5 | **Valores libres en `alert_type` y `send_status`.** Un error de tipeo ("SEND" en vez de "SENT") rompe los reportes. | Constantes en código (`EmailAlertTypes`, `EmailAlertStatus`). Opcional: un `CHECK` en `send_status` (sección 3). |
| 6 | **Destinatarios repetidos o vacíos.** | Se normalizan: sin espacios, en minúsculas, sin repetidos, sin vacíos y de 320 caracteres o menos. Sin destinatarios válidos, no se envía. |
| 7 | **⚠️ La llave a `course_assignment` es `ON DELETE NO ACTION`.** El editor de cursos permite quitar una asignación sin formularios diligenciados. Si esa asignación ya tiene correos en el log, el `DELETE` falla con el error `547`. | Cambiar la llave a `ON DELETE SET NULL`: el log del correo se conserva y deja de apuntar a una asignación que ya no existe. Script en la sección 3. |
| 8 | **"¿Ya se envió este recordatorio?"** Útil para no mandar el mismo correo dos veces. | `WasSentAsync(alertType, assignmentId)`. Para que sea rápido, un índice compuesto `(assignment_id, alert_type, send_status)` (sección 3). |
| 9 | **Crecimiento y datos personales.** Cada correo guarda direcciones de personas. | Definan cuánto tiempo se guarda (por ejemplo, 12 meses) y una tarea de limpieza. No hace parte de esta guía. |
| 10 | **`BaseEntity`.** Agrega `CreatedDate` y `UpdatedDate`, y estas tablas no tienen esas columnas. | Las entidades **no** heredan `BaseEntity`. |

---

## 3. 🗄️ Base de datos

Las tablas ya existen:

```text
dbo.course_assignment (id) ◄──── dbo.email_alert_log ──< dbo.email_alert_recipient
                           NULL    id                      id
                                   alert_type              email_alert_log_id (CASCADE)
                                   assignment_id NULL      email
                                   sent_date
                                   send_status
                                   error_message
```

### `Persistence/Scripts SQL/EmailAlertLog-ajustes.sql` — recomendado

```sql
/* =====================================================================
   Log de correos — ajustes sobre las tablas ya creadas
   Base de datos: DB · Esquema: dbo
   ===================================================================== */
USE [DB];
GO

/* 1. Quitar una asignación no debe fallar porque tenga correos registrados.
      El log se conserva y assignment_id queda en NULL. */
IF EXISTS (SELECT 1 FROM sys.foreign_keys
           WHERE name = N'fk_email_alert_log_course_assignment'
             AND delete_referential_action_desc = N'NO_ACTION')
BEGIN
    ALTER TABLE dbo.email_alert_log DROP CONSTRAINT fk_email_alert_log_course_assignment;

    ALTER TABLE dbo.email_alert_log
        ADD CONSTRAINT fk_email_alert_log_course_assignment
        FOREIGN KEY (assignment_id) REFERENCES dbo.course_assignment (id)
        ON DELETE SET NULL;
END;
GO

/* 2. "¿Ya se envió esta alerta para esta asignación?" en una sola búsqueda.
      Reemplaza a ix_email_alert_log_assignment_id, que queda cubierto por este. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.email_alert_log') AND name = N'ix_email_alert_log_assignment_type_status')
    CREATE INDEX ix_email_alert_log_assignment_type_status
        ON dbo.email_alert_log (assignment_id, alert_type, send_status)
        INCLUDE (sent_date);

IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.email_alert_log') AND name = N'ix_email_alert_log_assignment_id')
    DROP INDEX ix_email_alert_log_assignment_id ON dbo.email_alert_log;
GO

/* 3. Opcional: solo estados conocidos. */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_email_alert_log_send_status')
    ALTER TABLE dbo.email_alert_log
        ADD CONSTRAINT ck_email_alert_log_send_status CHECK (send_status IN ('SENT', 'FAILED'));
GO
```

> `ix_email_alert_log_alert_type` sirve para reportes por tipo ("¿cuántos recordatorios fallaron este mes?"). Si no hay reportes así, se puede quitar: un índice sobre una columna con pocos valores distintos casi no ayuda.

---

## 4. 📁 Archivos

```text
DOCCB.Domain/Entities/
├── EmailAlertLog.cs
└── EmailAlertRecipient.cs

DOCCB.Application/Features/EmailAlerts/Application/
├── Constants/
│   ├── EmailAlertTypes.cs                ⭐ tipos de alerta
│   └── EmailAlertStatus.cs               SENT / FAILED
├── DTOs/EmailAlertSend.cs                lo que recibe el servicio
├── Helpers/EmailRecipientNormalizer.cs
├── Interfaces/IEmailAlertLogService.cs
└── Services/EmailAlertLogService.cs      ⭐ envía y registra

DOCCB.Infraestructure/Configurations/
├── EmailAlertLogConfiguration.cs
└── EmailAlertRecipientConfiguration.cs

ApplicationServiceRegistration.cs         (+1 línea)
```

Sin controlador, sin repositorio y sin cambios en `InfrastructureServiceRegistration.cs`.

---

## 5. Paso 1 — Dominio

### `Entities/EmailAlertLog.cs`

```csharp
namespace DOCCB.Domain.Entities;

/// <summary>Un envío de correo: una alerta, sus destinatarios y el resultado.</summary>
/// <remarks>No hereda BaseEntity: la tabla no tiene created_date ni updated_date.</remarks>
public class EmailAlertLog
{
    public int Id { get; set; }
    public string AlertType { get; set; } = string.Empty;

    /// <summary>Asignación de curso relacionada. null para alertas que no son de cursos.</summary>
    public int? AssignmentId { get; set; }

    public DateTime SentDate { get; set; }
    public string SendStatus { get; set; } = string.Empty;
    public string? ErrorMessage { get; set; }

    public ICollection<EmailAlertRecipient> Recipients { get; set; } = new List<EmailAlertRecipient>();
}
```

### `Entities/EmailAlertRecipient.cs`

```csharp
namespace DOCCB.Domain.Entities;

public class EmailAlertRecipient
{
    public int Id { get; set; }
    public int EmailAlertLogId { get; set; }
    public string Email { get; set; } = string.Empty;

    public EmailAlertLog EmailAlertLog { get; set; } = null!;
}
```

> `EmailAlertLog` no tiene navegación a `CourseAssignment`, a propósito: el log es transversal y no debe arrastrar la feature de cursos. La llave sí se declara en la configuración.

---

## 6. Paso 2 — Configuración de EF Core

### `Configurations/EmailAlertLogConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class EmailAlertLogConfiguration : IEntityTypeConfiguration<EmailAlertLog>
{
    public void Configure(EntityTypeBuilder<EmailAlertLog> builder)
    {
        builder.ToTable("email_alert_log", "dbo");

        builder.HasKey(l => l.Id).HasName("pk_email_alert_log");

        builder.Property(l => l.Id).HasColumnName("id");
        builder.Property(l => l.AlertType).HasColumnName("alert_type").HasMaxLength(100).IsUnicode(false).IsRequired();
        builder.Property(l => l.AssignmentId).HasColumnName("assignment_id");
        builder.Property(l => l.SentDate)
            .HasColumnName("sent_date")
            .HasColumnType("datetime2(0)")
            .HasDefaultValueSql("SYSUTCDATETIME()");
        builder.Property(l => l.SendStatus).HasColumnName("send_status").HasMaxLength(30).IsUnicode(false).IsRequired();
        builder.Property(l => l.ErrorMessage).HasColumnName("error_message");

        builder.HasIndex(l => new { l.AssignmentId, l.AlertType, l.SendStatus })
            .HasDatabaseName("ix_email_alert_log_assignment_type_status");
        builder.HasIndex(l => l.AlertType).HasDatabaseName("ix_email_alert_log_alert_type");
        builder.HasIndex(l => l.SentDate).HasDatabaseName("ix_email_alert_log_sent_date");

        builder.HasMany(l => l.Recipients)
            .WithOne(r => r.EmailAlertLog)
            .HasForeignKey(r => r.EmailAlertLogId)
            .HasConstraintName("fk_email_alert_recipient_email_alert_log")
            .OnDelete(DeleteBehavior.Cascade);

        // Sin navegación: solo la llave. SetNull coincide con el ajuste de la sección 3.
        builder.HasOne<CourseAssignment>()
            .WithMany()
            .HasForeignKey(l => l.AssignmentId)
            .HasConstraintName("fk_email_alert_log_course_assignment")
            .OnDelete(DeleteBehavior.SetNull);
    }
}
```

> Si no ejecutas el ajuste de la llave, cambia `DeleteBehavior.SetNull` por `DeleteBehavior.NoAction` para que el modelo coincida con la base de datos.

### `Configurations/EmailAlertRecipientConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class EmailAlertRecipientConfiguration : IEntityTypeConfiguration<EmailAlertRecipient>
{
    public void Configure(EntityTypeBuilder<EmailAlertRecipient> builder)
    {
        builder.ToTable("email_alert_recipient", "dbo");

        builder.HasKey(r => r.Id).HasName("pk_email_alert_recipient");

        builder.Property(r => r.Id).HasColumnName("id");
        builder.Property(r => r.EmailAlertLogId).HasColumnName("email_alert_log_id");
        builder.Property(r => r.Email).HasColumnName("email").HasMaxLength(320).IsUnicode(false).IsRequired();

        builder.HasIndex(r => r.Email).HasDatabaseName("ix_email_alert_recipient_email");
    }
}
```

No hace falta registrarlas en el `DbContext`: `ApplyConfigurationsFromAssembly` las encuentra solas.

---

## 7. Paso 3 — Aplicación

### `Constants/EmailAlertTypes.cs`

Un valor por cada correo que envía el sistema. Agrega aquí los nuevos; nunca escribas el texto suelto en un servicio.

```csharp
namespace DOCCB.Application.Features.EmailAlerts.Application.Constants;

public static class EmailAlertTypes
{
    // Cursos
    public const string CourseAssigned = "COURSE_ASSIGNED";
    public const string CourseDueReminder = "COURSE_DUE_REMINDER";
    public const string CourseOverdue = "COURSE_OVERDUE";

    // Solicitudes (ejemplo)
    public const string RequestShared = "REQUEST_SHARED";

    // Agrega los de otras features aquí (máximo 100 caracteres).
}
```

### `Constants/EmailAlertStatus.cs`

```csharp
namespace DOCCB.Application.Features.EmailAlerts.Application.Constants;

public static class EmailAlertStatus
{
    public const string Sent = "SENT";
    public const string Failed = "FAILED";
}
```

### `DTOs/EmailAlertSend.cs`

```csharp
namespace DOCCB.Application.Features.EmailAlerts.Application.DTOs;

/// <summary>Qué alerta se envía, de qué asignación (si aplica) y a quién.</summary>
public sealed record EmailAlertSend(string AlertType, int? AssignmentId, IReadOnlyCollection<string> Recipients);
```

### `Helpers/EmailRecipientNormalizer.cs`

```csharp
namespace DOCCB.Application.Features.EmailAlerts.Application.Helpers;

public static class EmailRecipientNormalizer
{
    public const int MaxLength = 320; // largo de la columna email

    /// <summary>Sin espacios, en minúsculas, sin repetidos, sin vacíos y dentro del largo de la columna.</summary>
    public static List<string> Normalize(IEnumerable<string?> emails) =>
        emails
            .Select(email => email?.Trim().ToLowerInvariant())
            .Where(email => !string.IsNullOrEmpty(email) && email.Length <= MaxLength && email.Contains('@'))
            .Select(email => email!)
            .Distinct()
            .ToList();
}
```

### `Interfaces/IEmailAlertLogService.cs`

```csharp
using DOCCB.Application.Features.EmailAlerts.Application.DTOs;

namespace DOCCB.Application.Features.EmailAlerts.Application.Interfaces;

/// <summary>Uso interno: lo inyectan los servicios que envían correos. No tiene controlador.</summary>
public interface IEmailAlertLogService
{
    /// <summary>
    /// Ejecuta el envío y registra el resultado (SENT o FAILED).
    /// true si el correo salió. Nunca lanza por un fallo del envío ni del log: los deja en el logger.
    /// </summary>
    Task<bool> SendAndLogAsync(EmailAlertSend alert, Func<IReadOnlyList<string>, Task> send);

    /// <summary>Registra un envío hecho por otro medio. No lanza si falla el guardado.</summary>
    Task RegisterAsync(EmailAlertSend alert, string status, string? errorMessage = null);

    /// <summary>¿Ya salió con éxito esta alerta para esta asignación? Para no repetir recordatorios.</summary>
    Task<bool> WasSentAsync(string alertType, int assignmentId);
}
```

### `Services/EmailAlertLogService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.EmailAlerts.Application.Constants;
using DOCCB.Application.Features.EmailAlerts.Application.DTOs;
using DOCCB.Application.Features.EmailAlerts.Application.Helpers;
using DOCCB.Application.Features.EmailAlerts.Application.Interfaces;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.EmailAlerts.Application.Services;

public class EmailAlertLogService(
    ITransactionExecutorHelper transactionHelper,
    TimeProvider timeProvider,
    ILogger<EmailAlertLogService> logger) : IEmailAlertLogService
{
    private const int MaxErrorLength = 2000;

    public async Task<bool> SendAndLogAsync(EmailAlertSend alert, Func<IReadOnlyList<string>, Task> send)
    {
        var recipients = EmailRecipientNormalizer.Normalize(alert.Recipients);
        if (recipients.Count == 0)
        {
            logger.LogWarning("Alerta {AlertType} sin destinatarios válidos; no se envió.", alert.AlertType);
            return false;
        }

        string status;
        string? error = null;

        try
        {
            await send(recipients);
            status = EmailAlertStatus.Sent;
        }
        catch (OperationCanceledException)
        {
            throw; // la petición se canceló: no es un fallo del correo
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Falló el envío de la alerta {AlertType} (asignación {AssignmentId}).", alert.AlertType, alert.AssignmentId);
            status = EmailAlertStatus.Failed;
            error = ex.Message;
        }

        await SaveAsync(alert with { Recipients = recipients }, status, error);
        return status == EmailAlertStatus.Sent;
    }

    public Task RegisterAsync(EmailAlertSend alert, string status, string? errorMessage = null) =>
        SaveAsync(alert with { Recipients = EmailRecipientNormalizer.Normalize(alert.Recipients) }, status, errorMessage);

    public async Task<bool> WasSentAsync(string alertType, int assignmentId) =>
        await transactionHelper.ExecuteQueryAsync<bool>(unitOfWork =>
            unitOfWork.Repository<EmailAlertLog>().AnyAsync(log =>
                log.AssignmentId == assignmentId &&
                log.AlertType == alertType &&
                log.SendStatus == EmailAlertStatus.Sent));

    // ── Privado ─────────────────────────────────────────────────────

    /// <summary>
    /// El helper usa su propio DbContext y su propia transacción: el log queda guardado
    /// aunque el proceso que envió el correo haga rollback de lo suyo.
    /// </summary>
    private async Task SaveAsync(EmailAlertSend alert, string status, string? errorMessage)
    {
        var log = new EmailAlertLog
        {
            AlertType = alert.AlertType,
            AssignmentId = alert.AssignmentId,
            SentDate = timeProvider.GetUtcNow().UtcDateTime,
            SendStatus = status,
            ErrorMessage = Truncate(errorMessage),
            Recipients = alert.Recipients.Select(email => new EmailAlertRecipient { Email = email }).ToList(),
        };

        try
        {
            await transactionHelper.ExecuteWithTransactionAsync<bool>(async unitOfWork =>
            {
                // Un solo AddAsync: EF inserta el log y sus destinatarios en el mismo SaveChanges.
                await unitOfWork.Repository<EmailAlertLog>().AddAsync(log);
                return true;
            });
        }
        catch (Exception ex)
        {
            // El correo ya se envió (o ya falló): no rompas el proceso de negocio por el log.
            logger.LogError(ex, "No se pudo guardar el log de la alerta {AlertType} con estado {Status}.", alert.AlertType, status);
        }
    }

    private static string? Truncate(string? value) =>
        string.IsNullOrEmpty(value) || value.Length <= MaxErrorLength ? value : value[..MaxErrorLength];
}
```

> **Firmas supuestas.** La guía de arquitectura muestra `ExecuteWithTransactionAsync<TResult>(Func<IUnitOfWork, Task<TResult?>>)` y lista `AnyAsync` en `GenericRepository<T>`. Si `ExecuteQueryAsync` o `AnyAsync` tienen otra firma, ajusta solo esas dos llamadas.
>
> `TimeProvider` ya está registrado desde las guías de cursos. Si no, agrega `services.AddSingleton(TimeProvider.System);`.

---

## 8. Paso 4 — Registro y uso desde otros servicios

### `ApplicationServiceRegistration.cs`

```csharp
services.AddScoped<IEmailAlertLogService, EmailAlertLogService>();
```

Nada en `InfrastructureServiceRegistration.cs`: el repositorio genérico, el Unit of Work y la fábrica ya están registrados.

### Ejemplo: avisar a los integrantes de una asignación nueva

En `CourseService`, **después** de guardar el curso, para no enviar correos por asignaciones que no quedaron guardadas:

```csharp
public class CourseService(
    ICourseRepository repository,
    IEmailAlertLogService emailAlerts,
    IEmailService emailService,          // ⬅ tu servicio actual de envío de correos
    /* … */) : ICourseService
{
    // … dentro de CreateAsync / UpdateAsync, cuando TrySaveAsync ya terminó bien:
    foreach (var assignment in newAssignments)
    {
        // Correos de las personas de la asignación (assignment.Users → User.CorportativeEmail).
        var emails = assignment.Users.Select(u => u.User.CorportativeEmail ?? string.Empty).ToList();

        await emailAlerts.SendAndLogAsync(
            new EmailAlertSend(EmailAlertTypes.CourseAssigned, assignment.Id, emails),
            recipients => emailService.SendAsync(
                recipients,
                subject: $"Tienes un curso asignado: {course.Name}",
                body: BuildAssignedBody(course, assignment)));
    }
}
```

- Para tener `u.User` cargado, trae las personas con su usuario al guardar, o consulta los correos después con una proyección.
- `send` recibe los destinatarios **ya normalizados**: usa esa lista, no la original.
- Si el envío falla, `SendAndLogAsync` devuelve `false` y deja el log en `FAILED`. Decide en el servicio si eso cambia la respuesta al usuario (normalmente no: el curso sí quedó guardado).

### Ejemplo: recordatorio sin repetir

```csharp
if (await emailAlerts.WasSentAsync(EmailAlertTypes.CourseDueReminder, assignment.Id))
    return; // ya se envió con éxito

await emailAlerts.SendAndLogAsync(
    new EmailAlertSend(EmailAlertTypes.CourseDueReminder, assignment.Id, pendingEmails),
    recipients => emailService.SendAsync(recipients, subject, body));
```

### Ejemplo: alerta que no es de cursos

```csharp
await emailAlerts.SendAndLogAsync(
    new EmailAlertSend(EmailAlertTypes.RequestShared, AssignmentId: null, [ownerEmail]),
    recipients => emailService.SendAsync(recipients, subject, body));
```

---

## 9. Consultas útiles

```sql
-- Últimos envíos con sus destinatarios
SELECT TOP (50) l.id, l.alert_type, l.assignment_id, l.sent_date, l.send_status, l.error_message,
       recipients = STRING_AGG(r.email, ', ')
FROM   dbo.email_alert_log l
LEFT JOIN dbo.email_alert_recipient r ON r.email_alert_log_id = l.id
GROUP BY l.id, l.alert_type, l.assignment_id, l.sent_date, l.send_status, l.error_message
ORDER BY l.sent_date DESC;

-- Fallos por tipo en los últimos 30 días
SELECT alert_type, failed = COUNT(*)
FROM   dbo.email_alert_log
WHERE  send_status = 'FAILED' AND sent_date >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY alert_type;

-- Correos que recibió una persona
SELECT l.alert_type, l.sent_date, l.send_status
FROM   dbo.email_alert_recipient r
JOIN   dbo.email_alert_log l ON l.id = r.email_alert_log_id
WHERE  r.email = 'persona@empresa.com'
ORDER BY l.sent_date DESC;
```

---

## 10. Pruebas

- Envío correcto → una fila `SENT` en `email_alert_log`, `error_message` en `NULL`, una fila por destinatario.
- El envío lanza una excepción → fila `FAILED` con el mensaje recortado; `SendAndLogAsync` devuelve `false` y no lanza.
- Destinatarios `[" Ana@Empresa.com ", "ana@empresa.com", "", null]` → una sola fila `ana@empresa.com`.
- Sin destinatarios válidos → no llama a `send` ni guarda log; devuelve `false`.
- La base de datos no responde al guardar el log → el proceso que llamó termina igual; el error queda en el logger.
- `WasSentAsync` → `true` solo si hay un `SENT`; un `FAILED` no cuenta.
- Quitar una asignación sin formularios que tiene correos registrados (con el ajuste de la sección 3) → se borra; el log queda con `assignment_id = NULL`.

---

## 11. Consulta para la pantalla "Registro de correos"

La pantalla filtra por **tipo de alerta**, **nombre** del destinatario y **correo** del destinatario. Cada fila es **un correo recibido por una persona**: si una alerta se envió a 40 personas, son 40 filas. Así, al filtrar por una persona, se ve exactamente lo que le llegó a ella.

### ¿Repositorio propio? Sí, solo para leer

| Condición | ¿Se cumple? |
|---|---|
| Proyección con datos de varias tablas | Sí: destinatario + log + nombre desde `dbo.users`. |
| Subconsultas | Sí: `email_alert_recipient` no guarda el nombre y no tiene llave hacia `dbo.users`. El nombre se busca por `users.corporative_email`, y el repositorio genérico no tiene cómo cruzar dos tablas sin relación. |
| Paginación con total y orden propio | Sí. |

El registro de envíos (secciones 7 y 8) **sigue** con el repositorio genérico. Este repositorio es de solo lectura: no abre transacciones ni guarda nada, y el servicio sigue devolviendo `ResponseDto<T>` como el resto de la feature.

> **Nombre al momento del envío (opcional).** Como el nombre sale de `dbo.users`, una persona que no está en el maestro aparece solo con su correo, y si alguien cambia de nombre se ve el nombre actual. Si eso importa, agrega `display_name NVARCHAR(256) NULL` a `email_alert_recipient` y llénalo al enviar: la consulta queda más simple y no depende del maestro.

### Archivos

```text
DOCCB.Application/
├── Contracts/Persistence/IEmailAlertLogQueryRepository.cs        nuevo
└── Features/EmailAlerts/Application/
    ├── DTOs/EmailAlertLogQueryDtos.cs                           nuevo
    ├── Interfaces/IEmailAlertLogQueryService.cs                 nuevo
    └── Services/EmailAlertLogQueryService.cs                    nuevo

DOCCB.Infraestructure/Repositories/EmailAlertLogQueryRepository.cs   nuevo

Presentation/WebApp/Controllers/EmailAlertLogsController.cs     nuevo — solo GET
```

### `DTOs/EmailAlertLogQueryDtos.cs`

```csharp
namespace DOCCB.Application.Features.EmailAlerts.Application.DTOs;

/// <summary>Filtros que llegan por query string. Todos opcionales.</summary>
public class EmailAlertLogQueryDto
{
    public string? Type { get; set; }
    public string? Name { get; set; }
    public string? Email { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 20;
}

/// <summary>Filtros ya normalizados por el servicio.</summary>
public sealed record EmailAlertLogFilter(string? Type, string? Name, string? Email, int Page, int PageSize);

/// <summary>Un correo recibido por una persona.</summary>
public class EmailAlertLogItemDto
{
    public int RecipientId { get; set; }
    public int LogId { get; set; }
    public string AlertType { get; set; } = string.Empty;
    public int? AssignmentId { get; set; }
    public DateTime SentDate { get; set; }
    public string SendStatus { get; set; } = string.Empty;
    public string? ErrorMessage { get; set; }
    public string RecipientEmail { get; set; } = string.Empty;
    /// <summary>De dbo.users. null si la persona no está en el maestro.</summary>
    public string? RecipientName { get; set; }
}

public class EmailAlertLogPageDto
{
    public List<EmailAlertLogItemDto> Items { get; set; } = [];
    public int TotalCount { get; set; }
}
```

### `Contracts/Persistence/IEmailAlertLogQueryRepository.cs`

```csharp
using DOCCB.Application.Features.EmailAlerts.Application.DTOs;

namespace DOCCB.Application.Contracts.Persistence;

/// <summary>Solo lectura: consultas de la pantalla "Registro de correos".</summary>
public interface IEmailAlertLogQueryRepository
{
    Task<EmailAlertLogPageDto> GetPageAsync(EmailAlertLogFilter filter, CancellationToken ct);

    /// <summary>Tipos de alerta que existen en el log, para el filtro.</summary>
    Task<List<string>> GetAlertTypesAsync(CancellationToken ct);
}
```

### `Repositories/EmailAlertLogQueryRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.EmailAlerts.Application.DTOs;
using DOCCB.Domain.Entities;
using DOCCB.Infraestructure.Common;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Infraestructure.Repositories;

/// <summary>Tabla principal: email_alert_recipient (una fila por persona). Solo lectura.</summary>
public class EmailAlertLogQueryRepository(DOCCbDbContext context)
    : GenericRepositoryBase<DOCCbDbContext, EmailAlertRecipient>(context), IEmailAlertLogQueryRepository
{
    public Task<EmailAlertLogPageDto> GetPageAsync(EmailAlertLogFilter filter, CancellationToken ct) =>
        Guard(() => BuildPageAsync(filter, ct));

    public Task<List<string>> GetAlertTypesAsync(CancellationToken ct) =>
        Guard(() => _context.Set<EmailAlertLog>()
            .AsNoTracking()
            .Select(log => log.AlertType)
            .Distinct()
            .OrderBy(type => type)
            .ToListAsync(ct)); // usa ix_email_alert_log_alert_type

    private async Task<EmailAlertLogPageDto> BuildPageAsync(EmailAlertLogFilter filter, CancellationToken ct)
    {
        var users = _context.Set<User>().AsNoTracking();
        var recipients = _dbSet.AsNoTracking();

        if (filter.Type is { } type)
            recipients = recipients.Where(r => r.EmailAlertLog.AlertType == type);

        // "Empieza por": aprovecha ix_email_alert_recipient_email. Un correo completo también coincide.
        if (filter.Email is { } email)
            recipients = recipients.Where(r => r.Email.StartsWith(email));

        // El nombre no está en la tabla: se busca en el maestro por el correo.
        if (filter.Name is { } name)
            recipients = recipients.Where(r => users.Any(u => u.CorportativeEmail == r.Email && u.DisplayName.Contains(name)));

        var total = await recipients.CountAsync(ct);

        var items = await recipients
            .OrderByDescending(r => r.EmailAlertLog.SentDate)
            .ThenByDescending(r => r.Id)
            .Skip((filter.Page - 1) * filter.PageSize)
            .Take(filter.PageSize)
            .Select(r => new EmailAlertLogItemDto
            {
                RecipientId = r.Id,
                LogId = r.EmailAlertLogId,
                AlertType = r.EmailAlertLog.AlertType,
                AssignmentId = r.EmailAlertLog.AssignmentId,
                SentDate = r.EmailAlertLog.SentDate,
                SendStatus = r.EmailAlertLog.SendStatus,
                ErrorMessage = r.EmailAlertLog.ErrorMessage,
                RecipientEmail = r.Email,
                // Subconsulta con TOP 1: si el maestro tuviera el correo repetido, no duplica filas.
                RecipientName = users
                    .Where(u => u.CorportativeEmail == r.Email)
                    .Select(u => u.DisplayName)
                    .FirstOrDefault(),
            })
            .ToListAsync(ct);

        return new EmailAlertLogPageDto { Items = items, TotalCount = total };
    }

    /// <summary>Convención de GenericRepositoryBase; la cancelación pasa sin envolver.</summary>
    private static async Task<TResult> Guard<TResult>(Func<Task<TResult>> action)
    {
        try
        {
            return await action();
        }
        catch (Exception ex) when (ex is not (OperationCanceledException or DbUpdateException or SqlException or TimeoutException))
        {
            throw new InvalidOperationException($"Error en el repositorio para la entidad {nameof(EmailAlertRecipient)}.", ex);
        }
    }
}
```

> `DisplayName` y `CorportativeEmail` son los nombres de la entidad `User` en tu código. Si el nombre está en otra propiedad, cámbialo en las dos líneas que lo usan.

### `Interfaces/IEmailAlertLogQueryService.cs`

```csharp
using DOCCB.Application.Features.EmailAlerts.Application.DTOs;

namespace DOCCB.Application.Features.EmailAlerts.Application.Interfaces;

public interface IEmailAlertLogQueryService
{
    Task<ResponseDto<EmailAlertLogPageDto>> GetPageAsync(EmailAlertLogQueryDto query, CancellationToken ct = default);
    Task<ResponseDto<List<string>>> GetAlertTypesAsync(CancellationToken ct = default);
}
```

### `Services/EmailAlertLogQueryService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.EmailAlerts.Application.DTOs;
using DOCCB.Application.Features.EmailAlerts.Application.Interfaces;

namespace DOCCB.Application.Features.EmailAlerts.Application.Services;

public class EmailAlertLogQueryService(IEmailAlertLogQueryRepository repository) : IEmailAlertLogQueryService
{
    private const int MaxTermLength = 100;

    public async Task<ResponseDto<EmailAlertLogPageDto>> GetPageAsync(EmailAlertLogQueryDto query, CancellationToken ct = default)
    {
        var filter = new EmailAlertLogFilter(
            Type: Clean(query.Type)?.ToUpperInvariant(),
            Name: Clean(query.Name),
            Email: Clean(query.Email)?.ToLowerInvariant(), // los destinatarios se guardan en minúsculas
            Page: Math.Max(1, query.Page),
            PageSize: Math.Clamp(query.PageSize, 1, 100));

        var page = await repository.GetPageAsync(filter, ct);
        return ResponseDtoHelper.CreateSuccessResponseDto(page);
    }

    public async Task<ResponseDto<List<string>>> GetAlertTypesAsync(CancellationToken ct = default) =>
        ResponseDtoHelper.CreateSuccessResponseDto(await repository.GetAlertTypesAsync(ct));

    /// <summary>Vacío = sin filtro. Recorta textos muy largos para no armar consultas costosas.</summary>
    private static string? Clean(string? value)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return null;
        return trimmed.Length > MaxTermLength ? trimmed[..MaxTermLength] : trimmed;
    }
}
```

### `Controllers/EmailAlertLogsController.cs`

Mismo estilo que `RequestController`: el servicio devuelve `ResponseDto<T>` y el controlador traduce excepciones a HTTP.

```csharp
using DOCCB.Application.Features.EmailAlerts.Application.DTOs;
using DOCCB.Application.Features.EmailAlerts.Application.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace WebApp.Controllers;

/// <summary>
/// Solo lectura. Muestra correos de personas: protégelo con el mismo permiso de administración
/// que usan tus otros controladores (⬇ agrega aquí tu atributo o política).
/// </summary>
[ApiController]
[Route("api/email-alert-logs")]
[Authorize]
public class EmailAlertLogsController(
    IEmailAlertLogQueryService service,
    ILogger<EmailAlertLogsController> logger) : ControllerBase
{
    /// <summary>GET api/email-alert-logs?type=&name=&email=&page=&pageSize=</summary>
    [HttpGet]
    public async Task<IActionResult> GetPage([FromQuery] EmailAlertLogQueryDto query, CancellationToken ct)
    {
        try
        {
            return Ok(await service.GetPageAsync(query, ct));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "Error consultando el registro de correos.");
            return StatusCode(StatusCodes.Status500InternalServerError, new { message = "No se pudo consultar el registro de correos." });
        }
    }

    [HttpGet("types")]
    public async Task<IActionResult> GetTypes(CancellationToken ct)
    {
        try
        {
            return Ok(await service.GetAlertTypesAsync(ct));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "Error consultando los tipos de alerta.");
            return StatusCode(StatusCodes.Status500InternalServerError, new { message = "No se pudieron consultar los tipos de alerta." });
        }
    }
}
```

### Registro

```csharp
// ApplicationServiceRegistration.cs
services.AddScoped<IEmailAlertLogQueryService, EmailAlertLogQueryService>();

// InfrastructureServiceRegistration.cs
services.AddScoped<IEmailAlertLogQueryRepository, EmailAlertLogQueryRepository>();
```

### Contrato

| Método | Ruta | Respuesta |
|---|---|---|
| `GET` | `/api/email-alert-logs?type=&name=&email=&page=1&pageSize=20` | `ResponseDto<{ items: [...], totalCount }>`, más recientes primero |
| `GET` | `/api/email-alert-logs/types` | `ResponseDto<string[]>` con los tipos que existen en el log |

### Pruebas de la consulta

- Sin filtros → todas las filas, más recientes primero, con `totalCount`.
- `email=ana@` → solo destinatarios cuyo correo empieza por `ana@`; mayúsculas o minúsculas da igual.
- `name=pérez` → solo destinatarios cuyo correo está en `dbo.users` con ese nombre.
- Destinatario que no está en el maestro → aparece con `recipientName = null`; el filtro por nombre no lo encuentra.
- `pageSize=1000` → se recorta a 100.

---

## ✅ Checklist

- [ ] Ajuste de la llave a `ON DELETE SET NULL` ejecutado (o `DeleteBehavior.NoAction` en la configuración, y el editor de cursos bloqueando ese caso).
- [ ] Índice `ix_email_alert_log_assignment_type_status` creado.
- [ ] Entidades sin `BaseEntity`.
- [ ] Configuraciones en `Configurations/` (se cargan solas).
- [ ] `EmailAlertTypes` con un valor por cada correo del sistema.
- [ ] `IEmailAlertLogService` registrado en `ApplicationServiceRegistration.cs`.
- [ ] Los servicios envían **después** de guardar el negocio y usan la lista normalizada que recibe `send`.
- [ ] Registro de envíos sin controlador y con el repositorio genérico.
- [ ] Consulta de la pantalla con `IEmailAlertLogQueryRepository` (solo lectura) y `EmailAlertLogsController` protegido con el permiso de administración.
- [ ] Política de retención de los logs acordada.
