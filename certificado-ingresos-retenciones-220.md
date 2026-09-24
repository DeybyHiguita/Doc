# 🧾 Formulario 220 — Certificado de Ingresos y Retenciones con QuestPDF

Guía paso a paso para agregar el **Certificado de Ingresos y Retenciones por Rentas de Trabajo y de Pensiones (Formulario 220)** siguiendo el mismo patrón del certificado laboral existente:

- un **Factory** que consulta, valida y arma el modelo → ff`IIncomeWithholdingCertificateGenerationService`
- un **servicio generador** que implementa `IDocument` de QuestPDF y solo dibuja

> Los namespaces del documento usan el prefijo `DOCCB.*`. Reemplázalo por el prefijo real de la solución al copiar el código.

---

## 0. Qué cambia respecto a la carta laboral

Antes de copiar el generador laboral, ten presentes estas diferencias. Por eso el 220 **no** reutiliza su header ni su footer:

| Aspecto | Carta laboral | Formulario 220 |
|---|---|---|
| Naturaleza | Documento corporativo | Formato oficial prescrito por la DIAN |
| Header / footer | Logo corporativo + logos de pie | Sin marca corporativa. Casilla superior izquierda opcional para el logo DIAN |
| Firma | Imagen de la firma de Gestión Humana | Recuadro **en blanco** para la firma del **trabajador** |
| Datos | Cargo, fecha de ingreso, salario | ~50 valores de nómina del año gravable |
| Casillas calculadas | Ninguna | 52, 67, 74 y 75 son sumas: **se calculan, nunca se reciben** |
| Textos | Fijos | Los topes UVT de la certificación dependen del año gravable |
| Vigencia | Un mes desde la aprobación | Por año gravable cerrado |
| Tamaño / fuente | Carta, Arial 11 | Carta, Arial 6–8 (formulario denso) |

---

## 1. 📁 Archivos a crear

```text
DOCCB.Domain/
└── Enum/
    └── DianDocumentType.cs                                   ⭐ casillas 24 y 79

DOCCB.Application/Features/Requests/Application/
├── DTOs/IncomeWithholding/
│   ├── CreateIncomeWithholdingRequestDto.cs                  entrada del endpoint
│   ├── WithholdingAgentDto.cs                                retenedor (5–11)
│   ├── TaxWorkerDto.cs                                       trabajador (24–29)
│   ├── IncomeConceptsDto.cs                                  ingresos (36–52)
│   ├── ContributionsDto.cs                                   aportes (53–59)
│   ├── OtherIncomeDto.cs                                     otros ingresos (61–74)
│   ├── AssetDto.cs                                           bienes (76–77)
│   ├── EconomicDependentDto.cs                               dependiente (79–82)
│   ├── IncomeWithholdingThresholdsDto.cs                     topes UVT
│   ├── PayrollTaxSummaryDto.cs                               lo que entrega nómina
│   ├── IncomeWithholdingCertificateOptions.cs                configuración
│   └── IncomeWithholdingCertificateModelDto.cs               ⭐ el modelo del PDF
├── Helper/
│   ├── DianVerificationDigitHelper.cs                        DV del NIT (casilla 6)
│   └── IncomeWithholdingCertificateMapper.cs                 nómina → modelo
├── Constants/
│   └── IncomeWithholdingCertificateTexts.cs                  textos legales
├── Interfaces/
│   ├── IIncomeWithholdingCertificateGenerationService.cs
│   └── IPayrollTaxSummaryService.cs                          ⭐ fuente de nómina
└── Services/
    ├── IncomeWithholdingCertificateGenerationFactory.cs      ⭐ el Factory
    └── IncomeWithholdingCertificateGenerationService.cs      ⭐ el generador QuestPDF
```

---

## 2. Paso 1 — Enum de tipos de documento DIAN

### `DOCCB.Domain/Enum/DianDocumentType.cs`

```csharp
namespace DOCCB.Domain.Enum;

/// <summary>
/// Códigos de tipo de documento de la DIAN. Se usan en la casilla 24 (trabajador)
/// y en la 79 (dependiente económico). El formulario imprime el número, no el nombre.
/// </summary>
public enum DianDocumentType
{
    RegistroCivil = 11,
    TarjetaIdentidad = 12,
    CedulaCiudadania = 13,
    TarjetaExtranjeria = 21,
    CedulaExtranjeria = 22,
    Nit = 31,
    Pasaporte = 41,
    DocumentoExtranjero = 42,
    PermisoEspecialPermanencia = 47,
    PermisoProteccionTemporal = 48
}
```

> Valida la tabla de códigos contra la resolución DIAN que prescribe el formulario del año gravable: es la fuente oficial.

---

## 3. Paso 2 — DTOs

### Mapa de casillas

Sirve para revisar con el equipo de nómina de dónde sale cada valor:

| Casillas | Bloque | DTO | Origen |
|---|---|---|---|
| 4 | Número de formulario | `IncomeWithholdingCertificateModelDto.FormNumber` | Opcional |
| 5–11 | Retenedor | `WithholdingAgentDto` | `appsettings.json` |
| 24–29 | Trabajador | `TaxWorkerDto` | Gestión de usuarios |
| 30–35 | Período y lugar | Modelo | Nómina + configuración |
| 36–51 | Ingresos | `IncomeConceptsDto` | Nómina |
| **52** | Total ingresos brutos | `IncomeConceptsDto.TotalGrossIncome` | **Calculada** |
| 53–59 | Aportes | `ContributionsDto` | Nómina |
| 60 | Retención en la fuente | `WithholdingAmount` | Nómina |
| 61–66 / 68–73 | Otros ingresos | `OtherIncomeDto` | Los diligencia el trabajador |
| **67 / 74** | Totales otros ingresos | `OtherIncomeDto.TotalReceived / TotalWithheld` | **Calculadas** |
| **75** | Total retenciones | `TotalWithholdings` | **Calculada** (60 + 74) |
| 76–78 | Bienes y deudas | `AssetDto`, `OutstandingDebts` | Los diligencia el trabajador |
| 79–82 | Dependiente económico | `EconomicDependentDto` | Los diligencia el trabajador |

> Las casillas 61 a 82 son "Datos a cargo del trabajador o pensionado". La empresa normalmente las entrega **vacías**; el modelo las soporta por si en el futuro se precargan.

### `CreateIncomeWithholdingRequestDto.cs`

```csharp
using System.Text.Json.Serialization;

namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class CreateIncomeWithholdingRequestDto
{
    public int RequestId { get; set; }

    /// <summary>Año gravable a certificar, p. ej. 2025.</summary>
    public int TaxYear { get; set; }

    /// <summary>
    /// Lo asigna el controlador desde el token. NUNCA desde el body:
    /// si viniera del cliente, cualquiera podría pedir el certificado de otra persona.
    /// </summary>
    [JsonIgnore]
    public string UserEmail { get; set; } = string.Empty;

    /// <summary>
    /// Solo para llamadas internas (p. ej. desde el flujo de aprobación).
    /// Si se deserializa del body, el cliente se salta la validación de aprobación.
    /// </summary>
    [JsonIgnore]
    public bool IsApproved { get; set; }
}
```

### `WithholdingAgentDto.cs` — casillas 5 a 11

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class WithholdingAgentDto
{
    public string Nit { get; set; } = string.Empty;               // 5
    public string VerificationDigit { get; set; } = string.Empty; // 6
    public string FirstLastName { get; set; } = string.Empty;     // 7  (solo persona natural)
    public string SecondLastName { get; set; } = string.Empty;    // 8
    public string FirstName { get; set; } = string.Empty;         // 9
    public string OtherNames { get; set; } = string.Empty;        // 10
    public string BusinessName { get; set; } = string.Empty;      // 11 (persona jurídica)

    /// <summary>"Nombre del pagador o agente retenedor", bajo la casilla 60.</summary>
    public string PayerName { get; set; } = string.Empty;
}
```

### `TaxWorkerDto.cs` — casillas 24 a 29

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class TaxWorkerDto
{
    public DianDocumentType DocumentType { get; set; } = DianDocumentType.CedulaCiudadania; // 24
    public string DocumentNumber { get; set; } = string.Empty; // 25
    public string FirstLastName { get; set; } = string.Empty;  // 26
    public string SecondLastName { get; set; } = string.Empty; // 27
    public string FirstName { get; set; } = string.Empty;      // 28
    public string OtherNames { get; set; } = string.Empty;     // 29
}
```

> ⚠️ El formulario pide apellidos y nombres **por separado**. No los derives partiendo `User.DisplayName` por espacios: "María del Pilar De La Torre" se parte mal. Deben venir como campos separados desde el maestro de empleados (ver paso 5).

### `IncomeConceptsDto.cs` — casillas 36 a 52

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class IncomeConceptsDto
{
    public decimal SalaryPayments { get; set; }                 // 36
    public decimal BonusVoucherPayments { get; set; }           // 37
    public decimal FoodExcessPayments { get; set; }             // 38
    public decimal FeePayments { get; set; }                    // 39
    public decimal ServicePayments { get; set; }                // 40
    public decimal CommissionPayments { get; set; }             // 41
    public decimal SocialBenefitPayments { get; set; }          // 42
    public decimal TravelExpensePayments { get; set; }          // 43
    public decimal RepresentationExpensePayments { get; set; }  // 44
    public decimal CooperativeWorkPayments { get; set; }        // 45
    public decimal OtherPayments { get; set; }                  // 46
    public decimal SeveranceAndInterestPaid { get; set; }       // 47
    public decimal SeveranceTraditionalRegime { get; set; }     // 48
    public decimal SeveranceConsignedToFund { get; set; }       // 49
    public decimal PensionPayments { get; set; }                // 50
    public decimal PublicEducationalSupport { get; set; }       // 51

    /// <summary>Casilla 52: suma de 36 a 51. Se calcula; nunca se recibe de nómina.</summary>
    public decimal TotalGrossIncome =>
        SalaryPayments + BonusVoucherPayments + FoodExcessPayments + FeePayments +
        ServicePayments + CommissionPayments + SocialBenefitPayments + TravelExpensePayments +
        RepresentationExpensePayments + CooperativeWorkPayments + OtherPayments +
        SeveranceAndInterestPaid + SeveranceTraditionalRegime + SeveranceConsignedToFund +
        PensionPayments + PublicEducationalSupport;
}
```

### `ContributionsDto.cs` — casillas 53 a 59

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class ContributionsDto
{
    public decimal MandatoryHealth { get; set; }                  // 53
    public decimal MandatoryPensionAndSolidarity { get; set; }    // 54
    public decimal VoluntaryRais { get; set; }                    // 55
    public decimal VoluntaryPensionFunds { get; set; }            // 56
    public decimal AfcAccounts { get; set; }                      // 57
    public decimal AvcAccounts { get; set; }                      // 58
    public decimal AverageLaborIncomeLastSixMonths { get; set; }  // 59 (numeral 4 art. 206 E.T.)
}
```

### `OtherIncomeDto.cs` — casillas 61 a 74

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class OtherIncomeLineDto
{
    public decimal Received { get; set; }
    public decimal Withheld { get; set; }
}

public class OtherIncomeDto
{
    public OtherIncomeLineDto Leases { get; set; } = new();                   // 61 / 68
    public OtherIncomeLineDto FeesCommissionsServices { get; set; } = new();  // 62 / 69
    public OtherIncomeLineDto FinancialInterest { get; set; } = new();        // 63 / 70
    public OtherIncomeLineDto FixedAssetSales { get; set; } = new();          // 64 / 71
    public OtherIncomeLineDto LotteriesAndBets { get; set; } = new();         // 65 / 72
    public OtherIncomeLineDto Other { get; set; } = new();                    // 66 / 73

    private IEnumerable<OtherIncomeLineDto> Lines =>
        [Leases, FeesCommissionsServices, FinancialInterest, FixedAssetSales, LotteriesAndBets, Other];

    /// <summary>Casilla 67: suma de 61 a 66.</summary>
    public decimal TotalReceived => Lines.Sum(l => l.Received);

    /// <summary>Casilla 74: suma de 68 a 73.</summary>
    public decimal TotalWithheld => Lines.Sum(l => l.Withheld);
}
```

### `AssetDto.cs` y `EconomicDependentDto.cs` — casillas 76 a 82

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class AssetDto
{
    public string Description { get; set; } = string.Empty;  // 76
    public decimal PatrimonialValue { get; set; }            // 77
}

public class EconomicDependentDto
{
    public DianDocumentType DocumentType { get; set; }        // 79
    public string DocumentNumber { get; set; } = string.Empty; // 80
    public string FullName { get; set; } = string.Empty;       // 81
    public string Relationship { get; set; } = string.Empty;   // 82
}
```

### `IncomeWithholdingThresholdsDto.cs` — topes UVT del texto de certificación

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

/// <summary>
/// Topes que aparecen en "Certifico que durante el año gravable...".
/// Dependen de la norma vigente para cada año: se configuran por año, no van quemados en el código.
/// </summary>
public class IncomeWithholdingThresholdsDto
{
    public int GrossEquityUvt { get; set; }   // numeral 1 (patrimonio bruto)
    public int GrossIncomeUvt { get; set; }   // numeral 2 (ingresos brutos)
    public int CreditCardUvt { get; set; }    // numeral 4
    public int PurchasesUvt { get; set; }     // numeral 5
    public int DepositsUvt { get; set; }      // numeral 6
}
```

### `PayrollTaxSummaryDto.cs` — lo que entrega nómina

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class PayrollTaxSummaryDto
{
    /// <summary>Casilla 30. Si el empleado ingresó a mitad de año, es su fecha de ingreso.</summary>
    public DateOnly PeriodFrom { get; set; }

    /// <summary>Casilla 31. Si se retiró a mitad de año, es su fecha de retiro.</summary>
    public DateOnly PeriodTo { get; set; }

    public IncomeConceptsDto Income { get; set; } = new();
    public ContributionsDto Contributions { get; set; } = new();

    /// <summary>Casilla 60.</summary>
    public decimal WithholdingAmount { get; set; }
}
```

### `IncomeWithholdingCertificateOptions.cs` — configuración del retenedor

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

public class IncomeWithholdingCertificateOptions
{
    public const string SectionName = "IncomeWithholdingCertificate";

    public string Nit { get; set; } = string.Empty;
    public string BusinessName { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string WithholdingPlace { get; set; } = string.Empty;   // 33
    public string DepartmentCode { get; set; } = string.Empty;     // 34 (DIVIPOLA)
    public string MunicipalityCode { get; set; } = string.Empty;   // 35 (DIVIPOLA)
    public string? DianLogoFileName { get; set; }

    /// <summary>Claves string ("2025") porque así llegan desde la configuración.</summary>
    public Dictionary<string, IncomeWithholdingThresholdsDto> ThresholdsByYear { get; set; } = new();

    /// <summary>
    /// Devuelve null si el año no está configurado. Es preferible fallar a expedir
    /// un certificado con topes de otro año.
    /// </summary>
    public IncomeWithholdingThresholdsDto? ResolveThresholds(int taxYear) =>
        ThresholdsByYear.TryGetValue(taxYear.ToString(), out var thresholds) ? thresholds : null;
}
```

### `IncomeWithholdingCertificateModelDto.cs` — ⭐ el modelo del PDF

```csharp
namespace DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

/// <summary>
/// Todo lo que el generador necesita, ya resuelto y formateable.
/// El generador no consulta nada: solo dibuja lo que hay aquí.
/// </summary>
public class IncomeWithholdingCertificateModelDto
{
    public int TaxYear { get; set; }
    public string? FormNumber { get; set; }                         // 4

    public WithholdingAgentDto Agent { get; set; } = new();         // 5–11
    public TaxWorkerDto Worker { get; set; } = new();               // 24–29

    public DateOnly PeriodFrom { get; set; }                        // 30
    public DateOnly PeriodTo { get; set; }                          // 31
    public DateOnly IssueDate { get; set; }                         // 32
    public string WithholdingPlace { get; set; } = string.Empty;    // 33
    public string DepartmentCode { get; set; } = string.Empty;      // 34
    public string MunicipalityCode { get; set; } = string.Empty;    // 35

    public IncomeConceptsDto Income { get; set; } = new();          // 36–52
    public ContributionsDto Contributions { get; set; } = new();    // 53–59
    public decimal WithholdingAmount { get; set; }                  // 60

    public OtherIncomeDto OtherIncome { get; set; } = new();        // 61–74

    /// <summary>Casilla 75: 60 + 74.</summary>
    public decimal TotalWithholdings => WithholdingAmount + OtherIncome.TotalWithheld;

    public IReadOnlyList<AssetDto> Assets { get; set; } = [];       // 76–77 (máximo 7)
    public decimal OutstandingDebts { get; set; }                   // 78
    public EconomicDependentDto? Dependent { get; set; }            // 79–82

    public IncomeWithholdingThresholdsDto Thresholds { get; set; } = new();
}
```

---

## 4. Paso 3 — Configuración en `appsettings.json`

```json
"IncomeWithholdingCertificate": {
  "Nit": "900000000",
  "BusinessName": "<Razón social del retenedor>",
  "PayerName": "<Razón social del retenedor>",
  "WithholdingPlace": "BOGOTA",
  "DepartmentCode": "11",
  "MunicipalityCode": "001",
  "DianLogoFileName": null,
  "ThresholdsByYear": {
    "2025": {
      "GrossEquityUvt": 4500,
      "GrossIncomeUvt": 1400,
      "CreditCardUvt": 1400,
      "PurchasesUvt": 1400,
      "DepositsUvt": 1400
    }
  }
}
```

- El NIT va **sin** DV: el DV se calcula (paso 4), así no pueden quedar desalineados.
- Cada enero, antes de expedir certificados del año que cerró, se agrega su bloque en `ThresholdsByYear`. Si falta, el Factory responde error en lugar de imprimir topes de otro año.

---

## 5. Paso 4 — Helpers

### `Helper/DianVerificationDigitHelper.cs` — casilla 6

Algoritmo oficial de módulo 11 de la DIAN:

```csharp
namespace DOCCB.Application.Features.Requests.Application.Helper;

public static class DianVerificationDigitHelper
{
    private static readonly int[] Weights = [3, 7, 13, 17, 19, 23, 29, 37, 41, 43, 47, 53, 59, 67, 71];

    public static string Calculate(string nit)
    {
        var digits = new string(nit.Where(char.IsDigit).ToArray());

        if (digits.Length == 0 || digits.Length > Weights.Length)
            throw new ArgumentException($"El NIT '{nit}' no es válido.", nameof(nit));

        var sum = 0;
        for (var i = 0; i < digits.Length; i++)
        {
            // Los pesos se aplican de derecha a izquierda.
            var digit = digits[digits.Length - 1 - i] - '0';
            sum += digit * Weights[i];
        }

        var remainder = sum % 11;
        return (remainder > 1 ? 11 - remainder : remainder).ToString();
    }
}
```

### `Helper/IncomeWithholdingCertificateMapper.cs`

```csharp
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

namespace DOCCB.Application.Features.Requests.Application.Helper;

public static class IncomeWithholdingCertificateMapper
{
    public static IncomeWithholdingCertificateModelDto ToModel(
        int taxYear,
        IncomeWithholdingCertificateOptions options,
        IncomeWithholdingThresholdsDto thresholds,
        TaxWorkerDto worker,
        PayrollTaxSummaryDto payroll,
        DateOnly issueDate)
    {
        return new IncomeWithholdingCertificateModelDto
        {
            TaxYear = taxYear,
            Agent = new WithholdingAgentDto
            {
                Nit = options.Nit,
                VerificationDigit = DianVerificationDigitHelper.Calculate(options.Nit),
                BusinessName = options.BusinessName,
                PayerName = options.PayerName
            },
            Worker = worker,
            PeriodFrom = payroll.PeriodFrom,
            PeriodTo = payroll.PeriodTo,
            IssueDate = issueDate,
            WithholdingPlace = options.WithholdingPlace,
            DepartmentCode = options.DepartmentCode,
            MunicipalityCode = options.MunicipalityCode,
            Income = payroll.Income,
            Contributions = payroll.Contributions,
            WithholdingAmount = payroll.WithholdingAmount,
            Thresholds = thresholds
        };
    }
}
```

### `Constants/IncomeWithholdingCertificateTexts.cs`

```csharp
namespace DOCCB.Application.Features.Requests.Application.Constants;

public static class IncomeWithholdingCertificateTexts
{
    public const string Title =
        "Certificado de Ingresos y Retenciones por Rentas de Trabajo y de Pensiones Año gravable ";

    public const string LegalNote =
        "Nota: este certificado sustituye para todos los efectos legales la declaración de Renta y " +
        "Complementario para el trabajador o pensionado que cumpla con lo establecido en el Art. " +
        "1.6.1.13.2.7. Dec. 1625 de 2016 Único reglamentario en materia tributaria. Para aquellos " +
        "trabajadores independientes contribuyentes del impuesto unificado deberán presentar la " +
        "declaración anual consolidada del Régimen Simple de Tributación (SIMPLE).";
}
```

---

## 6. Paso 5 — Contratos de datos

### `Interfaces/IPayrollTaxSummaryService.cs` — la fuente de nómina

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

namespace DOCCB.Application.Features.Requests.Application.Interfaces;

public interface IPayrollTaxSummaryService
{
    /// <summary>Acumulados del año gravable para un empleado.</summary>
    Task<ResponseDto<PayrollTaxSummaryDto>> GetAnnualSummaryAsync(string employeeCode, int taxYear);
}
```

> Este es el punto que más depende de terceros: los valores salen del maestro de nómina. La implementación se conecta a esa fuente. **No quemes valores** como en el salario de la carta laboral actual: un 220 con cifras de prueba que llegue a un empleado es un documento tributario falso. Si necesitas un stub para desarrollo, regístralo **solo** cuando `IHostEnvironment.IsDevelopment()`.

### Método nuevo en `IUserManagementService`

El formulario necesita apellidos y nombres separados y el tipo de documento DIAN:

```csharp
Task<ResponseDto<TaxWorkerDto>> GetUserTaxIdentificationAsync(string userEmail);
```

### `Interfaces/IIncomeWithholdingCertificateGenerationService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;

namespace DOCCB.Application.Features.Requests.Application.Interfaces;

public interface IIncomeWithholdingCertificateGenerationService
{
    Task<ResponseDto<byte[]>> GenerateIncomeWithholdingPdf(CreateIncomeWithholdingRequestDto request);
}
```

---

## 7. Paso 6 — ⭐ El generador QuestPDF

Replica la rejilla del formato: cada bloque es una tabla con sus propias columnas, apiladas dentro de un borde azul. Las filas de valores se generan desde arreglos `(casilla, concepto, selector)`, así el orden y los textos del formulario están en un solo lugar.

### `Services/IncomeWithholdingCertificateGenerationService.cs`

```csharp
using System.Globalization;
using DOCCB.Application.Features.Requests.Application.Constants;
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Requests.Application.Services
{
    public class IncomeWithholdingCertificateGenerationService(
        IncomeWithholdingCertificateModelDto model,
        string? dianLogoPath = null) : IDocument
    {
        private const string Blue = "#1D2AA2";
        private const string BlueSoft = "#3E6687";
        private const float LineWidth = 0.5f;
        private const int MaxAssets = 7;
        private static readonly CultureInfo Culture = new("es-CO");

        private readonly IncomeWithholdingCertificateModelDto _model = model;
        private readonly string? _dianLogoPath = dianLogoPath;

        // ── Filas del formulario: casilla, concepto y de dónde sale el valor ──────────

        private static readonly (int Box, string Concept, Func<IncomeConceptsDto, decimal> Value)[] IncomeRows =
        [
            (36, "Pagos por salarios", x => x.SalaryPayments),
            (37, "Pagos realizados con bonos electrónicos o de papel de servicio, cheques, tarjetas, vales etc.", x => x.BonusVoucherPayments),
            (38, "Valor del exceso de los pagos por alimentación mayores a 41 UVT, art. 387-1 E.T.", x => x.FoodExcessPayments),
            (39, "Pagos por honorarios", x => x.FeePayments),
            (40, "Pagos por servicios", x => x.ServicePayments),
            (41, "Pagos por comisiones", x => x.CommissionPayments),
            (42, "Pagos por prestaciones sociales", x => x.SocialBenefitPayments),
            (43, "Pagos por viáticos", x => x.TravelExpensePayments),
            (44, "Pagos por gastos de representación", x => x.RepresentationExpensePayments),
            (45, "Pagos por compensaciones por el trabajo asociado cooperativo", x => x.CooperativeWorkPayments),
            (46, "Otros pagos", x => x.OtherPayments),
            (47, "Auxilio de cesantía e intereses efectivamente pagados al empleado", x => x.SeveranceAndInterestPaid),
            (48, "Auxilio de cesantía reconocido a trabajadores del régimen tradicional del CST, contenido en el Capítulo VII, Título VIII Parte Primera", x => x.SeveranceTraditionalRegime),
            (49, "Auxilio de cesantía consignado al fondo de cesantías", x => x.SeveranceConsignedToFund),
            (50, "Pensiones de jubilación, vejez o invalidez", x => x.PensionPayments),
            (51, "Apoyos económicos educativos financiados con recursos públicos, no reembolsables o condonados", x => x.PublicEducationalSupport),
        ];

        private static readonly (int Box, string Concept, Func<ContributionsDto, decimal> Value)[] ContributionRows =
        [
            (53, "Aportes obligatorios por salud a cargo del trabajador", x => x.MandatoryHealth),
            (54, "Aportes obligatorios a fondos de pensiones y solidaridad pensional a cargo del trabajador", x => x.MandatoryPensionAndSolidarity),
            (55, "Cotizaciones voluntarias al régimen de ahorro individual con solidaridad - RAIS", x => x.VoluntaryRais),
            (56, "Aportes voluntarios a fondos de pensiones", x => x.VoluntaryPensionFunds),
            (57, "Aportes a cuentas AFC.", x => x.AfcAccounts),
            (58, "Aportes a cuentas AVC", x => x.AvcAccounts),
            (59, "Ingreso laboral promedio de los últimos seis meses anteriores (numeral 4 art. 206 E.T.)", x => x.AverageLaborIncomeLastSixMonths),
        ];

        private static readonly (int ReceivedBox, int WithheldBox, string Concept, Func<OtherIncomeDto, OtherIncomeLineDto> Line)[] OtherIncomeRows =
        [
            (61, 68, "Arrendamientos", x => x.Leases),
            (62, 69, "Honorarios, comisiones y servicios", x => x.FeesCommissionsServices),
            (63, 70, "Intereses y rendimientos financieros", x => x.FinancialInterest),
            (64, 71, "Enajenación de activos fijos", x => x.FixedAssetSales),
            (65, 72, "Loterías, rifas, apuestas y similares", x => x.LotteriesAndBets),
            (66, 73, "Otros", x => x.Other),
        ];

        // ── API pública (mismo contrato que el generador laboral) ─────────────────────

        public byte[] GeneratePdf() =>
            Document.Create(Compose).WithMetadata(GetMetadata()).GeneratePdf();

        public DocumentMetadata GetMetadata() => new()
        {
            Title = $"Formulario 220 - Año gravable {_model.TaxYear}",
            Author = _model.Agent.BusinessName,
            Subject = "Certificado de Ingresos y Retenciones"
        };

        public void Compose(IDocumentContainer container)
        {
            container.Page(page =>
            {
                page.Size(PageSizes.Letter);
                page.MarginVertical(0.3f, Unit.Inch);
                page.MarginHorizontal(0.4f, Unit.Inch);
                page.DefaultTextStyle(x => x.FontFamily("Arial").FontSize(7).LineHeight(1.05f));

                // Sin page.Header() ni page.Footer(): es un formato oficial, no lleva marca corporativa.
                page.Content().Column(column =>
                {
                    column.Item().Border(1.5f).BorderColor(Blue).Column(form =>
                    {
                        form.Item().Element(ComposeHeader);
                        form.Item().Element(ComposeNotice);
                        form.Item().Element(ComposeWithholdingAgent);
                        form.Item().Element(ComposeWorker);
                        form.Item().Element(ComposePeriod);
                        form.Item().Element(ComposeIncomeAndContributions);
                        form.Item().Element(ComposePayer);
                        form.Item().Element(ComposeOtherIncome);
                        form.Item().Element(ComposeAssets);
                        form.Item().Element(ComposeDebts);
                        form.Item().Element(ComposeDependent);
                        form.Item().Element(ComposeCertificationAndSignature);
                    });

                    column.Item().PaddingTop(5)
                        .Text(IncomeWithholdingCertificateTexts.LegalNote)
                        .FontSize(6).Bold();
                });
            });
        }

        // ── Bloques ───────────────────────────────────────────────────────────────────

        private void ComposeHeader(IContainer container)
        {
            container.Height(40).Row(row =>
            {
                row.ConstantItem(90).Element(BoxStyle).AlignMiddle().AlignCenter().Element(logo =>
                {
                    if (!string.IsNullOrEmpty(_dianLogoPath) && File.Exists(_dianLogoPath))
                    {
                        logo.Image(_dianLogoPath).FitArea();
                    }
                });

                row.RelativeItem().Element(BoxStyle).AlignMiddle().AlignCenter().Text(text =>
                {
                    text.AlignCenter();
                    text.Span(IncomeWithholdingCertificateTexts.Title).Bold().FontSize(9.5f);
                    text.Span(_model.TaxYear.ToString()).Bold().FontSize(9.5f).Underline();
                });

                row.ConstantItem(110).Background(BlueSoft).BorderBottom(LineWidth)
                    .AlignMiddle().AlignCenter()
                    .Text("220").FontSize(30).Bold().FontColor(Colors.White);
            });
        }

        private void ComposeNotice(IContainer container)
        {
            container.Row(row =>
            {
                row.RelativeItem().Element(BoxStyle).AlignMiddle().AlignCenter()
                    .Text("Antes de diligenciar este formulario lea cuidadosamente las instrucciones")
                    .FontSize(6);

                row.RelativeItem().Element(c => LabeledValue(c, "4. Número de formulario", _model.FormNumber));
            });
        }

        private void ComposeWithholdingAgent(IContainer container)
        {
            var agent = _model.Agent;

            container.Table(table =>
            {
                table.ColumnsDefinition(columns =>
                {
                    columns.ConstantColumn(18);
                    columns.RelativeColumn(1.3f);
                    columns.RelativeColumn(0.25f);
                    columns.RelativeColumn(0.95f);
                    columns.RelativeColumn(0.95f);
                    columns.RelativeColumn(0.82f);
                    columns.RelativeColumn(0.95f);
                });

                table.Cell().RowSpan(2).Element(c => VerticalLabel(c, "Retenedor"));
                table.Cell().Element(c => LabeledValue(c, "5. Número de Identificación Tributaria (NIT):", agent.Nit));
                table.Cell().Element(c => LabeledValue(c, "6. DV.", agent.VerificationDigit, center: true));
                table.Cell().Element(c => LabeledValue(c, "7. Primer Apellido", agent.FirstLastName));
                table.Cell().Element(c => LabeledValue(c, "8. Segundo Apellido", agent.SecondLastName));
                table.Cell().Element(c => LabeledValue(c, "9. Primer Nombre", agent.FirstName));
                table.Cell().Element(c => LabeledValue(c, "10. Otros Nombres", agent.OtherNames));

                table.Cell().ColumnSpan(6).Element(c => LabeledValue(c, "11. Razón Social", agent.BusinessName));
            });
        }

        private void ComposeWorker(IContainer container)
        {
            var worker = _model.Worker;

            container.Table(table =>
            {
                table.ColumnsDefinition(columns =>
                {
                    columns.ConstantColumn(18);
                    columns.RelativeColumn(0.55f);
                    columns.RelativeColumn(1.8f);
                    columns.RelativeColumn(0.82f);
                    columns.RelativeColumn(1.02f);
                    columns.RelativeColumn(0.78f);
                    columns.RelativeColumn(0.85f);
                });

                table.Cell().Element(c => VerticalLabel(c, "Trabajador"));
                table.Cell().Element(c => LabeledValue(c, "24. Tipo de documento", ((int)worker.DocumentType).ToString()));
                table.Cell().Element(c => LabeledValue(c, "25. Número de identificación", worker.DocumentNumber));
                table.Cell().Element(c => LabeledValue(c, "26. Primer apellido", worker.FirstLastName));
                table.Cell().Element(c => LabeledValue(c, "27. Segundo apellido", worker.SecondLastName));
                table.Cell().Element(c => LabeledValue(c, "28. Primer Nombre", worker.FirstName));
                table.Cell().Element(c => LabeledValue(c, "29. Otros Nombres", worker.OtherNames));
            });
        }

        private void ComposePeriod(IContainer container)
        {
            container.Table(table =>
            {
                table.ColumnsDefinition(columns =>
                {
                    columns.RelativeColumn(1.6f);
                    columns.RelativeColumn(1.2f);
                    columns.RelativeColumn(1.6f);
                    columns.RelativeColumn(0.45f);
                    columns.RelativeColumn(0.45f);
                });

                table.Cell().Element(BoxStyle).Column(column =>
                {
                    column.Item().AlignCenter().Text("Periodo de la Certificación").FontSize(5.5f);
                    column.Item().PaddingTop(2).Text(text =>
                    {
                        text.Span("30. DE: ").Bold();
                        text.Span(FormatDate(_model.PeriodFrom)).FontSize(8);
                        text.Span("     31. A: ").Bold();
                        text.Span(FormatDate(_model.PeriodTo)).FontSize(8);
                    });
                });

                table.Cell().Element(c => LabeledValue(c, "32. Fecha de Expedición", FormatDate(_model.IssueDate)));
                table.Cell().Element(c => LabeledValue(c, "33. Lugar donde se practicó la retención", _model.WithholdingPlace, center: true));
                table.Cell().Element(c => LabeledValue(c, "34. Cód Dpto.", _model.DepartmentCode, center: true));
                table.Cell().Element(c => LabeledValue(c, "35. Cód. Ciudad/Municipio", _model.MunicipalityCode, center: true));
            });
        }

        private void ComposeIncomeAndContributions(IContainer container)
        {
            container.Table(table =>
            {
                table.ColumnsDefinition(columns =>
                {
                    columns.RelativeColumn();
                    columns.ConstantColumn(22);
                    columns.ConstantColumn(150);
                });

                SectionHeader(table, "Concepto de los Ingresos");
                foreach (var row in IncomeRows)
                {
                    MoneyRow(table, row.Box, row.Concept, row.Value(_model.Income));
                }
                MoneyRow(table, 52, "Total de ingresos brutos (Sume casillas 36 a 51)", _model.Income.TotalGrossIncome, bold: true);

                SectionHeader(table, "Concepto de los aportes");
                foreach (var row in ContributionRows)
                {
                    MoneyRow(table, row.Box, row.Concept, row.Value(_model.Contributions));
                }

                HighlightRow(table, 60, "Valor de la retención en la fuente por rentas de trabajo y de pensiones", _model.WithholdingAmount);
            });
        }

        private void ComposePayer(IContainer container) =>
            container.Element(c => LabeledValue(c, "Nombre del pagador o agente retenedor", _model.Agent.PayerName));

        private void ComposeOtherIncome(IContainer container)
        {
            var other = _model.OtherIncome;

            container.Column(column =>
            {
                column.Item().Element(BoxStyle).AlignCenter()
                    .Text("Datos a cargo del trabajador o pensionado").Bold().FontSize(8);

                column.Item().Table(table =>
                {
                    table.ColumnsDefinition(columns =>
                    {
                        columns.RelativeColumn();
                        columns.ConstantColumn(22);
                        columns.ConstantColumn(100);
                        columns.ConstantColumn(22);
                        columns.ConstantColumn(100);
                    });

                    table.Cell().Element(BoxStyle).AlignCenter().Text("Concepto de otros ingresos").Bold();
                    table.Cell().Element(BoxStyle);
                    table.Cell().Element(BoxStyle).AlignCenter().Text("Valor recibido").Bold();
                    table.Cell().Element(BoxStyle);
                    table.Cell().Element(BoxStyle).AlignCenter().Text("Valor retenido").Bold();

                    foreach (var row in OtherIncomeRows)
                    {
                        var line = row.Line(other);
                        table.Cell().Element(BoxStyle).Text(row.Concept);
                        table.Cell().Element(BoxStyle).AlignCenter().Text(row.ReceivedBox.ToString());
                        table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(line.Received));
                        table.Cell().Element(BoxStyle).AlignCenter().Text(row.WithheldBox.ToString());
                        table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(line.Withheld));
                    }

                    table.Cell().Element(BoxStyle)
                        .Text("Totales: (Valor recibido: Sume casillas 61 a 66), (Valor retenido: Sume casillas 68 a 73)").Bold();
                    table.Cell().Element(BoxStyle).AlignCenter().Text("67").Bold();
                    table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(other.TotalReceived)).Bold();
                    table.Cell().Element(BoxStyle).AlignCenter().Text("74").Bold();
                    table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(other.TotalWithheld)).Bold();

                    table.Cell().ColumnSpan(3).Element(BoxStyle)
                        .Text($"Total retenciones año gravable {_model.TaxYear} (Sume 60 + 74)").Bold();
                    table.Cell().Element(BoxStyle).AlignCenter().Text("75").Bold();
                    table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(_model.TotalWithholdings)).Bold();
                });
            });
        }

        private void ComposeAssets(IContainer container)
        {
            container.Table(table =>
            {
                table.ColumnsDefinition(columns =>
                {
                    columns.ConstantColumn(22);
                    columns.RelativeColumn();
                    columns.ConstantColumn(120);
                });

                table.Cell().Element(BoxStyle).AlignCenter().Text("Item").Bold();
                table.Cell().Element(BoxStyle).AlignCenter().Text("76. Identificación de los bienes poseídos").Bold();
                table.Cell().Element(BoxStyle).AlignCenter().Text("77. Valor Patrimonial").Bold();

                // Siempre 7 filas, como el formato oficial, aunque vengan menos bienes.
                for (var i = 0; i < MaxAssets; i++)
                {
                    var asset = i < _model.Assets.Count ? _model.Assets[i] : null;

                    table.Cell().Element(BoxStyle).AlignCenter().Text((i + 1).ToString());
                    table.Cell().Element(BoxStyle).Text(asset?.Description ?? string.Empty);
                    table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(asset?.PatrimonialValue ?? 0));
                }
            });
        }

        private void ComposeDebts(IContainer container)
        {
            container.Row(row =>
            {
                row.RelativeItem().Background(Blue).Element(BoxStyle)
                    .Text("Deudas vigentes a 31 de Diciembre").Bold().FontColor(Colors.White);
                row.ConstantItem(22).Element(BoxStyle).AlignCenter().Text("78");
                row.ConstantItem(120).Element(BoxStyle).AlignRight().Text(FormatMoney(_model.OutstandingDebts));
            });
        }

        private void ComposeDependent(IContainer container)
        {
            var dependent = _model.Dependent;

            container.Column(column =>
            {
                column.Item().Element(BoxStyle).AlignCenter()
                    .Text("Identificación del dependiente económico de acuerdo al parágrafo 2 del artículo 387 del Estatuto Tributario")
                    .Bold();

                column.Item().Table(table =>
                {
                    table.ColumnsDefinition(columns =>
                    {
                        columns.ConstantColumn(105);
                        columns.ConstantColumn(75);
                        columns.RelativeColumn();
                        columns.ConstantColumn(115);
                    });

                    table.Cell().Element(c => LabeledValue(c, "79. Tipo documento",
                        dependent is null ? null : ((int)dependent.DocumentType).ToString()));
                    table.Cell().Element(c => LabeledValue(c, "80. No. Documento", dependent?.DocumentNumber));
                    table.Cell().Element(c => LabeledValue(c, "81. Apellidos y Nombres", dependent?.FullName));
                    table.Cell().Element(c => LabeledValue(c, "82. Parentesco", dependent?.Relationship));
                });
            });
        }

        private void ComposeCertificationAndSignature(IContainer container)
        {
            container.Row(row =>
            {
                row.RelativeItem(2.1f).MinHeight(105).Element(BoxStyle)
                    .Text(BuildCertificationText()).FontSize(6);

                // La firma es del TRABAJADOR: el recuadro va vacío, sin imagen.
                row.RelativeItem(1).MinHeight(105).Element(BoxStyle)
                    .Text("Firma del Trabajador o Pensionado").FontSize(7);
            });
        }

        private string BuildCertificationText()
        {
            var t = _model.Thresholds;

            return string.Join('\n',
                "Certifico que durante el año gravable:",
                $"1. Mi patrimonio bruto era igual o inferior a {FormatUvt(t.GrossEquityUvt)} UVT",
                $"2. Mis ingresos brutos fueron inferiores a {FormatUvt(t.GrossIncomeUvt)} UVT",
                "3. No fui responsable del impuesto sobre las ventas a 31 de diciembre del año gravable",
                $"4. Mis consumos mediante tarjeta de crédito no excedieron la suma de {FormatUvt(t.CreditCardUvt)} UVT.",
                $"5. Que el total de mis compras y consumos no superaron la suma de {FormatUvt(t.PurchasesUvt)} UVT.",
                $"6. Que el valor total de mis consignaciones bancarias, depósitos o inversiones financieras no excedieron los {FormatUvt(t.DepositsUvt)} UVT",
                "Por lo tanto, manifiesto que no estoy obligado a presentar declaración de renta y complementario por el año gravable.");
        }

        // ── Piezas reutilizables ──────────────────────────────────────────────────────

        /// <summary>Celda del formulario: borde inferior y derecho, alto mínimo y padding.</summary>
        private static IContainer BoxStyle(IContainer container) =>
            container
                .BorderBottom(LineWidth).BorderRight(LineWidth).BorderColor(Colors.Black)
                .MinHeight(11)
                .PaddingHorizontal(3).PaddingVertical(2);

        /// <summary>Etiqueta pequeña arriba ("5. Número de...") y valor debajo.</summary>
        private static void LabeledValue(IContainer container, string label, string? value, bool center = false)
        {
            container.Element(BoxStyle).Column(column =>
            {
                column.Item().Text(label).FontSize(5.5f);

                var valueContainer = column.Item().PaddingTop(2);
                if (center)
                {
                    valueContainer = valueContainer.AlignCenter();
                }
                valueContainer.Text(value ?? string.Empty).FontSize(8);
            });
        }

        private static void VerticalLabel(IContainer container, string text) =>
            container.Element(BoxStyle).AlignMiddle().AlignCenter().RotateLeft()
                .Text(text).Bold().FontSize(6.5f);

        private static void SectionHeader(TableDescriptor table, string title)
        {
            table.Cell().Element(BoxStyle).AlignCenter().Text(title).Bold().FontSize(7.5f);
            table.Cell().Element(BoxStyle);
            table.Cell().Element(BoxStyle).AlignCenter().Text("Valor").Bold().FontSize(7.5f);
        }

        private static void MoneyRow(TableDescriptor table, int box, string concept, decimal value, bool bold = false)
        {
            var conceptText = table.Cell().Element(BoxStyle).Text(concept);
            var boxText = table.Cell().Element(BoxStyle).AlignCenter().Text(box.ToString());
            var valueText = table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(value));

            if (bold)
            {
                conceptText.Bold();
                boxText.Bold();
                valueText.Bold();
            }
        }

        private static void HighlightRow(TableDescriptor table, int box, string concept, decimal value)
        {
            // Background ANTES del padding para que el azul llene toda la celda.
            table.Cell().Background(Blue).Element(BoxStyle).Text(concept).Bold().FontColor(Colors.White);
            table.Cell().Element(BoxStyle).AlignCenter().Text(box.ToString()).Bold();
            table.Cell().Element(BoxStyle).AlignRight().Text(FormatMoney(value)).Bold();
        }

        /// <summary>Pesos sin decimales; el cero se imprime como "-", igual que el formato oficial.</summary>
        private static string FormatMoney(decimal value) =>
            value == 0 ? "-" : value.ToString("N0", Culture);

        private static string FormatUvt(int uvt) => uvt.ToString("N0", Culture);

        private static string FormatDate(DateOnly date) =>
            date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }
}
```

---

## 8. Paso 7 — ⭐ El Factory

Mismo rol que `LaborCertificateGenerationFactory`: consulta, valida, arma el modelo y le pasa el trabajo al generador. Dos diferencias deliberadas frente al laboral:

1. **Las llamadas externas van fuera de la transacción.** Dentro de `ExecuteQueryAsync` solo se consulta y valida la solicitud; nómina y gestión de usuarios se llaman después, para no mantener abierta una transacción de base de datos mientras se espera a otro servicio.
2. **Las rutas se arman con `Path.Combine`**, no concatenando `\\`, que se rompe en contenedores Linux.

### `Services/IncomeWithholdingCertificateGenerationFactory.cs`

```csharp
using Microsoft.Extensions.Configuration;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.Requests.Application.DTOs.IncomeWithholding;
using DOCCB.Application.Features.Requests.Application.Helper;
using DOCCB.Application.Features.Requests.Application.Interfaces;
using DOCCB.Application.Features.UserManagement.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.Requests.Application.Services
{
    public class IncomeWithholdingCertificateGenerationFactory(
        IConfiguration configuration,
        ITransactionExecutorHelper transactionHelper,
        IUserManagementService userManagementService,
        IPayrollTaxSummaryService payrollTaxSummaryService
        ) : IIncomeWithholdingCertificateGenerationService
    {
        /// <summary>Cuántos años gravables hacia atrás se pueden certificar. Confirmar con Gestión Humana.</summary>
        private const int MaxYearsBack = 5;

        private readonly IConfiguration _configuration = configuration;
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly IUserManagementService _userManagementService = userManagementService;
        private readonly IPayrollTaxSummaryService _payrollTaxSummaryService = payrollTaxSummaryService;

        public async Task<ResponseDto<byte[]>> GenerateIncomeWithholdingPdf(CreateIncomeWithholdingRequestDto request)
        {
            var options = _configuration
                .GetSection(IncomeWithholdingCertificateOptions.SectionName)
                .Get<IncomeWithholdingCertificateOptions>();

            if (options is null || string.IsNullOrWhiteSpace(options.Nit))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<byte[]>(
                    "Falta la configuración del retenedor para el certificado de ingresos y retenciones.");
            }

            var thresholds = options.ResolveThresholds(request.TaxYear);
            if (thresholds is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<byte[]>(
                    $"No hay topes UVT configurados para el año gravable {request.TaxYear}.");
            }

            var modelResponse = await GetCertificateModel(request, options, thresholds);

            if (modelResponse is null || modelResponse.HasError)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<byte[]>(
                    modelResponse?.Errors ?? ["Error al obtener la información del certificado."]);
            }

            var generator = new IncomeWithholdingCertificateGenerationService(
                modelResponse.Response,
                ResolveAssetPath(options.DianLogoFileName));

            return ResponseDtoHelper.CreateSuccessResponseDto(generator.GeneratePdf());
        }

        private async Task<ResponseDto<IncomeWithholdingCertificateModelDto>?> GetCertificateModel(
            CreateIncomeWithholdingRequestDto dto,
            IncomeWithholdingCertificateOptions options,
            IncomeWithholdingThresholdsDto thresholds)
        {
            // 1) Dentro de la transacción: solo la solicitud y su validación.
            var requestResponse = await _transactionHelper.ExecuteQueryAsync<ResponseDto<Request>?>(
                async unitOfWork =>
                {
                    var request = await unitOfWork.Repository<Request>().GetAsync(
                        expr: r => r.Id == dto.RequestId && !r.Removed,
                        includeList: [i => i.RequestType, i => i.User, i => i.History]);

                    if (request is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<Request>(
                            $"La solicitud con ID {dto.RequestId} no fue encontrada.");
                    }

                    var (isValid, validationMessage) = IsValidGeneration(request, dto);

                    return isValid
                        ? ResponseDtoHelper.CreateSuccessResponseDto(request)
                        : ResponseDtoHelper.CreateErrorResponseDto<Request>(validationMessage);
                });

            if (requestResponse is null || requestResponse.HasError)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<IncomeWithholdingCertificateModelDto>(
                    requestResponse?.Errors ?? ["Error al validar la solicitud."]);
            }

            // 2) Fuera de la transacción: servicios externos.
            var payroll = await _payrollTaxSummaryService.GetAnnualSummaryAsync(
                requestResponse.Response.User.UserCode, dto.TaxYear);

            if (payroll.HasError || payroll.Response is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<IncomeWithholdingCertificateModelDto>(
                    payroll.Errors ?? [$"No hay información de nómina para el año gravable {dto.TaxYear}."]);
            }

            var worker = await _userManagementService.GetUserTaxIdentificationAsync(dto.UserEmail);

            if (worker.HasError || worker.Response is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<IncomeWithholdingCertificateModelDto>(
                    worker.Errors ?? ["No se encontró la identificación tributaria del trabajador."]);
            }

            var model = IncomeWithholdingCertificateMapper.ToModel(
                dto.TaxYear,
                options,
                thresholds,
                worker.Response,
                payroll.Response,
                issueDate: DateOnly.FromDateTime(DateTime.Today));

            return ResponseDtoHelper.CreateSuccessResponseDto(model);
        }

        private static (bool IsValid, string Message) IsValidGeneration(
            Request request, CreateIncomeWithholdingRequestDto dto)
        {
            if (!request.User.CorportativeEmail.Equals(dto.UserEmail, StringComparison.OrdinalIgnoreCase))
            {
                return (false, "El usuario no tiene permisos para acceder a esta solicitud.");
            }

            if (request.Status != RequestStatus.Approved.ToString() && !dto.IsApproved)
            {
                return (false, "La solicitud no ha sido aprobada.");
            }

            var currentYear = DateTime.Today.Year;

            if (dto.TaxYear >= currentYear)
            {
                return (false, $"El año gravable {dto.TaxYear} aún no ha cerrado.");
            }

            if (dto.TaxYear < currentYear - MaxYearsBack)
            {
                return (false, $"Solo se pueden expedir certificados de los últimos {MaxYearsBack} años gravables.");
            }

            return (true, string.Empty);
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

> La carta laboral tiene una regla de "vigencia de un mes desde la aprobación". El 220 **no** la lleva: certifica un año cerrado y su contenido no caduca.

---

## 9. Paso 8 — Registro de dependencias

En `ApplicationServiceRegistration.cs`, junto al registro del certificado laboral:

```csharp
services.AddScoped<IIncomeWithholdingCertificateGenerationService, IncomeWithholdingCertificateGenerationFactory>();
services.AddScoped<IPayrollTaxSummaryService, PayrollTaxSummaryService>();
```

---

## 10. Paso 9 — Endpoint

En `WebApp/Controllers/CertificateController.cs`:

```csharp
[HttpPost("ingresos-retenciones")]
public async Task<IActionResult> GenerateIncomeWithholdingCertificate(
    [FromBody] CreateIncomeWithholdingRequestDto request)
{
    // El correo sale del token, nunca del body.
    request.UserEmail = _userAuthenticator.GetCurrentUserEmail(User);

    var response = await _incomeWithholdingService.GenerateIncomeWithholdingPdf(request);

    return response.HasError ? BadRequest(response) : Ok(response);
}
```

Usa el helper de autenticación y el atributo de permisos que ya usan las demás acciones del controlador.

---

## 11. Pruebas

### Dígito de verificación

```csharp
[Theory]
[InlineData("800197268", "4")]   // NIT de la DIAN
[InlineData("800.197.268", "4")] // con puntos
public void Calcula_el_digito_de_verificacion(string nit, string expected) =>
    Assert.Equal(expected, DianVerificationDigitHelper.Calculate(nit));
```

Agrega también el NIT de la compañía con el DV que figura en su RUT.

### Casillas calculadas

```csharp
[Fact]
public void Calcula_las_casillas_52_67_74_y_75()
{
    var model = new IncomeWithholdingCertificateModelDto
    {
        Income = new IncomeConceptsDto { SalaryPayments = 60_000_000, SocialBenefitPayments = 10_000_000 },
        WithholdingAmount = 1_500_000,
        OtherIncome = new OtherIncomeDto
        {
            Leases = new OtherIncomeLineDto { Received = 12_000_000, Withheld = 400_000 }
        }
    };

    Assert.Equal(70_000_000, model.Income.TotalGrossIncome);   // 52
    Assert.Equal(12_000_000, model.OtherIncome.TotalReceived); // 67
    Assert.Equal(400_000, model.OtherIncome.TotalWithheld);    // 74
    Assert.Equal(1_900_000, model.TotalWithholdings);          // 75
}
```

### Generación

```csharp
[Fact]
public void Genera_un_pdf_valido()
{
    var generator = new IncomeWithholdingCertificateGenerationService(TestData.IncomeWithholdingModel());

    var pdf = generator.GeneratePdf();

    Assert.Equal("%PDF", Encoding.ASCII.GetString(pdf, 0, 4));
}
```

### Revisión visual

- Genera un PDF con todos los valores en cero y compáralo lado a lado con el ejemplo: todas las casillas deben mostrar `-`.
- Genera otro con valores de 11 dígitos en todas las casillas: ninguno debe cortarse ni empujar el formulario a una segunda página.
- Usa `QuestPDF.Settings.EnableDebugging = true` si aparece `DocumentLayoutException`.

---

## 12. Hallazgos en el generador laboral existente

Aparecieron al revisar el código base para este documento. Los primeros dos afectan también al 220 si se copia el patrón sin cambios:

| # | Hallazgo | Riesgo | Corrección |
|---|---|---|---|
| 1 | `IsApproved` llega del body de la petición | Un cliente que envía `"isApproved": true` se salta la validación de aprobación | `[JsonIgnore]` en el DTO; solo se asigna en llamadas internas |
| 2 | `UserEmail` en el DTO de entrada | Si el controlador no lo sobreescribe desde el token, cualquiera pide el certificado de otro | Asignarlo siempre desde los claims en el controlador |
| 3 | Rutas con `\\` concatenado | Fallan en contenedores Linux | `Path.Combine` |
| 4 | Salario quemado en `"2000000"` | Un documento con cifras falsas puede llegar a un empleado | Conectar al maestro o bloquear la opción "con salario" hasta que exista |
| 5 | `ComposeContent` y `ComposeContentWithSalary` repiten casi todo | Un cambio de texto hay que hacerlo dos veces | Un solo método con el bloque de salario condicional |
| 6 | Llamada a `IUserManagementService` dentro de la transacción | Transacción abierta mientras se espera otro servicio | Consultar fuera, como en el Factory del 220 |

---

## ✅ Checklist

- [ ] Tabla de códigos de `DianDocumentType` validada contra la resolución DIAN del año gravable.
- [ ] Sección `IncomeWithholdingCertificate` en `appsettings.json` de todos los ambientes, con el año gravable en `ThresholdsByYear`.
- [ ] NIT configurado sin DV; test del DV con el NIT de la compañía.
- [ ] `IPayrollTaxSummaryService` conectado al maestro de nómina, sin valores quemados.
- [ ] Nombres y apellidos del trabajador vienen como campos separados.
- [ ] `IsApproved` y `UserEmail` con `[JsonIgnore]`; el correo se asigna desde el token.
- [ ] Casillas 52, 67, 74 y 75 calculadas, no recibidas.
- [ ] Ceros impresos como `-`; montos con separador de miles `es-CO`.
- [ ] El formulario completo cabe en una hoja carta con valores de 11 dígitos.
- [ ] Recuadro de firma del trabajador vacío; sin header ni footer corporativos.
- [ ] Endpoint con el atributo de permisos del controlador y documentado en Swagger.
- [ ] Revisión de un certificado real con Gestión Humana o Contabilidad antes de liberar.
