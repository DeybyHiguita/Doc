# 🔔 Centro de notificaciones (Angular 20 + Bootstrap 5)

Guía paso a paso para construir un **cajón lateral de notificaciones** que se abre desde un botón con campana en el header. Al hacer clic en una notificación, la marca como leída y lleva a la página que corresponda según su tipo.

- **Stack:** Angular 20 · standalone · signals · OnPush · Bootstrap 5.3 (Offcanvas) · Font Awesome · SSR · MSAL
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

**Fuera de alcance, pero pregúntalo:** borrar o archivar notificaciones, filtro "Solo no leídas" (debe hacerse en el servidor, no sobre la página cargada), notificaciones del navegador y retención (cuánto tiempo se guardan).

---

## 2. 🎨 Diseño

### El cajón

```text
                              ┌──────────────────────────────────────┐
                              │ Notificaciones   Marcar todas    ✕   │
  Header                      ├──────────────────────────────────────┤
 ┌────────────────────────┐   │▌(✓) Solicitud aprobada   hace 5 min ●│ ← no leída:
 │ Logo   ...     🔔 (3)  │   │▌    Tu certificado laboral fue       │   fondo, negrita
 └────────────────────────┘   │▌    aprobado y está listo.           │   y punto
                              │▌    Solicitud #1284                  │
                              ├──────────────────────────────────────┤
                              │ (⏳) Pendiente de aprobación   ayer  │ ← leída
                              │     Carlos Ruiz envió una solicitud   │
                              │     de vacaciones.                    │
                              │     Solicitud #1279                   │
                              ├──────────────────────────────────────┤
                              │ (✕) Solicitud rechazada   hace 3 días│
                              │     ...                               │
                              ├──────────────────────────────────────┤
                              │            [ Ver más ]                │
                              └──────────────────────────────────────┘
                                    400 px en escritorio · 100 % en móvil
```

### Anatomía de un ítem

| Zona | Contenido | Bootstrap |
|---|---|---|
| Ícono | Círculo de 36 px con el ícono del tipo | `rounded-circle bg-{tono}-subtle text-{tono}-emphasis` |
| Línea 1 | Etiqueta del tipo · fecha relativa | `small text-body-secondary` |
| Línea 2 | Mensaje, máximo 3 líneas | `line-clamp` propio |
| Línea 3 | "Solicitud #1284" | `small text-body-secondary` |
| Indicador | Punto azul de 8 px si no está leída | `rounded-circle bg-primary` |

### Los cuatro estados del cajón

| Estado | Qué se ve |
|---|---|
| Cargando (primera vez) | 4 filas con `placeholder-glow` |
| Error | `alert alert-danger` con botón "Reintentar" |
| Vacío | Campana gris + "No tienes notificaciones" |
| Con datos | Lista + "Ver más" si hay más páginas |

Al abrir el cajón por segunda vez **no** se muestran placeholders: se pinta lo que ya estaba y se refresca por detrás. Mostrar el esqueleto cada vez que se abre se siente lento.

### Accesibilidad

- El botón de la campana anuncia el contador: `aria-label="Notificaciones, 3 sin leer"`, con `aria-expanded` y `aria-controls`.
- El badge visual lleva `aria-hidden="true"`: el número ya está en el `aria-label`.
- Cada ítem que navega es un `<a>` real: permite Ctrl+clic y "abrir en otra pestaña". Los que no navegan son `<button>`.
- Bootstrap Offcanvas aporta foco atrapado, cierre con Esc y cierre con clic en el fondo.
- Al cerrar sin navegar, el foco vuelve a la campana.

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
│   └── notification-center.facade.ts          ⭐ estado compartido (campana + cajón)
└── presentation/
    ├── notification-center/                   ⭐ botón + cajón
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

## 4. Paso 1 — Instalar los tipos de Bootstrap

El cajón usa el JavaScript de Offcanvas de Bootstrap: resuelve el foco atrapado, Esc, el fondo y el bloqueo del scroll. Reimplementar eso a mano es donde suelen aparecer los bugs de accesibilidad.

```bash
npm install bootstrap
npm install -D @types/bootstrap
```

Si `bootstrap` ya está en `package.json`, solo agrega los tipos. El módulo se carga con `import()` dinámico y solo en el navegador (SSR).

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

  readonly notifications = this._notifications.asReadonly();
  readonly unreadCount = this._unreadCount.asReadonly();
  readonly status = this._status.asReadonly();
  readonly hasMore = this._hasMore.asReadonly();
  readonly loadingMore = this._loadingMore.asReadonly();
  readonly loadMoreFailed = this._loadMoreFailed.asReadonly();

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
      .subscribe((count) => this._unreadCount.set(count));
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

## 8. Paso 5 — Utilidad de fecha relativa

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
  readonly relativeDate = computed(() => formatRelativeTime(this.notification().createdAt));
  readonly absoluteDate = computed(() => formatAbsoluteDate(this.notification().createdAt));
  readonly isoDate = computed(() => this.notification().createdAt.toISOString());

  readonly iconClasses = computed(() => {
    const tone = this.config().tone;
    return `notification-item__icon flex-shrink-0 rounded-circle d-inline-flex align-items-center justify-content-center bg-${tone}-subtle text-${tone}-emphasis`;
  });

  readonly iconGlyph = computed(() => `fa-solid ${this.config().icon}`);
}
```

### `notification-item.component.html`

```html
@if (link(); as commands) {
  <a
    class="notification-item d-flex gap-3 px-3 py-3 text-decoration-none text-body"
    [class.notification-item--unread]="!notification().isRead"
    [routerLink]="commands"
    (click)="selected.emit({ navigates: true })">
    <ng-container [ngTemplateOutlet]="content" />
  </a>
} @else {
  <button
    type="button"
    class="notification-item d-flex gap-3 px-3 py-3 w-100 border-0 text-start text-body bg-transparent"
    [class.notification-item--unread]="!notification().isRead"
    (click)="selected.emit({ navigates: false })">
    <ng-container [ngTemplateOutlet]="content" />
  </button>
}

<ng-template #content>
  <span [class]="iconClasses()" aria-hidden="true">
    <i [class]="iconGlyph()"></i>
  </span>

  <span class="notification-item__body flex-grow-1">
    @if (!notification().isRead) {
      <span class="visually-hidden">No leída.</span>
    }

    <span class="d-flex justify-content-between align-items-baseline gap-2">
      <span class="small text-body-secondary">{{ config().label }}</span>
      <time
        class="small text-body-secondary text-nowrap"
        [attr.datetime]="isoDate()"
        [title]="absoluteDate()">
        {{ relativeDate() }}
      </time>
    </span>

    <!-- Solo texto: nunca innerHTML -->
    <span class="notification-item__message d-block mt-1">{{ notification().message }}</span>

    @if (notification().requestId; as requestId) {
      <span class="d-block small text-body-secondary mt-1">Solicitud #{{ requestId }}</span>
    }
  </span>

  @if (!notification().isRead) {
    <span class="notification-item__dot flex-shrink-0 rounded-circle bg-primary mt-2" aria-hidden="true"></span>
  }
</ng-template>
```

### `notification-item.component.scss`

```scss
.notification-item {
  transition: background-color 0.15s ease-in-out;

  &:hover,
  &:focus-visible {
    background-color: var(--bs-tertiary-bg);
  }

  &:focus-visible {
    outline: 2px solid var(--bs-primary);
    outline-offset: -2px;
  }

  &--unread {
    background-color: var(--bs-primary-bg-subtle);

    .notification-item__message {
      font-weight: 600;
    }
  }
}

.notification-item__icon {
  width: 2.25rem;
  height: 2.25rem;
}

.notification-item__body {
  min-width: 0; // permite que el texto se corte dentro de un flex
}

.notification-item__message {
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.notification-item__dot {
  width: 0.5rem;
  height: 0.5rem;
}
```

> `bg-*-subtle` y `text-*-emphasis` existen desde Bootstrap 5.3. En 5.2 usa `text-bg-{tono}`.

---

## 10. Paso 7 — El centro: campana + cajón

### `presentation/notification-center/notification-center.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  DestroyRef,
  ElementRef,
  afterNextRender,
  computed,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { NavigationStart, Router } from '@angular/router';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { filter } from 'rxjs';
import type Offcanvas from 'bootstrap/js/dist/offcanvas';
import { NotificationCenterFacade } from '../../application/notification-center.facade';
import { AppNotification } from '../../domain/app-notification.model';
import { NotificationItemComponent } from '../notification-item/notification-item.component';

@Component({
  selector: 'app-notification-center',
  imports: [NotificationItemComponent],
  templateUrl: './notification-center.component.html',
  styleUrl: './notification-center.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NotificationCenterComponent {
  protected readonly facade = inject(NotificationCenterFacade);
  private readonly destroyRef = inject(DestroyRef);

  private readonly panel = viewChild.required<ElementRef<HTMLElement>>('panel');
  private readonly trigger = viewChild.required<ElementRef<HTMLButtonElement>>('trigger');

  readonly isOpen = signal(false);
  readonly skeletonRows = [1, 2, 3, 4];

  readonly badgeText = computed(() => {
    const count = this.facade.unreadCount();
    return count > 99 ? '99+' : String(count);
  });

  readonly triggerLabel = computed(() => {
    const count = this.facade.unreadCount();
    return count === 0 ? 'Notificaciones' : `Notificaciones, ${count} sin leer`;
  });

  private offcanvas: Offcanvas | null = null;
  private navigating = false;
  private destroyed = false;

  constructor() {
    // afterNextRender solo corre en el navegador: seguro con SSR.
    afterNextRender(() => {
      void this.initOffcanvas();
      this.facade.startUnreadCountPolling();
    });

    // Cualquier navegación (clic en una notificación, botón atrás) cierra el cajón.
    inject(Router)
      .events.pipe(
        filter((event) => event instanceof NavigationStart),
        takeUntilDestroyed(),
      )
      .subscribe(() => {
        this.navigating = true;
        this.offcanvas?.hide();
      });

    this.destroyRef.onDestroy(() => {
      this.destroyed = true;
      this.offcanvas?.dispose();
    });
  }

  toggle(): void {
    this.offcanvas?.toggle();
  }

  close(): void {
    this.offcanvas?.hide();
  }

  onSelect(notification: AppNotification, navigates: boolean): void {
    void this.facade.markAsRead(notification);
    if (navigates) {
      this.navigating = true;
      this.close();
    }
  }

  private async initOffcanvas(): Promise<void> {
    const { default: OffcanvasClass } = await import('bootstrap/js/dist/offcanvas');
    if (this.destroyed) return;

    const element = this.panel().nativeElement;
    this.offcanvas = OffcanvasClass.getOrCreateInstance(element);

    const onShow = () => {
      this.navigating = false;
      this.isOpen.set(true);
      void this.facade.load();
    };

    const onHidden = () => {
      this.isOpen.set(false);
      // Si se cerró sin navegar, el foco vuelve a la campana.
      if (!this.navigating) {
        this.trigger().nativeElement.focus();
      }
    };

    element.addEventListener('show.bs.offcanvas', onShow);
    element.addEventListener('hidden.bs.offcanvas', onHidden);

    this.destroyRef.onDestroy(() => {
      element.removeEventListener('show.bs.offcanvas', onShow);
      element.removeEventListener('hidden.bs.offcanvas', onHidden);
    });
  }
}
```

### `notification-center.component.html`

```html
<!-- Campana -->
<button
  #trigger
  type="button"
  class="btn btn-link position-relative text-body p-2"
  aria-controls="notificationCenter"
  [attr.aria-expanded]="isOpen()"
  [attr.aria-label]="triggerLabel()"
  (click)="toggle()">
  <i class="fa-regular fa-bell fa-lg" aria-hidden="true"></i>
  @if (facade.unreadCount() > 0) {
    <span
      class="position-absolute top-0 start-100 translate-middle badge rounded-pill bg-danger"
      aria-hidden="true">
      {{ badgeText() }}
    </span>
  }
</button>

<!-- Cajón -->
<div
  #panel
  id="notificationCenter"
  class="offcanvas offcanvas-end notification-center"
  tabindex="-1"
  aria-labelledby="notificationCenterTitle">

  <div class="offcanvas-header border-bottom gap-2">
    <h2 id="notificationCenterTitle" class="offcanvas-title h5 mb-0 me-auto">Notificaciones</h2>
    <button
      type="button"
      class="btn btn-link btn-sm text-decoration-none px-0"
      [disabled]="facade.unreadCount() === 0"
      (click)="facade.markAllAsRead()">
      Marcar todas como leídas
    </button>
    <button type="button" class="btn-close ms-2" aria-label="Cerrar notificaciones" (click)="close()"></button>
  </div>

  <div class="offcanvas-body p-0" [attr.aria-busy]="facade.status() === 'loading'">
    @switch (facade.status()) {
      @case ('loading') {
        <ul class="list-unstyled mb-0" aria-label="Cargando notificaciones">
          @for (row of skeletonRows; track row) {
            <li class="d-flex gap-3 px-3 py-3 border-bottom placeholder-glow">
              <span class="placeholder rounded-circle notification-center__skeleton-icon"></span>
              <span class="flex-grow-1">
                <span class="placeholder col-4 d-block mb-2"></span>
                <span class="placeholder col-11 d-block mb-1"></span>
                <span class="placeholder col-7 d-block"></span>
              </span>
            </li>
          }
        </ul>
      }

      @case ('error') {
        <div class="p-3">
          <div class="alert alert-danger mb-0" role="alert">
            <p class="mb-2">No pudimos cargar tus notificaciones.</p>
            <button type="button" class="btn btn-outline-danger btn-sm" (click)="facade.load()">
              Reintentar
            </button>
          </div>
        </div>
      }

      @default {
        @if (facade.notifications().length === 0) {
          <div class="d-flex flex-column align-items-center justify-content-center text-center text-body-secondary p-5">
            <i class="fa-regular fa-bell fa-2x mb-3" aria-hidden="true"></i>
            <p class="mb-0">No tienes notificaciones.</p>
          </div>
        } @else {
          <ul class="list-group list-group-flush">
            @for (notification of facade.notifications(); track notification.id) {
              <li class="list-group-item p-0">
                <app-notification-item
                  [notification]="notification"
                  (selected)="onSelect(notification, $event.navigates)" />
              </li>
            }
          </ul>

          @if (facade.hasMore()) {
            <div class="p-3 text-center">
              @if (facade.loadMoreFailed()) {
                <p class="small text-danger mb-2">No se pudieron cargar más. Inténtalo de nuevo.</p>
              }
              <button
                type="button"
                class="btn btn-outline-secondary btn-sm"
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
</div>
```

### `notification-center.component.scss`

```scss
.notification-center {
  --bs-offcanvas-width: 400px;

  @media (max-width: 575.98px) {
    --bs-offcanvas-width: 100vw;
  }
}

.notification-center__skeleton-icon {
  width: 2.25rem;
  height: 2.25rem;
}
```

---

## 11. Paso 8 — Ponerlo en el header

En el template del header (`shared/components/header` o `core/layout`):

```html
<app-notification-center />
```

Y en el `imports` del componente del header, `NotificationCenterComponent`.

**Tres cuidados:**

1. **Solo con sesión iniciada.** El polling llama a la API cada 60 s. Si el header se pinta antes del login de MSAL, llegan 401 en cadena. Renderiza `<app-notification-center />` solo cuando haya usuario autenticado.
2. **Al cerrar sesión**, llama a `facade.stopUnreadCountPolling()` en el flujo de logout de `app.ts`.
3. **Si el cajón aparece cortado o en el lugar equivocado**, algún contenedor padre del header tiene `transform`, `filter` o `will-change`. Esas propiedades hacen que `position: fixed` se mida contra ese contenedor y no contra la ventana. Quítalas del padre o mueve el componente fuera de ese contenedor.

---

## 12. Pruebas

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

**Pruebas manuales que no se pueden saltar:**

- Solo con teclado: Tab hasta la campana, Enter abre, Tab recorre los ítems, Esc cierra y el foco vuelve a la campana.
- Con lector de pantalla: la campana anuncia "Notificaciones, 3 sin leer" y cada ítem no leído anuncia "No leída".
- Ctrl+clic en una notificación: se abre en otra pestaña y la marca como leída.
- Un mensaje de 500 caracteres: se corta en 3 líneas sin romper el diseño.
- Pantalla de 360 px: el cajón ocupa todo el ancho.
- Con SSR activo: la página renderiza sin errores de `document is not defined`.

---

## ✅ Checklist

- [ ] Revisado qué hace `shared/components/notification` para no duplicar.
- [ ] Valores del enum `NotificationType` iguales a los del backend.
- [ ] Rutas reales configuradas en `notification-type.config.ts`.
- [ ] Backend: paginación keyset, contador de no leídas y endpoints filtrados por el usuario del token.
- [ ] Backend: fechas con zona horaria (o confirmado que son UTC).
- [ ] `@types/bootstrap` instalado; Offcanvas cargado con `import()` dinámico.
- [ ] El centro se renderiza solo con sesión iniciada y el polling se detiene al cerrar sesión.
- [ ] El mensaje se pinta con interpolación, nunca con `innerHTML`.
- [ ] "No leída" se distingue sin depender del color.
- [ ] Componentes con `OnPush`, `input()`, `output()` y signals; sin `ngClass` ni `ngStyle`.
