# 🎁 Puntos Dorados — Catálogo de productos (API .NET 8 + SQL Server)

Base de datos y API para la pestaña **Catálogo** del administrador y para el catálogo que ven los colaboradores. Solo backend; el frontend se hace después con el contrato de la sección 10.

**Qué cubre (feature "Catálogo de Productos" del backlog):**

| Historia de usuario | Cómo queda |
|---|---|
| Crear producto | `POST /api/GoldenProducts` |
| Editar/eliminar producto | `PUT /api/GoldenProducts/{id}` + inactivar/activar. **No hay borrado físico**: las redenciones van a referenciar el producto. |
| Listar productos disponibles (colaborador) | `GET /api/GoldenProducts/available` |
| Listado del administrador con filtros | `GET /api/GoldenProducts?categoryId=&available=&minPoints=&maxPoints=&sort=` |
| Múltiples imágenes | Tabla `golden_product_image` relacionada con el producto (hasta 10 URLs, en orden) |
| Límite de redención por usuario | Columna `max_redemptions_per_user` (0 = sin límite). La aplica la redención. |
| Fecha de expiración | Columna `expiration_date` (opcional) |
| Stock en tiempo real | `stock` en cada respuesta, leído en cada petición |
| Ocultar/reactivar sin stock | Filtro `available=false` con los **motivos** de cada producto (sin stock, inactivo, vencido…) |
| Enlace desde comunicaciones | `GET /api/GoldenProducts/{id}` para cualquier usuario autenticado |
| Mermar stock (para la redención) | `DecreaseStockAsync` en el servicio, **sin controlador**, seguro ante redenciones simultáneas |

- **Stack:** .NET 8 · EF Core 8 · SQL Server
- **Depende de:** `dbo.golden_product_category` ([puntos-dorados-categorias-api.md](puntos-dorados-categorias-api.md))

---

## 1. 📏 Convenciones aplicadas

Resumen de [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md) (patrón estándar de Request), confirmadas con las correcciones anteriores:

- **Datos:** `ITransactionExecutorHelper` + `unitOfWork.Repository<T>()`. Sin repositorio propio (sección 2).
- **Servicios:** devuelven `ResponseDto<T>` con `ResponseDtoHelper`. Toda la lógica con datos va dentro de la lambda del helper, con `?? CreateErrorResponseDto(...)` al final.
- **Inyección:** constructor primario + `private readonly ITransactionExecutorHelper _transactionHelper`.
- **Hora:** `DateTime.UtcNow` (no `TimeProvider`).
- **Controladores:** patrón de `RequestController`: `[Route("api/[controller]")]`, usuario autenticado en cada acción, `try/catch`, `Ok(response)`. Los errores de negocio van con HTTP 200 y `hasError: true`.
- **`DbContext`:** un `DbSet` por entidad nueva.
- **Código:** entidades sin `BaseEntity`, namespaces en bloque, llaves en todos los `if`, clases `public` sin los `using` de la plantilla de Visual Studio.
- **Crear:** el `Id` de una entidad nueva solo existe después de que el helper guarda, así que se vuelve a mapear afuera de la lambda.

---

## 2. 🧭 ¿Repositorio propio? No (por ahora)

| Condición | ¿Se cumple? |
|---|---|
| Agregados o proyecciones en SQL | No. El catálogo es pequeño (decenas de productos): se lee completo y se filtra en memoria. |
| `GroupBy`, subconsultas, orden calculado | No en SQL: la disponibilidad se calcula en memoria. |
| Traducir errores de SQL | Solo la concurrencia del stock, que se resuelve con `rowversion` y el repositorio genérico (sección 3, decisión 6). |
| Consulta compleja compartida | No. |

**Decisión:** repositorio genérico. Si el catálogo crece a miles de productos:

1. Primero, los métodos de paginación que ya tiene el genérico (`GetPagedListAsync`, o `GetNextPageAsync` por llave), con los filtros simples (categoría, rango de puntos, activo) en el predicado.
2. Solo si hace falta filtrar por **disponible** en SQL, que depende de la categoría (otra tabla) y de la fecha, se justifica un `IGoldenProductRepository`, porque ese LINQ ya no cabe en el genérico (sección 5 de `ARQUITECTURA Y EJEMPLO.MD`).

---

## 3. 🧐 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Disponible vs. activo.** Son dos cosas distintas. | `active` es lo que decide el administrador (mostrar u ocultar). **Disponible** se calcula en cada lectura: activo + categoría activa + con puntos + stock distinto de 0 + no vencido. La respuesta trae `available` y `unavailableReasons` (por ejemplo `["Sin stock"]`). |
| 2 | **"Si el stock baja a 0, el producto queda no disponible".** | Se cumple por el cálculo: con `stock = 0`, `available = false` con el motivo "Sin stock". No se cambia `active`, así que cuando el administrador vuelve a poner stock, el producto queda disponible otra vez sin otro paso. Eso cubre "ocultar/reactivar sin stock". |
| 3 | **Puntos opcionales.** | `points_cost` puede ser `NULL` (producto en borrador). Sin puntos **no está disponible** ("Sin puntos asignados"): no se puede redimir algo sin precio. |
| 4 | **Stock opcional.** | `stock = NULL` = sin control de stock (ilimitado, por ejemplo "Día libre adicional"). Descontar no cambia nada. |
| 5 | **Máximo a redimir por usuario.** | `max_redemptions_per_user`, entero, **0 = sin límite** (como dice el backlog). Aquí solo se guarda; lo valida la redención cuando exista. |
| 6 | **Dos redenciones del último producto al mismo tiempo.** Las dos leen `stock = 1` y las dos descuentan. | Columna `row_version` (`ROWVERSION`): EF incluye la versión en el `UPDATE`. La segunda redención no encuentra la fila con esa versión y falla. `DecreaseStockAsync` reintenta hasta 3 veces leyendo el stock nuevo. Además, `CHECK (stock >= 0)` en la base de datos impide un stock negativo pase lo que pase. |
| 7 | **Imágenes.** | Tabla aparte `golden_product_image` (`url`, `sort_order`). La primera es la portada. Son **URLs https**, como el campo "URL IMAGEN" de la pantalla; subir archivos sería otra funcionalidad. Máximo 10 por producto. Al editar, si la lista cambia, se reemplazan todas. |
| 8 | **Nombre repetido.** | Nombre único en el catálogo (activos e inactivos). |
| 9 | **Categoría inactiva.** | No se puede crear un producto en una categoría inactiva, ni moverlo a una. Si su categoría se inactiva después, el producto queda no disponible ("Categoría inactiva") hasta que se reactive. |
| 10 | **Fecha de expiración.** | Disponible hasta el final de ese día, en hora de Colombia. Al crear, o al cambiarla, no puede ser una fecha pasada. |
| 11 | **Eliminar.** | No hay borrado físico: inactivar. Cuando exista la tabla de redenciones, un producto nunca redimido se podría borrar; hoy no hay cómo saberlo. |
| 12 | **¿Quién ve qué?** | El listado completo con filtros y las escrituras son del administrador. Los colaboradores ven `available` y el detalle por id (para el enlace desde comunicaciones). |

---

## 4. 📁 Archivos

```text
DOCCB.Domain/Entities/
├── GoldenProduct.cs
└── GoldenProductImage.cs

DOCCB.Application/Features/GoldenPoints/Application/
├── Constants/GoldenProductConstants.cs          límites, orden y mensajes
├── Dtos/GoldenProductDtos.cs
├── Helpers/
│   ├── GoldenProductValidator.cs                limpia y valida lo que llega del formulario
│   ├── GoldenProductAvailability.cs             ⭐ regla de "disponible" y sus motivos
│   ├── GoldenProductStock.cs                    ⭐ regla para descontar stock
│   └── GoldenProductMapper.cs
├── Interfaces/IGoldenProductService.cs
└── Services/GoldenProductService.cs

DOCCB.Infraestructure/
├── Configurations/
│   ├── GoldenProductConfiguration.cs
│   └── GoldenProductImageConfiguration.cs
└── Persistence/
    ├── Models/DOCCbDbContext.cs                 ✏️ + 2 DbSet
    └── Scripts SQL/GoldenPointsProducts.sql

WebApp/
├── Common/ApiResponseConstants.cs               ✏️ + 1 mensaje
└── Controllers/GoldenProductsController.cs
```

---

## 5. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/GoldenPointsProducts.sql`

```sql
/* =====================================================================
   Puntos Dorados — catálogo de productos e imágenes
   Base de datos: DB · Esquema: dbo
   Requiere: dbo.golden_product_category (GoldenPointsCategories.sql)
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_product
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_product', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_product
    (
        id                       INT            IDENTITY(1, 1) NOT NULL,
        category_id              INT            NOT NULL,
        name                     NVARCHAR(150)  NOT NULL,
        description              NVARCHAR(500)  NULL,
        points_cost              INT            NULL,      -- NULL = sin puntos asignados (no se puede redimir)
        stock                    INT            NULL,      -- NULL = sin control de stock (ilimitado)
        max_redemptions_per_user INT            NOT NULL CONSTRAINT df_golden_product_max_redemptions DEFAULT (0), -- 0 = sin límite
        expiration_date          DATE           NULL,
        active                   BIT            NOT NULL CONSTRAINT df_golden_product_active DEFAULT (1),
        row_version              ROWVERSION     NOT NULL,  -- concurrencia: dos redenciones a la vez
        created_date             DATETIME2(0)   NOT NULL CONSTRAINT df_golden_product_created_date DEFAULT (SYSUTCDATETIME()),
        created_by               NVARCHAR(150)  NOT NULL,
        updated_date             DATETIME2(0)   NULL,
        updated_by               NVARCHAR(150)  NULL,

        CONSTRAINT pk_golden_product PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_golden_product_category
            FOREIGN KEY (category_id) REFERENCES dbo.golden_product_category (id),
        CONSTRAINT ck_golden_product_name CHECK (LEN(LTRIM(name)) > 0),
        CONSTRAINT ck_golden_product_points_cost CHECK (points_cost IS NULL OR points_cost > 0),
        -- Última defensa: el stock nunca queda negativo, aunque falle todo lo demás.
        CONSTRAINT ck_golden_product_stock CHECK (stock IS NULL OR stock >= 0),
        CONSTRAINT ck_golden_product_max_redemptions CHECK (max_redemptions_per_user >= 0)
    );

    CREATE UNIQUE INDEX ux_golden_product_name ON dbo.golden_product (name);
    CREATE INDEX ix_golden_product_category_id ON dbo.golden_product (category_id);
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.golden_product_image — varias imágenes por producto, en orden
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.golden_product_image', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_product_image
    (
        id           INT             IDENTITY(1, 1) NOT NULL,
        product_id   INT             NOT NULL,
        url          NVARCHAR(1000)  NOT NULL,
        sort_order   INT             NOT NULL,   -- 0 = portada
        created_date DATETIME2(0)    NOT NULL CONSTRAINT df_golden_product_image_created_date DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT pk_golden_product_image PRIMARY KEY CLUSTERED (id),
        CONSTRAINT fk_golden_product_image_product
            FOREIGN KEY (product_id) REFERENCES dbo.golden_product (id) ON DELETE CASCADE,
        CONSTRAINT ck_golden_product_image_url CHECK (url LIKE 'https://%'),
        CONSTRAINT ck_golden_product_image_sort_order CHECK (sort_order >= 0)
    );

    CREATE INDEX ix_golden_product_image_product_id
        ON dbo.golden_product_image (product_id)
        INCLUDE (sort_order, url);
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   Datos iniciales (opcional): los de la pantalla actual, sin imágenes.
   ───────────────────────────────────────────────────────────────────── */
IF NOT EXISTS (SELECT 1 FROM dbo.golden_product)
BEGIN
    INSERT INTO dbo.golden_product (category_id, name, description, points_cost, stock, created_by)
    SELECT c.id, v.name, v.description, v.points_cost, v.stock, N'sistema'
    FROM (VALUES
        (N'Bienestar',    N'Kit Wellness Premium', N'Set de bienestar con termos, antifaz y aceites esenciales.', 180, 25),
        (N'Experiencias', N'Gift Card Experiencia', N'Bono para experiencias recreativas y culturales.',          260, 10),
        (N'Beneficios',   N'Día Libre Adicional',   N'Redime un día libre adicional con aprobación del líder.',    320, 50)
    ) AS v (category, name, description, points_cost, stock)
    JOIN dbo.golden_product_category c ON c.name = v.category;
END;
GO
```

### Consultas útiles

```sql
-- Productos no disponibles y por qué (lo mismo que calcula la API)
DECLARE @today DATE = CAST(DATEADD(HOUR, -5, SYSUTCDATETIME()) AS DATE);

SELECT  p.id, p.name, p.stock, p.points_cost, p.expiration_date, p.active, c.active AS category_active,
        reasons = CONCAT_WS(', ',
            IIF(p.active = 0, 'Producto inactivo', NULL),
            IIF(c.active = 0, 'Categoría inactiva', NULL),
            IIF(p.points_cost IS NULL, 'Sin puntos asignados', NULL),
            IIF(p.stock = 0, 'Sin stock', NULL),
            IIF(p.expiration_date < @today, 'Vencido', NULL))
FROM    dbo.golden_product p
JOIN    dbo.golden_product_category c ON c.id = p.category_id
WHERE   p.active = 0 OR c.active = 0 OR p.points_cost IS NULL OR p.stock = 0 OR p.expiration_date < @today;
```

---

## 6. Paso 2 — Dominio y configuración EF

### `Entities/GoldenProduct.cs`

```csharp
namespace DOCCB.Domain.Entities
{
    /// <summary>Producto o experiencia del catálogo de Puntos Dorados.</summary>
    public class GoldenProduct
    {
        public int Id { get; set; }
        public int CategoryId { get; set; }
        public string Name { get; set; } = string.Empty;
        public string? Description { get; set; }

        /// <summary>null = sin puntos asignados: no se puede redimir.</summary>
        public int? PointsCost { get; set; }

        /// <summary>null = sin control de stock (ilimitado).</summary>
        public int? Stock { get; set; }

        /// <summary>Unidades de este producto que puede redimir cada usuario. 0 = sin límite.</summary>
        public int MaxRedemptionsPerUser { get; set; }

        /// <summary>Último día en que se puede redimir. null = no vence.</summary>
        public DateOnly? ExpirationDate { get; set; }

        public bool Active { get; set; } = true;

        /// <summary>Lo llena SQL Server en cada cambio. EF lo usa para detectar cambios simultáneos.</summary>
        public byte[] RowVersion { get; set; } = [];

        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;
        public DateTime? UpdatedDate { get; set; }
        public string? UpdatedBy { get; set; }

        public ICollection<GoldenProductImage> Images { get; set; } = new List<GoldenProductImage>();
    }
}
```

### `Entities/GoldenProductImage.cs`

```csharp
namespace DOCCB.Domain.Entities
{
    public class GoldenProductImage
    {
        public int Id { get; set; }
        public int ProductId { get; set; }
        public string Url { get; set; } = string.Empty;

        /// <summary>0 = portada.</summary>
        public int SortOrder { get; set; }

        public DateTime CreatedDate { get; set; }

        public GoldenProduct Product { get; set; } = null!;
    }
}
```

### `Configurations/GoldenProductConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenProductConfiguration : IEntityTypeConfiguration<GoldenProduct>
    {
        public void Configure(EntityTypeBuilder<GoldenProduct> builder)
        {
            builder.ToTable("golden_product", "dbo");

            builder.HasKey(p => p.Id).HasName("pk_golden_product");

            builder.Property(p => p.Id).HasColumnName("id");
            builder.Property(p => p.CategoryId).HasColumnName("category_id");
            builder.Property(p => p.Name).HasColumnName("name").HasMaxLength(150).IsRequired();
            builder.Property(p => p.Description).HasColumnName("description").HasMaxLength(500);
            builder.Property(p => p.PointsCost).HasColumnName("points_cost");
            builder.Property(p => p.Stock).HasColumnName("stock");
            builder.Property(p => p.MaxRedemptionsPerUser).HasColumnName("max_redemptions_per_user");
            builder.Property(p => p.ExpirationDate).HasColumnName("expiration_date").HasColumnType("date");
            builder.Property(p => p.Active).HasColumnName("active");
            builder.Property(p => p.RowVersion).HasColumnName("row_version").IsRowVersion();
            builder.Property(p => p.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(p => p.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
            builder.Property(p => p.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
            builder.Property(p => p.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

            builder.HasIndex(p => p.Name).IsUnique().HasDatabaseName("ux_golden_product_name");
            builder.HasIndex(p => p.CategoryId).HasDatabaseName("ix_golden_product_category_id");

            // Solo la llave: el nombre de la categoría se carga aparte (sección 8).
            builder.HasOne<GoldenProductCategory>()
                .WithMany()
                .HasForeignKey(p => p.CategoryId)
                .HasConstraintName("fk_golden_product_category")
                .OnDelete(DeleteBehavior.Restrict);

            builder.HasMany(p => p.Images)
                .WithOne(i => i.Product)
                .HasForeignKey(i => i.ProductId)
                .HasConstraintName("fk_golden_product_image_product")
                .OnDelete(DeleteBehavior.Cascade);
        }
    }
}
```

### `Configurations/GoldenProductImageConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenProductImageConfiguration : IEntityTypeConfiguration<GoldenProductImage>
    {
        public void Configure(EntityTypeBuilder<GoldenProductImage> builder)
        {
            builder.ToTable("golden_product_image", "dbo");

            builder.HasKey(i => i.Id).HasName("pk_golden_product_image");

            builder.Property(i => i.Id).HasColumnName("id");
            builder.Property(i => i.ProductId).HasColumnName("product_id");
            builder.Property(i => i.Url).HasColumnName("url").HasMaxLength(1000).IsRequired();
            builder.Property(i => i.SortOrder).HasColumnName("sort_order");
            builder.Property(i => i.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");

            builder.HasIndex(i => i.ProductId).HasDatabaseName("ix_golden_product_image_product_id");
        }
    }
}
```

### `Persistence/Models/DOCCbDbContext.cs` ✏️

```csharp
public DbSet<GoldenProduct> GoldenProducts { get; set; }
public DbSet<GoldenProductImage> GoldenProductImages { get; set; }
```

---

## 7. Paso 3 — Constantes, DTOs y reglas

### `Constants/GoldenProductConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenProductConstants
    {
        public const int NameMaxLength = 150;
        public const int DescriptionMaxLength = 500;
        public const int MaxImages = 10;
        public const int ImageUrlMaxLength = 1000;
        public const int MaxPointsCost = 1_000_000;
        public const int MaxStock = 1_000_000;
        public const int MaxRedemptionsPerUserLimit = 1_000;
        public const int DecreaseStockAttempts = 3;

        // Orden del listado (?sort=)
        public const string SortName = "name";
        public const string SortPointsAsc = "points-asc";
        public const string SortPointsDesc = "points-desc";

        public const string NameRequired = "El nombre es obligatorio.";
        public const string NameTooLong = "El nombre admite hasta 150 caracteres.";
        public const string NameTaken = "Ya existe un producto con ese nombre.";
        public const string DescriptionTooLong = "La descripción admite hasta 500 caracteres.";
        public const string CategoryRequired = "Elige una categoría.";
        public const string CategoryNotFound = "La categoría no existe.";
        public const string CategoryInactive = "La categoría está inactiva. Elige una categoría activa.";
        public const string PointsInvalid = "Los puntos requeridos deben ser un número entre 1 y 1.000.000.";
        public const string StockInvalid = "El stock debe ser un número entre 0 y 1.000.000.";
        public const string MaxRedemptionsInvalid = "El máximo a redimir por usuario debe estar entre 0 (sin límite) y 1.000.";
        public const string ExpirationInPast = "La fecha de expiración no puede ser una fecha pasada.";
        public const string TooManyImages = "Un producto admite hasta 10 imágenes.";
        public const string ImageInvalid = "La imagen {0} no es una URL https válida.";
        public const string QuantityInvalid = "La cantidad a descontar debe ser mayor que 0.";
        public const string InsufficientStock = "Stock insuficiente: quedan {0} unidades.";
        public const string ConcurrentChange = "El producto cambió mientras se guardaba (por ejemplo, alguien lo redimió). Vuelve a cargarlo e intenta de nuevo.";
        public const string ProductNotFound = "El producto no existe.";
        public const string InvalidPointsRange = "Los puntos mínimos no pueden ser mayores que los máximos.";
        public const string InvalidPointsFilter = "Los filtros de puntos no pueden ser negativos.";
        public const string InvalidSort = "El orden debe ser \"name\", \"points-asc\" o \"points-desc\".";
        public const string UnexpectedError = "No se pudo completar la operación. Intenta de nuevo.";
    }
}
```

### `Dtos/GoldenProductDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>Un producto del catálogo, para el administrador y para el colaborador.</summary>
    public class GoldenProductDto
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public int CategoryId { get; set; }
        /// <summary>Nombre de la categoría (GoldenProduct.category en el frontend).</summary>
        public string Category { get; set; } = string.Empty;
        public int? PointsCost { get; set; }
        /// <summary>null = sin control de stock.</summary>
        public int? Stock { get; set; }
        /// <summary>0 = sin límite.</summary>
        public int MaxRedemptionsPerUser { get; set; }
        public DateOnly? ExpirationDate { get; set; }
        /// <summary>true = activo (decisión del administrador). GoldenProduct.status en el frontend.</summary>
        public bool Status { get; set; }
        /// <summary>Se puede redimir ahora mismo.</summary>
        public bool Available { get; set; }
        /// <summary>Vacío si está disponible. Ej.: ["Sin stock", "Vencido"].</summary>
        public List<string> UnavailableReasons { get; set; } = [];
        /// <summary>En orden; la primera es la portada.</summary>
        public List<string> ImageUrls { get; set; } = [];
    }

    /// <summary>Crear y editar (formulario "Crear producto").</summary>
    public class SaveGoldenProductDto
    {
        public string? Name { get; set; }
        public string? Description { get; set; }
        public int CategoryId { get; set; }
        public int? PointsCost { get; set; }
        public int? Stock { get; set; }
        /// <summary>null o 0 = sin límite.</summary>
        public int? MaxRedemptionsPerUser { get; set; }
        public DateOnly? ExpirationDate { get; set; }
        public List<string>? ImageUrls { get; set; }
        /// <summary>Interruptor "Producto activo". null = activo.</summary>
        public bool? Status { get; set; }
    }

    /// <summary>Filtros del listado (query string).</summary>
    public class GoldenProductQueryDto
    {
        public int? CategoryId { get; set; }
        /// <summary>true = disponibles, false = no disponibles, null = todos. Solo en el listado del administrador.</summary>
        public bool? Available { get; set; }
        public int? MinPoints { get; set; }
        public int? MaxPoints { get; set; }
        /// <summary>"name" (por defecto), "points-asc", "points-desc".</summary>
        public string? Sort { get; set; }
    }

    public class GoldenProductListDto
    {
        public List<GoldenProductDto> Items { get; set; } = [];
        /// <summary>Total antes de aplicar los filtros: para "3 de 10 productos".</summary>
        public int TotalCount { get; set; }
    }

    /// <summary>Resultado de descontar stock.</summary>
    public class GoldenProductStockDto
    {
        public int ProductId { get; set; }
        /// <summary>null = sin control de stock.</summary>
        public int? Stock { get; set; }
        /// <summary>true si el descuento lo dejó en 0.</summary>
        public bool SoldOut { get; set; }
    }
}
```

### `Helpers/GoldenProductValidator.cs`

```csharp
using System.Text.RegularExpressions;
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    /// <summary>Lo que llega del formulario, ya limpio. Si hubo errores, los valores inválidos quedan en su valor por defecto.</summary>
    public sealed record GoldenProductDraft(
        string Name,
        string? Description,
        int CategoryId,
        int? PointsCost,
        int? Stock,
        int MaxRedemptionsPerUser,
        DateOnly? ExpirationDate,
        IReadOnlyList<string> ImageUrls,
        bool Active);

    public static class GoldenProductValidator
    {
        public static GoldenProductDraft Normalize(SaveGoldenProductDto dto, List<string> errors)
        {
            var name = Regex.Replace(dto.Name?.Trim() ?? string.Empty, @"\s+", " ");
            if (name.Length == 0)
            {
                errors.Add(GoldenProductConstants.NameRequired);
            }
            else if (name.Length > GoldenProductConstants.NameMaxLength)
            {
                errors.Add(GoldenProductConstants.NameTooLong);
            }

            var description = dto.Description?.Trim();
            if (string.IsNullOrEmpty(description))
            {
                description = null;
            }
            else if (description.Length > GoldenProductConstants.DescriptionMaxLength)
            {
                errors.Add(GoldenProductConstants.DescriptionTooLong);
            }

            if (dto.CategoryId <= 0)
            {
                errors.Add(GoldenProductConstants.CategoryRequired);
            }

            if (dto.PointsCost is { } points && (points < 1 || points > GoldenProductConstants.MaxPointsCost))
            {
                errors.Add(GoldenProductConstants.PointsInvalid);
            }

            if (dto.Stock is { } stock && (stock < 0 || stock > GoldenProductConstants.MaxStock))
            {
                errors.Add(GoldenProductConstants.StockInvalid);
            }

            var maxRedemptions = dto.MaxRedemptionsPerUser ?? 0;
            if (maxRedemptions < 0 || maxRedemptions > GoldenProductConstants.MaxRedemptionsPerUserLimit)
            {
                errors.Add(GoldenProductConstants.MaxRedemptionsInvalid);
            }

            var imageUrls = NormalizeImages(dto.ImageUrls, errors);

            return new GoldenProductDraft(
                name,
                description,
                dto.CategoryId,
                dto.PointsCost,
                dto.Stock,
                maxRedemptions,
                dto.ExpirationDate,
                imageUrls,
                dto.Status ?? true);
        }

        /// <summary>Solo https, sin vacías ni repetidas, en el orden en que llegan.</summary>
        private static List<string> NormalizeImages(List<string>? values, List<string> errors)
        {
            var urls = new List<string>();
            var position = 0;

            foreach (var value in values ?? [])
            {
                position++;
                var url = value?.Trim();

                if (string.IsNullOrEmpty(url))
                {
                    continue;
                }

                var valid = url.Length <= GoldenProductConstants.ImageUrlMaxLength
                    && Uri.TryCreate(url, UriKind.Absolute, out var uri)
                    && uri.Scheme == Uri.UriSchemeHttps;

                if (!valid)
                {
                    errors.Add(string.Format(GoldenProductConstants.ImageInvalid, position));
                    continue;
                }

                if (!urls.Contains(url, StringComparer.OrdinalIgnoreCase))
                {
                    urls.Add(url);
                }
            }

            if (urls.Count > GoldenProductConstants.MaxImages)
            {
                errors.Add(GoldenProductConstants.TooManyImages);
            }

            return urls;
        }
    }
}
```

> Solo `https`: una imagen `http` dentro de la aplicación (que corre en `https`) el navegador la bloquea o la marca como contenido inseguro.

### `Helpers/GoldenProductAvailability.cs` ⭐

La **única** definición de "disponible". La usan el listado, el detalle y, más adelante, la redención.

```csharp
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenProductAvailability
    {
        public const string Inactive = "Producto inactivo";
        public const string CategoryInactive = "Categoría inactiva";
        public const string NoPoints = "Sin puntos asignados";
        public const string OutOfStock = "Sin stock";
        public const string Expired = "Vencido";

        /// <summary>"Hoy" en Colombia (UTC-5, sin horario de verano).</summary>
        public static DateOnly Today() => DateOnly.FromDateTime(DateTime.UtcNow.AddHours(-5));

        /// <summary>Motivos por los que no se puede redimir. Lista vacía = disponible.</summary>
        public static List<string> UnavailableReasons(GoldenProduct product, bool categoryActive, DateOnly today)
        {
            var reasons = new List<string>();

            if (!product.Active)
            {
                reasons.Add(Inactive);
            }

            if (!categoryActive)
            {
                reasons.Add(CategoryInactive);
            }

            if (product.PointsCost is null)
            {
                reasons.Add(NoPoints);
            }

            // Regla: con stock en 0 el producto queda no disponible. null = sin control de stock.
            if (product.Stock is 0)
            {
                reasons.Add(OutOfStock);
            }

            // Se puede redimir hasta el final del día de expiración.
            if (product.ExpirationDate is { } expiration && expiration < today)
            {
                reasons.Add(Expired);
            }

            return reasons;
        }
    }
}
```

### `Helpers/GoldenProductStock.cs` ⭐

La regla para descontar stock, separada del servicio para que la **redención** la use dentro de **su propia** transacción (sección 8, nota de `DecreaseStockAsync`).

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenProductStock
    {
        /// <summary>
        /// Descuenta del stock de un producto que viene CON seguimiento.
        /// Stock null = sin control: no cambia nada. Nunca deja el stock negativo.
        /// </summary>
        public static bool TryDecrease(GoldenProduct product, int quantity, out string? error)
        {
            if (quantity <= 0)
            {
                error = GoldenProductConstants.QuantityInvalid;
                return false;
            }

            if (product.Stock is null)
            {
                error = null;
                return true;
            }

            if (product.Stock < quantity)
            {
                error = string.Format(GoldenProductConstants.InsufficientStock, product.Stock);
                return false;
            }

            product.Stock -= quantity;
            error = null;
            return true;
        }
    }
}
```

### `Helpers/GoldenProductMapper.cs`

```csharp
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Features.GoldenPoints.Application.Helpers
{
    public static class GoldenProductMapper
    {
        public static GoldenProductDto ToDto(
            GoldenProduct product,
            string? categoryName,
            IEnumerable<GoldenProductImage> images,
            IReadOnlyList<string> unavailableReasons) => new()
        {
            Id = product.Id,
            Name = product.Name,
            Description = product.Description ?? string.Empty,
            CategoryId = product.CategoryId,
            Category = categoryName ?? string.Empty,
            PointsCost = product.PointsCost,
            Stock = product.Stock,
            MaxRedemptionsPerUser = product.MaxRedemptionsPerUser,
            ExpirationDate = product.ExpirationDate,
            Status = product.Active,
            Available = unavailableReasons.Count == 0,
            UnavailableReasons = unavailableReasons.ToList(),
            ImageUrls = images.OrderBy(i => i.SortOrder).Select(i => i.Url).ToList(),
        };
    }
}
```

---

## 8. Paso 4 — Servicio

### `Interfaces/IGoldenProductService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;     // ResponseDto<T>
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenProductService
    {
        /// <summary>Administrador: todos los productos, con filtros y motivos de no disponibilidad.</summary>
        Task<ResponseDto<GoldenProductListDto>> GetAllAsync(GoldenProductQueryDto query);

        /// <summary>Colaborador: solo los disponibles para redimir.</summary>
        Task<ResponseDto<GoldenProductListDto>> GetAvailableAsync(GoldenProductQueryDto query);

        Task<ResponseDto<GoldenProductDto>> GetByIdAsync(int id);
        Task<ResponseDto<GoldenProductDto>> CreateAsync(SaveGoldenProductDto dto, string currentUser);
        Task<ResponseDto<GoldenProductDto>> UpdateAsync(int id, SaveGoldenProductDto dto, string currentUser);
        Task<ResponseDto<GoldenProductDto>> SetActiveAsync(int id, bool active, string currentUser);

        /// <summary>
        /// Uso interno (sin controlador): descuenta stock en su propia transacción.
        /// Si el stock queda en 0, el producto pasa a "no disponible".
        /// </summary>
        Task<ResponseDto<GoldenProductStockDto>> DecreaseStockAsync(int productId, int quantity, string performedBy);
    }
}
```

### `Services/GoldenProductService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore; // DbUpdateConcurrencyException

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenProductService(ITransactionExecutorHelper transactionHelper) : IGoldenProductService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        /// <summary>Un producto con su categoría y el resultado de la regla de disponibilidad.</summary>
        private sealed record CatalogRow(GoldenProduct Product, GoldenProductCategory? Category, List<string> Reasons)
        {
            public bool Available => Reasons.Count == 0;
        }

        // ── Listados ────────────────────────────────────────────────────

        public Task<ResponseDto<GoldenProductListDto>> GetAllAsync(GoldenProductQueryDto query) =>
            ListAsync(query, onlyAvailable: false);

        public Task<ResponseDto<GoldenProductListDto>> GetAvailableAsync(GoldenProductQueryDto query) =>
            ListAsync(query, onlyAvailable: true);

        private async Task<ResponseDto<GoldenProductListDto>> ListAsync(GoldenProductQueryDto query, bool onlyAvailable)
        {
            var errors = ValidateQuery(query, out var sort);
            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductListDto>(errors);
            }

            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenProductListDto>>(
                async unitOfWork =>
                {
                    // Catálogo pequeño: se lee completo y se filtra en memoria (ver sección 2).
                    var products = await unitOfWork.Repository<GoldenProduct>().ListAllAsync();
                    var categories = (await unitOfWork.Repository<GoldenProductCategory>().ListAllAsync())
                        .ToDictionary(c => c.Id);
                    var today = GoldenProductAvailability.Today();

                    var rows = products
                        .Select(p =>
                        {
                            var category = categories.GetValueOrDefault(p.CategoryId);
                            return new CatalogRow(p, category, GoldenProductAvailability.UnavailableReasons(p, category?.Active ?? false, today));
                        })
                        .ToList();

                    var scope = onlyAvailable ? rows.Where(r => r.Available).ToList() : rows;
                    IEnumerable<CatalogRow> filtered = scope;

                    if (query.CategoryId is { } categoryId)
                    {
                        filtered = filtered.Where(r => r.Product.CategoryId == categoryId);
                    }

                    if (!onlyAvailable && query.Available is { } available)
                    {
                        filtered = filtered.Where(r => r.Available == available);
                    }

                    // Un producto sin puntos no entra en un rango de puntos.
                    if (query.MinPoints is { } minPoints)
                    {
                        filtered = filtered.Where(r => r.Product.PointsCost >= minPoints);
                    }

                    if (query.MaxPoints is { } maxPoints)
                    {
                        filtered = filtered.Where(r => r.Product.PointsCost <= maxPoints);
                    }

                    var result = Sort(filtered, sort).ToList();

                    // Imágenes solo de los productos que se devuelven, en una consulta.
                    var ids = result.Select(r => r.Product.Id).ToList();
                    var images = (await unitOfWork.Repository<GoldenProductImage>().GetListAsync(i => ids.Contains(i.ProductId)))
                        .ToLookup(i => i.ProductId);

                    var items = result
                        .Select(r => GoldenProductMapper.ToDto(r.Product, r.Category?.Name, images[r.Product.Id], r.Reasons))
                        .ToList();

                    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenProductListDto
                    {
                        Items = items,
                        TotalCount = scope.Count,
                    });
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductListDto>(GoldenProductConstants.UnexpectedError);
        }

        // ── Detalle ─────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenProductDto>> GetByIdAsync(int id)
        {
            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<GoldenProductDto>>(
                async unitOfWork =>
                {
                    var product = await unitOfWork.Repository<GoldenProduct>().GetByIdAsync(id);
                    if (product is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.ProductNotFound);
                    }

                    var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(product.CategoryId);
                    var images = await unitOfWork.Repository<GoldenProductImage>().GetListAsync(i => i.ProductId == id);
                    var reasons = GoldenProductAvailability.UnavailableReasons(product, category?.Active ?? false, GoldenProductAvailability.Today());

                    return ResponseDtoHelper.CreateSuccessResponseDto(GoldenProductMapper.ToDto(product, category?.Name, images, reasons));
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.UnexpectedError);
        }

        // ── Crear ───────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenProductDto>> CreateAsync(SaveGoldenProductDto dto, string currentUser)
        {
            var errors = new List<string>();
            var draft = GoldenProductValidator.Normalize(dto, errors);

            if (draft.ExpirationDate is { } expiration && expiration < GoldenProductAvailability.Today())
            {
                errors.Add(GoldenProductConstants.ExpirationInPast);
            }

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(errors);
            }

            GoldenProduct? created = null;
            string? categoryName = null;

            var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductDto>>(
                async unitOfWork =>
                {
                    var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(draft.CategoryId);
                    if (category is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.CategoryNotFound);
                    }

                    if (!category.Active)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.CategoryInactive);
                    }

                    var products = unitOfWork.Repository<GoldenProduct>();
                    if (await products.AnyAsync(p => p.Name == draft.Name))
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.NameTaken);
                    }

                    var now = DateTime.UtcNow;
                    categoryName = category.Name;
                    created = new GoldenProduct
                    {
                        CategoryId = draft.CategoryId,
                        Name = draft.Name,
                        Description = draft.Description,
                        PointsCost = draft.PointsCost,
                        Stock = draft.Stock,
                        MaxRedemptionsPerUser = draft.MaxRedemptionsPerUser,
                        ExpirationDate = draft.ExpirationDate,
                        Active = draft.Active,
                        CreatedDate = now,
                        CreatedBy = currentUser,
                        // Las imágenes se insertan junto con el producto, en el mismo guardado.
                        Images = draft.ImageUrls
                            .Select((url, index) => new GoldenProductImage { Url = url, SortOrder = index, CreatedDate = now })
                            .ToList(),
                    };

                    await products.AddAsync(created);
                    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenProductDto());
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.UnexpectedError);

            if (created is null || response.HasError)
            {
                return response;
            }

            // Aquí el helper ya guardó: el producto y sus imágenes tienen su Id real.
            var reasons = GoldenProductAvailability.UnavailableReasons(created, categoryActive: true, GoldenProductAvailability.Today());
            return ResponseDtoHelper.CreateSuccessResponseDto(GoldenProductMapper.ToDto(created, categoryName, created.Images, reasons));
        }

        // ── Editar ──────────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenProductDto>> UpdateAsync(int id, SaveGoldenProductDto dto, string currentUser)
        {
            var errors = new List<string>();
            var draft = GoldenProductValidator.Normalize(dto, errors);

            if (errors.Count > 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(errors);
            }

            try
            {
                return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductDto>>(
                    async unitOfWork =>
                    {
                        var products = unitOfWork.Repository<GoldenProduct>();

                        // Con seguimiento: se guarda solo lo que cambie, y row_version protege del stock que cambie al mismo tiempo.
                        var product = await products.GetByIdAsync(id);
                        if (product is null)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.ProductNotFound);
                        }

                        var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(draft.CategoryId);
                        if (category is null)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.CategoryNotFound);
                        }

                        // Moverlo a una categoría inactiva no; quedarse en la suya aunque se haya inactivado, sí.
                        if (draft.CategoryId != product.CategoryId && !category.Active)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.CategoryInactive);
                        }

                        var today = GoldenProductAvailability.Today();
                        if (draft.ExpirationDate != product.ExpirationDate && draft.ExpirationDate is { } expiration && expiration < today)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.ExpirationInPast);
                        }

                        if (await products.AnyAsync(p => p.Name == draft.Name && p.Id != id))
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.NameTaken);
                        }

                        var now = DateTime.UtcNow;
                        product.CategoryId = draft.CategoryId;
                        product.Name = draft.Name;
                        product.Description = draft.Description;
                        product.PointsCost = draft.PointsCost;
                        product.Stock = draft.Stock;
                        product.MaxRedemptionsPerUser = draft.MaxRedemptionsPerUser;
                        product.ExpirationDate = draft.ExpirationDate;
                        product.Active = draft.Active;
                        product.UpdatedDate = now;
                        product.UpdatedBy = currentUser;

                        // Imágenes: si la lista cambió (contenido u orden), se reemplazan todas.
                        var imageRepository = unitOfWork.Repository<GoldenProductImage>();
                        var currentImages = (await imageRepository.GetListAsync(i => i.ProductId == id))
                            .OrderBy(i => i.SortOrder)
                            .ToList();

                        var images = currentImages;
                        if (!currentImages.Select(i => i.Url).SequenceEqual(draft.ImageUrls))
                        {
                            foreach (var image in currentImages)
                            {
                                imageRepository.Delete(image);
                            }

                            images = draft.ImageUrls
                                .Select((url, index) => new GoldenProductImage { ProductId = id, Url = url, SortOrder = index, CreatedDate = now })
                                .ToList();

                            await imageRepository.AddRangeAsync(images);
                        }

                        var reasons = GoldenProductAvailability.UnavailableReasons(product, category.Active, today);
                        return ResponseDtoHelper.CreateSuccessResponseDto(GoldenProductMapper.ToDto(product, category.Name, images, reasons));
                    }
                ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.UnexpectedError);
            }
            catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateConcurrencyException)
            {
                // Una redención descontó stock entre la lectura y el guardado.
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.ConcurrentChange);
            }
        }

        // ── Activar / inactivar ─────────────────────────────────────────

        public async Task<ResponseDto<GoldenProductDto>> SetActiveAsync(int id, bool active, string currentUser)
        {
            try
            {
                return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductDto>>(
                    async unitOfWork =>
                    {
                        var product = await unitOfWork.Repository<GoldenProduct>().GetByIdAsync(id);
                        if (product is null)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.ProductNotFound);
                        }

                        if (product.Active != active) // si ya estaba así, no hay nada que guardar
                        {
                            product.Active = active;
                            product.UpdatedDate = DateTime.UtcNow;
                            product.UpdatedBy = currentUser;
                        }

                        var category = await unitOfWork.Repository<GoldenProductCategory>().GetByIdAsync(product.CategoryId);
                        var images = await unitOfWork.Repository<GoldenProductImage>().GetListAsync(i => i.ProductId == id);
                        var reasons = GoldenProductAvailability.UnavailableReasons(product, category?.Active ?? false, GoldenProductAvailability.Today());

                        return ResponseDtoHelper.CreateSuccessResponseDto(GoldenProductMapper.ToDto(product, category?.Name, images, reasons));
                    }
                ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.UnexpectedError);
            }
            catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateConcurrencyException)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductDto>(GoldenProductConstants.ConcurrentChange);
            }
        }

        // ── Mermar stock (uso interno) ──────────────────────────────────

        public async Task<ResponseDto<GoldenProductStockDto>> DecreaseStockAsync(int productId, int quantity, string performedBy)
        {
            if (quantity <= 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductStockDto>(GoldenProductConstants.QuantityInvalid);
            }

            for (var attempt = 1; attempt <= GoldenProductConstants.DecreaseStockAttempts; attempt++)
            {
                try
                {
                    return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenProductStockDto>>(
                        async unitOfWork =>
                        {
                            // Cada llamada al helper abre su propio DbContext: cada intento lee el stock actual.
                            var product = await unitOfWork.Repository<GoldenProduct>().GetByIdAsync(productId);
                            if (product is null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductStockDto>(GoldenProductConstants.ProductNotFound);
                            }

                            if (!GoldenProductStock.TryDecrease(product, quantity, out var error))
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductStockDto>(error!);
                            }

                            if (product.Stock is not null)
                            {
                                product.UpdatedDate = DateTime.UtcNow;
                                product.UpdatedBy = performedBy;
                            }

                            // Con stock en 0, la regla de disponibilidad lo marca "Sin stock" en la siguiente lectura.
                            return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenProductStockDto
                            {
                                ProductId = product.Id,
                                Stock = product.Stock,
                                SoldOut = product.Stock == 0,
                            });
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenProductStockDto>(GoldenProductConstants.UnexpectedError);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateConcurrencyException)
                {
                    // Otra transacción cambió el producto entre la lectura y el guardado (row_version distinto).
                    // Se vuelve a intentar con el stock actualizado.
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenProductStockDto>(GoldenProductConstants.ConcurrentChange);
        }

        // ── Privados ────────────────────────────────────────────────────

        private static List<string> ValidateQuery(GoldenProductQueryDto query, out string sort)
        {
            var errors = new List<string>();
            sort = string.IsNullOrWhiteSpace(query.Sort) ? GoldenProductConstants.SortName : query.Sort.Trim().ToLowerInvariant();

            if (sort is not (GoldenProductConstants.SortName or GoldenProductConstants.SortPointsAsc or GoldenProductConstants.SortPointsDesc))
            {
                errors.Add(GoldenProductConstants.InvalidSort);
            }

            if (query.MinPoints < 0 || query.MaxPoints < 0)
            {
                errors.Add(GoldenProductConstants.InvalidPointsFilter);
            }

            if (query.MinPoints > query.MaxPoints)
            {
                errors.Add(GoldenProductConstants.InvalidPointsRange);
            }

            return errors;
        }

        /// <summary>Los productos sin puntos van al final cuando se ordena por puntos.</summary>
        private static IEnumerable<CatalogRow> Sort(IEnumerable<CatalogRow> rows, string sort) => sort switch
        {
            GoldenProductConstants.SortPointsAsc => rows
                .OrderBy(r => r.Product.PointsCost is null)
                .ThenBy(r => r.Product.PointsCost)
                .ThenBy(r => r.Product.Name),
            GoldenProductConstants.SortPointsDesc => rows
                .OrderBy(r => r.Product.PointsCost is null)
                .ThenByDescending(r => r.Product.PointsCost)
                .ThenBy(r => r.Product.Name),
            _ => rows.OrderBy(r => r.Product.Name),
        };
    }
}
```

**Notas del servicio**

- **Crear y el `Id`.** Dentro de la lambda el producto todavía no tiene `Id`, así que esa respuesta es provisional. El DTO real se arma afuera, después de que el helper guarda (convención del proyecto).
- **Imágenes al editar.** Se usa `Delete(entity)` por cada imagen, **no** `DeleteRangeAsync`, porque ese método guarda por su cuenta y rompe la regla de "el helper guarda al final".
- **`DbUpdateConcurrencyException`.** El helper envuelve los errores de guardado en `InvalidOperationException`, así que el servicio revisa `InnerException`. Requiere `using Microsoft.EntityFrameworkCore;`, que la capa de aplicación ya usa en el helper.
- **Descontar stock desde la redención (cuando exista).** La redención va a descontar puntos, crear el registro de redención y bajar el stock **en una sola transacción**. Para eso no debe llamar a `DecreaseStockAsync`, que abre su propia transacción. Debe usar la regla directamente dentro de **su** lambda:

  ```csharp
  // Dentro del ExecuteWithTransactionAsync de la redención
  var product = await unitOfWork.Repository<GoldenProduct>().GetByIdAsync(productId); // con seguimiento
  var reasons = GoldenProductAvailability.UnavailableReasons(product!, categoryActive, GoldenProductAvailability.Today());
  if (reasons.Count > 0) { return ResponseDtoHelper.CreateErrorResponseDto<…>(string.Join(", ", reasons)); }
  if (!GoldenProductStock.TryDecrease(product!, quantity, out var error)) { return ResponseDtoHelper.CreateErrorResponseDto<…>(error!); }
  // … descontar puntos, validar MaxRedemptionsPerUser, guardar la redención …
  ```

  `row_version` también protege esa transacción. `DecreaseStockAsync` queda para usos sueltos (ajustes, pruebas, otros procesos).

---

## 9. Paso 5 — Controlador

### `Common/ApiResponseConstants.cs` ✏️

```csharp
public const string GoldenProductsErrorMessage = "No se pudo completar la operación con el catálogo de productos.";
```

### `Controllers/GoldenProductsController.cs`

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: catálogo de productos. DecreaseStock no se expone: lo usa la redención.</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class GoldenProductsController(IGoldenProductService service) : ControllerBase
    {
        private readonly IGoldenProductService _service = service;

        /// <summary>Administrador. GET ?categoryId=&available=&minPoints=&maxPoints=&sort=name|points-asc|points-desc</summary>
        [HttpGet]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetAll([FromQuery] GoldenProductQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetAllAsync(query);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenProductsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductsErrorMessage });
            }
        }

        /// <summary>Colaborador: solo productos disponibles. GET available?categoryId=&minPoints=&maxPoints=&sort=</summary>
        [HttpGet("available")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> GetAvailable([FromQuery] GoldenProductQueryDto query)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetAvailableAsync(query);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenProductsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductsErrorMessage });
            }
        }

        /// <summary>Cualquier usuario autenticado (también el enlace desde comunicaciones).</summary>
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
                return BadRequest(new { message = ApiResponseConstants.GoldenProductsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductsErrorMessage });
            }
        }

        // ⬇ Escrituras (y GetAll) con el permiso de administración de Puntos Dorados
        //   (agrega el atributo o la política que usan tus otros controladores).

        [HttpPost]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Create([FromBody] SaveGoldenProductDto dto)
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
                return BadRequest(new { message = ApiResponseConstants.GoldenProductsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductsErrorMessage });
            }
        }

        [HttpPut("{id:int}")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Update(int id, [FromBody] SaveGoldenProductDto dto)
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
                return BadRequest(new { message = ApiResponseConstants.GoldenProductsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductsErrorMessage });
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
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenProductsErrorMessage });
            }
        }
    }
}
```

### Registro — `ApplicationServiceRegistration.cs`

```csharp
services.AddScoped<IGoldenProductService, GoldenProductService>();
```

Nada en `InfrastructureServiceRegistration.cs`.

> **Firmas del repositorio genérico usadas:** `ListAllAsync()`, `GetListAsync(predicado)`, `GetByIdAsync(id)` (con seguimiento), `AnyAsync(predicado)`, `AddAsync`, `AddRangeAsync` y `Delete(entidad)`. Si alguna tiene otro nombre en tu `IGenericRepository<T>`, ajusta solo esa línea.

---

## 10. Contrato (para el frontend)

Todas las respuestas: `{ response, hasError, errors }`. Errores de negocio con HTTP 200 y `hasError: true`; `401` sin usuario; `500` error no controlado.

| Método | Ruta | Quién | Cuerpo / query | `response` |
|---|---|---|---|---|
| `GET` | `/api/GoldenProducts` | Admin | `?categoryId=2&available=false&minPoints=100&maxPoints=300&sort=points-desc` | `{ items: GoldenProductDto[], totalCount }` |
| `GET` | `/api/GoldenProducts/available` | Cualquiera | `?categoryId=&minPoints=&maxPoints=&sort=` | Solo disponibles |
| `GET` | `/api/GoldenProducts/{id}` | Cualquiera | — | `GoldenProductDto` |
| `POST` | `/api/GoldenProducts` | Admin | `SaveGoldenProductDto` | Producto creado, con su `id` |
| `PUT` | `/api/GoldenProducts/{id}` | Admin | `SaveGoldenProductDto` | Producto actualizado |
| `PATCH` | `/api/GoldenProducts/{id}/inactivate` | Admin | — | `status: false` |
| `PATCH` | `/api/GoldenProducts/{id}/activate` | Admin | — | `status: true` |

Filtros de la pantalla → parámetros:

| Pantalla | Parámetro |
|---|---|
| "Todas las categorías" | sin `categoryId` |
| Disponibles / No disponibles | `available=true` / `available=false` |
| "Orden: Sin ordenar" / por puntos | `sort=name` (o nada) / `points-asc` / `points-desc` |
| Puntos min / max | `minPoints` / `maxPoints` |
| "3 de 3 productos" | `items.length` de `totalCount` |

Crear:

```json
POST /api/GoldenProducts
{
  "name": "Kit Wellness Premium",
  "description": "Set de bienestar con termos, antifaz y aceites esenciales.",
  "categoryId": 1,
  "pointsCost": 180,
  "stock": 25,
  "maxRedemptionsPerUser": 2,
  "expirationDate": "2026-12-31",
  "imageUrls": [
    "https://cdn.empresa.com/catalogo/kit-wellness-1.jpg",
    "https://cdn.empresa.com/catalogo/kit-wellness-2.jpg"
  ],
  "status": true
}
```

Respuesta (también la forma de cada ítem del listado):

```json
{
  "response": {
    "id": 4,
    "name": "Kit Wellness Premium",
    "description": "Set de bienestar con termos, antifaz y aceites esenciales.",
    "categoryId": 1,
    "category": "Bienestar",
    "pointsCost": 180,
    "stock": 25,
    "maxRedemptionsPerUser": 2,
    "expirationDate": "2026-12-31",
    "status": true,
    "available": true,
    "unavailableReasons": [],
    "imageUrls": [
      "https://cdn.empresa.com/catalogo/kit-wellness-1.jpg",
      "https://cdn.empresa.com/catalogo/kit-wellness-2.jpg"
    ]
  },
  "hasError": false,
  "errors": []
}
```

Producto agotado en el listado del administrador:

```json
{ "id": 2, "name": "Gift Card Experiencia", "stock": 0, "status": true, "available": false, "unavailableReasons": ["Sin stock"], "…": "…" }
```

**Cambios que necesitará el modelo del frontend** (`GoldenProduct` en `puntos-dorados.ts`), cuando se haga la pantalla:

- `categoryId: number` (además de `category`).
- `pointsCost: number | null` y `stock: number | null`.
- `imageUrls: string[]` en lugar de una sola imagen.
- `maxRedemptionsPerUser: number` y `expirationDate: string | null`.
- `available: boolean` y `unavailableReasons: string[]`.

---

## 11. Pruebas

**Crear y editar**
- Crear y revisar que la respuesta traiga el `id` real (no `0`) y las imágenes en orden.
- Crear sin `pointsCost` → se guarda, con `available: false` y `["Sin puntos asignados"]`.
- Crear sin `stock` → `stock: null`, disponible (ilimitado).
- Crear en una categoría inactiva → `hasError`; editar un producto cuya categoría se inactivó, sin cambiarla → se guarda, con `["Categoría inactiva"]`.
- Nombre repetido → `hasError`.
- `imageUrls` con `http://…`, vacías y repetidas → las vacías y repetidas se ignoran; la `http` da error. Más de 10 → error.
- `expirationDate` de ayer al crear → error; editar un producto ya vencido sin tocar la fecha → se guarda, con `["Vencido"]`.
- Editar cambiando solo el orden de las imágenes → se reemplazan y quedan en el orden nuevo.

**Stock**
- `DecreaseStockAsync(id, 1)` con `stock = 1` → `stock: 0`, `soldOut: true`; el listado lo muestra con `["Sin stock"]` y `available=true` ya no lo trae.
- `DecreaseStockAsync(id, 5)` con `stock = 3` → `hasError` "Stock insuficiente: quedan 3 unidades"; el stock no cambia.
- `DecreaseStockAsync` con `stock = null` → éxito, `stock: null`.
- **Concurrencia:** dos llamadas simultáneas con `stock = 1` (por ejemplo, dos pestañas o una prueba con `Task.WhenAll`) → una deja `stock = 0` y la otra responde "Stock insuficiente". Nunca queda en `-1`.
- Editar el producto desde la pantalla mientras se descuenta stock → si chocan, `hasError` con el mensaje de "el producto cambió".

**Listados**
- `available=false` → solo no disponibles, cada uno con sus motivos.
- `minPoints=200&maxPoints=300` → solo productos con puntos en ese rango; los que no tienen puntos no aparecen.
- `sort=points-desc` → mayor a menor, los que no tienen puntos al final.
- `/available` como colaborador → nunca aparece un inactivo, agotado, vencido o sin puntos.
- `minPoints=500&maxPoints=100` o `sort=precio` → `hasError`.

---

## ✅ Checklist

- [ ] `GoldenPointsProducts.sql` ejecutado después de `GoldenPointsCategories.sql`.
- [ ] Entidades `GoldenProduct` y `GoldenProductImage` sin `BaseEntity`; `RowVersion` con `IsRowVersion()`.
- [ ] Configuraciones en `Configurations/` y dos `DbSet` en `DOCCbDbContext`.
- [ ] Reglas en `GoldenProductAvailability` y `GoldenProductStock` (una sola definición de "disponible").
- [ ] `CreateAsync` vuelve a mapear después del helper.
- [ ] Imágenes reemplazadas con `Delete` + `AddRangeAsync` (no `DeleteRangeAsync`).
- [ ] `DecreaseStockAsync` registrado en el servicio, sin endpoint.
- [ ] `GoldenProductsController` con el patrón de Request; permiso de administración en `GetAll`, `POST`, `PUT` y `PATCH`.
- [ ] `IGoldenProductService` registrado en `ApplicationServiceRegistration.cs`.
- [ ] Prueba de concurrencia del stock hecha.
