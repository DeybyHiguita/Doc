# 📊 Cursos — Resultados como página, mejor selector de grupos y "Agregar personas" por gerencia y dirección

**Lo que se pide:**
1. **Resultados en su propia página.** El modal de resultados del curso pasa a ser una página: es de las partes más consultadas.
2. **Mejor selector de grupos.** Elegir el grupo que se quiere ver es más fácil.
3. **Solo colores del sistema.** El listado de grupos usa amarillos y grises, nada más.
4. **Dos opciones más en `grupos/nuevo`:** "Por gerencia" y "Por dirección" en "Agregar personas". **Solo interfaz**, todavía sin funcionalidad.

**Base:** el código real de `.claude/Cursos y recordatorios` (Angular). Solo cambia el frontend; la API no se toca.

---

## 1. Qué hay hoy

| Pieza | Cómo está | Qué cambia |
|---|---|---|
| `course-results-modal` | Modal de 860 px de ancho. Lo abre `courses.page` con `selectedCourseForResults` desde la tarjeta (`viewResults`). | Pasa a la página `/cursos/:id/resultados`. El modal se elimina. |
| Selector de grupos | Fila de pestañas con scroll horizontal (`.rm-tabs`): nombre, fecha y `x/y`. Con muchos grupos hay que desplazarse y no se puede buscar. | Lista lateral con búsqueda, filtro y orden, avance de cada grupo y el grupo elegido en la URL (`?grupo=`). En el celular, un `<select>`. |
| Colores de estado | **Verde** (`--cu-onsite`) para finalizados, **naranja** (`--cu-warning`) para pendientes y **rojo** (`--cu-danger`) para vencidos. La barra va de amarillo a verde. También en `assignment-users`. | Solo amarillo y grises: **amarillo** = finalizado, **gris** = pendiente, **gris oscuro** = vencido. Los íconos y textos siguen diciendo el estado, así que no depende solo del color. |
| "Agregar personas" | Tres pestañas en `TABS`: Por líder, Buscar persona, Pegar correos. | Dos más: Por gerencia y Por dirección, con el aviso "Pronto" y los controles deshabilitados. |

### Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **URL de la página.** | `/cursos/:id/resultados`. Se puede guardar en favoritos, compartir y abrir en otra pestaña. |
| 2 | **El grupo elegido va en la URL** (`?grupo=12`). | Al recargar o compartir se ve el mismo grupo. Se usa `replaceUrl`: el botón "Atrás" del navegador vuelve a Cursos, no grupo por grupo. |
| 3 | **Elegir grupo en escritorio.** | Lista lateral con: búsqueda por nombre, filtro (`Todos`, `Con pendientes`, `Con vencidos`, `Completos`) y orden (`Fecha límite`, `Menor avance`, `Mayor avance`, `Más vencidos`, `Nombre`). Filtro y orden son `<select>`, como en el resto del proyecto. |
| 4 | **Elegir grupo en el celular.** | Un `<select>` con el nombre y el porcentaje. Los mismos filtros lo acotan. |
| 5 | **Grupo por defecto.** | El primero que manda la API (la fecha límite más próxima), igual que el modal. |
| 6 | **Misma lógica.** | `CourseProgressFacade`, `AssignmentUsersComponent` y los cálculos (totales, calificaciones) se mueven tal cual. |
| 7 | **Gerencia y dirección.** | Un solo componente (`app-org-unit-import`) con `kind`. Muestra lo que va a pedir (el select y "Incluir a los líderes"), deshabilitado, con un aviso. Cuando exista la fuente de datos, se conecta ahí. |

---

# Parte 1 — La página de resultados

## 2. Paso 1 — La ruta

### `app.routes.ts` ✏️ — después de `cursos`

```ts
{
  path: 'cursos/:id/resultados',
  loadComponent: () =>
    import('@features/courses/presentation/course-results-page/course-results.page')
      .then(m => m.CourseResultsPage),
},
```

> Si `cursos` lleva más adelante `permissionGuard`, ponle aquí el mismo con `data: { permissionPath: 'cursos' }`: el guard mira el primer segmento de la ruta.

---

## 3. Paso 2 — `course-results.page.ts` (nuevo)

`features/courses/presentation/course-results-page/course-results.page.ts`

```ts
import { ChangeDetectionStrategy, Component, PLATFORM_ID, computed, effect, inject, signal, untracked } from '@angular/core';
import { DecimalPipe, isPlatformServer } from '@angular/common';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs';
import { describeDue } from '@shared/utils/due-date';
import { LayoutComponent } from '@core/layout/layout.component';
import { HeaderComponent } from '@shared/components/header/header.component';
import { UserInfoService } from '@core/services/user-info-msal.service';
import { GlobalPermissionsService } from '@core/services/global-permissions.service';
import { GlobalNotificationService } from '@shared/services/global-notification-alerts.service';
import { MenuPermission } from '@shared/entities/general/menu-permissions-service';
import { CourseProgressFacade } from '../../application/course-progress.facade';
import { COURSES_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/courses.providers';
import { AssignmentProgress, RatingSummary } from '../../domain/course.model';
import { AssignmentUsersComponent } from '../assignment-users/assignment-users.component';

/** Una barra del histograma de calificaciones (0 a 5). */
interface RatingBar {
  readonly score: number;
  readonly count: number;
  /** % respecto a la barra más alta, para el ancho visual. */
  readonly width: number;
}

interface RatingQuestion {
  readonly label: string;
  readonly average: number | null;
  readonly bars: readonly RatingBar[];
}

type GroupSort = 'due' | 'progress-asc' | 'progress-desc' | 'overdue' | 'name';
type GroupFilter = 'all' | 'pending' | 'overdue' | 'complete';

const GROUP_SORTS: readonly { value: GroupSort; label: string }[] = [
  { value: 'due', label: 'Fecha límite' },
  { value: 'progress-asc', label: 'Menor avance' },
  { value: 'progress-desc', label: 'Mayor avance' },
  { value: 'overdue', label: 'Más vencidos' },
  { value: 'name', label: 'Nombre' },
];

const GROUP_FILTERS: readonly { value: GroupFilter; label: string }[] = [
  { value: 'all', label: 'Todos los grupos' },
  { value: 'pending', label: 'Con pendientes' },
  { value: 'overdue', label: 'Con vencidos' },
  { value: 'complete', label: 'Completos' },
];

@Component({
  selector: 'app-course-results-page',
  imports: [DecimalPipe, RouterLink, LayoutComponent, HeaderComponent, AssignmentUsersComponent],
  // Facade propia: AssignmentUsersComponent la inyecta desde aquí.
  providers: [...COURSES_INFRASTRUCTURE_PROVIDERS, CourseProgressFacade],
  templateUrl: './course-results.page.html',
  styleUrl: './course-results.page.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CourseResultsPage {
  protected readonly facade = inject(CourseProgressFacade);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  private readonly userInfoService = inject(UserInfoService);
  private readonly permissionsService = inject(GlobalPermissionsService);
  private readonly globalNotificationService = inject(GlobalNotificationService);
  private readonly platformId = inject(PLATFORM_ID);

  readonly sorts = GROUP_SORTS;
  readonly filters = GROUP_FILTERS;

  // ── Encabezado (igual que las demás páginas) ───────────────────────
  readonly permissions = signal<MenuPermission[]>([]);
  readonly userName = signal('');
  readonly userEmail = signal('');
  readonly userRole = signal('');
  readonly notificationCount = signal(0);

  // ── URL ────────────────────────────────────────────────────────────
  /** :id de la ruta. null si no es un número válido. */
  readonly courseId = toSignal(
    this.route.paramMap.pipe(map(params => Number(params.get('id')) || null)),
    { initialValue: null },
  );

  /** ?grupo= — el grupo elegido sobrevive a recargar y se puede compartir. */
  private readonly groupParam = toSignal(
    this.route.queryParamMap.pipe(map(params => Number(params.get('grupo')) || null)),
    { initialValue: null },
  );

  // ── Selector de grupos ─────────────────────────────────────────────
  readonly groupSearch = signal('');
  readonly groupFilter = signal<GroupFilter>('all');
  readonly groupSort = signal<GroupSort>('due');

  readonly assignments = computed(() => this.facade.progress()?.assignments ?? []);

  /** La lista lateral: búsqueda, filtro y orden. */
  readonly visibleGroups = computed(() => {
    const term = normalize(this.groupSearch());
    const filter = this.groupFilter();
    const list = this.assignments().filter(
      a => (!term || normalize(a.groupName).includes(term)) && matchesFilter(a, filter),
    );
    return sortGroups(list, this.groupSort());
  });

  /** El de la URL; si no hay o no existe, el primero (la fecha límite más próxima). */
  readonly selected = computed<AssignmentProgress | null>(() => {
    const list = this.assignments();
    return list.find(a => a.id === this.groupParam()) ?? list[0] ?? null;
  });

  /** Opciones del select del celular: las visibles y, si los filtros lo ocultan, también el elegido. */
  readonly selectOptions = computed(() => {
    const visible = this.visibleGroups();
    const current = this.selected();
    return current && !visible.includes(current) ? [current, ...visible] : visible;
  });

  // ── Resumen del curso ──────────────────────────────────────────────
  /** Totales del curso: suma de todas las asignaciones. */
  readonly totals = computed(() => {
    const list = this.assignments();
    const total = list.reduce((s, a) => s + a.total, 0);
    const completed = list.reduce((s, a) => s + a.completed, 0);
    const overdue = list.reduce((s, a) => s + a.overdue, 0);
    return {
      total,
      completed,
      pending: total - completed,
      overdue,
      percent: total ? Math.round((completed / total) * 100) : 0,
    };
  });

  readonly courseRatings = computed(() => this.facade.progress()?.ratings ?? null);
  readonly courseQuestions = computed(() => toQuestions(this.courseRatings()));
  readonly selectedQuestions = computed(() => toQuestions(this.selected()?.ratings ?? null));

  constructor() {
    if (isPlatformServer(this.platformId)) {
      return;
    }

    // Usuario, permisos y notificaciones: lo mismo que courses.page.
    effect(() => {
      this.userInfoService.loadUserInfo().then(user => {
        if (!user?.mail) return;
        this.userEmail.set(user.mail);
        this.userName.set(user.displayName);
        this.userRole.set(user.jobTitle || '');
        this.globalNotificationService.refreshNotifications(user.mail);
        this.permissionsService.loadPermissions(user.mail).then(result => {
          if (!result.hasError) this.permissions.set(result.response);
        });
      });
    });

    effect(() => {
      this.notificationCount.set(this.globalNotificationService.notificationCount());
    });

    // Cada vez que cambia el curso de la URL.
    effect(() => {
      const id = this.courseId();
      if (!id) return;
      untracked(() => void this.facade.load(id));
    });
  }

  reload(): void {
    const id = this.courseId();
    if (id) void this.facade.load(id);
  }

  selectGroup(assignmentId: number): void {
    // replaceUrl: "Atrás" vuelve a Cursos, no grupo por grupo.
    void this.router.navigate([], {
      relativeTo: this.route,
      queryParams: { grupo: assignmentId },
      queryParamsHandling: 'merge',
      replaceUrl: true,
    });
  }

  percent(a: AssignmentProgress): number {
    return percentOf(a);
  }

  due(a: AssignmentProgress) {
    return describeDue(a.dueDate);
  }
}

// ── Funciones puras ──────────────────────────────────────────────────

function percentOf(a: AssignmentProgress): number {
  return a.total ? Math.round((a.completed / a.total) * 100) : 0;
}

/** Sin tildes ni mayúsculas: "Gestión" encuentra "gestion". */
function normalize(value: string | null | undefined): string {
  return (value ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
}

function matchesFilter(a: AssignmentProgress, filter: GroupFilter): boolean {
  switch (filter) {
    case 'pending': return a.completed < a.total;
    case 'overdue': return a.overdue > 0;
    case 'complete': return a.total > 0 && a.completed === a.total;
    default: return true;
  }
}

function sortGroups(list: readonly AssignmentProgress[], sort: GroupSort): AssignmentProgress[] {
  const copy = [...list];
  switch (sort) {
    case 'progress-asc': return copy.sort((x, y) => percentOf(x) - percentOf(y));
    case 'progress-desc': return copy.sort((x, y) => percentOf(y) - percentOf(x));
    case 'overdue': return copy.sort((x, y) => y.overdue - x.overdue);
    case 'name': return copy.sort((x, y) => (x.groupName || '').localeCompare(y.groupName || '', 'es'));
    default: return copy; // 'due': la API ya los envía por fecha límite.
  }
}

function toQuestions(summary: RatingSummary | null): RatingQuestion[] {
  if (!summary?.visible) return [];
  return [
    { label: 'Satisfacción con el curso', average: summary.satisfactionAverage, bars: toBars(summary.satisfactionDistribution) },
    { label: 'Utilidad para el trabajo', average: summary.usefulnessAverage, bars: toBars(summary.usefulnessDistribution) },
  ];
}

/** De mayor a menor (5 → 0), como se leen las reseñas. */
function toBars(distribution: readonly number[] | null): RatingBar[] {
  const counts = Array.from({ length: 6 }, (_, score) => distribution?.[score] ?? 0);
  const max = Math.max(1, ...counts);
  return counts
    .map((count, score) => ({ score, count, width: Math.round((count / max) * 100) }))
    .reverse();
}
```

> **`toSignal` sobre `paramMap`:** el router no tiene `withComponentInputBinding`, así que el `:id` no llega como `input()`. Si algún día se activa, `courseId` puede pasar a ser `input()`.
>
> **En el servidor (SSR) no se carga nada:** igual que el modal, que solo se abría con un clic en el navegador.

---

## 4. Paso 3 — `course-results.page.html` (nuevo)

```html
<app-layout [permissions]="permissions()">
  <app-header
    [title]="'Módulo de Cursos'"
    [subText]="'Avance, calificaciones y personas por grupo'"
    [userName]="userName()"
    [userEmail]="userEmail()"
    [userRole]="userRole()"
    [notificationCount]="notificationCount()">
  </app-header>

  <section class="crp">
    <a routerLink="/cursos" class="crp__back">
      <i class="fa-solid fa-arrow-left" aria-hidden="true"></i> Volver a cursos
    </a>

    <!-- ── Encabezado ──────────────────────────────────────────────── -->
    <header class="crp__hero">
      <span class="crp__icon"><i class="fa-solid fa-chart-column" aria-hidden="true"></i></span>
      <div class="crp__hero-text">
        <p class="crp__eyebrow">Resultados del curso</p>
        <h1 class="crp__title">{{ facade.progress()?.courseName ?? 'Cargando…' }}</h1>
      </div>
      <button type="button" class="btn btn-outline-secondary crp__reload"
        [disabled]="facade.status() === 'loading'" (click)="reload()">
        <i class="fa-solid fa-rotate-right me-1" aria-hidden="true"></i> Actualizar
      </button>
    </header>

    @if (!courseId()) {
      <div class="crp__state">
        <i class="fa-solid fa-circle-exclamation crp__state-icon" aria-hidden="true"></i>
        <p>El curso no es válido.</p>
        <a routerLink="/cursos" class="btn btn-yellow btn-sm">Ir a cursos</a>
      </div>
    } @else {
      @switch (facade.status()) {
        @case ('loading') {
          <div class="crp__state" role="status">
            <div class="spinner-border" aria-hidden="true"></div>
            <p>Cargando resultados…</p>
          </div>
        }

        @case ('error') {
          <div class="crp__state">
            <i class="fa-solid fa-circle-exclamation crp__state-icon" aria-hidden="true"></i>
            <p>{{ facade.error() }}</p>
            <button type="button" class="btn btn-yellow btn-sm" (click)="reload()">
              <i class="fa-solid fa-rotate-right me-1" aria-hidden="true"></i> Reintentar
            </button>
          </div>
        }

        @default {
          <div class="crp__top">
            <!-- ── Avance general ─────────────────────────────────── -->
            <section class="crp-card" aria-labelledby="crp-progress">
              <h2 id="crp-progress" class="crp-card__title">Avance general</h2>
              <div class="crp__kpis">
                <div class="crp-kpi">
                  <span class="crp-kpi__value">{{ totals().total }}</span>
                  <span class="crp-kpi__label">Asignados</span>
                </div>
                <div class="crp-kpi" data-tone="done">
                  <span class="crp-kpi__value">{{ totals().completed }}</span>
                  <span class="crp-kpi__label"><i class="fa-solid fa-check" aria-hidden="true"></i> Finalizaron</span>
                </div>
                <div class="crp-kpi" data-tone="pending">
                  <span class="crp-kpi__value">{{ totals().pending }}</span>
                  <span class="crp-kpi__label"><i class="fa-regular fa-clock" aria-hidden="true"></i> Faltan</span>
                </div>
                <div class="crp-kpi" data-tone="late">
                  <span class="crp-kpi__value">{{ totals().overdue }}</span>
                  <span class="crp-kpi__label"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i> Vencidos</span>
                </div>
              </div>
              <div class="crp-bar" role="progressbar"
                [attr.aria-valuenow]="totals().percent" aria-valuemin="0" aria-valuemax="100"
                [attr.aria-label]="totals().percent + ' % finalizado'">
                <span class="crp-bar__fill" [style.width.%]="totals().percent"></span>
              </div>
              <p class="crp__hint">{{ totals().percent }} % del curso finalizado</p>
            </section>

            <!-- ── Calificaciones (anónimas) ───────────────────────── -->
            <section class="crp-card" aria-labelledby="crp-ratings">
              <h2 id="crp-ratings" class="crp-card__title">
                Calificaciones
                <span class="crp__anon"><i class="fa-solid fa-user-secret" aria-hidden="true"></i> Anónimas</span>
              </h2>

              @if (courseRatings(); as ratings) {
                @if (ratings.visible) {
                  <p class="crp__hint mb-2">{{ ratings.responses }} {{ ratings.responses === 1 ? 'respuesta' : 'respuestas' }}</p>
                  <div class="crp__questions">
                    @for (q of courseQuestions(); track q.label) {
                      <div class="crp-question">
                        <div class="crp-question__head">
                          <span class="crp-question__label">{{ q.label }}</span>
                          <span class="crp-question__avg">
                            <i class="fa-solid fa-star" aria-hidden="true"></i>
                            {{ q.average !== null ? (q.average | number: '1.1-1') : '—' }}
                            <small>/ 5</small>
                          </span>
                        </div>
                        <ul class="crp-bars" [attr.aria-label]="'Distribución: ' + q.label">
                          @for (bar of q.bars; track bar.score) {
                            <li class="crp-bars__row">
                              <span class="crp-bars__score">{{ bar.score }}</span>
                              <span class="crp-bars__track"><span class="crp-bars__fill" [style.width.%]="bar.width"></span></span>
                              <span class="crp-bars__count">{{ bar.count }}</span>
                            </li>
                          }
                        </ul>
                      </div>
                    }
                  </div>
                } @else {
                  <div class="crp__notice">
                    <i class="fa-solid fa-shield-halved" aria-hidden="true"></i>
                    <p class="mb-0">
                      Para proteger el anonimato, el resumen se muestra a partir de
                      <strong>{{ ratings.minimumResponses }}</strong> respuestas.
                      Por ahora hay <strong>{{ ratings.responses }}</strong>.
                    </p>
                  </div>
                }
              }
            </section>
          </div>

          <!-- ── Personas por grupo ──────────────────────────────── -->
          <section class="crp-card crp-groups" aria-labelledby="crp-groups-title">
            <div class="crp-groups__head">
              <h2 id="crp-groups-title" class="crp-card__title mb-0">Personas por grupo</h2>
              <span class="crp-groups__count">{{ assignments().length }} {{ assignments().length === 1 ? 'grupo' : 'grupos' }}</span>
            </div>

            @if (!assignments().length) {
              <p class="crp__hint">Este curso no tiene grupos asignados.</p>
            } @else {
              <div class="crp-groups__layout">
                <!-- Selector -->
                <aside class="crp-picker" aria-label="Elegir grupo">
                  <div class="crp-picker__tools">
                    <div class="crp-picker__search">
                      <i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>
                      <input type="search" class="form-control form-control-sm" placeholder="Buscar grupo"
                        aria-label="Buscar grupo" [value]="groupSearch()"
                        (input)="groupSearch.set($any($event.target).value)" />
                    </div>
                    <div class="crp-picker__selects">
                      <select class="form-select form-select-sm" aria-label="Mostrar"
                        (change)="groupFilter.set($any($event.target).value)">
                        @for (f of filters; track f.value) {
                          <option [value]="f.value" [selected]="groupFilter() === f.value">{{ f.label }}</option>
                        }
                      </select>
                      <select class="form-select form-select-sm" aria-label="Ordenar por"
                        (change)="groupSort.set($any($event.target).value)">
                        @for (s of sorts; track s.value) {
                          <option [value]="s.value" [selected]="groupSort() === s.value">{{ s.label }}</option>
                        }
                      </select>
                    </div>
                  </div>

                  <!-- Celular y tableta: un select -->
                  <label class="crp-picker__label d-lg-none" for="crp-group-select">Grupo</label>
                  <select id="crp-group-select" class="form-select d-lg-none"
                    (change)="selectGroup(+$any($event.target).value)">
                    @for (a of selectOptions(); track a.id) {
                      <option [value]="a.id" [selected]="a.id === selected()?.id">
                        {{ a.groupName || 'Grupo sin nombre' }} · {{ percent(a) }} %
                      </option>
                    }
                  </select>

                  <!-- Escritorio: lista -->
                  <ul class="crp-picker__list d-none d-lg-flex">
                    @for (a of visibleGroups(); track a.id) {
                      <li>
                        <button type="button" class="crp-group-item"
                          [class.is-active]="a.id === selected()?.id"
                          [attr.aria-current]="a.id === selected()?.id ? 'true' : null"
                          (click)="selectGroup(a.id)">
                          <span class="crp-group-item__top">
                            <span class="crp-group-item__name">{{ a.groupName || 'Grupo sin nombre' }}</span>
                            <span class="crp-group-item__percent">{{ percent(a) }} %</span>
                          </span>
                          <span class="crp-bar crp-bar--xs" aria-hidden="true">
                            <span class="crp-bar__fill" [style.width.%]="percent(a)"></span>
                          </span>
                          <span class="crp-group-item__meta">
                            <span><i class="fa-regular fa-calendar" aria-hidden="true"></i> {{ due(a)?.date }}</span>
                            <span>{{ a.completed }}/{{ a.total }}</span>
                            @if (a.overdue) {
                              <span class="crp-tag" data-tone="late">{{ a.overdue }} vencidos</span>
                            }
                            @if (a.groupRemoved) {
                              <span class="crp-tag">Eliminado</span>
                            }
                          </span>
                        </button>
                      </li>
                    } @empty {
                      <li class="crp-picker__empty">Ningún grupo coincide con la búsqueda.</li>
                    }
                  </ul>
                </aside>

                <!-- Detalle del grupo elegido -->
                <div class="crp-panel">
                  @if (selected(); as a) {
                    <header class="crp-panel__head">
                      <div>
                        <h3 class="crp-panel__title">
                          {{ a.groupName || 'Grupo sin nombre' }}
                          @if (a.groupRemoved) { <small>(eliminado)</small> }
                        </h3>
                        @if (due(a); as d) {
                          <p class="crp-panel__due">
                            <i class="fa-regular fa-calendar" aria-hidden="true"></i> Fecha límite: {{ d.date }} · {{ d.relative }}
                          </p>
                        }
                      </div>
                      <span class="crp-panel__percent">{{ percent(a) }} %</span>
                    </header>

                    <div class="crp-bar crp-bar--sm" aria-hidden="true">
                      <span class="crp-bar__fill" [style.width.%]="percent(a)"></span>
                    </div>

                    <div class="crp-panel__stats">
                      <span class="crp-chip" data-tone="done"><i class="fa-solid fa-check" aria-hidden="true"></i> {{ a.completed }} finalizaron</span>
                      <span class="crp-chip" data-tone="pending"><i class="fa-regular fa-clock" aria-hidden="true"></i> {{ a.total - a.completed }} faltan</span>
                      @if (a.overdue) {
                        <span class="crp-chip" data-tone="late"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i> {{ a.overdue }} vencidos</span>
                      }
                      @if (a.withoutUser) {
                        <span class="crp-chip" title="Integrantes del grupo sin usuario: no recibieron el curso">
                          <i class="fa-solid fa-user-slash" aria-hidden="true"></i> {{ a.withoutUser }} sin usuario
                        </span>
                      }
                    </div>

                    @if (selectedQuestions().length) {
                      <div class="crp-panel__stats">
                        @for (q of selectedQuestions(); track q.label) {
                          <span class="crp-chip">
                            <i class="fa-solid fa-star" aria-hidden="true"></i>
                            {{ q.label }}: {{ q.average !== null ? (q.average | number: '1.1-1') : '—' }} / 5
                          </span>
                        }
                      </div>
                    }

                    <!-- Filtros: Todos / Pendientes / Vencidos / Finalizados -->
                    <app-assignment-users [assignmentId]="a.id" />
                  }
                </div>
              </div>
            }
          </section>
        }
      }
    }
  </section>
</app-layout>
```

---

## 5. Paso 4 — `course-results.page.scss` (nuevo): solo amarillos y grises

```scss
@use '../../../../../styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}

// Estados solo con la paleta del sistema: amarillo = finalizado, gris = pendiente, gris oscuro = vencido.
// El ícono y el texto también dicen el estado: no depende solo del color.
[data-tone='done'] {
  --tone-bg: var(--cu-accent-subtle-bg);
  --tone-border: var(--cu-accent-border);
  --tone-text: var(--cu-accent-text);
}

[data-tone='pending'] {
  --tone-bg: var(--cu-gray-100);
  --tone-border: var(--cu-gray-200);
  --tone-text: var(--cu-gray-600);
}

[data-tone='late'] {
  --tone-bg: var(--cu-gray-800);
  --tone-border: var(--cu-gray-800);
  --tone-text: #fff;
}

// ── Página ───────────────────────────────────────────────────────────
.crp {
  display: grid;
  gap: 1.25rem;
  max-width: 1240px;
  margin: 0 auto;
  padding: 1rem 0 2rem;
}

.crp__back {
  justify-self: start;
  display: inline-flex;
  align-items: center;
  gap: 0.45rem;
  color: var(--cu-muted);
  font-size: 0.875rem;
  font-weight: 600;
  text-decoration: none;

  &:hover { color: var(--cu-text); }
}

.crp__hero {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 1.25rem 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-lg);
  background: linear-gradient(135deg, rgba(245, 197, 24, 0.1), rgba(245, 197, 24, 0.02));
}

.crp__icon {
  display: grid;
  flex-shrink: 0;
  width: 52px;
  height: 52px;
  place-items: center;
  border-radius: 12px;
  background: var(--cu-accent);
  color: var(--cu-on-accent);
  font-size: 1.35rem;
  box-shadow: 0 4px 12px rgba(245, 197, 24, 0.3);
}

.crp__hero-text { flex: 1 1 auto; min-width: 0; }

.crp__eyebrow {
  margin: 0;
  color: var(--cu-accent-text);
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.crp__title {
  margin: 0.15rem 0 0;
  overflow: hidden;
  font-size: 1.5rem;
  font-weight: 700;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.crp__reload { flex-shrink: 0; }

// ── Estados ──────────────────────────────────────────────────────────
.crp__state {
  display: grid;
  justify-items: center;
  gap: 0.75rem;
  padding: 4rem 1rem;
  color: var(--cu-muted);
  text-align: center;

  .spinner-border { color: var(--cu-accent); }
}

.crp__state-icon {
  color: var(--cu-gray-500);
  font-size: 2rem;
}

// ── Tarjetas ─────────────────────────────────────────────────────────
.crp__top {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 1.25rem;
}

.crp-card {
  padding: 1.25rem 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-lg);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow-sm);
}

.crp-card__title {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0 0.875rem;
  color: var(--cu-muted);
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.crp__anon {
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);
  font-size: 0.7rem;
  letter-spacing: 0;
  text-transform: none;
}

.crp__hint {
  margin: 0.4rem 0 0;
  color: var(--cu-muted);
  font-size: 0.85rem;
}

.crp__notice {
  display: flex;
  gap: 0.75rem;
  padding: 0.875rem 1rem;
  border-radius: var(--cu-radius-sm);
  background: var(--cu-accent-subtle-bg);
  font-size: 0.9rem;

  i { margin-top: 0.15rem; color: var(--cu-accent-dark); }
}

// ── KPIs ─────────────────────────────────────────────────────────────
.crp__kpis {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 0.625rem;
  margin-bottom: 0.875rem;
}

.crp-kpi {
  --tone-bg: var(--cu-surface-alt);
  --tone-border: var(--cu-border);
  --tone-text: var(--cu-text);

  display: grid;
  gap: 0.15rem;
  padding: 0.75rem 0.875rem;
  border: 1px solid var(--tone-border);
  border-radius: var(--cu-radius-sm);
  background: var(--tone-bg);
  color: var(--tone-text);
}

.crp-kpi__value {
  font-size: 1.5rem;
  font-weight: 700;
  line-height: 1.1;
}

.crp-kpi__label {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  font-size: 0.75rem;
  font-weight: 600;
  opacity: 0.85;
}

// ── Barras de avance ─────────────────────────────────────────────────
.crp-bar {
  display: block;
  height: 10px;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-gray-100);

  &--sm { height: 6px; margin-bottom: 0.875rem; }
  &--xs { height: 4px; }
}

.crp-bar__fill {
  display: block;
  height: 100%;
  border-radius: inherit;
  background: linear-gradient(90deg, var(--cu-accent), var(--cu-accent-dark));
  transition: width 0.4s ease;
}

// ── Calificaciones ───────────────────────────────────────────────────
.crp__questions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.875rem;
}

.crp-question {
  padding: 0.75rem 0.875rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-sm);
}

.crp-question__head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5rem;
  margin-bottom: 0.5rem;
}

.crp-question__label { font-size: 0.85rem; font-weight: 600; }

.crp-question__avg {
  font-size: 1.2rem;
  font-weight: 700;
  white-space: nowrap;

  i { color: var(--cu-accent); font-size: 0.95rem; }
  small { color: var(--cu-muted); font-size: 0.75rem; font-weight: 600; }
}

.crp-bars {
  display: grid;
  gap: 0.25rem;
  margin: 0;
  padding: 0;
  list-style: none;
}

.crp-bars__row {
  display: grid;
  grid-template-columns: 1rem 1fr 2rem;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.78rem;
}

.crp-bars__score { color: var(--cu-muted); font-weight: 600; text-align: right; }
.crp-bars__count { color: var(--cu-muted); }

.crp-bars__track {
  height: 8px;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-gray-100);
}

.crp-bars__fill {
  display: block;
  height: 100%;
  border-radius: inherit;
  background: var(--cu-accent);
}

// ── Grupos ───────────────────────────────────────────────────────────
.crp-groups__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1rem;
}

.crp-groups__count {
  padding: 0.15rem 0.65rem;
  border-radius: 999px;
  background: var(--cu-gray-100);
  color: var(--cu-gray-600);
  font-size: 0.78rem;
  font-weight: 600;
}

.crp-groups__layout {
  display: grid;
  grid-template-columns: 320px minmax(0, 1fr);
  gap: 1.25rem;
  align-items: start;
}

// Selector
.crp-picker {
  display: grid;
  gap: 0.625rem;
  padding: 0.75rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface-alt);

  @media (min-width: 992px) {
    position: sticky;
    top: 1rem;
  }
}

.crp-picker__tools { display: grid; gap: 0.5rem; }

.crp-picker__search {
  position: relative;

  i {
    position: absolute;
    top: 50%;
    left: 0.7rem;
    color: var(--cu-gray-400);
    font-size: 0.8rem;
    transform: translateY(-50%);
  }

  input { padding-left: 2rem; }
}

.crp-picker__selects {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5rem;
}

.crp-picker__label {
  margin: 0.25rem 0 -0.25rem;
  color: var(--cu-muted);
  font-size: 0.78rem;
  font-weight: 600;
}

.crp-picker__list {
  flex-direction: column;
  gap: 0.375rem;
  max-height: 60vh;
  margin: 0;
  padding: 0 0.125rem 0 0;
  overflow-y: auto;
  list-style: none;
}

.crp-picker__empty {
  padding: 1rem 0.5rem;
  color: var(--cu-muted);
  font-size: 0.85rem;
  text-align: center;
}

.crp-group-item {
  display: grid;
  width: 100%;
  gap: 0.375rem;
  padding: 0.625rem 0.75rem;
  border: 1.5px solid transparent;
  border-radius: var(--cu-radius-sm);
  background: var(--cu-surface);
  text-align: left;
  transition: border-color 0.15s ease, background-color 0.15s ease;

  &:hover { border-color: var(--cu-accent-border); }

  &.is-active {
    border-color: var(--cu-accent);
    background: var(--cu-accent-subtle-bg);
    box-shadow: inset 4px 0 0 var(--cu-accent);
  }

  &:focus-visible {
    outline: 2px solid var(--cu-accent);
    outline-offset: 2px;
  }
}

.crp-group-item__top {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5rem;
}

.crp-group-item__name {
  overflow: hidden;
  color: var(--cu-text);
  font-size: 0.875rem;
  font-weight: 600;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.crp-group-item__percent {
  color: var(--cu-gray-700);
  font-size: 0.8rem;
  font-weight: 700;
}

.crp-group-item__meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.25rem 0.625rem;
  color: var(--cu-muted);
  font-size: 0.72rem;
}

.crp-tag {
  --tone-bg: var(--cu-gray-200);
  --tone-text: var(--cu-gray-700);

  padding: 0 0.45rem;
  border-radius: 999px;
  background: var(--tone-bg);
  color: var(--tone-text);
  font-weight: 600;
}

// Detalle
.crp-panel { min-width: 0; }

.crp-panel__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.625rem;
}

.crp-panel__title {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 700;

  small { color: var(--cu-gray-500); font-size: 0.8rem; font-weight: 500; }
}

.crp-panel__due {
  margin: 0.2rem 0 0;
  color: var(--cu-muted);
  font-size: 0.82rem;
}

.crp-panel__percent {
  color: var(--cu-text);
  font-size: 1.6rem;
  font-weight: 700;
  line-height: 1;
}

.crp-panel__stats {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 0.75rem;
}

.crp-chip {
  --tone-bg: var(--cu-gray-100);
  --tone-border: var(--cu-gray-200);
  --tone-text: var(--cu-gray-700);

  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.2rem 0.65rem;
  border: 1px solid var(--tone-border);
  border-radius: 999px;
  background: var(--tone-bg);
  color: var(--tone-text);
  font-size: 0.78rem;
  font-weight: 600;

  .fa-star { color: var(--cu-accent); }
}

// ── Responsive ───────────────────────────────────────────────────────
@media (max-width: 1199.98px) {
  .crp__top { grid-template-columns: 1fr; }
}

@media (max-width: 991.98px) {
  .crp-groups__layout { grid-template-columns: 1fr; }
}

@media (max-width: 767.98px) {
  .crp__hero { flex-wrap: wrap; padding: 1rem; }
  .crp__title { white-space: normal; }
  .crp__reload { width: 100%; }
  .crp-card { padding: 1rem; }
  .crp__kpis { grid-template-columns: repeat(2, 1fr); }
  .crp__questions { grid-template-columns: 1fr; }
}

@media (prefers-reduced-motion: reduce) {
  .crp-bar__fill { transition: none; }
}
```

---

## 6. Paso 5 — `assignment-users`: los mismos colores

### `assignment-users.component.scss` ✏️ — los estados de la tabla de personas

```scss
// Amarillo = finalizado, gris = pendiente, gris oscuro = vencido (solo paleta del sistema).
&[data-tone='done'] { --tone: var(--cu-accent-dark); }
&[data-tone='pending'] { --tone: var(--cu-gray-500); }
&[data-tone='late'] {
  --tone: var(--cu-gray-800);
  background: var(--cu-gray-800);
  color: #fff;
}
```

(Reemplaza las tres líneas de `--cu-onsite`, `--cu-danger` y `--cu-warning`.)

> Los botones de filtro (Todos / Pendientes / Vencidos / Finalizados) ya usan amarillo (`--cu-accent`): no cambian.

---

## 7. Paso 6 — `courses.page` abre la página

### `courses.page.ts` ✏️

1. **Quita:**
   - El import de `CourseResultsModalComponent` y su entrada en `imports`.
   - La señal `selectedCourseForResults`.
2. **Agrega el router:**

   ```ts
   import { Router } from '@angular/router';

   private readonly router = inject(Router);
   ```

3. **`viewResults`:**

   ```ts
   viewResults(course: CourseSummary): void {
     void this.router.navigate(['/cursos', course.id, 'resultados']);
   }
   ```

### `courses.page.html` ✏️ — quita

```html
<app-course-results-modal
  [courseId]="selectedCourseForResults()"
  (close)="selectedCourseForResults.set(null)" />
```

### Borra la carpeta

`features/courses/presentation/course-results-modal/` (los tres archivos). Todo lo que tenía está en la página.

---

## 8. (Opcional) `/grupos`: los botones de la tabla

Si con "el listado de grupos" también te refieres a la tabla de `/grupos`: sus botones usan **azul** (editar) y **rojo** (eliminar) al pasar el mouse.

### `user-groups-list.page.scss` ✏️

```scss
&--edit:hover {
  background: var(--ug-accent);
  color: var(--ug-on-accent);
}

&--danger:hover {
  background: #1f2937; // gris oscuro, como "vencido" en resultados
  color: #fff;
}
```

> Eliminar queda en gris oscuro para respetar "solo amarillos y grises". Si prefieres que la acción destructiva siga en rojo, deja ese bloque como está.

---

# Parte 2 — `grupos/nuevo`: Por gerencia y Por dirección

## 9. Paso 7 — Las pestañas

### `user-group-builder.page.ts` ✏️

```ts
import { OrgUnitImportComponent } from '../org-unit-import/org-unit-import.component';

type ImportTab = 'manager' | 'management' | 'direction' | 'person' | 'emails';

const TABS: readonly { id: ImportTab; label: string; icon: string; soon?: boolean }[] = [
  { id: 'manager', label: 'Por líder', icon: 'fa-sitemap' },
  { id: 'management', label: 'Por gerencia', icon: 'fa-building', soon: true },
  { id: 'direction', label: 'Por dirección', icon: 'fa-layer-group', soon: true },
  { id: 'person', label: 'Buscar persona', icon: 'fa-magnifying-glass' },
  { id: 'emails', label: 'Pegar correos', icon: 'fa-paste' },
];
```

Agrega `OrgUnitImportComponent` a `imports` del `@Component`.

> `onTabKeydown` recorre `this.tabs`, así que las flechas ya pasan por las nuevas sin cambios.

### `user-group-builder.page.html` ✏️

**1. La etiqueta de la pestaña**, con el aviso "Pronto":

```html
<i class="fa-solid {{ tab.icon }}" aria-hidden="true"></i> {{ tab.label }}
@if (tab.soon) {
  <span class="ug-tabs__soon">Pronto</span>
}
```

**2. Los paneles**, dentro del `@switch (activeTab())`:

```html
@case ('management') {
  <app-org-unit-import kind="management" />
}
@case ('direction') {
  <app-org-unit-import kind="direction" />
}
```

### `user-group-builder.page.scss` ✏️

```scss
.ug-tabs {
  // … lo de hoy …
  max-width: 100%; // con 5 pestañas, en el celular se desplaza dentro de la tarjeta
}

.ug-tabs__soon {
  margin-left: 0.35rem;
  padding: 0.05rem 0.45rem;
  border-radius: 999px;
  background: #e5e7eb;
  color: #4b5563;
  font-size: 0.65rem;
  font-weight: 700;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  vertical-align: middle;
}

.ug-tabs__tab.is-active .ug-tabs__soon {
  background: rgba(0, 0, 0, 0.12);
  color: var(--ug-on-accent);
}
```

---

## 10. Paso 8 — `org-unit-import` (nuevo, solo interfaz)

`features/user-groups/presentation/org-unit-import/`

### `org-unit-import.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';

export type OrgUnitKind = 'management' | 'direction';

const COPY: Record<OrgUnitKind, { label: string; plural: string; icon: string; placeholder: string; help: string }> = {
  management: {
    label: 'Gerencia',
    plural: 'gerencias',
    icon: 'fa-building',
    placeholder: 'Selecciona una gerencia',
    help: 'Agrega a todas las personas de la gerencia, con sus direcciones y áreas.',
  },
  direction: {
    label: 'Dirección',
    plural: 'direcciones',
    icon: 'fa-layer-group',
    placeholder: 'Selecciona una dirección',
    help: 'Agrega a todas las personas de la dirección.',
  },
};

/**
 * Agregar personas por gerencia o por dirección.
 * SOLO INTERFAZ: falta la fuente de gerencias y direcciones (maestro de Gestión Humana).
 * Cuando exista, se carga la lista en el select y se emite `added` como en ManagerImportComponent.
 */
@Component({
  selector: 'app-org-unit-import',
  templateUrl: './org-unit-import.component.html',
  styleUrl: './org-unit-import.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class OrgUnitImportComponent {
  readonly kind = input.required<OrgUnitKind>();

  readonly copy = computed(() => COPY[this.kind()]);
  readonly fieldId = computed(() => `org-unit-${this.kind()}`);
}
```

### `org-unit-import.component.html`

```html
<div class="oi">
  <div class="oi__soon" role="note">
    <i class="fa-solid fa-hourglass-half" aria-hidden="true"></i>
    <p class="mb-0">
      <strong>Muy pronto.</strong> Estamos conectando las {{ copy().plural }} del maestro de Gestión Humana.
      Mientras tanto, usa <em>Por líder</em> o <em>Pegar correos</em>.
    </p>
  </div>

  <label class="form-label fw-semibold" [for]="fieldId()">{{ copy().label }}</label>
  <select class="form-select" [id]="fieldId()" disabled>
    <option selected>{{ copy().placeholder }}</option>
  </select>
  <div class="form-text">{{ copy().help }}</div>

  <div class="oi__options">
    <div class="form-check form-switch">
      <input class="form-check-input" type="checkbox" role="switch" [id]="fieldId() + '-leaders'" disabled />
      <label class="form-check-label" [for]="fieldId() + '-leaders'">Incluir a los líderes</label>
    </div>

    <button type="button" class="btn btn-yellow ms-auto" disabled>
      <i class="fa-solid {{ copy().icon }} me-1" aria-hidden="true"></i> Buscar personas
    </button>
  </div>
</div>
```

### `org-unit-import.component.scss`

```scss
@use '../user-groups-tokens' as ug;

.oi__soon {
  display: flex;
  align-items: flex-start;
  gap: 0.75rem;
  margin-bottom: 1.25rem;
  padding: 0.875rem 1rem;
  border: 1px dashed var(--ug-accent);
  border-radius: var(--ug-radius-sm);
  background: rgba(245, 197, 24, 0.08);
  font-size: 0.875rem;

  i {
    margin-top: 0.15rem;
    color: #b58900;
  }
}

// Igual que .mi__options de manager-import.
.oi__options {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 0.75rem 1.5rem;
  margin-top: 1rem;
}

.form-select:disabled,
.btn:disabled {
  cursor: not-allowed;
}
```

---

## 11. Pruebas

**Página de resultados**
- **Abrirla desde Cursos:** "Ver resultados" en una tarjeta abre `/cursos/{id}/resultados`, con el encabezado, el menú y las notificaciones como en las demás páginas.
- **Volver:** "Volver a cursos" y el botón "Atrás" del navegador regresan a Cursos, aunque se hayan cambiado varios grupos.
- **Recargar con `?grupo=` en la URL:** sigue en el mismo grupo. Al copiar la URL en otra pestaña, abre el mismo curso y el mismo grupo.
- **URL inválida:**
  - `/cursos/abc/resultados` → "El curso no es válido" y el botón a Cursos.
  - Un id que no existe → el error de la API con "Reintentar".
- **Escritorio (≥ 992 px):**
  - **La lista lateral:** muestra nombre, % de avance, barra, fecha, `x/y` y las etiquetas "vencidos" y "Eliminado".
  - **Buscar "gestion":** encuentra "Gestión Humana" (sin tildes ni mayúsculas).
  - **"Con vencidos":** solo los grupos con vencidos. Si ninguno coincide, sale "Ningún grupo coincide…".
  - **"Menor avance":** el de menor % arriba.
  - **El grupo activo:** borde y fondo amarillos, y una franja a la izquierda.
  - **La lista con muchos grupos:** queda fija al bajar por la tabla de personas.
- **Celular y tableta (< 992 px):** en lugar de la lista hay un `select` "Grupo" con "Nombre · %". Los filtros lo acotan, y el grupo elegido siempre aparece aunque el filtro lo oculte.
- **Colores:**
  - Ningún verde, naranja, rojo ni azul en la página.
  - Finalizados en amarillo, pendientes en gris, vencidos en gris oscuro con texto blanco.
  - Las barras van en amarillo.
  - Lo mismo en las etiquetas de la tabla de personas.
- **El modal ya no existe:** no queda `app-course-results-modal` en `courses.page.html`, y la carpeta se borró.

**`grupos/nuevo`**
- **Las pestañas:** aparecen "Por gerencia" y "Por dirección" (después de "Por líder"), con la etiqueta "Pronto".
- **Cada pestaña nueva:** el aviso "Muy pronto…", el select, el switch y el botón "Buscar personas" deshabilitados. No se agrega a nadie.
- **Teclado:** las flechas recorren las 5 pestañas.
- **Celular:** las pestañas se desplazan dentro de la tarjeta, sin desbordar la página.
- **Las otras 3 pestañas** funcionan igual que antes.

---

## ✅ Checklist

**Resultados**
- [ ] Ruta `cursos/:id/resultados`.
- [ ] `course-results-page/course-results.page.{ts,html,scss}`.
- [ ] `assignment-users.component.scss` con amarillo y grises.
- [ ] `courses.page` navega a la página; sin el modal ni `selectedCourseForResults`.
- [ ] Carpeta `course-results-modal` eliminada.
- [ ] (Opcional) Botones de `/grupos` en amarillo y gris.

**Grupos**
- [ ] `TABS` con "Por gerencia" y "Por dirección" (`soon: true`) y la etiqueta "Pronto".
- [ ] `@case ('management')` y `@case ('direction')` con `app-org-unit-import`.
- [ ] `org-unit-import.component.{ts,html,scss}`.
