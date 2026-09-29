# 📚 CRUD de cursos (Angular 20 + Bootstrap 5)

Guía paso a paso para construir la página de **gestión de cursos** del requerimiento **#453**:

- Crear un curso con **nombre**, **modalidad** (Virtual / Presencial) e **ID del sistema externo** opcional.
- Agregar el **ID externo después** de crear el curso, sin abrir el formulario completo.
- Asignar **grupos de usuarios**, cada uno con su **fecha límite de finalización**.
- **Actualizar** y **eliminar** cursos.

La página es un catálogo de tarjetas animadas con filtros rápidos y un panel lateral que se desliza para crear y editar.

- **Stack:** Angular 20 · standalone · signals · OnPush · Reactive Forms tipados · Bootstrap 5.3 · Font Awesome · SweetAlert2 · SSR · MSAL
- **Alias:** `@core`, `@shared`, `@features`, `@shared-styles`
- **Colores:** todos salen de **un solo bloque de tokens** (sección 4). Ahí conectas tus variables; ningún otro archivo tiene colores escritos a mano.

> **Listado en tabla:** para la pantalla con el diseño de Módulo de Certificados (tabla, filtros y filtros compartibles por URL), ver [listado-cursos-angular.md](listado-cursos-angular.md). Esa página reemplaza a `courses-page` y reutiliza el panel de edición de esta guía.

---

## 1. 🧐 Revisión crítica del requerimiento

Estos son los huecos del ticket y la decisión que toma esta guía. Si alguna no te sirve, cámbiala **antes** de construir.

| # | Hueco o riesgo | Decisión |
|---|---|---|
| 1 | **"Cursos independientes por modalidad".** Si se puede cambiar la modalidad de un curso que ya tiene usuarios, esos usuarios pasan de un curso virtual a uno presencial sin enterarse. | La modalidad se elige **al crear** y queda bloqueada al editar. Para la otra modalidad se crea otro curso. Se permite el mismo nombre en ambas modalidades; el backend valida que no se repita **nombre + modalidad**. |
| 2 | **"El ID se agrega después".** Si para agregarlo hay que abrir el formulario completo, nadie lo hace y el dato queda vacío. | Cada tarjeta tiene una acción rápida **Agregar ID externo** que edita solo ese campo, en línea. |
| 3 | **"Presencial no siempre tiene ID".** Marcar como pendiente todo curso sin ID llenaría la pantalla de alertas falsas. | Solo los **virtuales** sin ID se marcan como *pendientes* y cuentan en el indicador. Los presenciales sin ID se muestran neutros ("Opcional"). Se configura en un solo lugar: `externalIdExpected`. |
| 4 | **ID externo duplicado.** Dos cursos con el mismo ID del sistema externo rompen cualquier sincronización posterior. | Índice único filtrado en BD (`WHERE ExternalId IS NOT NULL`). El backend responde `409` y el front muestra el mensaje. Sin espacios, máximo 50 caracteres. |
| 5 | **"Fecha límite para el grupo asignado"** — ¿un grupo por curso o varios? | Varios **grupos de asignación** por curso, cada uno con su fecha. Cubre el caso real: un grupo en octubre y otro en diciembre para el mismo curso. |
| 6 | **Un usuario en dos grupos del mismo curso** tendría dos fechas límite distintas. | No se permite. El formulario lo valida y el buscador oculta a quien ya está en otro grupo. El backend también lo valida. |
| 7 | **Fecha límite con hora y zona.** Un `Date` de JavaScript convertido a UTC puede mover el 15 de octubre al 14. | Se maneja como **fecha sin hora** (`yyyy-MM-dd`) de punta a punta: `input type="date"` en el front y `DateOnly` en .NET. |
| 8 | **Fechas pasadas al editar.** Si se exige fecha futura siempre, no se podría guardar un curso con un grupo que ya venció. | La regla "no puede ser pasada" aplica solo a fechas que el usuario **cambia**. Las que llegan del servidor se respetan. |
| 9 | **De dónde salen los usuarios.** Llamar a Microsoft Graph desde el navegador exige pedir `User.Read.All` a cada usuario y expone el directorio completo. | El backend expone `/api/users/search` y consulta Graph con permisos de aplicación. Se guarda el **object id** de Entra ID, no el correo, porque el correo cambia. |
| 10 | **Eliminar un curso con usuarios** borra el historial de quién debía tomarlo. | Si tiene asignaciones, el backend hace **borrado lógico** (`IsActive = false`). La confirmación le avisa al usuario cuántas personas tiene asignadas. |
| 11 | **Volumen del catálogo.** Traer todos los cursos para filtrar en el navegador se vuelve lento. | Búsqueda, filtros y paginación **en el servidor**. Páginas de 12. |
| 12 | **Nombres con HTML** pintados con `innerHTML` o con `html` de SweetAlert2 son XSS. | Solo interpolación `{{ }}` y la opción `text` de SweetAlert2, nunca `html`. |
| 13 | **Ticket cortado.** La foto termina en el punto **b** ("La información de los cursos se debe poder actualizar"). | Esta guía cubre crear, consultar, actualizar y eliminar. **Revisa si hay puntos c, d… en el ticket** antes de estimar. |

**Fuera de alcance, pero pregúntalo:** avance de cada usuario en el curso, notificar al usuario cuando lo asignan, carga masiva de usuarios desde Excel, asignar por grupo de Entra ID en lugar de persona por persona, y quién puede ver y editar cursos (permisos por rol).

---

## 2. 🎨 Diseño

### La idea

Un catálogo vivo: los números de arriba **también son filtros**, las tarjetas entran en cascada, se elevan al pasar el mouse y el color de cada una dice su modalidad sin tener que leerla. Crear y editar pasa en un panel lateral para no perder de vista el catálogo.

### Escritorio

```text
┌──────────────────────────────────────────────────────────────────────────┐
│  COMPENSACIÓN Y BENEFICIOS                                               │
│  Cursos                                                 [＋ Nuevo curso]  │
│  Crea cursos, asígnalos a grupos y registra el ID externo.               │
│                                                                          │
│  ┌──────────┐ ┌──────────┐ ┌─────────────┐ ┌───────────────────┐         │
│  │ ▣ 24     │ │ 💻 15     │ │ 🏫 9         │ │ ⏳ 3               │  ← filtros│
│  │ Total    │ │ Virtuales│ │ Presenciales│ │ ID externo pend.  │         │
│  └──────────┘ └──────────┘ └─────────────┘ └───────────────────┘         │
│  ███████████████████████████░░░░░░░░░░░░░░░░   62 % virtual               │
├──────────────────────────────────────────────────────────────────────────┤
│  [🔍 Buscar por nombre o ID externo   ]   ( Todas │ Virtual │ Presencial )│  ← sticky
├──────────────────────────────────────────────────────────────────────────┤
│  ┌▌───────────────────┐ ┌▌───────────────────┐ ┌▌───────────────────┐     │
│  ▌ 💻 VIRTUAL     ✎ 🗑 │ ▌ 🏫 PRESENCIAL  ✎ 🗑 │ ▌ 💻 VIRTUAL     ✎ 🗑 │     │
│  ▌ Excel avanzado     │ ▌ Primeros auxilios │ ▌ Liderazgo          │     │
│  ▌ 🔗 LMS-2231     ✎   │ ▌ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐ │ ▌ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐  │     │
│  ▌                    │ ▌ ╎＋ ID externo   ╎ │ ▌ ╎＋ ID externo ✨ ╎  │ ← pendiente
│  ▌                    │ ▌ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘ │ ▌ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘  │     │
│  ▌ 👥 32 · Vence en 5d │ ▌ 👥 12 · 15 dic     │ ▌ 👥 0               │     │
│  └────────────────────┘ └────────────────────┘ └────────────────────┘     │
│                                                                          │
│              [‹ Anterior]   Página 1 de 2 · 24 cursos   [Siguiente ›]     │
└──────────────────────────────────────────────────────────────────────────┘
```

### Panel de crear / editar

Se desliza desde la derecha con un leve rebote. En móvil ocupa toda la pantalla.

```text
                               ┌──────────────────────────────────┐
                               │ NUEVO CURSO                   ✕  │
                               │ Excel avanzado                   │ ← el título sigue al nombre
                               ├──────────────────────────────────┤
                               │ ① Datos del curso                │
                               │ Nombre del curso                 │
                               │ [Excel avanzado______________]   │
                               │                        14/150    │
                               │ Modalidad                        │
                               │ ┌──────────────┐┌──────────────┐ │
                               │ │ 💻 Virtual  ✔ ││ 🏫 Presencial │ │
                               │ │ Plataforma   ││ En sitio     │ │
                               │ └──────────────┘└──────────────┘ │
                               │ ID del sistema externo (opcional)│
                               │ [____________________________]   │
                               │ Si aún no lo tienes, agrégalo…   │
                               │                                  │
                               │ ② Usuarios asignados   [32 usu.] │
                               │ ┌ Grupo 1 · 30 usuarios ──── 🗑 ┐│
                               │ │ Fecha límite  Usuarios          ││
                               │ │ [2026-10-30]  (AP✕)(JM✕)[busca]││
                               │ └─────────────────────────────────┘│
                               │ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐ │
                               │ ╎      ＋ Agregar grupo         ╎ │
                               │ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘ │
                               ├──────────────────────────────────┤
                               │            [Cancelar] [✔ Crear]  │ ← fijo abajo
                               └──────────────────────────────────┘
```

### Coreografía de animaciones

| Elemento | Qué hace | Duración |
|---|---|---|
| Tarjetas | Entran en cascada (sube + aparece). Máximo 8 escalones para no hacer esperar. | 450 ms + 45 ms por tarjeta |
| Tarjeta en hover | Se eleva 4 px, la barra lateral crece de 35 % a 100 % y aparece un brillo del color de su modalidad. | 250 ms |
| Indicadores | Se elevan en hover; el activo queda con borde y fondo del color de su tono. | 200 ms |
| Barra de proporción | Crece hasta el porcentaje de cursos virtuales cada vez que cambian los datos. | 600 ms |
| Selector de modalidad | La píldora de fondo se desliza hasta la opción elegida. | 350 ms con resorte |
| ID pendiente | Un destello recorre el botón punteado cada 3 s, para que se note sin molestar. | 3 s en bucle |
| Panel | Entra desde la derecha con resorte; sale rápido y sin rebote. | 380 ms / 180 ms |
| Grupos y chips | Aparecen con un pequeño "pop" al agregarlos. | 250 ms |
| Recarga con datos | Las tarjetas se atenúan en lugar de desaparecer, para que no salte la página. | 200 ms |

Todo se anima solo con `transform`, `opacity` y `width` de la barra. Con `prefers-reduced-motion` todo queda en un fundido corto.

### Los cuatro estados de la zona de resultados

```text
PRIMERA CARGA                 VACÍO                        ERROR
┌─────────────────────┐       ┌─────────────────────┐      ┌─────────────────────┐
│ ▓▓▓▓▓▓  ▓▓▓▓▓▓      │       │        📚 (flota)    │      │  ⚠ No se pudieron   │
│ ▓▓▓▓▓▓▓▓▓▓▓▓        │       │  Aún no hay cursos  │      │    cargar los cursos│
│ ▓▓▓▓  ▓▓▓▓▓▓▓▓      │       │  [＋ Crear el primero]│      │    [ Reintentar ]   │
└─────────────────────┘       │                     │      └─────────────────────┘
  6 tarjetas esqueleto        │ con filtros activos: │
                              │  "Sin resultados"   │
                              │  [Limpiar filtros]  │
                              └─────────────────────┘
```

Con datos ya cargados, un cambio de filtro o de página **no** vuelve al esqueleto: atenúa las tarjetas actuales mientras llega la respuesta.

### Accesibilidad

- Los indicadores son botones con `aria-pressed`; el selector de modalidad son radios reales (`btn-check`), navegables con flechas.
- El buscador de usuarios es un `combobox` con `aria-activedescendant`: ↑ ↓ para moverse, Enter para agregar, Retroceso con el campo vacío quita el último chip, Esc limpia la búsqueda.
- El panel es `role="dialog"` con `aria-modal`, recibe el foco al abrir, cierra con Esc y devuelve el foco al botón que lo abrió. Cerrado queda `inert`.
- La zona de resultados tiene `aria-live="polite"` y `aria-busy` mientras carga.
- La modalidad no se comunica solo con color: siempre va con ícono y texto.
- Foco visible en todos los controles; no se elimina el `outline`.

### Reglas de estilo del proyecto

- Sin `ngClass` ni `ngStyle`: `[class.is-active]`, `[attr.data-tone]` y `[style.--variable]`.
- Utilidades de Bootstrap primero; SCSS propio solo para lo que Bootstrap no cubre.
- Los colores de la feature solo se leen de los tokens `--cu-*`. Los tintes se calculan con `color-mix()`, así que tus variables pueden estar en hex, rgb u hsl.

---

## 3. 📁 Archivos

```text
src/app/shared/
└── utils/
    ├── api-response.ts                        ⭐ envelope + unwrap + mensajes de error (reutilizable)
    └── date-only.ts                           fechas yyyy-MM-dd sin corrimiento de zona

src/app/features/courses/
├── domain/
│   ├── course-modality.enum.ts
│   ├── course-modality.config.ts              ⭐ etiqueta, ícono, tono y regla del ID por modalidad
│   ├── course.model.ts
│   ├── course-due.ts                          estado y texto de la fecha límite
│   ├── course.repository.ts                   ⭐ contrato de datos de cursos
│   └── users-directory.repository.ts          contrato de búsqueda de usuarios
├── infraestructure/
│   ├── course.dto.ts
│   ├── course.mapper.ts
│   ├── courses.service.ts                     implementa CourseRepository
│   ├── users-directory.service.ts             implementa UsersDirectoryRepository (Entra ID vía backend)
│   └── courses.providers.ts                   conecta cada contrato con su implementación
├── application/
│   ├── courses.facade.ts                      ⭐ estado de la página: consulta, lista, panel
│   └── course-form.ts                         ⭐ formulario tipado + validadores
└── presentation/
    ├── course-feedback.ts                     toasts y confirmaciones (SweetAlert2)
    ├── courses-page/                          ⭐ la página + TOKENS DE COLOR
    │   ├── courses-page.component.ts
    │   ├── courses-page.component.html
    │   └── courses-page.component.scss
    ├── course-card/
    │   ├── course-card.component.ts
    │   ├── course-card.component.html
    │   └── course-card.component.scss
    ├── course-editor/                         panel lateral de crear / editar
    │   ├── course-editor.component.ts
    │   ├── course-editor.component.html
    │   └── course-editor.component.scss
    └── user-picker/                           buscador con chips (ControlValueAccessor)
        ├── user-picker.component.ts
        ├── user-picker.component.html
        └── user-picker.component.scss
```

> Si ya creaste `ApiResponse` y `unwrap` dentro de `features/notifications` (guía del centro de notificaciones), muévelos a `@shared/utils/api-response.ts` y actualiza ese import. Así no quedan dos copias.

### Reutiliza lo que ya existe en `shared`

La arquitectura pide reutilizar `shared/components` y `shared/services` antes de crear piezas nuevas. Esta guía trae su propia versión de cada pieza por si la de `shared` no cubre el caso: **revisa primero la existente** y quédate con la de esta guía solo si no sirve.

| Necesidad | Ya existe en el proyecto | Pieza de esta guía |
|---|---|---|
| Paginación | `shared/components/pagination` | `<nav class="pager">` de la página |
| Carga con esqueleto | `shared/components/skeleton-loader` | `.skeleton-card` y esqueleto del panel |
| Confirmar eliminar o descartar | `shared/components/confirmation-dialog-component` | `confirmDanger` en `course-feedback.ts` |
| Toasts de éxito y error | `shared/services/global-notification-alerts.service.ts` y `notification.service.ts` | `notifySuccess` y `notifyError` en `course-feedback.ts` |
| Traducir errores HTTP a mensajes | `shared/services/http-error-handle.service.ts` | `toErrorMessage` en `api-response.ts` |

Si usas la pieza de `shared`, reemplaza las llamadas de esta guía y borra la propia. Así la pantalla se ve y se comporta igual que el resto de la aplicación.

---

## 4. Paso 1 — 🎨 Tokens de color: conecta tus variables

Este bloque vive en el `:host` de la página. Las variables CSS se heredan por el DOM, así que la tarjeta, el panel y el buscador de usuarios las leen sin importar nada.

**Es el único lugar donde tocas colores.** Por defecto apuntan a las variables de Bootstrap; reemplaza cada `var(--bs-…)` por la tuya.

```scss
// courses-page.component.scss (inicio del archivo)
:host {
  // ══ Tokens de color — reemplaza por tus variables ══════════════════
  --cu-accent: var(--bs-primary);          // botones, foco, indicador "Total"
  --cu-virtual: var(--bs-primary);         // todo lo de modalidad Virtual
  --cu-onsite: var(--bs-success);          // todo lo de modalidad Presencial
  --cu-warning: var(--bs-warning);         // ID pendiente, vence pronto
  --cu-danger: var(--bs-danger);           // eliminar, vencido, errores
  --cu-surface: var(--bs-body-bg);         // fondo de tarjetas y panel
  --cu-surface-alt: var(--bs-tertiary-bg); // fondos secundarios, esqueletos
  --cu-border: var(--bs-border-color-translucent);
  --cu-text: var(--bs-body-color);
  --cu-muted: var(--bs-secondary-color);

  // ══ Forma y movimiento ════════════════════════════════════════════
  --cu-radius: 1rem;
  --cu-radius-sm: 0.625rem;
  --cu-shadow: 0 1px 2px rgb(0 0 0 / 0.04), 0 4px 16px rgb(0 0 0 / 0.06);
  --cu-shadow-lift: 0 2px 4px rgb(0 0 0 / 0.05), 0 18px 36px -8px rgb(0 0 0 / 0.16);
  --cu-ease-spring: cubic-bezier(0.2, 0.9, 0.3, 1.15);
  --cu-ease-out: cubic-bezier(0.2, 0.8, 0.2, 1);
  --cu-z-drawer: 1060;

  display: block;
}
```

Ejemplo, si tus variables se llaman `--color-brand`, `--color-teal` y `--color-surface`:

```scss
--cu-accent: var(--color-brand);
--cu-virtual: var(--color-brand);
--cu-onsite: var(--color-teal);
--cu-surface: var(--color-surface);
```

Cómo se usan en el resto de archivos:

| Necesidad | Fórmula |
|---|---|
| Fondo suave de un tono | `color-mix(in srgb, var(--tone) 12%, transparent)` |
| Borde con tono | `color-mix(in srgb, var(--tone) 35%, var(--cu-border))` |
| Texto con tono legible | `color-mix(in srgb, var(--tone) 80%, var(--cu-text))` |
| Tono de un componente | `--tone: var(--cu-virtual)` según `data-tone` |

> Si tus variables son de SCSS (`$primary`) y no CSS (`--primary`), asígnalas con interpolación: `--cu-accent: #{$primary};`. En ese caso importa el archivo con `@use '@shared-styles/...' as *;` al inicio.

---

## 5. Paso 2 — Shared: respuesta de la API y fechas

### `shared/utils/api-response.ts`

```ts
import { HttpErrorResponse } from '@angular/common/http';

/** Envelope estándar del backend (ResponseDto serializado en camelCase). */
export interface ApiResponse<T> {
  hasError: boolean;
  errors?: string[] | null;
  response: T;
}

export function unwrap<T>(response: ApiResponse<T>): T {
  if (response.hasError) {
    throw new Error(response.errors?.join(' ') || 'No se pudo completar la operación.');
  }
  return response.response;
}

/** Convierte cualquier error en un mensaje que se le puede mostrar al usuario. */
export function toErrorMessage(error: unknown, fallback = 'No se pudo completar la operación.'): string {
  if (error instanceof HttpErrorResponse) {
    const serverErrors = (error.error as Partial<ApiResponse<unknown>> | null)?.errors;
    if (serverErrors?.length) return serverErrors.join(' ');

    switch (error.status) {
      case 0:
        return 'No hay conexión con el servidor. Revisa tu red e intenta de nuevo.';
      case 403:
        return 'No tienes permiso para hacer esta acción.';
      case 404:
        return 'El registro ya no existe. Recarga la página.';
      case 409:
        return 'Ya existe un registro con esos datos.';
      default:
        return fallback;
    }
  }

  if (error instanceof Error && error.message) return error.message;
  return fallback;
}
```

### `shared/utils/date-only.ts`

```ts
/**
 * Fechas sin hora en formato yyyy-MM-dd.
 * Nunca pasan por toISOString(): en Colombia (UTC-5) eso convierte
 * "30 de octubre a medianoche" en "29 de octubre".
 */

export function toIsoDate(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

export function todayIso(): string {
  return toIsoDate(new Date());
}

/** Días entre hoy y la fecha. Negativo si ya pasó. */
export function daysUntil(iso: string, from = new Date()): number {
  const [y, m, d] = iso.split('-').map(Number);
  const target = Date.UTC(y, m - 1, d);
  const base = Date.UTC(from.getFullYear(), from.getMonth(), from.getDate());
  return Math.round((target - base) / 86_400_000);
}

const formatter = new Intl.DateTimeFormat('es-CO', { day: 'numeric', month: 'short', year: 'numeric' });

export function formatIsoDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  return formatter.format(new Date(y, m - 1, d));
}
```

---

## 6. Paso 3 — Domain

### `domain/course-modality.enum.ts`

Los valores deben ser **iguales** a los que envía el backend.

```ts
export enum CourseModality {
  Virtual = 'VIRTUAL',
  Onsite = 'PRESENCIAL',
}

export const COURSE_MODALITIES = Object.values(CourseModality) as CourseModality[];
```

### `domain/course-modality.config.ts` — ⭐ el comportamiento de cada modalidad

`Record<CourseModality, …>`: si agregas una modalidad al enum y no la configuras aquí, **no compila**.

```ts
import { CourseModality } from './course-modality.enum';

export type ModalityTone = 'virtual' | 'onsite';

export interface ModalityConfig {
  readonly label: string;
  readonly plural: string;
  readonly hint: string;
  /** Clase de Font Awesome, sin el prefijo fa-solid. */
  readonly icon: string;
  /** Se traduce a --cu-virtual / --cu-onsite en el CSS. */
  readonly tone: ModalityTone;
  /** true = un curso sin ID externo se muestra como pendiente y cuenta en el indicador. */
  readonly externalIdExpected: boolean;
  readonly externalIdHint: string;
}

export const COURSE_MODALITY_CONFIG: Record<CourseModality, ModalityConfig> = {
  [CourseModality.Virtual]: {
    label: 'Virtual',
    plural: 'Virtuales',
    hint: 'Se toma en la plataforma externa',
    icon: 'fa-laptop',
    tone: 'virtual',
    externalIdExpected: true,
    externalIdHint: 'Si aún no lo tienes, guarda el curso y agrégalo cuando los equipos externos lo aprueben.',
  },
  [CourseModality.Onsite]: {
    label: 'Presencial',
    plural: 'Presenciales',
    hint: 'Sesiones en sitio',
    icon: 'fa-chalkboard-user',
    tone: 'onsite',
    externalIdExpected: false,
    externalIdHint: 'Los cursos presenciales no siempre tienen ID externo. Déjalo vacío si no aplica.',
  },
};
```

### `domain/course.model.ts`

```ts
import { CourseModality } from './course-modality.enum';

/** Usuario de Entra ID. id = object id (oid), no el correo. */
export interface AssignedUser {
  readonly id: string;
  readonly displayName: string;
  readonly email: string | null;
  readonly jobTitle?: string | null;
}

export interface CourseAssignment {
  readonly id: number | null;
  /** yyyy-MM-dd */
  readonly dueDate: string;
  readonly users: readonly AssignedUser[];
}

/** Lo que muestra cada tarjeta del listado. */
export interface CourseSummary {
  readonly id: number;
  readonly name: string;
  readonly modality: CourseModality;
  readonly externalId: string | null;
  readonly assignedCount: number;
  /** Próxima fecha límite vigente; si todas vencieron, la última. yyyy-MM-dd */
  readonly nextDueDate: string | null;
}

export interface CourseDetail {
  readonly id: number;
  readonly name: string;
  readonly modality: CourseModality;
  readonly externalId: string | null;
  readonly assignments: readonly CourseAssignment[];
}

/** Lo que el formulario entrega para crear o actualizar. */
export interface CourseDraft {
  readonly name: string;
  readonly modality: CourseModality;
  readonly externalId: string | null;
  readonly assignments: ReadonlyArray<{
    readonly id: number | null;
    readonly dueDate: string;
    readonly userIds: readonly string[];
  }>;
}

export interface CourseStats {
  readonly total: number;
  readonly virtual: number;
  readonly onsite: number;
  /** Solo cursos cuya modalidad espera ID externo y no lo tienen. */
  readonly pendingExternalId: number;
}

export interface CourseQuery {
  readonly search: string;
  readonly modality: CourseModality | null;
  readonly pendingExternalId: boolean;
  readonly page: number;
  readonly pageSize: number;
}

export interface CoursePage {
  readonly items: readonly CourseSummary[];
  readonly total: number;
  readonly stats: CourseStats;
}
```

### `domain/course-due.ts`

Estado y texto de la fecha límite. Lo usan la tarjeta y la tabla del listado, así la regla de "vence pronto" vive en un solo lugar.

```ts
import { daysUntil, formatIsoDate } from '@shared/utils/date-only';

export type DueState = 'ok' | 'soon' | 'overdue';

export interface DueInfo {
  readonly state: DueState;
  /** 30 oct 2026 */
  readonly date: string;
  /** En 5 días, Vence hoy, Venció hace 2 días */
  readonly relative: string;
}

export function describeDue(iso: string | null, today = new Date()): DueInfo | null {
  if (!iso) return null;

  const days = daysUntil(iso, today);
  const date = formatIsoDate(iso);
  const plural = (n: number) => (n === 1 ? 'día' : 'días');

  if (days < 0) return { state: 'overdue', date, relative: `Venció hace ${-days} ${plural(-days)}` };
  if (days === 0) return { state: 'soon', date, relative: 'Vence hoy' };
  if (days <= 7) return { state: 'soon', date, relative: `En ${days} ${plural(days)}` };
  return { state: 'ok', date, relative: `En ${days} días` };
}
```

### `domain/course.repository.ts` — ⭐ contrato de datos

La facade depende de este contrato, no del servicio HTTP. Así la capa de aplicación no conoce `HttpClient`, y en las pruebas se reemplaza por un doble sin tocar la red.

```ts
import { Observable } from 'rxjs';
import { CourseDetail, CourseDraft, CoursePage, CourseQuery } from './course.model';

export abstract class CourseRepository {
  abstract list(query: CourseQuery): Observable<CoursePage>;
  abstract getById(id: number): Observable<CourseDetail>;
  abstract create(draft: CourseDraft): Observable<number>;
  abstract update(id: number, draft: CourseDraft): Observable<void>;
  abstract setExternalId(id: number, externalId: string): Observable<void>;
  abstract remove(id: number): Observable<void>;
}
```

### `domain/users-directory.repository.ts`

```ts
import { Observable } from 'rxjs';
import { AssignedUser } from './course.model';

export abstract class UsersDirectoryRepository {
  abstract search(term: string, top?: number): Observable<AssignedUser[]>;
}
```

> Son clases abstractas y no interfaces porque una interfaz de TypeScript no existe en tiempo de ejecución, y Angular necesita un valor real para usarlo como token de inyección.

---

## 7. Paso 4 — Infrastructure

### `infraestructure/course.dto.ts`

Ajusta los nombres a lo que responde tu API.

```ts
export interface CourseListItemDto {
  courseId: number;
  name: string;
  modality: string;
  externalId: string | null;
  assignedUsersCount: number;
  nextDueDate: string | null;
}

export interface CourseStatsDto {
  total: number;
  virtual: number;
  onsite: number;
  pendingExternalId: number;
}

export interface CoursePageDto {
  items: CourseListItemDto[];
  totalCount: number;
  stats: CourseStatsDto;
}

export interface CourseUserDto {
  userId: string;
  displayName: string;
  email: string | null;
  jobTitle?: string | null;
}

export interface CourseAssignmentDto {
  assignmentId: number;
  dueDate: string;
  users: CourseUserDto[];
}

export interface CourseDetailDto {
  courseId: number;
  name: string;
  modality: string;
  externalId: string | null;
  assignments: CourseAssignmentDto[];
}

/** POST envía modality; PUT no la envía (queda bloqueada al editar). */
export interface SaveCourseRequestDto {
  name: string;
  modality?: string;
  externalId: string | null;
  assignments: { assignmentId: number | null; dueDate: string; userIds: string[] }[];
}
```

### `infraestructure/course.mapper.ts`

```ts
import { CourseModality } from '../domain/course-modality.enum';
import { AssignedUser, CourseDetail, CourseDraft, CoursePage, CourseSummary } from '../domain/course.model';
import {
  CourseDetailDto,
  CourseListItemDto,
  CoursePageDto,
  CourseUserDto,
  SaveCourseRequestDto,
} from './course.dto';

const KNOWN_MODALITIES = new Set<string>(Object.values(CourseModality));

export function toCourseSummary(dto: CourseListItemDto): CourseSummary {
  return {
    id: dto.courseId,
    name: dto.name ?? '',
    modality: parseModality(dto.modality),
    externalId: dto.externalId?.trim() || null,
    assignedCount: dto.assignedUsersCount ?? 0,
    nextDueDate: toDateOnly(dto.nextDueDate),
  };
}

export function toCoursePage(dto: CoursePageDto): CoursePage {
  return {
    items: dto.items.map(toCourseSummary),
    total: dto.totalCount,
    stats: { ...dto.stats },
  };
}

export function toAssignedUser(dto: CourseUserDto): AssignedUser {
  return {
    id: dto.userId,
    displayName: dto.displayName || dto.email || dto.userId,
    email: dto.email,
    jobTitle: dto.jobTitle ?? null,
  };
}

export function toCourseDetail(dto: CourseDetailDto): CourseDetail {
  return {
    id: dto.courseId,
    name: dto.name,
    modality: parseModality(dto.modality),
    externalId: dto.externalId?.trim() || null,
    assignments: dto.assignments.map((a) => ({
      id: a.assignmentId,
      dueDate: toDateOnly(a.dueDate) ?? '',
      users: a.users.map(toAssignedUser),
    })),
  };
}

export function toSaveRequest(draft: CourseDraft, includeModality: boolean): SaveCourseRequestDto {
  return {
    name: draft.name,
    ...(includeModality ? { modality: draft.modality } : {}),
    externalId: draft.externalId,
    assignments: draft.assignments.map((a) => ({
      assignmentId: a.id,
      dueDate: a.dueDate,
      userIds: [...a.userIds],
    })),
  };
}

function parseModality(value: string): CourseModality {
  const normalized = value?.trim().toUpperCase();
  if (KNOWN_MODALITIES.has(normalized)) return normalized as CourseModality;

  console.warn(`[courses] Modalidad desconocida "${value}". Se muestra como Virtual.`);
  return CourseModality.Virtual;
}

/** DateOnly llega como "2026-10-30"; si el backend manda DateTime, se corta la hora. */
function toDateOnly(value: string | null | undefined): string | null {
  return value ? value.slice(0, 10) : null;
}
```

### `infraestructure/courses.service.ts`

Las URLs están bajo `/api/`, así que el interceptor de MSAL agrega el token.

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, unwrap } from '@shared/utils/api-response';
import { CourseDetail, CourseDraft, CoursePage, CourseQuery } from '../domain/course.model';
import { CourseRepository } from '../domain/course.repository';
import { CourseDetailDto, CoursePageDto } from './course.dto';
import { toCourseDetail, toCoursePage, toSaveRequest } from './course.mapper';

@Injectable({ providedIn: 'root' })
export class CoursesService implements CourseRepository {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/api/courses`;

  list(query: CourseQuery): Observable<CoursePage> {
    let params = new HttpParams().set('page', query.page).set('pageSize', query.pageSize);
    if (query.search) params = params.set('search', query.search);
    if (query.modality) params = params.set('modality', query.modality);
    if (query.pendingExternalId) params = params.set('pendingExternalId', true);

    return this.http
      .get<ApiResponse<CoursePageDto>>(this.baseUrl, { params })
      .pipe(map(unwrap), map(toCoursePage));
  }

  getById(id: number): Observable<CourseDetail> {
    return this.http
      .get<ApiResponse<CourseDetailDto>>(`${this.baseUrl}/${id}`)
      .pipe(map(unwrap), map(toCourseDetail));
  }

  create(draft: CourseDraft): Observable<number> {
    return this.http
      .post<ApiResponse<number>>(this.baseUrl, toSaveRequest(draft, true))
      .pipe(map(unwrap));
  }

  update(id: number, draft: CourseDraft): Observable<void> {
    return this.http
      .put<ApiResponse<unknown>>(`${this.baseUrl}/${id}`, toSaveRequest(draft, false))
      .pipe(map(unwrap), map(() => undefined));
  }

  setExternalId(id: number, externalId: string): Observable<void> {
    return this.http
      .patch<ApiResponse<unknown>>(`${this.baseUrl}/${id}/external-id`, { externalId })
      .pipe(map(unwrap), map(() => undefined));
  }

  remove(id: number): Observable<void> {
    return this.http
      .delete<ApiResponse<unknown>>(`${this.baseUrl}/${id}`)
      .pipe(map(unwrap), map(() => undefined));
  }
}
```

> `environment.api.baseUrl` es un nombre supuesto: usa la propiedad real de tu `enviroment.ts`.

### `infraestructure/users-directory.service.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, unwrap } from '@shared/utils/api-response';
import { AssignedUser } from '../domain/course.model';
import { UsersDirectoryRepository } from '../domain/users-directory.repository';
import { CourseUserDto } from './course.dto';
import { toAssignedUser } from './course.mapper';

@Injectable({ providedIn: 'root' })
export class UsersDirectoryService implements UsersDirectoryRepository {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/api/users`;

  search(term: string, top = 10): Observable<AssignedUser[]> {
    const params = new HttpParams().set('q', term).set('top', top);
    return this.http
      .get<ApiResponse<CourseUserDto[]>>(`${this.baseUrl}/search`, { params })
      .pipe(map(unwrap), map((users) => users.map(toAssignedUser)));
  }
}
```

### `infraestructure/courses.providers.ts`

Conecta cada contrato del dominio con su implementación. Las páginas lo incluyen en sus `providers`: son el punto donde la feature se arma.

```ts
import { Provider } from '@angular/core';
import { CourseRepository } from '../domain/course.repository';
import { UsersDirectoryRepository } from '../domain/users-directory.repository';
import { CoursesService } from './courses.service';
import { UsersDirectoryService } from './users-directory.service';

export const COURSES_INFRASTRUCTURE_PROVIDERS: Provider[] = [
  { provide: CourseRepository, useExisting: CoursesService },
  { provide: UsersDirectoryRepository, useExisting: UsersDirectoryService },
];
```

### Contrato que debe cumplir el backend

| Método | Ruta | Cuerpo / respuesta |
|---|---|---|
| `GET` | `/api/courses?search=excel&modality=VIRTUAL&pendingExternalId=true&page=1&pageSize=12` | `{ items, totalCount, stats }`. `search` busca en nombre **y** en ID externo. `stats` se calcula **sin** los filtros de modalidad y pendiente (solo con `search`), para que los indicadores no se vuelvan cero al filtrar. |
| `GET` | `/api/courses/{id}` | `{ courseId, name, modality, externalId, assignments[] }` |
| `POST` | `/api/courses` | `{ name, modality, externalId, assignments[] }` → `courseId` |
| `PUT` | `/api/courses/{id}` | `{ name, externalId, assignments[] }`. **Ignora** `modality`. Grupos con `assignmentId: null` son nuevos; los que no lleguen se eliminan. |
| `PATCH` | `/api/courses/{id}/external-id` | `{ externalId }` |
| `DELETE` | `/api/courses/{id}` | Borrado lógico si tiene asignaciones; físico si no. |
| `GET` | `/api/users/search?q=ana&top=10` | `[{ userId, displayName, email, jobTitle }]` |

Validaciones que el backend **debe** repetir, aunque el front ya las haga:

- `name` obligatorio, máximo 150; único por **nombre + modalidad** entre cursos activos → `409`.
- `externalId` sin espacios, máximo 50; único entre cursos que lo tengan → `409`.
- `dueDate` como `DateOnly`; no puede ser pasada si el grupo es nuevo o si cambió la fecha.
- Un mismo `userId` no puede estar en dos grupos del mismo curso.
- `nextDueDate`: la fecha más cercana mayor o igual a hoy; si todas vencieron, la más reciente.

Modelo de datos sugerido:

| Tabla | Columnas clave | Índices |
|---|---|---|
| `Course` | `Id`, `Name`, `Modality`, `ExternalId NULL`, `IsActive`, auditoría | Único `(Name, Modality) WHERE IsActive = 1` · Único `(ExternalId) WHERE ExternalId IS NOT NULL` |
| `CourseAssignment` | `Id`, `CourseId`, `DueDate DATE` | `(CourseId)` |
| `CourseAssignmentUser` | `AssignmentId`, `CourseId`, `UserObjectId`, `DisplayName`, `Email` | PK `(AssignmentId, UserObjectId)` · Único `(CourseId, UserObjectId)` |

`CourseId` se repite en `CourseAssignmentUser` para que la BD garantice la regla "un usuario, un grupo por curso". `DisplayName` y `Email` son una copia del momento de la asignación: el listado no tiene que consultar Graph cada vez.

### Búsqueda de usuarios con Microsoft Graph (backend)

Prueba primero la consulta en **Graph Explorer** (`https://aka.ms/ge`), con el encabezado `ConsistencyLevel: eventual`:

```text
GET https://graph.microsoft.com/v1.0/users?$search="displayName:ana" OR "mail:ana"&$select=id,displayName,mail,jobTitle&$top=10
```

Implementación con Microsoft Graph SDK v5. La app registrada necesita el permiso de **aplicación** `User.Read.All` con consentimiento de administrador.

```csharp
public sealed class GraphUsersDirectory(GraphServiceClient graph) : IUsersDirectory
{
    public async Task<IReadOnlyList<CourseUserDto>> SearchAsync(string term, int top, CancellationToken ct)
    {
        // Las comillas rompen la sintaxis de $search: se eliminan.
        var safe = term.Trim().Replace("\"", string.Empty);
        if (safe.Length < 2) return [];

        var result = await graph.Users.GetAsync(request =>
        {
            request.QueryParameters.Search = $"\"displayName:{safe}\" OR \"mail:{safe}\"";
            request.QueryParameters.Select = ["id", "displayName", "mail", "jobTitle"];
            request.QueryParameters.Top = Math.Clamp(top, 1, 25);
            request.Headers.Add("ConsistencyLevel", "eventual"); // obligatorio para $search
        }, ct);

        return result?.Value?
            .Where(u => u.Id is not null)
            .Select(u => new CourseUserDto(u.Id!, u.DisplayName ?? u.Mail ?? u.Id!, u.Mail, u.JobTitle))
            .ToList() ?? [];
    }
}
```

---

## 8. Paso 5 — Application: la facade

Se provee **en la página** (no en `root`): el estado del catálogo nace y muere con la pantalla.

### `application/courses.facade.ts`

La facade depende de los **contratos** del dominio, no de los servicios HTTP, y expone su estado en **solo lectura** con `asReadonly()`: los componentes leen, y solo la facade escribe. Así se cumple la regla de la arquitectura de no mutar el estado desde afuera.

```ts
import { Injectable, computed, inject, signal } from '@angular/core';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { Observable, Subject, catchError, firstValueFrom, map, merge, of, switchMap, tap } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { CourseRepository } from '../domain/course.repository';
import { UsersDirectoryRepository } from '../domain/users-directory.repository';
import { COURSE_MODALITY_CONFIG } from '../domain/course-modality.config';
import {
  AssignedUser,
  CourseDetail,
  CourseDraft,
  CoursePage,
  CourseQuery,
  CourseStats,
  CourseSummary,
} from '../domain/course.model';

export type LoadStatus = 'loading' | 'ready' | 'error';

export type EditorState =
  | { readonly mode: 'create' }
  | { readonly mode: 'edit'; readonly id: number }
  | null;

export const COURSES_PAGE_SIZE = 12;

const DEFAULT_QUERY: CourseQuery = {
  search: '',
  modality: null,
  pendingExternalId: false,
  page: 1,
  pageSize: COURSES_PAGE_SIZE,
};

const EMPTY_STATS: CourseStats = { total: 0, virtual: 0, onsite: 0, pendingExternalId: 0 };

type LoadResult = { readonly page: CoursePage } | { readonly error: string };

@Injectable()
export class CoursesFacade {
  private readonly repository = inject(CourseRepository);
  private readonly usersDirectory = inject(UsersDirectoryRepository);
  private readonly reload$ = new Subject<void>();

  // ── Estado: solo se escribe aquí dentro ──────────────────────────
  private readonly _query = signal<CourseQuery>(DEFAULT_QUERY);
  private readonly _status = signal<LoadStatus>('loading');
  private readonly _error = signal<string | null>(null);
  private readonly _courses = signal<readonly CourseSummary[]>([]);
  private readonly _total = signal(0);
  private readonly _stats = signal<CourseStats>(EMPTY_STATS);
  private readonly _editor = signal<EditorState>(null);

  // ── Hacia afuera, solo lectura ────────────────────────────────────
  readonly query = this._query.asReadonly();
  readonly status = this._status.asReadonly();
  readonly error = this._error.asReadonly();
  readonly courses = this._courses.asReadonly();
  readonly total = this._total.asReadonly();
  readonly stats = this._stats.asReadonly();
  readonly editor = this._editor.asReadonly();

  // ── Derivados ─────────────────────────────────────────────────────
  readonly totalPages = computed(() => Math.max(1, Math.ceil(this.total() / this.query().pageSize)));

  readonly hasFilters = computed(() => {
    const q = this.query();
    return q.search !== '' || q.modality !== null || q.pendingExternalId;
  });

  constructor() {
    // Cada cambio de consulta (o una recarga explícita) dispara UNA petición;
    // switchMap cancela la anterior si el usuario sigue filtrando.
    merge(toObservable(this.query), this.reload$.pipe(map(() => this.query())))
      .pipe(
        tap(() => {
          this._status.set('loading');
          this._error.set(null);
        }),
        switchMap((query) =>
          this.repository.list(query).pipe(
            map((page): LoadResult => ({ page })),
            catchError((e) => of<LoadResult>({ error: toErrorMessage(e, 'No se pudieron cargar los cursos.') })),
          ),
        ),
        takeUntilDestroyed(),
      )
      .subscribe((result) => {
        if ('error' in result) {
          this._status.set('error');
          this._error.set(result.error);
          return;
        }
        this._courses.set(result.page.items);
        this._total.set(result.page.total);
        this._stats.set(result.page.stats);
        this._status.set('ready');
      });
  }

  // ── Consulta ──────────────────────────────────────────────────────
  /** Cualquier filtro nuevo vuelve a la página 1. */
  patchQuery(patch: Partial<Pick<CourseQuery, 'search' | 'modality' | 'pendingExternalId'>>): void {
    this._query.update((q) => ({ ...q, ...patch, page: 1 }));
  }

  goToPage(page: number): void {
    const target = Math.min(Math.max(1, page), this.totalPages());
    if (target !== this.query().page) this._query.update((q) => ({ ...q, page: target }));
  }

  clearFilters(): void {
    this._query.set({ ...DEFAULT_QUERY, pageSize: this.query().pageSize });
  }

  reload(): void {
    this.reload$.next();
  }

  // ── Panel ─────────────────────────────────────────────────────────
  openCreate(): void {
    this._editor.set({ mode: 'create' });
  }

  openEdit(id: number): void {
    this._editor.set({ mode: 'edit', id });
  }

  closeEditor(): void {
    this._editor.set(null);
  }

  loadDetail(id: number): Promise<CourseDetail> {
    return firstValueFrom(this.repository.getById(id));
  }

  // ── Búsqueda de usuarios (la usa el buscador del panel) ───────────
  searchUsers(term: string): Observable<AssignedUser[]> {
    return this.usersDirectory.search(term);
  }

  // ── Comandos ──────────────────────────────────────────────────────
  async save(draft: CourseDraft): Promise<void> {
    const state = this.editor();
    if (!state) return;

    if (state.mode === 'create') {
      await firstValueFrom(this.repository.create(draft));
    } else {
      await firstValueFrom(this.repository.update(state.id, draft));
    }

    this._editor.set(null);
    this.reload();
  }

  /** Optimista: la tarjeta cambia al instante y se revierte si el servidor falla. */
  async setExternalId(course: CourseSummary, externalId: string): Promise<void> {
    const previous = course.externalId;
    const wasPending = !previous && COURSE_MODALITY_CONFIG[course.modality].externalIdExpected;

    this.patchCourse(course.id, { externalId });
    if (wasPending) this.shiftPending(-1);

    try {
      await firstValueFrom(this.repository.setExternalId(course.id, externalId));
      // Con el filtro "pendientes" activo, el curso ya no pertenece a la lista.
      if (this.query().pendingExternalId) this.reload();
    } catch (error) {
      this.patchCourse(course.id, { externalId: previous });
      if (wasPending) this.shiftPending(+1);
      throw error;
    }
  }

  async remove(course: CourseSummary): Promise<void> {
    await firstValueFrom(this.repository.remove(course.id));

    // Si era el último de una página que no es la primera, retrocede una.
    const { page } = this.query();
    if (this.courses().length === 1 && page > 1) {
      this.goToPage(page - 1);
    } else {
      this.reload();
    }
  }

  // ── Privados ──────────────────────────────────────────────────────
  private patchCourse(id: number, patch: Partial<CourseSummary>): void {
    this._courses.update((list) => list.map((c) => (c.id === id ? { ...c, ...patch } : c)));
  }

  private shiftPending(delta: number): void {
    this._stats.update((s) => ({ ...s, pendingExternalId: Math.max(0, s.pendingExternalId + delta) }));
  }
}
```

### `application/course-form.ts` — ⭐ formulario tipado y validadores

```ts
import {
  AbstractControl,
  FormArray,
  FormControl,
  FormGroup,
  NonNullableFormBuilder,
  ValidationErrors,
  ValidatorFn,
  Validators,
} from '@angular/forms';
import { todayIso } from '@shared/utils/date-only';
import { CourseModality } from '../domain/course-modality.enum';
import { AssignedUser, CourseAssignment, CourseDetail, CourseDraft } from '../domain/course.model';

export const COURSE_NAME_MAX = 150;
export const EXTERNAL_ID_MAX = 50;

export type AssignmentGroupForm = FormGroup<{
  id: FormControl<number | null>;
  dueDate: FormControl<string>;
  users: FormControl<AssignedUser[]>;
}>;

export type CourseForm = FormGroup<{
  name: FormControl<string>;
  modality: FormControl<CourseModality>;
  externalId: FormControl<string>;
  assignments: FormArray<AssignmentGroupForm>;
}>;

// ── Validadores ─────────────────────────────────────────────────────

/** "   " pasa el required de Angular; este no. */
export const notBlank: ValidatorFn = (control) =>
  typeof control.value === 'string' && control.value.length > 0 && !control.value.trim()
    ? { blank: true }
    : null;

/**
 * Solo valida fechas que el usuario tocó: las que llegan del servidor se respetan,
 * aunque ya hayan vencido. Angular marca el control como dirty ANTES de validar.
 */
export const dueDateNotPast: ValidatorFn = (control) => {
  if (!control.value || control.pristine) return null;
  return control.value < todayIso() ? { pastDate: true } : null;
};

export const atLeastOneUser: ValidatorFn = (control) =>
  Array.isArray(control.value) && control.value.length > 0 ? null : { noUsers: true };

/** Un usuario no puede estar en dos grupos del mismo curso. */
export const uniqueUsersAcrossGroups: ValidatorFn = (control: AbstractControl): ValidationErrors | null => {
  const groups = (control as FormArray<AssignmentGroupForm>).getRawValue();
  const seen = new Map<string, string>();
  const duplicated = new Set<string>();

  for (const group of groups) {
    for (const user of group.users) {
      if (seen.has(user.id)) duplicated.add(user.displayName);
      seen.set(user.id, user.displayName);
    }
  }

  return duplicated.size ? { duplicatedUsers: [...duplicated] } : null;
};

// ── Construcción ────────────────────────────────────────────────────

export function createCourseForm(fb: NonNullableFormBuilder): CourseForm {
  return fb.group({
    name: fb.control('', [Validators.required, notBlank, Validators.maxLength(COURSE_NAME_MAX)]),
    modality: fb.control<CourseModality>(CourseModality.Virtual, Validators.required),
    externalId: fb.control('', [Validators.maxLength(EXTERNAL_ID_MAX), Validators.pattern(/^\S*$/)]),
    assignments: fb.array<AssignmentGroupForm>([], uniqueUsersAcrossGroups),
  });
}

export function createAssignmentGroup(fb: NonNullableFormBuilder, value?: CourseAssignment): AssignmentGroupForm {
  return fb.group({
    id: fb.control<number | null>(value?.id ?? null),
    dueDate: fb.control(value?.dueDate ?? '', [Validators.required, dueDateNotPast]),
    users: fb.control<AssignedUser[]>(value ? [...value.users] : [], atLeastOneUser),
  });
}

export function resetCourseForm(form: CourseForm): void {
  form.controls.assignments.clear();
  form.reset(); // NonNullable: vuelve a '' y a Virtual
  form.controls.modality.enable();
}

export function patchCourseForm(form: CourseForm, fb: NonNullableFormBuilder, detail: CourseDetail): void {
  form.patchValue({
    name: detail.name,
    modality: detail.modality,
    externalId: detail.externalId ?? '',
  });

  for (const assignment of detail.assignments) {
    form.controls.assignments.push(createAssignmentGroup(fb, assignment));
  }

  form.controls.modality.disable(); // decisión #1: la modalidad no se cambia al editar
  form.markAsPristine();
  form.markAsUntouched();
}

export function toCourseDraft(form: CourseForm): CourseDraft {
  const raw = form.getRawValue(); // incluye la modalidad aunque esté deshabilitada
  return {
    name: raw.name.trim(),
    modality: raw.modality,
    externalId: raw.externalId.trim() || null,
    assignments: raw.assignments.map((group) => ({
      id: group.id,
      dueDate: group.dueDate,
      userIds: group.users.map((u) => u.id),
    })),
  };
}
```

---

## 9. Paso 6 — Feedback: toasts y confirmaciones

### `presentation/course-feedback.ts`

Envuelve SweetAlert2 para que ningún componente repita la configuración. Si la app ya tiene un servicio de alertas, usa ese y borra este archivo.

```ts
import Swal from 'sweetalert2';

const toast = () =>
  Swal.mixin({
    toast: true,
    position: 'top-end',
    showConfirmButton: false,
    timer: 3000,
    timerProgressBar: true,
  });

export function notifySuccess(title: string): void {
  void toast().fire({ icon: 'success', title });
}

export function notifyError(title: string): void {
  void toast().fire({ icon: 'error', title, timer: 5000 });
}

/** Usa `text`, nunca `html`: el nombre del curso lo escribió un usuario. */
export async function confirmDanger(title: string, text: string, confirmButtonText: string): Promise<boolean> {
  const result = await Swal.fire({
    icon: 'warning',
    title,
    text,
    showCancelButton: true,
    confirmButtonText,
    cancelButtonText: 'Cancelar',
    reverseButtons: true,
    focusCancel: true,
  });
  return result.isConfirmed;
}

export function isDialogOpen(): boolean {
  return Swal.isVisible();
}
```

---

## 10. Paso 7 — El buscador de usuarios

Un `ControlValueAccessor`: el formulario lo usa como cualquier control (`formControlName="users"`) y recibe un `AssignedUser[]`.

No llama al servicio HTTP: le pide los resultados a la facade, que es la que habla con el repositorio. Así la capa de presentación no depende de la infraestructura.

### `presentation/user-picker/user-picker.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  computed,
  forwardRef,
  inject,
  input,
  signal,
  viewChild,
} from '@angular/core';
import { ControlValueAccessor, NG_VALUE_ACCESSOR } from '@angular/forms';
import { toObservable, toSignal } from '@angular/core/rxjs-interop';
import { catchError, debounceTime, map, of, switchMap, tap } from 'rxjs';
import { AssignedUser } from '../../domain/course.model';
import { CoursesFacade } from '../../application/courses.facade';

const MIN_TERM = 2;
let nextId = 0;

@Component({
  selector: 'app-user-picker',
  templateUrl: './user-picker.component.html',
  styleUrl: './user-picker.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [{ provide: NG_VALUE_ACCESSOR, useExisting: forwardRef(() => UserPickerComponent), multi: true }],
})
export class UserPickerComponent implements ControlValueAccessor {
  private readonly facade = inject(CoursesFacade);
  private readonly searchInput = viewChild.required<ElementRef<HTMLInputElement>>('search');

  readonly inputId = input.required<string>();
  /** Usuarios de OTROS grupos: no se ofrecen aquí. */
  readonly excludeIds = input<readonly string[]>([]);
  readonly invalid = input(false);

  readonly listId = `user-picker-${nextId++}`;
  readonly selected = signal<readonly AssignedUser[]>([]);
  readonly term = signal('');
  readonly focused = signal(false);
  readonly disabled = signal(false);
  readonly searching = signal(false);
  readonly searchFailed = signal(false);
  readonly activeIndex = signal(0);

  private readonly results = toSignal(
    toObservable(this.term).pipe(
      map((term) => term.trim()),
      debounceTime(300),
      switchMap((term) =>
        term.length < MIN_TERM
          ? of<AssignedUser[]>([])
          : this.facade.searchUsers(term).pipe(
              catchError(() => {
                this.searchFailed.set(true);
                return of<AssignedUser[]>([]);
              }),
            ),
      ),
      tap(() => {
        this.searching.set(false);
        this.activeIndex.set(0);
      }),
    ),
    { initialValue: [] as AssignedUser[] },
  );

  readonly options = computed(() => {
    const taken = new Set([...this.excludeIds(), ...this.selected().map((u) => u.id)]);
    return this.results().filter((user) => !taken.has(user.id));
  });

  readonly panelOpen = computed(() => this.focused() && this.term().trim().length >= MIN_TERM);

  readonly activeOptionId = computed(() =>
    this.panelOpen() && this.options().length ? `${this.listId}-${this.activeIndex()}` : null,
  );

  private onChange: (value: AssignedUser[]) => void = () => {};
  private onTouched: () => void = () => {};

  // ── ControlValueAccessor ──────────────────────────────────────────
  writeValue(value: AssignedUser[] | null): void {
    this.selected.set(value ?? []);
  }

  registerOnChange(fn: (value: AssignedUser[]) => void): void {
    this.onChange = fn;
  }

  registerOnTouched(fn: () => void): void {
    this.onTouched = fn;
  }

  setDisabledState(isDisabled: boolean): void {
    this.disabled.set(isDisabled);
  }

  // ── Interacción ───────────────────────────────────────────────────
  onInput(value: string): void {
    this.term.set(value);
    this.searchFailed.set(false);
    this.searching.set(value.trim().length >= MIN_TERM);
  }

  onKeydown(event: KeyboardEvent): void {
    const options = this.options();

    switch (event.key) {
      case 'ArrowDown':
        if (!options.length) return;
        event.preventDefault();
        this.activeIndex.update((i) => (i + 1) % options.length);
        break;

      case 'ArrowUp':
        if (!options.length) return;
        event.preventDefault();
        this.activeIndex.update((i) => (i - 1 + options.length) % options.length);
        break;

      case 'Enter':
        event.preventDefault(); // Enter en el buscador nunca envía el formulario
        if (this.panelOpen() && options[this.activeIndex()]) this.add(options[this.activeIndex()]);
        break;

      case 'Escape':
        if (this.term()) {
          event.stopPropagation(); // limpia la búsqueda sin cerrar el panel lateral
          this.term.set('');
        }
        break;

      case 'Backspace':
        if (!this.term() && this.selected().length) {
          this.remove(this.selected()[this.selected().length - 1]);
        }
        break;
    }
  }

  add(user: AssignedUser): void {
    this.commit([...this.selected(), user]);
    this.term.set('');
    this.searching.set(false);
    this.searchInput().nativeElement.focus();
  }

  remove(user: AssignedUser): void {
    this.commit(this.selected().filter((u) => u.id !== user.id));
  }

  onBlur(): void {
    this.focused.set(false);
    this.onTouched();
  }

  focusInput(): void {
    if (!this.disabled()) this.searchInput().nativeElement.focus();
  }

  initials(user: AssignedUser): string {
    return user.displayName
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((part) => part[0])
      .join('')
      .toUpperCase();
  }

  private commit(next: readonly AssignedUser[]): void {
    this.selected.set(next);
    this.onChange([...next]);
    this.onTouched();
  }
}
```

### `user-picker.component.html`

```html
<div
  class="picker"
  [class.is-focused]="focused()"
  [class.is-invalid]="invalid()"
  [class.is-disabled]="disabled()"
  (click)="focusInput()">
  @for (user of selected(); track user.id) {
    <span class="picker-chip" [title]="user.email ?? user.displayName">
      <span class="picker-chip__avatar" aria-hidden="true">{{ initials(user) }}</span>
      <span class="picker-chip__name">{{ user.displayName }}</span>
      <button
        type="button"
        class="picker-chip__remove"
        [disabled]="disabled()"
        [attr.aria-label]="'Quitar a ' + user.displayName"
        (click)="remove(user); $event.stopPropagation()">
        <i class="fa-solid fa-xmark" aria-hidden="true"></i>
      </button>
    </span>
  }

  <input
    #search
    class="picker__input"
    type="text"
    role="combobox"
    autocomplete="off"
    aria-autocomplete="list"
    [id]="inputId()"
    [attr.aria-expanded]="panelOpen()"
    [attr.aria-controls]="listId"
    [attr.aria-activedescendant]="activeOptionId()"
    [value]="term()"
    [disabled]="disabled()"
    [placeholder]="selected().length ? 'Agregar otro…' : 'Busca por nombre o correo'"
    (input)="onInput($any($event.target).value)"
    (keydown)="onKeydown($event)"
    (focus)="focused.set(true)"
    (blur)="onBlur()" />
</div>

@if (panelOpen()) {
  <ul class="picker__panel" role="listbox" aria-label="Usuarios encontrados" [id]="listId">
    @if (searching()) {
      <li class="picker__status">
        <span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span> Buscando…
      </li>
    } @else if (searchFailed()) {
      <li class="picker__status text-danger">No se pudo buscar. Intenta de nuevo.</li>
    } @else {
      @for (user of options(); track user.id; let i = $index) {
        <li
          role="option"
          class="picker__option"
          [id]="listId + '-' + i"
          [class.is-active]="i === activeIndex()"
          [attr.aria-selected]="i === activeIndex()"
          (mousedown)="$event.preventDefault(); add(user)"
          (mouseenter)="activeIndex.set(i)">
          <span class="picker-chip__avatar" aria-hidden="true">{{ initials(user) }}</span>
          <span class="picker__option-text">
            <strong>{{ user.displayName }}</strong>
            <small>{{ user.email }}@if (user.jobTitle) { · {{ user.jobTitle }} }</small>
          </span>
        </li>
      } @empty {
        <li class="picker__status">Sin resultados para «{{ term().trim() }}».</li>
      }
    }
  </ul>
}
```

> `mousedown` + `preventDefault` en las opciones evita que el input pierda el foco (y cierre la lista) antes de que el clic llegue.

### `user-picker.component.scss`

```scss
:host {
  position: relative;
  display: block;
}

.picker {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.375rem;
  min-height: calc(1.5em + 0.75rem + 2px);
  padding: 0.3rem 0.5rem;
  border: 1px solid var(--bs-border-color);
  border-radius: var(--bs-border-radius);
  background: var(--cu-surface);
  cursor: text;
  transition: border-color 0.15s ease, box-shadow 0.15s ease;

  &.is-focused {
    border-color: color-mix(in srgb, var(--cu-accent) 60%, var(--bs-border-color));
    box-shadow: 0 0 0 0.25rem color-mix(in srgb, var(--cu-accent) 20%, transparent);
  }

  &.is-invalid {
    border-color: var(--cu-danger);
  }

  &.is-disabled {
    background: var(--cu-surface-alt);
    cursor: not-allowed;
  }
}

.picker__input {
  flex: 1 1 8rem;
  min-width: 8rem;
  padding: 0.2rem 0.25rem;
  border: 0;
  outline: none;
  background: transparent;
  color: var(--cu-text);
}

// ── Chips ──────────────────────────────────────────────────────────
.picker-chip {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  max-width: 100%;
  padding: 0.15rem 0.25rem 0.15rem 0.15rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--cu-accent) 10%, var(--cu-surface));
  color: var(--cu-text);
  font-size: 0.8125rem;
  animation: cu-chip-in 0.25s var(--cu-ease-spring) both;
}

.picker-chip__avatar {
  display: inline-grid;
  flex: 0 0 auto;
  place-items: center;
  width: 1.5rem;
  height: 1.5rem;
  border-radius: 50%;
  background: var(--cu-accent);
  color: #fff;
  font-size: 0.625rem;
  font-weight: 700;
  letter-spacing: 0.02em;
}

.picker-chip__name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.picker-chip__remove {
  display: inline-grid;
  place-items: center;
  width: 1.25rem;
  height: 1.25rem;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: var(--cu-muted);
  font-size: 0.7rem;
  transition: background-color 0.15s ease, color 0.15s ease;

  &:hover {
    background: color-mix(in srgb, var(--cu-danger) 15%, transparent);
    color: var(--cu-danger);
  }

  &:focus-visible {
    outline: 2px solid var(--cu-accent);
    outline-offset: 1px;
  }
}

// ── Lista de resultados ────────────────────────────────────────────
.picker__panel {
  position: absolute;
  top: calc(100% + 0.375rem);
  right: 0;
  left: 0;
  z-index: 5;
  max-height: 16rem;
  margin: 0;
  padding: 0.375rem;
  overflow-y: auto;
  list-style: none;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-sm);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow-lift);
  transform-origin: top center;
  animation: cu-dropdown-in 0.2s var(--cu-ease-out) both;
}

.picker__option {
  display: flex;
  align-items: center;
  gap: 0.625rem;
  padding: 0.5rem 0.625rem;
  border-radius: 0.5rem;
  cursor: pointer;
  transition: background-color 0.12s ease;

  &.is-active {
    background: color-mix(in srgb, var(--cu-accent) 10%, transparent);
  }
}

.picker__option-text {
  display: flex;
  flex-direction: column;
  min-width: 0;

  strong {
    font-size: 0.875rem;
    font-weight: 600;
  }

  small {
    overflow: hidden;
    color: var(--cu-muted);
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}

.picker__status {
  padding: 0.625rem;
  color: var(--cu-muted);
  font-size: 0.875rem;
}

@keyframes cu-chip-in {
  from {
    opacity: 0;
    transform: scale(0.6);
  }
}

@keyframes cu-dropdown-in {
  from {
    opacity: 0;
    transform: translateY(-0.25rem) scale(0.98);
  }
}

@media (prefers-reduced-motion: reduce) {
  .picker-chip,
  .picker__panel {
    animation-duration: 0.01ms;
  }
}
```

---

## 11. Paso 8 — La tarjeta del curso

Presentacional: recibe el curso y emite eventos. No inyecta la facade.

### `presentation/course-card/course-card.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  Injector,
  afterNextRender,
  computed,
  inject,
  input,
  output,
  signal,
  viewChild,
} from '@angular/core';
import { COURSE_MODALITY_CONFIG } from '../../domain/course-modality.config';
import { describeDue } from '../../domain/course-due';
import { CourseSummary } from '../../domain/course.model';

@Component({
  selector: 'app-course-card',
  templateUrl: './course-card.component.html',
  styleUrl: './course-card.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CourseCardComponent {
  private readonly injector = inject(Injector);
  private readonly idInput = viewChild<ElementRef<HTMLInputElement>>('idInput');

  readonly course = input.required<CourseSummary>();
  /** Posición en la lista: controla el escalón de la animación de entrada. */
  readonly index = input(0);

  readonly edit = output<void>();
  readonly remove = output<void>();
  readonly externalIdSubmit = output<string>();

  readonly config = computed(() => COURSE_MODALITY_CONFIG[this.course().modality]);
  readonly isPending = computed(() => !this.course().externalId && this.config().externalIdExpected);

  readonly editingId = signal(false);
  readonly draftId = signal('');

  readonly canSubmitId = computed(() => {
    const value = this.draftId().trim();
    return value.length > 0 && !/\s/.test(value) && value !== (this.course().externalId ?? '');
  });

  /** La regla de "vence pronto" vive en el dominio: la tarjeta y la tabla dicen lo mismo. */
  readonly due = computed(() => describeDue(this.course().nextDueDate));

  startIdEdit(): void {
    this.draftId.set(this.course().externalId ?? '');
    this.editingId.set(true);
    afterNextRender(() => this.idInput()?.nativeElement.select(), { injector: this.injector });
  }

  cancelIdEdit(): void {
    this.editingId.set(false);
  }

  submitId(): void {
    if (!this.canSubmitId()) return;
    this.externalIdSubmit.emit(this.draftId().trim());
    this.editingId.set(false); // la facade actualiza en optimista y revierte si falla
  }
}
```

### `course-card.component.html`

```html
<article
  class="course-card"
  [attr.data-tone]="config().tone"
  [style.--i]="index()"
  [attr.aria-labelledby]="'course-title-' + course().id">
  <header class="course-card__head">
    <span class="modality-pill">
      <i class="fa-solid {{ config().icon }}" aria-hidden="true"></i>
      {{ config().label }}
    </span>

    <div class="course-card__actions">
      <button
        type="button"
        class="icon-btn"
        [attr.aria-label]="'Editar ' + course().name"
        title="Editar"
        (click)="edit.emit()">
        <i class="fa-solid fa-pen" aria-hidden="true"></i>
      </button>
      <button
        type="button"
        class="icon-btn icon-btn--danger"
        [attr.aria-label]="'Eliminar ' + course().name"
        title="Eliminar"
        (click)="remove.emit()">
        <i class="fa-solid fa-trash-can" aria-hidden="true"></i>
      </button>
    </div>
  </header>

  <h3 class="course-card__title" [id]="'course-title-' + course().id" [title]="course().name">
    {{ course().name }}
  </h3>

  <div class="course-card__external">
    @if (editingId()) {
      <form class="ext-id-form" (submit)="$event.preventDefault(); submitId()">
        <label class="visually-hidden" [for]="'ext-id-' + course().id">ID del sistema externo</label>
        <input
          #idInput
          class="form-control form-control-sm font-monospace"
          maxlength="50"
          placeholder="Ej. LMS-2231"
          autocomplete="off"
          [id]="'ext-id-' + course().id"
          [value]="draftId()"
          (input)="draftId.set($any($event.target).value)"
          (keydown.escape)="cancelIdEdit()" />
        <button type="submit" class="btn btn-sm btn-primary" [disabled]="!canSubmitId()" aria-label="Guardar ID">
          <i class="fa-solid fa-check" aria-hidden="true"></i>
        </button>
        <button type="button" class="btn btn-sm btn-outline-secondary" aria-label="Cancelar" (click)="cancelIdEdit()">
          <i class="fa-solid fa-xmark" aria-hidden="true"></i>
        </button>
      </form>
    } @else if (course().externalId; as externalId) {
      <div class="ext-id">
        <i class="fa-solid fa-link" aria-hidden="true"></i>
        <span class="visually-hidden">ID externo:</span>
        <code class="ext-id__value">{{ externalId }}</code>
        <button type="button" class="icon-btn icon-btn--sm" aria-label="Cambiar ID externo" (click)="startIdEdit()">
          <i class="fa-solid fa-pen" aria-hidden="true"></i>
        </button>
      </div>
    } @else {
      <button type="button" class="ext-id-add" [class.is-pending]="isPending()" (click)="startIdEdit()">
        <i class="fa-solid fa-plus" aria-hidden="true"></i>
        Agregar ID externo
        <span class="ext-id-add__hint">{{ isPending() ? 'Pendiente' : 'Opcional' }}</span>
      </button>
    }
  </div>

  <footer class="course-card__meta">
    <span class="meta-item">
      <i class="fa-solid fa-user-group" aria-hidden="true"></i>
      {{ course().assignedCount }} {{ course().assignedCount === 1 ? 'asignado' : 'asignados' }}
    </span>

    @if (due(); as due) {
      <span class="meta-item due" [attr.data-state]="due.state" [title]="due.date">
        <i class="fa-regular fa-clock" aria-hidden="true"></i>
        {{ due.relative }}
      </span>
    }
  </footer>
</article>
```

### `course-card.component.scss`

```scss
:host {
  display: block;
}

.course-card {
  --tone: var(--cu-virtual);

  position: relative;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  height: 100%;
  padding: 1.1rem 1.1rem 1rem 1.4rem;
  overflow: hidden;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow);
  color: var(--cu-text);

  // Entrada en cascada: máximo 8 escalones.
  animation: cu-card-in 0.45s var(--cu-ease-spring) both;
  animation-delay: calc(min(var(--i, 0), 8) * 45ms);

  transition:
    transform 0.25s var(--cu-ease-out),
    box-shadow 0.25s var(--cu-ease-out),
    border-color 0.25s ease;

  &[data-tone='onsite'] {
    --tone: var(--cu-onsite);
  }

  // Barra lateral del color de la modalidad.
  &::before {
    content: '';
    position: absolute;
    top: 0;
    bottom: 0;
    left: 0;
    width: 4px;
    background: linear-gradient(180deg, var(--tone), color-mix(in srgb, var(--tone) 40%, transparent));
    transform: scaleY(0.35);
    transform-origin: top;
    transition: transform 0.35s var(--cu-ease-spring);
  }

  // Brillo que aparece en hover.
  &::after {
    content: '';
    position: absolute;
    inset: 0;
    background: radial-gradient(
      120% 80% at 100% 0%,
      color-mix(in srgb, var(--tone) 14%, transparent),
      transparent 60%
    );
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.3s ease;
  }

  &:hover,
  &:focus-within {
    border-color: color-mix(in srgb, var(--tone) 35%, var(--cu-border));
    box-shadow: var(--cu-shadow-lift);
    transform: translateY(-4px);

    &::before {
      transform: scaleY(1);
    }

    &::after {
      opacity: 1;
    }

    .course-card__actions {
      opacity: 1;
    }
  }

  > * {
    position: relative; // por encima del brillo
    z-index: 1;
  }
}

.course-card__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
}

.modality-pill {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  padding: 0.25rem 0.625rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 12%, transparent);
  color: color-mix(in srgb, var(--tone) 80%, var(--cu-text));
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.course-card__actions {
  display: flex;
  gap: 0.125rem;
  opacity: 0.55;
  transition: opacity 0.2s ease;

  @media (hover: none) {
    opacity: 1; // en táctil no hay hover
  }
}

.icon-btn {
  display: inline-grid;
  place-items: center;
  width: 2rem;
  height: 2rem;
  padding: 0;
  border: 0;
  border-radius: 0.5rem;
  background: transparent;
  color: var(--cu-muted);
  transition: background-color 0.15s ease, color 0.15s ease, transform 0.15s ease;

  &:hover {
    background: color-mix(in srgb, var(--tone, var(--cu-accent)) 12%, transparent);
    color: var(--tone, var(--cu-accent));
  }

  &:active {
    transform: scale(0.92);
  }

  &:focus-visible {
    outline: 2px solid var(--cu-accent);
    outline-offset: 1px;
  }

  &--danger:hover {
    background: color-mix(in srgb, var(--cu-danger) 12%, transparent);
    color: var(--cu-danger);
  }

  &--sm {
    width: 1.625rem;
    height: 1.625rem;
    font-size: 0.75rem;
  }
}

.course-card__title {
  display: -webkit-box;
  margin: 0;
  overflow: hidden;
  font-size: 1.05rem;
  font-weight: 600;
  line-height: 1.35;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
}

// ── ID externo ─────────────────────────────────────────────────────
.course-card__external {
  min-height: 2.25rem;
}

.ext-id {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  max-width: 100%;
  color: var(--cu-muted);
  font-size: 0.8125rem;
}

.ext-id__value {
  overflow: hidden;
  padding: 0.15rem 0.5rem;
  border-radius: 0.375rem;
  background: var(--cu-surface-alt);
  color: var(--cu-text);
  text-overflow: ellipsis;
  white-space: nowrap;
}

.ext-id-add {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  padding: 0.45rem 0.75rem;
  overflow: hidden;
  border: 1.5px dashed var(--cu-border);
  border-radius: var(--cu-radius-sm);
  background: transparent;
  color: var(--cu-muted);
  font-size: 0.8125rem;
  transition: border-color 0.2s ease, color 0.2s ease, background-color 0.2s ease;

  &:hover,
  &:focus-visible {
    border-color: var(--tone);
    background: color-mix(in srgb, var(--tone) 6%, transparent);
    color: var(--tone);
    outline: none;
  }

  &.is-pending {
    border-color: color-mix(in srgb, var(--cu-warning) 60%, transparent);
    background: color-mix(in srgb, var(--cu-warning) 8%, transparent);
    color: color-mix(in srgb, var(--cu-warning) 55%, var(--cu-text));

    // Destello que recorre el botón cada 3 s.
    &::after {
      content: '';
      position: absolute;
      inset: 0;
      background: linear-gradient(
        100deg,
        transparent 30%,
        color-mix(in srgb, var(--cu-warning) 25%, transparent) 50%,
        transparent 70%
      );
      transform: translateX(-100%);
      animation: cu-shine 3s ease-in-out infinite;
    }
  }
}

.ext-id-add__hint {
  margin-left: auto;
  font-size: 0.7rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  opacity: 0.8;
  text-transform: uppercase;
}

.ext-id-form {
  display: flex;
  gap: 0.375rem;
  animation: cu-pop-in 0.25s var(--cu-ease-spring) both;
}

// ── Pie ────────────────────────────────────────────────────────────
.course-card__meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem 1rem;
  margin-top: auto;
  padding-top: 0.75rem;
  border-top: 1px solid var(--cu-border);
  color: var(--cu-muted);
  font-size: 0.8125rem;
}

.meta-item {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
}

.due {
  &[data-state='soon'] {
    color: color-mix(in srgb, var(--cu-warning) 60%, var(--cu-text));
    font-weight: 600;
  }

  &[data-state='overdue'] {
    color: var(--cu-danger);
    font-weight: 600;
  }
}

// ── Animaciones ────────────────────────────────────────────────────
@keyframes cu-card-in {
  from {
    opacity: 0;
    transform: translateY(12px) scale(0.98);
  }
}

@keyframes cu-pop-in {
  from {
    opacity: 0;
    transform: scale(0.96);
  }
}

@keyframes cu-shine {
  0%,
  60% {
    transform: translateX(-100%);
  }
  100% {
    transform: translateX(100%);
  }
}

@media (prefers-reduced-motion: reduce) {
  .course-card,
  .ext-id-form {
    animation: cu-fade 0.15s ease both;
  }

  .course-card,
  .course-card::before {
    transition: none;
  }

  .course-card:hover,
  .course-card:focus-within {
    transform: none;
  }

  .ext-id-add.is-pending::after {
    animation: none;
  }
}

@keyframes cu-fade {
  from {
    opacity: 0;
  }
}
```

---

## 12. Paso 9 — El panel de crear / editar

Se queda siempre en el DOM y se muestra con una clase: así la salida también se anima. Cerrado queda `inert` (no recibe foco ni clics).

### `presentation/course-editor/course-editor.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  DestroyRef,
  ElementRef,
  PLATFORM_ID,
  computed,
  effect,
  inject,
  signal,
  untracked,
  viewChild,
} from '@angular/core';
import { DOCUMENT, isPlatformBrowser } from '@angular/common';
import { NonNullableFormBuilder, ReactiveFormsModule, AbstractControl } from '@angular/forms';
import { toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { todayIso } from '@shared/utils/date-only';
import { COURSE_MODALITIES } from '../../domain/course-modality.enum';
import { COURSE_MODALITY_CONFIG } from '../../domain/course-modality.config';
import { CoursesFacade, EditorState } from '../../application/courses.facade';
import {
  COURSE_NAME_MAX,
  EXTERNAL_ID_MAX,
  createAssignmentGroup,
  createCourseForm,
  patchCourseForm,
  resetCourseForm,
  toCourseDraft,
} from '../../application/course-form';
import { UserPickerComponent } from '../user-picker/user-picker.component';
import { confirmDanger, isDialogOpen, notifySuccess } from '../course-feedback';

@Component({
  selector: 'app-course-editor',
  imports: [ReactiveFormsModule, UserPickerComponent],
  templateUrl: './course-editor.component.html',
  styleUrl: './course-editor.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: { '(document:keydown.escape)': 'onEscape()' },
})
export class CourseEditorComponent {
  protected readonly facade = inject(CoursesFacade);
  private readonly fb = inject(NonNullableFormBuilder);
  private readonly document = inject(DOCUMENT);
  private readonly host = inject<ElementRef<HTMLElement>>(ElementRef);
  private readonly isBrowser = isPlatformBrowser(inject(PLATFORM_ID));
  private readonly nameInput = viewChild<ElementRef<HTMLInputElement>>('nameInput');

  readonly form = createCourseForm(this.fb);
  readonly modalities = COURSE_MODALITIES;
  readonly config = COURSE_MODALITY_CONFIG;
  readonly limits = { name: COURSE_NAME_MAX, externalId: EXTERNAL_ID_MAX };

  readonly isOpen = computed(() => this.facade.editor() !== null);
  readonly isEdit = computed(() => this.facade.editor()?.mode === 'edit');
  readonly loading = signal(false);
  readonly loadFailed = signal(false);
  readonly saving = signal(false);
  readonly submitted = signal(false);
  readonly error = signal<string | null>(null);
  readonly today = signal(todayIso());

  /** Valor del formulario como signal: alimenta los computed de abajo. */
  private readonly formValue = toSignal(this.form.valueChanges.pipe(map(() => this.form.getRawValue())), {
    initialValue: this.form.getRawValue(),
  });

  readonly selectedModality = computed(() => this.formValue().modality);

  /** Para cada grupo, los usuarios que ya están en los OTROS grupos. */
  readonly excludedByGroup = computed(() => {
    const groups = this.formValue().assignments;
    return groups.map((_, i) => groups.flatMap((group, j) => (j === i ? [] : group.users.map((u) => u.id))));
  });

  readonly totalAssigned = computed(
    () => new Set(this.formValue().assignments.flatMap((group) => group.users.map((u) => u.id))).size,
  );

  private returnFocusTo: HTMLElement | null = null;

  constructor() {
    effect(() => {
      const state = this.facade.editor();
      untracked(() => void this.prepare(state));
    });

    inject(DestroyRef).onDestroy(() => this.lockScroll(false));
  }

  // ── Grupos ────────────────────────────────────────────────────────
  addGroup(): void {
    this.form.controls.assignments.push(createAssignmentGroup(this.fb));
    this.form.controls.assignments.markAsDirty();
  }

  removeGroup(index: number): void {
    this.form.controls.assignments.removeAt(index);
    this.form.controls.assignments.markAsDirty();
  }

  // ── Validación visible ────────────────────────────────────────────
  hasError(control: AbstractControl, key?: string): boolean {
    const visible = control.invalid && (control.touched || this.submitted());
    return key ? visible && control.hasError(key) : visible;
  }

  // ── Guardar / cerrar ──────────────────────────────────────────────
  async save(): Promise<void> {
    this.submitted.set(true);

    if (this.form.invalid) {
      this.form.markAllAsTouched();
      this.focusFirstInvalid();
      return;
    }

    const wasEdit = this.isEdit();
    this.saving.set(true);
    this.error.set(null);

    try {
      await this.facade.save(toCourseDraft(this.form));
      notifySuccess(wasEdit ? 'Curso actualizado' : 'Curso creado');
    } catch (e) {
      this.error.set(toErrorMessage(e, 'No se pudo guardar el curso.'));
    } finally {
      this.saving.set(false);
    }
  }

  async requestClose(): Promise<void> {
    if (this.saving()) return;

    if (this.form.dirty) {
      const discard = await confirmDanger(
        '¿Descartar los cambios?',
        'Lo que no hayas guardado se perderá.',
        'Descartar',
      );
      if (!discard) return;
    }

    this.facade.closeEditor();
  }

  onEscape(): void {
    if (this.isOpen() && !isDialogOpen()) void this.requestClose();
  }

  // ── Ciclo del panel ───────────────────────────────────────────────
  private async prepare(state: EditorState): Promise<void> {
    this.error.set(null);
    this.submitted.set(false);
    this.loadFailed.set(false);

    if (!state) {
      this.lockScroll(false);
      this.returnFocusTo?.focus();
      this.returnFocusTo = null;
      return;
    }

    this.returnFocusTo = this.isBrowser ? (this.document.activeElement as HTMLElement | null) : null;
    this.lockScroll(true);
    this.today.set(todayIso());
    resetCourseForm(this.form);

    if (state.mode === 'create') {
      this.focusName();
      return;
    }

    this.loading.set(true);
    try {
      const detail = await this.facade.loadDetail(state.id);
      if (this.facade.editor() !== state) return; // el usuario cerró o abrió otro mientras cargaba
      patchCourseForm(this.form, this.fb, detail);
    } catch (e) {
      this.loadFailed.set(true);
      this.error.set(toErrorMessage(e, 'No se pudo cargar el curso.'));
    } finally {
      this.loading.set(false);
      this.focusName();
    }
  }

  private focusName(): void {
    if (!this.isBrowser) return;
    // Espera a que el panel deje de estar inert y termine de entrar.
    setTimeout(() => this.nameInput()?.nativeElement.focus({ preventScroll: true }), 80);
  }

  private focusFirstInvalid(): void {
    if (!this.isBrowser) return;
    setTimeout(() =>
      this.host.nativeElement
        .querySelector<HTMLElement>('input.ng-invalid, app-user-picker.ng-invalid input')
        ?.focus(),
    );
  }

  private lockScroll(lock: boolean): void {
    if (this.isBrowser) this.document.body.classList.toggle('overflow-hidden', lock);
  }
}
```

### `course-editor.component.html`

```html
<div class="drawer-backdrop" [class.is-open]="isOpen()" (click)="requestClose()"></div>

<aside
  class="drawer"
  role="dialog"
  aria-modal="true"
  aria-labelledby="course-editor-title"
  [class.is-open]="isOpen()"
  [attr.inert]="isOpen() ? null : ''"
  [attr.aria-hidden]="!isOpen()">
  <header class="drawer__head">
    <div class="drawer__heading">
      <p class="drawer__eyebrow">{{ isEdit() ? 'Editar curso' : 'Nuevo curso' }}</p>
      <h2 id="course-editor-title" class="h5 mb-0 text-truncate">
        {{ form.controls.name.value.trim() || 'Curso sin nombre' }}
      </h2>
    </div>
    <button type="button" class="btn-close" aria-label="Cerrar" (click)="requestClose()"></button>
  </header>

  <form id="course-form" class="drawer__body" novalidate [formGroup]="form" (ngSubmit)="save()">
    @if (loading()) {
      <div class="editor-skeleton" aria-hidden="true">
        <span></span><span></span><span class="is-tall"></span><span></span><span class="is-tall"></span>
      </div>
      <span class="visually-hidden" role="status">Cargando curso…</span>
    } @else if (!loadFailed()) {
      <!-- ① Datos del curso -->
      <fieldset class="editor-section">
        <legend class="editor-section__title">
          <span class="editor-section__step">1</span> Datos del curso
        </legend>

        <div class="mb-3">
          <label for="course-name" class="form-label">Nombre del curso</label>
          <input
            #nameInput
            id="course-name"
            type="text"
            class="form-control"
            formControlName="name"
            autocomplete="off"
            [attr.maxlength]="limits.name"
            [class.is-invalid]="hasError(form.controls.name)" />
          <div class="d-flex justify-content-between gap-2">
            <div>
              @if (hasError(form.controls.name, 'required') || hasError(form.controls.name, 'blank')) {
                <div class="invalid-feedback d-block">Escribe el nombre del curso.</div>
              }
            </div>
            <div class="form-text">{{ form.controls.name.value.length }}/{{ limits.name }}</div>
          </div>
        </div>

        <div class="mb-3">
          <span class="form-label d-block" id="course-modality-label">Modalidad</span>
          <div class="modality-options" role="radiogroup" aria-labelledby="course-modality-label">
            @for (modality of modalities; track modality) {
              <input
                class="btn-check"
                type="radio"
                formControlName="modality"
                [value]="modality"
                [id]="'course-modality-' + modality" />
              <label
                class="modality-option"
                [attr.data-tone]="config[modality].tone"
                [for]="'course-modality-' + modality">
                <span class="modality-option__icon">
                  <i class="fa-solid {{ config[modality].icon }}" aria-hidden="true"></i>
                </span>
                <span class="modality-option__text">
                  <strong>{{ config[modality].label }}</strong>
                  <small>{{ config[modality].hint }}</small>
                </span>
                <i class="fa-solid fa-circle-check modality-option__check" aria-hidden="true"></i>
              </label>
            }
          </div>
          @if (isEdit()) {
            <div class="form-text">
              <i class="fa-solid fa-lock me-1" aria-hidden="true"></i>
              La modalidad no se cambia: los cursos virtual y presencial son independientes. Si necesitas la otra,
              crea un curso nuevo.
            </div>
          }
        </div>

        <div>
          <label for="course-external-id" class="form-label">
            ID del sistema externo <span class="text-body-secondary fw-normal">(opcional)</span>
          </label>
          <input
            id="course-external-id"
            type="text"
            class="form-control font-monospace"
            formControlName="externalId"
            autocomplete="off"
            [attr.maxlength]="limits.externalId"
            [class.is-invalid]="hasError(form.controls.externalId)" />
          @if (hasError(form.controls.externalId, 'pattern')) {
            <div class="invalid-feedback d-block">El ID no puede tener espacios.</div>
          }
          <div class="form-text">{{ config[selectedModality()].externalIdHint }}</div>
        </div>
      </fieldset>

      <!-- ② Usuarios asignados -->
      <fieldset class="editor-section" formArrayName="assignments">
        <legend class="editor-section__title">
          <span class="editor-section__step">2</span> Usuarios asignados
          @if (totalAssigned()) {
            <span class="editor-section__count">{{ totalAssigned() }} usuarios</span>
          }
        </legend>
        <p class="form-text mt-0 mb-3">
          Cada grupo tiene su propia fecha límite de finalización. Puedes guardar el curso sin asignar a nadie.
        </p>

        @for (group of form.controls.assignments.controls; track group; let i = $index) {
          <div class="group-card" [formGroupName]="i">
            <div class="group-card__head">
              <span class="group-card__title">Grupo {{ i + 1 }}</span>
              <span class="group-card__count">
                {{ group.controls.users.value.length }}
                {{ group.controls.users.value.length === 1 ? 'usuario' : 'usuarios' }}
              </span>
              <button
                type="button"
                class="btn btn-sm btn-link text-danger ms-auto p-1"
                [attr.aria-label]="'Quitar grupo ' + (i + 1)"
                (click)="removeGroup(i)">
                <i class="fa-solid fa-trash-can" aria-hidden="true"></i>
              </button>
            </div>

            <div class="mb-2">
              <label class="form-label small mb-1" [for]="'due-' + i">Fecha límite de finalización</label>
              <input
                type="date"
                class="form-control group-card__date"
                formControlName="dueDate"
                [id]="'due-' + i"
                [min]="today()"
                [class.is-invalid]="hasError(group.controls.dueDate)" />
              @if (hasError(group.controls.dueDate, 'required')) {
                <div class="invalid-feedback d-block">Elige la fecha límite.</div>
              }
              @if (hasError(group.controls.dueDate, 'pastDate')) {
                <div class="invalid-feedback d-block">No puede ser una fecha pasada.</div>
              }
            </div>

            <div>
              <label class="form-label small mb-1" [for]="'users-' + i">Usuarios</label>
              <app-user-picker
                formControlName="users"
                [inputId]="'users-' + i"
                [excludeIds]="excludedByGroup()[i] ?? []"
                [invalid]="hasError(group.controls.users)" />
              @if (hasError(group.controls.users, 'noUsers')) {
                <div class="invalid-feedback d-block">Agrega al menos un usuario.</div>
              }
            </div>
          </div>
        } @empty {
          <div class="groups-empty">
            <i class="fa-solid fa-user-group" aria-hidden="true"></i>
            <span>Aún no hay usuarios asignados a este curso.</span>
          </div>
        }

        @if (form.controls.assignments.errors?.['duplicatedUsers']; as names) {
          <div class="alert alert-warning py-2 small mb-3" role="alert">
            Estos usuarios están en más de un grupo: {{ names.join(', ') }}. Déjalos en uno solo.
          </div>
        }

        <button type="button" class="add-group" (click)="addGroup()">
          <i class="fa-solid fa-plus" aria-hidden="true"></i> Agregar grupo
        </button>
      </fieldset>
    }

    @if (error(); as message) {
      <div class="alert alert-danger d-flex align-items-start gap-2 mt-3" role="alert">
        <i class="fa-solid fa-circle-exclamation mt-1" aria-hidden="true"></i>
        <span>{{ message }}</span>
      </div>
    }
  </form>

  <footer class="drawer__foot">
    <button type="button" class="btn btn-outline-secondary" [disabled]="saving()" (click)="requestClose()">
      Cancelar
    </button>
    <button
      type="submit"
      form="course-form"
      class="btn btn-primary drawer__save"
      [disabled]="saving() || loading() || loadFailed()">
      @if (saving()) {
        <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Guardando…
      } @else {
        <i class="fa-solid fa-check me-1" aria-hidden="true"></i>
        {{ isEdit() ? 'Guardar cambios' : 'Crear curso' }}
      }
    </button>
  </footer>
</aside>
```

### `course-editor.component.scss`

```scss
// ── Fondo ──────────────────────────────────────────────────────────
.drawer-backdrop {
  position: fixed;
  inset: 0;
  z-index: calc(var(--cu-z-drawer) - 1);
  background: rgb(15 23 42 / 0.45);
  opacity: 0;
  visibility: hidden;
  transition: opacity 0.2s ease, visibility 0s linear 0.2s;

  &.is-open {
    opacity: 1;
    visibility: visible;
    transition: opacity 0.25s ease, visibility 0s;
  }
}

@supports (backdrop-filter: blur(1px)) {
  .drawer-backdrop {
    backdrop-filter: blur(3px);
  }
}

// ── Panel ──────────────────────────────────────────────────────────
.drawer {
  position: fixed;
  top: 0;
  right: 0;
  bottom: 0;
  z-index: var(--cu-z-drawer);
  display: flex;
  flex-direction: column;
  width: min(560px, 100%);
  background: var(--cu-surface);
  box-shadow: -24px 0 48px -12px rgb(0 0 0 / 0.25);
  color: var(--cu-text);

  // Cerrado: fuera de pantalla. visibility se oculta AL FINAL de la transición.
  transform: translateX(104%);
  visibility: hidden;
  transition:
    transform 0.18s ease-in,
    visibility 0s linear 0.18s;

  &.is-open {
    transform: none;
    visibility: visible;
    transition:
      transform 0.38s var(--cu-ease-spring),
      visibility 0s;
  }

  // Línea de color arriba: el acento de la marca.
  &::before {
    content: '';
    position: absolute;
    top: 0;
    right: 0;
    left: 0;
    height: 3px;
    background: linear-gradient(90deg, var(--cu-virtual), var(--cu-onsite));
  }

  @media (min-width: 576px) {
    border-radius: var(--cu-radius) 0 0 var(--cu-radius);
    overflow: hidden;
  }
}

.drawer__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  padding: 1.25rem 1.5rem 1rem;
  border-bottom: 1px solid var(--cu-border);
}

.drawer__heading {
  min-width: 0; // permite text-truncate dentro de flex
}

.drawer__eyebrow {
  margin: 0 0 0.25rem;
  color: var(--cu-accent);
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.drawer__body {
  flex: 1;
  padding: 1.25rem 1.5rem 1.5rem;
  overflow-y: auto;
  overscroll-behavior: contain;
}

.drawer__foot {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  padding: 1rem 1.5rem calc(1rem + env(safe-area-inset-bottom));
  border-top: 1px solid var(--cu-border);
  background: color-mix(in srgb, var(--cu-surface-alt) 60%, var(--cu-surface));
}

.drawer__save {
  min-width: 9.5rem;
}

// ── Secciones ──────────────────────────────────────────────────────
.editor-section {
  margin: 0 0 1.75rem;
  padding: 0;
  border: 0;
}

.editor-section__title {
  display: flex;
  align-items: center;
  gap: 0.625rem;
  width: 100%;
  margin-bottom: 1rem;
  font-size: 0.95rem;
  font-weight: 600;
}

.editor-section__step {
  display: inline-grid;
  place-items: center;
  width: 1.625rem;
  height: 1.625rem;
  border-radius: 50%;
  background: color-mix(in srgb, var(--cu-accent) 14%, transparent);
  color: var(--cu-accent);
  font-size: 0.8rem;
  font-weight: 700;
}

.editor-section__count {
  margin-left: auto;
  padding: 0.15rem 0.625rem;
  border-radius: 999px;
  background: var(--cu-surface-alt);
  color: var(--cu-muted);
  font-size: 0.75rem;
  font-weight: 600;
  animation: cu-pop 0.3s var(--cu-ease-spring) both;
}

// ── Modalidad como tarjetas ────────────────────────────────────────
.modality-options {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 0.75rem;

  @media (max-width: 380px) {
    grid-template-columns: 1fr;
  }
}

.modality-option {
  --tone: var(--cu-virtual);

  position: relative;
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.875rem;
  border: 1.5px solid var(--cu-border);
  border-radius: var(--cu-radius-sm);
  cursor: pointer;
  transition:
    border-color 0.2s ease,
    background-color 0.2s ease,
    transform 0.2s var(--cu-ease-out),
    box-shadow 0.2s ease;

  &[data-tone='onsite'] {
    --tone: var(--cu-onsite);
  }

  &:hover {
    border-color: color-mix(in srgb, var(--tone) 45%, var(--cu-border));
    transform: translateY(-2px);
  }
}

.modality-option__icon {
  display: inline-grid;
  flex: 0 0 auto;
  place-items: center;
  width: 2.5rem;
  height: 2.5rem;
  border-radius: 0.75rem;
  background: color-mix(in srgb, var(--tone) 12%, transparent);
  color: var(--tone);
  font-size: 1.05rem;
  transition: transform 0.3s var(--cu-ease-spring);
}

.modality-option__text {
  display: flex;
  flex-direction: column;
  min-width: 0;
  line-height: 1.25;

  small {
    color: var(--cu-muted);
    font-size: 0.75rem;
  }
}

.modality-option__check {
  position: absolute;
  top: 0.5rem;
  right: 0.5rem;
  color: var(--tone);
  opacity: 0;
  transform: scale(0.4);
  transition: opacity 0.2s ease, transform 0.3s var(--cu-ease-spring);
}

.btn-check:checked + .modality-option {
  border-color: var(--tone);
  background: color-mix(in srgb, var(--tone) 7%, transparent);
  box-shadow: 0 6px 18px -8px color-mix(in srgb, var(--tone) 60%, transparent);

  .modality-option__icon {
    transform: scale(1.08) rotate(-4deg);
  }

  .modality-option__check {
    opacity: 1;
    transform: scale(1);
  }
}

.btn-check:focus-visible + .modality-option {
  outline: 2px solid var(--cu-accent);
  outline-offset: 2px;
}

.btn-check:disabled + .modality-option {
  cursor: not-allowed;
  opacity: 0.6;

  &:hover {
    transform: none;
  }
}

// ── Grupos de asignación ───────────────────────────────────────────
.group-card {
  margin-bottom: 0.75rem;
  padding: 0.875rem 1rem 1rem;
  border: 1px solid var(--cu-border);
  border-left: 3px solid var(--cu-accent);
  border-radius: var(--cu-radius-sm);
  background: color-mix(in srgb, var(--cu-surface-alt) 45%, var(--cu-surface));
  animation: cu-group-in 0.3s var(--cu-ease-spring) both;
}

.group-card__head {
  display: flex;
  align-items: center;
  gap: 0.625rem;
  margin-bottom: 0.625rem;
}

.group-card__title {
  font-size: 0.875rem;
  font-weight: 600;
}

.group-card__count {
  color: var(--cu-muted);
  font-size: 0.75rem;
}

.group-card__date {
  max-width: 13rem;
}

.groups-empty {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 0.75rem;
  padding: 1rem;
  border-radius: var(--cu-radius-sm);
  background: var(--cu-surface-alt);
  color: var(--cu-muted);
  font-size: 0.875rem;
}

.add-group {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  width: 100%;
  padding: 0.75rem;
  border: 1.5px dashed color-mix(in srgb, var(--cu-accent) 45%, var(--cu-border));
  border-radius: var(--cu-radius-sm);
  background: transparent;
  color: var(--cu-accent);
  font-weight: 600;
  transition: background-color 0.2s ease, transform 0.2s var(--cu-ease-out);

  &:hover {
    background: color-mix(in srgb, var(--cu-accent) 7%, transparent);
    transform: translateY(-1px);
  }

  &:active {
    transform: scale(0.99);
  }

  &:focus-visible {
    outline: 2px solid var(--cu-accent);
    outline-offset: 2px;
  }
}

// ── Esqueleto de carga ─────────────────────────────────────────────
.editor-skeleton {
  display: grid;
  gap: 0.875rem;

  span {
    display: block;
    height: 2.5rem;
    border-radius: var(--cu-radius-sm);
    background: linear-gradient(
      90deg,
      var(--cu-surface-alt) 0%,
      color-mix(in srgb, var(--cu-surface-alt) 40%, var(--cu-surface)) 50%,
      var(--cu-surface-alt) 100%
    );
    background-size: 200% 100%;
    animation: cu-skeleton 1.2s ease-in-out infinite;
  }

  .is-tall {
    height: 5.5rem;
  }
}

// ── Animaciones ────────────────────────────────────────────────────
@keyframes cu-group-in {
  from {
    opacity: 0;
    transform: translateY(-6px) scale(0.98);
  }
}

@keyframes cu-pop {
  from {
    opacity: 0;
    transform: scale(0.7);
  }
}

@keyframes cu-skeleton {
  from {
    background-position: 200% 0;
  }
  to {
    background-position: -200% 0;
  }
}

@media (prefers-reduced-motion: reduce) {
  .drawer,
  .drawer.is-open {
    transition: opacity 0.15s ease, visibility 0s linear 0.15s;
    transform: none;
    opacity: 0;
  }

  .drawer.is-open {
    opacity: 1;
    transition: opacity 0.15s ease, visibility 0s;
  }

  .group-card,
  .editor-section__count {
    animation: none;
  }

  .modality-option,
  .modality-option__icon,
  .modality-option__check {
    transition: none;
  }
}
```

---

## 13. Paso 10 — La página

### `presentation/courses-page/courses-page.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { debounceTime, distinctUntilChanged, map, skip } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { CourseModality, COURSE_MODALITIES } from '../../domain/course-modality.enum';
import { COURSE_MODALITY_CONFIG } from '../../domain/course-modality.config';
import { CourseSummary } from '../../domain/course.model';
import { CoursesFacade } from '../../application/courses.facade';
import { COURSES_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/courses.providers';
import { CourseCardComponent } from '../course-card/course-card.component';
import { CourseEditorComponent } from '../course-editor/course-editor.component';
import { confirmDanger, notifyError, notifySuccess } from '../course-feedback';

type ResultsView = 'skeleton' | 'error' | 'empty' | 'list';

@Component({
  selector: 'app-courses-page',
  imports: [CourseCardComponent, CourseEditorComponent],
  providers: [...COURSES_INFRASTRUCTURE_PROVIDERS, CoursesFacade],
  templateUrl: './courses-page.component.html',
  styleUrl: './courses-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CoursesPageComponent {
  protected readonly facade = inject(CoursesFacade);

  readonly modalities = COURSE_MODALITIES;
  readonly config = COURSE_MODALITY_CONFIG;
  readonly skeletons = Array.from({ length: 6 }, (_, i) => i);

  readonly q = this.facade.query;
  readonly stats = this.facade.stats;

  /** Valor inmediato del buscador; la consulta real va con rebote. */
  readonly searchDraft = signal(this.facade.query().search);

  readonly view = computed<ResultsView>(() => {
    const status = this.facade.status();
    const hasItems = this.facade.courses().length > 0;
    if (status === 'error') return 'error';
    if (!hasItems) return status === 'loading' ? 'skeleton' : 'empty';
    return 'list';
  });

  /** Posición de la píldora del selector: 0 Todas, 1 Virtual, 2 Presencial. */
  readonly segmentIndex = computed(() => {
    const modality = this.q().modality;
    return modality ? this.modalities.indexOf(modality) + 1 : 0;
  });

  readonly virtualShare = computed(() => {
    const { total, virtual } = this.stats();
    return total ? Math.round((virtual / total) * 100) : 0;
  });

  constructor() {
    toObservable(this.searchDraft)
      .pipe(
        skip(1), // el valor inicial ya está en la consulta
        debounceTime(350),
        map((value) => value.trim()),
        distinctUntilChanged(),
        takeUntilDestroyed(),
      )
      .subscribe((search) => this.facade.patchQuery({ search }));
  }

  statFor(modality: CourseModality): number {
    return modality === CourseModality.Virtual ? this.stats().virtual : this.stats().onsite;
  }

  /** Clic en un indicador ya activo lo desactiva. */
  toggleModality(modality: CourseModality): void {
    this.facade.patchQuery({ modality: this.q().modality === modality ? null : modality });
  }

  togglePending(): void {
    this.facade.patchQuery({ pendingExternalId: !this.q().pendingExternalId });
  }

  clearFilters(): void {
    this.searchDraft.set('');
    this.facade.clearFilters();
  }

  async remove(course: CourseSummary): Promise<void> {
    const count = course.assignedCount;
    const confirmed = await confirmDanger(
      `¿Eliminar "${course.name}"?`,
      count
        ? `Tiene ${count} ${count === 1 ? 'usuario asignado' : 'usuarios asignados'}. Se conserva el historial, pero el curso deja de aparecer en el catálogo.`
        : 'Esta acción no se puede deshacer.',
      'Eliminar',
    );
    if (!confirmed) return;

    try {
      await this.facade.remove(course);
      notifySuccess('Curso eliminado');
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudo eliminar el curso.'));
    }
  }

  async assignExternalId(course: CourseSummary, externalId: string): Promise<void> {
    try {
      await this.facade.setExternalId(course, externalId);
      notifySuccess('ID externo guardado');
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudo guardar el ID externo.'));
    }
  }
}
```

### `courses-page.component.html`

```html
<section class="courses container-fluid py-3">
  <!-- ── Encabezado + indicadores ─────────────────────────────────── -->
  <header class="courses-hero mb-3">
    <div class="d-flex flex-wrap align-items-start justify-content-between gap-3">
      <div>
        <p class="courses-hero__eyebrow">Compensación y beneficios</p>
        <h1 class="h3 mb-1">Cursos</h1>
        <p class="text-body-secondary mb-0">
          Crea cursos, asígnalos a grupos de usuarios y registra el ID del sistema externo cuando lo tengas.
        </p>
      </div>
      <button type="button" class="btn btn-primary courses-hero__cta" (click)="facade.openCreate()">
        <i class="fa-solid fa-plus me-1" aria-hidden="true"></i> Nuevo curso
      </button>
    </div>

    <div class="stats" role="group" aria-label="Resumen y filtros rápidos">
      <button
        type="button"
        class="stat"
        data-tone="accent"
        [attr.aria-pressed]="!q().modality && !q().pendingExternalId"
        (click)="clearFilters()">
        <span class="stat__icon"><i class="fa-solid fa-layer-group" aria-hidden="true"></i></span>
        <span class="stat__value">{{ stats().total }}</span>
        <span class="stat__label">Total</span>
      </button>

      @for (modality of modalities; track modality) {
        <button
          type="button"
          class="stat"
          [attr.data-tone]="config[modality].tone"
          [attr.aria-pressed]="q().modality === modality"
          (click)="toggleModality(modality)">
          <span class="stat__icon"><i class="fa-solid {{ config[modality].icon }}" aria-hidden="true"></i></span>
          <span class="stat__value">{{ statFor(modality) }}</span>
          <span class="stat__label">{{ config[modality].plural }}</span>
        </button>
      }

      <button
        type="button"
        class="stat"
        data-tone="warning"
        [class.has-alert]="stats().pendingExternalId > 0"
        [attr.aria-pressed]="q().pendingExternalId"
        (click)="togglePending()">
        <span class="stat__icon"><i class="fa-solid fa-hourglass-half" aria-hidden="true"></i></span>
        <span class="stat__value">{{ stats().pendingExternalId }}</span>
        <span class="stat__label">ID externo pendiente</span>
      </button>
    </div>

    @if (stats().total) {
      <div class="share">
        <div
          class="share-bar"
          role="img"
          [style.--virtual-share]="virtualShare() + '%'"
          [attr.aria-label]="virtualShare() + ' % de los cursos son virtuales'">
          <span class="share-bar__virtual"></span>
        </div>
        <span class="share__label">{{ virtualShare() }} % virtual</span>
      </div>
    }
  </header>

  <!-- ── Barra de filtros (sticky) ────────────────────────────────── -->
  <div class="toolbar mb-3">
    <div class="toolbar__search">
      <i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>
      <label for="course-search" class="visually-hidden">Buscar curso</label>
      <input
        id="course-search"
        type="search"
        class="form-control"
        placeholder="Buscar por nombre o ID externo"
        autocomplete="off"
        [value]="searchDraft()"
        (input)="searchDraft.set($any($event.target).value)" />
    </div>

    <div class="segmented" role="radiogroup" aria-label="Filtrar por modalidad" [style.--seg-index]="segmentIndex()">
      <span class="segmented__indicator" aria-hidden="true"></span>

      <input
        class="btn-check"
        type="radio"
        name="modality-filter"
        id="modality-filter-all"
        [checked]="!q().modality"
        (change)="facade.patchQuery({ modality: null })" />
      <label class="segmented__option" for="modality-filter-all">Todas</label>

      @for (modality of modalities; track modality) {
        <input
          class="btn-check"
          type="radio"
          name="modality-filter"
          [id]="'modality-filter-' + modality"
          [checked]="q().modality === modality"
          (change)="facade.patchQuery({ modality })" />
        <label class="segmented__option" [for]="'modality-filter-' + modality">{{ config[modality].label }}</label>
      }
    </div>

    @if (facade.hasFilters()) {
      <button type="button" class="btn btn-link btn-sm toolbar__clear" (click)="clearFilters()">
        <i class="fa-solid fa-filter-circle-xmark me-1" aria-hidden="true"></i> Limpiar filtros
      </button>
    }
  </div>

  <!-- ── Resultados ───────────────────────────────────────────────── -->
  <div class="results" aria-live="polite" [attr.aria-busy]="facade.status() === 'loading'">
    @switch (view()) {
      @case ('skeleton') {
        <div class="course-grid" aria-hidden="true">
          @for (i of skeletons; track i) {
            <div class="skeleton-card" [style.--i]="i">
              <span class="is-pill"></span>
              <span class="is-title"></span>
              <span class="is-line"></span>
              <span class="is-foot"></span>
            </div>
          }
        </div>
        <span class="visually-hidden" role="status">Cargando cursos…</span>
      }

      @case ('error') {
        <div class="state-card" data-tone="danger">
          <span class="state-card__icon"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i></span>
          <h2 class="h5">No se pudieron cargar los cursos</h2>
          <p class="text-body-secondary">{{ facade.error() }}</p>
          <button type="button" class="btn btn-outline-primary" (click)="facade.reload()">
            <i class="fa-solid fa-rotate-right me-1" aria-hidden="true"></i> Reintentar
          </button>
        </div>
      }

      @case ('empty') {
        <div class="state-card">
          <span class="state-card__icon is-floating"><i class="fa-solid fa-book-open" aria-hidden="true"></i></span>
          @if (facade.hasFilters()) {
            <h2 class="h5">Sin resultados</h2>
            <p class="text-body-secondary">Ningún curso coincide con los filtros actuales.</p>
            <button type="button" class="btn btn-outline-primary" (click)="clearFilters()">Limpiar filtros</button>
          } @else {
            <h2 class="h5">Aún no hay cursos</h2>
            <p class="text-body-secondary">Crea el primero y asígnalo a un grupo de usuarios.</p>
            <button type="button" class="btn btn-primary" (click)="facade.openCreate()">
              <i class="fa-solid fa-plus me-1" aria-hidden="true"></i> Crear el primer curso
            </button>
          }
        </div>
      }

      @default {
        <div class="course-grid" [class.is-refreshing]="facade.status() === 'loading'">
          @for (course of facade.courses(); track course.id; let i = $index) {
            <app-course-card
              [course]="course"
              [index]="i"
              (edit)="facade.openEdit(course.id)"
              (remove)="remove(course)"
              (externalIdSubmit)="assignExternalId(course, $event)" />
          }
        </div>

        @if (facade.totalPages() > 1) {
          <nav class="pager" aria-label="Paginación de cursos">
            <button
              type="button"
              class="btn btn-outline-secondary btn-sm"
              [disabled]="q().page <= 1"
              (click)="facade.goToPage(q().page - 1)">
              <i class="fa-solid fa-chevron-left me-1" aria-hidden="true"></i> Anterior
            </button>
            <span class="pager__status">
              Página <strong>{{ q().page }}</strong> de {{ facade.totalPages() }} · {{ facade.total() }} cursos
            </span>
            <button
              type="button"
              class="btn btn-outline-secondary btn-sm"
              [disabled]="q().page >= facade.totalPages()"
              (click)="facade.goToPage(q().page + 1)">
              Siguiente <i class="fa-solid fa-chevron-right ms-1" aria-hidden="true"></i>
            </button>
          </nav>
        }
      }
    }
  </div>

  <app-course-editor />
</section>
```

### `courses-page.component.scss`

El bloque de tokens es el de la sección 4; aquí va completo con el resto de estilos.

```scss
:host {
  // ══ Tokens de color — reemplaza por tus variables ══════════════════
  --cu-accent: var(--bs-primary);
  --cu-virtual: var(--bs-primary);
  --cu-onsite: var(--bs-success);
  --cu-warning: var(--bs-warning);
  --cu-danger: var(--bs-danger);
  --cu-surface: var(--bs-body-bg);
  --cu-surface-alt: var(--bs-tertiary-bg);
  --cu-border: var(--bs-border-color-translucent);
  --cu-text: var(--bs-body-color);
  --cu-muted: var(--bs-secondary-color);

  // ══ Forma y movimiento ════════════════════════════════════════════
  --cu-radius: 1rem;
  --cu-radius-sm: 0.625rem;
  --cu-shadow: 0 1px 2px rgb(0 0 0 / 0.04), 0 4px 16px rgb(0 0 0 / 0.06);
  --cu-shadow-lift: 0 2px 4px rgb(0 0 0 / 0.05), 0 18px 36px -8px rgb(0 0 0 / 0.16);
  --cu-ease-spring: cubic-bezier(0.2, 0.9, 0.3, 1.15);
  --cu-ease-out: cubic-bezier(0.2, 0.8, 0.2, 1);
  --cu-z-drawer: 1060;

  display: block;
}

// ── Encabezado ─────────────────────────────────────────────────────
.courses-hero {
  position: relative;
  padding: 1.5rem;
  overflow: hidden;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background:
    radial-gradient(90% 140% at 0% 0%, color-mix(in srgb, var(--cu-virtual) 13%, transparent), transparent 55%),
    radial-gradient(80% 120% at 100% 100%, color-mix(in srgb, var(--cu-onsite) 10%, transparent), transparent 55%),
    var(--cu-surface);

  // Halo que se mueve lento: le da vida al encabezado sin distraer.
  &::after {
    content: '';
    position: absolute;
    top: -40%;
    right: -10%;
    width: 22rem;
    height: 22rem;
    border-radius: 50%;
    background: radial-gradient(circle, color-mix(in srgb, var(--cu-accent) 14%, transparent), transparent 70%);
    animation: cu-drift 14s ease-in-out infinite alternate;
    pointer-events: none;
  }

  > * {
    position: relative;
    z-index: 1;
  }
}

.courses-hero__eyebrow {
  margin: 0 0 0.25rem;
  color: var(--cu-accent);
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.courses-hero__cta {
  box-shadow: 0 8px 20px -8px color-mix(in srgb, var(--cu-accent) 70%, transparent);
  transition: transform 0.2s var(--cu-ease-out), box-shadow 0.2s ease;

  &:hover {
    box-shadow: 0 12px 26px -8px color-mix(in srgb, var(--cu-accent) 80%, transparent);
    transform: translateY(-2px);
  }

  &:active {
    transform: translateY(0) scale(0.98);
  }

  i {
    transition: transform 0.3s var(--cu-ease-spring);
  }

  &:hover i {
    transform: rotate(90deg);
  }
}

// ── Indicadores (también son filtros) ──────────────────────────────
.stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(9.5rem, 1fr));
  gap: 0.75rem;
  margin-top: 1.25rem;
}

.stat {
  --tone: var(--cu-accent);

  display: grid;
  grid-template-areas:
    'icon value'
    'icon label';
  grid-template-columns: auto 1fr;
  column-gap: 0.75rem;
  align-items: center;
  padding: 0.75rem 0.875rem;
  border: 1.5px solid var(--cu-border);
  border-radius: var(--cu-radius-sm);
  background: color-mix(in srgb, var(--cu-surface) 85%, transparent);
  color: var(--cu-text);
  text-align: start;
  transition:
    transform 0.2s var(--cu-ease-out),
    border-color 0.2s ease,
    background-color 0.2s ease,
    box-shadow 0.2s ease;

  &[data-tone='virtual'] {
    --tone: var(--cu-virtual);
  }

  &[data-tone='onsite'] {
    --tone: var(--cu-onsite);
  }

  &[data-tone='warning'] {
    --tone: var(--cu-warning);
  }

  &:hover {
    border-color: color-mix(in srgb, var(--tone) 40%, var(--cu-border));
    transform: translateY(-2px);
  }

  &:focus-visible {
    outline: 2px solid var(--cu-accent);
    outline-offset: 2px;
  }

  &[aria-pressed='true'] {
    border-color: var(--tone);
    background: color-mix(in srgb, var(--tone) 9%, var(--cu-surface));
    box-shadow: 0 8px 20px -12px color-mix(in srgb, var(--tone) 80%, transparent);

    .stat__icon {
      background: var(--tone);
      color: #fff;
    }
  }

  // El indicador de pendientes "respira" solo si hay pendientes.
  &.has-alert .stat__icon {
    animation: cu-breathe 2.4s ease-in-out infinite;
  }
}

.stat__icon {
  display: inline-grid;
  grid-area: icon;
  place-items: center;
  width: 2.5rem;
  height: 2.5rem;
  border-radius: 0.75rem;
  background: color-mix(in srgb, var(--tone) 14%, transparent);
  color: var(--tone);
  transition: background-color 0.25s ease, color 0.25s ease;
}

.stat__value {
  grid-area: value;
  font-size: 1.35rem;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  line-height: 1.1;
}

.stat__label {
  grid-area: label;
  overflow: hidden;
  color: var(--cu-muted);
  font-size: 0.75rem;
  text-overflow: ellipsis;
  white-space: nowrap;
}

// ── Proporción virtual / presencial ────────────────────────────────
.share {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-top: 1rem;
}

.share-bar {
  flex: 1;
  height: 0.5rem;
  overflow: hidden;
  border-radius: 999px;
  background: color-mix(in srgb, var(--cu-onsite) 35%, transparent);
}

.share-bar__virtual {
  display: block;
  width: var(--virtual-share, 0%);
  height: 100%;
  border-radius: inherit;
  background: linear-gradient(90deg, var(--cu-virtual), color-mix(in srgb, var(--cu-virtual) 70%, #fff));
  transition: width 0.6s var(--cu-ease-out);
}

.share__label {
  color: var(--cu-muted);
  font-size: 0.75rem;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

// ── Barra de filtros ───────────────────────────────────────────────
.toolbar {
  position: sticky;
  top: 0;
  z-index: 10;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.75rem;
  padding: 0.625rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
}

@supports (backdrop-filter: blur(1px)) {
  .toolbar {
    background: color-mix(in srgb, var(--cu-surface) 82%, transparent);
    backdrop-filter: blur(14px) saturate(160%);
  }
}

.toolbar__search {
  position: relative;
  flex: 1 1 16rem;

  i {
    position: absolute;
    top: 50%;
    left: 0.875rem;
    color: var(--cu-muted);
    transform: translateY(-50%);
    transition: color 0.2s ease;
    pointer-events: none;
  }

  .form-control {
    padding-left: 2.5rem;
    border-radius: 999px;
  }

  &:focus-within i {
    color: var(--cu-accent);
  }
}

.toolbar__clear {
  color: var(--cu-muted);
  text-decoration: none;
  animation: cu-fade-in 0.2s ease both;

  &:hover {
    color: var(--cu-danger);
  }
}

// ── Selector segmentado con píldora deslizante ─────────────────────
.segmented {
  --seg-count: 3;
  --seg-pad: 0.25rem;

  position: relative;
  display: grid;
  grid-template-columns: repeat(var(--seg-count), minmax(0, 1fr));
  min-width: 18rem;
  padding: var(--seg-pad);
  border-radius: 999px;
  background: var(--cu-surface-alt);

  @media (max-width: 575.98px) {
    flex: 1 1 100%;
    min-width: 0;
  }
}

.segmented__indicator {
  position: absolute;
  top: var(--seg-pad);
  bottom: var(--seg-pad);
  left: var(--seg-pad);
  width: calc((100% - 2 * var(--seg-pad)) / var(--seg-count));
  border-radius: 999px;
  background: var(--cu-surface);
  box-shadow: 0 2px 8px rgb(0 0 0 / 0.1);
  transform: translateX(calc(100% * var(--seg-index, 0)));
  transition: transform 0.35s var(--cu-ease-spring);
}

.segmented__option {
  position: relative;
  z-index: 1;
  padding: 0.4rem 0.75rem;
  border-radius: 999px;
  color: var(--cu-muted);
  font-size: 0.8125rem;
  font-weight: 600;
  text-align: center;
  cursor: pointer;
  transition: color 0.2s ease;
  user-select: none;

  &:hover {
    color: var(--cu-text);
  }
}

.btn-check:checked + .segmented__option {
  color: var(--cu-accent);
}

.btn-check:focus-visible + .segmented__option {
  outline: 2px solid var(--cu-accent);
  outline-offset: -2px;
}

// ── Rejilla ────────────────────────────────────────────────────────
.course-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 18rem), 1fr));
  gap: 1rem;
  transition: opacity 0.2s ease;

  &.is-refreshing {
    opacity: 0.55;
    pointer-events: none;
  }
}

// ── Esqueleto ──────────────────────────────────────────────────────
.skeleton-card {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  height: 12.5rem;
  padding: 1.1rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  animation: cu-fade-in 0.3s ease both;
  animation-delay: calc(var(--i, 0) * 60ms);

  span {
    display: block;
    border-radius: 0.5rem;
    background: linear-gradient(
      90deg,
      var(--cu-surface-alt) 0%,
      color-mix(in srgb, var(--cu-surface-alt) 40%, var(--cu-surface)) 50%,
      var(--cu-surface-alt) 100%
    );
    background-size: 200% 100%;
    animation: cu-skeleton 1.2s ease-in-out infinite;
  }

  .is-pill {
    width: 5.5rem;
    height: 1.4rem;
    border-radius: 999px;
  }

  .is-title {
    width: 80%;
    height: 1.25rem;
  }

  .is-line {
    width: 100%;
    height: 2.25rem;
  }

  .is-foot {
    width: 60%;
    height: 1rem;
    margin-top: auto;
  }
}

// ── Estados vacío y error ──────────────────────────────────────────
.state-card {
  --tone: var(--cu-accent);

  max-width: 28rem;
  margin: 2rem auto;
  padding: 2rem 1.5rem;
  border: 1px dashed var(--cu-border);
  border-radius: var(--cu-radius);
  text-align: center;
  animation: cu-fade-in 0.3s ease both;

  &[data-tone='danger'] {
    --tone: var(--cu-danger);
  }
}

.state-card__icon {
  display: inline-grid;
  place-items: center;
  width: 4rem;
  height: 4rem;
  margin-bottom: 1rem;
  border-radius: 1.25rem;
  background: color-mix(in srgb, var(--tone) 12%, transparent);
  color: var(--tone);
  font-size: 1.6rem;

  &.is-floating {
    animation: cu-float 3.5s ease-in-out infinite;
  }
}

// ── Paginación ─────────────────────────────────────────────────────
.pager {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 1rem;
  margin-top: 1.5rem;
}

.pager__status {
  color: var(--cu-muted);
  font-size: 0.875rem;
  font-variant-numeric: tabular-nums;
}

// ── Animaciones ────────────────────────────────────────────────────
@keyframes cu-drift {
  to {
    transform: translate(-3rem, 2rem) scale(1.15);
  }
}

@keyframes cu-breathe {
  50% {
    box-shadow: 0 0 0 6px color-mix(in srgb, var(--tone) 18%, transparent);
  }
}

@keyframes cu-float {
  50% {
    transform: translateY(-6px);
  }
}

@keyframes cu-fade-in {
  from {
    opacity: 0;
  }
}

@keyframes cu-skeleton {
  from {
    background-position: 200% 0;
  }
  to {
    background-position: -200% 0;
  }
}

@media (prefers-reduced-motion: reduce) {
  .courses-hero::after,
  .stat.has-alert .stat__icon,
  .state-card__icon.is-floating,
  .skeleton-card span {
    animation: none;
  }

  .segmented__indicator,
  .share-bar__virtual,
  .stat,
  .courses-hero__cta,
  .courses-hero__cta i {
    transition: none;
  }

  .stat:hover,
  .courses-hero__cta:hover {
    transform: none;
  }
}
```

### Ruta en `src/app/app.routes.ts`

```ts
{
  path: 'cursos',
  canActivate: [permissionGuard],
  data: { permissionPath: 'courses' },
  loadComponent: () =>
    import('@features/courses/presentation/courses-page/courses-page.component')
      .then(m => m.CoursesPageComponent),
}
```

> Agrega la entrada **Cursos** al menú y el permiso `courses` en el backend de permisos, igual que las demás páginas.

---

## 14. Pruebas

### Unitarias

```ts
describe('course-form', () => {
  let fb: NonNullableFormBuilder;
  beforeEach(() => (fb = TestBed.inject(NonNullableFormBuilder)));

  it('rechaza un nombre con solo espacios', () => {
    const form = createCourseForm(fb);
    form.controls.name.setValue('   ');
    expect(form.controls.name.hasError('blank')).toBeTrue();
  });

  it('rechaza un ID externo con espacios', () => {
    const form = createCourseForm(fb);
    form.controls.externalId.setValue('LMS 22');
    expect(form.controls.externalId.hasError('pattern')).toBeTrue();
  });

  it('respeta una fecha vencida que llega del servidor', () => {
    const group = createAssignmentGroup(fb, { id: 1, dueDate: '2020-01-01', users: [ana] });
    expect(group.controls.dueDate.valid).toBeTrue();
  });

  it('rechaza una fecha pasada que el usuario escribe', () => {
    const group = createAssignmentGroup(fb);
    group.controls.dueDate.markAsDirty();
    group.controls.dueDate.setValue('2020-01-01');
    expect(group.controls.dueDate.hasError('pastDate')).toBeTrue();
  });

  it('detecta un usuario repetido en dos grupos', () => {
    const form = createCourseForm(fb);
    form.controls.assignments.push(createAssignmentGroup(fb, { id: null, dueDate: '2099-01-01', users: [ana] }));
    form.controls.assignments.push(createAssignmentGroup(fb, { id: null, dueDate: '2099-02-01', users: [ana] }));
    expect(form.controls.assignments.errors?.['duplicatedUsers']).toEqual(['Ana Pérez']);
  });

  it('bloquea la modalidad al editar y aun así la envía en el draft', () => {
    const form = createCourseForm(fb);
    patchCourseForm(form, fb, { ...detail, modality: CourseModality.Onsite });
    expect(form.controls.modality.disabled).toBeTrue();
    expect(toCourseDraft(form).modality).toBe(CourseModality.Onsite);
  });

  it('convierte un ID externo vacío en null', () => {
    const form = createCourseForm(fb);
    form.patchValue({ name: 'Excel', externalId: '   ' });
    expect(toCourseDraft(form).externalId).toBeNull();
  });
});

describe('daysUntil', () => {
  it('no se corre un día por la zona horaria', () => {
    expect(daysUntil('2026-10-30', new Date(2026, 9, 30, 23, 59))).toBe(0);
  });
});

describe('CoursesFacade', () => {
  // api es un doble de CourseRepository:
  // TestBed.configureTestingModule({ providers: [CoursesFacade, { provide: CourseRepository, useValue: api }] });

  it('revierte el ID externo si el servidor falla', async () => {
    api.setExternalId.and.returnValue(throwError(() => new Error('500')));
    const course = facade.courses()[0]; // virtual sin ID
    const pendingBefore = facade.stats().pendingExternalId;

    await expectAsync(facade.setExternalId(course, 'LMS-1')).toBeRejected();

    expect(facade.courses()[0].externalId).toBeNull();
    expect(facade.stats().pendingExternalId).toBe(pendingBefore);
  });

  it('vuelve a la página 1 al cambiar un filtro', () => {
    facade.goToPage(2);
    facade.patchQuery({ modality: CourseModality.Virtual });
    expect(facade.query().page).toBe(1);
  });

  it('retrocede una página al eliminar el último curso de la página', async () => {
    // página 2 con un solo curso
    await facade.remove(facade.courses()[0]);
    expect(facade.query().page).toBe(1);
  });
});

describe('UserPickerComponent', () => {
  it('no ofrece usuarios que ya están en otro grupo', () => {
    fixture.componentRef.setInput('excludeIds', ['ana-oid']);
    // resultados simulados: Ana y Juan
    expect(component.options().map((u) => u.id)).toEqual(['juan-oid']);
  });
});
```

### Revisión visual

Hazla con quien pidió el cambio al lado.

- **Cascada:** al cambiar de página, las tarjetas entran escalonadas y las 12 terminan en menos de un segundo.
- **Hover:** la tarjeta sube, la barra lateral crece y aparece el brillo del color de su modalidad.
- **Indicadores:** clic en "Virtuales" filtra y la píldora del selector se desliza a "Virtual"; otro clic quita el filtro.
- **Pendientes:** el botón punteado de un virtual sin ID tiene el destello; el de un presencial sin ID no.
- **ID rápido:** agregar un ID desde la tarjeta actualiza el indicador de pendientes al instante.
- **Panel:** entra desde la derecha con rebote y sale rápido. En 360 px ocupa toda la pantalla.
- **Colores:** cambia `--cu-virtual` y `--cu-onsite` en el `:host`; toda la página debe cambiar sin tocar otro archivo.
- **Tema oscuro:** si la app lo tiene, los tintes con `color-mix` se ven bien sobre el fondo oscuro.
- **Movimiento reducido:** DevTools → Rendering → *prefers-reduced-motion*: todo queda en fundidos cortos.

### Interacción y accesibilidad

- Solo con teclado: Tab hasta **Nuevo curso**, Enter abre el panel y el foco queda en el nombre; Esc cierra y el foco vuelve al botón.
- Con cambios sin guardar, Esc o clic en el fondo piden confirmación; sin cambios, cierran directo.
- En el buscador de usuarios: escribir "an", ↓ ↓ Enter agrega; Retroceso con el campo vacío quita el último chip; Esc limpia la búsqueda **sin** cerrar el panel.
- Enter dentro del buscador de usuarios **no** envía el formulario.
- Guardar con errores lleva el foco al primer campo inválido.
- Un nombre de 150 caracteres se corta en 2 líneas en la tarjeta sin romper la rejilla.
- Un nombre con `<b>hola</b>` se muestra como texto, en la tarjeta y en la confirmación de eliminar.
- Backend caído: aparece el estado de error con **Reintentar**; con datos ya cargados, el error del ID rápido revierte la tarjeta y muestra un toast.
- Con SSR: la página renderiza sin `document is not defined`.

---

## 15. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| La fecha guardada queda un día antes | Se convirtió a `Date` y se envió con `toISOString()` | Enviar el `string` del `input type="date"` tal cual; `DateOnly` en el backend. |
| Al editar no deja guardar por "fecha pasada" en un grupo viejo | El validador corre sobre valores del servidor | Verifica que `patchCourseForm` llame `markAsPristine()` y que el validador revise `pristine`. |
| La modalidad no llega al crear | Se usó `form.value` en vez de `getRawValue()` | `toCourseDraft` usa `getRawValue()`, que incluye controles deshabilitados. |
| Los colores no cambian al editar los tokens | La variable está en SCSS (`$x`) y no en CSS | Asígnala con interpolación: `--cu-accent: #{$x};`. |
| `color-mix` no pinta nada | La variable no existe en ese punto del DOM | Los tokens viven en el `:host` de la página; el panel y la tarjeta deben estar **dentro** de ella. |
| El panel queda detrás del header | `z-index` del header mayor que `--cu-z-drawer` | Sube `--cu-z-drawer` por encima del header y por debajo de los modales de SweetAlert2 (`1060`). |
| El panel no deja escribir en SweetAlert2 | Foco atrapado por otro componente | No uses `cdkTrapFocus` en el panel sin excluir `.swal2-container`. |
| El buscador de usuarios responde 403 | La app del backend no tiene `User.Read.All` de aplicación con consentimiento | Pide el consentimiento de administrador en Entra ID. |
| `$search` de Graph responde 400 | Falta el encabezado `ConsistencyLevel: eventual` | Agrégalo; pruébalo antes en Graph Explorer. |
| La lista parpadea al escribir en el buscador | Consulta sin rebote | El buscador pasa por `debounceTime(350)` antes de `patchQuery`. |

---

## ✅ Checklist

- [ ] Revisado el ticket #453 completo (la foto se corta en el punto **b**).
- [ ] Tokens `--cu-*` conectados a tus variables de color en `courses-page.component.scss`.
- [ ] Valores del enum `CourseModality` iguales a los del backend.
- [ ] `CourseRepository` y `UsersDirectoryRepository` en `domain/`; la facade inyecta los contratos, no los servicios HTTP.
- [ ] La facade expone su estado con `asReadonly()`; ningún componente escribe sus señales.
- [ ] Revisados `shared/components` y `shared/services` antes de usar la paginación, esqueletos, confirmaciones y toasts de esta guía.
- [ ] Confirmado con negocio: solo los virtuales sin ID cuentan como pendientes (`externalIdExpected`).
- [ ] `ApiResponse` y `unwrap` en `@shared/utils`, sin copias en otras features.
- [ ] Backend: búsqueda, filtros y paginación en servidor; `stats` sin los filtros de modalidad y pendiente.
- [ ] Backend: únicos de **nombre + modalidad** y de **ID externo**, con respuesta `409`.
- [ ] Backend: `DateOnly` para `dueDate` y regla "un usuario, un grupo por curso".
- [ ] Backend: `PUT` ignora `modality`; `DELETE` hace borrado lógico si hay asignaciones.
- [ ] Backend: `/api/users/search` con Graph, permiso `User.Read.All` de aplicación y `ConsistencyLevel: eventual`.
- [ ] Ruta `cursos` con `permissionGuard`, permiso `courses` creado y entrada en el menú.
- [ ] Probado con teclado, lector de pantalla, 360 px, tema oscuro y `prefers-reduced-motion`.
- [ ] Pruebas unitarias de validadores, facade y buscador de usuarios en verde.
