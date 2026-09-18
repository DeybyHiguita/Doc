# 📄 Generación de PDF con QuestPDF — DOCCB Backend

Guía paso a paso para implementar la generación de PDF en **DOCCB**, respetando la arquitectura documentada en `Arquitectura DOCCB Backend`.

El caso concreto es el **certificado laboral**, pero la base queda lista para cualquier otro documento. Lo único compartido entre todos los PDF es el **header** y el **footer**; el contenido y el bloque de firma los define cada documento.

> **Nomenclatura:** en este documento y en el código se usa **DOC** como nombre corto del sistema. No se usa el nombre de la concesionaria en código, configuración ni documentación: la razón social va en `appsettings.json`, nunca quemada en clases.

- **Stack:** .NET 8 · ASP.NET Core · Entity Framework Core · QuestPDF
- **Proyectos:** `WebApp` · `DOCCB.Application` · `DOCCB.Domain` · `DOCCB.Infraestructure`

---

## 🎯 Objetivo

1. Un **header y un footer únicos** para todos los PDF del sistema (imagen o texto, configurables).
2. Un **documento base** que fije página, márgenes, header y footer, dejando libre solo el contenido.
3. Un **bloque de firma reutilizable** que acepta imagen de firma escaneada.
4. Agregar un PDF nuevo = **3 archivos + 1 línea de DI**.

---

## 🧭 Dónde vive cada pieza (y por qué)

DOCCB ya tiene un precedente claro: `IExcelReportGenerator` vive en `DOCCB.Application/Features/Reports/Application/`, **no** en Infraestructure. En esta arquitectura `DOCCB.Infraestructure` es exclusivamente persistencia (DbContext, Configurations, Repositories, UnitOfWork); los generadores de artefactos son servicios de aplicación.

**Por consistencia, el PDF sigue el mismo camino que el Excel.**

| Pieza | Ubicación | Por qué |
|---|---|---|
| Base PDF: header, footer, firma, documento base | `DOCCB.Application/Features/Pdf/` | Feature transversal, igual que `Features/Common` y `Features/EmailsTemplate`. |
| Assets (logo, firmas, fuentes) | `DOCCB.Application/Features/Pdf/Assets/` | Mismo patrón que `Features/EmailsTemplate/Assets/`. |
| Documento concreto (certificado laboral) | `DOCCB.Application/Features/Certificates/Application/` | "Todo lo de una característica, junto". |
| Datos del empleado | `IUnitOfWork.Repository<User>()` | Regla: los servicios no tocan el `DbContext`. |
| Endpoint | `WebApp/Controllers/CertificateController.cs` | Ya existe; se le agrega una acción. |
| Configuración de marca | `appsettings.json` → sección `Pdf` | Nada de textos institucionales en el código. |

> **Alternativa purista:** mover todo lo de QuestPDF a `DOCCB.Infraestructure/Pdf/`. Es defendible, pero rompe la simetría con `IExcelReportGenerator`. Si el equipo decide eso, **mueve también el Excel** — lo que no conviene es tener dos criterios distintos para el mismo problema.

---

## ✅ Antes de empezar: 3 verificaciones

QuestPDF **ya figura como dependencia del proyecto** y existe `ICesantiasCertificateGenerationService` en `Features/Requests/Application/Interfaces/`. Antes de escribir código:

1. **¿Dónde está referenciado QuestPDF?**
   ```bash
   grep -r "QuestPDF" --include="*.csproj" .
   ```
   Anota el proyecto y la versión. Esta guía asume la API de QuestPDF **2024.x–2025.x**. Si la versión es anterior a 2023.4, revisa la sección de compatibilidad al final.

2. **¿Cómo genera hoy el certificado de cesantías?**
   ```bash
   grep -rn "Cesantias" --include="*.cs" DOCCB.Application/
   ```
   Si ya arma un `IDocument` de QuestPDF, **no dupliques**: la sección 12 explica cómo migrarlo a la base compartida para que herede el mismo header y footer.

3. **¿La licencia está en regla?**
   QuestPDF es gratis bajo licencia **Community** solo si la organización factura menos de **USD 1M anuales**. Por encima de ese umbral se requiere licencia **Professional / Enterprise** de pago. Para una concesión aeroportuaria esto casi con seguridad aplica. **Confírmalo con el líder técnico antes de subir a producción** — es una decisión de negocio, no técnica.

---

## 📁 Estructura de archivos a crear

```
DOCCB.Application/
├── Features/
│   ├── Pdf/                                          ⭐ base compartida
│   │   ├── Assets/
│   │   │   ├── logo.png                              (header)
│   │   │   ├── footer-logo.png                       (opcional)
│   │   │   └── firmas/firma-gerente-gh.png
│   │   └── Application/
│   │       ├── Constants/PdfConstants.cs
│   │       ├── DTOs/
│   │       │   ├── PdfFileDto.cs
│   │       │   └── PdfBrandingOptions.cs
│   │       ├── Interfaces/
│   │       │   ├── IPdfGeneratorService.cs
│   │       │   ├── IPdfDocumentBuilder.cs
│   │       │   └── IPdfAssetProvider.cs
│   │       ├── Documents/
│   │       │   ├── BasePdfDocument.cs                ⭐ header + footer para todos
│   │       │   ├── PdfPalette.cs
│   │       │   └── Components/
│   │       │       ├── PdfHeaderComponent.cs
│   │       │       ├── PdfFooterComponent.cs
│   │       │       └── SignatureBlockComponent.cs
│   │       └── Services/
│   │           ├── PdfGeneratorService.cs
│   │           └── FileSystemPdfAssetProvider.cs
│   │
│   └── Certificates/                                 ⭐ un PDF concreto
│       └── Application/
│           ├── DTOs/
│           │   ├── LaborCertificateRequestDto.cs
│           │   └── LaborCertificateModel.cs
│           ├── Documents/
│           │   ├── LaborCertificateDocument.cs
│           │   └── LaborCertificateDocumentBuilder.cs
│           ├── Interfaces/ILaborCertificateService.cs
│           └── Services/LaborCertificateService.cs
│
└── ApplicationServiceRegistration.cs                 (+ 5 líneas)

WebApp/
├── Controllers/CertificateController.cs              (+ 1 acción)
└── appsettings.json                                  (+ sección "Pdf")
```

---

## 🔄 Flujo de datos

```
┌──────────────────────────────────────────┐
│  CertificateController.GenerateLabor()   │  ← HTTP + token Azure AD
└───────────────┬──────────────────────────┘
                │ LaborCertificateRequestDto
                ▼
┌──────────────────────────────────────────┐
│  ILaborCertificateService                │  ← reglas del certificado
│   · valida                               │
│   · IUnitOfWork.Repository<User>()       │
│   · arma LaborCertificateModel           │
└───────────────┬──────────────────────────┘
                │ modelo
                ▼
┌──────────────────────────────────────────┐
│  IPdfGeneratorService                    │  ← único punto de generación
│   └─ IPdfDocumentBuilder<TModel>         │  ← resuelve logo y firma
│       └─ BasePdfDocument<TModel>         │  ← header + footer comunes
│           └─ ComposeContent()            │  ← lo propio de cada PDF
└───────────────┬──────────────────────────┘
                │ PdfFileDto (byte[] + nombre)
                ▼
        ResponseDto<PdfFileDto>  ó  File(...)
```

---

## 1️⃣ Paso 1 — Configuración de marca

### `Features/Pdf/Application/DTOs/PdfBrandingOptions.cs`

```csharp
namespace DOCCB.Application.Features.Pdf.Application.DTOs;

/// <summary>
/// Identidad visual compartida por todos los PDF. Se enlaza desde appsettings.json.
/// Ningún texto institucional debe quedar quemado en el código.
/// </summary>
public class PdfBrandingOptions
{
    public const string SectionName = "Pdf";

    public string AssetsRootPath { get; set; } = "Features/Pdf/Assets";

    // Header: si LogoAssetKey existe se usa la imagen; si no, se cae a CompanyName en texto.
    public string CompanyName { get; set; } = string.Empty;
    public string CompanyDocument { get; set; } = string.Empty;   // NIT
    public string CompanyAddress { get; set; } = string.Empty;
    public string? LogoAssetKey { get; set; }

    // Footer: leyenda en texto + logo opcional en imagen.
    public string FooterLegend { get; set; } = string.Empty;
    public string? FooterLogoAssetKey { get; set; }
    public bool ShowPageNumbers { get; set; } = true;
    public bool ShowGenerationDate { get; set; } = true;
}
```

### `WebApp/appsettings.json`

```json
"Pdf": {
  "AssetsRootPath": "Features/Pdf/Assets",
  "CompanyName": "<Razón social>",
  "CompanyDocument": "NIT 900.000.000-0",
  "CompanyAddress": "<Dirección>",
  "LogoAssetKey": "logo.png",
  "FooterLegend": "Documento generado electrónicamente. No requiere firma manuscrita.",
  "FooterLogoAssetKey": null,
  "ShowPageNumbers": true,
  "ShowGenerationDate": true
}
```

### `DOCCB.Application.csproj`

Los assets deben copiarse al output, igual que las plantillas de correo:

```xml
<ItemGroup>
  <Content Include="Features\Pdf\Assets\**" CopyToOutputDirectory="PreserveNewest" />
</ItemGroup>
```

### `Features/Pdf/Application/Constants/PdfConstants.cs`

```csharp
namespace DOCCB.Application.Features.Pdf.Application.Constants;

public static class PdfConstants
{
    public const string ContentType = "application/pdf";
    public const string CultureName = "es-CO";
    public const string AssetNotFound = "No se encontró el recurso gráfico del PDF: {0}";
}
```

---

## 2️⃣ Paso 2 — Contratos

### `Features/Pdf/Application/DTOs/PdfFileDto.cs`

```csharp
using DOCCB.Application.Features.Pdf.Application.Constants;

namespace DOCCB.Application.Features.Pdf.Application.DTOs;

public class PdfFileDto
{
    public byte[] Content { get; set; } = [];
    public string FileName { get; set; } = string.Empty;
    public string ContentType => PdfConstants.ContentType;

    /// <summary>Para responder dentro de ResponseDto sin romper el envelope de la API.</summary>
    public string ToBase64() => Convert.ToBase64String(Content);
}
```

### `Features/Pdf/Application/Interfaces/IPdfGeneratorService.cs`

```csharp
using DOCCB.Application.Features.Pdf.Application.DTOs;

namespace DOCCB.Application.Features.Pdf.Application.Interfaces;

/// <summary>Punto único de generación de PDF de la plataforma.</summary>
public interface IPdfGeneratorService
{
    Task<PdfFileDto> GenerateAsync<TModel>(TModel model, CancellationToken cancellationToken = default)
        where TModel : class;
}
```

### `Features/Pdf/Application/Interfaces/IPdfDocumentBuilder.cs`

```csharp
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Pdf.Application.Interfaces;

/// <summary>
/// Cada tipo de PDF implementa este contrato. Es el ÚNICO punto de extensión
/// al agregar un documento nuevo.
/// </summary>
public interface IPdfDocumentBuilder<in TModel> where TModel : class
{
    /// <summary>Nombre del archivo resultante, p. ej. "certificado-laboral-1032456789.pdf".</summary>
    string BuildFileName(TModel model);

    /// <summary>Resuelve los recursos gráficos (async) y arma el documento.</summary>
    Task<IDocument> BuildDocumentAsync(TModel model, CancellationToken cancellationToken = default);
}
```

### `Features/Pdf/Application/Interfaces/IPdfAssetProvider.cs`

```csharp
namespace DOCCB.Application.Features.Pdf.Application.Interfaces;

/// <summary>Entrega imágenes (logo, firmas) cacheadas en memoria.</summary>
public interface IPdfAssetProvider
{
    Task<byte[]> GetAsync(string assetKey, CancellationToken cancellationToken = default);

    /// <summary>Devuelve null si la clave es nula o el archivo no existe (logo o firma opcionales).</summary>
    Task<byte[]?> GetOrDefaultAsync(string? assetKey, CancellationToken cancellationToken = default);
}
```

---

## 3️⃣ Paso 3 — Proveedor de imágenes con caché

### `Features/Pdf/Application/Services/FileSystemPdfAssetProvider.cs`

```csharp
using DOCCB.Application.Features.Pdf.Application.Constants;
using DOCCB.Application.Features.Pdf.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.Interfaces;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace DOCCB.Application.Features.Pdf.Application.Services;

public class FileSystemPdfAssetProvider : IPdfAssetProvider
{
    private readonly IMemoryCache _cache;
    private readonly string _root;

    public FileSystemPdfAssetProvider(IMemoryCache cache, IOptions<PdfBrandingOptions> options)
    {
        _cache = cache;
        _root = Path.Combine(AppContext.BaseDirectory, options.Value.AssetsRootPath);
    }

    public async Task<byte[]> GetAsync(string assetKey, CancellationToken cancellationToken = default)
    {
        var asset = await GetOrDefaultAsync(assetKey, cancellationToken);
        return asset ?? throw new FileNotFoundException(string.Format(PdfConstants.AssetNotFound, assetKey));
    }

    public async Task<byte[]?> GetOrDefaultAsync(string? assetKey, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(assetKey))
            return null;

        // Se admite subcarpeta (firmas/x.png) pero se bloquea el path traversal.
        var relativeKey = assetKey.Replace('\\', '/').TrimStart('/');
        if (relativeKey.Contains(".."))
            return null;

        return await _cache.GetOrCreateAsync($"pdf-asset:{relativeKey}", async entry =>
        {
            entry.SlidingExpiration = TimeSpan.FromHours(1);

            var path = Path.Combine(_root, relativeKey.Replace('/', Path.DirectorySeparatorChar));
            return File.Exists(path)
                ? await File.ReadAllBytesAsync(path, cancellationToken)
                : null;
        });
    }
}
```

> Si mañana las firmas se guardan en base de datos o en DocManager, creas otra implementación de `IPdfAssetProvider` y cambias **una sola línea** de DI. El resto del código no se entera.

---

## 4️⃣ Paso 4 — Paleta y componentes compartidos

### `Features/Pdf/Application/Documents/PdfPalette.cs`

```csharp
using QuestPDF.Helpers;

namespace DOCCB.Application.Features.Pdf.Application.Documents;

public static class PdfPalette
{
    public const string Primary = "#004B87";
    public const string Text = "#1F2933";
    public const string Muted = "#6B7280";
    public const string Line = "#D8DEE6";

    public const string FontFamily = Fonts.Arial;
}
```

### `Features/Pdf/Application/Documents/Components/PdfHeaderComponent.cs`

Header común a **todos** los documentos. Acepta **imagen o texto**: si no hay logo cargado, muestra el nombre de la compañía.

```csharp
using DOCCB.Application.Features.Pdf.Application.DTOs;
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Pdf.Application.Documents.Components;

public class PdfHeaderComponent : IComponent
{
    private readonly PdfBrandingOptions _branding;
    private readonly byte[]? _logo;
    private readonly string? _documentTitle;

    public PdfHeaderComponent(PdfBrandingOptions branding, byte[]? logo, string? documentTitle = null)
    {
        _branding = branding;
        _logo = logo;
        _documentTitle = documentTitle;
    }

    public void Compose(IContainer container)
    {
        container.Column(column =>
        {
            column.Item().Row(row =>
            {
                // Imagen si existe; si no, texto. El ancho reservado es el mismo en ambos casos.
                if (_logo is not null)
                    row.ConstantItem(130).Height(45).AlignLeft().AlignMiddle().Image(_logo).FitArea();
                else
                    row.ConstantItem(130).AlignMiddle().Text(_branding.CompanyName)
                        .FontSize(12).Bold().FontColor(PdfPalette.Primary);

                row.RelativeItem().AlignRight().Column(info =>
                {
                    info.Item().Text(_branding.CompanyName)
                        .FontSize(10).Bold().FontColor(PdfPalette.Primary);
                    info.Item().Text(_branding.CompanyDocument)
                        .FontSize(8).FontColor(PdfPalette.Muted);
                    info.Item().Text(_branding.CompanyAddress)
                        .FontSize(8).FontColor(PdfPalette.Muted);
                });
            });

            if (!string.IsNullOrWhiteSpace(_documentTitle))
                column.Item().PaddingTop(6).Text(_documentTitle!)
                    .FontSize(9).SemiBold().FontColor(PdfPalette.Muted);

            column.Item().PaddingTop(8).LineHorizontal(1).LineColor(PdfPalette.Line);
        });
    }
}
```

### `Features/Pdf/Application/Documents/Components/PdfFooterComponent.cs`

Footer común: logo opcional (imagen), leyenda (texto), fecha de generación y paginación.

```csharp
using DOCCB.Application.Features.Pdf.Application.DTOs;
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Pdf.Application.Documents.Components;

public class PdfFooterComponent : IComponent
{
    private readonly PdfBrandingOptions _branding;
    private readonly byte[]? _footerLogo;
    private readonly DateTimeOffset _generatedAt;

    public PdfFooterComponent(PdfBrandingOptions branding, byte[]? footerLogo, DateTimeOffset generatedAt)
    {
        _branding = branding;
        _footerLogo = footerLogo;
        _generatedAt = generatedAt;
    }

    public void Compose(IContainer container)
    {
        container.Column(column =>
        {
            column.Item().PaddingBottom(6).LineHorizontal(1).LineColor(PdfPalette.Line);

            column.Item().Row(row =>
            {
                if (_footerLogo is not null)
                    row.ConstantItem(60).Height(20).AlignMiddle().Image(_footerLogo).FitArea();

                row.RelativeItem().PaddingLeft(_footerLogo is not null ? 8 : 0).Column(left =>
                {
                    if (!string.IsNullOrWhiteSpace(_branding.FooterLegend))
                        left.Item().Text(_branding.FooterLegend)
                            .FontSize(7).FontColor(PdfPalette.Muted);

                    if (_branding.ShowGenerationDate)
                        left.Item().Text($"Generado el {_generatedAt:dd/MM/yyyy HH:mm}")
                            .FontSize(7).FontColor(PdfPalette.Muted);
                });

                if (_branding.ShowPageNumbers)
                {
                    row.ConstantItem(90).AlignRight().AlignBottom().Text(text =>
                    {
                        text.DefaultTextStyle(x => x.FontSize(7).FontColor(PdfPalette.Muted));
                        text.Span("Página ");
                        text.CurrentPageNumber();
                        text.Span(" de ");
                        text.TotalPages();
                    });
                }
            });
        });
    }
}
```

### `Features/Pdf/Application/Documents/Components/SignatureBlockComponent.cs`

Bloque de firma reutilizable: **espacio para la foto de la firma** sobre la línea, nombre y cargo debajo.

```csharp
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Pdf.Application.Documents.Components;

public class SignatureBlockComponent : IComponent
{
    private const float BlockWidth = 210f;
    private const float SignatureHeight = 60f;

    private readonly byte[]? _signatureImage;
    private readonly string _signerName;
    private readonly string _signerPosition;
    private readonly string? _extraLine;

    public SignatureBlockComponent(
        byte[]? signatureImage, string signerName, string signerPosition, string? extraLine = null)
    {
        _signatureImage = signatureImage;
        _signerName = signerName;
        _signerPosition = signerPosition;
        _extraLine = extraLine;
    }

    public void Compose(IContainer container)
    {
        container.Width(BlockWidth).Column(column =>
        {
            // Alto fijo haya o no imagen: así la línea de firma nunca se desplaza
            // y el documento se ve igual con firma digital o para firma manuscrita.
            column.Item().Height(SignatureHeight).AlignBottom().AlignCenter().Element(area =>
            {
                if (_signatureImage is not null)
                    area.Image(_signatureImage).FitArea();
                else
                    area.Text(string.Empty);
            });

            column.Item().PaddingTop(2).LineHorizontal(1).LineColor(PdfPalette.Text);

            column.Item().PaddingTop(4).AlignCenter().Text(_signerName).FontSize(10).Bold();
            column.Item().AlignCenter().Text(_signerPosition).FontSize(9).FontColor(PdfPalette.Muted);

            if (!string.IsNullOrWhiteSpace(_extraLine))
                column.Item().AlignCenter().Text(_extraLine!).FontSize(8).FontColor(PdfPalette.Muted);
        });
    }
}
```

---

## 5️⃣ Paso 5 — Documento base (el corazón de la reutilización)

`BasePdfDocument<TModel>` aplica **Template Method**: fija página, márgenes, header y footer, y deja abstracto únicamente el contenido.

### `Features/Pdf/Application/Documents/BasePdfDocument.cs`

```csharp
using DOCCB.Application.Features.Pdf.Application.Documents.Components;
using DOCCB.Application.Features.Pdf.Application.DTOs;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Pdf.Application.Documents;

public abstract class BasePdfDocument<TModel> : IDocument where TModel : class
{
    protected TModel Model { get; }
    protected PdfBrandingOptions Branding { get; }
    protected byte[]? HeaderLogo { get; }
    protected byte[]? FooterLogo { get; }
    protected DateTimeOffset GeneratedAt { get; }

    protected BasePdfDocument(
        TModel model,
        PdfBrandingOptions branding,
        byte[]? headerLogo,
        byte[]? footerLogo,
        DateTimeOffset generatedAt)
    {
        Model = model;
        Branding = branding;
        HeaderLogo = headerLogo;
        FooterLogo = footerLogo;
        GeneratedAt = generatedAt;
    }

    /// <summary>Título del documento: metadatos del PDF y subtítulo opcional del header.</summary>
    protected abstract string DocumentTitle { get; }

    // Puntos de ajuste opcionales por documento.
    protected virtual PageSize PageSize => PageSizes.A4;
    protected virtual float MarginCentimeters => 2f;
    protected virtual bool ShowTitleInHeader => true;

    public DocumentMetadata GetMetadata() => new()
    {
        Title = DocumentTitle,
        Author = Branding.CompanyName,
        Creator = Branding.CompanyName,
        Subject = DocumentTitle
    };

    public DocumentSettings GetSettings() => DocumentSettings.Default;

    public void Compose(IDocumentContainer container)
    {
        container.Page(page =>
        {
            page.Size(PageSize);
            page.Margin(MarginCentimeters, Unit.Centimetre);
            page.DefaultTextStyle(ComposeDefaultTextStyle);

            page.Header().Component(
                new PdfHeaderComponent(Branding, HeaderLogo, ShowTitleInHeader ? DocumentTitle : null));

            page.Content().PaddingVertical(16).Element(ComposeContent);

            page.Footer().Component(
                new PdfFooterComponent(Branding, FooterLogo, GeneratedAt));
        });
    }

    /// <summary>Lo ÚNICO que cada documento concreto debe implementar.</summary>
    protected abstract void ComposeContent(IContainer container);

    protected virtual TextStyle ComposeDefaultTextStyle(TextStyle style) =>
        style.FontFamily(PdfPalette.FontFamily)
             .FontSize(11)
             .FontColor(PdfPalette.Text)
             .LineHeight(1.4f);
}
```

---

## 6️⃣ Paso 6 — Servicio generador

### `Features/Pdf/Application/Services/PdfGeneratorService.cs`

```csharp
using DOCCB.Application.Features.Pdf.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.Interfaces;
using Microsoft.Extensions.DependencyInjection;
using QuestPDF.Fluent;

namespace DOCCB.Application.Features.Pdf.Application.Services;

public class PdfGeneratorService : IPdfGeneratorService
{
    private readonly IServiceProvider _serviceProvider;

    public PdfGeneratorService(IServiceProvider serviceProvider) => _serviceProvider = serviceProvider;

    public async Task<PdfFileDto> GenerateAsync<TModel>(
        TModel model, CancellationToken cancellationToken = default) where TModel : class
    {
        // Resuelve el builder registrado para este modelo. Si falta el registro,
        // el error es explícito y aparece en el primer intento, no en producción.
        var builder = _serviceProvider.GetService<IPdfDocumentBuilder<TModel>>()
            ?? throw new InvalidOperationException(
                $"No hay un IPdfDocumentBuilder<{typeof(TModel).Name}> registrado en ApplicationServiceRegistration.");

        var document = await builder.BuildDocumentAsync(model, cancellationToken);

        // GeneratePdf() es síncrono y CPU-bound: se saca del hilo del request.
        var content = await Task.Run(document.GeneratePdf, cancellationToken);

        return new PdfFileDto
        {
            Content = content,
            FileName = builder.BuildFileName(model)
        };
    }
}
```

---

## 7️⃣ Paso 7 — El certificado laboral: modelo y DTO de entrada

### `Features/Certificates/Application/DTOs/LaborCertificateRequestDto.cs`

```csharp
namespace DOCCB.Application.Features.Certificates.Application.DTOs;

/// <summary>Lo que llega desde la API.</summary>
public class LaborCertificateRequestDto
{
    /// <summary>Opcional: si es nulo, se genera para el usuario autenticado.</summary>
    public int? UserId { get; set; }

    /// <summary>"A quien interese" si viene vacío.</summary>
    public string? AddressedTo { get; set; }

    public bool IncludeSalary { get; set; } = true;
}
```

### `Features/Certificates/Application/DTOs/LaborCertificateModel.cs`

```csharp
namespace DOCCB.Application.Features.Certificates.Application.DTOs;

/// <summary>Modelo ya resuelto que consume el documento PDF. No conoce entidades de dominio.</summary>
public class LaborCertificateModel
{
    public string EmployeeFullName { get; set; } = string.Empty;
    public string EmployeeDocument { get; set; } = string.Empty;
    public string Position { get; set; } = string.Empty;
    public string ContractType { get; set; } = string.Empty;
    public DateOnly HireDate { get; set; }
    public DateOnly? TerminationDate { get; set; }
    public decimal? MonthlySalary { get; set; }
    public string? AddressedTo { get; set; }
    public string City { get; set; } = "Bogotá D.C.";
    public DateOnly IssueDate { get; set; } = DateOnly.FromDateTime(DateTime.Today);

    // Firma
    public string SignerName { get; set; } = string.Empty;
    public string SignerPosition { get; set; } = string.Empty;
    public string? SignerSignatureAssetKey { get; set; }   // "firmas/firma-gerente-gh.png"

    public bool IsActiveEmployee => TerminationDate is null;
}
```

---

## 8️⃣ Paso 8 — El documento concreto

### `Features/Certificates/Application/Documents/LaborCertificateDocument.cs`

Fíjate en lo que **no** está aquí: ni header, ni footer, ni paginación, ni márgenes. Todo eso lo pone la base.

```csharp
using System.Globalization;
using DOCCB.Application.Features.Certificates.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.Constants;
using DOCCB.Application.Features.Pdf.Application.Documents;
using DOCCB.Application.Features.Pdf.Application.Documents.Components;
using DOCCB.Application.Features.Pdf.Application.DTOs;
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Certificates.Application.Documents;

public class LaborCertificateDocument : BasePdfDocument<LaborCertificateModel>
{
    private static readonly CultureInfo Culture = new(PdfConstants.CultureName);
    private readonly byte[]? _signatureImage;

    public LaborCertificateDocument(
        LaborCertificateModel model,
        PdfBrandingOptions branding,
        byte[]? headerLogo,
        byte[]? footerLogo,
        byte[]? signatureImage,
        DateTimeOffset generatedAt)
        : base(model, branding, headerLogo, footerLogo, generatedAt)
    {
        _signatureImage = signatureImage;
    }

    protected override string DocumentTitle => "Certificación laboral";
    protected override bool ShowTitleInHeader => false;   // el título va grande dentro del contenido

    protected override void ComposeContent(IContainer container)
    {
        container.Column(column =>
        {
            column.Spacing(14);

            column.Item().AlignCenter().Text("CERTIFICACIÓN LABORAL")
                .FontSize(14).Bold().FontColor(PdfPalette.Primary);

            column.Item().AlignRight().Text(
                $"{Model.City}, {Model.IssueDate.ToString("d 'de' MMMM 'de' yyyy", Culture)}");

            column.Item().Text(string.IsNullOrWhiteSpace(Model.AddressedTo)
                ? "A QUIEN INTERESE:"
                : $"Señores {Model.AddressedTo!.ToUpper(Culture)}:").Bold();

            column.Item().Text(BuildBodyText()).Justify();

            column.Item().Element(ComposeDetailTable);

            column.Item().Text(
                "La presente certificación se expide a solicitud del interesado, " +
                "para los fines que estime convenientes.").Justify();

            column.Item().PaddingTop(30).Element(ComposeSignature);
        });
    }

    private string BuildBodyText()
    {
        var verb = Model.IsActiveEmployee ? "labora actualmente" : "laboró";

        var period = Model.IsActiveEmployee
            ? $"desde el {Model.HireDate.ToString("d 'de' MMMM 'de' yyyy", Culture)}"
            : $"entre el {Model.HireDate.ToString("d 'de' MMMM 'de' yyyy", Culture)} " +
              $"y el {Model.TerminationDate!.Value.ToString("d 'de' MMMM 'de' yyyy", Culture)}";

        return $"{Branding.CompanyName}, identificada con {Branding.CompanyDocument}, certifica que " +
               $"el(la) señor(a) {Model.EmployeeFullName}, identificado(a) con documento No. " +
               $"{Model.EmployeeDocument}, {verb} en esta compañía {period}, desempeñando el cargo de " +
               $"{Model.Position} mediante {Model.ContractType}.";
    }

    private void ComposeDetailTable(IContainer container)
    {
        container.Border(1).BorderColor(PdfPalette.Line).Padding(10).Column(column =>
        {
            column.Spacing(4);

            AddRow(column, "Cargo", Model.Position);
            AddRow(column, "Tipo de contrato", Model.ContractType);
            AddRow(column, "Fecha de ingreso", Model.HireDate.ToString("dd/MM/yyyy"));

            if (Model.TerminationDate is not null)
                AddRow(column, "Fecha de retiro", Model.TerminationDate.Value.ToString("dd/MM/yyyy"));

            if (Model.MonthlySalary is > 0)
                AddRow(column, "Salario mensual", Model.MonthlySalary.Value.ToString("C0", Culture));
        });

        static void AddRow(ColumnDescriptor column, string label, string value) =>
            column.Item().Row(row =>
            {
                row.ConstantItem(150).Text(label).SemiBold().FontSize(10);
                row.RelativeItem().Text(value).FontSize(10);
            });
    }

    private void ComposeSignature(IContainer container) =>
        container.AlignLeft().Component(new SignatureBlockComponent(
            _signatureImage,
            Model.SignerName,
            Model.SignerPosition,
            Branding.CompanyName));
}
```

### `Features/Certificates/Application/Documents/LaborCertificateDocumentBuilder.cs`

Aquí se cargan las imágenes (operación async) y se arma el documento.

```csharp
using DOCCB.Application.Features.Certificates.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.Interfaces;
using Microsoft.Extensions.Options;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Certificates.Application.Documents;

public class LaborCertificateDocumentBuilder : IPdfDocumentBuilder<LaborCertificateModel>
{
    private readonly IPdfAssetProvider _assets;
    private readonly PdfBrandingOptions _branding;
    private readonly TimeProvider _timeProvider;

    public LaborCertificateDocumentBuilder(
        IPdfAssetProvider assets,
        IOptions<PdfBrandingOptions> branding,
        TimeProvider timeProvider)
    {
        _assets = assets;
        _branding = branding.Value;
        _timeProvider = timeProvider;
    }

    public string BuildFileName(LaborCertificateModel model) =>
        $"certificado-laboral-{model.EmployeeDocument}-{model.IssueDate:yyyyMMdd}.pdf";

    public async Task<IDocument> BuildDocumentAsync(
        LaborCertificateModel model, CancellationToken cancellationToken = default)
    {
        var headerLogo = await _assets.GetOrDefaultAsync(_branding.LogoAssetKey, cancellationToken);
        var footerLogo = await _assets.GetOrDefaultAsync(_branding.FooterLogoAssetKey, cancellationToken);
        var signature = await _assets.GetOrDefaultAsync(model.SignerSignatureAssetKey, cancellationToken);

        return new LaborCertificateDocument(
            model, _branding, headerLogo, footerLogo, signature, _timeProvider.GetLocalNow());
    }
}
```

---

## 9️⃣ Paso 9 — Servicio de la feature

Sigue el patrón de DOCCB: interfaz + servicio + `IUnitOfWork`, sin tocar el `DbContext`.

### `Features/Certificates/Application/Interfaces/ILaborCertificateService.cs`

```csharp
using DOCCB.Application.Features.Certificates.Application.DTOs;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.DTOs;

namespace DOCCB.Application.Features.Certificates.Application.Interfaces;

public interface ILaborCertificateService
{
    Task<ResponseDto<PdfFileDto>> GenerateAsync(
        LaborCertificateRequestDto request, int requestingUserId, CancellationToken cancellationToken = default);
}
```

### `Features/Certificates/Application/Services/LaborCertificateService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Certificates.Application.DTOs;
using DOCCB.Application.Features.Certificates.Application.Interfaces;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.DTOs;
using DOCCB.Application.Features.Pdf.Application.Interfaces;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Configuration;

namespace DOCCB.Application.Features.Certificates.Application.Services;

public class LaborCertificateService : ILaborCertificateService
{
    private readonly IUnitOfWork _unitOfWork;
    private readonly IPdfGeneratorService _pdfGenerator;
    private readonly IConfiguration _configuration;

    public LaborCertificateService(
        IUnitOfWork unitOfWork,
        IPdfGeneratorService pdfGenerator,
        IConfiguration configuration)
    {
        _unitOfWork = unitOfWork;
        _pdfGenerator = pdfGenerator;
        _configuration = configuration;
    }

    public async Task<ResponseDto<PdfFileDto>> GenerateAsync(
        LaborCertificateRequestDto request,
        int requestingUserId,
        CancellationToken cancellationToken = default)
    {
        var userId = request.UserId ?? requestingUserId;

        var user = await _unitOfWork.Repository<User>().GetByIdAsync(userId);
        if (user is null)
            return ResponseDto<PdfFileDto>.Fail("El usuario no existe.");

        if (user.HireDate is null)
            return ResponseDto<PdfFileDto>.Fail(
                "El usuario no tiene fecha de ingreso registrada; no es posible emitir el certificado.");

        var model = new LaborCertificateModel
        {
            EmployeeFullName = $"{user.FirstName} {user.LastName}".Trim(),
            EmployeeDocument = user.DocumentNumber,
            Position = user.Position,
            ContractType = user.ContractType,
            HireDate = DateOnly.FromDateTime(user.HireDate.Value),
            TerminationDate = user.TerminationDate is null
                ? null
                : DateOnly.FromDateTime(user.TerminationDate.Value),
            MonthlySalary = request.IncludeSalary ? user.Salary : null,
            AddressedTo = request.AddressedTo,

            // El firmante sale de configuración, no del código.
            SignerName = _configuration["Pdf:Signers:LaborCertificate:Name"] ?? string.Empty,
            SignerPosition = _configuration["Pdf:Signers:LaborCertificate:Position"] ?? string.Empty,
            SignerSignatureAssetKey = _configuration["Pdf:Signers:LaborCertificate:SignatureAssetKey"]
        };

        var file = await _pdfGenerator.GenerateAsync(model, cancellationToken);

        return ResponseDto<PdfFileDto>.Ok(file);
    }
}
```

> ⚠️ **Ajusta dos cosas a lo que ya existe en el repo:**
> 1. Los nombres de propiedades de `User` (`FirstName`, `DocumentNumber`, `HireDate`, `Position`, `Salary`…) — usa los reales de `DOCCB.Domain/Entities/User.cs`.
> 2. La firma de `ResponseDto` — si no tiene helpers `Ok`/`Fail`, constrúyelo como lo hacen los demás servicios y apóyate en `ApiResponseConstants`.

Agrega al `appsettings.json`:

```json
"Pdf": {
  "Signers": {
    "LaborCertificate": {
      "Name": "<Nombre del firmante>",
      "Position": "Gerente de Gestión Humana",
      "SignatureAssetKey": "firmas/firma-gerente-gh.png"
    }
  }
}
```

---

## 🔟 Paso 10 — Registro de dependencias

En `DOCCB.Application/ApplicationServiceRegistration.cs`:

```csharp
public static IServiceCollection AddApplicationServices(
    this IServiceCollection services, IConfiguration configuration)
{
    // ... registros existentes

    // ── PDF: base compartida ──────────────────────────────────────────
    QuestPDF.Settings.License = LicenseType.Community;   // cambiar si se adquiere licencia comercial

    services.Configure<PdfBrandingOptions>(configuration.GetSection(PdfBrandingOptions.SectionName));
    services.AddMemoryCache();
    services.TryAddSingleton(TimeProvider.System);

    services.AddSingleton<IPdfAssetProvider, FileSystemPdfAssetProvider>();
    services.AddScoped<IPdfGeneratorService, PdfGeneratorService>();

    // ── Un registro por cada tipo de PDF ──────────────────────────────
    services.AddScoped<IPdfDocumentBuilder<LaborCertificateModel>, LaborCertificateDocumentBuilder>();

    // ── Servicios de feature ──────────────────────────────────────────
    services.AddScoped<ILaborCertificateService, LaborCertificateService>();

    return services;
}
```

> Si `AddApplicationServices` hoy no recibe `IConfiguration`, agrégale el parámetro y actualiza la llamada en `Program.cs`.
> `TryAddSingleton` requiere `using Microsoft.Extensions.DependencyInjection.Extensions;`.

---

## 1️⃣1️⃣ Paso 11 — Endpoint

En `WebApp/Controllers/CertificateController.cs`:

```csharp
[HttpPost("laboral")]
[ProducesResponseType(typeof(ResponseDto<PdfFileDto>), StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
public async Task<IActionResult> GenerateLaborCertificate(
    [FromBody] LaborCertificateRequestDto request,
    CancellationToken cancellationToken)
{
    var userId = _userAuthenticator.GetCurrentUserId(User);   // MicrosoftUserAuthenticatorHelper

    var response = await _laborCertificateService.GenerateAsync(request, userId, cancellationToken);

    return response.Success ? Ok(response) : BadRequest(response);
}
```

**Dos formas de devolver el PDF — elige una y aplícala a todos los documentos:**

| Opción | Cuándo | Cómo |
|---|---|---|
| **A. Envelope** (recomendada aquí) | La API ya responde `ResponseDto<T>` en todos lados | El front recibe `Content` en base64 y arma la descarga. Mantiene el contrato uniforme. |
| **B. Archivo binario** | Descarga directa desde el navegador | `return File(file.Content, file.ContentType, file.FileName);` — rompe el envelope; documéntalo en Swagger. |

Para la opción A, expón `Content` como base64 en el DTO de salida:

```csharp
// En PdfFileDto, si se serializa directo, byte[] ya viaja como base64 en System.Text.Json.
// Si prefieres ser explícito, crea PdfFileResponseDto { Base64, FileName, ContentType }.
```

No olvides el atributo de autorización/permiso que usan los demás endpoints de `CertificateController`.

---

## 1️⃣2️⃣ Agregar un PDF nuevo (el objetivo del diseño)

Para cualquier documento futuro — paz y salvo, constancia de ingresos, orden de pago — son **3 archivos + 1 línea**:

| # | Archivo | Contenido |
|---|---|---|
| 1 | `Features/<Feature>/Application/DTOs/XxxModel.cs` | Los datos del documento. |
| 2 | `Features/<Feature>/Application/Documents/XxxDocument.cs` | `: BasePdfDocument<XxxModel>` → solo `DocumentTitle` y `ComposeContent`. |
| 3 | `Features/<Feature>/Application/Documents/XxxDocumentBuilder.cs` | `: IPdfDocumentBuilder<XxxModel>` → carga imágenes y arma el documento. |
| 4 | `ApplicationServiceRegistration.cs` | `services.AddScoped<IPdfDocumentBuilder<XxxModel>, XxxDocumentBuilder>();` |

El header y el footer **se heredan solos**. Si un documento necesita orientación horizontal o márgenes distintos, sobrescribe `PageSize` o `MarginCentimeters`. Si necesita firma, reutiliza `SignatureBlockComponent`.

### Migrar el certificado de cesantías existente

Si `ICesantiasCertificateGenerationService` ya arma un `IDocument`:

1. Extrae su modelo de datos a un `CesantiasCertificateModel`.
2. Convierte su clase de documento en `: BasePdfDocument<CesantiasCertificateModel>` y **borra** su header, footer y configuración de página: ahora los hereda.
3. Crea su `CesantiasCertificateDocumentBuilder` y regístralo.
4. El servicio existente pasa a llamar a `IPdfGeneratorService.GenerateAsync(model)` y conserva su interfaz pública → **los consumidores no se enteran**.

Resultado: cesantías y certificado laboral comparten header y footer. Cambiar el logo pasa a ser editar `appsettings.json`, no tocar N clases.

---

## 1️⃣3️⃣ Persistir o enviar el PDF (opcional)

`PdfFileDto.Content` son bytes: se integra con lo que ya existe sin código nuevo de PDF.

| Necesidad | Servicio existente |
|---|---|
| Guardar en almacenamiento local | `IRequestLocalStorageService` |
| Subir a SharePoint | `IRequestSharePointStorageService` |
| Radicar en gestor documental | `IDocManagerService` |
| Enviar por correo como adjunto | `IMailNotificationService` + plantilla en `EmailsTemplate/` |
| Asociar a una solicitud | `RequestAttachment` vía `IUnitOfWork` |

Si el certificado debe quedar adjunto a una solicitud, envuelve la operación con `TransactionExecutorHelper` para que el guardado y la actualización viajen en la misma transacción.

---

## 1️⃣4️⃣ Probar sin levantar la API

```csharp
QuestPDF.Settings.License = LicenseType.Community;
QuestPDF.Settings.EnableDebugging = true;   // solo en pruebas

var branding = new PdfBrandingOptions
{
    CompanyName = "DOC",
    CompanyDocument = "NIT 900.000.000-0",
    CompanyAddress = "Bogotá D.C."
};

var model = new LaborCertificateModel { /* datos de prueba */ };

var document = new LaborCertificateDocument(
    model, branding,
    headerLogo: File.ReadAllBytes("logo.png"),
    footerLogo: null,
    signatureImage: File.ReadAllBytes("firma.png"),
    generatedAt: DateTimeOffset.Now);

document.GeneratePdf("certificado-prueba.pdf");
```

Para iterar el diseño con hot reload del layout:

```bash
dotnet tool install --global QuestPDF.Companion
```

```csharp
await document.ShowInCompanionAsync();   // en versiones anteriores: ShowInPreviewer()
```

Test de humo:

```csharp
[Fact]
public async Task Genera_certificado_laboral_valido()
{
    var file = await _pdfGenerator.GenerateAsync(TestData.LaborCertificateModel());

    Assert.NotEmpty(file.Content);
    Assert.Equal("%PDF", Encoding.ASCII.GetString(file.Content, 0, 4));
    Assert.EndsWith(".pdf", file.FileName);
}
```

Prueba obligatoria antes de dar por terminado: **un certificado con texto largo que ocupe 2–3 páginas**, para verificar que header y footer se repiten y que la paginación dice "Página X de Y".

---

## 1️⃣5️⃣ Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| `DocumentLayoutException` | Un elemento no cabe (tabla ancha, `Height` fijo excesivo, imagen grande) | `QuestPDF.Settings.EnableDebugging = true` en desarrollo: el mensaje señala el elemento exacto. |
| Texto en blanco o excepción de fuentes en Linux/Docker | La imagen base no trae fuentes ni `libfontconfig1` | En el Dockerfile: `RUN apt-get update && apt-get install -y --no-install-recommends libfontconfig1 libfreetype6 && rm -rf /var/lib/apt/lists/*` y registra una fuente propia con `FontManager.RegisterFont(stream)`. |
| Firma pixelada | Imagen pequeña escalada hacia arriba | PNG con fondo transparente, mínimo 600 px de ancho. QuestPDF no inventa resolución. |
| PDF muy pesado | Imágenes sin compresión | `DocumentSettings { ImageCompressionQuality = ImageCompressionQuality.High, ImageRasterDpi = 144 }`. |
| Excepción de licencia al arrancar | Falta `QuestPDF.Settings.License` | Una sola vez, en `ApplicationServiceRegistration`. |
| Request lento bajo carga | `GeneratePdf()` en el hilo del request | Ya resuelto con `Task.Run` en `PdfGeneratorService`. Para volúmenes altos, encola en background. |
| Logo leído del disco en cada request | Sin caché | Ya resuelto con `IMemoryCache` en `FileSystemPdfAssetProvider`. |
| `Assets` no aparece en el servidor | Falta el `<Content Include>` | Verifica que los archivos existan en `bin/<config>/net8.0/Features/Pdf/Assets`. |

### Compatibilidad de versiones de QuestPDF

| API usada | Disponible desde | Alternativa en versiones viejas |
|---|---|---|
| `GetSettings()` en `IDocument` | 2023.4 | Elimina el método; la interfaz no lo pide. |
| `.Image(bytes).FitArea()` | 2023.x | `.Image(bytes, ImageScaling.FitArea)` |
| `ShowInCompanionAsync()` | 2024.3 | `ShowInPreviewer()` |
| `TimeProvider` | .NET 8 | `DateTimeOffset.Now` directo. |

---

## ✅ Checklist de cierre

- [ ] Verificado dónde está referenciado QuestPDF y con qué versión.
- [ ] Licencia validada con el líder técnico.
- [ ] `Features/Pdf/Assets/**` se copia al output (`CopyToOutputDirectory`).
- [ ] Sección `Pdf` presente en `appsettings.json` de **todos** los ambientes.
- [ ] Ningún nombre institucional, NIT ni dirección quemados en código.
- [ ] Header y footer idénticos en un PDF de 1 página y en uno de 3.
- [ ] Paginación "Página X de Y" correcta.
- [ ] El bloque de firma conserva su alto cuando no hay imagen.
- [ ] Servicios registrados en `ApplicationServiceRegistration.cs`.
- [ ] El endpoint respeta el contrato (`ResponseDto`) y el atributo de permisos del controlador.
- [ ] Endpoint documentado en Swagger.
- [ ] Test que valida cabecera `%PDF` y nombre de archivo.
- [ ] Probado dentro del contenedor Linux, no solo en Windows.
- [ ] Decidido si el certificado de cesantías migra a la base compartida (y creado el ticket si queda para después).
