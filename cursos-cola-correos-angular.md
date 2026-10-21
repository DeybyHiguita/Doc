# 📬 Cursos — Envío de correos en segundo plano — Angular

**Lo que cambia para quien administra cursos:**

| Antes | Ahora |
|---|---|
| "Guardar" se quedaba esperando a que salieran todos los correos de bienvenida. | "Guardar" responde enseguida: **"Curso creado · 300 correos de bienvenida en cola"**. |
| No había forma de saber si los correos salieron. | La tarjeta del curso muestra **"⏳ 180 correos en cola"** mientras se envían, o **"⚠ 2 con error"**. |
| — | Un modal **"Envío de correos"** muestra el avance por grupo, el tiempo estimado, quiénes fallaron y un botón **"Reintentar"**. Se actualiza solo cada 5 s. |

La API está en [cursos-cola-correos-api.md](cursos-cola-correos-api.md).

**Base:** el código real de `.claude/Cursos y recordatorios`:
- Repositorio abstracto + servicio + providers.
- `unwrap` / `toErrorMessage` de `@shared/utils/api-response`.
- `course-feedback` (`notifySuccess`, `notifyError`).
- `describeDue`.
- `alertTypeLabel` y `emailLogsLink` de `email-logs`.
- Los tokens `--cu-*`, solo con amarillos y grises.

---

## 1. Archivos

```text
src/app/features/course-emails/
├── domain/
│   ├── course-emails.model.ts                 modelos, textos y tiempos de consulta
│   └── course-emails.repository.ts            contrato
├── infraestructure/
│   ├── course-emails.service.ts               HTTP (api/course-emails)
│   └── course-emails.providers.ts
├── application/
│   ├── course-email-activity.facade.ts        cursos con correos en cola (para las tarjetas)
│   └── course-email-status.facade.ts          detalle de un curso (para el modal)
└── presentation/
    └── course-email-status-modal/             ⭐ "Envío de correos"

✏️ courses/domain/course.model.ts               + queuedEmails
✏️ courses/domain/course.repository.ts          create/update devuelven SaveCourseResult
✏️ courses/infraestructure/course.dto.ts        + queuedEmails
✏️ courses/infraestructure/courses.service.ts
✏️ courses/application/courses.facade.ts        save/updateCourseDirectly devuelven el resultado
✏️ course-editor.component.ts                   aviso con los correos en cola
✏️ add-group-modal.component.ts                 emite cuántos quedaron en cola
✏️ course-card (ts/html/scss)                   indicador de correos y botón del sobre
✏️ courses.page (ts/html)                       facade, consulta y modal
```

---

## 2. Paso 1 — Dominio

### `domain/course-emails.model.ts`

```ts
/** Cuántos correos hay en cada estado. `pending` incluye los que se están enviando en este momento. */
export interface CourseEmailCounts {
  readonly pending: number;
  readonly sent: number;
  readonly failed: number;
  readonly skipped: number;
}

export interface CourseEmailTypeStatus extends CourseEmailCounts {
  /** EmailAlertTypes del backend: COURSE_ASSIGNED, COURSE_DUE_REMINDER… */
  readonly alertType: string;
}

export interface CourseEmailAssignmentStatus {
  readonly assignmentId: number;
  readonly groupName: string;
  /** yyyy-MM-dd */
  readonly dueDate: string;
  readonly types: readonly CourseEmailTypeStatus[];
}

export interface CourseEmailFailedItem {
  readonly id: number;
  readonly alertType: string;
  readonly assignmentId: number;
  readonly name: string | null;
  readonly email: string | null;
  readonly error: string | null;
  readonly attempts: number;
  readonly lastAttemptDate: string | null;
}

export interface CourseEmailStatus extends CourseEmailCounts {
  readonly courseId: number;
  /** Minutos aproximados para vaciar toda la cola. */
  readonly estimatedMinutes: number;
  readonly assignments: readonly CourseEmailAssignmentStatus[];
  readonly failedItems: readonly CourseEmailFailedItem[];
}

/** Un curso con correos en cola o con error (para su tarjeta). */
export interface CourseEmailActivity {
  readonly courseId: number;
  readonly pending: number;
  readonly failed: number;
}

/** Cada cuánto se vuelve a consultar mientras haya correos en cola. */
export const STATUS_POLL_MS = 5_000;
export const ACTIVITY_POLL_MS = 15_000;

export function totalOf(c: CourseEmailCounts): number {
  return c.pending + c.sent + c.failed + c.skipped;
}

/** Porcentaje ya procesado (enviados, con error u omitidos). */
export function processedPercent(c: CourseEmailCounts): number {
  const total = totalOf(c);
  return total ? Math.round(((total - c.pending) / total) * 100) : 100;
}

export function etaLabel(minutes: number): string {
  if (minutes <= 1) return 'menos de un minuto';
  if (minutes < 60) return `unos ${minutes} minutos`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest ? `unas ${hours} h ${rest} min` : `unas ${hours} h`;
}

/** "Curso creado · 300 correos de bienvenida en cola". Sin correos, el mensaje queda igual. */
export function withQueuedEmails(message: string, queued: number): string {
  if (!queued) return message;
  return `${message} · ${queued} ${queued === 1 ? 'correo de bienvenida en cola' : 'correos de bienvenida en cola'}`;
}
```

### `domain/course-emails.repository.ts`

```ts
import { Observable } from 'rxjs';
import { CourseEmailActivity, CourseEmailStatus } from './course-emails.model';

export abstract class CourseEmailsRepository {
  abstract getActive(): Observable<CourseEmailActivity[]>;
  abstract getCourseStatus(courseId: number): Observable<CourseEmailStatus>;
  /** Vuelve a poner en cola los que fallaron. Devuelve cuántos. */
  abstract retryFailed(courseId: number): Observable<number>;
}
```

---

## 3. Paso 2 — Infraestructura

### `infraestructure/course-emails.service.ts`

El JSON tiene la misma forma que el modelo, así que no hace falta mapper.

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, unwrap } from '@shared/utils/api-response';
import { CourseEmailActivity, CourseEmailStatus } from '../domain/course-emails.model';
import { CourseEmailsRepository } from '../domain/course-emails.repository';

@Injectable({ providedIn: 'root' })
export class CourseEmailsService implements CourseEmailsRepository {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/course-emails`;

  getActive(): Observable<CourseEmailActivity[]> {
    return this.http.get<ApiResponse<CourseEmailActivity[]>>(`${this.baseUrl}/active`).pipe(map(unwrap));
  }

  getCourseStatus(courseId: number): Observable<CourseEmailStatus> {
    return this.http.get<ApiResponse<CourseEmailStatus>>(`${this.baseUrl}/courses/${courseId}`).pipe(map(unwrap));
  }

  retryFailed(courseId: number): Observable<number> {
    return this.http.post<ApiResponse<number>>(`${this.baseUrl}/courses/${courseId}/retry`, {}).pipe(map(unwrap));
  }
}
```

### `infraestructure/course-emails.providers.ts`

```ts
import { Provider } from '@angular/core';
import { CourseEmailsRepository } from '../domain/course-emails.repository';
import { CourseEmailsService } from './course-emails.service';

export const COURSE_EMAILS_INFRASTRUCTURE_PROVIDERS: Provider[] = [
  { provide: CourseEmailsRepository, useExisting: CourseEmailsService },
];
```

---

## 4. Paso 3 — Los facades

### `application/course-email-activity.facade.ts`

Para la página de cursos. Consulta una vez cada vez que la lista se recarga y, **solo mientras haya correos en cola**, cada 15 s.

```ts
import { DestroyRef, Injectable, PLATFORM_ID, computed, inject, signal } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { firstValueFrom } from 'rxjs';
import { ACTIVITY_POLL_MS, CourseEmailActivity } from '../domain/course-emails.model';
import { CourseEmailsRepository } from '../domain/course-emails.repository';

@Injectable()
export class CourseEmailActivityFacade {
  private readonly repository = inject(CourseEmailsRepository);
  private readonly isBrowser = isPlatformBrowser(inject(PLATFORM_ID));
  private timer: ReturnType<typeof setTimeout> | null = null;

  private readonly _byCourse = signal<ReadonlyMap<number, CourseEmailActivity>>(new Map());

  readonly byCourse = this._byCourse.asReadonly();
  /** ¿Algún curso tiene correos en cola? Mientras sí, se vuelve a consultar. */
  readonly sending = computed(() => [...this._byCourse().values()].some((a) => a.pending > 0));

  constructor() {
    inject(DestroyRef).onDestroy(() => this.stop());
  }

  async refresh(): Promise<void> {
    if (!this.isBrowser) return; // en el servidor (SSR) no se consulta ni se programan temporizadores
    this.stop();

    try {
      const active = await firstValueFrom(this.repository.getActive());
      this._byCourse.set(new Map(active.map((a) => [a.courseId, a])));
    } catch {
      // Es informativo: si falla, se conserva lo último y se vuelve a intentar en la siguiente vuelta.
    }

    if (this.sending()) {
      this.timer = setTimeout(() => void this.refresh(), ACTIVITY_POLL_MS);
    }
  }

  private stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}
```

### `application/course-email-status.facade.ts`

Para el modal. Se actualiza cada 5 s mientras haya correos en cola de ese curso y se detiene sola al terminar o al cerrar.

```ts
import { DestroyRef, Injectable, inject, signal } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { notifyError } from '@features/courses/course-feedback';
import { CourseEmailStatus, STATUS_POLL_MS } from '../domain/course-emails.model';
import { CourseEmailsRepository } from '../domain/course-emails.repository';

export type EmailStatusLoad = 'idle' | 'loading' | 'ready' | 'error';

@Injectable()
export class CourseEmailStatusFacade {
  private readonly repository = inject(CourseEmailsRepository);
  private timer: ReturnType<typeof setTimeout> | null = null;
  private courseId: number | null = null;

  private readonly _status = signal<CourseEmailStatus | null>(null);
  private readonly _load = signal<EmailStatusLoad>('idle');
  private readonly _error = signal<string | null>(null);
  private readonly _retrying = signal(false);

  readonly status = this._status.asReadonly();
  readonly load = this._load.asReadonly();
  readonly error = this._error.asReadonly();
  readonly retrying = this._retrying.asReadonly();

  constructor() {
    inject(DestroyRef).onDestroy(() => this.stop());
  }

  async open(courseId: number): Promise<void> {
    this.courseId = courseId;
    this._status.set(null);
    await this.reload();
  }

  close(): void {
    this.stop();
    this.courseId = null;
    this._status.set(null);
    this._load.set('idle');
  }

  async reload(): Promise<void> {
    if (!this._status()) this._load.set('loading');
    await this.poll();
  }

  async retryFailed(): Promise<number | null> {
    const courseId = this.courseId;
    if (!courseId) return null;

    this._retrying.set(true);
    try {
      const count = await firstValueFrom(this.repository.retryFailed(courseId));
      await this.poll();
      return count;
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudieron reintentar los correos.'));
      return null;
    } finally {
      this._retrying.set(false);
    }
  }

  // ── Privados ───────────────────────────────────────────────────────

  private async poll(): Promise<void> {
    const courseId = this.courseId;
    if (!courseId) return;
    this.stop();

    try {
      const status = await firstValueFrom(this.repository.getCourseStatus(courseId));
      if (courseId !== this.courseId) return; // cerraron el modal mientras llegaba la respuesta
      this._status.set(status);
      this._error.set(null);
      this._load.set('ready');
    } catch (e) {
      if (courseId !== this.courseId) return;
      // Con datos en pantalla, un fallo pasajero no los borra: se intenta en la siguiente vuelta.
      if (!this._status()) {
        this._error.set(toErrorMessage(e, 'No se pudo cargar el estado de los correos.'));
        this._load.set('error');
        return;
      }
    }

    if ((this._status()?.pending ?? 0) > 0) {
      this.timer = setTimeout(() => void this.poll(), STATUS_POLL_MS);
    }
  }

  private stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}
```

---

## 5. Paso 4 — ⭐ El modal "Envío de correos"

### `course-email-status-modal.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, effect, inject, input, output, untracked } from '@angular/core';
import { RouterLink } from '@angular/router';
import { describeDue } from '@shared/utils/due-date';
import { notifySuccess } from '@features/courses/course-feedback';
import { alertTypeLabel } from '@features/email-logs/domain/email-log.model';
import { EMAIL_LOGS_PATH, emailLogsLink } from '@features/email-logs/application/email-logs.link';
import { CourseEmailStatusFacade } from '../../application/course-email-status.facade';
import { CourseEmailCounts, etaLabel, processedPercent, totalOf } from '../../domain/course-emails.model';

@Component({
  selector: 'app-course-email-status-modal',
  imports: [RouterLink],
  providers: [CourseEmailStatusFacade],
  templateUrl: './course-email-status-modal.component.html',
  styleUrl: './course-email-status-modal.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CourseEmailStatusModalComponent {
  protected readonly facade = inject(CourseEmailStatusFacade);

  readonly courseId = input<number | null>(null);
  readonly courseName = input('');
  readonly close = output<void>();

  readonly isOpen = computed(() => this.courseId() !== null);
  readonly logsPath = EMAIL_LOGS_PATH;

  readonly total = computed(() => {
    const status = this.facade.status();
    return status ? totalOf(status) : 0;
  });

  readonly percent = computed(() => {
    const status = this.facade.status();
    return status ? processedPercent(status) : 0;
  });

  readonly eta = computed(() => etaLabel(this.facade.status()?.estimatedMinutes ?? 0));

  constructor() {
    effect(() => {
      const id = this.courseId();
      untracked(() => (id ? void this.facade.open(id) : this.facade.close()));
    });
  }

  typeLabel(alertType: string): string {
    return alertTypeLabel(alertType);
  }

  dueDate(value: string): string {
    return describeDue(value)?.date ?? value;
  }

  percentOf(counts: CourseEmailCounts): number {
    return processedPercent(counts);
  }

  logsLink(email: string | null) {
    return email ? emailLogsLink(email) : null;
  }

  async retry(): Promise<void> {
    const count = await this.facade.retryFailed();
    if (count) notifySuccess(`${count} ${count === 1 ? 'correo volvió' : 'correos volvieron'} a la cola`);
  }

  onBackdropClick(event: MouseEvent): void {
    if ((event.target as HTMLElement).classList.contains('em-backdrop')) this.close.emit();
  }
}
```

### `course-email-status-modal.component.html`

```html
@if (isOpen()) {
  <div class="em-backdrop" (click)="onBackdropClick($event)">
    <div class="em" role="dialog" aria-modal="true" aria-labelledby="em-title">
      <header class="em__head">
        <div class="em__title-wrap">
          <span class="em__icon"><i class="fa-solid fa-envelope-open-text" aria-hidden="true"></i></span>
          <div>
            <h3 id="em-title" class="em__title">Envío de correos</h3>
            <p class="em__subtitle">{{ courseName() }}</p>
          </div>
        </div>
        <button type="button" class="em__close" aria-label="Cerrar" (click)="close.emit()">
          <i class="fa-solid fa-xmark" aria-hidden="true"></i>
        </button>
      </header>

      <div class="em__body">
        @switch (facade.load()) {
          @case ('loading') {
            <div class="em__state" role="status">
              <div class="spinner-border" aria-hidden="true"></div>
              <p>Cargando el estado de los correos…</p>
            </div>
          }

          @case ('error') {
            <div class="em__state">
              <i class="fa-solid fa-circle-exclamation em__state-icon" aria-hidden="true"></i>
              <p>{{ facade.error() }}</p>
              <button type="button" class="btn btn-yellow btn-sm" (click)="facade.reload()">
                <i class="fa-solid fa-rotate-right me-1" aria-hidden="true"></i> Reintentar
              </button>
            </div>
          }

          @default {
            @if (facade.status(); as status) {
              @if (!total()) {
                <div class="em__state">
                  <i class="fa-regular fa-envelope em__state-icon" aria-hidden="true"></i>
                  <p>Este curso no tiene correos en cola ni recientes.</p>
                </div>
              } @else {
                <!-- ── Resumen ─────────────────────────────────────────── -->
                <section class="em__section" aria-labelledby="em-summary">
                  <h4 id="em-summary" class="visually-hidden">Resumen</h4>

                  <div class="em-summary" aria-live="polite">
                    @if (status.pending) {
                      <span class="spinner-border spinner-border-sm" aria-hidden="true"></span>
                      <p class="mb-0">
                        <strong>Enviando…</strong> faltan {{ status.pending }}.
                        Tiempo estimado: {{ eta() }}.
                      </p>
                    } @else {
                      <i class="fa-solid fa-circle-check em-summary__done" aria-hidden="true"></i>
                      <p class="mb-0"><strong>Envío terminado.</strong></p>
                    }
                  </div>

                  <div class="em-progress" role="progressbar"
                       [attr.aria-valuenow]="percent()" aria-valuemin="0" aria-valuemax="100"
                       [attr.aria-label]="percent() + ' % procesado'">
                    <span class="em-progress__bar" [style.width.%]="percent()"></span>
                  </div>

                  <div class="em-chips">
                    <span class="em-chip" data-tone="sent"><i class="fa-solid fa-check" aria-hidden="true"></i> {{ status.sent }} enviados</span>
                    <span class="em-chip"><i class="fa-regular fa-clock" aria-hidden="true"></i> {{ status.pending }} en cola</span>
                    @if (status.failed) {
                      <span class="em-chip" data-tone="failed"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i> {{ status.failed }} con error</span>
                    }
                    @if (status.skipped) {
                      <span class="em-chip" title="Ya no aplicaban: la persona salió del curso, el curso se eliminó…">
                        <i class="fa-solid fa-forward" aria-hidden="true"></i> {{ status.skipped }} omitidos
                      </span>
                    }
                  </div>

                  @if (status.pending) {
                    <p class="em__hint">Puedes cerrar esta ventana: el envío sigue en segundo plano.</p>
                  }
                </section>

                <!-- ── Por grupo ───────────────────────────────────────── -->
                <section class="em__section" aria-labelledby="em-groups">
                  <h4 id="em-groups" class="em__section-title">Por grupo</h4>
                  <ul class="em-groups">
                    @for (a of status.assignments; track a.assignmentId) {
                      <li class="em-group">
                        <div class="em-group__head">
                          <span class="em-group__name">{{ a.groupName }}</span>
                          <span class="em-group__due">Vence {{ dueDate(a.dueDate) }}</span>
                        </div>
                        @for (t of a.types; track t.alertType) {
                          <div class="em-type">
                            <span class="em-type__label">{{ typeLabel(t.alertType) }}</span>
                            <span class="em-type__track" aria-hidden="true">
                              <span class="em-type__fill" [style.width.%]="percentOf(t)"></span>
                            </span>
                            <span class="em-type__count">
                              {{ t.sent }} de {{ t.sent + t.pending + t.failed + t.skipped }}
                              @if (t.failed) { · <strong>{{ t.failed }} con error</strong> }
                            </span>
                          </div>
                        }
                      </li>
                    }
                  </ul>
                </section>

                <!-- ── Con error ───────────────────────────────────────── -->
                @if (status.failedItems.length) {
                  <section class="em__section" aria-labelledby="em-failed">
                    <div class="em__section-head">
                      <h4 id="em-failed" class="em__section-title">Con error</h4>
                      <button type="button" class="btn btn-yellow btn-sm" [disabled]="facade.retrying()" (click)="retry()">
                        @if (facade.retrying()) {
                          <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>
                        } @else {
                          <i class="fa-solid fa-rotate-right me-1" aria-hidden="true"></i>
                        }
                        Reintentar {{ status.failed === 1 ? 'el correo' : 'los ' + status.failed }}
                      </button>
                    </div>

                    <div class="table-responsive">
                      <table class="table table-sm em-table">
                        <thead>
                          <tr><th scope="col">Persona</th><th scope="col">Tipo</th><th scope="col">Error</th><th scope="col" class="text-end">Intentos</th></tr>
                        </thead>
                        <tbody>
                          @for (f of status.failedItems; track f.id) {
                            <tr>
                              <td>
                                <strong>{{ f.name ?? f.email ?? '—' }}</strong>
                                @if (logsLink(f.email); as link) {
                                  <a class="d-block small" [routerLink]="link.commands" [queryParams]="link.queryParams">Ver en el registro</a>
                                }
                              </td>
                              <td>{{ typeLabel(f.alertType) }}</td>
                              <td class="em-table__error">{{ f.error ?? '—' }}</td>
                              <td class="text-end">{{ f.attempts }}</td>
                            </tr>
                          }
                        </tbody>
                      </table>
                    </div>
                  </section>
                }
              }
            }
          }
        }
      </div>

      <footer class="em__foot">
        <a class="btn btn-link" [routerLink]="logsPath">Registro de correos</a>
        <button type="button" class="btn btn-outline-secondary" (click)="close.emit()">Cerrar</button>
      </footer>
    </div>
  </div>
}
```

### `course-email-status-modal.component.scss`

```scss
@use '../../../../../styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
}

// ── Contenedor (mismo lenguaje que el modal de resultados) ────────────
.em-backdrop {
  position: fixed;
  inset: 0;
  z-index: 1050;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1rem;
  background: rgba(0, 0, 0, 0.5);
  backdrop-filter: blur(4px);
}

.em {
  display: flex;
  flex-direction: column;
  width: 100%;
  max-width: 760px;
  max-height: 90vh;
  overflow: hidden;
  border-radius: 16px;
  background: var(--cu-surface);
  box-shadow: 0 10px 40px rgba(0, 0, 0, 0.15);
}

.em__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  padding: 1.25rem 1.5rem;
  border-bottom: 2px solid var(--cu-gray-100);
}

.em__title-wrap {
  display: flex;
  gap: 0.75rem;
  align-items: center;
}

.em__icon {
  display: grid;
  place-items: center;
  width: 2.5rem;
  height: 2.5rem;
  border-radius: var(--cu-radius);
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);
}

.em__title {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 700;
  color: var(--cu-text);
}

.em__subtitle {
  margin: 0;
  color: var(--cu-muted);
  font-size: 0.875rem;
}

.em__close {
  border: 0;
  background: transparent;
  color: var(--cu-gray-500);
  font-size: 1.25rem;

  &:hover {
    color: var(--cu-gray-900);
  }
}

.em__body {
  overflow-y: auto;
  padding: 1.25rem 1.5rem;
}

.em__foot {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.5rem;
  padding: 0.75rem 1.5rem;
  border-top: 1px solid var(--cu-gray-100);
}

.em__state {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.75rem;
  padding: 2rem 1rem;
  color: var(--cu-muted);
  text-align: center;
}

.em__state-icon {
  font-size: 2rem;
  color: var(--cu-gray-400);
}

.em__section + .em__section {
  margin-top: 1.5rem;
}

.em__section-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  margin-bottom: 0.5rem;
}

.em__section-title {
  margin: 0 0 0.5rem;
  font-size: 0.95rem;
  font-weight: 700;
  color: var(--cu-text);
}

.em__hint {
  margin: 0.5rem 0 0;
  font-size: 0.8125rem;
  color: var(--cu-muted);
}

// ── Resumen ───────────────────────────────────────────────────────────
.em-summary {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin-bottom: 0.75rem;
  color: var(--cu-text);
}

.em-summary__done {
  color: var(--cu-accent-dark);
  font-size: 1.25rem;
}

.em-progress {
  height: 10px;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-gray-100);
}

.em-progress__bar {
  display: block;
  height: 100%;
  border-radius: inherit;
  background: var(--cu-accent);
  transition: width 0.4s ease;
}

.em-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  margin-top: 0.75rem;
}

.em-chip {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.25rem 0.65rem;
  border-radius: 999px;
  background: var(--cu-gray-100);
  color: var(--cu-gray-700);
  font-size: 0.8125rem;
  font-weight: 600;

  &[data-tone='sent'] {
    background: var(--cu-accent-subtle-bg);
    color: var(--cu-accent-text);
  }

  &[data-tone='failed'] {
    background: var(--cu-gray-800);
    color: #fff;
  }
}

// ── Por grupo ─────────────────────────────────────────────────────────
.em-groups {
  display: grid;
  gap: 0.75rem;
  margin: 0;
  padding: 0;
  list-style: none;
}

.em-group {
  padding: 0.75rem 1rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
}

.em-group__head {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: 0.25rem 1rem;
  margin-bottom: 0.5rem;
}

.em-group__name {
  font-weight: 700;
  color: var(--cu-text);
}

.em-group__due {
  font-size: 0.8125rem;
  color: var(--cu-muted);
}

.em-type {
  display: grid;
  grid-template-columns: minmax(8rem, 12rem) 1fr auto;
  align-items: center;
  gap: 0.75rem;
  font-size: 0.8125rem;

  & + & {
    margin-top: 0.4rem;
  }

  @media (max-width: 575.98px) {
    grid-template-columns: 1fr auto;

    .em-type__track {
      grid-column: 1 / -1;
      order: 3;
    }
  }
}

.em-type__label {
  color: var(--cu-gray-700);
}

.em-type__track {
  height: 6px;
  overflow: hidden;
  border-radius: 999px;
  background: var(--cu-gray-100);
}

.em-type__fill {
  display: block;
  height: 100%;
  background: var(--cu-accent);
}

.em-type__count {
  color: var(--cu-gray-600);
  white-space: nowrap;
}

// ── Con error ─────────────────────────────────────────────────────────
.em-table {
  font-size: 0.8125rem;

  th {
    color: var(--cu-gray-600);
    font-weight: 600;
  }
}

.em-table__error {
  color: var(--cu-gray-700);
  max-width: 18rem;
}
```

---

## 6. Paso 5 — Cursos: el resultado de guardar trae los correos en cola

### `courses/domain/course.model.ts` ✏️

```ts
export interface SyncAssignmentResult {
  readonly added: number;
  readonly removedPending: number;
  readonly skippedWithoutUser: number;
  /** Correos de bienvenida que quedaron en cola. */
  readonly queuedEmails: number;
}

export interface SaveCourseResult {
  readonly courseId: number;
  readonly skippedWithoutUser: number;
  /** Correos de bienvenida que quedaron en cola. */
  readonly queuedEmails: number;
}
```

### `courses/infraestructure/course.dto.ts` ✏️

```ts
export interface SaveCourseResultDto {
  courseId: number;
  skippedWithoutUser: number;
  queuedEmails: number;
}
```

### `courses/domain/course.repository.ts` ✏️

```ts
abstract create(draft: CourseDraft): Observable<SaveCourseResult>;
abstract update(id: number, draft: CourseDraft): Observable<SaveCourseResult>;
```

(Agrega `SaveCourseResult` al import de `./course.model`.)

### `courses/infraestructure/courses.service.ts` ✏️

La API ya devolvía `SaveCourseResultDto` en los dos. Ahora el frontend lo lee:

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
```

(Agrega `SaveCourseResult` y `SaveCourseResultDto` a sus imports.)

### `courses/application/courses.facade.ts` ✏️

```ts
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

/** Actualizar curso sin abrir el modal del editor */
async updateCourseDirectly(id: number, draft: CourseDraft): Promise<SaveCourseResult> {
  const result = await firstValueFrom(this.repository.update(id, draft));
  this.reload();
  return result;
}
```

### `course-editor.component.ts` ✏️ — en `save()`

```ts
const result = await this.facade.save(toCourseDraft(this.form));
notifySuccess(withQueuedEmails(wasEdit ? 'Curso actualizado' : 'Curso creado', result.queuedEmails));
```

```ts
import { withQueuedEmails } from '@features/course-emails/domain/course-emails.model';
```

### `add-group-modal.component.ts` ✏️ — emite cuántos quedaron en cola

```ts
readonly groupAdded = output<number>();
```

```ts
// Actualizar directamente SIN abrir el modal del editor
const result = await this.facade.updateCourseDirectly(courseId, updatedDraft);

this.form.reset();
this.groupAdded.emit(result.queuedEmails);
this.close.emit();
```

---

## 7. Paso 6 — La tarjeta del curso

### `course-card.component.ts` ✏️

```ts
import { CourseEmailActivity } from '@features/course-emails/domain/course-emails.model';
```

```ts
/** Correos de este curso en cola o con error. null = nada pendiente. */
readonly emailActivity = input<CourseEmailActivity | null>(null);

readonly viewEmails = output<void>();
```

### `course-card.component.html` ✏️

**1. En `.course-card__actions`, antes de "Editar"**, el acceso al estado de los correos (solo si el curso tiene asignaciones):

```html
@if (course().assignedCount > 0) {
  <button
    type="button"
    class="action-btn action-btn--emails"
    [attr.aria-label]="'Envío de correos de ' + course().name"
    title="Envío de correos"
    (click)="viewEmails.emit()">
    <i class="fa-solid fa-envelope" aria-hidden="true"></i>
  </button>
}
```

**2. En `.course-card__stats`, después del chip de la fecha:**

```html
@if (emailActivity(); as mail) {
  <button
    type="button"
    class="stat-chip stat-chip--mail"
    [class.is-error]="!mail.pending"
    [attr.aria-label]="mail.pending
      ? mail.pending + ' correos en cola. Ver el envío'
      : mail.failed + ' correos con error. Ver el envío'"
    (click)="viewEmails.emit()">
    @if (mail.pending) {
      <span class="spinner-border spinner-border-sm" aria-hidden="true"></span>
      <span class="stat-chip__value">{{ mail.pending }}</span>
      <span class="stat-chip__label">{{ mail.pending === 1 ? 'correo en cola' : 'correos en cola' }}</span>
    } @else {
      <i class="fa-solid fa-triangle-exclamation stat-chip__icon" aria-hidden="true"></i>
      <span class="stat-chip__value">{{ mail.failed }}</span>
      <span class="stat-chip__label">con error</span>
    }
  </button>
}
```

### `course-card.component.scss` ✏️

```scss
.stat-chip--mail {
  border: 0;
  cursor: pointer;
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);

  .spinner-border-sm {
    width: 0.8rem;
    height: 0.8rem;
    border-width: 0.15em;
  }

  &.is-error {
    background: var(--cu-gray-800);
    color: #fff;
  }

  &:focus-visible {
    outline: 2px solid var(--cu-accent-dark);
    outline-offset: 2px;
  }
}

.action-btn--emails:hover {
  background: #f5c518;
  color: #111827;
}
```

> Si `.stat-chip` no define `display: inline-flex` y `gap`, agrégalos aquí para que el spinner y el número queden alineados.

---

## 8. Paso 7 — La página de cursos

### `courses.page.ts` ✏️

**1. Imports y providers:**

```ts
import { untracked } from '@angular/core'; // junto a los demás de @angular/core
import { COURSE_EMAILS_INFRASTRUCTURE_PROVIDERS } from '@features/course-emails/infraestructure/course-emails.providers';
import { CourseEmailActivityFacade } from '@features/course-emails/application/course-email-activity.facade';
import { CourseEmailStatusModalComponent } from '@features/course-emails/presentation/course-email-status-modal/course-email-status-modal.component';
import { withQueuedEmails } from '@features/course-emails/domain/course-emails.model';
```

```ts
imports: [/* …los de hoy…, */ CourseEmailStatusModalComponent],
providers: [
  ...COURSES_INFRASTRUCTURE_PROVIDERS,
  ...USER_GROUPS_INFRASTRUCTURE_PROVIDERS,
  ...COURSE_EMAILS_INFRASTRUCTURE_PROVIDERS,
  CoursesFacade,
  CourseEmailActivityFacade,
],
```

**2. Estado:**

```ts
protected readonly emailActivity = inject(CourseEmailActivityFacade);
readonly selectedCourseForEmails = signal<{ id: number; name: string } | null>(null);
```

**3. En el constructor:** cada vez que la lista se recarga (al entrar, al guardar, al cambiar de página), se pregunta qué cursos tienen correos en cola.

```ts
effect(() => {
  this.facade.courses();
  untracked(() => void this.emailActivity.refresh());
});
```

**4. Métodos:**

```ts
viewEmails(course: CourseSummary): void {
  this.selectedCourseForEmails.set({ id: course.id, name: course.name });
}

closeEmails(): void {
  this.selectedCourseForEmails.set(null);
  void this.emailActivity.refresh(); // pudo haber reintentado: la tarjeta se actualiza
}
```

**5. `onGroupAdded`** recibe cuántos quedaron en cola:

```ts
async onGroupAdded(queuedEmails: number): Promise<void> {
  const courseId = this.selectedCourseForAddGroup()?.id;
  if (!courseId) return;

  this.closeAddGroupModal();
  notifySuccess(withQueuedEmails('Grupo agregado exitosamente', queuedEmails));

  // … lo de hoy (reabrir el modal de grupos) …
}
```

### `courses.page.html` ✏️

**1. En `<app-course-card>`:**

```html
[emailActivity]="emailActivity.byCourse().get(course.id) ?? null"
(viewEmails)="viewEmails(course)"
```

**2. `(groupAdded)` del modal de agregar grupo:**

```html
(groupAdded)="onGroupAdded($event)"
```

**3. Junto a los demás modales:**

```html
<app-course-email-status-modal
  [courseId]="selectedCourseForEmails()?.id ?? null"
  [courseName]="selectedCourseForEmails()?.name ?? ''"
  (close)="closeEmails()" />
```

---

## 9. Pruebas

**Guardar sin esperar**
- **Crear un curso con un grupo de 300 personas:**
  - El editor se cierra en uno o dos segundos.
  - Aviso: "Curso creado · 300 correos de bienvenida en cola".
- **"Agregar grupo" desde el modal de grupos:** "Grupo agregado exitosamente · 25 correos de bienvenida en cola".
- **Cambiar solo la fecha de un grupo:** el aviso de siempre, sin correos en cola.

**La tarjeta**
- **Mientras se envía:** la tarjeta muestra el spinner y "N correos en cola", y el número baja solo cada 15 s.
- **Al terminar:** el indicador desaparece y la página deja de consultar (revisa la pestaña Network: no hay más `active`).
- **Con correos fallidos:** el indicador queda en gris oscuro con "N con error".
- **El sobre de las acciones:** abre el modal aunque no haya nada en cola.

**El modal "Envío de correos"**
- **Mientras se envía:**
  - "Enviando… faltan N. Tiempo estimado: unos 12 minutos".
  - La barra y los conteos se actualizan cada 5 s.
  - Dice que se puede cerrar la ventana.
- **Por grupo:** cada grupo con su fecha y una barra por tipo ("Curso asignado: 120 de 300").
- **Al terminar:** "Envío terminado." y deja de consultar.
- **Con error:**
  - La tabla muestra persona, tipo, error e intentos, y "Ver en el registro" abre "Registro de correos" filtrado por ese correo.
  - "Reintentar los N" muestra el aviso "N correos volvieron a la cola" y la tabla se vacía mientras se reenvían.
- **API caída al abrir:** el mensaje de error con "Reintentar".
- **Curso sin correos:** "Este curso no tiene correos en cola ni recientes".
- **Celular (< 576 px):** la barra de cada tipo baja a su propia línea y no hay scroll horizontal (la tabla tiene el suyo).

**Colores:** solo amarillos y grises (barra amarilla, enviados en amarillo suave, con error en gris oscuro).

---

## ✅ Checklist

- [ ] `features/course-emails`: modelo, repositorio, servicio y providers.
- [ ] `CourseEmailActivityFacade` y `CourseEmailStatusFacade`.
- [ ] `course-email-status-modal` (ts, html, scss).
- [ ] Cursos: `queuedEmails` en el modelo y el DTO; `create`/`update` y la facade devuelven `SaveCourseResult`.
- [ ] Avisos con `withQueuedEmails` en el editor y en "Agregar grupo".
- [ ] Tarjeta: indicador de correos, botón del sobre y estilos.
- [ ] Página de cursos: providers, el `effect` que consulta, el modal y `onGroupAdded($event)`.
