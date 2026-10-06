# 🏅 Puntos Dorados — Categorías (API .NET 8 + SQL Server)

API para la pestaña **Categorías** del administrador de Puntos Dorados:

| Parte | Campos | Operaciones |
|---|---|---|
| **Categorías de reconocimientos** | nombre, descripción, icono (Font Awesome), color | listar (todas, activas o inactivas), ver una, crear, editar, inactivar, reactivar |
| **Categorías de productos** | nombre, descripción | listar (todas, activas o inactivas), ver una, crear, editar, inactivar, reactivar |
| **Biblioteca de iconos y colores** | catálogo de iconos con etiqueta, grupo y palabras de búsqueda; paleta de colores | consultar para el selector de la pantalla |

- **Solo backend.** La sección 9 explica qué necesita Angular para el selector de iconos y colores, sin construir la pantalla.
- **Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md) (patrón estándar de Request).

> **Versión corregida (6 oct 2026).** La primera versión usaba `ServiceResult<T>`, `WriteOutcome`, `TimeProvider` y controladores con `ExecuteAsync`. Para que compilara y siguiera el patrón estándar del proyecto se cambió a: servicios con `ResponseDto<T>` y toda la lógica dentro de la lambda del helper, `DateTime.UtcNow`, controladores de Request (`api/[controller]` + `try/catch`) y `DbSet` en el `DbContext`. Esta guía ya refleja ese código.
- **El JSON coincide con tu `puntos-dorados.ts`:** `GoldenRecognitionCategory` (`id, name, description, icon, color, status`) y `GoldenProductCategory` (`id, name, description, status`), con `status` = `'Activa' | 'Inactiva'`. El frontend no necesita mapper.

---

## 1. 🧭 ¿Repositorio propio? No

| Condición para un repositorio específico | ¿Se cumple? |
|---|---|
| Agregados o proyecciones en SQL | No. Son tablas pequeñas: se leen completas. |
| `GroupBy`, subconsultas, orden calculado | No. |
| Traducir errores de SQL a negocio | No. El nombre repetido se valida antes de guardar. |
| Consulta compleja compartida | No. |

**Decisión:** `ITransactionExecutorHelper` + `unitOfWork.Repository<T>()`. Sin archivos en `Contracts/Persistence` ni en `Repositories`, y nada nuevo en `InfrastructureServiceRegistration.cs`.

---

## 2. 🧐 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Borrar categorías.** Las nominaciones y los productos las referencian. | No hay borrado: solo **inactivar** y **reactivar**. |
| 2 | **Nombre repetido.** Crear "Servicio" cuando ya existe una inactiva con ese nombre duplica la categoría. | Nombre **único entre activas e inactivas**. El mensaje sugiere reactivar la existente. |
| 3 | **Icono inválido.** Un nombre mal escrito (`fa-medall`) se ve como un cuadro vacío. | Solo se aceptan iconos del **catálogo** de la API. El mismo catálogo alimenta el selector. Al editar, el icono que ya tenía se acepta aunque no esté en el catálogo, para no romper datos anteriores. |
| 4 | **Color.** `<input type="color">` devuelve `#rrggbb` en minúsculas. | Solo `#RRGGBB`, guardado en mayúsculas. La paleta son sugerencias; se acepta cualquier hex válido. |
| 5 | **Quién usa qué.** El formulario de nominación necesita las categorías activas. | Los `GET` quedan para cualquier usuario autenticado. Crear, editar, inactivar y reactivar llevan el permiso de administración. |
| 6 | **Inactivar no cambia el pasado.** | Las nominaciones y productos existentes conservan su categoría. Los formularios nuevos piden `?status=Activa`, y el backend de nominaciones o productos debe rechazar una categoría inactiva. |
| 7 | **Productos con la categoría por nombre.** `GoldenProduct.category` es un `string`. | Cuando se construya la tabla de productos, que use `category_id` con llave a `golden_product_category`, no el nombre. Si no, renombrar una categoría desconecta sus productos. |
| 8 | **Reactivar desde la pantalla.** Hoy la tarjeta inactiva solo muestra "Editar". | El endpoint `activate` existe; falta el botón en la pantalla. |
| 9 | **Nombre de la feature.** Si la carpeta se llamara igual que una entidad, harían falta alias como en `EmailAlertLog`. | Feature `GoldenPoints`; entidades `GoldenRecognitionCategory` y `GoldenProductCategory`. Sin alias. |

---

## 3. 📁 Archivos

```text
DOCCB.Domain/Entities/
├── GoldenRecognitionCategory.cs
└── GoldenProductCategory.cs

DOCCB.Application/Features/GoldenPoints/Application/
├── Constants/
│   ├── GoldenCategoryStatus.cs            "Activa" / "Inactiva" y el filtro
│   ├── GoldenCategoryConstants.cs         límites y mensajes
│   └── GoldenAppearanceCatalog.cs         ⭐ biblioteca de iconos y paleta de colores
├── Dtos/GoldenCategoryDtos.cs
├── Helpers/
│   ├── GoldenCategoryValidator.cs         limpia y valida nombre, descripción, icono y color
│   └── GoldenCategoryMapper.cs            entidad → DTO
├── Interfaces/
│   ├── IGoldenRecognitionCategoryService.cs
│   └── IGoldenProductCategoryService.cs
└── Services/
    ├── GoldenRecognitionCategoryService.cs
    └── GoldenProductCategoryService.cs

DOCCB.Infraestructure/
├── Configurations/
│   ├── GoldenRecognitionCategoryConfiguration.cs
│   └── GoldenProductCategoryConfiguration.cs
└── Persistence/
    ├── Models/DOCCbDbContext.cs                ✏️ + 2 DbSet
    └── Scripts SQL/GoldenPointsCategories.sql

WebApp/
├── Common/ApiResponseConstants.cs               ✏️ + 3 mensajes
└── Controllers/
    ├── GoldenRecognitionCategoriesController.cs
    └── GoldenProductCategoriesController.cs
```

> La carpeta de DTOs de esta feature se llama `Dtos`, como en `EmailAlertLog`. Si prefieres `DTOs` como en `Common`, cambia carpeta y namespace juntos.
>
> **Namespaces en bloque.** En el proyecto se escribe `namespace X { … }`. Los bloques de las secciones 5 y 6 que usan `namespace X;` se copian igual, envolviendo la clase en llaves.

---

## 4. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/GoldenPointsCategories.sql`

```sql
/* =====================================================================
   Puntos Dorados — categorías de reconocimientos y de productos
   Base de datos: DB · Esquema: dbo
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_recognition_category
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_recognition_category', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_recognition_category
    (
        id           INT            IDENTITY(1, 1) NOT NULL,
        name         NVARCHAR(100)  NOT NULL,
        description  NVARCHAR(300)  NULL,
        icon         VARCHAR(60)    NOT NULL,          -- clases de Font Awesome: "fa-solid fa-medal"
        color        CHAR(7)        NOT NULL,          -- "#RRGGBB"
        active       BIT            NOT NULL CONSTRAINT df_golden_recognition_category_active DEFAULT (1),
        created_date DATETIME2(0)   NOT NULL CONSTRAINT df_golden_recognition_category_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)  NOT NULL,
        updated_date DATETIME2(0)   NULL,
        updated_by   NVARCHAR(150)  NULL,

        CONSTRAINT pk_golden_recognition_category PRIMARY KEY CLUSTERED (id),
        CONSTRAINT ck_golden_recognition_category_name CHECK (LEN(LTRIM(name)) > 0),
        CONSTRAINT ck_golden_recognition_category_icon CHECK (icon LIKE 'fa-% fa-%'),
        CONSTRAINT ck_golden_recognition_category_color
            CHECK (color LIKE '#[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]')
    );

    -- Único entre activas e inactivas: una inactiva se reactiva, no se duplica.
    CREATE UNIQUE INDEX ux_golden_recognition_category_name
        ON dbo.golden_recognition_category (name);
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_product_category
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_product_category', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_product_category
    (
        id           INT            IDENTITY(1, 1) NOT NULL,
        name         NVARCHAR(100)  NOT NULL,
        description  NVARCHAR(300)  NULL,
        active       BIT            NOT NULL CONSTRAINT df_golden_product_category_active DEFAULT (1),
        created_date DATETIME2(0)   NOT NULL CONSTRAINT df_golden_product_category_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)  NOT NULL,
        updated_date DATETIME2(0)   NULL,
        updated_by   NVARCHAR(150)  NULL,

        CONSTRAINT pk_golden_product_category PRIMARY KEY CLUSTERED (id),
        CONSTRAINT ck_golden_product_category_name CHECK (LEN(LTRIM(name)) > 0)
    );

    CREATE UNIQUE INDEX ux_golden_product_category_name
        ON dbo.golden_product_category (name);
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   Datos iniciales (opcional): los de las pantallas actuales.
   Los iconos usan los nombres de Font Awesome 6 (fa-hands-helping → fa-handshake-angle,
   fa-check-circle → fa-circle-check).
   ───────────────────────────────────────────────────────────────────── */
IF NOT EXISTS (SELECT 1 FROM dbo.golden_recognition_category)
BEGIN
    INSERT INTO dbo.golden_recognition_category (name, description, icon, color, created_by) VALUES
    (N'Servicio',              N'Actos de servicio que impactan positivamente al equipo o usuario.', 'fa-solid fa-handshake-angle', '#2563EB', N'sistema'),
    (N'Cumplimiento',          N'Logros sobresalientes en objetivos y compromisos.',                 'fa-solid fa-circle-check',    '#16A34A', N'sistema'),
    (N'Reconocimiento',        N'Aportes continuos de valor en el día a día.',                       'fa-solid fa-medal',           '#EA580C', N'sistema'),
    (N'La Sacaste del Estadio', N'Resultados extraordinarios en escenarios de alto impacto.',        'fa-solid fa-trophy',          '#DC2626', N'sistema');
END;

IF NOT EXISTS (SELECT 1 FROM dbo.golden_product_category)
BEGIN
    INSERT INTO dbo.golden_product_category (name, description, active, created_by) VALUES
    (N'Bienestar',    N'Productos orientados al bienestar físico y mental.', 1, N'sistema'),
    (N'Experiencias', N'Planes, actividades y vivencias para redención.',    1, N'sistema'),
    (N'Beneficios',   N'Beneficios corporativos y tiempo compensatorio.',   1, N'sistema'),
    (N'Tecnología',   N'Accesorios y recursos tecnológicos.',               0, N'sistema');
END;
GO
```

> Con la intercalación por defecto de SQL Server (sin distinguir mayúsculas), `Servicio` y `servicio` cuentan como el mismo nombre, tanto en el índice como en la validación del servicio.

---

## 5. Paso 2 — Dominio y configuración EF

### `Entities/GoldenRecognitionCategory.cs`

```csharp
namespace DOCCB.Domain.Entities;

/// <remarks>No hereda BaseEntity: declara sus columnas de auditoría con sus tipos exactos.</remarks>
public class GoldenRecognitionCategory
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string Icon { get; set; } = string.Empty;
    public string Color { get; set; } = string.Empty;
    public bool Active { get; set; } = true;

    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? UpdatedDate { get; set; }
    public string? UpdatedBy { get; set; }
}
```

### `Entities/GoldenProductCategory.cs`

```csharp
namespace DOCCB.Domain.Entities;

public class GoldenProductCategory
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool Active { get; set; } = true;

    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? UpdatedDate { get; set; }
    public string? UpdatedBy { get; set; }
}
```

> Las dos tablas tienen `created_date` y `updated_date`. Si tu `BaseEntity` tiene exactamente `CreatedDate` (no nula) y `UpdatedDate` (nula), puedes heredarla y quitar esas dos propiedades. Si no estás seguro, déjalas así.

### `Configurations/GoldenRecognitionCategoryConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class GoldenRecognitionCategoryConfiguration : IEntityTypeConfiguration<GoldenRecognitionCategory>
{
    public void Configure(EntityTypeBuilder<GoldenRecognitionCategory> builder)
    {
        builder.ToTable("golden_recognition_category", "dbo");

        builder.HasKey(c => c.Id).HasName("pk_golden_recognition_category");

        builder.Property(c => c.Id).HasColumnName("id");
        builder.Property(c => c.Name).HasColumnName("name").HasMaxLength(100).IsRequired();
        builder.Property(c => c.Description).HasColumnName("description").HasMaxLength(300);
        builder.Property(c => c.Icon).HasColumnName("icon").HasMaxLength(60).IsUnicode(false).IsRequired();
        builder.Property(c => c.Color).HasColumnName("color").HasMaxLength(7).IsFixedLength().IsUnicode(false).IsRequired();
        builder.Property(c => c.Active).HasColumnName("active");
        builder.Property(c => c.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(c => c.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
        builder.Property(c => c.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
        builder.Property(c => c.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

        builder.HasIndex(c => c.Name).IsUnique().HasDatabaseName("ux_golden_recognition_category_name");
    }
}
```

### `Configurations/GoldenProductCategoryConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class GoldenProductCategoryConfiguration : IEntityTypeConfiguration<GoldenProductCategory>
{
    public void Configure(EntityTypeBuilder<GoldenProductCategory> builder)
    {
        builder.ToTable("golden_product_category", "dbo");

        builder.HasKey(c => c.Id).HasName("pk_golden_product_category");

        builder.Property(c => c.Id).HasColumnName("id");
        builder.Property(c => c.Name).HasColumnName("name").HasMaxLength(100).IsRequired();
        builder.Property(c => c.Description).HasColumnName("description").HasMaxLength(300);
        builder.Property(c => c.Active).HasColumnName("active");
        builder.Property(c => c.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(c => c.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
        builder.Property(c => c.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
        builder.Property(c => c.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

        builder.HasIndex(c => c.Name).IsUnique().HasDatabaseName("ux_golden_product_category_name");
    }
}
```

Las dos se cargan solas con `ApplyConfigurationsFromAssembly`.

### `Persistence/Models/DOCCbDbContext.cs` ✏️

Convención del proyecto: **cada entidad tiene su `DbSet`**, junto a los demás.

```csharp
public DbSet<GoldenRecognitionCategory> GoldenRecognitionCategories { get; set; }
public DbSet<GoldenProductCategory> GoldenProductCategories { get; set; }
```

---

## 6. Paso 3 — Constantes, catálogo y DTOs

### `Constants/GoldenCategoryStatus.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    /// <summary>Código textual de estado usado por el frontend: "Activa" / "Inactiva".</summary>
    public static class GoldenCategoryStatus
    {
        private const string ActiveCode = "Activa";
        private const string InactiveCode = "Inactiva";

        /// <summary>
        /// Interpreta el filtro de estado recibido por query string.
        /// null o vacío => sin filtro (active = null). "Activa"/"Inactiva" (sin distinguir mayúsculas).
        /// Cualquier otro valor => inválido (devuelve false).
        /// </summary>
        public static bool TryParseFilter(string? status, out bool? active)
        {
            if (string.IsNullOrWhiteSpace(status))
            {
                active = null;
                return true;
            }

            if (string.Equals(status, ActiveCode, StringComparison.OrdinalIgnoreCase))
            {
                active = true;
                return true;
            }

            if (string.Equals(status, InactiveCode, StringComparison.OrdinalIgnoreCase))
            {
                active = false;
                return true;
            }

            active = null;
            return false;
        }

        public static string ToCode(bool active) => active ? ActiveCode : InactiveCode;
    }
}
```

> Al crear la clase desde Visual Studio, la plantilla genera `internal class` con `using System; using System.Linq; …`. Cámbiala a `public static class` y quita esos `using`: el proyecto tiene los `using` implícitos activos.

### `Constants/GoldenCategoryConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants;

public static class GoldenCategoryConstants
{
    public const int NameMaxLength = 100;
    public const int DescriptionMaxLength = 300;

    public const string NameRequired = "El nombre es obligatorio.";
    public static readonly string NameTooLong = $"El nombre admite hasta {NameMaxLength} caracteres.";
    public static readonly string DescriptionTooLong = $"La descripción admite hasta {DescriptionMaxLength} caracteres.";
    public const string IconRequired = "Elige un icono.";
    public const string IconInvalid = "El icono debe tener el formato de Font Awesome, por ejemplo \"fa-solid fa-medal\".";
    public const string IconNotInCatalog = "Ese icono no está en la biblioteca. Elige uno de la lista.";
    public const string ColorInvalid = "El color debe tener el formato #RRGGBB, por ejemplo #2563EB.";
    public const string InvalidStatusFilter = "El estado debe ser \"Activa\" o \"Inactiva\".";
    public const string UnexpectedError = "No se pudo completar la operación. Intenta de nuevo.";

    public const string RecognitionCategoryNotFound = "La categoría de reconocimiento no existe.";
    public const string RecognitionCategoryNameTaken =
        "Ya existe una categoría de reconocimiento con ese nombre. Si está inactiva, actívala en lugar de crear otra.";

    public const string ProductCategoryNotFound = "La categoría de producto no existe.";
    public const string ProductCategoryNameTaken =
        "Ya existe una categoría de producto con ese nombre. Si está inactiva, actívala en lugar de crear otra.";
}
```

### `Constants/GoldenAppearanceCatalog.cs` ⭐ — la biblioteca de iconos y colores

Font Awesome Free tiene más de 2.000 iconos: mostrarlos todos hace el selector inutilizable. Aquí va una selección pensada para reconocimientos, con etiqueta y palabras de búsqueda en español. Es **la única fuente**: la pantalla la pide a la API y el servicio valida contra ella.

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants;

/// <summary>Icono disponible para las categorías de reconocimiento.</summary>
/// <param name="CssClass">Clases de Font Awesome 6 tal como van en el HTML.</param>
public sealed record GoldenIconOption(string CssClass, string Label, string Group, string[] Keywords);

/// <summary>Color sugerido. Se acepta cualquier #RRGGBB; estos son los recomendados.</summary>
public sealed record GoldenColorOption(string Hex, string Label);

public static class GoldenAppearanceCatalog
{
    /// <summary>Todos son "fa-solid" de Font Awesome Free 6. Para agregar uno, agrega una línea.</summary>
    public static readonly IReadOnlyList<GoldenIconOption> Icons =
    [
        // Reconocimiento
        new("fa-solid fa-medal",          "Medalla",        "Reconocimiento", ["premio", "logro"]),
        new("fa-solid fa-trophy",         "Trofeo",         "Reconocimiento", ["ganador", "copa", "premio"]),
        new("fa-solid fa-award",          "Distinción",     "Reconocimiento", ["premio", "insignia"]),
        new("fa-solid fa-star",           "Estrella",       "Reconocimiento", ["destacado", "favorito"]),
        new("fa-solid fa-crown",          "Corona",         "Reconocimiento", ["líder", "mejor"]),
        new("fa-solid fa-ribbon",         "Cinta",          "Reconocimiento", ["mención"]),
        new("fa-solid fa-certificate",    "Certificado",    "Reconocimiento", ["sello", "calidad"]),
        new("fa-solid fa-gem",            "Gema",           "Reconocimiento", ["valioso", "diamante"]),
        new("fa-solid fa-hands-clapping", "Aplausos",       "Reconocimiento", ["felicitación", "bravo"]),
        new("fa-solid fa-thumbs-up",      "Pulgar arriba",  "Reconocimiento", ["bien", "aprobado"]),

        // Equipo y servicio
        new("fa-solid fa-handshake-angle",   "Mano amiga",    "Equipo y servicio", ["ayuda", "servicio", "apoyo"]),
        new("fa-solid fa-handshake",         "Acuerdo",       "Equipo y servicio", ["alianza", "trato"]),
        new("fa-solid fa-hand-holding-heart", "Cuidado",      "Equipo y servicio", ["empatía", "servicio"]),
        new("fa-solid fa-people-group",      "Equipo",        "Equipo y servicio", ["grupo", "colaboración"]),
        new("fa-solid fa-user-group",        "Compañeros",    "Equipo y servicio", ["pares", "colegas"]),
        new("fa-solid fa-heart",             "Corazón",       "Equipo y servicio", ["pasión", "amor"]),
        new("fa-solid fa-face-smile",        "Sonrisa",       "Equipo y servicio", ["actitud", "alegría"]),
        new("fa-solid fa-headset",           "Atención",      "Equipo y servicio", ["cliente", "soporte"]),
        new("fa-solid fa-comments",          "Comunicación",  "Equipo y servicio", ["diálogo", "conversación"]),

        // Logros y resultados
        new("fa-solid fa-circle-check",     "Cumplido",       "Logros y resultados", ["cumplimiento", "hecho", "check"]),
        new("fa-solid fa-bullseye",         "Objetivo",       "Logros y resultados", ["meta", "precisión"]),
        new("fa-solid fa-flag-checkered",   "Meta",           "Logros y resultados", ["llegada", "fin"]),
        new("fa-solid fa-chart-line",       "Crecimiento",    "Logros y resultados", ["resultados", "indicador"]),
        new("fa-solid fa-rocket",           "Impulso",        "Logros y resultados", ["despegue", "rápido"]),
        new("fa-solid fa-mountain",         "Reto superado",  "Logros y resultados", ["esfuerzo", "cima"]),
        new("fa-solid fa-bolt",             "Energía",        "Logros y resultados", ["rapidez", "rayo"]),
        new("fa-solid fa-fire",             "En racha",       "Logros y resultados", ["intensidad"]),

        // Innovación y aprendizaje
        new("fa-solid fa-lightbulb",           "Idea",          "Innovación y aprendizaje", ["innovación", "creatividad"]),
        new("fa-solid fa-wand-magic-sparkles", "Mejora",        "Innovación y aprendizaje", ["magia", "transformación"]),
        new("fa-solid fa-puzzle-piece",        "Solución",      "Innovación y aprendizaje", ["problema", "pieza"]),
        new("fa-solid fa-brain",               "Conocimiento",  "Innovación y aprendizaje", ["inteligencia", "mente"]),
        new("fa-solid fa-gears",               "Procesos",      "Innovación y aprendizaje", ["engranajes", "eficiencia"]),
        new("fa-solid fa-graduation-cap",      "Formación",     "Innovación y aprendizaje", ["curso", "estudio"]),
        new("fa-solid fa-seedling",            "Crecimiento personal", "Innovación y aprendizaje", ["desarrollo", "semilla"]),

        // Operación y seguridad
        new("fa-solid fa-plane-departure",  "Despegue",      "Operación y seguridad", ["avión", "vuelo", "aeropuerto"]),
        new("fa-solid fa-plane",            "Avión",         "Operación y seguridad", ["vuelo", "aeropuerto"]),
        new("fa-solid fa-suitcase-rolling", "Pasajero",      "Operación y seguridad", ["maleta", "viajero"]),
        new("fa-solid fa-shield-halved",    "Seguridad",     "Operación y seguridad", ["protección", "escudo"]),
        new("fa-solid fa-helmet-safety",    "Seguridad industrial", "Operación y seguridad", ["casco", "obra"]),
        new("fa-solid fa-clock",            "Puntualidad",   "Operación y seguridad", ["tiempo", "hora"]),
        new("fa-solid fa-leaf",             "Sostenibilidad", "Operación y seguridad", ["ambiente", "verde"]),
        new("fa-solid fa-compass",          "Orientación",   "Operación y seguridad", ["rumbo", "guía"]),
    ];

    /// <summary>Visibles sobre fondo blanco (barras e iconos de las tarjetas).</summary>
    public static readonly IReadOnlyList<GoldenColorOption> Colors =
    [
        new("#2563EB", "Azul"),
        new("#4F46E5", "Índigo"),
        new("#7C3AED", "Morado"),
        new("#DB2777", "Rosa"),
        new("#DC2626", "Rojo"),
        new("#EA580C", "Naranja"),
        new("#C99A06", "Dorado"),
        new("#16A34A", "Verde"),
        new("#0D9488", "Turquesa"),
        new("#475569", "Gris pizarra"),
    ];

    private static readonly HashSet<string> IconClasses =
        Icons.Select(icon => icon.CssClass).ToHashSet(StringComparer.Ordinal);

    public static bool IsKnownIcon(string cssClass) => IconClasses.Contains(cssClass);
}
```

> Revisa que cada icono exista en **tu versión** de Font Awesome (sección 9). Los de esta lista existen en Font Awesome Free 6.1 o superior.

### `Dtos/GoldenCategoryDtos.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;

namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos;

/// <summary>Igual a GoldenRecognitionCategory del frontend.</summary>
public class GoldenRecognitionCategoryDto
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Icon { get; set; } = string.Empty;
    public string Color { get; set; } = string.Empty;
    /// <summary>"Activa" | "Inactiva"</summary>
    public string Status { get; set; } = string.Empty;
}

/// <summary>Crear y editar. El estado no se cambia aquí: hay endpoints para inactivar y reactivar.</summary>
public class SaveGoldenRecognitionCategoryDto
{
    public string? Name { get; set; }
    public string? Description { get; set; }
    public string? Icon { get; set; }
    public string? Color { get; set; }
}

/// <summary>Igual a GoldenProductCategory del frontend.</summary>
public class GoldenProductCategoryDto
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
}

public class SaveGoldenProductCategoryDto
{
    public string? Name { get; set; }
    public string? Description { get; set; }
}

/// <summary>Lo que necesita el selector de la pantalla.</summary>
public class GoldenAppearanceOptionsDto
{
    public IReadOnlyList<GoldenIconOption> Icons { get; set; } = [];
    public IReadOnlyList<GoldenColorOption> Colors { get; set; } = [];
}
```

---

## 7. Paso 4 — Helpers y servicios

### `Helpers/GoldenCategoryValidator.cs`

```csharp
using System.Text.RegularExpressions;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers;

public static partial class GoldenCategoryValidator
{
    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();

    [GeneratedRegex("^fa-(solid|regular|brands) fa-[a-z0-9-]+$")]
    private static partial Regex FontAwesomeClass();

    [GeneratedRegex("^#[0-9A-Fa-f]{6}$")]
    private static partial Regex HexColor();

    /// <summary>Sin espacios al inicio ni al final y sin espacios dobles en medio.</summary>
    public static string? Name(string? value, List<string> errors)
    {
        var name = Spaces().Replace(value?.Trim() ?? string.Empty, " ");

        if (name.Length == 0) { errors.Add(GoldenCategoryConstants.NameRequired); return null; }
        if (name.Length > GoldenCategoryConstants.NameMaxLength) { errors.Add(GoldenCategoryConstants.NameTooLong); return null; }

        return name;
    }

    /// <summary>Opcional: vacío se guarda como NULL.</summary>
    public static string? Description(string? value, List<string> errors)
    {
        var description = value?.Trim();
        if (string.IsNullOrEmpty(description)) return null;

        if (description.Length > GoldenCategoryConstants.DescriptionMaxLength)
            errors.Add(GoldenCategoryConstants.DescriptionTooLong);

        return description;
    }

    /// <summary>Solo el formato. Si está en el catálogo lo decide el servicio (al editar se acepta el icono anterior).</summary>
    public static string? Icon(string? value, List<string> errors)
    {
        var icon = Spaces().Replace(value?.Trim() ?? string.Empty, " ");

        if (icon.Length == 0) { errors.Add(GoldenCategoryConstants.IconRequired); return null; }
        if (!FontAwesomeClass().IsMatch(icon)) { errors.Add(GoldenCategoryConstants.IconInvalid); return null; }

        return icon;
    }

    /// <summary>#RRGGBB en mayúsculas.</summary>
    public static string? Color(string? value, List<string> errors)
    {
        var color = value?.Trim() ?? string.Empty;

        if (!HexColor().IsMatch(color)) { errors.Add(GoldenCategoryConstants.ColorInvalid); return null; }

        return color.ToUpperInvariant();
    }
}
```

### `Helpers/GoldenCategoryMapper.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers;

public static class GoldenCategoryMapper
{
    public static GoldenRecognitionCategoryDto ToRecognitionDto(GoldenRecognitionCategory category) => new()
    {
        Id = category.Id,
        Name = category.Name,
        Description = category.Description ?? string.Empty,
        Icon = category.Icon,
        Color = category.Color,
        Status = GoldenCategoryStatus.ToCode(category.Active),
    };

    public static GoldenProductCategoryDto ToProductDto(GoldenProductCategory category) => new()
    {
        Id = category.Id,
        Name = category.Name,
        Description = category.Description ?? string.Empty,
        Status = GoldenCategoryStatus.ToCode(category.Active),
    };
}
```

### `Interfaces/IGoldenRecognitionCategoryService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;     // ResponseDto<T>
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenRecognitionCategoryService
    {
        /// <param name="status">"Activa", "Inactiva" o vacío para todas.</param>
        Task<ResponseDto<List<GoldenRecognitionCategoryDto>>> GetAllAsync(string? status);
        Task<ResponseDto<GoldenRecognitionCategoryDto>> GetByIdAsync(int id);
        Task<ResponseDto<GoldenRecognitionCategoryDto>> CreateAsync(SaveGoldenRecognitionCategoryDto dto, string currentUser);
        Task<ResponseDto<GoldenRecognitionCategoryDto>> UpdateAsync(int id, SaveGoldenRecognitionCategoryDto dto, string currentUser);
        Task<ResponseDto<GoldenRecognitionCategoryDto>> SetActiveAsync(int id, bool active, string currentUser);
        ResponseDto<GoldenAppearanceOptionsDto> GetAppearanceOptions();
    }
}
```

### `Services/GoldenRecognitionCategoryService.cs`

El patrón estándar: **toda** la lógica con datos va dentro de la lambda del helper, que devuelve el `ResponseDto`. El `?? CreateErrorResponseDto(...)` cubre el caso en que el helper devuelva `null`.

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenRecognitionCategoryService(ITransactionExecutorHelper transactionHelper) : IGoldenRecognitionCategoryService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        public async Task<ResponseDto<List<GoldenRecognitionCategoryDto>>> GetAllAsync(string? status)
        {
            if (!GoldenCategoryStatus.TryParseFilter(status, out var active))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<List<GoldenRecognitionCategoryDto>>(GoldenCategoryConstants.InvalidStatusFilter);
            }

            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<List<GoldenRecognitionCategoryDto>>>(
                async unitOfWork =>
                {
                    var categories = await unitOfWork.Repository<GoldenRecognitionCategory>()
                        .GetListAsync(c => active == null || c.Active == active);

                    // Tabla pequeña: se ordena en memoria. Activas primero, luego por nombre.
                    var result = categories
                        .OrderByDescending(c => c.Active)
                        .ThenBy(c => c.Name)
                        .Select(GoldenCategoryMapper.ToRecognitionDto)
                        .ToList();

                    return ResponseDtoHelper.CreateSuccessResponseDto(result);
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<List<GoldenRecognitionCategoryDto>>(GoldenCategoryConstants.UnexpectedError);
        }

        public async Task<ResponseDto<GoldenRecognitionCategoryDto>> GetByIdAsync(int id)
        {
            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenRecognitionCategoryDto>>(
                async unitOfWork =>
                {
                    var category = await unitOfWork.Repository<GoldenRecognitionCategory>().GetByIdAsync(id);

                    return category is null
                        ? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.RecognitionCategoryNotFound)
                        : ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToRecognitionDto(category));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.UnexpectedError);
        }

        public async Task<ResponseDto<GoldenRecognitionCategoryDto>> CreateAsync(SaveGoldenRecognitionCategoryDto dto, string currentUser)
        {
            var errors = new List<string>();
            var name = GoldenCategoryValidator.Name(dto.Name, errors);
            var description = GoldenCategoryValidator.Description(dto.Description, errors);
            var icon = GoldenCategoryValidator.Icon(dto.Icon, errors);
            var color = GoldenCategoryValidator.Color(dto.Color, errors);

            if (icon is not null && !GoldenAppearanceCatalog.IsKnownIcon(icon))
            {
                errors.Add(GoldenCategoryConstants.IconNotInCatalog);
            }

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(errors);
            }

            GoldenRecognitionCategory? created = null;

            var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionCategoryDto>>(
                async unitOfWork =>
                {
                    var repository = unitOfWork.Repository<GoldenRecognitionCategory>();

                    if (await repository.AnyAsync(c => c.Name == name))
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.RecognitionCategoryNameTaken);
                    }

                    created = new GoldenRecognitionCategory
                    {
                        Name = name!,
                        Description = description,
                        Icon = icon!,
                        Color = color!,
                        Active = true,
                        CreatedDate = DateTime.UtcNow,
                        CreatedBy = currentUser,
                    };

                    await repository.AddAsync(created);
                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToRecognitionDto(created));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.UnexpectedError);

            // ⚠️ El helper guarda DESPUÉS de la lambda: dentro de ella el Id todavía es 0.
            // Se vuelve a mapear aquí para que la respuesta lleve el Id real.
            return created is not null && !response.HasError
                ? ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToRecognitionDto(created))
                : response;
        }

        public async Task<ResponseDto<GoldenRecognitionCategoryDto>> UpdateAsync(int id, SaveGoldenRecognitionCategoryDto dto, string currentUser)
        {
            var errors = new List<string>();
            var name = GoldenCategoryValidator.Name(dto.Name, errors);
            var description = GoldenCategoryValidator.Description(dto.Description, errors);
            var icon = GoldenCategoryValidator.Icon(dto.Icon, errors);
            var color = GoldenCategoryValidator.Color(dto.Color, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(errors);
            }

            return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionCategoryDto>>(
                async unitOfWork =>
                {
                    var repository = unitOfWork.Repository<GoldenRecognitionCategory>();

                    // GetByIdAsync trae la entidad CON seguimiento: se guarda solo lo que cambie.
                    var category = await repository.GetByIdAsync(id);
                    if (category is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.RecognitionCategoryNotFound);
                    }

                    // El icono que ya tenía se respeta aunque no esté en el catálogo (datos anteriores).
                    if (icon != category.Icon && !GoldenAppearanceCatalog.IsKnownIcon(icon!))
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.IconNotInCatalog);
                    }

                    if (await repository.AnyAsync(c => c.Name == name && c.Id != id))
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.RecognitionCategoryNameTaken);
                    }

                    category.Name = name!;
                    category.Description = description;
                    category.Icon = icon!;
                    category.Color = color!;
                    category.UpdatedDate = DateTime.UtcNow;
                    category.UpdatedBy = currentUser;

                    // Aquí el Id ya existe (la entidad se leyó), así que mapear dentro de la lambda es correcto.
                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToRecognitionDto(category));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.UnexpectedError);
        }

        public async Task<ResponseDto<GoldenRecognitionCategoryDto>> SetActiveAsync(int id, bool active, string currentUser)
        {
            return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionCategoryDto>>(
                async unitOfWork =>
                {
                    var category = await unitOfWork.Repository<GoldenRecognitionCategory>().GetByIdAsync(id);
                    if (category is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.RecognitionCategoryNotFound);
                    }

                    if (category.Active != active) // si ya estaba así, no hay nada que guardar
                    {
                        category.Active = active;
                        category.UpdatedDate = DateTime.UtcNow;
                        category.UpdatedBy = currentUser;
                    }

                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToRecognitionDto(category));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionCategoryDto>(GoldenCategoryConstants.UnexpectedError);
        }

        public ResponseDto<GoldenAppearanceOptionsDto> GetAppearanceOptions() =>
            ResponseDtoHelper.CreateSuccessResponseDto(new GoldenAppearanceOptionsDto
            {
                Icons = GoldenAppearanceCatalog.Icons,
                Colors = GoldenAppearanceCatalog.Colors,
            });
    }
}
```

> **El Id al crear.** Si se devuelve el DTO armado dentro de la lambda, la respuesta de `POST` trae `id: 0`: el `INSERT` ocurre en el `CompleteAsync` del helper, después de la lambda. Por eso `CreateAsync` guarda la entidad en `created` y vuelve a mapear al final. En `UpdateAsync` y `SetActiveAsync` no hace falta porque la entidad ya existía.
>
> `ResponseDtoHelper.CreateErrorResponseDto<T>(errors)` recibe la lista de errores de validación; con un solo mensaje se usa la sobrecarga de `string`.

### `Interfaces/IGoldenProductCategoryService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenProductCategoryService
    {
        /// <param name="status">"Activa", "Inactiva" o vacío para todas.</param>
        Task<ResponseDto<List<GoldenProductCategoryDto>>> GetAllAsync(string? status);
        Task<ResponseDto<GoldenProductCategoryDto>> GetByIdAsync(int id);
        Task<ResponseDto<GoldenProductCategoryDto>> CreateAsync(SaveGoldenProductCategoryDto dto, string currentUser);
        Task<ResponseDto<GoldenProductCategoryDto>> UpdateAsync(int id, SaveGoldenProductCategoryDto dto, string currentUser);
        Task<ResponseDto<GoldenProductCategoryDto>> SetActiveAsync(int id, bool active, string currentUser);
    }
}
```

### `Services/GoldenProductCategoryService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenProductCategoryService(ITransactionExecutorHelper transactionHelper) : IGoldenProductCategoryService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        public async Task<ResponseDto<List<GoldenProductCategoryDto>>> GetAllAsync(string? status)
        {
            if (!GoldenCategoryStatus.TryParseFilter(status, out var active))
            {
                return ResponseDtoHelper.CreateErrorResponseDto<List<GoldenProductCategoryDto>>(GoldenCategoryConstants.InvalidStatusFilter);
            }

            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<List<GoldenProductCategoryDto>>>(
                async unitOfWork =>
                {
                    var categories = await unitOfWork.Repository<GoldenProductCategory>()
                        .GetListAsync(c => active == null || c.Active == active);

                    var result = categories
                        .OrderByDescending(c => c.Active)
                        .ThenBy(c => c.Name)
                        .Select(GoldenCategoryMapper.ToProductDto)
                        .ToList();

                    return ResponseDtoHelper.CreateSuccessResponseDto(result);
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<List<GoldenProductCategoryDto>>(GoldenCategoryConstants.UnexpectedError);
        }

        public async Task<ResponseDto<GoldenProductCategoryDto>> GetByIdAsync(int id)
        {
            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenProductCategoryDto>>(
                async unitOfWork =>
                {
                    var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(id);

                    return category is null
                        ? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.ProductCategoryNotFound)
                        : ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToProductDto(category));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.UnexpectedError);
        }

        public async Task<ResponseDto<GoldenProductCategoryDto>> CreateAsync(SaveGoldenProductCategoryDto dto, string currentUser)
        {
            var errors = new List<string>();
            var name = GoldenCategoryValidator.Name(dto.Name, errors);
            var description = GoldenCategoryValidator.Description(dto.Description, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(errors);
            }

            GoldenProductCategory? created = null;

            var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductCategoryDto>>(
                async unitOfWork =>
                {
                    var repository = unitOfWork.Repository<GoldenProductCategory>();

                    if (await repository.AnyAsync(c => c.Name == name))
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.ProductCategoryNameTaken);
                    }

                    created = new GoldenProductCategory
                    {
                        Name = name!,
                        Description = description,
                        Active = true,
                        CreatedDate = DateTime.UtcNow,
                        CreatedBy = currentUser,
                    };

                    await repository.AddAsync(created);
                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToProductDto(created));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.UnexpectedError);

            // El Id real solo existe después de que el helper guarda.
            return created is not null && !response.HasError
                ? ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToProductDto(created))
                : response;
        }

        public async Task<ResponseDto<GoldenProductCategoryDto>> UpdateAsync(int id, SaveGoldenProductCategoryDto dto, string currentUser)
        {
            var errors = new List<string>();
            var name = GoldenCategoryValidator.Name(dto.Name, errors);
            var description = GoldenCategoryValidator.Description(dto.Description, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(errors);
            }

            return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductCategoryDto>>(
                async unitOfWork =>
                {
                    var repository = unitOfWork.Repository<GoldenProductCategory>();

                    var category = await repository.GetByIdAsync(id);
                    if (category is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.ProductCategoryNotFound);
                    }

                    if (await repository.AnyAsync(c => c.Name == name && c.Id != id))
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.ProductCategoryNameTaken);
                    }

                    category.Name = name!;
                    category.Description = description;
                    category.UpdatedDate = DateTime.UtcNow;
                    category.UpdatedBy = currentUser;

                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToProductDto(category));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.UnexpectedError);
        }

        public async Task<ResponseDto<GoldenProductCategoryDto>> SetActiveAsync(int id, bool active, string currentUser)
        {
            return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductCategoryDto>>(
                async unitOfWork =>
                {
                    var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(id);
                    if (category is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.ProductCategoryNotFound);
                    }

                    if (category.Active != active)
                    {
                        category.Active = active;
                        category.UpdatedDate = DateTime.UtcNow;
                        category.UpdatedBy = currentUser;
                    }

                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenCategoryMapper.ToProductDto(category));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductCategoryDto>(GoldenCategoryConstants.UnexpectedError);
        }
    }
}
```

> **Nombre repetido al mismo tiempo.** Si dos administradores crean el mismo nombre en el mismo segundo, el índice único rechaza el segundo y el helper lanza `InvalidOperationException`: el controlador responde 500. Es muy poco probable en una pantalla de configuración.

---

## 8. Paso 5 — Controladores (patrón estándar de Request)

### `Common/ApiResponseConstants.cs` ✏️

`NotAuthenticatedUserMessage` y `UnauthorizedUserMessage` ya existen. Se agregan:

```csharp
public const string GoldenRecognitionCategoriesErrorMessage = "No se pudo completar la operación con las categorías de reconocimiento.";
public const string GoldenProductCategoriesErrorMessage = "No se pudo completar la operación con las categorías de producto.";
```

### `Controllers/GoldenRecognitionCategoriesController.cs`

Cada acción: lee el usuario del token, responde 401 si no hay correo, llama al servicio y devuelve `Ok(response)`. Los errores de negocio viajan en el `ResponseDto` con **HTTP 200** y `hasError: true`, como en Request.

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: categorías de reconocimiento y biblioteca de iconos y colores.</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class GoldenRecognitionCategoriesController(IGoldenRecognitionCategoryService service) : ControllerBase
    {
        private readonly IGoldenRecognitionCategoryService _service = service;

        /// <summary>GET ?status=Activa | Inactiva | (vacío = todas)</summary>
        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetAll([FromQuery] string? status)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetAllAsync(status);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage });
            }
        }

        /// <summary>Iconos y colores para el selector de la pantalla.</summary>
        [HttpGet("appearance-options")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public IActionResult GetAppearanceOptions()
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                return Ok(_service.GetAppearanceOptions());
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage });
            }
        }

        [HttpGet("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetById(int id)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetByIdAsync(id);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage });
            }
        }

        // ⬇ Escrituras con el permiso de administración de Puntos Dorados
        //   (agrega el atributo o la política que usan tus otros controladores).

        [HttpPost]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Create([FromBody] SaveGoldenRecognitionCategoryDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.CreateAsync(dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage });
            }
        }

        [HttpPut("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Update(int id, [FromBody] SaveGoldenRecognitionCategoryDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.UpdateAsync(id, dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage });
            }
        }

        [HttpPatch("{id:int}/inactivate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Inactivate(int id) => SetActive(id, active: false);

        [HttpPatch("{id:int}/activate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Activate(int id) => SetActive(id, active: true);

        private async Task<IActionResult> SetActive(int id, bool active)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.SetActiveAsync(id, active, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage });
            }
        }
    }
}
```

> `Inactivate` y `Activate` comparten un método privado para no repetir el `try/catch`. Si en el proyecto prefieren cada acción completa, copia el cuerpo de `SetActive` en las dos.

### `Controllers/GoldenProductCategoriesController.cs`

Igual al anterior, sin `appearance-options`, con `IGoldenProductCategoryService`, `SaveGoldenProductCategoryDto` y `ApiResponseConstants.GoldenProductCategoriesErrorMessage`:

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: categorías del catálogo de redención.</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class GoldenProductCategoriesController(IGoldenProductCategoryService service) : ControllerBase
    {
        private readonly IGoldenProductCategoryService _service = service;

        /// <summary>GET ?status=Activa | Inactiva | (vacío = todas)</summary>
        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetAll([FromQuery] string? status)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetAllAsync(status);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage });
            }
        }

        [HttpGet("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetById(int id)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetByIdAsync(id);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage });
            }
        }

        // ⬇ Escrituras con el permiso de administración de Puntos Dorados.

        [HttpPost]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Create([FromBody] SaveGoldenProductCategoryDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.CreateAsync(dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage });
            }
        }

        [HttpPut("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Update(int id, [FromBody] SaveGoldenProductCategoryDto dto)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.UpdateAsync(id, dto, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage });
            }
        }

        [HttpPatch("{id:int}/inactivate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Inactivate(int id) => SetActive(id, active: false);

        [HttpPatch("{id:int}/activate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Activate(int id) => SetActive(id, active: true);

        private async Task<IActionResult> SetActive(int id, bool active)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.SetActiveAsync(id, active, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductCategoriesErrorMessage });
            }
        }
    }
}
```

### Registro — `ApplicationServiceRegistration.cs`

```csharp
services.AddScoped<IGoldenRecognitionCategoryService, GoldenRecognitionCategoryService>();
services.AddScoped<IGoldenProductCategoryService, GoldenProductCategoryService>();
```

Nada en `InfrastructureServiceRegistration.cs`: el repositorio genérico, el Unit of Work y el helper ya están registrados.

---

## 9. 🎨 Biblioteca de iconos y colores — qué necesita Angular

**La librería: Font Awesome Free 6**, la que ya usa el proyecto (las tarjetas muestran clases `fa-solid fa-…`). No hace falta instalar otra.

1. **Confirma la versión.** En `DOCCB-frontend`:

   ```bash
   npm ls @fortawesome/fontawesome-free
   ```

   - Si dice `6.x`, todo el catálogo de la sección 6 funciona (`fa-people-group` necesita 6.1 o superior).
   - Si no aparece, Font Awesome se carga por CDN o kit en `index.html`: busca `fontawesome` ahí y revisa la versión en la URL.
   - Si es 5.x, los prefijos son `fas` en vez de `fa-solid` y varios nombres cambian. Avísame y ajusto el catálogo.

2. **El selector solo pinta lo que manda la API.** `GET /api/GoldenRecognitionCategories/appearance-options` devuelve:

   ```json
   {
     "response": {
       "icons": [
         { "cssClass": "fa-solid fa-medal", "label": "Medalla", "group": "Reconocimiento", "keywords": ["premio", "logro"] }
       ],
       "colors": [
         { "hex": "#2563EB", "label": "Azul" }
       ]
     },
     "hasError": false,
     "errors": []
   }
   ```

   Un icono se dibuja con `<i [class]="icon.cssClass" aria-hidden="true"></i>`. Una grilla de botones con eso, agrupada por `group` y filtrada por `label` o `keywords`, es el selector completo. El color se puede elegir de los `colors` o con `<input type="color">`.

3. **Cómo guardar:** se envía `icon` con el `cssClass` exacto y `color` en `#rrggbb` (la API lo pasa a mayúsculas).

4. **Seguridad:** `[class]` con valores del catálogo es seguro. No uses `[innerHTML]` para pintar iconos.

**Para agregar un icono:** una línea en `GoldenAppearanceCatalog.Icons`, con un nombre que exista en tu versión de Font Awesome (búscalo en fontawesome.com/icons filtrando por "Free" y "Solid"). Ese mismo cambio lo habilita en el selector y en la validación.

---

## 10. Contrato

Rutas con `api/[controller]` (ASP.NET no distingue mayúsculas en la ruta). Todas las respuestas son `{ response, hasError, errors }`. **Los errores de negocio llegan con HTTP 200 y `hasError: true`**, como en Request: el frontend debe revisar `hasError` (su `unwrap` ya lo hace).

| Método | Ruta | Cuerpo | Respuesta |
|---|---|---|---|
| `GET` | `/api/GoldenRecognitionCategories?status=Activa` | — | Lista, activas primero y por nombre |
| `GET` | `/api/GoldenRecognitionCategories/appearance-options` | — | `{ icons, colors }` |
| `GET` | `/api/GoldenRecognitionCategories/{id}` | — | Una categoría · `hasError` si no existe |
| `POST` | `/api/GoldenRecognitionCategories` | `{ name, description, icon, color }` | Creada, con su `id` y `status: "Activa"` |
| `PUT` | `/api/GoldenRecognitionCategories/{id}` | `{ name, description, icon, color }` | Actualizada |
| `PATCH` | `/api/GoldenRecognitionCategories/{id}/inactivate` | — | `status: "Inactiva"` |
| `PATCH` | `/api/GoldenRecognitionCategories/{id}/activate` | — | `status: "Activa"` |
| `GET` | `/api/GoldenProductCategories?status=Inactiva` | — | Lista |
| `GET` | `/api/GoldenProductCategories/{id}` | — | Una categoría |
| `POST` | `/api/GoldenProductCategories` | `{ name, description }` | Creada, con su `id` |
| `PUT` | `/api/GoldenProductCategories/{id}` | `{ name, description }` | Actualizada |
| `PATCH` | `/api/GoldenProductCategories/{id}/inactivate` | — | `status: "Inactiva"` |
| `PATCH` | `/api/GoldenProductCategories/{id}/activate` | — | `status: "Activa"` |

HTTP distinto de 200: `401` sin usuario autenticado y `500` por un error no controlado.

Ejemplo:

```json
POST /api/GoldenRecognitionCategories
{
  "name": "Servicio",
  "description": "Actos de servicio que impactan positivamente al equipo o usuario.",
  "icon": "fa-solid fa-handshake-angle",
  "color": "#2563eb"
}
```

```json
{
  "response": {
    "id": 1,
    "name": "Servicio",
    "description": "Actos de servicio que impactan positivamente al equipo o usuario.",
    "icon": "fa-solid fa-handshake-angle",
    "color": "#2563EB",
    "status": "Activa"
  },
  "hasError": false,
  "errors": []
}
```

Nombre repetido (también HTTP 200):

```json
{ "response": null, "hasError": true, "errors": ["Ya existe una categoría de reconocimiento con ese nombre. Si está inactiva, actívala en lugar de crear otra."] }
```

---

## 11. Pruebas

- Crear con nombre `"  Servicio   al  cliente "` → se guarda `"Servicio al cliente"`.
- **Crear y revisar el `id` de la respuesta: debe ser el real, no `0`.**
- Crear `servicio` cuando existe `Servicio` inactiva → `hasError: true` con el mensaje de reactivar.
- Crear con `icon: "fa-solid fa-medall"` → `hasError` (no está en el catálogo); con `"<script>"` → `hasError` (formato).
- Crear con `color: "#2563eb"` → se guarda `#2563EB`; con `"azul"` o `"#FFF"` → `hasError`.
- Editar una categoría con un icono antiguo (`fa-solid fa-hands-helping`) sin cambiar el icono → éxito; cambiarlo por uno fuera del catálogo → `hasError`.
- Inactivar dos veces la misma → éxito las dos; `updated_date` cambia solo la primera vez.
- `GET ?status=activa` (minúsculas) → solo activas; `?status=borrada` → `hasError`.
- Sin token → `401`.
- `GET` sin `status` → todas, activas primero.
- Usuario sin permiso de administración → puede listar, no puede crear ni editar.
- Revisar en la base de datos que `created_by` y `updated_by` tengan el correo del usuario.

---

## ✅ Checklist

- [ ] `GoldenPointsCategories.sql` ejecutado (con o sin datos iniciales).
- [ ] Entidades sin `BaseEntity` (o heredándola solo si sus tipos coinciden).
- [ ] Configuraciones en `Configurations/` (se cargan solas).
- [ ] Feature `GoldenPoints` con `Constants`, `Dtos`, `Helpers`, `Interfaces` y `Services`.
- [ ] `DbSet` de las dos entidades en `DOCCbDbContext`.
- [ ] Servicios con `ResponseDto<T>`, `ITransactionExecutorHelper` + `Repository<T>()` y `DateTime.UtcNow`; sin repositorio propio.
- [ ] `CreateAsync` vuelve a mapear después del helper (la respuesta trae el `id` real).
- [ ] Controladores con el patrón de Request (`api/[controller]`, usuario autenticado, `try/catch`, `Ok(response)`) y mensajes en `ApiResponseConstants`.
- [ ] Permiso de administración en `POST`, `PUT` y `PATCH`; `GET` para cualquier usuario autenticado.
- [ ] Versión de Font Awesome confirmada y catálogo revisado contra ella.
- [ ] Servicios registrados en `ApplicationServiceRegistration.cs`.
- [ ] Pendiente para después: botón "Activar" en las tarjetas inactivas y `category_id` en la tabla de productos.
