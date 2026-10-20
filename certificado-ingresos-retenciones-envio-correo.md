# 📧 Certificado de Ingresos y Retenciones — solicitud que se aprueba sola y llega por correo

**El flujo:** igual que el certificado laboral.

1. La persona solicita el "Certificado de Ingresos y Retenciones" y elige el año gravable.
2. Se crea la solicitud y **se aprueba automáticamente**.
3. Al aprobarse, se genera el PDF (Formulario 220) y se envía adjunto al correo corporativo.

**Lo que lo diferencia del laboral:**
- **No se descarga** desde la página.
- **El historial no se muestra:** la fila aparece en "Mis certificados" como aprobada, pero sin "Ver historial" y sin descarga.

Por ahora con **datos de prueba**: la nómina y la identificación del trabajador son ficticias.

**Base:** el código real de `.claude/Certificados API` (.NET 8) y `.claude/Certificados` (Angular), que también es la app que se usa desde el celular. El generador del PDF ya está hecho con la guía [certificado-ingresos-retenciones-220.md](.claude/guias/certificado-ingresos-retenciones-220.md). Esta guía lo conecta con la solicitud, la aprobación automática y el correo.

---

## 1. Qué hay hoy

| # | Qué se encontró | Consecuencia |
|---|---|---|
| 1 | **El PDF ya se genera.** Están `IncomeWithholdingCertificateGenerationService` (QuestPDF), el factory, el mapper, `DianVerificationDigitHelper` y la nómina ficticia (`FakePayrollTaxSummaryService`, años 2023 a 2025). | Se reutiliza. |
| 2 | **Nadie llama al generador.** Solo está registrado en DI. | Falta conectarlo con la aprobación. |
| 3 | **El factory exige un `RequestId`** y su propio DTO (`CreateIncomeWithholdingRequestDto`, con `IsApproved`). | Se simplifica: recibe correo y año. El año sale del campo `taxYear` de la solicitud. |
| 4 | **Falta la sección `IncomeWithholdingCertificate` en `appsettings.json`.** | Hoy el factory respondería "Falta la configuración del retenedor". |
| 5 | **`UserManagementService.GetUserTaxIdentificationAsync` devuelve un `TaxWorkerDto` vacío**, y `User` no tiene número de documento. | El PDF saldría sin nombre ni documento del trabajador. |
| 6 | **Así funciona el laboral (el modelo a seguir):** | El 220 entra en esos mismos tres puntos. |
| | `RequestService.SaveRequestAsync` crea la solicitud y llama a `ApproveLaborCertificateRequestAsync`. | |
| | `ApproverService.ChangeStateAsync(Approved)` envía el correo con el PDF (`SendChangeStatusEmailNotificationLabor`). | |
| | La tabla muestra la descarga solo si el tipo es "Certificado Laboral". | |
| 7 | **Los valores de cada campo se leen por reflexión** (`RequestValueService.GetFieldValue`): el `field_name` de `dbo.request_type_fields` debe llamarse igual que una propiedad de `CreateRequestDto`. | El año necesita la propiedad `TaxYear` en el DTO y el campo `taxYear` en la base. |
| 8 | ⚠️ **`CertificateController.GetRequestsByUserEmail` llama a `GetRequestsByUserEmailAsync(email, false)`.** Con `false`, el filtro trae las solicitudes de tipo `common` (permisos), no las de tipo `certificate`. | "Mis certificados" no mostraría los certificados. Se corrige en el Paso 6: revisa si en tu ambiente ya lo notaste. |
| 9 | ⚠️ **`GET /api/Certificate/{id}/history` no revisa de quién es la solicitud.** | Cualquier persona autenticada puede ver el historial de una solicitud ajena si conoce el id. Esta guía bloquea el historial del 220; revisa lo mismo para los demás tipos. |
| 10 | **`certification-form.component.ts` arranca con el nombre, el correo y la cédula de un desarrollador** en `userName`, `userEmail` y `documentId`. | Se reemplazan al cargar el usuario, pero si falla la carga se ve el dato de otra persona. Deben arrancar vacíos (Paso 8). |

---

## 2. El flujo

```text
Angular: tipo "Certificado de Ingresos y Retenciones" + año ──► POST /api/Certificate (el mismo de todos los certificados)
                                                                  │
RequestService.CreateRequestAsync                                 ▼
  1. Campos obligatorios (taxYear)                     ValidationRequestService
  2. Validación del 220 ───────────────────────────►   - ¿mismo año pedido hace < 2 min? → "ya está en camino"
                                                       - ¿se puede generar? año cerrado, topes, nómina, trabajador
  3. Guarda la solicitud (Pendiente) + taxYear
  4. Aprobación automática ─────────────────────────►  ApproverService.ChangeStateAsync(Approved)
                                                       - estado Aprobada + historial
                                                       - genera el PDF del año → correo con el PDF adjunto
  5. "Tu certificado de ingresos y retenciones 2025 fue aprobado. Te llegará a tu correo en unos minutos."

"Mis certificados": la fila aparece como Aprobada, sin "Ver historial" y sin descarga.
```

### Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Solicitud y aprobación.** | Igual que el laboral: se crea la solicitud y se aprueba sola. Queda el registro de quién pidió qué año y cuándo. |
| 2 | **Validar antes de guardar.** | Antes de crear la solicitud se comprueba que el certificado **se puede generar**: año cerrado, topes UVT, nómina y trabajador. Así nunca queda una solicitud aprobada sin certificado. |
| 3 | **A quién se envía.** | Al correo corporativo del dueño de la solicitud (`request.User`). El correo no viene del cliente. |
| 4 | **Sin descarga.** | No hay endpoint para descargar el 220, y la tabla no muestra el botón. |
| 5 | **Sin historial para la persona.** | La tabla no muestra "Ver historial", y `GetRequestHistoryAsync` responde un aviso para este tipo. El historial sí se guarda: el flujo de aprobación lo necesita. |
| 6 | **Doble toque desde el celular.** | Si ya hay una solicitud del mismo año de esa persona en los últimos 2 minutos, se rechaza: "ya está en camino". |
| 7 | **Datos de prueba detrás de interfaces.** | La nómina (`IPayrollTaxSummaryService`, ya existe) y el trabajador (`ITaxWorkerService`, nuevo) tienen implementaciones ficticias. Para pasar a los datos reales se cambia solo el registro en DI. |
| 8 | **Que se note que es de prueba.** | `TestMode: true`: el asunto lleva "[PRUEBA]" y el correo un aviso. |
| 9 | **Años.** | La página ofrece los 3 últimos años cerrados (la nómina ficticia tiene 2023 a 2025). La API acepta hasta 5 años atrás. |
| 10 | **El correo.** | La misma plantilla del laboral (`TemplateRequestStatusUser.html`), con su propio asunto y mensaje. |

---

## 3. Paso 1 — Base de datos y configuración

### El tipo y su campo (`Persistence/Scripts SQL/Certificado ingresos y retenciones.sql`)

```sql
/* Certificado de Ingresos y Retenciones (Formulario 220): tipo de solicitud y su campo.
   El script se puede ejecutar varias veces. */
IF NOT EXISTS (SELECT 1 FROM dbo.request_types WHERE name = 'Certificado de Ingresos y Retenciones' AND type = 'certificate')
    INSERT INTO dbo.request_types (name, type, description, active)
    VALUES ('Certificado de Ingresos y Retenciones', 'certificate',
            'Formulario 220. Se aprueba automáticamente y se envía al correo corporativo.', 1);
GO

DECLARE @typeId INT = (SELECT id FROM dbo.request_types
                       WHERE name = 'Certificado de Ingresos y Retenciones' AND type = 'certificate');

-- field_name debe llamarse igual que la propiedad TaxYear de CreateRequestDto (se lee por reflexión).
IF NOT EXISTS (SELECT 1 FROM dbo.request_type_fields WHERE request_type_id = @typeId AND field_name = 'taxYear')
    INSERT INTO dbo.request_type_fields (request_type_id, field_name, description, required, active)
    VALUES (@typeId, 'taxYear', 'Año gravable', 1, 1);
GO
```

> Revisa con `SELECT * FROM dbo.request_type_fields` qué campos tiene "Certificado Laboral". Si tiene alguno que todos los certificados deban guardar (por ejemplo `createdAt` u `observations`), agrégalo también aquí.

### `WebApp/appsettings.json` ✏️ — agrega la sección

```json
"IncomeWithholdingCertificate": {
  "Nit": "900000000",
  "BusinessName": "<Razón social del retenedor>",
  "PayerName": "<Razón social del retenedor>",
  "WithholdingPlace": "BOGOTA",
  "DepartmentCode": "11",
  "MunicipalityCode": "001",
  "DianLogoFileName": null,
  "TestMode": true,
  "ThresholdsByYear": {
    "2023": { "GrossEquityUvt": 4500, "GrossIncomeUvt": 1400, "CreditCardUvt": 1400, "PurchasesUvt": 1400, "DepositsUvt": 1400 },
    "2024": { "GrossEquityUvt": 4500, "GrossIncomeUvt": 1400, "CreditCardUvt": 1400, "PurchasesUvt": 1400, "DepositsUvt": 1400 },
    "2025": { "GrossEquityUvt": 4500, "GrossIncomeUvt": 1400, "CreditCardUvt": 1400, "PurchasesUvt": 1400, "DepositsUvt": 1400 }
  }
}
```

- **`Nit`, `BusinessName` y `PayerName`:** pon los reales. El NIT va **sin** dígito de verificación: lo calcula `DianVerificationDigitHelper`.
- **`ThresholdsByYear`:** van los 3 años de la nómina ficticia. Los topes UVT de 2023 y 2024 son los mismos de 2025; confírmalos con contabilidad.
- **`TestMode`:** `true` mientras los datos sean ficticios.

### `DTOs/IncomeWithholding/IncomeWithholdingCertificateOptions.cs` ✏️ — agrega

```csharp
/// <summary>true mientras los datos sean ficticios: el asunto lleva "[PRUEBA]" y el correo un aviso.</summary>
public bool TestMode { get; set; }
```

### `Common/ConstantsValues.cs` ✏️ — junto a `CertificateRequestTypeLabor`

```csharp
public const string CertificateRequestTypeIncomeWithholding = "Certificado de Ingresos y Retenciones";
public const string TaxYearFieldName = "taxYear";
```

### `DTOs/CreateRequestDto.cs` ✏️ — agrega

```csharp
/// <summary>Solo para el Certificado de Ingresos y Retenciones: año gravable a certificar.</summary>
public int? TaxYear { get; set; }
```

---

## 4. Paso 2 — El trabajador de prueba

`User` no tiene número de documento, y `GetUserTaxIdentificationAsync` devuelve un objeto vacío. La identificación tributaria va detrás de una interfaz, igual que la nómina.

### `Interfaces/ITaxWorkerService.cs` (nuevo)

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

namespace DOCCB.Application.Features.Requests.Application.Interfaces
{
    /// <summary>Identificación tributaria del trabajador (casillas 24 a 29 del Formulario 220).</summary>
    public interface ITaxWorkerService
    {
        Task<ResponseDto<TaxWorkerDto>> GetTaxWorkerAsync(string userEmail);
    }
}
```

### `Services/FakeTaxWorkerService.cs` (nuevo)

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.Requests.Application.Constants;
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;
using DOCCB.Application.Features.Requests.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Requests.Application.Services
{
    /// <summary>
    /// [FICTICIO] Nombres reales de dbo.users y un número de documento inventado a partir del id.
    /// Se reemplaza por la fuente real (maestro de Gestión Humana) cambiando solo el registro en DI.
    /// </summary>
    public class FakeTaxWorkerService(ITransactionExecutorHelper transactionHelper) : ITaxWorkerService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        public async Task<ResponseDto<TaxWorkerDto>> GetTaxWorkerAsync(string userEmail)
        {
            var user = await _transactionHelper.ExecuteQueryAsync<User>(async unitOfWork =>
                await unitOfWork.Repository<User>().GetAsync(u => u.CorportativeEmail == userEmail && u.IsActive));

            if (user is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<TaxWorkerDto>(IncomeWithholdingCertificateMessages.UserNotRegistered);
            }

            // Si la persona no llenó nombre y apellidos por separado, se parte el nombre que muestra Microsoft.
            var hasSplitNames = !string.IsNullOrWhiteSpace(user.Name) && !string.IsNullOrWhiteSpace(user.FamilyName);
            var (firstName, otherNames) = SplitFirst(hasSplitNames ? user.Name : user.DisplayName);
            var (firstLastName, secondLastName) = hasSplitNames ? SplitFirst(user.FamilyName) : SplitFirst(otherNames);

            return ResponseDtoHelper.CreateSuccessResponseDto(new TaxWorkerDto
            {
                DocumentType = DianDocumentType.CedulaCiudadania,
                // [FICTICIO] 10 dígitos a partir del id: User no tiene número de documento.
                DocumentNumber = $"10{user.Id:D8}",
                FirstLastName = firstLastName.ToUpperInvariant(),
                SecondLastName = secondLastName.ToUpperInvariant(),
                FirstName = firstName.ToUpperInvariant(),
                OtherNames = hasSplitNames ? otherNames.ToUpperInvariant() : string.Empty,
            });
        }

        /// <summary>"Juan Carlos" → ("Juan", "Carlos").</summary>
        private static (string First, string Rest) SplitFirst(string? value)
        {
            var parts = (value ?? string.Empty).Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            return parts.Length == 0 ? (string.Empty, string.Empty) : (parts[0], string.Join(' ', parts.Skip(1)));
        }
    }
}
```

### Lo que se quita

- **`GetUserTaxIdentificationAsync`** de `IUserManagementService` y `UserManagementService`: era el esqueleto vacío de la guía anterior.
- **`DTOs/IncomeWithholding/CreateIncomeWithholdingRequestDto.cs`:** el 220 usa `CreateRequestDto`, como los demás certificados.

---

## 5. Paso 3 — El factory: validar y generar sin `RequestId`

### `Constants/IncomeWithholdingCertificateMessages.cs` (nuevo)

```csharp
namespace DOCCB.Application.Features.Requests.Application.Constants
{
    public static class IncomeWithholdingCertificateMessages
    {
        public const string MissingConfiguration = "Falta la configuración del retenedor para el certificado de ingresos y retenciones.";
        public const string MissingThresholds = "No hay topes UVT configurados para el año gravable {0}.";
        public const string TaxYearRequired = "Selecciona el año gravable.";
        public const string YearNotClosed = "El año gravable {0} aún no ha cerrado.";
        public const string YearTooOld = "Solo se pueden expedir certificados de los últimos {0} años gravables.";
        public const string UserNotRegistered = "Para realizar cualquier acción primero debes ingresar tu información en el módulo 'Mis Datos'";
        public const string NoPayroll = "No hay información de nómina para el año gravable {0}.";
        public const string NoWorker = "No se encontró la identificación tributaria del trabajador.";
        public const string AlreadyRequested = "Tu certificado de {0} ya está en camino. Revisa tu correo, también la carpeta de no deseados.";
        public const string HistoryNotAvailable = "El historial no está disponible para el certificado de ingresos y retenciones.";

        /// <summary>Respuesta de crear la solicitud (sale en el toast).</summary>
        public const string Created = "Tu certificado de ingresos y retenciones {0} fue aprobado. Te llegará a tu correo en unos minutos.";

        /// <summary>Comentario de la aprobación automática.</summary>
        public const string ApprovalComment = "Respuesta a su solicitud de certificado de ingresos y retenciones del año gravable {0}.";

        public const string EmailSubject = "Su certificado de ingresos y retenciones {0}";
        public const string TestSubjectPrefix = "[PRUEBA] ";
        public const string AttachmentName = "Certificado_Ingresos_Retenciones_{0}.pdf";
    }
}
```

### `Interfaces/IIncomeWithholdingCertificateGenerationService.cs` ✏️

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;

namespace DOCCB.Application.Features.Requests.Application.Interfaces
{
    public interface IIncomeWithholdingCertificateGenerationService
    {
        /// <summary>
        /// Comprueba que el certificado se puede generar (año, topes, nómina, trabajador) sin dibujar el PDF.
        /// Se usa antes de crear la solicitud.
        /// </summary>
        Task<ResponseDto<bool>> ValidateAsync(string userEmail, int taxYear);

        /// <summary>El PDF del Formulario 220 de esa persona y ese año gravable.</summary>
        Task<ResponseDto<byte[]>> GenerateForUserAsync(string userEmail, int taxYear);
    }
}
```

### `Services/IncomeWithholdingCertificateGenerationFactory.cs` ✏️ — completo

```csharp
using Microsoft.Extensions.Configuration;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.Requests.Application.Constants;
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;
using DOCCB.Application.Features.Requests.Application.Helper;
using DOCCB.Application.Features.Requests.Application.Interfaces;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.Requests.Application.Services
{
    /// <summary>Arma el Formulario 220 de una persona y un año gravable.</summary>
    public class IncomeWithholdingCertificateGenerationFactory(
        IConfiguration configuration,
        ITransactionExecutorHelper transactionHelper,
        ITaxWorkerService taxWorkerService,
        IPayrollTaxSummaryService payrollTaxSummaryService) : IIncomeWithholdingCertificateGenerationService
    {
        /// <summary>Cuántos años gravables hacia atrás se pueden certificar. Confirmar con Gestión Humana.</summary>
        private const int MaxYearsBack = 5;

        private readonly IConfiguration _configuration = configuration;
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly ITaxWorkerService _taxWorkerService = taxWorkerService;
        private readonly IPayrollTaxSummaryService _payrollTaxSummaryService = payrollTaxSummaryService;

        public async Task<ResponseDto<bool>> ValidateAsync(string userEmail, int taxYear)
        {
            var model = await BuildModelAsync(userEmail, taxYear);
            return model.HasError
                ? ResponseDtoHelper.CreateErrorResponseDto<bool>(model.Errors)
                : ResponseDtoHelper.CreateSuccessResponseDto(true);
        }

        public async Task<ResponseDto<byte[]>> GenerateForUserAsync(string userEmail, int taxYear)
        {
            var model = await BuildModelAsync(userEmail, taxYear);
            if (model.HasError || model.Response is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<byte[]>(model.Errors);
            }

            var options = _configuration.GetSection(IncomeWithholdingCertificateOptions.SectionName).Get<IncomeWithholdingCertificateOptions>();
            var generator = new IncomeWithholdingCertificateGenerationService(model.Response, ResolveAssetPath(options?.DianLogoFileName));
            return ResponseDtoHelper.CreateSuccessResponseDto(generator.GeneratePdf());
        }

        /// <summary>Todo lo que necesita el PDF. Si algo falta, el error que verá la persona.</summary>
        private async Task<ResponseDto<IncomeWithholdingCertificateModelDto>> BuildModelAsync(string userEmail, int taxYear)
        {
            var options = _configuration.GetSection(IncomeWithholdingCertificateOptions.SectionName).Get<IncomeWithholdingCertificateOptions>();
            if (options is null || string.IsNullOrWhiteSpace(options.Nit))
            {
                return Error(IncomeWithholdingCertificateMessages.MissingConfiguration);
            }

            var yearError = ValidateTaxYear(taxYear);
            if (yearError is not null)
            {
                return Error(yearError);
            }

            // Es preferible fallar a expedir un certificado con topes de otro año.
            var thresholds = options.ResolveThresholds(taxYear);
            if (thresholds is null)
            {
                return Error(string.Format(IncomeWithholdingCertificateMessages.MissingThresholds, taxYear));
            }

            // El código de empleado con el que se consulta la nómina (solo esa columna).
            var employeeCode = await _transactionHelper.ExecuteQueryAsync<string>(async unitOfWork =>
                (await unitOfWork.Repository<User>().GetListAsync(
                    u => u.CorportativeEmail == userEmail && u.IsActive,
                    selector: q => q.Select(u => u.UserCode ?? string.Empty).Take(1)))
                .FirstOrDefault());

            if (employeeCode is null)
            {
                return Error(IncomeWithholdingCertificateMessages.UserNotRegistered);
            }

            // Servicios externos, fuera de cualquier transacción.
            var payroll = await _payrollTaxSummaryService.GetAnnualSummaryAsync(employeeCode, taxYear);
            if (payroll.HasError || payroll.Response is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<IncomeWithholdingCertificateModelDto>(
                    payroll.Errors ?? [string.Format(IncomeWithholdingCertificateMessages.NoPayroll, taxYear)]);
            }

            var worker = await _taxWorkerService.GetTaxWorkerAsync(userEmail);
            if (worker.HasError || worker.Response is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<IncomeWithholdingCertificateModelDto>(
                    worker.Errors ?? [IncomeWithholdingCertificateMessages.NoWorker]);
            }

            return ResponseDtoHelper.CreateSuccessResponseDto(IncomeWithholdingCertificateMapper.ToModel(
                taxYear,
                options,
                thresholds,
                worker.Response,
                payroll.Response,
                issueDate: DateOnly.FromDateTime(DateTime.Today)));
        }

        private static ResponseDto<IncomeWithholdingCertificateModelDto> Error(string message) =>
            ResponseDtoHelper.CreateErrorResponseDto<IncomeWithholdingCertificateModelDto>(message);

        private static string? ValidateTaxYear(int taxYear)
        {
            var currentYear = DateTime.Today.Year;

            if (taxYear >= currentYear)
            {
                return string.Format(IncomeWithholdingCertificateMessages.YearNotClosed, taxYear);
            }

            if (taxYear < currentYear - MaxYearsBack)
            {
                return string.Format(IncomeWithholdingCertificateMessages.YearTooOld, MaxYearsBack);
            }

            return null;
        }

        private string? ResolveAssetPath(string? fileName)
        {
            if (string.IsNullOrWhiteSpace(fileName))
            {
                return null;
            }

            var templatesDir = _configuration["AzureAd:TemplatesDir"] ?? string.Empty;
            return Path.Combine(templatesDir, "Assets", fileName);
        }
    }
}
```

> **`ValidateAsync` y `GenerateForUserAsync` comparten `BuildModelAsync`:** lo que se valida al crear la solicitud es exactamente lo que se usa al generar. Si pasó la validación, el PDF se genera.

---

## 6. Paso 4 — Crear la solicitud: validación y aprobación automática

### `Services/ValidationRequestService.cs` ✏️

**Constructor:** agrega el generador.

```csharp
public class ValidationRequestService(
    ITransactionExecutorHelper transactionHelper,
    IRequestValueService requestValueService,
    IUnitOfWorkFactory unitOfWorkFactory,
    IIncomeWithholdingCertificateGenerationService incomeWithholdingService) : IValidationRequestService
{
    // … los campos de hoy …
    private readonly IIncomeWithholdingCertificateGenerationService _incomeWithholdingService = incomeWithholdingService;
```

**`ValidateRequest`:** antes de `if (!isCommunRequest)`.

```csharp
if (requestDTO.Name.Equals(ConstantsValues.CertificateRequestTypeIncomeWithholding, StringComparison.OrdinalIgnoreCase))
{
    return await ValidateIncomeWithholdingRequest(requestDTO, userInfo, requestType);
}
```

**Método nuevo:**

```csharp
/// <summary>
/// Antes de crear la solicitud: el año viene, no hay otra igual "en camino" y el certificado se puede generar.
/// Así nunca queda una solicitud aprobada sin certificado.
/// </summary>
private async Task<(bool IsValid, string ErrorValidation)> ValidateIncomeWithholdingRequest(CreateRequestDto requestDTO, User userInfo, int requestTypeId)
{
    if (requestDTO.TaxYear is not { } taxYear)
    {
        return (false, IncomeWithholdingCertificateMessages.TaxYearRequired);
    }

    // Doble toque desde el celular: la misma persona, el mismo año, en los últimos 2 minutos.
    var since = DateTime.Now.AddMinutes(-2);
    var year = taxYear.ToString();
    var alreadyRequested = await _transactionHelper.ExecuteQueryAsync<bool>(async unitOfWork =>
        await unitOfWork.Repository<RequestFieldValue>().AnyAsync(v =>
            v.FieldValue == year
            && v.Field!.FieldName == ConstantsValues.TaxYearFieldName
            && v.Request.IdUser == userInfo.Id
            && v.Request.RequestTypeId == requestTypeId
            && !v.Request.Removed
            && v.Request.CreatedDate >= since));

    if (alreadyRequested)
    {
        return (false, string.Format(IncomeWithholdingCertificateMessages.AlreadyRequested, taxYear));
    }

    var check = await _incomeWithholdingService.ValidateAsync(userInfo.CorportativeEmail, taxYear);
    return check.HasError ? (false, string.Join(" ", check.Errors)) : (true, string.Empty);
}
```

> `requests.created_date` se guarda con `DateTime.Now` (hora del servidor). Por eso la ventana usa `DateTime.Now` y no `UtcNow`.
>
> **Usings:** `DOCCB.Application.Features.Requests.Application.Constants` (mensajes) y `DOCCB.Application.Features.Requests.Application.Interfaces` (el generador), si no están.

### `Services/RequestService.cs` ✏️

**1. Aprobación automática.** Al final de `SaveRequestAsync`, el `if` del laboral pasa a cubrir los dos certificados:

```csharp
if (IsAutoApprovedCertificate(requestDto.Name))
{
    await ApproveCertificateRequestAsync(request.Id, requestDto);
}
else
{
    await SendEmployeeEmailNotification(requestDto);
    await SendLeaderEmailNotification(requestDto);
}
```

**2. `ApproveLaborCertificateRequestAsync`** se renombra a `ApproveCertificateRequestAsync`, con el comentario de cada tipo:

```csharp
/// <summary>Certificados que no requieren aprobación: el laboral y el de ingresos y retenciones.</summary>
private static bool IsAutoApprovedCertificate(string requestName) =>
    requestName == ConstantsValues.CertificateRequestTypeLabor
    || requestName == ConstantsValues.CertificateRequestTypeIncomeWithholding;

private async Task ApproveCertificateRequestAsync(int requestId, CreateRequestDto requestDto)
{
    var comments = requestDto.Name == ConstantsValues.CertificateRequestTypeIncomeWithholding
        ? string.Format(IncomeWithholdingCertificateMessages.ApprovalComment, requestDto.TaxYear)
        : $"Respuesta a su solicitud de certificado laboral {CertificateCharacteristics.GetDescription(requestDto.CertificateCharacteristics)}.";

    var changeStatusDto = new ChangeRequestStatusDto
    {
        RequestId = requestId,
        UserEmail = requestDto.UserEmail,
        Comments = comments,
    };

    var result = await _approverService.ChangeStateAsync(changeStatusDto, RequestStatus.Approved);

    if (result!.HasError)
    {
        throw new InvalidOperationException(result.Errors.FirstOrDefault() ?? "No fue posible aprobar automáticamente la solicitud.");
    }
}
```

**3. El mensaje de respuesta.** En `CreateRequestAsync`, el `return` de éxito:

```csharp
// El 220 ya se aprobó y va en camino al correo: el toast lo dice.
var successMessage = requestDto.Name == ConstantsValues.CertificateRequestTypeIncomeWithholding
    ? string.Format(IncomeWithholdingCertificateMessages.Created, requestDto.TaxYear)
    : "Solicitud creada exitosamente.";

return ResponseDtoHelper.CreateSuccessResponseDto(successMessage);
```

**4. Historial oculto.** Al principio de la lambda de `GetRequestHistoryAsync`:

```csharp
// El certificado de ingresos y retenciones no muestra historial a la persona.
var isIncomeWithholding = await unitOfWork.Repository<Request>().AnyAsync(r =>
    r.Id == requestId && r.RequestType.Name == ConstantsValues.CertificateRequestTypeIncomeWithholding);

if (isIncomeWithholding)
{
    return ResponseDtoHelper.CreateErrorResponseDto<List<RequestHistoryResponseDto>>(IncomeWithholdingCertificateMessages.HistoryNotAvailable);
}
```

> `GetRequestHistoryAsync` lo usan `CertificateController` y `RequestController`, que son de la persona. Las pantallas del aprobador usan `ApproverService` y no se afectan.

---

## 7. Paso 5 — El correo con el PDF al aprobarse

### `Approver/Application/Services/ApproverService.cs` ✏️

**Constructor:** agrega el generador.

```csharp
IIncomeWithholdingCertificateGenerationService incomeWithholdingCertificateGenerationService
// …
private readonly IIncomeWithholdingCertificateGenerationService _incomeWithholdingCertificateGenerationService = incomeWithholdingCertificateGenerationService;
```

**`ChangeStateAsync`:** en el bloque que elige el correo, un caso para el 220 entre el laboral y el genérico.

```csharp
if (request.RequestType.Name == ConstantsValues.CertificateRequestTypeLabor)
{
    // … lo de hoy …
}
else if (request.RequestType.Name == ConstantsValues.CertificateRequestTypeIncomeWithholding)
{
    await SendIncomeWithholdingEmailAsync(request, dto.Comments, unitOfWork);
}
else
{
    // … lo de hoy …
}
```

**Método nuevo**, junto a `SendChangeStatusEmailNotificationLabor`:

```csharp
/// <summary>Certificado de ingresos y retenciones aprobado: el PDF del año va adjunto al correo corporativo.</summary>
private async Task SendIncomeWithholdingEmailAsync(Request request, string? observations, IUnitOfWork unitOfWork)
{
    const string Template = "TemplateRequestStatusUser.html";

    var yearValues = await _requestValueService.GetFieldValuesByFieldNameAsync([request.Id], ConstantsValues.TaxYearFieldName, unitOfWork);
    if (!yearValues.TryGetValue(request.Id, out var yearText) || !int.TryParse(yearText, out var taxYear))
    {
        return; // No pasa: la validación exige el año. Sin año no hay certificado que enviar.
    }

    var userEmail = request.User.CorportativeEmail;
    var pdf = await _incomeWithholdingCertificateGenerationService.GenerateForUserAsync(userEmail, taxYear);
    var hasPdf = !pdf.HasError && pdf.Response is not null;

    var options = _configuration.GetSection(IncomeWithholdingCertificateOptions.SectionName).Get<IncomeWithholdingCertificateOptions>();
    var testMode = options?.TestMode ?? false;

    var displayStatus = EmailNotificationHelper.ToStatusDisplay(request.Status);
    var frontendApp = _configuration["Frontend:FrontendApp"] ?? string.Empty;

    var testNotice = testMode
        ? """<div style="margin-bottom:12px; padding:10px 12px; border-radius:8px; background-color:#FFF3CD; color:#664D03;"><strong>Datos de prueba.</strong> Este certificado se generó con información ficticia y no tiene validez.</div>"""
        : string.Empty;

    var body = hasPdf
        ? $"""<div style="color:#333333; margin-bottom:16px;">Adjuntamos tu <strong>Certificado de Ingresos y Retenciones</strong> del año gravable <strong>{taxYear}</strong>. Por seguridad no se descarga desde el Portal del Empleado: si lo necesitas de nuevo, solicítalo otra vez.</div>"""
        : $"""<div style="color:#333333; margin-bottom:16px;">No pudimos generar tu certificado del año gravable <strong>{taxYear}</strong>. Solicítalo de nuevo en unos minutos.</div>""";

    var tokens = new Dictionary<string, string>
    {
        ["NOMBRE"] = request.User.Name,
        ["TIPO_PERMISO"] = request.RequestType.Name,
        ["ESTADO"] = displayStatus,
        ["ESTADO_COLOR"] = EmailNotificationHelper.GetHexadecimalColorState(displayStatus),
        ["OBSERVACIONES"] = observations ?? "Sin comentarios",
        ["CTA_URL"] = $"{frontendApp}/certificates",
        ["MENSAJE_SECTION"] = testNotice + body,
    };

    var subject = (testMode ? IncomeWithholdingCertificateMessages.TestSubjectPrefix : string.Empty)
        + string.Format(IncomeWithholdingCertificateMessages.EmailSubject, taxYear);

    await _mailNotificationService.SendTemplatedEmailAsync(
        to: userEmail,
        subject: subject,
        templateFileName: Template,
        tokens: tokens,
        pdfAttachment: hasPdf ? pdf.Response : null,
        pdfAttachmentName: hasPdf ? string.Format(IncomeWithholdingCertificateMessages.AttachmentName, taxYear) : null);
}
```

> Usa `TemplateRequestStatusUser.html`, la misma del laboral (tiene `MENSAJE_SECTION`, estado y observaciones). No hace falta una plantilla nueva.
>
> **Usings:** `DOCCB.Application.Features.Requests.Application.Constants` y `DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding`, si no están.

### `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<ITaxWorkerService, FakeTaxWorkerService>();
```

`IIncomeWithholdingCertificateGenerationService` e `IPayrollTaxSummaryService` ya están registrados.

---

## 8. Paso 6 — "Mis certificados" debe listar certificados

### `WebApp/Controllers/CertificateController.cs` ✏️ — `GetRequestsByUserEmail`

```csharp
// true: solicitudes de tipo "certificate" (con false traería las de tipo "common", es decir, permisos).
var requests = await _requestService.GetRequestsByUserEmailAsync(dto.Email, true);
```

Con `true`, `MapRequestAsync` también usa el mapeo de certificados (características, fondo, monto…), que es el que espera la tabla.

> Pruébalo antes de cambiarlo: abre "Mis certificados" y mira si salen certificados o permisos. `RequestController` sí debe quedar con `false`.

---

## 9. Paso 7 — Frontend (Angular)

### `shared/common/constant-values.ts` ✏️

```ts
export class ConstanValues {
  static readonly CesantiasRequestName: string = 'Cesantias';
  static readonly EmploymentRequestName: string = 'Certificado Laboral';
  /** Igual al name de dbo.request_types. */
  static readonly IncomeWithholdingRequestName: string = 'Certificado de Ingresos y Retenciones';
}
```

### `shared/common/select-tag-options.ts` ✏️

```ts
static readonly selectCesantiasRequestTypes = [
    { value: 'Cesantias', label: 'Cesantías' },
    { value: 'Certificado Laboral', label: 'Certificado Laboral' },
    { value: 'Certificado de Ingresos y Retenciones', label: 'Certificado de Ingresos y Retenciones' },
];
```

### `shared/entities/general/requests-entities.ts` ✏️ — en `CertificateRequest`

```ts
/** Solo para el Certificado de Ingresos y Retenciones. */
taxYear?: number;
```

### `features/certificates/domain/certificates.ts` ✏️ — agrega

```ts
/** Los 3 últimos años gravables cerrados (la nómina de prueba tiene 2023 a 2025). */
export function incomeWithholdingYears(today = new Date()): number[] {
  const lastClosed = today.getFullYear() - 1;
  return [lastClosed, lastClosed - 1, lastClosed - 2];
}
```

### `presentation/certification-form/certification-form.component.ts` ✏️

**Imports y propiedades:**

```ts
import { incomeWithholdingYears } from '@features/certificates/domain/certificates';
import { ConstanValues } from '@shared/common/constant-values';

readonly incomeWithholdingType = ConstanValues.IncomeWithholdingRequestName;
readonly taxYears = incomeWithholdingYears();
readonly isIncomeWithholding = computed(() => this.currentType() === ConstanValues.IncomeWithholdingRequestName);
```

**Datos de una persona real en el código:** cambia los valores iniciales a vacío. Se llenan al cargar el usuario.

```ts
userName = signal<string>('');
userEmail = signal<string>('');
documentId = signal<string>('');
```

**`createForm`:** agrega el control.

```ts
taxYear: [null as number | null],
```

**`registerTypeEffect`:** reemplázalo. Hoy, cualquier tipo que no sea Cesantías exige "Características" (`else`), y eso bloquearía el 220:

```ts
private registerTypeEffect(): void {
  this.form.get('type')?.valueChanges.subscribe(type => {
    this.currentType.set(type);
    const isCesantias = type === 'Cesantias';
    const isLabor = type === 'Certificado Laboral';
    const isIncomeWithholding = type === ConstanValues.IncomeWithholdingRequestName;

    const documentNumber = this.form.get('documentNumber');
    const requestedAmount = this.form.get('requestedAmount');
    const reason = this.form.get('reason');
    const cesantiasEntity = this.form.get('cesantiasEntity');
    const certificateCharacteristics = this.form.get('certificateCharacteristics');
    const taxYear = this.form.get('taxYear');

    documentNumber?.setValidators(isCesantias
      ? [Validators.required, Validators.minLength(6), Validators.maxLength(20), Validators.pattern(/^\d+$/)]
      : []);
    requestedAmount?.setValidators(isCesantias
      ? [Validators.required, Validators.pattern(/^\d+([.,]\d+)?$/), Validators.min(1)]
      : []);
    reason?.setValidators(isCesantias ? [Validators.required] : []);
    cesantiasEntity?.setValidators(isCesantias ? [Validators.required] : []);
    certificateCharacteristics?.setValidators(isLabor ? [Validators.required] : []);
    taxYear?.setValidators(isIncomeWithholding ? [Validators.required] : []);

    [documentNumber, requestedAmount, reason, cesantiasEntity, certificateCharacteristics, taxYear]
      .forEach(control => control?.updateValueAndValidity());
  });
}
```

**`transformToRequest`:** agrega `taxYear` a lo que se lee del formulario y, junto al `if` del laboral:

```ts
const { /* … lo de hoy … */ taxYear } = this.form.value;

// …

if (type === ConstanValues.IncomeWithholdingRequestName) {
  request.taxYear = Number(taxYear);
}
```

`onSubmit` no cambia: el 220 se guarda con `saveRequest`, como los demás. El toast muestra el mensaje de la API ("…fue aprobado. Te llegará a tu correo…").

### `certification-form.component.html` ✏️

**1. Bloque nuevo**, después del bloque "Certificado Laboral":

```html
<!-- ── Bloque Certificado de Ingresos y Retenciones ─────────── -->
@if (isIncomeWithholding()) {

<p class="form-section-title">Detalles del certificado</p>
<div class="row g-3 mb-3">
  <div class="col-md-6">
    <label for="taxYear" class="form-label">Año gravable</label>
    <div class="field-wrap">
      <select id="taxYear" class="form-select" formControlName="taxYear"
        [class.is-invalid]="form.get('taxYear')?.invalid && form.get('taxYear')?.touched">
        <option [ngValue]="null">Seleccione</option>
        @for (year of taxYears; track year) {
        <option [ngValue]="year">{{ year }}</option>
        }
      </select>
      <i class="fa-solid fa-circle-exclamation field-icon-error" aria-hidden="true"></i>
    </div>
    @if (form.get('taxYear')?.invalid && form.get('taxYear')?.touched) {
    <div class="field-error">Selecciona el año gravable.</div>
    }
  </div>
</div>

<div class="income-delivery-note mb-4" role="note">
  <i class="fa-solid fa-envelope-circle-check" aria-hidden="true"></i>
  <span>
    Se aprueba de inmediato y te llega en PDF a <strong>{{ userEmail() }}</strong>.
    Por seguridad no se descarga desde el portal.
  </span>
</div>
}
```

**2. Observaciones:** tampoco aplican al 220.

```html
@if (currentType() !== 'Certificado Laboral' && !isIncomeWithholding()) {
```

**3. Botón:**

```html
<button type="submit" class="btn btn-yellow" [disabled]="isSubmitting() || isEditingFiles()">
  @if (isSubmitting()) {
  {{ isIncomeWithholding() ? 'Solicitando…' : 'Guardando...' }}
  } @else {
  {{ isIncomeWithholding() ? 'Solicitar y enviar a mi correo' : (isEditMode() ? 'Actualizar solicitud' : 'Guardar solicitud') }}
  }
</button>
```

**4. Panel de ayuda:** un `@case` nuevo, antes de `@default`.

```html
@case (incomeWithholdingType) {
<div class="hints-header hints-header--dark">
  <i class="fa-solid fa-file-invoice-dollar"></i>
  <span>Ingresos y Retenciones</span>
</div>
<div class="hints-body">
  <p class="hints-intro">Así funciona:</p>
  <ul class="hints-list">
    <li>
      <i class="fa-solid fa-calendar-check hints-li-icon"></i>
      Elige el <strong>año gravable</strong> que necesitas para tu declaración de renta.
    </li>
    <li>
      <i class="fa-solid fa-circle-check hints-li-icon"></i>
      Se <strong>aprueba de inmediato</strong>, sin esperar a tu jefe.
    </li>
    <li>
      <i class="fa-solid fa-envelope hints-li-icon"></i>
      Te llega en PDF a tu <strong>correo corporativo</strong>.
    </li>
    <li>
      <i class="fa-solid fa-lock hints-li-icon"></i>
      Por seguridad <strong>no se descarga</strong> desde el portal. Si lo pierdes, solicítalo de nuevo.
    </li>
  </ul>
</div>
}
```

Y en el `@default`, un tercer tipo en la lista:

```html
<div class="hints-type-item">
  <i class="fa-solid fa-file-invoice-dollar"></i>
  <div>
    <strong>Ingresos y Retenciones</strong>
    <span>Formulario 220 para tu declaración de renta. Llega a tu correo.</span>
  </div>
</div>
```

### `certification-form.component.scss` ✏️

```scss
.income-delivery-note {
  display: flex;
  align-items: flex-start;
  gap: 0.6rem;
  padding: 0.75rem 0.9rem;
  border: 1px solid #ffc107;
  border-radius: 0.6rem;
  background: rgb(255 193 7 / 0.1);
  font-size: 0.875rem;
  line-height: 1.4;

  i {
    margin-top: 0.15rem;
    color: #b58900;
  }

  strong {
    word-break: break-all; // correos largos en el celular
  }
}
```

### `presentation/certificate-table/certificate-table.component.ts` ✏️

```ts
readonly incomeWithholdingType = ConstanValues.IncomeWithholdingRequestName;
```

### `certificate-table.component.html` ✏️ — acciones de la fila

El botón "Ver historial" se muestra solo si no es el 220. En su lugar, el 220 dice que se envió al correo:

```html
<td data-col="acciones">
  <div class="actions">
    @if (certificate.tipo === incomeWithholdingType) {
      <span class="sent-to-email" title="Enviado a tu correo corporativo">
        <i class="fa-solid fa-envelope-circle-check" aria-hidden="true"></i> Enviado a tu correo
      </span>
    } @else {
      <button class="btn btn-sm btn-yellow" title="Ver historial" (click)="openHistoryModal(certificate)">
        <i class="fa-solid fa-eye"></i>
      </button>
    }

    <!-- … Editar, Eliminar y las descargas, sin cambios … -->
  </div>
</td>
```

Las descargas ya son solo para Cesantías y Certificado Laboral: el 220 no tiene botón. Como se aprueba de inmediato, tampoco le aparecen "Editar" ni "Eliminar" (son de Pendiente y Devuelta).

### `certificate-table.component.scss` ✏️

```scss
.sent-to-email {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  color: #6b7280;
  font-size: 0.8rem;
  white-space: nowrap;

  i {
    color: #b58900;
  }
}
```

---

## 10. Pruebas

**Base de datos**
- `SELECT * FROM dbo.request_types WHERE name = 'Certificado de Ingresos y Retenciones'` → una fila de tipo `certificate`, con su campo `taxYear` obligatorio.

**API (Swagger, `POST /api/Certificate`)**
- **Solicitud correcta:** `{ "type": "certificate", "name": "Certificado de Ingresos y Retenciones", "taxYear": 2025, "userEmail": "<tu correo>", … }`.
  - **Respuesta:** "Tu certificado de ingresos y retenciones 2025 fue aprobado. Te llegará a tu correo en unos minutos."
  - **En `dbo.requests`:** la solicitud queda `Approved`, con el valor `2025` en `dbo.request_field_values`.
  - **El correo:** llega "[PRUEBA] Su certificado de ingresos y retenciones 2025", con el estado "Aprobada", el aviso de datos de prueba y `Certificado_Ingresos_Retenciones_2025.pdf`.
- **El PDF:**
  - Casillas 24 a 29: nombre y apellidos de la persona y el documento ficticio `10000000NN`.
  - Casillas 5 y 6: el NIT y el DV calculado.
  - Valores de la nómina ficticia.
- **Doble envío:** repetir antes de 2 minutos → "Tu certificado de 2025 ya está en camino…", sin solicitud nueva. Otro año sí se crea.
- **No se crea la solicitud** (no hay fila nueva en `dbo.requests`) en estos casos:
  - **Sin año:** "Faltan los siguientes campos obligatorios: taxYear".
  - **`2026`:** "El año gravable 2026 aún no ha cerrado".
  - **`2019`:** "…los últimos 5 años gravables".
  - **`2022`:** "No hay datos de ejemplo…" (la nómina ficticia no lo tiene).
  - **Sin la sección de configuración:** "Falta la configuración del retenedor…".
- **Historial:** `GET /api/Certificate/{id}/history` de un 220 → "El historial no está disponible…". Para un laboral responde como siempre.
- **Lista:** `POST /api/Certificate/user/requests-by-email` trae los certificados (con el 220), no los permisos.

**Frontend (también en el celular)**
- **El tipo:** "Certificado de Ingresos y Retenciones" aparece en "Tipo de certificado".
- **Al elegirlo:**
  - Se ve el select de año (los 3 últimos cerrados) y la nota con tu correo.
  - No se ven "Características" ni "Observaciones".
  - El botón dice "Solicitar y enviar a mi correo".
- **Sin año:** "Selecciona el año gravable" y no se envía.
- **Al enviar:** "Solicitando…" con el botón deshabilitado. Luego vuelve a "Mis certificados" con el toast de la API.
- **En "Mis certificados":** la fila aparece como **Aprobada**, con "Enviado a tu correo", sin "Ver historial" y sin descarga.
- **Los otros tipos siguen igual:**
  - El certificado laboral se aprueba solo, se descarga y "Características" sigue siendo obligatoria.
  - Cesantías sigue con su aprobación normal.
- **Celular:** la nota y "Enviado a tu correo" no se desbordan, y el panel de ayuda se lee completo.

---

## 11. Lo que queda para después

| Tema | Cómo encaja |
|---|---|
| **Nómina real** | Una clase nueva que implemente `IPayrollTaxSummaryService`. Se cambia solo el registro en `ApplicationServiceRegistration`. |
| **Identificación real** (cédula, nombres como están en nómina) | Una clase nueva que implemente `ITaxWorkerService`, contra el maestro de Gestión Humana. |
| **`TestMode: false`** | Cuando las dos fuentes sean reales. |
| **Historial de solicitudes ajenas** (hallazgo 9) | Validar en `GetRequestHistoryAsync` y `GetRequestByIdAsync` que la solicitud sea de quien la pide. |
| **PDF con contraseña** (por ejemplo, el número de documento) | QuestPDF no cifra PDFs. Requeriría una librería adicional; evalúalo con seguridad de la información. |
| **Topes UVT de cada año nuevo** | Cada enero, agrega el año que cerró en `ThresholdsByYear`. Sin él, no se crea la solicitud y se muestra el error, en lugar de usar topes de otro año. |

---

## ✅ Checklist

**Base de datos y configuración**
- [ ] Tipo "Certificado de Ingresos y Retenciones" y campo `taxYear` en `dbo.request_types` y `dbo.request_type_fields`.
- [ ] `IncomeWithholdingCertificate` en `appsettings.json` (NIT y razón social reales, 2023 a 2025, `TestMode: true`) y `TestMode` en las opciones.
- [ ] `CertificateRequestTypeIncomeWithholding` y `TaxYearFieldName` en `ConstantsValues`; `TaxYear` en `CreateRequestDto`.

**API**
- [ ] `ITaxWorkerService` + `FakeTaxWorkerService` (registrado); `GetUserTaxIdentificationAsync` y `CreateIncomeWithholdingRequestDto` eliminados.
- [ ] `IncomeWithholdingCertificateMessages`.
- [ ] Interfaz y factory con `ValidateAsync` y `GenerateForUserAsync` (sin `RequestId`).
- [ ] `ValidationRequestService`: `ValidateIncomeWithholdingRequest`.
- [ ] `RequestService`:
  - `ApproveCertificateRequestAsync` para el laboral y el 220.
  - El mensaje de respuesta del 220.
  - El historial oculto.
- [ ] `ApproverService`: `SendIncomeWithholdingEmailAsync` con el PDF adjunto.
- [ ] `CertificateController.GetRequestsByUserEmail` con `true`.

**Frontend**
- [ ] `IncomeWithholdingRequestName`, la opción del select, `taxYear` en `CertificateRequest` e `incomeWithholdingYears`.
- [ ] Formulario: control `taxYear`, `registerTypeEffect` nuevo, `transformToRequest`, bloque, botón, ayuda y estilos.
- [ ] `userName`, `userEmail` y `documentId` arrancan vacíos.
- [ ] Tabla: sin "Ver historial" para el 220 y con "Enviado a tu correo".
