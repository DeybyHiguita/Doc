# 🏅 Puntos Dorados — Categorías (API .NET 8 + SQL Server)

API para la pestaña **Categorías** del administrador de Puntos Dorados:

| Parte | Campos | Operaciones |
|---|---|---|
| **Categorías de reconocimientos** | nombre, descripción, icono (Font Awesome), color | listar (todas, activas o inactivas), ver una, crear, editar, inactivar, reactivar |
| **Categorías de productos** | nombre, descripción | listar (todas, activas o inactivas), ver una, crear, editar, inactivar, reactivar |
| **Biblioteca de iconos y colores** | catálogo de iconos con etiqueta, grupo y palabras de búsqueda; paleta de colores | consultar para el selector de la pantalla |

- **Solo backend.** La sección 9 explica qué necesita Angular para el selector de iconos y colores, sin construir la pantalla.
- **Convenciones:** las confirmadas en el código ([referencia-estilos-y-capas-doccb.md](referencia-estilos-y-capas-doccb.md), sección 4).
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
│   ├── GoldenCategoryMapper.cs            entidad → DTO
│   └── WriteOutcome.cs                    resultado de una escritura dentro del helper
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
└── Persistence/Scripts SQL/GoldenPointsCategories.sql

WebApp/
├── Common/ApiResponseConstants.cs               ✏️ + 2 mensajes
└── Controllers/
    ├── GoldenRecognitionCategoriesController.cs
    └── GoldenProductCategoriesController.cs
```

> La carpeta de DTOs de esta feature se llama `Dtos`, como en `EmailAlertLog`. Si prefieres `DTOs` como en `Common`, cambia carpeta y namespace juntos.

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

---

## 6. Paso 3 — Constantes, catálogo y DTOs

### `Constants/GoldenCategoryStatus.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants;

/// <summary>Los mismos textos que GoldenCategoryStatus del frontend: 'Activa' | 'Inactiva'.</summary>
public static class GoldenCategoryStatus
{
    public const string Active = "Activa";
    public const string Inactive = "Inactiva";

    public static string ToCode(bool active) => active ? Active : Inactive;

    /// <summary>Vacío = todas. "Activa" / "Inactiva" sin distinguir mayúsculas. false = valor desconocido.</summary>
    public static bool TryParseFilter(string? value, out bool? active)
    {
        active = null;
        if (string.IsNullOrWhiteSpace(value)) return true;

        var text = value.Trim();
        if (text.Equals(Active, StringComparison.OrdinalIgnoreCase)) { active = true; return true; }
        if (text.Equals(Inactive, StringComparison.OrdinalIgnoreCase)) { active = false; return true; }

        return false;
    }
}
```

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

### `Helpers/WriteOutcome.cs`

El helper guarda **después** de la lambda, así que el `Id` de una entidad nueva solo existe cuando `ExecuteWithTransactionAsync` termina. La lambda devuelve la entidad (o el motivo del rechazo) y el DTO se arma afuera.

```csharp
using DOCCB.Application.Features.Common.Application.DTOs; // ServiceResult<T>, ServiceResultStatus

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers;

/// <summary>Resultado de la lambda de escritura: la entidad que se guardará o por qué no.</summary>
public sealed record WriteOutcome<T>(T? Entity, ServiceResultStatus Status, string? Error) where T : class
{
    public static WriteOutcome<T> Ok(T entity) => new(entity, ServiceResultStatus.Ok, null);
    public static WriteOutcome<T> Fail(ServiceResultStatus status, string error) => new(null, status, error);
}

public static class WriteOutcomeExtensions
{
    /// <summary>Llamar después de ExecuteWithTransactionAsync: la entidad ya tiene su Id.</summary>
    public static ServiceResult<TDto> ToResult<T, TDto>(this WriteOutcome<T>? outcome, Func<T, TDto> map) where T : class =>
        outcome?.Entity is { } entity
            ? ServiceResult<TDto>.Ok(map(entity))
            : ServiceResult<TDto>.Fail(
                outcome?.Status ?? ServiceResultStatus.Unavailable,
                outcome?.Error ?? "No se pudo completar la operación.");
}
```

### `Interfaces/IGoldenRecognitionCategoryService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces;

public interface IGoldenRecognitionCategoryService
{
    /// <param name="status">"Activa", "Inactiva" o vacío para todas.</param>
    Task<ServiceResult<List<GoldenRecognitionCategoryDto>>> GetAllAsync(string? status);
    Task<ServiceResult<GoldenRecognitionCategoryDto>> GetByIdAsync(int id);
    Task<ServiceResult<GoldenRecognitionCategoryDto>> CreateAsync(SaveGoldenRecognitionCategoryDto dto, string currentUser);
    Task<ServiceResult<GoldenRecognitionCategoryDto>> UpdateAsync(int id, SaveGoldenRecognitionCategoryDto dto, string currentUser);
    Task<ServiceResult<GoldenRecognitionCategoryDto>> SetActiveAsync(int id, bool active, string currentUser);
    ServiceResult<GoldenAppearanceOptionsDto> GetAppearanceOptions();
}
```

### `Services/GoldenRecognitionCategoryService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Services;

public class GoldenRecognitionCategoryService(
    ITransactionExecutorHelper transactionHelper,
    TimeProvider timeProvider) : IGoldenRecognitionCategoryService
{
    public async Task<ServiceResult<List<GoldenRecognitionCategoryDto>>> GetAllAsync(string? status)
    {
        if (!GoldenCategoryStatus.TryParseFilter(status, out var active))
            return ServiceResult<List<GoldenRecognitionCategoryDto>>.Fail(ServiceResultStatus.Invalid, GoldenCategoryConstants.InvalidStatusFilter);

        var categories = await transactionHelper.ExecuteQueryAsync<List<GoldenRecognitionCategory>>(async unitOfWork =>
            (await unitOfWork.Repository<GoldenRecognitionCategory>()
                .GetListAsync(c => active == null || c.Active == active))
                .ToList());

        // Tabla pequeña: se ordena en memoria. Activas primero, luego por nombre.
        var result = (categories ?? [])
            .OrderByDescending(c => c.Active)
            .ThenBy(c => c.Name)
            .Select(GoldenCategoryMapper.ToRecognitionDto)
            .ToList();

        return ServiceResult<List<GoldenRecognitionCategoryDto>>.Ok(result);
    }

    public async Task<ServiceResult<GoldenRecognitionCategoryDto>> GetByIdAsync(int id)
    {
        var category = await transactionHelper.ExecuteQueryAsync<GoldenRecognitionCategory>(unitOfWork =>
            unitOfWork.Repository<GoldenRecognitionCategory>().GetByIdAsync(id));

        return category is null
            ? ServiceResult<GoldenRecognitionCategoryDto>.Fail(ServiceResultStatus.NotFound, GoldenCategoryConstants.RecognitionCategoryNotFound)
            : ServiceResult<GoldenRecognitionCategoryDto>.Ok(GoldenCategoryMapper.ToRecognitionDto(category));
    }

    public async Task<ServiceResult<GoldenRecognitionCategoryDto>> CreateAsync(SaveGoldenRecognitionCategoryDto dto, string currentUser)
    {
        var errors = new List<string>();
        var name = GoldenCategoryValidator.Name(dto.Name, errors);
        var description = GoldenCategoryValidator.Description(dto.Description, errors);
        var icon = GoldenCategoryValidator.Icon(dto.Icon, errors);
        var color = GoldenCategoryValidator.Color(dto.Color, errors);

        if (icon is not null && !GoldenAppearanceCatalog.IsKnownIcon(icon))
            errors.Add(GoldenCategoryConstants.IconNotInCatalog);

        if (errors.Count > 0)
            return ServiceResult<GoldenRecognitionCategoryDto>.Fail(ServiceResultStatus.Invalid, errors);

        var outcome = await transactionHelper.ExecuteWithTransactionAsync<WriteOutcome<GoldenRecognitionCategory>>(async unitOfWork =>
        {
            var repository = unitOfWork.Repository<GoldenRecognitionCategory>();

            if (await repository.AnyAsync(c => c.Name == name))
                return WriteOutcome<GoldenRecognitionCategory>.Fail(ServiceResultStatus.Conflict, GoldenCategoryConstants.RecognitionCategoryNameTaken);

            var category = new GoldenRecognitionCategory
            {
                Name = name!,
                Description = description,
                Icon = icon!,
                Color = color!,
                Active = true,
                CreatedDate = Now(),
                CreatedBy = currentUser,
            };

            await repository.AddAsync(category);
            return WriteOutcome<GoldenRecognitionCategory>.Ok(category); // el Id se llena cuando el helper guarda
        });

        return outcome.ToResult(GoldenCategoryMapper.ToRecognitionDto);
    }

    public async Task<ServiceResult<GoldenRecognitionCategoryDto>> UpdateAsync(int id, SaveGoldenRecognitionCategoryDto dto, string currentUser)
    {
        var errors = new List<string>();
        var name = GoldenCategoryValidator.Name(dto.Name, errors);
        var description = GoldenCategoryValidator.Description(dto.Description, errors);
        var icon = GoldenCategoryValidator.Icon(dto.Icon, errors);
        var color = GoldenCategoryValidator.Color(dto.Color, errors);

        if (errors.Count > 0)
            return ServiceResult<GoldenRecognitionCategoryDto>.Fail(ServiceResultStatus.Invalid, errors);

        var outcome = await transactionHelper.ExecuteWithTransactionAsync<WriteOutcome<GoldenRecognitionCategory>>(async unitOfWork =>
        {
            var repository = unitOfWork.Repository<GoldenRecognitionCategory>();

            // GetByIdAsync trae la entidad CON seguimiento: el helper guarda solo lo que cambie.
            var category = await repository.GetByIdAsync(id);
            if (category is null)
                return WriteOutcome<GoldenRecognitionCategory>.Fail(ServiceResultStatus.NotFound, GoldenCategoryConstants.RecognitionCategoryNotFound);

            // El icono que ya tenía se respeta aunque no esté en el catálogo (datos anteriores).
            if (icon != category.Icon && !GoldenAppearanceCatalog.IsKnownIcon(icon!))
                return WriteOutcome<GoldenRecognitionCategory>.Fail(ServiceResultStatus.Invalid, GoldenCategoryConstants.IconNotInCatalog);

            if (await repository.AnyAsync(c => c.Name == name && c.Id != id))
                return WriteOutcome<GoldenRecognitionCategory>.Fail(ServiceResultStatus.Conflict, GoldenCategoryConstants.RecognitionCategoryNameTaken);

            category.Name = name!;
            category.Description = description;
            category.Icon = icon!;
            category.Color = color!;
            category.UpdatedDate = Now();
            category.UpdatedBy = currentUser;

            // Sin UpdateAsync: marcaría todas las columnas como modificadas. La entidad ya está siendo seguida.
            return WriteOutcome<GoldenRecognitionCategory>.Ok(category);
        });

        return outcome.ToResult(GoldenCategoryMapper.ToRecognitionDto);
    }

    public async Task<ServiceResult<GoldenRecognitionCategoryDto>> SetActiveAsync(int id, bool active, string currentUser)
    {
        var outcome = await transactionHelper.ExecuteWithTransactionAsync<WriteOutcome<GoldenRecognitionCategory>>(async unitOfWork =>
        {
            var category = await unitOfWork.Repository<GoldenRecognitionCategory>().GetByIdAsync(id);
            if (category is null)
                return WriteOutcome<GoldenRecognitionCategory>.Fail(ServiceResultStatus.NotFound, GoldenCategoryConstants.RecognitionCategoryNotFound);

            if (category.Active != active) // si ya estaba así, no hay nada que guardar
            {
                category.Active = active;
                category.UpdatedDate = Now();
                category.UpdatedBy = currentUser;
            }

            return WriteOutcome<GoldenRecognitionCategory>.Ok(category);
        });

        return outcome.ToResult(GoldenCategoryMapper.ToRecognitionDto);
    }

    public ServiceResult<GoldenAppearanceOptionsDto> GetAppearanceOptions() =>
        ServiceResult<GoldenAppearanceOptionsDto>.Ok(new GoldenAppearanceOptionsDto
        {
            Icons = GoldenAppearanceCatalog.Icons,
            Colors = GoldenAppearanceCatalog.Colors,
        });

    private DateTime Now() => timeProvider.GetUtcNow().UtcDateTime;
}
```

### `Interfaces/IGoldenProductCategoryService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces;

public interface IGoldenProductCategoryService
{
    Task<ServiceResult<List<GoldenProductCategoryDto>>> GetAllAsync(string? status);
    Task<ServiceResult<GoldenProductCategoryDto>> GetByIdAsync(int id);
    Task<ServiceResult<GoldenProductCategoryDto>> CreateAsync(SaveGoldenProductCategoryDto dto, string currentUser);
    Task<ServiceResult<GoldenProductCategoryDto>> UpdateAsync(int id, SaveGoldenProductCategoryDto dto, string currentUser);
    Task<ServiceResult<GoldenProductCategoryDto>> SetActiveAsync(int id, bool active, string currentUser);
}
```

### `Services/GoldenProductCategoryService.cs`

El mismo patrón, sin icono ni color.

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Services;

public class GoldenProductCategoryService(
    ITransactionExecutorHelper transactionHelper,
    TimeProvider timeProvider) : IGoldenProductCategoryService
{
    public async Task<ServiceResult<List<GoldenProductCategoryDto>>> GetAllAsync(string? status)
    {
        if (!GoldenCategoryStatus.TryParseFilter(status, out var active))
            return ServiceResult<List<GoldenProductCategoryDto>>.Fail(ServiceResultStatus.Invalid, GoldenCategoryConstants.InvalidStatusFilter);

        var categories = await transactionHelper.ExecuteQueryAsync<List<GoldenProductCategory>>(async unitOfWork =>
            (await unitOfWork.Repository<GoldenProductCategory>()
                .GetListAsync(c => active == null || c.Active == active))
                .ToList());

        var result = (categories ?? [])
            .OrderByDescending(c => c.Active)
            .ThenBy(c => c.Name)
            .Select(GoldenCategoryMapper.ToProductDto)
            .ToList();

        return ServiceResult<List<GoldenProductCategoryDto>>.Ok(result);
    }

    public async Task<ServiceResult<GoldenProductCategoryDto>> GetByIdAsync(int id)
    {
        var category = await transactionHelper.ExecuteQueryAsync<GoldenProductCategory>(unitOfWork =>
            unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(id));

        return category is null
            ? ServiceResult<GoldenProductCategoryDto>.Fail(ServiceResultStatus.NotFound, GoldenCategoryConstants.ProductCategoryNotFound)
            : ServiceResult<GoldenProductCategoryDto>.Ok(GoldenCategoryMapper.ToProductDto(category));
    }

    public async Task<ServiceResult<GoldenProductCategoryDto>> CreateAsync(SaveGoldenProductCategoryDto dto, string currentUser)
    {
        var errors = new List<string>();
        var name = GoldenCategoryValidator.Name(dto.Name, errors);
        var description = GoldenCategoryValidator.Description(dto.Description, errors);

        if (errors.Count > 0)
            return ServiceResult<GoldenProductCategoryDto>.Fail(ServiceResultStatus.Invalid, errors);

        var outcome = await transactionHelper.ExecuteWithTransactionAsync<WriteOutcome<GoldenProductCategory>>(async unitOfWork =>
        {
            var repository = unitOfWork.Repository<GoldenProductCategory>();

            if (await repository.AnyAsync(c => c.Name == name))
                return WriteOutcome<GoldenProductCategory>.Fail(ServiceResultStatus.Conflict, GoldenCategoryConstants.ProductCategoryNameTaken);

            var category = new GoldenProductCategory
            {
                Name = name!,
                Description = description,
                Active = true,
                CreatedDate = Now(),
                CreatedBy = currentUser,
            };

            await repository.AddAsync(category);
            return WriteOutcome<GoldenProductCategory>.Ok(category);
        });

        return outcome.ToResult(GoldenCategoryMapper.ToProductDto);
    }

    public async Task<ServiceResult<GoldenProductCategoryDto>> UpdateAsync(int id, SaveGoldenProductCategoryDto dto, string currentUser)
    {
        var errors = new List<string>();
        var name = GoldenCategoryValidator.Name(dto.Name, errors);
        var description = GoldenCategoryValidator.Description(dto.Description, errors);

        if (errors.Count > 0)
            return ServiceResult<GoldenProductCategoryDto>.Fail(ServiceResultStatus.Invalid, errors);

        var outcome = await transactionHelper.ExecuteWithTransactionAsync<WriteOutcome<GoldenProductCategory>>(async unitOfWork =>
        {
            var repository = unitOfWork.Repository<GoldenProductCategory>();

            var category = await repository.GetByIdAsync(id);
            if (category is null)
                return WriteOutcome<GoldenProductCategory>.Fail(ServiceResultStatus.NotFound, GoldenCategoryConstants.ProductCategoryNotFound);

            if (await repository.AnyAsync(c => c.Name == name && c.Id != id))
                return WriteOutcome<GoldenProductCategory>.Fail(ServiceResultStatus.Conflict, GoldenCategoryConstants.ProductCategoryNameTaken);

            category.Name = name!;
            category.Description = description;
            category.UpdatedDate = Now();
            category.UpdatedBy = currentUser;

            return WriteOutcome<GoldenProductCategory>.Ok(category);
        });

        return outcome.ToResult(GoldenCategoryMapper.ToProductDto);
    }

    public async Task<ServiceResult<GoldenProductCategoryDto>> SetActiveAsync(int id, bool active, string currentUser)
    {
        var outcome = await transactionHelper.ExecuteWithTransactionAsync<WriteOutcome<GoldenProductCategory>>(async unitOfWork =>
        {
            var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(id);
            if (category is null)
                return WriteOutcome<GoldenProductCategory>.Fail(ServiceResultStatus.NotFound, GoldenCategoryConstants.ProductCategoryNotFound);

            if (category.Active != active)
            {
                category.Active = active;
                category.UpdatedDate = Now();
                category.UpdatedBy = currentUser;
            }

            return WriteOutcome<GoldenProductCategory>.Ok(category);
        });

        return outcome.ToResult(GoldenCategoryMapper.ToProductDto);
    }

    private DateTime Now() => timeProvider.GetUtcNow().UtcDateTime;
}
```

> **Firmas del repositorio genérico.** Se usan `GetListAsync(predicado)`, `GetByIdAsync(id)` (con seguimiento), `AnyAsync(predicado)` y `AddAsync(entidad)`, todas de tu `IGenericRepository<T>`. El `.ToList()` sobre `GetListAsync` funciona aunque devuelva `IReadOnlyList` o `IEnumerable`.
>
> **Nombre repetido al mismo tiempo.** Si dos administradores crean el mismo nombre en el mismo segundo, el índice único rechaza el segundo y el helper responde con el error general (500). Es muy poco probable en una pantalla de configuración; no vale la pena más código.

---

## 8. Paso 5 — Controladores

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenRecognitionCategoriesErrorMessage = "No se pudo completar la operación con las categorías de reconocimiento.";
public const string GoldenProductCategoriesErrorMessage = "No se pudo completar la operación con las categorías de producto.";
```

### `Controllers/GoldenRecognitionCategoriesController.cs`

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
    [Route("api/golden-points/recognition-categories")]
    [Authorize]
    public class GoldenRecognitionCategoriesController(
        IGoldenRecognitionCategoryService service,
        ILogger<GoldenRecognitionCategoriesController> logger) : ControllerBase
    {
        private readonly IGoldenRecognitionCategoryService _service = service;
        private readonly ILogger<GoldenRecognitionCategoriesController> _logger = logger;

        /// <summary>Correo del usuario autenticado, para created_by / updated_by.</summary>
        private string CurrentUser => MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User).Email ?? string.Empty;

        /// <summary>GET ?status=Activa | Inactiva | (vacío = todas)</summary>
        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> GetAll([FromQuery] string? status) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.GetAllAsync(status)),
                ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, _logger);

        /// <summary>Iconos y colores para el selector de la pantalla.</summary>
        [HttpGet("appearance-options")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        public Task<IActionResult> GetAppearanceOptions() =>
            this.ExecuteAsync(
                _ => Task.FromResult<IActionResult>(this.ToActionResult(_service.GetAppearanceOptions())),
                ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, _logger);

        [HttpGet("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> GetById(int id) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.GetByIdAsync(id)),
                ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, _logger);

        // ⬇ Las acciones de escritura llevan el permiso de administración de Puntos Dorados
        //   (agrega aquí el atributo o la política que usan tus otros controladores).

        [HttpPost]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status409Conflict)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Create([FromBody] SaveGoldenRecognitionCategoryDto dto) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.CreateAsync(dto, CurrentUser)),
                ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, _logger);

        [HttpPut("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status409Conflict)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Update(int id, [FromBody] SaveGoldenRecognitionCategoryDto dto) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.UpdateAsync(id, dto, CurrentUser)),
                ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, _logger);

        [HttpPatch("{id:int}/inactivate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Inactivate(int id) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.SetActiveAsync(id, active: false, CurrentUser)),
                ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, _logger);

        [HttpPatch("{id:int}/activate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Activate(int id) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.SetActiveAsync(id, active: true, CurrentUser)),
                ApiResponseConstants.GoldenRecognitionCategoriesErrorMessage, _logger);
    }
}
```

> `MicrosoftUserAuthenticatorHelper` es el que usa `RequestController`. Si tu `ControllerExtensions` ya tiene `User.CurrentUserEmail()`, úsalo en su lugar y ajusta el `using`.
>
> `appearance-options` va **antes** de `{id:int}` solo por orden de lectura: la restricción `:int` ya evita que choquen.

### `Controllers/GoldenProductCategoriesController.cs`

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
    [Route("api/golden-points/product-categories")]
    [Authorize]
    public class GoldenProductCategoriesController(
        IGoldenProductCategoryService service,
        ILogger<GoldenProductCategoriesController> logger) : ControllerBase
    {
        private readonly IGoldenProductCategoryService _service = service;
        private readonly ILogger<GoldenProductCategoriesController> _logger = logger;

        private string CurrentUser => MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User).Email ?? string.Empty;

        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> GetAll([FromQuery] string? status) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.GetAllAsync(status)),
                ApiResponseConstants.GoldenProductCategoriesErrorMessage, _logger);

        [HttpGet("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> GetById(int id) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.GetByIdAsync(id)),
                ApiResponseConstants.GoldenProductCategoriesErrorMessage, _logger);

        // ⬇ Escrituras con el permiso de administración de Puntos Dorados.

        [HttpPost]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status409Conflict)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Create([FromBody] SaveGoldenProductCategoryDto dto) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.CreateAsync(dto, CurrentUser)),
                ApiResponseConstants.GoldenProductCategoriesErrorMessage, _logger);

        [HttpPut("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status409Conflict)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Update(int id, [FromBody] SaveGoldenProductCategoryDto dto) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.UpdateAsync(id, dto, CurrentUser)),
                ApiResponseConstants.GoldenProductCategoriesErrorMessage, _logger);

        [HttpPatch("{id:int}/inactivate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Inactivate(int id) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.SetActiveAsync(id, active: false, CurrentUser)),
                ApiResponseConstants.GoldenProductCategoriesErrorMessage, _logger);

        [HttpPatch("{id:int}/activate")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status404NotFound)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public Task<IActionResult> Activate(int id) =>
            this.ExecuteAsync(
                async _ => this.ToActionResult(await _service.SetActiveAsync(id, active: true, CurrentUser)),
                ApiResponseConstants.GoldenProductCategoriesErrorMessage, _logger);
    }
}
```

### Registro — `ApplicationServiceRegistration.cs`

```csharp
services.AddScoped<IGoldenRecognitionCategoryService, GoldenRecognitionCategoryService>();
services.AddScoped<IGoldenProductCategoryService, GoldenProductCategoryService>();
```

Nada en `InfrastructureServiceRegistration.cs`: el repositorio genérico, el Unit of Work y el helper ya están registrados. `TimeProvider` también (si no, `services.AddSingleton(TimeProvider.System);`).

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

2. **El selector solo pinta lo que manda la API.** `GET /api/golden-points/recognition-categories/appearance-options` devuelve:

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

Base: `/api/golden-points`. Las respuestas usan el formato de siempre: `{ response, hasError, errors }`.

| Método | Ruta | Cuerpo | Respuesta |
|---|---|---|---|
| `GET` | `/recognition-categories?status=Activa` | — | `GoldenRecognitionCategoryDto[]`, activas primero y por nombre |
| `GET` | `/recognition-categories/appearance-options` | — | `{ icons, colors }` |
| `GET` | `/recognition-categories/{id}` | — | `GoldenRecognitionCategoryDto` · `404` |
| `POST` | `/recognition-categories` | `{ name, description, icon, color }` | Categoría creada, `status: "Activa"` · `400` · `409` |
| `PUT` | `/recognition-categories/{id}` | `{ name, description, icon, color }` | Categoría actualizada · `400` · `404` · `409` |
| `PATCH` | `/recognition-categories/{id}/inactivate` | — | Categoría con `status: "Inactiva"` · `404` |
| `PATCH` | `/recognition-categories/{id}/activate` | — | Categoría con `status: "Activa"` · `404` |
| `GET` | `/product-categories?status=Inactiva` | — | `GoldenProductCategoryDto[]` |
| `GET` | `/product-categories/{id}` | — | `GoldenProductCategoryDto` · `404` |
| `POST` | `/product-categories` | `{ name, description }` | Categoría creada · `400` · `409` |
| `PUT` | `/product-categories/{id}` | `{ name, description }` | Categoría actualizada · `400` · `404` · `409` |
| `PATCH` | `/product-categories/{id}/inactivate` | — | `status: "Inactiva"` · `404` |
| `PATCH` | `/product-categories/{id}/activate` | — | `status: "Activa"` · `404` |

`status` vacío o ausente = todas. Cualquier otro valor distinto de `Activa`/`Inactiva` → `400`.

Ejemplo de creación:

```json
POST /api/golden-points/recognition-categories
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

---

## 11. Pruebas

- Crear con nombre `"  Servicio   al  cliente "` → se guarda `"Servicio al cliente"`.
- Crear `servicio` cuando existe `Servicio` inactiva → `409` con el mensaje de reactivar.
- Crear con `icon: "fa-solid fa-medall"` → `400` (no está en el catálogo); con `"<script>"` → `400` (formato).
- Crear con `color: "#2563eb"` → se guarda `#2563EB`; con `"azul"` o `"#FFF"` → `400`.
- Editar una categoría con un icono antiguo (`fa-solid fa-hands-helping`) sin cambiar el icono → `200`; cambiarlo por uno fuera del catálogo → `400`.
- Inactivar dos veces la misma → `200` las dos; `updated_date` cambia solo la primera vez.
- `GET ?status=activa` (minúsculas) → solo activas; `?status=borrada` → `400`.
- `GET` sin `status` → todas, activas primero.
- Usuario sin permiso de administración → puede listar, no puede crear ni editar.
- Revisar en la base de datos que `created_by` y `updated_by` tengan el correo del usuario.

---

## ✅ Checklist

- [ ] `GoldenPointsCategories.sql` ejecutado (con o sin datos iniciales).
- [ ] Entidades sin `BaseEntity` (o heredándola solo si sus tipos coinciden).
- [ ] Configuraciones en `Configurations/` (se cargan solas).
- [ ] Feature `GoldenPoints` con `Constants`, `Dtos`, `Helpers`, `Interfaces` y `Services`.
- [ ] Servicios con `ITransactionExecutorHelper` + `Repository<T>()`; sin repositorio propio.
- [ ] Controladores con `ExecuteAsync` + `ToActionResult` y mensajes en `ApiResponseConstants`.
- [ ] Permiso de administración en `POST`, `PUT` y `PATCH`; `GET` para cualquier usuario autenticado.
- [ ] Versión de Font Awesome confirmada y catálogo revisado contra ella.
- [ ] Servicios registrados en `ApplicationServiceRegistration.cs`.
- [ ] Pendiente para después: botón "Activar" en las tarjetas inactivas y `category_id` en la tabla de productos.
