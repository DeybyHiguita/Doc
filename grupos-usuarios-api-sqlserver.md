# 👥 Grupos de usuarios — API (.NET 8) y base de datos (SQL Server)

Guía paso a paso para el backend de la página **Grupos de usuarios** en DOCCB. Un grupo se arma de tres formas, y se pueden combinar:

1. **Por líder:** se escribe el correo de uno o varios managers y se traen sus equipos desde Microsoft Graph.
2. **Persona por persona:** se busca por nombre o correo en el maestro de usuarios (`dbo.users`) y en el directorio (Graph) al mismo tiempo.
3. **Pegando una lista de correos:** se validan todos de una vez.

Cada integrante se relaciona con el maestro por `corporative_email`. Si la persona no está en el maestro pero sí en el directorio, también se acepta, marcada como **"solo directorio"**.

La pantalla está en [grupos-usuarios-angular.md](grupos-usuarios-angular.md).

- **Stack:** .NET 8 · ASP.NET Core · EF Core 8 · SQL Server · Microsoft Graph SDK v5
- **Base de datos:** `DB` · esquema `dbo` · nombres en inglés y `snake_case`

---

## 1. 🧐 Decisiones de diseño

| # | Tema | Decisión |
|---|---|---|
| 1 | **¿Cómo se identifica a un integrante?** Puede venir del maestro, del directorio o de ambos. | La llave dentro del grupo es el **correo normalizado** (minúsculas). Se guardan además `user_id` (si está en `dbo.users`) y `entra_object_id` (si vino del directorio). La base de datos exige al menos uno de los dos. |
| 2 | **Orden de búsqueda.** | Primero el maestro por `corporative_email`, como pediste. Solo los que no aparecen se buscan en Graph. Así la mayoría de validaciones no sale de SQL Server. |
| 3 | **El correo en el directorio puede ser otro.** Si alguien pega el UPN (`jperez@empresa.onmicrosoft.com`) y en el maestro está el correo (`juan.perez@empresa.com`), no coincidirían. | Graph busca por `mail` y, si no aparece, por `userPrincipalName`. Con el correo principal que devuelve, se vuelve a mirar el maestro. |
| 4 | **Equipo del líder: ¿directos o todos los niveles?** | Por defecto solo los **directos**. Una casilla permite traer **todos los niveles**, con un tope de 2.000 personas y 10 niveles para no recorrer media empresa por error. |
| 5 | **¿El grupo se actualiza solo cuando el líder cambia de equipo?** | **No.** El grupo es una **foto** del momento en que se guardó: predecible y sin sorpresas. Se guarda qué líderes se usaron (`user_group_manager`) para poder agregar después un botón "Actualizar equipos". |
| 6 | **No confiar en el cliente.** El navegador podría enviar un `userId` o un id del directorio que no corresponde al correo. | Al guardar, el backend vuelve a resolver cada correo contra el maestro. Los "solo directorio" se verifican en Graph con `getByIds` (hasta 1.000 por llamada) y el correo que devuelve Graph tiene que coincidir. |
| 7 | **Cuentas deshabilitadas en Entra ID.** | No se agregan. En la validación aparecen como **"deshabilitado"**, separadas de "no encontrado". |
| 8 | **Graph caído o limitando peticiones.** | La búsqueda de personas sigue funcionando solo con el maestro. Validar correos y traer equipos responden `503` con un mensaje claro, en lugar de marcar a todos como "no encontrados". |
| 9 | **Borrado.** Un grupo puede quedar referenciado más adelante (por ejemplo, por cursos). | Borrado lógico (`removed = 1`). El nombre se puede reutilizar después. |
| 10 | **Permisos de Graph.** | `User.Read.All` de **aplicación**, con consentimiento de administrador. El navegador nunca llama a Graph para esto. |

---

## 2. 🔄 Cómo se resuelve un correo

```text
 correo pegado ─► normalizar (trim + minúsculas + formato)
                     │
                     ├─ inválido ─────────────────────────────► "INVALID"
                     ▼
            dbo.users.corporative_email ── encontrado ───────► integrante del MAESTRO (user_id)
                     │ no
                     ▼
         Graph: mail in (…) → userPrincipalName in (…)
                     │
                     ├─ no aparece ───────────────────────────► "NOT_FOUND"
                     ├─ accountEnabled = false ───────────────► "DISABLED"
                     ▼
         ¿el correo principal de Graph está en el maestro?
                     ├─ sí ──────────────────────────────────► MAESTRO (user_id + entra_object_id)
                     └─ no ──────────────────────────────────► SOLO DIRECTORIO (entra_object_id)
```

---

## 3. 📁 Archivos

```text
DOCCB.Domain/
├── Entities/
│   ├── UserGroup.cs
│   ├── UserGroupManager.cs
│   └── UserGroupMember.cs
└── Enum/
    └── MemberAddedVia.cs

DOCCB.Application/
├── Contracts/Persistence/
│   ├── IUserGroupRepository.cs                     ⭐ contrato de datos de grupos
│   ├── IUserSearchRepository.cs                    ✏️ + búsqueda por correos (de la guía de cursos)
│   └── DuplicateKeyException.cs                    (de la guía de cursos)
├── Features/Common/Application/DTOs/
│   └── ServiceResult.cs                            resultado + 404 / 409 / 400 / 503
├── Features/Directory/Application/                  ⭐ Microsoft Graph
│   ├── DTOs/DirectoryUser.cs
│   ├── Exceptions/DirectoryUnavailableException.cs
│   ├── Interfaces/IGraphDirectoryService.cs
│   └── Services/GraphDirectoryService.cs
└── Features/UserGroups/Application/
    ├── Constants/UserGroupConstants.cs
    ├── DTOs/                                       listado, detalle, guardar, candidatos, validación
    ├── Helpers/EmailNormalizer.cs
    ├── Interfaces/
    │   ├── IUserDirectoryResolver.cs
    │   └── IUserGroupService.cs
    └── Services/
        ├── UserDirectoryResolver.cs                ⭐ maestro + directorio → un solo resultado
        └── UserGroupService.cs                     ⭐ reglas de negocio

DOCCB.Infraestructure/
├── Configurations/
│   ├── UserGroupConfiguration.cs
│   ├── UserGroupManagerConfiguration.cs
│   └── UserGroupMemberConfiguration.cs
├── Persistence/Scripts SQL/UserGroups.sql          ⭐ creación de tablas
└── Repositories/
    ├── UserGroupRepository.cs
    └── UserSearchRepository.cs                     ✏️ + búsqueda por correos

WebApp/
├── Common/Helper/ControllerExtensions.cs           usuario actual + ServiceResult → HTTP
└── Controllers/UserGroupsController.cs             ⭐ /api/user-groups
```

---

## 4. Paso 1 — 🗄️ Base de datos

### Modelo

```text
dbo.user_group ──< dbo.user_group_manager      (líderes usados para armar el grupo)
      │
      └────────< dbo.user_group_member ─────── user_id ──► dbo.users (maestro)
                   email (llave en el grupo)
                   entra_object_id ───────────────────────► Entra ID (directorio)
```

| Tabla | Qué guarda |
|---|---|
| `dbo.user_group` | Nombre, descripción y auditoría del grupo. |
| `dbo.user_group_manager` | Los líderes con los que se armó el grupo y si se trajeron todos los niveles. |
| `dbo.user_group_member` | Los integrantes: correo, nombre, de dónde vienen (`user_id`, `entra_object_id`) y cómo llegaron (`added_via`). |

### `Persistence/Scripts SQL/UserGroups.sql`

```sql
/* =====================================================================
   Grupos de usuarios
   Base de datos: DB · Esquema: dbo
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.user_group
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.user_group', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.user_group
    (
        id           INT            IDENTITY(1, 1) NOT NULL,
        name         NVARCHAR(120)  NOT NULL,
        description  NVARCHAR(500)  NULL,
        removed      BIT            NOT NULL CONSTRAINT df_user_group_removed DEFAULT (0),
        created_date DATETIME2(0)   NOT NULL CONSTRAINT df_user_group_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)  NOT NULL,
        updated_date DATETIME2(0)   NULL,
        updated_by   NVARCHAR(150)  NULL,

        CONSTRAINT pk_user_group PRIMARY KEY CLUSTERED (id),
        CONSTRAINT ck_user_group_name CHECK (LEN(LTRIM(name)) > 0)
    );

    -- Nombre único entre grupos activos: uno eliminado libera su nombre.
    CREATE UNIQUE INDEX ux_user_group_name
        ON dbo.user_group (name)
        WHERE removed = 0;
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.user_group_manager — líderes usados para armar el grupo
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.user_group_manager', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.user_group_manager
    (
        group_id           INT              NOT NULL,
        email              NVARCHAR(256)    NOT NULL,
        display_name       NVARCHAR(256)    NOT NULL,
        entra_object_id    UNIQUEIDENTIFIER NOT NULL,
        include_all_levels BIT              NOT NULL,
        created_date       DATETIME2(0)     NOT NULL CONSTRAINT df_user_group_manager_created_date DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT pk_user_group_manager PRIMARY KEY CLUSTERED (group_id, email),
        CONSTRAINT fk_user_group_manager_group
            FOREIGN KEY (group_id) REFERENCES dbo.user_group (id) ON DELETE CASCADE
    );
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   dbo.user_group_member — integrantes
   ───────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.user_group_member', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.user_group_member
    (
        group_id        INT              NOT NULL,
        email           NVARCHAR(256)    NOT NULL,
        display_name    NVARCHAR(256)    NOT NULL,
        job_title       NVARCHAR(256)    NULL,
        user_id         INT              NULL,
        entra_object_id UNIQUEIDENTIFIER NULL,
        added_via       VARCHAR(20)      NOT NULL,
        manager_email   NVARCHAR(256)    NULL,
        created_date    DATETIME2(0)     NOT NULL CONSTRAINT df_user_group_member_created_date DEFAULT (SYSUTCDATETIME()),
        created_by      NVARCHAR(150)    NOT NULL,

        CONSTRAINT pk_user_group_member PRIMARY KEY CLUSTERED (group_id, email),
        CONSTRAINT fk_user_group_member_group
            FOREIGN KEY (group_id) REFERENCES dbo.user_group (id) ON DELETE CASCADE,
        CONSTRAINT fk_user_group_member_user
            FOREIGN KEY (user_id) REFERENCES dbo.users (id),
        -- Cada integrante existe en el maestro, en el directorio o en ambos.
        CONSTRAINT ck_user_group_member_identity CHECK (user_id IS NOT NULL OR entra_object_id IS NOT NULL),
        CONSTRAINT ck_user_group_member_added_via CHECK (added_via IN ('MANAGER', 'INDIVIDUAL', 'BULK')),
        -- Si llegó por un líder, se sabe cuál.
        CONSTRAINT ck_user_group_member_manager CHECK (added_via <> 'MANAGER' OR manager_email IS NOT NULL)
    );

    -- "¿En qué grupos está esta persona?"
    CREATE INDEX ix_user_group_member_user_id
        ON dbo.user_group_member (user_id)
        WHERE user_id IS NOT NULL;

    CREATE INDEX ix_user_group_member_entra_object_id
        ON dbo.user_group_member (entra_object_id)
        WHERE entra_object_id IS NOT NULL;
END;
GO

/* ─────────────────────────────────────────────────────────────────────
   Maestro: índice por correo corporativo.
   Cada validación busca por este campo; sin índice, recorre toda la tabla.
   ───────────────────────────────────────────────────────────────────── */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.users') AND name = N'ix_users_corporative_email')
    CREATE INDEX ix_users_corporative_email ON dbo.users (corporative_email);
GO
```

> ⚠️ Antes de ejecutar, revisa si en `dbo.users` hay correos corporativos **repetidos**. Si los hay, la búsqueda por correo encuentra dos personas y el sistema no sabe con cuál relacionar el grupo:
>
> ```sql
> SELECT LOWER(corporative_email) AS email, COUNT(*) AS total
> FROM   dbo.users
> WHERE  corporative_email IS NOT NULL
> GROUP BY LOWER(corporative_email)
> HAVING COUNT(*) > 1;
> ```
>
> Si no hay repetidos, conviene convertir el índice en **único** para que no aparezcan después.

### Consultas de verificación

```sql
-- Grupos activos con cuántos integrantes tienen y cuántos no están en el maestro
SELECT  g.id,
        g.name,
        members        = COUNT(m.email),
        directory_only = SUM(CASE WHEN m.user_id IS NULL THEN 1 ELSE 0 END),
        managers       = (SELECT COUNT(*) FROM dbo.user_group_manager gm WHERE gm.group_id = g.id)
FROM    dbo.user_group g
LEFT JOIN dbo.user_group_member m ON m.group_id = g.id
WHERE   g.removed = 0
GROUP BY g.id, g.name
ORDER BY g.name;

-- Personas en grupos que no existen en el maestro (candidatas a cargar en dbo.users)
SELECT DISTINCT m.email, m.display_name
FROM   dbo.user_group_member m
JOIN   dbo.user_group g ON g.id = m.group_id AND g.removed = 0
WHERE  m.user_id IS NULL
ORDER BY m.display_name;
```

---

## 5. Paso 2 — Dominio

### `DOCCB.Domain/Enum/MemberAddedVia.cs`

```csharp
namespace DOCCB.Domain.Enum;

/// <summary>Cómo llegó el integrante al grupo.</summary>
public enum MemberAddedVia
{
    Manager = 1,
    Individual = 2,
    Bulk = 3
}
```

### `DOCCB.Domain/Entities/UserGroup.cs`

```csharp
namespace DOCCB.Domain.Entities;

public class UserGroup : BaseEntity
{
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool Removed { get; set; }

    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? UpdatedDate { get; set; }
    public string? UpdatedBy { get; set; }

    public ICollection<UserGroupManager> Managers { get; set; } = new List<UserGroupManager>();
    public ICollection<UserGroupMember> Members { get; set; } = new List<UserGroupMember>();
}
```

### `DOCCB.Domain/Entities/UserGroupManager.cs`

```csharp
namespace DOCCB.Domain.Entities;

public class UserGroupManager
{
    public int GroupId { get; set; }
    public string Email { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public Guid EntraObjectId { get; set; }
    public bool IncludeAllLevels { get; set; }
    public DateTime CreatedDate { get; set; }

    public UserGroup Group { get; set; } = null!;
}
```

### `DOCCB.Domain/Entities/UserGroupMember.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities;

public class UserGroupMember
{
    public int GroupId { get; set; }
    public string Email { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? JobTitle { get; set; }

    /// <summary>Id en dbo.users. null = la persona solo está en el directorio.</summary>
    public int? UserId { get; set; }

    /// <summary>Object id de Entra ID, si vino del directorio.</summary>
    public Guid? EntraObjectId { get; set; }

    public MemberAddedVia AddedVia { get; set; }
    public string? ManagerEmail { get; set; }

    public DateTime CreatedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;

    public UserGroup Group { get; set; } = null!;
    public User? User { get; set; }
}
```

> Igual que en cursos: si `BaseEntity` o `TrazabilityEntity` ya traen `Removed` o la auditoría, hereda de ellas y borra aquí lo repetido.

---

## 6. Paso 3 — Configuración de EF Core

### `DOCCB.Infraestructure/Configurations/UserGroupConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class UserGroupConfiguration : IEntityTypeConfiguration<UserGroup>
{
    public const string NameIndex = "ux_user_group_name";

    public void Configure(EntityTypeBuilder<UserGroup> builder)
    {
        builder.ToTable("user_group", "dbo", table =>
            table.HasCheckConstraint("ck_user_group_name", "LEN(LTRIM(name)) > 0"));

        builder.HasKey(g => g.Id).HasName("pk_user_group");

        builder.Property(g => g.Id).HasColumnName("id");
        builder.Property(g => g.Name).HasColumnName("name").HasMaxLength(120).IsRequired();
        builder.Property(g => g.Description).HasColumnName("description").HasMaxLength(500);
        builder.Property(g => g.Removed).HasColumnName("removed");
        builder.Property(g => g.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(g => g.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();
        builder.Property(g => g.UpdatedDate).HasColumnName("updated_date").HasColumnType("datetime2(0)");
        builder.Property(g => g.UpdatedBy).HasColumnName("updated_by").HasMaxLength(150);

        builder.HasIndex(g => g.Name)
            .IsUnique()
            .HasFilter("[removed] = 0")
            .HasDatabaseName(NameIndex);

        builder.HasMany(g => g.Managers)
            .WithOne(m => m.Group)
            .HasForeignKey(m => m.GroupId)
            .HasConstraintName("fk_user_group_manager_group")
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasMany(g => g.Members)
            .WithOne(m => m.Group)
            .HasForeignKey(m => m.GroupId)
            .HasConstraintName("fk_user_group_member_group")
            .OnDelete(DeleteBehavior.Cascade);
    }
}
```

### `DOCCB.Infraestructure/Configurations/UserGroupManagerConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class UserGroupManagerConfiguration : IEntityTypeConfiguration<UserGroupManager>
{
    public void Configure(EntityTypeBuilder<UserGroupManager> builder)
    {
        builder.ToTable("user_group_manager", "dbo");

        builder.HasKey(m => new { m.GroupId, m.Email }).HasName("pk_user_group_manager");

        builder.Property(m => m.GroupId).HasColumnName("group_id");
        builder.Property(m => m.Email).HasColumnName("email").HasMaxLength(256);
        builder.Property(m => m.DisplayName).HasColumnName("display_name").HasMaxLength(256).IsRequired();
        builder.Property(m => m.EntraObjectId).HasColumnName("entra_object_id");
        builder.Property(m => m.IncludeAllLevels).HasColumnName("include_all_levels");
        builder.Property(m => m.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
    }
}
```

### `DOCCB.Infraestructure/Configurations/UserGroupMemberConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations;

public class UserGroupMemberConfiguration : IEntityTypeConfiguration<UserGroupMember>
{
    public void Configure(EntityTypeBuilder<UserGroupMember> builder)
    {
        builder.ToTable("user_group_member", "dbo", table =>
        {
            table.HasCheckConstraint("ck_user_group_member_identity", "user_id IS NOT NULL OR entra_object_id IS NOT NULL");
            table.HasCheckConstraint("ck_user_group_member_added_via", "added_via IN ('MANAGER', 'INDIVIDUAL', 'BULK')");
            table.HasCheckConstraint("ck_user_group_member_manager", "added_via <> 'MANAGER' OR manager_email IS NOT NULL");
        });

        builder.HasKey(m => new { m.GroupId, m.Email }).HasName("pk_user_group_member");

        builder.Property(m => m.GroupId).HasColumnName("group_id");
        builder.Property(m => m.Email).HasColumnName("email").HasMaxLength(256);
        builder.Property(m => m.DisplayName).HasColumnName("display_name").HasMaxLength(256).IsRequired();
        builder.Property(m => m.JobTitle).HasColumnName("job_title").HasMaxLength(256);
        builder.Property(m => m.UserId).HasColumnName("user_id");
        builder.Property(m => m.EntraObjectId).HasColumnName("entra_object_id");
        builder.Property(m => m.ManagerEmail).HasColumnName("manager_email").HasMaxLength(256);
        builder.Property(m => m.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
        builder.Property(m => m.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();

        builder.Property(m => m.AddedVia)
            .HasColumnName("added_via")
            .HasMaxLength(20)
            .IsUnicode(false)
            .HasConversion(
                via => via.ToString().ToUpperInvariant(),
                code => Enum.Parse<MemberAddedVia>(code, true));

        builder.HasIndex(m => m.UserId).HasFilter("[user_id] IS NOT NULL").HasDatabaseName("ix_user_group_member_user_id");
        builder.HasIndex(m => m.EntraObjectId).HasFilter("[entra_object_id] IS NOT NULL").HasDatabaseName("ix_user_group_member_entra_object_id");

        builder.HasOne(m => m.User)
            .WithMany()
            .HasForeignKey(m => m.UserId)
            .HasConstraintName("fk_user_group_member_user")
            .OnDelete(DeleteBehavior.Restrict);
    }
}
```

### Registro en `DOCCbDbContext.cs`

```csharp
modelBuilder.ApplyConfiguration(new UserGroupConfiguration());
modelBuilder.ApplyConfiguration(new UserGroupManagerConfiguration());
modelBuilder.ApplyConfiguration(new UserGroupMemberConfiguration());
```

---

## 7. Paso 4 — Resultado de servicio compartido

Mismo patrón que `CourseResult` de la guía de cursos, pero en `Common` para que lo usen todas las features. Si ya creaste `CourseResult`, puedes reemplazarlo por este.

### `Features/Common/Application/DTOs/ServiceResult.cs`

```csharp
using DOCCB.Application.Features.Common.Application.Helpers;

namespace DOCCB.Application.Features.Common.Application.DTOs;

public enum ServiceResultStatus
{
    Ok,
    Invalid,
    NotFound,
    Conflict,
    /// <summary>Un servicio externo (Graph) no respondió.</summary>
    Unavailable
}

public sealed class ServiceResult<T>
{
    public ServiceResultStatus Status { get; }
    public ResponseDto<T> Response { get; }

    private ServiceResult(ServiceResultStatus status, ResponseDto<T> response)
    {
        Status = status;
        Response = response;
    }

    public static ServiceResult<T> Ok(T value) =>
        new(ServiceResultStatus.Ok, ResponseDtoHelper.CreateSuccessResponseDto(value));

    public static ServiceResult<T> Fail(ServiceResultStatus status, IEnumerable<string> errors) =>
        new(status, ResponseDtoHelper.CreateErrorResponseDto<T>(errors.ToList()));

    public static ServiceResult<T> Fail(ServiceResultStatus status, string error) =>
        Fail(status, [error]);
}
```

---

## 8. Paso 5 — Constantes, DTOs y normalización de correos

### `Constants/UserGroupConstants.cs`

```csharp
namespace DOCCB.Application.Features.UserGroups.Application.Constants;

public static class UserGroupConstants
{
    public const int NameMaxLength = 120;
    public const int DescriptionMaxLength = 500;
    public const int EmailMaxLength = 256;

    public const int MaxMembersPerGroup = 5000;
    public const int MaxManagersPerGroup = 50;
    public const int MaxEmailsPerValidation = 1000;
    public const int MaxManagersPerSearch = 20;
    public const int MaxTeamSize = 2000;

    public const int SearchMinLength = 2;
    public const int SearchMaxResults = 10;
    public const int DefaultPageSize = 10;
    public const int MaxPageSize = 50;

    public const string GroupNotFound = "El grupo no existe o fue eliminado.";
    public const string DuplicateName = "Ya existe un grupo con ese nombre.";
    public const string DirectoryUnavailable =
        "El directorio de Microsoft no responde en este momento. Intenta de nuevo en unos minutos.";
}

/// <summary>Motivos por los que un correo no se pudo agregar. Viajan como texto al frontend.</summary>
public static class UnresolvedReasons
{
    public const string Invalid = "INVALID";
    public const string NotFound = "NOT_FOUND";
    public const string Disabled = "DISABLED";
}
```

### `DTOs/MemberCandidateDto.cs`

```csharp
namespace DOCCB.Application.Features.UserGroups.Application.DTOs;

/// <summary>Una persona encontrada en el maestro, en el directorio o en ambos.</summary>
public record MemberCandidateDto
{
    public string Email { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public string? JobTitle { get; init; }

    /// <summary>Id en dbo.users. null = solo está en el directorio.</summary>
    public int? UserId { get; init; }

    public Guid? EntraObjectId { get; init; }

    public bool InDoccb => UserId is not null;
}

/// <summary>Integrante ya dentro de un grupo: el candidato más cómo llegó.</summary>
public record GroupMemberDto : MemberCandidateDto
{
    public string AddedVia { get; init; } = string.Empty;
    public string? ManagerEmail { get; init; }
}

public record UnresolvedEmailDto(string Email, string Reason);
```

### `DTOs/UserGroupDtos.cs`

```csharp
namespace DOCCB.Application.Features.UserGroups.Application.DTOs;

// ── Listado ─────────────────────────────────────────────────────────
public class UserGroupQueryDto
{
    public string? Search { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 10;
}

public sealed record UserGroupListQuery(string? Search, int Page, int PageSize);

public class UserGroupListItemDto
{
    public int GroupId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int MembersCount { get; set; }
    public int DirectoryOnlyCount { get; set; }
    public int ManagersCount { get; set; }
    public DateTime UpdatedDate { get; set; }
}

public class UserGroupPageDto
{
    public List<UserGroupListItemDto> Items { get; set; } = [];
    public int TotalCount { get; set; }
}

// ── Detalle ─────────────────────────────────────────────────────────
public class GroupManagerDto
{
    public string Email { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public bool IncludeAllLevels { get; set; }
}

public class UserGroupDetailDto
{
    public int GroupId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public List<GroupManagerDto> Managers { get; set; } = [];
    public List<GroupMemberDto> Members { get; set; } = [];
}

// ── Guardar ─────────────────────────────────────────────────────────
public class SaveUserGroupRequestDto
{
    public string? Name { get; set; }
    public string? Description { get; set; }
    public List<SaveGroupManagerDto> Managers { get; set; } = [];
    public List<SaveGroupMemberDto> Members { get; set; } = [];
}

public class SaveGroupManagerDto
{
    public string? Email { get; set; }
    public bool IncludeAllLevels { get; set; }
}

/// <summary>
/// El cliente solo envía el correo y cómo llegó la persona.
/// El backend vuelve a resolver la identidad: no confía en el userId del navegador.
/// </summary>
public class SaveGroupMemberDto
{
    public string? Email { get; set; }
    /// <summary>Solo se usa para verificar a los que no están en el maestro.</summary>
    public string? EntraObjectId { get; set; }
    public string? AddedVia { get; set; }
    public string? ManagerEmail { get; set; }
}

// ── Validar correos y traer equipos ─────────────────────────────────
public class ResolveEmailsRequestDto
{
    public List<string> Emails { get; set; } = [];
}

public class EmailResolutionDto
{
    public List<MemberCandidateDto> Found { get; set; } = [];
    public List<UnresolvedEmailDto> Unresolved { get; set; } = [];
}

public class ManagerTeamsRequestDto
{
    public List<string> ManagerEmails { get; set; } = [];
    public bool IncludeAllLevels { get; set; }
}

public class ManagerTeamDto
{
    public MemberCandidateDto Manager { get; set; } = new();
    public List<MemberCandidateDto> Members { get; set; } = [];
    /// <summary>true si el equipo superó el tope y se cortó.</summary>
    public bool Truncated { get; set; }
}

public class ManagerTeamsResultDto
{
    public List<ManagerTeamDto> Teams { get; set; } = [];
    public List<UnresolvedEmailDto> Unresolved { get; set; } = [];
}
```

### `Helpers/EmailNormalizer.cs`

```csharp
using System.Net.Mail;
using System.Text.RegularExpressions;
using DOCCB.Application.Features.UserGroups.Application.Constants;

namespace DOCCB.Application.Features.UserGroups.Application.Helpers;

public static partial class EmailNormalizer
{
    [GeneratedRegex(@"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$")]
    private static partial Regex Shape();

    /// <summary>Recorta, pasa a minúsculas y valida. "Ana@Empresa.com " → "ana@empresa.com".</summary>
    public static bool TryNormalize(string? raw, out string email)
    {
        email = raw?.Trim().Trim('<', '>', '"', '\'').ToLowerInvariant() ?? string.Empty;

        return email.Length is > 0 and <= UserGroupConstants.EmailMaxLength
            && Shape().IsMatch(email)
            && MailAddress.TryCreate(email, out var parsed)
            && string.Equals(parsed.Address, email, StringComparison.OrdinalIgnoreCase);
    }
}
```

---

## 9. Paso 6 — 🔷 Microsoft Graph

### `Features/Directory/Application/DTOs/DirectoryUser.cs`

```csharp
namespace DOCCB.Application.Features.Directory.Application.DTOs;

/// <summary>Usuario de Entra ID. Email = correo principal (mail, o el UPN si no tiene).</summary>
public sealed record DirectoryUser(string Email, string DisplayName, string? JobTitle, Guid EntraObjectId, bool AccountEnabled);

public sealed record DirectoryTeam(IReadOnlyList<DirectoryUser> Members, bool Truncated);
```

### `Features/Directory/Application/Exceptions/DirectoryUnavailableException.cs`

```csharp
namespace DOCCB.Application.Features.Directory.Application.Exceptions;

/// <summary>Graph falló, limitó peticiones o no respondió. El servicio la traduce a 503.</summary>
public sealed class DirectoryUnavailableException(Exception inner)
    : Exception("El directorio de Microsoft no está disponible.", inner);
```

### `Features/Directory/Application/Interfaces/IGraphDirectoryService.cs`

```csharp
using DOCCB.Application.Features.Directory.Application.DTOs;

namespace DOCCB.Application.Features.Directory.Application.Interfaces;

public interface IGraphDirectoryService
{
    /// <summary>Clave = correo pedido (minúsculas). Busca por mail y luego por UPN.</summary>
    Task<IReadOnlyDictionary<string, DirectoryUser>> FindByEmailsAsync(IReadOnlyCollection<string> emails, CancellationToken ct);

    /// <summary>Colaboradores del líder: directos, o todos los niveles hasta maxMembers.</summary>
    Task<DirectoryTeam> GetTeamAsync(Guid managerId, bool includeAllLevels, int maxMembers, CancellationToken ct);

    /// <summary>Busca por nombre o correo. Solo cuentas habilitadas.</summary>
    Task<IReadOnlyList<DirectoryUser>> SearchAsync(string term, int top, CancellationToken ct);

    /// <summary>Verifica ids del directorio en bloque (hasta 1.000 por llamada).</summary>
    Task<IReadOnlyDictionary<Guid, DirectoryUser>> GetByIdsAsync(IReadOnlyCollection<Guid> ids, CancellationToken ct);
}
```

### `Features/Directory/Application/Services/GraphDirectoryService.cs`

```csharp
using DOCCB.Application.Features.Directory.Application.DTOs;
using DOCCB.Application.Features.Directory.Application.Exceptions;
using DOCCB.Application.Features.Directory.Application.Interfaces;
using Microsoft.Graph;
using Microsoft.Graph.DirectoryObjects.GetByIds;
using Microsoft.Graph.Models;
using Microsoft.Graph.Models.ODataErrors;

namespace DOCCB.Application.Features.Directory.Application.Services;

public class GraphDirectoryService(GraphServiceClient graph) : IGraphDirectoryService
{
    private static readonly string[] UserFields =
        ["id", "displayName", "mail", "userPrincipalName", "jobTitle", "accountEnabled"];

    /// <summary>Graph admite hasta 15 valores dentro de un "in" en $filter.</summary>
    private const int InClauseLimit = 15;

    private const int GetByIdsLimit = 1000;
    private const int MaxHierarchyDepth = 10;

    public Task<IReadOnlyDictionary<string, DirectoryUser>> FindByEmailsAsync(
        IReadOnlyCollection<string> emails, CancellationToken ct) => GuardAsync(async () =>
    {
        var found = new Dictionary<string, DirectoryUser>(StringComparer.OrdinalIgnoreCase);

        foreach (var chunk in emails.Chunk(InClauseLimit))
        {
            await CollectAsync($"mail in ({ToODataList(chunk)})", u => u.Mail, found, ct);

            // Los que no aparecieron por mail se buscan por UPN.
            var pending = chunk.Where(email => !found.ContainsKey(email)).ToArray();
            if (pending.Length > 0)
            {
                await CollectAsync($"userPrincipalName in ({ToODataList(pending)})", u => u.UserPrincipalName, found, ct);
            }
        }

        return (IReadOnlyDictionary<string, DirectoryUser>)found;
    });

    public Task<DirectoryTeam> GetTeamAsync(Guid managerId, bool includeAllLevels, int maxMembers, CancellationToken ct) =>
        GuardAsync(async () =>
        {
            var members = new List<DirectoryUser>();
            var visited = new HashSet<Guid> { managerId }; // protege de ciclos por datos mal cargados
            var pending = new Queue<(Guid Id, int Depth)>([(managerId, 1)]);
            var truncated = false;

            while (pending.Count > 0 && !truncated)
            {
                var (currentId, depth) = pending.Dequeue();

                var page = await graph.Users[currentId.ToString()].DirectReports.GraphUser.GetAsync(
                    request => request.QueryParameters.Select = UserFields, ct);

                if (page is null) continue;

                var iterator = PageIterator<User, UserCollectionResponse>.CreatePageIterator(graph, page, user =>
                {
                    if (ToDirectoryUser(user) is not { } report || !visited.Add(report.EntraObjectId))
                        return true;

                    if (report.AccountEnabled)
                        members.Add(report);

                    if (members.Count >= maxMembers)
                    {
                        truncated = true;
                        return false; // detiene la paginación
                    }

                    // Aunque la cuenta esté deshabilitada, su equipo sí se recorre.
                    if (includeAllLevels && depth < MaxHierarchyDepth)
                        pending.Enqueue((report.EntraObjectId, depth + 1));

                    return true;
                });

                await iterator.IterateAsync(ct);
            }

            return new DirectoryTeam(members, truncated);
        });

    public Task<IReadOnlyList<DirectoryUser>> SearchAsync(string term, int top, CancellationToken ct) =>
        GuardAsync(async () =>
        {
            // Las comillas rompen la sintaxis de $search.
            var safe = term.Replace("\"", string.Empty).Trim();

            var response = await graph.Users.GetAsync(request =>
            {
                request.QueryParameters.Search = $"\"displayName:{safe}\" OR \"mail:{safe}\"";
                request.QueryParameters.Select = UserFields;
                request.QueryParameters.Top = top;
                request.Headers.Add("ConsistencyLevel", "eventual"); // obligatorio para $search
            }, ct);

            return (IReadOnlyList<DirectoryUser>)(response?.Value ?? [])
                .Select(ToDirectoryUser)
                .OfType<DirectoryUser>()
                .Where(user => user.AccountEnabled)
                .ToList();
        });

    public Task<IReadOnlyDictionary<Guid, DirectoryUser>> GetByIdsAsync(IReadOnlyCollection<Guid> ids, CancellationToken ct) =>
        GuardAsync(async () =>
        {
            var found = new Dictionary<Guid, DirectoryUser>();

            foreach (var chunk in ids.Chunk(GetByIdsLimit))
            {
                var response = await graph.DirectoryObjects.GetByIds.PostAsGetByIdsPostResponseAsync(
                    new GetByIdsPostRequestBody
                    {
                        Ids = chunk.Select(id => id.ToString()).ToList(),
                        Types = ["user"],
                    },
                    cancellationToken: ct);

                foreach (var user in response?.Value?.OfType<User>() ?? [])
                {
                    if (ToDirectoryUser(user) is { } directoryUser)
                        found[directoryUser.EntraObjectId] = directoryUser;
                }
            }

            return (IReadOnlyDictionary<Guid, DirectoryUser>)found;
        });

    // ── Privados ────────────────────────────────────────────────────

    private async Task CollectAsync(
        string filter, Func<User, string?> matchedBy, Dictionary<string, DirectoryUser> found, CancellationToken ct)
    {
        var response = await graph.Users.GetAsync(request =>
        {
            request.QueryParameters.Filter = filter;
            request.QueryParameters.Select = UserFields;
            request.QueryParameters.Top = InClauseLimit;
        }, ct);

        foreach (var user in response?.Value ?? [])
        {
            if (matchedBy(user) is { } requested && ToDirectoryUser(user) is { } directoryUser)
                found[requested.ToLowerInvariant()] = directoryUser;
        }
    }

    private static DirectoryUser? ToDirectoryUser(User user)
    {
        var email = (user.Mail ?? user.UserPrincipalName)?.ToLowerInvariant();
        if (email is null || !Guid.TryParse(user.Id, out var id)) return null;

        // getByIds no devuelve accountEnabled: si no viene, se asume habilitada.
        return new DirectoryUser(email, user.DisplayName ?? email, user.JobTitle, id, user.AccountEnabled ?? true);
    }

    /// <summary>'a@x.com','b@x.com' con las comillas simples escapadas.</summary>
    private static string ToODataList(IEnumerable<string> values) =>
        string.Join(",", values.Select(value => $"'{value.Replace("'", "''")}'"));

    /// <summary>Convierte cualquier falla de Graph en DirectoryUnavailableException.</summary>
    private static async Task<T> GuardAsync<T>(Func<Task<T>> action)
    {
        try
        {
            return await action();
        }
        catch (ODataError ex)
        {
            throw new DirectoryUnavailableException(ex);
        }
        catch (HttpRequestException ex)
        {
            throw new DirectoryUnavailableException(ex);
        }
    }
}
```

> **Antes de programar, prueba las consultas en Graph Explorer** (`https://aka.ms/ge`):
>
> ```http
> GET /v1.0/users?$filter=mail in ('ana@empresa.com','juan@empresa.com')&$select=id,displayName,mail,accountEnabled
> GET /v1.0/users/{id}/directReports/microsoft.graph.user?$select=id,displayName,mail,jobTitle,accountEnabled
> ```
>
> Si el `$filter` con `in` devuelve error en tu tenant, cambia a varias condiciones `mail eq '…' or mail eq '…'`: el resto del código no cambia.

---

## 10. Paso 7 — Maestro de usuarios: búsqueda por correos

Se agregan dos métodos a `IUserSearchRepository` (creado en la guía de cursos).

### `Contracts/Persistence/IUserSearchRepository.cs` ✏️

```csharp
using DOCCB.Application.Features.Users.Application.DTOs;

namespace DOCCB.Application.Contracts.Persistence;

/// <summary>Persona encontrada en dbo.users.</summary>
public sealed record LocalUserMatch(int UserId, string Email, string DisplayName);

public interface IUserSearchRepository
{
    Task<List<UserSearchResultDto>> SearchAsync(string term, int top, CancellationToken ct);

    /// <summary>Busca por users.corporative_email. Una sola consulta, sin importar cuántos correos.</summary>
    Task<IReadOnlyList<LocalUserMatch>> FindByEmailsAsync(IReadOnlyCollection<string> emails, CancellationToken ct);

    /// <summary>Busca por nombre o correo, con el id numérico.</summary>
    Task<IReadOnlyList<LocalUserMatch>> SearchMatchesAsync(string term, int top, CancellationToken ct);
}
```

### `Repositories/UserSearchRepository.cs` ✏️

```csharp
public async Task<IReadOnlyList<LocalUserMatch>> FindByEmailsAsync(IReadOnlyCollection<string> emails, CancellationToken ct)
{
    if (emails.Count == 0) return [];

    // EF Core 8 envía la lista como un solo parámetro JSON (OPENJSON): no hay tope de 2.100 parámetros.
    return await db.Set<User>()
        .AsNoTracking()
        .Where(u => emails.Contains(u.CorportativeEmail)) // + filtro de "usuario activo" de tu entidad
        .Select(u => new LocalUserMatch(u.Id, u.CorportativeEmail.ToLower(), u.DisplayName))
        .ToListAsync(ct);
}

public async Task<IReadOnlyList<LocalUserMatch>> SearchMatchesAsync(string term, int top, CancellationToken ct) =>
    await db.Set<User>()
        .AsNoTracking()
        .Where(u => u.DisplayName.Contains(term) || u.CorportativeEmail.Contains(term)) // + filtro de activos
        .OrderBy(u => u.DisplayName)
        .Take(top)
        .Select(u => new LocalUserMatch(u.Id, u.CorportativeEmail.ToLower(), u.DisplayName))
        .ToListAsync(ct);
```

> La columna es `corporative_email`; en la entidad C# la propiedad se llama `CorportativeEmail` (así está en el código actual). La comparación no distingue mayúsculas porque la intercalación de SQL Server por defecto es `CI`.
>
> Que EF Core 8 envíe la lista como JSON requiere nivel de compatibilidad **130 o superior** en la base de datos (SQL Server 2016+). Compruébalo con `SELECT compatibility_level FROM sys.databases WHERE name = 'DB';`.

---

## 11. Paso 8 — ⭐ El resolvedor: maestro + directorio

Une las dos fuentes en un solo resultado. Lo usan la validación de correos, los equipos por líder y la búsqueda de personas.

### `Interfaces/IUserDirectoryResolver.cs`

```csharp
using DOCCB.Application.Features.UserGroups.Application.DTOs;

namespace DOCCB.Application.Features.UserGroups.Application.Interfaces;

public interface IUserDirectoryResolver
{
    Task<EmailResolutionDto> ResolveEmailsAsync(IEnumerable<string?> rawEmails, CancellationToken ct);
    Task<ManagerTeamsResultDto> GetManagerTeamsAsync(IEnumerable<string?> managerEmails, bool includeAllLevels, CancellationToken ct);
    Task<List<MemberCandidateDto>> SearchAsync(string term, CancellationToken ct);
}
```

### `Services/UserDirectoryResolver.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Directory.Application.DTOs;
using DOCCB.Application.Features.Directory.Application.Exceptions;
using DOCCB.Application.Features.Directory.Application.Interfaces;
using DOCCB.Application.Features.UserGroups.Application.Constants;
using DOCCB.Application.Features.UserGroups.Application.DTOs;
using DOCCB.Application.Features.UserGroups.Application.Helpers;
using DOCCB.Application.Features.UserGroups.Application.Interfaces;
using Microsoft.Extensions.Logging;

namespace DOCCB.Application.Features.UserGroups.Application.Services;

public class UserDirectoryResolver(
    IUserSearchRepository localUsers,
    IGraphDirectoryService directory,
    ILogger<UserDirectoryResolver> logger) : IUserDirectoryResolver
{
    public async Task<EmailResolutionDto> ResolveEmailsAsync(IEnumerable<string?> rawEmails, CancellationToken ct)
    {
        var (emails, unresolved) = Normalize(rawEmails);
        var (found, disabled) = await ResolveAsync(emails, ct);

        foreach (var email in emails.Where(email => !found.ContainsKey(email)))
        {
            unresolved.Add(new UnresolvedEmailDto(
                email, disabled.Contains(email) ? UnresolvedReasons.Disabled : UnresolvedReasons.NotFound));
        }

        return new EmailResolutionDto
        {
            // Dos correos pedidos (mail y UPN) pueden ser la misma persona.
            Found = found.Values.DistinctBy(candidate => candidate.Email).ToList(),
            Unresolved = unresolved,
        };
    }

    public async Task<ManagerTeamsResultDto> GetManagerTeamsAsync(
        IEnumerable<string?> managerEmails, bool includeAllLevels, CancellationToken ct)
    {
        var (emails, unresolved) = Normalize(managerEmails);
        var managers = await directory.FindByEmailsAsync(emails, ct);
        var teams = new List<(DirectoryUser Manager, DirectoryTeam Team)>();

        foreach (var email in emails)
        {
            if (!managers.TryGetValue(email, out var manager))
            {
                unresolved.Add(new UnresolvedEmailDto(email, UnresolvedReasons.NotFound));
                continue;
            }

            var team = await directory.GetTeamAsync(
                manager.EntraObjectId, includeAllLevels, UserGroupConstants.MaxTeamSize, ct);
            teams.Add((manager, team));
        }

        // Una sola consulta al maestro para vincular a todos los integrantes de todos los equipos.
        var allEmails = teams
            .SelectMany(t => t.Team.Members.Select(m => m.Email).Append(t.Manager.Email))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        var local = await LocalByEmailAsync(allEmails, ct);

        return new ManagerTeamsResultDto
        {
            Teams = teams.Select(t => new ManagerTeamDto
            {
                Manager = Merge(t.Manager, local),
                Members = t.Team.Members.Select(m => Merge(m, local)).OrderBy(m => m.DisplayName).ToList(),
                Truncated = t.Team.Truncated,
            }).ToList(),
            Unresolved = unresolved,
        };
    }

    public async Task<List<MemberCandidateDto>> SearchAsync(string term, CancellationToken ct)
    {
        var top = UserGroupConstants.SearchMaxResults;
        var merged = new Dictionary<string, MemberCandidateDto>(StringComparer.OrdinalIgnoreCase);

        foreach (var match in await localUsers.SearchMatchesAsync(term, top, ct))
        {
            merged[match.Email] = FromLocal(match);
        }

        try
        {
            foreach (var user in await directory.SearchAsync(term, top, ct))
            {
                merged[user.Email] = merged.TryGetValue(user.Email, out var existing)
                    ? existing with { EntraObjectId = user.EntraObjectId, JobTitle = existing.JobTitle ?? user.JobTitle }
                    : FromDirectory(user);
            }
        }
        catch (DirectoryUnavailableException ex)
        {
            // Si Graph falla, la búsqueda sigue funcionando con el maestro.
            logger.LogWarning(ex, "Búsqueda de personas sin directorio: Graph no respondió.");
        }

        return merged.Values.OrderBy(c => c.DisplayName).Take(top).ToList();
    }

    // ── Núcleo ──────────────────────────────────────────────────────

    /// <summary>
    /// Clave del resultado = correo pedido. 1) maestro · 2) Graph para los que faltan ·
    /// 3) maestro otra vez con el correo principal que devolvió Graph.
    /// </summary>
    private async Task<(Dictionary<string, MemberCandidateDto> Found, HashSet<string> Disabled)> ResolveAsync(
        IReadOnlyCollection<string> emails, CancellationToken ct)
    {
        var found = new Dictionary<string, MemberCandidateDto>(StringComparer.OrdinalIgnoreCase);
        var disabled = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (emails.Count == 0) return (found, disabled);

        foreach (var match in await localUsers.FindByEmailsAsync(emails, ct))
        {
            found[match.Email] = FromLocal(match);
        }

        var pending = emails.Where(email => !found.ContainsKey(email)).ToList();
        if (pending.Count == 0) return (found, disabled);

        var fromDirectory = await directory.FindByEmailsAsync(pending, ct);
        var local = await LocalByEmailAsync(fromDirectory.Values.Select(user => user.Email).ToList(), ct);

        foreach (var (requested, user) in fromDirectory)
        {
            if (!user.AccountEnabled)
            {
                disabled.Add(requested);
                continue;
            }

            found[requested] = Merge(user, local);
        }

        return (found, disabled);
    }

    private async Task<Dictionary<string, LocalUserMatch>> LocalByEmailAsync(List<string> emails, CancellationToken ct) =>
        (await localUsers.FindByEmailsAsync(emails, ct))
            .DistinctBy(match => match.Email)
            .ToDictionary(match => match.Email, StringComparer.OrdinalIgnoreCase);

    private static (List<string> Emails, List<UnresolvedEmailDto> Invalid) Normalize(IEnumerable<string?> raw)
    {
        var emails = new List<string>();
        var invalid = new List<UnresolvedEmailDto>();

        foreach (var value in raw)
        {
            if (EmailNormalizer.TryNormalize(value, out var email))
                emails.Add(email);
            else if (!string.IsNullOrWhiteSpace(value))
                invalid.Add(new UnresolvedEmailDto(value.Trim(), UnresolvedReasons.Invalid));
        }

        return (emails.Distinct().ToList(), invalid);
    }

    /// <summary>Persona del directorio: si también está en el maestro, se vincula con su user_id.</summary>
    private static MemberCandidateDto Merge(DirectoryUser user, IReadOnlyDictionary<string, LocalUserMatch> local) =>
        local.TryGetValue(user.Email, out var match)
            ? FromLocal(match) with { EntraObjectId = user.EntraObjectId, JobTitle = user.JobTitle }
            : FromDirectory(user);

    private static MemberCandidateDto FromLocal(LocalUserMatch match) => new()
    {
        Email = match.Email.ToLowerInvariant(),
        DisplayName = match.DisplayName,
        UserId = match.UserId,
    };

    private static MemberCandidateDto FromDirectory(DirectoryUser user) => new()
    {
        Email = user.Email,
        DisplayName = user.DisplayName,
        JobTitle = user.JobTitle,
        EntraObjectId = user.EntraObjectId,
    };
}
```

---

## 12. Paso 9 — Repositorio de grupos

### `Contracts/Persistence/IUserGroupRepository.cs`

```csharp
using DOCCB.Application.Features.UserGroups.Application.DTOs;
using DOCCB.Domain.Entities;

namespace DOCCB.Application.Contracts.Persistence;

public interface IUserGroupRepository
{
    Task<UserGroupPageDto> GetPageAsync(UserGroupListQuery query, CancellationToken ct);
    Task<UserGroupDetailDto?> GetDetailAsync(int groupId, CancellationToken ct);
    Task<bool> NameExistsAsync(string name, int? excludeGroupId, CancellationToken ct);

    /// <summary>Grupo con seguimiento, con líderes e integrantes.</summary>
    Task<UserGroup?> GetForUpdateAsync(int groupId, CancellationToken ct);
    void Add(UserGroup group);
    void Remove<TEntity>(TEntity entity) where TEntity : class;

    /// <summary>Lanza DuplicateKeyException si el índice de nombre rechaza.</summary>
    Task SaveChangesAsync(CancellationToken ct);
}
```

### `Repositories/UserGroupRepository.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.UserGroups.Application.DTOs;
using DOCCB.Domain.Entities;
using DOCCB.Infraestructure.Configurations;
using DOCCB.Infraestructure.Persistence.Models;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace DOCCB.Infraestructure.Repositories;

public class UserGroupRepository(DOCCbDbContext db) : IUserGroupRepository
{
    public async Task<UserGroupPageDto> GetPageAsync(UserGroupListQuery query, CancellationToken ct)
    {
        var groups = db.Set<UserGroup>().AsNoTracking().Where(g => !g.Removed);

        if (query.Search is { Length: > 0 } term)
        {
            groups = groups.Where(g => g.Name.Contains(term) || (g.Description != null && g.Description.Contains(term)));
        }

        var total = await groups.CountAsync(ct);

        var items = await groups
            .OrderByDescending(g => g.UpdatedDate ?? g.CreatedDate)
            .ThenBy(g => g.Id)
            .Skip((query.Page - 1) * query.PageSize)
            .Take(query.PageSize)
            .Select(g => new UserGroupListItemDto
            {
                GroupId = g.Id,
                Name = g.Name,
                Description = g.Description,
                MembersCount = g.Members.Count,
                DirectoryOnlyCount = g.Members.Count(m => m.UserId == null),
                ManagersCount = g.Managers.Count,
                UpdatedDate = g.UpdatedDate ?? g.CreatedDate,
            })
            .ToListAsync(ct);

        return new UserGroupPageDto { Items = items, TotalCount = total };
    }

    public async Task<UserGroupDetailDto?> GetDetailAsync(int groupId, CancellationToken ct)
    {
        var group = await db.Set<UserGroup>()
            .AsNoTracking()
            .Where(g => g.Id == groupId && !g.Removed)
            .Select(g => new
            {
                g.Id,
                g.Name,
                g.Description,
                Managers = g.Managers
                    .OrderBy(m => m.DisplayName)
                    .Select(m => new GroupManagerDto { Email = m.Email, DisplayName = m.DisplayName, IncludeAllLevels = m.IncludeAllLevels })
                    .ToList(),
                Members = g.Members
                    .OrderBy(m => m.DisplayName)
                    .Select(m => new { m.Email, m.DisplayName, m.JobTitle, m.UserId, m.EntraObjectId, m.AddedVia, m.ManagerEmail })
                    .ToList(),
            })
            .AsSplitQuery()
            .FirstOrDefaultAsync(ct);

        if (group is null) return null;

        return new UserGroupDetailDto
        {
            GroupId = group.Id,
            Name = group.Name,
            Description = group.Description,
            Managers = group.Managers,
            Members = group.Members.Select(m => new GroupMemberDto
            {
                Email = m.Email,
                DisplayName = m.DisplayName,
                JobTitle = m.JobTitle,
                UserId = m.UserId,
                EntraObjectId = m.EntraObjectId,
                AddedVia = m.AddedVia.ToString().ToUpperInvariant(),
                ManagerEmail = m.ManagerEmail,
            }).ToList(),
        };
    }

    public Task<bool> NameExistsAsync(string name, int? excludeGroupId, CancellationToken ct) =>
        db.Set<UserGroup>().AnyAsync(g =>
            !g.Removed && g.Name == name && (excludeGroupId == null || g.Id != excludeGroupId), ct);

    public Task<UserGroup?> GetForUpdateAsync(int groupId, CancellationToken ct) =>
        db.Set<UserGroup>()
            .Include(g => g.Managers)
            .Include(g => g.Members)
            .AsSplitQuery()
            .FirstOrDefaultAsync(g => g.Id == groupId && !g.Removed, ct);

    public void Add(UserGroup group) => db.Set<UserGroup>().Add(group);

    public void Remove<TEntity>(TEntity entity) where TEntity : class => db.Remove(entity);

    public async Task SaveChangesAsync(CancellationToken ct)
    {
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (ex.InnerException is SqlException { Number: 2601 or 2627 } sql)
        {
            var index = sql.Message.Contains(UserGroupConfiguration.NameIndex) ? UserGroupConfiguration.NameIndex : "desconocido";
            throw new DuplicateKeyException(index, ex);
        }
    }
}
```

---

## 13. Paso 10 — ⭐ El servicio de grupos

### `Interfaces/IUserGroupService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.UserGroups.Application.DTOs;

namespace DOCCB.Application.Features.UserGroups.Application.Interfaces;

public interface IUserGroupService
{
    Task<ServiceResult<UserGroupPageDto>> GetPageAsync(UserGroupQueryDto query, CancellationToken ct = default);
    Task<ServiceResult<UserGroupDetailDto>> GetByIdAsync(int id, CancellationToken ct = default);
    Task<ServiceResult<int>> CreateAsync(SaveUserGroupRequestDto dto, string currentUser, CancellationToken ct = default);
    Task<ServiceResult<bool>> UpdateAsync(int id, SaveUserGroupRequestDto dto, string currentUser, CancellationToken ct = default);
    Task<ServiceResult<bool>> DeleteAsync(int id, string currentUser, CancellationToken ct = default);

    Task<ServiceResult<EmailResolutionDto>> ResolveEmailsAsync(ResolveEmailsRequestDto dto, CancellationToken ct = default);
    Task<ServiceResult<ManagerTeamsResultDto>> GetManagerTeamsAsync(ManagerTeamsRequestDto dto, CancellationToken ct = default);
    Task<ServiceResult<List<MemberCandidateDto>>> SearchPeopleAsync(string? term, CancellationToken ct = default);
}
```

### `Services/UserGroupService.cs`

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Directory.Application.DTOs;
using DOCCB.Application.Features.Directory.Application.Exceptions;
using DOCCB.Application.Features.Directory.Application.Interfaces;
using DOCCB.Application.Features.UserGroups.Application.Constants;
using DOCCB.Application.Features.UserGroups.Application.DTOs;
using DOCCB.Application.Features.UserGroups.Application.Helpers;
using DOCCB.Application.Features.UserGroups.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;

namespace DOCCB.Application.Features.UserGroups.Application.Services;

public class UserGroupService(
    IUserGroupRepository repository,
    IUserSearchRepository localUsers,
    IGraphDirectoryService directory,
    IUserDirectoryResolver resolver,
    TimeProvider timeProvider) : IUserGroupService
{
    // ── Consultas ───────────────────────────────────────────────────

    public async Task<ServiceResult<UserGroupPageDto>> GetPageAsync(UserGroupQueryDto dto, CancellationToken ct = default)
    {
        var search = dto.Search?.Trim();
        var query = new UserGroupListQuery(
            string.IsNullOrEmpty(search) ? null : search[..Math.Min(search.Length, 100)],
            Math.Max(1, dto.Page),
            Math.Clamp(dto.PageSize, 1, UserGroupConstants.MaxPageSize));

        return ServiceResult<UserGroupPageDto>.Ok(await repository.GetPageAsync(query, ct));
    }

    public async Task<ServiceResult<UserGroupDetailDto>> GetByIdAsync(int id, CancellationToken ct = default)
    {
        var detail = await repository.GetDetailAsync(id, ct);
        return detail is null
            ? ServiceResult<UserGroupDetailDto>.Fail(ServiceResultStatus.NotFound, UserGroupConstants.GroupNotFound)
            : ServiceResult<UserGroupDetailDto>.Ok(detail);
    }

    // ── Ayudas para armar el grupo ──────────────────────────────────

    public async Task<ServiceResult<EmailResolutionDto>> ResolveEmailsAsync(ResolveEmailsRequestDto dto, CancellationToken ct = default)
    {
        var emails = dto.Emails ?? [];
        if (emails.Count > UserGroupConstants.MaxEmailsPerValidation)
            return ServiceResult<EmailResolutionDto>.Fail(ServiceResultStatus.Invalid,
                $"Puedes validar hasta {UserGroupConstants.MaxEmailsPerValidation} correos a la vez.");

        return await WithDirectoryAsync(() => resolver.ResolveEmailsAsync(emails, ct));
    }

    public async Task<ServiceResult<ManagerTeamsResultDto>> GetManagerTeamsAsync(ManagerTeamsRequestDto dto, CancellationToken ct = default)
    {
        var emails = dto.ManagerEmails ?? [];
        if (emails.Count == 0)
            return ServiceResult<ManagerTeamsResultDto>.Fail(ServiceResultStatus.Invalid, "Escribe al menos un correo de líder.");

        if (emails.Count > UserGroupConstants.MaxManagersPerSearch)
            return ServiceResult<ManagerTeamsResultDto>.Fail(ServiceResultStatus.Invalid,
                $"Puedes consultar hasta {UserGroupConstants.MaxManagersPerSearch} líderes a la vez.");

        return await WithDirectoryAsync(() => resolver.GetManagerTeamsAsync(emails, dto.IncludeAllLevels, ct));
    }

    public async Task<ServiceResult<List<MemberCandidateDto>>> SearchPeopleAsync(string? term, CancellationToken ct = default)
    {
        var clean = term?.Trim() ?? string.Empty;
        if (clean.Length < UserGroupConstants.SearchMinLength)
            return ServiceResult<List<MemberCandidateDto>>.Ok([]);

        // La búsqueda ya se protege sola si Graph falla: nunca responde 503.
        return ServiceResult<List<MemberCandidateDto>>.Ok(await resolver.SearchAsync(clean, ct));
    }

    // ── Comandos ────────────────────────────────────────────────────

    public async Task<ServiceResult<int>> CreateAsync(SaveUserGroupRequestDto dto, string currentUser, CancellationToken ct = default)
    {
        var (draft, errors) = await BuildDraftAsync(dto, excludeGroupId: null, ct);
        if (draft is null) return ServiceResult<int>.Fail(errors.Status, errors.Messages);

        var now = Now();
        var group = new UserGroup
        {
            Name = draft.Name,
            Description = draft.Description,
            CreatedDate = now,
            CreatedBy = currentUser,
        };

        foreach (var manager in draft.Managers) group.Managers.Add(NewManager(manager, now));
        foreach (var member in draft.Members) group.Members.Add(NewMember(member, now, currentUser));

        repository.Add(group);

        return await TrySaveAsync(ct)
            ? ServiceResult<int>.Ok(group.Id)
            : ServiceResult<int>.Fail(ServiceResultStatus.Conflict, UserGroupConstants.DuplicateName);
    }

    public async Task<ServiceResult<bool>> UpdateAsync(int id, SaveUserGroupRequestDto dto, string currentUser, CancellationToken ct = default)
    {
        var group = await repository.GetForUpdateAsync(id, ct);
        if (group is null) return ServiceResult<bool>.Fail(ServiceResultStatus.NotFound, UserGroupConstants.GroupNotFound);

        var (draft, errors) = await BuildDraftAsync(dto, excludeGroupId: id, ct);
        if (draft is null) return ServiceResult<bool>.Fail(errors.Status, errors.Messages);

        var now = Now();
        group.Name = draft.Name;
        group.Description = draft.Description;
        group.UpdatedDate = now;
        group.UpdatedBy = currentUser;

        SyncManagers(group, draft.Managers, now);
        SyncMembers(group, draft.Members, now, currentUser);

        return await TrySaveAsync(ct)
            ? ServiceResult<bool>.Ok(true)
            : ServiceResult<bool>.Fail(ServiceResultStatus.Conflict, UserGroupConstants.DuplicateName);
    }

    public async Task<ServiceResult<bool>> DeleteAsync(int id, string currentUser, CancellationToken ct = default)
    {
        var group = await repository.GetForUpdateAsync(id, ct);
        if (group is null) return ServiceResult<bool>.Fail(ServiceResultStatus.NotFound, UserGroupConstants.GroupNotFound);

        group.Removed = true;
        group.UpdatedDate = Now();
        group.UpdatedBy = currentUser;

        await repository.SaveChangesAsync(ct);
        return ServiceResult<bool>.Ok(true);
    }

    // ── Validación y resolución al guardar ──────────────────────────

    private sealed record ManagerDraft(string Email, string DisplayName, Guid EntraObjectId, bool IncludeAllLevels);

    private sealed record MemberDraft(
        string Email, string DisplayName, string? JobTitle, int? UserId, Guid? EntraObjectId,
        MemberAddedVia AddedVia, string? ManagerEmail);

    private sealed record GroupDraft(
        string Name, string? Description, IReadOnlyList<ManagerDraft> Managers, IReadOnlyList<MemberDraft> Members);

    private sealed record DraftErrors(ServiceResultStatus Status, List<string> Messages);

    private async Task<(GroupDraft? Draft, DraftErrors Errors)> BuildDraftAsync(
        SaveUserGroupRequestDto dto, int? excludeGroupId, CancellationToken ct)
    {
        var errors = new List<string>();
        DraftErrors Invalid() => new(ServiceResultStatus.Invalid, errors);

        // 1. Datos del grupo
        var name = dto.Name?.Trim() ?? string.Empty;
        if (name.Length == 0) errors.Add("Escribe el nombre del grupo.");
        else if (name.Length > UserGroupConstants.NameMaxLength)
            errors.Add($"El nombre no puede tener más de {UserGroupConstants.NameMaxLength} caracteres.");

        var description = string.IsNullOrWhiteSpace(dto.Description) ? null : dto.Description.Trim();
        if (description?.Length > UserGroupConstants.DescriptionMaxLength)
            errors.Add($"La descripción no puede tener más de {UserGroupConstants.DescriptionMaxLength} caracteres.");

        // 2. Líderes
        var managerRequests = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var manager in dto.Managers ?? [])
        {
            if (EmailNormalizer.TryNormalize(manager.Email, out var email))
                managerRequests.TryAdd(email, manager.IncludeAllLevels);
            else
                errors.Add($"El correo de líder \"{manager.Email}\" no es válido.");
        }

        if (managerRequests.Count > UserGroupConstants.MaxManagersPerGroup)
            errors.Add($"Un grupo puede tener hasta {UserGroupConstants.MaxManagersPerGroup} líderes.");

        // 3. Integrantes: formato, repetidos y origen
        var requested = new Dictionary<string, SaveGroupMemberDto>(StringComparer.OrdinalIgnoreCase);
        foreach (var member in dto.Members ?? [])
        {
            if (!EmailNormalizer.TryNormalize(member.Email, out var email))
            {
                errors.Add($"El correo \"{member.Email}\" no es válido.");
                continue;
            }

            if (!Enum.TryParse<MemberAddedVia>(member.AddedVia, true, out var via) || !Enum.IsDefined(via))
                errors.Add($"{email}: origen \"{member.AddedVia}\" no válido.");
            else if (via == MemberAddedVia.Manager
                     && (!EmailNormalizer.TryNormalize(member.ManagerEmail, out var managerEmail) || !managerRequests.ContainsKey(managerEmail)))
                errors.Add($"{email}: el líder por el que llegó no está en la lista de líderes del grupo.");

            requested.TryAdd(email, member);
        }

        if (requested.Count == 0) errors.Add("Agrega al menos una persona al grupo.");
        if (requested.Count > UserGroupConstants.MaxMembersPerGroup)
            errors.Add($"Un grupo puede tener hasta {UserGroupConstants.MaxMembersPerGroup} personas.");

        if (errors.Count > 0) return (null, Invalid());

        if (await repository.NameExistsAsync(name, excludeGroupId, ct))
            return (null, new DraftErrors(ServiceResultStatus.Conflict, [UserGroupConstants.DuplicateName]));

        try
        {
            // 4. Identidad de los líderes (Graph)
            var managers = await directory.FindByEmailsAsync(managerRequests.Keys.ToList(), ct);
            var managerDrafts = new List<ManagerDraft>();
            foreach (var (email, includeAll) in managerRequests)
            {
                if (managers.TryGetValue(email, out var manager))
                    managerDrafts.Add(new ManagerDraft(email, manager.DisplayName, manager.EntraObjectId, includeAll));
                else
                    errors.Add($"El líder {email} no se encontró en el directorio.");
            }

            // 5. Identidad de los integrantes: primero el maestro, que es la fuente preferida.
            var local = (await localUsers.FindByEmailsAsync(requested.Keys.ToList(), ct))
                .DistinctBy(match => match.Email)
                .ToDictionary(match => match.Email, StringComparer.OrdinalIgnoreCase);

            // 6. Los que no están en el maestro se verifican en Graph por su id.
            var directoryIds = new HashSet<Guid>();
            foreach (var (email, member) in requested)
            {
                if (local.ContainsKey(email)) continue;

                if (Guid.TryParse(member.EntraObjectId, out var entraId))
                    directoryIds.Add(entraId);
                else
                    errors.Add($"{email} no está en el maestro de usuarios ni trae su id del directorio.");
            }

            var fromDirectory = directoryIds.Count > 0
                ? await directory.GetByIdsAsync(directoryIds, ct)
                : new Dictionary<Guid, DirectoryUser>();

            var memberDrafts = new List<MemberDraft>();
            foreach (var (email, member) in requested)
            {
                var via = Enum.Parse<MemberAddedVia>(member.AddedVia!, true);
                var managerEmail = via == MemberAddedVia.Manager ? member.ManagerEmail!.Trim().ToLowerInvariant() : null;

                if (local.TryGetValue(email, out var match))
                {
                    memberDrafts.Add(new MemberDraft(email, match.DisplayName, null, match.UserId, null, via, managerEmail));
                    continue;
                }

                // El id del directorio tiene que corresponder EXACTAMENTE al correo enviado.
                if (Guid.TryParse(member.EntraObjectId, out var entraId)
                    && fromDirectory.TryGetValue(entraId, out var user)
                    && string.Equals(user.Email, email, StringComparison.OrdinalIgnoreCase))
                {
                    memberDrafts.Add(new MemberDraft(email, user.DisplayName, user.JobTitle, null, entraId, via, managerEmail));
                }
                else if (Guid.TryParse(member.EntraObjectId, out _))
                {
                    errors.Add($"{email} no coincide con ninguna persona del directorio.");
                }
            }

            return errors.Count > 0
                ? (null, Invalid())
                : (new GroupDraft(name, description, managerDrafts, memberDrafts), Invalid());
        }
        catch (DirectoryUnavailableException)
        {
            return (null, new DraftErrors(ServiceResultStatus.Unavailable, [UserGroupConstants.DirectoryUnavailable]));
        }
    }

    // ── Sincronización (editar) ─────────────────────────────────────

    private void SyncManagers(UserGroup group, IReadOnlyList<ManagerDraft> managers, DateTime now)
    {
        var wanted = managers.ToDictionary(m => m.Email, StringComparer.OrdinalIgnoreCase);

        foreach (var removed in group.Managers.Where(m => !wanted.ContainsKey(m.Email)).ToList())
        {
            group.Managers.Remove(removed);
            repository.Remove(removed);
        }

        foreach (var draft in managers)
        {
            var current = group.Managers.FirstOrDefault(m => string.Equals(m.Email, draft.Email, StringComparison.OrdinalIgnoreCase));
            if (current is null)
            {
                group.Managers.Add(NewManager(draft, now));
                continue;
            }

            current.DisplayName = draft.DisplayName;
            current.EntraObjectId = draft.EntraObjectId;
            current.IncludeAllLevels = draft.IncludeAllLevels;
        }
    }

    private void SyncMembers(UserGroup group, IReadOnlyList<MemberDraft> members, DateTime now, string currentUser)
    {
        var wanted = members.ToDictionary(m => m.Email, StringComparer.OrdinalIgnoreCase);

        foreach (var removed in group.Members.Where(m => !wanted.ContainsKey(m.Email)).ToList())
        {
            group.Members.Remove(removed);
            repository.Remove(removed);
        }

        var current = group.Members.ToDictionary(m => m.Email, StringComparer.OrdinalIgnoreCase);

        foreach (var draft in members)
        {
            if (!current.TryGetValue(draft.Email, out var member))
            {
                group.Members.Add(NewMember(draft, now, currentUser));
                continue;
            }

            // Se refresca la identidad: alguien que antes era "solo directorio" pudo entrar al maestro.
            member.DisplayName = draft.DisplayName;
            member.JobTitle = draft.JobTitle;
            member.UserId = draft.UserId;
            member.EntraObjectId = draft.EntraObjectId ?? member.EntraObjectId;
            member.AddedVia = draft.AddedVia;
            member.ManagerEmail = draft.ManagerEmail;
        }
    }

    private static UserGroupManager NewManager(ManagerDraft draft, DateTime now) => new()
    {
        Email = draft.Email,
        DisplayName = draft.DisplayName,
        EntraObjectId = draft.EntraObjectId,
        IncludeAllLevels = draft.IncludeAllLevels,
        CreatedDate = now,
    };

    private static UserGroupMember NewMember(MemberDraft draft, DateTime now, string currentUser) => new()
    {
        Email = draft.Email,
        DisplayName = draft.DisplayName,
        JobTitle = draft.JobTitle,
        UserId = draft.UserId,
        EntraObjectId = draft.EntraObjectId,
        AddedVia = draft.AddedVia,
        ManagerEmail = draft.ManagerEmail,
        CreatedDate = now,
        CreatedBy = currentUser,
    };

    // ── Utilidades ──────────────────────────────────────────────────

    private static async Task<ServiceResult<T>> WithDirectoryAsync<T>(Func<Task<T>> action)
    {
        try
        {
            return ServiceResult<T>.Ok(await action());
        }
        catch (DirectoryUnavailableException)
        {
            return ServiceResult<T>.Fail(ServiceResultStatus.Unavailable, UserGroupConstants.DirectoryUnavailable);
        }
    }

    /// <summary>false si el índice de nombre rechazó (dos personas guardando a la vez).</summary>
    private async Task<bool> TrySaveAsync(CancellationToken ct)
    {
        try
        {
            await repository.SaveChangesAsync(ct);
            return true;
        }
        catch (DuplicateKeyException)
        {
            return false;
        }
    }

    private DateTime Now() => timeProvider.GetUtcNow().UtcDateTime;
}
```

---

## 14. Paso 11 — Controlador

### `WebApp/Common/Helper/ControllerExtensions.cs`

Sirve para este controlador y para los que vengan. Si ya hiciste `CoursesController`, puedes pasarlo a usar esto también.

```csharp
using System.Security.Claims;
using DOCCB.Application.Features.Common.Application.DTOs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace WebApp.Common.Helper;

public static class ControllerExtensions
{
    /// <summary>Correo del usuario autenticado, para la auditoría. Usa MicrosoftUserAuthenticatorHelper si ya lo expone.</summary>
    public static string CurrentUserEmail(this ClaimsPrincipal user) =>
        user.FindFirstValue("preferred_username")
        ?? user.FindFirstValue(ClaimTypes.Email)
        ?? user.Identity?.Name
        ?? "desconocido";

    public static IActionResult ToActionResult<T>(this ControllerBase controller, ServiceResult<T> result) =>
        result.Status switch
        {
            ServiceResultStatus.Ok => controller.Ok(result.Response),
            ServiceResultStatus.NotFound => controller.NotFound(result.Response),
            ServiceResultStatus.Conflict => controller.Conflict(result.Response),
            ServiceResultStatus.Unavailable => controller.StatusCode(StatusCodes.Status503ServiceUnavailable, result.Response),
            _ => controller.BadRequest(result.Response),
        };
}
```

### `WebApp/Controllers/UserGroupsController.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.UserGroups.Application.DTOs;
using DOCCB.Application.Features.UserGroups.Application.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using WebApp.Common.Helper;

namespace WebApp.Controllers;

[ApiController]
[Route("api/user-groups")]
[Authorize] // + el atributo de permiso de DOCCB: solo quien administra grupos
public class UserGroupsController(IUserGroupService service) : ControllerBase
{
    private readonly IUserGroupService _service = service;

    [HttpGet]
    public async Task<IActionResult> GetPage([FromQuery] UserGroupQueryDto query, CancellationToken ct) =>
        this.ToActionResult(await _service.GetPageAsync(query, ct));

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id, CancellationToken ct) =>
        this.ToActionResult(await _service.GetByIdAsync(id, ct));

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] SaveUserGroupRequestDto dto, CancellationToken ct)
    {
        var result = await _service.CreateAsync(dto, User.CurrentUserEmail(), ct);

        return result.Status == ServiceResultStatus.Ok
            ? CreatedAtAction(nameof(GetById), new { id = result.Response.Response }, result.Response)
            : this.ToActionResult(result);
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] SaveUserGroupRequestDto dto, CancellationToken ct) =>
        this.ToActionResult(await _service.UpdateAsync(id, dto, User.CurrentUserEmail(), ct));

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, CancellationToken ct) =>
        this.ToActionResult(await _service.DeleteAsync(id, User.CurrentUserEmail(), ct));

    /// <summary>Valida una lista de correos (pegada por el usuario) sin guardar nada.</summary>
    [HttpPost("resolve-emails")]
    public async Task<IActionResult> ResolveEmails([FromBody] ResolveEmailsRequestDto dto, CancellationToken ct) =>
        this.ToActionResult(await _service.ResolveEmailsAsync(dto, ct));

    /// <summary>Trae el equipo de uno o varios líderes sin guardar nada.</summary>
    [HttpPost("manager-teams")]
    public async Task<IActionResult> ManagerTeams([FromBody] ManagerTeamsRequestDto dto, CancellationToken ct) =>
        this.ToActionResult(await _service.GetManagerTeamsAsync(dto, ct));

    /// <summary>Busca personas en el maestro y en el directorio a la vez.</summary>
    [HttpGet("people")]
    public async Task<IActionResult> SearchPeople([FromQuery] string? q, CancellationToken ct) =>
        this.ToActionResult(await _service.SearchPeopleAsync(q, ct));
}
```

> `resolve-emails` y `manager-teams` son `POST` aunque no guardan nada: las listas de correos no caben en una URL y no deben quedar en los registros del servidor.

### Contrato resultante

| Método | Ruta | Éxito | Errores |
|---|---|---|---|
| `GET` | `/api/user-groups?search=&page=&pageSize=` | `200` `{ items, totalCount }` | — |
| `GET` | `/api/user-groups/{id}` | `200` detalle con líderes e integrantes | `404` |
| `POST` | `/api/user-groups` | `201` con el `groupId` | `400` · `409` nombre repetido · `503` Graph |
| `PUT` | `/api/user-groups/{id}` | `200` | `400` · `404` · `409` · `503` |
| `DELETE` | `/api/user-groups/{id}` | `200` (borrado lógico) | `404` |
| `POST` | `/api/user-groups/resolve-emails` | `200` `{ found[], unresolved[] }` | `400` más de 1.000 · `503` |
| `POST` | `/api/user-groups/manager-teams` | `200` `{ teams[], unresolved[] }` | `400` · `503` |
| `GET` | `/api/user-groups/people?q=ana` | `200` candidatos del maestro y del directorio | — |

---

## 15. Paso 12 — Registro de dependencias y Graph

### Paquetes

```bash
dotnet add DOCCB.Application package Microsoft.Graph
dotnet add DOCCB.Application package Azure.Identity   # si no está ya
```

### `appsettings.json`

```json
"AzureAd": {
  "TenantId": "<tenant>",
  "ClientId": "<app registration del backend>",
  "ClientSecret": "<secreto — en Key Vault o variable de entorno, nunca en el repo>"
}
```

La app registrada necesita el permiso de **aplicación** `User.Read.All` en Microsoft Graph, con consentimiento de administrador.

### `ApplicationServiceRegistration.cs`

```csharp
services.AddSingleton(_ =>
{
    var credential = new ClientSecretCredential(
        configuration["AzureAd:TenantId"],
        configuration["AzureAd:ClientId"],
        configuration["AzureAd:ClientSecret"]);

    return new GraphServiceClient(credential, ["https://graph.microsoft.com/.default"]);
});

services.AddScoped<IGraphDirectoryService, GraphDirectoryService>();
services.AddScoped<IUserDirectoryResolver, UserDirectoryResolver>();
services.AddScoped<IUserGroupService, UserGroupService>();
services.TryAddSingleton(TimeProvider.System);
```

> Si DOCCB ya obtiene tokens de Graph con `ITokenService` (feature MSAL), reutiliza ese mecanismo para crear el `GraphServiceClient` en lugar de un segundo `ClientSecretCredential`.

### `InfrastructureServiceRegistration.cs`

```csharp
services.AddScoped<IUserGroupRepository, UserGroupRepository>();
// IUserSearchRepository ya está registrado desde la guía de cursos.
```

---

## 16. Pruebas

### Unitarias

```csharp
public class EmailNormalizerTests
{
    [Theory]
    [InlineData(" Ana.Perez@Empresa.com ", "ana.perez@empresa.com")]
    [InlineData("<juan@empresa.com>", "juan@empresa.com")]
    public void Normaliza(string raw, string expected)
    {
        Assert.True(EmailNormalizer.TryNormalize(raw, out var email));
        Assert.Equal(expected, email);
    }

    [Theory]
    [InlineData("ana@")]
    [InlineData("ana perez@empresa.com")]
    [InlineData("Ana <ana@empresa.com>")]
    [InlineData("")]
    public void Rechaza(string raw) => Assert.False(EmailNormalizer.TryNormalize(raw, out _));
}
```

### Del resolvedor y del servicio (con dobles de los repositorios y de Graph)

- Un correo en el maestro **no** llama a Graph.
- Un correo que solo está en Graph queda como "solo directorio" (`userId = null`, `entraObjectId` lleno).
- Un UPN pegado cuyo correo principal sí está en el maestro queda vinculado con su `userId`.
- Cuenta deshabilitada → `DISABLED`, no `NOT_FOUND`.
- Graph lanza `DirectoryUnavailableException` al validar → `503`; al buscar personas → responde solo con el maestro.
- Guardar con un integrante "solo directorio" cuyo `entraObjectId` pertenece a **otro** correo → `400`.
- Guardar con un integrante `MANAGER` cuyo líder no está en la lista de líderes → `400`.
- Editar: alguien que antes era "solo directorio" y ya está en el maestro queda con `userId`.
- Equipo de más de 2.000 personas → `truncated = true`.

### Contra SQL Server y Graph

- Ejecuta el script dos veces: la segunda no debe fallar.
- Inserta un integrante sin `user_id` ni `entra_object_id` → lo rechaza `ck_user_group_member_identity`.
- Dos grupos activos con el mismo nombre → `2601` en `ux_user_group_name`.
- Prueba con un líder real: los integrantes coinciden con su equipo en Outlook o Teams.
- Pega 500 correos reales: la validación tarda pocos segundos y los que están en el maestro no consultan Graph.

---

## 17. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| Graph responde `403 Authorization_RequestDenied` | Falta `User.Read.All` de aplicación o el consentimiento | Concede el permiso y el consentimiento de administrador en Entra ID. |
| `$search` responde `400` | Falta el encabezado `ConsistencyLevel: eventual` | Ya está en `SearchAsync`; revisa que no se haya borrado. |
| El equipo de un líder sale vacío | El campo **Jefe** (`manager`) no está diligenciado en Entra ID | Revísalo en el centro de administración de Entra o en Teams; no es un error del código. |
| Personas que sí están en el maestro salen como "solo directorio" | El correo del maestro es distinto al de Entra ID (otro dominio, alias) | Revisa `corporative_email` de esas personas; la consulta de verificación de la sección 4 las lista. |
| `Invalid object name 'OPENJSON'` o error de sintaxis cerca de `WITH` | Nivel de compatibilidad de la base de datos inferior a 130 | Súbelo, o configura `UseCompatibilityLevel(120)` en `UseSqlServer` para que EF use parámetros normales. |
| Validar 1.000 correos tarda mucho | Muchos no están en el maestro y van a Graph en bloques de 15 | Es el caso lento. Para listas grandes y frecuentes, agrega JSON batching de Graph (20 consultas por llamada). |
| `429 Too Many Requests` | Graph limitó las peticiones | Graph SDK reintenta solo; si persiste, el usuario ve el `503` y puede reintentar. |

---

## ✅ Checklist

- [ ] Confirmado que la tabla de usuarios es `dbo.users` con `id` y `corporative_email`.
- [ ] Revisados los correos corporativos repetidos en `dbo.users`; índice por correo creado.
- [ ] Nivel de compatibilidad de la base de datos 130 o superior.
- [ ] `UserGroups.sql` en `Persistence/Scripts SQL` y ejecutado en cada ambiente.
- [ ] Entidades, enum y configuraciones creadas y registradas en `DOCCbDbContext`.
- [ ] Permiso `User.Read.All` de aplicación con consentimiento; secreto fuera del repositorio.
- [ ] Consultas de Graph probadas en Graph Explorer con correos reales.
- [ ] Filtro de "usuario activo" agregado en `FindByEmailsAsync` y `SearchMatchesAsync`.
- [ ] Servicios, resolvedor, repositorio y `GraphServiceClient` registrados.
- [ ] `UserGroupsController` protegido con el permiso de administración de grupos.
- [ ] Pruebas unitarias y pruebas con un líder real hechas.
