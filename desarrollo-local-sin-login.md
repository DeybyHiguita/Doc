# 🧪 Ambiente local sin login de Azure AD (modo `dev`)

**El problema:** en local, el login con el directorio activo no regresa a `https://localhost:4200`. Para probar hay que hacer dos cosas a mano:
- comentar `canMatch` y `canActivate` en `app.routes.ts`;
- pegar un token real en `environment.local.ts`, que vence en una hora.

Sin cuenta de MSAL, además, ninguna página tiene usuario: no cargan el menú, los permisos ni las notificaciones.

**La propuesta:** un **modo de autenticación por ambiente**. En local, la app entra con un **usuario de prueba** definido en `environment.local.ts`, y la API local lo reconoce sin Azure AD. En QA y producción todo sigue con MSAL. **No se comenta nada**: el modo lo decide la configuración de compilación que ya existe (`ng serve` usa `local`, `build:prod` usa `production`).

**Base:** el código real de `.claude/Puntos Dorados` (Angular) y `.claude/Puntos dorados api` (.NET 8).

---

## 1. Qué pasa hoy

| # | Qué se encontró | Consecuencia |
|---|---|---|
| 1 | **Guards comentados en 18 rutas.** Solo `home`, `users` y `requests-dashboard` tienen `MsalGuard`. | Ese archivo es el mismo que se despliega: **en el servidor tampoco hay guards** en esas páginas. Quien tenga la URL abre la página, aunque no tenga permiso. |
| 2 | **`AuthService.getAccessToken()` devuelve `environment.localToken` en `localhost`.** | Es un token real de Azure AD pegado en el código. Vence en ~1 hora y hay que copiar otro. Además, **queda en el repositorio**: un token no se debe subir nunca, aunque ya esté vencido. |
| 3 | **`UserInfoService.loadUserInfo()` depende de la cuenta activa de MSAL.** | En local devuelve `null`. Sin usuario no hay correo para la API, ni permisos, menú, notificaciones o nombre en el encabezado. |
| 4 | **Las consultas a Microsoft Graph** (personas del grupo, jefe, usuario por correo) usan ese mismo token. | El token es para la API, no para Graph: en local esas consultas fallan siempre. |
| 5 | **El `redirectUri` local es `https://localhost:4200`.** | Azure AD no regresa ahí porque esa dirección no está registrada en la aplicación de Azure. |

> **La alternativa "real":** registrar `https://localhost:4200` como *redirect URI* de tipo **SPA** en la aplicación del frontend en Azure (lo hace un administrador del tenant). Así el login funciona en local con MSAL. Sirve para probar el login mismo, pero sigue exigiendo una cuenta real por cada rol que quieras probar. El modo `dev` de esta guía no lo reemplaza: lo complementa.

---

## 2. La propuesta

```text
                         LOCAL (ng serve → environment.local.ts)          QA / PRODUCCIÓN
                         auth.mode = 'dev'                                auth.mode = 'msal'
Login                    "Entrar como [select de usuarios de prueba]"     Azure AD (como hoy)
Usuario de la página     environment.local.ts → devPeople                 MSAL + Graph (como hoy)
Token para la API        ninguno: encabezado X-Dev-User: correo           token de MSAL (como hoy)
API                      DevAuth (solo Development + localhost)           Azure AD (como hoy)
Graph (personas, jefe)   datos de prueba del mismo archivo                Graph (como hoy)
Guards                   activos (authGuard deja pasar, permissionGuard   activos
                         usa los permisos reales de tu base local)
```

### Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Dónde se elige el modo.** | En `environment.*.ts` (`auth.mode`). La configuración de compilación ya elige el archivo: no hay nada que comentar ni que acordarse de cambiar antes de desplegar. |
| 2 | **Dónde van los datos de prueba.** | En `environment.local.ts`, sección `auth.devPeople`: nombre, correo, cargo, área y cédula. Es lo que piden las páginas, el encabezado y los filtros de personas. |
| 3 | **Cambiar de usuario.** | En el login, un `<select>` "Entrar como". Así se prueba cada rol (SuperUsuario, Usuario, Aprobador…) sin tocar archivos. |
| 4 | **Cómo sabe la API quién es.** | Por el encabezado `X-Dev-User` con el correo, que agrega un interceptor solo en modo `dev`. La API lo acepta **solo** en Development, con `DevAuth:Enabled` y desde la misma máquina. |
| 5 | **Permisos y menú.** | Reales: la persona de prueba debe existir en `dbo.users` de tu base local con un rol. Si una página no abre en local, tampoco abriría en producción con ese rol. |
| 6 | **Guards.** | **Activos siempre.** Un `authGuard` nuevo reemplaza a `MsalGuard`: con MSAL hace lo mismo y en modo `dev` deja pasar. |
| 7 | **Seguridad.** | Varios candados independientes (sección 10). Ningún dato de prueba ni token llega a QA o a producción. |
| 8 | **Se borra** | `localToken` y `isLocalhost()`. |

---

## 3. Paso 1 — API: autenticación de desarrollo

### `WebApp/Authentication/DevAuthenticationHandler.cs` (nuevo)

```csharp
using System.Net;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace DOCCB.WebApp.Authentication
{
    /// <summary>
    /// SOLO DESARROLLO LOCAL. Autentica cada petición como la persona del encabezado X-Dev-User
    /// (o la de DevAuth:Email, por ejemplo desde Swagger), sin Azure AD.
    /// Se registra solo en Development con DevAuth:Enabled = true, y además solo acepta peticiones de la misma máquina.
    /// </summary>
    public sealed class DevAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder,
        IConfiguration configuration) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
    {
        public const string SchemeName = "DevAuth";
        public const string UserHeader = "X-Dev-User";

        private readonly IConfiguration _configuration = configuration;

        protected override Task<AuthenticateResult> HandleAuthenticateAsync()
        {
            // Tercer candado: aunque se activara por error en un servidor, solo responde a localhost.
            var remoteIp = Context.Connection.RemoteIpAddress;
            if (remoteIp is null || !IPAddress.IsLoopback(remoteIp))
            {
                return Task.FromResult(AuthenticateResult.Fail("DevAuth solo acepta peticiones locales."));
            }

            var defaultEmail = _configuration["DevAuth:Email"];
            var email = Request.Headers[UserHeader].FirstOrDefault();
            if (string.IsNullOrWhiteSpace(email))
            {
                email = defaultEmail;
            }

            if (string.IsNullOrWhiteSpace(email))
            {
                return Task.FromResult(AuthenticateResult.NoResult());
            }

            email = email.Trim();

            // Solo el correo viaja en el encabezado (los nombres con tildes no son válidos en un encabezado HTTP).
            var displayName = string.Equals(email, defaultEmail, StringComparison.OrdinalIgnoreCase)
                ? _configuration["DevAuth:DisplayName"] ?? email
                : email;

            // MicrosoftUserAuthenticatorHelper lee el correo de ClaimTypes.Name y el nombre de "name".
            var claims = new[]
            {
                new Claim(ClaimTypes.Name, email),
                new Claim("name", displayName),
                new Claim(ClaimTypes.GivenName, displayName),
                new Claim(ClaimTypes.Surname, string.Empty),
            };

            var principal = new ClaimsPrincipal(new ClaimsIdentity(claims, SchemeName));
            return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(principal, SchemeName)));
        }
    }
}
```

### `WebApp/Extensions/AzureAppExtensions.cs` ✏️

**Usings:**

```csharp
using DOCCB.WebApp.Authentication;
using Microsoft.AspNetCore.Authentication;
```

**`AddAzureAdAuthentication`:** el bloque nuevo va **al principio** del método:

```csharp
public static IServiceCollection AddAzureAdAuthentication(this IServiceCollection services, IConfiguration configuration, IHostEnvironment environment)
{
    // SOLO LOCAL: sin Azure AD (sección DevAuth de appsettings.Development.json).
    if (IsDevAuthEnabled(configuration, environment))
    {
        services.AddAuthentication(DevAuthenticationHandler.SchemeName)
            .AddScheme<AuthenticationSchemeOptions, DevAuthenticationHandler>(DevAuthenticationHandler.SchemeName, _ => { });
        services.AddAuthorization();
        return services;
    }

    var useAuthorization = configuration.GetValue<bool>("UseAutorization");
    // … lo de hoy, sin cambios …
}
```

**`UseAzureAdAuthentication`** y el método nuevo:

```csharp
public static IApplicationBuilder UseAzureAdAuthentication(this IApplicationBuilder app, IConfiguration configuration)
{
    var useAuthorization = configuration.GetValue<bool>("UseAutorization");
    var environment = app.ApplicationServices.GetRequiredService<IHostEnvironment>();

    if (useAuthorization || IsDevAuthEnabled(configuration, environment))
    {
        app.UseAuthentication();
    }

    app.UseAuthorization();

    return app;
}

/// <summary>Dos llaves: entorno Development y DevAuth:Enabled = true. En QA y producción siempre es false.</summary>
public static bool IsDevAuthEnabled(IConfiguration configuration, IHostEnvironment environment) =>
    environment.IsDevelopment() && configuration.GetValue<bool>("DevAuth:Enabled");
```

### `WebApp/Program.cs` ✏️ — aviso al arrancar

Después de `var app = builder.Build();`:

```csharp
if (AzureAdExtensions.IsDevAuthEnabled(builder.Configuration, app.Environment))
{
    app.Logger.LogWarning("DevAuth ACTIVO: la API acepta X-Dev-User sin Azure AD. Solo para desarrollo local.");
}
```

### `WebApp/appsettings.Development.json` ✏️

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "DevAuth": {
    "Enabled": true,
    "Email": "usuario.prueba@empresa.co",
    "DisplayName": "Usuario de prueba"
  }
}
```

- **`Email`:** es la persona que usa **Swagger**, que no envía `X-Dev-User`. El frontend siempre envía la persona elegida en el login.
- **Si cada desarrollador quiere la suya:** en *User Secrets* (`dotnet user-secrets set "DevAuth:Email" "mi.correo@empresa.co"`), sin cambiar el archivo.

### `WebApp/WebApp.csproj` ✏️ — que la configuración de desarrollo no se publique

```xml
<ItemGroup>
  <Content Update="appsettings.Development.json" CopyToPublishDirectory="Never" />
</ItemGroup>
```

> Con esto, aunque un servidor arrancara por error en `Development`, no tendría `DevAuth:Enabled` (y el handler, además, rechaza lo que no venga de la misma máquina).
>
> **CORS:** la política actual ya tiene `AllowAnyHeader()`, así que `X-Dev-User` pasa sin cambios.

---

## 4. Paso 2 — Frontend: el modo en cada ambiente

### `src/enviroments/auth-environment.ts` (nuevo)

```ts
/** msal = login con Azure AD (QA y producción). dev = usuario de prueba sin login (solo local). */
export type AuthMode = 'msal' | 'dev';

/** Una persona de prueba. Debe existir en dbo.users de la base local (corporative_email) con un rol. */
export interface DevPerson {
  name: string;
  email: string;
  jobTitle?: string;
  department?: string;
  /** Cédula, para las páginas que la piden (en Graph sale de homePage). */
  documentNumber?: string;
}

export interface AuthEnvironment {
  mode: AuthMode;
  /** Solo en modo dev. La primera es la que entra por defecto. */
  devPeople?: DevPerson[];
  /** Solo en modo dev: el "jefe" que devolvería Graph. */
  devManager?: { displayName: string; jobTitle: string; mail: string } | null;
}
```

### `environment.prod.ts`, `environment.qa.ts` y `enviroment.ts` ✏️

```ts
import { AuthEnvironment } from './auth-environment';

const auth: AuthEnvironment = { mode: 'msal' };

export const environment = {
  // … lo de hoy …
  auth,
};
```

Y **borra `localToken`** de los tres.

### `environment.local.ts` ✏️

```ts
import { AuthEnvironment } from './auth-environment';

// Personas de prueba: deben existir en dbo.users de tu base local (por corporative_email), activas y con el rol que quieras probar.
const auth: AuthEnvironment = {
  mode: 'dev',
  devPeople: [
    { name: 'Usuario de prueba', email: 'usuario.prueba@empresa.co', jobTitle: 'Desarrollador', department: 'Tecnología', documentNumber: '1000000001' },
    { name: 'Colaborador de prueba', email: 'colaborador.prueba@empresa.co', jobTitle: 'Analista', department: 'Gestión Humana', documentNumber: '1000000002' },
    { name: 'Aprobador de prueba', email: 'aprobador.prueba@empresa.co', jobTitle: 'Coordinador', department: 'Compensación', documentNumber: '1000000003' },
  ],
  devManager: { displayName: 'Aprobador de prueba', jobTitle: 'Coordinador', mail: 'aprobador.prueba@empresa.co' },
};

export const environment = {
  // … lo de hoy (applicationLocation, api, dev…) …
  auth,
};
```

**Borra `localToken`.**

> Usa correos que **existan** en tu base local. La consulta de la sección 9 te muestra cuáles tienes y con qué rol.

---

## 5. Paso 3 — Una sola pieza que sabe si estamos en modo `dev`

### `src/app/core/services/dev-auth.ts` (nuevo)

```ts
import { environment } from 'enviroments/enviroment';
import { DevPerson } from 'enviroments/auth-environment';

/** Encabezado que lee la API local (DevAuthenticationHandler). */
export const DEV_USER_HEADER = 'X-Dev-User';

/** Lo que devuelve getAccessToken() en modo dev. La API local no lo valida: autentica con X-Dev-User. */
export const DEV_ACCESS_TOKEN = 'dev-local';

const DEV_USER_KEY = 'dev-user-email';
const FALLBACK: DevPerson = { name: 'Usuario local', email: 'usuario.local@localhost' };

/**
 * true solo con auth.mode = 'dev' (environment.local.ts) y abierto desde localhost.
 * Si alguien desplegara un build con mode 'dev', fuera de localhost se ignora.
 */
export function isDevAuth(): boolean {
  if (environment.auth.mode !== 'dev') {
    return false;
  }

  // En el render del servidor (SSR) no hay window: vale el ambiente.
  if (typeof window === 'undefined') {
    return true;
  }

  const host = window.location.hostname;
  if (host === 'localhost' || host === '127.0.0.1') {
    return true;
  }

  console.error('[Auth] mode "dev" ignorado: solo funciona en localhost.');
  return false;
}

export function devPeople(): readonly DevPerson[] {
  return environment.auth.devPeople ?? [];
}

/** La persona elegida en el login. Por defecto, la primera de devPeople. */
export function currentDevPerson(): DevPerson {
  const people = devPeople();
  const saved = readSavedEmail();

  if (saved) {
    // Un correo que no está en la lista también sirve (por ejemplo, para probar con alguien más de la base).
    return people.find(person => sameEmail(person.email, saved)) ?? { name: saved, email: saved };
  }

  return people[0] ?? FALLBACK;
}

export function setCurrentDevPerson(email: string): void {
  try {
    localStorage.setItem(DEV_USER_KEY, email);
  } catch {
    // Navegación privada o almacenamiento bloqueado: se queda la primera persona.
  }
}

function readSavedEmail(): string | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage.getItem(DEV_USER_KEY);
  } catch {
    return null;
  }
}

function sameEmail(a: string, b: string): boolean {
  return a.trim().toLowerCase() === b.trim().toLowerCase();
}
```

### `src/app/core/interceptors/dev-auth.interceptor.ts` (nuevo)

```ts
import { HttpInterceptorFn } from '@angular/common/http';
import { environment } from 'enviroments/enviroment';
import { DEV_USER_HEADER, currentDevPerson, isDevAuth } from '@core/services/dev-auth';

/** Modo dev: cada petición a la API lleva el correo de la persona de prueba. En QA y producción no hace nada. */
export const devAuthInterceptor: HttpInterceptorFn = (req, next) => {
  if (!isDevAuth() || !req.url.startsWith(environment.api.baseUrl)) {
    return next(req);
  }

  return next(req.clone({ setHeaders: { [DEV_USER_HEADER]: currentDevPerson().email } }));
};
```

### `src/app/app.config.ts` ✏️

```ts
import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';
import { devAuthInterceptor } from '@core/interceptors/dev-auth.interceptor';

// …
provideHttpClient(withFetch(), withInterceptors([devAuthInterceptor])),
```

> **Ojo:** hoy `MsalInterceptor` está registrado como `HTTP_INTERCEPTORS`, pero **no se ejecuta**. `provideHttpClient` no tiene `withInterceptorsFromDi()`, y por eso cada servicio arma el encabezado `Authorization` a mano. Esta guía no lo cambia: el interceptor nuevo es funcional y sí se ejecuta.

---

## 6. Paso 4 — `AuthService` y `UserInfoService`

### `core/services/auth-msal.service.ts` ✏️

Al principio de `getAccessToken`, en lugar del bloque de `isLocalhost()`:

```ts
import { DEV_ACCESS_TOKEN, isDevAuth } from './dev-auth';

async getAccessToken(scopes: string[]): Promise<string> {
  // Local sin Azure AD: la API autentica con X-Dev-User (devAuthInterceptor), no con este valor.
  if (isDevAuth()) {
    return DEV_ACCESS_TOKEN;
  }

  // … lo de hoy (caché y acquireTokenSilent) …
}
```

Borra el método `isLocalhost()` y el `import { environment }` si queda sin uso.

### `core/services/user-info-msal.service.ts` ✏️

**Import:**

```ts
import { DevPerson } from 'enviroments/auth-environment';
import { currentDevPerson, devPeople, isDevAuth } from './dev-auth';
```

**Primera línea de cada método público:**

```ts
async loadUserInfo(): Promise<UserGraph | null> {
  // Sin caché: si se cambia de persona en el login, se ve de inmediato.
  if (isDevAuth()) {
    return this.toDevUserGraph(currentDevPerson());
  }
  // … lo de hoy …
}

async getUsersGroupFromGraph(): Promise<any[]> {
  if (isDevAuth()) {
    return devPeople().map(person => ({
      id: person.email,
      name: person.name,
      email: person.email.toLowerCase(),
      jobTitle: person.department ?? '', // igual que Graph: aquí va el área
      selected: false,
    }));
  }
  // … lo de hoy …
}

async getUserByEmail(email: string): Promise<UserGraph | null> {
  if (isDevAuth()) {
    const person = devPeople().find(item => item.email.toLowerCase() === email.trim().toLowerCase());
    return person ? this.toDevUserGraph(person) : null;
  }
  // … lo de hoy …
}

async loadManagerInfo(): Promise<ManagerGraph | null> {
  if (isDevAuth()) {
    return environment.auth.devManager ?? null;
  }
  // … lo de hoy …
}
```

**Privado nuevo:**

```ts
/** La persona de prueba con la misma forma que devuelve Graph. */
private toDevUserGraph(person: DevPerson): UserGraph {
  return {
    id: `dev-${person.email}`,
    displayName: person.name,
    mail: person.email,
    userPrincipalName: person.email,
    jobTitle: person.jobTitle ?? '',
    department: person.department ?? 'Usuario',
    mobilePhone: '',
    officeLocation: '',
    city: '',
    country: '',
    identificationNumber: person.documentNumber ?? '',
  };
}
```

Con esto, todo lo que hoy depende del usuario funciona en local sin cambiar ninguna página: el layout, el encabezado, `GlobalPermissionsService`, el menú, las notificaciones, los guards y el buscador de personas.

---

## 7. Paso 5 — Guards y rutas

### `shared/guards/auth.guard.ts` (nuevo)

```ts
import { inject } from '@angular/core';
import { CanMatchFn } from '@angular/router';
import { MsalGuard } from '@azure/msal-angular';
import { isDevAuth } from '@core/services/dev-auth';

/**
 * Exige sesión de Azure AD (lo mismo que MsalGuard).
 * En modo dev (local) deja pasar: la persona es la elegida en el login, de environment.local.ts.
 */
export const authGuard: CanMatchFn = () => {
  if (isDevAuth()) {
    return true;
  }

  return inject(MsalGuard).canMatch();
};
```

> En `@azure/msal-angular` 4, `MsalGuard.canMatch()` no recibe parámetros.

### `app.routes.ts` ✏️

1. **Imports:** quita `import { MsalGuard } from '@azure/msal-angular';` y agrega:

   ```ts
   import { authGuard } from '@shared/guards/auth.guard';
   ```

2. **Buscar y reemplazar** en el archivo (VS Code, `Ctrl+H`):

   | Buscar | Reemplazar por |
   |---|---|
   | `//    canMatch: [MsalGuard],` | `    canMatch: [authGuard],` |
   | `//    canActivate: [permissionGuard],` | `    canActivate: [permissionGuard],` |
   | `canMatch: [MsalGuard]` (`home`, `users` y `requests-dashboard`) | `canMatch: [authGuard]` |

   Así queda cada ruta:

   ```ts
   {
     path: 'requests',
     canMatch: [authGuard],
     canActivate: [permissionGuard],
     loadComponent: () =>
       import('@features/request/presentation/request-page/request-page-component').then(m => m.RequestPageComponent)
   },
   ```

3. **`login`** no lleva guard, como hoy.

> **`permissionGuard` activo en todas:** en local usa los permisos reales del rol de la persona de prueba en tu base. Si una página no abre, es que ese rol no tiene el módulo en `dbo.permissions`, y lo mismo pasaría en producción.
>
> Si alguna ruta debe abrirse sin módulo en `dbo.menu` (como `home` y `users`), déjala solo con `canMatch: [authGuard]`. Revisa también que cada `data.permissionPath` (`cargos-criticos`, `key-talent`, `approvers`…) exista en `dbo.menu`.

---

## 8. Paso 6 — Login, cerrar sesión y el aviso de modo local

### `features/auth/presentation/login/login.component.ts` ✏️

```ts
import { DevPerson } from 'enviroments/auth-environment';
import { currentDevPerson, devPeople, isDevAuth, setCurrentDevPerson } from '@core/services/dev-auth';

// Dentro de la clase:
readonly isDevAuth = isDevAuth();
readonly devPeople: readonly DevPerson[] = devPeople();
devEmail = currentDevPerson().email;
```

En `login()`, **después** del bloque que limpia el almacenamiento por versión y **antes** de `this.loading = true`:

```ts
// Local sin Azure AD: entra como la persona elegida.
if (this.isDevAuth) {
  setCurrentDevPerson(this.devEmail);
  this.router.navigateByUrl('/home');
  return;
}
```

> Va después de la limpieza por versión porque esa limpieza hace `localStorage.clear()`, y borraría la persona elegida.

### `login.component.html` ✏️ — antes del botón "Iniciar Sesión"

```html
@if (isDevAuth) {
<div class="dev-login">
  <span class="dev-login__badge">Modo local · sin Azure AD</span>
  <label class="dev-login__label" for="dev-user">Entrar como</label>
  <select id="dev-user" class="dev-login__select" (change)="devEmail = $any($event.target).value">
    @for (person of devPeople; track person.email) {
    <option [value]="person.email" [selected]="person.email === devEmail">
      {{ person.name }} — {{ person.jobTitle }}
    </option>
    }
  </select>
</div>
}
```

### `login.component.scss` ✏️

```scss
.dev-login {
  display: grid;
  gap: 0.35rem;
  margin-bottom: 1rem;
  padding: 0.75rem;
  border: 1px dashed #f5c518;
  border-radius: 0.5rem;
  background: rgb(245 197 24 / 0.08);
}

.dev-login__badge {
  justify-self: start;
  padding: 0.1rem 0.5rem;
  border-radius: 999px;
  background: #f5c518;
  color: #1f2937;
  font-size: 0.7rem;
  font-weight: 700;
  text-transform: uppercase;
}

.dev-login__label {
  font-size: 0.8rem;
  font-weight: 600;
}

.dev-login__select {
  width: 100%;
  padding: 0.45rem 0.6rem;
  border: 1px solid #d1d5db;
  border-radius: 0.375rem;
}
```

### `shared/components/sidebar/sidebar.component.ts` ✏️ — "Cerrar sesión"

Al inicio de `logout()`:

```ts
import { isDevAuth } from '@core/services/dev-auth';

private logout() {
  // Local sin Azure AD: no hay sesión que cerrar; vuelve al login para elegir otra persona.
  if (isDevAuth()) {
    this.router.navigateByUrl('/login');
    return;
  }

  // … lo de hoy (logoutRedirect) …
}
```

### `app.ts` ✏️ — que siempre se note el modo local (opcional, recomendado)

```ts
import { currentDevPerson, isDevAuth } from '@core/services/dev-auth';

@Component({
  // …
  template: `
    <router-outlet></router-outlet>
    @if (devAuth) {
      <div class="dev-auth-badge" title="environment.local.ts → auth.mode = 'dev'">
        Modo local · {{ devPersonName }}
      </div>
    }
  `,
})
export class App implements OnInit, OnDestroy {
  protected readonly devAuth = isDevAuth();

  protected get devPersonName(): string {
    return currentDevPerson().name;
  }
  // … lo de hoy …
}
```

En `app.scss`:

```scss
.dev-auth-badge {
  position: fixed;
  right: 0.75rem;
  bottom: 0.75rem;
  z-index: 9999;
  padding: 0.3rem 0.7rem;
  border-radius: 999px;
  background: #f5c518;
  color: #1f2937;
  font-size: 0.75rem;
  font-weight: 700;
  box-shadow: 0 2px 8px rgb(0 0 0 / 0.2);
  pointer-events: none;
}
```

> `app.ts` sigue inicializando MSAL igual: en modo `dev` no se usa, pero tampoco molesta.

---

## 9. Cómo se usa

### Una sola vez: las personas de prueba en tu base local

```sql
-- Revisa que existan, estén activas y tengan rol.
SELECT u.id, u.display_name, u.corporative_email, u.active, r.name AS rol
FROM   dbo.users u
LEFT JOIN dbo.user_roles ur ON ur.id_user = u.id
LEFT JOIN dbo.roles r       ON r.id = ur.id_role
WHERE  u.corporative_email IN ('usuario.prueba@empresa.co', 'colaborador.prueba@empresa.co', 'aprobador.prueba@empresa.co');
```

- Si no existen, créalas desde "Mis Datos" entrando con cada una, o con el script de usuarios de la API (`Users Inserts.sql`).
- Asígnales roles distintos (por ejemplo SuperUsuario, Usuario y Aprobador) para probar cada uno.

### Cada día

1. **API:** perfil `https` en Visual Studio (`https://localhost:7208`, `Development`). En la consola sale el aviso "DevAuth ACTIVO".
2. **Frontend:** `npm start` (`ng serve` usa la configuración `local`).
3. **En el login:** "Entrar como" → la persona → **Iniciar Sesión**. Ves su menú, sus permisos y sus notificaciones.
4. **Para probar otro rol:** "Cerrar sesión" → otra persona.
5. **Swagger:** funciona sin token, como la persona de `DevAuth:Email`.

---

## 10. Desplegar (no hay nada que cambiar)

| Candado | Dónde | Qué impide |
|---|---|---|
| 1 | `environment.prod.ts` y `environment.qa.ts` tienen `mode: 'msal'`, y `build:prod`/`build:qa` usan esos archivos | Que un build de servidor tenga modo `dev`. |
| 2 | `isDevAuth()` exige `localhost` | Aunque se desplegara un build con `mode: 'dev'`, fuera de `localhost` se ignora. |
| 3 | La API solo registra DevAuth en `Development` **y** con `DevAuth:Enabled` | En QA y producción el entorno no es `Development`. |
| 4 | `appsettings.Development.json` no se publica (`CopyToPublishDirectory="Never"`) | Aunque el servidor arrancara en `Development`, no habría `DevAuth:Enabled`. |
| 5 | El handler solo acepta peticiones de la misma máquina | Aunque todo lo anterior fallara, nadie de afuera podría hacerse pasar por otro. |

**Revisa una vez en el servidor:** que la variable `ASPNETCORE_ENVIRONMENT` no sea `Development` (en el `web.config` de la API o en el App Pool de IIS).

---

## 11. Pruebas

**Local (modo `dev`)**
- **Login:** `npm start` → `/login` muestra "Modo local · sin Azure AD" y el `select`. Al entrar va a `/home`, sin redirección a Microsoft.
- **Datos de la persona:** el encabezado muestra su nombre y cargo. Abajo a la derecha se ve "Modo local · {nombre}".
- **Menú:** el sidebar muestra los módulos del rol de esa persona en tu base local.
- **Notificaciones:** el contador carga (en DevTools → Network, la petición lleva `X-Dev-User`).
- **Guards:**
  - Entrar como una persona **sin** "Puntos Dorados - Admin" y escribir `/puntos-dorados-admin` en la URL → vuelve a `/home`.
  - Con SuperUsuario → abre.
- **Cerrar sesión:** vuelve al login sin pasar por Microsoft. Otra persona → otro menú.
- **Personas de Graph:**
  - Los filtros "Colaboradores" (dashboard, redenciones) muestran `devPeople`.
  - Solicitudes con aprobador muestran el "jefe" de `devManager`.
- **Swagger:** `GET /api/GoldenPoints/me/summary` sin token → 200 con la persona de `DevAuth:Email`.
- **Sin la API de Development** (`DevAuth:Enabled = false`): las peticiones responden 401. Así se confirma que la API no deja pasar a nadie sin el modo activo.

**Servidor (QA)**
- El login sigue yendo a Azure AD. No aparece el aviso de modo local.
- Una petición con `X-Dev-User` (Postman, sin token) → **401**.
- Las rutas que antes estaban sin guard (por ejemplo `/requests`) ahora piden sesión, y luego permiso.
- `appsettings.Development.json` no está en la carpeta publicada.

---

## ✅ Checklist

**API**
- [ ] `DevAuthenticationHandler` (con el candado de la misma máquina).
- [ ] `AddAzureAdAuthentication` / `UseAzureAdAuthentication` con `IsDevAuthEnabled`.
- [ ] Aviso en `Program.cs`.
- [ ] `DevAuth` en `appsettings.Development.json`.
- [ ] `appsettings.Development.json` fuera de la publicación (`.csproj`).

**Frontend**
- [ ] `auth-environment.ts`.
- [ ] `auth` en los 4 archivos de ambiente; `localToken` borrado.
- [ ] `dev-auth.ts` y `dev-auth.interceptor.ts`, registrado en `app.config.ts`.
- [ ] `AuthService` sin `isLocalhost()`.
- [ ] `UserInfoService` con los 4 métodos en modo `dev`.
- [ ] `authGuard` y `app.routes.ts` sin líneas comentadas.
- [ ] Login con "Entrar como", logout local y aviso en `app.ts`.

**Una vez**
- [ ] Personas de prueba en `dbo.users` local con roles distintos.
- [ ] `ASPNETCORE_ENVIRONMENT` del servidor revisado.
