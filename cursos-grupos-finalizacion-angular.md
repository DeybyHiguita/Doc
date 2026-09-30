# 🎓 Cursos por grupos y formulario de finalización (Angular 20 + Bootstrap 5)

Guía de las pantallas del nuevo flujo:

| Pantalla | Para quién | Qué hace |
|---|---|---|
| **Editor de curso** ✏️ | Administrador | Asigna **grupos de usuarios** al curso, cada uno con su fecha límite. Reemplaza a la asignación persona por persona. |
| **Mis cursos** | Cada colaborador | Lista sus cursos pendientes y finalizados. |
| **Formulario de finalización** | Cada colaborador | Curso, sus datos, su **gerencia** (bloqueada, traída de la API) y dos calificaciones **anónimas** con estrellas. Al enviarlo, el curso queda **Finalizado**. |
| **Seguimiento** | Administrador | Avance por grupo, personas con su estado y gerencia, y promedios anónimos de las calificaciones. |

- **Stack:** Angular 20 · standalone · signals · OnPush · Reactive Forms tipados · Bootstrap 5.3 · Font Awesome · SweetAlert2 · SSR · MSAL
- **Backend:** [cursos-grupos-finalizacion-api-sqlserver.md](cursos-grupos-finalizacion-api-sqlserver.md)
- **Modifica a:** [crud-cursos-angular.md](crud-cursos-angular.md) (sección 2 del panel de edición, el buscador de usuarios y el pie de la tarjeta)
- **Estilos:** siguen lo que ya tiene la app ([referencia-estilos-y-capas-doccb.md](referencia-estilos-y-capas-doccb.md)): acento dorado, botón principal `btn-accent`, encabezados de tabla dorados con texto oscuro, filtros en pastillas y paginación `‹ Página 1 de N ›`. Ningún archivo escribe colores a mano; todo sale de los tokens `--cu-*`.

---

## 1. 🧐 Revisión crítica

| # | Riesgo | Decisión en pantalla |
|---|---|---|
| 1 | **Calificar sin querer.** Si las estrellas empiezan en 0, quien no las toque envía "pésimo". | Las dos calificaciones empiezan **sin valor**. El 0 existe como opción explícita ("0 · Nada") al lado de las estrellas, y el botón de enviar pide las dos. |
| 2 | **"¿De verdad es anónimo?"** Si el usuario no lo cree, califica todo con 5. | Un aviso claro sobre las estrellas: se guardan en las estadísticas del curso, **sin su nombre**. Y es verdad: el backend las guarda sin relación con la persona. |
| 3 | **Consecuencia del anonimato:** después de enviar, la persona **no puede ver** lo que calificó. | La pantalla de éxito y la de "ya finalizado" no muestran las calificaciones y explican por qué. |
| 4 | **El envío no se puede deshacer.** | Confirmación antes de enviar: "No podrás cambiar tus respuestas". |
| 5 | **Gerencia bloqueada.** El usuario podría pensar que está mal y no tiene cómo corregirla. | Campo de solo lectura con candado y el texto "Viene del directorio activo". Si no se pudo consultar, dice "No disponible" y deja enviar igual. |
| 6 | **Vencido.** | Una etiqueta roja en "Mis cursos" y en el formulario. Se puede finalizar igual, fuera de plazo. |
| 7 | **Un grupo guardado no cambia de grupo.** Cambiarlo borraría el historial de quienes ya finalizaron. | El grupo de una asignación guardada aparece bloqueado. Para cambiarlo, se quita la asignación y se agrega otra. |
| 8 | **Quitar un grupo con finalizados.** | Confirmación que dice cuántos finalizaron y que se conserva su historial. |
| 9 | **Personas en dos grupos del mismo curso.** | El editor avisa al guardar: "N personas estaban en dos grupos y quedaron en el primero". |
| 10 | **Promedios con pocas respuestas delatan a alguien.** | El seguimiento solo muestra promedios con 3 respuestas o más, y lo explica. |
| 11 | **"Actualizar desde el grupo" con cambios sin guardar.** | El botón se deshabilita hasta guardar, para no mezclar dos operaciones. |

---

## 2. 🎨 Diseño

### Editor de curso — sección 2 "Grupos asignados"

```text
│ ② Grupos asignados                         ≈ 74 personas │
│ Cada grupo tiene su propia fecha límite. Al guardar,      │
│ cada integrante queda Pendiente.                          │
│ ┌ Asignación 1 ───────────────────────────────────── 🗑 ┐ │
│ │ Grupo de usuarios                                     │ │
│ │ [👥 Operaciones Norte · 42 personas             🔒]   │ │ ← guardada: bloqueada
│ │ Fecha límite  [2026-10-30]                            │ │
│ │ ███████████░░░░░░░  18 de 42 finalizaron              │ │
│ │                          ↻ Actualizar desde el grupo  │ │
│ └───────────────────────────────────────────────────────┘ │
│ ┌ Asignación 2 ───────────────────────────────────── 🗑 ┐ │
│ │ Grupo de usuarios                                     │ │
│ │ [🔍 Buscar grupo…                               ]      │ │ ← nueva: buscador
│ │ Fecha límite  [__________]                            │ │
│ └───────────────────────────────────────────────────────┘ │
│ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐ │
│ ╎                ＋ Asignar grupo                       ╎ │
│ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘ │
```

### Mis cursos (`/mis-cursos`)

```text
┌──────────────────────────────────────────────────────────────┐
│ FORMACIÓN                                                     │
│ Mis cursos                                                    │
│ Marca como finalizado cada curso cuando lo termines.          │
│ ┌[⏳] 3 Pendientes┐ ┌[✔] 5 Finalizados┐ ┌[⚠] 1 Vencidos┐       │
│ ┌──────────────────────────────┐ ┌──────────────────────────┐ │
│ │ 💻 VIRTUAL        ⏳ En 4 días│ │ 🏫 PRESENCIAL  ⚠ Vencido │ │
│ │ Excel avanzado               │ │ Primeros auxilios        │ │
│ │ Fecha límite: 3 oct 2026     │ │ Fecha límite: 15 sep     │ │
│ │ [✔ Marcar como finalizado]   │ │ [✔ Marcar como finalizado]│ │
│ └──────────────────────────────┘ └──────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### Formulario de finalización (`/mis-cursos/:id/finalizar`)

```text
┌────────────────────────────────────────────────────────────────┐
│ ← Mis cursos                                                    │
│ 💻 VIRTUAL · Fecha límite 3 oct 2026 (en 4 días)                │
│ Excel avanzado                                                  │
│ Formulario de finalización                                      │
├────────────────────────────────────────────────────────────────┤
│ TUS DATOS                                                       │
│ Nombre            Correo                                         │
│ [Ana Pérez     ]  [ana.perez@empresa.com      ]                  │
│ Gerencia 🔒                                                      │
│ [Gerencia de Operaciones                       ] Viene del       │
│                                                  directorio activo│
├────────────────────────────────────────────────────────────────┤
│ TU OPINIÓN                                   🕶 Respuestas anónimas│
│ ┌──────────────────────────────────────────────────────────────┐│
│ │ Tus calificaciones se guardan en las estadísticas del curso,  ││
│ │ sin tu nombre. Ni el administrador puede ver quién calificó.  ││
│ └──────────────────────────────────────────────────────────────┘│
│ ¿Qué tan satisfecho quedaste con el curso?                      │
│ (0)  ★ ★ ★ ★ ☆   Satisfecho                                      │
│ ¿Qué tan útil fue el curso para tu trabajo?                     │
│ (0)  ★ ★ ★ ★ ★   Muy útil                                        │
├────────────────────────────────────────────────────────────────┤
│ Al enviar, el curso queda Finalizado.   [✔ Marcar como finalizado]│
│ No podrás cambiar tus respuestas.                               │
└────────────────────────────────────────────────────────────────┘
```

### Seguimiento (`/cursos/:id/seguimiento`)

```text
┌────────────────────────────────────────────────────────────────┐
│ ← Cursos · Excel avanzado · Seguimiento                          │
│ ┌ Calificaciones (anónimas) · 27 respuestas ──────────────────┐ │
│ │ Satisfacción  4,3 ★★★★☆      Utilidad  4,6 ★★★★★             │ │
│ │ 5 ████████████ 14            5 ███████████████ 18            │ │
│ │ 4 ███████ 8                  4 ██████ 7                      │ │
│ │ …                            …                               │ │
│ └──────────────────────────────────────────────────────────────┘ │
│ ┌ Operaciones Norte · fecha límite 30 oct ────────────────────┐ │
│ │ ███████████░░░░░░░ 18 de 42 · 3 vencidos     [Ver personas ▾]│ │
│ │ ( Todos | Pendientes | Vencidos | Finalizados ) [🔍 Buscar]   │ │
│ │ PERSONA        CORREO        GERENCIA        ESTADO   FECHA   │ │
│ │ Ana Pérez      ana@…         Operaciones     ✔ Finalizado 24 sep│
│ │ Luis Rojas     luis@…        —               ⏳ Pendiente      │ │
│ └──────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

### Las estrellas

| Acción | Qué pasa |
|---|---|
| Pasar el mouse | Se iluminan hasta esa estrella y el texto muestra su significado ("Satisfecho"). Al salir, vuelve al valor elegido. |
| Clic | Las estrellas se llenan en cascada (35 ms entre una y otra) con un pequeño rebote. |
| Teclado | Tab entra al grupo; ← → cambian el valor; `0` a `5` lo fijan directo; Inicio y Fin van a 0 y 5. |
| Lector de pantalla | Es un grupo de radios: "4 estrellas: Satisfecho, seleccionado". |
| Sin elegir al enviar | El grupo se marca en rojo y aparece "Elige una calificación". |

### Pantalla de éxito

Un check verde que aparece con rebote y un anillo que se expande una vez, el texto "¡Listo! Finalizaste *Excel avanzado*", la fecha y el botón "Volver a mis cursos".

---

## 3. 📁 Archivos

```text
src/app/shared/
├── components/star-rating/                      ⭐ calificación 0-5 con estrellas (reutilizable)
└── utils/due-date.ts                            ✏️ movido desde courses/domain/course-due.ts

src/app/features/courses/                        ✏️ cambios
├── domain/
│   ├── course.model.ts                          ✏️ asignación = grupo + fecha; seguimiento
│   └── course.repository.ts                     ✏️ grupos, sincronizar, seguimiento
├── infraestructure/
│   ├── course.dto.ts / course.mapper.ts         ✏️
│   ├── courses.service.ts                       ✏️
│   ├── courses.providers.ts                     ✏️ sin UsersDirectoryRepository
│   └── users-directory.service.ts               🗑 ya no se usa en cursos
├── application/
│   ├── courses.facade.ts                        ✏️ save devuelve el resultado; grupos; sincronizar
│   ├── course-form.ts                           ✏️ grupo en lugar de usuarios
│   └── course-progress.facade.ts                nuevo
└── presentation/
    ├── group-picker/                            nuevo — buscador de grupos
    ├── course-editor/                           ✏️ sección 2
    ├── user-picker/                             🗑 ya no se usa
    ├── course-progress-page/                    nuevo — seguimiento
    └── assignment-users/                        nuevo — personas de una asignación

src/app/features/my-courses/                     nuevo
├── domain/
│   ├── my-course.model.ts
│   └── my-courses.repository.ts
├── infraestructure/
│   ├── my-course.dto.ts
│   ├── my-course.mapper.ts
│   ├── my-courses.service.ts
│   └── my-courses.providers.ts
├── application/
│   ├── my-courses.facade.ts
│   └── completion-form.facade.ts
└── presentation/
    ├── my-courses-page/
    └── completion-form-page/                    ⭐ el formulario
```

---

## 4. Paso 1 — Shared

### Token nuevo: `--cu-on-accent`

Las tablas nuevas llevan el encabezado dorado con **texto oscuro**, igual que el listado de grupos. Agrega el token al bloque de [crud-cursos-angular.md](crud-cursos-angular.md), sección 4, junto a `--cu-accent`:

```scss
--cu-on-accent: var(--bs-emphasis-color);  // texto sobre el dorado; usa tu variable de texto oscuro
```

Los tokens de cursos (`courses-tokens`) ahora los usan tres pantallas: cursos, seguimiento y mis cursos. Muévelos a `@shared-styles/_courses-tokens.scss` para que ninguna feature dependa de la carpeta de otra.

### Mover `describeDue` a `shared/utils/due-date.ts`

Ahora la usan dos features (cursos y mis cursos), así que pasa a `shared`. Mueve el contenido de `features/courses/domain/course-due.ts` sin cambios a `shared/utils/due-date.ts` y actualiza los imports de `course-card` y `courses-table`:

```ts
import { describeDue } from '@shared/utils/due-date';
```

### `shared/components/star-rating/star-rating.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  computed,
  input,
  model,
  signal,
  viewChildren,
} from '@angular/core';

let nextId = 0;

export const SATISFACTION_LABELS = [
  'Nada satisfecho',
  'Muy insatisfecho',
  'Insatisfecho',
  'Neutral',
  'Satisfecho',
  'Muy satisfecho',
] as const;

export const USEFULNESS_LABELS = ['Nada útil', 'Muy poco útil', 'Poco útil', 'Algo útil', 'Útil', 'Muy útil'] as const;

/**
 * Calificación de 0 a 5 con estrellas.
 * Empieza sin valor (null): así nadie envía un 0 sin haberlo elegido.
 * Uso: <app-star-rating [(value)]="satisfaction" label="…" [labels]="SATISFACTION_LABELS" />
 */
@Component({
  selector: 'app-star-rating',
  templateUrl: './star-rating.component.html',
  styleUrl: './star-rating.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class StarRatingComponent {
  readonly value = model<number | null>(null);
  readonly label = input.required<string>();
  /** Texto de cada valor, del 0 al 5. */
  readonly labels = input<readonly string[]>([]);
  readonly disabled = input(false);
  readonly invalid = input(false);

  readonly max = 5;
  readonly stars = [1, 2, 3, 4, 5];
  readonly id = `star-rating-${nextId++}`;

  /** En orden: el botón 0 y luego las estrellas 1 a 5. El índice es el valor. */
  private readonly options = viewChildren<ElementRef<HTMLButtonElement>>('option');

  readonly hovered = signal<number | null>(null);

  /** Lo que se pinta: la vista previa del mouse o el valor elegido. */
  readonly display = computed(() => this.hovered() ?? this.value() ?? 0);

  readonly caption = computed(() => {
    const value = this.hovered() ?? this.value();
    if (value === null) return 'Sin calificar';
    return this.labels()[value] ?? `${value} de ${this.max}`;
  });

  /** Tabindex itinerante: solo una opción entra en el orden de tabulación. */
  readonly focusable = computed(() => this.value() ?? 0);

  select(value: number): void {
    if (!this.disabled()) this.value.set(value);
  }

  optionLabel(value: number): string {
    const text = this.labels()[value];
    const base = value === 0 ? '0' : `${value} ${value === 1 ? 'estrella' : 'estrellas'}`;
    return text ? `${base}: ${text}` : base;
  }

  onKeydown(event: KeyboardEvent): void {
    if (this.disabled()) return;

    const current = this.value();
    let next: number | null = null;

    switch (event.key) {
      case 'ArrowRight':
      case 'ArrowUp':
        next = Math.min(this.max, (current ?? 0) + 1);
        break;
      case 'ArrowLeft':
      case 'ArrowDown':
        next = Math.max(0, (current ?? 1) - 1);
        break;
      case 'Home':
        next = 0;
        break;
      case 'End':
        next = this.max;
        break;
      default:
        if (/^[0-5]$/.test(event.key)) next = Number(event.key);
    }

    if (next === null) return;

    event.preventDefault();
    this.value.set(next);
    this.options()[next]?.nativeElement.focus();
  }
}
```

### `star-rating.component.html`

```html
<div
  class="sr"
  role="radiogroup"
  [attr.aria-labelledby]="id + '-label'"
  [attr.aria-invalid]="invalid()"
  [class.is-disabled]="disabled()"
  [class.is-invalid]="invalid()"
  (mouseleave)="hovered.set(null)">
  <span class="visually-hidden" [id]="id + '-label'">{{ label() }}</span>

  <button
    #option
    type="button"
    role="radio"
    class="sr__zero"
    [class.is-selected]="value() === 0"
    [attr.aria-checked]="value() === 0"
    [attr.aria-label]="optionLabel(0)"
    [attr.tabindex]="focusable() === 0 ? 0 : -1"
    [disabled]="disabled()"
    (click)="select(0)"
    (keydown)="onKeydown($event)"
    (mouseenter)="hovered.set(0)">
    0
  </button>

  <div class="sr__stars">
    @for (star of stars; track star) {
      <button
        #option
        type="button"
        role="radio"
        class="sr__star"
        [class.is-on]="star <= display()"
        [class.is-preview]="hovered() !== null"
        [style.--i]="star"
        [attr.aria-checked]="value() === star"
        [attr.aria-label]="optionLabel(star)"
        [attr.tabindex]="focusable() === star ? 0 : -1"
        [disabled]="disabled()"
        (click)="select(star)"
        (keydown)="onKeydown($event)"
        (mouseenter)="hovered.set(star)">
        <i class="fa-solid fa-star" aria-hidden="true"></i>
      </button>
    }
  </div>

  <span class="sr__caption" [class.is-empty]="(hovered() ?? value()) === null" aria-hidden="true">
    {{ caption() }}
  </span>
</div>
```

### `star-rating.component.scss`

```scss
:host {
  --sr-on: var(--bs-warning);                // la página lo conecta a su acento (ver el formulario)
  --sr-off: var(--bs-border-color);
  --sr-size: 2rem;
  --sr-spring: cubic-bezier(0.2, 0.9, 0.3, 1.4);

  display: block;
}

.sr {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.75rem;
  padding: 0.25rem 0.5rem;
  border-radius: 0.75rem;
  transition: box-shadow 0.2s ease;

  &.is-invalid {
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--bs-danger) 55%, transparent);
    animation: sr-shake 0.35s ease;
  }

  &.is-disabled {
    opacity: 0.6;
  }
}

.sr__zero {
  min-width: 2.25rem;
  padding: 0.25rem 0.65rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 999px;
  background: transparent;
  color: var(--bs-secondary-color);
  font-weight: 700;
  transition: background-color 0.2s ease, color 0.2s ease, border-color 0.2s ease;

  &:hover,
  &.is-selected {
    border-color: var(--bs-danger);
    background: color-mix(in srgb, var(--bs-danger) 12%, transparent);
    color: var(--bs-danger);
  }
}

.sr__stars {
  display: inline-flex;
  gap: 0.2rem;
}

.sr__star {
  padding: 0.1rem;
  border: 0;
  background: transparent;
  color: var(--sr-off);
  font-size: var(--sr-size);
  line-height: 1;
  cursor: pointer;
  transition:
    color 0.2s ease,
    transform 0.3s var(--sr-spring),
    filter 0.2s ease;
  // Al elegir, se llenan en cascada de izquierda a derecha.
  transition-delay: calc(var(--i, 1) * 35ms);

  &.is-on {
    color: var(--sr-on);
    filter: drop-shadow(0 2px 6px color-mix(in srgb, var(--sr-on) 45%, transparent));
    transform: scale(1.06);
  }

  // Con el mouse encima responde de inmediato, sin cascada.
  &.is-preview {
    transition-delay: 0s;
  }

  &:hover:not(:disabled) {
    transform: scale(1.2) rotate(-6deg);
  }

  &:focus-visible,
  + .sr__zero:focus-visible {
    border-radius: 0.375rem;
    outline: 2px solid var(--bs-primary);
    outline-offset: 2px;
  }
}

.sr__zero:focus-visible {
  outline: 2px solid var(--bs-primary);
  outline-offset: 2px;
}

.sr__caption {
  min-width: 9rem;
  color: var(--bs-body-color);
  font-weight: 600;

  &.is-empty {
    color: var(--bs-secondary-color);
    font-weight: 400;
    font-style: italic;
  }
}

@keyframes sr-shake {
  25% { transform: translateX(-4px); }
  75% { transform: translateX(4px); }
}

@media (prefers-reduced-motion: reduce) {
  .sr__star {
    transition-duration: 0.01ms;
    transition-delay: 0s;

    &:hover:not(:disabled),
    &.is-on {
      transform: none;
    }
  }

  .sr.is-invalid {
    animation: none;
  }
}
```

---

## 5. Paso 2 — Cambios en la feature de cursos

### `domain/course.model.ts` ✏️

Reemplaza `AssignedUser` y `CourseAssignment`, y agrega los tipos del seguimiento:

```ts
/** Un grupo de usuarios que se puede asignar al curso. */
export interface GroupOption {
  readonly id: number;
  readonly name: string;
  readonly membersCount: number;
  readonly directoryOnlyCount: number;
}

/** Un grupo asignado al curso, con su fecha límite y su avance. */
export interface CourseAssignment {
  readonly id: number;
  readonly groupId: number;
  readonly groupName: string;
  /** El grupo se eliminó después de asignarlo: sus personas siguen asignadas. */
  readonly groupRemoved: boolean;
  /** yyyy-MM-dd */
  readonly dueDate: string;
  readonly totalUsers: number;
  readonly completedUsers: number;
}

export interface CourseDraft {
  readonly name: string;
  readonly modality: CourseModality;
  readonly externalId: string | null;
  readonly assignments: ReadonlyArray<{
    readonly id: number | null;
    readonly groupId: number;
    readonly dueDate: string;
  }>;
}

export interface SaveCourseResult {
  readonly courseId: number;
  /** Personas que estaban en dos grupos: quedaron en el primero. */
  readonly overlappingUsers: number;
}

export interface SyncAssignmentResult {
  readonly added: number;
  readonly removedPending: number;
  readonly skippedInOtherGroups: number;
}

// ── Seguimiento ──────────────────────────────────────────────────────
export type CompletionStatus = 'PENDING' | 'COMPLETED';
export type CompletionStatusFilter = 'ALL' | 'PENDING' | 'OVERDUE' | 'COMPLETED';

export interface AssignmentProgress {
  readonly id: number;
  readonly groupName: string;
  readonly dueDate: string;
  readonly total: number;
  readonly completed: number;
  readonly overdue: number;
}

export interface RatingSummary {
  readonly responses: number;
  /** false = menos respuestas que el mínimo: no se muestran promedios. */
  readonly visible: boolean;
  readonly minimumResponses: number;
  readonly satisfactionAverage: number | null;
  readonly usefulnessAverage: number | null;
  /** Índice = calificación (0 a 5). */
  readonly satisfactionDistribution: readonly number[] | null;
  readonly usefulnessDistribution: readonly number[] | null;
}

export interface CourseProgress {
  readonly courseId: number;
  readonly courseName: string;
  readonly assignments: readonly AssignmentProgress[];
  readonly ratings: RatingSummary;
}

export interface AssignedUserProgress {
  readonly displayName: string;
  readonly email: string;
  readonly inDoccb: boolean;
  readonly status: CompletionStatus;
  readonly isOverdue: boolean;
  readonly completedDate: string | null;
  readonly management: string | null;
}

export interface AssignedUsersQuery {
  readonly search: string;
  readonly status: CompletionStatusFilter;
  readonly page: number;
  readonly pageSize: number;
}

export interface AssignedUsersPage {
  readonly items: readonly AssignedUserProgress[];
  readonly total: number;
}
```

### `domain/course.repository.ts` ✏️

```ts
export abstract class CourseRepository {
  abstract list(query: CourseQuery): Observable<CoursePage>;
  abstract getById(id: number): Observable<CourseDetail>;
  abstract create(draft: CourseDraft): Observable<SaveCourseResult>;
  abstract update(id: number, draft: CourseDraft): Observable<SaveCourseResult>;
  abstract setExternalId(id: number, externalId: string): Observable<void>;
  abstract remove(id: number): Observable<void>;

  // Nuevos
  abstract searchGroups(term: string): Observable<GroupOption[]>;
  abstract syncAssignment(courseId: number, assignmentId: number): Observable<SyncAssignmentResult>;
  abstract getProgress(courseId: number): Observable<CourseProgress>;
  abstract getAssignmentUsers(courseId: number, assignmentId: number, query: AssignedUsersQuery): Observable<AssignedUsersPage>;
}
```

Borra `domain/users-directory.repository.ts` y quita su línea de `COURSES_INFRASTRUCTURE_PROVIDERS`. El buscador de personas ahora vive en la feature de grupos.

### `infraestructure/course.dto.ts` ✏️

```ts
export interface CourseAssignmentDto {
  assignmentId: number;
  groupId: number;
  groupName: string;
  groupRemoved: boolean;
  dueDate: string;
  totalUsers: number;
  completedUsers: number;
}

export interface SaveCourseRequestDto {
  name: string;
  modality?: string;
  externalId: string | null;
  assignments: { assignmentId: number | null; groupId: number; dueDate: string }[];
}

export interface SaveCourseResultDto {
  courseId: number;
  overlappingUsers: number;
}

export interface GroupListItemDto {
  groupId: number;
  name: string;
  membersCount: number;
  directoryOnlyCount: number;
}

export interface CourseProgressDto {
  courseId: number;
  courseName: string;
  assignments: { assignmentId: number; groupName: string; dueDate: string; total: number; completed: number; overdue: number }[];
  ratings: RatingSummaryDto;
}

export interface RatingSummaryDto {
  responses: number;
  visible: boolean;
  minimumResponses: number;
  satisfactionAverage: number | null;
  usefulnessAverage: number | null;
  satisfactionDistribution: number[] | null;
  usefulnessDistribution: number[] | null;
}

export interface AssignedUsersPageDto {
  items: {
    displayName: string;
    email: string;
    inDoccb: boolean;
    status: string;
    isOverdue: boolean;
    completedDate: string | null;
    management: string | null;
  }[];
  totalCount: number;
}
```

`CourseUserDto` ya no se usa en cursos.

### `infraestructure/course.mapper.ts` ✏️

```ts
export function toCourseDetail(dto: CourseDetailDto): CourseDetail {
  return {
    id: dto.courseId,
    name: dto.name,
    modality: parseModality(dto.modality),
    externalId: dto.externalId?.trim() || null,
    assignments: dto.assignments.map((a) => ({
      id: a.assignmentId,
      groupId: a.groupId,
      groupName: a.groupName,
      groupRemoved: a.groupRemoved,
      dueDate: toDateOnly(a.dueDate) ?? '',
      totalUsers: a.totalUsers,
      completedUsers: a.completedUsers,
    })),
  };
}

export function toSaveRequest(draft: CourseDraft, includeModality: boolean): SaveCourseRequestDto {
  return {
    name: draft.name,
    ...(includeModality ? { modality: draft.modality } : {}),
    externalId: draft.externalId,
    assignments: draft.assignments.map((a) => ({ assignmentId: a.id, groupId: a.groupId, dueDate: a.dueDate })),
  };
}

export function toGroupOption(dto: GroupListItemDto): GroupOption {
  return { id: dto.groupId, name: dto.name, membersCount: dto.membersCount, directoryOnlyCount: dto.directoryOnlyCount };
}

export function toProgress(dto: CourseProgressDto): CourseProgress {
  return {
    courseId: dto.courseId,
    courseName: dto.courseName,
    assignments: dto.assignments.map((a) => ({
      id: a.assignmentId,
      groupName: a.groupName,
      dueDate: toDateOnly(a.dueDate) ?? '',
      total: a.total,
      completed: a.completed,
      overdue: a.overdue,
    })),
    ratings: { ...dto.ratings },
  };
}

export function toAssignedUsersPage(dto: AssignedUsersPageDto): AssignedUsersPage {
  return {
    total: dto.totalCount,
    items: dto.items.map((u) => ({
      ...u,
      status: u.status === 'COMPLETED' ? 'COMPLETED' : 'PENDING',
    })),
  };
}
```

### `infraestructure/courses.service.ts` ✏️

`create` y `update` devuelven el resultado, y se agregan cuatro métodos:

```ts
create(draft: CourseDraft): Observable<SaveCourseResult> {
  return this.http
    .post<ApiResponse<SaveCourseResultDto>>(this.baseUrl, toSaveRequest(draft, true))
    .pipe(map(unwrap));
}

update(id: number, draft: CourseDraft): Observable<SaveCourseResult> {
  return this.http
    .put<ApiResponse<SaveCourseResultDto>>(`${this.baseUrl}/${id}`, toSaveRequest(draft, false))
    .pipe(map(unwrap));
}

/** Usa el listado de grupos. Quien administra cursos necesita permiso de lectura sobre grupos. */
searchGroups(term: string): Observable<GroupOption[]> {
  const params = new HttpParams().set('search', term).set('pageSize', 10);
  return this.http
    .get<ApiResponse<{ items: GroupListItemDto[] }>>(`${environment.api.baseUrl}/api/user-groups`, { params })
    .pipe(map(unwrap), map((page) => page.items.map(toGroupOption)));
}

syncAssignment(courseId: number, assignmentId: number): Observable<SyncAssignmentResult> {
  return this.http
    .post<ApiResponse<SyncAssignmentResult>>(`${this.baseUrl}/${courseId}/assignments/${assignmentId}/sync`, {})
    .pipe(map(unwrap));
}

getProgress(courseId: number): Observable<CourseProgress> {
  return this.http
    .get<ApiResponse<CourseProgressDto>>(`${this.baseUrl}/${courseId}/progress`)
    .pipe(map(unwrap), map(toProgress));
}

getAssignmentUsers(courseId: number, assignmentId: number, query: AssignedUsersQuery): Observable<AssignedUsersPage> {
  let params = new HttpParams().set('page', query.page).set('pageSize', query.pageSize);
  if (query.search) params = params.set('search', query.search);
  if (query.status !== 'ALL') params = params.set('status', query.status);

  return this.http
    .get<ApiResponse<AssignedUsersPageDto>>(`${this.baseUrl}/${courseId}/assignments/${assignmentId}/users`, { params })
    .pipe(map(unwrap), map(toAssignedUsersPage));
}
```

> `GET /api/user-groups` está protegido con el permiso de grupos. Si quien administra cursos no lo tiene, dale permiso de lectura o crea en el backend un endpoint de solo lectura para elegir grupos.

### `application/courses.facade.ts` ✏️

```ts
// Reemplaza save:
async save(draft: CourseDraft): Promise<SaveCourseResult> {
  const state = this._editor();
  if (!state) throw new Error('No hay un curso abierto en el editor.');

  const result =
    state.mode === 'create'
      ? await firstValueFrom(this.repository.create(draft))
      : await firstValueFrom(this.repository.update(state.id, draft));

  this._editor.set(null);
  this.reload();
  return result;
}

// Nuevos:
searchGroups(term: string): Observable<GroupOption[]> {
  return this.repository.searchGroups(term);
}

syncAssignment(courseId: number, assignmentId: number): Promise<SyncAssignmentResult> {
  return firstValueFrom(this.repository.syncAssignment(courseId, assignmentId));
}
```

Borra `searchUsers` y la inyección de `UsersDirectoryRepository`.

### `application/course-form.ts` ✏️

```ts
export type AssignmentGroupForm = FormGroup<{
  id: FormControl<number | null>;
  group: FormControl<GroupOption | null>;
  dueDate: FormControl<string>;
}>;

/** Un grupo no se asigna dos veces al mismo curso. */
export const uniqueGroups: ValidatorFn = (control: AbstractControl): ValidationErrors | null => {
  const ids = (control as FormArray<AssignmentGroupForm>)
    .getRawValue()
    .map((assignment) => assignment.group?.id)
    .filter((id): id is number => id != null);

  return new Set(ids).size === ids.length ? null : { duplicatedGroups: true };
};

export function createCourseForm(fb: NonNullableFormBuilder): CourseForm {
  return fb.group({
    name: fb.control('', [Validators.required, notBlank, Validators.maxLength(COURSE_NAME_MAX)]),
    modality: fb.control<CourseModality>(CourseModality.Virtual, Validators.required),
    externalId: fb.control('', [Validators.maxLength(EXTERNAL_ID_MAX), Validators.pattern(/^\S*$/)]),
    assignments: fb.array<AssignmentGroupForm>([], uniqueGroups),
  });
}

export function createAssignmentGroup(fb: NonNullableFormBuilder, value?: CourseAssignment): AssignmentGroupForm {
  const assignment = fb.group({
    id: fb.control<number | null>(value?.id ?? null),
    group: fb.control<GroupOption | null>(
      value
        ? { id: value.groupId, name: value.groupName, membersCount: value.totalUsers, directoryOnlyCount: 0 }
        : null,
      Validators.required,
    ),
    dueDate: fb.control(value?.dueDate ?? '', [Validators.required, dueDateNotPast]),
  });

  // Una asignación guardada no cambia de grupo: se quita y se agrega otra.
  if (value) assignment.controls.group.disable();

  return assignment;
}

export function toCourseDraft(form: CourseForm): CourseDraft {
  const raw = form.getRawValue(); // incluye los grupos bloqueados
  return {
    name: raw.name.trim(),
    modality: raw.modality,
    externalId: raw.externalId.trim() || null,
    assignments: raw.assignments.map((assignment) => ({
      id: assignment.id,
      groupId: assignment.group!.id,
      dueDate: assignment.dueDate,
    })),
  };
}
```

Borra `atLeastOneUser` y `uniqueUsersAcrossGroups`.

### `presentation/group-picker/group-picker.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, input, output, signal } from '@angular/core';
import { toObservable, toSignal } from '@angular/core/rxjs-interop';
import { catchError, debounceTime, distinctUntilChanged, map, of, switchMap, tap } from 'rxjs';
import { CoursesFacade } from '../../application/courses.facade';
import { GroupOption } from '../../domain/course.model';

@Component({
  selector: 'app-group-picker',
  templateUrl: './group-picker.component.html',
  styleUrl: './group-picker.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class GroupPickerComponent {
  private readonly facade = inject(CoursesFacade);

  readonly inputId = input.required<string>();
  /** Grupos ya elegidos en otras asignaciones del curso. */
  readonly excludeIds = input<readonly number[]>([]);
  readonly invalid = input(false);
  readonly picked = output<GroupOption>();

  readonly term = signal('');
  readonly focused = signal(false);
  readonly searching = signal(false);
  readonly activeIndex = signal(0);

  private readonly results = toSignal(
    toObservable(this.term).pipe(
      map((term) => term.trim()),
      debounceTime(300),
      distinctUntilChanged(),
      switchMap((term) => this.facade.searchGroups(term).pipe(catchError(() => of<GroupOption[]>([])))),
      tap(() => {
        this.searching.set(false);
        this.activeIndex.set(0);
      }),
    ),
    { initialValue: [] as GroupOption[] },
  );

  readonly options = computed(() => {
    const excluded = new Set(this.excludeIds());
    return this.results().filter((group) => !excluded.has(group.id));
  });

  readonly listId = computed(() => `${this.inputId()}-list`);
  readonly panelOpen = computed(() => this.focused());

  onInput(value: string): void {
    this.term.set(value);
    this.searching.set(true);
  }

  onKeydown(event: KeyboardEvent): void {
    const options = this.options();
    if (event.key === 'ArrowDown' && options.length) {
      event.preventDefault();
      this.activeIndex.update((i) => (i + 1) % options.length);
    } else if (event.key === 'ArrowUp' && options.length) {
      event.preventDefault();
      this.activeIndex.update((i) => (i - 1 + options.length) % options.length);
    } else if (event.key === 'Enter') {
      event.preventDefault(); // nunca envía el formulario
      const option = options[this.activeIndex()];
      if (option) this.pick(option);
    }
  }

  pick(group: GroupOption): void {
    this.picked.emit(group);
    this.term.set('');
  }
}
```

### `group-picker.component.html`

```html
<div class="gp">
  <i class="fa-solid fa-user-group gp__icon" aria-hidden="true"></i>
  <input
    type="text"
    class="form-control gp__input"
    role="combobox"
    autocomplete="off"
    aria-autocomplete="list"
    placeholder="Buscar grupo por nombre"
    [id]="inputId()"
    [class.is-invalid]="invalid()"
    [attr.aria-expanded]="panelOpen()"
    [attr.aria-controls]="listId()"
    [attr.aria-activedescendant]="panelOpen() && options().length ? listId() + '-' + activeIndex() : null"
    [value]="term()"
    (input)="onInput($any($event.target).value)"
    (keydown)="onKeydown($event)"
    (focus)="focused.set(true)"
    (blur)="focused.set(false)" />

  @if (panelOpen()) {
    <ul class="gp__panel" role="listbox" aria-label="Grupos de usuarios" [id]="listId()">
      @if (searching()) {
        <li class="gp__status"><span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span> Buscando…</li>
      } @else {
        @for (group of options(); track group.id; let i = $index) {
          <li
            role="option"
            class="gp__option"
            [id]="listId() + '-' + i"
            [class.is-active]="i === activeIndex()"
            [attr.aria-selected]="i === activeIndex()"
            (mousedown)="$event.preventDefault(); pick(group)"
            (mouseenter)="activeIndex.set(i)">
            <strong>{{ group.name }}</strong>
            <small>
              {{ group.membersCount }} {{ group.membersCount === 1 ? 'persona' : 'personas' }}
              @if (group.directoryOnlyCount) { · {{ group.directoryOnlyCount }} solo directorio }
            </small>
          </li>
        } @empty {
          <li class="gp__status">No hay grupos que coincidan.</li>
        }
      }
    </ul>
  }
</div>
```

### `group-picker.component.scss`

```scss
:host {
  position: relative;
  display: block;
}

.gp__icon {
  position: absolute;
  top: 50%;
  left: 0.85rem;
  color: var(--cu-muted);
  transform: translateY(-50%);
  pointer-events: none;
}

.gp__input {
  padding-left: 2.3rem;
}

.gp__panel {
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
  animation: gp-drop 0.2s var(--cu-ease-out) both;
}

.gp__option {
  display: flex;
  flex-direction: column;
  padding: 0.5rem 0.625rem;
  border-radius: 0.5rem;
  cursor: pointer;

  small {
    color: var(--cu-muted);
  }

  &.is-active {
    background: color-mix(in srgb, var(--cu-accent) 10%, transparent);
  }
}

.gp__status {
  padding: 0.625rem;
  color: var(--cu-muted);
  font-size: 0.875rem;
}

@keyframes gp-drop {
  from {
    opacity: 0;
    transform: translateY(-4px);
  }
}
```

### `course-editor.component.ts` ✏️

Quita `UserPickerComponent` de `imports` y agrega `GroupPickerComponent`. Luego:

```ts
// ── Estado nuevo ─────────────────────────────────────────────────────
/** Avance de cada asignación guardada (del detalle cargado). */
readonly assignmentInfo = signal<ReadonlyMap<number, CourseAssignment>>(new Map());
readonly syncingId = signal<number | null>(null);
private courseId: number | null = null;

readonly selectedGroupIds = computed(() =>
  this.formValue()
    .assignments.map((assignment) => assignment.group?.id)
    .filter((id): id is number => id != null),
);

/** Aproximado: no descuenta a quienes están en dos grupos (eso lo resuelve el backend al guardar). */
readonly totalAssigned = computed(() =>
  this.formValue().assignments.reduce((sum, assignment) => sum + (assignment.group?.membersCount ?? 0), 0),
);

// ── En prepare(), después de patchCourseForm(...) ────────────────────
// this.courseId = detail.id;
// this.assignmentInfo.set(new Map(detail.assignments.map((a) => [a.id, a])));
// y en la rama de "create": this.courseId = null; this.assignmentInfo.set(new Map());

// ── Grupos ───────────────────────────────────────────────────────────
pickGroup(index: number, group: GroupOption): void {
  const control = this.form.controls.assignments.at(index).controls.group;
  control.setValue(group);
  control.markAsDirty();
}

clearGroup(index: number): void {
  this.form.controls.assignments.at(index).controls.group.setValue(null);
}

async removeGroup(index: number): Promise<void> {
  const id = this.form.controls.assignments.at(index).controls.id.value;
  const completed = id ? (this.assignmentInfo().get(id)?.completedUsers ?? 0) : 0;

  if (completed > 0) {
    const confirmed = await confirmDanger(
      '¿Quitar este grupo del curso?',
      `${completed} ${completed === 1 ? 'persona ya finalizó' : 'personas ya finalizaron'}: su historial se conserva. ` +
        'Las pendientes dejan de tener el curso asignado.',
      'Quitar grupo',
    );
    if (!confirmed) return;
  }

  this.form.controls.assignments.removeAt(index);
  this.form.controls.assignments.markAsDirty();
}

percentDone(info: CourseAssignment): number {
  return info.totalUsers ? Math.round((info.completedUsers / info.totalUsers) * 100) : 0;
}

async sync(assignmentId: number): Promise<void> {
  if (this.form.dirty || this.courseId === null) return;

  this.syncingId.set(assignmentId);
  try {
    const result = await this.facade.syncAssignment(this.courseId, assignmentId);
    notifySuccess(
      `Grupo actualizado · ${result.added} nuevas · ${result.removedPending} pendientes quitadas` +
        (result.skippedInOtherGroups ? ` · ${result.skippedInOtherGroups} ya estaban por otro grupo` : ''),
    );

    const detail = await this.facade.loadDetail(this.courseId);
    this.assignmentInfo.set(new Map(detail.assignments.map((a) => [a.id, a])));
  } catch (e) {
    notifyError(toErrorMessage(e, 'No se pudo actualizar desde el grupo.'));
  } finally {
    this.syncingId.set(null);
  }
}

// ── En save(), reemplaza el try ──────────────────────────────────────
try {
  const result = await this.facade.save(toCourseDraft(this.form));
  notifySuccess(
    (wasEdit ? 'Curso actualizado' : 'Curso creado') +
      (result.overlappingUsers
        ? ` · ${result.overlappingUsers} ${result.overlappingUsers === 1 ? 'persona estaba' : 'personas estaban'} en dos grupos y quedaron en el primero`
        : ''),
  );
} catch (e) { … }
```

### `course-editor.component.html` ✏️ — reemplaza la sección ②

```html
<!-- ② Grupos asignados -->
<fieldset class="editor-section" formArrayName="assignments">
  <legend class="editor-section__title">
    <span class="editor-section__step">2</span> Grupos asignados
    @if (totalAssigned()) {
      <span class="editor-section__count">≈ {{ totalAssigned() }} personas</span>
    }
  </legend>
  <p class="form-text mt-0 mb-3">
    Cada grupo tiene su propia fecha límite. Al guardar, cada integrante queda asignado en estado
    <strong>Pendiente</strong>. Si alguien está en dos grupos, queda en el primero de la lista.
  </p>

  @for (assignment of form.controls.assignments.controls; track assignment; let i = $index) {
    <div class="group-card" [formGroupName]="i">
      <div class="group-card__head">
        <span class="group-card__title">Asignación {{ i + 1 }}</span>
        <button
          type="button"
          class="btn btn-sm btn-link text-danger ms-auto p-1"
          [attr.aria-label]="'Quitar asignación ' + (i + 1)"
          (click)="removeGroup(i)">
          <i class="fa-solid fa-trash-can" aria-hidden="true"></i>
        </button>
      </div>

      <div class="mb-2">
        <label class="form-label small mb-1" [for]="'group-' + i">Grupo de usuarios</label>
        @if (assignment.controls.group.value; as selected) {
          <div class="group-chip" [class.is-locked]="assignment.controls.group.disabled">
            <i class="fa-solid fa-user-group" aria-hidden="true"></i>
            <span class="group-chip__name">{{ selected.name }}</span>
            <span class="group-chip__count">{{ selected.membersCount }} personas</span>
            @if (assignment.controls.group.disabled) {
              <i
                class="fa-solid fa-lock ms-auto"
                title="Para cambiar el grupo, quita esta asignación y agrega otra."
                aria-hidden="true"></i>
            } @else {
              <button type="button" class="btn-close btn-sm ms-auto" aria-label="Cambiar grupo" (click)="clearGroup(i)"></button>
            }
          </div>
        } @else {
          <app-group-picker
            [inputId]="'group-' + i"
            [excludeIds]="selectedGroupIds()"
            [invalid]="hasError(assignment.controls.group)"
            (picked)="pickGroup(i, $event)" />
          @if (hasError(assignment.controls.group, 'required')) {
            <div class="invalid-feedback d-block">Elige el grupo.</div>
          }
        }
      </div>

      <div class="mb-2">
        <label class="form-label small mb-1" [for]="'due-' + i">Fecha límite de finalización</label>
        <input
          type="date"
          class="form-control group-card__date"
          formControlName="dueDate"
          [id]="'due-' + i"
          [min]="today()"
          [class.is-invalid]="hasError(assignment.controls.dueDate)" />
        @if (hasError(assignment.controls.dueDate, 'required')) {
          <div class="invalid-feedback d-block">Elige la fecha límite.</div>
        }
        @if (hasError(assignment.controls.dueDate, 'pastDate')) {
          <div class="invalid-feedback d-block">No puede ser una fecha pasada.</div>
        }
      </div>

      @if (assignment.controls.id.value; as assignmentId) {
        @if (assignmentInfo().get(assignmentId); as info) {
          <div class="group-progress">
            <div class="group-progress__bar" role="img" [attr.aria-label]="info.completedUsers + ' de ' + info.totalUsers + ' finalizaron'">
              <span [style.width.%]="percentDone(info)"></span>
            </div>
            <span class="small text-body-secondary">{{ info.completedUsers }} de {{ info.totalUsers }} finalizaron</span>
            <button
              type="button"
              class="btn btn-link btn-sm ms-auto p-0"
              [disabled]="form.dirty || syncingId() !== null"
              [title]="form.dirty ? 'Guarda primero los cambios' : 'Agrega a los nuevos del grupo y quita a los pendientes que salieron'"
              (click)="sync(assignmentId)">
              @if (syncingId() === assignmentId) {
                <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>
              } @else {
                <i class="fa-solid fa-rotate me-1" aria-hidden="true"></i>
              }
              Actualizar desde el grupo
            </button>
          </div>
          @if (info.groupRemoved) {
            <p class="small text-warning-emphasis mt-2 mb-0">
              <i class="fa-solid fa-triangle-exclamation me-1" aria-hidden="true"></i>
              El grupo fue eliminado; sus personas siguen asignadas.
            </p>
          }
        }
      }
    </div>
  } @empty {
    <div class="groups-empty">
      <i class="fa-solid fa-user-group" aria-hidden="true"></i>
      <span>Aún no hay grupos asignados a este curso.</span>
    </div>
  }

  @if (form.controls.assignments.hasError('duplicatedGroups')) {
    <div class="alert alert-warning py-2 small mb-3" role="alert">Ese grupo ya está en la lista.</div>
  }

  <button type="button" class="add-group" (click)="addGroup()">
    <i class="fa-solid fa-plus" aria-hidden="true"></i> Asignar grupo
  </button>
</fieldset>
```

### `course-editor.component.scss` ✏️ — estilos nuevos

```scss
.group-chip {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  border: 1px solid color-mix(in srgb, var(--cu-accent) 35%, var(--cu-border));
  border-radius: var(--cu-radius-sm);
  background: color-mix(in srgb, var(--cu-accent) 6%, var(--cu-surface));
  animation: cu-pop-in 0.25s var(--cu-ease-spring) both;

  &.is-locked {
    border-style: dashed;
    color: var(--cu-muted);
  }
}

.group-chip__name {
  font-weight: 600;
}

.group-chip__count {
  color: var(--cu-muted);
  font-size: 0.8rem;
}

.group-progress {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem 0.75rem;
  margin-top: 0.75rem;
}

.group-progress__bar {
  flex: 1 1 100%;
  height: 0.45rem;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-surface-alt);

  span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--cu-onsite);
    transition: width 0.6s var(--cu-ease-out);
  }
}
```

### Tarjeta del curso ✏️ — pie con grupos y avance

Hoy el pie dice "0 usuarios". Con grupos, la tarjeta muestra cuántos grupos tiene el curso, cuántas personas y cuántas finalizaron, y suma la acción **Seguimiento** junto a ✎ y 🗑.

```ts
// domain/course.model.ts — CourseSummary
readonly groupsCount: number;
readonly assignedCount: number;
readonly completedCount: number;

// infraestructure/course.dto.ts — CourseListItemDto
assignedGroupsCount: number;
completedUsersCount: number;

// infraestructure/course.mapper.ts — toCourseSummary
groupsCount: dto.assignedGroupsCount ?? 0,
assignedCount: dto.assignedUsersCount ?? 0,
completedCount: dto.completedUsersCount ?? 0,
```

```ts
// course-card.component.ts
readonly completedPercent = computed(() => {
  const { assignedCount, completedCount } = this.course();
  return assignedCount ? Math.round((completedCount / assignedCount) * 100) : 0;
});
```

En `course-card.component.html`, junto a los botones ✎ y 🗑 del encabezado:

```html
<a
  class="icon-btn"
  [routerLink]="['/cursos', course().id, 'seguimiento']"
  queryParamsHandling="preserve"
  [attr.aria-label]="'Seguimiento de ' + course().name"
  title="Seguimiento">
  <i class="fa-solid fa-chart-column" aria-hidden="true"></i>
</a>
```

Y el pie reemplaza al `meta-item` de asignados:

```html
<footer class="course-card__meta">
  @if (course().groupsCount) {
    <span class="meta-item">
      <i class="fa-solid fa-user-group" aria-hidden="true"></i>
      {{ course().groupsCount }} {{ course().groupsCount === 1 ? 'grupo' : 'grupos' }} ·
      {{ course().assignedCount }} {{ course().assignedCount === 1 ? 'persona' : 'personas' }}
    </span>
  } @else {
    <span class="meta-item text-body-secondary">
      <i class="fa-solid fa-user-group" aria-hidden="true"></i> Sin grupos asignados
    </span>
  }

  @if (due(); as due) {
    <span class="meta-item due" [attr.data-state]="due.state" [title]="due.date">
      <i class="fa-regular fa-clock" aria-hidden="true"></i>
      {{ due.relative }}
    </span>
  }

  @if (course().assignedCount) {
    <div class="card-progress" role="img" [attr.aria-label]="course().completedCount + ' de ' + course().assignedCount + ' finalizaron'">
      <span class="card-progress__bar"><span [style.width.%]="completedPercent()"></span></span>
      <span class="card-progress__label">{{ completedPercent() }} % finalizado</span>
    </div>
  }
</footer>
```

```scss
// course-card.component.scss
.card-progress {
  display: flex;
  flex: 1 1 100%;
  align-items: center;
  gap: 0.5rem;
}

.card-progress__bar {
  flex: 1;
  height: 0.35rem;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-surface-alt);

  span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--cu-onsite);
    transition: width 0.6s var(--cu-ease-out);
  }
}

.card-progress__label {
  color: var(--cu-muted);
  font-size: 0.72rem;
  white-space: nowrap;
}
```

> `course-card` necesita `RouterLink` en `imports`. Si `.course-card__meta` no tiene `flex-wrap: wrap`, agrégalo para que la barra baje a su propia línea.

---

## 6. Paso 3 — Seguimiento (administración)

### `application/course-progress.facade.ts`

```ts
import { Injectable, inject, signal } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { CourseRepository } from '../domain/course.repository';
import { AssignedUsersPage, AssignedUsersQuery, CourseProgress } from '../domain/course.model';

@Injectable()
export class CourseProgressFacade {
  private readonly repository = inject(CourseRepository);

  private readonly _status = signal<'loading' | 'ready' | 'error'>('loading');
  private readonly _progress = signal<CourseProgress | null>(null);
  private readonly _error = signal<string | null>(null);

  readonly status = this._status.asReadonly();
  readonly progress = this._progress.asReadonly();
  readonly error = this._error.asReadonly();

  private courseId = 0;

  async load(courseId: number): Promise<void> {
    this.courseId = courseId;
    this._status.set('loading');
    try {
      this._progress.set(await firstValueFrom(this.repository.getProgress(courseId)));
      this._status.set('ready');
    } catch (e) {
      this._error.set(toErrorMessage(e, 'No se pudo cargar el seguimiento.'));
      this._status.set('error');
    }
  }

  loadUsers(assignmentId: number, query: AssignedUsersQuery): Promise<AssignedUsersPage> {
    return firstValueFrom(this.repository.getAssignmentUsers(this.courseId, assignmentId, query));
  }
}
```

### `presentation/assignment-users/assignment-users.component.ts`

Personas de una asignación, con filtro por estado, búsqueda y paginación en el servidor.

```ts
import { ChangeDetectionStrategy, Component, computed, inject, input, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { toObservable, toSignal } from '@angular/core/rxjs-interop';
import { catchError, combineLatest, debounceTime, distinctUntilChanged, from, map, of, startWith, switchMap } from 'rxjs';
import { CourseProgressFacade } from '../../application/course-progress.facade';
import { AssignedUsersPage, CompletionStatusFilter } from '../../domain/course.model';

const PAGE_SIZE = 20;

@Component({
  selector: 'app-assignment-users',
  imports: [DatePipe],
  templateUrl: './assignment-users.component.html',
  styleUrl: './assignment-users.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AssignmentUsersComponent {
  private readonly facade = inject(CourseProgressFacade);

  readonly assignmentId = input.required<number>();

  readonly filters: readonly { id: CompletionStatusFilter; label: string }[] = [
    { id: 'ALL', label: 'Todos' },
    { id: 'PENDING', label: 'Pendientes' },
    { id: 'OVERDUE', label: 'Vencidos' },
    { id: 'COMPLETED', label: 'Finalizados' },
  ];

  readonly status = signal<CompletionStatusFilter>('ALL');
  readonly search = signal('');
  readonly page = signal(1);
  readonly loading = signal(true);

  private readonly debouncedSearch = toSignal(
    toObservable(this.search).pipe(debounceTime(350), map((v) => v.trim()), distinctUntilChanged()),
    { initialValue: '' },
  );

  readonly result = toSignal(
    combineLatest([
      toObservable(this.assignmentId),
      toObservable(this.status),
      toObservable(this.debouncedSearch),
      toObservable(this.page),
    ]).pipe(
      switchMap(([assignmentId, status, search, page]) => {
        this.loading.set(true);
        return from(this.facade.loadUsers(assignmentId, { status, search, page, pageSize: PAGE_SIZE })).pipe(
          catchError(() => of<AssignedUsersPage>({ items: [], total: 0 })),
          map((result) => {
            this.loading.set(false);
            return result;
          }),
          startWith<AssignedUsersPage | null>(null),
        );
      }),
    ),
    { initialValue: null },
  );

  readonly totalPages = computed(() => Math.max(1, Math.ceil((this.result()?.total ?? 0) / PAGE_SIZE)));

  setStatus(value: CompletionStatusFilter): void {
    this.status.set(value);
    this.page.set(1);
  }

  setSearch(value: string): void {
    this.search.set(value);
    this.page.set(1);
  }
}
```

### `assignment-users.component.html`

```html
<div class="au__toolbar">
  <div class="au__chips" role="group" aria-label="Filtrar por estado">
    @for (filter of filters; track filter.id) {
      <button
        type="button"
        class="au__chip"
        [class.is-active]="status() === filter.id"
        [attr.aria-pressed]="status() === filter.id"
        (click)="setStatus(filter.id)">
        {{ filter.label }}
      </button>
    }
  </div>
  <input
    type="search"
    class="form-control form-control-sm au__search"
    placeholder="Buscar persona"
    aria-label="Buscar persona"
    [value]="search()"
    (input)="setSearch($any($event.target).value)" />
</div>

<div class="au__wrap" [class.is-loading]="loading()" aria-live="polite" [attr.aria-busy]="loading()">
  @if (result(); as data) {
    @if (!data.items.length) {
      <p class="text-body-secondary small m-3">Nadie coincide con el filtro.</p>
    } @else {
      <table class="au">
        <caption class="visually-hidden">Personas de la asignación</caption>
        <thead>
          <tr>
            <th scope="col">Persona</th>
            <th scope="col">Gerencia</th>
            <th scope="col">Estado</th>
            <th scope="col">Finalizó</th>
          </tr>
        </thead>
        <tbody>
          @for (user of data.items; track user.email) {
            <tr>
              <td data-label="Persona">
                <strong class="d-block">{{ user.displayName }}</strong>
                <small class="text-body-secondary">{{ user.email }}</small>
              </td>
              <td data-label="Gerencia">{{ user.management ?? '—' }}</td>
              <td data-label="Estado">
                @if (user.status === 'COMPLETED') {
                  <span class="au__pill" data-tone="done"><i class="fa-solid fa-check" aria-hidden="true"></i> Finalizado</span>
                } @else if (user.isOverdue) {
                  <span class="au__pill" data-tone="late"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i> Vencido</span>
                } @else {
                  <span class="au__pill" data-tone="pending"><i class="fa-regular fa-clock" aria-hidden="true"></i> Pendiente</span>
                }
              </td>
              <td data-label="Finalizó">{{ user.completedDate ? (user.completedDate | date: 'd MMM y') : '—' }}</td>
            </tr>
          }
        </tbody>
      </table>
    }

    @if (totalPages() > 1) {
      <nav class="au__pager" aria-label="Paginación de personas">
        <button type="button" class="au__pager-btn" aria-label="Página anterior" [disabled]="page() <= 1" (click)="page.set(page() - 1)">
          <i class="fa-solid fa-chevron-left" aria-hidden="true"></i>
        </button>
        <span class="small">Página {{ page() }} de {{ totalPages() }} · {{ data.total }} personas</span>
        <button type="button" class="au__pager-btn" aria-label="Página siguiente" [disabled]="page() >= totalPages()" (click)="page.set(page() + 1)">
          <i class="fa-solid fa-chevron-right" aria-hidden="true"></i>
        </button>
      </nav>
    }
  } @else {
    <div class="au__skeleton" aria-hidden="true"><span></span><span></span><span></span></div>
  }
</div>
```

> El resultado se llama `data` en la plantilla y no `page`: un alias con el mismo nombre taparía a la signal `page()` dentro del bloque.

### `assignment-users.component.scss`

```scss
.au__toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  margin: 1rem 0 0.75rem;
}

.au__search {
  max-width: 16rem;
}

// Pastillas como los filtros "Todas / Virtual / Presencial" de Cursos.
.au__chips {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 0.25rem;
}

.au__chip {
  padding: 0.3rem 0.85rem;
  border: 1px solid transparent;
  border-radius: 999px;
  background: transparent;
  color: var(--cu-muted);
  font-size: 0.8rem;
  font-weight: 600;
  transition: background-color 0.2s ease, color 0.2s ease;

  &:hover {
    color: var(--cu-text);
  }

  &.is-active {
    border-color: color-mix(in srgb, var(--cu-accent) 45%, transparent);
    background: color-mix(in srgb, var(--cu-accent) 14%, transparent);
    color: color-mix(in srgb, var(--cu-accent) 80%, var(--cu-text));
  }
}

.au__wrap {
  overflow-x: auto;
  // Sin esto, overflow-x convierte overflow-y en auto y aparece un scroll vertical
  // con pocas filas (el mismo detalle que se ve hoy en el listado de grupos).
  overflow-y: hidden;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-sm);
  transition: opacity 0.2s ease;

  &.is-loading {
    opacity: 0.6;
  }
}

.au {
  width: 100%;
  font-size: 0.875rem;

  th {
    padding: 0.6rem 0.75rem;
    background: var(--cu-accent);
    color: var(--cu-on-accent);
    font-size: 0.72rem;
    font-weight: 700;
    text-align: left;
    letter-spacing: 0.05em;
    text-transform: uppercase;
  }

  td {
    padding: 0.55rem 0.75rem;
    border-top: 1px solid var(--cu-border);
  }
}

.au__pill {
  --tone: var(--cu-muted);

  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.15rem 0.55rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 14%, transparent);
  color: color-mix(in srgb, var(--tone) 75%, var(--cu-text));
  font-size: 0.75rem;
  font-weight: 600;

  &[data-tone='done'] { --tone: var(--cu-onsite); }
  &[data-tone='late'] { --tone: var(--cu-danger); }
  &[data-tone='pending'] { --tone: var(--cu-warning); }
}

.au__pager {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  padding: 0.75rem;
  color: var(--cu-muted);
}

// Flechas sin borde, como la paginación del listado de grupos.
.au__pager-btn {
  padding: 0.25rem 0.5rem;
  border: 0;
  border-radius: 999px;
  background: transparent;
  color: var(--cu-text);
  transition: background-color 0.15s ease;

  &:hover:not(:disabled) {
    background: color-mix(in srgb, var(--cu-accent) 14%, transparent);
  }

  &:disabled {
    color: var(--cu-border);
  }
}

.au__skeleton {
  display: grid;
  gap: 0.5rem;
  padding: 0.75rem;

  span {
    height: 2.25rem;
    border-radius: 0.5rem;
    background: var(--cu-surface-alt);
    animation: au-pulse 1.2s ease-in-out infinite alternate;
  }
}

@keyframes au-pulse {
  to { opacity: 0.5; }
}

@media (max-width: 767.98px) {
  .au thead { display: none; }
  .au tr { display: block; padding: 0.5rem 0.75rem; border-top: 1px solid var(--cu-border); }
  .au td {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.2rem 0;
    border: 0;

    &::before {
      content: attr(data-label);
      color: var(--cu-muted);
      font-size: 0.75rem;
      font-weight: 600;
    }
  }
}

@media (prefers-reduced-motion: reduce) {
  .au__skeleton span { animation: none; }
}
```

### `presentation/course-progress-page/course-progress-page.component.ts`

```ts
import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { DatePipe, DecimalPipe } from '@angular/common';
import { CourseProgressFacade } from '../../application/course-progress.facade';
import { AssignmentProgress } from '../../domain/course.model';
import { COURSES_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/courses.providers';
import { AssignmentUsersComponent } from '../assignment-users/assignment-users.component';

@Component({
  selector: 'app-course-progress-page',
  imports: [RouterLink, DatePipe, DecimalPipe, AssignmentUsersComponent],
  providers: [...COURSES_INFRASTRUCTURE_PROVIDERS, CourseProgressFacade],
  templateUrl: './course-progress-page.component.html',
  styleUrl: './course-progress-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CourseProgressPageComponent {
  protected readonly facade = inject(CourseProgressFacade);

  readonly scores = [5, 4, 3, 2, 1, 0];
  readonly expanded = signal<ReadonlySet<number>>(new Set());

  constructor() {
    void this.facade.load(Number(inject(ActivatedRoute).snapshot.paramMap.get('id')));
  }

  toggle(assignmentId: number): void {
    this.expanded.update((current) => {
      const next = new Set(current);
      if (!next.delete(assignmentId)) next.add(assignmentId);
      return next;
    });
  }

  percent(assignment: AssignmentProgress): number {
    return assignment.total ? Math.round((assignment.completed / assignment.total) * 100) : 0;
  }

  /** Ancho de cada barra de la distribución, relativo a la más alta. */
  barWidth(distribution: readonly number[] | null, score: number): number {
    if (!distribution) return 0;
    const max = Math.max(...distribution, 1);
    return Math.round((distribution[score] / max) * 100);
  }

  starFill(average: number | null): string {
    return `${((average ?? 0) / 5) * 100}%`;
  }
}
```

### `course-progress-page.component.html`

```html
<section class="cp">
  <a routerLink="/cursos" queryParamsHandling="preserve" class="cp__back">
    <i class="fa-solid fa-arrow-left me-1" aria-hidden="true"></i> Cursos
  </a>

  @switch (facade.status()) {
    @case ('loading') {
      <div class="cp__skeleton" aria-hidden="true"><span></span><span></span></div>
    }
    @case ('error') {
      <div class="alert alert-danger" role="alert">{{ facade.error() }}</div>
    }
    @default {
      @if (facade.progress(); as progress) {
        <h1 class="cp__title">{{ progress.courseName }}</h1>
        <p class="cp__subtitle">Seguimiento del curso</p>

        <!-- ── Calificaciones anónimas ─────────────────────────────── -->
        <section class="cp-card" aria-labelledby="cp-ratings-title">
          <h2 id="cp-ratings-title" class="cp-card__title">
            Calificaciones
            <span class="cp__anon"><i class="fa-solid fa-user-secret" aria-hidden="true"></i> Anónimas</span>
            <span class="cp__count">{{ progress.ratings.responses }} {{ progress.ratings.responses === 1 ? 'respuesta' : 'respuestas' }}</span>
          </h2>

          @if (!progress.ratings.visible) {
            <p class="text-body-secondary mb-0">
              Los promedios se muestran cuando haya al menos {{ progress.ratings.minimumResponses }} respuestas.
              Así nadie puede deducir qué calificó cada persona.
            </p>
          } @else {
            <div class="row g-4">
              @for (metric of [
                { label: 'Satisfacción', average: progress.ratings.satisfactionAverage, distribution: progress.ratings.satisfactionDistribution },
                { label: 'Utilidad', average: progress.ratings.usefulnessAverage, distribution: progress.ratings.usefulnessDistribution }
              ]; track metric.label) {
                <div class="col-12 col-md-6">
                  <div class="cp__metric">
                    <span class="cp__metric-label">{{ metric.label }}</span>
                    <span class="cp__metric-value">{{ metric.average | number: '1.1-1' }}</span>
                    <span class="cp__stars" [style.--fill]="starFill(metric.average)" aria-hidden="true">★★★★★</span>
                  </div>
                  <ul class="cp__dist" [attr.aria-label]="'Distribución de ' + metric.label">
                    @for (score of scores; track score) {
                      <li>
                        <span class="cp__dist-score">{{ score }}</span>
                        <span class="cp__dist-bar"><span [style.width.%]="barWidth(metric.distribution, score)"></span></span>
                        <span class="cp__dist-count">{{ metric.distribution?.[score] ?? 0 }}</span>
                      </li>
                    }
                  </ul>
                </div>
              }
            </div>
          }
        </section>

        <!-- ── Avance por grupo ────────────────────────────────────── -->
        @for (assignment of progress.assignments; track assignment.id; let i = $index) {
          <section class="cp-card cp-assignment" [style.--i]="i">
            <div class="cp-assignment__head">
              <div>
                <h2 class="cp-card__title mb-1">{{ assignment.groupName }}</h2>
                <span class="text-body-secondary small">Fecha límite {{ assignment.dueDate | date: 'd MMM y' }}</span>
              </div>
              <button
                type="button"
                class="btn btn-sm btn-outline-secondary"
                [attr.aria-expanded]="expanded().has(assignment.id)"
                (click)="toggle(assignment.id)">
                {{ expanded().has(assignment.id) ? 'Ocultar personas' : 'Ver personas' }}
              </button>
            </div>

            <div class="cp-progress" role="img" [attr.aria-label]="assignment.completed + ' de ' + assignment.total + ' finalizaron'">
              <span [style.width.%]="percent(assignment)"></span>
            </div>
            <p class="small mb-0">
              <strong>{{ assignment.completed }}</strong> de {{ assignment.total }} finalizaron ({{ percent(assignment) }} %)
              @if (assignment.overdue) {
                · <span class="text-danger fw-semibold">{{ assignment.overdue }} vencidos</span>
              }
            </p>

            @if (expanded().has(assignment.id)) {
              <app-assignment-users [assignmentId]="assignment.id" />
            }
          </section>
        } @empty {
          <p class="text-body-secondary">Este curso aún no tiene grupos asignados.</p>
        }
      }
    }
  }
</section>
```

> El `@for` con un arreglo literal en la plantilla funciona en Angular 17+. Si tu versión se queja, arma ese arreglo como un `computed` en el componente.

### `course-progress-page.component.scss`

```scss
@use '@shared-styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
  padding: 1.5rem 0;
}

.cp__back {
  color: var(--cu-muted);
  font-size: 0.875rem;
  text-decoration: none;
}

.cp__title {
  margin: 0.5rem 0 0;
  font-size: 1.75rem;
  font-weight: 700;
}

.cp__subtitle {
  margin: 0 0 1.25rem;
  color: var(--cu-muted);
}

.cp-card {
  margin-bottom: 1rem;
  padding: 1.25rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow);
  animation: cp-rise 0.35s var(--cu-ease-out) both;
  animation-delay: calc(min(var(--i, 0), 6) * 60ms);
}

.cp-card__title {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0 1rem;
  font-size: 1.05rem;
  font-weight: 700;
}

.cp__anon,
.cp__count {
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
  background: var(--cu-surface-alt);
  color: var(--cu-muted);
  font-size: 0.75rem;
  font-weight: 600;
}

.cp__metric {
  display: flex;
  align-items: baseline;
  gap: 0.75rem;
  margin-bottom: 0.75rem;
}

.cp__metric-label {
  font-weight: 600;
}

.cp__metric-value {
  font-size: 2rem;
  font-weight: 800;
  line-height: 1;
}

// Estrellas parciales: un 4,3 llena el 86 %.
.cp__stars {
  position: relative;
  display: inline-block;
  color: var(--bs-border-color);
  font-size: 1.35rem;
  letter-spacing: 0.1em;

  &::before {
    content: '★★★★★';
    position: absolute;
    inset: 0;
    width: var(--fill, 0%);
    overflow: hidden;
    color: var(--cu-accent);
    white-space: nowrap;
  }
}

.cp__dist {
  display: grid;
  gap: 0.3rem;
  margin: 0;
  padding: 0;
  list-style: none;

  li {
    display: grid;
    grid-template-columns: 1.25rem 1fr 2.5rem;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.8rem;
  }
}

.cp__dist-bar {
  height: 0.5rem;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-surface-alt);

  span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--cu-accent);
    transition: width 0.6s var(--cu-ease-out);
  }
}

.cp__dist-count {
  color: var(--cu-muted);
  text-align: right;
}

.cp-assignment__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
}

.cp-progress {
  height: 0.6rem;
  margin: 0.75rem 0 0.5rem;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-surface-alt);

  span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--cu-onsite);
    transition: width 0.6s var(--cu-ease-out);
  }
}

.cp__skeleton span {
  display: block;
  height: 10rem;
  margin-bottom: 1rem;
  border-radius: var(--cu-radius);
  background: var(--cu-surface-alt);
}

@keyframes cp-rise {
  from {
    opacity: 0;
    transform: translateY(8px);
  }
}

@media (prefers-reduced-motion: reduce) {
  .cp-card { animation: none; }
  .cp-progress span,
  .cp__dist-bar span { transition: none; }
}
```

Si usas el listado en tabla ([listado-cursos-angular.md](listado-cursos-angular.md)) en lugar de tarjetas, la acción **Seguimiento** va en la columna de acciones:

```html
<a
  class="action-btn"
  [routerLink]="['/cursos', row.course.id, 'seguimiento']"
  queryParamsHandling="preserve"
  [attr.aria-label]="'Seguimiento de ' + row.course.name"
  title="Seguimiento">
  <i class="fa-solid fa-chart-column" aria-hidden="true"></i>
</a>
```

---

## 7. Paso 4 — Feature "Mis cursos"

### `domain/my-course.model.ts`

```ts
export type CompletionStatus = 'PENDING' | 'COMPLETED';
export type CourseModalityCode = 'VIRTUAL' | 'PRESENCIAL';

export interface MyCourse {
  readonly assignmentUserId: number;
  readonly courseId: number;
  readonly courseName: string;
  readonly modality: CourseModalityCode;
  /** yyyy-MM-dd */
  readonly dueDate: string;
  readonly status: CompletionStatus;
  /** ISO 8601 */
  readonly completedDate: string | null;
  readonly isOverdue: boolean;
}

export interface CompletionForm {
  readonly assignmentUserId: number;
  readonly courseName: string;
  readonly modality: CourseModalityCode;
  readonly dueDate: string;
  readonly status: CompletionStatus;
  readonly completedDate: string | null;
  readonly isOverdue: boolean;
  readonly userDisplayName: string;
  readonly userEmail: string;
  /** Del directorio activo. null = no se pudo consultar. */
  readonly management: string | null;
}

export interface CompletionRatings {
  readonly satisfaction: number;
  readonly usefulness: number;
}

/** Etiqueta e ícono por modalidad. Se repite aquí para no depender de la feature de cursos. */
export const MODALITY_VIEW: Record<CourseModalityCode, { readonly label: string; readonly icon: string }> = {
  VIRTUAL: { label: 'Virtual', icon: 'fa-laptop' },
  PRESENCIAL: { label: 'Presencial', icon: 'fa-chalkboard-user' },
};
```

### `domain/my-courses.repository.ts`

```ts
import { Observable } from 'rxjs';
import { CompletionForm, CompletionRatings, MyCourse } from './my-course.model';

export abstract class MyCoursesRepository {
  abstract list(): Observable<MyCourse[]>;
  abstract getForm(assignmentUserId: number): Observable<CompletionForm>;
  /** Devuelve la fecha de finalización (ISO). */
  abstract complete(assignmentUserId: number, ratings: CompletionRatings): Observable<string>;
}
```

### `infraestructure/my-course.dto.ts`, `my-course.mapper.ts` y `my-courses.service.ts`

```ts
// my-course.dto.ts
export interface MyCourseDto {
  assignmentUserId: number;
  courseId: number;
  courseName: string;
  modality: string;
  dueDate: string;
  status: string;
  completedDate: string | null;
  isOverdue: boolean;
}

export interface CompletionFormDto extends Omit<MyCourseDto, 'courseId'> {
  userDisplayName: string;
  userEmail: string;
  management: string | null;
}
```

```ts
// my-course.mapper.ts
import { CompletionForm, CompletionStatus, CourseModalityCode, MyCourse } from '../domain/my-course.model';
import { CompletionFormDto, MyCourseDto } from './my-course.dto';

const toStatus = (value: string): CompletionStatus => (value === 'COMPLETED' ? 'COMPLETED' : 'PENDING');
const toModality = (value: string): CourseModalityCode => (value === 'PRESENCIAL' ? 'PRESENCIAL' : 'VIRTUAL');

export function toMyCourse(dto: MyCourseDto): MyCourse {
  return { ...dto, modality: toModality(dto.modality), status: toStatus(dto.status), dueDate: dto.dueDate.slice(0, 10) };
}

export function toCompletionForm(dto: CompletionFormDto): CompletionForm {
  return {
    ...dto,
    modality: toModality(dto.modality),
    status: toStatus(dto.status),
    dueDate: dto.dueDate.slice(0, 10),
    management: dto.management?.trim() || null,
  };
}
```

```ts
// my-courses.service.ts
import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, unwrap } from '@shared/utils/api-response';
import { MyCoursesRepository } from '../domain/my-courses.repository';
import { CompletionForm, CompletionRatings, MyCourse } from '../domain/my-course.model';
import { CompletionFormDto, MyCourseDto } from './my-course.dto';
import { toCompletionForm, toMyCourse } from './my-course.mapper';

@Injectable({ providedIn: 'root' })
export class MyCoursesService implements MyCoursesRepository {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/api/my-courses`;

  list(): Observable<MyCourse[]> {
    return this.http.get<ApiResponse<MyCourseDto[]>>(this.baseUrl).pipe(map(unwrap), map((items) => items.map(toMyCourse)));
  }

  getForm(id: number): Observable<CompletionForm> {
    return this.http
      .get<ApiResponse<CompletionFormDto>>(`${this.baseUrl}/${id}/completion-form`)
      .pipe(map(unwrap), map(toCompletionForm));
  }

  complete(id: number, ratings: CompletionRatings): Observable<string> {
    return this.http
      .post<ApiResponse<{ completedDate: string }>>(`${this.baseUrl}/${id}/complete`, ratings)
      .pipe(map(unwrap), map((result) => result.completedDate));
  }
}
```

```ts
// my-courses.providers.ts
export const MY_COURSES_INFRASTRUCTURE_PROVIDERS: Provider[] = [
  { provide: MyCoursesRepository, useExisting: MyCoursesService },
];
```

### `application/my-courses.facade.ts`

```ts
import { Injectable, computed, inject, signal } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { MyCoursesRepository } from '../domain/my-courses.repository';
import { CompletionStatus, MyCourse } from '../domain/my-course.model';

@Injectable()
export class MyCoursesFacade {
  private readonly repository = inject(MyCoursesRepository);

  private readonly _status = signal<'loading' | 'ready' | 'error'>('loading');
  private readonly _error = signal<string | null>(null);
  private readonly _items = signal<readonly MyCourse[]>([]);
  private readonly _tab = signal<CompletionStatus>('PENDING');

  readonly status = this._status.asReadonly();
  readonly error = this._error.asReadonly();
  readonly tab = this._tab.asReadonly();

  readonly counts = computed(() => {
    const items = this._items();
    const pending = items.filter((c) => c.status === 'PENDING').length;
    const overdue = items.filter((c) => c.status === 'PENDING' && c.isOverdue).length;
    return { pending, overdue, completed: items.length - pending };
  });

  readonly visible = computed(() => this._items().filter((c) => c.status === this._tab()));

  async load(): Promise<void> {
    this._status.set('loading');
    try {
      const items = await firstValueFrom(this.repository.list());
      this._items.set(items);
      // Si no tiene pendientes, abre directo en "Finalizados".
      if (!items.some((c) => c.status === 'PENDING') && items.length) this._tab.set('COMPLETED');
      this._status.set('ready');
    } catch (e) {
      this._error.set(toErrorMessage(e, 'No se pudieron cargar tus cursos.'));
      this._status.set('error');
    }
  }

  selectTab(tab: CompletionStatus): void {
    this._tab.set(tab);
  }
}
```

### `application/completion-form.facade.ts`

```ts
import { Injectable, inject, signal } from '@angular/core';
import { HttpErrorResponse } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { MyCoursesRepository } from '../domain/my-courses.repository';
import { CompletionForm, CompletionRatings } from '../domain/my-course.model';

export type FormStatus = 'loading' | 'ready' | 'not-found' | 'error';

@Injectable()
export class CompletionFormFacade {
  private readonly repository = inject(MyCoursesRepository);

  private readonly _status = signal<FormStatus>('loading');
  private readonly _form = signal<CompletionForm | null>(null);
  private readonly _error = signal<string | null>(null);
  private readonly _submitting = signal(false);
  private readonly _justCompleted = signal(false);

  readonly status = this._status.asReadonly();
  readonly form = this._form.asReadonly();
  readonly error = this._error.asReadonly();
  readonly submitting = this._submitting.asReadonly();
  /** true solo en la sesión en que se envió: muestra la animación de éxito. */
  readonly justCompleted = this._justCompleted.asReadonly();

  private id = 0;

  async load(id: number): Promise<void> {
    this.id = id;
    this._status.set('loading');
    try {
      this._form.set(await firstValueFrom(this.repository.getForm(id)));
      this._status.set('ready');
    } catch (e) {
      this._status.set(e instanceof HttpErrorResponse && e.status === 404 ? 'not-found' : 'error');
      this._error.set(toErrorMessage(e, 'No se pudo cargar el formulario.'));
    }
  }

  /** true si quedó finalizado. Si ya lo estaba (409), recarga y lo muestra así. */
  async complete(ratings: CompletionRatings): Promise<boolean> {
    this._submitting.set(true);
    try {
      const completedDate = await firstValueFrom(this.repository.complete(this.id, ratings));
      this._form.update((form) => (form ? { ...form, status: 'COMPLETED', completedDate, isOverdue: false } : form));
      this._justCompleted.set(true);
      return true;
    } catch (e) {
      if (e instanceof HttpErrorResponse && e.status === 409) {
        await this.load(this.id);
        return false;
      }
      throw e;
    } finally {
      this._submitting.set(false);
    }
  }
}
```

### `presentation/my-courses-page/my-courses-page.component.ts`

```ts
import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { RouterLink } from '@angular/router';
import { DatePipe } from '@angular/common';
import { describeDue } from '@shared/utils/due-date';
import { MyCoursesFacade } from '../../application/my-courses.facade';
import { MODALITY_VIEW, MyCourse } from '../../domain/my-course.model';
import { MY_COURSES_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/my-courses.providers';

@Component({
  selector: 'app-my-courses-page',
  imports: [RouterLink, DatePipe],
  providers: [...MY_COURSES_INFRASTRUCTURE_PROVIDERS, MyCoursesFacade],
  templateUrl: './my-courses-page.component.html',
  styleUrl: './my-courses-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class MyCoursesPageComponent {
  protected readonly facade = inject(MyCoursesFacade);
  readonly modality = MODALITY_VIEW;

  constructor() {
    void this.facade.load();
  }

  due(course: MyCourse) {
    return describeDue(course.dueDate);
  }
}
```

### `my-courses-page.component.html`

```html
<section class="mc">
  <!-- Mismo encabezado que Cursos: hero con eyebrow y tiles de indicadores. -->
  <header class="mc-hero mb-3">
    <p class="mc-hero__eyebrow">Formación</p>
    <h1 class="h3 mb-1">Mis cursos</h1>
    <p class="text-body-secondary mb-0">Marca como finalizado cada curso cuando lo termines.</p>

    <div class="mc-stats" role="tablist" aria-label="Estado de los cursos">
      <button
        type="button"
        role="tab"
        class="mc-stat"
        data-tone="accent"
        [class.is-active]="facade.tab() === 'PENDING'"
        [attr.aria-selected]="facade.tab() === 'PENDING'"
        (click)="facade.selectTab('PENDING')">
        <span class="mc-stat__icon"><i class="fa-regular fa-hourglass-half" aria-hidden="true"></i></span>
        <span class="mc-stat__value">{{ facade.counts().pending }}</span>
        <span class="mc-stat__label">Pendientes</span>
      </button>
      <button
        type="button"
        role="tab"
        class="mc-stat"
        data-tone="done"
        [class.is-active]="facade.tab() === 'COMPLETED'"
        [attr.aria-selected]="facade.tab() === 'COMPLETED'"
        (click)="facade.selectTab('COMPLETED')">
        <span class="mc-stat__icon"><i class="fa-solid fa-check" aria-hidden="true"></i></span>
        <span class="mc-stat__value">{{ facade.counts().completed }}</span>
        <span class="mc-stat__label">Finalizados</span>
      </button>
      @if (facade.counts().overdue) {
        <!-- Informativo: los vencidos están dentro de "Pendientes". -->
        <div class="mc-stat is-static" data-tone="late">
          <span class="mc-stat__icon"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i></span>
          <span class="mc-stat__value">{{ facade.counts().overdue }}</span>
          <span class="mc-stat__label">Vencidos</span>
        </div>
      }
    </div>
  </header>

  @switch (facade.status()) {
    @case ('loading') {
      <div class="mc__grid" aria-hidden="true">
        @for (i of [0, 1, 2]; track i) { <div class="mc__skeleton"></div> }
      </div>
    }
    @case ('error') {
      <div class="alert alert-danger d-flex justify-content-between align-items-center" role="alert">
        {{ facade.error() }}
        <button type="button" class="btn btn-sm btn-outline-danger" (click)="facade.load()">Reintentar</button>
      </div>
    }
    @default {
      @if (!facade.visible().length) {
        <div class="mc__empty">
          @if (facade.tab() === 'PENDING') {
            <span class="mc__empty-icon"><i class="fa-solid fa-check" aria-hidden="true"></i></span>
            <p class="fw-semibold mb-1">¡No tienes cursos pendientes!</p>
            <p class="text-body-secondary small mb-0">Cuando te asignen uno, aparecerá aquí.</p>
          } @else {
            <p class="text-body-secondary mb-0">Aún no has finalizado ningún curso.</p>
          }
        </div>
      } @else {
        <div class="mc__grid">
          @for (course of facade.visible(); track course.assignmentUserId; let i = $index) {
            <article class="mc-card" [attr.data-state]="course.status === 'COMPLETED' ? 'done' : (due(course)?.state ?? 'ok')" [style.--i]="i">
              <div class="mc-card__top">
                <span class="mc-card__modality">
                  <i class="fa-solid {{ modality[course.modality].icon }}" aria-hidden="true"></i>
                  {{ modality[course.modality].label }}
                </span>
                @if (course.status === 'COMPLETED') {
                  <span class="mc-card__status" data-tone="done"><i class="fa-solid fa-check" aria-hidden="true"></i> Finalizado</span>
                } @else if (course.isOverdue) {
                  <span class="mc-card__status" data-tone="late"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i> Vencido</span>
                } @else if (due(course); as dueInfo) {
                  <span class="mc-card__status" [attr.data-tone]="dueInfo.state === 'soon' ? 'soon' : 'pending'">
                    <i class="fa-regular fa-clock" aria-hidden="true"></i> {{ dueInfo.relative }}
                  </span>
                }
              </div>

              <h2 class="mc-card__name">{{ course.courseName }}</h2>

              @if (course.status === 'COMPLETED') {
                <p class="mc-card__meta">Finalizado el {{ course.completedDate | date: "d 'de' MMMM 'de' y" }}</p>
              } @else {
                <p class="mc-card__meta">Fecha límite: {{ due(course)?.date }}</p>
                <a class="btn btn-accent mc-card__cta" [routerLink]="['/mis-cursos', course.assignmentUserId, 'finalizar']">
                  <i class="fa-solid fa-check me-1" aria-hidden="true"></i> Marcar como finalizado
                </a>
              }
            </article>
          }
        </div>
      }
    }
  }
</section>
```

### `my-courses-page.component.scss`

```scss
@use '@shared-styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
  padding: 1.5rem 0;
}

// ── Encabezado: el mismo lenguaje que .courses-hero y .stat de Cursos ─────
.mc-hero {
  padding: 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background:
    radial-gradient(90% 140% at 0% 0%, color-mix(in srgb, var(--cu-accent) 13%, transparent), transparent 55%),
    var(--cu-surface);
  box-shadow: var(--cu-shadow);
}

.mc-hero__eyebrow {
  margin: 0 0 0.25rem;
  color: var(--cu-accent);
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.mc-stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
  gap: 0.75rem;
  margin-top: 1.25rem;
}

.mc-stat {
  --tone: var(--cu-accent);

  display: grid;
  grid-template-columns: auto 1fr;
  grid-template-rows: auto auto;
  column-gap: 0.75rem;
  align-items: center;
  padding: 0.75rem 1rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-sm);
  background: var(--cu-surface);
  text-align: left;
  transition: border-color 0.2s ease, box-shadow 0.2s ease, transform 0.2s var(--cu-ease-out);

  &[data-tone='done'] { --tone: var(--cu-onsite); }
  &[data-tone='late'] { --tone: var(--cu-danger); }

  &:not(.is-static):hover { transform: translateY(-2px); box-shadow: var(--cu-shadow); }

  // Seleccionado: borde del tono, como el tile "Total" de Cursos.
  &.is-active { border-color: var(--tone); box-shadow: var(--cu-shadow); }
}

.mc-stat__icon {
  display: inline-grid;
  grid-row: span 2;
  place-items: center;
  width: 2.25rem;
  height: 2.25rem;
  border-radius: 0.5rem;
  background: color-mix(in srgb, var(--tone) 16%, transparent);
  color: color-mix(in srgb, var(--tone) 80%, var(--cu-text));
}

.mc-stat__value { font-size: 1.35rem; font-weight: 800; line-height: 1.1; }
.mc-stat__label { color: var(--cu-muted); font-size: 0.75rem; }

.mc__grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(18rem, 1fr));
  gap: 1rem;
}

.mc-card {
  --tone: var(--cu-accent);

  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 1.1rem 1.1rem 1rem 1.3rem;
  border: 1px solid var(--cu-border);
  border-left: 4px solid var(--tone);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow);
  animation: mc-rise 0.4s var(--cu-ease-spring) both;
  animation-delay: calc(min(var(--i, 0), 8) * 45ms);
  transition: transform 0.25s var(--cu-ease-out), box-shadow 0.25s ease;

  &:hover { transform: translateY(-3px); box-shadow: var(--cu-shadow-lift); }

  &[data-state='soon'] { --tone: var(--cu-warning); }
  &[data-state='overdue'] { --tone: var(--cu-danger); }
  &[data-state='done'] { --tone: var(--cu-onsite); }
}

.mc-card__top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
}

.mc-card__modality {
  color: var(--cu-muted);
  font-size: 0.72rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.mc-card__status {
  --tone: var(--cu-muted);

  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.15rem 0.55rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 14%, transparent);
  color: color-mix(in srgb, var(--tone) 75%, var(--cu-text));
  font-size: 0.75rem;
  font-weight: 600;

  &[data-tone='done'] { --tone: var(--cu-onsite); }
  &[data-tone='late'] { --tone: var(--cu-danger); }
  &[data-tone='soon'] { --tone: var(--cu-warning); }
}

.mc-card__name { margin: 0; font-size: 1.1rem; font-weight: 700; }
.mc-card__meta { margin: 0; color: var(--cu-muted); font-size: 0.85rem; }
.mc-card__cta { align-self: flex-start; margin-top: 0.5rem; }

.mc__empty {
  display: grid;
  justify-items: center;
  gap: 0.25rem;
  padding: 3rem 1rem;
  text-align: center;
}

.mc__empty-icon {
  display: inline-grid;
  place-items: center;
  width: 3.5rem;
  height: 3.5rem;
  margin-bottom: 0.5rem;
  border-radius: 50%;
  background: color-mix(in srgb, var(--cu-onsite) 15%, transparent);
  color: var(--cu-onsite);
  font-size: 1.4rem;
}

.mc__skeleton {
  height: 9rem;
  border-radius: var(--cu-radius);
  background: var(--cu-surface-alt);
  animation: mc-pulse 1.2s ease-in-out infinite alternate;
}

@keyframes mc-rise { from { opacity: 0; transform: translateY(10px); } }
@keyframes mc-pulse { to { opacity: 0.5; } }

@media (prefers-reduced-motion: reduce) {
  .mc-card, .mc__skeleton { animation: none; }
  .mc-card:hover, .mc-stat:hover { transform: none; }
}
```

> Los tokens salen de `@shared-styles/courses-tokens` (paso 1). El encabezado repite a propósito el lenguaje de `.courses-hero` y `.stat` de Cursos: si prefieres no duplicarlo, sácalo a un parcial `@shared-styles/_page-hero.scss` y úsalo en las dos páginas.

### `presentation/completion-form-page/completion-form-page.component.ts` — ⭐ el formulario

```ts
import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { DatePipe } from '@angular/common';
import { toErrorMessage } from '@shared/utils/api-response';
import { confirmDanger, notifyError } from '@shared/utils/feedback';
import { describeDue } from '@shared/utils/due-date';
import {
  SATISFACTION_LABELS,
  StarRatingComponent,
  USEFULNESS_LABELS,
} from '@shared/components/star-rating/star-rating.component';
import { CompletionFormFacade } from '../../application/completion-form.facade';
import { MODALITY_VIEW } from '../../domain/my-course.model';
import { MY_COURSES_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/my-courses.providers';

@Component({
  selector: 'app-completion-form-page',
  imports: [RouterLink, DatePipe, StarRatingComponent],
  providers: [...MY_COURSES_INFRASTRUCTURE_PROVIDERS, CompletionFormFacade],
  templateUrl: './completion-form-page.component.html',
  styleUrl: './completion-form-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CompletionFormPageComponent {
  protected readonly facade = inject(CompletionFormFacade);

  readonly modality = MODALITY_VIEW;
  readonly satisfactionLabels = SATISFACTION_LABELS;
  readonly usefulnessLabels = USEFULNESS_LABELS;

  /** Empiezan sin valor: el 0 hay que elegirlo, no llega por omisión. */
  readonly satisfaction = signal<number | null>(null);
  readonly usefulness = signal<number | null>(null);
  readonly submitted = signal(false);

  readonly dueInfo = computed(() => {
    const form = this.facade.form();
    return form ? describeDue(form.dueDate) : null;
  });

  readonly isComplete = computed(() => this.satisfaction() !== null && this.usefulness() !== null);

  constructor() {
    void this.facade.load(Number(inject(ActivatedRoute).snapshot.paramMap.get('id')));
  }

  async submit(): Promise<void> {
    this.submitted.set(true);
    if (!this.isComplete() || this.facade.submitting()) return;

    const confirmed = await confirmDanger(
      '¿Marcar el curso como finalizado?',
      'Después de enviarlo no podrás cambiar tus respuestas.',
      'Sí, finalizar',
    );
    if (!confirmed) return;

    try {
      await this.facade.complete({ satisfaction: this.satisfaction()!, usefulness: this.usefulness()! });
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudo enviar el formulario. Intenta de nuevo.'));
    }
  }
}
```

### `completion-form-page.component.html`

```html
<section class="cf">
  <a routerLink="/mis-cursos" class="cf__back">
    <i class="fa-solid fa-arrow-left me-1" aria-hidden="true"></i> Mis cursos
  </a>

  @switch (facade.status()) {
    @case ('loading') {
      <div class="cf-card cf__skeleton" aria-hidden="true"><span></span><span></span><span></span></div>
      <span class="visually-hidden" role="status">Cargando formulario…</span>
    }

    @case ('not-found') {
      <div class="cf-card text-center">
        <p class="fw-semibold mb-1">No encontramos este curso entre tus asignaciones.</p>
        <a routerLink="/mis-cursos" class="btn btn-outline-primary btn-sm mt-2">Ver mis cursos</a>
      </div>
    }

    @case ('error') {
      <div class="alert alert-danger" role="alert">{{ facade.error() }}</div>
    }

    @default {
      @if (facade.form(); as form) {
        <!-- ── Encabezado ─────────────────────────────────────────────── -->
        <header class="cf__head">
          <p class="cf__eyebrow">
            <i class="fa-solid {{ modality[form.modality].icon }}" aria-hidden="true"></i>
            {{ modality[form.modality].label }} · Fecha límite {{ dueInfo()?.date }}
            @if (form.status === 'PENDING') {
              <span class="cf__due" [attr.data-state]="dueInfo()?.state">{{ dueInfo()?.relative }}</span>
            }
          </p>
          <h1 class="cf__title">{{ form.courseName }}</h1>
          <p class="cf__subtitle">Formulario de finalización</p>
        </header>

        @if (form.status === 'COMPLETED') {
          <!-- ── Finalizado ──────────────────────────────────────────── -->
          <div class="cf-card cf-done" [class.is-fresh]="facade.justCompleted()" role="status">
            <span class="cf-done__icon"><i class="fa-solid fa-check" aria-hidden="true"></i></span>
            <h2 class="cf-done__title">
              {{ facade.justCompleted() ? '¡Listo! Finalizaste' : 'Ya finalizaste' }} {{ form.courseName }}
            </h2>
            <p class="text-body-secondary mb-1">{{ form.completedDate | date: "d 'de' MMMM 'de' y, h:mm a" }}</p>
            <p class="small text-body-secondary">
              Tus calificaciones se guardaron de forma anónima, por eso no se pueden consultar ni cambiar.
            </p>
            <a routerLink="/mis-cursos" class="btn btn-accent mt-2">Volver a mis cursos</a>
          </div>
        } @else {
          <form class="cf-card" (ngSubmit)="submit()" novalidate>
            <!-- ── Tus datos ─────────────────────────────────────────── -->
            <fieldset class="cf-section">
              <legend class="cf-section__title">Tus datos</legend>
              <div class="row g-3">
                <div class="col-12 col-md-6">
                  <label class="form-label" for="cf-name">Nombre</label>
                  <input id="cf-name" class="form-control" [value]="form.userDisplayName" readonly />
                </div>
                <div class="col-12 col-md-6">
                  <label class="form-label" for="cf-email">Correo</label>
                  <input id="cf-email" class="form-control" [value]="form.userEmail" readonly />
                </div>
                <div class="col-12">
                  <label class="form-label" for="cf-management">
                    Gerencia <i class="fa-solid fa-lock ms-1 text-body-secondary" aria-hidden="true"></i>
                  </label>
                  <input
                    id="cf-management"
                    class="form-control cf__locked"
                    [value]="form.management ?? 'No disponible'"
                    [class.is-missing]="!form.management"
                    aria-describedby="cf-management-help"
                    readonly />
                  <div id="cf-management-help" class="form-text">
                    @if (form.management) {
                      Viene del directorio activo. Si no es correcta, pídele a Gestión Humana que la actualice.
                    } @else {
                      No pudimos consultarla en este momento. Puedes enviar el formulario igual.
                    }
                  </div>
                </div>
              </div>
            </fieldset>

            <!-- ── Tu opinión ────────────────────────────────────────── -->
            <fieldset class="cf-section">
              <legend class="cf-section__title">
                Tu opinión
                <span class="cf__anon"><i class="fa-solid fa-user-secret" aria-hidden="true"></i> Respuestas anónimas</span>
              </legend>

              <div class="cf__notice">
                <i class="fa-solid fa-shield-halved" aria-hidden="true"></i>
                <p class="mb-0">
                  Tus calificaciones se guardan en las estadísticas del curso, <strong>sin tu nombre</strong>.
                  Nadie puede ver qué calificó cada persona.
                </p>
              </div>

              <div class="cf__question">
                <p class="cf__question-text">¿Qué tan satisfecho quedaste con el curso?</p>
                <app-star-rating
                  [(value)]="satisfaction"
                  label="Satisfacción con el curso"
                  [labels]="satisfactionLabels"
                  [invalid]="submitted() && satisfaction() === null" />
                @if (submitted() && satisfaction() === null) {
                  <div class="invalid-feedback d-block">Elige una calificación (de 0 a 5).</div>
                }
              </div>

              <div class="cf__question">
                <p class="cf__question-text">¿Qué tan útil fue el curso para tu trabajo?</p>
                <app-star-rating
                  [(value)]="usefulness"
                  label="Utilidad del curso"
                  [labels]="usefulnessLabels"
                  [invalid]="submitted() && usefulness() === null" />
                @if (submitted() && usefulness() === null) {
                  <div class="invalid-feedback d-block">Elige una calificación (de 0 a 5).</div>
                }
              </div>
            </fieldset>

            <!-- ── Enviar ────────────────────────────────────────────── -->
            <footer class="cf__foot">
              <p class="small text-body-secondary mb-0">
                Al enviar, el curso queda <strong>Finalizado</strong>. No podrás cambiar tus respuestas.
              </p>
              <button type="submit" class="btn btn-accent" [disabled]="facade.submitting()">
                @if (facade.submitting()) {
                  <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Enviando…
                } @else {
                  <i class="fa-solid fa-check me-1" aria-hidden="true"></i> Marcar como finalizado
                }
              </button>
            </footer>
          </form>
        }
      }
    }
  }
</section>
```

### `completion-form-page.component.scss`

```scss
@use '@shared-styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
  max-width: 52rem;
  margin: 0 auto;
  padding: 1.5rem 0;
}

.cf__back { color: var(--cu-muted); font-size: 0.875rem; text-decoration: none; }

.cf__head { margin: 0.75rem 0 1.25rem; }

.cf__eyebrow {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  margin: 0;
  color: var(--cu-muted);
  font-size: 0.8rem;
  font-weight: 600;
}

.cf__due {
  --tone: var(--cu-accent);

  padding: 0.1rem 0.5rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 14%, transparent);
  color: color-mix(in srgb, var(--tone) 75%, var(--cu-text));

  &[data-state='soon'] { --tone: var(--cu-warning); }
  &[data-state='overdue'] { --tone: var(--cu-danger); }
}

.cf__title { margin: 0.25rem 0 0; font-size: 1.9rem; font-weight: 800; }
.cf__subtitle { margin: 0; color: var(--cu-muted); }

.cf-card {
  padding: 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow);
  animation: cf-rise 0.4s var(--cu-ease-out) both;
}

.cf-section {
  margin: 0 0 1.5rem;
  padding: 0 0 1.5rem;
  border: 0;
  border-bottom: 1px solid var(--cu-border);
}

.cf-section__title {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 1rem;
  color: var(--cu-muted);
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.cf__locked {
  background: var(--cu-surface-alt);
  cursor: not-allowed;

  &.is-missing { color: var(--cu-muted); font-style: italic; }
}

.cf__anon {
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--cu-accent) 12%, transparent);
  color: color-mix(in srgb, var(--cu-accent) 80%, var(--cu-text));
  font-size: 0.7rem;
  letter-spacing: 0;
  text-transform: none;
}

.cf__notice {
  display: flex;
  gap: 0.75rem;
  margin-bottom: 1.25rem;
  padding: 0.875rem 1rem;
  border-radius: var(--cu-radius-sm);
  background: color-mix(in srgb, var(--cu-accent) 7%, var(--cu-surface));
  font-size: 0.9rem;

  i { margin-top: 0.15rem; color: var(--cu-accent); }
}

.cf__question + .cf__question { margin-top: 1.25rem; }

// Las estrellas usan el dorado de la app.
app-star-rating { --sr-on: var(--cu-accent); }

.cf__question-text { margin: 0 0 0.35rem; font-weight: 600; }

.cf__foot {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
}

// ── Éxito ────────────────────────────────────────────────────────────
.cf-done {
  display: grid;
  justify-items: center;
  gap: 0.25rem;
  text-align: center;
}

.cf-done__icon {
  position: relative;
  display: inline-grid;
  place-items: center;
  width: 4.5rem;
  height: 4.5rem;
  margin-bottom: 0.75rem;
  border-radius: 50%;
  background: var(--cu-onsite);
  color: var(--cu-surface);
  font-size: 2rem;

  // Anillo que se expande una vez.
  &::after {
    content: '';
    position: absolute;
    inset: 0;
    border: 3px solid var(--cu-onsite);
    border-radius: inherit;
    opacity: 0;
  }
}

.cf-done.is-fresh .cf-done__icon {
  animation: cf-pop 0.5s var(--cu-ease-spring) both;

  &::after { animation: cf-ring 1s ease-out 0.25s both; }
}

.cf-done__title { margin: 0; font-size: 1.35rem; font-weight: 700; }

.cf__skeleton span {
  display: block;
  height: 3rem;
  margin-bottom: 1rem;
  border-radius: 0.5rem;
  background: var(--cu-surface-alt);
}

@keyframes cf-rise { from { opacity: 0; transform: translateY(8px); } }
@keyframes cf-pop { from { transform: scale(0) rotate(-25deg); } }
@keyframes cf-ring {
  0% { opacity: 0.8; transform: scale(1); }
  100% { opacity: 0; transform: scale(1.8); }
}

@media (prefers-reduced-motion: reduce) {
  .cf-card,
  .cf-done.is-fresh .cf-done__icon,
  .cf-done.is-fresh .cf-done__icon::after {
    animation: none;
  }
}
```

> `(ngSubmit)` necesita `FormsModule` o `ReactiveFormsModule` en `imports`. Como este formulario no usa controles de Angular (solo las estrellas y campos de lectura), puedes cambiarlo por `(submit)="$event.preventDefault(); submit()"` y no importar nada.

---

## 8. Paso 5 — Rutas

En `src/app/app.routes.ts`:

```ts
// Colaboradores: todos los empleados necesitan el permiso "my-courses".
{
  path: 'mis-cursos',
  canActivate: [permissionGuard],
  data: { permissionPath: 'my-courses' },
  loadComponent: () =>
    import('@features/my-courses/presentation/my-courses-page/my-courses-page.component')
      .then(m => m.MyCoursesPageComponent),
},
{
  path: 'mis-cursos/:id/finalizar',
  canActivate: [permissionGuard],
  data: { permissionPath: 'my-courses' },
  loadComponent: () =>
    import('@features/my-courses/presentation/completion-form-page/completion-form-page.component')
      .then(m => m.CompletionFormPageComponent),
},

// Administración de cursos
{
  path: 'cursos/:id/seguimiento',
  canActivate: [permissionGuard],
  data: { permissionPath: 'courses' },
  loadComponent: () =>
    import('@features/courses/presentation/course-progress-page/course-progress-page.component')
      .then(m => m.CourseProgressPageComponent),
},
```

Agrega **Mis cursos** al menú de todos los usuarios.

---

## 9. Opcional — Avisar con el centro de notificaciones

Si el backend crea una notificación al asignar un grupo (una por persona), agrega un tipo en [centro-notificaciones-angular.md](centro-notificaciones-angular.md):

```ts
// notification-type.enum.ts
CourseAssigned = 'COURSE_ASSIGNED',

// notification-type.config.ts — requestId lleva el id de la asignación de la persona
[NotificationType.CourseAssigned]: {
  label: 'Curso asignado',
  icon: 'fa-graduation-cap',
  tone: 'info',
  route: (n) => (n.requestId ? ['/mis-cursos', n.requestId, 'finalizar'] : ['/mis-cursos']),
},
```

`route` debe devolver `unknown[] | null`; aquí nunca es `null`, así que la notificación siempre lleva a algún lado.

---

## 10. Pruebas

### Unitarias

```ts
describe('StarRatingComponent', () => {
  it('empieza sin valor', () => {
    expect(component.value()).toBeNull();
    expect(component.caption()).toBe('Sin calificar');
  });

  it('el 0 se elige explícitamente', () => {
    component.select(0);
    expect(component.value()).toBe(0);
  });

  it('las flechas no pasan de 0 ni de 5', () => {
    component.select(5);
    component.onKeydown(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
    expect(component.value()).toBe(5);

    component.select(0);
    component.onKeydown(new KeyboardEvent('keydown', { key: 'ArrowLeft' }));
    expect(component.value()).toBe(0);
  });

  it('las teclas numéricas fijan el valor', () => {
    component.onKeydown(new KeyboardEvent('keydown', { key: '3' }));
    expect(component.value()).toBe(3);
  });

  it('deshabilitado no cambia', () => {
    fixture.componentRef.setInput('disabled', true);
    component.select(4);
    expect(component.value()).toBeNull();
  });
});

describe('course-form', () => {
  it('bloquea el grupo de una asignación guardada y aun así lo envía', () => {
    const group = createAssignmentGroup(fb, { id: 7, groupId: 12, groupName: 'Norte', groupRemoved: false, dueDate: '2099-01-01', totalUsers: 40, completedUsers: 3 });
    expect(group.controls.group.disabled).toBeTrue();
    expect(group.getRawValue().group?.id).toBe(12);
  });

  it('detecta un grupo repetido', () => {
    const form = createCourseForm(fb);
    const norte = { id: 12, name: 'Norte', membersCount: 40, directoryOnlyCount: 0 };
    form.controls.assignments.push(createAssignmentGroup(fb));
    form.controls.assignments.push(createAssignmentGroup(fb));
    form.controls.assignments.at(0).controls.group.setValue(norte);
    form.controls.assignments.at(1).controls.group.setValue(norte);
    expect(form.controls.assignments.hasError('duplicatedGroups')).toBeTrue();
  });
});

describe('CompletionFormFacade', () => {
  it('un 409 recarga el formulario en lugar de mostrar un error', async () => {
    repository.complete.and.returnValue(throwError(() => new HttpErrorResponse({ status: 409 })));
    await facade.load(5);

    const result = await facade.complete({ satisfaction: 4, usefulness: 5 });

    expect(result).toBeFalse();
    expect(repository.getForm).toHaveBeenCalledTimes(2);
  });
});
```

### Revisión con usuarios reales

- Asignar dos grupos que comparten personas: el aviso dice cuántas quedaron en el primero.
- Abrir "Mis cursos" con una cuenta de prueba: aparece el curso como Pendiente.
- En el formulario, la gerencia aparece bloqueada y coincide con la del directorio.
- Enviar sin tocar las estrellas: las dos se marcan en rojo y no se envía.
- Elegir 0 en una: se acepta.
- Enviar: aparece la animación de éxito; "Mis cursos" lo muestra como Finalizado.
- Volver a abrir el mismo formulario: dice "Ya finalizaste" y no muestra las calificaciones.
- Hacer doble clic muy rápido en "Marcar como finalizado": solo queda una respuesta en el seguimiento.
- Seguimiento con 2 respuestas: no hay promedios y lo explica. Con 3: aparecen promedios y distribución.
- Solo con teclado: Tab hasta las estrellas, flechas para cambiar, `4` para fijar 4 estrellas, Enter en el botón.
- Con lector de pantalla: cada estrella se anuncia con su número y su significado.

---

## ✅ Checklist

- [ ] `describeDue` movido a `@shared/utils/due-date` y los imports actualizados.
- [ ] Tokens de cursos en `@shared-styles/courses-tokens`, con `--cu-on-accent` (texto oscuro sobre el dorado).
- [ ] Ningún color escrito a mano: estrellas, barras y encabezados salen de los tokens.
- [ ] Tarjeta del curso con "N grupos · N personas", avance y acción Seguimiento.
- [ ] `user-picker` y `users-directory` eliminados de la feature de cursos.
- [ ] Editor con "Grupos asignados", grupo bloqueado en asignaciones guardadas y "Actualizar desde el grupo".
- [ ] Quien administra cursos puede leer la lista de grupos (permiso o endpoint de lectura).
- [ ] `app-star-rating` en `shared/components`, empezando sin valor y con el 0 explícito.
- [ ] Aviso de anonimato visible sobre las estrellas.
- [ ] La gerencia se muestra bloqueada y el formulario se puede enviar aunque no llegue.
- [ ] Confirmación antes de enviar.
- [ ] Seguimiento con promedios solo a partir del mínimo de respuestas.
- [ ] Rutas `mis-cursos`, `mis-cursos/:id/finalizar` y `cursos/:id/seguimiento`; permiso `my-courses` para todos.
- [ ] Probado con teclado, lector de pantalla, móvil y `prefers-reduced-motion`.
