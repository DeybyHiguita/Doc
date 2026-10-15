# 🔐 Puntos Dorados — Roles y permisos por función (configurables, sin tocar código)

**Lo que se pide:**
- El admin de Puntos Dorados tiene **7 funciones**: Aprobaciones, Categorías, Catálogo, Puntos, Redenciones, Dashboard y Masivos. Cada una debe poder asignarse a uno o varios roles **desde una pantalla, sin cambiar el código**.
- Si mañana existe un rol nuevo, el administrador le marca las funciones y listo.
- El control debe estar en **los dos lados**: el frontend muestra solo lo permitido, y **la API rechaza** lo que el rol no tiene.

**Base:** el código real de `.claude/Puntos Dorados` (Angular) y `.claude/Puntos dorados api` (.NET 8). Convenciones: [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md).

---

## 1. Cómo funciona hoy (lo que se revisó)

### El modelo de datos

```text
dbo.users ──1:1*── dbo.user_roles ──N:1── dbo.roles
                                           │
                                           └──1:N── dbo.permissions ──N:1── dbo.menu
                                                    (id_role, id_menu, is_active)   (name, path, icon, menu_group)
```

| Tabla | Para qué |
|---|---|
| `dbo.menu` | Cada **página** del sistema (`path` = la ruta de Angular, por ejemplo `puntos-dorados-admin`). |
| `dbo.roles` | SuperUsuario, Usuario, Aprobador, Compensación y Beneficio… |
| `dbo.permissions` | Qué páginas tiene cada rol (`is_active`). |
| `dbo.user_roles` | El rol de cada persona. *La llave admite varios roles, pero todo el código trata **un rol por persona**.* |

### La pantalla que ya existe

`roles-permissions` → **"Gestionar Roles"** (`permissions-assignation-modal`):
- A la izquierda, los roles, con el botón "Nuevo rol".
- A la derecha, los módulos (`dbo.menu`) con checkboxes. "Guardar" llama a `POST /api/Permissions/assign-permissions`.

La tabla de la pantalla cambia el rol de cada persona (`POST /api/Roles/change-role`).

### Cómo se usa en el frontend

| Pieza | Qué hace |
|---|---|
| `GlobalPermissionsService.loadPermissions(email)` | `POST /api/Permissions/get-permissions-by-user`. Trae las páginas del rol, con caché de 5 minutos. |
| `sidebar.component` | Arma el menú con esas páginas, agrupadas por `menu_group`. |
| `permissionGuard` | Deja entrar a una ruta si su **primer segmento** está entre los `path` del usuario. |
| `app.routes.ts` | El guard está **comentado** en casi todas las rutas, incluidas `puntos-dorados-user` y `puntos-dorados-admin`. |

### ⚠️ Hallazgos

| # | Hallazgo | Riesgo |
|---|---|---|
| 1 | **La API no valida permisos.** Los `Forbid()` de `RolesController` y `PermissionsController` solo comparan el correo del cuerpo con el del token. | **Crítico.** Cualquier persona autenticada puede llamar `assign-permissions` con su propio correo y darle **todos los módulos a su rol**. Lo mismo con crear roles y cambiar roles. |
| 2 | **Las APIs de Puntos Dorados no tienen permisos.** Todas dicen "Permisos: pendiente". | Cualquier colaborador puede aprobar reconocimientos, asignarse puntos de otra persona, cambiar el catálogo o exportar redenciones con Postman. |
| 3 | **El rol se cambia solo.** `validate-user-role` se llama desde `layout.component` **en cada página**. Si la persona no es SuperUsuario, Aprobador ni Compensación, y es jefe en alguna solicitud, **su rol pasa a "Aprobador"**. | Un rol nuevo como "Administrador Puntos Dorados" **se pierde solo** la primera vez que esa persona abre cualquier página. Hay que corregirlo antes de crear roles nuevos (Paso 5). |
| 4 | **Los permisos son por página**, no por función. | No hay forma de dar "Aprobaciones" sin "Catálogo": hoy el admin es todo o nada. |
| 5 | **El guard del frontend no bloquea si falla.** Si la API de permisos falla, deja pasar. | Aceptable solo si la API protege los datos (hallazgos 1 y 2). |
| 6 | **Hay nombres de rol escritos en el código.** `compensationDashboardGuard` y `approver-page` leen el rol del texto de `validate-user-role`. `ApproverService` (línea ~393) compara con "Compensación y Beneficio" y "SuperUsuario". | Es justo lo que se quiere evitar. Esta guía no lo toca (es de Solicitudes), pero el mecanismo nuevo sirve para migrarlo después. |
| 7 | **Errores menores:** | Se anotan; la guía corrige solo el del modal. |
| | `ChangeRole` llama dos veces `Delete(userRoleInBd)` y responde "ha sido **eliminado**" aunque cambió el rol. | |
| | El modal muestra "Permisos asignados" aunque la API responda con error (no revisa `hasError`). | |
| | `GoldenRecognitionsController` todavía tiene `review`, `approve` y `reject`, los de administración de antes de `GoldenRecognitionApprovals`. | |

---

## 2. La propuesta: páginas y **funciones** en el mismo menú

Se reutiliza todo lo que existe (tablas, pantalla, endpoint de asignación) y se agrega un nivel:

```text
dbo.menu
├── Puntos Dorados                      path = puntos-dorados-user           ← página (sidebar)
└── Puntos Dorados - Admin              path = puntos-dorados-admin          ← página (sidebar)
    ├── Aprobaciones                    path = puntos-dorados-admin/aprobaciones   ← función (id_parent)
    ├── Categorías                      path = puntos-dorados-admin/categorias
    ├── Catálogo                        path = puntos-dorados-admin/catalogo
    ├── Puntos                          path = puntos-dorados-admin/puntos
    ├── Redenciones                     path = puntos-dorados-admin/redenciones
    ├── Dashboard                       path = puntos-dorados-admin/dashboard
    └── Masivos                         path = puntos-dorados-admin/masivos
```

| Concepto | Qué es | Dónde se usa |
|---|---|---|
| **Página** | Fila de `dbo.menu` sin padre. | Sidebar y `permissionGuard`, como hoy. |
| **Función** | Fila de `dbo.menu` con `id_parent`. Su `path` es la **llave** del permiso. | Pestañas del admin (frontend) y `[RequirePermission]` (API). |
| **Rol → permisos** | `dbo.permissions`, igual que hoy. | Se configura en "Gestionar Roles", que ahora muestra las funciones debajo de su página. |

**Lo que queda en el código:** solo las **llaves** de las funciones (`puntos-dorados-admin/aprobaciones`), nunca nombres de rol. **Lo que queda en datos:** qué rol tiene qué función. Crear un rol, quitarle o darle funciones y cambiarle el rol a una persona se hace en la pantalla.

### Por qué así

| Alternativa | Por qué no |
|---|---|
| Tablas nuevas (`function`, `role_function`) y otra pantalla | Duplica lo que ya hacen `menu` y `permissions`, y habría dos lugares para administrar accesos. |
| Validar por nombre de rol (`if role == "Administrador"`) | Cada rol nuevo obliga a cambiar el código. Es el problema del hallazgo 6. |
| Solo ocultar las pestañas en Angular | La API seguiría abierta (hallazgo 2). |
| Claims de Azure AD (App Roles) | Los roles se administrarían en Azure, fuera de la aplicación, y no por función. |

### Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Llave de un permiso.** | El `path` del menú, que ya es la llave de las páginas en `permissionGuard`. Se le agrega un índice único. |
| 2 | **Función sin su página.** | No sirve: no se puede abrir el admin. Al guardar, la API **agrega la página** de cada función marcada, y el modal marca o desmarca en cascada. |
| 3 | **Página de colaborador.** | Un solo permiso (`puntos-dorados-user`) para todas sus pestañas. Si algún día una pestaña debe restringirse, se agrega como función de esa página con el mismo mecanismo. |
| 4 | **Lecturas compartidas** (categorías, personas, producto por id). | Las usan las dos páginas. Basta con **cualquiera** de las dos (`[RequirePermission(UserPage, AdminPage)]`). |
| 5 | **Masivos.** | Una función para las tres cargas (reconocimientos, aprobaciones y puntos), porque están en la misma pestaña. |
| 6 | **Respuesta sin permiso.** | HTTP **403**. No es un error de negocio (HTTP 200 + `hasError`), es un acceso denegado. El frontend muestra "No tienes permiso para esta acción". |
| 7 | **Caché.** | La API guarda los permisos de cada persona **1 minuto**, y los descarta al guardar permisos o cambiar un rol. El frontend ya los guarda 5 minutos, o hasta recargar. |
| 8 | **Un rol por persona** (como hoy). | Si alguien necesita "Aprobador" de Solicitudes **y** administrar Puntos Dorados, se crea un rol que tenga los dos grupos de módulos. Varios roles por persona es la fase 2 (sección 11). |
| 9 | **General.** | `[RequirePermission]` y el lector de permisos no son de Puntos Dorados. Cualquier módulo (Solicitudes, Bienestar…) puede usarlos igual. |

---

## 3. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/PermissionsFunctions.sql`

```sql
/* =====================================================================
   Funciones dentro de las páginas (permisos por función)
   Base de datos: DB · Esquema: dbo
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

/* 0. Revisa antes: cómo están guardados los path de las páginas (con o sin "/" inicial)
      y que no haya path repetidos. La segunda consulta debe devolver CERO filas. */
SELECT id_menu, name, path, menu_group FROM dbo.menu ORDER BY id_menu;
SELECT path, COUNT(*) AS veces FROM dbo.menu GROUP BY path HAVING COUNT(*) > 1;
GO

/* 1. Columnas nuevas en dbo.menu */
IF COL_LENGTH('dbo.menu', 'id_parent') IS NULL
    ALTER TABLE dbo.menu ADD id_parent INT NULL
        CONSTRAINT fk_menu_parent REFERENCES dbo.menu (id_menu);
GO

IF COL_LENGTH('dbo.menu', 'sort_order') IS NULL
    ALTER TABLE dbo.menu ADD sort_order INT NOT NULL
        CONSTRAINT df_menu_sort_order DEFAULT (0);
GO

/* 2. El path es la llave de un permiso: no se puede repetir. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_menu_path' AND object_id = OBJECT_ID('dbo.menu'))
    CREATE UNIQUE INDEX ux_menu_path ON dbo.menu (path);
GO

/* 3. Las páginas de Puntos Dorados (si no existen) y las 7 funciones del admin. */
IF NOT EXISTS (SELECT 1 FROM dbo.menu WHERE path IN ('puntos-dorados-user', '/puntos-dorados-user'))
    INSERT INTO dbo.menu (name, menu_group, path, icon, sort_order)
    VALUES (N'Puntos Dorados', N'Puntos Dorados', 'puntos-dorados-user', 'fa-solid fa-star', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.menu WHERE path IN ('puntos-dorados-admin', '/puntos-dorados-admin'))
    INSERT INTO dbo.menu (name, menu_group, path, icon, sort_order)
    VALUES (N'Puntos Dorados - Admin', N'Puntos Dorados', 'puntos-dorados-admin', 'fa-solid fa-sliders', 2);
GO

DECLARE @adminPage INT = (SELECT id_menu FROM dbo.menu WHERE path IN ('puntos-dorados-admin', '/puntos-dorados-admin'));

INSERT INTO dbo.menu (name, menu_group, path, icon, id_parent, sort_order)
SELECT v.name, N'Puntos Dorados', v.path, v.icon, @adminPage, v.sort_order
FROM (VALUES
    (N'Aprobaciones', 'puntos-dorados-admin/aprobaciones', 'fa-solid fa-check-double',    1),
    (N'Categorías',   'puntos-dorados-admin/categorias',   'fa-solid fa-tags',            2),
    (N'Catálogo',     'puntos-dorados-admin/catalogo',     'fa-solid fa-gift',            3),
    (N'Puntos',       'puntos-dorados-admin/puntos',       'fa-solid fa-coins',           4),
    (N'Redenciones',  'puntos-dorados-admin/redenciones',  'fa-solid fa-receipt',         5),
    (N'Dashboard',    'puntos-dorados-admin/dashboard',    'fa-solid fa-chart-column',    6),
    (N'Masivos',      'puntos-dorados-admin/masivos',      'fa-solid fa-file-arrow-up',   7)
) AS v (name, path, icon, sort_order)
WHERE NOT EXISTS (SELECT 1 FROM dbo.menu m WHERE m.path = v.path);
GO

/* 4. Que nadie quede por fuera al desplegar la API:
      SuperUsuario recibe la página de roles, las dos páginas de Puntos Dorados y las 7 funciones. */
DECLARE @super INT = (SELECT id FROM dbo.roles WHERE name = N'SuperUsuario');
DECLARE @adminPage INT = (SELECT id_menu FROM dbo.menu WHERE path IN ('puntos-dorados-admin', '/puntos-dorados-admin'));

INSERT INTO dbo.permissions (id_menu, id_role, is_active, updated_by, updated_date)
SELECT m.id_menu, @super, 1, NULL, SYSDATETIME()
FROM dbo.menu m
WHERE (m.id_menu = @adminPage
       OR m.id_parent = @adminPage
       OR m.path IN ('puntos-dorados-user', '/puntos-dorados-user', 'roles-permissions', '/roles-permissions'))
  AND NOT EXISTS (SELECT 1 FROM dbo.permissions p
                  WHERE p.id_role = @super AND p.id_menu = m.id_menu AND p.is_active = 1);
GO

/* 5. La página de colaborador para todos los roles activos.
      ⚠️ Si no todos los roles deben ver Puntos Dorados, no ejecutes este bloque y asígnala desde la pantalla. */
DECLARE @userPage INT = (SELECT id_menu FROM dbo.menu WHERE path IN ('puntos-dorados-user', '/puntos-dorados-user'));

INSERT INTO dbo.permissions (id_menu, id_role, is_active, updated_by, updated_date)
SELECT @userPage, r.id, 1, NULL, SYSDATETIME()
FROM dbo.roles r
WHERE r.active = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.permissions p
                  WHERE p.id_role = r.id AND p.id_menu = @userPage AND p.is_active = 1);
GO
```

> **¿`roles-permissions` está guardado con otro `path`?** La consulta 0 lo muestra. Ajusta el bloque 4: si SuperUsuario no tiene la página de roles cuando se despliegue la API, **nadie podrá administrar permisos**.
>
> **`updated_by` en `NULL`:** son permisos iniciales del script. Los siguientes los registra la pantalla con la persona que los guarda.

### Consultas útiles

```sql
-- Matriz: qué rol tiene qué página o función de Puntos Dorados
SELECT r.name AS rol, ISNULL(parent.name + N' › ', N'') + m.name AS acceso, m.path
FROM   dbo.permissions p
JOIN   dbo.roles r ON r.id = p.id_role
JOIN   dbo.menu  m ON m.id_menu = p.id_menu
LEFT JOIN dbo.menu parent ON parent.id_menu = m.id_parent
WHERE  p.is_active = 1 AND m.path LIKE '%puntos-dorados%'
ORDER BY r.name, ISNULL(m.id_parent, m.id_menu), m.sort_order;

-- Quiénes pueden aprobar reconocimientos hoy
SELECT u.display_name, u.corporative_email, r.name AS rol
FROM   dbo.permissions p
JOIN   dbo.menu m        ON m.id_menu = p.id_menu
JOIN   dbo.roles r       ON r.id = p.id_role AND r.active = 1
JOIN   dbo.user_roles ur ON ur.id_role = r.id
JOIN   dbo.users u       ON u.id = ur.id_user AND u.active = 1
WHERE  p.is_active = 1 AND m.path = 'puntos-dorados-admin/aprobaciones';
```


---

## 4. Paso 2 — Backend: el menú con funciones

### `DOCCB.Domain/Entities/Menu.cs` ✏️ — agrega

```csharp
/// <summary>null = página (sidebar). Con valor = función dentro de esa página (por ejemplo, una pestaña).</summary>
public int? ParentId { get; set; }
public int SortOrder { get; set; }

public Menu? Parent { get; set; }
public ICollection<Menu> Children { get; set; } = [];
```

### `DOCCB.Infraestructure/Configurations/MenuConfiguration.cs` ✏️ — agrega dentro de `Configure`

```csharp
builder.Property(m => m.ParentId).HasColumnName("id_parent");
builder.Property(m => m.SortOrder).HasColumnName("sort_order");

builder.HasOne(m => m.Parent)
    .WithMany(m => m.Children)
    .HasForeignKey(m => m.ParentId)
    .HasConstraintName("fk_menu_parent")
    .OnDelete(DeleteBehavior.Restrict);

builder.HasIndex(m => m.Path)
    .IsUnique()
    .HasDatabaseName("ux_menu_path");
```

### DTOs ✏️

`PermissionResponseDto` (lo que recibe el sidebar y las páginas):

```csharp
/// <summary>null = página. Con valor = función de esa página (no va en el sidebar).</summary>
public int? ParentId { get; set; }
```

`PermissionDto`, en `RolesAndPermissionsRequestDto.cs` (lo que recibe el modal "Gestionar Roles"):

```csharp
public int? ParentId { get; set; }
public string Path { get; set; } = string.Empty;
public int SortOrder { get; set; }
```

---

## 5. Paso 3 — Backend: leer los permisos de una persona (con caché)

Es la pieza general: la usa `[RequirePermission]` para **cualquier** módulo.

### `Features/RolesAndPermissions/Application/Interfaces/IUserPermissionReader.cs`

```csharp
namespace DOCCB.Application.Features.RolesAndPermissions.Application.Interfaces
{
    public interface IUserPermissionReader
    {
        /// <summary>Los path (páginas y funciones) que tiene la persona, en minúsculas y sin "/" inicial.</summary>
        Task<IReadOnlySet<string>> GetPathsAsync(string userEmail);

        /// <summary>Descarta la caché de todos: se llama al guardar permisos o cambiar un rol.</summary>
        void Invalidate();
    }
}
```

### `Features/RolesAndPermissions/Application/Services/UserPermissionReader.cs`

```csharp
using DOCCB.Application.Features.Common.Application.Interfaces;
using DOCCB.Application.Features.RolesAndPermissions.Application.Interfaces;
using DOCCB.Domain.Entities;
using Microsoft.Extensions.Caching.Memory;

namespace DOCCB.Application.Features.RolesAndPermissions.Application.Services
{
    public class UserPermissionReader(ITransactionExecutorHelper transactionHelper, IMemoryCache cache) : IUserPermissionReader
    {
        private static readonly TimeSpan CacheDuration = TimeSpan.FromMinutes(1);

        /// <summary>Cambia al invalidar: las llaves viejas dejan de usarse y vencen solas.</summary>
        private static int _version;

        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;
        private readonly IMemoryCache _cache = cache;

        public async Task<IReadOnlySet<string>> GetPathsAsync(string userEmail)
        {
            var email = userEmail.Trim().ToLowerInvariant();
            var key = $"user-permissions:{Volatile.Read(ref _version)}:{email}";

            if (_cache.TryGetValue(key, out IReadOnlySet<string>? cached) && cached is not null)
            {
                return cached;
            }

            // Una consulta: permisos activos de los roles activos de la persona (si algún día tiene varios, se suman).
            var paths = await _transactionHelper.ExecuteQueryAsync<IReadOnlyList<string>>(async unitOfWork =>
                await unitOfWork.Repository<Permissions>().GetListAsync<string>(
                    p => p.IsActive
                         && p.Role.IsActive
                         && p.Role.UserRoles.Any(ur => ur.User.CorportativeEmail == email && ur.User.IsActive),
                    selector: q => q.Select(p => p.Menu.Path))) ?? [];

            IReadOnlySet<string> result = paths
                .Select(path => path.Trim().TrimStart('/').ToLowerInvariant())
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            _cache.Set(key, result, CacheDuration);
            return result;
        }

        public void Invalidate() => Interlocked.Increment(ref _version);
    }
}
```

> **¿Por qué una versión y no borrar llaves?** `IMemoryCache` no permite borrar "todas las de un rol". Al cambiar la versión, todas las llaves anteriores quedan sin uso y vencen en menos de un minuto.
>
> **Varios servidores:** si la API corre en más de una instancia, cada una tiene su caché. Un cambio de permisos puede tardar hasta 1 minuto en las demás. Es aceptable para permisos de administración.

### Registro — `ApplicationServiceRegistration.cs` ✏️

```csharp
services.AddScoped<IUserPermissionReader, UserPermissionReader>();
```

(`AddMemoryCache()` ya está registrado.)

---

## 6. Paso 4 — Backend: el atributo `[RequirePermission]`

.NET 8 permite que un atributo **sea** su propio requisito de autorización (`IAuthorizationRequirementData`). Así no hace falta un `IAuthorizationPolicyProvider` ni registrar políticas por nombre.

### `WebApp/Authorization/RequirePermissionAttribute.cs`

```csharp
using Microsoft.AspNetCore.Authorization;

namespace DOCCB.WebApp.Authorization
{
    /// <summary>
    /// Exige que el rol de la persona tenga AL MENOS UNO de estos path (páginas o funciones de dbo.menu).
    /// Varios atributos en la misma acción (o en la clase y en la acción) se exigen todos.
    /// Sin permiso: HTTP 403.
    /// </summary>
    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = true)]
    public sealed class RequirePermissionAttribute : AuthorizeAttribute, IAuthorizationRequirement, IAuthorizationRequirementData
    {
        public RequirePermissionAttribute(params string[] paths)
        {
            Paths = paths;
        }

        public IReadOnlyList<string> Paths { get; }

        public IEnumerable<IAuthorizationRequirement> GetRequirements()
        {
            yield return this;
        }
    }
}
```

### `WebApp/Authorization/RequirePermissionHandler.cs`

```csharp
using DOCCB.Application.Features.RolesAndPermissions.Application.Interfaces;
using DOCCB.WebApp.Common.Helper;
using Microsoft.AspNetCore.Authorization;

namespace DOCCB.WebApp.Authorization
{
    public sealed class RequirePermissionHandler(IUserPermissionReader permissionReader) : AuthorizationHandler<RequirePermissionAttribute>
    {
        private readonly IUserPermissionReader _permissionReader = permissionReader;

        protected override async Task HandleRequirementAsync(AuthorizationHandlerContext context, RequirePermissionAttribute requirement)
        {
            var email = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(context.User).Email;
            if (string.IsNullOrEmpty(email))
            {
                return; // sin usuario: la autenticación responde 401
            }

            var granted = await _permissionReader.GetPathsAsync(email);
            if (requirement.Paths.Any(granted.Contains))
            {
                context.Succeed(requirement);
            }
        }
    }
}
```

### `WebApp/Program.cs` ✏️ — junto a los demás servicios

```csharp
using DOCCB.WebApp.Authorization;
using Microsoft.AspNetCore.Authorization;

// …
builder.Services.AddScoped<IAuthorizationHandler, RequirePermissionHandler>();
```

> **Scoped**, no singleton: el handler usa `IUserPermissionReader`, que a su vez usa `ITransactionExecutorHelper` (scoped).

### Las llaves — `Features/GoldenPoints/Application/Constants/GoldenPermissions.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    /// <summary>Los path de dbo.menu de Puntos Dorados. Son llaves: no cambian aunque cambie el nombre que se muestra.</summary>
    public static class GoldenPermissions
    {
        public const string UserPage = "puntos-dorados-user";
        public const string AdminPage = "puntos-dorados-admin";

        public const string Approvals = AdminPage + "/aprobaciones";
        public const string Categories = AdminPage + "/categorias";
        public const string Catalog = AdminPage + "/catalogo";
        public const string Points = AdminPage + "/puntos";
        public const string Redemptions = AdminPage + "/redenciones";
        public const string Dashboard = AdminPage + "/dashboard";
        public const string BulkLoads = AdminPage + "/masivos";
    }
}
```

Y para la pantalla de roles, en `Features/RolesAndPermissions/Application/Constants/RolesPermissionsConstants.cs`:

```csharp
namespace DOCCB.Application.Features.RolesAndPermissions.Application.Constants
{
    public static class RolesPermissionsConstants
    {
        /// <summary>Path de la página "Roles y permisos" en dbo.menu.</summary>
        public const string PagePath = "roles-permissions";
    }
}
```

---

## 7. Paso 5 — Backend: proteger los endpoints

### 7.1 Roles y permisos (hallazgo 1, **primero**)

| Controlador | Acción | Atributo |
|---|---|---|
| `PermissionsController` | `GET get-content`, `POST assign-permissions`, `POST get-permissions-by-role` | `[RequirePermission(RolesPermissionsConstants.PagePath)]` |
| `PermissionsController` | `POST get-permissions-by-user` | Sin cambio: ya exige que sea el propio correo. |
| `RolesController` | `POST` (crear rol), `POST get-user-roles`, `POST change-role` | `[RequirePermission(RolesPermissionsConstants.PagePath)]` |
| `RolesController` | `POST validate-user-role` | Sin cambio (propio correo). |

Por ejemplo:

```csharp
[HttpPost("assign-permissions")]
[RequirePermission(RolesPermissionsConstants.PagePath)]
[ProducesResponseType(StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status401Unauthorized)]
[ProducesResponseType(StatusCodes.Status403Forbidden)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
public async Task<IActionResult> AssignPermissionsToRole(PermissionAssignationRequestDto permissionAssignation)
```

> Los `Forbid()` que comparan correos se quedan: evitan que alguien guarde cambios a nombre de otra persona.

### 7.2 Puntos Dorados

Los controladores que mezclan colaborador y administración llevan el atributo **en cada acción**. Los que son de una sola función lo llevan **en la clase**.

| Controlador | Acción | Permiso |
|---|---|---|
| `GoldenRecognitionApprovalsController` | **Clase** | `Approvals` |
| `GoldenDashboardController` | **Clase** | `Dashboard` |
| `GoldenBulkLoadsController` | **Clase** (puntos, reconocimientos, aprobaciones, pendientes) | `BulkLoads` |
| `GoldenRecognitionsController` | `POST`, `PUT {id}`, `DELETE {id}`, `sent`, `received`, `feed`, reacciones | `UserPage` |
| | `review`, `{id}/approve`, `{id}/reject` (los de antes) | `Approvals` *(o elimínalos si el frontend ya no los usa)* |
| `GoldenRecognitionCategoriesController` | `GET`, `GET {id}` | `UserPage, AdminPage` |
| | `appearance-options`, `POST`, `PUT`, `inactivate`, `activate` | `Categories` |
| `GoldenProductCategoriesController` | `GET`, `GET {id}` | `UserPage, AdminPage` |
| | `POST`, `PUT`, `inactivate`, `activate` | `Categories` |
| `GoldenProductsController` | `GET available` | `UserPage` |
| | `GET {id}` | `UserPage, AdminPage` |
| | `GET` (listado del admin) | `Catalog, Redemptions` *(Redenciones lo usa para su filtro de productos)* |
| | `POST`, `PUT`, `inactivate`, `activate`, `images` | `Catalog` |
| `GoldenPointsController` | `me/summary`, `me/transactions` | `UserPage` |
| | `summary`, `transactions`, `assignments`, `transactions/{id}/reverse` | `Points` |
| `GoldenRedemptionsController` | `POST` (canjear) | `UserPage` |
| | `GET`, `GET export` | `Redemptions` |
| `GoldenPeopleController` | `GET` (buscar personas) | `UserPage, AdminPage` |

Ejemplos:

```csharp
// Una sola función: en la clase.
[ApiController]
[Route("api/[controller]")]
[Authorize]
[RequirePermission(GoldenPermissions.Approvals)]
public class GoldenRecognitionApprovalsController(IGoldenRecognitionApprovalService approvalService) : ControllerBase
```

```csharp
// Mezclado: en cada acción.
[HttpPost]
[RequirePermission(GoldenPermissions.UserPage)]
public async Task<IActionResult> Redeem([FromBody] RedeemGoldenProductDto request)

[HttpGet]
[RequirePermission(GoldenPermissions.Redemptions)]
public async Task<IActionResult> GetAll([FromQuery] GoldenRedemptionQueryDto query)
```

```csharp
// Lectura compartida: basta con cualquiera de las dos páginas.
[HttpGet]
[RequirePermission(GoldenPermissions.UserPage, GoldenPermissions.AdminPage)]
public async Task<IActionResult> GetAll([FromQuery] string? status)
```

Quita los comentarios "Permisos: pendiente…" y "⬇ Permiso de administración…" de esos controladores, y agrega `[ProducesResponseType(StatusCodes.Status403Forbidden)]` en las acciones protegidas.

---

## 8. Paso 6 — Backend: guardar permisos y que no se pierdan los roles

### `PermissionService` ✏️

Inyecta el lector:

```csharp
public class PermissionService(ITransactionExecutorHelper transactionHelper, IUserService userService, IUserPermissionReader permissionReader) : IPermissionService
{
    // …
    private readonly IUserPermissionReader _permissionReader = permissionReader;
```

**`AssignPermissionToRole`:** al inicio de la lambda (después de validar el rol) agrega las páginas de las funciones marcadas, y al final descarta la caché:

```csharp
public async Task<ResponseDto<string>?> AssignPermissionToRole(PermissionAssignationRequestDto dto)
{
    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<string>?>(
        async unitOfWork =>
        {
            var userModified = await unitOfWork.Repository<User>().GetAsync(r => r.CorportativeEmail == dto.UserEmail && r.IsActive);
            var roleInBd = await unitOfWork.Repository<Role>().GetAsync(r => r.Id == dto.RoleId && r.IsActive);

            if (roleInBd == null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<string>($"El rol proporcionado es inválido");
            }

            // Una función sin su página no sirve: se agrega la página de cada función marcada.
            var selectedMenus = await unitOfWork.Repository<Menu>().GetListAsync(m => dto.PermissionIds.Contains(m.Id));
            dto.PermissionIds = [.. dto.PermissionIds
                .Concat(selectedMenus.Where(m => m.ParentId != null).Select(m => m.ParentId!.Value))
                .Distinct()];

            // … lo de hoy: actualPermissions, UpdatePermissions / CreateNewPermissions …
        }
    );

    // Los permisos del rol cambiaron: la API los vuelve a leer en la siguiente petición.
    if (response is { HasError: false })
    {
        _permissionReader.Invalidate();
    }

    return response;
}
```

**`GetPermissionsByRole`:** agrega `ParentId = p.Menu.ParentId` al `Select`.

**`GetRolesAndPermissionsModalContent`:** agrega los campos nuevos al `PermissionDto`:

```csharp
Permissions = [.. activeMenus
    .OrderBy(m => m.SortOrder)
    .ThenBy(m => m.Name)
    .Select(m => new PermissionDto
    {
        PermissionId = m.Id,
        Name = m.Name,
        Code = $"CYP_{m.Name}",
        MenuGroup = m.Group ?? string.Empty,
        ParentId = m.ParentId,
        Path = m.Path,
        SortOrder = m.SortOrder,
    })]
```

### `RoleService` ✏️ — el cambio automático de rol (hallazgo 3)

Inyecta también `IUserPermissionReader permissionReader` (`private readonly IUserPermissionReader _permissionReader = permissionReader;`).

En `ValidateUserRequest`, hoy se promueve a "Aprobador" a **cualquiera** que no sea SuperUsuario, Aprobador o Compensación. Eso incluye los roles nuevos. Cámbialo para que **solo** se muevan solos "Usuario" y "Aprobador":

```csharp
// Antes
var highLevelRoles = new List<string>
{
    ConstantsValues.SuperUserRoleName,
    ConstantsValues.ApproverUserRoleName,
    ConstantsValues.CompensacionBeneficioUserRoleName
};
// …
if (!highLevelRoles.Contains(userRole.Role.Name) && hasRequests) { … }
if (!highLevelRoles.Contains(userRole.Role.Name) && hasActiveDelegations) { … }
```

```csharp
// Después: solo "Usuario" sube a "Aprobador" y solo "Aprobador" baja a "Usuario".
// Los demás roles (SuperUsuario, Compensación y Beneficio y los que se creen en la pantalla) los decide un administrador.
var isBasicUser = userRole.Role.Name.Equals(ConstantsValues.BasicUserRoleName, StringComparison.OrdinalIgnoreCase);

if (isBasicUser && (hasRequests || hasActiveDelegations))
{
    newRoleName = ConstantsValues.ApproverUserRoleName;
    await ModifyRole(user.Id, ConstantsValues.ApproverUserRoleName, userSystem!.Id, userRole);

    message = $"El usuario {user.DisplayName} ha sido validado exitosamente. Rol anterior: {oldRoleName}, Nuevo rol: {newRoleName}";
    return ResponseDtoHelper.CreateSuccessResponseDto<string>(message);
}

// El bloque que baja de "Aprobador" a "Usuario" queda igual.
```

Elimina la lista `highLevelRoles`: ya no se usa.

> **Consecuencia:** una persona con un rol propio (por ejemplo "Administrador Puntos Dorados") que además es jefe en solicitudes **ya no pasa sola a "Aprobador"**. Su rol debe incluir los módulos de aprobador que necesite (`approvers`, `requests-dashboard`…). Es la regla de "un rol por persona" (decisión 8).

**Descartar la caché al cambiar un rol:**
- **`ChangeRole`:** igual que `AssignPermissionToRole`, guarda la respuesta del helper y, si no tiene error, llama `_permissionReader.Invalidate()` antes de devolverla.
- **`ModifyRole`:** lo mismo después de la transacción, si devolvió `true`.
- **De paso, en `ChangeRole`:** quita el segundo `unitOfWork.Repository<UserRole>().Delete(userRoleInBd);`. Cambia el mensaje a "El rol del usuario {…} se cambió correctamente".

---

## 9. Paso 7 — Frontend

### `shared/entities/general/menu-permissions-service.ts` ✏️

```ts
export interface MenuPermission {
  permissionId: number;
  path: string;
  label: string;
  icon: string;
  menuGroup?: string | null;
  /** null = página (sidebar). Con valor = función de esa página (pestaña). */
  parentId?: number | null;
}

/** Igual que permissionGuard: sin "/" inicial y en minúsculas. */
export function normalizePermissionPath(path: string): string {
  return path.trim().replace(/^\//, '').toLowerCase();
}

/** true si el usuario tiene esa página o función. */
export function canAccess(permissions: readonly MenuPermission[], path: string): boolean {
  const target = normalizePermissionPath(path);
  return permissions.some(permission => normalizePermissionPath(permission.path) === target);
}
```

### `shared/components/sidebar/sidebar.component.ts` ✏️ — las funciones no van al menú

Al inicio de `buildNavigation`:

```ts
private buildNavigation(permissions: MenuPermission[]): { directItems: MenuPermission[]; groups: SidebarGroup[] } {
  // Las funciones (pestañas) no son entradas del menú: solo las páginas.
  const mappedPermissions = permissions
    .filter(permission => !permission.parentId)
    .map((permission: MenuPermission) => ({
      // … igual que hoy
    }));
```

### `app.routes.ts` ✏️ — activar el guard en las dos páginas

```ts
{
  path: 'puntos-dorados-user',
  canActivate: [permissionGuard],
  loadComponent: () => import('./features/puntos-dorados/presentation/user/puntos-dorados-user.component').then(m => m.PuntosDoradosUserComponent),
},
{
  path: 'puntos-dorados-admin',
  canActivate: [permissionGuard],
  loadComponent: () => import('./features/puntos-dorados/presentation/admin/puntos-dorados-admin.component').then(m => m.PuntosDoradosAdminComponent),
},
```

> El guard compara el primer segmento (`puntos-dorados-admin`) con las **páginas**: no lo confunden las funciones (`puntos-dorados-admin/aprobaciones`).

### `features/puntos-dorados/domain/puntos-dorados.ts` ✏️ — agrega

```ts
/** Los mismos path que dbo.menu y GoldenPermissions en la API. */
export const GOLDEN_PERMISSIONS = {
  userPage: 'puntos-dorados-user',
  adminPage: 'puntos-dorados-admin',
  approvals: 'puntos-dorados-admin/aprobaciones',
  categories: 'puntos-dorados-admin/categorias',
  catalog: 'puntos-dorados-admin/catalogo',
  points: 'puntos-dorados-admin/puntos',
  redemptions: 'puntos-dorados-admin/redenciones',
  dashboard: 'puntos-dorados-admin/dashboard',
  bulkLoads: 'puntos-dorados-admin/masivos',
} as const;
```

### `features/puntos-dorados/infrastructure/golden-api.ts` ✏️ — el 403

En `toErrorMessage`, después del caso `401`:

```ts
if (error.status === 403) {
  return 'No tienes permiso para esta acción. Si lo necesitas, pídeselo a un administrador.';
}
```

### `presentation/admin/puntos-dorados-admin.component.ts` ✏️

Imports:

```ts
import { canAccess } from "@shared/entities/general/menu-permissions-service";
import { GOLDEN_PERMISSIONS } from "@features/puntos-dorados/domain/puntos-dorados";
```

Las pestañas, con su permiso (junto a `activeTab`):

```ts
/** Las 7 funciones. Cada una se ve solo si el rol tiene su permiso (Roles y permisos → Gestionar roles). */
private readonly adminTabs: readonly { tab: AdminTab; label: string; permission: string }[] = [
  { tab: 'aprobaciones', label: 'Aprobaciones', permission: GOLDEN_PERMISSIONS.approvals },
  { tab: 'categorias', label: 'Categorías', permission: GOLDEN_PERMISSIONS.categories },
  { tab: 'catalogo', label: 'Catálogo', permission: GOLDEN_PERMISSIONS.catalog },
  { tab: 'puntos', label: 'Puntos', permission: GOLDEN_PERMISSIONS.points },
  { tab: 'redenciones', label: 'Redenciones', permission: GOLDEN_PERMISSIONS.redemptions },
  { tab: 'dashboard', label: 'Dashboard', permission: GOLDEN_PERMISSIONS.dashboard },
  { tab: 'masivos', label: 'Masivos', permission: GOLDEN_PERMISSIONS.bulkLoads },
];

readonly allowedTabs = computed(() => this.adminTabs.filter(item => canAccess(this.permissions(), item.permission)));
```

**Constructor:** ya no carga "Aprobaciones" de una vez, porque no todos la tienen. Quita esta línea:

```ts
this.loadAdminTabData(this.activeTab()); // ← se va
```

**`bootstrapUserContext`:** al recibir los permisos, abre la primera función permitida:

```ts
this.permissionsService
  .loadPermissions(user.mail)
  .then(result => {
    if (!result.hasError) {
      this.permissions.set(result.response);
      this.openFirstAllowedTab();
    }
  })
  .finally(() => {
    this.isLoadingPermissions.set(false);
  });
```

```ts
/** La primera función que tiene el rol. Antes siempre era "Aprobaciones". */
private openFirstAllowedTab(): void {
  const first = this.allowedTabs()[0];
  if (!first) {
    return;
  }

  this.activeTab.set(first.tab);
  this.loadAdminTabData(first.tab);
}
```

**`setActiveTab`:** primera línea:

```ts
if (!this.allowedTabs().some(item => item.tab === tab)) {
  return;
}
```

**`reloadApprovals`:** "Masivos" la llama al terminar una carga. Si el rol no tiene Aprobaciones, la API respondería 403. Primera línea:

```ts
if (!canAccess(this.permissions(), GOLDEN_PERMISSIONS.approvals)) {
  return;
}
```

### `presentation/admin/puntos-dorados-admin.component.html` ✏️

1. Reemplaza los 7 `<button class="tab-btn">` por:

```html
@for (item of allowedTabs(); track item.tab) {
<button type="button" class="tab-btn" [class.active]="activeTab() === item.tab"
  (click)="setActiveTab(item.tab)">{{ item.label }}</button>
}
```

2. Envuelve el `<div class="golden-page">` completo (pestañas y contenido) así:

```html
@if (isLoadingPermissions()) {
<div class="golden-page">
  <p class="text-body-secondary py-4 text-center">Cargando tus permisos…</p>
</div>
} @else if (allowedTabs().length === 0) {
<div class="golden-page">
  <section class="panel">
    <div class="panel-title">
      <h2>Sin funciones asignadas</h2>
      <p>Tu rol no tiene funciones de administración de Puntos Dorados, o no se pudieron cargar tus permisos.
        Recarga la página o pídele acceso a un administrador.</p>
    </div>
  </section>
</div>
} @else {
<div class="golden-page">
  <!-- … lo de hoy: pestañas (ya con el @for) y los bloques @if (activeTab() === '…') … -->
</div>
}
```

> Los bloques `@if (activeTab() === '…')` no cambian: `activeTab` solo puede ser una función permitida.

### Página de colaborador

No cambia: el guard de la ruta y los `[RequirePermission(UserPage)]` de la API bastan. Todas sus pestañas son de la misma página.

### Modal "Gestionar Roles" ✏️ — las funciones debajo de su página

**`features/roles-permissions/domain/roles-permissions.dto.ts`:**

```ts
export interface PermissionDto {
  permissionId: number;
  name: string;
  code: string;
  /** null = página. Con valor = función de esa página. */
  parentId?: number | null;
  path?: string;
  sortOrder?: number;
}
```

**`permissions-assignation-modal.component.ts`:** reemplaza `filteredModules` por:

```ts
/** Páginas con sus funciones debajo. La búsqueda encuentra páginas y funciones. */
moduleTree = computed(() => {
  const term = this.moduleSearch().trim().toLowerCase();
  const all = this.modules();
  const byOrder = (a: PermissionDto, b: PermissionDto) =>
    (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || a.name.localeCompare(b.name, 'es');
  const matches = (module: PermissionDto) => !term || module.name.toLowerCase().includes(term);

  return all
    .filter(module => !module.parentId)
    .sort(byOrder)
    .map(page => ({ page, functions: all.filter(child => child.parentId === page.permissionId).sort(byOrder) }))
    .filter(node => matches(node.page) || node.functions.some(matches));
});

/** Lista plana de lo visible: la usan "Seleccionar todos" y el contador. */
filteredModules = computed(() => this.moduleTree().flatMap(node => [node.page, ...node.functions]));
```

Y `toggleModule` marca o desmarca en cascada:

```ts
toggleModule(moduleId: number, checked: boolean) {
  const role = this.selectedRole();
  if (!role) return;
  const set = this.roleSelections.get(role.roleId)!;
  const module = this.modules().find(m => m.permissionId === moduleId);

  if (checked) {
    set.add(moduleId);
    // Una función sin su página no sirve: se marca la página.
    if (module?.parentId) set.add(module.parentId);
  } else {
    set.delete(moduleId);
    // Sin la página, sus funciones no sirven: se desmarcan.
    this.modules().filter(m => m.parentId === moduleId).forEach(child => set.delete(child.permissionId));
  }
}
```

**`savePermissions`:** hoy dice "Permisos asignados" aunque la API responda con error. Cámbialo, y descarta la caché local de permisos:

```ts
this.fecade.assignPermissionsToRole(payload)
  .then(res => {
    if (res.hasError) {
      this.notificationService.error('No se pudieron asignar los permisos: ' + res.errors.join(' '), 'toast');
      return;
    }

    // En este navegador se ven de inmediato; en los demás, en máximo 5 minutos o al recargar.
    this.permissionsService.invalidatePermissions();
    this.notificationService.success('Permisos asignados correctamente.', 'toast');
  })
  .catch(() => this.notificationService.error('Error al asignar permisos.', 'toast'))
  .finally(() => this.isSaving.set(false));
```

(Inyecta `private readonly permissionsService = inject(GlobalPermissionsService);`.)

**`permissions-assignation-modal.component.html`:** reemplaza el `<ul class="modules-list">` por:

```html
<ul class="modules-list">
  @for (node of moduleTree(); track node.page.permissionId) {
    <li class="module-item" [class.checked]="isModuleChecked(node.page.permissionId)">
      <label>
        <input type="checkbox"
          [checked]="isModuleChecked(node.page.permissionId)"
          (change)="toggleModule(node.page.permissionId, $any($event.target).checked)" />
        <i class="fa-solid fa-puzzle-piece module-icon"></i>
        <span>{{ node.page.name }}</span>
        @if (node.functions.length) {
          <span class="module-functions-count">{{ node.functions.length }} funciones</span>
        }
      </label>
    </li>

    @for (fn of node.functions; track fn.permissionId) {
      <li class="module-item module-item--function" [class.checked]="isModuleChecked(fn.permissionId)">
        <label>
          <input type="checkbox"
            [checked]="isModuleChecked(fn.permissionId)"
            (change)="toggleModule(fn.permissionId, $any($event.target).checked)" />
          <i class="fa-solid fa-turn-up fa-rotate-90 module-icon"></i>
          <span>{{ fn.name }}</span>
        </label>
      </li>
    }
  }
  @if (moduleTree().length === 0) {
    <li class="modules-empty">No se encontraron módulos</li>
  }
</ul>
```

**`permissions-assignation-modal.component.scss`:** agrega

```scss
.module-item--function {
  margin-left: 1.75rem;
  font-size: 0.9em;
}

.module-functions-count {
  margin-left: auto;
  color: var(--bs-secondary-color, #6b7280);
  font-size: 0.75rem;
}
```

---

## 10. Paso 8 — Orden de despliegue y uso

### Orden (para que nadie quede por fuera)

1. **SQL** (Paso 1). Revisa con la matriz que SuperUsuario tenga `roles-permissions`, las dos páginas y las 7 funciones.
2. **API** (Pasos 2 a 6). Desde aquí, las APIs exigen permiso.
3. **Frontend** (Paso 7).

Si algo sale mal en el paso 2, se puede volver atrás quitando los `[RequirePermission]`: las tablas nuevas no afectan nada más.

### Cómo se usa (ya sin tocar código)

1. Roles y permisos → **Gestionar roles** → **Nuevo rol**. Por ejemplo, "Aprobador Puntos Dorados".
2. Elige el rol y, bajo **Puntos Dorados - Admin**, marca **Aprobaciones**. La página se marca sola. → **Guardar**.
3. En la tabla de usuarios, cámbiale el rol a la persona.
4. La API lo aplica en máximo 1 minuto. Esa persona ve el cambio al recargar, o en máximo 5 minutos.

### Ejemplo de roles (es una sugerencia: se configura en la pantalla)

| Rol | Página colaborador | Aprob. | Categ. | Catálogo | Puntos | Redenc. | Dashboard | Masivos |
|---|---|---|---|---|---|---|---|---|
| SuperUsuario | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Administrador Puntos Dorados | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Aprobador Puntos Dorados | ✅ | ✅ | | | | | ✅ | |
| Compensación y Beneficio | ✅ | | | ✅ | | ✅ | ✅ | |
| Usuario / Aprobador | ✅ | | | | | | | |

---

## 11. Fase 2 (opcional): varios roles por persona

Hoy, una persona que es "Aprobador" de solicitudes y además administra Puntos Dorados necesita un rol combinado. Con varios roles por persona, sus permisos serían la suma:

| Pieza | Cambio |
|---|---|
| `dbo.user_roles` | Ya admite varios (la llave es `id_user, id_role`). |
| `UserPermissionReader` | Ya suma los permisos de todos los roles de la persona. |
| `GetRoleInfoByUser`, `GetPermissionsByUser` | Hoy toman **un** rol (`GetAsync`). Deberían leer todos. |
| `ChangeRole` / pantalla de usuarios | De "cambiar el rol" a "agregar o quitar roles" (selección múltiple). |
| `ValidateUserRequest` | Agregar o quitar **solo** el rol "Aprobador", sin tocar los demás. |
| Guard de compensación, `approver-page` y `ApproverService` | Pasarlos a permisos (`[RequirePermission]` y `canAccess`) en lugar de leer el nombre del rol. |

Es un cambio aparte, que toca Solicitudes. Esta guía funciona igual con uno o con varios roles.

---

## 12. Pruebas

**Base de datos**
- La matriz muestra a SuperUsuario con todo. `ux_menu_path` existe y no hay path repetidos.

**API** (en Swagger, con el token de una persona de prueba)
- **Rol "Aprobador Puntos Dorados"** (solo Aprobaciones):
  - `GET /api/GoldenRecognitionApprovals` → 200.
  - `GET /api/GoldenDashboard`, `POST /api/GoldenPoints/assignments` y `GET /api/GoldenRedemptions` → **403**.
- **Rol "Usuario":**
  - `GET /api/GoldenRecognitions/feed`, `POST /api/GoldenRedemptions` y `GET /api/GoldenRecognitionCategories` → 200.
  - Cualquier endpoint de administración → **403**.
- **Rol "Usuario" en roles y permisos:** `POST /api/Permissions/assign-permissions` con su propio correo → **403** (antes pasaba).
- **Cambio en caliente:**
  - Quitarle "Dashboard" a un rol desde el modal.
  - En menos de 1 minuto, `GET /api/GoldenDashboard` con ese rol → 403.

**Roles que se cambiaban solos**
- Persona con rol "Administrador Puntos Dorados" que es jefe en una solicitud:
  - Al abrir cualquier página **sigue** con su rol (antes pasaba a "Aprobador").
- Persona con rol "Usuario" que es jefe en una solicitud:
  - Pasa a "Aprobador", como antes.

**Frontend**
- **Rol solo con Aprobaciones y Dashboard:**
  - El admin muestra solo esas dos pestañas y abre en "Aprobaciones".
  - En el sidebar sale "Puntos Dorados - Admin", pero no las funciones.
- **Rol solo con Redenciones:** abre directo en "Redenciones" y el filtro de productos carga.
- **Rol sin la página de admin:** al escribir `/puntos-dorados-admin` en la URL vuelve a `/home`.
- **Rol con la página pero sin funciones:** sale "Sin funciones asignadas".
- **Carga en "Masivos" con un rol sin Aprobaciones:** termina sin errores, porque no intenta recargar aprobaciones.
- **Modal "Gestionar Roles":**
  - Las 7 funciones salen debajo de "Puntos Dorados - Admin".
  - Marcar una función marca la página. Desmarcar la página desmarca sus funciones.
  - Si la API responde con error, el modal lo dice (antes decía "asignados").
- **Llamar una API sin permiso** (por ejemplo, con la pestaña oculta por consola): el mensaje es "No tienes permiso para esta acción…".

---

## ✅ Checklist

**Base de datos**
- [ ] `PermissionsFunctions.sql`: columnas, índice, 7 funciones, permisos de SuperUsuario y página de colaborador.

**API**
- [ ] `Menu` + `MenuConfiguration` (`ParentId`, `SortOrder`, índice único).
- [ ] `ParentId` en `PermissionResponseDto`; `ParentId`, `Path` y `SortOrder` en `PermissionDto`.
- [ ] `IUserPermissionReader` + `UserPermissionReader` (caché de 1 minuto) y su registro.
- [ ] `RequirePermissionAttribute` + `RequirePermissionHandler`, registrado en `Program.cs`.
- [ ] `GoldenPermissions` y `RolesPermissionsConstants`.
- [ ] `[RequirePermission]` en Roles, Permissions y los 10 controladores de Puntos Dorados (tabla 7.2).
- [ ] `AssignPermissionToRole`: agrega las páginas de las funciones e invalida la caché.
- [ ] `ValidateUserRequest`: solo mueve "Usuario" ↔ "Aprobador".
- [ ] `ChangeRole` y `ModifyRole` invalidan la caché; `ChangeRole` sin el `Delete` doble.

**Frontend**
- [ ] `parentId` y `canAccess` en `menu-permissions-service.ts`.
- [ ] El sidebar filtra las funciones.
- [ ] `permissionGuard` activo en las dos rutas de Puntos Dorados.
- [ ] `GOLDEN_PERMISSIONS` en el dominio; el 403 en `toErrorMessage`.
- [ ] Admin: pestañas por permiso, primera permitida, "Sin funciones asignadas", `reloadApprovals` protegido.
- [ ] Modal "Gestionar Roles": árbol de páginas y funciones, cascada, error real e `invalidatePermissions()`.
