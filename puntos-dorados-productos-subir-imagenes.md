# 🖼️ Puntos Dorados — Subir imágenes de productos (además de los enlaces)

Hoy el formulario de producto recibe **enlaces** de imágenes (`imageUrls`). Esta guía agrega la opción de **subir archivos**. Las dos conviven:

| El administrador… | Qué pasa |
|---|---|
| Pega un enlace (`https://…`) | Igual que hoy. |
| Sube un archivo | La API lo guarda y devuelve una URL `https` propia. Esa URL entra en la **misma lista** `imageUrls`, como si fuera un enlace. |

El producto se sigue guardando igual (`POST/PUT /api/GoldenProducts` con `imageUrls`). La validación actual (solo URLs absolutas `https`, máximo 10) no cambia: las URLs de las imágenes subidas la cumplen.

**Base:** la lógica de `CommunicationController` / `CommunicationService` del backend. **Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md).

---

## 1. Cómo sube imágenes Comunicaciones hoy

| Pieza | Qué hace | ¿Se reutiliza? |
|---|---|---|
| `[FromForm] List<IFormFile> imageFiles` | Recibe los archivos en `multipart/form-data`. | ✅ Igual, uno por petición. |
| `ValidateCommunicationRequest` | Extensión `.jpg/.jpeg/.png`, máximo 5 MB, no vacío. | ✅ Y se agrega revisar el **contenido** (sección 3, decisión 3). |
| `StoreFile` | Nombre `{título}_{Guid}{ext}`, `FileStream`, lista de rutas guardadas. | ✅ Nombre solo con `Guid`: el producto puede no existir todavía. |
| `CleanupFiles` | Si algo falla, borra lo que alcanzó a escribir. | ✅ |
| **`Frontend:AssetsPath`** | Guarda en la carpeta `assets` **del frontend** y devuelve `assets/news/…` para que el frontend la sirva. | ❌ Ver sección 2. |
| `DeleteResourcesFromFolder` | Al desactivar, borra los archivos. | ✅ Al quitar una imagen subida de un producto. |

---

## 2. Evaluación: dónde guardar las imágenes

| Opción | A favor | En contra |
|---|---|---|
| **A. La carpeta `assets` del frontend** (como Comunicaciones) | No hay que servir nada desde la API: el frontend publica la imagen. | **Un despliegue del frontend que reemplace la carpeta publicada borra las imágenes subidas.** La API necesita permiso de escritura en la carpeta del frontend (mismo servidor). En desarrollo escribe en `src/assets` del repositorio: `ng serve` recompila con cada imagen y los archivos terminan en git. |
| **B. Una carpeta propia del servidor, publicada por la API** ✅ | Sobrevive a los despliegues de los dos proyectos. Es la misma lógica de subida. La URL es `https` de la API, así que pasa la validación actual del producto sin tocar el módulo. Es el mismo enfoque de `SystemFileServer` (solicitudes). | Hay que agregar 15 líneas en `Program.cs` para servir la carpeta. Las imágenes son públicas para quien tenga la URL; como los nombres son GUID, no se pueden adivinar. |
| C. SharePoint / DocManager | Ya hay integración. | Un `<img>` no puede enviar el token: haría falta un enlace temporal por imagen. Es mucho más complejo para un catálogo. |
| D. En la base de datos (`varbinary`) | Todo en un solo lugar. | La base crece rápido, hay que servir cada imagen por un endpoint y se pierde la caché del servidor web. |

**Decisión: B.**

> ⚠️ **Lo mismo le pasa hoy a Comunicaciones.** Si el despliegue del frontend reemplaza la carpeta publicada, las imágenes de `assets/news` se pierden. Vale la pena revisar cómo se despliega. Si se pierden, Comunicaciones se puede pasar a este mismo esquema después.

---

## 3. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Dos pasos.** | 1) `POST /api/GoldenProducts/images` sube **un** archivo y responde su URL. 2) El formulario guarda el producto con esa URL en `imageUrls`, como hoy. Funciona igual al crear y al editar, y la imagen se ve en la vista previa antes de guardar. |
| 2 | **Un archivo por petición.** | Máximo 5 MB por imagen. Si se eligen varias, el frontend las sube una por una. Así ninguna petición pasa el límite de IIS (30 MB por defecto) y un error en una no afecta a las demás. |
| 3 | **Validar el contenido, no solo la extensión.** | Comunicaciones solo mira la extensión: un `.exe` renombrado a `.png` pasaría. Aquí se leen los primeros bytes (firma de JPG, PNG o WEBP). |
| 4 | **Formatos.** | JPG, JPEG, PNG y WEBP. No SVG: puede llevar scripts. |
| 5 | **Nombre del archivo.** | `{Guid}{ext}`, nunca el nombre original: evita choques, rutas raras (`../`) y que se adivinen las URLs. |
| 6 | **Públicas, sin token.** | Un `<img src>` no envía el token de MSAL. Son fotos de premios del catálogo, no información sensible, y la URL no se puede adivinar. Se publican **antes** de la autenticación en `Program.cs`. |
| 7 | **Caché.** | El nombre nunca cambia (si cambia la imagen, cambia el GUID), así que se publican con caché de un año (`immutable`): el navegador no las vuelve a pedir. |
| 8 | **Quitar una imagen subida.** | Al guardar el producto sin ella, la API borra el archivo, **después** de confirmar la transacción. Los enlaces externos no se tocan. |
| 9 | **Subidas que nunca se guardaron.** | Por ejemplo, si se sube una imagen y se cancela el formulario. Una limpieza borra los archivos de más de 24 horas que ningún producto usa (sección 8). |
| 10 | **Permisos.** | Igual que el resto de administración (comentados por ahora). |

---

## 4. Paso 1 — Configuración

### `WebApp/appsettings.json` ✏️ — agrega la sección

```json
"GoldenProductImages": {
  "PhysicalPath": "C:\\DOCCBStorage\\golden_products",
  "RequestPath": "/files/golden-products",
  "PublicBaseUrl": "https://<host-de-la-api>"
}
```

| Clave | Qué es |
|---|---|
| `PhysicalPath` | Carpeta del servidor donde se guardan. Ponla junto a las de `SystemFileServer`, **fuera** de la carpeta publicada de la API y del frontend. |
| `RequestPath` | Ruta pública con la que la API sirve la carpeta. |
| `PublicBaseUrl` | La dirección `https` pública de la API, **sin** `/api` (por ejemplo `https://api-compensacion.empresa.co`). La URL final es `{PublicBaseUrl}{RequestPath}/{archivo}`. |

### `WebApp/appsettings.Development.json` ✏️

```json
"GoldenProductImages": {
  "PhysicalPath": "C:\\DOCCBStorage\\golden_products",
  "RequestPath": "/files/golden-products",
  "PublicBaseUrl": "https://localhost:7208"
}
```

> **En desarrollo, usa el perfil `https`** (`https://localhost:7208`). La validación de productos solo acepta URLs `https`; con el perfil `http` (`:5213`) la imagen se sube, pero el producto no se guarda.
>
> **Permisos de la carpeta:** la identidad del pool de IIS necesita **modificar** en `PhysicalPath`, igual que en las carpetas de `SystemFileServer`.

---

## 5. Paso 2 — `WebApp/Program.cs` ✏️: publicar la carpeta

Va **después** de `UseHttpsRedirection` y **antes** de `UseAzureAdAuthentication`, para que las imágenes no pidan token:

```csharp
using Microsoft.Extensions.FileProviders;

// …

app.UseHttpsRedirection();

// Imágenes de productos de Puntos Dorados: archivos públicos con nombre GUID, antes de la autenticación.
var productImages = builder.Configuration.GetSection("GoldenProductImages");
var productImagesPath = productImages["PhysicalPath"];
if (!string.IsNullOrWhiteSpace(productImagesPath))
{
    Directory.CreateDirectory(productImagesPath);

    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider(productImagesPath),
        RequestPath = productImages["RequestPath"] ?? "/files/golden-products",
        OnPrepareResponse = context =>
        {
            // El nombre nunca cambia: caché de un año.
            context.Context.Response.Headers["Cache-Control"] = "public, max-age=31536000, immutable";
            // El navegador no intenta adivinar otro tipo de contenido.
            context.Context.Response.Headers["X-Content-Type-Options"] = "nosniff";
        },
    });
}

// Configuración Azure AD Middleware
app.UseAzureAdAuthentication(builder.Configuration);
```

> Es la única carpeta que se publica: `UseStaticFiles` con `FileProvider` solo sirve lo que hay en `PhysicalPath`. No publica `wwwroot` ni nada más.
>
> **CORS:** un `<img>` de otro dominio no necesita CORS. La subida sí pasa por CORS, pero va al controlador, que ya está cubierto por la política actual.

---

## 6. Paso 3 — Servicio de imágenes

### `Constants/GoldenProductImageConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenProductImageConstants
    {
        public const long MaxBytes = 5 * 1024 * 1024;
        /// <summary>Límite de la petición: la imagen + lo que agrega multipart/form-data.</summary>
        public const long RequestMaxBytes = MaxBytes + 512 * 1024;

        public static readonly string[] AllowedExtensions = [".jpg", ".jpeg", ".png", ".webp"];

        public const string FileRequired = "Selecciona una imagen.";
        public const string FileEmpty = "La imagen está vacía.";
        public const string FileTooLarge = "La imagen supera los 5 MB.";
        public const string FileTypeInvalid = "Solo se permiten imágenes JPG, PNG o WEBP.";
        public const string FileContentInvalid = "El archivo no es una imagen válida.";
        public const string StorageNotConfigured = "No está configurada la carpeta de imágenes de productos.";
        public const string SaveFailed = "No se pudo guardar la imagen. Intenta de nuevo.";
    }
}
```

### `Dtos/GoldenProductImageDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>Respuesta de subir una imagen: la URL va a ImageUrls del producto.</summary>
    public class GoldenProductImageUploadDto
    {
        public string Url { get; set; } = string.Empty;
        /// <summary>Nombre original, solo para mostrarlo.</summary>
        public string FileName { get; set; } = string.Empty;
        public long SizeBytes { get; set; }
    }
}
```

### `Interfaces/IGoldenProductImageService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using Microsoft.AspNetCore.Http;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenProductImageService
    {
        /// <summary>Valida, guarda y devuelve la URL pública de una imagen.</summary>
        Task<ResponseDto<GoldenProductImageUploadDto>> UploadAsync(IFormFile? file, string uploadedBy, CancellationToken cancellationToken = default);

        /// <summary>Borra los archivos de estas URLs que sean imágenes subidas aquí. Los enlaces externos se ignoran.</summary>
        void DeleteOwnedImages(IEnumerable<string> urls);

        /// <summary>Borra las imágenes subidas que ningún producto usa y tienen más de <paramref name="olderThan"/>.</summary>
        Task<int> DeleteOrphansAsync(TimeSpan olderThan, CancellationToken cancellationToken = default);
    }
}
```

### `Services/GoldenProductImageService.cs`

En la capa Application, como `CommunicationService` y `RequestLocalStorageService`, que también escriben archivos con `IConfiguration`:

```csharp
using System.Text.RegularExpressions;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Helpers;
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public partial class GoldenProductImageService(
        IConfiguration configuration,
        ITransactionExecutorHelper transactionHelper,
        ILogger<GoldenProductImageService> logger) : IGoldenProductImageService
    {
        private readonly IConfiguration _configuration = configuration;
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly ILogger<GoldenProductImageService> _logger = logger;

        /// <summary>Solo nombres que genera este servicio: 32 hex + extensión permitida. Evita borrar algo fuera de la carpeta.</summary>
        [GeneratedRegex(@"^[0-9a-f]{32}\.(jpg|jpeg|png|webp)$", RegexOptions.IgnoreCase)]
        private static partial Regex OwnedFileNamePattern();

        // ── Subir ───────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenProductImageUploadDto>> UploadAsync(IFormFile? file, string uploadedBy, CancellationToken cancellationToken = default)
        {
            var settings = Settings();
            if (settings is null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductImageUploadDto>(GoldenProductImageConstants.StorageNotConfigured);
            }

            var validationError = await ValidateAsync(file, cancellationToken);
            if (validationError is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductImageUploadDto>(validationError);
            }

            // ".JPEG" → ".jpeg": la URL siempre en minúsculas.
            var extension = Path.GetExtension(file!.FileName).ToLowerInvariant();
            var fileName = $"{Guid.NewGuid():N}{extension}";
            var fullPath = Path.Combine(settings.PhysicalPath, fileName);

            try
            {
                Directory.CreateDirectory(settings.PhysicalPath);

                // CreateNew: nunca pisa un archivo existente.
                await using var stream = new FileStream(fullPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                await file.CopyToAsync(stream, cancellationToken);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error guardando la imagen de producto '{FileName}' subida por {User}", file.FileName, uploadedBy);
                TryDelete(fullPath);
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductImageUploadDto>(GoldenProductImageConstants.SaveFailed);
            }

            _logger.LogInformation("Imagen de producto {StoredName} ({Size} bytes) subida por {User}", fileName, file.Length, uploadedBy);

            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenProductImageUploadDto
            {
                Url = settings.PublicUrl(fileName),
                FileName = Path.GetFileName(file.FileName),
                SizeBytes = file.Length,
            });
        }

        // ── Borrar las que ya no usa un producto ────────────────────────

        public void DeleteOwnedImages(IEnumerable<string> urls)
        {
            var settings = Settings();
            if (settings is null)
            {
                return;
            }

            foreach (var url in urls)
            {
                var fileName = settings.FileNameFromUrl(url);
                if (fileName is not null)
                {
                    TryDelete(Path.Combine(settings.PhysicalPath, fileName));
                }
            }
        }

        // ── Limpiar subidas que nunca se guardaron ──────────────────────

        public async Task<int> DeleteOrphansAsync(TimeSpan olderThan, CancellationToken cancellationToken = default)
        {
            var settings = Settings();
            if (settings is null || !Directory.Exists(settings.PhysicalPath))
            {
                return 0;
            }

            // Las URLs propias que siguen en uso, en una sola consulta.
            var prefix = settings.PublicUrl(string.Empty);
            var used = await _transactionHelper.ExecuteQueryAsync<HashSet<string>>(async unitOfWork =>
                (await unitOfWork.Repository<GoldenProductImage>().GetListAsync<string>(
                    i => i.Url.StartsWith(prefix),
                    selector: q => q.Select(i => i.Url)))
                .Select(url => settings.FileNameFromUrl(url))
                .Where(name => name is not null)
                .Select(name => name!)
                .ToHashSet(StringComparer.OrdinalIgnoreCase)) ?? [];

            var limit = DateTime.UtcNow - olderThan;
            var deleted = 0;

            foreach (var path in Directory.EnumerateFiles(settings.PhysicalPath))
            {
                cancellationToken.ThrowIfCancellationRequested();

                var name = Path.GetFileName(path);
                if (!OwnedFileNamePattern().IsMatch(name) || used.Contains(name) || File.GetCreationTimeUtc(path) > limit)
                {
                    continue;
                }

                if (TryDelete(path))
                {
                    deleted++;
                }
            }

            if (deleted > 0)
            {
                _logger.LogInformation("Se borraron {Count} imágenes de productos sin usar", deleted);
            }

            return deleted;
        }

        // ── Privados ────────────────────────────────────────────────────

        private sealed record ImageSettings(string PhysicalPath, string RequestPath, string PublicBaseUrl)
        {
            public string PublicUrl(string fileName) => $"{PublicBaseUrl.TrimEnd('/')}/{RequestPath.Trim('/')}/{fileName}";

            /// <summary>El nombre del archivo si la URL es una imagen subida aquí; null si es un enlace externo.</summary>
            public string? FileNameFromUrl(string? url)
            {
                var prefix = PublicUrl(string.Empty);
                if (string.IsNullOrWhiteSpace(url) || !url.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }

                var name = url[prefix.Length..];
                return OwnedFileNamePattern().IsMatch(name) ? name : null;
            }
        }

        private ImageSettings? Settings()
        {
            var section = _configuration.GetSection("GoldenProductImages");
            var physicalPath = section["PhysicalPath"];
            var publicBaseUrl = section["PublicBaseUrl"];

            return string.IsNullOrWhiteSpace(physicalPath) || string.IsNullOrWhiteSpace(publicBaseUrl)
                ? null
                : new ImageSettings(physicalPath, section["RequestPath"] ?? "/files/golden-products", publicBaseUrl);
        }

        /// <summary>Lo mismo que Comunicaciones (extensión, tamaño, vacío) + la firma de los primeros bytes.</summary>
        private static async Task<string?> ValidateAsync(IFormFile? file, CancellationToken cancellationToken)
        {
            if (file is null)
            {
                return GoldenProductImageConstants.FileRequired;
            }

            if (file.Length == 0)
            {
                return GoldenProductImageConstants.FileEmpty;
            }

            if (file.Length > GoldenProductImageConstants.MaxBytes)
            {
                return GoldenProductImageConstants.FileTooLarge;
            }

            var extension = Path.GetExtension(file.FileName).ToLowerInvariant();
            if (!GoldenProductImageConstants.AllowedExtensions.Contains(extension))
            {
                return GoldenProductImageConstants.FileTypeInvalid;
            }

            return await HasImageSignatureAsync(file, extension, cancellationToken)
                ? null
                : GoldenProductImageConstants.FileContentInvalid;
        }

        /// <summary>Un .exe renombrado a .png no pasa: se revisan los primeros bytes según la extensión.</summary>
        private static async Task<bool> HasImageSignatureAsync(IFormFile file, string extension, CancellationToken cancellationToken)
        {
            var header = new byte[12];
            await using var stream = file.OpenReadStream();
            var read = await stream.ReadAtLeastAsync(header, header.Length, throwOnEndOfStream: false, cancellationToken);

            return extension switch
            {
                ".jpg" or ".jpeg" => read >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF,
                ".png" => read >= 8 && header.AsSpan(0, 8).SequenceEqual(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }),
                ".webp" => read >= 12 && header.AsSpan(0, 4).SequenceEqual("RIFF"u8) && header.AsSpan(8, 4).SequenceEqual("WEBP"u8),
                _ => false,
            };
        }

        private bool TryDelete(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                    return true;
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "No fue posible borrar la imagen {Path}", path);
            }

            return false;
        }
    }
}
```

> **`GetListAsync<string>` con `selector`:** es la sobrecarga de proyección del repositorio genérico. Con `selector`, el `orderBy` se ignora; aquí no hace falta.
>
> **Sin `try/catch` general en `UploadAsync`:** los errores de validación vuelven como `ResponseDto` con error. Un error inesperado al escribir se registra, se borra lo que alcanzó a escribir y se responde `SaveFailed`, igual que `CleanupFiles` en Comunicaciones.

### Registro — `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IGoldenProductImageService, GoldenProductImageService>();
```

---

## 7. Paso 4 — Controlador y producto

### `ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenProductImageErrorMessage = "No se pudo subir la imagen del producto.";
```

### `Controllers/GoldenProductsController.cs` ✏️ — agrega la acción

El controlador recibe también `IGoldenProductImageService` en el constructor primario (`private readonly IGoldenProductImageService _imageService = imageService;`).

```csharp
/// <summary>
/// Sube UNA imagen (multipart/form-data, campo "file") y devuelve su URL pública.
/// La URL se agrega a ImageUrls al crear o editar el producto.
/// </summary>
[HttpPost("images")]
[Consumes("multipart/form-data")]
[RequestSizeLimit(GoldenProductImageConstants.RequestMaxBytes)]
[RequestFormLimits(MultipartBodyLengthLimit = GoldenProductImageConstants.RequestMaxBytes)]
[ProducesResponseType(StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
[ProducesResponseType(StatusCodes.Status401Unauthorized)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
public async Task<IActionResult> UploadImage(IFormFile? file, CancellationToken cancellationToken)
{
    try
    {
        var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
        if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
        {
            return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
        }

        // Permisos (pendiente): solo administración del programa.

        var response = await _imageService.UploadAsync(file, authenticatedUserInfo.Email, cancellationToken);
        return Ok(response);
    }
    catch (ArgumentException ex)
    {
        return BadRequest(new { message = ApiResponseConstants.GoldenProductImageErrorMessage, error = ex.Message });
    }
    catch (UnauthorizedAccessException)
    {
        return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
    }
    catch (Exception)
    {
        return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductImageErrorMessage });
    }
}
```

> Con `[ApiController]`, un `IFormFile` se lee del formulario sin `[FromForm]`. El nombre del parámetro (`file`) es el del campo que envía el frontend.
>
> **Un archivo de más de 5,5 MB** lo corta ASP.NET antes de llegar a la acción (HTTP 413). El frontend revisa el tamaño antes de enviarlo, así que en la práctica no llega.

### `Services/GoldenProductService.UpdateAsync` ✏️ — borrar las imágenes que se quitaron

Inyecta `IGoldenProductImageService` en el servicio de productos (`private readonly IGoldenProductImageService _imageService = imageService;`). En `UpdateAsync`:

1. **Antes del helper**, declara la lista donde se guardan las URLs quitadas:

```csharp
var removedUrls = new List<string>();
```

2. **Dentro de la lambda**, donde hoy se reemplazan las imágenes, antes del `foreach` que las borra:

```csharp
// Las URLs que el producto tenía y ya no tiene: sus archivos se borran después de guardar.
removedUrls.AddRange(currentImages.Select(i => i.Url).Except(draft.ImageUrls, StringComparer.OrdinalIgnoreCase));
```

3. **El `return await _transactionHelper…`** se cambia para borrar **después** de confirmar:

```csharp
var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductDto>>(
    async unitOfWork => { /* … lo de hoy … */ }
) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.UnexpectedError);

// Solo si se guardó: si la transacción falló, el producto conserva sus imágenes y los archivos se quedan.
if (!response.HasError)
{
    _imageService.DeleteOwnedImages(removedUrls);
}

return response;
```

> `DeleteOwnedImages` ignora los enlaces externos y cualquier URL que no tenga la forma `{GUID}.{ext}` de la carpeta. Si un producto quita un enlace de Google Drive, por ejemplo, no se borra nada.

---

## 8. Paso 5 — Limpieza de subidas que nunca se guardaron

**Caso:** se sube una imagen y el administrador cancela el formulario. El archivo queda en la carpeta sin ningún producto que lo use.

`DeleteOrphansAsync(TimeSpan.FromDays(1))` borra los archivos de más de 24 horas que ninguna fila de `golden_product_image` usa. Las 24 horas son margen para un formulario que siga abierto. Hay dos formas de llamarlo:

- **Si ya tienes un proceso diario** (por ejemplo, el worker del vencimiento de puntos): al final de cada ciclo, en el mismo scope:

```csharp
var images = scope.ServiceProvider.GetRequiredService<IGoldenProductImageService>();
await images.DeleteOrphansAsync(TimeSpan.FromDays(1), stoppingToken);
```

- **Si no:** una acción de administración `POST /api/GoldenProducts/images/cleanup` que llame al método y devuelva cuántos borró. Se usa cuando se necesite.

Los archivos huérfanos no se ven en ningún lado ni afectan nada; solo ocupan espacio. Por eso basta con limpiar una vez al día.

---

## 9. Paso 6 — Frontend

### `domain/puntos-dorados.ts` ✏️ — agrega

```ts
export interface GoldenProductImageUpload {
  url: string;
  fileName: string;
  sizeBytes: number;
}

/** Mismos límites que la API (GoldenProductImageConstants y GoldenProductConstants.MaxImages). */
export const GOLDEN_PRODUCT_IMAGE_LIMITS = {
  maxBytes: 5 * 1024 * 1024,
  maxImages: 10,
  accept: '.jpg,.jpeg,.png,.webp',
  types: ['image/jpeg', 'image/png', 'image/webp'],
} as const;
```

### `infrastructure/services/golden-products.service.ts` ✏️ — agrega

```ts
/** Sube UNA imagen (multipart/form-data, campo "file") y devuelve su URL pública. */
async uploadImage(file: File): Promise<Observable<ResponseDto<GoldenProductImageUpload>>> {
  const token = await this.authService.getAccessToken(environment.api.apiScopes);
  // Sin Content-Type: el navegador lo pone con el "boundary" de multipart.
  const headers = new HttpHeaders({ Authorization: `Bearer ${token}` });

  const body = new FormData();
  body.append('file', file, file.name);

  return this.http.post<ResponseDto<GoldenProductImageUpload>>(`${this.apiUrl}/images`, body, { headers }).pipe(
    catchError((error: HttpErrorResponse) => this.errorHandler.handleHttpError(error, 'subir la imagen'))
  );
}
```

### `application/puntos-dorados.fecade.ts` ✏️ — agrega (junto a `upsertProduct`)

```ts
async uploadProductImage(file: File): Promise<ResponseDto<GoldenProductImageUpload>> {
  try {
    return await firstValueFrom(await this.productsService.uploadImage(file));
  } catch (error) {
    console.error('Error uploading product image:', error);
    return {
      hasError: true,
      errors: [toErrorMessage(error, `No se pudo subir "${file.name}". Intenta de nuevo.`)],
      response: null,
    };
  }
}
```

> Sigue la forma de los métodos de productos del facade (`ResponseDto` y `try/catch`).

### `presentation/admin/puntos-dorados-admin.component.ts` ✏️

```ts
import { GOLDEN_PRODUCT_IMAGE_LIMITS } from '../../domain/puntos-dorados';

readonly productImageLimits = GOLDEN_PRODUCT_IMAGE_LIMITS;
/** Subidas en curso: mientras haya alguna, no se guarda el producto. */
readonly uploadingProductImages = signal(0);
readonly productImageErrors = signal<string[]>([]);

/**
 * Archivos elegidos. Con rowIndex se reemplaza esa fila; sin rowIndex van a las filas vacías y, si no hay, a filas nuevas.
 * Se suben uno por uno (máximo 5 MB cada uno).
 */
async onProductImageFilesSelected(event: Event, rowIndex?: number): Promise<void> {
  const input = event.target as HTMLInputElement;
  const files = Array.from(input.files ?? []);
  input.value = ''; // permite volver a elegir el mismo archivo
  this.productImageErrors.set([]);

  const errors: string[] = [];

  for (const file of files) {
    const localError = this.validateProductImage(file, rowIndex);
    if (localError) {
      errors.push(localError);
      continue;
    }

    this.uploadingProductImages.update(count => count + 1);

    try {
      const result = await this.facade.uploadProductImage(file);
      if (result.hasError) {
        errors.push(...result.errors);
        continue;
      }

      this.placeProductImageUrl(result.response.url, rowIndex);
      rowIndex = undefined; // si eligió varios en una fila, el resto va a filas nuevas
    } finally {
      this.uploadingProductImages.update(count => count - 1);
    }
  }

  this.productImageErrors.set(errors);
}

private validateProductImage(file: File, rowIndex?: number): string | null {
  if (!(this.productImageLimits.types as readonly string[]).includes(file.type)) {
    return `"${file.name}": solo se permiten imágenes JPG, PNG o WEBP.`;
  }

  if (file.size > this.productImageLimits.maxBytes) {
    return `"${file.name}" supera los 5 MB.`;
  }

  const hasEmptyRow = this.productImageUrls.controls.some(control => !control.value?.trim());
  if (rowIndex === undefined && !hasEmptyRow && this.productImageUrls.length >= this.productImageLimits.maxImages) {
    return `Un producto admite hasta ${this.productImageLimits.maxImages} imágenes.`;
  }

  return null;
}

/** En la fila indicada, en la primera vacía o en una nueva. */
private placeProductImageUrl(url: string, rowIndex?: number): void {
  const controls = this.productImageUrls.controls;
  const target = rowIndex !== undefined ? controls[rowIndex] : controls.find(control => !control.value?.trim());

  if (target) {
    target.setValue(url);
    target.markAsTouched();
  } else {
    this.productImageUrls.push(this.fb.nonNullable.control(url, Validators.required));
  }
}
```

### `puntos-dorados-admin.component.html` ✏️ — el bloque `formArrayName="imageUrls"`

Reemplaza el bloque actual por este. Cada fila admite un enlace **o** un archivo, y abajo hay un botón para subir varias de una vez:

```html
<div formArrayName="imageUrls">
  <label class="field-label">Imágenes del producto</label>
  <small class="field-help">
    Pega un enlace https o sube un archivo (JPG, PNG o WEBP, máximo 5 MB). La primera es la portada.
  </small>

  @for (imageUrlControl of productImageUrls.controls; track $index) {
  <div class="image-url-row">
    @if (imageUrlControl.value?.trim()) {
    <img class="image-url-thumb" [src]="imageUrlControl.value" alt="" loading="lazy" />
    }

    <input type="text" class="field-input" [formControlName]="$index"
      [placeholder]="$index === 0 ? 'https://... (portada)' : 'https://...'" />

    <!-- Subir un archivo para ESTA fila -->
    <label class="btn-secondary image-upload-btn" [class.is-disabled]="uploadingProductImages() > 0"
      [attr.aria-label]="'Subir archivo para la imagen ' + ($index + 1)" title="Subir archivo">
      <i class="fa-solid fa-upload" aria-hidden="true"></i>
      <input type="file" hidden [accept]="productImageLimits.accept" [disabled]="uploadingProductImages() > 0"
        (change)="onProductImageFilesSelected($event, $index)" />
    </label>

    <button type="button" class="btn-secondary" [disabled]="!imageUrlControl.value?.trim()"
      [attr.aria-label]="'Ver imagen ' + ($index + 1) + ' en grande'" (click)="openProductImageUrlPreview($index)">
      <i class="fa-solid fa-eye"></i>
    </button>
    <button type="button" class="btn-secondary" [disabled]="productImageUrls.length <= 1"
      [attr.aria-label]="'Eliminar imagen ' + ($index + 1)" (click)="removeProductImageUrl($index)">
      <i class="fa-solid fa-trash"></i>
    </button>
  </div>
  @if (imageUrlControl.touched && imageUrlControl.invalid) {
  <span class="error">Pega un enlace o sube un archivo.</span>
  }
  }

  <div class="image-url-actions">
    <button type="button" class="btn-secondary" [disabled]="productImageUrls.length >= productImageLimits.maxImages"
      (click)="addProductImageUrl()">
      <i class="fa-solid fa-link" aria-hidden="true"></i> Agregar enlace
    </button>

    <label class="btn-secondary image-upload-btn" [class.is-disabled]="uploadingProductImages() > 0">
      <i class="fa-solid fa-images" aria-hidden="true"></i> Subir imágenes
      <input type="file" hidden multiple [accept]="productImageLimits.accept" [disabled]="uploadingProductImages() > 0"
        (change)="onProductImageFilesSelected($event)" />
    </label>

    @if (uploadingProductImages() > 0) {
    <small class="image-uploading" role="status">Subiendo {{ uploadingProductImages() }}…</small>
    }
  </div>

  @for (error of productImageErrors(); track error) {
  <span class="error" role="alert">{{ error }}</span>
  }
</div>
```

Y el botón "Guardar producto" espera a que terminen las subidas:

```html
<button type="submit" class="btn-primary" [disabled]="productForm.invalid || uploadingProductImages() > 0">Guardar producto</button>
```

### `puntos-dorados-admin.component.scss` ✏️ — agrega

```scss
.field-help {
  display: block;
  margin-bottom: 0.5rem;
  color: var(--bs-secondary-color, #6b7280);
  font-size: 0.8rem;
}

.image-url-thumb {
  flex-shrink: 0;
  width: 2.5rem;
  height: 2.5rem;
  border-radius: 0.5rem;
  object-fit: cover;
  background: var(--bs-tertiary-bg, #f3f4f6);
}

.image-upload-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  cursor: pointer;

  &.is-disabled {
    opacity: 0.6;
    pointer-events: none;
  }
}

.image-url-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  margin-top: 0.5rem;
}

.image-uploading {
  color: var(--bs-secondary-color, #6b7280);
}
```

> El `<input type="file">` va escondido dentro de un `<label>` con estilo de botón: así se puede abrir con el teclado y no hace falta un `ViewChild`.

---

## 10. Pruebas

**API**
- **Subida correcta:** `POST /api/GoldenProducts/images` con un JPG de 1 MB responde `{ url: "https://…/files/golden-products/3f0b….jpg" }`. Abrir esa URL en el navegador, sin sesión, muestra la imagen.
- **Encabezados de la imagen:** `Cache-Control: public, max-age=31536000, immutable` y `X-Content-Type-Options: nosniff`.
- **Archivos que no pasan:**
  - Un `.exe` renombrado a `.png`: "El archivo no es una imagen válida".
  - Un `.gif` o un `.svg`: "Solo se permiten imágenes JPG, PNG o WEBP".
  - Uno de 6 MB: lo rechaza ASP.NET (413) o el frontend antes de enviarlo.
  - Sin archivo: "Selecciona una imagen".
- **Sin `GoldenProductImages` en `appsettings`:** "No está configurada la carpeta de imágenes de productos".
- **Otro dominio:** `GET https://<api>/files/golden-products/../appsettings.json` no devuelve nada; `PhysicalFileProvider` no sale de la carpeta.

**Producto**
- **Con imágenes mezcladas:** crear un producto con una URL subida y un enlace externo lo guarda (las dos son `https`). El catálogo y la galería muestran las dos.
- **Quitar la imagen subida al editar:** el archivo desaparece de la carpeta después de guardar. Quitar el enlace externo no borra nada.
- **Error al guardar el producto** (por ejemplo, nombre repetido): el archivo de la imagen quitada **no** se borra.

**Formulario**
- **Elegir 3 archivos con "Subir imágenes":** llenan la fila vacía y crean dos filas nuevas, con su miniatura.
- **"Subir" en una fila que ya tenía un enlace:** reemplaza esa fila.
- **Mientras sube:** "Guardar producto" está deshabilitado y se ve "Subiendo 2…".
- **Un archivo de 8 MB:** el error sale sin llamar a la API.
- **Con 10 imágenes:** "Agregar enlace" se deshabilita y "Subir imágenes" avisa del límite.

**Limpieza**
- **Una subida sin guardar:** subir una imagen y cancelar el formulario. Con `DeleteOrphansAsync(TimeSpan.Zero)`, el archivo se borra; los que usa algún producto se quedan.

---

## ✅ Checklist

- [ ] `GoldenProductImages` en `appsettings.json` y `appsettings.Development.json` (perfil `https` en desarrollo).
- [ ] Carpeta creada con permiso de escritura para el pool de IIS.
- [ ] `Program.cs`: `UseStaticFiles` con `PhysicalFileProvider`, antes de `UseAzureAdAuthentication`.
- [ ] `GoldenProductImageConstants`, `GoldenProductImageUploadDto`, `IGoldenProductImageService` y `GoldenProductImageService`; registro.
- [ ] `POST /api/GoldenProducts/images` con `try/catch` completo y límites de tamaño.
- [ ] `UpdateAsync` de productos borra las imágenes propias quitadas, **después** de guardar.
- [ ] Limpieza de huérfanas conectada (worker diario o acción de administración).
- [ ] Frontend: `uploadImage`, `uploadProductImage`, la fila con "Subir", "Subir imágenes", miniaturas y "Guardar" bloqueado mientras sube.
