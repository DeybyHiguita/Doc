# 👥 Grupos de usuarios (Angular 20 + Bootstrap 5)

Guía paso a paso para la página que **arma grupos de usuarios**. Un grupo se construye combinando tres formas de agregar personas:

| Pestaña | Qué hace |
|---|---|
| **Por líder** | Escribes el correo de uno o varios managers y se trae su equipo desde el directorio de Microsoft (Graph). Puedes elegir solo los colaboradores directos o todos los niveles. |
| **Buscar persona** | Buscas por nombre o correo en el maestro de usuarios (`dbo.users`) y en el directorio al mismo tiempo, y agregas a alguien puntual. |
| **Pegar correos** | Pegas una lista (columna de Excel, destinatarios de Outlook, CSV) y se valida completa antes de agregarla. |

Cada persona muestra de dónde viene: **Maestro** (está en `dbo.users`, relacionada por `corporative_email`) o **Solo directorio** (existe en Microsoft, pero no en el maestro).

- **Stack:** Angular 20 · standalone · signals · OnPush · Bootstrap 5.3 · Font Awesome · SweetAlert2 · SSR · MSAL
- **Backend:** [grupos-usuarios-api-sqlserver.md](grupos-usuarios-api-sqlserver.md)

---

## 1. 🧐 Revisión crítica del requerimiento

| # | Hueco o riesgo | Decisión |
|---|---|---|
| 1 | **¿El grupo cambia solo si el líder cambia de equipo?** | No. Se guarda una **foto** del momento. La pantalla lo dice claramente y el backend guarda qué líderes se usaron, para poder agregar después un botón "Actualizar equipos". |
| 2 | **Personas "solo directorio".** Existen en Microsoft pero no en `dbo.users`. Los procesos que dependen del maestro no las ven. | Se aceptan, pero se marcan con un distintivo y el resumen avisa cuántas son. **Cursos no las asigna:** `course_assignment_user` se relaciona con `dbo.users`, así que solo reciben el curso quienes tienen usuario; el editor de cursos avisa cuántas quedan fuera ([cursos-grupos-finalizacion-api-sqlserver.md](cursos-grupos-finalizacion-api-sqlserver.md)). Para que las reciban, hay que cargarlas en el maestro. |
| 3 | **"Todos los niveles" puede traer media empresa.** | Casilla apagada por defecto, tope de 2.000 personas por líder, y todo pasa por una vista previa con casillas antes de agregarse. |
| 4 | **La misma persona llega por dos caminos** (en el equipo de un líder y en la lista pegada). | La llave es el correo. Se queda con el **primer** origen y se informa "N ya estaban en el grupo". |
| 5 | **Quitar un líder.** ¿Qué pasa con su equipo? | Se quitan las personas que llegaron **solo** por ese líder, previa confirmación que dice cuántas son. Las que se agregaron también de otra forma se quedan. |
| 6 | **Listas pegadas en cualquier formato.** | Se extraen los correos con una expresión regular, sin importar separadores ni nombres alrededor. Máximo 1.000 por validación. |
| 7 | **Validar no es guardar.** El navegador podría enviar datos alterados. | Las vistas previas no guardan nada. Al guardar, el backend vuelve a resolver a cada persona contra el maestro y el directorio. |
| 8 | **Salir sin guardar** después de armar un grupo de 300 personas. | Guard de salida y aviso del navegador al cerrar la pestaña. |
| 9 | **Correos en la URL.** | Validar y traer equipos van por `POST`: las listas no quedan en la barra de direcciones ni en los registros del servidor. |

---

## 2. 🎨 Diseño

### Listado (`/grupos`)

Mismo diseño que **Módulo de Certificados** y el listado de cursos: título, tarjeta con buscador, tabla y paginación.

```text
┌───────────────────────────────────────────────────────────────────────┐
│ Grupos de usuarios                                                     │
│ Arma grupos con equipos de líderes, personas puntuales o listas        │
│ ┌───────────────────────────────────────────────────────────────────┐ │
│ │ Listado de grupos                                 [＋ Nuevo grupo] │ │
│ │ [🔍 Buscar por nombre o descripción              ]                 │ │
│ │ ┌───────────────────────────────────────────────────────────────┐ │ │
│ │ │ NOMBRE            INTEGRANTES          LÍDERES  ACTUALIZADO ACC.│ │ │
│ │ │ Operaciones Norte 128  (6 solo dir.)   3        24 sep 2026 [✎][🗑]│ │
│ │ │ Brigadistas        42                  0        20 sep 2026 [✎][🗑]│ │
│ │ └───────────────────────────────────────────────────────────────┘ │ │
│ │                     (‹)  Página 1 de 3  (›)                        │ │
│ └───────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### Constructor (`/grupos/nuevo` y `/grupos/:id/editar`)

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ← Grupos de usuarios                                                          │
│ Nuevo grupo                                         [Cancelar] [✔ Guardar grupo]│
├───────────────────────────────────────────────────┬──────────────────────────┤
│ ┌ Datos del grupo ──────────────────────────────┐ │ ┌ Resumen ─────────────┐ │
│ │ Nombre [Operaciones Norte__________]  17/120  │ │ │      128              │ │
│ │ Descripción [_________________________]       │ │ │   personas            │ │
│ └───────────────────────────────────────────────┘ │ │ ████████████████░░    │ │
│ ┌ Agregar personas ─────────────────────────────┐ │ │ 122 maestro · 6 solo  │ │
│ │ ( 🗂 Por líder )( 🔍 Buscar persona )( 📋 Pegar )│ │ │ directorio            │ │
│ │                                               │ │ │                       │ │
│ │ Correo del líder                              │ │ │ LÍDERES               │ │
│ │ [lider@empresa.com; otro@empresa.com     ]    │ │ │ (AP) Ana Pérez     ✕  │ │
│ │ (ana@…)(otro@…)   ◯ Todos los niveles         │ │ │      42 · directos    │ │
│ │ ◯ Incluir a los líderes     [Buscar equipos]  │ │ │ (JM) Juan Mora     ✕  │ │
│ │ ┌ ☑ Ana Pérez · 42 personas ──────────────┐   │ │ │      80 · todos       │ │
│ │ │ ☑ (LR) Luis Rojas   luis@…   Maestro     │   │ │ └───────────────────────┘ │
│ │ │ ☐ (MT) Marta Toro   Ya está              │   │ │ ⚠ 6 personas no están  │
│ │ └──────────────────────────────────────────┘   │ │   en el maestro        │
│ │                 41 seleccionadas [Agregar 41]  │ │                          │
│ └───────────────────────────────────────────────┘ │                          │
│ ┌ Integrantes (128) ────────────────────────────┐ │                          │
│ │ [🔍 Filtrar]  ( Todos 128 | Maestro 122 | Solo directorio 6 ) │           │
│ │ PERSONA             CORREO        FUENTE      ORIGEN              │        │
│ │ (LR) Luis Rojas     luis@…        Maestro     🗂 Equipo de Ana Pérez  ✕ │  │
│ │ (CP) Carla Paz      carla@…       Solo dir.   📋 Lista de correos     ✕ │  │
│ │                     [ Mostrar 100 más ]                              │    │
│ └───────────────────────────────────────────────┘                          │
└───────────────────────────────────────────────────┴──────────────────────────┘
```

En pantallas pequeñas el resumen pasa arriba, las pestañas se vuelven desplazables y la tabla de integrantes se convierte en tarjetas.

### Estados de cada pestaña

| Pestaña | Vacío | Cargando | Resultado | Error |
|---|---|---|---|---|
| Por líder | Campo de correo y casillas | Botón con spinner "Buscando equipos…" | Una tarjeta por líder con casillas; líderes no encontrados en un aviso | Alerta con el mensaje (ej. directorio no disponible) |
| Buscar persona | Campo de búsqueda | "Buscando…" en la lista | Opciones con su fuente; las que ya están, deshabilitadas | "No se pudo buscar" en la lista |
| Pegar correos | Área de texto con ejemplos de formatos | Botón con spinner "Validando…" | Tres indicadores: nuevos, ya en el grupo, no se pudieron agregar | Alerta con el mensaje |

### Movimiento

| Elemento | Qué hace |
|---|---|
| Cambio de pestaña | El panel entra con un fundido y sube 6 px. |
| Tarjetas de equipo | Entran en cascada, máximo 6 escalones. |
| Correos detectados | Aparecen como chips con un pequeño "pop". |
| Personas recién agregadas | Su fila se ilumina con el color del acento y se apaga en 2,5 s. |
| Barra del resumen | Cambia de proporción con una transición suave. |

Todo usa solo `transform`, `opacity` y el ancho de la barra, y se apaga con `prefers-reduced-motion`.

### Accesibilidad

- Pestañas con `role="tablist"`, `aria-selected` y navegación con flechas.
- Casilla "seleccionar todo" de cada equipo en estado **indeterminado** cuando hay selección parcial.
- Cada alta anuncia su resultado en una región `aria-live` ("Se agregaron 41 personas · 1 ya estaba").
- La fuente no se comunica solo con color: el distintivo siempre lleva texto.

---

## 3. 📁 Archivos

```text
src/app/shared/
├── utils/
│   ├── email-list.ts                            ⭐ extrae correos de cualquier texto pegado
│   └── feedback.ts                              toasts y confirmaciones (ver nota)
└── guards/
    └── unsaved-changes.guard.ts                 avisa antes de salir sin guardar

src/app/features/user-groups/
├── domain/
│   ├── user-group.model.ts
│   ├── member-origin.config.ts                  textos e íconos de origen y motivos
│   └── user-group.repository.ts                 ⭐ contrato de datos
├── infraestructure/
│   ├── user-group.dto.ts
│   ├── user-group.mapper.ts
│   ├── user-groups.service.ts                   implementa UserGroupRepository
│   └── user-groups.providers.ts
├── application/
│   ├── user-groups-list.facade.ts
│   └── user-group-builder.facade.ts             ⭐ integrantes, líderes y reglas de mezcla
└── presentation/
    ├── _user-groups-tokens.scss                 tokens de color y mixins compartidos
    ├── initials.ts
    ├── source-badge/                            distintivo Maestro / Solo directorio
    ├── user-groups-list-page/                   listado
    ├── user-group-builder-page/                 ⭐ constructor
    ├── manager-import/                          pestaña "Por líder"
    ├── person-search/                           pestaña "Buscar persona"
    ├── email-import/                            pestaña "Pegar correos"
    └── members-table/                           tabla de integrantes
```

> **`@shared/utils/feedback.ts`:** si la app ya tiene un servicio de alertas en `shared/services`, úsalo. Si no, mueve ahí `course-feedback.ts` de la guía de cursos (`notifySuccess`, `notifyError`, `confirmDanger`) para que las dos features usen el mismo. `ApiResponse`, `unwrap` y `toErrorMessage` salen de `@shared/utils/api-response`, también de esa guía.

---

## 4. Paso 1 — Shared

### `shared/utils/email-list.ts`

```ts
/**
 * Extrae los correos de cualquier texto pegado: una columna de Excel, destinatarios de Outlook
 * ("Ana Pérez <ana@empresa.com>; Juan <juan@empresa.com>"), un CSV o uno por línea.
 * No le importan los separadores ni los nombres alrededor.
 */
const EMAIL_PATTERN = /[a-z0-9._%+'-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}/gi;

export interface EmailExtraction {
  /** Únicos, en minúsculas, en el orden en que aparecieron. */
  readonly emails: readonly string[];
  /** Cuántos venían repetidos. */
  readonly duplicates: number;
}

export function extractEmails(text: string): EmailExtraction {
  const all = (text.match(EMAIL_PATTERN) ?? []).map((email) => email.toLowerCase());
  const unique = [...new Set(all)];
  return { emails: unique, duplicates: all.length - unique.length };
}
```

### `shared/guards/unsaved-changes.guard.ts`

```ts
import { CanDeactivateFn } from '@angular/router';
import { confirmDanger } from '@shared/utils/feedback';

export interface HasUnsavedChanges {
  hasUnsavedChanges(): boolean;
}

/** Reutilizable en cualquier página que implemente HasUnsavedChanges. */
export const unsavedChangesGuard: CanDeactivateFn<HasUnsavedChanges> = (component) =>
  !component.hasUnsavedChanges() ||
  confirmDanger('¿Salir sin guardar?', 'Los cambios que hiciste se perderán.', 'Salir sin guardar');
```

---

## 5. Paso 2 — Domain

### `domain/user-group.model.ts`

```ts
export type MemberAddedVia = 'MANAGER' | 'INDIVIDUAL' | 'BULK';
export type UnresolvedReason = 'INVALID' | 'NOT_FOUND' | 'DISABLED';

/** Una persona encontrada en el maestro, en el directorio o en ambos. */
export interface MemberCandidate {
  readonly email: string;
  readonly displayName: string;
  readonly jobTitle: string | null;
  /** Id en dbo.users. null = solo está en el directorio. */
  readonly userId: number | null;
  readonly entraObjectId: string | null;
}

export interface GroupMember extends MemberCandidate {
  readonly addedVia: MemberAddedVia;
  /** Líder por el que llegó, si addedVia es MANAGER. */
  readonly managerEmail: string | null;
}

export interface GroupManager {
  readonly email: string;
  readonly displayName: string;
  readonly includeAllLevels: boolean;
}

export interface UserGroupSummary {
  readonly id: number;
  readonly name: string;
  readonly description: string | null;
  readonly membersCount: number;
  readonly directoryOnlyCount: number;
  readonly managersCount: number;
  /** ISO 8601 */
  readonly updatedAt: string;
}

export interface UserGroupDetail {
  readonly id: number;
  readonly name: string;
  readonly description: string | null;
  readonly managers: readonly GroupManager[];
  readonly members: readonly GroupMember[];
}

/** Lo que se envía al guardar. El backend vuelve a resolver la identidad de cada persona. */
export interface UserGroupDraft {
  readonly name: string;
  readonly description: string | null;
  readonly managers: ReadonlyArray<{ readonly email: string; readonly includeAllLevels: boolean }>;
  readonly members: ReadonlyArray<{
    readonly email: string;
    readonly entraObjectId: string | null;
    readonly addedVia: MemberAddedVia;
    readonly managerEmail: string | null;
  }>;
}

export interface UnresolvedEmail {
  readonly email: string;
  readonly reason: UnresolvedReason;
}

export interface EmailResolution {
  readonly found: readonly MemberCandidate[];
  readonly unresolved: readonly UnresolvedEmail[];
}

export interface ManagerTeam {
  readonly manager: MemberCandidate;
  readonly members: readonly MemberCandidate[];
  /** true si el equipo superó el tope y se cortó. */
  readonly truncated: boolean;
}

export interface ManagerTeamsResult {
  readonly teams: readonly ManagerTeam[];
  readonly unresolved: readonly UnresolvedEmail[];
}

export interface UserGroupQuery {
  readonly search: string;
  readonly page: number;
  readonly pageSize: number;
}

export interface UserGroupPage {
  readonly items: readonly UserGroupSummary[];
  readonly total: number;
}

/** Deben coincidir con UserGroupConstants del backend. */
export const USER_GROUP_LIMITS = {
  name: 120,
  description: 500,
  membersPerGroup: 5000,
  managersPerSearch: 20,
  emailsPerValidation: 1000,
  searchMinLength: 2,
} as const;
```

### `domain/member-origin.config.ts`

```ts
import { MemberAddedVia, UnresolvedReason } from './user-group.model';

export const ADDED_VIA_CONFIG: Record<MemberAddedVia, { readonly label: string; readonly icon: string }> = {
  MANAGER: { label: 'Equipo de', icon: 'fa-sitemap' },
  INDIVIDUAL: { label: 'Agregado a mano', icon: 'fa-user-plus' },
  BULK: { label: 'Lista de correos', icon: 'fa-paste' },
};

export const UNRESOLVED_REASON_LABEL: Record<UnresolvedReason, string> = {
  INVALID: 'Formato de correo inválido',
  NOT_FOUND: 'No existe en el maestro ni en el directorio',
  DISABLED: 'Cuenta deshabilitada en el directorio',
};
```

### `domain/user-group.repository.ts`

```ts
import { Observable } from 'rxjs';
import {
  EmailResolution,
  ManagerTeamsResult,
  MemberCandidate,
  UserGroupDetail,
  UserGroupDraft,
  UserGroupPage,
  UserGroupQuery,
} from './user-group.model';

export abstract class UserGroupRepository {
  abstract list(query: UserGroupQuery): Observable<UserGroupPage>;
  abstract getById(id: number): Observable<UserGroupDetail>;
  abstract create(draft: UserGroupDraft): Observable<number>;
  abstract update(id: number, draft: UserGroupDraft): Observable<void>;
  abstract remove(id: number): Observable<void>;

  /** Vista previa: no guarda nada. */
  abstract resolveEmails(emails: readonly string[]): Observable<EmailResolution>;
  /** Vista previa: no guarda nada. */
  abstract getManagerTeams(managerEmails: readonly string[], includeAllLevels: boolean): Observable<ManagerTeamsResult>;
  abstract searchPeople(term: string): Observable<MemberCandidate[]>;
}
```

---

## 6. Paso 3 — Infrastructure

### `infraestructure/user-group.dto.ts`

```ts
export interface MemberCandidateDto {
  email: string;
  displayName: string;
  jobTitle: string | null;
  userId: number | null;
  entraObjectId: string | null;
  inDoccb: boolean;
}

export interface GroupMemberDto extends MemberCandidateDto {
  addedVia: string;
  managerEmail: string | null;
}

export interface GroupManagerDto {
  email: string;
  displayName: string;
  includeAllLevels: boolean;
}

export interface UserGroupListItemDto {
  groupId: number;
  name: string;
  description: string | null;
  membersCount: number;
  directoryOnlyCount: number;
  managersCount: number;
  updatedDate: string;
}

export interface UserGroupPageDto {
  items: UserGroupListItemDto[];
  totalCount: number;
}

export interface UserGroupDetailDto {
  groupId: number;
  name: string;
  description: string | null;
  managers: GroupManagerDto[];
  members: GroupMemberDto[];
}

export interface SaveUserGroupRequestDto {
  name: string;
  description: string | null;
  managers: { email: string; includeAllLevels: boolean }[];
  members: { email: string; entraObjectId: string | null; addedVia: string; managerEmail: string | null }[];
}

export interface UnresolvedEmailDto {
  email: string;
  reason: string;
}

export interface EmailResolutionDto {
  found: MemberCandidateDto[];
  unresolved: UnresolvedEmailDto[];
}

export interface ManagerTeamDto {
  manager: MemberCandidateDto;
  members: MemberCandidateDto[];
  truncated: boolean;
}

export interface ManagerTeamsResultDto {
  teams: ManagerTeamDto[];
  unresolved: UnresolvedEmailDto[];
}
```

### `infraestructure/user-group.mapper.ts`

```ts
import {
  EmailResolution,
  GroupMember,
  ManagerTeamsResult,
  MemberAddedVia,
  MemberCandidate,
  UnresolvedEmail,
  UnresolvedReason,
  UserGroupDetail,
  UserGroupDraft,
  UserGroupPage,
} from '../domain/user-group.model';
import {
  EmailResolutionDto,
  GroupMemberDto,
  ManagerTeamsResultDto,
  MemberCandidateDto,
  SaveUserGroupRequestDto,
  UnresolvedEmailDto,
  UserGroupDetailDto,
  UserGroupPageDto,
} from './user-group.dto';

const ADDED_VIA: readonly MemberAddedVia[] = ['MANAGER', 'INDIVIDUAL', 'BULK'];
const REASONS: readonly UnresolvedReason[] = ['INVALID', 'NOT_FOUND', 'DISABLED'];

export function toCandidate(dto: MemberCandidateDto): MemberCandidate {
  return {
    email: dto.email.toLowerCase(),
    displayName: dto.displayName || dto.email,
    jobTitle: dto.jobTitle ?? null,
    userId: dto.userId ?? null,
    entraObjectId: dto.entraObjectId ?? null,
  };
}

export function toMember(dto: GroupMemberDto): GroupMember {
  return {
    ...toCandidate(dto),
    addedVia: ADDED_VIA.find((via) => via === dto.addedVia?.toUpperCase()) ?? 'INDIVIDUAL',
    managerEmail: dto.managerEmail?.toLowerCase() ?? null,
  };
}

export function toPage(dto: UserGroupPageDto): UserGroupPage {
  return {
    total: dto.totalCount,
    items: dto.items.map((item) => ({
      id: item.groupId,
      name: item.name,
      description: item.description,
      membersCount: item.membersCount,
      directoryOnlyCount: item.directoryOnlyCount,
      managersCount: item.managersCount,
      updatedAt: item.updatedDate,
    })),
  };
}

export function toDetail(dto: UserGroupDetailDto): UserGroupDetail {
  return {
    id: dto.groupId,
    name: dto.name,
    description: dto.description,
    managers: dto.managers.map((m) => ({ ...m, email: m.email.toLowerCase() })),
    members: dto.members.map(toMember),
  };
}

export function toResolution(dto: EmailResolutionDto): EmailResolution {
  return { found: dto.found.map(toCandidate), unresolved: dto.unresolved.map(toUnresolved) };
}

export function toTeams(dto: ManagerTeamsResultDto): ManagerTeamsResult {
  return {
    teams: dto.teams.map((team) => ({
      manager: toCandidate(team.manager),
      members: team.members.map(toCandidate),
      truncated: team.truncated,
    })),
    unresolved: dto.unresolved.map(toUnresolved),
  };
}

export function toSaveRequest(draft: UserGroupDraft): SaveUserGroupRequestDto {
  return {
    name: draft.name,
    description: draft.description,
    managers: draft.managers.map((m) => ({ ...m })),
    members: draft.members.map((m) => ({ ...m })),
  };
}

function toUnresolved(dto: UnresolvedEmailDto): UnresolvedEmail {
  return { email: dto.email, reason: REASONS.find((reason) => reason === dto.reason) ?? 'NOT_FOUND' };
}
```

### `infraestructure/user-groups.service.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, unwrap } from '@shared/utils/api-response';
import { UserGroupRepository } from '../domain/user-group.repository';
import {
  EmailResolution,
  ManagerTeamsResult,
  MemberCandidate,
  UserGroupDetail,
  UserGroupDraft,
  UserGroupPage,
  UserGroupQuery,
} from '../domain/user-group.model';
import {
  EmailResolutionDto,
  ManagerTeamsResultDto,
  MemberCandidateDto,
  UserGroupDetailDto,
  UserGroupPageDto,
} from './user-group.dto';
import { toCandidate, toDetail, toPage, toResolution, toSaveRequest, toTeams } from './user-group.mapper';

@Injectable({ providedIn: 'root' })
export class UserGroupsService implements UserGroupRepository {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/api/user-groups`;

  list(query: UserGroupQuery): Observable<UserGroupPage> {
    let params = new HttpParams().set('page', query.page).set('pageSize', query.pageSize);
    if (query.search) params = params.set('search', query.search);

    return this.http.get<ApiResponse<UserGroupPageDto>>(this.baseUrl, { params }).pipe(map(unwrap), map(toPage));
  }

  getById(id: number): Observable<UserGroupDetail> {
    return this.http.get<ApiResponse<UserGroupDetailDto>>(`${this.baseUrl}/${id}`).pipe(map(unwrap), map(toDetail));
  }

  create(draft: UserGroupDraft): Observable<number> {
    return this.http.post<ApiResponse<number>>(this.baseUrl, toSaveRequest(draft)).pipe(map(unwrap));
  }

  update(id: number, draft: UserGroupDraft): Observable<void> {
    return this.http
      .put<ApiResponse<unknown>>(`${this.baseUrl}/${id}`, toSaveRequest(draft))
      .pipe(map(unwrap), map(() => undefined));
  }

  remove(id: number): Observable<void> {
    return this.http.delete<ApiResponse<unknown>>(`${this.baseUrl}/${id}`).pipe(map(unwrap), map(() => undefined));
  }

  resolveEmails(emails: readonly string[]): Observable<EmailResolution> {
    return this.http
      .post<ApiResponse<EmailResolutionDto>>(`${this.baseUrl}/resolve-emails`, { emails })
      .pipe(map(unwrap), map(toResolution));
  }

  getManagerTeams(managerEmails: readonly string[], includeAllLevels: boolean): Observable<ManagerTeamsResult> {
    return this.http
      .post<ApiResponse<ManagerTeamsResultDto>>(`${this.baseUrl}/manager-teams`, { managerEmails, includeAllLevels })
      .pipe(map(unwrap), map(toTeams));
  }

  searchPeople(term: string): Observable<MemberCandidate[]> {
    const params = new HttpParams().set('q', term);
    return this.http
      .get<ApiResponse<MemberCandidateDto[]>>(`${this.baseUrl}/people`, { params })
      .pipe(map(unwrap), map((people) => people.map(toCandidate)));
  }
}
```

### `infraestructure/user-groups.providers.ts`

```ts
import { Provider } from '@angular/core';
import { UserGroupRepository } from '../domain/user-group.repository';
import { UserGroupsService } from './user-groups.service';

export const USER_GROUPS_INFRASTRUCTURE_PROVIDERS: Provider[] = [
  { provide: UserGroupRepository, useExisting: UserGroupsService },
];
```

---

## 7. Paso 4 — Application

### `application/user-groups-list.facade.ts`

```ts
import { Injectable, computed, inject, signal } from '@angular/core';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { Subject, catchError, firstValueFrom, map, merge, of, switchMap, tap } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { UserGroupRepository } from '../domain/user-group.repository';
import { UserGroupPage, UserGroupQuery, UserGroupSummary } from '../domain/user-group.model';

export type LoadStatus = 'loading' | 'ready' | 'error';

type LoadResult = { readonly page: UserGroupPage } | { readonly error: string };

@Injectable()
export class UserGroupsListFacade {
  private readonly repository = inject(UserGroupRepository);
  private readonly reload$ = new Subject<void>();

  private readonly _query = signal<UserGroupQuery>({ search: '', page: 1, pageSize: 10 });
  private readonly _status = signal<LoadStatus>('loading');
  private readonly _error = signal<string | null>(null);
  private readonly _items = signal<readonly UserGroupSummary[]>([]);
  private readonly _total = signal(0);

  readonly query = this._query.asReadonly();
  readonly status = this._status.asReadonly();
  readonly error = this._error.asReadonly();
  readonly items = this._items.asReadonly();
  readonly total = this._total.asReadonly();

  readonly totalPages = computed(() => Math.max(1, Math.ceil(this._total() / this._query().pageSize)));

  constructor() {
    merge(toObservable(this._query), this.reload$.pipe(map(() => this._query())))
      .pipe(
        tap(() => {
          this._status.set('loading');
          this._error.set(null);
        }),
        switchMap((query) =>
          this.repository.list(query).pipe(
            map((page): LoadResult => ({ page })),
            catchError((e) => of<LoadResult>({ error: toErrorMessage(e, 'No se pudieron cargar los grupos.') })),
          ),
        ),
        takeUntilDestroyed(),
      )
      .subscribe((result) => {
        if ('error' in result) {
          this._error.set(result.error);
          this._status.set('error');
          return;
        }
        this._items.set(result.page.items);
        this._total.set(result.page.total);
        this._status.set('ready');
      });
  }

  search(term: string): void {
    this._query.update((q) => ({ ...q, search: term, page: 1 }));
  }

  goToPage(page: number): void {
    const target = Math.min(Math.max(1, page), this.totalPages());
    if (target !== this._query().page) this._query.update((q) => ({ ...q, page: target }));
  }

  reload(): void {
    this.reload$.next();
  }

  async remove(group: UserGroupSummary): Promise<void> {
    await firstValueFrom(this.repository.remove(group.id));

    const { page } = this._query();
    if (this._items().length === 1 && page > 1) this.goToPage(page - 1);
    else this.reload();
  }
}
```

### `application/user-group-builder.facade.ts` — ⭐ las reglas del constructor

```ts
import { Injectable, OnDestroy, computed, inject, signal } from '@angular/core';
import { Observable, firstValueFrom } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { UserGroupRepository } from '../domain/user-group.repository';
import {
  EmailResolution,
  GroupManager,
  GroupMember,
  ManagerTeam,
  ManagerTeamsResult,
  MemberAddedVia,
  MemberCandidate,
  USER_GROUP_LIMITS,
  UserGroupDraft,
} from '../domain/user-group.model';

export type BuilderStatus = 'loading' | 'ready' | 'error';

export interface AddResult {
  readonly added: number;
  readonly alreadyInGroup: number;
}

const RECENT_HIGHLIGHT_MS = 2500;

@Injectable()
export class UserGroupBuilderFacade implements OnDestroy {
  private readonly repository = inject(UserGroupRepository);

  // ── Estado: solo se escribe aquí dentro ─────────────────────────
  private readonly _groupId = signal<number | null>(null);
  private readonly _name = signal('');
  private readonly _description = signal('');
  /** Llave = correo en minúsculas. */
  private readonly _managers = signal<ReadonlyMap<string, GroupManager>>(new Map());
  private readonly _members = signal<ReadonlyMap<string, GroupMember>>(new Map());
  private readonly _recentlyAdded = signal<ReadonlySet<string>>(new Set());
  private readonly _status = signal<BuilderStatus>('ready');
  private readonly _loadError = signal<string | null>(null);
  private readonly _saving = signal(false);
  private readonly _dirty = signal(false);

  // ── Hacia afuera, solo lectura ──────────────────────────────────
  readonly name = this._name.asReadonly();
  readonly description = this._description.asReadonly();
  readonly recentlyAdded = this._recentlyAdded.asReadonly();
  readonly status = this._status.asReadonly();
  readonly loadError = this._loadError.asReadonly();
  readonly saving = this._saving.asReadonly();
  readonly hasUnsavedChanges = this._dirty.asReadonly();

  readonly isEdit = computed(() => this._groupId() !== null);
  readonly memberEmails = computed<ReadonlySet<string>>(() => new Set(this._members().keys()));
  readonly managers = computed(() => [...this._managers().values()]);
  readonly members = computed(() =>
    [...this._members().values()].sort((a, b) => a.displayName.localeCompare(b.displayName, 'es')),
  );

  readonly summary = computed(() => {
    const members = this.members();
    const inDoccb = members.filter((m) => m.userId !== null).length;
    return {
      total: members.length,
      inDoccb,
      directoryOnly: members.length - inDoccb,
      managers: this._managers().size,
    };
  });

  /** Cuántas personas llegaron por cada líder (para el resumen y la confirmación al quitarlo). */
  readonly countByManager = computed(() => {
    const counts = new Map<string, number>();
    for (const member of this._members().values()) {
      if (member.addedVia === 'MANAGER' && member.managerEmail) {
        counts.set(member.managerEmail, (counts.get(member.managerEmail) ?? 0) + 1);
      }
    }
    return counts as ReadonlyMap<string, number>;
  });

  // ── Validación ──────────────────────────────────────────────────
  readonly nameError = computed(() => {
    const name = this._name().trim();
    if (!name) return 'Escribe el nombre del grupo.';
    if (name.length > USER_GROUP_LIMITS.name) return `Máximo ${USER_GROUP_LIMITS.name} caracteres.`;
    return null;
  });

  readonly descriptionError = computed(() =>
    this._description().trim().length > USER_GROUP_LIMITS.description
      ? `Máximo ${USER_GROUP_LIMITS.description} caracteres.`
      : null,
  );

  readonly membersError = computed(() => {
    const total = this._members().size;
    if (total === 0) return 'Agrega al menos una persona al grupo.';
    if (total > USER_GROUP_LIMITS.membersPerGroup) {
      return `Un grupo puede tener hasta ${USER_GROUP_LIMITS.membersPerGroup} personas.`;
    }
    return null;
  });

  readonly isValid = computed(() => !this.nameError() && !this.descriptionError() && !this.membersError());

  private recentTimer?: ReturnType<typeof setTimeout>;

  // ── Carga ───────────────────────────────────────────────────────
  async load(id: number | null): Promise<void> {
    this.reset();
    if (id === null) return;

    this._status.set('loading');
    try {
      const detail = await firstValueFrom(this.repository.getById(id));
      this._groupId.set(detail.id);
      this._name.set(detail.name);
      this._description.set(detail.description ?? '');
      this._managers.set(new Map(detail.managers.map((m) => [m.email, m])));
      this._members.set(new Map(detail.members.map((m) => [m.email, m])));
      this._status.set('ready');
    } catch (error) {
      this._loadError.set(toErrorMessage(error, 'No se pudo cargar el grupo.'));
      this._status.set('error');
    }
  }

  // ── Datos del grupo ─────────────────────────────────────────────
  setName(value: string): void {
    this._name.set(value);
    this._dirty.set(true);
  }

  setDescription(value: string): void {
    this._description.set(value);
    this._dirty.set(true);
  }

  // ── Integrantes ─────────────────────────────────────────────────
  /**
   * Regla de mezcla: el correo es la llave. Si la persona ya estaba, conserva su primer origen
   * y solo se completa lo que le faltaba (userId, entraObjectId, cargo).
   */
  addCandidates(
    candidates: readonly MemberCandidate[],
    via: MemberAddedVia,
    managerEmail: string | null = null,
  ): AddResult {
    const next = new Map(this._members());
    const addedEmails: string[] = [];
    let alreadyInGroup = 0;

    for (const candidate of candidates) {
      const existing = next.get(candidate.email);

      if (existing) {
        alreadyInGroup++;
        next.set(candidate.email, {
          ...existing,
          userId: existing.userId ?? candidate.userId,
          entraObjectId: existing.entraObjectId ?? candidate.entraObjectId,
          jobTitle: existing.jobTitle ?? candidate.jobTitle,
        });
        continue;
      }

      next.set(candidate.email, {
        ...candidate,
        addedVia: via,
        managerEmail: via === 'MANAGER' ? managerEmail : null,
      });
      addedEmails.push(candidate.email);
    }

    this._members.set(next);

    if (addedEmails.length > 0) {
      this._dirty.set(true);
      this.highlight(addedEmails);
    }

    return { added: addedEmails.length, alreadyInGroup };
  }

  addManagerTeam(team: ManagerTeam, selected: readonly MemberCandidate[], includeAllLevels: boolean): AddResult {
    const manager: GroupManager = {
      email: team.manager.email,
      displayName: team.manager.displayName,
      includeAllLevels,
    };
    this._managers.update((current) => new Map(current).set(manager.email, manager));
    this._dirty.set(true);

    return this.addCandidates(selected, 'MANAGER', manager.email);
  }

  removeMember(email: string): void {
    const next = new Map(this._members());
    if (next.delete(email)) {
      this._members.set(next);
      this._dirty.set(true);
    }
  }

  /** Quita al líder y a las personas que llegaron SOLO por su equipo. */
  removeManager(email: string): void {
    const managers = new Map(this._managers());
    managers.delete(email);
    this._managers.set(managers);

    const members = new Map(this._members());
    for (const [key, member] of members) {
      if (member.addedVia === 'MANAGER' && member.managerEmail === email) members.delete(key);
    }
    this._members.set(members);
    this._dirty.set(true);
  }

  // ── Consultas de apoyo (no guardan nada) ────────────────────────
  resolveEmails(emails: readonly string[]): Promise<EmailResolution> {
    return firstValueFrom(this.repository.resolveEmails(emails));
  }

  getManagerTeams(emails: readonly string[], includeAllLevels: boolean): Promise<ManagerTeamsResult> {
    return firstValueFrom(this.repository.getManagerTeams(emails, includeAllLevels));
  }

  searchPeople(term: string): Observable<MemberCandidate[]> {
    return this.repository.searchPeople(term);
  }

  // ── Guardar ─────────────────────────────────────────────────────
  async save(): Promise<number> {
    this._saving.set(true);
    try {
      const draft = this.toDraft();
      const currentId = this._groupId();

      let savedId: number;
      if (currentId === null) {
        savedId = await firstValueFrom(this.repository.create(draft));
      } else {
        await firstValueFrom(this.repository.update(currentId, draft));
        savedId = currentId;
      }

      this._groupId.set(savedId);
      this._dirty.set(false);
      return savedId;
    } finally {
      this._saving.set(false);
    }
  }

  ngOnDestroy(): void {
    clearTimeout(this.recentTimer);
  }

  // ── Privados ────────────────────────────────────────────────────
  private toDraft(): UserGroupDraft {
    return {
      name: this._name().trim(),
      description: this._description().trim() || null,
      managers: this.managers().map((m) => ({ email: m.email, includeAllLevels: m.includeAllLevels })),
      members: this.members().map((m) => ({
        email: m.email,
        entraObjectId: m.entraObjectId,
        addedVia: m.addedVia,
        managerEmail: m.managerEmail,
      })),
    };
  }

  private highlight(emails: readonly string[]): void {
    this._recentlyAdded.set(new Set(emails));
    clearTimeout(this.recentTimer);
    this.recentTimer = setTimeout(() => this._recentlyAdded.set(new Set()), RECENT_HIGHLIGHT_MS);
  }

  private reset(): void {
    this._groupId.set(null);
    this._name.set('');
    this._description.set('');
    this._managers.set(new Map());
    this._members.set(new Map());
    this._loadError.set(null);
    this._status.set('ready');
    this._dirty.set(false);
  }
}
```

---

## 8. Paso 5 — Estilos compartidos de la feature

### `presentation/_user-groups-tokens.scss`

**El único lugar donde tocas colores.** Reemplaza cada `var(--bs-…)` por tu variable.

```scss
@mixin user-groups-tokens {
  // ══ Colores — reemplaza por tus variables ═════════════════════════
  --ug-accent: var(--bs-primary);          // botones, pestaña activa, encabezado de tablas
  --ug-on-accent: #fff;
  --ug-doccb: var(--bs-success);           // integrante que está en el maestro
  --ug-directory: var(--bs-warning);       // integrante que solo está en el directorio
  --ug-danger: var(--bs-danger);
  --ug-surface: var(--bs-body-bg);
  --ug-surface-alt: var(--bs-tertiary-bg);
  --ug-border: var(--bs-border-color-translucent);
  --ug-text: var(--bs-body-color);
  --ug-muted: var(--bs-secondary-color);

  // ══ Forma y movimiento ════════════════════════════════════════════
  --ug-radius: 1rem;
  --ug-radius-sm: 0.625rem;
  --ug-shadow: 0 1px 2px rgb(0 0 0 / 0.04), 0 4px 16px rgb(0 0 0 / 0.06);
  --ug-ease-spring: cubic-bezier(0.2, 0.9, 0.3, 1.15);
  --ug-ease-out: cubic-bezier(0.2, 0.8, 0.2, 1);
}

/** Tarjeta blanca de las secciones. */
@mixin card {
  padding: 1.25rem;
  border: 1px solid var(--ug-border);
  border-radius: var(--ug-radius);
  background: var(--ug-surface);
  box-shadow: var(--ug-shadow);
}

/** Círculo con iniciales. */
@mixin avatar($size: 2rem) {
  display: inline-grid;
  flex: 0 0 auto;
  place-items: center;
  width: $size;
  height: $size;
  border-radius: 50%;
  background: color-mix(in srgb, var(--ug-accent) 14%, var(--ug-surface));
  color: color-mix(in srgb, var(--ug-accent) 80%, var(--ug-text));
  font-size: calc(#{$size} * 0.36);
  font-weight: 700;
}
```

### `presentation/initials.ts`

```ts
export function initials(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0])
    .join('')
    .toUpperCase();
}
```

### `presentation/source-badge/source-badge.component.ts`

Tan pequeño que la plantilla y los estilos van en línea.

```ts
import { ChangeDetectionStrategy, Component, input } from '@angular/core';

@Component({
  selector: 'app-source-badge',
  template: `
    @if (inDoccb()) {
      <span class="badge-source" data-source="doccb">
        <i class="fa-solid fa-id-card" aria-hidden="true"></i> Maestro
      </span>
    } @else {
      <span class="badge-source" data-source="directory" title="Existe en Microsoft, pero no en el maestro de usuarios">
        <i class="fa-brands fa-microsoft" aria-hidden="true"></i> Solo directorio
      </span>
    }
  `,
  styles: `
    .badge-source {
      --tone: var(--ug-doccb);
      display: inline-flex;
      align-items: center;
      gap: 0.3rem;
      padding: 0.15rem 0.55rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--tone) 14%, transparent);
      color: color-mix(in srgb, var(--tone) 70%, var(--ug-text));
      font-size: 0.7rem;
      font-weight: 600;
      white-space: nowrap;

      &[data-source='directory'] {
        --tone: var(--ug-directory);
      }
    }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SourceBadgeComponent {
  readonly inDoccb = input.required<boolean>();
}
```

---

## 9. Paso 6 — Pestaña "Por líder"

### `presentation/manager-import/manager-import.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, output, signal } from '@angular/core';
import { extractEmails } from '@shared/utils/email-list';
import { toErrorMessage } from '@shared/utils/api-response';
import { AddResult, UserGroupBuilderFacade } from '../../application/user-group-builder.facade';
import { ManagerTeam, ManagerTeamsResult, MemberCandidate, USER_GROUP_LIMITS } from '../../domain/user-group.model';
import { UNRESOLVED_REASON_LABEL } from '../../domain/member-origin.config';
import { SourceBadgeComponent } from '../source-badge/source-badge.component';
import { initials } from '../initials';

type TeamSelection = 'all' | 'some' | 'none';

@Component({
  selector: 'app-manager-import',
  imports: [SourceBadgeComponent],
  templateUrl: './manager-import.component.html',
  styleUrl: './manager-import.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ManagerImportComponent {
  private readonly facade = inject(UserGroupBuilderFacade);

  readonly added = output<AddResult>();

  readonly limit = USER_GROUP_LIMITS.managersPerSearch;
  readonly reasonLabel = UNRESOLVED_REASON_LABEL;
  readonly initials = initials;

  readonly raw = signal('');
  readonly includeAllLevels = signal(false);
  readonly includeManagers = signal(false);
  readonly loading = signal(false);
  readonly error = signal<string | null>(null);
  readonly result = signal<ManagerTeamsResult | null>(null);
  /** Correos seleccionados de todos los equipos. */
  readonly selected = signal<ReadonlySet<string>>(new Set());

  readonly detected = computed(() => extractEmails(this.raw()).emails);
  readonly tooMany = computed(() => this.detected().length > this.limit);
  readonly selectedCount = computed(() => this.selected().size);

  async search(): Promise<void> {
    if (!this.detected().length || this.tooMany() || this.loading()) return;

    this.loading.set(true);
    this.error.set(null);
    this.result.set(null);

    try {
      const result = await this.facade.getManagerTeams(this.detected(), this.includeAllLevels());
      this.result.set(result);

      // Todos preseleccionados, menos los que ya están en el grupo.
      this.selected.set(
        new Set(result.teams.flatMap((team) => team.members.map((m) => m.email)).filter((e) => !this.inGroup(e))),
      );
    } catch (e) {
      this.error.set(toErrorMessage(e, 'No se pudieron traer los equipos.'));
    } finally {
      this.loading.set(false);
    }
  }

  inGroup(email: string): boolean {
    return this.facade.memberEmails().has(email);
  }

  isSelected(email: string): boolean {
    return this.selected().has(email);
  }

  toggle(email: string): void {
    this.selected.update((current) => {
      const next = new Set(current);
      if (!next.delete(email)) next.add(email);
      return next;
    });
  }

  teamSelection(team: ManagerTeam): TeamSelection {
    const selectable = team.members.filter((m) => !this.inGroup(m.email));
    const picked = selectable.filter((m) => this.isSelected(m.email)).length;
    if (picked === 0) return 'none';
    return picked === selectable.length ? 'all' : 'some';
  }

  toggleTeam(team: ManagerTeam, checked: boolean): void {
    this.selected.update((current) => {
      const next = new Set(current);
      for (const member of team.members) {
        if (this.inGroup(member.email)) continue;
        if (checked) next.add(member.email);
        else next.delete(member.email);
      }
      return next;
    });
  }

  add(): void {
    const result = this.result();
    if (!result) return;

    let total: AddResult = { added: 0, alreadyInGroup: 0 };

    for (const team of result.teams) {
      const picked: MemberCandidate[] = team.members.filter((m) => this.isSelected(m.email));
      if (this.includeManagers()) picked.unshift(team.manager);
      if (!picked.length) continue;

      const partial = this.facade.addManagerTeam(team, picked, this.includeAllLevels());
      total = { added: total.added + partial.added, alreadyInGroup: total.alreadyInGroup + partial.alreadyInGroup };
    }

    this.added.emit(total);
    this.raw.set('');
    this.result.set(null);
    this.selected.set(new Set());
  }
}
```

### `manager-import.component.html`

```html
<div class="mi">
  <label for="manager-emails" class="form-label fw-semibold">Correo del líder</label>
  <textarea
    id="manager-emails"
    class="form-control"
    rows="2"
    placeholder="lider@empresa.com — puedes pegar varios, separados por coma, punto y coma o en líneas"
    [value]="raw()"
    (input)="raw.set($any($event.target).value)"></textarea>

  @if (detected().length) {
    <div class="mi__chips" aria-label="Líderes detectados">
      @for (email of detected(); track email) {
        <span class="mi__chip">{{ email }}</span>
      }
    </div>
  }

  @if (tooMany()) {
    <div class="form-text text-danger">Puedes consultar hasta {{ limit }} líderes a la vez.</div>
  }

  <div class="mi__options">
    <div class="form-check form-switch">
      <input
        class="form-check-input"
        type="checkbox"
        role="switch"
        id="all-levels"
        [checked]="includeAllLevels()"
        (change)="includeAllLevels.set($any($event.target).checked)" />
      <label class="form-check-label" for="all-levels">
        Todos los niveles
        <span class="form-text d-block mt-0">También los equipos de sus colaboradores.</span>
      </label>
    </div>

    <div class="form-check form-switch">
      <input
        class="form-check-input"
        type="checkbox"
        role="switch"
        id="include-managers"
        [checked]="includeManagers()"
        (change)="includeManagers.set($any($event.target).checked)" />
      <label class="form-check-label" for="include-managers">Incluir a los líderes</label>
    </div>

    <button
      type="button"
      class="btn btn-accent ms-auto"
      [disabled]="!detected().length || tooMany() || loading()"
      (click)="search()">
      @if (loading()) {
        <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Buscando equipos…
      } @else {
        <i class="fa-solid fa-sitemap me-1" aria-hidden="true"></i> Buscar equipos
      }
    </button>
  </div>

  @if (error(); as message) {
    <div class="alert alert-danger mt-3 mb-0" role="alert">{{ message }}</div>
  }

  @if (result(); as result) {
    @if (result.unresolved.length) {
      <div class="alert alert-warning mt-3 mb-0" role="alert">
        <strong>No se encontraron estos líderes:</strong>
        <ul class="mb-0 mt-1 small">
          @for (item of result.unresolved; track item.email) {
            <li>{{ item.email }} — {{ reasonLabel[item.reason] }}</li>
          }
        </ul>
      </div>
    }

    <div class="mi__teams">
      @for (team of result.teams; track team.manager.email; let i = $index) {
        <article class="team" [style.--i]="i">
          <header class="team__head">
            <input
              class="form-check-input"
              type="checkbox"
              [id]="'team-' + i"
              [checked]="teamSelection(team) === 'all'"
              [indeterminate]="teamSelection(team) === 'some'"
              [disabled]="!team.members.length"
              (change)="toggleTeam(team, $any($event.target).checked)" />
            <span class="team__avatar" aria-hidden="true">{{ initials(team.manager.displayName) }}</span>
            <label class="team__title" [for]="'team-' + i">
              <strong>{{ team.manager.displayName }}</strong>
              <small>{{ team.manager.email }}</small>
            </label>
            <span class="team__count">
              {{ team.members.length }} {{ team.members.length === 1 ? 'persona' : 'personas' }}
            </span>
          </header>

          @if (team.truncated) {
            <div class="alert alert-warning py-2 small mb-2">
              El equipo es muy grande y se cortó en {{ team.members.length }} personas. Revisa si de verdad necesitas todos los niveles.
            </div>
          }

          @if (!team.members.length) {
            <p class="text-body-secondary small mb-0 px-2 pb-2">
              Este líder no tiene colaboradores registrados en el directorio.
            </p>
          } @else {
            <ul class="team__list">
              @for (member of team.members; track member.email) {
                <li>
                  <label class="member-row" [class.is-disabled]="inGroup(member.email)">
                    <input
                      class="form-check-input"
                      type="checkbox"
                      [checked]="isSelected(member.email)"
                      [disabled]="inGroup(member.email)"
                      (change)="toggle(member.email)" />
                    <span class="member-row__avatar" aria-hidden="true">{{ initials(member.displayName) }}</span>
                    <span class="member-row__text">
                      <strong>{{ member.displayName }}</strong>
                      <small>{{ member.email }}@if (member.jobTitle) { · {{ member.jobTitle }} }</small>
                    </span>
                    @if (inGroup(member.email)) {
                      <span class="member-row__already">Ya está</span>
                    } @else {
                      <app-source-badge [inDoccb]="member.userId !== null" />
                    }
                  </label>
                </li>
              }
            </ul>
          }
        </article>
      }
    </div>

    @if (result.teams.length) {
      <footer class="mi__footer">
        <span>
          <strong>{{ selectedCount() }}</strong> {{ selectedCount() === 1 ? 'seleccionada' : 'seleccionadas' }}
          @if (includeManagers()) { + {{ result.teams.length }} líderes }
        </span>
        <button type="button" class="btn btn-accent" [disabled]="!selectedCount() && !includeManagers()" (click)="add()">
          <i class="fa-solid fa-user-plus me-1" aria-hidden="true"></i> Agregar al grupo
        </button>
      </footer>
    }
  }
</div>
```

### `manager-import.component.scss`

```scss
@use '../user-groups-tokens' as ug;

.mi__chips {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin-top: 0.5rem;
}

.mi__chip {
  padding: 0.15rem 0.6rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--ug-accent) 12%, transparent);
  color: color-mix(in srgb, var(--ug-accent) 80%, var(--ug-text));
  font-size: 0.8rem;
  animation: ug-pop 0.25s var(--ug-ease-spring) both;
}

.mi__options {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 0.75rem 1.5rem;
  margin-top: 1rem;

  // Interruptores con contraste: apagados, el riel de Bootstrap casi no se ve sobre fondo blanco
  // y queda solo el punto gris.
  .form-switch .form-check-input {
    width: 2.25em;
    height: 1.25em;
    border-color: var(--ug-muted);
    cursor: pointer;

    &:checked {
      border-color: var(--ug-accent);
      background-color: var(--ug-accent);
    }

    &:focus-visible {
      box-shadow: 0 0 0 0.2rem color-mix(in srgb, var(--ug-accent) 30%, transparent);
    }
  }
}

.mi__teams {
  display: grid;
  gap: 0.75rem;
  margin-top: 1rem;
}

.team {
  border: 1px solid var(--ug-border);
  border-radius: var(--ug-radius-sm);
  background: var(--ug-surface);
  animation: ug-rise 0.35s var(--ug-ease-out) both;
  animation-delay: calc(min(var(--i, 0), 6) * 60ms);
}

.team__head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--ug-border);
}

.team__avatar {
  @include ug.avatar(2.25rem);
}

.team__title {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-width: 0;
  cursor: pointer;

  small {
    color: var(--ug-muted);
  }
}

.team__count {
  color: var(--ug-muted);
  font-size: 0.85rem;
  white-space: nowrap;
}

.team__list {
  max-height: 18rem;
  margin: 0;
  padding: 0.375rem;
  overflow-y: auto;
  list-style: none;
}

.member-row {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.45rem 0.625rem;
  border-radius: 0.5rem;
  cursor: pointer;
  transition: background-color 0.15s ease;

  &:hover {
    background: var(--ug-surface-alt);
  }

  &.is-disabled {
    cursor: default;
    opacity: 0.6;
  }
}

.member-row__avatar {
  @include ug.avatar(1.75rem);
}

.member-row__text {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-width: 0;

  strong {
    font-size: 0.875rem;
    font-weight: 600;
  }

  small {
    overflow: hidden;
    color: var(--ug-muted);
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}

.member-row__already {
  color: var(--ug-muted);
  font-size: 0.75rem;
  font-style: italic;
}

.mi__footer {
  position: sticky;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  margin-top: 1rem;
  padding: 0.75rem 1rem;
  border: 1px solid var(--ug-border);
  border-radius: var(--ug-radius-sm);
  background: color-mix(in srgb, var(--ug-surface) 92%, transparent);
  backdrop-filter: blur(8px);
}

@keyframes ug-pop {
  from {
    opacity: 0;
    transform: scale(0.7);
  }
}

@keyframes ug-rise {
  from {
    opacity: 0;
    transform: translateY(8px);
  }
}

@media (prefers-reduced-motion: reduce) {
  .mi__chip,
  .team {
    animation: none;
  }
}
```

---

## 10. Paso 7 — Pestaña "Buscar persona"

### `presentation/person-search/person-search.component.ts`

```ts
import { ChangeDetectionStrategy, Component, ElementRef, computed, inject, output, signal, viewChild } from '@angular/core';
import { toObservable, toSignal } from '@angular/core/rxjs-interop';
import { catchError, debounceTime, distinctUntilChanged, map, of, switchMap, tap } from 'rxjs';
import { AddResult, UserGroupBuilderFacade } from '../../application/user-group-builder.facade';
import { MemberCandidate, USER_GROUP_LIMITS } from '../../domain/user-group.model';
import { SourceBadgeComponent } from '../source-badge/source-badge.component';
import { initials } from '../initials';

@Component({
  selector: 'app-person-search',
  imports: [SourceBadgeComponent],
  templateUrl: './person-search.component.html',
  styleUrl: './person-search.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class PersonSearchComponent {
  private readonly facade = inject(UserGroupBuilderFacade);
  private readonly input = viewChild.required<ElementRef<HTMLInputElement>>('search');

  readonly added = output<AddResult>();

  readonly listId = 'person-search-list';
  readonly initials = initials;
  readonly minLength = USER_GROUP_LIMITS.searchMinLength;

  readonly term = signal('');
  readonly focused = signal(false);
  readonly searching = signal(false);
  readonly failed = signal(false);
  readonly activeIndex = signal(0);

  readonly results = toSignal(
    toObservable(this.term).pipe(
      map((term) => term.trim()),
      debounceTime(300),
      distinctUntilChanged(),
      switchMap((term) =>
        term.length < this.minLength
          ? of<MemberCandidate[]>([])
          : this.facade.searchPeople(term).pipe(
              catchError(() => {
                this.failed.set(true);
                return of<MemberCandidate[]>([]);
              }),
            ),
      ),
      tap(() => {
        this.searching.set(false);
        this.activeIndex.set(0);
      }),
    ),
    { initialValue: [] as MemberCandidate[] },
  );

  readonly panelOpen = computed(() => this.focused() && this.term().trim().length >= this.minLength);

  readonly activeOptionId = computed(() =>
    this.panelOpen() && this.results().length ? `${this.listId}-${this.activeIndex()}` : null,
  );

  inGroup(email: string): boolean {
    return this.facade.memberEmails().has(email);
  }

  onInput(value: string): void {
    this.term.set(value);
    this.failed.set(false);
    this.searching.set(value.trim().length >= this.minLength);
  }

  onKeydown(event: KeyboardEvent): void {
    const options = this.results();

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
        event.preventDefault();
        if (this.panelOpen() && options[this.activeIndex()]) this.pick(options[this.activeIndex()]);
        break;
      case 'Escape':
        this.term.set('');
        break;
    }
  }

  pick(candidate: MemberCandidate): void {
    if (this.inGroup(candidate.email)) return;

    this.added.emit(this.facade.addCandidates([candidate], 'INDIVIDUAL'));
    this.term.set('');
    this.input().nativeElement.focus();
  }
}
```

### `person-search.component.html`

```html
<label for="person-search" class="form-label fw-semibold">Buscar por nombre o correo</label>
<div class="ps">
  <i class="fa-solid fa-magnifying-glass ps__icon" aria-hidden="true"></i>
  <input
    #search
    id="person-search"
    type="text"
    class="form-control ps__input"
    role="combobox"
    autocomplete="off"
    aria-autocomplete="list"
    placeholder="Ej. Ana Pérez o ana.perez@empresa.com"
    [attr.aria-expanded]="panelOpen()"
    [attr.aria-controls]="listId"
    [attr.aria-activedescendant]="activeOptionId()"
    [value]="term()"
    (input)="onInput($any($event.target).value)"
    (keydown)="onKeydown($event)"
    (focus)="focused.set(true)"
    (blur)="focused.set(false)" />

  @if (panelOpen()) {
    <ul class="ps__panel" role="listbox" aria-label="Personas encontradas" [id]="listId">
      @if (searching()) {
        <li class="ps__status"><span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span> Buscando…</li>
      } @else if (failed()) {
        <li class="ps__status text-danger">No se pudo buscar. Intenta de nuevo.</li>
      } @else {
        @for (person of results(); track person.email; let i = $index) {
          <li
            role="option"
            class="ps__option"
            [id]="listId + '-' + i"
            [class.is-active]="i === activeIndex()"
            [class.is-disabled]="inGroup(person.email)"
            [attr.aria-selected]="i === activeIndex()"
            [attr.aria-disabled]="inGroup(person.email)"
            (mousedown)="$event.preventDefault(); pick(person)"
            (mouseenter)="activeIndex.set(i)">
            <span class="ps__avatar" aria-hidden="true">{{ initials(person.displayName) }}</span>
            <span class="ps__text">
              <strong>{{ person.displayName }}</strong>
              <small>{{ person.email }}@if (person.jobTitle) { · {{ person.jobTitle }} }</small>
            </span>
            @if (inGroup(person.email)) {
              <span class="ps__already">Ya está en el grupo</span>
            } @else {
              <app-source-badge [inDoccb]="person.userId !== null" />
            }
          </li>
        } @empty {
          <li class="ps__status">Sin resultados para «{{ term().trim() }}».</li>
        }
      }
    </ul>
  }
</div>
<p class="form-text mb-0">Busca en el maestro de usuarios y en el directorio de Microsoft al mismo tiempo.</p>
```

### `person-search.component.scss`

```scss
@use '../user-groups-tokens' as ug;

.ps {
  position: relative;
}

.ps__icon {
  position: absolute;
  top: 50%;
  left: 0.9rem;
  color: var(--ug-muted);
  transform: translateY(-50%);
  pointer-events: none;
}

.ps__input {
  padding-left: 2.4rem;
}

.ps__panel {
  position: absolute;
  top: calc(100% + 0.375rem);
  right: 0;
  left: 0;
  z-index: 5;
  max-height: 20rem;
  margin: 0;
  padding: 0.375rem;
  overflow-y: auto;
  list-style: none;
  border: 1px solid var(--ug-border);
  border-radius: var(--ug-radius-sm);
  background: var(--ug-surface);
  box-shadow: 0 18px 36px -8px rgb(0 0 0 / 0.16);
  animation: ug-drop 0.2s var(--ug-ease-out) both;
}

.ps__option {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.5rem 0.625rem;
  border-radius: 0.5rem;
  cursor: pointer;

  &.is-active {
    background: color-mix(in srgb, var(--ug-accent) 10%, transparent);
  }

  &.is-disabled {
    cursor: default;
    opacity: 0.6;
  }
}

.ps__avatar {
  @include ug.avatar(2rem);
}

.ps__text {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-width: 0;

  small {
    overflow: hidden;
    color: var(--ug-muted);
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}

.ps__already {
  color: var(--ug-muted);
  font-size: 0.75rem;
  font-style: italic;
  white-space: nowrap;
}

.ps__status {
  padding: 0.625rem;
  color: var(--ug-muted);
  font-size: 0.875rem;
}

@keyframes ug-drop {
  from {
    opacity: 0;
    transform: translateY(-4px);
  }
}

@media (prefers-reduced-motion: reduce) {
  .ps__panel {
    animation: none;
  }
}
```

---

## 11. Paso 8 — Pestaña "Pegar correos"

### `presentation/email-import/email-import.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, output, signal } from '@angular/core';
import { extractEmails } from '@shared/utils/email-list';
import { toErrorMessage } from '@shared/utils/api-response';
import { AddResult, UserGroupBuilderFacade } from '../../application/user-group-builder.facade';
import { EmailResolution, USER_GROUP_LIMITS, UnresolvedReason } from '../../domain/user-group.model';
import { UNRESOLVED_REASON_LABEL } from '../../domain/member-origin.config';
import { SourceBadgeComponent } from '../source-badge/source-badge.component';

@Component({
  selector: 'app-email-import',
  imports: [SourceBadgeComponent],
  templateUrl: './email-import.component.html',
  styleUrl: './email-import.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class EmailImportComponent {
  private readonly facade = inject(UserGroupBuilderFacade);

  readonly added = output<AddResult>();
  readonly limit = USER_GROUP_LIMITS.emailsPerValidation;

  readonly raw = signal('');
  readonly validating = signal(false);
  readonly error = signal<string | null>(null);
  readonly result = signal<EmailResolution | null>(null);
  readonly copied = signal(false);

  readonly extraction = computed(() => extractEmails(this.raw()));
  readonly tooMany = computed(() => this.extraction().emails.length > this.limit);

  readonly toAdd = computed(() =>
    (this.result()?.found ?? []).filter((person) => !this.facade.memberEmails().has(person.email)),
  );
  readonly alreadyInGroup = computed(() => (this.result()?.found.length ?? 0) - this.toAdd().length);
  readonly toAddDirectoryOnly = computed(() => this.toAdd().filter((person) => person.userId === null).length);

  readonly unresolvedByReason = computed(() => {
    const groups = new Map<UnresolvedReason, string[]>();
    for (const item of this.result()?.unresolved ?? []) {
      groups.set(item.reason, [...(groups.get(item.reason) ?? []), item.email]);
    }
    return [...groups].map(([reason, emails]) => ({ reason, label: UNRESOLVED_REASON_LABEL[reason], emails }));
  });

  readonly unresolvedCount = computed(() => this.result()?.unresolved.length ?? 0);

  onInput(value: string): void {
    this.raw.set(value);
    this.result.set(null); // el texto cambió: hay que volver a validar
  }

  async validate(): Promise<void> {
    const emails = this.extraction().emails;
    if (!emails.length || this.tooMany() || this.validating()) return;

    this.validating.set(true);
    this.error.set(null);

    try {
      this.result.set(await this.facade.resolveEmails(emails));
    } catch (e) {
      this.error.set(toErrorMessage(e, 'No se pudieron validar los correos.'));
    } finally {
      this.validating.set(false);
    }
  }

  add(): void {
    this.added.emit(this.facade.addCandidates(this.toAdd(), 'BULK'));
    this.raw.set('');
    this.result.set(null);
  }

  async copyUnresolved(): Promise<void> {
    const emails = (this.result()?.unresolved ?? []).map((item) => item.email).join('\n');
    try {
      await navigator.clipboard.writeText(emails);
      this.copied.set(true);
      setTimeout(() => this.copied.set(false), 2000);
    } catch {
      // Sin permiso de portapapeles: la lista sigue visible en pantalla para copiarla a mano.
    }
  }
}
```

### `email-import.component.html`

```html
<label for="email-list" class="form-label fw-semibold">Pega la lista de correos</label>
<textarea
  id="email-list"
  class="form-control ei__text"
  rows="6"
  placeholder="Sirve cualquier formato:&#10;ana@empresa.com, juan@empresa.com&#10;Ana Pérez <ana@empresa.com>; Juan Mora <juan@empresa.com>&#10;o una columna copiada de Excel"
  [value]="raw()"
  (input)="onInput($any($event.target).value)"></textarea>

<div class="ei__meta">
  <span [class.text-danger]="tooMany()">
    <strong>{{ extraction().emails.length }}</strong>
    {{ extraction().emails.length === 1 ? 'correo detectado' : 'correos detectados' }}
    @if (extraction().duplicates) { · {{ extraction().duplicates }} repetidos se ignoran }
    @if (tooMany()) { · máximo {{ limit }} por validación }
  </span>

  <button
    type="button"
    class="btn btn-primary"
    [disabled]="!extraction().emails.length || tooMany() || validating()"
    (click)="validate()">
    @if (validating()) {
      <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Validando…
    } @else {
      <i class="fa-solid fa-list-check me-1" aria-hidden="true"></i> Validar correos
    }
  </button>
</div>

@if (error(); as message) {
  <div class="alert alert-danger mt-3 mb-0" role="alert">{{ message }}</div>
}

@if (result()) {
  <div class="ei__stats">
    <div class="ei__stat" data-tone="ok">
      <span class="ei__stat-value">{{ toAdd().length }}</span>
      <span class="ei__stat-label">Nuevas para agregar</span>
      @if (toAddDirectoryOnly()) {
        <small>{{ toAddDirectoryOnly() }} solo en el directorio</small>
      }
    </div>
    <div class="ei__stat" data-tone="muted">
      <span class="ei__stat-value">{{ alreadyInGroup() }}</span>
      <span class="ei__stat-label">Ya estaban en el grupo</span>
    </div>
    <div class="ei__stat" data-tone="danger">
      <span class="ei__stat-value">{{ unresolvedCount() }}</span>
      <span class="ei__stat-label">No se pudieron agregar</span>
    </div>
  </div>

  @if (unresolvedCount()) {
    <div class="ei__unresolved">
      <div class="d-flex align-items-center justify-content-between gap-2 mb-2">
        <strong class="small">Correos que no se agregarán</strong>
        <button type="button" class="btn btn-link btn-sm p-0" (click)="copyUnresolved()">
          <i class="fa-solid {{ copied() ? 'fa-check' : 'fa-copy' }} me-1" aria-hidden="true"></i>
          {{ copied() ? 'Copiados' : 'Copiar lista' }}
        </button>
      </div>
      @for (group of unresolvedByReason(); track group.reason) {
        <p class="small fw-semibold mb-1">{{ group.label }} ({{ group.emails.length }})</p>
        <ul class="ei__emails">
          @for (email of group.emails; track email) {
            <li>{{ email }}</li>
          }
        </ul>
      }
    </div>
  }

  @if (toAdd().length) {
    <ul class="ei__preview" aria-label="Personas que se agregarán">
      @for (person of toAdd(); track person.email) {
        <li>
          <span class="ei__name">{{ person.displayName }}</span>
          <span class="ei__email">{{ person.email }}</span>
          <app-source-badge [inDoccb]="person.userId !== null" />
        </li>
      }
    </ul>

    <div class="text-end mt-3">
      <button type="button" class="btn btn-accent" (click)="add()">
        <i class="fa-solid fa-user-plus me-1" aria-hidden="true"></i>
        Agregar {{ toAdd().length }} {{ toAdd().length === 1 ? 'persona' : 'personas' }}
      </button>
    </div>
  }
}
```

### `email-import.component.scss`

```scss
.ei__text {
  font-family: var(--bs-font-monospace);
  font-size: 0.85rem;
}

.ei__meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  margin-top: 0.75rem;
  color: var(--ug-muted);
  font-size: 0.875rem;
}

.ei__stats {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.75rem;
  margin-top: 1rem;

  @media (max-width: 575.98px) {
    grid-template-columns: 1fr;
  }
}

.ei__stat {
  --tone: var(--ug-doccb);

  display: flex;
  flex-direction: column;
  padding: 0.875rem 1rem;
  border-radius: var(--ug-radius-sm);
  background: color-mix(in srgb, var(--tone) 10%, var(--ug-surface));
  animation: ug-rise 0.35s var(--ug-ease-out) both;

  &[data-tone='muted'] {
    --tone: var(--ug-muted);
    animation-delay: 60ms;
  }

  &[data-tone='danger'] {
    --tone: var(--ug-danger);
    animation-delay: 120ms;
  }

  small {
    color: var(--ug-muted);
  }
}

.ei__stat-value {
  color: color-mix(in srgb, var(--tone) 80%, var(--ug-text));
  font-size: 1.6rem;
  font-weight: 700;
  line-height: 1.1;
}

.ei__stat-label {
  font-size: 0.8rem;
  font-weight: 600;
}

.ei__unresolved {
  margin-top: 1rem;
  padding: 0.875rem 1rem;
  border: 1px dashed color-mix(in srgb, var(--ug-danger) 45%, var(--ug-border));
  border-radius: var(--ug-radius-sm);
}

.ei__emails {
  display: flex;
  flex-wrap: wrap;
  gap: 0.25rem 1rem;
  margin: 0 0 0.75rem;
  padding: 0;
  list-style: none;
  font-family: var(--bs-font-monospace);
  font-size: 0.8rem;
}

.ei__preview {
  max-height: 16rem;
  margin: 1rem 0 0;
  padding: 0.375rem;
  overflow-y: auto;
  list-style: none;
  border: 1px solid var(--ug-border);
  border-radius: var(--ug-radius-sm);

  li {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.4rem 0.5rem;
    border-radius: 0.375rem;

    &:nth-child(odd) {
      background: var(--ug-surface-alt);
    }
  }
}

.ei__name {
  font-weight: 600;
}

.ei__email {
  flex: 1 1 auto;
  overflow: hidden;
  color: var(--ug-muted);
  font-size: 0.85rem;
  text-overflow: ellipsis;
  white-space: nowrap;
}

@keyframes ug-rise {
  from {
    opacity: 0;
    transform: translateY(8px);
  }
}

@media (prefers-reduced-motion: reduce) {
  .ei__stat {
    animation: none;
  }
}
```

---

## 12. Paso 9 — Tabla de integrantes

Presentacional: recibe la lista y emite `remove`. Muestra de a 100 filas para que un grupo de 3.000 personas no congele la pantalla.

### `presentation/members-table/members-table.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, input, output, signal } from '@angular/core';
import { GroupManager, GroupMember } from '../../domain/user-group.model';
import { ADDED_VIA_CONFIG } from '../../domain/member-origin.config';
import { SourceBadgeComponent } from '../source-badge/source-badge.component';
import { initials } from '../initials';

export type SourceFilter = 'all' | 'doccb' | 'directory';

const PAGE_STEP = 100;

@Component({
  selector: 'app-members-table',
  imports: [SourceBadgeComponent],
  templateUrl: './members-table.component.html',
  styleUrl: './members-table.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class MembersTableComponent {
  readonly members = input.required<readonly GroupMember[]>();
  readonly managers = input<readonly GroupManager[]>([]);
  readonly recentlyAdded = input<ReadonlySet<string>>(new Set());

  readonly remove = output<GroupMember>();

  readonly search = signal('');
  readonly source = signal<SourceFilter>('all');
  readonly visible = signal(PAGE_STEP);

  readonly counts = computed(() => {
    const all = this.members();
    const doccb = all.filter((m) => m.userId !== null).length;
    return { all: all.length, doccb, directory: all.length - doccb };
  });

  readonly filters = computed(() => [
    { id: 'all' as const, label: 'Todos', count: this.counts().all },
    { id: 'doccb' as const, label: 'Maestro', count: this.counts().doccb },
    { id: 'directory' as const, label: 'Solo directorio', count: this.counts().directory },
  ]);

  private readonly managerNames = computed(() => new Map(this.managers().map((m) => [m.email, m.displayName])));

  private readonly filtered = computed(() => {
    const term = this.search().trim().toLowerCase();
    const source = this.source();

    return this.members().filter((m) => {
      const matchesSource = source === 'all' || (source === 'doccb') === (m.userId !== null);
      const matchesTerm = !term || m.displayName.toLowerCase().includes(term) || m.email.includes(term);
      return matchesSource && matchesTerm;
    });
  });

  /** Todo lo que la fila necesita, calculado una vez por cambio. */
  readonly rows = computed(() =>
    this.filtered()
      .slice(0, this.visible())
      .map((member) => ({
        member,
        initials: initials(member.displayName),
        via: ADDED_VIA_CONFIG[member.addedVia],
        managerName: member.managerEmail
          ? (this.managerNames().get(member.managerEmail) ?? member.managerEmail)
          : null,
        isNew: this.recentlyAdded().has(member.email),
      })),
  );

  readonly remaining = computed(() => this.filtered().length - this.rows().length);

  setSearch(value: string): void {
    this.search.set(value);
    this.visible.set(PAGE_STEP);
  }

  setSource(value: SourceFilter): void {
    this.source.set(value);
    this.visible.set(PAGE_STEP);
  }

  showMore(): void {
    this.visible.update((v) => v + PAGE_STEP);
  }
}
```

### `members-table.component.html`

```html
<div class="mt__toolbar">
  <div class="mt__search">
    <i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>
    <label for="members-filter" class="visually-hidden">Filtrar integrantes</label>
    <input
      id="members-filter"
      type="search"
      class="form-control form-control-sm"
      placeholder="Filtrar por nombre o correo"
      [value]="search()"
      (input)="setSearch($any($event.target).value)" />
  </div>

  <div class="btn-group btn-group-sm" role="group" aria-label="Filtrar por fuente">
    @for (filter of filters(); track filter.id) {
      <button
        type="button"
        class="btn btn-outline-secondary"
        [class.active]="source() === filter.id"
        [attr.aria-pressed]="source() === filter.id"
        (click)="setSource(filter.id)">
        {{ filter.label }} <span class="mt__count">{{ filter.count }}</span>
      </button>
    }
  </div>
</div>

@if (!members().length) {
  <div class="mt__empty">
    <i class="fa-solid fa-user-group" aria-hidden="true"></i>
    <p class="mb-0">Todavía no hay personas. Agrégalas con las pestañas de arriba.</p>
  </div>
} @else if (!rows().length) {
  <p class="text-body-secondary small mt-3 mb-0">Nadie coincide con el filtro.</p>
} @else {
  <div class="mt__wrap">
    <table class="mt">
      <caption class="visually-hidden">Integrantes del grupo</caption>
      <thead>
        <tr>
          <th scope="col">Persona</th>
          <th scope="col">Correo</th>
          <th scope="col">Fuente</th>
          <th scope="col">Origen</th>
          <th scope="col"><span class="visually-hidden">Acciones</span></th>
        </tr>
      </thead>
      <tbody>
        @for (row of rows(); track row.member.email) {
          <tr [class.is-new]="row.isNew">
            <td data-label="Persona">
              <div class="mt__person">
                <span class="mt__avatar" aria-hidden="true">{{ row.initials }}</span>
                <span>
                  <strong>{{ row.member.displayName }}</strong>
                  @if (row.member.jobTitle) {
                    <small class="d-block text-body-secondary">{{ row.member.jobTitle }}</small>
                  }
                </span>
              </div>
            </td>
            <td data-label="Correo" class="mt__email">{{ row.member.email }}</td>
            <td data-label="Fuente"><app-source-badge [inDoccb]="row.member.userId !== null" /></td>
            <td data-label="Origen" class="mt__origin">
              <i class="fa-solid {{ row.via.icon }}" aria-hidden="true"></i>
              {{ row.via.label }}@if (row.managerName) { {{ row.managerName }} }
            </td>
            <td class="text-end">
              <button
                type="button"
                class="mt__remove"
                [attr.aria-label]="'Quitar a ' + row.member.displayName"
                title="Quitar del grupo"
                (click)="remove.emit(row.member)">
                <i class="fa-solid fa-xmark" aria-hidden="true"></i>
              </button>
            </td>
          </tr>
        }
      </tbody>
    </table>
  </div>

  @if (remaining() > 0) {
    <div class="text-center mt-3">
      <button type="button" class="btn btn-outline-secondary btn-sm" (click)="showMore()">
        Mostrar {{ remaining() > 100 ? 100 : remaining() }} más
        <span class="text-body-secondary">(quedan {{ remaining() }})</span>
      </button>
    </div>
  }
}
```

### `members-table.component.scss`

```scss
@use '../user-groups-tokens' as ug;

.mt__toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 0.75rem;
}

.mt__search {
  position: relative;
  flex: 1 1 16rem;
  max-width: 22rem;

  i {
    position: absolute;
    top: 50%;
    left: 0.7rem;
    color: var(--ug-muted);
    font-size: 0.8rem;
    transform: translateY(-50%);
  }

  input {
    padding-left: 2rem;
  }
}

.mt__count {
  margin-left: 0.25rem;
  opacity: 0.7;
}

.mt__wrap {
  max-height: 32rem;
  overflow: auto;
  border: 1px solid var(--ug-border);
  border-radius: var(--ug-radius-sm);
}

.mt {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  font-size: 0.875rem;

  th {
    position: sticky;
    top: 0;
    z-index: 1;
    padding: 0.6rem 0.75rem;
    background: var(--ug-accent);
    color: var(--ug-on-accent);
    font-size: 0.72rem;
    letter-spacing: 0.05em;
    text-transform: uppercase;
  }

  td {
    padding: 0.55rem 0.75rem;
    border-top: 1px solid var(--ug-border);
    vertical-align: middle;
  }

  tbody tr {
    transition: background-color 0.15s ease;

    &:hover {
      background: var(--ug-surface-alt);
    }

    // Recién agregada: se ilumina y se apaga sola.
    &.is-new {
      animation: ug-flash 2.5s ease-out;
    }
  }
}

.mt__person {
  display: flex;
  align-items: center;
  gap: 0.625rem;
}

.mt__avatar {
  @include ug.avatar(2rem);
}

.mt__email {
  color: var(--ug-muted);
}

.mt__origin {
  color: var(--ug-muted);
  font-size: 0.8rem;
  white-space: nowrap;
}

.mt__remove {
  display: inline-grid;
  place-items: center;
  width: 1.9rem;
  height: 1.9rem;
  padding: 0;
  border: 0;
  border-radius: 0.5rem;
  background: transparent;
  color: var(--ug-muted);
  transition: background-color 0.15s ease, color 0.15s ease, transform 0.15s ease;

  &:hover {
    background: color-mix(in srgb, var(--ug-danger) 12%, transparent);
    color: var(--ug-danger);
  }

  &:active {
    transform: scale(0.9);
  }
}

.mt__empty {
  display: grid;
  justify-items: center;
  gap: 0.5rem;
  padding: 2rem 1rem;
  color: var(--ug-muted);
  text-align: center;

  i {
    font-size: 1.75rem;
  }
}

// Móvil: cada fila es una tarjeta con etiquetas.
@media (max-width: 767.98px) {
  .mt thead {
    display: none;
  }

  .mt tr {
    display: block;
    padding: 0.5rem 0.75rem;
    border-top: 1px solid var(--ug-border);
  }

  .mt td {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.25rem 0;
    border: 0;

    &[data-label]::before {
      content: attr(data-label);
      color: var(--ug-muted);
      font-size: 0.75rem;
      font-weight: 600;
    }
  }
}

@keyframes ug-flash {
  0%,
  30% {
    background: color-mix(in srgb, var(--ug-accent) 16%, transparent);
  }
}

@media (prefers-reduced-motion: reduce) {
  .mt tbody tr.is-new {
    animation: none;
    background: color-mix(in srgb, var(--ug-accent) 8%, transparent);
  }
}
```

---

## 13. Paso 10 — ⭐ El constructor

### `presentation/user-group-builder-page/user-group-builder-page.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { toErrorMessage } from '@shared/utils/api-response';
import { confirmDanger, notifyError, notifySuccess } from '@shared/utils/feedback';
import { HasUnsavedChanges } from '@shared/guards/unsaved-changes.guard';
import { AddResult, UserGroupBuilderFacade } from '../../application/user-group-builder.facade';
import { GroupManager, GroupMember, USER_GROUP_LIMITS } from '../../domain/user-group.model';
import { USER_GROUPS_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/user-groups.providers';
import { ManagerImportComponent } from '../manager-import/manager-import.component';
import { PersonSearchComponent } from '../person-search/person-search.component';
import { EmailImportComponent } from '../email-import/email-import.component';
import { MembersTableComponent } from '../members-table/members-table.component';
import { initials } from '../initials';

type ImportTab = 'manager' | 'person' | 'emails';

const TABS: readonly { id: ImportTab; label: string; icon: string }[] = [
  { id: 'manager', label: 'Por líder', icon: 'fa-sitemap' },
  { id: 'person', label: 'Buscar persona', icon: 'fa-magnifying-glass' },
  { id: 'emails', label: 'Pegar correos', icon: 'fa-paste' },
];

@Component({
  selector: 'app-user-group-builder-page',
  imports: [RouterLink, ManagerImportComponent, PersonSearchComponent, EmailImportComponent, MembersTableComponent],
  providers: [...USER_GROUPS_INFRASTRUCTURE_PROVIDERS, UserGroupBuilderFacade],
  templateUrl: './user-group-builder-page.component.html',
  styleUrl: './user-group-builder-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: { '(window:beforeunload)': 'onBeforeUnload($event)' },
})
export class UserGroupBuilderPageComponent implements HasUnsavedChanges {
  protected readonly facade = inject(UserGroupBuilderFacade);
  private readonly router = inject(Router);

  readonly tabs = TABS;
  readonly limits = USER_GROUP_LIMITS;
  readonly initials = initials;

  readonly activeTab = signal<ImportTab>('manager');
  readonly submitted = signal(false);
  /** Lo lee un lector de pantalla cada vez que se agrega gente. */
  readonly announcement = signal('');

  readonly doccbShare = computed(() => {
    const { total, inDoccb } = this.facade.summary();
    return total ? Math.round((inDoccb / total) * 100) : 0;
  });

  constructor() {
    const id = Number(inject(ActivatedRoute).snapshot.paramMap.get('id'));
    void this.facade.load(Number.isInteger(id) && id > 0 ? id : null);
  }

  hasUnsavedChanges(): boolean {
    return this.facade.hasUnsavedChanges();
  }

  /** Aviso del navegador si se cierra la pestaña con cambios. */
  onBeforeUnload(event: BeforeUnloadEvent): void {
    if (this.hasUnsavedChanges()) event.preventDefault();
  }

  // ── Pestañas ────────────────────────────────────────────────────
  onTabKeydown(event: KeyboardEvent, index: number): void {
    const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
    if (!step) return;

    event.preventDefault();
    const next = this.tabs[(index + step + this.tabs.length) % this.tabs.length];
    this.activeTab.set(next.id);
    document.getElementById(`ug-tab-${next.id}`)?.focus();
  }

  // ── Resultado de las pestañas ───────────────────────────────────
  onAdded({ added, alreadyInGroup }: AddResult): void {
    const message =
      added === 0
        ? 'Esas personas ya estaban en el grupo.'
        : `Se ${added === 1 ? 'agregó 1 persona' : `agregaron ${added} personas`}` +
          (alreadyInGroup ? ` · ${alreadyInGroup} ya ${alreadyInGroup === 1 ? 'estaba' : 'estaban'}` : '') +
          '.';

    this.announcement.set(message);
    notifySuccess(message);
  }

  removeMember(member: GroupMember): void {
    this.facade.removeMember(member.email);
  }

  async removeManager(manager: GroupManager): Promise<void> {
    const count = this.facade.countByManager().get(manager.email) ?? 0;

    if (count > 0) {
      const confirmed = await confirmDanger(
        `¿Quitar el equipo de ${manager.displayName}?`,
        `Se quitarán ${count} ${count === 1 ? 'persona que llegó' : 'personas que llegaron'} por su equipo. ` +
          'Las que agregaste de otra forma se quedan.',
        'Quitar equipo',
      );
      if (!confirmed) return;
    }

    this.facade.removeManager(manager.email);
  }

  // ── Guardar ─────────────────────────────────────────────────────
  async save(): Promise<void> {
    this.submitted.set(true);

    if (!this.facade.isValid()) {
      document.getElementById(this.facade.nameError() ? 'group-name' : 'ug-add-card')?.focus();
      return;
    }

    try {
      await this.facade.save();
      notifySuccess(this.facade.isEdit() ? 'Grupo actualizado' : 'Grupo creado');
      await this.router.navigate(['/grupos']);
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudo guardar el grupo.'));
    }
  }
}
```

### `user-group-builder-page.component.html`

```html
<section class="ugb">
  <header class="ugb__head">
    <div>
      <a routerLink="/grupos" class="ugb__back">
        <i class="fa-solid fa-arrow-left me-1" aria-hidden="true"></i> Grupos de usuarios
      </a>
      <h1 class="ugb__title">{{ facade.isEdit() ? 'Editar grupo' : 'Nuevo grupo' }}</h1>
      <p class="ugb__subtitle">
        Arma el grupo con equipos de líderes, personas puntuales o una lista de correos. Se guarda como está hoy:
        si un equipo cambia después, el grupo no se actualiza solo.
      </p>
    </div>

    <div class="ugb__actions">
      <a routerLink="/grupos" class="btn btn-outline-secondary">Cancelar</a>
      <button type="button" class="btn btn-accent" [disabled]="facade.saving()" (click)="save()">
        @if (facade.saving()) {
          <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Guardando…
        } @else {
          <i class="fa-solid fa-check me-1" aria-hidden="true"></i> Guardar grupo
        }
      </button>
    </div>
  </header>

  @switch (facade.status()) {
    @case ('loading') {
      <div class="ugb__skeleton" aria-hidden="true"><span></span><span></span><span></span></div>
      <span class="visually-hidden" role="status">Cargando grupo…</span>
    }

    @case ('error') {
      <div class="alert alert-danger" role="alert">
        {{ facade.loadError() }}
        <a routerLink="/grupos" class="alert-link ms-2">Volver al listado</a>
      </div>
    }

    @default {
      <div class="row g-3">
        <div class="col-12 col-xl-8 d-flex flex-column gap-3">
          <!-- ── Datos del grupo ─────────────────────────────────── -->
          <section class="ug-card" aria-labelledby="ug-data-title">
            <h2 id="ug-data-title" class="ug-card__title">Datos del grupo</h2>

            <div class="mb-3">
              <label for="group-name" class="form-label">Nombre</label>
              <input
                id="group-name"
                type="text"
                class="form-control"
                autocomplete="off"
                [attr.maxlength]="limits.name"
                [class.is-invalid]="submitted() && facade.nameError()"
                [value]="facade.name()"
                (input)="facade.setName($any($event.target).value)" />
              <div class="d-flex justify-content-between gap-2">
                <div>
                  @if (submitted() && facade.nameError(); as message) {
                    <div class="invalid-feedback d-block">{{ message }}</div>
                  }
                </div>
                <div class="form-text">{{ facade.name().length }}/{{ limits.name }}</div>
              </div>
            </div>

            <div>
              <label for="group-description" class="form-label">
                Descripción <span class="text-body-secondary fw-normal">(opcional)</span>
              </label>
              <textarea
                id="group-description"
                class="form-control"
                rows="2"
                [attr.maxlength]="limits.description"
                [value]="facade.description()"
                (input)="facade.setDescription($any($event.target).value)"></textarea>
            </div>
          </section>

          <!-- ── Agregar personas ─────────────────────────────────── -->
          <section id="ug-add-card" class="ug-card" tabindex="-1" aria-labelledby="ug-add-title">
            <h2 id="ug-add-title" class="ug-card__title">Agregar personas</h2>

            <div class="ug-tabs" role="tablist" aria-label="Formas de agregar personas">
              @for (tab of tabs; track tab.id; let i = $index) {
                <button
                  type="button"
                  role="tab"
                  class="ug-tabs__tab"
                  [id]="'ug-tab-' + tab.id"
                  [class.is-active]="activeTab() === tab.id"
                  [attr.aria-selected]="activeTab() === tab.id"
                  [attr.aria-controls]="'ug-panel-' + tab.id"
                  [attr.tabindex]="activeTab() === tab.id ? 0 : -1"
                  (click)="activeTab.set(tab.id)"
                  (keydown)="onTabKeydown($event, i)">
                  <i class="fa-solid {{ tab.icon }}" aria-hidden="true"></i> {{ tab.label }}
                </button>
              }
            </div>

            <div
              class="ug-tabs__panel"
              role="tabpanel"
              [id]="'ug-panel-' + activeTab()"
              [attr.aria-labelledby]="'ug-tab-' + activeTab()">
              @switch (activeTab()) {
                @case ('manager') {
                  <app-manager-import (added)="onAdded($event)" />
                }
                @case ('person') {
                  <app-person-search (added)="onAdded($event)" />
                }
                @case ('emails') {
                  <app-email-import (added)="onAdded($event)" />
                }
              }
            </div>

            @if (submitted() && facade.membersError(); as message) {
              <div class="alert alert-warning mt-3 mb-0 py-2 small" role="alert">{{ message }}</div>
            }
          </section>

          <!-- ── Integrantes ──────────────────────────────────────── -->
          <section class="ug-card" aria-labelledby="ug-members-title">
            <h2 id="ug-members-title" class="ug-card__title">
              Integrantes <span class="ug-card__badge">{{ facade.summary().total }}</span>
            </h2>
            <app-members-table
              [members]="facade.members()"
              [managers]="facade.managers()"
              [recentlyAdded]="facade.recentlyAdded()"
              (remove)="removeMember($event)" />
          </section>
        </div>

        <!-- ── Resumen ──────────────────────────────────────────────── -->
        <aside class="col-12 col-xl-4">
          <div class="ug-card ugb__summary">
            <p class="ugb__total">
              <span class="ugb__total-value">{{ facade.summary().total }}</span>
              {{ facade.summary().total === 1 ? 'persona' : 'personas' }}
            </p>

            <div
              class="ugb__bar"
              role="img"
              [style.--share]="doccbShare() + '%'"
              [attr.aria-label]="doccbShare() + ' % de las personas están en el maestro'">
              <span class="ugb__bar-fill"></span>
            </div>
            <p class="ugb__legend">
              <span><i class="dot" data-source="doccb"></i> {{ facade.summary().inDoccb }} en el maestro</span>
              <span><i class="dot" data-source="directory"></i> {{ facade.summary().directoryOnly }} solo directorio</span>
            </p>

            @if (facade.summary().directoryOnly) {
              <div class="alert alert-warning small py-2">
                <strong>{{ facade.summary().directoryOnly }}</strong>
                {{ facade.summary().directoryOnly === 1 ? 'persona no está' : 'personas no están' }} en el maestro de usuarios.
                Cursos y los demás procesos que usan el maestro no las incluirán hasta que se carguen allí.
              </div>
            }

            <h3 class="ugb__subtitle-sm">Líderes</h3>
            @if (!facade.managers().length) {
              <p class="text-body-secondary small mb-0">Aún no agregas equipos por líder.</p>
            } @else {
              <ul class="ugb__managers">
                @for (manager of facade.managers(); track manager.email) {
                  <li>
                    <span class="ugb__avatar" aria-hidden="true">{{ initials(manager.displayName) }}</span>
                    <span class="ugb__manager-text">
                      <strong>{{ manager.displayName }}</strong>
                      <small>
                        {{ facade.countByManager().get(manager.email) ?? 0 }} personas ·
                        {{ manager.includeAllLevels ? 'todos los niveles' : 'directos' }}
                      </small>
                    </span>
                    <button
                      type="button"
                      class="ugb__remove"
                      [attr.aria-label]="'Quitar el equipo de ' + manager.displayName"
                      (click)="removeManager(manager)">
                      <i class="fa-solid fa-xmark" aria-hidden="true"></i>
                    </button>
                  </li>
                }
              </ul>
            }
          </div>
        </aside>
      </div>
    }
  }

  <span class="visually-hidden" aria-live="polite">{{ announcement() }}</span>
</section>
```

### `user-group-builder-page.component.scss`

```scss
@use '../user-groups-tokens' as ug;

:host {
  @include ug.user-groups-tokens;
  display: block;
}

.ugb {
  padding: 1.5rem 0;
}

.ugb__head {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1.25rem;
}

.ugb__back {
  display: inline-block;
  margin-bottom: 0.5rem;
  color: var(--ug-muted);
  font-size: 0.875rem;
  text-decoration: none;

  &:hover {
    color: var(--ug-accent);
  }
}

.ugb__title {
  margin: 0;
  font-size: 1.75rem;
  font-weight: 700;
}

.ugb__subtitle {
  max-width: 44rem;
  margin: 0.25rem 0 0;
  color: var(--ug-muted);
}

.ugb__actions {
  display: flex;
  gap: 0.5rem;
}

.ug-card {
  @include ug.card;
  animation: ug-rise 0.35s var(--ug-ease-out) both;

  &:focus {
    outline: 2px solid var(--ug-accent);
    outline-offset: 2px;
  }
}

.ug-card__title {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0 1rem;
  font-size: 1.05rem;
  font-weight: 700;
}

.ug-card__badge {
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--ug-accent) 14%, transparent);
  color: color-mix(in srgb, var(--ug-accent) 80%, var(--ug-text));
  font-size: 0.8rem;
}

// ── Pestañas ────────────────────────────────────────────────────────
.ug-tabs {
  display: flex;
  gap: 0.375rem;
  margin-bottom: 1.25rem;
  padding: 0.3rem;
  overflow-x: auto;
  border-radius: 999px;
  background: var(--ug-surface-alt);
}

.ug-tabs__tab {
  flex: 1 0 auto;
  padding: 0.5rem 1rem;
  border: 0;
  border-radius: 999px;
  background: transparent;
  color: var(--ug-muted);
  font-weight: 600;
  white-space: nowrap;
  transition: background-color 0.2s ease, color 0.2s ease, box-shadow 0.2s ease;

  &:hover {
    color: var(--ug-text);
  }

  &.is-active {
    background: var(--ug-surface);
    box-shadow: 0 1px 3px rgb(0 0 0 / 0.1);
    color: var(--ug-accent);
  }

  &:focus-visible {
    outline: 2px solid var(--ug-accent);
    outline-offset: 2px;
  }
}

.ug-tabs__panel {
  animation: ug-rise 0.25s var(--ug-ease-out) both;
}

// ── Resumen ─────────────────────────────────────────────────────────
.ugb__summary {
  @media (min-width: 1200px) {
    position: sticky;
    top: 1rem;
  }
}

.ugb__total {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
  margin: 0 0 0.75rem;
  color: var(--ug-muted);
}

.ugb__total-value {
  color: var(--ug-text);
  font-size: 2.5rem;
  font-weight: 800;
  line-height: 1;
}

.ugb__bar {
  height: 0.5rem;
  overflow: hidden;
  border-radius: 999px;
  background: color-mix(in srgb, var(--ug-directory) 45%, var(--ug-surface-alt));
}

.ugb__bar-fill {
  display: block;
  width: var(--share, 0%);
  height: 100%;
  border-radius: inherit;
  background: var(--ug-doccb);
  transition: width 0.6s var(--ug-ease-out);
}

.ugb__legend {
  display: flex;
  flex-wrap: wrap;
  gap: 0.25rem 1rem;
  margin: 0.5rem 0 1rem;
  color: var(--ug-muted);
  font-size: 0.8rem;

  .dot {
    display: inline-block;
    width: 0.55rem;
    height: 0.55rem;
    margin-right: 0.25rem;
    border-radius: 50%;
    background: var(--ug-doccb);

    &[data-source='directory'] {
      background: var(--ug-directory);
    }
  }
}

.ugb__subtitle-sm {
  margin: 1.25rem 0 0.5rem;
  color: var(--ug-muted);
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.ugb__managers {
  display: grid;
  gap: 0.375rem;
  margin: 0;
  padding: 0;
  list-style: none;

  li {
    display: flex;
    align-items: center;
    gap: 0.625rem;
    padding: 0.5rem;
    border-radius: var(--ug-radius-sm);
    background: var(--ug-surface-alt);
    animation: ug-rise 0.3s var(--ug-ease-out) both;
  }
}

.ugb__avatar {
  @include ug.avatar(2rem);
}

.ugb__manager-text {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-width: 0;

  small {
    color: var(--ug-muted);
  }
}

.ugb__remove {
  display: inline-grid;
  place-items: center;
  width: 1.75rem;
  height: 1.75rem;
  padding: 0;
  border: 0;
  border-radius: 0.5rem;
  background: transparent;
  color: var(--ug-muted);

  &:hover {
    background: color-mix(in srgb, var(--ug-danger) 12%, transparent);
    color: var(--ug-danger);
  }
}

// ── Carga ───────────────────────────────────────────────────────────
.ugb__skeleton {
  display: grid;
  gap: 1rem;

  span {
    height: 9rem;
    border-radius: var(--ug-radius);
    background: linear-gradient(90deg, var(--ug-surface-alt) 25%, var(--ug-surface) 50%, var(--ug-surface-alt) 75%);
    background-size: 200% 100%;
    animation: ug-shimmer 1.4s linear infinite;
  }
}

@keyframes ug-rise {
  from {
    opacity: 0;
    transform: translateY(6px);
  }
}

@keyframes ug-shimmer {
  to {
    background-position: -200% 0;
  }
}

@media (prefers-reduced-motion: reduce) {
  .ug-card,
  .ug-tabs__panel,
  .ugb__managers li {
    animation: none;
  }

  .ugb__bar-fill {
    transition: none;
  }

  .ugb__skeleton span {
    animation: none;
  }
}
```

> `btn-accent` es la clase del botón principal que ya usan Certificados y el listado de cursos. Si no existe en tus estilos globales, usa `btn-primary`.

---

## 14. Paso 11 — El listado

> **Filtros en la URL:** para que la búsqueda y la página queden en la URL (enlace compartible, F5, atrás / adelante), aplica [filtros-url-angular.md](filtros-url-angular.md), sección 12. Reemplaza el buscador con rebote de este componente por `createSearchDraft`.

### `presentation/user-groups-list-page/user-groups-list-page.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { DatePipe } from '@angular/common';
import { takeUntilDestroyed, toObservable } from '@angular/core/rxjs-interop';
import { debounceTime, distinctUntilChanged, map, skip } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { confirmDanger, notifyError, notifySuccess } from '@shared/utils/feedback';
import { UserGroupsListFacade } from '../../application/user-groups-list.facade';
import { UserGroupSummary } from '../../domain/user-group.model';
import { USER_GROUPS_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/user-groups.providers';

type ResultsView = 'skeleton' | 'error' | 'empty' | 'table';

@Component({
  selector: 'app-user-groups-list-page',
  imports: [RouterLink, DatePipe],
  providers: [...USER_GROUPS_INFRASTRUCTURE_PROVIDERS, UserGroupsListFacade],
  templateUrl: './user-groups-list-page.component.html',
  styleUrl: './user-groups-list-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class UserGroupsListPageComponent {
  protected readonly facade = inject(UserGroupsListFacade);

  readonly skeletonRows = [0, 1, 2, 3, 4];
  readonly searchDraft = signal('');

  readonly view = computed<ResultsView>(() => {
    if (this.facade.status() === 'error') return 'error';
    if (!this.facade.items().length) return this.facade.status() === 'loading' ? 'skeleton' : 'empty';
    return 'table';
  });

  constructor() {
    toObservable(this.searchDraft)
      .pipe(skip(1), debounceTime(350), map((v) => v.trim()), distinctUntilChanged(), takeUntilDestroyed())
      .subscribe((term) => this.facade.search(term));
  }

  async remove(group: UserGroupSummary): Promise<void> {
    const confirmed = await confirmDanger(
      `¿Eliminar "${group.name}"?`,
      `Tiene ${group.membersCount} ${group.membersCount === 1 ? 'persona' : 'personas'}. Esta acción no se puede deshacer desde la pantalla.`,
      'Eliminar',
    );
    if (!confirmed) return;

    try {
      await this.facade.remove(group);
      notifySuccess('Grupo eliminado');
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudo eliminar el grupo.'));
    }
  }
}
```

### `user-groups-list-page.component.html`

```html
<section class="ugl">
  <header class="mb-4">
    <h1 class="ugl__title">Grupos de usuarios</h1>
    <p class="ugl__subtitle">Arma grupos con equipos de líderes, personas puntuales o listas de correos</p>
  </header>

  <div class="ug-card">
    <div class="d-flex flex-wrap align-items-center justify-content-between gap-3 mb-3">
      <h2 class="h5 mb-0">Listado de grupos</h2>
      <a routerLink="/grupos/nuevo" class="btn btn-accent">
        <i class="fa-solid fa-user-plus me-2" aria-hidden="true"></i> Nuevo grupo
      </a>
    </div>

    <div class="ugl__search mb-3">
      <i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>
      <label for="group-search" class="visually-hidden">Buscar grupo</label>
      <input
        id="group-search"
        type="search"
        class="form-control"
        placeholder="Buscar por nombre o descripción"
        [value]="searchDraft()"
        (input)="searchDraft.set($any($event.target).value)" />
    </div>

    <div aria-live="polite" [attr.aria-busy]="facade.status() === 'loading'">
      @switch (view()) {
        @case ('skeleton') {
          <div class="ugl__skeleton" aria-hidden="true">
            @for (row of skeletonRows; track row) {
              <span></span>
            }
          </div>
        }

        @case ('error') {
          <div class="alert alert-danger d-flex align-items-center justify-content-between gap-2" role="alert">
            <span>{{ facade.error() }}</span>
            <button type="button" class="btn btn-outline-danger btn-sm" (click)="facade.reload()">Reintentar</button>
          </div>
        }

        @case ('empty') {
          <div class="ugl__empty">
            <i class="fa-solid fa-user-group" aria-hidden="true"></i>
            @if (facade.query().search) {
              <p class="mb-0">Ningún grupo coincide con «{{ facade.query().search }}».</p>
            } @else {
              <p class="mb-2">Aún no hay grupos.</p>
              <a routerLink="/grupos/nuevo" class="btn btn-outline-primary btn-sm">Crear el primero</a>
            }
          </div>
        }

        @default {
          <div class="ugl__wrap" [class.is-refreshing]="facade.status() === 'loading'">
            <table class="ugl__table">
              <caption class="visually-hidden">Grupos de usuarios</caption>
              <thead>
                <tr>
                  <th scope="col">Nombre</th>
                  <th scope="col" class="text-center">Integrantes</th>
                  <th scope="col" class="text-center">Líderes</th>
                  <th scope="col">Actualizado</th>
                  <th scope="col" class="text-center">Acciones</th>
                </tr>
              </thead>
              <tbody>
                @for (group of facade.items(); track group.id; let i = $index) {
                  <tr [style.--i]="i">
                    <td data-label="Nombre">
                      <strong class="d-block">{{ group.name }}</strong>
                      @if (group.description) {
                        <small class="ugl__description">{{ group.description }}</small>
                      }
                    </td>
                    <td data-label="Integrantes" class="text-center">
                      {{ group.membersCount }}
                      @if (group.directoryOnlyCount) {
                        <span class="ugl__warn" title="Personas que no están en el maestro de usuarios">
                          {{ group.directoryOnlyCount }} solo directorio
                        </span>
                      }
                    </td>
                    <td data-label="Líderes" class="text-center">{{ group.managersCount }}</td>
                    <td data-label="Actualizado">{{ group.updatedAt | date: 'd MMM y' }}</td>
                    <td data-label="Acciones">
                      <div class="d-flex justify-content-center gap-1">
                        <a
                          class="ugl__action"
                          [routerLink]="['/grupos', group.id, 'editar']"
                          [attr.aria-label]="'Editar ' + group.name"
                          title="Editar">
                          <i class="fa-solid fa-pen-to-square" aria-hidden="true"></i>
                        </a>
                        <button
                          type="button"
                          class="ugl__action ugl__action--danger"
                          [attr.aria-label]="'Eliminar ' + group.name"
                          title="Eliminar"
                          (click)="remove(group)">
                          <i class="fa-solid fa-trash" aria-hidden="true"></i>
                        </button>
                      </div>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          </div>

          <nav class="ugl__pager" aria-label="Paginación de grupos">
            <button
              type="button"
              class="ugl__page-btn"
              aria-label="Página anterior"
              [disabled]="facade.query().page <= 1"
              (click)="facade.goToPage(facade.query().page - 1)">
              <i class="fa-solid fa-chevron-left" aria-hidden="true"></i>
            </button>
            <span>Página {{ facade.query().page }} de {{ facade.totalPages() }}</span>
            <button
              type="button"
              class="ugl__page-btn"
              aria-label="Página siguiente"
              [disabled]="facade.query().page >= facade.totalPages()"
              (click)="facade.goToPage(facade.query().page + 1)">
              <i class="fa-solid fa-chevron-right" aria-hidden="true"></i>
            </button>
          </nav>
        }
      }
    </div>
  </div>
</section>
```

### `user-groups-list-page.component.scss`

```scss
@use '../user-groups-tokens' as ug;

:host {
  @include ug.user-groups-tokens;
  display: block;
  padding: 1.5rem 0;
}

.ugl__title {
  margin: 0;
  font-size: 1.75rem;
  font-weight: 700;
}

.ugl__subtitle {
  margin: 0.25rem 0 0;
  color: var(--ug-muted);
}

.ug-card {
  @include ug.card;
}

.ugl__search {
  position: relative;
  max-width: 28rem;

  i {
    position: absolute;
    top: 50%;
    left: 0.9rem;
    color: var(--ug-muted);
    transform: translateY(-50%);
  }

  input {
    padding-left: 2.4rem;
  }
}

.ugl__wrap {
  overflow-x: auto;
  // overflow-x: auto convierte overflow-y en auto: la animación de entrada de las filas
  // desborda un instante y aparece un scroll vertical aunque haya una sola fila.
  overflow-y: hidden;
  border: 1px solid var(--ug-border);
  border-radius: var(--ug-radius-sm);
  transition: opacity 0.2s ease;

  &.is-refreshing {
    opacity: 0.55;
  }
}

.ugl__table {
  width: 100%;
  border-collapse: collapse;

  th {
    padding: 0.75rem 1rem;
    background: var(--ug-accent);
    color: var(--ug-on-accent);
    font-size: 0.75rem;
    letter-spacing: 0.05em;
    text-transform: uppercase;
  }

  td {
    padding: 0.75rem 1rem;
    border-top: 1px solid var(--ug-border);
    vertical-align: middle;
  }

  tbody tr {
    animation: ug-rise 0.3s var(--ug-ease-out) both;
    animation-delay: calc(min(var(--i, 0), 10) * 35ms);
    transition: background-color 0.15s ease;

    &:hover {
      background: color-mix(in srgb, var(--ug-accent) 6%, transparent);
    }
  }
}

.ugl__description {
  display: -webkit-box;
  overflow: hidden;
  color: var(--ug-muted);
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 1;
}

.ugl__warn {
  display: inline-block;
  margin-left: 0.375rem;
  padding: 0.1rem 0.5rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--ug-directory) 16%, transparent);
  color: color-mix(in srgb, var(--ug-directory) 70%, var(--ug-text));
  font-size: 0.72rem;
  font-weight: 600;
}

.ugl__action {
  display: inline-grid;
  place-items: center;
  width: 2.1rem;
  height: 2.1rem;
  border: 0;
  border-radius: 0.5rem;
  background: color-mix(in srgb, var(--ug-accent) 14%, var(--ug-surface));
  color: color-mix(in srgb, var(--ug-accent) 30%, #111);
  text-decoration: none;
  transition: transform 0.15s ease, background-color 0.15s ease;

  &:hover {
    transform: translateY(-2px);
  }

  &:active {
    transform: scale(0.94);
  }

  &--danger:hover {
    background: color-mix(in srgb, var(--ug-danger) 16%, var(--ug-surface));
    color: var(--ug-danger);
  }
}

.ugl__pager {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 1rem;
  margin-top: 1rem;
  color: var(--ug-muted);
}

.ugl__page-btn {
  display: inline-grid;
  place-items: center;
  width: 2.25rem;
  height: 2.25rem;
  border: 1px solid var(--ug-border);
  border-radius: 50%;
  background: var(--ug-surface);

  &:disabled {
    opacity: 0.4;
  }
}

.ugl__empty {
  display: grid;
  justify-items: center;
  gap: 0.5rem;
  padding: 2.5rem 1rem;
  color: var(--ug-muted);
  text-align: center;

  i {
    font-size: 2rem;
  }
}

.ugl__skeleton {
  display: grid;
  gap: 0.5rem;

  span {
    height: 3rem;
    border-radius: 0.5rem;
    background: var(--ug-surface-alt);
    animation: ug-pulse 1.2s ease-in-out infinite alternate;
  }
}

@media (max-width: 767.98px) {
  .ugl__table thead {
    display: none;
  }

  .ugl__table tr {
    display: block;
    padding: 0.75rem 1rem;
    border-top: 1px solid var(--ug-border);
  }

  .ugl__table td {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.25rem 0;
    border: 0;

    &::before {
      content: attr(data-label);
      color: var(--ug-muted);
      font-size: 0.75rem;
      font-weight: 600;
    }
  }
}

@keyframes ug-rise {
  from {
    opacity: 0;
    transform: translateY(6px);
  }
}

@keyframes ug-pulse {
  to {
    opacity: 0.5;
  }
}

@media (prefers-reduced-motion: reduce) {
  .ugl__table tbody tr,
  .ugl__skeleton span {
    animation: none;
  }
}
```

---

## 15. Paso 12 — Rutas

En `src/app/app.routes.ts`:

```ts
{
  path: 'grupos',
  canActivate: [permissionGuard],
  data: { permissionPath: 'user-groups' },
  loadComponent: () =>
    import('@features/user-groups/presentation/user-groups-list-page/user-groups-list-page.component')
      .then(m => m.UserGroupsListPageComponent),
},
{
  path: 'grupos/nuevo',
  canActivate: [permissionGuard],
  canDeactivate: [unsavedChangesGuard],
  data: { permissionPath: 'user-groups' },
  loadComponent: () =>
    import('@features/user-groups/presentation/user-group-builder-page/user-group-builder-page.component')
      .then(m => m.UserGroupBuilderPageComponent),
},
{
  path: 'grupos/:id/editar',
  canActivate: [permissionGuard],
  canDeactivate: [unsavedChangesGuard],
  data: { permissionPath: 'user-groups' },
  loadComponent: () =>
    import('@features/user-groups/presentation/user-group-builder-page/user-group-builder-page.component')
      .then(m => m.UserGroupBuilderPageComponent),
},
```

Agrega **Grupos de usuarios** al menú y el permiso `user-groups` en el backend de permisos.

---

## 16. Pruebas

### Unitarias

```ts
describe('extractEmails', () => {
  it('saca los correos de una lista de Outlook', () => {
    const result = extractEmails('Ana Pérez <Ana@Empresa.com>; Juan Mora <juan@empresa.com>');
    expect(result.emails).toEqual(['ana@empresa.com', 'juan@empresa.com']);
  });

  it('cuenta los repetidos sin importar mayúsculas', () => {
    expect(extractEmails('a@x.com\nA@X.com\nb@x.com').duplicates).toBe(1);
  });

  it('ignora texto que no es correo', () => {
    expect(extractEmails('hola, sin correos aquí').emails).toEqual([]);
  });
});

describe('UserGroupBuilderFacade', () => {
  const ana: MemberCandidate = { email: 'ana@x.com', displayName: 'Ana', jobTitle: null, userId: 1, entraObjectId: null };

  it('no duplica a una persona y conserva su primer origen', () => {
    facade.addCandidates([ana], 'BULK');
    const result = facade.addCandidates([{ ...ana, entraObjectId: 'guid-1' }], 'INDIVIDUAL');

    expect(result).toEqual({ added: 0, alreadyInGroup: 1 });
    expect(facade.members()[0].addedVia).toBe('BULK');
    expect(facade.members()[0].entraObjectId).toBe('guid-1'); // se completó lo que faltaba
  });

  it('al quitar un líder, quita solo a quienes llegaron por él', () => {
    const team = { manager: { ...ana, email: 'lider@x.com' }, members: [ana], truncated: false };
    facade.addManagerTeam(team, [ana], false);
    facade.addCandidates([{ ...ana, email: 'otro@x.com' }], 'INDIVIDUAL');

    facade.removeManager('lider@x.com');

    expect(facade.members().map((m) => m.email)).toEqual(['otro@x.com']);
  });

  it('marca cambios sin guardar y los limpia al guardar', async () => {
    facade.setName('Operaciones');
    expect(facade.hasUnsavedChanges()).toBeTrue();

    facade.addCandidates([ana], 'INDIVIDUAL');
    await facade.save();

    expect(facade.hasUnsavedChanges()).toBeFalse();
  });
});
```

### Revisión con usuarios reales

- Un líder con equipo conocido: la lista coincide con lo que se ve en Outlook o Teams.
- El mismo líder con **todos los niveles**: aparecen también los equipos de sus colaboradores.
- Pegar una lista con correos inválidos, repetidos, de cuentas deshabilitadas y de personas que no existen: cada uno aparece en su grupo.
- Una persona en el equipo de un líder y en la lista pegada: queda una sola vez y el aviso dice "ya estaba".
- Quitar un líder: la confirmación dice cuántas personas se van y las agregadas a mano se quedan.
- Salir con cambios sin guardar (enlace, botón atrás, cerrar pestaña): aparece el aviso.
- Con Graph caído (simúlalo con un `503` en el mock): la búsqueda de personas sigue mostrando resultados del maestro.

---

## ✅ Checklist

- [ ] `@shared/utils/feedback.ts` y `@shared/utils/api-response.ts` disponibles y sin copias por feature.
- [ ] `USER_GROUP_LIMITS` iguales a `UserGroupConstants` del backend.
- [ ] Tokens `--ug-*` conectados a tus variables de color.
- [ ] Rutas con `permissionGuard`, `unsavedChangesGuard` y permiso `user-groups` creado.
- [ ] Probado con líderes reales, listas reales y un grupo de más de 1.000 personas.
- [ ] Decidido qué pasa con las personas "solo directorio": cursos no las asigna hasta que estén en el maestro.
- [ ] Probado con teclado (pestañas con flechas, casillas, búsqueda), lector de pantalla, móvil y `prefers-reduced-motion`.
- [ ] Componentes con `OnPush`, `input()`, `output()` y signals; sin `ngClass` ni `ngStyle`.
