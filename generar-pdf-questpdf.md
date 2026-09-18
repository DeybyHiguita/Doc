# Generación de PDF con QuestPDF (.NET / Clean Architecture)

Guía paso a paso para implementar la generación de PDF en la solución **OpainCB** (Src/Application, Src/Domain, Src/Infrastructure, Src/Presentation).

El caso concreto es el **certificado laboral**, pero la infraestructura queda preparada para cualquier otro documento: lo único que se comparte entre todos es el **header** y el **footer**; el contenido y la firma los define cada documento.

- Stack: .NET 8 (aplica igual a .NET 9), ASP.NET Core, MediatR, QuestPDF.
- Namespaces usados: `OpainCB.Domain`, `OpainCB.Application`, `OpainCB.Infrastructure`, `OpainCB.WebApp`.

---

## 0. Decisiones de diseño (leer antes de codificar)

| Pieza | Capa | Por qué ahí |
|---|---|---|
| Modelos de datos del PDF (`LaborCertificateModel`) | Application / Contracts | Son el contrato de entrada; no dependen de QuestPDF. |
| `IPdfGenerator`, `IPdfDocumentBuilder<T>`, `IPdfAssetProvider` | Application / Contracts | La capa de aplicación orquesta, no conoce la librería. |
| Componentes QuestPDF (header, footer, firma) | Infrastructure | QuestPDF es un detalle técnico reemplazable. |
| `BasePdfDocument<TModel>` | Infrastructure | Template Method: fija header/footer/página, deja libre el contenido. |
| Command + Handler (`GenerateLaborCertificate`) | Application / Features | Regla de negocio: qué datos lleva el certificado. |
| Endpoint | Presentation / Controllers | Solo transporte HTTP. |

**Regla de oro:** `OpainCB.Application` **no** referencia el paquete QuestPDF. Si al terminar `Application.csproj` tiene `<PackageReference Include="QuestPDF" />`, algo quedó en la capa equivocada.

### ⚠️ Licenciamiento (validar antes de instalar)
QuestPDF es gratuito bajo licencia **Community** solo si la organización factura menos de **USD 1M anuales** (o el proyecto es open source). Para una empresa por encima de ese umbral se requiere licencia **Professional / Enterprise** de pago. Confirma esto con el líder técnico antes de subirlo a producción: es una decisión de negocio, no técnica.

---

## 1. Estructura de archivos a crear

```
Src/
├── Application/OpainCB.Application/
│   ├── Contracts/
│   │   └── Pdf/
│   │       ├── IPdfGenerator.cs
│   │       ├── IPdfDocumentBuilder.cs
│   │       ├── IPdfAssetProvider.cs
│   │       └── PdfFile.cs
│   └── Features/
│       └── Certificates/
│           └── Commands/
│               └── GenerateLaborCertificate/
│                   ├── GenerateLaborCertificateCommand.cs
│                   ├── GenerateLaborCertificateCommandHandler.cs
│                   ├── GenerateLaborCertificateCommandValidator.cs
│                   └── LaborCertificateModel.cs
│
├── Infrastructure/OpainCB.Infrastructure/
│   └── Pdf/
│       ├── Options/
│       │   └── PdfBrandingOptions.cs
│       ├── Shared/
│       │   ├── PdfPalette.cs
│       │   ├── PdfHeaderComponent.cs
│       │   ├── PdfFooterComponent.cs
│       │   ├── SignatureBlockComponent.cs
│       │   └── BasePdfDocument.cs
│       ├── Documents/
│       │   └── LaborCertificate/
│       │       ├── LaborCertificateDocument.cs
│       │       └── LaborCertificateDocumentBuilder.cs
│       ├── FileSystemPdfAssetProvider.cs
│       └── QuestPdfGenerator.cs
│
└── Presentation/OpainCB.WebApp/
    ├── Assets/Pdf/            (logo.png, firma-*.png, fuentes)
    └── Controllers/CertificatesController.cs
```

---

## 2. Paso 1 — Instalar el paquete

Solo en **Infrastructure**:

```bash
dotnet add Src/Infrastructure/OpainCB.Infrastructure package QuestPDF
```

Verifica en `OpainCB.Infrastructure.csproj`:

```xml
<PackageReference Include="QuestPDF" Version="2025.7.0" />
```

> Usa la versión estable más reciente. La API descrita aquí corresponde a 2024.x–2025.x.

---

## 3. Paso 2 — Contratos en Application

### `Contracts/Pdf/PdfFile.cs`

```csharp
namespace OpainCB.Application.Contracts.Pdf;

public sealed record PdfFile(byte[] Content, string FileName)
{
    public string ContentType => "application/pdf";
}
```

### `Contracts/Pdf/IPdfGenerator.cs`

```csharp
namespace OpainCB.Application.Contracts.Pdf;

/// <summary>
/// Punto único de entrada para generar cualquier PDF de la plataforma.
/// </summary>
public interface IPdfGenerator
{
    Task<PdfFile> GenerateAsync<TModel>(TModel model, CancellationToken cancellationToken = default)
        where TModel : class;
}
```

### `Contracts/Pdf/IPdfDocumentBuilder.cs`

```csharp
namespace OpainCB.Application.Contracts.Pdf;

/// <summary>
/// Cada tipo de PDF implementa este contrato en Infrastructure.
/// Es el único punto de extensión al agregar un documento nuevo.
/// </summary>
public interface IPdfDocumentBuilder<in TModel> where TModel : class
{
    /// <summary>Nombre del archivo resultante, p. ej. "certificado-laboral-1032456789.pdf".</summary>
    string BuildFileName(TModel model);

    /// <summary>Resuelve recursos (logo, firma) y arma el documento. Devuelve object para no exponer QuestPDF.</summary>
    Task<object> BuildDocumentAsync(TModel model, CancellationToken cancellationToken = default);
}
```

> `object` mantiene a `Application` libre de la referencia a QuestPDF. `QuestPdfGenerator` lo castea a `IDocument`. Si prefieres tipado fuerte, mueve `IPdfDocumentBuilder<T>` a Infrastructure y deja en Application solo `IPdfGenerator`: es igual de válido y más limpio en cuanto a tipos.

### `Contracts/Pdf/IPdfAssetProvider.cs`

```csharp
namespace OpainCB.Application.Contracts.Pdf;

/// <summary>Entrega imágenes (logo, firmas) cacheadas en memoria.</summary>
public interface IPdfAssetProvider
{
    Task<byte[]> GetAsync(string assetKey, CancellationToken cancellationToken = default);
    Task<byte[]?> GetOrDefaultAsync(string? assetKey, CancellationToken cancellationToken = default);
}
```

---

## 4. Paso 3 — Configuración de marca (header/footer)

### `Pdf/Options/PdfBrandingOptions.cs` (Infrastructure)

```csharp
namespace OpainCB.Infrastructure.Pdf.Options;

public sealed class PdfBrandingOptions
{
    public const string SectionName = "Pdf";

    public string AssetsRootPath { get; set; } = "Assets/Pdf";

    public string CompanyName { get; set; } = string.Empty;
    public string CompanyDocument { get; set; } = string.Empty;   // NIT
    public string CompanyAddress { get; set; } = string.Empty;
    public string LogoAssetKey { get; set; } = "logo.png";

    public string FooterLegend { get; set; } = string.Empty;
    public string? FooterLogoAssetKey { get; set; }               // opcional: footer con imagen
    public bool ShowPageNumbers { get; set; } = true;
    public bool ShowGenerationDate { get; set; } = true;
}
```

### `appsettings.json` (WebApp)

```json
"Pdf": {
  "AssetsRootPath": "Assets/Pdf",
  "CompanyName": "Sociedad Concesionaria OPAIN S.A.",
  "CompanyDocument": "NIT 900.105.860-4",
  "CompanyAddress": "Aeropuerto Internacional El Dorado, Bogotá D.C.",
  "LogoAssetKey": "logo.png",
  "FooterLegend": "Documento generado electrónicamente. No requiere firma manuscrita.",
  "FooterLogoAssetKey": null,
  "ShowPageNumbers": true,
  "ShowGenerationDate": true
}
```

Coloca `logo.png` y las firmas en `Src/Presentation/OpainCB.WebApp/Assets/Pdf/` y marca copia al publicar en el `.csproj`:

```xml
<ItemGroup>
  <Content Include="Assets\Pdf\**" CopyToOutputDirectory="PreserveNewest" />
</ItemGroup>
```

---

## 5. Paso 4 — Proveedor de imágenes con caché

### `Pdf/FileSystemPdfAssetProvider.cs`

```csharp
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;
using OpainCB.Application.Contracts.Pdf;
using OpainCB.Infrastructure.Pdf.Options;

namespace OpainCB.Infrastructure.Pdf;

internal sealed class FileSystemPdfAssetProvider : IPdfAssetProvider
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
        return asset ?? throw new FileNotFoundException($"Recurso PDF no encontrado: {assetKey}");
    }

    public async Task<byte[]?> GetOrDefaultAsync(string? assetKey, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(assetKey))
            return null;

        // Evita path traversal: solo se admite el nombre del archivo.
        var safeKey = Path.GetFileName(assetKey);

        return await _cache.GetOrCreateAsync($"pdf-asset:{safeKey}", async entry =>
        {
            entry.SlidingExpiration = TimeSpan.FromHours(1);

            var path = Path.Combine(_root, safeKey);
            return File.Exists(path)
                ? await File.ReadAllBytesAsync(path, cancellationToken)
                : null;
        });
    }
}
```

> Si las firmas se guardan en base de datos o en un blob storage, crea otra implementación de `IPdfAssetProvider` y cambia solo el registro en DI.

---

## 6. Paso 5 — Componentes compartidos (header, footer, firma)

### `Pdf/Shared/PdfPalette.cs`

```csharp
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace OpainCB.Infrastructure.Pdf.Shared;

internal static class PdfPalette
{
    public const string Primary = "#004B87";
    public const string Text = "#1F2933";
    public const string Muted = "#6B7280";
    public const string Line = "#D8DEE6";

    public const string FontFamily = Fonts.Arial;
}
```

### `Pdf/Shared/PdfHeaderComponent.cs`

Header común a **todos** los documentos: logo a la izquierda, datos de la empresa a la derecha, línea divisoria.

```csharp
using OpainCB.Infrastructure.Pdf.Options;
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace OpainCB.Infrastructure.Pdf.Shared;

internal sealed class PdfHeaderComponent : IComponent
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
                if (_logo is not null)
                    row.ConstantItem(120).Height(45).Image(_logo).FitArea();
                else
                    row.ConstantItem(120).Text(_branding.CompanyName).Bold().FontColor(PdfPalette.Primary);

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
            {
                column.Item().PaddingTop(6).Text(_documentTitle!)
                    .FontSize(9).SemiBold().FontColor(PdfPalette.Muted);
            }

            column.Item().PaddingTop(8).LineHorizontal(1).LineColor(PdfPalette.Line);
        });
    }
}
```

### `Pdf/Shared/PdfFooterComponent.cs`

Footer común: leyenda (texto), logo opcional (imagen), fecha de generación y paginación.

```csharp
using OpainCB.Infrastructure.Pdf.Options;
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace OpainCB.Infrastructure.Pdf.Shared;

internal sealed class PdfFooterComponent : IComponent
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
                    row.ConstantItem(60).Height(20).Image(_footerLogo).FitArea();

                row.RelativeItem().Column(left =>
                {
                    if (!string.IsNullOrWhiteSpace(_branding.FooterLegend))
                        left.Item().Text(_branding.FooterLegend).FontSize(7).FontColor(PdfPalette.Muted);

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

### `Pdf/Shared/SignatureBlockComponent.cs`

Bloque de firma reutilizable: imagen de la firma sobre la línea, nombre y cargo debajo. Si no hay imagen, deja el espacio en blanco para firma manuscrita.

```csharp
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace OpainCB.Infrastructure.Pdf.Shared;

internal sealed class SignatureBlockComponent : IComponent
{
    private const float SignatureHeight = 60f;
    private const float SignatureWidth = 200f;

    private readonly byte[]? _signatureImage;
    private readonly string _signerName;
    private readonly string _signerPosition;
    private readonly string? _extraLine;

    public SignatureBlockComponent(byte[]? signatureImage, string signerName, string signerPosition, string? extraLine = null)
    {
        _signatureImage = signatureImage;
        _signerName = signerName;
        _signerPosition = signerPosition;
        _extraLine = extraLine;
    }

    public void Compose(IContainer container)
    {
        container.Width(SignatureWidth).Column(column =>
        {
            // El alto es fijo haya o no imagen: así la línea de firma nunca "salta".
            column.Item().Height(SignatureHeight).AlignBottom().AlignCenter()
                .Element(area =>
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

## 7. Paso 6 — Documento base (el corazón de la reutilización)

`BasePdfDocument<TModel>` fija página, header y footer. Cada documento concreto solo implementa `ComposeContent`.

### `Pdf/Shared/BasePdfDocument.cs`

```csharp
using OpainCB.Infrastructure.Pdf.Options;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace OpainCB.Infrastructure.Pdf.Shared;

internal abstract class BasePdfDocument<TModel> : IDocument where TModel : class
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

    /// <summary>Título del documento (metadatos y subtítulo del header).</summary>
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

    /// <summary>Lo único que cada documento debe implementar.</summary>
    protected abstract void ComposeContent(IContainer container);

    protected virtual TextStyle ComposeDefaultTextStyle(TextStyle style) =>
        style.FontFamily(PdfPalette.FontFamily).FontSize(11).FontColor(PdfPalette.Text).LineHeight(1.4f);
}
```

---

## 8. Paso 7 — El documento concreto: certificado laboral

### `Features/.../LaborCertificateModel.cs` (Application)

```csharp
namespace OpainCB.Application.Features.Certificates.Commands.GenerateLaborCertificate;

public sealed class LaborCertificateModel
{
    public required string EmployeeFullName { get; init; }
    public required string EmployeeDocument { get; init; }
    public required string Position { get; init; }
    public required string ContractType { get; init; }
    public required DateOnly HireDate { get; init; }
    public DateOnly? TerminationDate { get; init; }
    public decimal MonthlySalary { get; init; }
    public string? AddressedTo { get; init; }

    // Firma
    public required string SignerName { get; init; }
    public required string SignerPosition { get; init; }
    public string? SignerSignatureAssetKey { get; init; }   // p. ej. "firma-gerente-rrhh.png"

    public DateOnly IssueDate { get; init; } = DateOnly.FromDateTime(DateTime.Today);
    public bool IsActiveEmployee => TerminationDate is null;
}
```

### `Pdf/Documents/LaborCertificate/LaborCertificateDocument.cs` (Infrastructure)

```csharp
using System.Globalization;
using OpainCB.Application.Features.Certificates.Commands.GenerateLaborCertificate;
using OpainCB.Infrastructure.Pdf.Options;
using OpainCB.Infrastructure.Pdf.Shared;
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace OpainCB.Infrastructure.Pdf.Documents.LaborCertificate;

internal sealed class LaborCertificateDocument : BasePdfDocument<LaborCertificateModel>
{
    private static readonly CultureInfo Culture = new("es-CO");
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
    protected override bool ShowTitleInHeader => false;   // el título va grande en el contenido

    protected override void ComposeContent(IContainer container)
    {
        container.Column(column =>
        {
            column.Spacing(14);

            column.Item().AlignCenter().Text("CERTIFICACIÓN LABORAL")
                .FontSize(14).Bold().FontColor(PdfPalette.Primary).LetterSpacing(0.05f);

            column.Item().AlignRight().Text(
                $"Bogotá D.C., {Model.IssueDate.ToString("d 'de' MMMM 'de' yyyy", Culture)}");

            column.Item().Text(string.IsNullOrWhiteSpace(Model.AddressedTo)
                ? "A QUIEN INTERESE:"
                : $"Señores {Model.AddressedTo!.ToUpperInvariant()}:").Bold();

            column.Item().Text(ComposeBodyText).Justify();

            column.Item().Element(ComposeDetailTable);

            column.Item().Text(
                "La presente certificación se expide a solicitud del interesado, " +
                "a los fines que estime convenientes.").Justify();

            column.Item().PaddingTop(30).Element(ComposeSignature);
        });
    }

    private string ComposeBodyText()
    {
        var verb = Model.IsActiveEmployee ? "labora actualmente" : "laboró";
        var period = Model.IsActiveEmployee
            ? $"desde el {Model.HireDate.ToString("d 'de' MMMM 'de' yyyy", Culture)}"
            : $"entre el {Model.HireDate.ToString("d 'de' MMMM 'de' yyyy", Culture)} " +
              $"y el {Model.TerminationDate!.Value.ToString("d 'de' MMMM 'de' yyyy", Culture)}";

        return $"{Branding.CompanyName}, identificada con {Branding.CompanyDocument}, " +
               $"certifica que el(la) señor(a) {Model.EmployeeFullName}, identificado(a) con documento " +
               $"No. {Model.EmployeeDocument}, {verb} en esta compañía {period}, " +
               $"desempeñando el cargo de {Model.Position} mediante {Model.ContractType}.";
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

            if (Model.MonthlySalary > 0)
                AddRow(column, "Salario mensual", Model.MonthlySalary.ToString("C0", Culture));
        });

        static void AddRow(ColumnDescriptor column, string label, string value) =>
            column.Item().Row(row =>
            {
                row.ConstantItem(150).Text(label).SemiBold().FontSize(10);
                row.RelativeItem().Text(value).FontSize(10);
            });
    }

    private void ComposeSignature(IContainer container)
    {
        // AlignLeft/AlignCenter según el formato institucional.
        container.AlignLeft().Component(
            new SignatureBlockComponent(
                _signatureImage,
                Model.SignerName,
                Model.SignerPosition,
                Branding.CompanyName));
    }
}
```

> **Nota sobre `column.Item().Text(ComposeBodyText)`**: el `Text()` recibe el string ya construido; se usa el método para no ensuciar el `Compose`. Si tu versión de QuestPDF no acepta el grupo de métodos, escribe `column.Item().Text(ComposeBodyText()).Justify();`.

### `Pdf/Documents/LaborCertificate/LaborCertificateDocumentBuilder.cs`

Aquí se resuelven las imágenes (async) y se arma el documento.

```csharp
using Microsoft.Extensions.Options;
using OpainCB.Application.Contracts.Pdf;
using OpainCB.Application.Features.Certificates.Commands.GenerateLaborCertificate;
using OpainCB.Infrastructure.Pdf.Options;

namespace OpainCB.Infrastructure.Pdf.Documents.LaborCertificate;

internal sealed class LaborCertificateDocumentBuilder : IPdfDocumentBuilder<LaborCertificateModel>
{
    private readonly IPdfAssetProvider _assets;
    private readonly PdfBrandingOptions _branding;
    private readonly TimeProvider _time;

    public LaborCertificateDocumentBuilder(
        IPdfAssetProvider assets,
        IOptions<PdfBrandingOptions> branding,
        TimeProvider time)
    {
        _assets = assets;
        _branding = branding.Value;
        _time = time;
    }

    public string BuildFileName(LaborCertificateModel model) =>
        $"certificado-laboral-{model.EmployeeDocument}-{model.IssueDate:yyyyMMdd}.pdf";

    public async Task<object> BuildDocumentAsync(LaborCertificateModel model, CancellationToken cancellationToken = default)
    {
        var headerLogo = await _assets.GetOrDefaultAsync(_branding.LogoAssetKey, cancellationToken);
        var footerLogo = await _assets.GetOrDefaultAsync(_branding.FooterLogoAssetKey, cancellationToken);
        var signature  = await _assets.GetOrDefaultAsync(model.SignerSignatureAssetKey, cancellationToken);

        return new LaborCertificateDocument(
            model, _branding, headerLogo, footerLogo, signature, _time.GetLocalNow());
    }
}
```

---

## 9. Paso 8 — El generador y el registro en DI

### `Pdf/QuestPdfGenerator.cs`

```csharp
using Microsoft.Extensions.DependencyInjection;
using OpainCB.Application.Contracts.Pdf;
using QuestPDF.Fluent;
using QuestPDF.Infrastructure;

namespace OpainCB.Infrastructure.Pdf;

internal sealed class QuestPdfGenerator : IPdfGenerator
{
    private readonly IServiceProvider _serviceProvider;

    public QuestPdfGenerator(IServiceProvider serviceProvider) => _serviceProvider = serviceProvider;

    public async Task<PdfFile> GenerateAsync<TModel>(TModel model, CancellationToken cancellationToken = default)
        where TModel : class
    {
        var builder = _serviceProvider.GetRequiredService<IPdfDocumentBuilder<TModel>>();

        var built = await builder.BuildDocumentAsync(model, cancellationToken);

        if (built is not IDocument document)
            throw new InvalidOperationException(
                $"El builder de {typeof(TModel).Name} no devolvió un IDocument de QuestPDF.");

        // GeneratePdf es CPU-bound y síncrono: se saca del hilo de request.
        var bytes = await Task.Run(document.GeneratePdf, cancellationToken);

        return new PdfFile(bytes, builder.BuildFileName(model));
    }
}
```

### Registro en `InfrastructureServiceRegistration.cs`

```csharp
public static IServiceCollection AddInfrastructureServices(
    this IServiceCollection services, IConfiguration configuration)
{
    // ... registros existentes

    QuestPDF.Settings.License = LicenseType.Community;   // cambiar si se adquiere licencia comercial

    services.Configure<PdfBrandingOptions>(configuration.GetSection(PdfBrandingOptions.SectionName));
    services.AddMemoryCache();
    services.TryAddSingleton(TimeProvider.System);

    services.AddSingleton<IPdfAssetProvider, FileSystemPdfAssetProvider>();
    services.AddScoped<IPdfGenerator, QuestPdfGenerator>();

    // Un registro por cada tipo de PDF:
    services.AddScoped<IPdfDocumentBuilder<LaborCertificateModel>, LaborCertificateDocumentBuilder>();

    return services;
}
```

Opcional, para fuentes propias (recomendado si el contenedor es Linux):

```csharp
using var fontStream = File.OpenRead(Path.Combine(AppContext.BaseDirectory, "Assets/Pdf/Fonts/Roboto-Regular.ttf"));
FontManager.RegisterFont(fontStream);
```

---

## 10. Paso 9 — Feature (MediatR) en Application

### `GenerateLaborCertificateCommand.cs`

```csharp
using MediatR;
using OpainCB.Application.Contracts.Pdf;

namespace OpainCB.Application.Features.Certificates.Commands.GenerateLaborCertificate;

public sealed record GenerateLaborCertificateCommand(string EmployeeDocument, string? AddressedTo)
    : IRequest<PdfFile>;
```

### `GenerateLaborCertificateCommandHandler.cs`

```csharp
using MediatR;
using OpainCB.Application.Contracts.Pdf;

namespace OpainCB.Application.Features.Certificates.Commands.GenerateLaborCertificate;

public sealed class GenerateLaborCertificateCommandHandler
    : IRequestHandler<GenerateLaborCertificateCommand, PdfFile>
{
    private readonly IEmployeeRepository _employees;   // tu repositorio existente
    private readonly IPdfGenerator _pdfGenerator;

    public GenerateLaborCertificateCommandHandler(IEmployeeRepository employees, IPdfGenerator pdfGenerator)
    {
        _employees = employees;
        _pdfGenerator = pdfGenerator;
    }

    public async Task<PdfFile> Handle(GenerateLaborCertificateCommand request, CancellationToken cancellationToken)
    {
        var employee = await _employees.GetByDocumentAsync(request.EmployeeDocument, cancellationToken)
            ?? throw new NotFoundException(nameof(Employee), request.EmployeeDocument);

        var model = new LaborCertificateModel
        {
            EmployeeFullName = employee.FullName,
            EmployeeDocument = employee.Document,
            Position = employee.Position,
            ContractType = employee.ContractType,
            HireDate = employee.HireDate,
            TerminationDate = employee.TerminationDate,
            MonthlySalary = employee.MonthlySalary,
            AddressedTo = request.AddressedTo,
            SignerName = "Nombre del firmante",
            SignerPosition = "Gerente de Gestión Humana",
            SignerSignatureAssetKey = "firma-gerente-gh.png"
        };

        return await _pdfGenerator.GenerateAsync(model, cancellationToken);
    }
}
```

> El firmante puede venir de configuración o de base de datos; deja de una vez la puerta abierta para no tenerlo quemado en el handler.

### `GenerateLaborCertificateCommandValidator.cs`

```csharp
using FluentValidation;

namespace OpainCB.Application.Features.Certificates.Commands.GenerateLaborCertificate;

public sealed class GenerateLaborCertificateCommandValidator
    : AbstractValidator<GenerateLaborCertificateCommand>
{
    public GenerateLaborCertificateCommandValidator()
    {
        RuleFor(x => x.EmployeeDocument)
            .NotEmpty().WithMessage("El documento del empleado es obligatorio.")
            .MaximumLength(20);

        RuleFor(x => x.AddressedTo).MaximumLength(150);
    }
}
```

---

## 11. Paso 10 — Endpoint en WebApp

```csharp
using MediatR;
using Microsoft.AspNetCore.Mvc;
using OpainCB.Application.Features.Certificates.Commands.GenerateLaborCertificate;

namespace OpainCB.WebApp.Controllers;

[ApiController]
[Route("api/v1/certificados")]
public sealed class CertificatesController : ControllerBase
{
    private readonly IMediator _mediator;

    public CertificatesController(IMediator mediator) => _mediator = mediator;

    [HttpPost("laboral")]
    [Produces("application/pdf")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GenerateLaborCertificate(
        [FromBody] GenerateLaborCertificateCommand command,
        CancellationToken cancellationToken)
    {
        var file = await _mediator.Send(command, cancellationToken);
        return File(file.Content, file.ContentType, file.FileName);
    }
}
```

**Si la API usa un envelope estándar** (`Response<T>` + `ResponseConstants`), no devuelvas `File(...)`: rompe el contrato. En ese caso devuelve el PDF en base64 y que el front haga la descarga:

```csharp
return Ok(new Response<PdfFileDto>
{
    Data = new PdfFileDto(Convert.ToBase64String(file.Content), file.FileName, file.ContentType),
    Message = ResponseConstants.Success
});
```

Decide una de las dos y aplícala a todos los PDF por consistencia.

---

## 12. Cómo agregar un PDF nuevo (el objetivo del diseño)

Para cualquier documento futuro — orden de pago, paz y salvo, constancia — son **3 archivos y 1 línea de DI**:

1. **Modelo** en `Application/Features/<Area>/.../XxxModel.cs`.
2. **Documento** en `Infrastructure/Pdf/Documents/Xxx/XxxDocument.cs` heredando de `BasePdfDocument<XxxModel>` e implementando solo `DocumentTitle` y `ComposeContent`.
3. **Builder** `XxxDocumentBuilder : IPdfDocumentBuilder<XxxModel>`.
4. **Registro**: `services.AddScoped<IPdfDocumentBuilder<XxxModel>, XxxDocumentBuilder>();`

El header y el footer se heredan solos. Si un documento necesita orientación horizontal o márgenes distintos, sobrescribe `PageSize` o `MarginCentimeters`.

---

## 13. Probar sin levantar la API

Proyecto de consola o test unitario:

```csharp
QuestPDF.Settings.License = LicenseType.Community;

var branding = new PdfBrandingOptions { CompanyName = "OPAIN S.A.", CompanyDocument = "NIT 900.105.860-4" };
var model = new LaborCertificateModel { /* datos de prueba */ };

var document = new LaborCertificateDocument(
    model, branding,
    headerLogo: File.ReadAllBytes("logo.png"),
    footerLogo: null,
    signatureImage: File.ReadAllBytes("firma.png"),
    generatedAt: DateTimeOffset.Now);

document.GeneratePdf("certificado-prueba.pdf");
```

Para iterar el diseño en caliente, usa el **QuestPDF Companion** (hot reload del layout):

```bash
dotnet tool install --global QuestPDF.Companion
```

```csharp
await document.ShowInCompanionAsync();   // en versiones previas: ShowInPreviewer()
```

Test de humo recomendado:

```csharp
[Fact]
public async Task Genera_certificado_con_contenido_valido()
{
    var file = await _generator.GenerateAsync(ModelBuilder.Valid());

    Assert.NotEmpty(file.Content);
    Assert.StartsWith("%PDF", System.Text.Encoding.ASCII.GetString(file.Content, 0, 4));
    Assert.EndsWith(".pdf", file.FileName);
}
```

---

## 14. Errores comunes y cómo evitarlos

| Síntoma | Causa | Solución |
|---|---|---|
| `DocumentLayoutException` | Un elemento no cabe en la página (tabla ancha, imagen grande, `Height` fijo excesivo) | Activa `QuestPDF.Settings.EnableDebugging = true` en desarrollo: el mensaje indica el elemento exacto. |
| Excepción de fuentes / texto en blanco en Linux o Docker | La imagen base no trae fuentes ni `libfontconfig1` | En el Dockerfile: `RUN apt-get update && apt-get install -y --no-install-recommends libfontconfig1 libfreetype6 && rm -rf /var/lib/apt/lists/*` y registra una fuente propia con `FontManager.RegisterFont`. |
| Firma se ve pixelada | Imagen pequeña escalada hacia arriba | Usa PNG con fondo transparente de al menos 600 px de ancho; QuestPDF no inventa resolución. |
| PDF muy pesado | Imágenes en alta sin compresión | `DocumentSettings { ImageCompressionQuality = ImageCompressionQuality.High, ImageRasterDpi = 144 }`. |
| Excepción de licencia al arrancar | Falta `QuestPDF.Settings.License` | Configúralo una sola vez en el registro de Infrastructure o en `Program.cs`. |
| Request lento / thread pool ahogado | `GeneratePdf()` corriendo en el hilo del request | Ya resuelto con `Task.Run` en `QuestPdfGenerator`; para volúmenes altos, encola el trabajo en background. |
| Leer el logo del disco en cada request | Sin caché | Ya resuelto con `IMemoryCache` en `FileSystemPdfAssetProvider`. |

---

## 15. Checklist de cierre

- [ ] `QuestPDF` está **solo** en `OpainCB.Infrastructure.csproj`.
- [ ] La licencia está configurada y validada con el líder técnico.
- [ ] `Assets/Pdf` se copia al output (`CopyToOutputDirectory`).
- [ ] La sección `Pdf` existe en `appsettings.json` de todos los ambientes.
- [ ] Header y footer se ven idénticos en un PDF de 1 página y en uno de 3 (probar con contenido largo).
- [ ] La paginación muestra "Página X de Y" correctamente.
- [ ] El bloque de firma conserva su alto cuando no hay imagen.
- [ ] El endpoint respeta el contrato de respuesta del resto de la API.
- [ ] Hay al menos un test que valida bytes `%PDF` y nombre de archivo.
- [ ] Probado dentro del contenedor Linux, no solo en Windows.
