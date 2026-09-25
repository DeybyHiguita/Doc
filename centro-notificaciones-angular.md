# 🔔 Centro de notificaciones animado (Angular 20 + Bootstrap 5)

Guía paso a paso para construir un **panel de notificaciones** que se despliega desde la campana del header:

- **En escritorio**, una tarjeta flotante de vidrio esmerilado **crece desde la campana** con un leve rebote y sus notificaciones entran en cascada.
- **En móvil**, una **hoja inferior** sube desde el borde, cómoda para el pulgar.

Al hacer clic en una notificación, se marca como leída con una animación y lleva a la página que corresponda según su tipo.

- **Stack:** Angular 20 · standalone · signals · OnPush · Bootstrap 5.3 (utilidades y variables) · animaciones CSS · Font Awesome · SSR · MSAL
- **Datos de cada notificación:** id, id del requerimiento, tipo, mensaje, si ya fue leída y fecha de creación

---

## 1. 🧐 Revisión crítica del requerimiento

Antes de diseñar, estos son los huecos del requerimiento y la decisión que toma esta guía para cada uno. Si alguna decisión no te sirve, cámbiala **antes** de construir, no después.

| # | Hueco o riesgo | Decisión |
|---|---|---|
| 1 | **El "tipo" como texto libre.** Si llega `"aprobada"`, `"APROBADA"` o `"Aprobado"`, cada variante rompe el ícono y la ruta. | Enum de strings + un mapa de configuración `Record<NotificationType, ...>`. Si agregas un tipo al enum y olvidas configurarlo, **no compila**. |
| 2 | **"La URL la creo yo"**, ¿pero dónde? Si cada componente arma su URL, en seis meses hay rutas repetidas y rotas. | Un solo archivo (`notification-type.config.ts`) define la ruta de cada tipo con comandos del Router. |
| 3 | **URL enviada por el backend.** Navegar a lo que diga la API abre la puerta a redirecciones a sitios externos. | El front nunca navega a una URL que llegue del servidor: la construye a partir del tipo y del `requestId`. |
| 4 | **¿Quién marca como leída?** El requerimiento no lo dice. | Se marca al hacer clic en ella. Abrir el cajón **no** marca todo como leído: eso ocultaría lo que el usuario no alcanzó a ver. Se agrega "Marcar todas como leídas" como acción explícita. |
| 5 | **Volumen.** Traer todas las notificaciones de un usuario con dos años de historial es lento y pesado. | Páginas de 20 con **keyset** (`beforeId`), no con número de página: si llega una notificación nueva mientras paginas, el número de página duplica elementos y el keyset no. El backend ya tiene `KeysetPageRequest`. |
| 6 | **El contador de no leídas.** No se puede calcular con la primera página: puede haber no leídas en la página 5. | El contador lo entrega el servidor. |
| 7 | **¿Cómo llegan las nuevas?** El requerimiento no lo dice. | Consulta del contador cada 60 s, solo con la pestaña visible. El contenido del cajón se refresca cada vez que se abre. SignalR queda para después, si el negocio lo pide. |
| 8 | **Zona horaria.** Si la API envía `2026-09-25T14:30:00` sin zona, JavaScript lo lee como hora local y el "hace 5 min" queda corrido 5 horas. | El mapper interpreta las fechas sin zona como UTC. Lo correcto es que el backend envíe la zona; confírmalo con ellos. |
| 9 | **El mensaje con HTML.** Pintarlo con `innerHTML` es XSS. | Solo texto, con interpolación `{{ }}`. |
| 10 | **"Leída" solo con color.** Un usuario daltónico o con lector de pantalla no la distingue. | Punto + negrita + fondo + texto oculto "No leída". |
| 11 | **Nombre `Notification`.** Choca con la API del navegador `window.Notification`. | El modelo se llama `AppNotification`. |
| 12 | **Ya existe `shared/components/notification`.** Otro componente con nombre parecido genera confusión. | Revisa qué hace el existente antes de crear este. Aquí se llama `notification-center` para diferenciarlo. |
| 13 | **Seguridad del backend.** `markAsRead(id)` sin validar dueño deja a cualquiera marcar notificaciones ajenas. | Los endpoints filtran por el usuario del token, nunca por un `userId` enviado por el cliente. |
| 14 | **Animaciones que estorban.** Un panel que tarda en abrir, una campana que suena en cada carga o un rebote exagerado cansan en la segunda semana. | Solo `transform` y `opacity`; abrir en ~320 ms y cerrar en 160 ms; la campana suena solo cuando el contador **sube**; todo se apaga con `prefers-reduced-motion`. |

**Fuera de alcance, pero pregúntalo:** borrar o archivar notificaciones, filtro "Solo no leídas" (debe hacerse en el servidor, no sobre la página cargada), notificaciones del navegador y retención (cuánto tiempo se guardan).

---

## 2. 🎨 Diseño

### La idea

El panel debe sentirse **conectado al botón que lo abrió**. Por eso nace desde la campana: escala desde el punto donde está el ícono, con una pequeña flecha que la señala. Un cajón lateral que tapa media pantalla, en cambio, se siente como otra página.

### Escritorio: tarjeta flotante

```text
                                              🔔 (3)
                                               ▲
                  ┌────────────────────────────┴──┐
                  │ Notificaciones  [3 nuevas]  ✓✓ ✕│
                  ├───────────────────────────────┤
                  │ HOY                             │ ← encabezado fijo al hacer scroll
                  │┃(✓) Solicitud aprobada   5 min ●│ ← no leída: barra de acento,
                  │┃    Tu certificado laboral fue  │   fondo suave y punto
                  │┃    aprobado y está listo.       │
                  │┃    # Solicitud 1284            │
                  │ (⏳) Pendiente de aprobación 2 h │ ← leída
                  │      Carlos Ruiz envió...       │
                  │ AYER                            │
                  │ (✕) Solicitud rechazada  ayer   │
                  │ ANTERIORES                      │
                  │ ...                             │
                  │           [ Ver más ]           │
                  └─────────────────────────────────┘
                   380 px · esquinas de 16 px · vidrio esmerilado · sombra profunda
```

### Móvil: hoja inferior

```text
┌─────────────────────────┐
│                         │
│   (página oscurecida)   │  ← tocar aquí cierra
│                         │
├─────────────────────────┤ ╮
│         ──────          │ │  asa decorativa
│ Notificaciones 3 nuevas │ │
│ HOY                     │ │  hasta 85 % del alto
│ (✓) Solicitud aprobada  │ │
│ ...                     │ ╯
└─────────────────────────┘
```

### Coreografía de animaciones

| Momento | Qué pasa | Duración y curva |
|---|---|---|
| **Abrir** (escritorio) | La tarjeta crece desde la campana: escala 0,9 → 1, sube 8 px, aparece | 320 ms · resorte leve `cubic-bezier(0.2, 0.9, 0.3, 1.15)` |
| **Cerrar** | Se encoge hacia la campana, sin rebote | 160 ms · `ease-in` |
| **Ítems al abrir** | Entran en cascada: suben 8 px y aparecen | 260 ms cada uno, 35 ms entre uno y otro, máximo 8 escalones |
| **Llega una nueva** | La campana se balancea y el badge da un salto | 900 ms |
| **Marcar como leída** | El resaltado se desvanece y el punto se encoge | 300 ms |
| **Marcar todas** | Los resaltados se apagan en ola, de arriba hacia abajo | 300 ms + 30 ms por ítem |
| **Abrir** (móvil) | La hoja sube desde el borde y el fondo se oscurece | 320 ms |
| **Estado vacío** | El check aparece con rebote y un anillo pulsa tres veces | 400 ms + 3 × 2,4 s |
| **Hover** en un ítem | Se desplaza 2 px, el ícono gira un poco y aparece una flecha | 200 ms |

**Reglas de la coreografía:**

1. Solo se animan `transform` y `opacity`: corren en la GPU y no causan saltos.
2. Cerrar es más rápido que abrir: el usuario ya decidió irse.
3. Nada bloquea el clic: se puede elegir una notificación mientras la cascada todavía entra.
4. La campana **no** suena al cargar la página, solo cuando el contador sube mientras el usuario está ahí.
5. Con `prefers-reduced-motion: reduce`, todo se reduce a un fundido corto.

### Detalles visuales

| Elemento | Tratamiento |
|---|---|
| Panel | Fondo translúcido con `backdrop-filter: blur(18px)` (vidrio), borde sutil, sombra de dos capas |
| Flecha | Cuadrado rotado 45° que apunta a la campana |
| Encabezado | Título + chip "3 nuevas" + "Marcar todas" + cerrar (la X gira al pasar el mouse) |
| Grupos | "Hoy", "Ayer", "Esta semana", "Anteriores", fijos arriba al hacer scroll |
| Ítem no leído | Barra de acento de 3 px a la izquierda + fondo suave + punto con halo + mensaje en negrita |
| Ícono del tipo | Cuadrado redondeado de 40 px con el color suave del tono |
| Badge de la campana | Píldora roja con borde del color del fondo, para que se despegue del ícono |

### Los cuatro estados

| Estado | Qué se ve |
|---|---|
| Cargando (primera vez) | 4 filas con `placeholder-wave` |
| Error | Ícono en círculo rojo + "No pudimos cargar tus notificaciones" + "Reintentar" |
| Vacío | Check verde con anillo que pulsa + "¡Estás al día!" |
| Con datos | Grupos por día + "Ver más" si hay más páginas |

Al abrir por segunda vez **no** se muestran los placeholders: se pinta lo que ya estaba, con su cascada, y se refresca por detrás.

### Accesibilidad

- El panel es un **diálogo no modal** (`role="dialog"`, `aria-modal="false"`): no atrapa el foco, igual que los paneles de notificaciones de GitHub o LinkedIn.
- Al abrir, el foco pasa al panel. **Esc** lo cierra y devuelve el foco a la campana. Un clic afuera lo cierra sin robar el foco.
- La campana anuncia el contador: `aria-label="Notificaciones, 3 sin leer"`, con `aria-expanded`, `aria-controls` y `aria-haspopup="dialog"`.
- Cada ítem que navega es un `<a>` real: permite Ctrl+clic y abrir en otra pestaña.
- "No leída" se distingue por barra, fondo, punto, negrita y un texto oculto para lectores de pantalla, no solo por el color.
- Cerrado, el panel queda con `visibility: hidden`: sale del orden de tabulación y del árbol de accesibilidad.

---

## 3. 📁 Archivos

```text
src/app/features/notifications/
├── domain/
│   ├── notification-type.enum.ts
│   ├── app-notification.model.ts
│   └── notification-type.config.ts            ⭐ ícono, color, etiqueta y RUTA por tipo
├── infraestructure/
│   ├── notification.dto.ts
│   ├── notification.mapper.ts
│   └── notifications.service.ts
├── application/
│   ├── notification-center.facade.ts          ⭐ estado compartido (campana + panel)
│   └── notification-groups.ts                 agrupa por Hoy / Ayer / Esta semana / Anteriores
└── presentation/
    ├── notification-center/                   ⭐ campana + panel animado
    │   ├── notification-center.component.ts
    │   ├── notification-center.component.html
    │   └── notification-center.component.scss
    └── notification-item/
        ├── notification-item.component.ts
        ├── notification-item.component.html
        └── notification-item.component.scss

src/app/shared/utils/
└── relative-time.ts
```

---

## 4. Paso 1 — Por qué un panel propio y no Offcanvas

El Offcanvas de Bootstrap solo sabe entrar desde un borde de la pantalla. No puede crecer desde la campana, que es lo que hace que el panel se sienta conectado al botón.

| | Offcanvas | Panel propio |
|---|---|---|
| Animación | Deslizar desde el borde | Crece desde la campana, cascada, resorte |
| JavaScript extra | Módulo de Bootstrap con `import()` dinámico por SSR | Ninguno |
| Esc, clic afuera y foco | Los trae Offcanvas | ~20 líneas en el componente |
| Móvil | Panel lateral | Hoja inferior, natural para el pulgar |

**No hay nada que instalar.** Si instalaste `@types/bootstrap` solo para el Offcanvas, puedes quitarlo.

> Las animaciones son **CSS puro** con clases (`is-open`, `is-ringing`). No se usa `@angular/animations`, que quedó marcado como obsoleto desde Angular 20.2. Las transiciones de `transform` y `opacity` corren en la GPU y no pasan por la detección de cambios.

---

## 5. Paso 2 — Domain

### `domain/notification-type.enum.ts`

```ts
/**
 * Tipos de notificación. Los valores deben coincidir EXACTAMENTE con los del backend.
 * Los de este archivo son ejemplos: reemplázalos por los reales.
 */
export enum NotificationType {
  RequestCreated = 'REQUEST_CREATED',
  RequestPendingApproval = 'REQUEST_PENDING_APPROVAL',
  RequestApproved = 'REQUEST_APPROVED',
  RequestRejected = 'REQUEST_REJECTED',
  CertificateReady = 'CERTIFICATE_READY',
  /** Respaldo para tipos que el front todavía no conoce. */
  General = 'GENERAL',
}
```

### `domain/app-notification.model.ts`

```ts
import { NotificationType } from './notification-type.enum';

/** Se llama AppNotification para no chocar con window.Notification del navegador. */
export interface AppNotification {
  readonly id: number;
  readonly requestId: number | null;
  readonly type: NotificationType;
  readonly message: string;
  readonly isRead: boolean;
  readonly createdAt: Date;
}
```

### `domain/notification-type.config.ts` — ⭐ aquí creas las URLs

```ts
import { AppNotification } from './app-notification.model';
import { NotificationType } from './notification-type.enum';

export type NotificationTone = 'primary' | 'success' | 'danger' | 'warning' | 'info' | 'secondary';

export interface NotificationTypeConfig {
  readonly label: string;
  /** Clase de Font Awesome, sin el prefijo de estilo. */
  readonly icon: string;
  readonly tone: NotificationTone;
  /**
   * Comandos del Router hacia donde lleva la notificación.
   * null = la notificación no navega (solo se marca como leída).
   */
  readonly route: (notification: AppNotification) => unknown[] | null;
}

/**
 * Un solo lugar para decidir cómo se ve y a dónde lleva cada tipo.
 * Al ser Record<NotificationType, ...>, agregar un tipo al enum sin configurarlo aquí NO compila.
 */
export const NOTIFICATION_TYPE_CONFIG: Record<NotificationType, NotificationTypeConfig> = {
  [NotificationType.RequestCreated]: {
    label: 'Solicitud creada',
    icon: 'fa-file-circle-plus',
    tone: 'primary',
    route: (n) => (n.requestId ? ['/requests', n.requestId] : null),
  },
  [NotificationType.RequestPendingApproval]: {
    label: 'Pendiente de aprobación',
    icon: 'fa-hourglass-half',
    tone: 'warning',
    route: (n) => (n.requestId ? ['/approvers', n.requestId] : null),
  },
  [NotificationType.RequestApproved]: {
    label: 'Solicitud aprobada',
    icon: 'fa-circle-check',
    tone: 'success',
    route: (n) => (n.requestId ? ['/requests', n.requestId] : null),
  },
  [NotificationType.RequestRejected]: {
    label: 'Solicitud rechazada',
    icon: 'fa-circle-xmark',
    tone: 'danger',
    route: (n) => (n.requestId ? ['/requests', n.requestId] : null),
  },
  [NotificationType.CertificateReady]: {
    label: 'Certificado disponible',
    icon: 'fa-file-pdf',
    tone: 'info',
    route: (n) => (n.requestId ? ['/certificados', n.requestId] : null),
  },
  [NotificationType.General]: {
    label: 'Aviso',
    icon: 'fa-bell',
    tone: 'secondary',
    route: () => null,
  },
};
```

> Las rutas de arriba son ejemplos. Reemplázalas por las reales de `app.routes.ts`. Las páginas destino siguen protegidas por `permissionGuard`: si el usuario perdió el permiso, el guard lo detiene aunque la notificación siga ahí.

---

## 6. Paso 3 — Infrastructure

### `infraestructure/notification.dto.ts`

Ajusta los nombres a lo que responde tu API.

```ts
export interface NotificationDto {
  notificationId: number;
  requestId: number | null;
  notificationType: string;
  message: string;
  isRead: boolean;
  /** ISO 8601. Idealmente con zona: "2026-09-25T14:30:00Z". */
  createdDate: string;
}

export interface NotificationPageDto {
  items: NotificationDto[];
  hasMore: boolean;
  unreadCount: number;
}

/** Envelope estándar del backend (ResponseDto serializado en camelCase). */
export interface ApiResponse<T> {
  hasError: boolean;
  errors?: string[] | null;
  response: T;
}
```

### `infraestructure/notification.mapper.ts`

```ts
import { AppNotification } from '../domain/app-notification.model';
import { NotificationType } from '../domain/notification-type.enum';
import { NotificationDto, NotificationPageDto } from './notification.dto';

export interface NotificationPage {
  readonly items: AppNotification[];
  readonly hasMore: boolean;
  readonly unreadCount: number;
}

const KNOWN_TYPES = new Set<string>(Object.values(NotificationType));

export function toAppNotification(dto: NotificationDto): AppNotification {
  return {
    id: dto.notificationId,
    requestId: dto.requestId,
    type: parseType(dto.notificationType),
    message: dto.message ?? '',
    isRead: dto.isRead,
    createdAt: parseApiDate(dto.createdDate),
  };
}

export function toNotificationPage(dto: NotificationPageDto): NotificationPage {
  return {
    items: dto.items.map(toAppNotification),
    hasMore: dto.hasMore,
    unreadCount: dto.unreadCount,
  };
}

/** Un tipo que el front no conoce no debe romper la lista: se muestra como General. */
function parseType(value: string): NotificationType {
  const normalized = value?.trim().toUpperCase();
  return KNOWN_TYPES.has(normalized) ? (normalized as NotificationType) : NotificationType.General;
}

/**
 * Si la fecha llega sin zona, JavaScript la interpreta como hora LOCAL.
 * Se asume que el backend guarda en UTC y se le agrega la "Z".
 * Confírmalo con el backend: lo correcto es que envíe la zona.
 */
function parseApiDate(value: string): Date {
  const hasZone = /(Z|[+-]\d{2}:?\d{2})$/i.test(value);
  return new Date(hasZone ? value : `${value}Z`);
}
```

### `infraestructure/notifications.service.ts`

Las URLs están bajo `/api/`, así que el interceptor de MSAL agrega el token.

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, NotificationPageDto } from './notification.dto';
import { NotificationPage, toNotificationPage } from './notification.mapper';

export interface NotificationQuery {
  readonly pageSize: number;
  /** Keyset: trae las anteriores a este id. */
  readonly beforeId?: number;
}

@Injectable({ providedIn: 'root' })
export class NotificationsService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/api/notifications`;

  getNotifications(query: NotificationQuery): Observable<NotificationPage> {
    let params = new HttpParams().set('pageSize', query.pageSize);
    if (query.beforeId) {
      params = params.set('beforeId', query.beforeId);
    }

    return this.http
      .get<ApiResponse<NotificationPageDto>>(this.baseUrl, { params })
      .pipe(map(unwrap), map(toNotificationPage));
  }

  getUnreadCount(): Observable<number> {
    return this.http.get<ApiResponse<number>>(`${this.baseUrl}/unread-count`).pipe(map(unwrap));
  }

  markAsRead(id: number): Observable<void> {
    return this.http
      .patch<ApiResponse<unknown>>(`${this.baseUrl}/${id}/read`, {})
      .pipe(map(unwrap), map(() => undefined));
  }

  markAllAsRead(): Observable<void> {
    return this.http
      .patch<ApiResponse<unknown>>(`${this.baseUrl}/read-all`, {})
      .pipe(map(unwrap), map(() => undefined));
  }
}

function unwrap<T>(response: ApiResponse<T>): T {
  if (response.hasError) {
    throw new Error(response.errors?.join(' ') || 'No se pudo completar la operación.');
  }
  return response.response;
}
```

> `environment.api.baseUrl` es un nombre supuesto: usa la propiedad real de tu `enviroment.ts`.

### Contrato que debe cumplir el backend

| Método | Ruta | Respuesta |
|---|---|---|
| `GET` | `/api/notifications?pageSize=20&beforeId=1284` | `{ items, hasMore, unreadCount }`, ordenado del más reciente al más antiguo |
| `GET` | `/api/notifications/unread-count` | `number` |
| `PATCH` | `/api/notifications/{id}/read` | vacío |
| `PATCH` | `/api/notifications/read-all` | vacío |

Todas filtran por el usuario del token. `PATCH /{id}/read` debe validar que la notificación le pertenezca a quien la marca.

---

## 7. Paso 4 — Application: la facade

Es `providedIn: 'root'` porque la campana y el cajón comparten el mismo estado, y ese estado sobrevive a la navegación.

### `application/notification-center.facade.ts`

```ts
import { Injectable, PLATFORM_ID, inject, signal } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { EMPTY, Subscription, catchError, filter, firstValueFrom, switchMap, timer } from 'rxjs';
import { AppNotification } from '../domain/app-notification.model';
import { NotificationsService } from '../infraestructure/notifications.service';

const PAGE_SIZE = 20;
const UNREAD_POLL_MS = 60_000;

export type NotificationCenterStatus = 'idle' | 'loading' | 'ready' | 'error';

@Injectable({ providedIn: 'root' })
export class NotificationCenterFacade {
  private readonly api = inject(NotificationsService);
  private readonly platformId = inject(PLATFORM_ID);

  private readonly _notifications = signal<readonly AppNotification[]>([]);
  private readonly _unreadCount = signal(0);
  private readonly _status = signal<NotificationCenterStatus>('idle');
  private readonly _hasMore = signal(false);
  private readonly _loadingMore = signal(false);
  private readonly _loadMoreFailed = signal(false);
  private readonly _unreadCountReady = signal(false);

  readonly notifications = this._notifications.asReadonly();
  readonly unreadCount = this._unreadCount.asReadonly();
  readonly status = this._status.asReadonly();
  readonly hasMore = this._hasMore.asReadonly();
  readonly loadingMore = this._loadingMore.asReadonly();
  readonly loadMoreFailed = this._loadMoreFailed.asReadonly();
  /** true cuando el contador ya vino del servidor. Evita que la campana suene al cargar la página. */
  readonly unreadCountReady = this._unreadCountReady.asReadonly();

  private pollingSubscription: Subscription | null = null;
  /** Evita que una respuesta vieja pise a una más nueva si se abre y cierra rápido. */
  private loadVersion = 0;

  /** Primera página. Si ya hay datos, los deja visibles y refresca por detrás. */
  async load(): Promise<void> {
    const version = ++this.loadVersion;

    if (this._notifications().length === 0) {
      this._status.set('loading');
    }

    try {
      const page = await firstValueFrom(this.api.getNotifications({ pageSize: PAGE_SIZE }));
      if (version !== this.loadVersion) return;

      this._notifications.set(page.items);
      this._hasMore.set(page.hasMore);
      this._unreadCount.set(page.unreadCount);
      this._unreadCountReady.set(true);
      this._loadMoreFailed.set(false);
      this._status.set('ready');
    } catch {
      if (version !== this.loadVersion) return;
      // Si falla un refresco pero ya había datos, se siguen mostrando.
      this._status.set(this._notifications().length > 0 ? 'ready' : 'error');
    }
  }

  async loadMore(): Promise<void> {
    const last = this._notifications().at(-1);
    if (!last || this._loadingMore() || !this._hasMore()) return;

    this._loadingMore.set(true);
    this._loadMoreFailed.set(false);

    try {
      const page = await firstValueFrom(
        this.api.getNotifications({ pageSize: PAGE_SIZE, beforeId: last.id }),
      );
      this._notifications.update((current) => mergeById(current, page.items));
      this._hasMore.set(page.hasMore);
    } catch {
      this._loadMoreFailed.set(true);
    } finally {
      this._loadingMore.set(false);
    }
  }

  /** Optimista: se marca de inmediato y se revierte si el servidor falla. */
  async markAsRead(notification: AppNotification): Promise<void> {
    if (notification.isRead) return;

    this.setReadState(notification.id, true);
    this._unreadCount.update((count) => Math.max(0, count - 1));

    try {
      await firstValueFrom(this.api.markAsRead(notification.id));
    } catch {
      this.setReadState(notification.id, false);
      this._unreadCount.update((count) => count + 1);
    }
  }

  async markAllAsRead(): Promise<void> {
    const previousItems = this._notifications();
    const previousCount = this._unreadCount();
    if (previousCount === 0) return;

    this._notifications.set(previousItems.map((n) => (n.isRead ? n : { ...n, isRead: true })));
    this._unreadCount.set(0);

    try {
      await firstValueFrom(this.api.markAllAsRead());
    } catch {
      this._notifications.set(previousItems);
      this._unreadCount.set(previousCount);
    }
  }

  /** Consulta el contador cada 60 s, solo en el navegador y con la pestaña visible. */
  startUnreadCountPolling(): void {
    if (!isPlatformBrowser(this.platformId) || this.pollingSubscription) return;

    this.pollingSubscription = timer(0, UNREAD_POLL_MS)
      .pipe(
        filter(() => document.visibilityState === 'visible'),
        // catchError DENTRO del switchMap: un error de red no debe matar el polling.
        switchMap(() => this.api.getUnreadCount().pipe(catchError(() => EMPTY))),
      )
      .subscribe((count) => {
        this._unreadCount.set(count);
        this._unreadCountReady.set(true);
      });
  }

  /** Llamar al cerrar sesión. */
  stopUnreadCountPolling(): void {
    this.pollingSubscription?.unsubscribe();
    this.pollingSubscription = null;
  }

  private setReadState(id: number, isRead: boolean): void {
    this._notifications.update((items) => items.map((n) => (n.id === id ? { ...n, isRead } : n)));
  }
}

function mergeById(
  current: readonly AppNotification[],
  incoming: readonly AppNotification[],
): AppNotification[] {
  const seen = new Set(current.map((n) => n.id));
  return [...current, ...incoming.filter((n) => !seen.has(n.id))];
}
```

---

## 8. Paso 5 — Utilidades: fecha relativa y grupos por día

### `shared/utils/relative-time.ts`

```ts
const relativeFormatter = new Intl.RelativeTimeFormat('es', { numeric: 'auto' });
const absoluteFormatter = new Intl.DateTimeFormat('es-CO', { dateStyle: 'long', timeStyle: 'short' });
const shortDateFormatter = new Intl.DateTimeFormat('es-CO', { dateStyle: 'medium' });

/** "hace un momento", "hace 5 minutos", "ayer", "hace 3 días" o la fecha si pasó una semana. */
export function formatRelativeTime(date: Date, now: Date = new Date()): string {
  const seconds = Math.round((date.getTime() - now.getTime()) / 1000);
  const absolute = Math.abs(seconds);

  if (absolute < 60) return 'hace un momento';
  if (absolute < 3_600) return relativeFormatter.format(Math.round(seconds / 60), 'minute');
  if (absolute < 86_400) return relativeFormatter.format(Math.round(seconds / 3_600), 'hour');
  if (absolute < 604_800) return relativeFormatter.format(Math.round(seconds / 86_400), 'day');
  return shortDateFormatter.format(date);
}

/** Para el tooltip: "25 de septiembre de 2026, 2:30 p. m." */
export function formatAbsoluteDate(date: Date): string {
  return absoluteFormatter.format(date);
}
```

> La fecha relativa se calcula cuando se pinta el ítem y no se actualiza sola. Es aceptable porque el cajón se refresca cada vez que se abre.

---

### `application/notification-groups.ts`

Agrupa en "Hoy", "Ayer", "Esta semana" y "Anteriores". Cada entrada guarda su posición global (`order`), que es la que usa la cascada de la animación.

```ts
import { AppNotification } from '../domain/app-notification.model';

export type NotificationGroupKey = 'today' | 'yesterday' | 'week' | 'older';

export interface NotificationEntry {
  readonly notification: AppNotification;
  /** Posición global en la lista: define el retraso de la cascada. */
  readonly order: number;
}

export interface NotificationGroup {
  readonly key: NotificationGroupKey;
  readonly label: string;
  readonly entries: readonly NotificationEntry[];
}

const DAY_MS = 86_400_000;
const GROUP_ORDER: readonly NotificationGroupKey[] = ['today', 'yesterday', 'week', 'older'];
const GROUP_LABELS: Record<NotificationGroupKey, string> = {
  today: 'Hoy',
  yesterday: 'Ayer',
  week: 'Esta semana',
  older: 'Anteriores',
};

/** Espera la lista ordenada de la más reciente a la más antigua, como la entrega la API. */
export function groupByDay(
  items: readonly AppNotification[],
  now: Date = new Date(),
): NotificationGroup[] {
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const buckets = new Map<NotificationGroupKey, NotificationEntry[]>();

  items.forEach((notification, order) => {
    const key = bucketOf(notification.createdAt.getTime(), startOfToday);
    const entries = buckets.get(key) ?? [];
    entries.push({ notification, order });
    buckets.set(key, entries);
  });

  return GROUP_ORDER.filter((key) => buckets.has(key)).map((key) => ({
    key,
    label: GROUP_LABELS[key],
    entries: buckets.get(key)!,
  }));
}

function bucketOf(time: number, startOfToday: number): NotificationGroupKey {
  if (time >= startOfToday) return 'today';
  if (time >= startOfToday - DAY_MS) return 'yesterday';
  if (time >= startOfToday - 6 * DAY_MS) return 'week';
  return 'older';
}
```

---

## 9. Paso 6 — El ítem

### `presentation/notification-item/notification-item.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import { NgTemplateOutlet } from '@angular/common';
import { RouterLink } from '@angular/router';
import { AppNotification } from '../../domain/app-notification.model';
import { NOTIFICATION_TYPE_CONFIG } from '../../domain/notification-type.config';
import { formatAbsoluteDate, formatRelativeTime } from '@shared/utils/relative-time';

@Component({
  selector: 'app-notification-item',
  imports: [RouterLink, NgTemplateOutlet],
  templateUrl: './notification-item.component.html',
  styleUrl: './notification-item.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NotificationItemComponent {
  readonly notification = input.required<AppNotification>();

  /** navigates = true cuando el clic lleva a otra página. */
  readonly selected = output<{ navigates: boolean }>();

  readonly config = computed(() => NOTIFICATION_TYPE_CONFIG[this.notification().type]);
  readonly link = computed(() => this.config().route(this.notification()));
  readonly isUnread = computed(() => !this.notification().isRead);
  readonly relativeDate = computed(() => formatRelativeTime(this.notification().createdAt));
  readonly absoluteDate = computed(() => formatAbsoluteDate(this.notification().createdAt));
  readonly isoDate = computed(() => this.notification().createdAt.toISOString());

  readonly iconClasses = computed(() => {
    const tone = this.config().tone;
    return `nc-item__icon bg-${tone}-subtle text-${tone}-emphasis`;
  });

  readonly iconGlyph = computed(() => `fa-solid ${this.config().icon}`);
}
```

### `notification-item.component.html`

El punto de "no leída" **siempre está en el DOM** y se muestra u oculta con una clase: si se quitara con `@if`, desaparecería de golpe y no se podría animar.

```html
@if (link(); as commands) {
  <a
    class="nc-item"
    [class.is-unread]="isUnread()"
    [routerLink]="commands"
    (click)="selected.emit({ navigates: true })">
    <ng-container [ngTemplateOutlet]="content" />
  </a>
} @else {
  <button
    type="button"
    class="nc-item"
    [class.is-unread]="isUnread()"
    (click)="selected.emit({ navigates: false })">
    <ng-container [ngTemplateOutlet]="content" />
  </button>
}

<ng-template #content>
  <span [class]="iconClasses()" aria-hidden="true">
    <i [class]="iconGlyph()"></i>
  </span>

  <span class="nc-item__body">
    @if (isUnread()) {
      <span class="visually-hidden">No leída.</span>
    }

    <span class="nc-item__meta">
      <span class="nc-item__label">{{ config().label }}</span>
      <time class="nc-item__time" [attr.datetime]="isoDate()" [title]="absoluteDate()">
        {{ relativeDate() }}
      </time>
    </span>

    <!-- Solo texto: nunca innerHTML -->
    <span class="nc-item__message">{{ notification().message }}</span>

    @if (notification().requestId; as requestId) {
      <span class="nc-item__request">
        <i class="fa-solid fa-hashtag" aria-hidden="true"></i> Solicitud {{ requestId }}
      </span>
    }
  </span>

  <span class="nc-item__dot" aria-hidden="true"></span>

  @if (link()) {
    <i class="fa-solid fa-chevron-right nc-item__chevron" aria-hidden="true"></i>
  }
</ng-template>
```

### `notification-item.component.scss`

```scss
:host {
  display: block;
}

.nc-item {
  --nc-accent: var(--bs-primary);

  position: relative;
  display: flex;
  align-items: flex-start;
  gap: 0.875rem;
  width: 100%;
  padding: 0.875rem 1rem 0.875rem 1.125rem;
  border: 0;
  border-radius: 0.75rem;
  background: transparent;
  color: var(--bs-body-color);
  text-align: start;
  text-decoration: none;
  transition: background-color 0.2s ease, transform 0.2s ease;

  // Resaltado de "no leída" en una capa aparte: se desvanece sin pelear con el hover.
  &::before {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background:
      linear-gradient(90deg, var(--nc-accent) 0 3px, transparent 3px),
      var(--bs-primary-bg-subtle);
    opacity: 0;
    transition: opacity 0.3s ease;
    pointer-events: none;
  }

  &.is-unread::before {
    opacity: 1;
  }

  // El contenido va por encima de la capa de resaltado.
  > * {
    position: relative;
  }

  &:hover,
  &:focus-visible {
    background-color: var(--bs-tertiary-bg);
  }

  &:hover {
    transform: translateX(2px);
  }

  &:focus-visible {
    outline: 2px solid var(--bs-primary);
    outline-offset: -2px;
  }
}

// "Marcar todas": los resaltados se apagan en ola, de arriba hacia abajo.
// --nc-order lo define el <li> en el panel.
:host-context(.nc-panel--marking-all) .nc-item::before {
  transition-delay: calc(min(var(--nc-order, 0), 12) * 30ms);
}

.nc-item__icon {
  flex-shrink: 0;
  display: inline-grid;
  place-items: center;
  width: 2.5rem;
  height: 2.5rem;
  border-radius: 0.75rem;
  font-size: 1rem;
  transition: transform 0.25s cubic-bezier(0.2, 0.9, 0.3, 1.3);
}

.nc-item:hover .nc-item__icon {
  transform: scale(1.08) rotate(-4deg);
}

.nc-item__body {
  flex-grow: 1;
  min-width: 0; // permite cortar el texto dentro de un flex
}

.nc-item__meta {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5rem;
}

.nc-item__label {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--bs-secondary-color);
}

.nc-item__time {
  flex-shrink: 0;
  font-size: 0.75rem;
  color: var(--bs-secondary-color);
}

.nc-item__message {
  display: -webkit-box;
  margin-top: 0.2rem;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  font-size: 0.875rem;
  line-height: 1.4;

  .is-unread & {
    font-weight: 600;
  }
}

.nc-item__request {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  margin-top: 0.35rem;
  font-size: 0.75rem;
  color: var(--bs-secondary-color);
}

.nc-item__dot {
  flex-shrink: 0;
  width: 0.5rem;
  height: 0.5rem;
  margin-top: 0.45rem;
  border-radius: 50%;
  background: var(--nc-accent);
  box-shadow: 0 0 0 3px rgba(var(--bs-primary-rgb), 0.18);
  transform: scale(0);
  transition: transform 0.3s cubic-bezier(0.2, 0.9, 0.3, 1.3);

  .is-unread & {
    transform: scale(1);
  }
}

.nc-item__chevron {
  align-self: center;
  flex-shrink: 0;
  font-size: 0.7rem;
  color: var(--bs-secondary-color);
  opacity: 0;
  transform: translateX(-4px);
  transition: opacity 0.2s ease, transform 0.2s ease;
}

.nc-item:hover .nc-item__chevron,
.nc-item:focus-visible .nc-item__chevron {
  opacity: 0.6;
  transform: none;
}

@media (prefers-reduced-motion: reduce) {
  .nc-item,
  .nc-item::before,
  .nc-item__icon,
  .nc-item__dot,
  .nc-item__chevron {
    transition-duration: 0.01ms !important;
    transition-delay: 0s !important;
  }

  .nc-item:hover,
  .nc-item:hover .nc-item__icon {
    transform: none;
  }
}
```

> `bg-*-subtle`, `text-*-emphasis` y `--bs-primary-bg-subtle` existen desde Bootstrap 5.3.

---

## 10. Paso 7 — El centro: campana + panel animado

### `presentation/notification-center/notification-center.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  DestroyRef,
  ElementRef,
  Injector,
  PLATFORM_ID,
  afterNextRender,
  computed,
  effect,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { NavigationStart, Router } from '@angular/router';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { filter } from 'rxjs';
import { NotificationCenterFacade } from '../../application/notification-center.facade';
import { groupByDay } from '../../application/notification-groups';
import { AppNotification } from '../../domain/app-notification.model';
import { NotificationItemComponent } from '../notification-item/notification-item.component';

/** Deben coincidir con las duraciones del SCSS. */
const RING_ANIMATION_MS = 900;
const MARK_ALL_ANIMATION_MS = 900;

@Component({
  selector: 'app-notification-center',
  imports: [NotificationItemComponent],
  templateUrl: './notification-center.component.html',
  styleUrl: './notification-center.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: {
    '(document:keydown.escape)': 'onEscape()',
    '(document:click)': 'onDocumentClick($event)',
  },
})
export class NotificationCenterComponent {
  protected readonly facade = inject(NotificationCenterFacade);
  private readonly host = inject<ElementRef<HTMLElement>>(ElementRef);
  private readonly injector = inject(Injector);
  private readonly isBrowser = isPlatformBrowser(inject(PLATFORM_ID));

  private readonly trigger = viewChild.required<ElementRef<HTMLButtonElement>>('trigger');
  private readonly panel = viewChild.required<ElementRef<HTMLElement>>('panel');

  readonly isOpen = signal(false);
  readonly isRinging = signal(false);
  readonly isMarkingAll = signal(false);
  readonly skeletonRows = [0, 1, 2, 3];

  readonly groups = computed(() => groupByDay(this.facade.notifications()));

  readonly badgeText = computed(() => {
    const count = this.facade.unreadCount();
    return count > 99 ? '99+' : String(count);
  });

  readonly triggerLabel = computed(() => {
    const count = this.facade.unreadCount();
    return count === 0 ? 'Notificaciones' : `Notificaciones, ${count} sin leer`;
  });

  readonly unreadLabel = computed(() => {
    const count = this.facade.unreadCount();
    return count === 1 ? '1 nueva' : `${count} nuevas`;
  });

  private lastSeenCount: number | null = null;
  private ringTimer?: ReturnType<typeof setTimeout>;
  private markAllTimer?: ReturnType<typeof setTimeout>;

  constructor() {
    this.facade.startUnreadCountPolling();

    // La campana suena solo cuando el contador SUBE. El primer valor del servidor
    // se registra sin sonar: así no suena en cada carga de página.
    effect(() => {
      const count = this.facade.unreadCount();
      if (!this.facade.unreadCountReady()) return;

      if (this.lastSeenCount !== null && count > this.lastSeenCount) {
        this.ring();
      }
      this.lastSeenCount = count;
    });

    // Cualquier navegación (clic en una notificación, botón atrás) cierra el panel.
    inject(Router)
      .events.pipe(
        filter((event) => event instanceof NavigationStart),
        takeUntilDestroyed(),
      )
      .subscribe(() => this.close({ restoreFocus: false }));

    inject(DestroyRef).onDestroy(() => {
      clearTimeout(this.ringTimer);
      clearTimeout(this.markAllTimer);
    });
  }

  toggle(): void {
    if (this.isOpen()) {
      this.close();
    } else {
      this.open();
    }
  }

  open(): void {
    if (this.isOpen()) return;

    this.isOpen.set(true);
    void this.facade.load();

    // Mueve el foco cuando el panel ya es visible.
    afterNextRender(() => this.panel().nativeElement.focus({ preventScroll: true }), {
      injector: this.injector,
    });
  }

  close(options: { restoreFocus?: boolean } = {}): void {
    if (!this.isOpen()) return;

    this.isOpen.set(false);
    if (options.restoreFocus ?? true) {
      this.trigger().nativeElement.focus();
    }
  }

  onSelect(notification: AppNotification, navigates: boolean): void {
    void this.facade.markAsRead(notification);
    if (navigates) {
      this.close({ restoreFocus: false });
    }
  }

  markAllAsRead(): void {
    // La clase activa la ola de la animación solo durante esta acción.
    this.isMarkingAll.set(true);
    clearTimeout(this.markAllTimer);
    this.markAllTimer = setTimeout(() => this.isMarkingAll.set(false), MARK_ALL_ANIMATION_MS);

    void this.facade.markAllAsRead();
  }

  protected onEscape(): void {
    if (this.isOpen()) {
      this.close();
    }
  }

  protected onDocumentClick(event: MouseEvent): void {
    // Los clics dentro del componente (campana o panel) no cuentan como "afuera".
    if (this.isOpen() && !this.host.nativeElement.contains(event.target as Node)) {
      this.close({ restoreFocus: false });
    }
  }

  private ring(): void {
    if (!this.isBrowser || this.isRinging()) return;

    this.isRinging.set(true);
    this.ringTimer = setTimeout(() => this.isRinging.set(false), RING_ANIMATION_MS);
  }
}
```

### `notification-center.component.html`

```html
<!-- Campana -->
<button
  #trigger
  type="button"
  class="nc-trigger btn"
  [class.is-open]="isOpen()"
  [class.is-ringing]="isRinging()"
  aria-haspopup="dialog"
  aria-controls="notificationCenterPanel"
  [attr.aria-expanded]="isOpen()"
  [attr.aria-label]="triggerLabel()"
  (click)="toggle()">
  <i class="nc-trigger__bell fa-regular fa-bell" aria-hidden="true"></i>
  @if (facade.unreadCount() > 0) {
    <span class="nc-trigger__badge" aria-hidden="true">{{ badgeText() }}</span>
  }
</button>

<!-- Fondo oscuro: solo se ve en móvil -->
<div
  class="nc-backdrop"
  [class.is-open]="isOpen()"
  aria-hidden="true"
  (click)="close({ restoreFocus: false })"></div>

<!-- Panel -->
<section
  #panel
  id="notificationCenterPanel"
  class="nc-panel"
  [class.is-open]="isOpen()"
  [class.nc-panel--marking-all]="isMarkingAll()"
  role="dialog"
  aria-modal="false"
  aria-labelledby="notificationCenterTitle"
  tabindex="-1">

  <span class="nc-panel__caret" aria-hidden="true"></span>
  <span class="nc-panel__handle" aria-hidden="true"></span>

  <header class="nc-panel__header">
    <div class="d-flex align-items-center gap-2">
      <h2 id="notificationCenterTitle" class="nc-panel__title">Notificaciones</h2>
      @if (facade.unreadCount() > 0) {
        <span class="nc-panel__chip">{{ unreadLabel() }}</span>
      }
    </div>

    <div class="d-flex align-items-center gap-1">
      <button
        type="button"
        class="btn btn-sm nc-panel__action"
        [disabled]="facade.unreadCount() === 0"
        (click)="markAllAsRead()">
        <i class="fa-solid fa-check-double me-1" aria-hidden="true"></i>Marcar todas
      </button>
      <button type="button" class="btn-close nc-panel__close" aria-label="Cerrar notificaciones" (click)="close()"></button>
    </div>
  </header>

  <div class="nc-panel__body" [attr.aria-busy]="facade.status() === 'loading'">
    @switch (facade.status()) {
      @case ('loading') {
        <ul class="list-unstyled mb-0 p-2" aria-label="Cargando notificaciones">
          @for (row of skeletonRows; track row) {
            <li class="d-flex gap-3 p-3 placeholder-wave">
              <span class="placeholder nc-skeleton__icon"></span>
              <span class="flex-grow-1">
                <span class="placeholder col-4 d-block mb-2 rounded"></span>
                <span class="placeholder col-11 d-block mb-1 rounded"></span>
                <span class="placeholder col-7 d-block rounded"></span>
              </span>
            </li>
          }
        </ul>
      }

      @case ('error') {
        <div class="nc-state" role="alert">
          <span class="nc-state__icon nc-state__icon--error">
            <i class="fa-solid fa-plug-circle-exclamation" aria-hidden="true"></i>
          </span>
          <p class="nc-state__title">No pudimos cargar tus notificaciones</p>
          <button type="button" class="btn btn-sm btn-outline-danger" (click)="facade.load()">Reintentar</button>
        </div>
      }

      @default {
        @if (groups().length === 0) {
          <div class="nc-state">
            <span class="nc-state__icon nc-state__icon--done">
              <i class="fa-solid fa-check" aria-hidden="true"></i>
            </span>
            <p class="nc-state__title">¡Estás al día!</p>
            <p class="nc-state__text">Cuando pase algo con tus solicitudes, lo verás aquí.</p>
          </div>
        } @else {
          @for (group of groups(); track group.key) {
            <section class="nc-group" [attr.aria-labelledby]="'nc-group-' + group.key">
              <h3 class="nc-group__title" [id]="'nc-group-' + group.key">{{ group.label }}</h3>
              <ul class="nc-group__list">
                @for (entry of group.entries; track entry.notification.id) {
                  <li class="nc-group__item" [style.--nc-order]="entry.order">
                    <app-notification-item
                      [notification]="entry.notification"
                      (selected)="onSelect(entry.notification, $event.navigates)" />
                  </li>
                }
              </ul>
            </section>
          }

          @if (facade.hasMore()) {
            <div class="nc-more">
              @if (facade.loadMoreFailed()) {
                <p class="small text-danger mb-2">No se pudieron cargar más. Inténtalo de nuevo.</p>
              }
              <button
                type="button"
                class="btn btn-sm btn-outline-secondary rounded-pill px-3"
                [disabled]="facade.loadingMore()"
                (click)="facade.loadMore()">
                @if (facade.loadingMore()) {
                  <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>
                }
                Ver más
              </button>
            </div>
          }
        }
      }
    }
  </div>
</section>
```

> `[style.--nc-order]` es un binding de estilo a una variable CSS, no `ngStyle`: respeta la regla del proyecto.

### `notification-center.component.scss`

```scss
// ── Tokens ──────────────────────────────────────────────────────────
:host {
  --nc-width: 380px;
  --nc-radius: 1rem;
  --nc-z: 1070;
  --nc-ease-spring: cubic-bezier(0.2, 0.9, 0.3, 1.15);
  --nc-ease-out: cubic-bezier(0.2, 0.8, 0.2, 1);

  position: relative;
  display: inline-block;
}

// ── Campana ─────────────────────────────────────────────────────────
.nc-trigger {
  position: relative;
  display: inline-grid;
  place-items: center;
  width: 2.5rem;
  height: 2.5rem;
  padding: 0;
  border: 0;
  border-radius: 50%;
  color: var(--bs-body-color);
  transition: background-color 0.2s ease;

  &:hover,
  &.is-open {
    background-color: var(--bs-tertiary-bg);
  }

  &:focus-visible {
    outline: 2px solid var(--bs-primary);
    outline-offset: 2px;
  }
}

.nc-trigger__bell {
  font-size: 1.15rem;
  transform-origin: 50% 10%; // pivota desde el "colgador", como una campana real
}

.nc-trigger.is-ringing .nc-trigger__bell {
  animation: nc-ring 0.9s ease-in-out;
}

.nc-trigger__badge {
  position: absolute;
  top: 0.15rem;
  right: 0.05rem;
  min-width: 1.15rem;
  height: 1.15rem;
  padding: 0 0.3rem;
  border-radius: 999px;
  background: var(--bs-danger);
  color: #fff;
  font-size: 0.65rem;
  font-weight: 700;
  line-height: 1.15rem;
  text-align: center;
  box-shadow: 0 0 0 2px var(--bs-body-bg); // se despega del ícono
  animation: nc-badge-in 0.35s var(--nc-ease-spring) both;
}

.nc-trigger.is-ringing .nc-trigger__badge {
  animation: nc-badge-bump 0.5s var(--nc-ease-spring);
}

// ── Panel: tarjeta flotante que crece desde la campana ─────────────
.nc-panel {
  position: absolute;
  top: calc(100% + 0.75rem);
  right: -0.5rem;
  z-index: var(--nc-z);
  display: flex;
  flex-direction: column;
  width: var(--nc-width);
  max-height: min(70vh, 560px);
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: var(--nc-radius);
  background: var(--bs-body-bg);
  box-shadow:
    0 1.5rem 3rem -0.75rem rgba(0, 0, 0, 0.25),
    0 0.25rem 0.75rem rgba(0, 0, 0, 0.08);
  outline: none;

  // Origen en la campana: 1.75rem desde el borde derecho del panel.
  transform-origin: calc(100% - 1.75rem) 0;
  opacity: 0;
  transform: translateY(-0.5rem) scale(0.9);
  visibility: hidden;

  // Cierre: rápido y sin rebote. visibility se oculta AL FINAL.
  transition:
    opacity 0.16s ease-in,
    transform 0.16s ease-in,
    visibility 0s linear 0.16s;

  &.is-open {
    opacity: 1;
    transform: none;
    visibility: visible;

    // Apertura: con resorte. visibility se muestra AL INICIO.
    transition:
      opacity 0.2s var(--nc-ease-out),
      transform 0.32s var(--nc-ease-spring),
      visibility 0s;
  }
}

// Vidrio esmerilado donde el navegador lo soporte.
@supports (backdrop-filter: blur(1px)) {
  .nc-panel {
    background: rgba(var(--bs-body-bg-rgb), 0.82);
    backdrop-filter: blur(18px) saturate(180%);
  }
}

.nc-panel__caret {
  position: absolute;
  top: -0.4rem;
  right: 1.35rem; // centro de la campana menos la mitad de la flecha
  width: 0.8rem;
  height: 0.8rem;
  border-top: 1px solid var(--bs-border-color-translucent);
  border-left: 1px solid var(--bs-border-color-translucent);
  background: var(--bs-body-bg);
  transform: rotate(45deg);
}

.nc-panel__handle {
  display: none;
}

.nc-panel__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 1rem 0.75rem 0.75rem 1.25rem;
  border-bottom: 1px solid var(--bs-border-color-translucent);
}

.nc-panel__title {
  margin: 0;
  font-size: 1.05rem;
  font-weight: 700;
}

.nc-panel__chip {
  flex-shrink: 0;
  padding: 0.15rem 0.55rem;
  border-radius: 999px;
  background: var(--bs-primary-bg-subtle);
  color: var(--bs-primary-text-emphasis);
  font-size: 0.75rem;
  font-weight: 600;
  animation: nc-fade-up 0.3s var(--nc-ease-out) both;
}

.nc-panel__action {
  border-radius: 999px;
  color: var(--bs-primary);
  font-weight: 500;

  &:hover:not(:disabled) {
    background: var(--bs-primary-bg-subtle);
  }
}

.nc-panel__close {
  transition: transform 0.2s ease;

  &:hover {
    transform: rotate(90deg);
  }
}

.nc-panel__body {
  overflow-y: auto;
  overscroll-behavior: contain; // el scroll no se pasa a la página
  padding: 0.25rem 0.5rem 0.5rem;
  scrollbar-width: thin;
}

// ── Grupos por día ──────────────────────────────────────────────────
.nc-group__title {
  position: sticky;
  top: 0;
  z-index: 1;
  margin: 0;
  padding: 0.75rem 0.75rem 0.35rem;
  background: linear-gradient(rgba(var(--bs-body-bg-rgb), 0.96) 70%, transparent);
  color: var(--bs-secondary-color);
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.nc-group__list {
  display: grid;
  gap: 0.125rem;
  margin: 0;
  padding: 0;
  list-style: none;
}

// Cascada: se reproduce cada vez que el panel se abre.
.nc-panel.is-open .nc-group__item {
  animation: nc-item-in 0.26s var(--nc-ease-out) both;
  animation-delay: calc(min(var(--nc-order, 0), 8) * 35ms + 60ms);
}

.nc-more {
  padding: 0.75rem;
  text-align: center;
}

// ── Estados ─────────────────────────────────────────────────────────
.nc-state {
  display: grid;
  justify-items: center;
  gap: 0.5rem;
  padding: 2.5rem 1.5rem;
  text-align: center;
  animation: nc-fade-up 0.35s var(--nc-ease-out) both;
}

.nc-state__icon {
  position: relative;
  display: inline-grid;
  place-items: center;
  width: 3.5rem;
  height: 3.5rem;
  border-radius: 50%;
  font-size: 1.35rem;

  &--done {
    background: var(--bs-success-bg-subtle);
    color: var(--bs-success-text-emphasis);

    // Anillo que pulsa tres veces y se detiene.
    &::after {
      content: '';
      position: absolute;
      inset: 0;
      border: 2px solid var(--bs-success);
      border-radius: inherit;
      opacity: 0;
      animation: nc-pulse 2.4s ease-out 0.4s 3;
    }
  }

  &--error {
    background: var(--bs-danger-bg-subtle);
    color: var(--bs-danger-text-emphasis);
  }
}

.nc-panel.is-open .nc-state__icon--done i {
  animation: nc-pop 0.4s var(--nc-ease-spring) 0.15s both;
}

.nc-state__title {
  margin: 0.5rem 0 0;
  font-weight: 600;
}

.nc-state__text {
  max-width: 16rem;
  margin: 0;
  color: var(--bs-secondary-color);
  font-size: 0.875rem;
}

.nc-skeleton__icon {
  width: 2.5rem;
  height: 2.5rem;
  border-radius: 0.75rem;
}

.nc-backdrop {
  display: none;
}

// ── Móvil: hoja inferior ────────────────────────────────────────────
@media (max-width: 575.98px) {
  .nc-backdrop {
    position: fixed;
    inset: 0;
    z-index: calc(var(--nc-z) - 1);
    display: block;
    background: rgba(0, 0, 0, 0.4);
    opacity: 0;
    visibility: hidden;
    transition: opacity 0.2s ease, visibility 0s linear 0.2s;

    &.is-open {
      opacity: 1;
      visibility: visible;
      transition: opacity 0.25s ease, visibility 0s;
    }
  }

  .nc-panel {
    position: fixed;
    top: auto;
    right: 0;
    bottom: 0;
    left: 0;
    width: 100%;
    max-height: 85vh;
    padding-bottom: env(safe-area-inset-bottom); // respeta la barra del iPhone
    border-radius: 1.25rem 1.25rem 0 0;
    opacity: 1;
    transform: translateY(100%);
    transition:
      transform 0.22s ease-in,
      visibility 0s linear 0.22s;

    &.is-open {
      transform: none;
      transition:
        transform 0.32s var(--nc-ease-out),
        visibility 0s;
    }
  }

  .nc-panel__caret {
    display: none;
  }

  .nc-panel__handle {
    display: block;
    width: 2.5rem;
    height: 0.3rem;
    margin: 0.6rem auto 0;
    border-radius: 999px;
    background: var(--bs-border-color);
  }
}

// ── Keyframes ───────────────────────────────────────────────────────
@keyframes nc-ring {
  0%, 100% { transform: rotate(0); }
  15% { transform: rotate(14deg); }
  30% { transform: rotate(-12deg); }
  45% { transform: rotate(9deg); }
  60% { transform: rotate(-6deg); }
  75% { transform: rotate(3deg); }
}

@keyframes nc-badge-in {
  from { transform: scale(0); }
  to { transform: scale(1); }
}

@keyframes nc-badge-bump {
  0%, 100% { transform: scale(1); }
  40% { transform: scale(1.35); }
}

@keyframes nc-item-in {
  from { opacity: 0; transform: translateY(0.5rem); }
  to { opacity: 1; transform: none; }
}

@keyframes nc-fade-up {
  from { opacity: 0; transform: translateY(0.25rem); }
  to { opacity: 1; transform: none; }
}

@keyframes nc-pop {
  from { transform: scale(0) rotate(-20deg); }
  to { transform: scale(1) rotate(0); }
}

@keyframes nc-pulse {
  0% { opacity: 0.6; transform: scale(1); }
  100% { opacity: 0; transform: scale(1.6); }
}

// ── Movimiento reducido: todo se vuelve un fundido corto ────────────
@media (prefers-reduced-motion: reduce) {
  .nc-panel,
  .nc-panel.is-open,
  .nc-backdrop,
  .nc-backdrop.is-open {
    transform: none !important;
    transition-property: opacity, visibility !important;
    transition-duration: 0.12s !important;
  }

  .nc-panel:not(.is-open) {
    opacity: 0 !important;
  }

  .nc-trigger.is-ringing .nc-trigger__bell,
  .nc-trigger__badge,
  .nc-trigger.is-ringing .nc-trigger__badge,
  .nc-panel.is-open .nc-group__item,
  .nc-panel__chip,
  .nc-state,
  .nc-state__icon--done::after,
  .nc-panel.is-open .nc-state__icon--done i {
    animation: none !important;
  }

  .nc-panel__close:hover {
    transform: none;
  }
}
```

---

## 11. Paso 8 — Ponerlo en el header

En el template del header (`shared/components/header` o `core/layout`):

```html
<app-notification-center />
```

Y en el `imports` del componente del header, `NotificationCenterComponent`.

**Cinco cuidados:**

1. **Solo con sesión iniciada.** El polling llama a la API cada 60 s. Si el header se pinta antes del login de MSAL, llegan 401 en cadena. Renderiza `<app-notification-center />` solo cuando haya usuario autenticado.
2. **Al cerrar sesión**, llama a `facade.stopUnreadCountPolling()` en el flujo de logout de `app.ts`.
3. **Si el panel aparece cortado**, el header o un contenedor padre tiene `overflow: hidden`. El panel flota por fuera del header y ese `overflow` lo recorta. Quítalo del contenedor que lo tenga.
4. **Si el panel queda debajo del contenido de la página**, el header crea su propio contexto de apilamiento con un `z-index` bajo. Sube el `z-index` del header o ajusta `--nc-z`.
5. **La campana debe estar a la derecha del header.** La tarjeta se alinea a la derecha de la campana. Si la campana va a la izquierda, cambia `right` por `left` en `.nc-panel` y `.nc-panel__caret`, y usa `transform-origin: 1.75rem 0`.

> En móvil la hoja usa `position: fixed`. Si algún contenedor padre tiene `transform`, `filter` o `will-change`, la hoja se ubicará respecto a ese contenedor y no respecto a la pantalla.

---

## 12. Pruebas

### Unitarias

```ts
describe('notification.mapper', () => {
  it('interpreta como UTC una fecha sin zona', () => {
    const n = toAppNotification({ ...dto, createdDate: '2026-09-25T14:30:00' });
    expect(n.createdAt.toISOString()).toBe('2026-09-25T14:30:00.000Z');
  });

  it('convierte un tipo desconocido en General', () => {
    const n = toAppNotification({ ...dto, notificationType: 'NUEVO_TIPO' });
    expect(n.type).toBe(NotificationType.General);
  });
});

describe('groupByDay', () => {
  const now = new Date(2026, 8, 25, 10, 0);
  const at = (date: Date, id: number) => ({ ...notification, id, createdAt: date });

  it('agrupa en Hoy, Ayer, Esta semana y Anteriores', () => {
    const groups = groupByDay(
      [
        at(new Date(2026, 8, 25, 8, 0), 4),
        at(new Date(2026, 8, 24, 20, 0), 3),
        at(new Date(2026, 8, 21, 9, 0), 2),
        at(new Date(2026, 7, 1, 9, 0), 1),
      ],
      now,
    );

    expect(groups.map((g) => g.label)).toEqual(['Hoy', 'Ayer', 'Esta semana', 'Anteriores']);
  });

  it('conserva la posición global para la cascada', () => {
    const groups = groupByDay([at(new Date(2026, 8, 25, 8, 0), 2), at(new Date(2026, 8, 24, 8, 0), 1)], now);

    expect(groups[1].entries[0].order).toBe(1);
  });
});

describe('NotificationCenterFacade', () => {
  it('revierte la marca de leída si el servidor falla', async () => {
    api.markAsRead.and.returnValue(throwError(() => new Error('500')));
    await facade.load();
    const unread = facade.notifications().find((n) => !n.isRead)!;
    const before = facade.unreadCount();

    await facade.markAsRead(unread);

    expect(facade.notifications().find((n) => n.id === unread.id)!.isRead).toBeFalse();
    expect(facade.unreadCount()).toBe(before);
  });
});
```

### Revisión de las animaciones

Hazla con quien pidió el cambio al lado. Las animaciones se juzgan viéndolas, no leyéndolas.

- **Apertura:** la tarjeta nace desde la campana, no desde el centro ni desde una esquina.
- **Cascada:** con 20 notificaciones, las primeras 8 entran escalonadas y el resto aparece sin esperar.
- **Campana:** suena al simular una notificación nueva y **no** suena al recargar la página. Para simularla, devuelve un contador mayor en el mock del servicio.
- **Marcar todas:** los resaltados se apagan en ola, de arriba hacia abajo.
- **Fluidez:** en DevTools → Performance, graba una apertura y verifica que no haya cuadros rojos (tareas largas).
- **Movimiento reducido:** en DevTools → Rendering → *Emulate CSS media feature prefers-reduced-motion*, todo debe verse como un fundido corto.
- **Vidrio:** en un navegador sin `backdrop-filter`, el panel se ve con fondo sólido, no transparente.

### Interacción y accesibilidad

- Solo con teclado: Tab hasta la campana, Enter abre y el foco entra al panel, Tab recorre los ítems, Esc cierra y el foco vuelve a la campana.
- Clic afuera cierra el panel; clic dentro no.
- Con lector de pantalla: la campana anuncia "Notificaciones, 3 sin leer" y cada ítem no leído anuncia "No leída".
- Ctrl+clic en una notificación: se abre en otra pestaña y la marca como leída.
- Un mensaje de 500 caracteres se corta en 3 líneas sin romper el diseño.
- En 360 px: la hoja sube desde abajo, el fondo se oscurece y tocarlo la cierra.
- Con SSR activo: la página renderiza sin errores de `document is not defined`.

---

## ✅ Checklist

- [ ] Revisado qué hace `shared/components/notification` para no duplicar.
- [ ] Valores del enum `NotificationType` iguales a los del backend.
- [ ] Rutas reales configuradas en `notification-type.config.ts`.
- [ ] Backend: paginación keyset, contador de no leídas y endpoints filtrados por el usuario del token.
- [ ] Backend: fechas con zona horaria (o confirmado que son UTC).
- [ ] El centro se renderiza solo con sesión iniciada y el polling se detiene al cerrar sesión.
- [ ] El header no tiene `overflow: hidden` ni un `z-index` que tape el panel.
- [ ] La campana suena solo cuando llegan notificaciones nuevas, no al cargar la página.
- [ ] Todas las animaciones usan solo `transform` y `opacity`.
- [ ] Probado con `prefers-reduced-motion: reduce`.
- [ ] Probado en móvil como hoja inferior.
- [ ] El mensaje se pinta con interpolación, nunca con `innerHTML`.
- [ ] "No leída" se distingue sin depender del color.
- [ ] Componentes con `OnPush`, `input()`, `output()` y signals; sin `ngClass` ni `ngStyle`.
